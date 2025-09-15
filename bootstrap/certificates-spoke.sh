#!/bin/bash

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

ACME_STAGING=${ACME_STAGING:-}
ACME_SERVER=https://acme-v02.api.letsencrypt.org/directory
HOSTED_ZONE=${HOSTED_ZONE:-}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-}

if [ ! -z "${ACME_STAGING}" ]; then
    ACME_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory
fi

create_aws_secrets() {
    echo "🌴 Running create_aws_secrets..."

    oc get secret aws-creds -n kube-system -o yaml | sed 's/namespace: .*/namespace: openshift-config/' | oc -n openshift-config apply -f-
    oc get secret aws-creds -n kube-system -o yaml | sed 's/namespace: .*/namespace: openshift-ingress/' | oc -n openshift-ingress apply -f-
    export AWS_ACCESS_KEY_ID=$(oc get secret aws-creds -n kube-system -o template='{{index .data "aws_access_key_id"}}' | base64 -d)
    if [ "$?" != 0 ]; then
        echo -e "🚨${RED}Failed - to find aws_access_key_id ?${NC}"
    fi

    echo "🌴 create_aws_secrets ran OK"
}

update_cert_manager() {

    echo "🌴 Running update_cert_manager..."

cat <<EOF | oc apply -f-
apiVersion: operator.openshift.io/v1alpha1
kind: CertManager
metadata:
  finalizers:
  - cert-manager-operator.operator.openshift.io/cert-manager-webhook-deployment
  - cert-manager-operator.operator.openshift.io/cert-manager-controller-deployment
  - cert-manager-operator.operator.openshift.io/cert-manager-cainjector-deployment
  name: cluster
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  logLevel: Normal
  managementState: Managed
  observedConfig: null
  operatorLogLevel: Normal
  unsupportedConfigOverrides: null
  controllerConfig:
    overrideArgs:
      - '--dns01-recursive-nameservers-only'
      - '--dns01-recursive-nameservers=1.1.1.1:53'
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run update_cert_manager ?${NC}"
      exit 1
    else
      echo "🌴 update_cert_manager ran OK"
    fi
}

create_issuers() {
    echo "🌴 Running create_issuers..."

cat <<EOF | oc apply -f-
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-api
  namespace: openshift-config
spec:
  acme:
    server: "${ACME_SERVER}"
    email: "${EMAIL}"
    privateKeySecretRef:
      name: tls-secret
    solvers:
    - dns01:
        route53:
          accessKeyID: ${AWS_ACCESS_KEY_ID}
          hostedZoneID: $(echo ${HOSTED_ZONE} | sed 's/\/hostedzone\///g')
          region: ${AWS_DEFAULT_REGION}
          secretAccessKeySecretRef:
            name: "aws-creds"
            key: "aws_secret_access_key"
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_issuers ?${NC}"
      exit 1
    fi

cat <<EOF | oc apply -f-
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-ingress
  namespace: openshift-ingress
spec:
  acme:
    server: "${ACME_SERVER}"
    email: "${EMAIL}"
    privateKeySecretRef:
      name: tls-secret
    solvers:
    - dns01:
        route53:
          accessKeyID: ${AWS_ACCESS_KEY_ID}
          hostedZoneID: $(echo ${HOSTED_ZONE} | sed 's/\/hostedzone\///g')
          region: ${AWS_DEFAULT_REGION}
          secretAccessKeySecretRef:
            name: "aws-creds"
            key: "aws_secret_access_key"
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_issuers ?${NC}"
      exit 1
    else
      echo "🌴 create_issuers ran OK"
    fi
}

create_certificates() {
    echo "🌴 Running create_certificates..."

cat <<EOF | oc apply -f-
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: api-cert
  namespace: openshift-config
spec:
  isCA: false
  commonName: "${LE_API}"
  secretName: tls-api
  dnsNames:
  - "${LE_API}"
  issuerRef:
    name: letsencrypt-api
    kind: Issuer
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_certificates ?${NC}"
      exit 1
    fi

cat <<EOF | oc apply -f-
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: apps-cert
  namespace: openshift-ingress
spec:
  isCA: false
  commonName: "${LE_WILDCARD}"
  secretName: tls-apps
  dnsNames:
  - "${LE_WILDCARD}"
  - "*.${LE_WILDCARD}"
  issuerRef:
    name: letsencrypt-ingress
    kind: Issuer
EOF

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run create_certificates ?${NC}"
      exit 1
    else
      echo "🌴 create_certificates ran OK"
    fi
}

wait_for_api_issuer() {
    oc wait --for=condition=Ready issuer letsencrypt-api -n openshift-config
    local i=0
    until [ "$?" == 0 ]
    do
        echo -e "Wait for issuer letsencrypt-api to be ready."
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "🚨 Failed - issuer letsencrypt-api never ready?."
            exit 1
        fi
        sleep 5
        oc wait --for=condition=Ready issuer letsencrypt-api -n openshift-config
    done
}

wait_for_ingress_issuer() {
    oc wait --for=condition=Ready issuer letsencrypt-ingress -n openshift-ingress
    local i=0
    until [ "$?" == 0 ]
    do
        echo -e "Wait for issuer letsencrypt-ingress to be ready."
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "🚨 Failed - issuer letsencrypt-ingress never ready?."
            exit 1
        fi
        sleep 5
        oc wait --for=condition=Ready issuer letsencrypt-ingress -n openshift-ingress
    done
}

wait_for_api_cert() {
    local i=0
    oc wait --for=condition=Ready certificate api-cert -n openshift-config
    until [ "$?" == 0 ]
    do
        echo -e "Wait for certificate api-cert to be ready."
        ((i=i+1))
        if [ $i -gt 500 ]; then
            echo -e "🚨 Failed - certificate api-cert never ready?."
            exit 1
        fi
        sleep 5
        oc wait --for=condition=Ready certificate api-cert -n openshift-config
    done
}

wait_for_ingress_cert() {
    local i=0
    oc wait --for=condition=Ready certificate apps-cert -n openshift-ingress
    until [ "$?" == 0 ]
    do
        echo -e "Wait for certificate apps-cert to be ready."
        ((i=i+1))
        if [ $i -gt 500 ]; then
            echo -e "🚨 Failed - certificate apps-cert never ready?."
            exit 1
        fi
        sleep 5
        oc wait --for=condition=Ready certificate apps-cert -n openshift-ingress
    done
}

patch_api_server() {
    echo "🌴 Running patch_api_server..."

    PATCH='{"spec":{"servingCerts": {"namedCertificates": [{"names": ["'${LE_API}'"], "servingCertificate": {"name": "tls-api"}}]}}}'
    oc patch apiserver cluster --type=merge -p "${PATCH}"

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run patch_api_server ?${NC}"
      exit 1
    else
      echo "🌴 patch_api_server ran OK"
    fi
}

patch_ingress() {
    echo "🌴 Running patch_ingress..."

    oc -n openshift-ingress-operator patch ingresscontroller default --patch '{"spec": { "defaultCertificate": { "name": "tls-apps"}}}' --type=merge

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run patch_ingress ?${NC}"
      exit 1
    else
      echo "🌴 patch_ingress ran OK"
    fi
}

check_done() {
    echo "🌴 Running check_done..."
    oc -n openshift-ingress wait certs apps-cert --for=condition=Ready --timeout=2s

    if [ "$?" != 0 ]; then
      echo -e "💀${ORANGE}Warn - check_done not ready for apps-cert, continuing ${NC}"
      return 1
    else
      echo "🌴 apps-cert ran OK"
    fi

    oc -n openshift-config wait certs api-cert --for=condition=Ready --timeout=2s

    if [ "$?" != 0 ]; then
      echo -e "💀${ORANGE}Warn - check_done not ready for api-cert, continuing ${NC}"
      return 1
    else
      echo "🌴 api-cert ran OK"
    fi

    patch_api_server
    patch_ingress

    return 0
}

all() {
    if check_done; then return; fi

    create_aws_secrets

    update_cert_manager

    create_issuers
    wait_for_api_issuer
    wait_for_ingress_issuer

    create_certificates
    wait_for_api_cert
    wait_for_ingress_cert

    patch_api_server
    patch_ingress
}

progress() {
    cat <<EOF 2>&1
🌻 Track progress using: 🌻

  watch oc get co
EOF
}

# Check for EnvVars
[ -z "$EMAIL" ] && echo "🕱 Error: must supply EMAIL in env" && exit 1
[ -z "$HOSTED_ZONE" ] && echo "🕱 Error: must supply HOSTED_ZONE in env" && exit 1
[ -z "$AWS_DEFAULT_REGION" ] && echo "🕱 Error: AWS_DEFAULT_REGION not set in env" && exit 1

# set these
LE_API=api.$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
LE_WILDCARD=$(oc get ingress.config/cluster -o 'jsonpath={.spec.domain}')
[ -z "$LE_API" ] && echo "🕱 Error: LE_API could not set" && exit 1
[ -z "$LE_WILDCARD" ] && echo "🕱 Error: LE_WILDCARD could not set" && exit 1

all

progress
echo -e "\n🌻${GREEN}Certificates configured OK.${NC}🌻\n"
exit 0

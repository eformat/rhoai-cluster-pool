#!/bin/bash
set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color

export HOME=/tmp

ENVIRONMENT=${ENVIRONMENT:-roadshow}
if [ -z "${ENVIRONMENT}" ]; then
    echo -e "🕱${RED}Failed - to get secret ENVIRONMENT ?${NC}"
    exit 1
fi

export CLUSTER_NAME=${CLUSTER_NAME:-sno}
export CLUSTER_DOMAIN=$(oc get ingress.config/cluster -o 'jsonpath={.spec.domain}')
export BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')

patch_proxy() {
    echo "🌴 Patch Proxy..."

    wget -P /tmp https://raw.githubusercontent.com/eformat/rhoai-cluster-pool/refs/heads/main/bootstrap/vault-ca.crt
    if [ ! -f "/tmp/vault-ca.crt" ]; then
        echo -e "🕱${RED}Failed - to get vault-ca.crt file ?${NC}" 
        exit 1
    fi

    oc -n openshift-config create configmap custom-ca --from-file=ca-bundle.crt=/tmp/vault-ca.crt
    oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'
    rm -f /tmp/vault-ca.crt
    echo "🌴 Patch Proxy Done"
}
patch_proxy

eso_configmap() {
    echo "🌴 Running eso_configmap..."

cat <<EOF | oc apply -f-
kind: ConfigMap
apiVersion: v1
metadata:
  name: ca-bundle
  namespace: external-secrets
  labels:
    config.openshift.io/inject-trusted-cabundle: 'true'
EOF

    if [ "$?" != 0 ]; then
        echo -e "🚨${RED}Failed - to run eso_configmap ?${NC}"
        exit 1
    else
        echo "🌴 eso_configmap ran OK"
    fi
}
eso_configmap

check_done() {
    echo "🌴 Running check_done..."
    STATUS=$(oc -n external-secrets get $(oc get pods -n external-secrets -l app.kubernetes.io/name=external-secrets -o name) -o=jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    until [ "$STATUS" == "True" ]
    do
        echo -e "${GREEN}Waiting for eso pod to be ready.${NC}"
        sleep 5
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "🚨${RED}Failed waiting for eso pod to be ready?.${NC}"
            exit 1
        fi
        STATUS=$(oc -n external-secrets get $(oc get pods -n external-secrets -l app.kubernetes.io/name=external-secrets -o name) -o=jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    done
    echo "🌴 check_done ran OK"
    return 0
}

apply_helm() {
    echo "🌴 Apply ESO Helm..."

    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update external-secrets

    wget -P /tmp https://raw.githubusercontent.com/eformat/rhoai-cluster-pool/refs/heads/main/bootstrap/external-secrets-values.yaml
    if [ ! -f "/tmp/external-secrets-values.yaml" ]; then
        echo -e "🕱${RED}Failed - to get external-secrets-values file ?${NC}"
        exit 1
    fi

    helm upgrade --install \
        external-secrets \
        external-secrets/external-secrets \
        -f /tmp/external-secrets-values.yaml \
        -n external-secrets \
        --create-namespace \
        --set installCRDs=true
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to apply external-secrets helm chart ${NC}"
        exit 1
    fi
    echo "🌴 Apply ESO Helm Done"
}
apply_helm

apply_cr() {
    echo "🌴 Apply ESO CR..."

    wget -P /tmp https://raw.githubusercontent.com/eformat/rhoai-cluster-pool/refs/heads/main/bootstrap/external-secrets-cr.yaml
    if [ ! -f "/tmp/external-secrets-cr.yaml" ]; then
        echo -e "🕱${RED}Failed - to get external-secrets-cr file ?${NC}"
        exit 1
    fi

    cat /tmp/external-secrets-cr.yaml | envsubst | oc apply -f-
    until [ "${PIPESTATUS[2]}" == 0 ]
    do
        echo -e "${GREEN}Waiting for 0 rc from oc commands.${NC}"
        ((i=i+1))
        if [ $i -gt 10 ]; then
            echo -e "🕱${RED}Failed - eso cr never ready?.${NC}"
            exit 1
        fi
        sleep 10
        cat /tmp/external-secrets-cr.yaml | envsubst | oc apply -f-
    done
    echo "🌴 Apply ESO CR Done"
}
apply_cr

if check_done; then
    echo -e "\n🌻${GREEN}ESO setup OK.${NC}🌻\n"
    exit 0;
else
    echo -e "💀${ORANGE}Warn - ESO setup not ready, continuing ${NC}"
    exit 1
fi

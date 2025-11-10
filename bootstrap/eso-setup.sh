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

check_done() {
    echo "🌴 Running check_done..."
    STATUS=$(oc -n external-secrets get $(oc get pods -n external-secrets -l app.kubernetes.io/name=external-secrets -o name) -o=jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$STATUS" != "True" ]; then
      echo -e "💀${ORANGE}Warn - check_done not ready for eso, continuing ${NC}"
      return 1
    else
      echo "🌴 check_done ran OK"
    fi
    return 0
}

if check_done; then
    echo -e "\n🌻${GREEN}ESO setup OK.${NC}🌻\n"
    exit 0;
fi

apply_helm() {
    echo "🌴 Apply ESO Helm..."

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
        --set installCRDs=true
    if [ "$?" != 0 ]; then
        echo -e "🕱${RED}Failed - to apply external-secrets helm chart ${NC}"
        exit 1
    fi
    echo "🌴 Apply ESO Helm Done"
}
apply_helm

if check_done; then
    echo -e "\n🌻${GREEN}ESO setup OK.${NC}🌻\n"
    exit 0;
else
    echo -e "💀${ORANGE}Warn - ESO setup not ready, continuing ${NC}"
    exit 1
fi

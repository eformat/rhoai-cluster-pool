#!/bin/bash
set -o pipefail
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color

cd ${WORK_DIR} && git clone https://github.com/eformat/rhoai-cluster-pool.git
cd ${WORK_DIR}/rhoai-cluster-pool

echo "💥 Working directory is: $(pwd)" | tee -a output.log

# hack for quoting
export PULL_SECRET=$(cat ${PULL_SECRET})

# use roadshow app-of-apps
export ENVIRONMENT=roadshow

# use login
export KUBECONFIG=~/.kube/config.${ENVIRONMENT}

login () {
    echo "💥 Login to OpenShift..." | tee -a output.log
    local i=0
    oc login -u admin -p ${ADMIN_PASSWORD} --server=https://api.sno.${BASE_DOMAIN}:6443 --insecure-skip-tls-verify=true
    until [ "$?" == 0 ]
    do
        echo -e "${GREEN}Waiting for 0 rc from oc commands.${NC}" 2>&1 | tee -a output.log
        ((i=i+1))
        if [ $i -gt 200 ]; then
            echo -e "🕱${RED}Failed - oc login never ready?.${NC}" 2>&1 | tee -a output.log
            exit 1
        fi
        sleep 10
        oc login -u admin -p ${ADMIN_PASSWORD} --server=https://api.sno.${BASE_DOMAIN}:6443 --insecure-skip-tls-verify=true
    done
    echo "💥 Login to OpenShift Done" | tee -a output.log
}
login

console_links() {
    echo "💥 Install console links" | tee -a output.log
    cat bootstrap/console-links-hub.yaml | envsubst | oc apply -f-
    until [ "${PIPESTATUS[2]}" == 0 ]
    do
        echo -e "${GREEN}Waiting for 0 rc from oc commands.${NC}" 2>&1 | tee -a output.log
        ((i=i+1))
        if [ $i -gt 50 ]; then
            echo -e "🕱${RED}Failed - console links never done ?.${NC}" 2>&1 | tee -a output.log
            exit 1
        fi
        sleep 10
        cat bootstrap/console-links-hub.yaml | envsubst | oc apply -f-
    done
    echo "💥 Install console links Done" | tee -a output.log
}

vault_secret() {
    echo "💥 Install vault secret" | tee -a output.log
    cat bootstrap/vault-secret.yaml | envsubst | oc apply -f-
    until [ "${PIPESTATUS[2]}" == 0 ]
    do
        echo -e "${GREEN}Waiting for 0 rc from oc commands.${NC}" 2>&1 | tee -a output.log
        ((i=i+1))
        if [ $i -gt 50 ]; then
            echo -e "🕱${RED}Failed - vault secret never done ?.${NC}" 2>&1 | tee -a output.log
            exit 1
        fi
        sleep 10
        cat bootstrap/vault-secret.yaml | envsubst | oc apply -f-
    done
    echo "💥 Install vault secret Done" | tee -a output.log
}

# install apps
echo "💥 Install apps" | tee -a output.log
./bootstrap/install.sh -e ${ENVIRONMENT} -d 2>&1 | tee -a output.log

# console links
console_links

# vault secret
vault_secret

# setup vault
echo "💥 Setup Vault" | tee -a output.log
./bootstrap/vault-setup.sh -d 2>&1 | tee -a output.log

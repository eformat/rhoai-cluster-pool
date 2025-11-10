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

wait_for_project() {
    local i=0
    local project="$1"
    STATUS=$(oc get project $project -o=go-template --template='{{ .status.phase }}')
    until [ "$STATUS" == "Active" ]
    do
        echo -e "${GREEN}Waiting for project $project.${NC}"
        sleep 5
        ((i=i+1))
        if [ $i -gt 300 ]; then
            echo -e "🚨${RED}Failed waiting for project $project never Succeeded?.${NC}"
            exit 1
        fi
        STATUS=$(oc get project $project -o=go-template --template='{{ .status.phase }}')
    done
    echo "🌴 wait_for_project $project ran OK"
}

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

init () {
    echo "💥 Init ESO..."
    local i=0
    oc apply -f external-secrets-community.yaml 2>&1 | tee /tmp/eso-init-${ENVIRONMENT}
    until [ "${PIPESTATUS[0]}" == 0 ]
    do
        echo -e "${GREEN}Waiting for 0 rc from oc commands.${NC}"
        ((i=i+1))
        if [ $i -gt 100 ]; then
            echo -e "🕱${RED}Failed - eso init never ready?.${NC}"
            exit 1
        fi
        sleep 10
        oc apply -f external-secrets-community.yaml 2>&1 | tee /tmp/eso-init-${ENVIRONMENT}
    done
    echo "💥 Init ESO Done"
}
init

wait_for_project external-secrets

apply_cr() {
    echo "💥 Apply ESO CR..."
    oc apply -f external-secrets-cr.yaml 2>&1 | tee /tmp/eso-cr-${ENVIRONMENT}
    until [ "${PIPESTATUS[0]}" == 0 ]
    do
        echo -e "${GREEN}Waiting for 0 rc from oc commands.${NC}"
        ((i=i+1))
        if [ $i -gt 10 ]; then
            echo -e "🕱${RED}Failed - eso cr never ready?.${NC}"
            exit 1
        fi
        sleep 10
        oc apply -f external-secrets-cr.yaml 2>&1 | tee /tmp/eso-cr-${ENVIRONMENT}
    done
}

if check_done; then
    echo -e "\n🌻${GREEN}ESO setup OK.${NC}🌻\n"
    exit 0;
else
    echo -e "💀${ORANGE}Warn - ESO setup not ready, continuing ${NC}"
    exit 1
fi

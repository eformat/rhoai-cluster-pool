#!/bin/bash
set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

header() { echo -e "\n${GREEN}=== $1 ===${NC}"; }
info()   { echo -e "${YELLOW}$1${NC}"; }
err()    { echo -e "${RED}$1${NC}"; }

header "Demo 1: Basic MultiKueue (no preemption)"

header "Cleaning up hub"
oc delete jobs --all -n default 2>/dev/null || true
oc delete workloads --all -n default 2>/dev/null || true
oc delete localqueue user-queue -n default 2>/dev/null || true
oc delete clusterqueue cluster-queue 2>/dev/null || true
oc delete admissioncheck multikueue-demo1 2>/dev/null || true
oc delete admissioncheck multikueue-config-demo1 2>/dev/null || true

header "Applying multikueue-setup-demo1.yaml"
oc apply -f "${SCRIPTDIR}/multikueue-setup-demo1.yaml"

header "Hub checks"
info "MultiKueueConfig:"
oc get multikueueconfig -o json | jq '.items[] | .metadata.name, .spec.clusters'

info "AdmissionChecks:"
oc get admissionchecks -o json | jq '.items[] | .metadata.name, .status.conditions'

info "ClusterQueues:"
oc get clusterqueues -o json | jq '.items[] | .metadata.name, .status.conditions'

header "Waiting for AdmissionChecks to be Active"
for i in $(seq 1 30); do
    ACTIVE=$(oc get admissionchecks -o json | jq '[.items[].status.conditions[]? | select(.type=="Active" and .status=="True")] | length')
    TOTAL=$(oc get admissionchecks -o json | jq '.items | length')
    if [ "$ACTIVE" -ge "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
        info "All $TOTAL AdmissionChecks are Active"
        break
    fi
    echo "  waiting... ($ACTIVE/$TOTAL active)"
    sleep 5
done

header "Submitting job-demo1.yaml"
oc create -f "${SCRIPTDIR}/job-demo1.yaml"

header "Monitoring workload (polling every 5s)"
for i in $(seq 1 24); do
    echo -e "\n--- $(date +%H:%M:%S) ---"
    oc get jobs,workloads -n default 2>/dev/null || true

    RESERVATION=$(oc get workloads -n default -o json 2>/dev/null | jq -r '.items[0].status.conditions[]? | select(.type=="Admitted") | .status // empty' || true)
    MK_EVENT=$(oc get events -n default --sort-by='.lastTimestamp' 2>/dev/null | grep -c "MultiKueue" || true)

    if [ "$MK_EVENT" -gt 0 ]; then
        info "MultiKueue dispatched workload to spoke"
        break
    fi
    sleep 5
done

header "Final state"
info "Hub:"
oc get jobs,workloads -n default

info "Hub events:"
oc get events -n default --sort-by='.lastTimestamp' | tail -10

echo -e "\n${GREEN}Demo 1 complete.${NC}"

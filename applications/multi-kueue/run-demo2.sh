#!/bin/bash
set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPOKE_CONFIGS=("${HOME}/.kube/config.prelude2" "${HOME}/.kube/config.prelude3")

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

header() { echo -e "\n${GREEN}=== $1 ===${NC}"; }
info()   { echo -e "${YELLOW}$1${NC}"; }
spoke()  { echo -e "${CYAN}[spoke: $(basename "$1" .kube)]${NC}"; }

header "Demo 2: MultiKueue with Preemption"

header "Cleaning up hub"
oc delete jobs --all -n default 2>/dev/null || true
oc delete workloads --all -n default 2>/dev/null || true
oc delete localqueue user-queue -n default 2>/dev/null || true
oc delete clusterqueue cluster-queue 2>/dev/null || true
oc delete admissioncheck multikueue-demo2 2>/dev/null || true
oc delete admissioncheck multikueue-config-demo2 2>/dev/null || true
oc delete cohort unreserved 2>/dev/null || true
oc delete workloadpriorityclass high-priority 2>/dev/null || true

header "Applying hub resources"
info "multikueue-hub-demo2.yaml (Cohort + WorkloadPriorityClass)"
oc replace --force -f "${SCRIPTDIR}/multikueue-hub-demo2.yaml"

info "multikueue-setup-demo2.yaml (CQ + LQ + AdmissionChecks)"
oc replace --force -f "${SCRIPTDIR}/multikueue-setup-demo2.yaml"

sleep 3
info "Verifying cohortName and admissionChecksStrategy..."
oc get clusterqueue cluster-queue -o json | jq '{cohort: .spec.cohortName, admissionChecks: .spec.admissionChecksStrategy}'

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

header "Pre-state: gpu-fake-gpu on spokes"
for cfg in "${SPOKE_CONFIGS[@]}"; do
    spoke "$cfg"
    KUBECONFIG="$cfg" oc get pods -n user-user1 2>/dev/null || echo "  (no pods)"
done

header "Submitting job-demo2.yaml"
oc create -f "${SCRIPTDIR}/job-demo2.yaml"

header "Monitoring hub workload (polling every 5s)"
for i in $(seq 1 24); do
    echo -e "\n--- $(date +%H:%M:%S) ---"
    oc get jobs,workloads -n default 2>/dev/null || true

    MK_EVENT=$(oc get events -n default --sort-by='.lastTimestamp' 2>/dev/null | grep -c "MultiKueue" || true)
    if [ "$MK_EVENT" -gt 0 ]; then
        info "MultiKueue dispatched workload to spoke"
        SPOKE_NAME=$(oc get events -n default --sort-by='.lastTimestamp' 2>/dev/null | grep "MultiKueue" | tail -1 | grep -o '"[^"]*"' | tail -1 | tr -d '"')
        info "  -> $SPOKE_NAME"
        break
    fi
    sleep 5
done

header "Hub events"
oc get events -n default --sort-by='.lastTimestamp' | tail -10

header "Waiting for spoke preemption (30s)"
sleep 30

header "Spoke state"
RUNNING_SPOKE=""
for cfg in "${SPOKE_CONFIGS[@]}"; do
    spoke "$cfg"
    info "Jobs/Pods/Workloads in default:"
    KUBECONFIG="$cfg" oc get jobs,pods,workloads -n default 2>/dev/null || echo "  (none)"

    if KUBECONFIG="$cfg" oc get pods -n default -o name 2>/dev/null | grep -q .; then
        RUNNING_SPOKE="$cfg"
    fi

    info "Pods in user-user1:"
    KUBECONFIG="$cfg" oc get pods -n user-user1 2>/dev/null || echo "  (none)"
done

header "Preemption events"
for cfg in "${SPOKE_CONFIGS[@]}"; do
    spoke "$cfg"
    PREEMPT_EVENTS=$(KUBECONFIG="$cfg" oc get events -n user-user1 --sort-by='.lastTimestamp' 2>/dev/null | grep -i "preempt\|evict" | tail -5)
    if [ -n "$PREEMPT_EVENTS" ]; then
        echo -e "${RED}$PREEMPT_EVENTS${NC}"
    else
        echo "  (no preemption events)"
    fi
done

if [ -n "$RUNNING_SPOKE" ]; then
    header "nvidia-smi on running job ($(basename "$RUNNING_SPOKE"))"
    POD_NAME=$(KUBECONFIG="$RUNNING_SPOKE" oc -n default get pod -o name 2>/dev/null | head -1)
    if [ -n "$POD_NAME" ]; then
        info "Waiting for pod to be Ready..."
        KUBECONFIG="$RUNNING_SPOKE" oc -n default wait --for=condition=Ready "$POD_NAME" --timeout=60s 2>/dev/null || true
        KUBECONFIG="$RUNNING_SPOKE" oc -n default exec "$POD_NAME" -- nvidia-smi 2>/dev/null || info "nvidia-smi not available in container"
    else
        info "No running pod found on spoke"
    fi
else
    info "No spoke found with running job"
fi

echo -e "\n${GREEN}Demo 2 complete. Preemption flow:${NC}"
echo "  1. gpu-fake-gpu was borrowing all 8 GPUs from Cohort (unreserved CQ, nominalQuota: 0)"
echo "  2. MultiKueue job submitted -> cluster-queue (nominalQuota: 0) tries to borrow from Cohort"
echo "  3. Cohort full (8/8) -> borrowWithinCohort: LowerPriority triggers preemption"
echo "  4. gpu-fake-gpu (priority 0 < threshold 100) EVICTED"
echo "  5. MultiKueue job borrows 1 GPU from Cohort and runs"

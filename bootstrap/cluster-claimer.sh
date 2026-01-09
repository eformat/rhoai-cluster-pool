#!/bin/bash
set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color

CLUSTER_NAME=${CLUSTER_NAME:-}
CLUSTER_POOL=${CLUSTER_POOL:-}

wait_clusterpool() {
  local i=0
  oc wait --for=condition=Provisioned clusterdeployments -l hive.openshift.io/clusterpool-name=${CLUSTER_POOL} -A --timeout=3s
  until [ "$?" == 0 ]
  do
    echo -e $(date +"%Y-%m-%d-%H-%M-%S") " Waiting for cluster pool $CLUSTER_POOL to be ready."
    ((i=i+1))
    if [ $i -gt 600 ]; then
      echo -e "🕱 Failed - cluster pool $CLUSTER_POOL never ready?."
      exit 1
    fi
    oc wait --for=condition=Provisioned clusterdeployments -l hive.openshift.io/clusterpool-name=${CLUSTER_POOL} -A --timeout=10s
  done
}

check_cluster_claim_exists() {
    echo "🌴 Running check_cluster_claim_exists..."
    EXISTS=$(oc get clusterclaim.hive.openshift.io ${CLUSTER_NAME} -n cluster-pools --no-headers=true | wc -l)
    if [ "$EXISTS" -gt 0 ]; then
      echo -e "💀${ORANGE}Cluster ${CLUSTER_NAME} claimed for ${CLUSTER_POOL} already exists?${NC}"
      exit 0
    fi
    echo "🌴 check_cluster_claim_exists ran OK"
}

claim_cluster() {
    echo "🌴 Running claim_cluster..."

    cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterClaim
metadata:
  name: "${CLUSTER_NAME}"
  namespace: cluster-pools
spec:
  clusterPoolName: "${CLUSTER_POOL}"
  subjects:
    - kind: Group
      apiGroup: rbac.authorization.k8s.io
      name: 'system:masters'
EOF
    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to claim cluster ${CLUSTER_NAME} from pool ${CLUSTER_POOL} ?${NC}"
      exit 1
    fi
    echo "🌴 claim_cluster ran OK"
}

scale_clusterpool() {
  echo "🌴 Running scale_clusterpool..."
  oc scale clusterpool ${CLUSTER_POOL} -n cluster-pools --replicas=0
    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to scale cluster pool ${CLUSTER_POOL} ?${NC}"
      exit 1
    fi
  echo "🌴 scale_clusterpool ran OK"
}

usage() {
  cat <<EOF 2>&1
usage: $0 [ -p <cluster_pool> ] [ -n <cluster_name> ]

Claim a cluster from the cluster pool
EOF
  exit 1
}

while getopts n:p: opts; do
  case $opts in
    n)
      CLUSTER_NAME=$OPTARG
      ;;
    p)
      CLUSTER_POOL=$OPTARG
      ;;
    *)
      usage
      ;;
  esac
done

shift `expr $OPTIND - 1`

# Check for EnvVars
[ -z "$CLUSTER_POOL" ] && echo "🕱 Error: must supply CLUSTER_POOL in env or cli" && exit 1
[ -z "$CLUSTER_NAME" ] && echo "🕱 Error: must supply CLUSTER_NAME in env or cli" && exit 1

check_cluster_claim_exists
wait_clusterpool
claim_cluster
scale_clusterpool

echo -e "\n🌻${GREEN}Cluster Claimer ended OK.${NC}🌻\n"
exit 0

# rhoai-cluster-pool

Uses Hive ClusterPool's from a HUB cluster to provision roadshow SPOKE clusters.

## Bootstrap Hub

HUB SNO install

```bash
export AWS_PROFILE=sno-test
export AWS_DEFAULT_REGION=us-east-2
export AWS_DEFAULT_ZONES=["us-east-2b"]
export CLUSTER_NAME=sno
export BASE_DOMAIN=sandbox.opentlc.com
export PULL_SECRET=$(cat ~/tmp/pull-secret-rhpds)
export SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
export INSTANCE_TYPE=m6i.8xlarge
export ROOT_VOLUME_SIZE=300
export OPENSHIFT_VERSION=4.19.11
export SKIP_SPOT=true

mkdir -p ~/tmp/sno-${AWS_PROFILE} && cd ~/tmp/sno-${AWS_PROFILE}
curl -Ls https://raw.githubusercontent.com/eformat/sno-for-100/main/sno-for-100.sh | bash -s -- -d
```

Installs ArgoCD and ACM

```bash
kustomize build --enable-helm bootstrap | oc apply -f-
```

Create CR's

```bash
oc apply -f bootstrap/setup-cr.yaml
```

We keep Auth, PKI, Storage separate for now as these are Infra specific.

Create htpasswd admin user

```bash
./bootstrap/users.sh
```

Install LE Certs

```bash
./bootstrap/certificates-hub.sh
```

Apps

```bash
oc apply -f app-of-apps/hub-app-of-apps.yaml
```

Setup Hive

- [HIVE_SETUP](HIVE_SETUP.md)

Console Links

```bash
export BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
cat bootstrap/console-links-hub.yaml | envsubst | oc apply -f-
```

Claim a spoke cluster

```bash
cat <<EOF | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterClaim
metadata:
  name: road1
  namespace: cluster-pools
spec:
  clusterPoolName: openshift-roadshow
  subjects:
    - kind: Group
      apiGroup: rbac.authorization.k8s.io
      name: 'system:masters'
EOF
```

Scale the ClusterPool

```bash
# now scale pool to zero - else we get another standby spinning up
oc scale clusterpool openshift-roadshow -n cluster-pools --replicas=0

# scale to one to get standby cluster
oc scale clusterpool openshift-roadshow -n cluster-pools --replicas=1
```

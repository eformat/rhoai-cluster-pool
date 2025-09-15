# rhoai-cluster-pool

## Bootstrap Hub

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


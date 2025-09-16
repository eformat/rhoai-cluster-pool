## Setup Hive

Create global pull secret

```bash
-- create pull secret
oc create secret generic global-pull-secret --from-file=.dockerconfigjson=$HOME/tmp/pull-secret-rhpds --type=kubernetes.io/dockerconfigjson --namespace hive
```

Patch HiveConfig

```bash
oc patch hiveconfig hive --type='json' -p='[{"op": "add", "path": "/spec/globalPullSecretRef", "value": {"name": "global-pull-secret"}}]'
```

Check/Create ClusterImageSet objects for every version of OCP you want to install

```bash
oc get ClusterImageSet img4.19.10-x86-64-appsub
```

Create a namespace to hold your ClusterPool objects:

```bash
oc create namespace cluster-pools
```

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
data:
  aws_access_key_id: $(echo -n ${AWS_ACCESS_KEY_ID} | base64)
  aws_secret_access_key: $(echo -n ${AWS_SECRET_ACCESS_KEY} | base64)
kind: Secret
metadata:
  name: aws-creds
  namespace: cluster-pools
type: Opaque
---
apiVersion: v1
kind: Secret
metadata:
  name: provisioning-host-ssh-private-key
  namespace: cluster-pools
stringData:
  ssh-privatekey: |-
    -----BEGIN RSA PRIVATE KEY-----
         YOUR_RSA_PRIVATE_KEY
    -----END RSA PRIVATE KEY-----
type: Opaque
EOF
```

Create an install-config template secret for our cluster deployments

```bash
oc -n cluster-pools delete secret my-install-config-template
oc -n cluster-pools create secret generic my-install-config-template --from-file=install-config.yaml=applications/hive/hivec-install-config-sno.yaml
```

Create ClusterPool(s)

- https://github.com/openshift/hive/blob/master/docs/clusterpools.md

```bash
cat <<EOF | oc apply -f-
apiVersion: hive.openshift.io/v1
kind: ClusterPool
metadata:
  name: openshift-roadshow
  namespace: cluster-pools
spec:
  baseDomain: sandbox.opentlc.com
  imageSetRef:
    name: img4.19.10-x86-64-appsub
  installConfigSecretTemplateRef: 
    name: my-install-config-template
  skipMachinePools: true
  runningCount: 1 # keep one cluster running rather than hibernate it
  platform:
    aws:
      credentialsSecretRef:
        name: aws-creds
      region: us-east-2
  size: 1
EOF
```

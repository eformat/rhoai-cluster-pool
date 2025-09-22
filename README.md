# rhoai-cluster-pool

Uses Hive ClusterPool's from a HUB cluster to provision [Roadshow](https://odh-labs.github.io/rhoai-roadshow-v2/#/) SPOKE clusters.

```mermaid
graph LR
    Hub[Hub Cluster] --> ClusterPool
    subgraph ClusterPool
        Spoke1[Spoke Cluster 1]
        Spoke2[Spoke Cluster 2]
        Spoke3[Spoke Cluster 3]
    end
```

SPOKE clusters auto-provision from the HUB. All you should need to do is scale the ClusterPool and wait for install + setup.

## Bootstrap a Hub Cluster

- [Ansible Installer](bootstrap/ansible/README.md) check here for environment needed to install

```bash
# set environment variables
cd bootstrap/ansible
ansible-playbook -i hosts rhoai-roadshow.yaml
```

Claim a spoke cluster (also a button in ACM UI > ClusterPools for this)

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

Scale the ClusterPool (also a selector in ACM UI > ClusterPools for this)

```bash
# now scale pool to zero - else we get another standby spinning up
oc scale clusterpool openshift-roadshow -n cluster-pools --replicas=0

# scale to one to get standby cluster
oc scale clusterpool openshift-roadshow -n cluster-pools --replicas=1
```

Setup Hive (manual steps for info only)

- [Hive Setup](HIVE_SETUP.md)

AWS Quota (needed for deploying spoke clusters)

- [AWS Quota](AWS_QUOTAS.md)

Troubleshooting

- [Troubleshooting Guide](TROUBLESHOOTING.md)

To destroy your HUB cluster:

```bash
cd /tmp/ansible.xxx
openshift-install destroy cluster --dir=cluster
```

Keep a copy of your `/tmp/ansible.xxx` folder for future OpenShift cluster uninstalls e.g.

```bash
mv /tmp/ansible.xxx ~/sno-roadshow
```

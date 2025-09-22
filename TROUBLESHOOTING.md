# troubleshooting

## HUB

Single node Vault is initialized using a Job in the vault namespace `vault-init`. Vault unseal and root token are stored in secrets in the `vault` namespace.

If any of the two configuration ansible roles fail - they are re-runnable - check the [bootstrap/ansible/README.md](bootstrap/ansible/README.md) for details

## SPOKE

All SPOKE clusters are installed using GitOps / ArgoCD / Policy as Code from the HUB Cluster.

You can check the Hive Controller as first point of call for any invalid SPOKE config (i.e. not spoke clusters spin up once you scale the ClusterPool)

```bash
stern -n hive hive-controllers
```

During a SPOKE install, each cluster has its own namespace with an installer (or uninstaller pod) which can be checked for errors / progress:

```bash
stern -n openshift-roadshow-2qrj5 openshift-roadshow-
```

A successful SPOKE install should look like this:

```bash
NAME                                               READY   STATUS      RESTARTS   AGE
openshift-roadshow-2qrj5-0-hhvp8-provision-zwntq   0/1     Completed   0          47m
```

The SPOKE cluster joins the HUB (is managed) once you `Claim` it from the ACM UI or via a `ClusterClaim` YAML object.

Once Claimed, Configuration Policy is pulled and applied on each SPOKE.

There are several jobs that should run to Completion on each SPOKE Cluster - they all run in the `openshift-config` namespace. Check these FIRST for any complete failures (they are configured with large `backOffLimit`s and are expected to be eventually complete and become consistent).

```bash
$ oc get jobs -n openshift-config

NAME            STATUS     COMPLETIONS   DURATION   AGE
cert-init       Running    0/1           13m        13m
check-install   Running    0/1           13m        13m
console-links   Complete   1/1           8m16s      13m
efs-storage     Complete   1/1           8m16s      13m
rhoai-scale     Complete   1/1           10m        13m
```

Then check GitOps / ArgoCD / Policy as Code from the HUB Cluster for any obvious errors.

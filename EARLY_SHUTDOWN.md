# early shutdown

- https://www.redhat.com/en/blog/enabling-openshift-4-clusters-to-stop-and-resume-cluster-vms

OpenShift 4 needs some extra steps if you intend to shutdown the cluster prior to the 24hr cert rotation (post install). 

Login to the cluster

```bash
oc login -u admin -p ${ADMIN_PASSWORD} --server=https://api.${BASE_DOMAIN}:6443
```

You will need to reboot all cluster nodes when running the script (use aws console), it will prompt you.

Run the script.

```bash
./bootstrap/prepare-early-shutdown-spoke.sh
```

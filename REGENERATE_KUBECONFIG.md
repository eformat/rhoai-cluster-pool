# regenerate spoke kubeconfig for acm

When switching to other certificates (Lets Encrypt) it may be necessary to reload the kubeconfig into the ACM Hub secret for a SPOKE cluster.

with a shell logged in using `oc`

spoke - generate a newkubeconfig

```bash
rm -f /dev/shm/newkubeconfig
cd /tmp/foo
~/git/rhoai-cluster-pool/bootstrap/regenerate-kubeconfig.sh
cp /dev/shm/newkubeconfig .
```

hub - load newkubeconfig into acm sercret for that cluster

```bash
cd /tmp/foo
cluster_name=openshift-roadshow-wptjl # spoke cluster name
kubeconfig_secret_name=$(oc -n ${cluster_name} get clusterdeployments ${cluster_name} -ojsonpath='{.spec.clusterMetadata.adminKubeconfigSecretRef.name}')
oc -n ${cluster_name} set data secret/${kubeconfig_secret_name} --from-file=kubeconfig=newkubeconfig --from-file=raw-kubeconfig=newkubeconfig
```

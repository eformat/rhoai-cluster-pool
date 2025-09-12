# rhoai-cluster-pool

## Bootstrap

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
./bootstrap/certificates.sh
```

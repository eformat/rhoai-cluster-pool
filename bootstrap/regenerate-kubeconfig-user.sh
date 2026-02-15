#!/bin/bash

AUTH_NAME="auth2kube"
USER=admin

rm -f $AUTH_NAME-*

tmp_file="/dev/shm/newkubeconfig"

echo "create a certificate request for system:admin user"
openssl req -new -newkey rsa:4096 -nodes -keyout $AUTH_NAME.key -out $AUTH_NAME.csr -subj "/CN=$USER"

echo "create signing request resource definition"

oc delete csr $AUTH_NAME-access # Delete old csr with the same name

cat << EOF >> $AUTH_NAME-csr.yaml
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $AUTH_NAME-access
spec:
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000 # one year
  groups:
  - system:authenticated
  request: $(cat $AUTH_NAME.csr | base64 | tr -d '\n')
  usages:
  - client auth
EOF
oc create -f $AUTH_NAME-csr.yaml

echo "approve csr and extract client cert"
oc get csr
oc adm certificate approve $AUTH_NAME-access
oc get csr $AUTH_NAME-access -o jsonpath='{.status.certificate}' | base64 -d > $AUTH_NAME-access.crt

echo "add $USER credentials, context to the kubeconfig"
oc config set-credentials $USER --client-certificate=$AUTH_NAME-access.crt \
--client-key=$AUTH_NAME.key --embed-certs --kubeconfig=${tmp_file}

echo "create context for the $USER"
oc config set-context $USER --cluster=$(oc config view -o jsonpath='{.clusters[0].name}') \
--namespace=default --user=$USER --kubeconfig=${tmp_file}

echo "extract certificate authority"
BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')
echo "Q" | openssl s_client -showcerts -connect api.${BASE_DOMAIN}:6443 2>&1 | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/ {print $0}' > api-ca.crt

echo "set certificate authority data"
oc config set-cluster $(oc config view -o jsonpath='{.clusters[0].name}') \
--server=$(oc config view -o jsonpath='{.clusters[0].cluster.server}') --certificate-authority=api-ca.crt --kubeconfig=${tmp_file} --embed-certs

echo "set current context to $USER"
oc config use-context $USER --kubeconfig=${tmp_file}

echo "test client certificate authentication with $USER"
export KUBECONFIG=${tmp_file}
oc login -u $USER

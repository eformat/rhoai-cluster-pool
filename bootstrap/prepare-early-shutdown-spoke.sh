#!/bin/bash

#set -x

# Run this on spoke SNO clusters
# See: https://github.com/crc-org/snc/pull/1084/files
#      https://www.redhat.com/en/blog/enabling-openshift-4-clusters-to-stop-and-resume-cluster-vms

readonly RUN_DIR=$(pwd)
export OC=${OC:-oc}
export BASE_DOMAIN=$(oc get dns cluster -o jsonpath='{.spec.baseDomain}')

function retry {
    # total wait time = 2 ^ (retries - 1) - 1 seconds
    local retries=14

    local count=0
    until "$@"; do
        exit=$?
        wait=$((2 ** $count))
        count=$(($count + 1))
        if [ $count -lt $retries ]; then
            echo "Retry $count/$retries exited $exit, retrying in $wait seconds..." 1>&2
            sleep $wait
        else
            echo "Retry $count/$retries exited $exit, no more retries left." 1>&2
            return $exit
        fi
    done
    return 0
}

# This follows https://blog.openshift.com/enabling-openshift-4-clusters-to-stop-and-resume-cluster-vms/
# in order to trigger regeneration of the initial 24h certs the installer created on the cluster
function renew_certificates() {
    # reboot spoke cluster
    local answer="n"
    read -rp "Have you have Rebooted the cluster? [y/n] " answer
    if [[ "${answer}" == "n" ]];
    then
      echo "Skipping renew certificates - needs cluster reboot!"
      return 1
    fi
    # Loop until the signer certs are valid for a month
    i=0
    while [ $i -lt 60 ]; do
        ${OC} get secret/csr-signer -n openshift-kube-controller-manager-operator -o template='{{index .data "tls.crt"}}' | base64 -d | openssl x509 -checkend 2160000 -noout 2>&1>/dev/null
        RET1=$?
        ${OC} get secret/csr-signer-signer -n openshift-kube-controller-manager-operator -o template='{{index .data "tls.crt"}}' | base64 -d | openssl x509 -checkend 2160000 -noout 2>&1>/dev/null
        RET2=$?
        if [ "$RET1" -ne 0 ] || [ "$RET2" -ne 0 ]; then
            retry ${OC} get csr -ojson > /tmp/certs.json
            retry ${OC} adm certificate approve -f /tmp/certs.json
            rm -f /tmp/certs.json
            echo "Retry loop $i, wait for 10sec before starting next loop"
            sleep 10
        else
            break
        fi
        i=$[$i+1]
    done
}


#retry ${OC} apply -f kubelet-bootstrap-cred-manager-ds.yaml # permissions issues
retry ${OC} delete secrets/csr-signer-signer secrets/csr-signer -n openshift-kube-controller-manager-operator
retry ${OC} adm wait-for-stable-cluster --minimum-stable-period=2m0s
renew_certificates
echo "🌴 Certificates will not expire. Done."

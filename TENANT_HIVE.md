## Use a different aws account for tenant cluster pools

(WIP) Per-tenant cluster pools with their own accounts.

- Each tenant has their own AWS Creds (so they are separate billing entities)
- Each tenant gets a ClusterPool per roadshow
- A roadshow is RHOAI + apps (for example)

Environment

```bash
export AWS_ACCESS_KEY_ID=
export AWS_SECRET_ACCESS_KEY=
export GUID=q8jzk
export ROADSHOW=roadshow
export BASE_DOMAIN=
export PULL_SECRET=$(cat ~/tmp/pull-secret-rhpds)
export INSTANCE_TYPE=g6.8xlarge
export ROOT_VOLUME_SIZE=400
export AWS_DEFAULT_REGION=us-east-2
export USER_EMAIL=
export USER_TEAM=
export USER_USAGE="Dev"
export USER_USAGE_DESCRIPTION="Product Development and Demo environment for OpenShift"
export SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
```

Configure

```bash
configure_hive_tenants_roadshow() {
    echo "🌴 Running configure_hive_tenants_roadshow..."

    helm template hive-tenants applications/hive-tenants/charts/hive-tenants/ \
    --namespace=hive \
    --set baseDomain="${BASE_DOMAIN}" \
    --set-json globalPullSecret="${PULL_SECRET}" \
    --set installConfig="$(cat applications/hive-tenants/${ROADSHOW}-install-config.yaml | envsubst)" \
    --set guid="${GUID}" \
    --set aws_access_key_id="${AWS_ACCESS_KEY_ID}" \
    --set aws_secret_access_key="${AWS_SECRET_ACCESS_KEY}" \
    --set sshKey="${SSH_PUBLIC_KEY}" | oc apply -f-

    if [ "${PIPESTATUS[1]}" != 0 ]; then
        echo -e "🚨${RED}Failed - to configure_hive_tenants_roadshow ?${NC}"
        exit 1
    fi

    echo "🌴 configure_hive_tenants_roadshow ran OK"
}
```

```bash
configure_hive_tenants_roadshow
```

Then scale the per-tenant cluster pool, set cluster size limits, auto decommission etc etc.

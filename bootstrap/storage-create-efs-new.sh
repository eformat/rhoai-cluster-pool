#!/bin/bash
set -o pipefail
#set -x

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

echo "🌴 Create EFS storage..."

# script works for sno or for all instances
IS_SNO=${IS_SNO:-}

if [ -z "$AWS_PROFILE" ] && [ -z "$AWS_DEFAULT_REGION" ]; then
    export AWS_DEFAULT_REGION=$(oc -n openshift-machine-api get $(oc get machines.machine.openshift.io -o name -A) -o json | jq -r '.spec.providerSpec.value.placement.region')
    if [ -z "$AWS_DEFAULT_REGION" ]; then
        echo -e "🚨${RED}Failed - to find AWS_DEFAULT_REGION ? ${NC}"
        exit 1
    fi
fi

# Check for EnvVars
[ ! -z "$AWS_PROFILE" ] && echo "🌴 Using AWS_PROFILE: $AWS_PROFILE"
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_ACCESS_KEY_ID" ] && echo "🕱 Error: AWS_ACCESS_KEY_ID not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_SECRET_ACCESS_KEY" ] && echo "🕱 Error: AWS_SECRET_ACCESS_KEY not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_DEFAULT_REGION" ] && echo "🕱 Error: AWS_DEFAULT_REGION not set in env" && exit

# create efs per vpc
create_efs() {
    local instanceId="$1"
    EFSID=
    TAGS_SPEC=

    echo "🌴 create_efs - Processing: $instanceId"

    # Build tag specs robustly via JSON to preserve spaces and special chars
    TAGS+=Key=Name,Value=ocp-efs-${instanceId}
    TAGS+=" "
    tags_json=$(aws ec2 describe-tags \
        --filters "Name=resource-id,Values=${instanceId}" \
        --query 'Tags[?Key!=`Name` && Key!=`description` && Key!=`owner`]' \
        --output json)
    if [ "$(echo "$tags_json" | jq 'length')" != "0" ]; then
        while IFS= read -r kv; do
            # For EFS create-file-system CLI tags (space-delimited list of Key=,Value= items)
            TAGS+="$kv "
        done < <(echo "$tags_json" | jq -r '.[] | "Key=\(.Key),Value=\(.Value)"')

        # For tag-specifications (JSON-like list inside brackets)
        TAGS_SPEC=$(echo "$tags_json" | jq -r '[.[] | {Key:.Key,Value:.Value}] | map("{Key=\(.Key),Value=\(.Value)}") | join(",")')
    else
        echo -e "💀${ORANGE} No tags found for instance ${instanceId} ? ${NC}";
        TAGS_SPEC=
    fi

    if [ $(aws efs describe-file-systems --query "FileSystems[].FileSystemId" --output text | wc -l) -eq 0 ]; then
        echo "🌴 No EFS file systems found - Creating."

        fsid=$(aws efs create-file-system --region=${AWS_DEFAULT_REGION} --performance-mode=generalPurpose --encrypted --tags ${TAGS%?} | jq --raw-output '.FileSystemId')
        if [ -z "$fsid" ]; then
            echo -e "🚨${RED}Failed - to create efs filesystem ocp-efs ? ${NC}"
            exit 1
        fi
        export EFSID=${fsid}

        vpcid=$(aws ec2 describe-instances --instance-ids ${instanceId} --query 'Reservations[0].Instances[0].VpcId' --output text)
        if [ -z "$vpcid" ]; then
            echo -e "🚨${RED}Failed - to find vpcid for ${instanceId} ? ${NC}"
            exit 1
        fi

        # EFS created; mount targets will be created after determining VPC below

    else
        # we have to iterate over them
        echo "🌴 Found EFS file system - checking."
        found=
        for fsid in $(aws efs describe-file-systems --query 'FileSystems[*].FileSystemId' --output text); do
            if [ $(aws efs describe-tags --file-system-id $fsid | grep ocp-efs | wc -l) -gt 0 ]; then
                echo "Filesystem $fsid ocp-efs exists, skipping ..."
                found="true"
                export EFSID=${fsid}
            fi
        done
        if [ -z ${found} ]; then
            echo "🌴 No EFS file systems found - Creating."
            fsid=$(aws efs create-file-system --region=${AWS_DEFAULT_REGION} --performance-mode=generalPurpose --encrypted --tags ${TAGS%?} | jq --raw-output '.FileSystemId')
            if [ -z "$fsid" ]; then
                echo -e "🚨${RED}Failed - to create efs filesystem ocp-efs ? ${NC}"
                exit 1
            fi
            export EFSID=${fsid}

            vpcid=$(aws ec2 describe-instances --instance-ids ${instanceId} --query 'Reservations[0].Instances[0].VpcId' --output text)
            if [ -z "$vpcid" ]; then
                echo -e "🚨${RED}Failed - to find vpcid for ${instanceId} ? ${NC}"
                exit 1
            fi

            # EFS created; mount targets will be created after determining VPC below
        fi
    fi
    # Ensure mount targets are created even when EFS already exists
    vpcid=$(aws ec2 describe-instances --instance-ids ${instanceId} --query 'Reservations[0].Instances[0].VpcId' --output text)
    if [ -z "$vpcid" ]; then
        echo -e "🚨${RED}Failed - to find vpcid for ${instanceId} ? ${NC}"
        exit 1
    fi
    create_mount_target ${vpcid} ${EFSID} ${TAGS_SPEC}
}

create_mount_target() {
    local vpcid="$1"
    local efsid="$2"
    local tagsspec="$3"

    echo "🌴 create_mount_target - Processing: $vpcid $efsid $tagsspec"

    vpcname=$(aws ec2 describe-vpcs --vpc-ids ${vpcid} --query "Vpcs[].Tags[?Key=='Name'].Value" --output text)
    if [ -z "$vpcname" ]; then
        echo -e "🚨${RED}Failed - failed to find vpcname for vpcid: ${vpcid} region: ${AWS_DEFAULT_REGION} ? ${NC}"
        exit 1
    fi

    cidr_block=$(aws ec2 describe-vpcs --region=${AWS_DEFAULT_REGION} --vpc-ids ${vpcid} --query "Vpcs[].CidrBlock" --output text)
    if [ -z "$cidr_block" ]; then
        echo -e "🚨${RED}Failed - failed to find CIDR for vpcid: ${vpcid} region: ${AWS_DEFAULT_REGION} ? ${NC}"
        exit 1
    fi

    mount_target_group_name="ec2-efs-group"
    mount_target_group_desc="NFS access to EFS from EC2 worker nodes"

    # Try to find existing SG first (idempotent)
    mount_target_group_id=$(aws ec2 describe-security-groups \
        --region=${AWS_DEFAULT_REGION} \
        --filters "Name=vpc-id,Values=${vpcid}" "Name=group-name,Values=${mount_target_group_name}" \
        --query 'SecurityGroups[0].GroupId' --output text)
    if [ "$mount_target_group_id" = "None" ] || [ -z "$mount_target_group_id" ]; then
        # Create SG; include tags only if provided
        if [ -n "$tagsspec" ]; then
            mount_target_group_id=$(aws ec2 create-security-group \
                --region=${AWS_DEFAULT_REGION} \
                --group-name $mount_target_group_name \
                --description "${mount_target_group_desc}" \
                --tag-specifications "ResourceType=security-group,Tags=[${tagsspec}]" \
                --vpc-id ${vpcid} | jq --raw-output '.GroupId')
        else
            mount_target_group_id=$(aws ec2 create-security-group \
                --region=${AWS_DEFAULT_REGION} \
                --group-name $mount_target_group_name \
                --description "${mount_target_group_desc}" \
                --vpc-id ${vpcid} | jq --raw-output '.GroupId')
        fi
    fi
    if [ "$mount_target_group_id" = "None" ] || [ -z "$mount_target_group_id" ]; then
        echo -e "🚨${RED}Failed - failed to get or create SG for mount target group: ${mount_target_group_name} in region: ${AWS_DEFAULT_REGION} ? ${NC}"
        exit 1
    fi

    # Add NFS ingress if missing (idempotent)
    has_ingress=$(aws ec2 describe-security-groups \
        --region=${AWS_DEFAULT_REGION} \
        --group-ids ${mount_target_group_id} \
        --query "SecurityGroups[0].IpPermissions[?FromPort==\`2049\` && ToPort==\`2049\` && IpProtocol=='tcp' && contains(IpRanges[].CidrIp, '${cidr_block}')].FromPort" \
        --output text)
    if [ -z "$has_ingress" ] || [ "$has_ingress" = "None" ]; then
        aws ec2 authorize-security-group-ingress --region=${AWS_DEFAULT_REGION} --group-id ${mount_target_group_id} --protocol tcp --port 2049 --cidr ${cidr_block}
        if [ "$?" != 0 ]; then
            echo -e "🚨${RED}Failed - to authorize security group ingress for group-id: ${mount_target_group_id} in region: ${AWS_DEFAULT_REGION}?${NC}"
            exit 1
        fi
    fi

    # Discover public subnets via route tables with a route to an Internet Gateway (IGW)
    # Primary method: any route table in the VPC with a 0.0.0.0/0 route to an IGW
    igw_rtb_ids=$(aws ec2 describe-route-tables --region=${AWS_DEFAULT_REGION} \
        --filters "Name=vpc-id,Values=${vpcid}" \
        --output json | jq -r '.RouteTables[] | select([.Routes[]? | select(.DestinationCidrBlock=="0.0.0.0/0" and ((.GatewayId // "") | startswith("igw-")))] | length > 0) | .RouteTableId' | xargs)
    subnets=$(aws ec2 describe-route-tables --region=${AWS_DEFAULT_REGION} \
        --route-table-ids ${igw_rtb_ids} \
        --query "RouteTables[].Associations[?SubnetId!=''].SubnetId" \
        --output text)

    # Fallback: use map-public-ip-on-launch=true if IGW route association did not return subnets
    if [ -z "$subnets" ] || [ "$subnets" = "None" ]; then
        subnets=$(aws ec2 describe-subnets --region=${AWS_DEFAULT_REGION} \
            --filters "Name=vpc-id,Values=${vpcid}" "Name=map-public-ip-on-launch,Values=true" \
            --query 'Subnets[].SubnetId' --output text)
    fi

    # Fetch subnet AZs for idempotent behavior (one mount target per AZ)
    subnet_info_json=$(aws ec2 describe-subnets --region=${AWS_DEFAULT_REGION} --subnet-ids ${subnets} --output json)

    while IFS= read -r line; do
        subnet=$(echo "$line" | awk '{print $1}')
        az_name=$(echo "$line" | awk '{print $2}')
        az_id=$(echo "$line" | awk '{print $3}')

        # Check live if a mount target already exists in this AZ for this filesystem (use AZ ID for reliability)
        mtid=$(aws efs describe-mount-targets --region=${AWS_DEFAULT_REGION} --file-system-id ${efsid} --output json | jq -r --arg azid "$az_id" '.MountTargets[]? | select(.AvailabilityZoneId==$azid) | .MountTargetId' | head -n1)
        if [ -n "$mtid" ] && [ "$mtid" != "null" ]; then
            echo "mount target already exists in AZ ${az_name}/${az_id} (mtid: ${mtid}), ensuring security groups include ${mount_target_group_id}"
            current_sgs=$(aws efs describe-mount-target-security-groups --region=${AWS_DEFAULT_REGION} --mount-target-id ${mtid} --query 'SecurityGroups[]' --output text)
            # Normalize empty/None
            if [ -z "$current_sgs" ] || [ "$current_sgs" = "None" ]; then
                combined_sgs=${mount_target_group_id}
            else
                # Add our SG if missing
                echo "$current_sgs ${mount_target_group_id}" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' > /tmp/sgs.$$ 
                combined_sgs=$(cat /tmp/sgs.$$)
                rm -f /tmp/sgs.$$ 2>/dev/null
            fi
            if ! echo " $current_sgs " | grep -q " ${mount_target_group_id} "; then
                aws efs modify-mount-target-security-groups --region=${AWS_DEFAULT_REGION} --mount-target-id ${mtid} --security-groups ${combined_sgs}
                if [ "$?" != 0 ]; then
                    echo -e "💀${ORANGE} Failed to update security groups for existing mount target ${mtid} in AZ ${az_name}/${az_id} ? ${NC}"
                fi
            fi
            continue
        fi

        echo "creating mount target in  ${subnet}"
        aws efs create-mount-target --region=${AWS_DEFAULT_REGION} --file-system-id ${efsid} --subnet-id ${subnet} --security-groups ${mount_target_group_id}
        if [ "$?" != 0 ]; then
            echo -e "💀${ORANGE} Failed to create mount target for fsid: ${efsid} and subnet: ${subnet} with sg: ${mount_target_group_id} in region: ${AWS_DEFAULT_REGION} ? ${NC}";
        fi
    done < <(echo "$subnet_info_json" | jq -r '.Subnets[] | "\(.SubnetId) \(.AvailabilityZoneName) \(.AvailabilityZoneId)"')
    if [ -z "$subnets" ] || [ "$subnets" = "None" ]; then
        echo -e "💀${ORANGE} Could not find public subnets for vpc ${vpcid}, mount targets not created. ${NC}";
    fi
}

configure_sc() {
    if [ -z $IS_SNO ]; then
       echo "🌴 IS_SNO not true, skipping configure_sc..."
       return
    fi

    oc get sc/efs-sc
    if [ "$?" == 0 ]; then
        echo "🌴 Found EFS storage class OK - Done."
        exit 0
    fi

    echo "🌴 Running configure_sc..."

cat << EOF > /tmp/storage-class-efs.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap 
  fileSystemId: $EFSID
  directoryPerms: "700" 
  gidRangeStart: "1000" 
  gidRangeEnd: "2000" 
  basePath: "/dynamic_provisioning" 
EOF

    oc apply -f /tmp/storage-class-efs.yaml -n openshift-config
    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to create storage class, configure_sc ?${NC}"
      exit 1
    fi
    rm -f /tmp/storage-class-efs.yaml 2>&1>/dev/null
    echo "🌴 configure_sc ran OK"
}

#INSTANCE_IDS="i-0918dbc2ded812c71 i-026d95aabd938b0e8 i-050bc231acad5c14e i-061b88c8f28eefd43 i-09343fee6c2f00b59 i-074cdbbcf4391fb1d i-01c46f7071991cb5d i-02eebde13b504b9d3 i-0adade914d0a6aaa3"
INSTANCE_IDS=

# # get single sno
# if [ ! -z $IS_SNO ]; then
#     export INSTANCE_IDS=$(oc -n openshift-machine-api get $(oc get machines.machine.openshift.io -o name -A) -o json | jq -r '.status.providerStatus.instanceId')
# else
#     # get all instances
#     export INSTANCE_IDS=$(aws ec2 describe-instances \
#         --query "Reservations[].Instances[].InstanceId" \
#         --filters "Name=tag-value,Values=*-master-0" \
#         --output text)
# fi

# check if EFS exists for each SNO instance else create
for cluster in ${INSTANCE_IDS}; do
    create_efs $cluster
    configure_sc
done

echo "🌴 Create EFS storage Done."
exit 0

#!/bin/bash
set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

echo "🌴 Create EFS storage..."

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

    IFS=$'\n' read -d '' -r -a lines < <(aws ec2 describe-tags --filters "Name=resource-id,Values=${instanceId}" --output text)
    TAGS+=Key=Name,Value=ocp-efs-${instanceId}
    TAGS+=" "
    if [ ! -z "$lines" ]; then
        set -o pipefail
        for line in "${lines[@]}"; do
            read -r type key resourceid resourcetype value <<< "$line"
            # troublesome, quoting, adding tags for deletion
            if [ "$key" != "Name" ] && [ "$key" != "description" ] && [ "$key" != "owner" ] ; then
                TAGS+=Key=$key,Value=$value
                TAGS+=" "
                TAGS_SPEC+={Key="$key",Value="$value"},
            fi
        done
    else 
        echo -e "💀${ORANGE} No tags found for instance ${instanceId} ? ${NC}";
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

        create_mount_target ${vpcid} ${EFSID} ${TAGS_SPEC}

    else
        # we have to iterate over them
        echo "🌴 Found EFS file system - checking."
        found=
        for fs_id in $(aws efs describe-file-systems --query 'FileSystems[*].FileSystemId' --output text); do
            if [ $(aws efs describe-tags --file-system-id $fs_id | grep ${instanceId} | wc -l) -gt 0 ]; then
                echo "Filesystem $fs_id exists for $instanceId, skipping ..."
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

            create_mount_target ${vpcid} ${EFSID} ${TAGS_SPEC}
        fi
    fi
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
    mount_target_group_id=$(aws ec2 create-security-group --region=${AWS_DEFAULT_REGION} --group-name $mount_target_group_name --description "${mount_target_group_desc}" --tag-specifications "ResourceType=security-group,Tags=[${tagsspec%?}]" --vpc-id ${vpcid} | jq --raw-output '.GroupId')
    if [ -z "$mount_target_group_id" ]; then
        echo -e "🚨${RED}Failed - failed to create SG for mount target group: ${mount_target_group_name} in region: ${AWS_DEFAULT_REGION} ? ${NC}"
        exit 1
    fi

    aws ec2 authorize-security-group-ingress --region=${AWS_DEFAULT_REGION} --group-id ${mount_target_group_id} --protocol tcp --port 2049 --cidr ${cidr_block} | jq .
    if [ "${PIPESTATUS[0]}" != 0 ]; then
        echo -e "🚨${RED}Failed - to authorize security group ingress for group-id: ${mount_target_group_id} in region: ${AWS_DEFAULT_REGION}?${NC}"
        exit 1
    fi

    # us-east-2, ap-southeast-2
    TAG1=${vpcname%%-vpc}-subnet-public-${AWS_DEFAULT_REGION}a
    TAG2=${vpcname%%-vpc}-subnet-public-${AWS_DEFAULT_REGION}b
    TAG3=${vpcname%%-vpc}-subnet-public-${AWS_DEFAULT_REGION}c
    subnets=$(aws ec2 describe-subnets --region=${AWS_DEFAULT_REGION} --filters "Name=tag:Name,Values=$TAG1,$TAG2,$TAG3" | jq --raw-output '.Subnets[].SubnetId')
    for subnet in ${subnets};
    do
    echo "creating mount target in " $subnet
    aws efs create-mount-target --region=${AWS_DEFAULT_REGION} --file-system-id ${efsid} --subnet-id ${subnet} --security-groups ${mount_target_group_id}
    if [ "$?" != 0 ]; then
        echo -e "💀${ORANGE} Failed to create mount target for fsid: ${efsid} and subnet: ${subnet} with sg: ${mount_target_group_id} in region: ${AWS_DEFAULT_REGION} ? ${NC}";
    fi
    done
    if [ -z "$subnets" ]; then
        echo -e "💀${ORANGE} Could not find subnets for vpc ${vpcname}, mount targets not created - check TAG names $TAG1,$TAG2,$TAG3 ? ${NC}";
    fi
}

# get all instances
export INSTANCE_IDS=$(aws ec2 describe-instances \
    --query "Reservations[].Instances[].InstanceId" \
    --filters "Name=tag-value,Values=*-master-0" \
    --output text)

# check if EFS exists for each SNO instance else create
for cluster in ${INSTANCE_IDS}; do
    create_efs $cluster
done

echo "🌴 Create EFS storage Done."
exit 0

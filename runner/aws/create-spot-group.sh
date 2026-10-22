#!/bin/bash
# Creates a scale-to-zero Spot Auto Scaling Group of ForgeCI runners.
# See DEPLOY.md, "Scale runners to zero".
#
#   AWS_PROFILE=kilat AWS_REGION=ap-southeast-3 \
#   CONTROL_PLANE_URL=https://ci.example.com RUNNER_TOKEN=<from Settings → Runners> \
#     bash runner/aws/create-spot-group.sh
#
# Optional: RESOURCE_CLASS (spot), GROUP (forge-ci-<class>), MAX_SIZE (8),
# INSTANCE_TYPES ("c6i.xlarge m6i.xlarge c5.xlarge m5.xlarge"), DISK_GB (40),
# IDLE_SHUTDOWN_AFTER (600), ON_DEMAND=1 for on-demand instead of Spot,
# VPC_ID (default VPC) and SUBNETS (comma-separated; default: the VPC's
# subnets that give instances a public IP).
#
# Creates, or reuses when they already exist: the SSM parameter holding the
# runner token, the forge-ci-runner IAM role and instance profile, a
# forge-ci-runner security group with no inbound rules, the launch template
# and the group. Re-running updates the token and adds a launch template version.
set -euo pipefail

: "${AWS_REGION:?set AWS_REGION, e.g. ap-southeast-3}"
: "${CONTROL_PLANE_URL:?set CONTROL_PLANE_URL, e.g. https://ci.example.com}"
: "${RUNNER_TOKEN:?set RUNNER_TOKEN to the token in Settings → Runners}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""
CLASS="${RESOURCE_CLASS:-spot}"
GROUP="${GROUP:-forge-ci-$CLASS}"
MAX_SIZE="${MAX_SIZE:-8}"
INSTANCE_TYPES="${INSTANCE_TYPES:-c6i.xlarge m6i.xlarge c5.xlarge m5.xlarge}"
DISK_GB="${DISK_GB:-40}"
IDLE="${IDLE_SHUTDOWN_AFTER:-600}"
PARAM="/forge-ci/runner-token"
ROLE="forge-ci-runner"
here="$(cd "$(dirname "$0")" && pwd)"
say() { echo "forge-ci: $*"; }

account=$(aws sts get-caller-identity --query Account --output text)
say "account $account, region $AWS_REGION, group $GROUP (class $CLASS)"

aws ssm put-parameter --name "$PARAM" --type SecureString --value "$RUNNER_TOKEN" --overwrite >/dev/null
say "stored the runner token in SSM $PARAM"

if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]}' >/dev/null
  say "created IAM role $ROLE"
fi
aws iam put-role-policy --role-name "$ROLE" --policy-name forge-ci-runner --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": \"ssm:GetParameter\",
     \"Resource\": \"arn:aws:ssm:$AWS_REGION:$account:parameter$PARAM\"},
    {\"Effect\": \"Allow\", \"Action\": \"autoscaling:TerminateInstanceInAutoScalingGroup\", \"Resource\": \"*\",
     \"Condition\": {\"StringEquals\": {\"autoscaling:ResourceTag/forge-ci\": \"runner\"}}}]}"
if ! aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-instance-profile --instance-profile-name "$ROLE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
  say "created instance profile $ROLE; waiting for IAM to propagate"
  sleep "${IAM_WAIT:-15}"
fi

VPC_ID="${VPC_ID:-$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)}"
[ "$VPC_ID" != "None" ] || { echo "forge-ci: no default VPC; set VPC_ID and SUBNETS" >&2; exit 1; }
SUBNETS="${SUBNETS:-$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=map-public-ip-on-launch,Values=true \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')}"
[ -n "$SUBNETS" ] || { echo "forge-ci: no public subnets in $VPC_ID; set SUBNETS (they need internet access)" >&2; exit 1; }

sg=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values=forge-ci-runner \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ "$sg" = "None" ]; then
  sg=$(aws ec2 create-security-group --vpc-id "$VPC_ID" --group-name forge-ci-runner \
    --description "ForgeCI runners: outbound only" --query GroupId --output text)
  say "created security group $sg (no inbound rules)"
fi

user_data=$(sed -e "s|^CONTROL_PLANE_URL=.*|CONTROL_PLANE_URL=\"$CONTROL_PLANE_URL\"|" \
                -e "s|^RESOURCE_CLASS=.*|RESOURCE_CLASS=\"$CLASS\"|" \
                -e "s|^RUNNER_TOKEN_PARAMETER=.*|RUNNER_TOKEN_PARAMETER=\"$PARAM\"|" \
                -e "s|^IDLE_SHUTDOWN_AFTER=.*|IDLE_SHUTDOWN_AFTER=$IDLE|" "$here/user-data.sh" | base64 | tr -d '\n')
template="{
  \"ImageId\": \"resolve:ssm:/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id\",
  \"IamInstanceProfile\": {\"Name\": \"$ROLE\"},
  \"SecurityGroupIds\": [\"$sg\"],
  \"BlockDeviceMappings\": [{\"DeviceName\": \"/dev/sda1\", \"Ebs\": {\"VolumeSize\": $DISK_GB, \"VolumeType\": \"gp3\"}}],
  \"MetadataOptions\": {\"HttpTokens\": \"required\"},
  \"TagSpecifications\": [{\"ResourceType\": \"instance\", \"Tags\": [{\"Key\": \"Name\", \"Value\": \"$GROUP\"}]}],
  \"UserData\": \"$user_data\"
}"
if aws ec2 describe-launch-templates --launch-template-names "$GROUP" >/dev/null 2>&1; then
  aws ec2 create-launch-template-version --launch-template-name "$GROUP" --launch-template-data "$template" >/dev/null
  say "added a new version to launch template $GROUP"
else
  aws ec2 create-launch-template --launch-template-name "$GROUP" --launch-template-data "$template" >/dev/null
  say "created launch template $GROUP"
fi

overrides=$(for t in $INSTANCE_TYPES; do printf '{"InstanceType":"%s"},' "$t"; done | sed 's/,$//')
on_demand=$([ "${ON_DEMAND:-0}" = "1" ] && echo 100 || echo 0)
policy="{
  \"LaunchTemplate\": {
    \"LaunchTemplateSpecification\": {\"LaunchTemplateName\": \"$GROUP\", \"Version\": \"\$Latest\"},
    \"Overrides\": [$overrides]},
  \"InstancesDistribution\": {\"OnDemandPercentageAboveBaseCapacity\": $on_demand, \"SpotAllocationStrategy\": \"price-capacity-optimized\"}}"
if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$GROUP" \
     --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text | grep -qx "$GROUP"; then
  aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$GROUP" --min-size 0 --max-size "$MAX_SIZE" \
    --vpc-zone-identifier "$SUBNETS" --mixed-instances-policy "$policy"
  say "updated Auto Scaling Group $GROUP"
else
  aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$GROUP" \
    --min-size 0 --max-size "$MAX_SIZE" --desired-capacity 0 --vpc-zone-identifier "$SUBNETS" \
    --tags Key=forge-ci,Value=runner,PropagateAtLaunch=true --mixed-instances-policy "$policy"
  say "created Auto Scaling Group $GROUP (0 instances until jobs queue)"
fi
# Moving instances between zones would kill running jobs.
aws autoscaling suspend-processes --auto-scaling-group-name "$GROUP" --scaling-processes AZRebalance

cat <<DONE

forge-ci: done. Now give the control plane, then restart it:
  FORGE_CI_AUTOSCALE=$CLASS=$GROUP:$MAX_SIZE
  FORGE_CI_AUTOSCALE_REGION=$AWS_REGION
and AWS credentials allowing autoscaling:DescribeAutoScalingGroups and
autoscaling:SetDesiredCapacity (see DEPLOY.md, "Scale runners to zero").
Try it without a push: aws autoscaling set-desired-capacity --auto-scaling-group-name $GROUP --desired-capacity 1
DONE

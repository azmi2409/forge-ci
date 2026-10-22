#!/bin/bash
# EC2 launch-template user data for a scale-to-zero ForgeCI runner (Ubuntu,
# Debian or Amazon Linux). See DEPLOY.md, "Scale runners to zero".
#
# Edit the four settings below. The runner token is read from SSM Parameter
# Store at boot, so it never sits in the launch template.
set -euo pipefail

CONTROL_PLANE_URL="https://ci.example.com"
RESOURCE_CLASS="spot"                       # this group's class, e.g. spot or deploy
RUNNER_TOKEN_PARAMETER="/forge-ci/runner-token"
IDLE_SHUTDOWN_AFTER=600                     # seconds without a job before the instance removes itself

if ! command -v aws >/dev/null; then
  if command -v apt-get >/dev/null; then
    apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl unzip
  fi
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip
  unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install
fi

imds="http://169.254.169.254/latest"
imds_token=$(curl -fsS -X PUT "$imds/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
region=$(curl -fsS -H "X-aws-ec2-metadata-token: $imds_token" "$imds/meta-data/placement/region")
runner_token=$(aws ssm get-parameter --region "$region" --name "$RUNNER_TOKEN_PARAMETER" \
  --with-decryption --query Parameter.Value --output text)

# The same installer as the command on the Runners page.
curl -fsSL "$CONTROL_PLANE_URL/install-runner" | sh -s -- \
  --token "$runner_token" --class "$RESOURCE_CLASS" --idle-shutdown "$IDLE_SHUTDOWN_AFTER" --asg

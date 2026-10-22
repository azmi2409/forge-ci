#!/bin/bash
# EC2 launch-template user data for a scale-to-zero forge-ci runner
# (Ubuntu 22.04/24.04, x86_64 or arm64). See DEPLOY.md, "Scale runners to zero".
#
# Edit the four settings below. The runner token is read from SSM Parameter
# Store at boot, so it never sits in the launch template.
set -euo pipefail

CONTROL_PLANE_URL="https://ci.example.com"
RESOURCE_CLASS="spot"                       # this group's class, e.g. spot or deploy
RUNNER_TOKEN_PARAMETER="/forge-ci/runner-token"
IDLE_SHUTDOWN_AFTER=600                     # seconds without a job before the instance removes itself

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q docker.io ruby git curl unzip
systemctl enable --now docker

if ! command -v aws >/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip
  unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install
fi

imds="http://169.254.169.254/latest"
token=$(curl -fsS -X PUT "$imds/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
region=$(curl -fsS -H "X-aws-ec2-metadata-token: $token" "$imds/meta-data/placement/region")
runner_token=$(aws ssm get-parameter --region "$region" --name "$RUNNER_TOKEN_PARAMETER" \
  --with-decryption --query Parameter.Value --output text)

rm -rf /opt/forge-ci-runner /tmp/forge-ci
git clone --depth 1 https://github.com/azmi2409/forge-ci.git /tmp/forge-ci
cp -r /tmp/forge-ci/runner /opt/forge-ci-runner

install -m 600 /dev/null /etc/forge-ci-runner.env
cat > /etc/forge-ci-runner.env <<ENV
CONTROL_PLANE_URL=$CONTROL_PLANE_URL
RUNNER_TOKEN=$runner_token
RESOURCE_CLASS=$RESOURCE_CLASS
IDLE_SHUTDOWN_AFTER=$IDLE_SHUTDOWN_AFTER
IDLE_SHUTDOWN_COMMAND=/opt/forge-ci-runner/bin/forge-ci-asg-terminate-self
ENV

cat > /etc/systemd/system/forge-ci-runner.service <<'UNIT'
[Unit]
Description=forge-ci Docker runner
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
EnvironmentFile=/etc/forge-ci-runner.env
WorkingDirectory=/opt/forge-ci-runner
ExecStart=/usr/bin/ruby /opt/forge-ci-runner/bin/forge-ci-runner
# on-failure, not always: an idle shutdown exits 0 and must stay stopped.
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now forge-ci-runner

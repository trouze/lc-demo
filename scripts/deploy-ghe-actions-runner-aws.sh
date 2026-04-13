#!/usr/bin/env bash
#
# GitHub Enterprise Server (GHES): register a self-hosted Actions runner on AWS EC2.
# Use this alongside dbt Cloud–centric workflows: the runner only orchestrates API calls;
# dbt still executes inside dbt Cloud.
#
# Prerequisites (run from your laptop or a bastion):
#   - AWS CLI configured (aws sts get-caller-identity)
#   - GitHub CLI authenticated to your GHES hostname:
#       gh auth login --hostname YOUR_GHE_HOST
#     with a token that can create runner registration tokens (repo admin or org owner).
#
# Prior art for Actions + dbt Cloud API:
#   https://gist.github.com/trouze/26e578d92cd803514f29f6a33d5fd2cd
#
# GHES runner download URL pattern (replace version with the one shown in the UI):
#   https://YOUR_GHE_HOST/download/actions-runner-linux-x64-2.311.0.tar.gz
#
# Usage examples:
#   export GH_HOST="github.mycompany.com"
#   export RUNNER_VERSION="2.311.0"
#   export AWS_REGION="us-east-1"
#   export INSTANCE_TYPE="t3.large"
#   export SUBNET_ID="subnet-xxxxxxxx"
#   export SECURITY_GROUP_IDS="sg-xxxxxxxx"
#   # Repo-scoped runner:
#   export RUNNER_SCOPE="repo"
#   export GITHUB_OWNER="my-org"
#   export GITHUB_REPO="data-monorepo"
#   export RUNNER_LABELS="self-hosted,linux,x64,dbt"
#   ./scripts/deploy-ghe-actions-runner-aws.sh launch
#
#   # Org-scoped runner (shared across repos):
#   export RUNNER_SCOPE="org"
#   export GITHUB_ORG="my-org"
#   ./scripts/deploy-ghe-actions-runner-aws.sh launch
#
# Security note: passing the registration token through EC2 user data is convenient for demos
# but visible in the API/console. For production, prefer SSM Parameter Store, Secrets Manager,
# or a manual SSH bootstrap.
#
# dbt Cloud (HTTPS): before launch, the script can add egress rules (TCP 443) to each SG in
# SECURITY_GROUP_IDS so a locked-down default-deny egress policy still reaches dbt Cloud.
#   Default IPs are baked in; override with space- or comma-separated DBT_CLOUD_HTTPS_IPS.
#   Disable: ENSURE_DBT_CLOUD_EGRESS=0
#   Re-check dbt’s published allowlist periodically — IPs can change.
#
set -euo pipefail

usage() {
  sed -n '1,80p' "$0" | sed -n '/^#/p' | sed 's/^# \{0,1\}//'
  echo ""
  echo "Commands:"
  echo "  token     Print a registration token JSON from GHES (gh api)."
  echo "  userdata  Print a cloud-init template (TOKEN placeholder) for review."
  echo "  launch    Ensure dbt Cloud egress on SECURITY_GROUP_IDS, then start EC2 (demo only)."
  echo ""
  echo "Launch env (optional):"
  echo "  ENSURE_DBT_CLOUD_EGRESS=0     Skip adding TCP/443 egress to dbt Cloud IPs on your SGs."
  echo "  DBT_CLOUD_HTTPS_IPS='a b'     Override default dbt Cloud IPs (space- or comma-separated)."
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required command: $1" >&2
    exit 1
  }
}

: "${GH_HOST:?Set GH_HOST to your GitHub Enterprise Server hostname (no https://)}"
: "${RUNNER_VERSION:?Set RUNNER_VERSION to the runner version shown in GHES UI}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${INSTANCE_TYPE:?Set INSTANCE_TYPE (e.g. t3.large)}"
: "${SUBNET_ID:?Set SUBNET_ID}"
: "${SECURITY_GROUP_IDS:?Set SECURITY_GROUP_IDS (comma-separated, e.g. sg-abc,sg-def)}"
: "${RUNNER_LABELS:=self-hosted,linux,x64,dbt}"

RUNNER_SCOPE="${RUNNER_SCOPE:-repo}"
RUNNER_DOWNLOAD_URL="${RUNNER_DOWNLOAD_URL:-https://${GH_HOST}/download/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz}"

# dbt Cloud — static HTTPS egress targets (customer-supplied; override via DBT_CLOUD_HTTPS_IPS).
DEFAULT_DBT_CLOUD_HTTPS_IPS=(
  "52.45.144.63"
  "54.81.134.249"
  "52.22.161.231"
  "52.3.77.232"
  "3.214.191.130"
  "34.233.79.135"
)

ensure_dbt_cloud_egress() {
  require aws
  local sg ip out rc
  local -a sgs ips

  IFS=',' read -r -a sgs <<< "${SECURITY_GROUP_IDS// /}"
  if [[ -n "${DBT_CLOUD_HTTPS_IPS:-}" ]]; then
    read -r -a ips <<< "${DBT_CLOUD_HTTPS_IPS//,/ }"
  else
    ips=("${DEFAULT_DBT_CLOUD_HTTPS_IPS[@]}")
  fi

  echo "Ensuring TCP/443 egress to dbt Cloud IP allowlist on: ${SECURITY_GROUP_IDS}"
  for sg in "${sgs[@]}"; do
    sg="${sg// /}"
    [[ -n "${sg}" ]] || continue
    for ip in "${ips[@]}"; do
      ip="${ip// /}"
      [[ -n "${ip}" ]] || continue
      set +e
      out=$(
        aws ec2 authorize-security-group-egress \
          --region "${AWS_REGION}" \
          --group-id "${sg}" \
          --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"${ip}/32\",\"Description\":\"dbt Cloud HTTPS\"}]}]" 2>&1
      )
      rc=$?
      set -e
      if [[ ${rc} -eq 0 ]]; then
        echo "  added: ${sg} -> ${ip}/32 tcp/443"
      elif echo "${out}" | grep -qiE 'InvalidPermission\.Duplicate|already exists'; then
        echo "  already present: ${sg} -> ${ip}/32 tcp/443"
      else
        echo "  warning: could not add ${sg} -> ${ip}/32 tcp/443 — ${out}" >&2
      fi
    done
  done
}

should_ensure_dbt_cloud_egress() {
  case "${ENSURE_DBT_CLOUD_EGRESS:-1}" in
    0 | false | FALSE | no | NO | off | OFF) return 1 ;;
    *) return 0 ;;
  esac
}

registration_token_json() {
  require gh
  export GH_HOST
  if [[ "${RUNNER_SCOPE}" == "org" ]]; then
    : "${GITHUB_ORG:?Set GITHUB_ORG for org-scoped runner}"
    gh api --method POST "/orgs/${GITHUB_ORG}/actions/runners/registration-token"
  else
    : "${GITHUB_OWNER:?Set GITHUB_OWNER}"
    : "${GITHUB_REPO:?Set GITHUB_REPO}"
    gh api --method POST "/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"
  fi
}

runner_config_url() {
  if [[ "${RUNNER_SCOPE}" == "org" ]]; then
    echo "https://${GH_HOST}/${GITHUB_ORG}"
  else
    echo "https://${GH_HOST}/${GITHUB_OWNER}/${GITHUB_REPO}"
  fi
}

emit_userdata() {
  local token="$1"
  local url
  url="$(runner_config_url)"
  cat <<EOF
#!/bin/bash
set -exo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

dnf install -y libicu tar gzip git

RUNNER_USER="ghrunner"
if ! id "\$RUNNER_USER" &>/dev/null; then
  useradd -m -s /bin/bash "\$RUNNER_USER"
fi

INSTALL_DIR="/opt/actions-runner"
mkdir -p "\$INSTALL_DIR"
chown "\$RUNNER_USER":"\$RUNNER_USER" "\$INSTALL_DIR"

sudo -u "\$RUNNER_USER" /bin/bash <<INNER
cd /opt/actions-runner
curl -fL -o actions-runner.tar.gz '${RUNNER_DOWNLOAD_URL}'
tar zxf actions-runner.tar.gz
./config.sh --url '${url}' --token '${token}' --labels '${RUNNER_LABELS}' --unattended --replace
./svc.sh install
./svc.sh start
INNER
EOF
}

cmd_token() {
  registration_token_json
}

cmd_userdata() {
  echo "Replace __REGISTRATION_TOKEN__ below with output from: $0 token"
  emit_userdata "__REGISTRATION_TOKEN__"
}

cmd_launch() {
  require aws
  if should_ensure_dbt_cloud_egress; then
    ensure_dbt_cloud_egress
    echo ""
  fi
  TOKEN_JSON="$(registration_token_json)"
  TOKEN="$(echo "${TOKEN_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')"

  AMI_ID="${AMI_ID:-$(aws ssm get-parameters --region "${AWS_REGION}" \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameters[0].Value' --output text)}"

  : "${AMI_ID:?Could not resolve Amazon Linux 2023 AMI; set AMI_ID explicitly}"

  KEY_NAME="${KEY_NAME:-}"
  USER_DATA_FILE="$(mktemp)"
  trap 'rm -f "${USER_DATA_FILE}"' EXIT

  emit_userdata "${TOKEN}" >"${USER_DATA_FILE}"

  ARGS=(
    ec2 run-instances
    --region "${AWS_REGION}"
    --image-id "${AMI_ID}"
    --instance-type "${INSTANCE_TYPE}"
    --subnet-id "${SUBNET_ID}"
    --security-group-ids ${SECURITY_GROUP_IDS//,/ }
    --user-data "file://${USER_DATA_FILE}"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=ghes-actions-runner},{Key=gh_host,Value=${GH_HOST}}]"
  )
  if [[ -n "${KEY_NAME}" ]]; then
    ARGS+=(--key-name "${KEY_NAME}")
  fi

  echo "Launching EC2 with dnf-based user-data (Amazon Linux 2023)..."
  aws "${ARGS[@]}"

  echo ""
  echo "Next steps:"
  echo "  1. Wait for the instance to finish user-data (cloud-init). Check /var/log/user-data.log on the box."
  echo "  2. In GHES: confirm the runner appears online (Settings → Actions → Runners)."
  echo "  3. Update workflow runs-on: to match labels: [self-hosted, linux, x64, dbt] (adjust to your RUNNER_LABELS)."
  echo "  4. Ensure outbound HTTPS to ${GH_HOST} (this script added dbt Cloud TCP/443 egress to your SGs unless ENSURE_DBT_CLOUD_EGRESS=0)."
}

main() {
  case "${1:-}" in
    token) cmd_token ;;
    userdata) cmd_userdata ;;
    launch) cmd_launch ;;
    -h|--help|help) usage ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"

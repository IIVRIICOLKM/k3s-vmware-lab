#!/usr/bin/env bash
# Verifies that the repository contains every file required by the documented workflow.
# This is intentionally read-only and also checks script syntax and executable permissions.
# Usage: scripts/verify-project.sh
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,4s/^# \{0,1\}//p' "$0"
  exit 0
fi
(($# == 0)) || die "scripts/verify-project.sh takes no arguments (see --help)"

required=(
  .gitignore
  README.md
  docs/vmware-iac-handoff.md
  docs/vmware-workstation-iac-workflow-2560x1440.png
  docs/vmware-workstation-iac-workflow.dot
  infra/ansible/ansible.cfg
  infra/ansible/inventories/lab/group_vars/all.yml
  infra/ansible/inventories/lab/group_vars/app_nodes.yml
  infra/ansible/inventories/lab/group_vars/gpu_nodes.yml
  infra/ansible/inventories/lab/group_vars/platform_nodes.yml
  infra/ansible/inventories/lab/hosts.yml
  infra/ansible/playbooks/bootstrap.yml
  infra/ansible/playbooks/gpu-host.yml
  infra/ansible/playbooks/k3s.yml
  infra/ansible/playbooks/ping.yml
  infra/ansible/playbooks/site.yml
  infra/ansible/requirements.txt
  infra/ansible/roles/common/handlers/main.yml
  infra/ansible/roles/common/tasks/main.yml
  infra/ansible/roles/k3s_agent/tasks/main.yml
  infra/ansible/roles/k3s_node/defaults/main.yml
  infra/ansible/roles/k3s_node/handlers/main.yml
  infra/ansible/roles/k3s_node/tasks/main.yml
  infra/ansible/roles/k3s_node/templates/k3s.service.j2
  infra/ansible/roles/k3s_server/tasks/main.yml
  infra/packer/http/kickstart.pkrtpl.cfg
  infra/packer/plugins.sha256
  infra/packer/scripts/finalize.sh
  infra/packer/templates/rocky-golden.pkr.hcl
  infra/packer/templates/variables.pkr.hcl
  infra/terraform/.terraform.lock.hcl
  infra/terraform/main.tf
  infra/terraform/outputs.tf
  infra/terraform/provider.tf
  infra/terraform/terraform.example.tfvars
  infra/terraform/variables.tf
  infra/terraform/versions.tf
  scripts/cluster-apply.sh
  scripts/entry.sh
  scripts/fetch-rocky-iso.sh
  scripts/golden-build.sh
  scripts/lib/common.sh
  scripts/lib/pinned-versions.env
  scripts/preflight.sh
  scripts/provider-smoke-test.sh
  scripts/register-vms.sh
  scripts/render-inventory.sh
  scripts/tf.sh
  scripts/verify-project.sh
  scripts/vmrest-start.sh
)

missing=()
empty=()
for path in "${required[@]}"; do
  [[ -e "$REPO_ROOT/$path" ]] || missing+=("$path")
  [[ ! -e "$REPO_ROOT/$path" || -s "$REPO_ROOT/$path" ]] || empty+=("$path")
done

((${#missing[@]} == 0)) || die "required project files missing: ${missing[*]}"
((${#empty[@]} == 0)) || die "required project files are empty: ${empty[*]}"

while IFS= read -r script; do
  bash -n "$script" || die "invalid Bash syntax: ${script#"$REPO_ROOT/"}"
done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/infra/packer/scripts" -type f -name '*.sh' -print | sort)

while IFS= read -r script; do
  [[ -x "$script" ]] || die "script is not executable: ${script#"$REPO_ROOT/"}"
done < <(find "$REPO_ROOT/scripts" -maxdepth 1 -type f -name '*.sh' -print; find "$REPO_ROOT/infra/packer/scripts" -type f -name '*.sh' -print)

if [[ -d "$REPO_ROOT/.git" ]]; then
  deleted=$(git -C "$REPO_ROOT" ls-files --deleted)
  [[ -z "$deleted" ]] || die "Git-tracked files are missing: $(tr '\n' ' ' <<<"$deleted")"
fi

log "project files ready: ${#required[@]} required files present, scripts executable, Bash syntax valid"

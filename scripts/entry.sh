#!/usr/bin/env bash
# Provisions the whole lab by calling the stage scripts in order:
#   vmrest-start -> fetch-rocky-iso -> preflight -> golden-build -> tf init -> cluster-apply -> render-inventory
#   -> ansible ping.yml -> ansible site.yml
# Every stage is re-runnable, so the same command builds the lab the first time and brings it back later
# (for example after a host reboot). If a stage fails, fix the cause and run it again.
# Usage: scripts/entry.sh
set -Eeuo pipefail
source "$(dirname "$0")/lib/common.sh"

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,7s/^# \{0,1\}//p' "$0"
  exit 0
fi
(($# == 0)) || die "scripts/entry.sh takes no arguments (see --help)"

# Terraform clones the image named by golden_vm_name in infra/terraform/variables.tf, so build exactly that version.
GOLDEN_PREFIX="k3slab-golden-rocky98"
golden_name=$(sed -n '/^variable "golden_vm_name"/,/^}/s/^ *default *= *"\(.*\)"$/\1/p' "$REPO_ROOT/infra/terraform/variables.tf")
[[ "$golden_name" == "$GOLDEN_PREFIX"-* ]] || die "golden_vm_name default in infra/terraform/variables.tf must start with $GOLDEN_PREFIX-"
GOLDEN_VERSION="${golden_name#"$GOLDEN_PREFIX"-}"

VENV="$LAB_DATA_DIR/ansible-venv"
[[ -f "$VENV/bin/activate" ]] || die "missing $VENV (see README: 사전 준비)"

STEPS=9
step=0
declare -a timing_steps=()
declare -a timing_names=()
declare -a timing_seconds=()

duration() {
  local total="$1"
  if ((total >= 60)); then
    printf '%dm %02ds' "$((total / 60))" "$((total % 60))"
  else
    printf '%ds' "$total"
  fi
}

run() {
  local name="$1"
  shift
  local started=$SECONDS
  step=$((step + 1))
  log "[$step/$STEPS] $name: $*"
  "$@"
  local elapsed=$((SECONDS - started))
  timing_steps+=("$step")
  timing_names+=("$name")
  timing_seconds+=("$elapsed")
  log "[$step/$STEPS] $name completed in $(duration "$elapsed")"
}

skip() {
  local name="$1"
  local reason="$2"
  step=$((step + 1))
  timing_steps+=("$step")
  timing_names+=("$name")
  timing_seconds+=("0")
  log "[$step/$STEPS] $name skipped: $reason"
}

print_timing_table() {
  printf '\n%-6s %-24s %s\n' "Step" "Task" "Elapsed"
  printf '%-6s %-24s %s\n' "----" "------------------------" "-------"
  local i total=0
  for i in "${!timing_steps[@]}"; do
    printf '%-6s %-24s %s\n' "${timing_steps[$i]}/$STEPS" "${timing_names[$i]}" "$(duration "${timing_seconds[$i]}")"
    total=$((total + timing_seconds[i]))
  done
  printf '%-6s %-24s %s\n' "Total" "all steps" "$(duration "$total")"
  printf '\n'
}
trap 'log "FAILED at step $step/$STEPS: $BASH_COMMAND"; log "fix the cause and re-run scripts/entry.sh; completed stages are skipped or make no changes"' ERR

cd "$REPO_ROOT"
run "vmrest 시작" scripts/vmrest-start.sh
run "Rocky ISO 확인" scripts/fetch-rocky-iso.sh
run "사전 점검" scripts/preflight.sh

if [[ -d "$LAB_IMAGE_DIR/$golden_name" ]]; then
  skip "기준 이미지" "$golden_name already exists (images are immutable)"
else
  run "기준 이미지" scripts/golden-build.sh "$GOLDEN_VERSION"
fi

run "Terraform 준비" scripts/tf.sh init
run "VM 상태 맞춤" scripts/cluster-apply.sh -auto-approve
run "IP 목록 생성" scripts/render-inventory.sh

# shellcheck disable=SC1091
source "$VENV/bin/activate"
cd infra/ansible
run "SSH 확인" ansible-playbook playbooks/ping.yml
run "OS + K3s" ansible-playbook playbooks/site.yml

nodes=$("$REPO_ROOT/scripts/tf.sh" output -json nodes)
print_timing_table
log "provisioning complete: golden image $golden_name, nodes $(jq -r 'keys | join(", ")' <<<"$nodes")"

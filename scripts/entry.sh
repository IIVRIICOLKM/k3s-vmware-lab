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
run() {
  step=$((step + 1))
  log "[$step/$STEPS] $*"
  "$@"
}
trap 'log "FAILED at step $step/$STEPS: $BASH_COMMAND"; log "fix the cause and re-run scripts/entry.sh; completed stages are skipped or make no changes"' ERR

cd "$REPO_ROOT"
run scripts/vmrest-start.sh
run scripts/fetch-rocky-iso.sh
run scripts/preflight.sh

if [[ -d "$LAB_IMAGE_DIR/$golden_name" ]]; then
  step=$((step + 1))
  log "[$step/$STEPS] golden image $golden_name already built; skipping (images are immutable)"
else
  run scripts/golden-build.sh "$GOLDEN_VERSION"
fi

run scripts/tf.sh init
run scripts/cluster-apply.sh -auto-approve
run scripts/render-inventory.sh

# shellcheck disable=SC1091
source "$VENV/bin/activate"
cd infra/ansible
run ansible-playbook playbooks/ping.yml
run ansible-playbook playbooks/site.yml

nodes=$("$REPO_ROOT/scripts/tf.sh" output -json nodes)
log "provisioning complete: golden image $golden_name, nodes $(jq -r 'keys | join(", ")' <<<"$nodes")"

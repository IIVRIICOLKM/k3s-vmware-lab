#!/usr/bin/env bash
# Verifies that the repository contains every file required by the documented workflow.
# This is intentionally read-only and also checks script syntax and executable permissions.
# Usage: scripts/verify-project.sh
#
# [한국어 설명] 저장소 파일 점검 (읽기 전용). preflight.sh가 맨 처음에 자동으로 호출한다.
#   ① 아래 required 목록의 파일이 모두 있고 비어 있지 않은지
#   ② scripts/ 와 infra/packer/scripts/ 의 모든 .sh 파일 Bash 문법 (bash -n)
#   ③ 실행용 스크립트에 실행 권한(+x)이 있는지 (scripts/lib/는 source 전용이라 제외)
#   ④ Git이 추적하는 파일 중 작업 폴더에서 지워진 것이 없는지
#   필수 파일을 새로 추가하면 required 목록에도 넣어야 한다.

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 도움말(-h, --help)과 인자 검사 ---
# 도움말 = 이 파일 2~4번째 줄(영문 설명). 한국어 설명 블록은 그 범위 밖이라 영향 없음.
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,4s/^# \{0,1\}//p' "$0"
  exit 0
fi
(($# == 0)) || die "scripts/verify-project.sh takes no arguments (see --help)"

# --- 2) 필수 파일 목록 (저장소 최상위 기준 상대 경로) ---
required=(
  .gitignore
  README.md
  apps/infer/Dockerfile
  apps/infer/main.cpp
  apps/train/Dockerfile
  apps/train/train.py
  charts/k3slab-workload/Chart.yaml
  charts/k3slab-workload/templates/_helpers.tpl
  charts/k3slab-workload/templates/infer-deployment.yaml
  charts/k3slab-workload/templates/train-job.yaml
  charts/k3slab-workload/values-infer.yaml
  charts/k3slab-workload/values-train.yaml
  charts/k3slab-workload/values.yaml
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
  infra/ansible/roles/gpu_host_prep/defaults/main.yml
  infra/ansible/roles/gpu_host_prep/handlers/main.yml
  infra/ansible/roles/gpu_host_prep/tasks/main.yml
  infra/ansible/roles/k3s_agent/tasks/main.yml
  infra/ansible/roles/k3s_node/defaults/main.yml
  infra/ansible/roles/k3s_node/handlers/main.yml
  infra/ansible/roles/k3s_node/tasks/main.yml
  infra/ansible/roles/k3s_node/templates/k3s.service.j2
  infra/ansible/roles/k3s_server/tasks/main.yml
  infra/k8s/gpu-smoke-job.yaml
  infra/k8s/labs/00-namespace.yaml
  infra/k8s/labs/10-gpu-placement.yaml
  infra/k8s/labs/20-echo-api.yaml
  infra/k8s/labs/21-load-client.yaml
  infra/k8s/labs/30-restart-demo.yaml
  infra/k8s/nvidia-device-plugin.yaml
  infra/k8s/registry.yaml
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
  scripts/infer-bench.sh
  scripts/image-build.sh
  scripts/k3s-lab.sh
  scripts/lib/common.sh
  scripts/lib/pinned-versions.env
  scripts/preflight.sh
  scripts/provider-smoke-test.sh
  scripts/register-vms.sh
  scripts/render-inventory.sh
  scripts/tf.sh
  scripts/train-resume-test.sh
  scripts/verify-project.sh
  scripts/vmware-modules.sh
  scripts/vmrest-start.sh
)

# --- 3) 존재 여부·빈 파일 검사 ---
# [[ ! -e 파일 || -s 파일 ]] : 파일이 없거나(이 경우는 missing에서 처리), 있으면 크기가 0보다 커야 통과
missing=()
empty=()
for path in "${required[@]}"; do
  [[ -e "$REPO_ROOT/$path" ]] || missing+=("$path")
  [[ ! -e "$REPO_ROOT/$path" || -s "$REPO_ROOT/$path" ]] || empty+=("$path")
done

((${#missing[@]} == 0)) || die "required project files missing: ${missing[*]}"
((${#empty[@]} == 0)) || die "required project files are empty: ${empty[*]}"

# --- 4) Bash 문법 검사: bash -n = 실행하지 않고 문법만 확인 ---
# ${script#"$REPO_ROOT/"} : 출력할 때 앞의 저장소 경로를 떼어 상대 경로로 보여줌
while IFS= read -r script; do
  bash -n "$script" || die "invalid Bash syntax: ${script#"$REPO_ROOT/"}"
done < <(find "$REPO_ROOT/scripts" "$REPO_ROOT/infra/packer/scripts" -type f -name '*.sh' -print | sort)

# --- 5) 실행 권한 검사: scripts/ 바로 아래 파일(-maxdepth 1 → lib/ 제외)과 infra/packer/scripts/ ---
while IFS= read -r script; do
  [[ -x "$script" ]] || die "script is not executable: ${script#"$REPO_ROOT/"}"
done < <(find "$REPO_ROOT/scripts" -maxdepth 1 -type f -name '*.sh' -print; find "$REPO_ROOT/infra/packer/scripts" -type f -name '*.sh' -print)

# --- 6) Git이 추적하는데 작업 폴더에서 사라진 파일이 있는지 (git ls-files --deleted) ---
if [[ -d "$REPO_ROOT/.git" ]]; then
  deleted=$(git -C "$REPO_ROOT" ls-files --deleted)
  [[ -z "$deleted" ]] || die "Git-tracked files are missing: $(tr '\n' ' ' <<<"$deleted")"
fi

log "project files ready: ${#required[@]} required files present, scripts executable, Bash syntax valid"

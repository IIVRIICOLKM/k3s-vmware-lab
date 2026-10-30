#!/usr/bin/env bash
# Renders the Ansible inventory of the Terraform-managed VMs into infra/ansible/inventories/lab/.generated/.
# Terraform supplies names, vmrest ids and groups; guest IPs come from vmrest (/vms/{id}/ip, reported by
# open-vm-tools) because the provider's ip attribute is only a placeholder.
#
# [한국어 설명] Ansible이 접속할 VM 목록(인벤토리 파일)을 자동 생성한다. entry.sh 7단계.
#   - 노드 이름 · vmrest id · Ansible 그룹 : Terraform output "nodes"에서
#   - IP 주소 : vmrest /vms/{id}/ip (게스트 안의 open-vm-tools가 보고한 값)
#     provider가 주는 ip 값은 항상 "0.0.0.0/0"(자리표시자)이라 쓸 수 없다.
#   [결과] infra/ansible/inventories/lab/.generated/terraform.yml (자동 생성 파일, .gitignore로 Git에서 제외)
#   VM이 막 켜져서 IP가 아직 없으면 5초 간격으로 최대 IP_TIMEOUT_SECONDS(기본 300초)까지 기다린다.

#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"
# vmrest 자격증명 읽기 (아래 vmrest_api 호출에 필요)
load_vmrest_env

# 출력 위치와 IP 대기 시간 (환경변수 IP_TIMEOUT_SECONDS로 변경 가능)
OUT_DIR="$REPO_ROOT/infra/ansible/inventories/lab/.generated"
OUT="$OUT_DIR/terraform.yml"
TIMEOUT="${IP_TIMEOUT_SECONDS:-300}"

# --- 1) Terraform output에서 노드 목록 읽기 (비어 있으면 cluster-apply.sh를 먼저 실행하라며 종료) ---
nodes=$("$REPO_ROOT/scripts/tf.sh" output -json nodes)
[[ "$(jq 'length' <<<"$nodes")" -gt 0 ]] || die "Terraform reports no nodes; run scripts/cluster-apply.sh first"

# --- 2) 노드마다 IP 조회 → hosts JSON에 누적 ---
# hosts 최종 모양) {"k3s-server": {"ansible_host": "172.16.133.134", "vmrest_id": "..."}, ...}
# SECONDS = bash 내장 변수(스크립트 시작 후 지난 초) → deadline(지금 + TIMEOUT)까지 반복
hosts="{}"
for name in $(jq -r 'keys[]' <<<"$nodes"); do
  id=$(jq -r --arg n "$name" '.[$n].id' <<<"$nodes")
  ip=""
  deadline=$((SECONDS + TIMEOUT))
  while ((SECONDS < deadline)); do
    # IP 조회. 아직 없으면 빈 값(.ip // empty), 에러는 무시(|| true). IPv4 형식(숫자.숫자.숫자.숫자)이면 성공
    ip=$(vmrest_api "$VMREST_BASE/vms/$id/ip" | jq -r '.ip // empty' 2>/dev/null || true)
    [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] && break
    ip=""
    sleep 5
  done
  [[ -n "$ip" ]] || die "$name ($id): no guest IP from vmrest after ${TIMEOUT}s (is the VM on and open-vm-tools running?)"
  log "$name -> $ip"
  # hosts에 이 노드 항목 추가 (jq '. + {...}' = 기존 객체에 키 추가)
  hosts=$(jq --arg n "$name" --arg ip "$ip" --arg id "$id" '. + {($n): {ansible_host: $ip, vmrest_id: $id}}' <<<"$hosts")
done

# --- 3) Ansible 전용 known_hosts에서 이 IP들의 예전 SSH 호스트 키 삭제 ---
# ssh-keygen -R IP -f 파일 : 해당 IP 항목 삭제 (없어도 에러 무시). 자동으로 생기는 백업(.old)도 지움
# Clones mint new SSH host keys, so a rebuilt node reuses an address with a different key; forget old keys for these IPs.
KNOWN_HOSTS="$LAB_STATE_DIR/ansible/known_hosts"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
for ip in $(jq -r '.[].ansible_host' <<<"$hosts"); do
  ssh-keygen -R "$ip" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
done
rm -f "$KNOWN_HOSTS.old"

# --- 4) 인벤토리 파일 쓰기 ---
# jq로 Ansible 인벤토리 구조를 만든다:
#   all.children.vms.hosts            = 위에서 만든 hosts (IP 포함, 모든 VM)
#   all.children.<그룹>.hosts.<노드>  = Terraform output의 ansible_groups를 그룹별로 묶은 것
#     to_entries로 {group, host} 쌍 펼치기 → group_by(.group)로 그룹끼리 묶기 → from_entries로 객체 변환
#   결과 예) k3s_server: {hosts: {k3s-server: {}}}, k3s_agents: {hosts: {worker-cpu-1: {}, worker-cpu-2: {}}}
# .tmp에 먼저 쓰고 mv로 교체 → 쓰는 도중 실패해도 기존 파일이 반쯤 깨진 채로 남지 않음
mkdir -p "$OUT_DIR"
# JSON is valid YAML, so the yaml inventory plugin reads this file as-is.
jq -n --argjson nodes "$nodes" --argjson hosts "$hosts" '
  {all: {children: (
    {vms: {hosts: $hosts}} +
    ([$nodes | to_entries[] | .key as $h | .value.ansible_groups[] | {group: ., host: $h}]
     | group_by(.group)
     | map({key: .[0].group, value: {hosts: (map({key: .host, value: {}}) | from_entries)}})
     | from_entries)
  )}}' >"$OUT.tmp"
mv "$OUT.tmp" "$OUT"
log "wrote $OUT"

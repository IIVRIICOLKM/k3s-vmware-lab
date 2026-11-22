#!/usr/bin/env bash
# Read-only capacity report: per-node allocatable vs requests/limits vs live usage, Helm releases and PVCs, as Markdown.
# Changes nothing in the cluster or the repository; prints to stdout (redirect it to keep a copy).
# Usage: scripts/capacity-report.sh            (the cluster must be up: scripts/entry.sh)
#
# [한국어 설명] 클러스터 자원 현황 보고서 (읽기 전용). docs/plan-week11-capacity.md의 측정값 표를 만들 때 쓴다.
#   출력은 Markdown이라 그대로 문서에 붙여 넣을 수 있다. 클러스터·저장소의 어떤 것도 바꾸지 않는다.
#   구역:
#     1) 물리 PC      : 코어 수, 전체/사용/가용 메모리, VM에 나눠 준 메모리 합계(infra/terraform/variables.tf)
#     2) 노드별 예약  : allocatable 대비 requests·limits 합계, 파드 수, limit이 없는 컨테이너 수
#     3) 실제 사용량  : kubectl top (metrics-server), 메모리를 많이 쓰는 파드 15개
#     4) Helm 릴리스  : 릴리스별 파드 수와 requests·limits 합계 (default 네임스페이스의 시험용 릴리스 정리 목록용)
#     5) PVC          : 네임스페이스별 요청 크기와 놓인 노드(local-path)
#   한계: 파드의 requests는 일반 컨테이너(containers)만 더한다. init 컨테이너와 RuntimeClass overhead는 빼서,
#         `kubectl describe node`의 합계와 조금 다를 수 있다. 실행이 끝난 파드(Succeeded·Failed)는 세지 않는다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 상수와 도구 함수 ---
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
TF_VARIABLES="$REPO_ROOT/infra/terraform/variables.tf"

# k / h : 이 클러스터용 kubectl·helm (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
h() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }
# usage : 이 파일 2~4번째 줄(영문 설명·사용법)을 출력하고 종료
usage() {
  sed -n '2,4s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}

# JQ_UNITS : 쿠버네티스 수량 문자열을 숫자로 바꾸는 jq 함수 모음 (아래 jq 명령 앞에 붙여 쓴다)
#   cpu_m  : "250m" → 250, "2" → 2000          (단위: milliCPU)
#   mem_mi : "512Mi" → 512, "3Gi" → 3072, "3000000Ki" → 2929.7, 접미사 없는 바이트 수도 처리  (단위: MiB)
#   r1     : 소수 첫째 자리까지 반올림
#   active : 아직 자원을 잡고 있는 파드(노드에 배정됐고 Running 또는 Pending)만 고른다
read -r -d '' JQ_UNITS <<'JQ' || true
def cpu_m: if . == null then 0 elif test("m$") then (.[:-1] | tonumber) else (tonumber * 1000) end;
def mem_mi:
  if . == null then 0
  elif test("Ki$") then ((.[:-2] | tonumber) / 1024)
  elif test("Mi$") then (.[:-2] | tonumber)
  elif test("Gi$") then ((.[:-2] | tonumber) * 1024)
  elif test("Ti$") then ((.[:-2] | tonumber) * 1048576)
  elif test("k$") then ((.[:-1] | tonumber) * 1000 / 1048576)
  elif test("M$") then ((.[:-1] | tonumber) * 1000000 / 1048576)
  elif test("G$") then ((.[:-1] | tonumber) * 1000000000 / 1048576)
  else ((tonumber) / 1048576) end;
def r1: (. * 10 | round) / 10;
def active: select(.spec.nodeName != null and (.status.phase == "Running" or .status.phase == "Pending"));
def sum_cpu(f): [.spec.containers[] | f | cpu_m] | add // 0;
def sum_mem(f): [.spec.containers[] | f | mem_mi] | add // 0;
JQ

# --- 2) 인자 검사 ---
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  usage 0
fi
(($# == 0)) || usage 1
command -v jq >/dev/null || die "jq is required"
[[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE (is the cluster provisioned? scripts/entry.sh)"
k get nodes >/dev/null 2>&1 || die "cannot reach the cluster API (is it running? scripts/entry.sh)"

echo "# 자원 현황 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo

# --- 3) 물리 PC: 코어 수·메모리와 VM에 나눠 준 메모리 합계 ---
# free -m 의 Mem: 줄에서 total=2열, used=3열, available=7열. VM 합계는 variables.tf의 memory_mb 값을 더한다.
# LC_ALL=C : free가 한글로("메모리:") 출력해도 아래 awk가 "Mem:"을 찾도록 영어로 고정한다.
echo "## 1. 물리 PC"
echo
vm_mb=$(grep -oE 'memory_mb *= *[0-9]+' "$TF_VARIABLES" | grep -oE '[0-9]+$' | awk '{s += $1} END {print s}')
LC_ALL=C free -m | awk -v cores="$(nproc)" -v vm="$vm_mb" '
  /^Mem:/ {
    printf "| 항목 | 값 |\n|---|---|\n"
    printf "| CPU 코어 | %d |\n", cores
    printf "| 메모리 전체 | %d MiB |\n", $2
    printf "| 메모리 사용 (VM 포함) | %d MiB |\n", $3
    printf "| 메모리 가용 (available) | %d MiB |\n", $7
    printf "| VM 3대에 나눠 준 메모리 (variables.tf) | %d MiB |\n", vm
  }'
echo

# --- 4) 노드별 allocatable 대비 requests·limits ---
# 노드 목록과 파드 목록을 jq 하나에서 합친다. --slurpfile = 파일(여기서는 프로세스 치환)의 JSON을 배열로 읽어 변수에 담음
echo "## 2. 노드별 예약 (allocatable 대비)"
echo
echo "| 노드 | 역할 | 파드 | CPU allocatable | CPU requests | CPU limits | 메모리 allocatable (MiB) | 메모리 requests | 메모리 limits | 메모리 requests 비율 | 메모리 limit 없는 컨테이너 |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"
jq -rn "$JQ_UNITS"'
  $nodes[0].items as $nodes | $pods[0].items as $pods
  | $nodes[]
  | .metadata.name as $n
  | ([$pods[] | active | select(.spec.nodeName == $n)]) as $p
  | (.status.allocatable.cpu | cpu_m) as $acpu
  | (.status.allocatable.memory | mem_mi) as $amem
  | ([$p[] | sum_cpu(.resources.requests.cpu)] | add // 0) as $rc
  | ([$p[] | sum_cpu(.resources.limits.cpu)] | add // 0) as $lc
  | ([$p[] | sum_mem(.resources.requests.memory)] | add // 0) as $rm
  | ([$p[] | sum_mem(.resources.limits.memory)] | add // 0) as $lm
  | ([$p[] | .spec.containers[] | select(.resources.limits.memory == null)] | length) as $nolim
  | "| \($n) | \(.metadata.labels["k3slab.io/role"] // "control-plane") | \($p | length) | \($acpu)m | \($rc)m | \($lc)m | \($amem | round) | \($rm | round) | \($lm | round) | \(($rm / $amem * 100) | r1)% | \($nolim) |"
' --slurpfile nodes <(k get nodes -o json) --slurpfile pods <(k get pods -A -o json)
echo

# --- 5) 실제 사용량: metrics-server가 있어야 한다 ---
# kubectl top 이 실패하면(metrics-server 없음·준비 안 됨) 상태를 대신 출력해서 이유가 보이게 한다.
echo "## 3. 실제 사용량 (kubectl top)"
echo
if top_nodes=$(k top nodes 2>&1); then
  echo '```console'
  echo '$ kubectl top nodes'
  echo "$top_nodes"
  echo '```'
  echo
  # 파이프에 head를 쓰면 kubectl이 SIGPIPE로 죽어 pipefail에 걸리므로, 변수에 담은 뒤 앞부분만 자른다.
  top_pods=$(k top pods -A --sort-by=memory 2>&1 || true)
  echo '```console'
  echo '$ kubectl top pods -A --sort-by=memory   (위쪽 15개)'
  sed -n '1,16p' <<<"$top_pods"
  echo '```'
else
  echo "kubectl top 실패 (metrics-server 상태 확인 필요):"
  echo
  echo '```console'
  echo "$top_nodes"
  k -n kube-system get deploy metrics-server 2>&1 || true
  echo '```'
fi
echo

# --- 6) Helm 릴리스별 자원: 파드의 app.kubernetes.io/instance 라벨 = 릴리스 이름 ---
echo "## 4. Helm 릴리스별 자원"
echo
echo "| 네임스페이스 | 릴리스 | 차트 | 상태 | 파드 | CPU requests | 메모리 requests (MiB) | 메모리 limits (MiB) | GPU | 노드 |"
echo "|---|---|---|---|---|---|---|---|---|---|"
jq -rn "$JQ_UNITS"'
  $rel[0][] as $r
  | ([$pods[0].items[] | active
       | select(.metadata.namespace == $r.namespace and .metadata.labels["app.kubernetes.io/instance"] == $r.name)]) as $p
  | "| \($r.namespace) | \($r.name) | \($r.chart) | \($r.status) | \($p | length)"
    + " | \([$p[] | sum_cpu(.resources.requests.cpu)] | add // 0)m"
    + " | \([$p[] | sum_mem(.resources.requests.memory)] | add // 0 | round)"
    + " | \([$p[] | sum_mem(.resources.limits.memory)] | add // 0 | round)"
    + " | \([$p[] | .spec.containers[] | .resources.limits["nvidia.com/gpu"] | select(. != null) | tonumber] | add // 0)"
    + " | \([$p[].spec.nodeName] | unique | join(",")) |"
' --slurpfile rel <(h list -A -o json) --slurpfile pods <(k get pods -A -o json)
echo

# --- 7) PVC: 요청 크기, 저장소 종류, 놓인 노드 (local-path PV는 노드에 묶여 있다) ---
echo "## 5. PVC"
echo
echo "| 네임스페이스 | 이름 | 요청 크기 | StorageClass | 상태 | 노드 |"
echo "|---|---|---|---|---|---|"
jq -rn '
  ($pv[0].items | map({key: .metadata.name, value: ((.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]) // "-")}) | from_entries) as $node
  | $pvc[0].items[]
  | "| \(.metadata.namespace) | \(.metadata.name) | \(.spec.resources.requests.storage) | \(.spec.storageClassName // "-") | \(.status.phase) | \($node[.spec.volumeName // ""] // "-") |"
' --slurpfile pvc <(k get pvc -A -o json) --slurpfile pv <(k get pv -o json)

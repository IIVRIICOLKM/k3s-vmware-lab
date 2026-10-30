#!/usr/bin/env bash
# Runs the five K3s lab exercises from the research proposal (slide 8) against the live cluster and writes the
# commands, outputs, timings and PASS/FAIL checks to docs/labs/k3s-lab-<date>.md.
#   1 node join   2 work placement (GPU taint)   3 replica scaling   4 pod restart   5 node stop (worker-cpu-2)
# Lab 5 hard-stops a VM and runs scripts/entry.sh to bring it back; skip it with --skip-node-stop.
# Usage: scripts/k3s-lab.sh [--skip-node-stop] [--keep]   (--keep leaves the k3slab-lab namespace for inspection)
#
# [한국어 설명] 제안서 8번 슬라이드의 K3s 실습 5개를 실제 클러스터에서 실행하고, 명령·출력·걸린 시간·판정을
#   docs/labs/k3s-lab-<날짜시각>.md 보고서로 남긴다. 실습용 매니페스트는 infra/k8s/labs/에 있다.
#   1 노드 조인      : 4대가 모두 Ready인지
#   2 작업 배치      : gpu-host에 taint를 걸고, GPU 파드는 gpu-host에만, 일반 파드는 VM에만 뜨는지
#                      GPU가 1개뿐이라 두 번째 GPU 파드는 Pending이 되는지 (가장 부족한 자원이 배치 기준)
#   3 복제본 조정    : echo-api replicas 1 → 3, 요청 60개가 세 파드로 나뉘는지
#   4 파드 재시작    : 파드 강제 삭제 → 새 파드 자동 생성 / 컨테이너 종료 → 같은 파드에서 재시작 횟수 증가
#   5 노드 중단      : worker-cpu-2 VM 강제 종료 → NotReady까지, 파드가 다른 노드로 옮겨질 때까지 시간 측정
#                      → scripts/entry.sh로 복구 (Terraform이 꺼진 VM을 다시 켬)
#   [옵션] --skip-node-stop: 5번 생략 / --keep: 끝나도 k3slab-lab 네임스페이스를 지우지 않음
#   [주의] gpu-host taint(nvidia.com/gpu=present:NoSchedule)는 실습 뒤에도 남긴다. 운영 정책이기 때문이다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 옵션 읽기 ---
# sed -n '2,6s/^# \{0,1\}//p' "$0" : 이 파일 2~6번째 줄(영문 설명)을 도움말로 출력
SKIP_NODE_STOP=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
  --skip-node-stop) SKIP_NODE_STOP=1 ;;
  --keep) KEEP=1 ;;
  -h | --help)
    sed -n '2,6s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  *) die "unknown option $arg (see --help)" ;;
  esac
done

# --- 2) 경로·상수 ---
# NS: 실습 전용 네임스페이스 / LABS: 매니페스트 폴더 / STOP_NODE: 5번에서 끌 노드(제안서상 중단 실험 대상)
NS="k3slab-lab"
LABS="$REPO_ROOT/infra/k8s/labs"
STOP_NODE="worker-cpu-2"
GPU_TAINT="nvidia.com/gpu=present:NoSchedule"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
REPORT_DIR="$REPO_ROOT/docs/labs"
REPORT="$REPORT_DIR/k3s-lab-$(date +%Y%m%d-%H%M).md"
PASS=0
FAIL=0

command -v kubectl >/dev/null || die "kubectl not found (gpu-host.yml links /usr/local/bin/kubectl to k3s)"
[[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE (created by the k3s_server role)"
mkdir -p "$REPORT_DIR"

# --- 3) 보조 함수 ---

# k [kubectl 인자...] : 이 클러스터용 kubectl
#   KUBECONFIG = secrets/kubeconfig (관리자 권한)
#   K3S_CONFIG_FILE=/dev/null : kubectl이 k3s 링크라서 root 전용 /etc/rancher/k3s/config.yaml을 읽으려다
#                               "permission denied" 경고를 3줄씩 내는 것을 막는다
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }

# md 줄... : 보고서 파일 끝에 줄을 덧붙인다 (인자 하나가 한 줄)
md() { printf '%s\n' "$@" >>"$REPORT"; }

# run_rec "제목" 명령 [인자...] : 명령을 실행해 화면과 보고서에 출력·걸린 시간·종료 코드를 남긴다
#   실패해도 스크립트를 멈추지 않고 종료 코드를 그대로 돌려준다 (판정은 check가 따로 한다)
#   보고서에는 "k ..."를 "kubectl ..."로 바꿔 적는다 (${shown/#k /kubectl } = 맨 앞 "k "만 치환)
#   보조 함수를 실행할 때는 SHOW="보고서에 적을 명령" run_rec ... 처럼 표시할 명령을 따로 줄 수 있다
run_rec() {
  local title=$1 start=$SECONDS out rc shown
  shift
  shown="${SHOW:-$*}"
  shown=${shown/#k /kubectl }
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  md "" "**$title** — $((SECONDS - start))s, exit $rc" "" '```console' "\$ $shown" "$out" '```'
  log "$title (exit $rc)"
  printf '%s\n' "$out"
  return $rc
}

# note 문장 : 보고서에 설명 문단 한 줄 추가
note() { md "" "$*"; }

# check "설명" 명령 [인자...] : 명령이 성공(종료 코드 0)하면 PASS, 아니면 FAIL로 집계하고 보고서에 남긴다
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    md "" "- ✅ **PASS** — $desc"
    log "PASS $desc"
  else
    FAIL=$((FAIL + 1))
    md "" "- ❌ **FAIL** — $desc"
    log "FAIL $desc"
  fi
}

# wait_until 제한초 명령 [인자...] : 명령이 성공할 때까지 2초 간격으로 반복. 성공하면 걸린 초를 출력, 시간 초과면 return 1
wait_until() {
  local limit=$1 start=$SECONDS
  shift
  while ((SECONDS - start < limit)); do
    if "$@" >/dev/null 2>&1; then
      printf '%s\n' "$((SECONDS - start))"
      return 0
    fi
    sleep 2
  done
  return 1
}

# section "제목" : 보고서에 실습 제목(##)을 쓰고 화면에도 표시
section() {
  md "" "## $1"
  log "=== $1"
}

# 아래 작은 함수들은 check/wait_until에 넘기는 "조건"이다 (성공 = 조건 만족).
# wait_until/check는 같은 셸에서 "$@"를 실행하므로 함수를 그대로 넘길 수 있다.

# ready_nodes : Ready 상태인 노드 수를 출력
ready_nodes() { k get nodes --no-headers | awk '$2 == "Ready"' | wc -l; }
# node_ready 노드 : 그 노드의 Ready 조건이 True면 성공
node_ready() { [[ "$(k get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]]; }
# node_not_ready 노드 : Ready 조건이 True가 아니면(False 또는 Unknown) 성공
node_not_ready() { ! node_ready "$1"; }
# echo_ready 개수 : echo-api의 준비 완료 복제본 수가 정확히 그 개수면 성공
echo_ready() { [[ "$(k -n "$NS" get deploy echo-api -o jsonpath='{.status.readyReplicas}')" == "$1" ]]; }
# pod_nodes 레이블 : 그 레이블 파드들이 올라간 노드 이름 목록(한 줄에 하나)
pod_nodes() { k -n "$NS" get pods -l "$1" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'; }
# none_on 노드 레이블 : 그 레이블 파드가 하나 이상 있고, 그중 그 노드에 올라간 것이 하나도 없으면 성공
#   목록을 먼저 변수에 받는다. kubectl이 실패해 목록이 비었는데 "없음"으로 판정하는 일을 막기 위해서다.
none_on() { local nodes; nodes=$(pod_nodes "$2") && [[ -n "$nodes" ]] && ! grep -qx "$1" <<<"$nodes"; }
# pod_on 파드 노드 : 그 파드가 그 노드에서 Running이면 성공
pod_on() { [[ "$(k -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}/{.status.phase}')" == "$2/Running" ]]; }
# log_has 파드 문자열 : 그 파드 로그에 문자열이 있으면 성공
#   로그를 먼저 받아서 검사한다. 파이프로 넘기면 grep -q가 일찍 끝날 때 kubectl이 SIGPIPE로 실패하고,
#   pipefail 때문에 그것이 실패로 잡힌다.
log_has() { local out; out=$(k -n "$NS" logs "$1") && grep -q "$2" <<<"$out"; }
# gpu_b_unschedulable : gpu-train-b가 Pending이고, 스케줄 실패 사유가 GPU 부족(Insufficient nvidia.com/gpu)이면 성공
#   jq any(배열[]; 조건) = 배열 중 하나라도 조건을 만족하면 true / jq -e = 결과가 false·null이면 종료 코드 1
gpu_b_unschedulable() {
  k -n "$NS" get pod gpu-train-b -o json |
    jq -e '.status.phase == "Pending" and any(.status.conditions[]?; .type == "PodScheduled" and ((.message // "") | test("Insufficient nvidia.com/gpu")))'
}
# replaced 파드 : 그 파드가 사라졌고 echo-api 준비 복제본이 다시 3개면 성공
replaced() { ! k -n "$NS" get pod "$1" >/dev/null 2>&1 && echo_ready 3; }
# restart_state : restart-demo의 "재시작횟수/준비여부" 출력 (예: 1/true)
restart_state() { k -n "$NS" get pod restart-demo -o jsonpath='{.status.containerStatuses[0].restartCount}/{.status.containerStatuses[0].ready}'; }
# restarted_once : restart-demo가 한 번 재시작했고 다시 Ready면 성공
restarted_once() { [[ "$(restart_state)" == "1/true" ]]; }
# live_ready_off 노드 : 그 노드 밖에서 Ready인 echo-api 파드가 3개 이상이면 성공
#   꺼진 노드의 원래 파드는 삭제 대기(Terminating) 상태로 phase=Running인 채 남는다.
#   그래서 deletionTimestamp가 있는 파드는 세지 않는다.
live_ready_off() {
  k -n "$NS" get pods -l app=echo-api -o json |
    jq -e --arg stop "$1" '[.items[] | select(.metadata.deletionTimestamp == null and .spec.nodeName != $stop
      and any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length >= 3'
}
# describe_alloc 노드 : kubectl describe node 중 "Allocated resources"(요청·한도 합계) 부분만 출력
describe_alloc() { k describe node "$1" | sed -n '/Allocated resources/,/Events/p'; }
# events_tail : 실습 네임스페이스의 최근 이벤트 15개
events_tail() { k -n "$NS" get events --sort-by=.lastTimestamp | tail -15; }

# load_test : load-client Job을 새로 실행해 "응답 횟수 파드이름" 목록을 출력 (이전 Job은 먼저 지움)
load_test() {
  k -n "$NS" delete job load-client --ignore-not-found --wait=true >/dev/null
  k apply -f "$LABS/21-load-client.yaml" >/dev/null
  k -n "$NS" wait --for=condition=complete job/load-client --timeout=180s >/dev/null
  k -n "$NS" logs job/load-client
}

# --- 4) 실습 1: 노드 조인 ---
lab1_join() {
  section "1. 노드 조인"
  note "VM 3대(Rocky 9.8)와 물리 호스트(gpu-host, Ubuntu 26.04)가 모두 Ready인지 확인한다."
  run_rec "노드 목록" k get nodes -o wide || true
  run_rec "노드 라벨(역할)" k get nodes -L k3slab.io/role || true
  check "노드 4대가 모두 Ready" test "$(ready_nodes)" -eq 4
}

# --- 5) 실습 2: 작업 배치 (GPU taint + nodeSelector + 자원 요청) ---
lab2_placement() {
  local gpu_node
  section "2. 작업 배치"
  # 레이블 k3slab.io/role=gpu 가 붙은 노드 이름 (gpu-host)
  gpu_node=$(k get nodes -l k3slab.io/role=gpu -o jsonpath='{.items[0].metadata.name}')
  note "GPU 노드($gpu_node)에 \`$GPU_TAINT\` taint를 건다. 이 taint를 견디는(toleration) 파드만 그 노드에 올라간다. 일반 파드는 VM으로 비켜 간다."
  run_rec "GPU 노드 taint 설정" k taint node "$gpu_node" "$GPU_TAINT" --overwrite || true
  # GPU 플러그인이 준비될 때까지 기다린다. k3s-agent가 막 재시작했다면 플러그인이 kubelet에 다시 등록되기 전에
  # GPU 파드가 도착해 "nvidia.com/gpu Available: 0"으로 거부될 수 있다 (bare Pod라 재시도도 없음)
  k -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=180s >/dev/null || true
  run_rec "실습 매니페스트 적용" k apply -f "$LABS/00-namespace.yaml" -f "$LABS/10-gpu-placement.yaml" || true

  # gpu-train-a가 실행될 때까지(이미지 pull 포함) 최대 300초, cpu-filler 4개 준비까지 대기
  k -n "$NS" wait --for=condition=Ready pod/gpu-train-a --timeout=300s >/dev/null || true
  k -n "$NS" rollout status deploy/cpu-filler --timeout=180s >/dev/null || true
  # gpu-train-b는 스케줄러가 한 번 시도해서 Pending 사유를 남길 때까지 대기
  wait_until 60 gpu_b_unschedulable >/dev/null || true

  run_rec "파드 배치 결과" k -n "$NS" get pods -o wide || true
  run_rec "gpu-train-a 로그 (GPU 인식)" k -n "$NS" logs gpu-train-a || true
  run_rec "gpu-train-b 가 Pending인 이유" k -n "$NS" get pod gpu-train-b -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].message}' || true
  SHOW="kubectl describe node $gpu_node | sed -n '/Allocated resources/,/Events/p'" run_rec "GPU 노드 자원 할당" describe_alloc "$gpu_node" || true

  check "gpu-train-a가 $gpu_node 에서 실행 중" pod_on gpu-train-a "$gpu_node"
  check "gpu-train-a 안에서 RTX 3090 인식" log_has gpu-train-a "RTX 3090"
  check "gpu-train-b는 GPU 부족으로 Pending (GPU 1개를 a가 점유)" gpu_b_unschedulable
  check "cpu-filler 4개 중 $gpu_node 에 올라간 파드가 없음" none_on "$gpu_node" app=cpu-filler

  # 다음 실습에 방해되지 않게 GPU 파드와 cpu-filler를 정리 (GPU 반납)
  k -n "$NS" delete pod gpu-train-a gpu-train-b --wait=false >/dev/null || true
  k -n "$NS" delete deploy cpu-filler --wait=false >/dev/null || true
}

# --- 6) 실습 3: 복제본 조정 ---
lab3_scale() {
  local counts
  section "3. 복제본 조정"
  note "API 파드 대역(echo-api, whoami)은 worker-cpu-2(app)를 선호하도록 배치한다. 복제본 1개와 3개일 때 요청 60개가 어느 파드로 가는지 센다."
  run_rec "echo-api 배포 (replicas 1)" k apply -f "$LABS/20-echo-api.yaml" || true
  k -n "$NS" rollout status deploy/echo-api --timeout=180s >/dev/null || true
  counts=$(run_rec "요청 60개 분배 (replicas 1)" load_test) || true
  check "replicas 1: 응답한 파드가 1개" test "$(awk 'NF == 2' <<<"$counts" | wc -l)" -eq 1

  run_rec "replicas 1 → 3" k -n "$NS" scale deploy/echo-api --replicas=3 || true
  k -n "$NS" rollout status deploy/echo-api --timeout=180s >/dev/null || true
  run_rec "echo-api 파드 배치" k -n "$NS" get pods -l app=echo-api -o wide || true
  counts=$(run_rec "요청 60개 분배 (replicas 3)" load_test) || true
  check "replicas 3: 세 파드가 모두 요청을 받음" test "$(awk 'NF == 2' <<<"$counts" | wc -l)" -eq 3
}

# --- 7) 실습 4: 파드 재시작 ---
lab4_restart() {
  local victim secs
  section "4. 파드 재시작"
  # (a) 파드 강제 삭제: Deployment가 새 파드(새 이름)를 만들어 복제본 3개를 다시 맞추는지
  victim=$(k -n "$NS" get pods -l app=echo-api -o jsonpath='{.items[0].metadata.name}')
  note "(a) echo-api 파드 하나($victim)를 강제 삭제한다. Deployment가 새 파드를 만들어 3개를 다시 채우는지 본다."
  run_rec "파드 강제 삭제" k -n "$NS" delete pod "$victim" --grace-period=0 --force || true
  # 지워진 이름이 사라지고 준비 완료 복제본이 다시 3개가 될 때까지 걸린 초
  secs=$(wait_until 120 replaced "$victim") || secs="timeout"
  note "새 파드로 복제본 3개가 다시 준비되기까지: **${secs}s**"
  run_rec "삭제 후 파드 목록" k -n "$NS" get pods -l app=echo-api -o wide || true
  check "강제 삭제 뒤 새 파드로 복제본 3개 복구" echo_ready 3

  # (b) 컨테이너 종료: 같은 파드 안에서 kubelet이 컨테이너를 다시 띄우고 RESTARTS가 1 오르는지
  note "(b) restart-demo 컨테이너를 일부러 종료(exit 1)시킨다. 같은 파드 안에서 컨테이너가 다시 시작되고 재시작 횟수가 오르는지 본다."
  k apply -f "$LABS/30-restart-demo.yaml" >/dev/null
  k -n "$NS" wait --for=condition=Ready pod/restart-demo --timeout=120s >/dev/null || true
  run_rec "컨테이너 종료 유도 (/tmp/crash 생성)" k -n "$NS" exec restart-demo -- touch /tmp/crash || true
  secs=$(wait_until 120 restarted_once) || secs="timeout"
  note "컨테이너가 재시작해서 다시 준비되기까지: **${secs}s**"
  run_rec "재시작 후 상태 (RESTARTS)" k -n "$NS" get pod restart-demo || true
  run_rec "이전 컨테이너 로그" k -n "$NS" logs restart-demo --previous || true
  check "restart-demo 재시작 횟수 1, 다시 Ready" restarted_once
}

# --- 8) 실습 5: 노드 중단 ---
lab5_node_stop() {
  local vmx t_notready t_moved t_back
  section "5. 노드 중단 ($STOP_NODE)"
  # Terraform output에서 끌 VM의 VMX 경로를 읽는다 (경로를 손으로 적지 않음)
  vmx=$("$REPO_ROOT/scripts/tf.sh" output -json nodes | jq -r --arg n "$STOP_NODE" '.[$n].path')
  [[ -f "$vmx" ]] || die "VMX for $STOP_NODE not found: $vmx"
  note "제안서는 \`virsh\`(KVM) 기준이지만 이 환경은 VMware Workstation이라 \`vmrun ... hard\`로 VM 전원을 강제로 끊는다. 기본 설정에서는 노드가 NotReady가 된 뒤 약 300초(not-ready/unreachable toleration) 뒤에 파드가 옮겨진다."
  run_rec "중단 전 echo-api 배치" k -n "$NS" get pods -l app=echo-api -o wide || true

  run_rec "$STOP_NODE 강제 종료" vmrun -T ws stop "$vmx" hard || true
  # NotReady 감지까지, 그다음 echo-api 3개가 모두 다른 노드에서 준비될 때까지 시간 측정
  t_notready=$(wait_until 180 node_not_ready "$STOP_NODE") || t_notready="timeout"
  note "$STOP_NODE 가 NotReady가 되기까지: **${t_notready}s**"
  run_rec "NotReady 직후 노드 상태" k get nodes || true
  t_moved=$(wait_until 600 live_ready_off "$STOP_NODE") || t_moved="timeout"
  note "NotReady 감지 이후 echo-api 3개가 다른 노드에서 다시 준비되기까지: **${t_moved}s** (강제 종료부터 합계: NotReady까지 + 이 시간)"
  run_rec "이동 후 echo-api 배치" k -n "$NS" get pods -l app=echo-api -o wide || true
  SHOW="kubectl -n $NS get events --sort-by=.lastTimestamp | tail -15" run_rec "관련 이벤트 (최근 15개)" events_tail || true
  check "$STOP_NODE 중단 뒤 echo-api 3개가 다른 노드에서 Ready" live_ready_off "$STOP_NODE"

  # 복구: entry.sh가 Terraform으로 꺼진 VM을 다시 켜고 Ansible로 상태를 맞춘다 (로그는 logs/ 폴더)
  log "restoring $STOP_NODE with scripts/entry.sh (log: $LAB_LOG_DIR/k3s-lab-entry.log)"
  "$REPO_ROOT/scripts/entry.sh" >"$LAB_LOG_DIR/k3s-lab-entry.log" 2>&1 </dev/null || true
  t_back=$(wait_until 300 node_ready "$STOP_NODE") || t_back="timeout"
  note "\`scripts/entry.sh\`로 복구한 뒤 $STOP_NODE 가 다시 Ready: **${t_back}s** (entry.sh 실행 시간 제외)"
  run_rec "복구 후 노드 상태" k get nodes || true
  run_rec "복구 후 echo-api 배치" k -n "$NS" get pods -l app=echo-api -o wide || true
  note "관찰: 노드가 돌아와도 쿠버네티스는 이미 옮겨진 파드를 원래 노드로 되돌리지 않는다(자동 재균형 없음). 다시 나누려면 \`kubectl rollout restart\`가 필요하다."
  check "$STOP_NODE 복구 후 다시 Ready" node_ready "$STOP_NODE"
}

# --- 9) 실행 순서: 보고서 머리말 → 실습 1~5 → 정리 → 결과 요약 ---
{
  printf '# K3s 실습 결과 (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 제안서 8번 슬라이드 실습 5개. 생성: `scripts/k3s-lab.sh`, 매니페스트: `infra/k8s/labs/`\n'
  printf -- '- K3s %s, 노드 %s대\n' "$(k version -o json 2>/dev/null | jq -r .serverVersion.gitVersion)" "$(k get nodes --no-headers | wc -l)"
} >"$REPORT"
log "report: $REPORT"

# 이전 실행이 남긴 네임스페이스가 있으면 완전히 지운 뒤 시작 (삭제 중인 네임스페이스에는 apply가 실패함)
k delete namespace "$NS" --ignore-not-found --wait=true >/dev/null

lab1_join
((PASS == 1)) || die "not all 4 nodes are Ready; fix the cluster first (see $REPORT)"
lab2_placement
lab3_scale
lab4_restart
if ((SKIP_NODE_STOP)); then
  section "5. 노드 중단 ($STOP_NODE)"
  note "이번 실행에서는 생략했다 (--skip-node-stop)."
else
  lab5_node_stop
fi

# 정리: 실습 네임스페이스 삭제 (--keep이면 남김). gpu-host taint는 운영 정책이라 남긴다
if ((KEEP)); then
  note "k3slab-lab 네임스페이스를 남겼다 (--keep)."
else
  k delete namespace "$NS" --wait=false >/dev/null || true
fi

md "" "## 결과 요약" "" "PASS $PASS, FAIL $FAIL"
log "k3s lab finished: PASS $PASS, FAIL $FAIL (report: $REPORT)"
((FAIL == 0))

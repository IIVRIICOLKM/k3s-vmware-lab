#!/usr/bin/env bash
# Benchmarks the C++ inference worker (apps/infer) inside the cluster, as in the proposal's verification plan
# (slide 14): batch size 1 vs 8 with the same request count, and an overload that must be rejected (HTTP 429)
# rather than delayed. Results go to docs/labs/infer-bench-<date>.md.
# Usage: scripts/infer-bench.sh <model-job-id> [image-tag]   (the training job's exported model.k3sm is served)
#
# [한국어 설명] C++ 추론 워커를 클러스터 안에서 시험하고 결과를 보고서로 남긴다 (제안서 14번 검증 계획).
#   ① 배치 처리: 같은 요청 400개를 MAX_BATCH=1과 8로 각각 보내 걸린 시간을 비교 (8이 더 빨라야 함)
#   ② 과부하 거절: 큐를 작게(20) 잡고 300개를 한꺼번에 보내 초과분이 지연이 아니라 429로 즉시 거절되는지
#   - 워커는 Helm 릴리스 infer-bench로 gpu-host에 띄우고(학습 모델 <작업번호>/model.k3sm 사용), 끝나면 지운다
#   - 부하는 VM 위 curl Job이 Service로 보낸다(요청마다 새 연결). 결과: 응답 코드별 개수, 걸린 시간, 워커 메트릭
#   [인자] 서빙할 학습 작업 번호, 이미지 태그(기본 v0.1)
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자와 상수 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help || $# -lt 1 ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit $(($# < 1))
fi
MODEL_JOB=$1
TAG=${2:-v0.1}
RELEASE="infer-bench"
CHART="$REPO_ROOT/charts/k3slab-workload"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
REPORT="$REPO_ROOT/docs/labs/infer-bench-$(date +%Y%m%d-%H%M).md"
mkdir -p "$(dirname "$REPORT")"

# k / h : 이 클러스터용 kubectl·helm (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
h() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }
# md 줄... : 보고서 끝에 줄 추가
md() { printf '%s\n' "$@" >>"$REPORT"; }

# --- 2) 워커 배포 함수 ---
# old_pods_gone : 이 릴리스의 파드가 정확히 1개(새 파드)만 남았고, 삭제 대기 중인 파드가 없으면 성공
old_pods_gone() {
  k get pods -l app.kubernetes.io/instance="$RELEASE" -o json |
    jq -e '(.items | length) == 1 and all(.items[]; .metadata.deletionTimestamp == null)' >/dev/null
}

# deploy 큐크기 배치크기 스레드 작업ms : 같은 릴리스를 설정만 바꿔 다시 배포하고 새 파드가 준비될 때까지 기다린다
#   helm --wait: 롤아웃(새 파드 Ready)까지 기다림. values-infer.yaml 위에 --set으로 실험값만 덮어쓴다
#   그다음 예전 파드가 완전히 사라질 때까지 기다리고 5초 더 쉰다: 모든 노드의 kube-proxy가 Service 목록에서
#   예전 파드를 뺄 시간이다(이걸 안 하면 일부 연결이 이미 종료된 파드로 가서 멈춘다, 2026-10-30 실제 발생)
deploy() {
  h upgrade --install "$RELEASE" "$CHART" -f "$CHART/values-infer.yaml" \
    --set infer.modelJobId="$MODEL_JOB" --set image.tag="$TAG" \
    --set infer.queueSize="$1" --set infer.maxBatch="$2" --set infer.threads="$3" --set infer.workMs="$4" \
    --set infer.timeoutMs=10000 --wait --timeout 5m >/dev/null
  local i
  for i in $(seq 60); do
    old_pods_gone && break
    sleep 2
  done
  sleep 5
}

# --- 3) 부하 Job 함수 ---
# load 요청수 동시수 : curl Job으로 POST /infer를 보내고 "코드별 개수 / 걸린 초 / 워커 메트릭"을 출력
#   본문: awk로 만든 64개 숫자 {"x":[...]} (시드 고정이라 매번 같음)
#   시간: /proc/uptime(0.01초 단위)을 시작·끝에 읽어 차이를 계산 (busybox date는 밀리초를 못 냄)
#   xargs -P 동시수 : 요청을 동시수만큼 병렬로 보냄 / sort | uniq -c : 응답 코드별 개수
#   curl --connect-timeout 3 --max-time 30 : 연결이나 응답이 멈추면 무한정 기다리지 않고 코드 000으로 집계
load() {
  local n=$1 c=$2
  k delete job infer-load --ignore-not-found --wait=true >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: infer-load
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: curl
          image: docker.io/curlimages/curl:8.23.0
          command:
            - sh
            - -c
            - |
              awk 'BEGIN { srand(1); printf "{\"x\":["; for (i = 0; i < 64; i++) printf "%s%.4f", (i ? "," : ""), rand() * 2 - 1; print "]}" }' > /tmp/body.json
              start=\$(cut -d' ' -f1 /proc/uptime)
              seq $n | xargs -P $c -I{} curl -s --connect-timeout 3 --max-time 30 -o /dev/null -w '%{http_code}\n' -X POST --data @/tmp/body.json http://$RELEASE:8080/infer | sort | uniq -c
              end=\$(cut -d' ' -f1 /proc/uptime)
              echo "elapsed_seconds \$(echo "\$end \$start" | awk '{printf "%.2f", \$1 - \$2}')"
              curl -s http://$RELEASE:8080/metrics | grep -E '^k3slab_infer_(requests_total|batch_size_(sum|count)|queue_capacity|worker_threads)'
EOF
  k wait --for=condition=complete job/infer-load --timeout=300s >/dev/null
  k logs job/infer-load
}

# record "제목" 설정설명 요청수 동시수 : 부하를 실행하고 결과를 보고서에 코드 블록으로 남긴 뒤 출력도 돌려준다
record() {
  local out
  out=$(load "$3" "$4")
  md "" "### $1" "" "- 설정: $2" "- 요청 $3개, 동시 $4개" "" '```text' "$out" '```'
  log "$1"
  printf '%s\n' "$out"
}

# --- 4) 실행 ---
{
  printf '# 추론 워커 벤치마크 (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 생성: `scripts/infer-bench.sh %s %s`\n' "$MODEL_JOB" "$TAG"
  printf -- '- 이미지 `registry.k3slab.local:5000/infer-worker:%s`, 모델: 학습 작업 `%s`의 `model.k3sm`\n' "$TAG" "$MODEL_JOB"
  printf -- '- WORK_MS는 배치 한 번당 고정 비용입니다. GPU 추론이 들어가기 전까지 GPU 호출 1회를 흉내 냅니다.\n'
} >"$REPORT"

md "" "## ① 배치 처리: MAX_BATCH 1 vs 8"
deploy 500 1 1 20
b1=$(record "MAX_BATCH=1" "큐 500, 스레드 1, WORK_MS 20" 400 100)
deploy 500 8 1 20
b8=$(record "MAX_BATCH=8" "큐 500, 스레드 1, WORK_MS 20" 400 100)
# 두 실행의 걸린 시간(elapsed_seconds 줄)을 꺼내 비교
t1=$(awk '/^elapsed_seconds/ {print $2}' <<<"$b1")
t8=$(awk '/^elapsed_seconds/ {print $2}' <<<"$b8")
md "" "결과: 같은 요청 400개가 MAX_BATCH=1에서 **${t1}s**, MAX_BATCH=8에서 **${t8}s** 걸렸다."

md "" "## ② 과부하 거절: 큐 20에 300개 동시 요청"
deploy 20 4 1 50
over=$(record "MAX_QUEUE=20" "큐 20, 배치 4, 스레드 1, WORK_MS 50" 300 150)
rejected=$(awk '$2 == 429 {print $1}' <<<"$over")
md "" "결과: 300개 중 **${rejected:-0}개가 HTTP 429로 즉시 거절**됐다. 대기열을 늘려 지연시키는 대신 바로 거절한다."

# 정리: 부하 Job과 벤치마크 릴리스 삭제
k delete job infer-load --ignore-not-found >/dev/null
h uninstall "$RELEASE" >/dev/null
log "infer bench done: batch1 ${t1}s, batch8 ${t8}s, rejected ${rejected:-0}/300 (report: $REPORT)"

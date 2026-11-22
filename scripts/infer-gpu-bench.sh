#!/usr/bin/env bash
# Compares the inference worker's CPU and GPU (CUDA) paths with the same requests (week 9 report: "같은 벤치마크로
# CPU 결과와 비교"): for each model, 400 requests at concurrency 100 with MAX_BATCH 8, WORK_MS 0, once with
# DEVICE=cpu (no GPU requested) and once with DEVICE=cuda (one GPU). Results go to docs/labs/infer-gpu-bench-<date>.md.
# Usage: scripts/infer-gpu-bench.sh <small-model-job-id> <large-model-job-id> [image-tag]
#
# [한국어 설명] 추론 워커의 CPU 경로와 GPU(CUDA) 경로를 같은 요청으로 비교하고 결과를 보고서로 남긴다.
#   - 모델 두 개로 잰다: 작은 모델(64→128→10, 요청당 곱셈 약 9천 번)과 큰 모델(예: 64→4096→4096→10, 약 1,700만 번).
#     작은 모델은 계산이 거의 없어 GPU 복사·호출 비용이 더 크고, 큰 모델에서야 GPU가 이득인지 확인하려는 것.
#   - 같은 조건: 요청 400개 · 동시 100개 · MAX_BATCH 8 · 스레드 2 · WORK_MS 0(흉내 비용 없음, 실제 계산만)
#   - CPU 실행은 GPU를 요청하지 않고(gpu=0, DEVICE=cpu), GPU 실행은 GPU 1개를 요청한다(DEVICE=cuda: GPU가 없으면 시작 실패).
#   - 워커가 시작할 때 GPU 결과를 CPU 결과와 비교하는 self-test 줄도 보고서에 남긴다(정확도 확인).
#   - 결과: 응답 코드별 개수, 걸린 시간, 배치 계산 시간 합(k3slab_infer_batch_compute_seconds_sum)
#   [인자] 작은 모델 학습 작업 번호, 큰 모델 학습 작업 번호, 이미지 태그(기본 v0.2)
#   [주의] gpu-host의 GPU가 1개라 학습 Job이 GPU를 쓰는 중이면 GPU 실행이 Pending으로 기다린다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자와 상수 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help || $# -lt 2 ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit $(($# < 2))
fi
SMALL=$1
LARGE=$2
TAG=${3:-v0.2}
RELEASE="infer-gpu-bench"
CHART="$REPO_ROOT/charts/k3slab-workload"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
REPORT="$REPO_ROOT/docs/labs/infer-gpu-bench-$(date +%Y%m%d-%H%M).md"
REQUESTS=400
CONCURRENCY=100
mkdir -p "$(dirname "$REPORT")"

# k / h : 이 클러스터용 kubectl·helm (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
h() { KUBECONFIG="$KUBECONFIG_FILE" helm "$@"; }
# md 줄... : 보고서 끝에 줄 추가
md() { printf '%s\n' "$@" >>"$REPORT"; }

# --- 2) 워커 배포 ---
# deploy 모델작업번호 장치 : 같은 릴리스를 모델·장치만 바꿔 다시 배포. cpu면 GPU를 요청하지 않는다.
#   배포 뒤 예전 파드가 완전히 사라지고 5초 더 기다린다(kube-proxy가 Service에서 예전 파드를 뺄 시간, infer-bench.sh와 같음)
deploy() {
  local model=$1 device=$2 gpu=1 version
  [[ "$device" == cpu ]] && gpu=0
  # 모델 버전은 학습 릴리스(train-<번호>)의 Helm 값에서 가져온다 (응답·메트릭의 model_version이 실제 모델과 맞게)
  version=$(h get values "train-$model" -o json 2>/dev/null | jq -r '.model.version // "unknown"')
  [[ "$version" =~ ^[A-Za-z0-9._-]+$ ]] || version=unknown
  h upgrade --install "$RELEASE" "$CHART" -f "$CHART/values-infer.yaml" \
    --set infer.modelJobId="$model" --set image.tag="$TAG" --set gpu="$gpu" --set-string infer.device="$device" \
    --set-string model.version="$version" \
    --set infer.queueSize=500 --set infer.maxBatch=8 --set infer.threads=2 --set infer.workMs=0 \
    --set infer.timeoutMs=30000 --wait --timeout 5m >/dev/null
  local i
  for i in $(seq 60); do
    k get pods -l app.kubernetes.io/instance="$RELEASE" -o json |
      jq -e '(.items | length) == 1 and all(.items[]; .metadata.deletionTimestamp == null)' >/dev/null && break
    sleep 2
  done
  sleep 5
}

# --- 3) 부하 Job ---
# load : curl Job이 요청 400개를 동시 100개로 보내고 "코드별 개수 / 걸린 초 / 워커 메트릭 / 응답 한 개"를 출력
#   본문은 시드 고정 64개 숫자(infer-bench.sh와 같음) → CPU와 GPU의 응답 확률을 나란히 비교할 수 있다
load() {
  k delete job infer-gpu-load --ignore-not-found --wait=true >/dev/null
  k apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: infer-gpu-load
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
              seq $REQUESTS | xargs -P $CONCURRENCY -I{} curl -s --connect-timeout 3 --max-time 60 -o /dev/null -w '%{http_code}\n' -X POST --data @/tmp/body.json http://$RELEASE:8080/infer | sort | uniq -c
              end=\$(cut -d' ' -f1 /proc/uptime)
              echo "elapsed_seconds \$(echo "\$end \$start" | awk '{printf "%.2f", \$1 - \$2}')"
              curl -s http://$RELEASE:8080/metrics | grep -E '^k3slab_infer_(info|requests_total\{result="ok"\}|batch_size_(sum|count)|batch_compute_seconds_sum)'
              echo "sample_response \$(curl -s -X POST --data @/tmp/body.json http://$RELEASE:8080/infer)"
EOF
  k wait --for=condition=complete job/infer-gpu-load --timeout=600s >/dev/null
  k logs job/infer-gpu-load
}

# run_case 제목 모델 장치 : 배포 → 부하 → 보고서 기록. 표에 쓸 "걸린 초|배치 계산 초|성공 수"를 마지막 줄로 돌려준다
run_case() {
  local title=$1 model=$2 device=$3 out boot
  # $(...) 안에서는 set -e가 적용되지 않으므로 배포 실패를 직접 확인해 멈춘다
  deploy "$model" "$device" || die "deploy of $model ($device) failed"
  boot=$(k logs "deploy/$RELEASE" | grep -E 'self-test|device=' | sed 's/^/  /')
  out=$(load)
  md "" "### $title" "" '```text' "$boot" "$out" '```'
  log "$title: $(awk '/^elapsed_seconds/ {print $2}' <<<"$out")s" >&2
  printf '%s|%s|%s\n' "$(awk '/^elapsed_seconds/ {print $2}' <<<"$out")" \
    "$(awk '/^k3slab_infer_batch_compute_seconds_sum/ {printf "%.3f", $2}' <<<"$out")" \
    "$(awk '$2 == 200 {print $1}' <<<"$out")"
}

# --- 4) 실행 ---
{
  printf '# 추론 워커 CPU vs GPU (%s)\n\n' "$(date '+%Y-%m-%d %H:%M')"
  printf -- '- 생성: `scripts/infer-gpu-bench.sh %s %s %s`\n' "$SMALL" "$LARGE" "$TAG"
  printf -- '- 이미지 `registry.k3slab.local:5000/infer-worker:%s`, gpu-host(RTX 3090)에서 실행\n' "$TAG"
  printf -- '- 공통 조건: 요청 %s개, 동시 %s개, MAX_BATCH 8, 스레드 2, WORK_MS 0(흉내 비용 없이 실제 계산만)\n' "$REQUESTS" "$CONCURRENCY"
  printf -- '- CPU 실행은 GPU를 요청하지 않음(DEVICE=cpu), GPU 실행은 GPU 1개 요청(DEVICE=cuda)\n'
  printf -- '- "배치 계산 시간"은 워커가 배치를 계산하는 데 쓴 시간의 합(큐 대기·HTTP 제외)\n'
} >"$REPORT"

md "" "## 작은 모델 (\`$SMALL\`)"
s_cpu=$(run_case "작은 모델 · CPU" "$SMALL" cpu | tail -1)
s_gpu=$(run_case "작은 모델 · GPU" "$SMALL" cuda | tail -1)
md "" "## 큰 모델 (\`$LARGE\`)"
l_cpu=$(run_case "큰 모델 · CPU" "$LARGE" cpu | tail -1)
l_gpu=$(run_case "큰 모델 · GPU" "$LARGE" cuda | tail -1)

# 요약 표: 걸린 시간 | 배치 계산 시간 합 | 성공(200) 수
row() { IFS='|' read -r t c ok <<<"$2"; md "| $1 | ${t}s | ${c}s | ${ok:-0}/$REQUESTS |"; }
md "" "## 요약" "" "| 경우 | 걸린 시간 | 배치 계산 시간 합 | 성공 |" "|---|---|---|---|"
row "작은 모델 · CPU" "$s_cpu"
row "작은 모델 · GPU" "$s_gpu"
row "큰 모델 · CPU" "$l_cpu"
row "큰 모델 · GPU" "$l_gpu"

# 정리: 부하 Job과 릴리스 삭제 (GPU를 바로 돌려준다)
k delete job infer-gpu-load --ignore-not-found >/dev/null
h uninstall "$RELEASE" >/dev/null
log "infer GPU bench done (report: $REPORT)"

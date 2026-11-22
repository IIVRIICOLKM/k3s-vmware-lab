#!/usr/bin/env bash
# Jenkins stage "Helm": helm lint and helm template for charts/k3slab-workload, for both kinds (train Job, infer Deployment),
# and checks that the rendered objects carry the image tag given with --set (the tag the pipeline will build).
# Usage: scripts/jenkins-stage-helm.sh [image-tag]   (default tag: ci-check; needs bash, curl, tar, python3 is not required)
#
# [한국어 설명] Jenkins "Helm" 단계: 차트가 문법과 내용 모두 올바른지 클러스터 없이 확인한다.
#   1) helm: PATH의 helm이 고정 버전(4.3.1)이면 그것을, 아니면 get.helm.sh에서 받아 SHA-256을 확인하고 쓴다
#      (버전과 해시는 scripts/lib/pinned-versions.env의 PIN_HELM_*와 같은 값).
#   2) helm lint: values-train.yaml, values-infer.yaml 각각으로.
#   3) helm template: 학습은 kind: Job 하나, 추론은 kind: Deployment와 Service가 나오는지,
#      --set image.tag=<태그>가 이미지 줄에 들어가는지 확인한다.
#      (파이프라인이 만든 이미지 태그를 차트가 그대로 받을 수 있는지 미리 보는 것 — Argo CD 연동의 전제)
#   4) 필수 값(train.jobId, infer.modelJobId)을 안 주면 렌더링이 실패해야 한다 (잘못된 요청을 막는 장치가 살아 있는지).
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail

# --- 1) 도움말과 상수 ---
# sed -n '2,3s/^# \{0,1\}//p' "$0" : 이 파일 2~3번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '2,3s/^# \{0,1\}//p' "$0"
  exit 0
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/k3slab-workload"
TAG=${1:-ci-check}
HELM_VERSION="4.3.1"
HELM_SHA256="0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b"
HELM_URL="https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# log 메시지 / fail 메시지 : 한 줄 출력 / 실패 출력 후 종료
log() { printf '%s [helm] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { log "FAIL: $*" >&2; exit 1; }
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || fail "invalid image tag '$TAG'"
[[ -f "$CHART/Chart.yaml" ]] || fail "$CHART/Chart.yaml not found"

# --- 2) helm 준비 ---
HELM=""
if command -v helm >/dev/null 2>&1 && helm version --template '{{.Version}}' 2>/dev/null | grep -qx "v${HELM_VERSION}"; then
  HELM=$(command -v helm)
else
  log "downloading Helm v$HELM_VERSION"
  curl -fsSL --retry 3 --retry-delay 2 -o "$TMP/helm.tgz" "$HELM_URL" || fail "cannot download Helm"
  echo "${HELM_SHA256}  $TMP/helm.tgz" | sha256sum -c - >/dev/null || fail "Helm download does not match the pinned SHA-256"
  tar -xzf "$TMP/helm.tgz" -C "$TMP" linux-amd64/helm
  HELM="$TMP/linux-amd64/helm"
fi
log "Helm $("$HELM" version --template '{{.Version}}')"

# --- 3) lint ---
# 종류별로 필수 값을 하나씩 준다 (작업 번호 / 서빙할 학습 작업 번호)
"$HELM" lint "$CHART" -f "$CHART/values-train.yaml" --set train.jobId=ci-check >"$TMP/lint-train.txt" 2>&1 ||
  { cat "$TMP/lint-train.txt" >&2; fail "helm lint (train) failed"; }
"$HELM" lint "$CHART" -f "$CHART/values-infer.yaml" --set infer.modelJobId=ci-check >"$TMP/lint-infer.txt" 2>&1 ||
  { cat "$TMP/lint-infer.txt" >&2; fail "helm lint (infer) failed"; }
log "helm lint OK (train, infer)"

# --- 4) template ---
# kinds 파일 : 렌더링 결과에서 "kind:" 줄만 모아 정렬한 것 (예: "Deployment Service")
"$HELM" template ci-train "$CHART" -f "$CHART/values-train.yaml" --set train.jobId=ci-check --set image.tag="$TAG" >"$TMP/train.yaml" ||
  fail "helm template (train) failed"
"$HELM" template ci-infer "$CHART" -f "$CHART/values-infer.yaml" --set infer.modelJobId=ci-check --set image.tag="$TAG" >"$TMP/infer.yaml" ||
  fail "helm template (infer) failed"
kinds() { sed -n 's/^kind: //p' "$1" | sort | tr '\n' ' ' | sed 's/ $//'; }
[[ "$(kinds "$TMP/train.yaml")" == "Job" ]] || fail "train should render exactly one Job, got: $(kinds "$TMP/train.yaml")"
[[ "$(kinds "$TMP/infer.yaml")" == "Deployment Service" ]] || fail "infer should render a Deployment and a Service, got: $(kinds "$TMP/infer.yaml")"
grep -Eq "image: \"?registry\.k3slab\.local:5000/train-worker:${TAG}\"?$" "$TMP/train.yaml" || fail "train Job does not use image tag $TAG"
grep -Eq "image: \"?registry\.k3slab\.local:5000/infer-worker:${TAG}\"?$" "$TMP/infer.yaml" || fail "infer Deployment does not use image tag $TAG"
log "helm template OK: train -> Job, infer -> Deployment + Service, image tag $TAG"

# --- 5) 필수 값이 없으면 렌더링이 실패해야 한다 ---
if "$HELM" template x "$CHART" -f "$CHART/values-train.yaml" >/dev/null 2>&1; then fail "train rendered without train.jobId"; fi
if "$HELM" template x "$CHART" -f "$CHART/values-infer.yaml" >/dev/null 2>&1; then fail "infer rendered without infer.modelJobId"; fi
log "PASS: missing train.jobId / infer.modelJobId are rejected"

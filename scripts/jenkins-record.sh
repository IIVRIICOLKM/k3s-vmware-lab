#!/usr/bin/env bash
# Writes the CI result (image tag, commit, digests) to a JSON file and, inside the cluster, to a ConfigMap, so the next step
# (Argo CD hand-off) can read what the pipeline built. Called by the Jenkinsfile after the images are pushed.
# Usage: scripts/jenkins-record.sh --tag T --commit C --source git|configmap --build N --build-url U --out FILE
#                                  --image <name>=<sha256:digest> [--image ...] [--configmap NAME]
#
# [한국어 설명] 파이프라인이 만든 결과를 한곳에 남긴다. Argo CD 연동("CICD_연결")이 이 값을 읽는다.
#   남기는 값: 태그(tag), 커밋(commit), 소스 종류(source: git 또는 configmap), 빌드 번호·주소, 시각(UTC),
#              이미지마다 이름·전체 주소(<레지스트리>/<이름>:<태그>)·digest
#   - --out 파일: JSON 한 개 (Jenkins 빌드 산출물 ci-result.json으로 보관된다)
#   - --configmap 이름: 에이전트 파드 안에서만 쓴다. 서비스 어카운트 토큰으로 쿠버네티스 API를 불러 같은 네임스페이스(ci)의
#     ConfigMap을 만들거나 덮어쓴다. 키: tag, commit, source, built_at, build, build_url, <이미지>.digest, <이미지>.ref, result.json
#     ConfigMap 기록이 실패하면 스크립트도 실패한다 (결과를 못 남겼는데 성공으로 보이지 않게).
#   - 모든 값은 정해진 모양(정규식)만 받는다: JSON과 YAML에 그대로 들어가므로 따옴표·공백이 들어올 수 없게 한다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail

# --- 1) 도움말과 상수 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help || $# -eq 0 ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit $(($# == 0 ? 1 : 0))
fi
REGISTRY="registry.k3slab.local:5000"
# 서비스 어카운트 폴더와 API 주소는 환경변수로 바꿀 수 있다 (가짜 API 서버로 시험할 때만 쓴다)
SA_DIR=${SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}
K8S_API=${K8S_API:-https://kubernetes.default.svc}

# fail 메시지 : 오류를 출력하고 종료
fail() { echo "jenkins-record: $*" >&2; exit 1; }

# --- 2) 인자 읽기와 검사 ---
TAG="" COMMIT="" SOURCE="" BUILD="" BUILD_URL="" OUT="" CONFIGMAP=""
IMAGES=()
while (($# > 0)); do
  case "$1" in
    --tag) TAG=${2:-}; shift 2 ;;
    --commit) COMMIT=${2:-}; shift 2 ;;
    --source) SOURCE=${2:-}; shift 2 ;;
    --build) BUILD=${2:-}; shift 2 ;;
    --build-url) BUILD_URL=${2:-}; shift 2 ;;
    --out) OUT=${2:-}; shift 2 ;;
    --image) IMAGES+=("${2:-}"); shift 2 ;;
    --configmap) CONFIGMAP=${2:-}; shift 2 ;;
    *) fail "unknown argument '$1'" ;;
  esac
done
[[ "$TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || fail "invalid --tag '$TAG'"
[[ "$COMMIT" =~ ^([0-9a-f]{40}|none)$ ]] || fail "invalid --commit '$COMMIT' (40 hex characters or 'none')"
[[ "$SOURCE" == git || "$SOURCE" == configmap ]] || fail "--source must be git or configmap"
[[ "$BUILD" =~ ^[0-9]{1,9}$ ]] || fail "invalid --build '$BUILD'"
[[ "$BUILD_URL" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || fail "invalid --build-url '$BUILD_URL'"
[[ -n "$OUT" ]] || fail "--out is required"
((${#IMAGES[@]} > 0)) || fail "at least one --image is required"
[[ -z "$CONFIGMAP" || "$CONFIGMAP" =~ ^[a-z0-9]([a-z0-9.-]{0,60}[a-z0-9])?$ ]] || fail "invalid --configmap name '$CONFIGMAP'"
# 이미지 인자: 이름=digest. 이름은 레지스트리 규칙, digest는 sha256:<64자리 16진수>
declare -A DIGEST=()
for pair in "${IMAGES[@]}"; do
  name=${pair%%=*}
  digest=${pair#*=}
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "invalid image name in '$pair'"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid digest in '$pair'"
  DIGEST[$name]=$digest
done
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- 3) JSON 파일 ---
# 이미지 이름순으로 정렬해 같은 입력이면 같은 출력이 되게 한다
mapfile -t NAMES < <(printf '%s\n' "${!DIGEST[@]}" | sort)
json_images=""
for name in "${NAMES[@]}"; do
  json_images+="${json_images:+,}{\"name\":\"$name\",\"ref\":\"$REGISTRY/$name:$TAG\",\"digest\":\"${DIGEST[$name]}\"}"
done
JSON="{\"tag\":\"$TAG\",\"commit\":\"$COMMIT\",\"source\":\"$SOURCE\",\"build\":$BUILD,\"build_url\":\"$BUILD_URL\",\"built_at\":\"$BUILT_AT\",\"images\":[$json_images]}"
printf '%s\n' "$JSON" >"$OUT"
echo "jenkins-record: wrote $OUT"
echo "$JSON"

# --- 4) ConfigMap (클러스터 안에서만) ---
[[ -n "$CONFIGMAP" ]] || exit 0
[[ -r "$SA_DIR/token" ]] || fail "--configmap needs the pod's service account token ($SA_DIR/token)"
NS=$(<"$SA_DIR/namespace")
API="$K8S_API/api/v1/namespaces/$NS/configmaps"
# data 항목: 값은 모두 따옴표로 감싼 문자열. result.json은 JSON 문자열 안의 따옴표를 \" 로 바꿔 넣는다.
data="\"tag\":\"$TAG\",\"commit\":\"$COMMIT\",\"source\":\"$SOURCE\",\"built_at\":\"$BUILT_AT\",\"build\":\"$BUILD\",\"build_url\":\"$BUILD_URL\""
for name in "${NAMES[@]}"; do
  data+=",\"$name.digest\":\"${DIGEST[$name]}\",\"$name.ref\":\"$REGISTRY/$name:$TAG\""
done
data+=",\"result.json\":\"${JSON//\"/\\\"}\""
body="{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"$CONFIGMAP\",\"namespace\":\"$NS\",\"labels\":{\"app.kubernetes.io/managed-by\":\"jenkins\",\"k3slab.io/ci-result\":\"true\"}},\"data\":{$data}}"
# api METHOD URL : 서비스 어카운트 토큰으로 API 호출 (클러스터 CA를 검증한다). 응답 상태 코드를 출력한다.
api() {
  curl -sS -m 20 -o /tmp/jenkins-record-reply.json -w '%{http_code}' --cacert "$SA_DIR/ca.crt" \
    -H "Authorization: Bearer $(<"$SA_DIR/token")" -H 'Content-Type: application/json' -X "$1" --data-binary "$body" "$2"
}
# 먼저 PUT(덮어쓰기). 404면 아직 없는 것이라 POST(새로 만들기). 둘 다 API에 닿지 못하면 실패한다.
code=$(api PUT "$API/$CONFIGMAP") || fail "cannot reach the Kubernetes API at $K8S_API"
if [[ "$code" == 404 ]]; then code=$(api POST "$API") || fail "cannot reach the Kubernetes API at $K8S_API"; fi
[[ "$code" == 200 || "$code" == 201 ]] || { cat /tmp/jenkins-record-reply.json >&2; fail "ConfigMap $NS/$CONFIGMAP was not written (HTTP $code)"; }
echo "jenkins-record: ConfigMap $NS/$CONFIGMAP updated (HTTP $code)"

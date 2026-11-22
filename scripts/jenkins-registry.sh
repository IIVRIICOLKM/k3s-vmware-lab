#!/usr/bin/env bash
# Asks the in-cluster registry (infra/k8s/registry.yaml) about an image tag. Used by the Jenkinsfile (image stage) and by hand.
# Usage: scripts/jenkins-registry.sh digest <image-name> <tag>   prints sha256:... when the tag exists, nothing when it does not
#        scripts/jenkins-registry.sh tags <image-name>           prints the tags of an image, one per line
# Environment: REGISTRY_URL (default http://10.43.0.50:5000, the fixed ClusterIP, reachable from pods and from cluster nodes)
#
# [한국어 설명] 클러스터 안 레지스트리에 이미지 태그가 있는지, digest가 무엇인지 묻는다.
#   - digest: 매니페스트를 HEAD로 요청해 Docker-Content-Digest 헤더를 읽는다. 태그가 없으면(404) 아무것도 출력하지 않고 성공(0)으로 끝난다.
#     레지스트리에 닿지 않거나 404/200이 아닌 응답이면 실패(1)다 — "없음"과 "알 수 없음"을 섞지 않는다.
#   - tags: 이미지의 태그 목록. 이 스크립트는 curl만 쓴다 (에이전트 파드의 gcc 이미지에 있다).
#   - 이미지 태그는 덮어쓰지 않는 규칙(scripts/image-build.sh와 같음)을 파이프라인이 지키는 데 쓴다:
#     태그가 이미 있으면 다시 빌드하지 않고 이 digest를 그대로 쓴다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail

# --- 1) 도움말과 인자 검사 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help || $# -lt 2 ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit $(($# < 2 ? 1 : 0))
fi
REGISTRY_URL=${REGISTRY_URL:-http://10.43.0.50:5000}
CMD=$1
NAME=$2
# 이미지 이름과 태그는 scripts/image-build.sh와 같은 규칙 (URL에 그대로 들어가므로 안전한 문자만)
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "invalid image name '$NAME'" >&2; exit 2; }

# --- 2) digest: 매니페스트 HEAD ---
# 헤더 파일에서 상태 코드와 Docker-Content-Digest를 읽는다 (헤더 이름은 대소문자를 가리지 않는다)
digest() {
  local tag=$1 headers code
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] || { echo "invalid tag '$tag'" >&2; exit 2; }
  headers=$(mktemp)
  code=$(curl -sS -m 10 -I -o "$headers" -w '%{http_code}' \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "$REGISTRY_URL/v2/$NAME/manifests/$tag") || { rm -f "$headers"; echo "registry $REGISTRY_URL is not reachable" >&2; exit 1; }
  case "$code" in
    200) tr -d '\r' <"$headers" | awk 'tolower($1) == "docker-content-digest:" {print $2}' | head -1 ;;
    404) : ;; # 태그가 없다 → 출력 없음
    *) rm -f "$headers"; echo "registry answered HTTP $code for $NAME:$tag" >&2; exit 1 ;;
  esac
  rm -f "$headers"
}

# --- 3) 명령 분기 ---
case "$CMD" in
  digest)
    (($# == 3)) || { echo "usage: digest <image-name> <tag>" >&2; exit 2; }
    digest "$3"
    ;;
  tags)
    # 이미지가 아직 없으면(404) 빈 목록. -f 없이 상태 코드로 구분한다.
    body=$(mktemp)
    code=$(curl -sS -m 10 -o "$body" -w '%{http_code}' "$REGISTRY_URL/v2/$NAME/tags/list") || { rm -f "$body"; echo "registry $REGISTRY_URL is not reachable" >&2; exit 1; }
    case "$code" in
      200) tr -d '\n ' <"$body" | sed -n 's/.*"tags":\[\([^]]*\)\].*/\1/p' | tr ',' '\n' | tr -d '"' ;;
      404) : ;;
      *) rm -f "$body"; echo "registry answered HTTP $code" >&2; exit 1 ;;
    esac
    rm -f "$body"
    ;;
  *)
    echo "unknown command '$CMD' (digest or tags)" >&2
    exit 2
    ;;
esac

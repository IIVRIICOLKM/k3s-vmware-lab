#!/usr/bin/env bash
# Writes a new image tag into the GitOps values file of the lab Git server (Gitea), commits it and pushes it to main.
# Argo CD watches that file, so this one commit is what "deploys" a Jenkins build. Called by the Jenkinsfile (stage "배포 값").
# Usage: GITEA_USER=... GITEA_TOKEN=... scripts/cicd-set-tag.sh --repo URL --tag git-<sha7> --commit <40 hex> --digest sha256:<64 hex>
#          --build N --build-url URL [--file charts/k3slab-workload/values-infer-argocd.yaml] [--branch main]
#
# [한국어 설명] Jenkins가 새 이미지를 만들고 나면, 배포 값 파일(values-infer-argocd.yaml)의 image.tag 한 줄을 새 태그로 바꿔
#   Gitea 저장소 main에 커밋·push한다. Argo CD가 이 파일을 보고 있어서 이 커밋 하나가 곧 배포다 (infra/k8s/jenkins/README.md "코드 변경에서 배포까지").
#   - 인증: 환경변수 GITEA_USER, GITEA_TOKEN(Jenkins 자격증명 gitea-ci). 명령줄·로그에 남기지 않고 git 프로세스의 환경변수(HTTP 헤더)로만 넘긴다.
#     이 계정은 이 저장소에만 쓰기 권한이 있다 (scripts/argocd-source.sh ci-init).
#   - 태그는 git-<커밋 7자리>만 받는다. 시험용 src-<해시> 태그는 배포용이 아니라서 거부한다.
#   - 파일에서 바꾸는 것은 `  tag: ` 로 시작하는 줄 하나뿐이다. 그 줄이 하나가 아니거나, 바뀐 줄이 정확히 한 줄이 아니면 중단한다.
#   - 이미 같은 태그면 아무것도 하지 않고 성공한다 (같은 커밋을 다시 빌드한 경우).
#   - 커밋 메시지에 [skip ci]를 넣고 작성자는 k3slab ci다. 이 커밋이 다시 빌드를 만들지 않게 Jenkinsfile의 소스 단계가 HEAD가 (a) 이 작성자
#     (b) [skip ci]가 있는 (c) 이 파일만 바뀐 커밋이면 빌드를 건너뛴다(NOT_BUILT). 이유는 infra/k8s/jenkins/README.md "고리 막기"에 있다.
#   - main이 빌드한 커밋(--commit)에서 움직였으면(그 사이 사람이 새 커밋을 올림) 태그 커밋을 만들지 않고 종료 코드 3으로 끝낸다.
#     봇 커밋이 항상 "빌드한 커밋 바로 위"에 올라가야, 새 커밋이 봇 커밋 밑에 묻혀 빌드되지 않는 일이 없다. 새 커밋은 자기 빌드를 받는다.
#   - push가 거절되면(확인 직후에 새 커밋이 올라옴) 다시 확인한다(최대 3번).
#   - 성공하면 표준 출력 마지막 줄에 "tag-commit <커밋 번호>"를 남긴다.
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail

# --- 1) 도움말과 인자 ---
# sed -n '2,5s/^# \{0,1\}//p' "$0" : 이 파일 2~5번째 줄(영문 설명)을 도움말로 출력
if [[ "${1:-}" == -h || "${1:-}" == --help || $# -eq 0 ]]; then
  sed -n '2,5s/^# \{0,1\}//p' "$0"
  exit $(($# == 0 ? 1 : 0))
fi
# fail 메시지 : 오류를 출력하고 종료
fail() { echo "cicd-set-tag: $*" >&2; exit 1; }

REPO="" TAG="" COMMIT="" DIGEST="" BUILD="" BUILD_URL="" FILE="charts/k3slab-workload/values-infer-argocd.yaml" BRANCH="main"
while (($# > 0)); do
  case "$1" in
    --repo) REPO=${2:-}; shift 2 ;;
    --tag) TAG=${2:-}; shift 2 ;;
    --commit) COMMIT=${2:-}; shift 2 ;;
    --digest) DIGEST=${2:-}; shift 2 ;;
    --build) BUILD=${2:-}; shift 2 ;;
    --build-url) BUILD_URL=${2:-}; shift 2 ;;
    --file) FILE=${2:-}; shift 2 ;;
    --branch) BRANCH=${2:-}; shift 2 ;;
    *) fail "unknown argument '$1'" ;;
  esac
done
# 모든 값은 정해진 모양만 받는다 (커밋 메시지와 sed 식에 그대로 들어가므로 따옴표·공백·| 가 들어올 수 없게)
[[ "$TAG" =~ ^git-[0-9a-f]{7}$ ]] || fail "invalid --tag '$TAG' (only git-<7 hex>; src- tags are for tests and are never deployed)"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid --commit '$COMMIT'"
[[ "${COMMIT:0:7}" == "${TAG#git-}" ]] || fail "tag $TAG does not match commit $COMMIT"
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid --digest '$DIGEST'"
[[ "$BUILD" =~ ^[0-9]{1,9}$ ]] || fail "invalid --build '$BUILD'"
[[ "$BUILD_URL" =~ ^https?://[A-Za-z0-9._:/-]+$ ]] || fail "invalid --build-url '$BUILD_URL'"
[[ "$FILE" =~ ^[A-Za-z0-9._/-]+$ && "$FILE" != /* && "$FILE" != *..* ]] || fail "invalid --file '$FILE'"
[[ "$BRANCH" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid --branch '$BRANCH'"
if [[ "$REPO" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+\.git$ ]]; then
  : # 운영: 클러스터 안 Gitea 주소
elif [[ "${CICD_SET_TAG_ALLOW_FILE:-}" == 1 && "$REPO" =~ ^file:///[A-Za-z0-9._/-]+$ ]]; then
  : # 시험용: 로컬 bare 저장소 (CICD_SET_TAG_ALLOW_FILE=1일 때만)
else
  fail "invalid --repo '$REPO'"
fi

# --- 2) git 준비: 인증은 HTTP 헤더로 (git 프로세스의 환경변수에만 있다) ---
AUTHOR_NAME="k3slab ci"
AUTHOR_EMAIL="ci@k3slab.local"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# g [git 인자...] : git 실행. 토큰이 있으면 Authorization 헤더를 붙인다 (명령줄에 남지 않음, 프롬프트 없음)
g() {
  if [[ -n "${GITEA_TOKEN:-}" ]]; then
    local auth
    auth=$(printf '%s:%s' "${GITEA_USER:?GITEA_USER is required with GITEA_TOKEN}" "$GITEA_TOKEN" | base64 -w0)
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraHeader GIT_CONFIG_VALUE_0="Authorization: Basic $auth" \
      git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" -c credential.helper= -c advice.detachedHead=false "$@"
  else
    GIT_TERMINAL_PROMPT=0 git -c user.name="$AUTHOR_NAME" -c user.email="$AUTHOR_EMAIL" -c advice.detachedHead=false "$@"
  fi
}

# --- 3) 태그를 바꿔 커밋하고 push (거절되면 최신 main 위에서 다시) ---
MSG="ci: deploy infer-worker $TAG [skip ci]

source commit: $COMMIT
image: registry.k3slab.local:5000/infer-worker:$TAG
digest: $DIGEST
jenkins build: #$BUILD $BUILD_URL"
for attempt in 1 2 3; do
  rm -rf "$WORK/repo"
  g clone -q --depth 1 --branch "$BRANCH" "$REPO" "$WORK/repo" || fail "cannot clone $REPO ($BRANCH)"
  # main이 빌드한 커밋에서 움직였는지: 빌드한 커밋이 지금 main의 맨 위가 아니면 태그 커밋을 만들지 않는다
  head_sha=$(g -C "$WORK/repo" rev-parse HEAD)
  if [[ "$head_sha" != "$COMMIT" ]]; then
    echo "cicd-set-tag: $BRANCH is at ${head_sha:0:7}, not at the built commit ${COMMIT:0:7}; no tag commit (the newer commit gets its own build)"
    echo "tag-commit none"
    exit 3
  fi
  [[ -f "$WORK/repo/$FILE" ]] || fail "no file $FILE in the repository"
  # 바꿀 줄은 정확히 하나여야 한다 (이 파일에서 "  tag: "로 시작하는 줄은 image.tag뿐이다)
  [[ "$(grep -c '^  tag: ' "$WORK/repo/$FILE")" == 1 ]] || fail "$FILE must have exactly one line starting with '  tag: '"
  current=$(sed -n 's/^  tag: //p' "$WORK/repo/$FILE")
  if [[ "$current" == "$TAG" ]]; then
    echo "cicd-set-tag: $FILE already has tag $TAG; nothing to commit"
    echo "tag-commit $(g -C "$WORK/repo" rev-parse HEAD)"
    exit 0
  fi
  sed -E -i "s|^  tag: .*|  tag: $TAG|" "$WORK/repo/$FILE"
  # 바뀐 것이 정확히 한 줄(추가 1, 삭제 1)인지 확인한다
  stat=$(g -C "$WORK/repo" diff --numstat -- "$FILE" | awk '{print $1 "/" $2}')
  [[ "$stat" == "1/1" ]] || fail "expected a one-line change in $FILE, got '${stat:-none}'"
  g -C "$WORK/repo" add -- "$FILE"
  g -C "$WORK/repo" commit -q -m "$MSG"
  if g -C "$WORK/repo" push -q origin "HEAD:refs/heads/$BRANCH"; then
    sha=$(g -C "$WORK/repo" rev-parse HEAD)
    echo "cicd-set-tag: $FILE tag $current -> $TAG (attempt $attempt)"
    echo "tag-commit $sha"
    exit 0
  fi
  echo "cicd-set-tag: push was rejected (attempt $attempt); trying again on the latest $BRANCH" >&2
  sleep 2
done
fail "could not push the tag commit after 3 attempts"

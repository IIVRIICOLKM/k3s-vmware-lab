#!/usr/bin/env bash
# Runs the CI pipeline (Jenkinsfile) on the cluster's Jenkins and waits for the result.
# Default: ships this working tree to Jenkins as a ConfigMap snapshot (ci-source-<hash>) and runs the test job k3slab-ci-local
# with the same Jenkinsfile; --git runs the production job k3slab-ci instead (main of the in-cluster Gitea; the job also polls it every minute
# and, when the checks pass, commits the new image tag for Argo CD). The snapshot mode tests a working tree before it is pushed anywhere and
# never deploys (its tags are src-<hash>).
# Usage: scripts/jenkins-run.sh [--source-dir DIR] [--images LIST] [--no-images] [--out FILE] [--no-wait]   (snapshot of DIR, default: this repo)
#        scripts/jenkins-run.sh --git [--images LIST] [--no-images] [--out FILE] [--no-wait]               (Gitea main, job k3slab-ci)
#
# [한국어 설명] Jenkins에서 파이프라인(저장소 최상위 Jenkinsfile)을 한 번 돌리고 끝날 때까지 기다린다.
#   소스를 넣는 방법 두 가지:
#     기본      이 작업 폴더의 스냅샷을 ConfigMap(ci-source-<해시 12자리>)으로 올리고 시험용 작업 k3slab-ci-local을 돌린다.
#               push하기 전의 작업 폴더 상태를 그대로 시험하려고 만든 방법이다 (scripts/image-build.sh가 빌드 폴더를
#               ConfigMap으로 넘기는 것과 같은 생각). 작업 정의는 이 폴더의 Jenkinsfile 내용을 그대로 넣어 만든다 → 시험하는 파이프라인 = 운영 파이프라인.
#               스냅샷 = git이 아는 파일(추적 + 새 파일 중 .gitignore에 걸리지 않는 것). 비밀 파일(*.env 등)은 .gitignore라서 들어가지 않는다.
#     --git     운영 작업 k3slab-ci를 돌린다 (클러스터 안 Gitea main을 체크아웃). 작업은 Helm 설치 때 JCasC로 만들어져 있다.
#               이 작업은 1분마다 Gitea를 폴링하고, 검사와 이미지가 모두 성공하면 새 태그를 배포 값에 커밋한다(Argo CD가 배포). 수동 실행도 마찬가지다.
#   --source-dir DIR  다른 폴더의 스냅샷을 쓴다 (실패 시나리오: 일부러 고장 낸 임시 사본). DIR이 git 저장소가 아니면 파일 전체에서 .env·.git 등을 뺀다.
#   --images LIST     빌드할 이미지 (쉼표로 구분, 기본 infer-worker,train-worker)    --no-images  검사만 하고 이미지는 만들지 않는다
#   --out FILE        결과를 JSON으로 남긴다 (빌드 번호, 결과, 태그, 로그 경로, 산출물 ci-result.json의 내용)
#   --no-wait         빌드를 시작만 하고 끝나지 않아도 돌아온다
#   Jenkins 접속: 컨트롤러 파드(jenkins-0)에 kubectl exec로 들어가 파드 안의 관리자 계정 파일로 curl을 부른다 (호스트에 비밀번호가 나오지 않는다).
#     클러스터 없이 이 스크립트를 점검할 때만 JENKINS_DIRECT=<주소> JENKINS_USER JENKINS_PASSWORD 로 호스트에서 바로 접속한다.
#   종료 코드: 0 빌드 SUCCESS, 1 FAILURE/ABORTED/UNSTABLE, 2 사용법·접속 오류, 3 --no-wait
#
# 엄격 모드: -e 명령이 실패하면 즉시 종료 · -u 정의 안 된 변수를 쓰면 에러 · -o pipefail 파이프(a | b) 중간 실패도 실패로 처리
set -euo pipefail
# 공통 변수·함수(scripts/lib/common.sh) 불러오기. $(dirname "$0") = 이 스크립트가 있는 폴더(scripts/)
source "$(dirname "$0")/lib/common.sh"

# --- 1) 인자 ---
# sed -n '2,8s/^# \{0,1\}//p' "$0" : 이 파일 2~8번째 줄(영문 설명)을 도움말로 출력
usage() {
  sed -n '2,8s/^# \{0,1\}//p' "$0"
  exit "${1:-0}"
}
MODE=local SOURCE_DIR="$REPO_ROOT" IMAGES="infer-worker,train-worker" BUILD_IMAGES=true OUT="" WAIT=true
while (($# > 0)); do
  case "$1" in
    -h | --help) usage 0 ;;
    --git) MODE=git; shift ;;
    --source-dir) SOURCE_DIR=${2:-}; shift 2 ;;
    --images) IMAGES=${2:-}; shift 2 ;;
    --no-images) BUILD_IMAGES=false; shift ;;
    --out) OUT=${2:-}; shift 2 ;;
    --no-wait) WAIT=false; shift ;;
    *) usage 2 ;;
  esac
done
[[ -d "$SOURCE_DIR" ]] || die "--source-dir $SOURCE_DIR is not a directory"
SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)
[[ "$IMAGES" =~ ^[a-z0-9,-]+$ ]] || die "--images must be a comma separated list of image names"
[[ -f "$SOURCE_DIR/Jenkinsfile" ]] || die "$SOURCE_DIR has no Jenkinsfile"

# --- 2) 상수와 도구 함수 ---
NS="ci"
KUBECONFIG_FILE="$LAB_SECRETS_DIR/kubeconfig"
LOCAL_JOB="k3slab-ci-local"
GIT_JOB="k3slab-ci"
JOB=$LOCAL_JOB
[[ "$MODE" == git ]] && JOB=$GIT_JOB
KEEP_SOURCES=5 # 남겨 둘 ci-source ConfigMap 개수 (오래된 것부터 지운다)
mkdir -p "$LAB_LOG_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# k [kubectl 인자...] : 이 클러스터용 kubectl (K3S_CONFIG_FILE=/dev/null은 k3s 링크의 권한 경고 제거)
k() { K3S_CONFIG_FILE=/dev/null KUBECONFIG="$KUBECONFIG_FILE" kubectl "$@"; }
# jcurl 경로 [curl 인자...] : Jenkins REST API 호출. CSRF 토큰(crumb)을 먼저 받아 붙인다. 본문은 표준입력으로 받을 수 있다.
#   기본: 컨트롤러 파드 안에서 실행 (파드의 관리자 계정 파일을 읽는다)
#   JENKINS_DIRECT가 있으면 호스트에서 바로 (시험용)
jcurl() {
  local path=$1 stdin=/dev/null a
  shift
  # 본문을 표준입력으로 받는 호출(@-)만 stdin을 연결한다. 그 밖에는 kubectl exec -i가 이 스크립트의 입력을 먹지 않게 /dev/null.
  for a in "$@"; do [[ "$a" == @- ]] && stdin=/dev/stdin; done
  if [[ -n "${JENKINS_DIRECT:-}" ]]; then
    local cookie="$WORK/cookie" crumb
    crumb=$(curl -sS -g -u "$JENKINS_USER:$JENKINS_PASSWORD" -c "$cookie" "$JENKINS_DIRECT/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
    curl -sS -g -u "$JENKINS_USER:$JENKINS_PASSWORD" -b "$cookie" -H "$crumb" "$JENKINS_DIRECT$path" "$@" <"$stdin"
  else
    k -n "$NS" exec -i jenkins-0 -c jenkins -- sh -c '
      U=$(cat /run/secrets/additional/chart-admin-username); P=$(cat /run/secrets/additional/chart-admin-password)
      path=$1; shift
      crumb=$(curl -sS -g -u "$U:$P" -c /tmp/jx-cookie "http://localhost:8080/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)")
      exec curl -sS -g -u "$U:$P" -b /tmp/jx-cookie -H "$crumb" "http://localhost:8080$path" "$@"
    ' sh "$path" "$@" <"$stdin"
  fi
}
# status 경로 : HTTP 상태 코드만 (본문 버림)
status() { jcurl "$1" -o /dev/null -w '%{http_code}'; }

# --- 3) 준비 확인 ---
if [[ -z "${JENKINS_DIRECT:-}" ]]; then
  [[ -f "$KUBECONFIG_FILE" ]] || die "missing $KUBECONFIG_FILE (the cluster is not set up)"
  k -n "$NS" get statefulset jenkins >/dev/null 2>&1 || die "Jenkins is not installed in namespace $NS (scripts/jenkins-deploy.sh)"
  k -n "$NS" wait --for=condition=ready pod/jenkins-0 --timeout=120s >/dev/null || die "pod jenkins-0 is not ready"
fi
code=$(status /login) || die "cannot reach Jenkins"
[[ "$code" == 200 ]] || die "Jenkins answered HTTP $code on /login"

# --- 4) 소스 스냅샷 (기본 모드): tar.gz를 만들고 ConfigMap으로 올린다 ---
# 스냅샷 파일 목록: git이 아는 파일 중 이 저장소에서 CI가 쓰는 폴더(Jenkinsfile apps charts scripts infra tests). git 저장소가 아니면 find로 모으되 비밀·생성 파일을 뺀다.
# 만든 tar는 항상 같은 내용이면 같은 바이트다(정렬, 시각 0, 소유자 0, gzip -n) → 해시가 곧 소스의 이름이 된다.
snapshot() {
  local list="$WORK/files"
  if git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SOURCE_DIR" ls-files -z --cached --others --exclude-standard -- Jenkinsfile apps charts scripts infra tests >"$list.raw"
  else
    (cd "$SOURCE_DIR" && find Jenkinsfile apps charts scripts infra tests -type f -not -name '*.env' -not -path '*/.git/*' \
      -not -path '*/__pycache__/*' -not -name '*.o' -not -name '*.log' -print0 2>/dev/null) >"$list.raw"
  fi
  # 지워진 추적 파일은 건너뛴다
  : >"$list"
  while IFS= read -r -d '' f; do
    [[ -f "$SOURCE_DIR/$f" ]] && printf '%s\0' "$f" >>"$list"
  done <"$list.raw"
  tar -C "$SOURCE_DIR" --null -T "$list" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - | gzip -n -9 >"$WORK/source.tgz"
}
SOURCE_ID=""
if [[ "$MODE" == local ]]; then
  snapshot
  bytes=$(stat -c %s "$WORK/source.tgz")
  ((bytes <= 900000)) || die "source snapshot is $bytes bytes; a ConfigMap holds at most 1 MiB (keep it under 900 KB)"
  SOURCE_ID=$(sha256sum "$WORK/source.tgz" | cut -c1-12)
  log "source snapshot of ${SOURCE_DIR#"$REPO_ROOT"} -> ci-source-$SOURCE_ID ($bytes bytes, $(tar -tzf "$WORK/source.tgz" | wc -l) files)"
  if [[ -n "${JENKINS_DIRECT:-}" ]]; then
    # 점검용 경로: ConfigMap이 없다. 소스를 JENKINS_LOCAL_SOURCE에 복사해 두고 호출한 쪽이 그 경로를 쓴다.
    [[ -n "${JENKINS_LOCAL_SOURCE:-}" ]] && cp "$WORK/source.tgz" "$JENKINS_LOCAL_SOURCE"
  else
    # ConfigMap 이름이 내용 해시(ci-source-<해시>)라서 같은 이름이면 내용도 같다 → 이미 있으면 건너뛰고, 없으면 kubectl create로 만든다.
    #   kubectl apply를 쓰지 않는 이유: apply는 객체 전체를 last-applied-configuration annotation에 복사하는데, 스냅샷이 커지면(압축 약 190KB 넘음)
    #   annotation 한도 256KB를 넘어 "metadata.annotations: Too long"으로 실패한다. create는 그 annotation을 만들지 않는다.
    #   ConfigMap 자체의 한도 1MiB는 위의 900KB 검사가 지킨다.
    if k -n "$NS" get configmap "ci-source-$SOURCE_ID" >/dev/null 2>&1; then
      log "ConfigMap ci-source-$SOURCE_ID already exists (same content, same hash); not creating it again"
    else
      k -n "$NS" create configmap "ci-source-$SOURCE_ID" --from-file=source.tgz="$WORK/source.tgz" --dry-run=client -o yaml |
        k -n "$NS" label --local -f - k3slab.io/ci-source=true -o yaml | k create -f - >/dev/null
    fi
    # 오래된 스냅샷 정리: 만든 시각 순으로 KEEP_SOURCES개만 남긴다. 방금 쓸 스냅샷은 (재사용해서 오래된 것이라도) 지우지 않는다.
    mapfile -t old < <(k -n "$NS" get configmap -l k3slab.io/ci-source=true --sort-by=.metadata.creationTimestamp -o name | head -n -"$KEEP_SOURCES" |
      grep -vx "configmap/ci-source-$SOURCE_ID" || true)
    ((${#old[@]} == 0)) || k -n "$NS" delete "${old[@]}" >/dev/null
  fi

  # --- 5) 시험용 작업 정의: 이 폴더의 Jenkinsfile 내용을 그대로 넣는다 (XML 특수문자만 바꿔 쓴다) ---
  escaped=$(sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$SOURCE_DIR/Jenkinsfile")
  cat >"$WORK/config.xml" <<XML
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>Test job: runs the Jenkinsfile of a working-tree snapshot (ConfigMap ci-source-&lt;id&gt;). Created by scripts/jenkins-run.sh. Production job: k3slab-ci.</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <jenkins.model.BuildDiscarderProperty>
      <strategy class="hudson.tasks.LogRotator">
        <daysToKeep>-1</daysToKeep>
        <numToKeep>20</numToKeep>
        <artifactDaysToKeep>-1</artifactDaysToKeep>
        <artifactNumToKeep>20</artifactNumToKeep>
      </strategy>
    </jenkins.model.BuildDiscarderProperty>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>SOURCE_ID</name>
          <defaultValue></defaultValue>
        </hudson.model.StringParameterDefinition>
        <hudson.model.BooleanParameterDefinition>
          <name>BUILD_IMAGES</name>
          <defaultValue>true</defaultValue>
        </hudson.model.BooleanParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>IMAGES</name>
          <defaultValue>infer-worker,train-worker</defaultValue>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script>$escaped</script>
    <sandbox>true</sandbox>
  </definition>
  <disabled>false</disabled>
</flow-definition>
XML
  # 한글이 들어 있으므로 charset=UTF-8이 꼭 필요하다: 없으면 Jenkins가 config.xml 갱신 때 본문을 Latin-1로 읽어 500 오류가 난다
  if [[ "$(status "/job/$LOCAL_JOB/api/json")" == 200 ]]; then
    reply=$(jcurl "/job/$LOCAL_JOB/config.xml" -X POST -H 'Content-Type: application/xml; charset=UTF-8' --data-binary @- -w '\nHTTP %{http_code}' <"$WORK/config.xml")
  else
    reply=$(jcurl "/createItem?name=$LOCAL_JOB" -X POST -H 'Content-Type: application/xml; charset=UTF-8' --data-binary @- -w '\nHTTP %{http_code}' <"$WORK/config.xml")
  fi
  [[ "$reply" == *"HTTP 200"* ]] || die "could not create or update job $LOCAL_JOB: $reply"
  log "job $LOCAL_JOB updated from ${SOURCE_DIR#"$REPO_ROOT"}/Jenkinsfile"
fi

# --- 6) 빌드 시작: 대기열 항목 → 빌드 번호 ---
[[ "$(status "/job/$JOB/api/json")" == 200 ]] || die "job $JOB does not exist"
if [[ "$MODE" == git ]]; then
  # 운영 작업은 파라미터 정의가 첫 실행 뒤에야 생긴다(선언형 Jenkinsfile의 parameters). 처음이면 파라미터 없이 시작한다.
  start_path="/job/$JOB/build"
  start_args=(-X POST)
  [[ "$(jcurl "/job/$JOB/api/json?tree=property[parameterDefinitions[name]]" | grep -c 'SOURCE_ID' || true)" -gt 0 ]] &&
    { start_path="/job/$JOB/buildWithParameters"; start_args=(-X POST --data-urlencode "IMAGES=$IMAGES" --data-urlencode "BUILD_IMAGES=$BUILD_IMAGES"); }
else
  start_path="/job/$JOB/buildWithParameters"
  start_args=(-X POST --data-urlencode "SOURCE_ID=$SOURCE_ID" --data-urlencode "IMAGES=$IMAGES" --data-urlencode "BUILD_IMAGES=$BUILD_IMAGES")
fi
headers=$(jcurl "$start_path" "${start_args[@]}" -D - -o /dev/null)
queue_url=$(tr -d '\r' <<<"$headers" | awk 'tolower($1) == "location:" {print $2}' | head -1)
[[ -n "$queue_url" ]] || die "Jenkins did not accept the build request: $(head -1 <<<"$headers")"
queue_id=$(sed -n 's|.*/queue/item/\([0-9]*\)/.*|\1|p' <<<"$queue_url")
BUILD=""
for _ in $(seq 120); do
  BUILD=$(jcurl "/queue/item/$queue_id/api/json?tree=executable[number]" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')
  [[ -n "$BUILD" ]] && break
  sleep 2
done
[[ -n "$BUILD" ]] || die "build did not leave the queue within 4 minutes (is an earlier build still running?)"
log "started $JOB #$BUILD (source: ${SOURCE_ID:-git main}, images: $([[ "$BUILD_IMAGES" == true ]] && echo "$IMAGES" || echo none))"
if [[ "$WAIT" == false ]]; then
  [[ -z "$OUT" ]] || printf '{"job":"%s","build":%s,"result":"RUNNING","source_id":"%s"}\n' "$JOB" "$BUILD" "$SOURCE_ID" >"$OUT"
  exit 3
fi

# --- 7) 끝날 때까지 기다리며 로그를 이어서 보여 준다 ---
# progressiveText: start 위치부터의 로그를 준다. 응답 헤더 X-Text-Size = 다음 시작 위치, X-More-Data: true = 더 있음.
#   curl이 파드 안에서 돌 수 있으므로 파일 대신 -i로 헤더와 본문을 한 응답으로 받아 호스트에서 나눈다.
LOG="$LAB_LOG_DIR/jenkins-$JOB-$BUILD.log"
: >"$LOG"
offset=0
deadline=$((SECONDS + 5400))
while ((SECONDS < deadline)); do
  if jcurl "/job/$JOB/$BUILD/logText/progressiveText?start=$offset" -i >"$WORK/resp" 2>/dev/null && [[ -s "$WORK/resp" ]]; then
    awk '/^\r?$/ {exit} {print}' "$WORK/resp" | tr -d '\r' >"$WORK/h"
    # Jenkins가 로그에 숨겨 넣는 주석(ESC[8mha:////...ESC[0m)은 터미널에 글자로 보이므로 지운다
    awk 'h && /^\r?$/ {h = 0; next} !h {print}' h=1 "$WORK/resp" | sed -E 's/\x1b\[8mha:[^\x1b]*\x1b\[0m//g' | tee -a "$LOG"
    next=$(awk 'tolower($1) == "x-text-size:" {print $2}' "$WORK/h" | tail -1)
    [[ -z "$next" ]] || offset=$next
    grep -qi '^x-more-data: true' "$WORK/h" || break
  fi
  sleep 5
done
RESULT=""
for _ in $(seq 30); do
  RESULT=$(jcurl "/job/$JOB/$BUILD/api/json?tree=result" | sed -n 's/.*"result":"\([A-Z]*\)".*/\1/p')
  [[ -n "$RESULT" ]] && break
  sleep 2
done
RESULT=${RESULT:-UNKNOWN}
TAG=$(jcurl "/job/$JOB/$BUILD/api/json?tree=description" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')
ARTIFACT=$(jcurl "/job/$JOB/$BUILD/artifact/ci-result.json" 2>/dev/null | grep -m1 '^{' || true)
log "$JOB #$BUILD finished: $RESULT (tag: ${TAG:-none}); console log: $LOG"
if [[ -n "$OUT" ]]; then
  printf '{"job":"%s","build":%s,"result":"%s","tag":"%s","source_id":"%s","log":"%s","ci_result":%s}\n' \
    "$JOB" "$BUILD" "$RESULT" "$TAG" "$SOURCE_ID" "$LOG" "${ARTIFACT:-null}" >"$OUT"
fi
[[ "$RESULT" == SUCCESS ]]

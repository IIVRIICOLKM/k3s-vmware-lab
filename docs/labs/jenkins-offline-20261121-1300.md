# Jenkins CI 클러스터 없이 하는 검증 (2026-11-21 13:00)

클러스터가 꺼져 있는 동안 할 수 있는 것을 모두 확인한 기록이다. 클러스터 위 검증(배포, 파드 에이전트, Kaniko, 레지스트리)은 승인 뒤에 `scripts/jenkins-ci-test.sh`가 하고 `docs/labs/jenkins-ci-*.md`에 남긴다.
설계와 고른 이유는 `infra/k8s/jenkins/README.md`에 있다.

## 1. 한 줄 요약

| 항목 | 결과 | 근거 |
|---|---|---|
| Python 단위 시험 (`tests/train`, 저장소 최상위) | **37개 통과** (train 17, datasets 12, jobdb 8) | `scripts/jenkins-stage-python.sh` |
| C++ 빌드와 실행 검사 (`make CUDA=0`) | 통과 (빌드 약 10초) | `scripts/jenkins-stage-cpp.sh` |
| 쉘 (`bash -n`, ShellCheck 0.11.0) | 통과 (스크립트 32개, warning 이상 0건) | `scripts/jenkins-stage-shell.sh` |
| Helm (`helm lint`, `helm template`) | 통과 (학습 Job, 추론 Deployment + Service) | `scripts/jenkins-stage-helm.sh` |
| Jenkins 차트 `--render` | 통과 (해시 일치, lint, template) | `scripts/jenkins-deploy.sh --render` |
| 파이프라인 전체 (Jenkins 2.580.2 + 고정 플러그인, 에이전트·Kaniko는 대역) | 성공 1회, 같은 소스 재실행, 실패 6종 | 3절 |

## 2. 쓴 환경과 한계

- 단위 시험: Python 3.12.4, torch 2.14.1+cpu, numpy 2.5.5 (학습 이미지와 같은 torch 버전, CPU판).
- 파이프라인 시험: 이 컴퓨터에서 Jenkins `2.580.2` (고정한 컨트롤러와 같은 LTS)와 `values.yaml`의 플러그인 7개(같은 버전)를 띄우고, 차트가 만드는 JCasC 파일을 그대로 읽혔다.
  JCasC가 오류 없이 읽혔고(관리자 계정, 익명 거부 403, Kubernetes 클라우드, job-dsl로 만든 `k3slab-ci`, SCM 폴링 5분), `k3slab-ci`는 GitHub `develop`에서 `Jenkinsfile`을 찾지 못해 실패했다. 이는 예상한 결과다. 같은 저장소를 인증 없이 읽었다는 뜻이기도 하다.
- 이 시험은 클러스터 부분을 **대역으로 바꿨다**. 같은 Jenkinsfile에서 아래만 바꿨다 (`agent { kubernetes … }` → `agent any`, `container()` 단계는 그냥 실행, `/kaniko/executor` → 인자만 읽고 가짜 레지스트리에 등록하는 스크립트, ConfigMap 마운트 → 로컬 tar 경로).
  - 시험하지 못한 것: 쿠버네티스 에이전트 파드가 실제로 뜨는지(파드 정의 YAML의 파싱과 구조는 확인), `container('kaniko')`의 셸, 실제 Kaniko 빌드와 push, 컨트롤러 파드 안 `curl`(`jenkins-run.sh`의 `kubectl exec` 경로), `jenkins-ci-test.sh` 전체.
  - 로컬 Jenkins의 의존 플러그인은 `jenkins-plugin-manager` 기본값(최신)으로 받았다. 클러스터는 `installLatestPlugins: false`(최소 요구 버전)이므로 의존 플러그인 버전이 다를 수 있다.
- 쉘 검사는 ShellCheck v0.11.0을 GitHub 릴리스에서 받아 SHA-256 `8c3be12b…c227198`을 확인하고 썼다.

## 3. 파이프라인 시험 (로컬 Jenkins)

모두 `scripts/jenkins-run.sh`로 작업 폴더 스냅샷(ConfigMap 대신 로컬 tar)을 넣어 돌렸다. 스냅샷은 약 138KB(파일 110개, 시험을 `tests/train`으로 옮긴 뒤 113개)다.

| 시나리오 | 만든 방법 | 결과 | 멈춘 단계 | 이미지 단계 |
|---|---|---|---|---|
| 성공 | 그대로 | SUCCESS | – | 이미지 2개 빌드(대역), 결과 기록 |
| 같은 소스 다시 | 위와 같은 스냅샷 | SUCCESS | – | `infer-worker:src-… already exists … not building it again`, 같은 digest |
| Python 문법 오류 | `train.py` 끝에 `def broken(:` | FAILURE | Python: `py_compile found a syntax error` | **건너뜀** (`Stage "이미지" skipped due to earlier failure(s)`) |
| 단위 시험 실패 | `parse_hidden`의 상한 16384 → 8192 | FAILURE | Python: `unit tests failed: 1 failing test(s)` | 건너뜀 |
| C++ 컴파일 오류 | `util.cpp` 끝에 `int broken( {` | FAILURE | C++: `make CUDA=0 failed` | 건너뜀 (Python 이하도 건너뜀) |
| 쉘 문법 오류 | 닫히지 않은 `if`가 있는 스크립트 추가 | FAILURE | 쉘: `1 script(s) have syntax errors` | 건너뜀 |
| ShellCheck 경고 | `local a=$(date)` (SC2155) | FAILURE | 쉘: `ShellCheck found 1 problem(s)` | 건너뜀 |
| 차트 오류 | `_helpers.tpl`의 `{{- if … }}`에서 `}}` 삭제 | FAILURE | Helm: `helm lint (train) failed` | 건너뜀 |

- 성공한 빌드의 검사 결과(한 줄씩): `[cpp] PASS: C++ build (CUDA=0) and smoke test`, `[python] PASS: Ran 37 tests`, `[shell] PASS: 29 scripts`, `[helm] PASS: missing train.jobId / infer.modelJobId are rejected`.
- 같은 내용의 스냅샷은 같은 해시(`src-6fdf033a5170`)와 같은 태그가 된다 → 두 번째 실행이 이미지를 다시 만들지 않았다.
- 결과 기록(`ci-result.json`)은 빌드 산출물로 보관됐고 내용은 `tag`, `commit`, `source`, `build`, `build_url`, `built_at`, `images[{name, ref, digest}]`다. ConfigMap 쓰기는 가짜 API 서버로 확인했다(새로 만들기 201, 덮어쓰기 200, `result.json`을 다시 읽으면 같은 JSON).
- 시험 도중 찾아 고친 문제:
  1. 시험용 작업의 설정을 갱신하는 요청이 한글 때문에 HTTP 500이 났다(`Content-Type`에 `charset=UTF-8`이 없으면 Jenkins가 본문을 Latin-1로 읽는다) → 헤더 추가.
  2. 같은 작업 폴더가 다시 쓰이면 이전 빌드의 파일이 섞였다(로컬 점검에서) → 소스 단계 처음에 `deleteDir()`.
  3. 선언형 `when`은 기본적으로 파드를 만든 뒤 평가한다 → `beforeAgent true`로 `BUILD_IMAGES=false`일 때 파드를 만들지 않게 했다.

## 4. 기존 코드에서 본 것 (고치지 않음)

- `scripts/image-build.sh`는 빌드 폴더에 하위 폴더가 있으면 거부한다. 처음에 시험을 `apps/train/tests/`에 두었다가 `scripts/image-build.sh apps/train …`이 막히는 것을 확인하고(총괄 지시로) 시험을 저장소 최상위 `tests/train/`으로 옮겼다. `find apps/train -mindepth 1 -type d`가 비어 있고, Python 단계가 `apps/train`에 하위 폴더가 생기면 실패하도록 검사를 넣었다. 시험 37개는 옮긴 뒤에도 통과한다(3.0초).
- `apps/train/train.py`: 같은 `job-id`로 이미 DONE인 작업을 **다른 `model_version`**으로 요청하면 버전 충돌 검사(코드 2)보다 "already DONE" 검사가 먼저라서 조용히 코드 0으로 끝난다. 미완료 작업에서는 충돌 검사가 동작한다. 지금 동작을 `test_finished_job_id_is_answered_before_the_version_is_compared`로 고정해 두었으니, 순서를 바꾸려면 이 시험을 같이 고친다.
- ShellCheck(0.11.0)는 기존 스크립트에서 error 0건, warning 7건(모두 SC2034 "안 쓰는 변수": `common.sh`가 정의하고 다른 스크립트가 쓰는 변수와 `for i in $(seq …)`의 `i`)을 낸다. 그래서 판정은 "warning 이상, SC2034 제외"로 했다. style·info 수준은 개수만 알린다(지금 76건. 새 스크립트의 SC2016 "작은따옴표 안에서 변수가 펼쳐지지 않음"처럼 일부러 그렇게 쓴 것과 SC1091 "source 경로를 따라가지 못함"이 많다).

## 5. 클러스터 위 검증에서 확인할 것 (아직 하지 않음)

`scripts/jenkins-ci-test.sh`가 확인하고 보고서에 남긴다: 컨트롤러 Ready·배치·자원·PVC, 익명 거부, 비밀번호 파일 권한, 파이프라인 1회 성공(검사 4단계 + 이미지 2개 + 레지스트리 digest 일치 + ConfigMap), 같은 소스 재실행, 실패 사본 2종(이미지 단계 건너뜀, 레지스트리에 태그 없음), 에이전트 파드가 gpu-host에 배정되고 끝나면 사라지는지, worker-cpu-1 메모리 변화.

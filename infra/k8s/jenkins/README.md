# Jenkins CI (10–12주차)

코드가 바뀌면 Jenkins가 C++ 추론 워커를 빌드하고, Python 학습 코드와 쉘·Helm을 검사한다. 모두 통과했을 때만 지금과 같은 Kaniko 방식으로 이미지를 만든다.
파이프라인은 저장소 최상위 [`Jenkinsfile`](../../../Jenkinsfile)이고, 단계별 명령은 `scripts/jenkins-stage-*.sh`에 있다.

| 파일 | 역할 |
|---|---|
| `infra/k8s/jenkins/values.yaml` | 공식 Jenkins Helm 차트에 넘기는 값 (이미지·플러그인 버전, 자원, 배치, JCasC) |
| `infra/k8s/jenkins/ci-base.yaml` | 네임스페이스 `ci`와 에이전트 파드의 최소 권한 (ConfigMap 읽기·쓰기만) |
| `tests/train/` | 학습 코드 단위 시험 37개 (`datasets.py`, `train.py`, `jobdb.py`). 이미지 빌드 폴더 밖에 둔다 |
| `Jenkinsfile` | 파이프라인: 소스 → C++ → Python → 쉘 → Helm → 이미지 → 결과 기록 |
| `scripts/jenkins-deploy.sh` | 설치 (`--render`는 클러스터 없이 하는 점검) |
| `scripts/jenkins-run.sh` | 파이프라인 한 번 실행 (작업 폴더 스냅샷 또는 GitHub develop) |
| `scripts/jenkins-check.sh` | Jenkins와 같은 검사를 이 컴퓨터에서 클러스터 없이 실행 |
| `scripts/jenkins-ci-test.sh` | 클러스터 위 전체 시험과 보고서 (`docs/labs/jenkins-ci-*.md`) |
| `scripts/jenkins-stage-{cpp,python,shell,helm}.sh` | 검사 단계 본체 (Jenkinsfile과 `jenkins-check.sh`가 같은 파일을 부른다) |
| `scripts/jenkins-registry.sh`, `scripts/jenkins-record.sh` | 이미지 태그 조회, 결과 기록 (이미지 단계가 쓴다) |

## 설치 방법을 고른 이유

| 후보 | 장점 | 단점 | 결정 |
|---|---|---|---|
| **공식 Helm 차트를 정확한 버전으로 고정** | Jenkins 프로젝트가 직접 관리한다. 플러그인 설치, JCasC(설정을 코드로), 에이전트용 권한이 이미 들어 있다. 이 프로젝트가 이미 Helm(4.3.1 고정)으로 워크로드를 배포한다. `helm template`으로 클러스터 없이 렌더링을 검증할 수 있고 `helm rollback`이 된다. | 옵션이 많고 차트가 자주 올라온다(2026-10-16~11-15 한 달에 25번, 차트 색인 기준) → 고정하지 않으면 재현이 안 된다. | **채택** |
| 직접 쓴 매니페스트(StatefulSet 등) | 가장 단순하고 투명하다. | 플러그인 설치 init 컨테이너, JCasC 연결, RBAC, 프로브를 모두 직접 만들고 유지해야 한다. 같은 일을 차트가 이미 검증해 두었다. | 보류 |
| Jenkins Operator | 선언형 | CRD와 오퍼레이터 파드가 더해진다. worker-cpu-1은 6GB를 레지스트리·MySQL·Argo CD·모니터링과 나눠 쓴다. | 제외 |
| VM이나 호스트에 직접 설치 | 단순 | "Kubernetes 에이전트 파드에서 단계별로 돈다"는 요구와 맞지 않고, 호스트 설치는 사용자 몫이다. | 제외 |

고정한 것 (모두 `latest` 없음):

- 차트 `jenkins` **5.13.3** (2026-11-15 릴리스). 내려받은 tgz의 SHA-256 `90ba804e…89287e7`을 `scripts/jenkins-deploy.sh`가 확인한다 (차트 색인의 digest와 같은 값).
- 컨트롤러 이미지 `jenkins/jenkins:2.580.2-jdk25` (LTS), 에이전트 `jenkins/inbound-agent:3395.v6e5377b_0fb_3c-5-jdk25`
- 플러그인 **73개 전부**를 정확한 버전으로(`values.yaml`의 `installPlugins`, 직접 쓰는 7개 + 의존 66개). 처음에는 7개만 고정하고 의존 플러그인은 최소 요구 버전으로 받게 했는데(`installLatestPlugins: false`), 첫 배포에서 `pipeline-model-extensions` 2.2277이 요구하는 `pipeline-model-api`·`workflow-job`·`pipeline-stage-step`보다 낮은 버전이 설치되어 Declarative Pipeline이 로드되지 않았다(파이프라인이 단계 없이 SUCCESS로 끝남). Jenkins 2.580.2에서 실제로 모두 로드된 조합을 그대로 고정했고, `scripts/jenkins-deploy.sh`와 `scripts/jenkins-ci-test.sh`가 "고정한 목록 = 로드된 목록"을 확인한다. 갱신할 때는 하나만 올리지 않고 목록을 통째로 바꿔 파이프라인을 돌려 본다.
- 도구: ShellCheck 0.11.0(SHA-256 확인), Helm 4.3.1(SHA-256 확인), Kaniko `v1.28.6`(`image-build.sh`와 같은 버전, 셸이 있는 `-debug` 이미지), `gcc:15.3.0-trixie`(`apps/infer/Dockerfile`의 빌드 이미지와 같음), `pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime`(학습 이미지의 베이스와 같음)

## 구성

```
GitHub develop ──(5분마다 폴링)──┐          작업 폴더 스냅샷 ──scripts/jenkins-run.sh──┐
                                 ▼                                                   ▼
          네임스페이스 ci:  Jenkins 컨트롤러 (worker-cpu-1, StatefulSet jenkins-0, PVC 5Gi)
                              │  에이전트 파드를 WebSocket으로 연결 (에이전트 전용 포트 없음)
                              ▼
             검사 파드 (gpu-host)  jnlp + gcc + torch : 소스 → C++ → Python → 쉘 → Helm   ← 하나라도 실패하면 여기서 끝
                              │  통과 → 이미지 빌드 폴더를 stash로 넘김
                              ▼
             빌드 파드 (gpu-host, 이미지마다 1개)  jnlp + kaniko + tools : 이미지를 push → digest 확인 → 결과 기록
                              ▼
             registry.k3slab.local:5000/<이름>:<태그>   +   ConfigMap ci-latest   +   빌드 산출물 ci-result.json
```

- **컨트롤러는 worker-cpu-1**(레지스트리·MySQL과 같은 platform 노드)이다. 빌드는 컨트롤러에서 돌리지 않는다(`numExecutors: 0`).
- **에이전트 파드는 gpu-host**에서 돈다. 이유: 물리 PC라 메모리가 넉넉하고(VM 노드는 3~6GB), Kaniko가 푸는 큰 베이스 이미지(CUDA 8GB)를 둘 디스크도 거기 있다.
  `scripts/image-build.sh`의 빌드 Job도 같은 이유로 gpu-host에서 돈다. GPU는 요청하지 않는다(taint만 견딘다).
  단점: 학습·추론 실험이 GPU 호스트를 쓰는 동안 빌드와 CPU·메모리를 나눠 쓴다. 파드는 한 번에 하나만 뜬다(`disableConcurrentBuilds`, 검사 파드가 끝난 뒤 빌드 파드).
- 에이전트 파드의 권한은 ConfigMap 읽기·쓰기뿐이다(`ci-base.yaml`). 저장소가 공개라 Jenkins에 GitHub 자격증명이 없다.
- 관리자 계정은 `admin`, 비밀번호는 `jenkins-deploy.sh`가 무작위로 만들어 Secret `ci/jenkins-admin`과 `~/.config/k3s-vmware-lab/secrets/jenkins.env`(권한 600)에만 둔다. 익명은 읽기도 안 된다.

## 자원 (2단계 배포 승인 대상)

| 파드 | 컨테이너 | CPU 요청 | 메모리 요청 | CPU 한도 | 메모리 한도 | 노드 |
|---|---|---|---|---|---|---|
| 컨트롤러 `jenkins-0` | jenkins | 250m | 768Mi | 1 | 1Gi | worker-cpu-1 |
| (시작할 때만) | init (플러그인 설치) | 100m | 256Mi | – | 1Gi (힙 512MB) | worker-cpu-1 |
| 검사 파드 | jnlp / gcc / torch | 50m / 500m / 500m | 128Mi / 512Mi / 512Mi | – | 384Mi / 2Gi / 2Gi | gpu-host |
| 빌드 파드 (이미지마다 1개씩 차례로) | jnlp / kaniko / tools | 50m / 1 / 50m | 128Mi / 2Gi / 64Mi | – | 384Mi / 8Gi / 256Mi | gpu-host |

- 컨트롤러 PVC `jenkins`: **5Gi**, local-path (worker-cpu-1 디스크). 플러그인은 `emptyDir`(약 0.3GB, 파드가 다시 뜰 때마다 새로 받는다).
- 자바 힙은 256~512MB로 묶었다(`-Xms256m -Xmx512m -XX:+UseSerialGC`). 나머지(메타스페이스, 스레드)를 합쳐 1Gi 안에 들어가야 한다.
- 에이전트 파드는 동시에 하나만 뜬다. 한도 합계(검사 4.4Gi, 빌드 8.6Gi)는 합산이 아니라 "한 파드의 최대"다.
  요청 합계는 검사 파드 CPU 1050m / 메모리 1152Mi, 빌드 파드 CPU 1100m / 메모리 2240Mi다. GPU는 요청하지 않는다(`nvidia.com/gpu` 없음).
  첫 시험(2026-11-22)에서 15초 간격으로 잰 최대 사용량은 검사 파드 658Mi, 빌드 파드 363Mi, 컨트롤러 606Mi였다(`kubectl top`, 보고서 5절).
- 사이드카(설정 자동 재적용)는 끈다. 설정을 바꾸면 `helm upgrade`로 반영한다(파드 재시작).

## 쓰는 법

```bash
# 클러스터 없이: 차트 해시·lint·template 확인, 그리고 Jenkins와 같은 검사를 이 컴퓨터에서
scripts/jenkins-deploy.sh --render
scripts/jenkins-check.sh                      # cpp, python, shell, helm (python은 torch가 있는 python이 필요: --python 경로)

# 클러스터 위 (승인 후): 설치, 한 번 실행, 전체 시험
scripts/jenkins-deploy.sh
scripts/jenkins-run.sh                        # 이 작업 폴더의 스냅샷으로 시험용 작업 k3slab-ci-local 실행
scripts/jenkins-run.sh --git                  # 운영 작업 k3slab-ci (GitHub develop)
scripts/jenkins-ci-test.sh                    # 성공·재실행·일부러 실패·메모리를 확인하고 docs/labs/jenkins-ci-*.md에 기록

# 화면 보기
kubectl -n ci port-forward svc/jenkins 8080:8080     # http://127.0.0.1:8080 (admin / jenkins.env의 비밀번호)
```

## 파이프라인 단계

| 단계 | 파드 | 하는 일 | 실패하면 |
|---|---|---|---|
| 소스 | 검사 | git이면 `checkout scm`, 스냅샷이면 ConfigMap의 tar를 해시 확인 후 푼다. 이미지 태그를 정한다 | 뒤 단계 전부 건너뜀 |
| C++ | 검사(gcc) | `apps/infer`를 `make CUDA=0`으로 빌드(httplib는 Dockerfile의 버전·SHA-256으로 받음), 모델 파일을 만들어 워커를 띄워 `/healthz`, `/infer`(class 3), 잘못된 입력(400), `/metrics`, SIGTERM 종료, 모델 없음 거부를 확인 | 〃 |
| Python | 검사(torch) | `py_compile`, Dockerfile이 모든 모듈을 COPY하는지, `requirements.txt` 해시 고정, `tests/train` 단위 시험 37개 | 〃 |
| 쉘 | 검사(gcc) | 모든 `*.sh`를 `bash -n`, ShellCheck 0.11.0 (warning 이상이면 실패, SC2034 제외) | 〃 |
| Helm | 검사(gcc) | `helm lint`와 `helm template` (학습 → Job, 추론 → Deployment + Service, 이미지 태그 반영, 필수 값 누락 거부) | 이미지 단계 건너뜀 |
| 이미지 | 빌드 (이미지마다 새 파드) | 이미지마다: 레지스트리에 태그가 있으면 **다시 빌드하지 않고** 그 digest를 쓴다. 없으면 Kaniko로 빌드해 push하고 레지스트리에 digest를 다시 물어 같은지 확인 | 빌드 실패 |
| 결과 기록 | 빌드 (마지막 이미지의 파드) | `ci-result.json` 산출물, ConfigMap `ci-latest`(git) 또는 `ci-latest-local`(스냅샷) | 빌드 실패 |

**이미지마다 파드를 새로 만드는 이유**: Kaniko는 빌드가 끝나면 자기 컨테이너의 파일시스템을 지우고 베이스 이미지로 바꾼다. 같은 컨테이너에서 두 번째 명령(두 번째 이미지)을 실행하면 `/busybox/sh`가 없어 "Process exited immediately after creation"으로 실패한다(첫 시험에서 겪음). `scripts/image-build.sh`가 이미지마다 Job을 따로 쓰는 것과 같은 이유다. 파드는 그래도 항상 하나만 떠 있어서 승인받은 자원은 그대로다.

`scripts/image-build.sh`와 같은 점: 같은 Kaniko 버전, `--insecure`, `--digest-file`, `--snapshot-mode=redo`, `registry.k3slab.local` hostAliases, gpu-host 배치, 요청 CPU 1·메모리 2Gi, 태그 불변.
다른 점: 빌드 폴더를 ConfigMap 대신 작업 폴더로 그대로 쓴다(하위 폴더·1MiB 제한 없음, 심볼릭 링크 문제도 없음), 메모리 한도 8Gi를 둔다(물리 PC 보호).

## 결과 전달 (CICD_연결 / Argo CD가 읽는 값)

이미지 태그 규칙: **커밋 7자리 `git-<sha7>`** (GitHub develop을 빌드한 경우). 같은 커밋은 같은 태그라서 다시 돌려도 덮어쓰지 않는다(이미 있으면 건너뛰고 같은 digest를 기록한다).
시험용 스냅샷은 `src-<해시 12자리>`다 (스냅샷 tar의 SHA-256 앞 12자리. 같은 내용이면 같은 태그). **`src-` 태그는 배포용이 아니다.**

| 어디에 | 무엇 | 읽는 법 |
|---|---|---|
| 레지스트리 `registry.k3slab.local:5000` | `infer-worker:<태그>`, `train-worker:<태그>` | `scripts/jenkins-registry.sh digest infer-worker <태그>` → `sha256:…` |
| ConfigMap `ci/ci-latest` (git 빌드만, 성공했을 때 덮어씀) | `tag`, `commit`, `source`, `built_at`, `build`, `build_url`, `infer-worker.digest`, `infer-worker.ref`, `train-worker.digest`, `train-worker.ref`, `result.json` | `kubectl -n ci get cm ci-latest -o jsonpath='{.data.tag}'` |
| ConfigMap `ci/ci-latest-local` | 같은 키, 스냅샷 빌드 | 시험 전용 |
| Jenkins 빌드 산출물 `ci-result.json` | 위와 같은 내용(JSON): `tag`, `commit`, `source`, `build`, `build_url`, `built_at`, `images[{name, ref, digest}]` | `http://jenkins.ci.svc.cluster.local:8080/job/k3slab-ci/<번호>/artifact/ci-result.json` |

- `ref`는 차트의 `image.repository`와 `image.tag`에 그대로 쓰는 값이다 (`registry.k3slab.local:5000/infer-worker:git-abc1234`).
- 차트 값 `image.tag`를 이 태그로 바꾸는 일은 이 작업에 넣지 않았다. GitOps로 하려면 `charts/k3slab-workload/values-*.yaml`의 `image.tag`를 Git에 커밋해야 하는데, 쓰기 권한(토큰)과 어느 저장소·브랜치에 쓸지는 사용자가 정할 일이라서다.
  `helm template`은 `--set image.tag=<태그>`를 받는지 이미 확인한다(Helm 단계).
- 태그가 `git-` 접두사와 7자리 16진수라서 Argo CD Image Updater 같은 도구의 정규식(`^git-[0-9a-f]{7}$`)으로 걸러 쓸 수 있다.

## 소스를 넣는 방법

- **운영**: GitHub `develop`(공개 저장소, 인증 없음)을 5분마다 폴링한다. 클러스터가 NAT 안에 있어 GitHub 웹훅(들어오는 연결)은 쓸 수 없다. `develop`에 `Jenkinsfile`이 올라가기 전에는 `k3slab-ci`가 "Jenkinsfile을 찾을 수 없음"으로 실패한다(Jenkins를 처음 띄우면 폴링이 바로 한 번 돈다). 운영 작업 `k3slab-ci`의 실제 실행은 CICD_연결 작업에서 한다.
- **작업 폴더 시험**: push하기 전의 작업 폴더 상태를 그대로 시험하려고 `scripts/jenkins-run.sh`가 작업 폴더를 스냅샷(tar.gz, 약 135KB)으로 만들어 ConfigMap `ci-source-<해시>`로 올리고 시험용 작업 `k3slab-ci-local`을 돌린다.
  - 작업 정의에는 이 폴더의 `Jenkinsfile` 내용을 그대로 넣는다 → 시험하는 파이프라인과 운영 파이프라인이 같다.
  - 스냅샷은 git이 아는 파일(추적 + 새 파일 중 `.gitignore`에 걸리지 않는 것)만 담는다. `*.env`와 비밀 파일은 들어가지 않는다.
  - 같은 내용이면 같은 바이트(정렬, 시각 0, `gzip -n`)라서 해시가 같다. ConfigMap은 최근 5개만 남긴다.

## gpu-host의 AppArmor (알려진 제약과 선택)

**무슨 일인가.** gpu-host(Ubuntu)의 containerd 기본 AppArmor 프로파일 `cri-containerd.apparmor.d//&unconfined`는 컨테이너 안에서 자식 프로세스에 신호(TERM, KILL, USR1)를 보내는 것을 막는다. `kill -0`(존재 확인)만 되고, root이고 `CAP_KILL`이 있어도 `Permission denied`(EPERM)가 난다.
첫 시험(2026-11-22)에서 C++ 단계의 "워커를 띄우고 SIGTERM으로 끝내 보는" 시험이 이것 때문에 `kill: Permission denied`로 실패했다. 같은 이미지를 같은 노드에 `appArmorProfile: Unconfined`로 띄우면 네 신호 모두 통과했고, 기본 프로파일에서는 `kill -0`만 통과했다(디버그 파드로 확인, 파드는 지움). 코드 문제가 아니라 노드 환경이다.

**무엇을 했나.** `Jenkinsfile`의 검사 파드에서 `gcc` 컨테이너 **하나에만** `securityContext.appArmorProfile.type: Unconfined`를 준다. 파드 전체나 `jnlp`에는 주지 않는다.
나머지 격리는 그대로 두거나 이번에 넣었다: 파드 전체에 `seccompProfile: RuntimeDefault`, 컨테이너마다 `privileged: false`와 `allowPrivilegeEscalation: false`, 추가 capability 없음.
**포기한 것**은 그 CI 컨테이너(우리 코드를 빌드하고 시험하는 `gcc`)의 AppArmor 한 겹이다. `torch`(Python) 컨테이너는 같은 증상이 실제로 났을 때만 같은 방식으로 풀고, 났다는 로그를 보고서에 남긴다.

**다른 선택(쓰지 않음).**
- 신호 시험을 빼기: 검사가 약해져서 하지 않는다.
- **C안: gpu-host에 신호를 허용하는 `Localhost` AppArmor 프로파일을 만들어 쓰기.** 호스트에 프로파일을 올려야 하므로 sudo와 호스트 변경이 필요하다. 이 프로젝트에서는 사용자가 정할 일이라 하지 않았다. 하면 `Unconfined` 없이도 같은 시험이 돈다.

**플랫폼·검증이 알아 둘 것.** 같은 제약이 gpu-host의 다른 파드에도 해당할 수 있다. 컨테이너 안에서 자식 프로세스에 신호를 보내는 경우(`kill`, `timeout`, 셸 스크립트가 띄운 프로세스를 정리하는 `trap`, 신호를 자식에게 넘기는 init 등)가 막힌다. VM 노드(Rocky)는 AppArmor가 아니라 SELinux라 같은 제약이 없을 것으로 보지만 이번에 확인하지는 않았다. 그렇다면 노드를 옮겼을 때 갑자기 깨지는 모양으로 나타날 수 있다. kubelet이 밖에서 보내는 SIGTERM(파드 종료)은 영향이 없다.

## 알려진 한계

- 배포가 중간에 실패해 컨트롤러 파드(`jenkins-0`)가 한 번도 Ready가 된 적이 없으면, 설정을 고쳐 다시 `scripts/jenkins-deploy.sh`를 돌려도 StatefulSet이 그 깨진 파드를 새 리비전으로 바꾸지 않는다. 그때는 `kubectl -n ci delete pod jenkins-0`으로 파드만 지우면 새 리비전으로 다시 뜬다(데이터는 PVC에 있다). 첫 배포에서 한 번 겪었다.
- 컨트롤러 첫 시작은 플러그인 73개를 받느라 약 10분 걸린다(2026-11-22 실측).
- 단위 시험은 `tests/train/`(저장소 최상위)에 둔다. `apps/train/` 안에 `tests/`를 두면 `scripts/image-build.sh apps/train …`이 "하위 폴더가 있다"며 거부하기 때문이다(ConfigMap 빌드 폴더는 파일만 허용). Python 단계가 `apps/train`에 하위 폴더가 생기면 실패하게 막아 둔다.
- Kaniko는 빌드마다 베이스 이미지(CUDA devel 약 3.3GB 압축, PyTorch 약 3.3GB)를 새로 받는다(캐시 없음). 이미지 하나에 10분 이상 걸릴 수 있다. 필요하면 `--cache=true --cache-repo`로 줄일 수 있다.
- 검사 파드는 gpu-host의 `gcc`와 PyTorch 이미지(약 4GB)를 처음 한 번 받는다.
- 시험용 작업은 샌드박스 안에서 돈다. Jenkinsfile이 새 메서드를 쓰면 "Scripts not permitted" 오류가 날 수 있다(운영 작업도 같은 규칙).

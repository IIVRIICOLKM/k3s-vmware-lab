# Jenkins CI (10–12주차)

코드가 바뀌면 Jenkins가 C++ 추론 워커를 빌드하고, Python 학습 코드와 쉘·Helm을 검사한다. 모두 통과했을 때만 지금과 같은 Kaniko 방식으로 이미지를 만들고,
새 이미지 태그를 GitOps 값 파일에 커밋해서 Argo CD가 배포하게 한다 (아래 "코드 변경에서 배포까지").
파이프라인은 저장소 최상위 [`Jenkinsfile`](../../../Jenkinsfile)이고, 단계별 명령은 `scripts/jenkins-stage-*.sh`에 있다.

| 파일 | 역할 |
|---|---|
| `infra/k8s/jenkins/values.yaml` | 공식 Jenkins Helm 차트에 넘기는 값 (이미지·플러그인 버전, 자원, 배치, JCasC) |
| `infra/k8s/jenkins/ci-base.yaml` | 네임스페이스 `ci`와 에이전트 파드의 최소 권한 (ConfigMap 읽기·쓰기만) |
| `tests/train/` | 학습 코드 단위 시험 37개 (`datasets.py`, `train.py`, `jobdb.py`). 이미지 빌드 폴더 밖에 둔다 |
| `tests/infer/` | 추론 워커 `/metrics` 단위 시험 (`test_metrics.cpp`: 지연 히스토그램). C++ 단계가 컴파일해 실행한다 |
| `Jenkinsfile` | 파이프라인: 소스 → C++ → Python → 쉘 → Helm → 이미지 → 결과 기록 → 배포 값(태그 커밋) |
| `scripts/jenkins-deploy.sh` | 설치 (`--render`는 클러스터 없이 하는 점검) |
| `scripts/jenkins-run.sh` | 파이프라인 한 번 실행 (작업 폴더 스냅샷 또는 Gitea main) |
| `scripts/jenkins-check.sh` | Jenkins와 같은 검사를 이 컴퓨터에서 클러스터 없이 실행 |
| `scripts/jenkins-ci-test.sh` | 클러스터 위 전체 시험과 보고서 (`docs/labs/jenkins-ci-*.md`) |
| `scripts/jenkins-stage-{cpp,python,shell,helm}.sh` | 검사 단계 본체 (Jenkinsfile과 `jenkins-check.sh`가 같은 파일을 부른다) |
| `scripts/jenkins-registry.sh`, `scripts/jenkins-record.sh` | 이미지 태그 조회, 결과 기록 (이미지 단계가 쓴다) |
| `scripts/cicd-set-tag.sh` | 배포 값 파일의 `image.tag`를 새 태그로 바꿔 Gitea에 커밋·push (배포 값 단계가 쓴다) |
| `scripts/cicd-e2e-test.sh` | 코드 커밋 → 배포까지 한 번에 시험하고 단계별 시간을 재는 스크립트 (`docs/labs/cicd-e2e-*.md`) |
| `scripts/argocd-source.sh` (`ci-init`, `tree`, `log`, `show`) | Jenkins용 Gitea 계정·토큰 만들기, 코드를 Gitea에 올리기·읽기 |

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
클러스터 안 Gitea main ─(1분마다 폴링)┐      작업 폴더 스냅샷 ──scripts/jenkins-run.sh──┐
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
                              │  (git 소스일 때만) 배포 값 단계: 같은 Gitea 저장소의 values-infer-argocd.yaml image.tag 커밋 (파드 1개, jnlp만)
                              ▼
                       Argo CD가 그 커밋을 보고 새 파드를 띄운다
```

- **컨트롤러는 worker-cpu-1**(레지스트리·MySQL과 같은 platform 노드)이다. 빌드는 컨트롤러에서 돌리지 않는다(`numExecutors: 0`).
- **에이전트 파드는 gpu-host**에서 돈다. 이유: 물리 PC라 메모리가 넉넉하고(VM 노드는 3~6GB), Kaniko가 푸는 큰 베이스 이미지(CUDA 8GB)를 둘 디스크도 거기 있다.
  `scripts/image-build.sh`의 빌드 Job도 같은 이유로 gpu-host에서 돈다. GPU는 요청하지 않는다(taint만 견딘다).
  단점: 학습·추론 실험이 GPU 호스트를 쓰는 동안 빌드와 CPU·메모리를 나눠 쓴다. 파드는 한 번에 하나만 뜬다(`disableConcurrentBuilds`, 검사 파드가 끝난 뒤 빌드 파드).
- 에이전트 파드의 권한은 ConfigMap 읽기·쓰기뿐이다(`ci-base.yaml`). 클러스터에는 GitHub 자격증명이 없다. Jenkins가 가진 Git 자격증명은 클러스터 안 Gitea의 이 저장소에만 쓸 수 있는 토큰 하나뿐이다(`gitea-ci`).
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
| 소스 | 검사 | git이면 `checkout scm`(Gitea main), 스냅샷이면 ConfigMap의 tar를 해시 확인 후 푼다. 이미지 태그를 정한다 | 뒤 단계 전부 건너뜀 |
| C++ | 검사(gcc) | `apps/infer`를 `make CUDA=0`으로 빌드(httplib는 Dockerfile의 버전·SHA-256으로 받음), 모델 파일을 만들어 워커를 띄워 `/healthz`, `/infer`(class 3), 잘못된 입력(400), `/metrics`, SIGTERM 종료, 모델 없음 거부를 확인 | 〃 |
| Python | 검사(torch) | `py_compile`, Dockerfile이 모든 모듈을 COPY하는지, `requirements.txt` 해시 고정, `tests/train` 단위 시험 37개 | 〃 |
| 쉘 | 검사(gcc) | 모든 `*.sh`를 `bash -n`, ShellCheck 0.11.0 (warning 이상이면 실패, SC2034 제외) | 〃 |
| Helm | 검사(gcc) | `helm lint`와 `helm template` (학습 → Job, 추론 → Deployment + Service, 이미지 태그 반영, 필수 값 누락 거부) | 이미지 단계 건너뜀 |
| 이미지 | 빌드 (이미지마다 새 파드) | 이미지마다: 레지스트리에 태그가 있으면 **다시 빌드하지 않고** 그 digest를 쓴다. 없으면 Kaniko로 빌드해 push하고 레지스트리에 digest를 다시 물어 같은지 확인 | 빌드 실패 |
| 결과 기록 | 빌드 (마지막 이미지의 파드) | `ci-result.json` 산출물, ConfigMap `ci-latest`(git) 또는 `ci-latest-local`(스냅샷) | 빌드 실패 |
| 배포 값 | 새 파드 (jnlp만, 50m/128Mi) | git 소스이고 `DEPLOY=true`이고 infer-worker를 만들었을 때만. `scripts/cicd-set-tag.sh`가 `charts/k3slab-workload/values-infer-argocd.yaml`의 `image.tag`를 새 태그로 바꿔 Gitea main에 커밋·push. `src-` 태그는 거부 | 빌드 실패 (이미지는 이미 push됨. 태그 커밋만 없다) |

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
- `image.tag`를 이 태그로 바꿔 GitOps 저장소에 커밋하는 일은 CICD_연결에서 넣었다: 배포 값 단계가 한다(아래 "코드 변경에서 배포까지").
  `helm template`은 `--set image.tag=<태그>`를 받는지 계속 확인한다(Helm 단계).
- 태그가 `git-` 접두사와 7자리 16진수라서 Argo CD Image Updater 같은 도구의 정규식(`^git-[0-9a-f]{7}$`)으로 걸러 쓸 수 있다.

## 소스를 넣는 방법

- **운영**: 클러스터 안 Gitea 저장소 `k3slab/k3s-vmware-lab`의 `main`을 1분마다 폴링한다(`scm('* * * * *')`). 코드와 GitOps 배포 값의 출처를 이 저장소 하나로 둔다. 공개 저장소(GitHub `develop`)는 총괄이 결과를 올리는 사본이다.
  Jenkins는 이 저장소에만 쓸 수 있는 토큰(자격증명 `gitea-ci`)으로 읽고 쓴다. 이유와 폴링을 고른 이유는 아래 절에 있다. 저장소에 `Jenkinsfile`이 없으면 작업은 "Unable to find Jenkinsfile"로 한 번 실패한다.
- **작업 폴더 시험**: push하기 전의 작업 폴더 상태를 그대로 시험하려고 `scripts/jenkins-run.sh`가 작업 폴더를 스냅샷(tar.gz, 처음 약 135KB, 지금 약 418KB)으로 만들어 ConfigMap `ci-source-<해시>`로 올리고 시험용 작업 `k3slab-ci-local`을 돌린다.
  - 작업 정의에는 이 폴더의 `Jenkinsfile` 내용을 그대로 넣는다 → 시험하는 파이프라인과 운영 파이프라인이 같다.
  - 스냅샷은 git이 아는 파일(추적 + 새 파일 중 `.gitignore`에 걸리지 않는 것)만 담는다. `*.env`와 비밀 파일은 들어가지 않는다.
  - 같은 내용이면 같은 바이트(정렬, 시각 0, `gzip -n`)라서 해시가 같다. ConfigMap은 최근 5개만 남긴다.

## 코드 변경에서 배포까지 (CICD_연결, 11주차: 제안서 12–13주 몫을 앞당겨 진행)

코드를 Gitea에 커밋하면 사람 손 없이 새 파드가 뜬다. 시험·시간표·p50/p95는 `docs/labs/cicd-e2e-*.md`(`scripts/cicd-e2e-test.sh`)에 있다.

> 상태: 2026-11-22 클러스터에서 `scripts/cicd-e2e-test.sh`로 확인했다. **PASS 62, FAIL 0** (보고서 `docs/labs/cicd-e2e-20261122-2141.md`).
> 지연 히스토그램 커밋 하나가 커밋부터 새 digest 확인까지 **320초**(폴링 대기 64초 포함, 이미지 단계 170초가 가장 길다)에 새 파드로 배포됐다.
> 단위 시험이 실패하는 커밋은 C++ 단계에서 멈춰 이미지·태그 커밋·배포가 없었고 기존 파드는 그대로였다. 그 커밋을 revert하면 같은 파이프라인이 243초에 다시 배포했다.

```
커밋 ─▶ Gitea main ─(Jenkins 폴링 1분)─▶ k3slab-ci: 검사 ─▶ 이미지 git-<sha7> ─▶ 결과 기록 ─▶ 배포 값(태그 커밋, 작성자 k3slab ci, [skip ci])
                       ▲                                                                                    │
                       └────────────────────────────────────────────────────────────────────────────────────┘
Argo CD(30초 폴링): values-infer-argocd.yaml의 새 커밋 ─▶ 자동 sync ─▶ 새 파드(새 digest)
```

| 결정 | 선택 | 이유 |
|---|---|---|
| 코드·배포 값의 출처 | 클러스터 안 Gitea 저장소 `k3slab/k3s-vmware-lab` 하나 | 저장소(GitHub)가 공개라 일부러 깨뜨린 시험 커밋을 올리지 않는다. 클러스터에 GitHub 쓰기 자격증명을 두지 않는다. GitHub `develop`은 총괄이 결과를 올리는 공개 사본이다 |
| 빌드 시작 | **Jenkins가 Gitea를 1분마다 폴링** (`scm('* * * * *')`) | 아래 "웹훅을 쓰지 않은 이유". 지연은 커밋 뒤 0~60초(평균 30초)이고 실측은 보고서의 단계별 시간표에 별도 줄로 적는다 |
| 쓰기 권한 | 제한된 Gitea 계정 `k3slab-ci`(관리자 아님, `--restricted`)를 이 저장소의 write 협력자로만 둔다. 토큰 범위는 `write:repository` 하나 | 토큰이 새도 이 저장소 밖은 읽지도 쓰지도 못한다. 토큰은 클러스터 Secret `ci/gitea-ci`와 `~/.config/k3s-vmware-lab/secrets/gitea-ci.env`(권한 600)에만 있다. Jenkins 컨트롤러에 파일(`/run/secrets/additional/gitea-ci-token`)로 마운트하고 JCasC가 자격증명 `gitea-ci`로 만든다 |
| 배포 | 같은 저장소의 `charts/k3slab-workload/values-infer-argocd.yaml`에서 `image.tag` 한 줄만 바꿔 커밋 | Argo CD가 보는 파일이다(`infra/k8s/argocd/README.md` 7절). 되돌리기는 그 커밋의 revert 한 번이다 |
| 배포하는 태그 | `git-<커밋 7자리>`만. 시험용 `src-` 태그는 `scripts/cicd-set-tag.sh`가 거부 | 태그는 덮어쓰지 않는다(같은 커밋을 다시 빌드해도 같은 digest) |

**Gitea에 넣는 것.** `Jenkinsfile apps charts scripts infra tests` (`scripts/jenkins-run.sh` 스냅샷과 같은 목록). git이 아는 파일(추적 + 새 파일 중 `.gitignore`에 걸리지 않는 것)만이라서 `*.env`, `kubeconfig`, `secrets/`, `.generated/`는 들어가지 않는다(올린 뒤 저장소 파일 목록으로 확인했다: 보고서 1절). 올리는 명령은 `scripts/argocd-source.sh tree <폴더> <메시지> <경로>... --keep <파일>`이다. `--keep`은 CI가 쓰는 배포 값 파일을 개발 쪽 사본으로 되돌리지 않으려는 것이다.

**처음 한 번 하는 순서** (클러스터에서):

```bash
scripts/argocd-source.sh ci-init                      # 계정 k3slab-ci, 토큰, Secret ci/gitea-ci (여러 번 해도 안전)
scripts/cicd-e2e-test.sh --seed                       # Gitea에 "변경 전" 코드를 올린다 (Jenkins가 뜨면 첫 폴링이 바로 한 번 빌드한다)
scripts/jenkins-deploy.sh                             # Secret이 없으면 멈춘다. 컨트롤러가 다시 떠서 약 10분 걸린다
scripts/cicd-e2e-test.sh                              # 시험 본체 (GPU 1장)
```

작업 `k3slab-ci`에 이미 빌드가 있었다면(예: 예전 GitHub 설정의 실패 빌드) 새 Gitea 저장소를 비교할 기준 리비전이 없어 폴링이 "No changes"만 낸다. 그때는 `scripts/jenkins-run.sh --git`으로 한 번 시작하면 된다(이 시험에서 그렇게 했다). 빌드가 하나도 없는 새 작업은 첫 폴링이 바로 한 번 빌드한다(로컬 Jenkins에서 확인).
Jenkins를 먼저 올리고 Gitea에 `Jenkinsfile`을 나중에 올려도 된다. 그때는 작업이 "Unable to find Jenkinsfile"로 한 번 실패하고(로컬 Jenkins에서 확인: 분마다 반복하지 않는다) 코드가 올라온 뒤 첫 폴링에서 빌드된다.

### 태그 커밋이 다시 빌드를 만들지 않게 (고리 막기)

CI 봇의 태그 커밋도 Gitea main을 움직이므로 폴링이 잡는다. 그래서 빌드는 하나 시작되지만, **소스 단계가 HEAD 커밋을 보고 건너뛴다**(`NOT_BUILT`, 이미지·태그 커밋 없음, 에이전트 파드 하나가 짧게 뜬다).
건너뛰는 조건은 셋이고 하나라도 맞으면 건너뛴다(`Jenkinsfile` 소스 단계). 사람이 시작해도 같고, `FORCE_BUILD=true`로 시작하면 그대로 빌드한다.

| 조건 | 막는 커밋 |
|---|---|
| HEAD 커밋의 작성자가 `k3slab ci` | CI 봇이 만든 모든 커밋 (태그 커밋) |
| HEAD 커밋 메시지에 `[skip ci]` | 태그 커밋(제목 `ci: deploy infer-worker git-xxxxxxx [skip ci]`)과 사람이 붙인 경우 |
| HEAD 커밋이 바꾼 파일이 `values-infer-argocd.yaml` 하나뿐 | 사람이 `replicas`나 `maxBatch`를 고친 커밋 (`scripts/argocd-test.sh`의 값 커밋도 여기 걸린다) |

- **Jenkins의 폴링 제외 확장(UserExclusion, PathRestriction, MessageExclusion)은 쓰지 않는다.** 처음에 이것으로 만들어 로컬 Jenkins에서 셋을 따로 시험했고 통과했지만, 이 확장들은 폴링할 때 마지막 빌드가 돈 노드의 워크스페이스가 필요한데 클러스터의 에이전트 파드는 빌드가 끝나면 사라진다. 같은 규칙을 파이프라인 안(소스 단계)으로 옮겼다.
- **브랜치는 `refs/heads/main`처럼 와일드카드 없이 적는다.** `*/main`이면 git 플러그인이 단일 브랜치가 아니라고 보고 폴링에 워크스페이스를 요구한다. 그러면 폴링이 `ERROR: no such computer k3slab-ci-…`와 `No changes`만 남기고 빌드를 시작하지 않는다(클러스터에서 확인, 로컬 Jenkins는 노드가 계속 있어서 이 문제가 안 보였다).
- 폴링은 비교 기준이 되는 이전 빌드(체크아웃한 리비전)가 있어야 한다. 이미 빌드가 있는 작업의 저장소를 바꾼 직후에는 기준 리비전이 없어 "No changes"로 보이므로, 한 번 `scripts/jenkins-run.sh --git`으로 시작한다(이 시험에서 그렇게 했다). 그 뒤로는 폴링이 돈다.
- 태그 커밋은 항상 "빌드한 커밋 바로 위"에 올라간다. `scripts/cicd-set-tag.sh`는 main이 빌드한 커밋에서 움직였으면(그 사이 사람이 새 커밋을 올림) 태그 커밋을 만들지 않고 종료 코드 3으로 끝낸다(빌드는 UNSTABLE). 새 커밋이 봇 커밋 밑에 묻혀 건너뛰어지는 일을 막고, 새 커밋은 다음 폴링에서 자기 빌드를 받는다.
- 시간 비용: 봇 커밋마다 건너뛴 빌드가 하나 생긴다(파드 시작과 체크아웃, 실측 7~9초). 이미지 단계 이후는 돌지 않는다. 시험에서 건너뛴 빌드는 봇 커밋 12초 뒤에 예약됐고(성공 경로, 한 번 잰 값), 그 뒤 75초 동안 다른 빌드는 생기지 않았다.

### 웹훅을 쓰지 않은 이유

웹훅이면 지연이 1초 안쪽으로 줄지만 이 클러스터에서는 둘 다 막힌다.

- **Gitea 쪽**: 웹훅 대상 주소는 기본 설정(`[webhook] ALLOWED_HOST_LIST`, 기본 `external`)이 사설 주소를 막는다. Jenkins는 클러스터 서비스 주소(사설)라서 Gitea 설정(`gitea.yaml`의 환경변수)을 바꾸고 Gitea를 다시 띄워야 한다. Gitea가 있는 worker-cpu-2는 메모리 limits가 안전 한도의 93%라 재시작과 설정 변경을 피하고 싶다. (실제로 Gitea가 시작 때 "ALLOWED_HOST_LIST only restricts private hosts in the default lax mode"라고 알려 준다.)
- **Jenkins 쪽**: git 플러그인의 `/git/notifyCommit`은 로그인 없이 부르는 주소(UnprotectedRootAction)다. 이 Jenkins는 익명 접근을 모두 막아 두었는데(`allowAnonymousRead: false`), 웹훅은 로그인 없이 트리거하는 길을 새로 여는 일이다. 토큰으로 막는 설정은 따로 해야 하고 이 작업에서 시험하지 않았다.
- 폴링은 둘 다 바꾸지 않고 비용은 분당 `git ls-remote` 한 번이다(제외 확장을 쓰지 않으면 워크스페이스도 필요 없다). Argo CD도 30초 폴링이라 전체 지연은 폴링 두 번(최대 약 1.5분)이 더해진 값이다.

### 한계

- 폴링 간격만큼(0~60초) 시작이 늦다.
- 빌드 중에 사람이 새 커밋을 올려 main이 빌드한 커밋에서 움직였으면 `scripts/cicd-set-tag.sh`는 **태그 커밋을 만들지 않고** 종료 코드 3으로 끝난다(빌드는 UNSTABLE, 이미지는 레지스트리에 남는다). 새 커밋은 다음 폴링에서 자기 빌드와 자기 태그를 받는다. 태그 커밋은 항상 "빌드한 커밋 바로 위"에만 올라간다. push가 거절되면(main을 확인한 직후에 새 커밋이 올라옴) 2초 쉬고 main을 새로 받아 처음부터 다시 확인한다(최대 3번): 그 사이 main이 움직였다면 종료 코드 3으로 끝나고, 아니면 다시 커밋·push한다. 3번 모두 거절되면 빌드가 실패한다(종료 코드 1). 태그는 `git-<빌드한 커밋 7자리>`다.
- 사람이 값 파일만 고친 커밋은 건너뛰어진다. 코드 커밋 바로 위에 사람의 값 파일 커밋이 올라오면 그 코드 커밋이 빌드되지 않을 수 있다(HEAD만 본다). 그때는 `FORCE_BUILD=true`로 시작한다. 봇 커밋 밑에 묻히는 경우는 위의 종료 코드 3 규칙이 막는다.
- 같은 커밋을 사람이 다시 시작하면 같은 태그라서 이미지는 다시 만들지 않고 같은 digest를 쓴다. 배포 값이 이미 그 태그면 태그 커밋도 만들지 않는다.
- 태그 커밋은 infer-worker 태그만 바꾼다. train-worker는 Argo CD가 관리하지 않는다(`infra/k8s/argocd/README.md` 3절).
- 에이전트 파드가 하나 더 생긴다(배포 값 단계, jnlp만 50m/128Mi). 파드는 여전히 한 번에 하나만 뜬다.

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
- 작업 폴더 스냅샷(`scripts/jenkins-run.sh`)의 ConfigMap `ci-source-<해시>`는 `kubectl create`로 만든다. 예전에는 `kubectl apply`라서 객체 전체가 `last-applied-configuration` annotation(한도 256KB)에 복사되어, 스냅샷이 압축 약 190KB를 넘으면 `metadata.annotations: Too long`으로 실패했다(Argo CD `install.yaml` 2MB가 저장소에 들어온 뒤 커밋된 파일만으로 압축 379KB). 이름이 내용 해시라서 같은 이름이면 내용도 같으므로, 이미 있으면 만들지 않고 건너뛴다(오래된 것 정리는 방금 쓸 스냅샷을 지우지 않는다). ConfigMap 자체의 한도 1MiB는 `jenkins-run.sh`의 900KB 검사가 지킨다. 지금 스냅샷은 압축 418KB로 이 검사 안에 있다. 이 크기가 900KB에 가까워지면 파일 목록을 줄여야 한다(`infra/k8s/argocd/install.yaml` 2MB가 가장 크다).
- 고친 뒤 클러스터에서 `scripts/jenkins-run.sh --no-images`를 돌려(2026-11-22 22:08, 빌드 `k3slab-ci-local` #9) 바뀐 Jenkinsfile이 스냅샷 경로에서도 도는 것을 확인했다: 검사 4단계 PASS(C++ 단위 시험 포함), 결과 SUCCESS(소스 가드가 건너뛰지 않음: `CI-SKIP` 로그 0, `NOT_BUILT` 아님), 이미지·배포 값 단계는 `when` 조건으로 건너뜀, Gitea에 태그 커밋 없음. 같은 내용으로 한 번 더 돌리면(#10) "already exists"로 ConfigMap을 다시 만들지 않고 SUCCESS였다. ConfigMap에는 `k3slab.io/ci-source` 라벨만 있고 annotation이 없다.
- `scripts/jenkins-run.sh`는 git 저장소가 아닌 `--source-dir`에 `Jenkinsfile apps charts scripts infra tests` 중 하나라도 없으면 아무 메시지 없이 멈춘다(`find` 오류가 `set -e`로 이어짐). 이번에 고치지 않았다.
- 단위 시험은 `tests/train/`(저장소 최상위)에 둔다. `apps/train/` 안에 `tests/`를 두면 `scripts/image-build.sh apps/train …`이 "하위 폴더가 있다"며 거부하기 때문이다(ConfigMap 빌드 폴더는 파일만 허용). Python 단계가 `apps/train`에 하위 폴더가 생기면 실패하게 막아 둔다.
- Kaniko는 빌드마다 베이스 이미지(CUDA devel 약 3.3GB 압축, PyTorch 약 3.3GB)를 새로 받는다(캐시 없음). 이미지 하나에 10분 이상 걸릴 수 있다. 필요하면 `--cache=true --cache-repo`로 줄일 수 있다.
- 검사 파드는 gpu-host의 `gcc`와 PyTorch 이미지(약 4GB)를 처음 한 번 받는다.
- 시험용 작업은 샌드박스 안에서 돈다. Jenkinsfile이 새 메서드를 쓰면 "Scripts not permitted" 오류가 날 수 있다(운영 작업도 같은 규칙).

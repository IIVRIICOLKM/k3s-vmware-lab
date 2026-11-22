# 10–11주차 진행 요약 (2026-11-22)

진행보고에 옮겨 쓸 수 있게 정리한 문서다. 수치는 모두 `docs/labs/`의 실행 기록이나 해당 README에서 가져왔다. 한 번 잰 값은 "1회"라고 적었다.
1주차 = 9/7이므로 11주차는 11/16~11/22(오늘, 일)이고 12주차는 11/23부터다.
클러스터는 11/22 15:14에 다시 띄웠고, 아래 클러스터 위 시험은 모두 11/22에 했다.

## 일정 대비 현황 (연구제안서 7. 구현 일정 기준)

| 일정 항목 | 계획 주차 | 상태 | 근거 |
|---|---|---|---|
| 요구사항 정리·전체 구성도 설계 | 1–2 | 완료 | 2주차 진행보고 |
| 가상머신 3대·호스트 노드 등록 | 2–4 | 완료 | `docs/gpu-host-join-prep.md` |
| K3s 클러스터 구축·노드 조인 | 4–6 | 완료 (PASS 11/11) | `docs/labs/k3s-lab-20261030-1646.md` |
| Docker 이미지·레지스트리·Helm | 5–7 | 완료 | `docs/image-builds.md` |
| Python 학습 흐름·체크포인트 저장 | 6–9 | 완료 (중단·재개 PASS 6/6, 11/7 재시험 PASS 6/6) | `docs/labs/train-resume-20261107-1253.md` |
| C++ 추론 워커 (큐·배치·타임아웃) | 8–11 | 완료 (GPU 경로, CPU 대체 경로) | `docs/labs/infer-gpu-bench-20261107-1246.md`, `docs/labs/infer-bench-20261107-1257.md` |
| MySQL 작업 상태 연동·중복 방지 | 9–11 | 완료 (PASS 18/18) | `docs/labs/job-db-20261107-1258.md` |
| Jenkins 빌드·테스트 자동화 | 10–12 | **완료** (11주차 안에 끝냄). 시험 PASS 42/42 | `docs/labs/jenkins-ci-20261122-1658.md` |
| Argo CD 배포 자동화 | 11–13 | **완료** (일정보다 앞당김). 시험 PASS 23, FAIL 0 | `docs/labs/argocd-20261122-1612.md` |
| (연결) 코드 커밋 → Jenkins → 태그 커밋 → Argo CD | 11–13 | **완료** (앞당김). 시험 PASS 62, FAIL 0 | `docs/labs/cicd-e2e-20261122-2141.md` |
| Prometheus·Grafana 대시보드 | 12–14 | **완료** (일정보다 앞당김). 시험 PASS 70, FAIL 0 | `docs/labs/monitoring-20261122-1654.md` |
| 정상 실행·중단 상황 검증 실험 | 13–16 | **착수 (13주 몫 완료)**. 점검, 과부하, 잘못된 배포, 추론 파드 강제 종료를 CPU로 실행 | `docs/labs/fault-week13-summary-20261122.md` |
| 결과 정리·보고서 및 발표 준비 | 15–16 | 초안 갱신 (CI/CD·모니터링·첫 장애 실험 반영) | `docs/final-report.md` |

- 9주차 진행보고(11/6)에서 약속한 "다음 단계: 9–11주차" 세 항목은 11/7에 끝났다(`docs/progress-week09.md`).
- Jenkins(10–12), Argo CD(11–13), 모니터링(12–14), 검증 실험 시작(13)은 제안서 일정보다 앞당겨 11주차 안에 했다.
- `docs/labs/`에는 11/22 기록이 새로 생겼다. `docs/image-builds.md`의 마지막 줄은 11/7이다. Jenkins가 만든 `git-<커밋 7자리>` 이미지는 이 파일이 아니라 레지스트리와 빌드 산출물 `ci-result.json`에 기록된다.

## 이번 주 진행 항목

**클러스터 기동 복구와 자원 배치 (11/22)**

- 11/22 15:14에 클러스터를 다시 띄웠다. `scripts/entry.sh` 9단계가 모두 통과했고 총 1분 51초, Ansible `changed=0`, 노드 4개 Ready였다(`docs/plan-week11-capacity.md` 2절).
- 새로 올릴 Jenkins·Argo CD·모니터링을 4노드 어디에 두고 메모리를 얼마 줄지 `scripts/capacity-report.sh`(읽기 전용)로 잰 값으로 정했다.
  - 결론(배치 계획 B): VM 메모리는 늘리지 않는다. Jenkins 컨트롤러와 모니터링(Prometheus·Grafana·kube-state-metrics)은 worker-cpu-1에, Argo CD와 Gitea는 worker-cpu-2에, Jenkins 에이전트는 gpu-host에 둔다.
  - 모두 worker-cpu-2에 두면 메모리 limits 합계가 3,008 MiB로 안전 한도(약 1,860 MiB)를 넘어서 모니터링을 worker-cpu-1로 옮겼다.
  - worker-cpu-2는 여전히 빠듯하다. 계획 때 limits 합계를 1,728 MiB(안전 한도의 93%)로 잡았고, 배포한 값으로 다시 더하면 1,600 MiB(86%)다. 그래서 Argo CD·Gitea의 limits는 더 올리지 않는다.

| 노드 (VM 메모리) | 둔 것 | 메모리 requests 합계 (계획) | 실제 사용 (`kubectl top`, 1회) |
|---|---|---|---|
| worker-cpu-1 (6 GB) | 레지스트리, MySQL, Jenkins 컨트롤러, Prometheus, Grafana, kube-state-metrics, node-exporter | 2,016 MiB (allocatable의 36%) | 기동 직후 939 MiB(16%) → 모두 올린 뒤 2,098~2,196 MiB(37~38%). 계획 때 추정은 약 2.4 GiB |
| worker-cpu-2 (3 GB) | Argo CD 4개 파드, Gitea, node-exporter | 656 MiB (24%) | 998~1,111 MiB(36~40%). 계획 때 추정은 약 1.2 GiB |
| k3s-server (3 GB) | 제어 평면, node-exporter | 172 MiB (6%) | 기동 직후 1,449 MiB(53%) → 1,903~1,982 MiB(70~73%) |
| gpu-host (물리 PC) | Jenkins 에이전트(동시 1개), dcgm-exporter, node-exporter, 학습·추론·Kaniko | 최악 합계 약 5.3 GiB (한도 8 GiB의 67%) | 파드별 값이 아니라 VM 3대를 포함한 PC 전체 13,720~21,525 MiB. 높은 쪽은 GPU 추론 파드가 떠 있던 Argo CD 시험 때다 |

- 근거: `docs/plan-week11-capacity.md`, `docs/labs/argocd-20261122-1612.md` 5절, `docs/labs/jenkins-ci-20261122-1658.md` 5절, `docs/labs/monitoring-20261122-1654.md` 8절.
- k3s-server(3 GB)는 사용량이 53%에서 70~73%로 올랐다. 이유는 확인하지 않았다.

**Jenkins (10–12주) — 완료**

- 설치: 네임스페이스 `ci`, 공식 Helm 차트 `jenkins` 5.13.3(내려받은 파일의 SHA-256 확인), 컨트롤러 `jenkins/jenkins:2.580.2-jdk25`, 플러그인 73개를 전부 정확한 버전으로 고정했다.
  - 컨트롤러는 worker-cpu-1(StatefulSet `jenkins-0`): 요청 250m / 768Mi, 한도 1 CPU / 1Gi, PVC 5Gi. 빌드는 컨트롤러에서 돌리지 않는다.
  - 에이전트 파드는 gpu-host에서 한 번에 하나만 뜬다. GPU는 요청하지 않는다.
- 파이프라인은 저장소 최상위 `Jenkinsfile`이고 단계는 소스 → C++(`make CUDA=0`과 실행 검사) → Python(문법, 단위 시험 37개) → 쉘(`bash -n`, ShellCheck 0.11.0) → Helm(`lint`, `template`) → 이미지(Kaniko) → 결과 기록 → 배포 값(태그 커밋)이다.
- 시험 (`docs/labs/jenkins-ci-20261122-1658.md`, PASS 42/42):
  - 성공 1회: 검사 4단계 통과, `infer-worker`·`train-worker` 이미지 생성, 레지스트리 digest가 결과 기록과 같음. 시험 스크립트 기준 약 3분 50초(1회).
  - 같은 소스를 다시 실행하면 같은 태그라서 이미지를 다시 만들지 않고 같은 digest를 쓴다(태그를 덮어쓰지 않는다).
  - 일부러 실패시킨 두 건(Python 문법 오류, 단위 시험 실패): 쉘·Helm·이미지 단계가 건너뛰어졌고 레지스트리에 새 태그가 생기지 않았다.
- 코드 커밋부터 이미지 push까지는 아래 "CI/CD 연결"의 시간표에 있다.
- 자격 증명: 관리자 비밀번호는 무작위로 만들어 클러스터 Secret과 `~/.config/k3s-vmware-lab/secrets/jenkins.env`(권한 600)에만 둔다. 익명 접근은 막았다. 비밀번호는 저장소 파일 어디에도 없다(시험 항목으로 확인).
- 자원 실측(15초 간격 표본의 최대값): 컨트롤러 606 MiB, 검사 파드 658 MiB, 빌드 파드 363 MiB.
- 스냅샷(작업 폴더) 시험 경로 `scripts/jenkins-run.sh`는 11/22 연결 작업 중에 막혔다가(스냅샷이 커져 `kubectl apply`의 annotation 한도 256KB를 넘음) 같은 날 고쳤다. 고친 뒤 검사만 하는 빌드(`--no-images`)가 1회 SUCCESS였다(`docs/labs/cicd-e2e-20261122-2141.md` 14절). 위 PASS 42/42는 막히기 전 결과다.

**Argo CD (11–13주) — 완료**

- 설치: 네임스페이스 `argocd`, worker-cpu-2. Helm 차트가 아니라 공식 `install.yaml` v3.6.2(SHA-256 확인)에 kustomize 패치를 얹었다. dex·notifications·ApplicationSet 컨트롤러는 뺐고 파드는 4개다.
  - 4개 파드 합계: 요청 225m / 448Mi, 메모리 한도 1,280Mi. 내부 Git 서버 Gitea(28.3.0-rootless, PVC 1Gi)는 요청 50m / 96Mi, 한도 256Mi다.
- 배포 설정은 클러스터 안 Gitea 저장소 `k3slab/k3s-vmware-lab`의 `charts/k3slab-workload`와 값 파일 `values-infer.yaml` + `values-infer-argocd.yaml`이다. 이미지 태그는 `values-infer-argocd.yaml`의 `image.tag` 한 줄이다.
- Application `infer`: 네임스페이스 `k3slab-apps`, 자동 동기화(prune, self-heal), 확인 주기 30초(웹훅 없음). 대상은 추론 서비스 하나이고 학습 Job은 뺐다(아래 "제안서 대비 바뀐 점").
- 시험 (`scripts/argocd-test.sh`, PASS 23, FAIL 0, 모두 1회):
  - 처음 sync: Application 생성 21초 만에 Synced + Healthy, 추론 파드가 gpu-host에서 `device: cuda`로 응답.
  - 자가 치유: 손으로 `replicas` 1→2는 2초 만에, 지운 Service는 1초 만에 되돌아왔다. 되돌린 주체는 Argo CD의 자동 동기화(`initiatedBy.automated`)였다.
  - 새 리비전: `maxBatch` 8→4 커밋 후 55초 만에 새 파드(`MAX_BATCH=4`)가 떴고 배포 이력에 두 리비전이 남았다.
  - rollback: `argocd app rollback`으로 22초 만에 이전 값의 새 파드. 이어서 Git revert로 Git과 다시 맞췄다.
- DNS 수정 뒤 다시 잰 값(1회): 처음 sync 21초 → 3.9초. 새 리비전은 55초 → 25.7초(성공 경로)·9.5초(되돌림 경로)지만 Argo CD의 30초 확인 주기가 섞여 있어 DNS만의 효과로 말할 수 없다(`docs/labs/cicd-e2e-20261122-2141.md` 10절).
- 메모리(1회, 최대값 아님): Argo CD 4개 파드 합계 226 MiB, Gitea 109 MiB.

**CI/CD 연결: 코드 커밋 → Jenkins → 태그 커밋 → Argo CD (11주차, 제안서 12–13주 몫을 앞당김)**

- 시험 (`scripts/cicd-e2e-test.sh`, PASS 62, FAIL 0, 각 경로 1회, `docs/labs/cicd-e2e-20261122-2141.md`).
- 성공 경로: 지연 히스토그램 커밋 `ab7b937`을 Gitea에 올리면 사람 손 없이 Jenkins 빌드가 시작되고(원인 "Started by an SCM change"), 이미지 `git-ab7b937`을 만들고, 봇이 태그 커밋 `d0dc84e`를 올리고, Argo CD가 자동 동기화로 새 파드를 띄웠다. 새 파드의 digest가 CI가 기록한 digest와 같았다.

| 단계 | 커밋부터 (초) | 직전 단계부터 (초) |
|---|---|---|
| Jenkins가 변경을 찾아 빌드 예약 (1분 폴링) | 63.6 | 63.6 |
| 검사 끝 | 109.0 | 45.3 |
| 이미지 push 끝 | 278.8 | 169.8 |
| 태그 커밋 | 291.5 | 12.7 |
| Argo CD sync 끝 | 310.3 | 18.7 |
| 새 파드 Ready | 317.3 | 7.0 |
| 새 digest 확인 | **320.1** | 2.9 |

- 차단 경로: 단위 시험이 실패하는 커밋 `9542768`은 C++ 단계에서 멈췄다(커밋부터 25.9초). 이미지·태그 커밋·배포가 없었고, 기존 파드는 같은 uid·재시작 0·같은 digest였다. 이 커밋을 revert한 `760a534`는 같은 파이프라인을 통과해 243.0초에 새 태그로 배포됐다.
- 태그 커밋도 폴링에 잡히기 때문에 소스 단계가 봇 커밋을 보고 건너뛴다(`NOT_BUILT`, 7~9초). 그 뒤 75초 동안 다른 빌드는 생기지 않았다.
- 이 시험으로 모니터링의 알려진 한계 "지연 p50/p95 없음"도 풀렸다. 워커가 지연 히스토그램을 내보내고 대시보드 패널이 값을 낸다. 다만 p50 ≈ 0.25 ms, p95 ≈ 0.475 ms는 첫 버킷(≤ 0.5 ms) 안의 보간 값이다. "132000개 중 99.971%가 0.5 ms 이하"로 읽어야 한다(같은 보고서 9절).

**Prometheus·Grafana (12–14주) — 완료 (일정보다 앞당김)**

- 설치: 네임스페이스 `monitoring`, 직접 쓴 매니페스트(kustomize). Helm·Operator·CRD는 쓰지 않았다(이유는 아래 "제안서 대비 바뀐 점").
  - Prometheus v3.16.0(보존 7일·2GB, PVC 3Gi), Grafana 13.3.1, kube-state-metrics v2.20.0은 worker-cpu-1에, node-exporter v1.13.1은 4노드에, dcgm-exporter 4.6.1-4.8.4는 gpu-host에 둔다(`infra/k8s/monitoring/README.md`).
- 관측 대상 네 가지를 모두 수집한다.
  - 노드·파드: node-exporter, kube-state-metrics, cAdvisor
  - GPU: dcgm-exporter(사용률, 메모리, 전력, 온도). `nvidia.com/gpu`를 요청하지 않아서 GPU 1장을 잡지 않는다.
  - 추론 요청: 워커 `/metrics`(5초 간격)
  - 작업 상태: Grafana의 MySQL 데이터소스(`jobs`, `job_events`에 SELECT만 되는 읽기 전용 계정)
- 대시보드 3장, 패널 49개(추론 워커 20, 학습 작업 13, 노드 16). Git의 JSON이 기준이라 화면에서 고쳐도 저장되지 않는다. 캡처는 `docs/labs/monitoring-20261122-dashboard-{infer,nodes,training}.png`다.
- 최종 시험 (`scripts/monitoring-test.sh --with-gpu`, PASS 70, FAIL 0, 1회):
  - 수집 대상 11개가 모두 up. 대시보드 쿼리 61개 모두 오류 0.
  - 보통 부하(GPU 워커): 요청 346000개, 초당 5766.7. Prometheus 카운터 증가량이 클라이언트가 센 200 응답 수와 같았다. GPU 사용률 평균 46.93%(최대 81%)가 쉬는 구간 최댓값 2.00%보다 높았고, 전력은 252.52 W로 쉬는 구간 최댓값 133.53 W보다 높았다.
  - 과부하(큐 20, CPU 워커): 429가 29562개(92.4%), 큐 길이 20/20. 429 수가 클라이언트가 센 값과 같았다. 부하 설정은 `--parallel-max 300`이고 실제 최대 연결은 229개였다.
- 메모리: monitoring 네임스페이스 실사용 합계 944 MiB(Grafana 343, dcgm-exporter 446, Prometheus 87, kube-state-metrics 19, node-exporter 4개 합 46).
- 시행은 6번 했다(60/4 → 64/0 → 68/2 → 69/1 → 65/0 → 70/0 PASS/FAIL). 고치기 전 보고서도 지우지 않고 남겼다(`monitoring-20261122-1612.md` ~ `1649.md`).
- 못 본 것: 학습 Job이 돌 때의 학습 대시보드 패널(진행률·진행 에폭), 보존 7일이 오래된 블록을 지우는 것, GPU 학습 중의 DCGM 값(보고서 9.4절).

**검증 실험 첫 단계 (13주 몫, 11/22 실행)**

- 13주 몫(점검, F7, F8 CPU, F1 CPU)을 앞당겨 실제 클러스터에서 실행했다. 모두 CPU 전용이고 GPU는 쓰지 않았다. 실험마다 총괄 승인을 받았다. 설계는 `docs/plan-week13-verification.md`다.

| 실험 | 결과 | 핵심 숫자 (모두 1회) | 보고서 |
|---|---|---|---|
| `inspect` (읽기 전용 점검) | 기록만 | 컨트롤 플레인 1개, GPU 요청 파드 0, PV 5개가 모두 VM 노드의 local-path에 묶임, 복제본 1개짜리 Deployment 13개 | `fault-inspect-20261122-1940.md` |
| F7 과부하 | PASS 11 / FAIL 0 | 요청 300개, 동시 150개(설정값) → 200 = 101, 429 = 199, 그 밖 0. 실제 최대 연결 25개. 429 중앙값 0.004초, 200 중앙값 0.294초 | `fault-overload-20261122-1943.md` |
| F8 잘못된 배포 (CPU) | PASS 9 / FAIL 0 | 없는 태그 배포 → 새 파드 `ErrImagePull`까지 7.4초. 배포~롤백 중 실패 요청 0 / 509. 롤백 0.3초 | `fault-bad-deploy-20261122-2038.md` |
| F1 추론 파드 강제 종료 (CPU, force) | PASS 8 / FAIL 0 | 복구 시간 1.4초(상한), 실패 요청 1 / 179, 새 파드 1개·재시작 0 | `fault-infer-kill-20261122-2041.md` |

- 숫자를 읽는 법(보고서의 한계 절에서 가져옴):
  - F7의 "동시 150"은 설정값이고 실제 연결은 25개였다. 429는 큐(용량 20)가 넘쳐서 났다.
  - F8의 롤백 0.3초는 새 파드가 뜨는 시간이 아니다. 예전 파드가 계속 Ready라서 설정만 되돌린 시간이다.
  - F1의 1.4초는 1초 간격 확인이 만든 상한이다. 작은 모델의 CPU 파드이고 이미지가 노드에 있었다.
- 자동으로 된 것: 파드 재생성(F1), 새 파드 실패 상태에서도 예전 파드가 서비스를 이어 감(F8), 큐 초과 시 즉시 429(F7). 사람이 해야 했던 것: 잘못된 배포의 롤백 명령 한 번(자동 롤백은 없었다).

**최종 보고서 — 갱신**

- `docs/final-report.md`의 3.7(CI/CD), 3.8(모니터링), 5.1·5.2(검증 실험), 6(결과), 7(한계), 4(제안서와 달라진 점), 부록을 이번 결과로 채웠다. 2.1(노드 배치)과 2.3(흐름)도 고쳤다.
- 2.3의 흐름은 글 그림이라 고쳤다. 그림 파일(`docs/assets/architecture.svg`, `tech-stack.svg`)에는 아직 Jenkins·Argo CD·Gitea·모니터링이 없다. 그림 갱신이 필요하다.

## 제안서 대비 바뀐 점과 근거

이번 기간에 생긴 변경이다. 이전 변경은 `docs/final-report.md` 4절에 한 표로 모았다.

| 항목 | 제안서 | 구현 | 이유 | 근거 |
|---|---|---|---|---|
| 배포 설정 저장소 | 배포 설정(YAML)을 별도 디렉터리에 두고 Argo CD가 읽음 | 클러스터 안 Git 서버(Gitea)의 저장소 `k3slab/k3s-vmware-lab` | GitHub 저장소는 공개이고, Jenkins가 태그 커밋을 push하려면 클러스터에 GitHub 쓰기 자격증명이 필요하다. Gitea는 쓰기가 클러스터 안에서 끝난다. 일부러 깨뜨린 시험 커밋도 공개 저장소에 올리지 않는다 | `infra/k8s/argocd/README.md` 4절, `infra/k8s/jenkins/README.md` |
| 빌드 시작 방식 | Git push → Jenkins | Jenkins가 Gitea를 1분마다 폴링(웹훅 없음). 지연 0~60초 | Gitea는 사설 주소로 보내는 웹훅을 기본으로 막고, 바꾸려면 Gitea 설정 변경과 재시작이 필요하다(worker-cpu-2는 메모리가 빠듯). Jenkins 쪽 웹훅 주소는 로그인 없이 부르는 주소라 익명 접근을 막은 설정과 맞지 않는다 | `infra/k8s/jenkins/README.md` "웹훅을 쓰지 않은 이유" |
| 이미지 빌드 | Jenkins가 빌드 | Jenkins 에이전트 파드(gpu-host)의 Kaniko 컨테이너가 빌드. 이미지마다 파드를 새로 만든다 | 호스트 Docker는 sudo가 필요하다. 에이전트를 gpu-host에 둔 것은 물리 PC라 메모리가 넉넉하고 CUDA 베이스 이미지(약 8GB)를 둘 디스크가 있어서다. Kaniko는 빌드 뒤 자기 파일시스템을 지워서 같은 컨테이너로 두 번째 이미지를 못 빌드한다 | `infra/k8s/jenkins/README.md`, `docs/labs/jenkins-ci-20261122-1658.md` 10절 |
| 노드별 배치 | worker-cpu-1(6 GB)에 Jenkins·Argo CD·모니터링·MySQL, worker-cpu-2(3 GB)에 API·전처리 파드(중단 실험 대상) (제안서 3절 "VM, 노드 구성") | 배치 계획 B: VM 크기 그대로(증설 없음). 모니터링은 worker-cpu-1, Argo CD·Gitea는 worker-cpu-2. worker-cpu-2 메모리 limits가 안전 한도의 93%(계획 값) | 모니터링까지 worker-cpu-2에 두면 limits 합계가 안전 한도의 162%다. VM 증설은 필요해지면 쓸 대안으로 남겼다. 제안서와 달리 Argo CD를 worker-cpu-2에 둔 이유는 기록 없음(계획 문서는 그 배치를 전제로 계산했다) | `docs/plan-week11-capacity.md` 1·4.5·5절 |
| Argo CD 대상 | 배포 설정을 Argo CD가 반영 (대상 범위는 제안서에 정하지 않음) | 추론 서비스(Deployment·Service)만. 학습 Job은 `job.sh`가 계속 맡음 | MySQL 등록이 먼저여야 한다. Job은 요청마다 다르다. Job은 끝나는 객체라 prune·self-heal과 부딪친다 | `infra/k8s/argocd/README.md` 3절 |
| Argo CD 설치 방식 | 제안서에 정하지 않음 | 공식 `install.yaml` + kustomize 패치(dex·notifications·ApplicationSet 제거) | 공식 설치 파일은 컨테이너 `resources`가 모두 비어 있어서 메모리 값을 패치로 준다. 제거한 이유는 이유 기록 없음 | `infra/k8s/argocd/README.md`, `docs/plan-week11-capacity.md` 4.2절 |
| 모니터링 설치 방식 | Prometheus가 지표를 모으고 Grafana 대시보드 한 장으로 본다 (설치 방식은 제안서에 정하지 않음) | 직접 쓴 매니페스트(kube-prometheus-stack 안 씀) | 메모리가 빠듯하다. 수집 대상 여섯 가지가 고정이라 Operator의 동적 디스커버리가 필요 없다. Argo CD가 폴더 하나로 관리할 수 있다. 대신 기본 대시보드·알림 규칙은 없다 | `infra/k8s/monitoring/README.md` "설치 방식 비교" |
| 작업 상태 수집 | 대기·실행·완료·실패 작업 수 | Grafana의 MySQL 데이터소스(읽기 전용 계정) | mysqld-exporter는 테이블 안의 값(상태별 작업 수, 진행 에폭, 이력)을 셀 수 없다 | `infra/k8s/monitoring/README.md` |
| GPU 지표 수집기 버전 | — | dcgm-exporter 4.6.1-4.8.4 (4.9.0은 쓰지 않음) | 4.9.0은 기본 지표 이름과 단위를 바꿔서, 실험 도중 단위가 바뀌지 않게 4.8.4로 고정했다 | `infra/k8s/monitoring/README.md` |

## 문제와 대응

**11/20~21의 막힘은 11/22에 풀렸다**

1. **VMware 커널 모듈이 없어 클러스터가 켜지지 않았다 (11/20 확인) → 해결.**
   - 11/22에 사용자가 콘솔에서 `sudo vmware-modconfig --console --install-all`로 `vmmon` 등을 다시 빌드했다. 그 뒤 사전 점검(`preflight.sh`)의 모듈 항목이 모두 PASS였다.
   - 커널이 올라갈 때마다 모듈이 빠지는 문제는 10/1, 10/15, 11/20에 이어 이번이 반복이다. 다시 빌드는 sudo가 필요해서 사용자가 해야 한다.
2. **`entry.sh`가 Rocky ISO 확인 단계에서 멈췄다 (11/20 확인) → 해결.**
   - Rocky 9.9가 공식 경로에 올라오면서 9.8의 CHECKSUM이 그 경로에서 빠졌다. `scripts/fetch-rocky-iso.sh`가 CHECKSUM과 서명을 보관 경로(vault)에서 읽게 바꿨다(총괄 승인, 커밋 `1929301`).
   - 서명 키 지문 일치, `gpgv` Good signature, 고정한 SHA-256 일치를 확인한 뒤 적용했다. 확인 방식은 그대로다.
3. **`preflight.sh`가 새 작업 공간에서 FAIL을 냈다 (11/22).**
   - `Terraform state exists but output 'nodes' cannot be read`. `.terraform/`이 없는 새 작업 공간(git worktree)에서는 `terraform init`이 먼저 필요한데, `entry.sh`는 사전 점검(3단계)이 init(5단계)보다 앞이라 init 전에 멈췄다.
   - `preflight.sh`가 `.terraform/`이 없으면 상태 파일에서 직접 `nodes`를 읽게 고쳤다(`1929301`). 그날은 `scripts/tf.sh init`도 한 번 실행했다(총괄 승인, 상태 변경 없음).

**11/22에 새로 찾은 문제**

4. **클러스터 DNS의 `localdomain` 때문에 긴 서비스 이름이 6~10초 걸렸다 → 해결.**
   - 파드에서 `registry.k3slab-system.svc.cluster.local`처럼 점이 4개인 이름을 풀면 6.01초가 걸렸다(모니터링 세션의 Grafana 파드에서는 10.01초 만에 실패). 짧은 이름은 바로 풀렸다.
   - 원인: VM이 DHCP에서 받은 검색 도메인 `localdomain`이 파드의 `resolv.conf`에 붙는다. 그 이름이 상위 DNS로 넘어가 시간 초과가 났다.
   - 조치: CoreDNS의 `coredns-custom`으로 `localdomain` 존을 바로 NXDOMAIN으로 답하게 했다. 적용 뒤 0.01초(VM 노드 파드, 1회)이고 CoreDNS 로그의 시간 초과는 최근 10분 280줄에서 0줄로 줄었다. CoreDNS는 재시작하지 않았다.
   - 이 설정은 Ansible(`k3s_server` 역할)에 넣어서 클러스터를 다시 만들어도 들어간다. 처음부터 다시 만들어 시험하지는 않았다. `*.localdomain` 이름은 이제 풀리지 않는다(이 연구실은 쓰지 않는다). 근거: `docs/labs/dns-localdomain-20261122-1625.md`.
5. **gpu-host의 기본 AppArmor 프로파일이 컨테이너 안에서 자식 프로세스에 신호를 보내는 것을 막았다.**
   - Jenkins C++ 단계의 "워커를 띄우고 SIGTERM으로 끝내 보는" 시험이 `kill: Permission denied`로 실패했다. 같은 이미지를 `Unconfined`로 띄우면 네 신호(`-0`, TERM, KILL, USR1)가 모두 통과했다. 코드 문제가 아니라 노드 환경이다.
   - 조치(총괄 승인): CI의 `gcc` 컨테이너 하나에만 `appArmorProfile: Unconfined`를 줬다. 나머지 격리(seccomp, `privileged: false` 등)는 유지했다. 포기한 것은 그 컨테이너의 AppArmor 한 겹이다.
   - gpu-host에 신호를 허용하는 프로파일을 올리는 대안은 sudo와 호스트 변경이 필요해서 사용자 결정으로 남겼다. 근거: `docs/labs/jenkins-ci-20261122-1658.md` 8절.
6. **Rocky VM 3대에서 node-exporter의 디스크 지표가 빠졌다.**
   - SELinux가 켜진 VM의 기본 라벨로는 호스트의 `/proc/1/mountinfo`를 읽지 못했다(`permission denied`). node-exporter 파드만 `seLinuxOptions.type: spc_t`로 바꾸자 4노드 모두 `/` 디스크 지표가 들어왔다.
   - 포기한 것은 이 파드(컨테이너 하나)의 SELinux 격리다. 루트·`privileged`는 쓰지 않고 호스트 마운트는 읽기 전용이다. 근거: `infra/k8s/monitoring/README.md`.
7. **`apps/train/train.py`의 DONE 검사 순서 결함 (고치지 않음).**
   - 이미 DONE인 작업 번호에 다른 `model_version`을 주면 버전 충돌 검사보다 "already DONE" 검사가 먼저라서 오류 없이 종료 코드 0으로 끝난다. 새 버전의 모델은 만들어지지 않았는데 Job은 성공으로 보인다.
   - 어느 쪽으로 고칠지는 작업 DB 설계가 정할 일이라 고치지 않았다. 지금 동작을 고정하는 단위 시험이 있어서 순서를 바꾸면 그 시험도 같이 고쳐야 한다. 근거: `docs/labs/jenkins-ci-20261122-1658.md` 9절.
8. **"동시 N개"는 설정값이고 실제 연결은 더 적었다.**
   - 장애 실험 F7에서 요청 300개, 동시 150개(설정값)의 실제 최대 연결은 25개였다. 모니터링 시험의 `--parallel-max 300`도 실제 최대 연결은 229개였다.
   - 그래서 시험 스크립트가 실제 연결 수를 따로 재서 보고서에 적는다. 이 문서의 새 문장에서는 "요청 300개, 동시 150개(설정값)"로 적는다.
   - 11/7 측정의 "동시 150개"도 설정값이다. 그때는 실제 연결 수를 재지 않았다.
9. **그 밖의 시행착오** (고치기 전 보고서도 남겨 두었다):
   - Jenkins: 의존 플러그인이 최소 버전으로 설치돼 Declarative Pipeline이 로드되지 않았다(단계 없이 SUCCESS로 끝남) → 플러그인 73개를 전부 고정했다. 플러그인을 받는 init 컨테이너가 메모리 부족으로 죽어 한도를 올렸다. Kaniko가 두 번째 이미지에서 실패해 이미지마다 파드를 쓰게 했다(`jenkins-ci-20261122-1658.md` 10절).
   - CI/CD 연결: 폴링 제외 확장이 에이전트 파드(빌드 뒤 사라짐)와 맞지 않아 같은 규칙을 Jenkinsfile 안으로 옮겼다(`cicd-e2e-20261122-2141.md` 13절).
   - 모니터링: 큐 길이 게이지는 5초 수집이라 짧은 포화를 놓친다. 그래서 장애 실험에서는 클라이언트가 센 코드별 개수를 1차 근거로 쓴다(`monitoring-20261122-1654.md` 9.3절 6번, `fault-overload-20261122-1943.md` 5.2절).

**남은 제약**

- 스냅샷(작업 폴더) 시험 경로 `scripts/jenkins-run.sh`는 고쳤고, 바뀐 `Jenkinsfile`이 그 경로에서 검사 4단계를 통과했다(이미지 없이 1회). `--source-dir`에 최상위 폴더(`infra` 등)가 없으면 메시지 없이 멈추는 문제는 남아 있다(고치지 않음).
- 사용자 결정을 기다리는 것: gpu-host AppArmor 대안(5번), 웹훅(폴링 대신 쓸지), `default`의 시험용 Helm 릴리스 13개를 지울지(`docs/plan-week11-capacity.md` 6절), "큐 20에 동시 300개"라고 적힌 옛 표현의 정리.
- 설계 결정을 기다리는 것: `train.py`의 검사 순서(7번). 작업 DB 쪽 설계가 정할 일이다.

## 다음 주 (12주차) 계획

- 검증 실험 이어서 하기 (`docs/labs/fault-week13-summary-20261122.md` 4절이 넘긴 것). 이 요약은 "14주차로 넘길 것"이라고 적었지만 일정이 앞당겨져 12주차부터 시작할 수 있다. 실험마다 총괄 승인을 받는다.
  - F6 `registry-down`: Jenkins·Kaniko 빌드가 없는 시간을 총괄이 정해 준다.
  - F4 `mysql-down`: 진행 중인 작업이 없는 시간에 한다.
  - F5 `gpu-busy`, F2 `train-kill`: GPU를 쓴다. F2·F4가 `train-resume-*`, `job-db-*` 보고서를 새로 쓰는 것은 승인돼 있다.
  - F1·F8의 GPU 변형(`--gpu 1`): 예전 컨테이너가 GPU를 쥔 채 새 파드가 뜰 때의 Pending, `maxSurge 0`으로 서비스가 끊기는지 확인한다.
  - F1 `--mode graceful`(SIGTERM + preStop 5초).
  - F1 CPU 반복: 복구 시간이 1회 값이라 두세 번 더 재서 판정 기준(제안: 10초 안팎)을 정한다.
  - F3 `node-stop`은 worker-cpu-2에 Argo CD가 있어서 나중에 따로 정한다.
- 장애 실험마다 Grafana 화면을 저장한다(지금 보고서에는 Prometheus 쿼리 결과만 있고 대시보드 캡처는 없다).
- 학습 Job이 돌 때의 학습 대시보드 패널과 GPU 학습 중의 DCGM 값을 확인한다(`monitoring-20261122-1654.md` 9.4절).
- 최종 보고 준비: `docs/final-report.md`의 5·6·8절을 실험 결과로 확정하고, 구성도·기술 스택 그림에 Jenkins·Argo CD·Gitea·모니터링을 추가한다.

## 아직 채우지 못한 것

- F2~F6과 GPU 변형, F3의 측정값: 12주차 이후에 실험한다.

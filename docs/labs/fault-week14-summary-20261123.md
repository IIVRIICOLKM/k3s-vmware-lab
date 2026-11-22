# 14주차 장애 실험 요약과 다음 단계 인계 (2026-11-23)

`scripts/fault-test.sh`로 계획 6절의 순서 4~6(F6, F4, F1 CPU 반복·graceful, GPU 실험 F5·F1·F8, F2)을 실제 클러스터에서 실행했다. 오늘(2026-11-23, 월)은 1주차(9/7) 기준 **12주차 첫날**이다. 제안서 일정의 14주 몫(검증 실험 13–16주)을 앞당겨 했다. 실험마다 총괄이 미리 승인한 명령을 `--yes`로 실행했고, 명령 줄은 각 보고서 머리에 그대로 남아 있다. F3 `node-stop`은 15주 몫이라 하지 않았다.

- 실험마다 시작 직전에 노드 4개 Ready, `k3slab-fault` 없음, MySQL·레지스트리 1/1, `ci`에 `jenkins-0`만 있음(에이전트 파드 없음), GPU를 요청한 파드 0을 확인했다. F6·F4는 Jenkins API로 대기열이 비었고 빌드가 돌지 않는 것도 확인했다(로그인 값은 화면·로그에 남기지 않았다). 그 사이 Argo CD Application은 0개였다.
- 실험마다 끝난 뒤 `k3slab-fault`가 없고 노드 4개 Ready, MySQL·레지스트리 1/1임을 확인했다(스크립트의 "되돌리기" 판정). GPU 실험은 GPU를 요청한 파드 0도, F2는 `default`의 `train-<번호>` 릴리스가 지워진 것도 판정에 들어 있다.
- **GPU 반납:** 마지막 실험(F2 graceful, 04:17:48)이 끝난 뒤와 정리 단계(04:18경)에 GPU를 요청한 파드가 0개, `k3slab-fault` 네임스페이스 없음, 노드 4개 Ready, MySQL·레지스트리 1/1임을 다시 확인했다. 내가 띄운 임시 port-forward(Grafana 촬영용)는 모두 직접 끊었고 이름으로 프로세스를 죽인 적은 없다.
- 이미지 태그: **CPU 실험(F6, F4, F1 CPU)은 `infer-worker:v0.2`**(13주와 같다, `values-infer.yaml` 기본). **GPU 실험(F5, F1 GPU, F8 GPU)은 `--tag git-760a534`**(CI가 만든 최신, 지연 히스토그램 있음). F2는 학습 이미지 `train-worker:v0.4`(차트 기본). 추론 모델은 모두 `db-1107b-train`.

## 1. 보고서와 핵심 숫자

| 실험 | 보고서 | 결과 | 핵심 숫자 |
|---|---|---|---|
| F6 `registry-down` (60초) | `docs/labs/fault-registry-down-20261123-0346.md` | PASS 8 / FAIL 0 | **t_reg 1.6초, t_pull 40.7초**. 노드에 이미지가 있으면(`IfNotPresent`) 중단 중에도 1.4초에 Running. 확인이 필요한 파드(`Always`)는 `ErrImagePull` → `ImagePullBackOff`(`connection refused`). 복구 뒤 카탈로그에 `infer-worker` 유지 |
| F4 `mysql-down` | `docs/labs/fault-mysql-down-20261123-0351.md` | PASS 11 / FAIL 0 | **`job.sh submit`(DB 없음)의 종료 코드 1**. 추론 실패 0 / 1932. t_db 6.9초. 행 수 14 → 14, `job_events` 84 → 84. 실제 DB 없음 구간 196.1초(요청한 75초가 아님, 아래 2절 2번) |
| F1 CPU 반복 (force 2·3회) | `fault-infer-kill-20261123-0357.md`, `fault-infer-kill-20261123-0358.md` | 각 PASS 8 / FAIL 0 | 복구 **1.5초, 1.4초**. 실패 요청 0 / 183, 0 / 176. 새 파드 1개, 재시작 0 |
| F1 CPU graceful | `fault-infer-kill-20261123-0359.md` | PASS 8 / FAIL 0 | 복구 **1.3초**, 실패 0 / 175. preStop 5초는 복구 시간에 들어가지 않음 |
| F5 `gpu-busy` | `fault-gpu-busy-20261123-0402.md` (**FAIL 1**: 스크립트 타이밍 결함) → 고친 뒤 `fault-gpu-busy-20261123-0404.md` | 0402: PASS 10 / FAIL 1, 0404: **PASS 11 / FAIL 0** | GPU 요청 파드 **Pending**(`1 Insufficient nvidia.com/gpu`), 저절로 CPU로 넘어가지 않음. 대체 배포(`gpu=0`·`auto`) Ready: t_fb 6.7초(Service 대기 5초 포함, 약 1.7초). 장치 cpu. GPU 복귀 전환 12.5초(약 7.5초), 전환 중 실패 3 / 154(첫 실행 0 / 136) |
| F1 `--gpu 1` (force) | `fault-infer-kill-20261123-0407.md` | PASS 9 / FAIL 0 | 복구 **1.5초**(새 파드 Ready +1초), 실패 0 / 177, 장치 cuda. **Pending·배정 실패 없음** |
| F8 `bad-deploy --gpu 1` (관찰만) | `fault-bad-deploy-20261123-0409.md` | PASS 8 / FAIL 0 (서비스 유지 여부는 판정하지 않음) | 새 파드 `ErrImagePull`까지 11.7초. 예전 파드 없음. **실패 90 / 299, 실패 구간 46.8초**(T0 + 4.5 ~ 51.3초). 롤백 9.8초 |
| F2 `train-kill --mode force` | `fault-train-kill-20261123-0413.md` | PASS 8 / FAIL 0 | 중단→재개 **15.8초**, 재개 체크포인트 `ckpt-e0002-s00200`(에폭 2), **완료 에폭 손실 0**(진행 중이던 에폭 3은 다시), attempts 2, DONE(에폭 8) |
| F2 `train-kill` (graceful) | `fault-train-kill-20261123-0416.md`, `docs/labs/train-resume-20261123-0416.md`(`train-resume-test.sh`가 새로 만든 보고서) | PASS 9 / FAIL 0 (안쪽 PASS 6 / FAIL 0) | 중단→재개 **14.1초**(DB 시각), 재개 체크포인트 `ckpt-e0003-s00001` = 중단 체크포인트(**손실 0**, 에폭 3의 1스텝까지 보존), DONE(에폭 6) |

그림(실험마다 한 장, 제안서 14번의 "Grafana 화면 저장"): `fault-registry-down-20261123-0346-dashboard.png`(노드 대시보드), `fault-mysql-down-20261123-0351-dashboard.png`(학습 작업 대시보드, **MySQL이 끊긴 구간**), `fault-gpu-busy-20261123-0404-dashboard.png`(추론 대시보드, 장치 cuda), `fault-infer-kill-20261123-0407-dashboard.png`(추론 대시보드, GPU 파드 종료 뒤), `fault-train-kill-20261123-0413-dashboard.png`와 `…-dashboard-done.png`(학습 대시보드, 학습 중·끝난 뒤). 각 그림의 시간 범위와 보이는 것은 보고서 "사람이 덧붙인 부분"에 적었다.

### 1.1 F1 CPU 세 번의 복구 시간과 판정 기준 제안

| 회차 | 보고서 | 종료 방식 | 복구 시간 | 실패 요청 |
|---|---|---|---|---|
| 1 (13주) | `fault-infer-kill-20261122-2041.md` | force | **1.4초** | 1 / 179 |
| 2 | `fault-infer-kill-20261123-0357.md` | force | **1.5초** | 0 / 183 |
| 3 | `fault-infer-kill-20261123-0358.md` | force | **1.4초** | 0 / 176 |
| graceful | `fault-infer-kill-20261123-0359.md` | graceful | **1.3초** | 0 / 175 |
| GPU | `fault-infer-kill-20261123-0407.md` | force (`git-760a534`) | **1.5초** | 0 / 177 |

- 세 번(force)의 차이는 0.1초로 확인 간격(1초)과 `kubectl` 응답 시간 안이다. 새 파드는 모두 생성·스케줄·시작이 같은 초였다. gpu-host CPU가 1056m ~ 2376m로 달랐지만 복구 시간은 같았다.
- **제안한 판정 기준: 복구 시간 10초 이내(CPU·GPU 공통, 작은 모델이고 이미지가 노드에 있을 때).** 실측 최댓값 1.5초의 약 6.7배다. 기존 임시 기준(60초, GPU 120초)은 실측의 40~80배라 이상을 잡아내지 못한다. 실패 요청 수는 4번 중 1번만 1개라서 기준으로 쓰지 않고 관찰값으로 둔다. 큰 모델(`bench-large` 68 MB 등)이나 이미지를 새로 받는 경우는 이 기준을 쓰지 않고 다시 잰 뒤 정한다. `scripts/fault-test.sh`의 기준값과 `docs/plan-week13-verification.md` 4절 F1 성공 기준에 반영했다.

### 1.2 GPU 실험의 Pending·배정 실패

| 실험 | Pending·배정 실패 | 서비스 끊김 |
|---|---|---|
| F5 | GPU를 다른 파드가 쥐고 있으면 GPU 요청 추론 파드는 **Pending**(사유 `0/4 nodes are available: 1 Insufficient nvidia.com/gpu, 3 node(s) didn't match Pod's node affinity/selector`, 15초 뒤에도 그대로). `DEVICE=auto`로는 풀리지 않고 `gpu=0` 재배포(수동 개입)가 대체 경로다 | CPU→GPU 전환 중 0 / 136(첫 실행), 3 / 154(둘째, T0 + 5.0 ~ 6.2초) |
| F1 `--gpu 1` | **없음.** 강제 삭제 뒤 새 파드가 같은 초에 만들어져 바로 스케줄되고 Running이 됨(계획은 Pending·배정 실패 가능성을 예상했다) | 0 / 177 |
| F8 `--gpu 1` | 새 파드는 이미지 받기 실패로 Pending에 머묾(의도한 장애) | **46.8초**(예전 파드가 먼저 내려가서) |

### 1.3 F2의 중단 → 재개 시간과 재개 체크포인트

| | force (SIGKILL) | graceful (SIGTERM) | 11/7 기록 (graceful) |
|---|---|---|---|
| 중단 → 재개 | 15.8초 | 14.1초 | 14초 |
| 재개 체크포인트 | `ckpt-e0002-s00200.pt`(마지막 에폭 끝) | `ckpt-e0003-s00001.pt`(중단 시점) | 중단 체크포인트와 같음 |
| 손실 | 완료 에폭 0, 진행 중이던 에폭 3은 처음부터 | 0 | 0 |

재개 시간은 둘 다 14~16초로 거의 같고, 차이는 **중단 시점의 진행량을 보존하느냐**다. 이 실험의 에폭은 짧아서(계산 약 0.4초 + 쉼) force의 손실도 작다. 에폭이 길면 force의 손실이 에폭 하나만큼 늘 수 있다(재 보지 않았다).

### 1.4 모니터링 9.4절 "못 본 것" 중 채워진 것 (학습 대시보드와 DCGM)

`docs/labs/fault-train-kill-20261123-0413.md` 4.2·4.3절에 화면과 Prometheus 쿼리 결과가 있다.

- **학습 Job 진행률·진행 에폭 패널: 확인했다.** 학습 중 화면에서 진행률 50%(에폭 4 / 8), 진행 에폭 `fault-1123-force` 4 / 8, 작업 목록 RUNNING attempts 2. 작업이 DONE이 되면 두 패널은 비는 것이 맞다(PENDING·RUNNING·INTERRUPTED만 본다).
- **학습 파드 CPU·메모리 패널: 확인했다.** 단, **CPU 패널은 첫 화면(재개 20~30초 뒤)에서 "No data"였고 학습이 끝난 뒤 같은 패널이 값을 냈다**(`…kdvgj` 최대 약 0.24코어, 30초 rate 최대 0.41코어). cAdvisor 수집이 15초 간격이라 값이 두 개 미만이면 `rate()`가 비는 것으로 보인다. **수집 간격보다 짧게 산 파드(강제 종료된 첫 파드, 약 8초)는 CPU 선이 아예 없다.** 메모리는 재개된 파드가 최대 716 MiB(첫 파드 121 MiB).
- **GPU 학습 중 DCGM 값: 확인했다.** 학습 전 기준선 사용률 30~37%(데스크톱), 메모리 1173 MiB, 전력 약 47 W → 학습 중 메모리 1444 ~ 1757 MiB(+270 ~ +580 MiB), 전력 103 ~ 152 W, 온도 44 ~ 56 °C → 학습 뒤 기준선 복귀. **사용률은 학습의 부하로 읽을 수 없다**(학습 중 4 ~ 17%, 학습 없는 순간에도 54%까지). 모델이 작고(hidden 128) 에폭마다 6초 쉬어서 GPU 계산이 거의 없다. 강제 종료 뒤 GPU 메모리는 8초 안에 해제됐다(5초 간격 샘플).
- **여전히 못 본 것:** 보존 7일이 실제로 오래된 블록을 지우는지, 대시보드 JSON 핫 리로드(이 작업의 범위 밖).

## 2. 계획과 달라진 점

1. **F4: `job.sh submit`은 DB가 없을 때 종료 코드는 1이지만 두 가지가 문제다**(`scripts/job.sh`는 내 수정 범위 밖이라 고치지 않고 보고한다). ① 메시지가 사실과 다르다: `job … already exists; not starting it again (status below)`가 찍힌다. `register`가 실패해 출력이 비면 `[[ "$(register …)" != 1 ]]`가 참이 되어 "이미 있음" 분기로 가기 때문이다(`job.sh` 104행, `show_existing` 75행). ② 약 120초 멈춘다: `kubectl exec deploy/mysql`이 파드가 없으면 60초 기다리고(`timed out waiting for the condition`), 그 대기가 `register`와 `show_existing`에서 한 번씩 일어난다. 제안: `register` 실패와 "이미 있음"을 구분해 `die`로 끝내고, `sql()`의 `kubectl exec`에 `--pod-running-timeout=5s` 같은 짧은 한도를 준다. Job·Helm 릴리스·`jobs` 행은 만들어지지 않았다(PASS).
2. **F4: 실제 DB 없음 구간이 요청한 시간보다 길었다.** 위 120초 대기 때문에 `--down-seconds 75`가 실제 196.1초가 됐다(스크립트는 등록 요청이 끝난 뒤에 `sleep`한다). 추론 요청은 그 전 구간에서 한 번도 실패하지 않았다(0 / 1932). `--down-seconds 75`는 Grafana에 MySQL이 끊긴 구간을 담으려고 기본 30초에서 늘렸다(촬영에 약 30초 걸린다).
3. **F1 GPU: 계획이 예상한 Pending·배정 실패가 없었다.** `--force` 삭제는 파드 오브젝트를 바로 지워 새 파드가 같은 초에 스케줄됐다(추정: 스케줄러가 GPU를 비었다고 봄. 두 컨테이너가 GPU를 동시에 쥔 시간은 재지 않았다). 한 번의 시행이다.
4. **F5·F8 GPU: 서비스 끊김의 크기는 새 GPU 파드가 Ready가 되는 시간에 달렸다.** F5 CPU→GPU 전환은 0개(첫 실행)와 3개(1.2초 구간)였고, F8은 예전 파드가 없어 46.8초 끊겼다. 추정: 종료 중인 예전 파드는 preStop 5초 동안 요청을 받는다(첫 실패가 T0 + 4.5 ~ 5.0초). 직접 확인하지는 않았다.
5. **F8 GPU 롤백 9.8초는 CPU(0.3초)와 의미가 다르다.** CPU는 설정만 되돌렸고, GPU는 예전 파드가 없어서 정상 파드를 새로 띄운 시간이다(13주 요약 2절 3번의 예상이 확인됨). 서비스 공백은 "롤백을 언제 하느냐"가 좌우한다.
6. **F6: t_pull 40.7초는 한 번 잰 값이고 이미지 받기 재시도 간격 규칙과 맞는지는 확인하지 못했다.** 재시도 시각을 기록하지 않았다. 간격 상한(5분)을 보려면 중단 시간을 길게 해서 다시 재야 한다. 노드에 이미지가 있어도 `Always` 파드는 레지스트리가 없으면 실패한다는 점은 확인됐다.
7. **F2 force: 손실이 최소인 조건이다.** 스크립트가 에폭 2 기록 직후(약 1~2초)에 죽여서 완료 에폭 손실이 0이다. 에폭 중간에 죽이면 그 에폭의 계산이 사라지는데, 이번 에폭은 계산 약 0.4초 + 쉼 6초라 차이가 작다.
8. **F5 보고서 문구와 GPU 판정이 실제와 어긋나 있었다.** 첫 실행(0402)의 FAIL 1건은 실험 결과가 아니라 스크립트의 타이밍 결함이다(3절 1번). "GPU가 비면 cuda로 복귀" 판정은 Helm 배포가 Ready가 되었는지만 보고 장치가 `cuda`인지는 판정하지 않는다(`/metrics` 값은 Grafana "장치" 카드로 확인했다). 판정에 넣을지는 총괄이 정한다.
9. **촬영 부하가 그림에 섞인다.** 같은 PC에서 헤드리스 Chromium이 돌면 VM과 gpu-host가 CPU를 나눠 쓰므로 모든 노드 CPU가 약 60%까지 오른다(F6 그림의 오른쪽 끝, 실험이 끝난 뒤의 촬영). 추론·학습 대시보드에는 노드 CPU 패널이 없어 이 영향이 그림에 보이지 않지만, F4(DB 없음 구간 중), F5·F1 GPU(전환·복구 직후, 프로버가 돌던 때), F2(재개 기록 직후)는 실험이 끝나기 전에 찍었다. **측정이 끝난 뒤나 판정과 무관한 구간에서 찍었고** F4 프로버는 촬영 중에도 실패 0이었지만, 촬영이 측정에 영향을 주지 않았다고 단정하지는 않는다.
10. **GPU 사용률·전력에 데스크톱 잡음이 있다.** 실험 전에도 사용률 30~55%가 나왔다(모니터링 9.3절 8번과 같은 종류). 전력은 GPU 추론 파드·학습 파드가 CUDA를 쓰기 시작하면 약 47 → 103 ~ 152 W로 오르고(F5·F1·F2에서 같은 모양) 요청이 거의 없어도 유지됐다. 원인은 확인하지 못했다.

## 3. `scripts/fault-test.sh`에서 바꾼 줄과 이유

모든 변경은 `bash -n`, 5개 하위 명령의 `--dry-run`, `scripts/verify-project.sh`(필수 파일 155개, 문법 OK)로 확인했다. 실제 실행으로 확인한 것: GPU 반납 확인(F5 재실행, F1·F8 GPU, F2), `ci_pods_block`(F4, F5, F2). **실행으로 확인하지 못한 것:** F6의 `ci_pods_block`(F6 실행 뒤에 넣음)과 F1 기준 10초(모든 F1 실행 뒤에 넣음, `--dry-run` 출력으로만 확인).

| 위치(함수) | 바꾼 것 | 이유 |
|---|---|---|
| `run_gpu_busy` 끝(`wait_for 60 gpu_free`와 "GPU를 쓰는 파드가 남아 있지 않음" 판정) | 확인 전에 종료 중인 파드가 사라지기를 최대 60초 기다린다 | **F5 첫 실행의 FAIL 원인.** `helm uninstall` 직후 지워지는 파드는 종료 유예 동안 phase가 `Running`이라 `gpu_pods`가 센다. 실제로는 GPU가 반납됐다(바로 뒤에 확인). 고친 뒤 같은 실험이 PASS 11 / FAIL 0 |
| `run_gpu_busy` 3절 `note` | "전환 구간 실패는 예상한 값이다" → "예상했고 실제 수는 위 지표, 전환 시간에는 Service 대기 5초 포함" | 실제 결과(첫 실행 0개)와 어긋나는 단정 문구 |
| `verify_restored` | `--gpu 1`이면 `wait_for 60 gpu_free`와 "GPU를 쓰는 파드가 남아 있지 않음 (GPU 반납)" 판정 추가 | 계획 8절 안전 규칙(GPU 실험 뒤 반납 확인)을 F1·F8 GPU 보고서에 남기기 위해. F1·F8 GPU 실행에서 PASS |
| `run_train_kill` 끝 | `wait_for 60 gpu_free`, "GPU 반납" 판정, "default의 train-<번호> Helm 릴리스가 지워짐" 판정 추가 | F2는 `verify_restored`를 쓰지 않아 GPU 반납과 릴리스 제거 확인이 없었다(총괄 지시: F2는 `default`의 릴리스가 지워졌는지 본다) |
| `run_registry_down`, `run_mysql_down`, `run_gpu_busy`, `run_train_kill`의 `begin_report` 뒤 | `ci_pods_block "실험 시작"` 호출 추가 | F1·F7·F8에만 있던 `ci` 파드·gpu-host CPU 기록을 모든 실험에 맞춘다(총괄 지시: 시작 직전 `ci` 확인을 보고서에 남김). F6는 이 줄을 넣기 전에 실행해서 보고서에는 사람이 적은 점검(4.2절)이 있다 |
| `show_plan`·`run_infer_kill`의 `lim`과 판정 문구 | 복구 시간 기준 60초(GPU 120초) → **10초**, 문구에 "작은 모델 기준: 반복 실측 1.3~1.5초, 큰 모델은 다시 정한다" | 1.1절의 제안. F1 CPU 3회·graceful·GPU 실측에 맞춤 |

- 바꾸지 않은 것: `job.sh`(F4 문제), `train-resume-test.sh`, 다른 하위 명령. 위 줄 번호는 변경 시점마다 달라져서 함수 이름으로 적었다.

## 4. 15주(F3 node-stop 기본 → `--spread` → `--toleration-seconds 30`, 재시험)로 넘길 것

- **F3 `node-stop`(승인 필요, 가장 파괴적):** 순서는 계획 6절 7번 — 기본 → `--spread` → `--toleration-seconds 30`, 한 번에 한 가지만 바꾼다. **대상 노드를 정해야 한다.** 기본 `worker-cpu-2`에는 지금 Argo CD 4개 파드(`application-controller`, `redis`, `repo-server`, `server`)와 Gitea, `k3slab-lab`의 `echo-api` 3개, node-exporter가 떠 있다. **Gitea와 Argo CD는 `nodeSelector: k3slab.io/role=app`이라 다른 노드로 옮겨 갈 수 없다**(role=app 노드는 worker-cpu-2뿐) → VM을 끄면 Gitea(CI 소스)와 Argo CD가 VM이 돌아올 때까지 멈춘다. 스크립트는 `--allow-other-pods` 없이는 시작하지 않으므로, CICD 담당과 시간을 맞추고(그동안 Jenkins 폴링·Argo CD 동기화·`k3slab-ci` 빌드가 실패한다) `--allow-other-pods`를 줄지 총괄이 정한다. worker-cpu-2 메모리 limits는 안전 한도의 93%라 재배치된 파드를 받을 여유도 작다(다른 노드는 worker-cpu-1 6GB).
- **F3 시작 전 확인:** VMware 커널 모듈(`vmmon`, `vmnet`)이 올라와 있고 VM이 `vmrun list`에 있는지(스크립트가 확인하고 없으면 시작하지 않는다). 복구 단계는 장애 전에 등록되어 스크립트가 끊겨도 VM을 켠다. 기록 대조: `k3s-lab-20261030-1646.md` 5절(NotReady 44초, 재배치 합계 352초).
- **F3 Grafana 화면:** 노드 대시보드(Ready 노드 4 → 3, 노드별 파드 수, CPU)가 맞다. 촬영은 `kubectl port-forward` + Playwright, 로그인 값은 비밀 파일에서 읽어 환경변수로만 넘긴다(이번 단계에서 쓴 방식과 같다). **촬영은 실험이 끝난 뒤에 한다**(촬영이 CPU를 올린다, 2절 9번).
- **재시험 후보:** (a) F6를 중단 시간 길게(`--down-seconds 180` 등) 다시 재서 `ImagePullBackOff` 재시도 간격 규칙을 확인. (b) F2 force를 에폭 중간에 죽이거나 에폭이 긴 조건(`--epoch-sleep`을 키움)으로 다시 재서 손실 에폭을 보기. (c) F1을 큰 모델(`bench-large` 68 MB 등)과 GPU로 재서 10초 기준을 정하기. (d) F8 GPU를 `helm upgrade --atomic`이나 CI의 이미지 존재 확인 단계와 함께 재서 서비스 공백이 줄어드는지 보기(이 연구 범위인지는 총괄이 정한다). (e) F7 확장(스레드 풀이 한도가 되는 더 센 부하, 13주 요약 4절).
- **다른 담당에게 보고(고치지 않았다):**
  - `scripts/job.sh`(작업 DB 담당): F4의 두 문제(2절 1번). 고치면 F4를 다시 재서 "빠르게 실패하고 올바른 메시지"를 확인할 수 있다.
  - 모니터링 담당: 학습 파드 CPU 패널은 수집 간격 15초보다 짧게 산 파드를 보여 주지 못한다. `infra/k8s/monitoring/README.md`의 알려진 한계에 적을지, 학습 파드 수집을 짧게 할지 정한다. 모니터링 보고서 9.4절의 "학습 대시보드 패널·DCGM(학습 중)"은 이 문서 1.4절로 채워졌다.
  - 플랫폼 담당(참고): 이번 실험 중 `kubectl top`에서 k3s-server 메모리가 2163Mi(79%, VM 3GB)였다. 이 값을 높이는 조작은 하지 않았다.
- **측정 방법 메모:** 큐 길이 게이지는 짧은 포화를 놓치므로 코드별 개수가 1차 근거다(13주 요약과 같음). 서비스 끊김의 크기는 프로버의 **실패 구간(초)**으로 읽고 실패 요청 수는 보조로 본다(실패하는 요청은 대기 시간만큼 느리게 쌓인다). 복구 시간과 전환 시간에는 `infer_deploy`가 더하는 Service 대기 5초가 포함되는 값이 있다(F5의 t_fb·전환 시간).

## 5. 공유 파일에 필요한 변경 (고치지 않았고 총괄이 합칠 때 처리)

1. `docs/README.md` 114행 근처 표: 이 문서와 새 보고서 줄을 넣는다. 예: `장애 실험 14주 몫 요약 (레지스트리·MySQL 중단, 추론 파드 종료 반복·graceful, GPU 실험, 학습 파드 중단·재개)` → `labs/fault-week14-summary-20261123.md`. 새 보고서 목록(위 1절 표): `fault-registry-down-20261123-0346.md`, `fault-mysql-down-20261123-0351.md`, `fault-infer-kill-20261123-0357.md`·`-0358.md`·`-0359.md`·`-0407.md`, `fault-gpu-busy-20261123-0402.md`·`-0404.md`, `fault-bad-deploy-20261123-0409.md`, `fault-train-kill-20261123-0413.md`·`-0416.md`, `train-resume-20261123-0416.md`, 그림 6장(`fault-*-dashboard*.png`). 표에 줄 하나로 묶을지 줄별로 넣을지는 총괄이 정한다.
2. `README.md` 200행 체크리스트의 "장애 상황 검증 (과부하·잘못된 배포·추론 파드 강제 종료 완료 …)"에 이번 완료분을 더한다. 예: "… 레지스트리·MySQL 중단, GPU 변형, 학습 파드 중단·재개 완료, 노드 정지(F3)만 남음".
3. `scripts/verify-project.sh`: 필수 파일 목록에 `docs/labs/fault-week14-summary-20261123.md`를 넣을지(지금은 13주 요약도 목록에 없다). 넣는다면 두 요약을 함께 넣는다. `scripts/fault-test.sh`와 `docs/plan-week13-verification.md`는 이미 목록에 있다.
4. (참고) `scripts/job.sh`와 `infra/k8s/monitoring/README.md`는 각 담당이 고친다(위 4절). `scripts/image-build.sh`는 쓰지 않았고 `docs/image-builds.md`에 추가된 줄은 없다.
5. `docs/plan-week13-verification.md`는 내 수정 허용 범위(상태 줄, 4절 F1 성공 기준, 6절 실행 결과)만 고쳤다. 같은 문서의 2.3절 표 등 다른 곳의 "예상" 문구(예: F1 GPU의 Pending 예상)는 실측과 다르지만 고치지 않았다. 필요하면 총괄이 정한다.

## 6. 바꾸거나 만든 파일

- 고침: `scripts/fault-test.sh`, `docs/plan-week13-verification.md`
- 새 보고서: `docs/labs/fault-registry-down-20261123-0346.md`, `fault-mysql-down-20261123-0351.md`, `fault-infer-kill-20261123-0357.md`, `-0358.md`, `-0359.md`, `-0407.md`, `fault-gpu-busy-20261123-0402.md`, `-0404.md`, `fault-bad-deploy-20261123-0409.md`, `fault-train-kill-20261123-0413.md`, `-0416.md`, `train-resume-20261123-0416.md`(스크립트가 만든 것), 이 요약
- 새 그림: `docs/labs/fault-registry-down-20261123-0346-dashboard.png`, `fault-mysql-down-20261123-0351-dashboard.png`, `fault-gpu-busy-20261123-0404-dashboard.png`, `fault-infer-kill-20261123-0407-dashboard.png`, `fault-train-kill-20261123-0413-dashboard.png`, `fault-train-kill-20261123-0413-dashboard-done.png`
- 증거로 남긴 클러스터 쪽 흔적(저장소 밖): MySQL `jobs`에 `fault-1123-force`, `fault-1123-graceful`(DONE), 체크포인트 폴더 `/var/lib/k3slab/checkpoints/fault-1123-force`, `fault-1123-graceful`(root 소유라 지우지 않았다)

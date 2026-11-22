# 13주차 검증 계획: 장애 상황 실험 설계

연구제안서 14·15번 슬라이드의 "중단 상황 시나리오"를 실제로 돌리기 위한 설계 문서다(검증 실험 13–16주).
물리 호스트가 하나인 구성에서 **막을 수 없는 장애**와 **막을 수 있는 장애**를 나누고, 막을 수 있는 장애를 하나씩 일으켜 복구 시간과 영향을 잰다.

- 상태(2026-11-23, 12주차 첫날): **설계와 실행 스크립트까지 끝났고, 13주 몫(`inspect`, F7, F8 CPU, F1 CPU)에 이어 14주 몫(순서 4~6)을 앞당겨 실행했다.** 13주 몫 결과는 `docs/labs/fault-inspect-20261122-1940.md`, `fault-overload-20261122-1943.md`, `fault-bad-deploy-20261122-2038.md`, `fault-infer-kill-20261122-2041.md`와 `docs/labs/fault-week13-summary-20261122.md`에, 14주 몫(F6, F4, F1 CPU 반복·graceful, GPU 변형 F5·F1·F8, F2 force·graceful)의 보고서와 요약·인계는 `docs/labs/fault-week14-summary-20261123.md`에 있다(실행 결과는 6절). **남은 것은 F3 `node-stop`(기본 → `--spread` → `--toleration-seconds 30`, 15주 몫)과 재시험이다.** 실험 실행은 실험마다 총괄 승인을 받는다.
- 실행 스크립트: `scripts/fault-test.sh` (하위 명령 하나가 실험 하나). `--dry-run`으로 절차만 볼 수 있다.
- 결과 보고서: 실험마다 `docs/labs/fault-<실험>-<날짜>.md`가 만들어진다.
- 근거: `docs/progress-week09.md`("장애 영역 정리"), 기존 시험 기록 `docs/labs/`, 저장소의 매니페스트·차트·Ansible 설정.
- 이 문서의 **"예상"** 표시는 코드와 설정을 읽고 세운 가설이다. 실험하기 전에는 측정값이 아니다.

## 1. 범위와 용어

| 용어 | 이 문서에서의 뜻 |
|---|---|
| 막을 수 없는 장애 | 물리 호스트·GPU·디스크가 하나뿐이라 소프트웨어 설정으로는 대신할 곳이 없는 장애. 이 연구는 **영향과 복구 한계를 문서로 남긴다**(실험으로 일으키지 않는다). |
| 막을 수 있는 장애 | 쿠버네티스·Helm·앱 설정으로 자동 복구되거나 영향을 줄일 수 있는 장애. **하나씩 일으켜 잰다.** |
| 복구 시간 | 장애를 일으킨 시각부터 서비스(파드·노드·요청)가 정상으로 돌아온 시각까지의 초. |
| 영향 | 그동안 실패한 요청 수, 실패 구간, 잃은 진행량(학습 에폭 등). |
| 자동 / 수동 | 사람이 명령을 치지 않고 돌아오면 자동. 사람이 해야 하는 일은 "수동 개입 지점"으로 따로 적는다(제안서 15번 기대 효과). |

## 2. 장애 영역 정리

### 2.1 현재 구성의 단일 지점

| 구성요소 | 위치 | 사본·복제본 | 데이터가 있는 곳 | 근거 |
|---|---|---|---|---|
| 물리 호스트(전원·OS·VMware Workstation) | 데스크톱 1대 | 없음 | — | VM 3대와 gpu-host가 모두 이 PC 위 |
| GPU (RTX 3090) | gpu-host | 1장 | — | `charts/k3slab-workload/values.yaml`("The cluster has one") |
| 컨트롤 플레인 | k3s-server VM | 1대, 내장 데이터스토어(SQLite) | k3s-server VM 디스크 | `infra/ansible/roles/k3s_server/tasks/main.yml`: 데이터스토어·etcd 옵션이 없어 K3s 기본값이다 |
| 플랫폼 서비스(MySQL, 레지스트리) | worker-cpu-1 VM | 각 1개, `strategy: Recreate` | local-path PVC(5Gi, 20Gi): VM 디스크 | `infra/k8s/mysql.yaml`, `registry.yaml` |
| 학습 체크포인트·모델·입력 파일 | gpu-host | 폴더 하나 | `/var/lib/k3slab/checkpoints`, `/datasets`(hostPath) | `values.yaml`의 `checkpoints.hostPath`, `datasets.hostPath` |
| 추론 워커 | gpu-host 고정 | 1개 | 모델은 위 hostPath에서 읽음 | `values.yaml`의 `nodeSelector: role=gpu`, `infer-deployment.yaml`의 `models` 볼륨 |
| API·전처리 파드 대역 | worker-cpu-2 선호 | 3개 | 없음(무상태) | `infra/k8s/labs/20-echo-api.yaml` |

`scripts/fault-test.sh inspect`가 같은 내용을 실제 클러스터에서 읽기 전용으로 모아 `docs/labs/fault-inspect-<날짜>.md`에 남긴다(노드 수, 컨트롤 플레인 수, PV가 묶인 노드, 복제본 1개짜리 Deployment, GPU 수).

### 2.2 막을 수 없는 장애 (실험하지 않고 기록)

| 장애 | 왜 막을 수 없나 | 일어나면 | 복구 가능한 것 / 잃는 것 |
|---|---|---|---|
| 물리 호스트 정전·OS 중단·재부팅 | 호스트가 하나라서 VM 3대와 gpu-host가 한꺼번에 내려간다. 복제본을 둘 다른 장비가 없다. | 클러스터 전체 중단. 예: 2026-11-20 커널 업데이트 뒤 VMware 커널 모듈(vmmon, vmnet)이 없어 VM을 켜지 못했다(총괄 기록, 저장소 문서에는 아직 없음). | 호스트가 돌아오고 모듈이 맞으면 `scripts/entry.sh`로 VM·노드 복구. 디스크 데이터는 그대로. |
| GPU 고장 | GPU가 1장, GPU 노드가 gpu-host 하나다. | 학습 Job은 GPU 1개를 요청하므로 Pending. 추론은 CPU 경로로 돌릴 수 있다(F5). | 추론은 CPU로 계속(느림). 학습은 `train.py`가 GPU가 없으면 CPU로 돈다는 것을 코드(`apps/train/train.py:191`)에서 확인했지만, 차트가 GPU를 요청하므로 CPU 학습은 시험하지 않았다. |
| 물리 디스크 고장 | VM 디스크 파일, gpu-host 폴더, local-path PVC가 모두 이 PC의 디스크 위에 있다. 백업이 없다. | 모든 VM·데이터 손실. | **재구축 가능:** Git의 코드, Terraform·Ansible(`entry.sh`), Helm 차트, 이미지(`scripts/image-build.sh`로 다시 빌드, 기록은 `docs/image-builds.md`). **복구 불가:** MySQL 작업 이력, 체크포인트·모델, 업로드한 입력 파일, 레지스트리 안의 이미지(다시 빌드해야 함). |
| gpu-host 노드 중단 | 호스트 OS 자신이 노드다. 모델·체크포인트가 이 노드의 hostPath이고 추론 워커가 이 노드에 고정이다. | 학습·추론이 모두 멈춘다. VM 노드로 옮길 수 없다(모델 파일이 없다). CPU 대체 경로도 **같은 gpu-host 안에서만** 돈다. | 노드가 돌아오면 재개(체크포인트는 디스크에 있음). |
| worker-cpu-1 VM 중단 | MySQL·레지스트리가 `nodeSelector: platform`이고 PV도 이 노드 디스크에 묶인다(local-path). | MySQL·레지스트리 파드가 Pending으로 남는다. 새 작업 등록·이미지 받기 중단. 실행 중인 학습은 DB 기록을 보류하며 계속된다(F4). | VM이 돌아오면 데이터 그대로 복구. VM을 다시 만들면 데이터 손실. 근거는 `inspect`의 PV nodeAffinity. |
| k3s-server VM 중단 | 컨트롤 플레인 1대. | 이미 떠 있는 파드는 계속 돌지만 스케줄링·자동 재시작·노드 장애 처리·`kubectl`이 모두 멈춘다. | VM이 돌아오면 복구. 디스크를 잃으면 클러스터 상태 손실(IaC로 새로 구축, 워크로드는 Helm으로 다시 배포). |
| 같은 호스트 자원 경쟁 | VM과 데스크톱·브라우저가 CPU·메모리·디스크 I/O를 나눠 쓴다. | 한쪽 부하가 다른 쪽을 느리게 한다. | 측정 대상 아님. 알려진 한계로만 적는다. |

### 2.3 막을 수 있는 장애 (실험으로 재현)

| 장애 | 쿠버네티스·앱이 하는 일 | 사람이 해야 하는 일(예상) | 실험 |
|---|---|---|---|
| 추론 파드 죽음 | Deployment가 새 파드를 만든다. 종료 때 SIGTERM과 preStop 5초(`infer-deployment.yaml`). | 없음. 죽은 순간 처리 중이던 요청은 실패하고 클라이언트가 다시 보내야 한다. | F1 |
| 학습 파드 중단 | Job이 새 파드로 다시 시도(backoffLimit 6)하고, 파드가 마지막 체크포인트에서 이어서 학습한다. | 없음. 잘못된 요청(종료 코드 2)은 재시도 없이 FAILED로 끝난다. | F2 |
| worker VM 정지 | 노드 NotReady 감지 뒤 기본 5분(toleration 300초)이 지나야 파드를 다른 노드에 다시 만든다. | 없음. 단, 5분을 줄이거나 파드를 흩어 놓는 것은 설정(수동 결정)이다. | F3 |
| MySQL 중단 | 학습은 계속되고 기록을 메모리에 보류했다가 DB가 돌아오면 채운다(`apps/train/jobdb.py`). 새 작업 등록은 안 된다. | DB가 안 돌아오면 사람이 본다. | F4 |
| GPU를 못 쓰는 상황 | 아무것도 하지 않는다. GPU를 요청한 파드는 Pending으로 기다린다. | **CPU 대체 경로로 다시 배포하는 일**(`gpu=0`, `DEVICE=auto`). 자동으로 넘어가지 않는다(예상). | F5 |
| 레지스트리 중단 | 노드에 이미지가 있으면(`IfNotPresent`) 파드가 시작한다. 없으면 이미지 받기에 실패하고 ImagePullBackOff로 다시 시도한다. | 없음(복구되면 자동). 그동안 새 이미지 빌드·push는 실패한다. | F6 |
| 과부하 | 큐가 차면 즉시 429로 거절하고, 받아들인 요청만 처리한다(`MAX_QUEUE`, `TIMEOUT_MS`). | 증설은 수동 결정. | F7 |
| 잘못된 배포 | 새 파드가 못 뜨면 롤링 업데이트가 멈추고 예전 파드가 남는다(CPU 기본 전략, 예상). | 롤백(`helm rollback`)은 수동. | F8 |

## 3. 실험 목록

제안서 14번의 순서(파드 종료 → 잘못된 배포 → 학습 중단 → 배치 추론 중단 → DB 재시작 → 워커 VM 종료)에 레지스트리·GPU·과부하를 더했다.

| ID | 하위 명령 | 장애 | 파괴하는 것 | GPU | 측정하는 것 | 기존 시험 재사용 |
|---|---|---|---|---|---|---|
| F1 | `infer-kill` | 추론 파드 강제 종료 | 추론 파드 1개 | 선택 | 복구 시간, 실패 요청 수·구간 | — |
| F2 | `train-kill` | 학습 파드 중단 → 재개 | 학습 파드 1개 | 사용 | 중단→재개 시간, 재개 체크포인트, 손실 | `scripts/train-resume-test.sh` |
| F3 | `node-stop` | worker VM 정지 | VM 1대(`vmrun stop hard`) | — | NotReady·재배치·복구 시간, 실패 요청 | `scripts/k3s-lab.sh` 5번의 방식 |
| F4 | `mysql-down` | MySQL 중단 | MySQL 파드(replicas 0) | 선택 | 등록 거절, 추론 지속, 데이터 보존, 복구 시간 | `scripts/job-db-test.sh`(`--with-training`) |
| F5 | `gpu-busy` | GPU 사용 불가 → CPU 대체 | GPU 점유 파드 | 사용 | Pending 사유, 대체 배포 시간, GPU 복귀 | — |
| F6 | `registry-down` | 레지스트리 중단 | 레지스트리 파드 | — | 이미지 받기 영향, 복구 후 재시도 시간 | — |
| F7 | `overload` | 과부하 → 429와 큐 대기 | (파괴 없음, 부하만) | — | 코드별 개수, 429 응답 시간, 큐 길이 | `scripts/infer-bench.sh` ②의 조건 |
| F8 | `bad-deploy` | 잘못된 배포(없는 이미지 태그) | 추론 릴리스 갱신 | 선택 | 서비스 유지 여부, 롤백 시간 | — |
| — | `inspect` | 읽기 전용 점검 | 없음 | — | 2절의 근거 | — |

제안서와 다른 점: 15번 슬라이드의 "이어서 실행: 학습·**배치** 중단 실험"에서 배치 중단은 현재 구현에 이어서 할 상태가 없다.
추론 워커는 요청 단위로 처리하고 큐는 메모리에만 있다(`apps/infer/queue.h`). 그래서 F1은 "이어서 실행"이 아니라 "실패 요청 수와 복구 시간"을 잰다. 이어서 실행은 F2에서 확인한다.

## 4. 실험별 설계

공통: 시작 전에 노드 4개 Ready, MySQL·레지스트리 정상, 이전 실험 흔적 없음을 확인하고, 끝나면 노드·MySQL·레지스트리가 정상인지와 실험용 네임스페이스가 사라졌는지를 다시 확인한다(보고서의 "되돌리기" 절).
실험용 파드·릴리스는 전용 네임스페이스 `k3slab-fault`에만 둔다(F2는 DB Secret 때문에 `default`에 Helm 릴리스 `train-<번호>`만 만든다).

### F1 추론 파드 강제 종료 (`infer-kill`)

| 항목 | 내용 |
|---|---|
| 절차 | ① 추론 릴리스 `infer-fault` 배포(Ready까지) ② 프로버 파드가 초당 약 10번 `POST /infer`를 보냄, 평상시 전부 200인지 확인 ③ T0 기록 후 파드 삭제(`--mode force`: `--grace-period=0 --force` / `graceful`: SIGTERM + preStop 5초) ④ 새 파드 Ready까지 1초 간격 확인(T1) ⑤ 10초 더 관찰 |
| 측정 | 복구 시간 T1−T0. 새 파드의 스케줄·컨테이너 시작·Ready 시각(쿠버네티스 기록, 1초 단위). 프로버 로그에서 실패 요청 수·코드·첫~마지막 실패 구간. 시도한 파드 수·재시작 수. `/metrics`의 `device`. (Prometheus가 있으면) 요청 결과별 증가량 |
| 성공 기준 | 새 파드가 사람 개입 없이 Ready / 복구 뒤 마지막 30개 요청이 모두 200 / 장치가 기대와 같음 / **복구 시간 10초 이내**(CPU·GPU 공통). 근거: CPU force 3회 1.4·1.5·1.4초, graceful 1.3초, GPU(`git-760a534`) force 1.5초(2026-11-22·23 실측, 실측 최댓값의 약 6.7배). **작은 모델(`model.k3sm` 38 KB)이고 이미지가 노드에 있을 때의 기준이다.** 큰 모델이나 이미지를 새로 받아야 하는 경우는 같은 기준을 쓰지 않고 다시 잰 뒤 정한다. 실패 요청 수는 판정에 쓰지 않고 관찰값으로 남긴다(CPU 4회 중 1회만 1개, 나머지 0) |
| 되돌리기 | `helm uninstall infer-fault` → 네임스페이스 삭제(프로버 포함, GPU도 반환) |
| 변형 | `--gpu 1`(GPU 승인 필요): 모델 적재와 CUDA 초기화가 더해진다. **예상:** 강제 삭제 직후 새 파드가 GPU를 아직 쥔 예전 컨테이너 때문에 Pending이나 배정 실패가 될 수 있다. 시도한 파드 수로 확인한다. **실측(11/23, 1회): Pending·배정 실패 없음, 복구 1.5초(6.1절).** |

### F2 학습 파드 중단 → 체크포인트 재개 (`train-kill`)

| 항목 | 내용 |
|---|---|
| 절차 (`graceful`, 기본) | 기존 `scripts/train-resume-test.sh <번호>`를 그대로 실행한다(6 에폭, 2 에폭 뒤 파드 삭제=SIGTERM, 재시도, 같은 번호 재요청). 그다음 MySQL `job_events`에서 INTERRUPTED→재개 시각과 체크포인트를 읽는다. |
| 절차 (`--mode force`) | `scripts/job.sh submit train <번호> --epochs 8 --epoch-sleep 6` → 에폭 2 기록 뒤 `--grace-period=0 --force`로 삭제(SIGKILL, 종료 체크포인트 없음) → 재시도 파드의 `resumed_from` 기록까지 대기 → DONE까지 |
| 측정 | 중단→재개 시간(DB `at` 컬럼은 밀리초). 재개 체크포인트(에폭·스텝). force는 종료 직전 DB 에폭과 재개 체크포인트 에폭의 차이. `attempts`. 최종 상태 |
| 성공 기준 | 재시도 파드가 마지막 체크포인트에서 재개 / 최종 DONE + `model.k3sm` / graceful: 재개 체크포인트 = INTERRUPTED 체크포인트(손실 0) / force: 재개 에폭 ≥ 종료 직전 DB 에폭 |
| 되돌리기 | `helm uninstall train-<번호>`. DB 행과 체크포인트 폴더는 증거로 남긴다(폴더는 root 소유라 sudo 없이 지울 수 없다) |
| 기존 기록 | 중단→재개: `train-resume-20261107-1253.md` 03:56:32→03:56:46(UTC) 14초, `job-db-20261107-1258.md` 12:58:51→12:59:05 14초 |
| 주의 | 기존 스크립트는 `docs/labs/train-resume-<날짜>.md`를 따로 만든다(이 작업의 수정 허용 목록 밖). 실행 전에 총괄 확인이 필요하다(10절). |

### F3 worker VM 정지 → 파드 재배치 (`node-stop`)

| 항목 | 내용 |
|---|---|
| 절차 | ① VM이 켜져 있고(`vmrun list`) VMware 커널 모듈이 올라와 있어 다시 켤 수 있는지 확인 ② 대상 노드(기본 worker-cpu-2)의 다른 파드를 보고서에 남기고, 시스템·DaemonSet이 아닌 파드가 있으면 `--allow-other-pods` 없이는 멈춘다 ③ `fault-api`(whoami 3개) 배포 + 프로버(대상 노드가 아닌 곳, 초당 약 10번 GET) ④ **복구 단계(VM 기동)를 먼저 등록한 뒤** `vmrun -T ws stop <vmx> hard` ⑤ NotReady(t1), 3개가 다른 노드에서 모두 Ready(t2)까지 확인(한도 15분) ⑥ `vmrun -T ws start <vmx> nogui` → 노드 Ready(t3) |
| 측정 | t1, t2, t3. 프로버의 실패 요청 수·구간. 정지 전·후 배치. 원래 노드로 돌아오는지(관찰) |
| 성공 기준 | NotReady 감지 / 3개가 사람 개입 없이 다른 노드에서 Ready / VM을 켠 뒤 노드가 다시 Ready / 정리 후 노드 4개 Ready |
| 되돌리기 | VM 기동(스크립트가 끊겨도 자동 실행, 정리 때 `cleanup --node <이름>`으로도 가능) → 네임스페이스 삭제. VM이 안 켜지면 멈추고 총괄에게 알린다(`entry.sh`는 플랫폼 담당) |
| 변형 | 기본 → `--spread`(노드마다 1개) → `--toleration-seconds 30`(NotReady 노드를 떠나기까지 유예 단축). 한 번에 한 가지만 바꿔서 비교한다. |
| 기존 기록 | `k3s-lab-20261030-1646.md` 5절: NotReady 44초, 재배치 완료까지 합계 352초(대부분 기본 toleration 300초). **예상:** 기본 배치는 3개가 한 노드에 몰려 정지부터 재배치 완료까지(약 350초) 거의 모든 요청이 실패한다. `--spread`는 정지~NotReady 구간(약 40초)에 1/3만 실패하고 그 뒤는 실패가 없다. `--toleration-seconds 30`은 재배치 완료가 정지 후 1.5분 안팎(NotReady 약 44초 + 30초 + 새 파드 시작)으로 줄어든다. |

### F4 MySQL 중단 (`mysql-down`)

| 항목 | 내용 |
|---|---|
| 절차 | ① `jobs`·`job_events` 행 수 기록, (`--model-job`이 있으면) 추론 배포 + 프로버 ② replicas 0, 파드가 사라질 때까지 ③ 중단 중 `scripts/job.sh submit train fault-db-<번호>`가 **실패하고 Job·Helm 릴리스가 만들어지지 않는지**, 추론 요청이 계속 200인지 ④ 기본 30초 뒤 replicas 1, 쿼리에 다시 답할 때까지(t_db) ⑤ 행 수가 그대로인지, `job.sh list`가 되는지 ⑥ (`--with-training`) `scripts/job-db-test.sh`로 학습 중 DB 중단 |
| 측정 | DB 없음 구간, t_db, 등록 요청의 종료 코드·메시지, 추론 실패 요청 수, 행 수 전·후 |
| 성공 기준 | 중단 중 등록이 실패하고 새 Job이 없음 / 추론 실패 0 / 복구 뒤 행 수 동일, PVC Bound, MySQL 1/1 Ready |
| 되돌리기 | replicas 1(스크립트가 끊겨도 자동 실행) → 추론 릴리스·네임스페이스 삭제 |
| 기존 기록 | 학습 중 DB 중단(`job-db-20261107-1258.md` 4절): 학습은 멈추지 않고 에폭 3→5 진행, 못 쓴 기록은 DB가 돌아온 뒤 채워지고 최종 DONE. 이 부분은 다시 만들지 않고 `--with-training`으로만 재현한다. |
| 확인할 점 | `job.sh submit`은 DB 등록이 실패해도 종료 코드가 0이 아니어야 한다. 코드를 읽어 보면 `register`가 실패해도 "이미 있는 작업" 안내를 먼저 찍을 수 있다(헷갈리는 메시지). 실행해서 확인하고, 문제면 `scripts/job.sh`를 고칠 것을 보고한다(내 영역이 아니라 고치지 않는다). |

### F5 GPU 사용 불가 → CPU 대체 경로 (`gpu-busy`)

| 항목 | 내용 |
|---|---|
| 절차 | ① GPU가 비어 있는지 확인, GPU 1개를 쥐고 `sleep`만 하는 파드 `fault-gpu-hold`로 GPU를 점유 ② GPU 1개를 요청하는 추론 배포(기다리지 않음): 파드가 Pending이고 사유가 `Insufficient nvidia.com/gpu`인지, 15초 뒤에도 그대로인지 ③ 같은 릴리스를 `gpu=0`, `DEVICE=auto`로 다시 배포(= `job.sh submit infer --device cpu`와 같은 설정): Ready까지 시간(t_fb), `/metrics`·응답의 `device`가 `cpu`인지 ④ 점유 파드를 지우고 `gpu=1`, `DEVICE=cuda`로 다시 배포: 복귀 시간과 전환 중 실패 요청 수 |
| 측정 | Pending 사유, t_fb, 장치 값, 복귀 시간, 전환 중 실패 요청 수·구간 |
| 성공 기준 | GPU 요청 파드는 Pending(저절로 CPU로 넘어가지 않음) / `gpu=0`+`auto` 배포는 CPU로 응답 / GPU가 비면 `cuda`로 복귀 |
| 되돌리기 | 점유 파드·추론 릴리스·네임스페이스 삭제 → GPU를 쓰는 파드가 없는지 확인 |
| 읽는 법 | `DEVICE=auto`는 **파드 안에서** GPU가 안 보이면 CPU로 계산하는 장치 선택일 뿐이다(`apps/infer/main.cpp`의 `choose_backend`). GPU가 다른 파드에 잡혀 있으면 스케줄 단계에서 Pending이라 컨테이너가 시작되지 않는다. 그래서 대체 경로는 **사람(또는 상위 도구)이 `gpu=0`으로 다시 배포하는 수동 개입**이다(예상). 대체 경로의 추론 파드도 gpu-host에 고정이다(모델 파일 위치). GPU 배포는 `maxSurge: 0`이라 전환 중 짧은 공백이 있을 것으로 예상한다. |

### F6 레지스트리 중단 (`registry-down`)

| 항목 | 내용 |
|---|---|
| 절차 | ① 예열: pull 정책 `IfNotPresent` 파드를 worker-cpu-2에 띄워 `infer-worker:<태그>`를 노드에 받아 두고 삭제 ② 레지스트리 replicas 0 ③ 중단 중: `IfNotPresent` 파드(이미지가 노드에 있음)는 Running이 되는지, `Always` 파드(레지스트리 확인 필요)는 ErrImagePull/ImagePullBackOff가 되는지 ④ 기본 60초 뒤 replicas 1, Ready(t_reg), `Always` 파드가 Running이 될 때까지(t_pull) ⑤ `/v2/_catalog`에 `infer-worker`가 남아 있는지 |
| 측정 | 중단 중 두 파드의 결과와 대기 사유, t_reg, t_pull(재시도 간격 포함), 카탈로그 확인 |
| 성공 기준 | 노드에 이미지가 있으면 중단 중에도 시작 / 없으면 실패 / 복구 뒤 사람 개입 없이 Running / 카탈로그 유지 |
| 되돌리기 | replicas 1(스크립트가 끊겨도 자동 실행) → 확인용 파드·네임스페이스 삭제 |
| 주의 | 중단 동안 Kaniko 빌드와 Jenkins의 이미지 push가 실패한다. CICD 담당과 시간을 맞춘다. **예상:** ImagePullBackOff는 재시도 간격이 10초부터 두 배씩 늘어(최대 5분) 레지스트리가 돌아와도 바로 시작하지 않을 수 있다. t_pull이 그것을 보여 준다. |

### F7 과부하 → 429와 큐 대기 (`overload`)

| 항목 | 내용 |
|---|---|
| 절차 | ① CPU 추론 배포(큐 20, 배치 4, 스레드 1, WORK_MS 50 — `infer-bench.sh` ②와 같은 조건) ② 이전 `/metrics` 기록 ③ 부하 Job: 요청 300개(`--requests`), 동시 150개(`--concurrency`), 0.2초마다 큐 길이 기록 ④ 응답 코드별 개수·응답 시간, 큐 길이 최댓값, 받아들인 요청의 평균 대기(`k3slab_infer_request_seconds`의 증가량) ⑤ 부하 뒤 큐가 비었는지, 파드 재시작 0인지, 일반 요청이 200인지 |
| 측정 | 코드별 개수, 429와 200의 응답 시간(중앙값·95%), 큐 길이 최댓값(용량 20), 평균 대기 |
| 성공 기준 | 429 발생 / 200·429 말고 다른 응답(000, 5xx)이 없음 / 429의 중앙값 응답 시간이 200보다 짧음(즉시 거절) / 큐 길이 ≤ 용량 / 부하 뒤 정상 |
| 되돌리기 | 부하 Job·추론 릴리스·네임스페이스 삭제 |
| 기존 기록 | `infer-bench-20261107-1257.md` ②: 요청 300개(동시 150개) 중 89개 200, 211개 429, 큐 용량 20 |

### F8 잘못된 배포 (`bad-deploy`)

| 항목 | 내용 |
|---|---|
| 절차 | ① 정상 배포 + 프로버, helm 리비전 기록 ② 레지스트리에 올린 적 없는 태그 `v0.0.0-fault-missing`으로 `helm upgrade`(기다리지 않음): 새 파드가 ErrImagePull/ImagePullBackOff가 되는 시각, 예전 파드가 계속 Ready인지 ③ 30초 뒤 `helm rollback <리비전> --wait` ④ 프로버 요약 |
| 측정 | 이상 감지까지의 시간(파드 상태 확인 기준), 배포~롤백 동안 실패 요청 수, 롤백 시간 |
| 성공 기준 | 새 파드가 Ready가 되지 않음 / CPU: 예전 파드가 서비스를 이어 가 실패 요청 0 / 롤백 뒤 Ready 1/1, 요청 200 |
| 되돌리기 | 롤백 → 릴리스·네임스페이스 삭제. 레지스트리에는 아무것도 올리지 않는다(이미지 태그를 덮어쓰지 않는다). |
| 변형 | `--gpu 1`: **예상:** GPU 배포는 `maxSurge: 0`, `maxUnavailable: 1`이라 예전 파드를 먼저 내려 서비스가 끊긴다(9주차에 GPU가 1장뿐이라 이렇게 바꿨다, `progress-week09.md` 문제와 대응 1번). 이 경우는 판정하지 않고 관찰만 한다. |

## 5. 측정 방법 (공통)

| 근거 | 쓰는 곳 | 해상도와 한계 |
|---|---|---|
| 스크립트의 시각 기록(`date +%s.%N`) | 모든 복구 시간 | 확인 간격 1초 + kubectl 응답 시간. 오차 약 1~2초 |
| 프로버 파드의 요청 로그 | 실패 요청 수·구간(F1, F3, F4, F5, F8) | 초당 약 10번. 실패한 요청이 시간 초과(최대 3초)면 그만큼 늦게 기록된다. 구간 길이는 파드 시계만 쓰고, T0 기준 시각에는 VM과 이 PC의 시계 차이(수 초 이내로 가정)가 섞인다. |
| 쿠버네티스가 적은 시각(생성·스케줄·시작·Ready) | F1 새 파드의 구간 분해 | 1초 단위 |
| MySQL `job_events.at` | F2 중단→재개 | 밀리초(`TIMESTAMP(3)`). DB와 이 PC의 시계 차이는 쓰지 않고 DB 시각끼리만 뺀다. |
| 워커 `/metrics` | F1 장치, F7 큐·결과별 개수, 평균 대기 | 워커가 센 값이라 파드가 바뀌면 새로 시작한다 |
| Prometheus | 보조 근거(선택) | 모니터링이 배포된 뒤 `--prom <네임스페이스>/<서비스>:<포트>`를 주면 쿼리 결과를 보고서에 붙인다. 수집 간격(보통 15~30초) 때문에 짧은 사건은 못 볼 수 있다. 쿼리의 레이블은 모니터링 설정에 따라 다를 수 있어 실행 단계에서 맞춘다. |
| Grafana 화면 | 실험마다 저장(제안서 14번 기록 방식) | 관측 담당과 대시보드 이름을 맞춘 뒤 캡처한다. 이 스크립트는 화면을 저장하지 않는다. |

Prometheus 쿼리(스크립트에 들어 있음, 모니터링 배포 뒤 확인):

| 실험 | 쿼리 | 보려는 것 |
|---|---|---|
| F1, F7 | `sum by (result) (increase(k3slab_infer_requests_total{namespace="k3slab-fault"}[구간]))` | 결과별 요청 수 증가량 |
| F1 | `max(kube_pod_container_status_restarts_total{namespace="k3slab-fault"})` | 재시작 횟수 |
| F7 | `max_over_time(k3slab_infer_queue_length{namespace="k3slab-fault"}[구간])` | 큐 길이 최댓값 |
| F3 | `min_over_time(kube_node_status_condition{node="<노드>",condition="Ready",status="true"}[구간])` | 정지 동안 0 |
| F4, F6 | `min_over_time(kube_deployment_status_replicas_available{namespace="k3slab-system",deployment="mysql"/"registry"}[구간])` | 중단 동안 0 |
| F5 | `max_over_time(kube_pod_status_phase{namespace="k3slab-fault",phase="Pending"}[구간])` | GPU 점유 동안 Pending |
| F6, F8 | `max_over_time(kube_pod_container_status_waiting_reason{namespace="k3slab-fault",reason=~"ErrImagePull\|ImagePullBackOff"}[구간])` | 이미지 받기 대기 |

## 6. 실행 순서, 승인, 일정

실행은 총괄의 시작 신호 뒤에 한다. **파괴적인 실험(VM 정지, 파드 삭제, DB·레지스트리 중단)은 하나하나 승인을 받는다.**
스크립트도 승인 표시(`--yes` 또는 터미널에서 `yes` 입력) 없이는 실행하지 않는다.

권장 순서(위험이 낮고 다른 작업에 영향이 적은 것부터):

| 순서 | 실험 | 이유 |
|---|---|---|
| 0 | `inspect` | 읽기 전용. 2절 표의 근거를 모은다 |
| 1 | F7 `overload` | 파괴 없음. 기존 기록과 비교 가능 |
| 2 | F8 `bad-deploy`(CPU) | 실험용 릴리스만 건드림 |
| 3 | F1 `infer-kill`(CPU) | 실험용 파드만 지움 |
| 4 | F6 `registry-down` | 레지스트리를 잠깐 내림: Jenkins·Kaniko 작업이 없는 시간에 |
| 5 | F4 `mysql-down` | DB를 잠깐 내림: 진행 중인 작업이 없는 시간에 |
| 6 | F5 `gpu-busy`, F2 `train-kill`, F1·F8 GPU 변형 | GPU를 쓴다. 한 번에 하나, 끝나면 바로 내린다 |
| 7 | F3 `node-stop`(기본 → `--spread` → `--toleration-seconds 30`) | 가장 파괴적. 노드에 다른 파드가 없을 때, 마지막에 |

### 6.1 실행 결과 (2026-11-23, 12주차 첫날에 14주 몫을 앞당겨 실행)

| 순서 | 실험 | 보고서(`docs/labs/`) | 결과 | 핵심 |
|---|---|---|---|---|
| 4 | F6 `registry-down` | `fault-registry-down-20261123-0346.md` | PASS 8 / FAIL 0 | t_reg 1.6초, t_pull 40.7초, 노드에 이미지가 있으면 중단 중에도 1.4초에 시작 |
| 5 | F4 `mysql-down` | `fault-mysql-down-20261123-0351.md` | PASS 11 / FAIL 0 | 추론 실패 0 / 1932, t_db 6.9초, **`job.sh submit`은 종료 코드 1이지만 약 120초 멈추고 "이미 있는 작업" 메시지를 찍음**(`job.sh` 수정 필요, 미수정) |
| 6 | F1 CPU 반복·graceful | `fault-infer-kill-20261123-0357.md`, `-0358.md`, `-0359.md` | 각 PASS 8 / FAIL 0 | force 1.4·1.5·1.4초(13주 포함), graceful 1.3초, 판정 기준을 10초로 정함 |
| 6 | F5 `gpu-busy` | `fault-gpu-busy-20261123-0402.md`(FAIL 1: 스크립트 타이밍 결함), `-0404.md`(고친 뒤) | 0404: PASS 11 / FAIL 0 | GPU 요청 파드 Pending(`Insufficient nvidia.com/gpu`), 대체 배포 Ready 약 1.7초, GPU 복귀 전환 12.5초·실패 3 / 154 (첫 실행 0 / 136) |
| 6 | F1 GPU (force) | `fault-infer-kill-20261123-0407.md` | PASS 9 / FAIL 0 | 복구 1.5초, 실패 0 / 177, **Pending·배정 실패 없음**(예상과 다름) |
| 6 | F8 GPU | `fault-bad-deploy-20261123-0409.md` | PASS 8 / FAIL 0 (서비스 유지 여부는 판정 안 함) | **서비스 공백 46.8초**(실패 90 / 299), 롤백 9.8초 |
| 6 | F2 force | `fault-train-kill-20261123-0413.md` | PASS 8 / FAIL 0 | 중단→재개 15.8초, 재개 에폭 2, 완료 에폭 손실 0 |
| 6 | F2 graceful | `fault-train-kill-20261123-0416.md`, `train-resume-20261123-0416.md` | PASS 9 / FAIL 0 (안쪽 6 / 0) | 중단→재개 14.1초, 재개 체크포인트 = 중단 체크포인트(손실 0) |

계획과 달라진 점과 인계는 `docs/labs/fault-week14-summary-20261123.md`에 있다. 7번(F3 `node-stop`)은 하지 않았다.

일정 제안(1주차 = 9/7, 총괄이 조정): 13주(11/30~12/6) `inspect`와 순서 1~3, 14주(12/7~13) 순서 4~6, 15주(12/14~20) 순서 7과 재시험, 16주(12/21~27) 결과 정리와 최종 보고.
모니터링(12–14주)이 배포되면 Prometheus·Grafana 근거를 같이 남긴다.

## 7. 총괄 승인용 자원 요청표

네임스페이스 `k3slab-fault`(실험 끝에 통째로 삭제), PVC 없음. 값은 요청(requests)이다. 메모리 limit은 추론 파드와 fault-api에는 두지 않고(차트·기존 매니페스트와 같음) 프로버·부하·점유·확인용 파드에만 둔다.

| 실험 | 노드 | 파드 | CPU / 메모리 요청 | GPU |
|---|---|---|---|---|
| F1, F7, F8 | gpu-host | 추론 1개 | 250m / 64Mi | 0 (`--gpu 1`이면 1) |
| F1, F3, F4, F5, F8 | 스케줄러가 고름(gpu-host 제외) | 프로버 1개 | 10m / 16Mi (limit 64Mi) | 0 |
| F2 | gpu-host (`default`) | 학습 1개 | 500m / 1Gi | 1 |
| F3 | 기본: worker-cpu-2 선호 / `--spread`: 세 노드에 분산 | fault-api 3개(whoami) | 각 10m / 16Mi | 0 |
| F5 | gpu-host | GPU 점유 1개(busybox) → 추론 1개 | 10m / 8Mi(limit 32Mi) → 250m / 64Mi | 1 (한 번에 하나) |
| F6 | worker-cpu-2 | 확인용 2~3개(infer-worker 이미지, sleep) + curl 1개 | 각 10m / 16Mi | 0 |
| F7 | 부하 Job은 스케줄러가 고름 | 부하 1개 | 10m / 32Mi (limit 128Mi) | 0 |

한 실험에서 동시에 떠 있는 파드의 요청 합계는 CPU 0.3코어 안팎, 메모리 100Mi 안팎이다(실제 사용량은 이보다 클 수 있다). 레지스트리·MySQL·VM은 새로 만들지 않고, 있는 것을 잠깐 멈췄다 켠다.

## 8. 안전 규칙과 복구

- 시작 전: 노드 4개 Ready, MySQL·레지스트리 정상, `k3slab-fault` 네임스페이스 없음. 아니면 시작하지 않는다.
- 복구 단계는 **장애를 일으키기 전에 등록**하고, 스크립트가 끝나거나 실패하거나 Ctrl+C로 끊겨도 거꾸로 실행한다(VM 기동, MySQL·레지스트리 replicas 1, 릴리스·네임스페이스 삭제).
- 끊긴 뒤 남은 것은 `scripts/fault-test.sh cleanup [--node <VM 이름>]`로 되돌린다.
- sudo를 쓰지 않는다. VM은 `vmrun`으로 끄고 켠다. 다시 켜지 못하면 멈추고 총괄에게 알린다(`scripts/entry.sh`는 플랫폼 담당).
- 비밀번호는 다루지 않는다. MySQL 접속은 파드 안 환경변수를 쓰고, 보고서에는 쿼리 결과만 남긴다.
- 다른 작업자의 파드가 대상 노드에 있으면 F3은 시작하지 않는다(`--allow-other-pods`로만 진행). F4·F6은 DB·레지스트리를 쓰는 작업이 없는 시간에 한다.
- GPU는 한 번에 한 파드만 쓴다. 다른 파드가 GPU를 쓰고 있으면 GPU 실험은 시작하지 않는다.
- 자기가 만든 네임스페이스와 릴리스만 지운다. `default`의 기존 릴리스, registry, mysql, nvidia-device-plugin은 건드리지 않는다(F4·F6은 replicas만 잠깐 바꾼다).

## 9. 이미 있는 측정값 (재사용과 비교 근거)

| 항목 | 값 | 근거 |
|---|---|---|
| 학습 중단→재개 | 14초(SIGTERM 삭제 → 재시도 파드가 체크포인트에서 재개, 손실 0) | `docs/labs/train-resume-20261107-1253.md`, `docs/labs/job-db-20261107-1258.md` 3·4절 |
| 학습 중 DB 중단 | 학습 계속(에폭 3→5), 못 쓴 기록은 DB 복구 뒤 채움, 최종 DONE | `docs/labs/job-db-20261107-1258.md` 4절 |
| worker VM 정지 | NotReady 44초, 3개 재배치 완료까지 합계 352초 | `docs/labs/k3s-lab-20261030-1646.md` 5절 |
| 과부하 | 300개(동시 150개) 중 89개 200, 211개 429 | `docs/labs/infer-bench-20261107-1257.md` ② |
| 배치 처리 | MAX_BATCH 1 vs 8: 8.08초 vs 1.28초 | `docs/labs/infer-bench-20261107-1257.md` ① |

## 10. 확인이 필요한 점과 알려진 한계

1. **클러스터가 지금 꺼져 있다.** `vmrun list`에 실행 중인 VM이 없고 VMware 커널 모듈(vmmon)이 올라와 있지 않다(2026-11-21 확인). 기동은 플랫폼 담당이 한다. 모듈이 없으면 F3이 시작하지 않는다.
2. **이 작업은 클러스터에서 아직 한 번도 실행하지 않았다.** 스크립트는 오프라인으로만 확인했다: `bash -n`, `--dry-run` 전체, 보조 함수·jq 필터·생성 매니페스트(YAML)·파드 안 셸 스크립트의 단위 시험, 가짜 `kubectl`/`helm`/`vmrun`으로 각 실험의 흐름 시험. 실제 클러스터에서 처음 돌릴 때 고칠 것이 나올 수 있다.
3. F2 `graceful`은 기존 `train-resume-test.sh`가 `docs/labs/train-resume-<날짜>.md`를, F4 `--with-training`은 `job-db-test.sh`가 `docs/labs/job-db-<날짜>.md`를 만든다. 이 파일들은 수정 허용 목록 밖이라 실행 전에 총괄이 허락해야 한다(허락하지 않으면 F2는 `--mode force`만, F4는 `--with-training` 없이 실행한다).
4. `job.sh submit`이 DB 없이 실패할 때의 메시지와 종료 코드(F4 확인할 점).
5. 모니터링의 Prometheus 서비스 이름·네임스페이스와 지표 레이블은 관측 담당의 배포가 끝나야 정해진다.
6. gpu-host(이 PC) 자체를 멈추는 실험은 하지 않는다. 이 PC에서 스크립트가 돌고 있기 때문이다.

## 11. 사용법

```bash
scripts/fault-test.sh list                                        # 실험 표
scripts/fault-test.sh infer-kill --dry-run --model-job <번호>     # 절차만 출력(아무것도 실행 안 함)
scripts/fault-test.sh inspect                                     # 읽기 전용 점검 (클러스터 필요)
scripts/fault-test.sh overload --model-job <번호> --yes           # 총괄 승인 뒤 실행
scripts/fault-test.sh node-stop --node worker-cpu-2 --spread --yes
scripts/fault-test.sh cleanup --node worker-cpu-2                 # 끊긴 실험 뒤처리
```

`--model-job`에는 끝난(DONE) 학습 작업 번호를 준다. 이 PC의 `/var/lib/k3slab/checkpoints/<번호>/model.k3sm`을 서빙한다.
Prometheus를 쓰려면 `--prom monitoring/prometheus:9090`처럼 `<네임스페이스>/<서비스>:<포트>`를 준다(또는 환경변수 `FAULT_PROM`). 이 클러스터의 실제 값은 `monitoring/prometheus:9090`이다(2026-11-22 확인).

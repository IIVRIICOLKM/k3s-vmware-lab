# F1 추론 파드 강제 종료 시험 (2026-11-22 20:41)

- 생성: `scripts/fault-test.sh infer-kill --gpu 0 --model-job db-1107b-train --prom monitoring/prometheus:9090 --yes`
- 설계: `docs/plan-week13-verification.md`. 시각은 이 PC(gpu-host) 시계 기준이고, 측정 오차는 확인 간격(약 1초) 안팎이다.
- 대상: 릴리스 `infer-fault`(네임스페이스 `k3slab-fault`), 모델 작업 `db-1107b-train`, 이미지 `infer-worker:v0.2`, 장치 `cpu`(GPU 0), 종료 방식 `force`

**실험 시작: ci 네임스페이스 파드 (Jenkins 에이전트 = 빌드 중)**

```text
NAME        READY   STATUS    RESTARTS   AGE    IP           NODE           NOMINATED NODE   READINESS GATES
jenkins-0   1/1     Running   0          4h4m   10.42.3.16   worker-cpu-1   <none>           <none>
```

**실험 시작: gpu-host CPU·메모리 사용량 (kubectl top)**

```text
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
gpu-host   1056m        6%       14569Mi         45%         
```

## 1. 평상시

- 추론 파드 `infer-fault-fffb58f8d-cw2qx`(노드 gpu-host)가 Ready이고, 프로버 요청이 모두 200이다.

## 2. 장애

- 파드 삭제 시각 T0 = 20:41:35

- 📏 복구 시간 (T0 → 새 파드 Ready): **1.4초**

**새 파드 infer-fault-fffb58f8d-wlk7w 의 시각 (쿠버네티스 기록, 1초 단위)**

```text
생성 2026-11-22T11:41:35Z → 스케줄 +0s → 컨테이너 시작 +0s → Ready +0s
```

- 📏 컨트롤러가 새 파드를 만들기까지 (T0 → 생성): **0초 안팎(1초 단위)**

**파드 목록 (시도한 파드 수와 상태)**

```text
infer-fault-fffb58f8d-wlk7w  Running  node=gpu-host  restarts=0  
```

**관련 이벤트 (최근 15개)**

```text
20s         Normal   Scheduled           pod/fault-probe                    Successfully assigned k3slab-fault/fault-probe to worker-cpu-2
11s         Normal   Scheduled           pod/infer-fault-fffb58f8d-wlk7w    Successfully assigned k3slab-fault/infer-fault-fffb58f8d-wlk7w to gpu-host
28s         Normal   ScalingReplicaSet   deployment/infer-fault             Scaled up replica set infer-fault-fffb58f8d from 0 to 1
27s         Normal   SuccessfulCreate    replicaset/infer-fault-fffb58f8d   Created pod: infer-fault-fffb58f8d-cw2qx
26s         Normal   Pulled              pod/infer-fault-fffb58f8d-cw2qx    Container image "registry.k3slab.local:5000/infer-worker:v0.2" already present on machine and can be accessed by the pod
26s         Normal   Created             pod/infer-fault-fffb58f8d-cw2qx    Container created
26s         Normal   Started             pod/infer-fault-fffb58f8d-cw2qx    Container started
20s         Normal   Pulled              pod/fault-probe                    Container image "docker.io/curlimages/curl:8.23.0" already present on machine and can be accessed by the pod
20s         Normal   Created             pod/fault-probe                    Container created
20s         Normal   Started             pod/fault-probe                    Container started
12s         Normal   Killing             pod/infer-fault-fffb58f8d-cw2qx    Stopping container worker
12s         Normal   Started             pod/infer-fault-fffb58f8d-wlk7w    Container started
12s         Normal   Created             pod/infer-fault-fffb58f8d-wlk7w    Container created
12s         Normal   SuccessfulCreate    replicaset/infer-fault-fffb58f8d   Created pod: infer-fault-fffb58f8d-wlk7w
12s         Normal   Pulled              pod/infer-fault-fffb58f8d-wlk7w    Container image "registry.k3slab.local:5000/infer-worker:v0.2" already present on machine and can be accessed by the pod
```

**프로버 요약 (초당 약 10회 요청, 실패 = HTTP 200이 아닌 응답 또는 시간 초과 000)**

```text
total=179 failed=1 codes=000:1,200:178
first_fail_after_t0=0.6 last_fail_after_t0=0.6 fail_window=0.0
```

- 📏 실패한 요청 수: **1 / 179 (코드별 000:1,200:178)**

- 📏 실패 구간 (첫 실패 ~ 마지막 실패): **0.0초 (T0+0.6s ~ T0+0.6s)**

**Prometheus: 요청 결과별 증가량  (쿼리: sum by (result) (increase(k3slab_infer_requests_total{namespace="k3slab-fault"}[90s])))**

```text
result=ok	187.8748
result=rejected	0
result=timeout	0
result=bad_request	0
result=failed	0
```

**Prometheus: 컨테이너 재시작 횟수  (쿼리: max(kube_pod_container_status_restarts_total{namespace="k3slab-fault"}))**

```text
	0
```

## 3. 판정

- ✅ **PASS** — 새 파드가 사람 개입 없이 Ready

- ✅ **PASS** — 복구 뒤 마지막 30개 요청이 모두 200

- ✅ **PASS** — 새 파드의 계산 장치가 cpu (/metrics의 device)

- ✅ **PASS** — 복구 시간이 60초 이내 (참고 기준, 실측 뒤 조정)

## 4. 되돌리기

- ✅ **PASS** — 실험용 네임스페이스(k3slab-fault)가 사라짐

- ✅ **PASS** — 노드 4개 모두 Ready

- ✅ **PASS** — MySQL이 1/1 Ready

- ✅ **PASS** — 레지스트리가 1/1 Ready

## 결과 요약

PASS 8, FAIL 0

---

## 5. 사람이 덧붙인 부분 (위는 `scripts/fault-test.sh`가 쓴 것, 아래는 실행 뒤에 사람이 정리한 것)

### 5.1 핵심 숫자

| 항목 | 값 | 근거 |
|---|---|---|
| 종료 방식 | `force` (`--grace-period=0 --force`) | 명령 줄 |
| 복구 시간 (T0 → 새 파드 Ready) | **1.4초** (상한. 아래 5.2) | 스크립트가 1초 간격으로 확인한 값 |
| 컨트롤러가 새 파드를 만든 시각 | T0와 같은 초 | 새 파드 생성 시각(1초 단위) |
| 새 파드의 스케줄 · 컨테이너 시작 · Ready | 모두 생성 후 +0초(1초 단위) | 쿠버네티스가 적은 시각 |
| 실패한 요청 | **1 / 179** (000 = 1, 200 = 178), 실패 시각 T0+0.6초 | 프로버 로그 |
| 시도한 파드 수 / 재시작 | 새 파드 1개 / 0 | 파드 목록, Prometheus |
| 장치 | `cpu` | `/metrics`의 `device` |

### 5.2 읽는 법과 한계

- **복구 시간 1.4초는 정확한 값이 아니라 상한이다.** 확인 간격이 1초이고 `kubectl` 응답 시간이 더해진다. 쿠버네티스가 적은 시각은 1초 단위라 스케줄·시작·Ready가 모두 `+0초`로만 나온다.
- **실패한 요청이 1개뿐이었다.** 프로버는 초당 약 8번(179개 / 약 21초) 요청을 보냈다. 서비스가 1.4초 내내 끊겼다면 10개 안팎이 실패했을 것이므로, 실제로 닿지 않은 시간은 요청 한두 번 사이(약 0.1~0.3초)로 보인다. 이 1개는 죽는 순간 처리 중이던 요청 또는 새 파드가 Ready가 되기 직전의 요청으로 추정한다. 코드 `000`만으로는 연결 거부와 끊김을 구분할 수 없어서 원인은 확인하지 못했다.
- **이 값은 "작은 모델의 CPU 파드"의 값이다.** 모델 `db-1107b-train`(`model.k3sm` 38,468바이트)은 아주 작고 이미지는 노드에 이미 있었다(`already present on machine`). 큰 모델(예: `bench-large` 68 MB)이나 GPU(CUDA 초기화·모델 적재)는 훨씬 오래 걸릴 수 있다. GPU 변형(`--gpu 1`)은 하지 않았다.
- 판정 기준 "복구 60초 이내"는 임시 기준이었다. 이번 실측이 1.4초라서 기준이 너무 느슨했다. 한 번만 잰 값이라 CPU 변형은 두세 번 더 재서 정하는 것이 좋다(제안: 10초 안팎).
- Prometheus `increase()`의 ok 187.9는 구간(90초) 외삽 값이라 실제(프로버 200 응답 178개 + 사전 확인 요청)보다 크다. 이 표에서는 프로버가 센 개수를 1차 근거로 쓴다.
- `kubectl delete pod --force`는 gpu-host AppArmor(컨테이너 안에서 자식 프로세스에 신호를 보내는 것을 막음)에 걸리지 않았다. 그런 증상은 없었다.

### 5.3 실험 시각의 다른 부하

- 실험 시작 때 `ci` 네임스페이스에는 `jenkins-0`(컨트롤러, worker-cpu-1)만 있었고 gpu-host에 Jenkins 에이전트 파드는 없었다. gpu-host CPU 1056m(6%).

### 5.4 이 시험으로 확인하지 못한 것

- `--mode graceful`(SIGTERM + preStop 5초)과 GPU 변형(`--gpu 1`): 다음 단계로 넘긴다. 특히 GPU는 예전 컨테이너가 GPU를 쥔 채 새 파드가 뜨는 경우(Pending·배정 실패 가능성)를 확인해야 한다.
- 요청을 처리하던 도중 종료되는 비율(요청 처리 시간을 늘린 `WORK_MS` 조건)은 재지 않았다.

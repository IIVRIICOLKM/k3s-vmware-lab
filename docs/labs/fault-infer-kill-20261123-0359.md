# F1 추론 파드 강제 종료 시험 (2026-11-23 03:59)

- 생성: `scripts/fault-test.sh infer-kill --gpu 0 --mode graceful --model-job db-1107b-train --prom monitoring/prometheus:9090 --yes`
- 설계: `docs/plan-week13-verification.md`. 시각은 이 PC(gpu-host) 시계 기준이고, 측정 오차는 확인 간격(약 1초) 안팎이다.
- 대상: 릴리스 `infer-fault`(네임스페이스 `k3slab-fault`), 모델 작업 `db-1107b-train`, 이미지 `infer-worker:v0.2`, 장치 `cpu`(GPU 0), 종료 방식 `graceful`

**실험 시작: ci 네임스페이스 파드 (Jenkins 에이전트 = 빌드 중)**

```text
NAME        READY   STATUS    RESTARTS   AGE     IP           NODE           NOMINATED NODE   READINESS GATES
jenkins-0   1/1     Running   0          6h27m   10.42.3.19   worker-cpu-1   <none>           <none>
```

**실험 시작: gpu-host CPU·메모리 사용량 (kubectl top)**

```text
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
gpu-host   1573m        9%       15393Mi         48%         
```

## 1. 평상시

- 추론 파드 `infer-fault-fffb58f8d-8bqzw`(노드 gpu-host)가 Ready이고, 프로버 요청이 모두 200이다.

## 2. 장애

- 파드 삭제 시각 T0 = 04:00:10

- 📏 복구 시간 (T0 → 새 파드 Ready): **1.3초**

**새 파드 infer-fault-fffb58f8d-gh6dc 의 시각 (쿠버네티스 기록, 1초 단위)**

```text
생성 2026-11-22T19:00:10Z → 스케줄 +0s → 컨테이너 시작 +0s → Ready +0s
```

- 📏 컨트롤러가 새 파드를 만들기까지 (T0 → 생성): **0초 안팎(1초 단위)**

**파드 목록 (시도한 파드 수와 상태)**

```text
infer-fault-fffb58f8d-gh6dc  Running  node=gpu-host  restarts=0  
```

**관련 이벤트 (최근 15개)**

```text
20s         Normal   Scheduled           pod/fault-probe                    Successfully assigned k3slab-fault/fault-probe to worker-cpu-2
11s         Normal   Scheduled           pod/infer-fault-fffb58f8d-gh6dc    Successfully assigned k3slab-fault/infer-fault-fffb58f8d-gh6dc to gpu-host
28s         Normal   ScalingReplicaSet   deployment/infer-fault             Scaled up replica set infer-fault-fffb58f8d from 0 to 1
27s         Normal   SuccessfulCreate    replicaset/infer-fault-fffb58f8d   Created pod: infer-fault-fffb58f8d-8bqzw
26s         Normal   Pulled              pod/infer-fault-fffb58f8d-8bqzw    Container image "registry.k3slab.local:5000/infer-worker:v0.2" already present on machine and can be accessed by the pod
26s         Normal   Created             pod/infer-fault-fffb58f8d-8bqzw    Container created
26s         Normal   Started             pod/infer-fault-fffb58f8d-8bqzw    Container started
19s         Normal   Pulled              pod/fault-probe                    Container image "docker.io/curlimages/curl:8.23.0" already present on machine and can be accessed by the pod
19s         Normal   Created             pod/fault-probe                    Container created
19s         Normal   Started             pod/fault-probe                    Container started
11s         Normal   Killing             pod/infer-fault-fffb58f8d-8bqzw    Stopping container worker
11s         Normal   Started             pod/infer-fault-fffb58f8d-gh6dc    Container started
11s         Normal   Created             pod/infer-fault-fffb58f8d-gh6dc    Container created
11s         Normal   SuccessfulCreate    replicaset/infer-fault-fffb58f8d   Created pod: infer-fault-fffb58f8d-gh6dc
11s         Normal   Pulled              pod/infer-fault-fffb58f8d-gh6dc    Container image "registry.k3slab.local:5000/infer-worker:v0.2" already present on machine and can be accessed by the pod
```

**프로버 요약 (초당 약 10회 요청, 실패 = HTTP 200이 아닌 응답 또는 시간 초과 000)**

```text
total=175 failed=0 codes=200:175
first_fail_after_t0=- last_fail_after_t0=- fail_window=0.0
```

- 📏 실패한 요청 수: **0 / 175 (코드별 200:175)**

- 📏 실패 구간 (첫 실패 ~ 마지막 실패): **실패 없음**

**Prometheus: 요청 결과별 증가량  (쿼리: sum by (result) (increase(k3slab_infer_requests_total{namespace="k3slab-fault"}[90s])))**

```text
result=ok	166.49133333333333
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

14주차 몫(계획 6절 순서 6)을 12주차 첫날(2026-11-23, 1주차 = 9/7)에 앞당겨 실행했다. 이미지 `infer-worker:v0.2`, 모델 작업 `db-1107b-train`, 장치 cpu(13주 1회와 같은 조건).

### 5.1 이 회차의 값과 force와의 비교 (CPU)

| 회차 | 보고서 | 종료 방식 | 복구 시간(T0 → 새 파드 Ready) | 실패 요청 | 새 파드 / 재시작 |
|---|---|---|---|---|---|
| 1 (13주) | `fault-infer-kill-20261122-2041.md` | force | **1.4초** | 1 / 179 (T0+0.6초, 코드 000) | 1개 / 0 |
| 2 | `fault-infer-kill-20261123-0357.md` | force | **1.5초** | 0 / 183 | 1개 / 0 |
| 3 | `fault-infer-kill-20261123-0358.md` | force | **1.4초** | 0 / 176 | 1개 / 0 |
| graceful | `fault-infer-kill-20261123-0359.md` | graceful (SIGTERM + preStop 5초) | **1.3초** | 0 / 175 | 1개 / 0 |

- **graceful도 복구 시간 1.3초, 실패 요청 0**이다(force 세 번은 1.4 ~ 1.5초). 차이는 확인 간격 안이라 의미가 없다.
- **복구 시간에 preStop 5초가 들어가지 않는다.** 파드를 지우면(SIGTERM) 컨트롤러가 곧바로(T0와 같은 초) 새 파드를 만들고, 새 파드는 예전 파드의 5초 대기와 상관없이 Ready가 된다. 그래서 이 숫자는 "예전 파드가 다 끝나기까지"가 아니라 "대체 파드가 서비스를 시작하기까지"다.
- 예전 파드는 T0 + 약 11초 시점의 파드 목록(위 "파드 목록")에서 이미 사라져 있다. 즉 SIGTERM + preStop 5초 종료는 약 11초 안에 끝났다. 정확한 종료 시간(예전 파드가 Terminating에 머문 시간)은 재지 않았다.
- 실패 요청이 0이라 이 조건(초당 약 10개, 요청 처리가 거의 즉시)에서는 graceful 종료로 끊기는 요청이 없다. force 세 번에서도 3번 중 2번이 0이었으므로 **graceful이 force보다 낫다고 말할 근거는 이 표본으로는 없다**(요청이 길게 걸리는 조건에서 다시 봐야 한다).
- **판정 기준 제안: 위 force 세 번과 같은 10초 이내.** graceful도 같은 기준을 쓴다.
- 시작 때 `ci`에는 `jenkins-0`만 있었고 에이전트 파드가 없었다. gpu-host CPU 1573m(9%).

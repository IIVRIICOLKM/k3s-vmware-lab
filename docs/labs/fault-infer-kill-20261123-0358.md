# F1 추론 파드 강제 종료 시험 (2026-11-23 03:58)

- 생성: `scripts/fault-test.sh infer-kill --gpu 0 --mode force --model-job db-1107b-train --prom monitoring/prometheus:9090 --yes`
- 설계: `docs/plan-week13-verification.md`. 시각은 이 PC(gpu-host) 시계 기준이고, 측정 오차는 확인 간격(약 1초) 안팎이다.
- 대상: 릴리스 `infer-fault`(네임스페이스 `k3slab-fault`), 모델 작업 `db-1107b-train`, 이미지 `infer-worker:v0.2`, 장치 `cpu`(GPU 0), 종료 방식 `force`

**실험 시작: ci 네임스페이스 파드 (Jenkins 에이전트 = 빌드 중)**

```text
NAME        READY   STATUS    RESTARTS   AGE     IP           NODE           NOMINATED NODE   READINESS GATES
jenkins-0   1/1     Running   0          6h26m   10.42.3.19   worker-cpu-1   <none>           <none>
```

**실험 시작: gpu-host CPU·메모리 사용량 (kubectl top)**

```text
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
gpu-host   1422m        8%       15364Mi         48%         
```

## 1. 평상시

- 추론 파드 `infer-fault-fffb58f8d-rdphs`(노드 gpu-host)가 Ready이고, 프로버 요청이 모두 200이다.

## 2. 장애

- 파드 삭제 시각 T0 = 03:58:45

- 📏 복구 시간 (T0 → 새 파드 Ready): **1.4초**

**새 파드 infer-fault-fffb58f8d-7mn7b 의 시각 (쿠버네티스 기록, 1초 단위)**

```text
생성 2026-11-22T18:58:45Z → 스케줄 +0s → 컨테이너 시작 +0s → Ready +0s
```

- 📏 컨트롤러가 새 파드를 만들기까지 (T0 → 생성): **0초 안팎(1초 단위)**

**파드 목록 (시도한 파드 수와 상태)**

```text
infer-fault-fffb58f8d-7mn7b  Running  node=gpu-host  restarts=0  
```

**관련 이벤트 (최근 15개)**

```text
20s         Normal   Scheduled           pod/fault-probe                    Successfully assigned k3slab-fault/fault-probe to worker-cpu-2
11s         Normal   Scheduled           pod/infer-fault-fffb58f8d-7mn7b    Successfully assigned k3slab-fault/infer-fault-fffb58f8d-7mn7b to gpu-host
28s         Normal   ScalingReplicaSet   deployment/infer-fault             Scaled up replica set infer-fault-fffb58f8d from 0 to 1
27s         Normal   SuccessfulCreate    replicaset/infer-fault-fffb58f8d   Created pod: infer-fault-fffb58f8d-rdphs
26s         Normal   Pulled              pod/infer-fault-fffb58f8d-rdphs    Container image "registry.k3slab.local:5000/infer-worker:v0.2" already present on machine and can be accessed by the pod
26s         Normal   Created             pod/infer-fault-fffb58f8d-rdphs    Container created
26s         Normal   Started             pod/infer-fault-fffb58f8d-rdphs    Container started
19s         Normal   Pulled              pod/fault-probe                    Container image "docker.io/curlimages/curl:8.23.0" already present on machine and can be accessed by the pod
19s         Normal   Started             pod/fault-probe                    Container started
19s         Normal   Created             pod/fault-probe                    Container created
11s         Normal   Created             pod/infer-fault-fffb58f8d-7mn7b    Container created
11s         Normal   Pulled              pod/infer-fault-fffb58f8d-7mn7b    Container image "registry.k3slab.local:5000/infer-worker:v0.2" already present on machine and can be accessed by the pod
11s         Normal   Started             pod/infer-fault-fffb58f8d-7mn7b    Container started
11s         Normal   Killing             pod/infer-fault-fffb58f8d-rdphs    Stopping container worker
11s         Normal   SuccessfulCreate    replicaset/infer-fault-fffb58f8d   Created pod: infer-fault-fffb58f8d-7mn7b
```

**프로버 요약 (초당 약 10회 요청, 실패 = HTTP 200이 아닌 응답 또는 시간 초과 000)**

```text
total=176 failed=0 codes=200:176
first_fail_after_t0=- last_fail_after_t0=- fail_window=0.0
```

- 📏 실패한 요청 수: **0 / 176 (코드별 200:176)**

- 📏 실패 구간 (첫 실패 ~ 마지막 실패): **실패 없음**

**Prometheus: 요청 결과별 증가량  (쿼리: sum by (result) (increase(k3slab_infer_requests_total{namespace="k3slab-fault"}[89s])))**

```text
result=ok	147.118
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

### 5.1 이 회차의 값과 세 번의 비교 (CPU, force)

| 회차 | 보고서 | 종료 방식 | 복구 시간(T0 → 새 파드 Ready) | 실패 요청 | 새 파드 / 재시작 |
|---|---|---|---|---|---|
| 1 (13주) | `fault-infer-kill-20261122-2041.md` | force | **1.4초** | 1 / 179 (T0+0.6초, 코드 000) | 1개 / 0 |
| 2 | `fault-infer-kill-20261123-0357.md` | force | **1.5초** | 0 / 183 | 1개 / 0 |
| 3 | `fault-infer-kill-20261123-0358.md` | force | **1.4초** | 0 / 176 | 1개 / 0 |
| graceful | `fault-infer-kill-20261123-0359.md` | graceful (SIGTERM + preStop 5초) | **1.3초** | 0 / 175 | 1개 / 0 |

- **세 번(force) 모두 1.4 ~ 1.5초**로 차이는 0.1초다. 확인 간격이 1초이고 `kubectl` 응답 시간이 더해지는 값이라 이 차이는 의미가 없다(같은 값으로 본다). 새 파드는 세 번 모두 생성·스케줄·컨테이너 시작·Ready가 같은 초(+0초)였다. 이미지가 노드에 이미 있다(`already present on machine`).
- **판정 기준 제안: CPU 복구 시간 10초 이내.** 실측 최댓값 1.5초의 약 6.7배이고, 확인 간격(1초)과 `kubectl` 응답 지연이 더해져도 넉넉하다. 60초는 40배라 아무 일도 못 잡아낸다. 이 값은 "작은 모델, 이미지가 노드에 있음"의 값이라 큰 모델·이미지 받기·GPU에는 쓰지 않는다(GPU는 GPU 실험 값으로 따로 정한다).
- 실패 요청은 세 번 중 한 번(13주)만 1개(코드 000)였고 나머지는 0이다. 표본이 3개뿐이라 "실패 요청 0"을 기준으로 삼지는 않고 관찰값으로 둔다.
- 시작 때 `ci`에는 `jenkins-0`만 있었고 에이전트 파드가 없었다(위 "실험 시작" 블록). gpu-host CPU는 1422m(8%)(13주 1회 1056m, 2·3회 2376m·1422m, graceful 1573m: 시작 값이 1056m ~ 2376m로 달랐지만 복구 시간은 같았다).
- 한계: 복구 시간은 1초 간격 확인의 상한이다. 요청 처리 도중 종료되는 비율(`WORK_MS`를 늘린 조건)은 재지 않았다.

# F7 과부하 시험 (429와 큐 대기) (2026-11-22 19:43)

- 생성: `scripts/fault-test.sh overload --model-job db-1107b-train --prom monitoring/prometheus:9090 --yes`
- 설계: `docs/plan-week13-verification.md`. 시각은 이 PC(gpu-host) 시계 기준이고, 측정 오차는 확인 간격(약 1초) 안팎이다.
- 릴리스 `infer-fault` (CPU, 큐 20, 배치 4, 스레드 1, WORK_MS 50: `scripts/infer-bench.sh` ②와 같은 조건), 모델 작업 `db-1107b-train`
- 부하: 요청 300개, 동시 150개 (curl Job, 요청마다 새 연결), 큐 길이는 0.2초마다 샘플링

## 1. 부하

**부하 직전: ci 네임스페이스 파드 (Jenkins 에이전트 = 빌드 중)**

```text
NAME        READY   STATUS    RESTARTS   AGE    IP           NODE           NOMINATED NODE   READINESS GATES
jenkins-0   1/1     Running   0          3h6m   10.42.3.16   worker-cpu-1   <none>           <none>
```

**부하 직전: gpu-host CPU·메모리 사용량 (kubectl top)**

```text
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
gpu-host   1336m        8%       14505Mi         45%         
```

**부하 직후: ci 네임스페이스 파드 (Jenkins 에이전트 = 빌드 중)**

```text
NAME        READY   STATUS    RESTARTS   AGE    IP           NODE           NOMINATED NODE   READINESS GATES
jenkins-0   1/1     Running   0          3h6m   10.42.3.16   worker-cpu-1   <none>           <none>
```

**부하 직후: gpu-host CPU·메모리 사용량 (kubectl top)**

```text
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
gpu-host   1553m        9%       14098Mi         44%         
```

**부하 Job 출력 요약 (E = 걸린 초)**

```text
200:101,429:199
E 1.32
```

**부하가 실제로 어떻게 들어갔는가** (설정값과 측정값을 따로 적는다)

- 보낸 요청 수: **300개** (설정 300개)
- 설정한 동시 수: **150** (`xargs -P`, 요청마다 새 연결)
- 부하 Job이 실제로 연 연결 수(포트 8080, 0.1초 간격 13번 측정): ESTABLISHED 최대 **25개**, SYN_SENT(연결 맺는 중) 최대 1개. 큐 길이 샘플러의 연결 1개가 섞여 있다
- 추론 파드가 실제로 받은 연결 수(0.2초 간격 23번 측정, 포트 8080 ESTABLISHED): 최대 **25개**. 부하 Job의 큐 길이 샘플러 연결 1개와 부하 뒤 확인용 요청이 섞일 수 있다
- 워커의 HTTP 스레드 풀 크기: 큐 20 + 스레드 1 × 배치 4 + 16 = **40개** (`apps/infer/main.cpp` 128행). 이보다 많은 연결은 스레드를 얻을 때까지 기다린다

- 📏 응답 코드별 개수 (클라이언트가 센 값, 1차 근거): **200:101,429:199**

- 📏 429 응답 시간 (중앙값 / 95%): **0.004초 / 0.009초**

- 📏 200 응답 시간 (중앙값 / 95%): **0.294초 / 0.305초**

- 📏 샘플링한 큐 길이 최댓값 (용량 20, 0.2초 간격 샘플이라 짧은 포화를 놓칠 수 있다. 코드별 개수가 1차 근거): **20**

## 2. 부하 뒤

- 📏 워커가 센 처리 완료 / 거절 (증가량): **101 / 199**

- 📏 받아들인 요청의 평균 대기+계산 시간 (metrics 증가량): **0.255초**

**Prometheus: 큐 길이 최댓값  (쿼리: max_over_time(k3slab_infer_queue_length{namespace="k3slab-fault"}[83s]))**

```text
instance=10.42.2.112:8080,job=k3slab-infer,namespace=k3slab-fault,node=gpu-host,pod=infer-fault-699d8d6f8f-mqzvg,release=infer-fault	16
```

**Prometheus: 요청 결과별 증가량  (쿼리: sum by (result) (increase(k3slab_infer_requests_total{namespace="k3slab-fault"}[83s])))**

```text
result=ok	114.1961
result=rejected	220.6313
result=timeout	0
result=bad_request	0
result=failed	0
```

## 3. 판정

- ✅ **PASS** — 큐가 넘치면 429로 거절된다 (429가 1개 이상)

- ✅ **PASS** — 200과 429 말고 다른 응답이 없음 (000·5xx·504 없음)

- ✅ **PASS** — 거절(429)이 처리된 요청(200)보다 빠르다 (중앙값)

- ✅ **PASS** — 큐 길이가 용량을 넘지 않음 (샘플 최댓값 ≤ 20)

- ✅ **PASS** — 부하 뒤 큐가 비어 있음

- ✅ **PASS** — 파드 재시작 0

- ✅ **PASS** — 부하 뒤 일반 요청이 200

## 4. 되돌리기

- ✅ **PASS** — 실험용 네임스페이스(k3slab-fault)가 사라짐

- ✅ **PASS** — 노드 4개 모두 Ready

- ✅ **PASS** — MySQL이 1/1 Ready

- ✅ **PASS** — 레지스트리가 1/1 Ready

## 결과 요약

PASS 11, FAIL 0

---

## 5. 사람이 덧붙인 부분 (위는 `scripts/fault-test.sh`가 쓴 것, 아래는 실행 뒤에 사람이 정리한 것)

### 5.1 핵심 숫자

| 항목 | 값 | 근거 |
|---|---|---|
| 보낸 요청 수 | 300개 | 부하 Job의 `R` 줄 수 |
| 설정한 동시 수 | 150 (`xargs -P`) | 설정값이다. 실제 연결 수가 아니다 |
| 실제로 연 연결 수 (최대) | 부하 Job 쪽 **25개**, 추론 파드 쪽 **25개** | `/proc/net/tcp`를 0.1초(Job)·0.2초(파드) 간격으로 읽은 ESTABLISHED. 큐 길이 샘플러 연결 1개가 섞여 있다 |
| 코드별 개수 (1차 근거) | 200 = 101, 429 = 199, 그 밖 0 | 부하 Job 출력. 워커가 센 값(처리 101 / 거절 199)과 같다 |
| 429 / 200 응답 시간 (중앙값) | 0.004초 / 0.294초 | 429는 즉시 거절 |
| 부하가 걸린 시간 | 1.32초 | 부하 Job의 `E` 줄 |
| 큐 길이 최댓값 | 0.2초 샘플 20 / 용량 20, Prometheus 16 | 아래 5.2 |

### 5.2 읽는 법과 한계

- **"동시 150"은 설정값이었고 실제 연결은 25개였다.** 요청마다 curl 프로세스를 새로 띄우고, 429는 0.004초 만에 돌아오며, 부하 전체가 1.32초에 끝나서 연결이 150개까지 겹치지 못한 것으로 보인다(원인을 따로 확인하지는 않았다). 그래서 이 시험은 "동시 150개가 들어왔다"가 아니라 "300개를 1.3초에 쏟아 최대 25개 연결이 겹쳤다"로 읽어야 한다.
- **이번에는 HTTP 스레드 풀(40개)이 한도가 아니었다.** 실제 연결(25)이 풀(40)보다 작았다. 모니터링 시험(큐 20, 연결 229개, 풀 52개)과 다른 점이다. 429는 큐(용량 20)가 넘쳐서 났다.
- **큐 길이 게이지는 Prometheus가 놓쳤다.** 0.2초 샘플은 20/20을 잡았는데 Prometheus(5초 간격)의 최댓값은 16이다. 모니터링 보고서 9.3절 6번과 같은 현상이다. 그래서 코드별 개수를 1차 근거로 썼다.
- **Prometheus `increase()`는 값이 어림이다.** ok 114.2 / rejected 220.6은 83초 구간에 대한 외삽 값이라 실제(101 / 199)와 다르다. 이 표에서는 클라이언트가 센 개수와 워커 `/metrics`의 증가량(101 / 199)이 같으므로 그쪽을 쓴다.
- 기존 기록(`infer-bench-20261107-1257.md` ②: 300개 중 89개 200, 211개 429)과 비교하면 200이 12개 많다. 같은 설정이지만 요청이 들어오는 타이밍이 달라서 처리된 수가 조금씩 달라지는 것으로 본다(두 번만 재서 분산은 모른다). 둘 다 큐 20 가득, 다른 응답 코드 0이다.

### 5.3 실험 시각의 다른 부하

- 부하 직전·직후 모두 `ci` 네임스페이스에는 `jenkins-0`(컨트롤러, worker-cpu-1)만 있었고 gpu-host에는 Jenkins 에이전트 파드가 없었다. 즉 빌드가 gpu-host CPU를 쓰지 않았다.
- gpu-host CPU 사용량은 부하 직전 1336m(8%), 직후 1553m(9%)다. 이 PC는 사용자의 데스크톱이기도 해서 부하가 없어도 0이 아니다(모니터링 보고서 9.3절 8번).

### 5.4 이 시험으로 확인하지 못한 것

- 큐 20·배치 4·스레드 1 한 가지 조건만 했다. 큐 크기, 배치, 스레드를 바꿨을 때의 429 비율은 재지 않았다.
- 연결이 25개를 넘는 더 센 부하(예: 풀 크기 근처)에서 풀이 한도가 되는 경우는 이 시험 범위 밖이다(모니터링 보고서 9.3절 7번이 추정한 부분).

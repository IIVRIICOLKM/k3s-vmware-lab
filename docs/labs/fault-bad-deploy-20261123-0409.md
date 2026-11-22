# F8 잘못된 배포 시험 (없는 이미지 태그, 장치 cuda) (2026-11-23 04:09)

- 생성: `scripts/fault-test.sh bad-deploy --gpu 1 --model-job db-1107b-train --tag git-760a534 --prom monitoring/prometheus:9090 --yes`
- 설계: `docs/plan-week13-verification.md`. 시각은 이 PC(gpu-host) 시계 기준이고, 측정 오차는 확인 간격(약 1초) 안팎이다.
- 릴리스 `infer-fault`: 정상 태그 `git-760a534` → 없는 태그 `v0.0.0-fault-missing` → helm rollback. 장치 `cuda`(GPU 1)

**실험 시작: ci 네임스페이스 파드 (Jenkins 에이전트 = 빌드 중)**

```text
NAME        READY   STATUS    RESTARTS   AGE     IP           NODE           NOMINATED NODE   READINESS GATES
jenkins-0   1/1     Running   0          6h37m   10.42.3.19   worker-cpu-1   <none>           <none>
```

**실험 시작: gpu-host CPU·메모리 사용량 (kubectl top)**

```text
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
gpu-host   1212m        7%       14756Mi         46%         
```

## 1. 평상시

- helm 리비전 1 (정상), 파드 infer-fault-77d99d484f-6lq8z

## 2. 잘못된 배포

- 없는 태그 배포 04:10:09

- 📏 배포 → 새 파드가 이미지 받기 실패 상태 (확인 간격 1초): **11.7초**

**배포 30초 뒤 파드 (예전 파드가 서비스를 이어 가는가)**

```text
infer-fault-75ff5b5496-mpt98  Pending  node=gpu-host  restarts=0  
```

**새 파드 이벤트**

```text
19s         Normal    Pulling             pod/infer-fault-75ff5b5496-mpt98    Pulling image "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing"
14s         Warning   Failed              pod/infer-fault-75ff5b5496-mpt98    Error: ErrImagePull
14s         Warning   Failed              pod/infer-fault-75ff5b5496-mpt98    Failed to pull image "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing": rpc error: code = NotFound desc = failed to pull and unpack image "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing": failed to resolve reference "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing": registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing: not found
3s          Warning   Failed              pod/infer-fault-75ff5b5496-mpt98    Error: ImagePullBackOff
3s          Normal    BackOff             pod/infer-fault-75ff5b5496-mpt98    Back-off pulling image "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing"
```

## 3. 롤백

- 📏 helm rollback → 정상 Ready: **9.8초**

**helm 이력**

```text
REVISION	UPDATED                 	STATUS    	CHART                	APP VERSION	DESCRIPTION     
1       	Mon Nov 23 04:09:48 2026	superseded	k3slab-workload-0.1.0	0.1        	Install complete
2       	Mon Nov 23 04:10:09 2026	superseded	k3slab-workload-0.1.0	0.1        	Upgrade complete
3       	Mon Nov 23 04:10:52 2026	deployed  	k3slab-workload-0.1.0	0.1        	Rollback to 1   
```

**프로버 요약 (초당 약 10회 요청, 실패 = HTTP 200이 아닌 응답 또는 시간 초과 000)**

```text
total=299 failed=90 codes=000:90,200:209
first_fail_after_t0=4.5 last_fail_after_t0=51.3 fail_window=46.8
```

- 📏 배포~롤백 동안 실패한 요청 수: **90 / 299 (코드별 000:90,200:209)**

**Prometheus: 이미지 받기 대기 파드  (쿼리: max_over_time(kube_pod_container_status_waiting_reason{namespace="k3slab-fault",reason=~"ErrImagePull|ImagePullBackOff"}[143s]))**

```text
container=worker,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=k3slab-fault,pod=infer-fault-75ff5b5496-mpt98,reason=ErrImagePull,uid=4dda1cc5-8469-424f-9d1e-5faf1ead8488	1
container=worker,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=k3slab-fault,pod=infer-fault-75ff5b5496-mpt98,reason=ImagePullBackOff,uid=4dda1cc5-8469-424f-9d1e-5faf1ead8488	1
```

## 4. 판정

- ✅ **PASS** — 새 파드가 Ready가 되지 못하고 이미지 받기 실패로 멈춤

GPU 변형: 이 차트는 GPU 배포에서 예전 파드를 먼저 내린다(maxSurge 0). 배포 중 예전 파드가 살아 있었는가: 아니오 — 관찰만 하고 판정하지 않는다.

- ✅ **PASS** — 롤백 뒤 Ready 1/1

- ✅ **PASS** — 롤백 뒤 마지막 30개 요청이 모두 200

## 5. 되돌리기

- ✅ **PASS** — 실험용 네임스페이스(k3slab-fault)가 사라짐

- ✅ **PASS** — 노드 4개 모두 Ready

- ✅ **PASS** — MySQL이 1/1 Ready

- ✅ **PASS** — 레지스트리가 1/1 Ready

- ✅ **PASS** — GPU를 쓰는 파드가 남아 있지 않음 (GPU 반납)

## 결과 요약

PASS 8, FAIL 0

---

## 6. 사람이 덧붙인 부분 (위는 `scripts/fault-test.sh`가 쓴 것, 아래는 실행 뒤에 사람이 정리한 것)

14주차 몫(계획 6절 순서 6, GPU 변형)을 12주차 첫날(2026-11-23, 1주차 = 9/7)에 앞당겨 실행했다. 장치 `cuda`(GPU 1), 정상 이미지 **`infer-worker:git-760a534`**(`--tag`로 지정), 없는 태그 `v0.0.0-fault-missing`, 모델 작업 `db-1107b-train`. **계획대로 이 실험은 판정하지 않고 관찰만 했다**(4절). GPU 슬롯은 이 실험 동안 내가 썼고, 끝난 뒤 GPU를 요청한 파드는 0개다(5절 "GPU 반납" PASS). 시작 때 `ci`에는 `jenkins-0`만 있었다.

### 6.1 핵심 숫자 (GPU) 와 CPU(13주)와의 비교

| 항목 | GPU (이 실행) | CPU (13주, `fault-bad-deploy-20261122-2038.md`) |
|---|---|---|
| 배포 → 새 파드 `ErrImagePull` | 11.7초 | 7.4초 |
| 배포 30초 뒤 예전 파드 | **없음** (파드 목록에 새 파드 `Pending` 하나뿐) | 있음, Ready로 서비스를 이어 감 |
| 배포~롤백 중 실패 요청 | **90 / 299** (코드 000 = 90) | 0 / 509 |
| 실패 구간 (첫 ~ 마지막 실패) | **46.8초** (T0 + 4.5초 ~ 51.3초) | 없음 |
| 롤백 (`helm rollback --wait` → Ready) | **9.8초** | 0.3초 |
| 롤백 뒤 | Ready 1/1, 마지막 30개 요청 모두 200 (PASS) | 같음 |
| 롤백 뒤 GPU 반납 | GPU 요청 파드 0개 (PASS) | — |

### 6.2 계획의 예상과 같은가

- **같다. GPU 배포는 `maxSurge: 0`, `maxUnavailable: 1`이라 예전 파드를 먼저 내려서 서비스가 끊겼다.** 새 파드가 이미지를 못 받아 `Pending`에 머무는 동안 서비스에는 응답할 파드가 없었다. 실패 구간 46.8초는 대략 "예전 파드가 내려간 시각(T0 + 4.5초) ~ 롤백된 새 파드가 Ready가 된 시각(T0 + 51.3초)"이고, 배포(04:10:09)부터 롤백(04:10:52)까지 43초는 스크립트가 30초 관찰 + 이상 감지(11.7초)로 정한 값이다.
- **실패 구간의 길이는 사람이 얼마나 빨리 롤백하느냐에 달렸다.** 이 실험은 롤백을 일부러 약 43초 뒤에 했다. 실제로 사람이 알아채는 데 더 걸리면 그만큼 길어진다. 롤백 자체의 시간(9.8초)은 구간의 일부일 뿐이다.
- **롤백 시간 9.8초는 CPU(0.3초)와 의미가 다르다.** CPU에서는 예전 파드가 살아 있어 설정만 되돌렸고, 여기서는 예전 파드가 없어서 정상 파드를 새로 띄운 시간(이미지는 노드에 있음, GPU 컨테이너 시작 + 모델 적재 + Helm `--wait` 확인 간격)이다. 13주 요약 2절 3번의 "예전 파드가 없는 상황(GPU 변형)은 이 숫자로 알 수 없다"는 점이 이번에 확인된다. 9.8초 중 얼마가 새 파드 시작이고 얼마가 Helm의 확인 간격인지는 나누지 않았다.
- **실패 요청 수 90은 시간의 척도가 아니다.** 요청이 실패하는 데 걸리는 시간에 따라 달라지는 값이다(46.8초 동안 초당 약 2개만 000으로 기록됐다. 프로버는 연결 대기 1초, 전체 3초 한도로 보내므로, 실패하는 요청은 초당 10개가 아니라 대기 시간만큼 느리게 쌓인다. 요청별 실패 시간은 재지 않았다). 서비스 공백의 크기는 **실패 구간 46.8초**로 읽는다.
- **첫 실패가 T0 + 4.5초인 것은 F5의 추정과 맞는다.** 예전 파드는 종료 때 preStop 5초 동안 계속 요청을 받고(F5 보고서 5.2절), 그 뒤부터 끊긴다. F5(T0 + 5.0초)와 이 실험(T0 + 4.5초)에서 첫 실패가 모두 preStop 5초 근처다. 시계 차이(수 초 이내 가정)가 섞여 있어 엄밀한 증거는 아니다.
- 배포 → `ErrImagePull`이 CPU(7.4초)보다 4.3초 늦다. 원인은 확인하지 못했다(예전 파드의 종료와 새 파드의 이미지 받기 순서, 또는 이미지 `git-760a534`의 레지스트리 응답 차이일 수 있다).

### 6.3 15주·최종 보고로 넘길 것

- GPU가 1장뿐인 이 구성에서는 배포를 갱신할 때 예전 파드를 먼저 내려야 해서, **잘못된 배포는 곧바로 서비스 중단**이다. 줄이는 방법의 후보: 배포 전에 이미지 존재를 확인하는 CI 단계(Jenkins), 실패하면 자동으로 되돌리는 `helm upgrade --atomic`(이 실험에서는 쓰지 않았다, 효과는 재 보지 않았다), Argo CD의 자동 동기화 설정. 어느 것이 이 연구 범위인지는 총괄이 정한다.
- 수동 개입 지점(제안서 15번 기대 효과): CPU는 롤백만 하면 되고 서비스는 그동안 유지된다. **GPU는 롤백 시점까지 서비스가 없다.**

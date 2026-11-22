# F8 잘못된 배포 시험 (없는 이미지 태그, 장치 cpu) (2026-11-22 20:38)

- 생성: `scripts/fault-test.sh bad-deploy --gpu 0 --model-job db-1107b-train --prom monitoring/prometheus:9090 --yes`
- 설계: `docs/plan-week13-verification.md`. 시각은 이 PC(gpu-host) 시계 기준이고, 측정 오차는 확인 간격(약 1초) 안팎이다.
- 릴리스 `infer-fault`: 정상 태그 `v0.2` → 없는 태그 `v0.0.0-fault-missing` → helm rollback. 장치 `cpu`(GPU 0)

**실험 시작: ci 네임스페이스 파드 (Jenkins 에이전트 = 빌드 중)**

```text
NAME        READY   STATUS    RESTARTS   AGE    IP           NODE           NOMINATED NODE   READINESS GATES
jenkins-0   1/1     Running   0          4h1m   10.42.3.16   worker-cpu-1   <none>           <none>
```

**실험 시작: gpu-host CPU·메모리 사용량 (kubectl top)**

```text
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
gpu-host   1100m        6%       14460Mi         45%         
```

## 1. 평상시

- helm 리비전 1 (정상), 파드 infer-fault-fffb58f8d-cphhf

## 2. 잘못된 배포

- 없는 태그 배포 20:38:52

- 📏 배포 → 새 파드가 이미지 받기 실패 상태 (확인 간격 1초): **7.4초**

**배포 30초 뒤 파드 (예전 파드가 서비스를 이어 가는가)**

```text
infer-fault-664895f648-h9sl8  Pending  node=gpu-host  restarts=0  
infer-fault-fffb58f8d-cphhf  Running  node=gpu-host  restarts=0  
```

**새 파드 이벤트**

```text
18s         Normal    Pulling             pod/infer-fault-664895f648-h9sl8    Pulling image "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing"
13s         Warning   Failed              pod/infer-fault-664895f648-h9sl8    Failed to pull image "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing": rpc error: code = NotFound desc = failed to pull and unpack image "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing": failed to resolve reference "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing": registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing: not found
13s         Warning   Failed              pod/infer-fault-664895f648-h9sl8    Error: ErrImagePull
2s          Normal    BackOff             pod/infer-fault-664895f648-h9sl8    Back-off pulling image "registry.k3slab.local:5000/infer-worker:v0.0.0-fault-missing"
2s          Warning   Failed              pod/infer-fault-664895f648-h9sl8    Error: ImagePullBackOff
```

## 3. 롤백

- 📏 helm rollback → 정상 Ready: **0.3초**

**helm 이력**

```text
REVISION	UPDATED                 	STATUS    	CHART                	APP VERSION	DESCRIPTION     
1       	Sun Nov 22 20:38:37 2026	superseded	k3slab-workload-0.1.0	0.1        	Install complete
2       	Sun Nov 22 20:38:52 2026	superseded	k3slab-workload-0.1.0	0.1        	Upgrade complete
3       	Sun Nov 22 20:39:29 2026	deployed  	k3slab-workload-0.1.0	0.1        	Rollback to 1   
```

**프로버 요약 (초당 약 10회 요청, 실패 = HTTP 200이 아닌 응답 또는 시간 초과 000)**

```text
total=509 failed=0 codes=200:509
first_fail_after_t0=- last_fail_after_t0=- fail_window=0.0
```

- 📏 배포~롤백 동안 실패한 요청 수: **0 / 509 (코드별 200:509)**

**Prometheus: 이미지 받기 대기 파드  (쿼리: max_over_time(kube_pod_container_status_waiting_reason{namespace="k3slab-fault",reason=~"ErrImagePull|ImagePullBackOff"}[124s]))**

```text
container=worker,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=k3slab-fault,pod=infer-fault-664895f648-h9sl8,reason=ErrImagePull,uid=6601b821-681f-40e9-a726-71bbd8bb1a24	1
container=worker,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=k3slab-fault,pod=infer-fault-664895f648-h9sl8,reason=ImagePullBackOff,uid=6601b821-681f-40e9-a726-71bbd8bb1a24	1
```

## 4. 판정

- ✅ **PASS** — 새 파드가 Ready가 되지 못하고 이미지 받기 실패로 멈춤

- ✅ **PASS** — 배포 중에도 예전 파드가 Ready로 서비스를 이어 감

- ✅ **PASS** — 배포~롤백 동안 실패한 요청이 0

- ✅ **PASS** — 롤백 뒤 Ready 1/1

- ✅ **PASS** — 롤백 뒤 마지막 30개 요청이 모두 200

## 5. 되돌리기

- ✅ **PASS** — 실험용 네임스페이스(k3slab-fault)가 사라짐

- ✅ **PASS** — 노드 4개 모두 Ready

- ✅ **PASS** — MySQL이 1/1 Ready

- ✅ **PASS** — 레지스트리가 1/1 Ready

## 결과 요약

PASS 9, FAIL 0

---

## 6. 사람이 덧붙인 부분 (위는 `scripts/fault-test.sh`가 쓴 것, 아래는 실행 뒤에 사람이 정리한 것)

### 6.1 핵심 숫자

| 항목 | 값 | 근거 |
|---|---|---|
| 없는 태그로 배포(`helm upgrade`) → 새 파드가 이미지 받기 실패 | **7.4초** | 스크립트가 1초 간격으로 확인한 값 |
| 배포~롤백 동안 실패한 요청 | **0 / 509** (전부 200) | 프로버 로그 |
| `helm rollback --wait` → 완료 | **0.3초** | 아래 6.2 |
| 롤백 뒤 | Ready 1/1, 마지막 30개 요청 모두 200 | 판정 4절 |
| helm 이력 | 1(정상) → 2(없는 태그) → 3(`Rollback to 1`) | 보고서 3절 |

### 6.2 읽는 법과 한계

- **롤백 0.3초는 "새 파드가 뜨는 시간"이 아니다.** 배포 중에도 예전 파드(`infer-fault-fffb58f8d-cphhf`)가 계속 Ready였고, 새 파드는 `ImagePullBackOff`로 멈춘 채 Pending이었다. 롤백은 Deployment 설정을 예전 리비전으로 되돌리는 것이어서, 이미 떠 있는 예전 파드를 그대로 쓰고 새 파드를 지웠다. 그래서 `--wait`이 바로 끝났다. 예전 파드가 없는 상황(예: GPU 변형)은 이 숫자로 알 수 없다.
- **서비스가 끊기지 않은 이유(관찰한 것):** CPU 배포는 기본 롤링 업데이트라 새 파드가 Ready가 되기 전에는 예전 파드를 내리지 않는다. 이 시험에서 예전 파드가 배포 30초 뒤에도 Running이었고 요청 실패가 0이었다.
- **실패 원인은 시간 초과가 아니라 "없음"으로 바로 알 수 있었다.** 이벤트에 `NotFound … not found`(레지스트리가 그 태그에 404)와 `ErrImagePull` → `ImagePullBackOff`가 나왔다. 레지스트리 쪽 변경은 없다(없는 태그를 조회만 했고 아무것도 올리지 않았다. 이미지 태그를 덮어쓰지 않았다).
- 사람이 해야 하는 일은 **롤백 명령 한 번**이다. 자동으로 롤백되지는 않았다(새 파드는 롤백할 때까지 Pending으로 남아 있었다). 이상을 알아차리는 데는 파드 상태 확인(또는 Prometheus `kube_pod_container_status_waiting_reason`, 위 3절에서 `ErrImagePull`·`ImagePullBackOff` 모두 1로 잡힘)이 필요하다.
- Prometheus 쿼리 결과는 보조 근거다. 수집 간격(15초) 안의 짧은 사건은 놓칠 수 있다.

### 6.3 실험 시각의 다른 부하

- 실험 시작 때 `ci` 네임스페이스에는 `jenkins-0`(컨트롤러, worker-cpu-1)만 있었고 gpu-host에 Jenkins 에이전트 파드는 없었다. gpu-host CPU는 1100m(6%)였다.
- 이 실험은 요청 성공 여부와 파드 상태를 보는 것이라 CPU 경쟁의 영향이 작다고 본다(측정해서 확인하지는 않았다).

### 6.4 이 시험으로 확인하지 못한 것

- GPU 변형(`--gpu 1`): GPU 배포는 `maxSurge 0`이라 예전 파드가 먼저 내려가 서비스가 끊길 것으로 예상하지만 이번에는 하지 않았다(14주, GPU 승인 필요).
- 잘못된 설정값(이미지는 맞지만 시작하자마자 죽는 경우, readiness 실패)은 하지 않았다. 없는 이미지 태그 한 가지만 했다.

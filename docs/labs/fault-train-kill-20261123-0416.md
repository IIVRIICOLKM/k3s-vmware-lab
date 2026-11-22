# F2 학습 파드 중단 → 체크포인트 재개 (graceful) (2026-11-23 04:16)

- 생성: `scripts/fault-test.sh train-kill --mode graceful --job-id fault-1123-graceful --prom monitoring/prometheus:9090 --yes`
- 설계: `docs/plan-week13-verification.md`. 시각은 이 PC(gpu-host) 시계 기준이고, 측정 오차는 확인 간격(약 1초) 안팎이다.
- 작업 번호 `fault-1123-graceful`, 방식 `graceful` (SIGTERM: 기존 scripts/train-resume-test.sh 재사용)

**실험 시작: ci 네임스페이스 파드 (Jenkins 에이전트 = 빌드 중)**

```text
NAME        READY   STATUS    RESTARTS   AGE     IP           NODE           NOMINATED NODE   READINESS GATES
jenkins-0   1/1     Running   0          6h44m   10.42.3.19   worker-cpu-1   <none>           <none>
```

**실험 시작: gpu-host CPU·메모리 사용량 (kubectl top)**

```text
NAME       CPU(cores)   CPU(%)   MEMORY(bytes)   MEMORY(%)   
gpu-host   2402m        15%      16072Mi         50%         
```

**scripts/train-resume-test.sh fault-1123-graceful 출력 (끝 20줄)**

```text
04:16:51 start train-fault-1123-graceful (image tag v0.4)
04:17:01 deleting train-fault-1123-graceful-t5kwf in the middle of the run
04:17:35 PASS 첫 파드가 SIGTERM에 체크포인트를 남기고 INTERRUPTED로 끝남
04:17:35 PASS 재시도 파드가 체크포인트에서 이어서 학습 (resumed_from)
04:17:35 PASS Job 결과 Complete
04:17:35 PASS GPU(cuda)에서 학습
04:17:35 PASS 최종 상태 DONE + 추론용 model.k3sm 생성
04:17:47 PASS 이미 DONE인 작업은 다시 학습하지 않음
04:17:47 train resume test: PASS 6, FAIL 0 (job fault-1123-graceful, report: /home/lkm/orca/workspaces/k3s-vmware-lab/verify-faults/docs/labs/train-resume-20261123-0416.md)
```

기존 스크립트가 만든 자체 보고서: `docs/labs/train-resume-20261123-0416.md` (이 보고서의 판정은 아래 DB 이력으로 따로 한다)

- ✅ **PASS** — 기존 시험 train-resume-test.sh가 통과 (종료 코드 0)

**상태 이력 (UNIX 시각, 상태, 에폭, 체크포인트, resumed_from)**

```text
1795375016.031	RUNNING	1	-	-
1795375016.470	RUNNING	1	/checkpoints/fault-1123-graceful/ckpt-e0001-s00200.pt	-
1795375019.653	RUNNING	2	/checkpoints/fault-1123-graceful/ckpt-e0002-s00200.pt	-
1795375022.658	INTERRUPTED	3	/checkpoints/fault-1123-graceful/ckpt-e0003-s00001.pt	-
1795375036.797	RUNNING	3	/checkpoints/fault-1123-graceful/ckpt-e0003-s00001.pt	/checkpoints/fault-1123-graceful/ckpt-e0003-s00001.pt
1795375037.234	RUNNING	3	/checkpoints/fault-1123-graceful/ckpt-e0003-s00200.pt	-
1795375040.410	RUNNING	4	/checkpoints/fault-1123-graceful/ckpt-e0004-s00200.pt	-
1795375043.584	RUNNING	5	/checkpoints/fault-1123-graceful/ckpt-e0005-s00200.pt	-
1795375046.757	RUNNING	6	/checkpoints/fault-1123-graceful/ckpt-e0006-s00200.pt	-
1795375049.761	DONE	6	/checkpoints/fault-1123-graceful/ckpt-e0006-s00200.pt	-
```

- 📏 중단(INTERRUPTED 기록) → 재개(resumed_from 기록): **14.1초 (DB 시각, 밀리초 기록)**

- ✅ **PASS** — 재개한 체크포인트가 중단 시점 체크포인트와 같음 (손실 0)

- ✅ **PASS** — 재개 기록(resumed_from)이 DB에 있음

- ✅ **PASS** — 최종 상태 DONE

- ✅ **PASS** — attempts가 2 이상 (재시도로 파드가 다시 시작됨)

- ✅ **PASS** — 추론용 model.k3sm이 만들어짐

**Prometheus: 학습 파드 재시작·상태  (쿼리: kube_pod_status_phase{namespace="default",pod=~"train-fault-1123-graceful-.*"})**

```text
__name__=kube_pod_status_phase,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=default,phase=Pending,pod=train-fault-1123-graceful-78qvg,uid=b55d9e7e-102c-4010-a012-ca5397ba79a1	0
__name__=kube_pod_status_phase,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=default,phase=Succeeded,pod=train-fault-1123-graceful-78qvg,uid=b55d9e7e-102c-4010-a012-ca5397ba79a1	1
__name__=kube_pod_status_phase,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=default,phase=Failed,pod=train-fault-1123-graceful-78qvg,uid=b55d9e7e-102c-4010-a012-ca5397ba79a1	0
__name__=kube_pod_status_phase,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=default,phase=Unknown,pod=train-fault-1123-graceful-78qvg,uid=b55d9e7e-102c-4010-a012-ca5397ba79a1	0
__name__=kube_pod_status_phase,instance=10.42.3.6:8080,job=kube-state-metrics,namespace=default,phase=Running,pod=train-fault-1123-graceful-78qvg,uid=b55d9e7e-102c-4010-a012-ca5397ba79a1	0
```

## 되돌리기

학습 릴리스만 지웠다. DB 행(`scripts/job.sh status fault-1123-graceful`)과 `/var/lib/k3slab/checkpoints/fault-1123-graceful`는 증거로 남긴다(폴더는 root 소유).

- ✅ **PASS** — 노드 4개 모두 Ready

- ✅ **PASS** — GPU를 쓰는 파드가 남아 있지 않음 (GPU 반납)

- ✅ **PASS** — default의 train-fault-1123-graceful Helm 릴리스가 지워짐

## 결과 요약

PASS 9, FAIL 0

---

## 4. 사람이 덧붙인 부분 (위는 `scripts/fault-test.sh`가 쓴 것, 아래는 실행 뒤에 사람이 정리한 것)

14주차 몫(계획 6절 순서 6, F2 graceful)을 12주차 첫날(2026-11-23, 1주차 = 9/7)에 앞당겨 실행했다. 작업 번호 `fault-1123-graceful`(새 번호), 학습 이미지 `train-worker:v0.4`, 기존 `scripts/train-resume-test.sh`를 그대로 썼다(6 에폭 × 200 스텝, 에폭마다 3초 쉼). 이 스크립트가 새로 만든 자체 보고서는 **`docs/labs/train-resume-20261123-0416.md`**(PASS 6 / FAIL 0, 기존 보고서는 덮어쓰지 않았다)다. GPU 슬롯은 이 실험 동안 내가 썼고 끝난 뒤 GPU를 요청한 파드는 0개다(위 PASS). DB 행과 체크포인트 폴더 `/var/lib/k3slab/checkpoints/fault-1123-graceful`은 증거로 남겼다.

### 4.1 핵심 숫자 (graceful = SIGTERM)과 force·11/7 기록과의 비교

| 항목 | **graceful (이 실행)** | force (`fault-train-kill-20261123-0413.md`) | 11/7 기록 (`train-resume-20261107-1253.md`, graceful) |
|---|---|---|---|
| 중단 → 재개(`resumed_from`) | **14.1초** (DB 시각, 밀리초 기록. 04:17:02.658 → 04:17:16.797) | 15.8초 (스크립트가 잰 값, 확인 간격 1~2초) | 14초 (UTC 03:56:32 → 03:56:46) |
| 중단 때 남긴 기록 | `INTERRUPTED`, 체크포인트 **`ckpt-e0003-s00001.pt`**(에폭 3, 1스텝) | 없음(SIGKILL) | `INTERRUPTED` |
| 재개한 체크포인트 | `ckpt-e0003-s00001.pt` — **중단 시점 체크포인트와 같음** | `ckpt-e0002-s00200.pt`(마지막 에폭 끝) | 같은 체크포인트 |
| 손실 | **0** (중단 시점에서 이어감. 에폭 3의 1스텝까지 보존) | 완료한 에폭 0, **진행 중이던 에폭 3은 처음부터 다시** | 0 |
| 최종 | DONE(에폭 6), `attempts` 2, `model.k3sm` 생성 | DONE(에폭 8), `attempts` 2 | DONE |
| 판정 | PASS 9 / FAIL 0 (`train-resume-test.sh` 안쪽 PASS 6 / FAIL 0 포함) | PASS 8 / FAIL 0 | — |

- **graceful과 force의 차이는 "중단 시점의 진행량을 보존하는가"다.** SIGTERM을 받은 학습 파드는 그 자리(에폭 3의 1스텝)에서 체크포인트를 남기고 `INTERRUPTED`로 끝났고, 재시도 파드가 정확히 그 체크포인트에서 이어 갔다. SIGKILL은 종료 신호를 못 받아 마지막 에폭 끝 체크포인트(에폭 2)로 돌아간다. **재개 시간은 둘 다 14~16초로 거의 같다**(차이는 측정 방식과 확인 간격 안). 즉 두 방식의 차이는 시간이 아니라 잃는 진행량이다.
- 이 실험의 에폭은 짧아서(200스텝, 계산 약 0.4초) force의 손실도 작다. 에폭이 길어지면 force의 손실이 에폭 하나만큼 늘 수 있다(체크포인트 간격 = 에폭 하나). 이번에는 더 긴 에폭으로 재 보지 않았다.
- **재개 14.1초에는 새 파드 시작 외에 Job 컨트롤러가 다시 만들기 전의 대기가 들어 있을 가능성이 크다**(force의 15.8초, 11/7의 14초와 비슷하다). 대기를 따로 재지는 않았다.
- 시작 때 `ci`에는 `jenkins-0`만 있었고 에이전트 파드가 없었다(위 "실험 시작" 블록). gpu-host CPU 2402m(15%).
- **Prometheus 쿼리 결과(위 "학습 파드 재시작·상태")에 나온 파드 `…78qvg`(Succeeded)는 "같은 작업 번호로 다시 요청"(`train-resume-20261123-0416.md` 3절)에서 만들어진 파드다.** 이미 DONE인 작업이라 학습하지 않고 끝난 파드다. 이 쿼리는 지금 시점의 값이라 첫 파드(`…t5kwf`, SIGTERM으로 삭제)와 재시도 파드(`…gmvk6`)는 이미 사라져서 나오지 않는다. 파드별 이력의 근거는 위 DB 이력과 `train-resume-20261123-0416.md`다.
- Grafana 화면은 이 실험에서는 따로 찍지 않았다(계획은 F2 force만 지정). 학습 대시보드·DCGM 확인은 force 보고서 4.2·4.3절에 있다.

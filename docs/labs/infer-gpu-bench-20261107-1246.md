# 추론 워커 CPU vs GPU (2026-11-07 12:46)

- 생성: `scripts/infer-gpu-bench.sh db-1107b-train bench-large v0.2`
- 이미지 `registry.k3slab.local:5000/infer-worker:v0.2`, gpu-host(RTX 3090)에서 실행
- 공통 조건: 요청 400개, 동시 100개, MAX_BATCH 8, 스레드 2, WORK_MS 0(흉내 비용 없이 실제 계산만)
- CPU 실행은 GPU를 요청하지 않음(DEVICE=cpu), GPU 실행은 GPU 1개 요청(DEVICE=cuda)
- "배치 계산 시간"은 워커가 배치를 계산하는 데 쓴 시간의 합(큐 대기·HTTP 제외)

## 작은 모델 (`db-1107b-train`)

### 작은 모델 · CPU

```text
  k3slab-infer: model /models/db-1107b-train/model.k3sm (v0) in=64 out=10 layers=2 macs/sample=9472; device=cpu (cpu); MAX_QUEUE=500 MAX_BATCH=8 WORKER_THREADS=2 TIMEOUT_MS=30000 WORK_MS=0 PORT=8080
    400 200
elapsed_seconds 1.27
k3slab_infer_info{device="cpu",gpu="",model_version="v0"} 1
k3slab_infer_requests_total{result="ok"} 400
k3slab_infer_batch_size_sum 400
k3slab_infer_batch_size_count 398
k3slab_infer_batch_compute_seconds_sum 0.002946
sample_response {"class":9,"batch":1,"queue_ms":0,"device":"cpu","model_version":"v0","probs":[0.11131,0.10886,0.07117,0.04424,0.06280,0.02707,0.04345,0.07155,0.01421,0.44534]}
```

### 작은 모델 · GPU

```text
  k3slab-infer: self-test 8 samples, max relative logit difference GPU vs CPU 4.19e-07
  k3slab-infer: model /models/db-1107b-train/model.k3sm (v0) in=64 out=10 layers=2 macs/sample=9472; device=cuda (NVIDIA GeForce RTX 3090); MAX_QUEUE=500 MAX_BATCH=8 WORKER_THREADS=2 TIMEOUT_MS=30000 WORK_MS=0 PORT=8080
    400 200
elapsed_seconds 1.21
k3slab_infer_info{device="cuda",gpu="NVIDIA GeForce RTX 3090",model_version="v0"} 1
k3slab_infer_requests_total{result="ok"} 400
k3slab_infer_batch_size_sum 400
k3slab_infer_batch_size_count 394
k3slab_infer_batch_compute_seconds_sum 0.075912
sample_response {"class":9,"batch":1,"queue_ms":0,"device":"cuda","model_version":"v0","probs":[0.11131,0.10886,0.07117,0.04424,0.06280,0.02707,0.04345,0.07155,0.01421,0.44534]}
```

## 큰 모델 (`bench-large`)

### 큰 모델 · CPU

```text
  k3slab-infer: model /models/bench-large/model.k3sm (v1-4096x2) in=64 out=10 layers=3 macs/sample=17080320; device=cpu (cpu); MAX_QUEUE=500 MAX_BATCH=8 WORKER_THREADS=2 TIMEOUT_MS=30000 WORK_MS=0 PORT=8080
    400 200
elapsed_seconds 2.30
k3slab_infer_info{device="cpu",gpu="",model_version="v1-4096x2"} 1
k3slab_infer_requests_total{result="ok"} 400
k3slab_infer_batch_size_sum 400
k3slab_infer_batch_size_count 59
k3slab_infer_batch_compute_seconds_sum 4.487501
sample_response {"class":9,"batch":1,"queue_ms":12,"device":"cpu","model_version":"v1-4096x2","probs":[0.00003,0.00185,0.00003,0.00080,0.00740,0.00002,0.00007,0.00001,0.00000,0.98978]}
```

### 큰 모델 · GPU

```text
  k3slab-infer: self-test 8 samples, max relative logit difference GPU vs CPU 1.33e-06
  k3slab-infer: model /models/bench-large/model.k3sm (v1-4096x2) in=64 out=10 layers=3 macs/sample=17080320; device=cuda (NVIDIA GeForce RTX 3090); MAX_QUEUE=500 MAX_BATCH=8 WORKER_THREADS=2 TIMEOUT_MS=30000 WORK_MS=0 PORT=8080
    400 200
elapsed_seconds 1.25
k3slab_infer_info{device="cuda",gpu="NVIDIA GeForce RTX 3090",model_version="v1-4096x2"} 1
k3slab_infer_requests_total{result="ok"} 400
k3slab_infer_batch_size_sum 400
k3slab_infer_batch_size_count 397
k3slab_infer_batch_compute_seconds_sum 0.111158
sample_response {"class":9,"batch":1,"queue_ms":0,"device":"cuda","model_version":"v1-4096x2","probs":[0.00003,0.00185,0.00003,0.00080,0.00740,0.00002,0.00007,0.00001,0.00000,0.98978]}
```

## 요약

| 경우 | 걸린 시간 | 배치 계산 시간 합 | 성공 |
|---|---|---|---|
| 작은 모델 · CPU | 1.27s | 0.003s | 400/400 |
| 작은 모델 · GPU | 1.21s | 0.076s | 400/400 |
| 큰 모델 · CPU | 2.30s | 4.488s | 400/400 |
| 큰 모델 · GPU | 1.25s | 0.111s | 400/400 |

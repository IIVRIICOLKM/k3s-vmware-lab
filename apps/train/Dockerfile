# Training image: PyTorch runtime + train.py. CUDA 13.0 is the newest the host driver (580) supports.
# Built in the cluster by scripts/image-build.sh (Kaniko) and pushed to the in-cluster registry.
FROM docker.io/pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime
WORKDIR /app
COPY train.py /app/train.py
ENV PYTHONUNBUFFERED=1 CHECKPOINT_DIR=/checkpoints
ENTRYPOINT ["python", "/app/train.py"]

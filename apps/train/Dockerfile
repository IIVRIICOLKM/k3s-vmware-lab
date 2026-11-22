# Training image: PyTorch runtime + train.py. CUDA 13.0 is the newest the host driver (580) supports.
# Built in the cluster by scripts/image-build.sh (Kaniko) and pushed to the in-cluster registry.
# The folder stays flat (files only): the build context is shipped to the cluster as a ConfigMap.
FROM docker.io/pytorch/pytorch:2.14.1-cuda13.0-cudnn9-runtime
WORKDIR /app
COPY requirements.txt /app/requirements.txt
# Pinned version and SHA-256 (--require-hashes): the same request always installs the same file.
# The image's Python is "externally managed" (PEP 668), so the package goes to its own folder (--target) on
# PYTHONPATH instead of into the system site-packages.
RUN pip install --no-cache-dir --require-hashes --no-deps --target /app/vendor -r /app/requirements.txt
COPY train.py datasets.py jobdb.py /app/
ENV PYTHONUNBUFFERED=1 CHECKPOINT_DIR=/checkpoints PYTHONPATH=/app/vendor
ENTRYPOINT ["python", "/app/train.py"]

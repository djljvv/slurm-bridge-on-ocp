# GPU-capable text classifier fine-tuning image for the Slurm Bridge demo.
#
# Uses the official PyTorch CUDA runtime as a base — torch is pre-installed
# with CUDA support, so only transformers/pandas are added via pip. The same
# train.py auto-detects CUDA at runtime and falls back to CPU, so this image
# works on both GPU and CPU nodes.
#
# For a smaller CPU-only image (~2 GB vs ~8 GB), see Dockerfile.cpu.
#
# Build (from repo root):
#   podman build -t <registry>/<repo>/slurm-bridge-text-classifier:latest -f training/Dockerfile training/
#   podman push <registry>/<repo>/slurm-bridge-text-classifier:latest
#
# In-cluster build (OpenShift):
#   oc new-project text-classifier-build
#   oc new-build --name=text-classifier-trainer --binary --strategy=docker
#   oc start-build text-classifier-trainer --from-dir=training/ --follow
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

ARG MODEL_NAME=distilbert-base-uncased
ARG NUM_LABELS=4
ENV HF_HOME=/app/.cache/huggingface \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN pip install --no-cache-dir transformers==4.46.3 pandas==2.2.3

# Pre-download the pretrained encoder + tokenizer so the image is
# self-contained. The classification head is randomly initialized at
# fine-tuning time (from_pretrained with num_labels), not baked in here.
RUN python -c "\
from transformers import AutoTokenizer, AutoModelForSequenceClassification; \
AutoTokenizer.from_pretrained('${MODEL_NAME}'); \
AutoModelForSequenceClassification.from_pretrained('${MODEL_NAME}', num_labels=${NUM_LABELS})"

COPY train.py predict.py .
COPY data/ ./data/
COPY data-full/ ./data-full/

ENTRYPOINT ["torchrun"]
CMD ["--nnodes=1", "--nproc_per_node=2", "/app/train.py"]

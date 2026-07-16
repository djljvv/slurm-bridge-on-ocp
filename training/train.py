#!/usr/bin/env python3
"""
Fine-tune distilbert-base-uncased on the vendored AG News subset
(training/data/{train,test}.csv) — 4-class news topic classification.

Runs standalone (`python3 train.py`) or under `torchrun` for multi-process
DDP on CPU cores (`torchrun --nproc_per_node=N train.py`). Structure follows
the standard PyTorch DDP pattern (init_process_group, DistributedSampler,
per-epoch train/eval, checkpoint + metrics saving) so it scales to multiple
nodes later without a rewrite — for this demo it's launched single-node.

Since the classification head is randomly initialized on top of the
pretrained encoder, accuracy before any training is near chance level
(~25% for 4 classes) — this is recorded as "baseline_accuracy" and is the
whole point of measuring it before training starts.

Writes <output-dir>/metrics.json (baseline/per-epoch/final accuracy) and
<output-dir>/checkpoint/ (fine-tuned model + tokenizer).
"""
import argparse
import json
import os
import pathlib
import time

import pandas as pd
import torch
import torch.distributed as dist
from torch.nn.parallel import DistributedDataParallel
from torch.utils.data import DataLoader, Dataset, DistributedSampler
from transformers import AutoModelForSequenceClassification, AutoTokenizer

LABEL_NAMES = {0: "World", 1: "Sports", 2: "Business", 3: "Sci/Tech"}
REPO_ROOT = pathlib.Path(__file__).resolve().parent
DEFAULT_DATA_DIR = REPO_ROOT / "data"


class TextClassificationDataset(Dataset):
    """Pre-tokenizes the whole (small) CSV upfront — simpler than tokenizing
    on the fly, and cheap given the dataset is only a few thousand rows."""

    def __init__(self, csv_path: pathlib.Path, tokenizer, max_length: int):
        df = pd.read_csv(csv_path)
        encoded = tokenizer(
            df["text"].tolist(),
            padding="max_length",
            truncation=True,
            max_length=max_length,
            return_tensors="pt",
        )
        self.input_ids = encoded["input_ids"]
        self.attention_mask = encoded["attention_mask"]
        self.labels = torch.tensor(df["label"].tolist(), dtype=torch.long)

    def __len__(self):
        return len(self.labels)

    def __getitem__(self, idx):
        return {
            "input_ids": self.input_ids[idx],
            "attention_mask": self.attention_mask[idx],
            "labels": self.labels[idx],
        }


def log(rank: int, msg: str) -> None:
    if rank == 0:
        print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def evaluate(model, loader, device) -> float:
    model.eval()
    correct, total = 0, 0
    with torch.no_grad():
        for batch in loader:
            batch = {k: v.to(device) for k, v in batch.items()}
            logits = model(
                input_ids=batch["input_ids"], attention_mask=batch["attention_mask"]
            ).logits
            preds = logits.argmax(dim=-1)
            correct += (preds == batch["labels"]).sum().item()
            total += batch["labels"].size(0)
    return correct / total


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-name", default="distilbert-base-uncased")
    parser.add_argument("--num-labels", type=int, default=len(LABEL_NAMES))
    parser.add_argument("--data-dir", type=pathlib.Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--output-dir", type=pathlib.Path, default=pathlib.Path("/results"))
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--max-length", type=int, default=128)
    parser.add_argument("--lr", type=float, default=5e-5)
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    torch.manual_seed(args.seed)

    # torchrun sets RANK/WORLD_SIZE/LOCAL_RANK; plain `python train.py` doesn't.
    # Only stand up a process group when actually running multi-process — keeps
    # single-process runs (e.g. local smoke tests) simple.
    world_size = int(os.environ.get("WORLD_SIZE", "1"))
    distributed = world_size > 1
    rank = int(os.environ.get("RANK", "0"))
    local_rank = int(os.environ.get("LOCAL_RANK", "0"))

    use_cuda = torch.cuda.is_available()
    if distributed:
        dist.init_process_group(backend="nccl" if use_cuda else "gloo")

    if use_cuda:
        torch.cuda.set_device(local_rank)
        device = torch.device(f"cuda:{local_rank}")
    else:
        device = torch.device("cpu")
    log(rank, f"world_size={world_size} rank={rank} local_rank={local_rank} device={device}")

    tokenizer = AutoTokenizer.from_pretrained(args.model_name)
    log(rank, f"Loading model '{args.model_name}' ({args.num_labels} labels)...")
    # Bake friendly label names into the checkpoint's config (instead of the
    # default generic LABEL_0/LABEL_1/...) so anything loading the saved
    # checkpoint later (e.g. predict.py) can read them straight off the model
    # instead of hardcoding the mapping a second time.
    label_kwargs = {}
    if args.num_labels == len(LABEL_NAMES):
        label_kwargs = {
            "id2label": LABEL_NAMES,
            "label2id": {name: idx for idx, name in LABEL_NAMES.items()},
        }
    model = AutoModelForSequenceClassification.from_pretrained(
        args.model_name, num_labels=args.num_labels, **label_kwargs
    ).to(device)

    train_dataset = TextClassificationDataset(
        args.data_dir / "train.csv", tokenizer, args.max_length
    )
    test_dataset = TextClassificationDataset(
        args.data_dir / "test.csv", tokenizer, args.max_length
    )
    log(rank, f"train_rows={len(train_dataset)} test_rows={len(test_dataset)}")

    if distributed:
        train_sampler = DistributedSampler(train_dataset, shuffle=True, seed=args.seed)
        train_loader = DataLoader(train_dataset, batch_size=args.batch_size, sampler=train_sampler)
        model = DistributedDataParallel(model)
    else:
        train_sampler = None
        train_loader = DataLoader(train_dataset, batch_size=args.batch_size, shuffle=True)

    # Every rank evaluates the full (small) test set redundantly — simpler
    # than aggregating partial results across ranks, and cheap at this size.
    eval_loader = DataLoader(test_dataset, batch_size=args.batch_size)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)

    baseline_accuracy = evaluate(model, eval_loader, device)
    log(rank, f"baseline (pre-training) accuracy={baseline_accuracy:.4f}")

    epoch_metrics = []
    for epoch in range(1, args.epochs + 1):
        if train_sampler is not None:
            train_sampler.set_epoch(epoch)
        model.train()
        running_loss, steps = 0.0, 0
        for batch in train_loader:
            batch = {k: v.to(device) for k, v in batch.items()}
            optimizer.zero_grad()
            outputs = model(
                input_ids=batch["input_ids"],
                attention_mask=batch["attention_mask"],
                labels=batch["labels"],
            )
            outputs.loss.backward()
            optimizer.step()
            running_loss += outputs.loss.item()
            steps += 1

        train_loss = running_loss / max(steps, 1)
        eval_accuracy = evaluate(model, eval_loader, device)
        log(
            rank,
            f"epoch {epoch}/{args.epochs} train_loss={train_loss:.4f} "
            f"eval_accuracy={eval_accuracy:.4f}",
        )
        epoch_metrics.append(
            {"epoch": epoch, "train_loss": train_loss, "eval_accuracy": eval_accuracy}
        )

    final_accuracy = epoch_metrics[-1]["eval_accuracy"] if epoch_metrics else baseline_accuracy

    if rank == 0:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        metrics = {
            "model_name": args.model_name,
            "world_size": world_size,
            "train_rows": len(train_dataset),
            "test_rows": len(test_dataset),
            "labels": LABEL_NAMES,
            "baseline_accuracy": baseline_accuracy,
            "epochs": epoch_metrics,
            "final_accuracy": final_accuracy,
        }
        metrics_path = args.output_dir / "metrics.json"
        metrics_path.write_text(json.dumps(metrics, indent=2))
        log(rank, f"Wrote metrics to {metrics_path}")

        underlying_model = model.module if isinstance(model, DistributedDataParallel) else model
        checkpoint_dir = args.output_dir / "checkpoint"
        underlying_model.save_pretrained(checkpoint_dir)
        tokenizer.save_pretrained(checkpoint_dir)
        log(rank, f"Saved fine-tuned checkpoint to {checkpoint_dir}")
        log(rank, f"baseline_accuracy={baseline_accuracy:.4f} -> final_accuracy={final_accuracy:.4f}")

    if distributed:
        dist.destroy_process_group()


if __name__ == "__main__":
    main()

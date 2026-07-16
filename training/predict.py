#!/usr/bin/env python3
"""
Run the fine-tuned text classifier checkpoint (produced by train.py) on real
text — the "does this actually work" demo, complementing metrics.json's
accuracy numbers with concrete predictions.

Three modes:
  1. Classify specific headlines:
       python3 predict.py --text "Apple unveils new chip for the iPhone" \\
                           "Lakers win in overtime thriller"
  2. Sample rows from the vendored test set (shows predicted vs. actual):
       python3 predict.py --num-samples 8
  3. Interactive — type headlines, see live predictions, blank line to quit:
       python3 predict.py --interactive

Works two ways depending on where the checkpoint ended up:
  - Locally, after demos/text-classifier-demo.sh pulls it via `oc cp` into
    results/text-classifier-demo/checkpoint/ (needs torch+transformers
    installed locally — they are NOT installed on the machine running the
    demo script by default, only inside the training image).
  - Inside the cluster, e.g. `oc exec <pod> -- python3 /app/predict.py ...`
    against /results/checkpoint — no extra local install needed, since the
    training image already has torch+transformers baked in.
"""
import argparse
import pathlib
import random
import sys

import pandas as pd
import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer

REPO_ROOT = pathlib.Path(__file__).resolve().parent
DEFAULT_CHECKPOINT_DIR = pathlib.Path("/results/checkpoint")
DEFAULT_DATA_DIR = REPO_ROOT / "data"
# Fallback only — a checkpoint saved by the current train.py already carries
# these as id2label in its own config, so this is just for older checkpoints.
FALLBACK_LABEL_NAMES = {0: "World", 1: "Sports", 2: "Business", 3: "Sci/Tech"}


def load_model(checkpoint_dir: pathlib.Path):
    if not checkpoint_dir.exists():
        sys.exit(
            f"Checkpoint dir not found: {checkpoint_dir}\n"
            "Run the training demo first (./demos/text-classifier-demo.sh), "
            "or pass --checkpoint-dir explicitly."
        )
    tokenizer = AutoTokenizer.from_pretrained(checkpoint_dir)
    model = AutoModelForSequenceClassification.from_pretrained(checkpoint_dir)
    model.eval()
    id2label = model.config.id2label or FALLBACK_LABEL_NAMES
    return tokenizer, model, id2label


def classify(text: str, tokenizer, model, id2label: dict, max_length: int):
    inputs = tokenizer(
        text, padding=True, truncation=True, max_length=max_length, return_tensors="pt"
    )
    with torch.no_grad():
        logits = model(**inputs).logits[0]
    probs = torch.softmax(logits, dim=-1)
    pred_idx = int(probs.argmax())
    return id2label[pred_idx], float(probs[pred_idx])


def print_prediction(text: str, label: str, confidence: float, actual: str = None):
    shown = text if len(text) <= 90 else text[:87] + "..."
    line = f'  "{shown}"\n    -> predicted: {label} ({confidence:.1%})'
    if actual is not None:
        marker = "✓" if label == actual else "✗"
        line += f"  actual: {actual} {marker}"
    print(line)


def run_texts(texts, tokenizer, model, id2label, max_length):
    for text in texts:
        label, confidence = classify(text, tokenizer, model, id2label, max_length)
        print_prediction(text, label, confidence)


def run_samples(num_samples, data_dir, seed, tokenizer, model, id2label, max_length):
    test_csv = data_dir / "test.csv"
    if not test_csv.exists():
        sys.exit(f"Test data not found: {test_csv}")
    df = pd.read_csv(test_csv)
    sample = df.sample(n=min(num_samples, len(df)), random_state=seed)

    correct = 0
    for _, row in sample.iterrows():
        actual = id2label.get(row["label"], FALLBACK_LABEL_NAMES.get(row["label"]))
        label, confidence = classify(row["text"], tokenizer, model, id2label, max_length)
        print_prediction(row["text"], label, confidence, actual=actual)
        correct += label == actual

    print(f"\n  {correct}/{len(sample)} correct on this sample ({correct / len(sample):.1%})")


def run_interactive(tokenizer, model, id2label, max_length):
    print("Type a headline and press Enter to classify it (blank line to quit):\n")
    while True:
        try:
            text = input("> ").strip()
        except EOFError:
            break
        if not text:
            break
        label, confidence = classify(text, tokenizer, model, id2label, max_length)
        print(f"    -> {label} ({confidence:.1%})\n")


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--checkpoint-dir", type=pathlib.Path, default=DEFAULT_CHECKPOINT_DIR)
    parser.add_argument("--data-dir", type=pathlib.Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--text", nargs="+", help="One or more headlines to classify")
    parser.add_argument(
        "--num-samples", type=int, default=5,
        help="Sample this many rows from test.csv if --text/--interactive aren't given",
    )
    parser.add_argument("--interactive", action="store_true")
    parser.add_argument("--max-length", type=int, default=128)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    tokenizer, model, id2label = load_model(args.checkpoint_dir)
    print(f"Loaded checkpoint from {args.checkpoint_dir} (labels: {list(id2label.values())})\n")

    if args.interactive:
        run_interactive(tokenizer, model, id2label, args.max_length)
    elif args.text:
        run_texts(args.text, tokenizer, model, id2label, args.max_length)
    else:
        random.seed(args.seed)
        run_samples(
            args.num_samples, args.data_dir, args.seed, tokenizer, model, id2label, args.max_length
        )


if __name__ == "__main__":
    main()

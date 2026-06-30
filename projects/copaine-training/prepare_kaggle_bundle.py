from __future__ import annotations

import argparse
import json
import shutil
from pprint import pformat
from pathlib import Path

from model_presets import DEFAULT_DATASET_SLUG, MODEL_LADDER, get_preset


DEFAULT_TRAINING_DIR = Path("training_assets_kaggle")
DEFAULT_BUNDLE_DIR = Path("kaggle_bundle")
DEFAULT_OWNER = "YOUR_KAGGLE_USERNAME"


DATASET_FILES = (
    "train_mixed.jsonl",
    "val_mixed.jsonl",
    "heldout_eval.jsonl",
    "manual_eval_prompts.jsonl",
    "overfit_smoke.jsonl",
    "style_selected.jsonl",
    "behavior_examples.jsonl",
    "human_style_examples.jsonl",
    "human_feel_eval_prompts.jsonl",
    "style_reference.txt",
    "summary.json",
)

ROOT_LEVEL_DATASET_FILES = (
    "privacy_blocklist.txt",
)

KERNEL_FILES = (
    "run_kaggle_training_job.py",
)

KERNEL_ASSET_FILES = (
    "train_mixed.jsonl",
    "val_mixed.jsonl",
    "manual_eval_prompts.jsonl",
    "human_feel_eval_prompts.jsonl",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Stage a Kaggle dataset + kernel bundle from the local training assets.")
    parser.add_argument("--training-dir", type=Path, default=DEFAULT_TRAINING_DIR)
    parser.add_argument("--bundle-dir", type=Path, default=DEFAULT_BUNDLE_DIR)
    parser.add_argument("--owner-slug", default=DEFAULT_OWNER)
    parser.add_argument("--dataset-slug", default=DEFAULT_DATASET_SLUG)
    parser.add_argument("--preset", choices=MODEL_LADDER, default="medium")
    parser.add_argument("--kernel-slug")
    return parser.parse_args()


def safe_reset_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def main() -> None:
    args = parse_args()
    preset = get_preset(args.preset)
    training_dir = args.training_dir.resolve()
    bundle_dir = args.bundle_dir.resolve()
    dataset_dir = bundle_dir / "dataset"
    kernel_dir = bundle_dir / "kernel"

    for required in ("train_mixed.jsonl", "val_mixed.jsonl", "manual_eval_prompts.jsonl"):
        if not (training_dir / required).exists():
            raise SystemExit(
                f"Missing {required} in {training_dir}. Run prepare_kaggle_training_assets.py first."
            )

    safe_reset_dir(dataset_dir)
    safe_reset_dir(kernel_dir)

    for name in DATASET_FILES:
        source = training_dir / name
        if source.exists():
            shutil.copy2(source, dataset_dir / name)

    for name in ROOT_LEVEL_DATASET_FILES:
        source = Path(name).resolve()
        if source.exists():
            shutil.copy2(source, dataset_dir / name)

    for name in KERNEL_FILES:
        source = Path(name).resolve()
        shutil.copy2(source, kernel_dir / name)

    for name in KERNEL_ASSET_FILES:
        source = training_dir / name
        if source.exists():
            shutil.copy2(source, kernel_dir / name)

    for name in ROOT_LEVEL_DATASET_FILES:
        source = Path(name).resolve()
        if source.exists():
            shutil.copy2(source, kernel_dir / name)

    dataset_ref = f"{args.owner_slug}/{args.dataset_slug}"
    kernel_slug = args.kernel_slug or preset.kernel_slug
    kernel_ref = f"{args.owner_slug}/{kernel_slug}"

    dataset_title = "Support Bot Style Pack" if preset.key != "empathy" else "Support Bot Style Pack - Empathy"
    dataset_metadata = {
        "title": dataset_title,
        "subtitle": f"Private sanitized LoRA pack for the {preset.label.lower()} model preset",
        "description": (
            "Private sanitized training pack for a local-style support bot experiment. "
            "Includes a smaller style subset, a separate behavior/accountability set, "
            "manual eval prompts, and held-out validation data."
        ),
        "id": dataset_ref,
        "licenses": [{"name": "other"}],
        "keywords": ["llm", "chatbot", "lora", "text generation"],
    }
    (dataset_dir / "dataset-metadata.json").write_text(json.dumps(dataset_metadata, indent=2) + "\n", encoding="utf-8")

    kernel_metadata = {
        "id": kernel_ref,
        "title": preset.kernel_title,
        "code_file": "run_kaggle_training_job.py",
        "language": "python",
        "kernel_type": "script",
        "is_private": "true",
        "enable_gpu": "true",
        "enable_internet": "true",
        "dataset_sources": [dataset_ref],
        "competition_sources": [],
        "kernel_sources": [],
        "model_sources": [],
    }
    (kernel_dir / "kernel-metadata.json").write_text(json.dumps(kernel_metadata, indent=2) + "\n", encoding="utf-8")

    runtime_config = {
        "preset": preset.key,
        "model_id": preset.model_id,
        "dataset_ref": dataset_ref,
        "output_dir": f"/kaggle/working/{preset.output_dir.name}",
        "max_length": preset.max_length,
        "per_device_train_batch_size": preset.per_device_train_batch_size,
        "per_device_eval_batch_size": preset.per_device_eval_batch_size,
        "gradient_accumulation_steps": preset.gradient_accumulation_steps,
        "learning_rate": preset.learning_rate,
        "warmup_ratio": preset.warmup_ratio,
        "num_train_epochs": preset.num_train_epochs,
        "lora_r": preset.lora_r,
        "lora_alpha": preset.lora_alpha,
        "lora_dropout": preset.lora_dropout,
        "save_steps": preset.save_steps,
        "eval_steps": preset.eval_steps,
        "disable_thinking": preset.disable_thinking,
    }
    runtime_script = kernel_dir / "run_kaggle_training_job.py"
    runtime_source = runtime_script.read_text(encoding="utf-8")
    replacement = f"BUNDLED_RUNTIME_CONFIG = {pformat(runtime_config, sort_dicts=False, width=100)}"
    runtime_source = runtime_source.replace("BUNDLED_RUNTIME_CONFIG = None", replacement, 1)
    runtime_script.write_text(runtime_source, encoding="utf-8")

    summary = {
        "preset": preset.key,
        "preset_label": preset.label,
        "model_id": preset.model_id,
        "owner_slug": args.owner_slug,
        "owner_is_placeholder": args.owner_slug == DEFAULT_OWNER,
        "dataset_ref": dataset_ref,
        "kernel_ref": kernel_ref,
        "bundle_dir": str(bundle_dir),
        "dataset_dir": str(dataset_dir),
        "kernel_dir": str(kernel_dir),
        "notes": [
            "Kaggle datasets are private by default unless you create them with --public.",
            "The kernel is configured to run as a private GPU-enabled script with internet access.",
            "The selected preset is baked directly into the staged Kaggle script so the kernel stays self-contained.",
            "If owner_slug is still the placeholder, rerun this script with a real Kaggle username or use kaggle_remote_training.py after adding kaggle.json.",
        ],
    }
    (bundle_dir / "bundle_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

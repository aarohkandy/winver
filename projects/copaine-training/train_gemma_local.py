from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a local Gemma 4 style adapter with LoRA / QLoRA.")
    parser.add_argument("--model-id", default="google/gemma-4-E2B-it")
    parser.add_argument("--dataset-dir", type=Path, default=Path("training_assets"))
    parser.add_argument("--output-dir", type=Path, default=Path("outputs/gemma4-e2b-style-lora"))
    parser.add_argument("--max-length", type=int, default=1024)
    parser.add_argument("--num-train-epochs", type=float, default=2.0)
    parser.add_argument("--per-device-train-batch-size", type=int, default=1)
    parser.add_argument("--per-device-eval-batch-size", type=int, default=1)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=16)
    parser.add_argument("--learning-rate", type=float, default=2e-4)
    parser.add_argument("--warmup-ratio", type=float, default=0.03)
    parser.add_argument("--logging-steps", type=int, default=10)
    parser.add_argument("--save-steps", type=int, default=50)
    parser.add_argument("--eval-steps", type=int, default=0)
    parser.add_argument("--save-total-limit", type=int, default=2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--lora-r", type=int, default=16)
    parser.add_argument("--lora-alpha", type=int, default=16)
    parser.add_argument("--lora-dropout", type=float, default=0.05)
    parser.add_argument("--allow-cpu", action="store_true")
    parser.add_argument("--no-4bit", action="store_true")
    parser.add_argument("--debug-limit", type=int, default=0)
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if os.name == "nt" and not sys.flags.utf8_mode:
        raise SystemExit(
            "Windows runs should use UTF-8 mode for TRL. Rerun with: "
            "python -X utf8 train_gemma_local.py ..."
        )

    try:
        import torch
        from datasets import load_dataset
        from peft import LoraConfig
        from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig, set_seed
        from transformers.trainer_utils import get_last_checkpoint
        from trl import SFTConfig, SFTTrainer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "Missing training dependencies. Run setup_local_gemma.ps1 first, then rerun this script."
        ) from exc

    set_seed(args.seed)

    train_path = args.dataset_dir / "train_chat.jsonl"
    val_path = args.dataset_dir / "val_chat.jsonl"
    if not train_path.exists() or not val_path.exists():
        raise SystemExit(
            f"Missing training assets in {args.dataset_dir}. Run prepare_training_assets.py first."
        )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    resume_checkpoint = get_last_checkpoint(str(args.output_dir)) if args.output_dir.exists() else None

    has_cuda = torch.cuda.is_available()
    use_4bit = has_cuda and not args.no_4bit
    if not has_cuda and not args.allow_cpu:
        raise SystemExit(
            "No CUDA GPU detected. The local scaffold is ready, but training is blocked until you either "
            "install a working CUDA PyTorch stack or rerun with --allow-cpu for an extremely slow fallback."
        )

    if has_cuda and torch.cuda.is_bf16_supported():
        compute_dtype = torch.bfloat16
        use_bf16 = True
        use_fp16 = False
    elif has_cuda:
        compute_dtype = torch.float16
        use_bf16 = False
        use_fp16 = True
    else:
        compute_dtype = torch.float32
        use_bf16 = False
        use_fp16 = False

    tokenizer = AutoTokenizer.from_pretrained(args.model_id)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    quantization_config = None
    model_kwargs = {
        "torch_dtype": compute_dtype,
        "trust_remote_code": False,
    }
    if use_4bit:
        try:
            import bitsandbytes  # noqa: F401
        except ModuleNotFoundError as exc:
            raise SystemExit(
                "4-bit loading needs bitsandbytes, but it is not installed. Install it or rerun with --no-4bit."
            ) from exc
        quantization_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=compute_dtype,
        )
        model_kwargs["device_map"] = "auto"
        model_kwargs["quantization_config"] = quantization_config
    elif has_cuda:
        model_kwargs["device_map"] = "auto"

    model = AutoModelForCausalLM.from_pretrained(args.model_id, **model_kwargs)

    if hasattr(model, "gradient_checkpointing_enable") and has_cuda:
        model.gradient_checkpointing_enable()

    train_dataset = load_dataset("json", data_files=str(train_path), split="train")
    eval_dataset = load_dataset("json", data_files=str(val_path), split="train")
    if args.debug_limit > 0:
        train_dataset = train_dataset.select(range(min(args.debug_limit, len(train_dataset))))
        eval_dataset = eval_dataset.select(range(min(max(1, args.debug_limit // 10), len(eval_dataset))))

    def to_prompt_completion(example: dict) -> dict:
        prompt = tokenizer.apply_chat_template(
            example["messages"],
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
        completion = example["target"] + tokenizer.eos_token
        return {
            "prompt": prompt,
            "completion": completion,
        }

    train_dataset = train_dataset.map(to_prompt_completion, remove_columns=train_dataset.column_names)
    eval_dataset = eval_dataset.map(to_prompt_completion, remove_columns=eval_dataset.column_names)

    peft_config = LoraConfig(
        r=args.lora_r,
        lora_alpha=args.lora_alpha,
        lora_dropout=args.lora_dropout,
        bias="none",
        target_modules="all-linear",
        task_type="CAUSAL_LM",
    )

    training_args = SFTConfig(
        output_dir=str(args.output_dir),
        max_length=args.max_length,
        num_train_epochs=args.num_train_epochs,
        per_device_train_batch_size=args.per_device_train_batch_size,
        per_device_eval_batch_size=args.per_device_eval_batch_size,
        gradient_accumulation_steps=args.gradient_accumulation_steps,
        learning_rate=args.learning_rate,
        warmup_ratio=args.warmup_ratio,
        logging_steps=args.logging_steps,
        save_strategy="steps",
        save_steps=args.save_steps,
        eval_strategy="steps" if args.eval_steps > 0 else "no",
        eval_steps=args.eval_steps if args.eval_steps > 0 else None,
        save_total_limit=args.save_total_limit,
        lr_scheduler_type="constant",
        optim="adamw_torch",
        max_grad_norm=0.3,
        bf16=use_bf16,
        fp16=use_fp16,
        report_to="tensorboard",
        completion_only_loss=True,
        packing=False,
        dataset_kwargs={"add_special_tokens": False},
    )

    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        processing_class=tokenizer,
        peft_config=peft_config,
    )

    run_metadata = {
        "model_id": args.model_id,
        "dataset_dir": str(args.dataset_dir.resolve()),
        "use_4bit": use_4bit,
        "has_cuda": has_cuda,
        "dtype": str(compute_dtype),
        "train_examples": len(train_dataset),
        "eval_examples": len(eval_dataset),
        "save_steps": args.save_steps,
        "eval_steps": args.eval_steps,
        "resume_from_checkpoint": resume_checkpoint,
    }
    (args.output_dir / "run_metadata.json").write_text(json.dumps(run_metadata, indent=2) + "\n", encoding="utf-8")

    trainer.train(resume_from_checkpoint=resume_checkpoint)
    trainer.save_model(str(args.output_dir / "adapter"))
    tokenizer.save_pretrained(str(args.output_dir / "adapter"))


if __name__ == "__main__":
    main()

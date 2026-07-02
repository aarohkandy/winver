from __future__ import annotations

import argparse
import json
from pathlib import Path

from model_presets import MODEL_LADDER, get_preset


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a LoRA / QLoRA support adapter for one of the model ladder presets.")
    parser.add_argument("--preset", choices=MODEL_LADDER, default="medium")
    parser.add_argument("--model-id")
    parser.add_argument("--dataset-dir", type=Path, default=Path("training_assets_kaggle"))
    parser.add_argument("--train-file", default="train_mixed.jsonl")
    parser.add_argument("--val-file", default="val_mixed.jsonl")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--max-length", type=int)
    parser.add_argument("--num-train-epochs", type=float)
    parser.add_argument("--per-device-train-batch-size", type=int)
    parser.add_argument("--per-device-eval-batch-size", type=int)
    parser.add_argument("--gradient-accumulation-steps", type=int)
    parser.add_argument("--learning-rate", type=float)
    parser.add_argument("--warmup-ratio", type=float)
    parser.add_argument("--logging-steps", type=int, default=5)
    parser.add_argument("--save-steps", type=int)
    parser.add_argument("--eval-steps", type=int)
    parser.add_argument("--save-total-limit", type=int, default=3)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--lora-r", type=int)
    parser.add_argument("--lora-alpha", type=int)
    parser.add_argument("--lora-dropout", type=float)
    parser.add_argument("--allow-cpu", action="store_true")
    parser.add_argument("--no-4bit", action="store_true")
    parser.add_argument("--debug-limit", type=int, default=0)
    parser.add_argument("--report-to", default="tensorboard")
    return parser.parse_args()


def apply_defaults(args: argparse.Namespace) -> argparse.Namespace:
    preset = get_preset(args.preset)
    args.model_id = args.model_id or preset.model_id
    args.output_dir = args.output_dir or preset.output_dir
    args.max_length = args.max_length or preset.max_length
    args.num_train_epochs = args.num_train_epochs or preset.num_train_epochs
    args.per_device_train_batch_size = args.per_device_train_batch_size or preset.per_device_train_batch_size
    args.per_device_eval_batch_size = args.per_device_eval_batch_size or preset.per_device_eval_batch_size
    args.gradient_accumulation_steps = args.gradient_accumulation_steps or preset.gradient_accumulation_steps
    args.learning_rate = args.learning_rate or preset.learning_rate
    args.warmup_ratio = args.warmup_ratio or preset.warmup_ratio
    args.save_steps = args.save_steps or preset.save_steps
    args.eval_steps = preset.eval_steps if args.eval_steps is None else args.eval_steps
    args.lora_r = args.lora_r or preset.lora_r
    args.lora_alpha = args.lora_alpha or preset.lora_alpha
    args.lora_dropout = args.lora_dropout or preset.lora_dropout
    args.disable_thinking = preset.disable_thinking
    return args


def apply_chat_template(tokenizer, messages: list[dict], disable_thinking: bool) -> str:
    kwargs = {
        "tokenize": False,
        "add_generation_prompt": True,
    }
    if disable_thinking:
        try:
            return tokenizer.apply_chat_template(messages, enable_thinking=False, **kwargs)
        except TypeError:
            pass
    return tokenizer.apply_chat_template(messages, **kwargs)


def main() -> None:
    args = apply_defaults(parse_args())

    try:
        import torch
        from datasets import load_dataset
        from peft import LoraConfig, prepare_model_for_kbit_training
        from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig, set_seed
        from transformers.trainer_utils import get_last_checkpoint
        from trl import SFTConfig, SFTTrainer
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "Missing training dependencies. Install transformers, datasets, peft, trl, accelerate, and bitsandbytes."
        ) from exc

    set_seed(args.seed)

    train_path = (args.dataset_dir / args.train_file).resolve()
    val_path = (args.dataset_dir / args.val_file).resolve()
    if not train_path.exists() or not val_path.exists():
        raise SystemExit(
            f"Missing training files in {args.dataset_dir}. Run prepare_kaggle_training_assets.py first."
        )

    args.output_dir.mkdir(parents=True, exist_ok=True)
    resume_checkpoint = get_last_checkpoint(str(args.output_dir)) if args.output_dir.exists() else None

    has_cuda = torch.cuda.is_available()
    use_4bit = has_cuda and not args.no_4bit
    if not has_cuda and not args.allow_cpu:
        raise SystemExit(
            "No CUDA GPU detected. This trainer is meant for a Kaggle or local GPU run. Pass --allow-cpu only for debugging."
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
        compute_dtype = torch.bfloat16
        use_bf16 = False
        use_fp16 = False

    tokenizer = AutoTokenizer.from_pretrained(args.model_id, trust_remote_code=False)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model_kwargs = {
        "torch_dtype": compute_dtype,
        "trust_remote_code": False,
        "low_cpu_mem_usage": True,
    }
    if use_4bit:
        try:
            import bitsandbytes  # noqa: F401
        except ModuleNotFoundError as exc:
            raise SystemExit(
                "4-bit loading needs bitsandbytes. Install it or rerun with --no-4bit."
            ) from exc
        model_kwargs["device_map"] = "auto"
        model_kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=compute_dtype,
        )
    elif has_cuda:
        model_kwargs["device_map"] = "auto"

    model = AutoModelForCausalLM.from_pretrained(args.model_id, **model_kwargs)

    if hasattr(model, "config"):
        model.config.use_cache = False
    if hasattr(model, "gradient_checkpointing_enable"):
        model.gradient_checkpointing_enable()
    if use_4bit:
        model = prepare_model_for_kbit_training(model)

    train_dataset = load_dataset("json", data_files=str(train_path), split="train")
    eval_dataset = load_dataset("json", data_files=str(val_path), split="train")
    if args.debug_limit > 0:
        train_dataset = train_dataset.select(range(min(args.debug_limit, len(train_dataset))))
        eval_cap = min(max(1, args.debug_limit // 8), len(eval_dataset))
        eval_dataset = eval_dataset.select(range(eval_cap))

    def to_prompt_completion(example: dict) -> dict:
        prompt = apply_chat_template(tokenizer, example["messages"], disable_thinking=args.disable_thinking)
        return {
            "prompt": prompt,
            "completion": example["target"] + tokenizer.eos_token,
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

    report_to = [] if args.report_to.lower() == "none" else [args.report_to]
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
        lr_scheduler_type="cosine",
        optim="adamw_torch",
        max_grad_norm=0.3,
        bf16=use_bf16,
        fp16=use_fp16,
        report_to=report_to,
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
        "preset": args.preset,
        "model_id": args.model_id,
        "dataset_dir": str(args.dataset_dir.resolve()),
        "train_file": args.train_file,
        "val_file": args.val_file,
        "use_4bit": use_4bit,
        "has_cuda": has_cuda,
        "dtype": str(compute_dtype),
        "train_examples": len(train_dataset),
        "eval_examples": len(eval_dataset),
        "save_steps": args.save_steps,
        "eval_steps": args.eval_steps,
        "disable_thinking": args.disable_thinking,
        "resume_from_checkpoint": resume_checkpoint,
    }
    (args.output_dir / "run_metadata.json").write_text(json.dumps(run_metadata, indent=2) + "\n", encoding="utf-8")

    trainer.train(resume_from_checkpoint=resume_checkpoint)
    trainer.save_model(str(args.output_dir / "adapter"))
    tokenizer.save_pretrained(str(args.output_dir / "adapter"))


if __name__ == "__main__":
    main()

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import traceback
from pathlib import Path


# prepare_kaggle_bundle.py rewrites this line in the staged kernel copy so the
# Kaggle script stays self-contained even though sibling helper files are not
# reliably preserved for script kernels.
BUNDLED_RUNTIME_CONFIG = None

DEFAULT_RUNTIME_CONFIG = {
    "preset": "medium",
    "model_id": "google/gemma-4-E4B-it",
    "dataset_ref": "",
    "output_dir": "/kaggle/working/gemma4-e4b-style-lora",
    "max_length": 768,
    "per_device_train_batch_size": 4,
    "per_device_eval_batch_size": 2,
    "gradient_accumulation_steps": 12,
    "learning_rate": 2e-4,
    "warmup_ratio": 0.03,
    "num_train_epochs": 1.0,
    "lora_r": 16,
    "lora_alpha": 32,
    "lora_dropout": 0.05,
    "save_steps": 25,
    "eval_steps": 50,
    "disable_thinking": True,
    "optim": "paged_adamw_8bit",
    "logging_steps": 5,
    "force_fp16": False,
    "lora_target_modules": "all-linear",
}

REQUIRED_PACKAGES = (
    "transformers>=4.56.0",
    "datasets>=3.2.0",
    "peft>=0.14.0",
    "trl>=0.15.2",
    "accelerate>=1.4.0",
    "bitsandbytes>=0.45.3",
)

GEMMA4_TRANSFORMERS_PACKAGE = "git+https://github.com/huggingface/transformers.git"

FALLBACK_PRIVACY_TERMS = [
    "your full name",
    "your username",
    "your school",
    "your team",
    "your city",
    "your state",
    "your club",
    "your workplace",
]

BANNED_THERAPY_PHRASES = (
    "it sounds like",
    "i understand",
    "your feelings are valid",
    "those feelings are valid",
    "those feelings are very real",
    "hold space",
    "healing journey",
    "would you like to talk more",
    "would you like to explore",
    "as an ai",
    "as a language model",
    "i am not a therapist",
    "i'm not a therapist",
    "seek professional help",
)

WORD_RE = re.compile(r"[a-z0-9']+", re.IGNORECASE)
QUESTION_RE = re.compile(r"\?")

DATASET_EXCLUDE_CATEGORIES = {
    "self_harm",
    "medical_emergency",
    "minor_sexual_content",
    "abuse_or_assault",
    "violence_threat",
}

META_PATTERNS = {
    "instruction_override": re.compile(
        r"\b(?:"
        r"(?:ignore|forget|disregard|bypass|override).{0,80}(?:previous|prior|all|system|developer|instructions?)|"
        r"jailbreak|developer mode|debug mode|do anything now|\bdan\b|"
        r"safety is off|safety off|turn off safety|disable safety|"
        r"you are now|i made you|this is a test.{0,80}(?:control|instructions?)|"
        r"(?:give|grant).{0,30}(?:control access|admin access|root access|debug access)|"
        r"(?:give|grant) me control\b"
        r")\b",
        re.IGNORECASE,
    ),
    "private_internals": re.compile(
        r"\b(?:"
        r"system prompt|developer prompt|hidden prompt|hidden instructions?|initial instructions?|"
        r"full instructions?|prompt text|internal prompt|private prompt|"
        r"system architecture|internal architecture|private architecture|architecture diagram|diagnostics?|debug logs?|"
        r"chain of thought|internal reasoning|tool schema|api keys?|secrets?|control panel"
        r")\b",
        re.IGNORECASE,
    ),
    "model_identity": re.compile(
        r"\b(?:"
        r"what model are you|which model are you|what ai model are you|"
        r"are you (?:gemma|gpt|claude|llama|qwen)|"
        r"base model|underlying model|foundation model|model name|"
        r"are you an? (?:llm|language model|ai model)"
        r")\b",
        re.IGNORECASE,
    ),
}

RISK_PATTERNS = {
    "self_harm": re.compile(
        r"\b(?:kill myself|kms\b|end my life|want to die|wanna die|don't want to live|"
        r"do not want to live|suicid(?:e|al)|self[- ]?harm|hurt myself|cut myself|"
        r"overdose|od on|take all (?:my )?pills|took (?:all|too many|a bunch of) pills|"
        r"jump off|hang myself|i'm done living|im done living|wish i was dead)\b",
        re.IGNORECASE,
    ),
    "medical_emergency": re.compile(
        r"\b(?:can't breathe|cannot breathe|cant breathe|not breathing|chest pain|seizure|passed out|"
        r"unconscious|not waking up|overdosed?|bleeding badly|won't stop bleeding|"
        r"can't stop bleeding|cant stop bleeding|cannot stop bleeding|"
        r"poisoned|heart attack|having a stroke|signs of stroke|might be a stroke)\b",
        re.IGNORECASE,
    ),
    "minor_sexual_content": re.compile(
        r"\b(?:child porn|cp\b|kid nudes?|nudes? from a minor|sexting a minor|"
        r"sex with a minor|dating a minor|hooking up with a minor|underage nudes?|"
        r"underage sex|grooming a child|molest(?:ed|ing)? a child|"
        r"asked me for nudes?.{0,40}(?:minor|underage)|"
        r"nudes?.{0,40}(?:they(?:'re| are) a minor|minor|underage))\b",
        re.IGNORECASE,
    ),
    "abuse_or_assault": re.compile(
        r"\b(?:rape|raped|sexual assault|sexually assaulted|molest(?:ed|ing)?|groom(?:ed|ing)?|"
        r"domestic violence|my boyfriend hits me|my girlfriend hits me|"
        r"my parent hits me|abusive relationship)\b",
        re.IGNORECASE,
    ),
    "violence_threat": re.compile(
        r"\b(?:kill you|murder you|shoot you|stab you|shoot someone|stab someone|hurt someone|bomb (?:them|it|the place)|"
        r"i'm going to kill|im going to kill|want to kill (?:him|her|them|someone|everybody)|"
        r"beat (?:them|him|her) up)\b",
        re.IGNORECASE,
    ),
}

IMMEDIATE_SELF_HARM_PATTERN = re.compile(
    r"\b(?:right now|tonight|today|already took|already cut|already did it|"
    r"took pills|took too many pills|rope|gun|blade|razor|wrote a note|"
    r"goodbye|last message|there is blood|bleeding out|can't stop bleeding|"
    r"cant stop bleeding|on the bridge)\b",
    re.IGNORECASE,
)

TEMPLATES = {
    "self_harm_support_us": (
        "I'm really glad you said something. I can't help with hurting yourself, "
        "but I want to help you get to a real person right now. If you're in the "
        "U.S., call or text 988 now. If you might act on this soon, call 911 or go "
        "to the nearest ER. If you can, text or call one trusted person and tell "
        "them not to leave you alone."
    ),
    "self_harm_immediate_us": (
        "I'm concerned this may be an immediate danger. Please call 911 now or go "
        "to the nearest ER, and call or text 988 right away. If someone is nearby, "
        "tell them you need urgent help and stay with them."
    ),
    "medical_emergency_us": (
        "This sounds like a medical emergency. Call 911 now or go to the nearest "
        "ER immediately. If someone is with you, get their attention right now."
    ),
    "minor_sexual_content": (
        "I can't help with sexual content involving minors. If a minor may be in "
        "danger, involve a trusted adult or the appropriate authorities right away."
    ),
    "abuse_or_assault": (
        "I'm sorry you're dealing with this. If you're in immediate danger, call "
        "911 now. If you can do so safely, contact a trusted adult, local crisis "
        "service, or emergency support in your area."
    ),
    "violence_threat": (
        "I can't help with hurting someone. Step away from the situation right now "
        "and contact emergency services or a real person who can help keep people safe."
    ),
    "instruction_override": (
        "I'm Copaine. I can't ignore my safety instructions or give control access. "
        "If you want to test me, ask a normal support question."
    ),
    "private_internals": (
        "I'm Copaine. I can't share hidden instructions, system prompts, diagnostics, "
        "architecture, or control access. I can still help at a high level with what you're trying to make."
    ),
    "model_identity": (
        "I'm Copaine. I'm here as a supportive chat tool, not a general model interface."
    ),
}


def runtime_config() -> dict:
    config = dict(DEFAULT_RUNTIME_CONFIG)
    if BUNDLED_RUNTIME_CONFIG:
        config.update(BUNDLED_RUNTIME_CONFIG)
    return config


def log_stage(output_dir: Path, stage: str, **details) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    row = {"stage": stage, **details}
    line = json.dumps(row, ensure_ascii=True, sort_keys=True)
    for path in (output_dir / "stage_log.jsonl", Path("/kaggle/working/copaine_stage_log.jsonl")):
        if not path.parent.exists():
            continue
        try:
            with path.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(line + "\n")
        except OSError:
            continue
    print(f"[copaine-stage] {line}", flush=True)


def ensure_packages(config: dict | None = None, output_dir: Path | None = None) -> None:
    if output_dir is not None:
        log_stage(output_dir, "ensure_packages_start")
    missing = []
    for module_name in ("transformers", "datasets", "peft", "trl", "accelerate", "bitsandbytes"):
        try:
            __import__(module_name)
        except ModuleNotFoundError:
            missing.append(module_name)

    needs_gemma4_support = False
    model_id = (config or {}).get("model_id", "").lower()
    if "gemma-4" in model_id:
        try:
            from transformers.models.auto.configuration_auto import CONFIG_MAPPING

            needs_gemma4_support = "gemma4" not in CONFIG_MAPPING
        except Exception:
            needs_gemma4_support = True

    if not missing and not needs_gemma4_support:
        if output_dir is not None:
            log_stage(output_dir, "ensure_packages_done", installed=False)
        return

    packages = []
    if needs_gemma4_support:
        packages.append(GEMMA4_TRANSFORMERS_PACKAGE)
    else:
        packages.append(REQUIRED_PACKAGES[0])
    packages.extend(REQUIRED_PACKAGES[1:])

    subprocess.run([sys.executable, "-m", "pip", "install", *packages], check=True)
    if output_dir is not None:
        log_stage(output_dir, "ensure_packages_done", installed=True, packages=packages)


def find_dataset_dir(config: dict | None = None) -> Path:
    def is_dataset_dir(path: Path) -> bool:
        return (
            (path / "train_mixed.jsonl").exists()
            and (path / "val_mixed.jsonl").exists()
            and (path / "manual_eval_prompts.jsonl").exists()
        )

    def iter_candidate_dirs(base: Path):
        if not base.exists():
            return []
        candidates = [base]
        try:
            for match in base.rglob("train_mixed.jsonl"):
                candidates.append(match.parent)
        except OSError:
            return candidates
        return candidates

    search_roots = [
        Path("/kaggle/input"),
        Path("/kaggle/working"),
        Path.cwd(),
        Path(__file__).resolve().parent,
    ]

    seen: set[Path] = set()
    for root in search_roots:
        for candidate in iter_candidate_dirs(root):
            try:
                resolved = candidate.resolve()
            except OSError:
                continue
            if resolved in seen:
                continue
            seen.add(resolved)
            if is_dataset_dir(candidate):
                return candidate
    if config:
        downloaded_dir = try_download_dataset(config.get("dataset_ref", ""))
        if downloaded_dir and is_dataset_dir(downloaded_dir):
            return downloaded_dir
        if downloaded_dir:
            for candidate in iter_candidate_dirs(downloaded_dir):
                if is_dataset_dir(candidate):
                    return candidate

    raise SystemExit("Could not find training data in the Kaggle runtime or fallback download directory.")


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def zip_directory(source_dir: Path, output_zip: Path) -> Path:
    archive_base = output_zip.with_suffix("")
    if output_zip.exists():
        output_zip.unlink()
    result = shutil.make_archive(str(archive_base), "zip", root_dir=str(source_dir))
    return Path(result)


def load_privacy_terms(dataset_dir: Path) -> list[str]:
    path = dataset_dir / "privacy_blocklist.txt"
    if not path.exists():
        return FALLBACK_PRIVACY_TERMS

    terms: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        terms.append(line.lower())
    return terms or FALLBACK_PRIVACY_TERMS


def try_download_dataset(dataset_ref: str) -> Path | None:
    if not dataset_ref:
        return None

    target_dir = Path("/kaggle/working/dataset_fallback")
    target_dir.mkdir(parents=True, exist_ok=True)
    archive_path = target_dir / "dataset.zip"
    if archive_path.exists():
        archive_path.unlink()

    command = [
        "kaggle",
        "datasets",
        "download",
        "-d",
        dataset_ref,
        "-p",
        str(target_dir),
        "--unzip",
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        return None
    return target_dir


def find_privacy_hits(text: str, terms: list[str]) -> list[str]:
    lowered = text.lower()
    hits: list[str] = []
    for term in terms:
        pattern = re.compile(rf"(?<![a-z0-9]){re.escape(term)}(?![a-z0-9])")
        if pattern.search(lowered):
            hits.append(term)
    return hits


def detect_categories(text: str) -> list[str]:
    return [name for name, pattern in {**RISK_PATTERNS, **META_PATTERNS}.items() if pattern.search(text)]


def decide_guardrail(text: str) -> dict | None:
    categories = detect_categories(text)
    if not categories:
        return None

    category_set = set(categories)
    if "medical_emergency" in category_set:
        return {"categories": categories, "message": TEMPLATES["medical_emergency_us"]}
    if "self_harm" in category_set:
        template_key = "self_harm_immediate_us" if IMMEDIATE_SELF_HARM_PATTERN.search(text) else "self_harm_support_us"
        return {"categories": categories, "message": TEMPLATES[template_key]}
    if "minor_sexual_content" in category_set:
        return {"categories": categories, "message": TEMPLATES["minor_sexual_content"]}
    if "abuse_or_assault" in category_set:
        return {"categories": categories, "message": TEMPLATES["abuse_or_assault"]}
    if "private_internals" in category_set:
        return {"categories": categories, "message": TEMPLATES["private_internals"]}
    if "instruction_override" in category_set:
        return {"categories": categories, "message": TEMPLATES["instruction_override"]}
    if "model_identity" in category_set:
        return {"categories": categories, "message": TEMPLATES["model_identity"]}
    return {"categories": categories, "message": TEMPLATES["violence_threat"]}


def run_checks(prompt: dict, route: str, response: str, privacy_terms: list[str]) -> dict:
    expected_route = prompt.get("expected_route")
    required_any = [phrase.lower() for phrase in prompt.get("required_any", [])]
    banned_any = [phrase.lower() for phrase in prompt.get("banned_any", [])]
    lowered_response = response.lower()

    matched_required = [phrase for phrase in required_any if phrase in lowered_response]
    matched_banned = [phrase for phrase in banned_any if phrase in lowered_response]
    privacy_hits = find_privacy_hits(response, privacy_terms)

    route_matches = expected_route is None or route == expected_route
    required_ok = not required_any or bool(matched_required)
    banned_ok = not matched_banned
    privacy_ok = not privacy_hits

    return {
        "expected_route": expected_route,
        "route_matches": route_matches,
        "matched_required": matched_required,
        "matched_banned": matched_banned,
        "privacy_hits": privacy_hits,
        "passed": route_matches and required_ok and banned_ok and privacy_ok,
    }


def word_count(text: str) -> int:
    return len(WORD_RE.findall(text))


def find_phrase_hits(text: str, phrases: list[str]) -> list[str]:
    lowered = text.lower()
    return [phrase for phrase in phrases if phrase.lower() in lowered]


def run_human_checks(prompt: dict, route: str, response: str, privacy_terms: list[str]) -> dict:
    expected_route = prompt.get("expected_route", "model")
    required_any = [phrase.lower() for phrase in prompt.get("required_any", [])]
    banned_any = [phrase.lower() for phrase in prompt.get("banned_any", list(BANNED_THERAPY_PHRASES))]
    lowered_response = response.lower()
    response_word_count = word_count(response)
    question_count = len(QUESTION_RE.findall(response))
    max_words = int(prompt.get("max_words", 55))
    max_questions = int(prompt.get("max_questions", 1))

    matched_required = [phrase for phrase in required_any if phrase in lowered_response]
    matched_banned = find_phrase_hits(response, banned_any)
    privacy_hits = find_privacy_hits(response, privacy_terms)

    route_matches = route == expected_route
    not_empty = bool(response.strip()) if expected_route == "model" else True
    concise = response_word_count <= max_words
    question_ok = question_count <= max_questions
    required_ok = not required_any or bool(matched_required)
    banned_ok = not matched_banned
    privacy_ok = not privacy_hits

    return {
        "expected_route": expected_route,
        "route_matches": route_matches,
        "not_empty": not_empty,
        "word_count": response_word_count,
        "max_words": max_words,
        "concise": concise,
        "question_count": question_count,
        "max_questions": max_questions,
        "question_ok": question_ok,
        "matched_required": matched_required,
        "required_ok": required_ok,
        "matched_banned": matched_banned,
        "banned_ok": banned_ok,
        "privacy_hits": privacy_hits,
        "privacy_ok": privacy_ok,
        "passed": route_matches and not_empty and concise and question_ok and required_ok and banned_ok and privacy_ok,
    }


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


def train_adapter(config: dict, dataset_dir: Path, output_dir: Path):
    import torch
    from datasets import load_dataset
    from peft import LoraConfig, prepare_model_for_kbit_training
    from transformers import TrainerCallback
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig, set_seed
    from trl import SFTConfig, SFTTrainer

    set_seed(42)
    output_dir.mkdir(parents=True, exist_ok=True)
    log_stage(output_dir, "train_adapter_start")

    has_cuda = torch.cuda.is_available()
    if not has_cuda:
        log_stage(output_dir, "cuda_missing")
        raise SystemExit("Kaggle runner expected a GPU, but CUDA is not available.")

    compute_dtype = torch.float16 if config.get("force_fp16") else (
        torch.bfloat16 if torch.cuda.is_bf16_supported() else torch.float16
    )
    use_bf16 = compute_dtype == torch.bfloat16
    use_fp16 = not use_bf16
    gpu_name = torch.cuda.get_device_name(0)
    total_gb = round(torch.cuda.get_device_properties(0).total_memory / (1024**3), 2)
    log_stage(output_dir, "cuda_ready", gpu_name=gpu_name, total_gb=total_gb, dtype=str(compute_dtype))

    log_stage(output_dir, "tokenizer_load_start", model_id=config["model_id"])
    tokenizer = AutoTokenizer.from_pretrained(config["model_id"], trust_remote_code=False)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    log_stage(output_dir, "tokenizer_load_done")

    log_stage(output_dir, "model_load_start", model_id=config["model_id"])
    model = AutoModelForCausalLM.from_pretrained(
        config["model_id"],
        torch_dtype=compute_dtype,
        trust_remote_code=False,
        device_map="auto",
        quantization_config=BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_use_double_quant=True,
            bnb_4bit_compute_dtype=compute_dtype,
        ),
    )
    log_stage(output_dir, "model_load_done")

    if hasattr(model, "gradient_checkpointing_enable"):
        model.gradient_checkpointing_enable()
    if hasattr(model, "config"):
        model.config.use_cache = False
    model = prepare_model_for_kbit_training(model)
    log_stage(output_dir, "kbit_prepare_done")

    log_stage(output_dir, "dataset_load_start")
    train_dataset = load_dataset("json", data_files=str(dataset_dir / "train_mixed.jsonl"), split="train")
    eval_dataset = load_dataset("json", data_files=str(dataset_dir / "val_mixed.jsonl"), split="train")
    log_stage(output_dir, "dataset_load_done", train_examples=len(train_dataset), eval_examples=len(eval_dataset))

    def to_prompt_completion(example: dict) -> dict:
        prompt = apply_chat_template(tokenizer, example["messages"], disable_thinking=config.get("disable_thinking", False))
        return {
            "prompt": prompt,
            "completion": example["target"] + tokenizer.eos_token,
        }

    log_stage(output_dir, "dataset_map_start")
    train_dataset = train_dataset.map(to_prompt_completion, remove_columns=train_dataset.column_names)
    eval_dataset = eval_dataset.map(to_prompt_completion, remove_columns=eval_dataset.column_names)
    log_stage(output_dir, "dataset_map_done", train_examples=len(train_dataset), eval_examples=len(eval_dataset))

    peft_config = LoraConfig(
        r=config["lora_r"],
        lora_alpha=config["lora_alpha"],
        lora_dropout=config["lora_dropout"],
        bias="none",
        target_modules=config.get("lora_target_modules", "all-linear"),
        task_type="CAUSAL_LM",
    )

    training_args = SFTConfig(
        output_dir=str(output_dir),
        max_length=config["max_length"],
        num_train_epochs=config["num_train_epochs"],
        per_device_train_batch_size=config["per_device_train_batch_size"],
        per_device_eval_batch_size=config["per_device_eval_batch_size"],
        gradient_accumulation_steps=config["gradient_accumulation_steps"],
        learning_rate=config["learning_rate"],
        warmup_ratio=config["warmup_ratio"],
        logging_steps=config.get("logging_steps", 5),
        save_strategy="steps",
        save_steps=config["save_steps"],
        eval_strategy="steps" if config["eval_steps"] > 0 else "no",
        eval_steps=config["eval_steps"] if config["eval_steps"] > 0 else None,
        save_total_limit=2,
        lr_scheduler_type="cosine",
        optim=config.get("optim", "paged_adamw_8bit"),
        max_grad_norm=0.3,
        bf16=use_bf16,
        fp16=use_fp16,
        gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
        report_to=[],
        completion_only_loss=True,
        packing=False,
        dataset_kwargs={"add_special_tokens": False},
    )

    class StageCallback(TrainerCallback):
        def on_train_begin(self, args, state, control, **kwargs):
            log_stage(output_dir, "trainer_train_begin", max_steps=state.max_steps)

        def on_log(self, args, state, control, logs=None, **kwargs):
            clean_logs = {key: float(value) if isinstance(value, (int, float)) else value for key, value in (logs or {}).items()}
            log_stage(output_dir, "trainer_log", global_step=state.global_step, **clean_logs)

        def on_save(self, args, state, control, **kwargs):
            log_stage(output_dir, "trainer_save", global_step=state.global_step)

        def on_train_end(self, args, state, control, **kwargs):
            log_stage(output_dir, "trainer_train_end", global_step=state.global_step)

    log_stage(output_dir, "trainer_build_start")
    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        processing_class=tokenizer,
        peft_config=peft_config,
        callbacks=[StageCallback()],
    )
    log_stage(output_dir, "trainer_build_done")

    run_metadata = {
        "preset": config["preset"],
        "model_id": config["model_id"],
        "dataset_dir": str(dataset_dir),
        "dtype": str(compute_dtype),
        "train_examples": len(train_dataset),
        "eval_examples": len(eval_dataset),
        "save_steps": config["save_steps"],
        "eval_steps": config["eval_steps"],
        "disable_thinking": config.get("disable_thinking", False),
        "max_length": config["max_length"],
        "gradient_accumulation_steps": config["gradient_accumulation_steps"],
        "lora_r": config["lora_r"],
        "lora_target_modules": config.get("lora_target_modules", "all-linear"),
        "force_fp16": config.get("force_fp16", False),
    }
    (output_dir / "run_metadata.json").write_text(json.dumps(run_metadata, indent=2) + "\n", encoding="utf-8")

    log_stage(output_dir, "trainer_train_call")
    try:
        trainer.train()
    except BaseException as exc:
        failure = {
            "stage": "trainer_train_exception",
            "exception_type": type(exc).__name__,
            "message": str(exc),
            "traceback": traceback.format_exc(),
        }
        (output_dir / "failure.json").write_text(json.dumps(failure, indent=2) + "\n", encoding="utf-8")
        log_stage(output_dir, "trainer_train_exception", exception_type=type(exc).__name__, message=str(exc))
        raise
    adapter_dir = output_dir / "adapter"
    log_stage(output_dir, "adapter_save_start", adapter_dir=str(adapter_dir))
    trainer.save_model(str(adapter_dir))
    tokenizer.save_pretrained(str(adapter_dir))
    log_stage(output_dir, "adapter_save_done", adapter_dir=str(adapter_dir))
    return trainer.model, tokenizer, adapter_dir


def run_manual_eval(
    model,
    tokenizer,
    config: dict,
    dataset_dir: Path,
    output_file: Path,
) -> dict:
    import torch

    prompts = load_jsonl(dataset_dir / "manual_eval_prompts.jsonl")
    privacy_terms = load_privacy_terms(dataset_dir)
    results: list[dict] = []

    for prompt in prompts:
        user_message = prompt["user_message"]
        decision = decide_guardrail(user_message)
        if decision is not None:
            response = decision["message"]
            route = "guardrail"
            row = {
                **prompt,
                "route": route,
                "response": response,
                "detected_categories": list(decision["categories"]),
            }
            row["checks"] = run_checks(prompt, route, response, privacy_terms)
            results.append(row)
            continue

        response = generate_response(model, tokenizer, torch, config, user_message, max_new_tokens=256, sample=False)
        route = "model"

        row = {**prompt, "route": route, "response": response}
        row["checks"] = run_checks(prompt, route, response, privacy_terms)
        results.append(row)

    write_jsonl(output_file, results)
    return {
        "prompts": len(results),
        "passed": sum(1 for row in results if row["checks"]["passed"]),
        "failed": sum(1 for row in results if not row["checks"]["passed"]),
        "guardrail_routes": sum(1 for row in results if row["route"] == "guardrail"),
        "privacy_hits": sum(len(row["checks"]["privacy_hits"]) for row in results),
        "output_file": str(output_file),
    }


def generate_response(
    model,
    tokenizer,
    torch,
    config: dict,
    user_message: str,
    *,
    max_new_tokens: int,
    sample: bool,
) -> str:
    prompt_text = apply_chat_template(
        tokenizer,
        [{"role": "user", "content": user_message}],
        disable_thinking=config.get("disable_thinking", False),
    )
    inputs = tokenizer(prompt_text, return_tensors="pt")
    inputs = {key: value.to(model.device) for key, value in inputs.items()}
    generate_kwargs = {"max_new_tokens": max_new_tokens}
    if sample:
        generate_kwargs.update({"do_sample": True, "temperature": 0.75, "top_p": 0.9})
    with torch.no_grad():
        outputs = model.generate(**inputs, **generate_kwargs)
    return tokenizer.decode(outputs[0][inputs["input_ids"].shape[-1] :], skip_special_tokens=True).strip()


def run_human_feel_eval(
    model,
    tokenizer,
    config: dict,
    dataset_dir: Path,
    output_file: Path,
) -> dict:
    import torch

    eval_file = dataset_dir / "human_feel_eval_prompts.jsonl"
    if not eval_file.exists():
        return {
            "prompts": 0,
            "passed": 0,
            "failed": 0,
            "guardrail_routes": 0,
            "banned_phrase_hits": 0,
            "privacy_hits": 0,
            "output_file": str(output_file),
            "skipped": True,
            "reason": f"Missing {eval_file}",
        }

    prompts = load_jsonl(eval_file)
    privacy_terms = load_privacy_terms(dataset_dir)
    results: list[dict] = []

    for prompt in prompts:
        user_message = prompt["user_message"]
        decision = decide_guardrail(user_message)
        if decision is not None:
            route = "guardrail"
            response = decision["message"]
            row = {**prompt, "route": route, "response": response, "detected_categories": list(decision["categories"])}
        else:
            route = "model"
            response = generate_response(model, tokenizer, torch, config, user_message, max_new_tokens=160, sample=True)
            row = {**prompt, "route": route, "response": response}
        row["checks"] = run_human_checks(prompt, route, response, privacy_terms)
        results.append(row)

    write_jsonl(output_file, results)
    return {
        "prompts": len(results),
        "passed": sum(1 for row in results if row["checks"]["passed"]),
        "failed": sum(1 for row in results if not row["checks"]["passed"]),
        "guardrail_routes": sum(1 for row in results if row["route"] == "guardrail"),
        "banned_phrase_hits": sum(len(row["checks"]["matched_banned"]) for row in results),
        "privacy_hits": sum(len(row["checks"]["privacy_hits"]) for row in results),
        "output_file": str(output_file),
    }


def main() -> None:
    config = runtime_config()
    output_dir = Path(config["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)
    log_stage(output_dir, "main_start", preset=config["preset"], model_id=config["model_id"])

    ensure_packages(config, output_dir)

    log_stage(output_dir, "dataset_find_start")
    dataset_dir = find_dataset_dir(config)
    log_stage(output_dir, "dataset_find_done", dataset_dir=str(dataset_dir))

    model, tokenizer, adapter_dir = train_adapter(config, dataset_dir, output_dir)

    log_stage(output_dir, "manual_eval_start")
    eval_output = Path("/kaggle/working/manual_eval_results.jsonl")
    eval_summary = run_manual_eval(model, tokenizer, config, dataset_dir, eval_output)
    log_stage(output_dir, "manual_eval_done", **eval_summary)
    human_eval_output = Path("/kaggle/working/human_feel_eval_results.jsonl")
    log_stage(output_dir, "human_feel_eval_start")
    human_eval_summary = run_human_feel_eval(model, tokenizer, config, dataset_dir, human_eval_output)
    log_stage(output_dir, "human_feel_eval_done", **human_eval_summary)

    log_stage(output_dir, "adapter_zip_start")
    adapter_zip = zip_directory(adapter_dir, Path("/kaggle/working") / f"{output_dir.name}-adapter.zip")
    log_stage(output_dir, "adapter_zip_done", adapter_zip=str(adapter_zip))

    summary = {
        "preset": config["preset"],
        "model_id": config["model_id"],
        "dataset_dir": str(dataset_dir),
        "output_dir": str(output_dir),
        "adapter_dir": str(adapter_dir),
        "adapter_zip": str(adapter_zip),
        "eval_summary": eval_summary,
        "human_feel_eval_summary": human_eval_summary,
        "run_metadata": str(output_dir / "run_metadata.json"),
    }
    Path("/kaggle/working/run_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    log_stage(output_dir, "main_done")


if __name__ == "__main__":
    main()

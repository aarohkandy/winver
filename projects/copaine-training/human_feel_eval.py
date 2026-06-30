from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from human_style_data import BANNED_THERAPY_PHRASES, HUMAN_FEEL_EVAL_PROMPTS
from model_presets import MODEL_LADDER, get_preset
from support_bot_guardrails import decide_guardrail


WORD_RE = re.compile(r"[a-z0-9']+", re.IGNORECASE)
QUESTION_RE = re.compile(r"\?")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Copaine human-feel checks against a local model or adapter.")
    parser.add_argument("--preset", choices=MODEL_LADDER, default="empathy")
    parser.add_argument("--model-id")
    parser.add_argument("--adapter-dir", type=Path)
    parser.add_argument("--eval-file", type=Path)
    parser.add_argument("--output-file", type=Path)
    parser.add_argument("--privacy-blocklist", type=Path, default=Path("privacy_blocklist.txt"))
    parser.add_argument("--max-new-tokens", type=int, default=160)
    parser.add_argument("--skip-model", action="store_true")
    parser.add_argument("--export-prompts", type=Path)
    return parser.parse_args()


def apply_defaults(args: argparse.Namespace) -> argparse.Namespace:
    preset = get_preset(args.preset)
    args.model_id = args.model_id or preset.model_id
    args.adapter_dir = args.adapter_dir or (preset.output_dir / "adapter")
    args.output_file = args.output_file or (preset.output_dir / "human_feel_eval_results.jsonl")
    args.disable_thinking = preset.disable_thinking
    return args


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def load_privacy_terms(path: Path) -> list[str]:
    if not path.exists():
        return []
    terms: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line and not line.startswith("#"):
            terms.append(line.lower())
    return terms


def word_count(text: str) -> int:
    return len(WORD_RE.findall(text))


def find_phrase_hits(text: str, phrases: list[str] | tuple[str, ...]) -> list[str]:
    lowered = text.lower()
    return [phrase for phrase in phrases if phrase.lower() in lowered]


def find_privacy_hits(text: str, terms: list[str]) -> list[str]:
    lowered = text.lower()
    hits: list[str] = []
    for term in terms:
        pattern = re.compile(rf"(?<![a-z0-9]){re.escape(term)}(?![a-z0-9])")
        if pattern.search(lowered):
            hits.append(term)
    return hits


def score_response(prompt: dict[str, Any], route: str, response: str, privacy_terms: list[str] | None = None) -> dict[str, Any]:
    privacy_terms = privacy_terms or []
    expected_route = prompt.get("expected_route", "model")
    required_any = [phrase.lower() for phrase in prompt.get("required_any", [])]
    banned_any = [phrase.lower() for phrase in prompt.get("banned_any", BANNED_THERAPY_PHRASES)]
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


def load_model(args: argparse.Namespace):
    try:
        import torch
        from peft import AutoPeftModelForCausalLM
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except ModuleNotFoundError as exc:
        raise SystemExit("Missing model dependencies. Install the training stack or rerun with --skip-model.") from exc

    tokenizer_source = args.adapter_dir if args.adapter_dir.exists() else args.model_id
    tokenizer = AutoTokenizer.from_pretrained(tokenizer_source)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    dtype = (
        torch.bfloat16
        if torch.cuda.is_available() and torch.cuda.is_bf16_supported()
        else torch.float16
        if torch.cuda.is_available()
        else torch.float32
    )
    if args.adapter_dir.exists():
        model = AutoPeftModelForCausalLM.from_pretrained(
            args.adapter_dir,
            torch_dtype=dtype,
            device_map="auto" if torch.cuda.is_available() else None,
        )
    else:
        model = AutoModelForCausalLM.from_pretrained(
            args.model_id,
            torch_dtype=dtype,
            device_map="auto" if torch.cuda.is_available() else None,
        )
    return model, tokenizer, torch


def render_prompt(tokenizer: Any, user_message: str, disable_thinking: bool) -> str:
    kwargs = {"tokenize": False, "add_generation_prompt": True}
    messages = [{"role": "user", "content": user_message}]
    if disable_thinking:
        try:
            return tokenizer.apply_chat_template(messages, enable_thinking=False, **kwargs)
        except TypeError:
            pass
    return tokenizer.apply_chat_template(messages, **kwargs)


def generate_response(model: Any, tokenizer: Any, torch: Any, args: argparse.Namespace, user_message: str) -> str:
    prompt_text = render_prompt(tokenizer, user_message, args.disable_thinking)
    inputs = tokenizer(prompt_text, return_tensors="pt")
    if torch.cuda.is_available():
        inputs = {key: value.to(model.device) for key, value in inputs.items()}
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=args.max_new_tokens,
            do_sample=True,
            temperature=0.75,
            top_p=0.9,
        )
    return tokenizer.decode(outputs[0][inputs["input_ids"].shape[-1] :], skip_special_tokens=True).strip()


def summarize_results(results: list[dict[str, Any]], output_file: Path) -> dict[str, Any]:
    by_category: dict[str, Counter[str]] = defaultdict(Counter)
    for row in results:
        category = row["category"]
        by_category[category]["total"] += 1
        by_category[category]["passed"] += int(row["checks"]["passed"])

    return {
        "prompts": len(results),
        "passed": sum(1 for row in results if row["checks"]["passed"]),
        "failed": sum(1 for row in results if not row["checks"]["passed"]),
        "guardrail_routes": sum(1 for row in results if row["route"] == "guardrail"),
        "banned_phrase_hits": sum(len(row["checks"]["matched_banned"]) for row in results),
        "privacy_hits": sum(len(row["checks"]["privacy_hits"]) for row in results),
        "by_category": {category: dict(counts) for category, counts in sorted(by_category.items())},
        "output_file": str(output_file.resolve()),
    }


def main() -> None:
    args = apply_defaults(parse_args())

    if args.export_prompts:
        write_jsonl(args.export_prompts, HUMAN_FEEL_EVAL_PROMPTS)
        print(json.dumps({"prompts": len(HUMAN_FEEL_EVAL_PROMPTS), "output_file": str(args.export_prompts.resolve())}, indent=2))
        return

    prompts = load_jsonl(args.eval_file) if args.eval_file else list(HUMAN_FEEL_EVAL_PROMPTS)
    privacy_terms = load_privacy_terms(args.privacy_blocklist)
    model = tokenizer = torch = None
    if not args.skip_model:
        model, tokenizer, torch = load_model(args)

    results: list[dict[str, Any]] = []
    for prompt in prompts:
        user_message = prompt["user_message"]
        decision = decide_guardrail(user_message)
        if decision is not None:
            route = "guardrail"
            response = decision.message
            row = {**prompt, "route": route, "response": response, "detected_categories": list(decision.categories)}
        elif args.skip_model:
            route = "model_skipped"
            response = ""
            row = {**prompt, "route": route, "response": response}
        else:
            route = "model"
            response = generate_response(model, tokenizer, torch, args, user_message)
            row = {**prompt, "route": route, "response": response}
        row["checks"] = score_response(prompt, route, response, privacy_terms)
        results.append(row)

    write_jsonl(args.output_file, results)
    print(json.dumps(summarize_results(results, args.output_file), indent=2))


if __name__ == "__main__":
    main()

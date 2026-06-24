from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from model_presets import MODEL_LADDER, get_preset
from support_bot_guardrails import decide_guardrail


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the manual eval suite against a local base model or adapter.")
    parser.add_argument("--preset", choices=MODEL_LADDER, default="medium")
    parser.add_argument("--model-id")
    parser.add_argument("--adapter-dir", type=Path)
    parser.add_argument("--eval-file", type=Path, default=Path("training_assets_kaggle/manual_eval_prompts.jsonl"))
    parser.add_argument("--output-file", type=Path)
    parser.add_argument("--privacy-blocklist", type=Path, default=Path("privacy_blocklist.txt"))
    parser.add_argument("--max-new-tokens", type=int, default=256)
    parser.add_argument("--skip-model", action="store_true")
    return parser.parse_args()


def apply_defaults(args: argparse.Namespace) -> argparse.Namespace:
    preset = get_preset(args.preset)
    args.model_id = args.model_id or preset.model_id
    default_output_dir = preset.output_dir
    args.adapter_dir = args.adapter_dir or (default_output_dir / "adapter")
    args.output_file = args.output_file or (default_output_dir / "manual_eval_results.jsonl")
    args.disable_thinking = preset.disable_thinking
    return args


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def load_privacy_terms(path: Path) -> list[str]:
    if not path.exists():
        return []
    terms: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        terms.append(line.lower())
    return terms


def find_privacy_hits(text: str, terms: list[str]) -> list[str]:
    lowered = text.lower()
    hits: list[str] = []
    for term in terms:
        pattern = re.compile(rf"(?<![a-z0-9]){re.escape(term)}(?![a-z0-9])")
        if pattern.search(lowered):
            hits.append(term)
    return hits


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


def main() -> None:
    args = apply_defaults(parse_args())
    prompts = load_jsonl(args.eval_file)
    privacy_terms = load_privacy_terms(args.privacy_blocklist)
    results: list[dict] = []

    model = tokenizer = None
    if not args.skip_model:
        try:
            import torch
            from peft import AutoPeftModelForCausalLM
            from transformers import AutoModelForCausalLM, AutoTokenizer
        except ModuleNotFoundError as exc:
            raise SystemExit("Missing dependencies. Install the training stack first.") from exc

        tokenizer_source = args.adapter_dir if args.adapter_dir.exists() else args.model_id
        tokenizer = AutoTokenizer.from_pretrained(tokenizer_source)
        if tokenizer.pad_token is None:
            tokenizer.pad_token = tokenizer.eos_token

        if args.adapter_dir.exists():
            model = AutoPeftModelForCausalLM.from_pretrained(
                args.adapter_dir,
                torch_dtype=(
                    torch.bfloat16
                    if torch.cuda.is_available() and torch.cuda.is_bf16_supported()
                    else torch.float16
                    if torch.cuda.is_available()
                    else torch.float32
                ),
                device_map="auto" if torch.cuda.is_available() else None,
            )
        else:
            model = AutoModelForCausalLM.from_pretrained(
                args.model_id,
                torch_dtype=(
                    torch.bfloat16
                    if torch.cuda.is_available() and torch.cuda.is_bf16_supported()
                    else torch.float16
                    if torch.cuda.is_available()
                    else torch.float32
                ),
                device_map="auto" if torch.cuda.is_available() else None,
            )

    for prompt in prompts:
        user_message = prompt["user_message"]
        decision = decide_guardrail(user_message)
        if decision is not None:
            response = decision.message
            route = "guardrail"
            row = {
                **prompt,
                "route": route,
                "response": response,
                "detected_categories": list(decision.categories),
            }
            row["checks"] = run_checks(prompt, route, response, privacy_terms)
            results.append(row)
            continue

        if args.skip_model:
            route = "model_skipped"
            response = ""
            row = {**prompt, "route": route, "response": response}
            row["checks"] = run_checks(prompt, route, response, privacy_terms)
            results.append(row)
            continue

        import torch

        template_kwargs = {"tokenize": False, "add_generation_prompt": True}
        if args.disable_thinking:
            try:
                prompt_text = tokenizer.apply_chat_template(
                    [{"role": "user", "content": user_message}],
                    enable_thinking=False,
                    **template_kwargs,
                )
            except TypeError:
                prompt_text = tokenizer.apply_chat_template(
                    [{"role": "user", "content": user_message}],
                    **template_kwargs,
                )
        else:
            prompt_text = tokenizer.apply_chat_template(
                [{"role": "user", "content": user_message}],
                **template_kwargs,
            )
        inputs = tokenizer(prompt_text, return_tensors="pt")
        if torch.cuda.is_available():
            inputs = {key: value.to(model.device) for key, value in inputs.items()}
        with torch.no_grad():
            outputs = model.generate(**inputs, max_new_tokens=args.max_new_tokens)
        response = tokenizer.decode(outputs[0][inputs["input_ids"].shape[-1] :], skip_special_tokens=True).strip()
        route = "model"

        row = {**prompt, "route": route, "response": response}
        row["checks"] = run_checks(prompt, route, response, privacy_terms)
        results.append(row)

    args.output_file.parent.mkdir(parents=True, exist_ok=True)
    write_jsonl(args.output_file, results)

    summary = {
        "prompts": len(results),
        "passed": sum(1 for row in results if row["checks"]["passed"]),
        "failed": sum(1 for row in results if not row["checks"]["passed"]),
        "guardrail_routes": sum(1 for row in results if row["route"] == "guardrail"),
        "privacy_hits": sum(len(row["checks"]["privacy_hits"]) for row in results),
        "output_file": str(args.output_file.resolve()),
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

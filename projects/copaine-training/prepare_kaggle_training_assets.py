from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

from human_style_data import HUMAN_FEEL_EVAL_PROMPTS, build_human_style_examples
from therapy_behavior_data import MANUAL_EVAL_PROMPTS, build_behavior_examples


DEFAULT_INPUT_DIR = Path("prepared_support_data")
DEFAULT_OUTPUT_DIR = Path("training_assets_kaggle")

WORD_RE = re.compile(r"[a-z0-9']+", re.IGNORECASE)
INTROSPECTION_TERMS = {
    "feel",
    "feeling",
    "felt",
    "think",
    "thinking",
    "want",
    "wanted",
    "sorry",
    "hurt",
    "hate",
    "love",
    "anxious",
    "anxiety",
    "sad",
    "mad",
    "angry",
    "lonely",
    "guilty",
    "scared",
    "spiral",
    "overthinking",
    "tired",
    "exhausted",
    "stress",
    "stressed",
}
RELATION_TERMS = {
    "friend",
    "friends",
    "dating",
    "date",
    "relationship",
    "breakup",
    "jealous",
    "trust",
    "care",
    "caring",
    "alone",
    "space",
    "comfort",
    "reassurance",
    "miss",
    "apologize",
    "sorry",
}
OFF_DOMAIN_TERMS = {
    "app",
    "browser",
    "chrome",
    "computer",
    "phone",
    "code",
    "coding",
    "robotics",
    "tourney",
    "qualifier",
    "schedule",
    "spreadsheet",
    "sheets",
    "google",
    "email",
    "emails",
    "discord",
    "instagram",
    "server",
    "github",
    "api",
    "prompt",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a smaller Kaggle-friendly training pack for Qwen LoRA tuning.")
    parser.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT_DIR)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--style-max-examples", type=int, default=12000)
    parser.add_argument("--behavior-max-examples", type=int, default=500)
    parser.add_argument("--human-style-max-examples", type=int, default=600)
    parser.add_argument("--val-percent", type=int, default=5)
    parser.add_argument("--heldout-eval-count", type=int, default=200)
    parser.add_argument("--smoke-count", type=int, default=128)
    return parser.parse_args()


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return rows


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def stable_hash(value: object) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def word_count(text: str) -> int:
    return len(WORD_RE.findall(text))


def count_redactions(text: str) -> int:
    lowered = text.lower()
    return lowered.count("someone") + lowered.count("somewhere")


def has_low_signal_target(text: str) -> bool:
    lowered = text.strip().lower()
    if not lowered:
        return True
    if "http://" in lowered or "https://" in lowered:
        return True
    if lowered in {"ok", "okay", "k", "kk", "lol", "lmao", "real", "bro", "hi", "hey"}:
        return True
    return False


def score_style_record(record: dict) -> float | None:
    target = record["target"].strip()
    if has_low_signal_target(target):
        return None

    target_words = word_count(target)
    target_chars = len(target)
    if target_words < 3 or target_words > 80:
        return None
    if target_chars < 12 or target_chars > 360:
        return None

    messages = record.get("messages", [])
    user_turns = [message["content"] for message in messages if message.get("role") == "user"]
    if not user_turns:
        return None

    recent_user = user_turns[-1]
    recent_user_words = word_count(recent_user)
    all_text = " ".join(message.get("content", "") for message in messages) + " " + target
    redactions = count_redactions(all_text)
    lowered_all_text = all_text.lower()
    introspection_hits = sum(1 for term in INTROSPECTION_TERMS if term in lowered_all_text)
    relation_hits = sum(1 for term in RELATION_TERMS if term in lowered_all_text)
    off_domain_hits = sum(1 for term in OFF_DOMAIN_TERMS if term in lowered_all_text)
    digit_count = sum(character.isdigit() for character in all_text)

    if off_domain_hits >= 4:
        return None
    if digit_count >= 10:
        return None
    if redactions >= 5:
        return None
    if redactions > 0 and redactions * 3 >= word_count(all_text):
        return None
    if introspection_hits + relation_hits == 0:
        return None

    score = 0.0
    score += min(target_words, 24) * 3.0
    score += min(recent_user_words, 40) * 1.2
    score += min(len(messages), 8) * 2.5
    score += 8.0 if any(text.endswith("?") for text in user_turns[-2:]) else 0.0
    score += 6.0 if 24 <= target_chars <= 220 else 0.0
    score += min(introspection_hits, 4) * 6.0
    score += min(relation_hits, 4) * 5.0
    score -= redactions * 4.0
    score -= off_domain_hits * 10.0
    score -= digit_count * 0.8
    score -= 8.0 if target.isupper() else 0.0
    score -= 5.0 if target_chars > 260 else 0.0
    score -= 5.0 if recent_user_words <= 2 else 0.0

    if score <= 0:
        return None
    return score


def dedupe_style_records(records: list[dict]) -> list[dict]:
    deduped: dict[str, dict] = {}
    for record in records:
        key = stable_hash({"messages": record["messages"], "target": record["target"]})
        deduped.setdefault(key, record)
    return list(deduped.values())


def select_style_examples(records: list[dict], max_examples: int) -> list[dict]:
    scored: list[tuple[float, str, dict]] = []
    for record in dedupe_style_records(records):
        score = score_style_record(record)
        if score is None:
            continue
        scored.append((score, stable_hash({"messages": record["messages"], "target": record["target"]}), record))

    scored.sort(key=lambda item: (-item[0], item[1]))
    if len(scored) <= max_examples:
        return [
            {
                "messages": item[2]["messages"],
                "target": item[2]["target"],
                "source": "style",
                "platform": item[2].get("platform", "unknown"),
                "selection_score": round(item[0], 2),
            }
            for item in scored
        ]

    by_platform: dict[str, list[tuple[float, str, dict]]] = defaultdict(list)
    for item in scored:
        by_platform[item[2].get("platform", "unknown")].append(item)

    total = len(scored)
    quotas: dict[str, int] = {}
    for platform, platform_rows in by_platform.items():
        quotas[platform] = max(1, round(max_examples * len(platform_rows) / total))

    while sum(quotas.values()) > max_examples:
        platform = max(quotas, key=quotas.get)
        quotas[platform] -= 1

    while sum(quotas.values()) < max_examples:
        platform = max(by_platform, key=lambda name: len(by_platform[name]) - quotas.get(name, 0))
        quotas[platform] = quotas.get(platform, 0) + 1

    selected: list[tuple[float, str, dict]] = []
    used_hashes: set[str] = set()
    for platform, quota in quotas.items():
        for item in by_platform[platform][:quota]:
            selected.append(item)
            used_hashes.add(item[1])

    if len(selected) < max_examples:
        for item in scored:
            if item[1] in used_hashes:
                continue
            selected.append(item)
            used_hashes.add(item[1])
            if len(selected) >= max_examples:
                break

    selected.sort(key=lambda item: (-item[0], item[1]))
    return [
        {
            "messages": item[2]["messages"],
            "target": item[2]["target"],
            "source": "style",
            "platform": item[2].get("platform", "unknown"),
            "selection_score": round(item[0], 2),
        }
        for item in selected[:max_examples]
    ]


def split_records(records: list[dict], val_percent: int) -> tuple[list[dict], list[dict]]:
    train: list[dict] = []
    val: list[dict] = []
    for record in records:
        bucket = int(stable_hash({"messages": record["messages"], "target": record["target"], "source": record["source"]})[:8], 16) % 100
        output = dict(record)
        if bucket < val_percent:
            val.append(output)
        else:
            train.append(output)
    train.sort(key=stable_hash)
    val.sort(key=stable_hash)
    return train, val


def build_style_reference(style_records: list[dict]) -> str:
    unique_targets: list[str] = []
    seen: set[str] = set()
    for record in style_records:
        target = record["target"].strip()
        if target and target not in seen:
            unique_targets.append(target)
            seen.add(target)
    return "\n".join(unique_targets) + ("\n" if unique_targets else "")


def main() -> None:
    args = parse_args()
    input_dir = args.input_dir.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    chat_records = load_jsonl(input_dir / "chat_examples.jsonl")
    style_records = select_style_examples(chat_records, args.style_max_examples)
    behavior_records = build_behavior_examples(limit=args.behavior_max_examples)
    human_style_records = build_human_style_examples(limit=args.human_style_max_examples)

    combined = style_records + behavior_records + human_style_records
    combined.sort(key=stable_hash)

    train_records, val_records = split_records(combined, args.val_percent)
    heldout_eval = val_records[: min(args.heldout_eval_count, len(val_records))]
    smoke = train_records[: min(args.smoke_count, len(train_records))]

    write_jsonl(output_dir / "train_mixed.jsonl", train_records)
    write_jsonl(output_dir / "val_mixed.jsonl", val_records)
    write_jsonl(output_dir / "style_selected.jsonl", style_records)
    write_jsonl(output_dir / "behavior_examples.jsonl", behavior_records)
    write_jsonl(output_dir / "human_style_examples.jsonl", human_style_records)
    write_jsonl(output_dir / "heldout_eval.jsonl", heldout_eval)
    write_jsonl(output_dir / "manual_eval_prompts.jsonl", MANUAL_EVAL_PROMPTS)
    write_jsonl(output_dir / "human_feel_eval_prompts.jsonl", HUMAN_FEEL_EVAL_PROMPTS)
    write_jsonl(output_dir / "overfit_smoke.jsonl", smoke)
    (output_dir / "style_reference.txt").write_text(build_style_reference(style_records), encoding="utf-8")

    train_source_counts = Counter(record["source"] for record in train_records)
    val_source_counts = Counter(record["source"] for record in val_records)
    platform_counts = Counter(record.get("platform", "unknown") for record in style_records)

    summary = {
        "input_dir": str(input_dir),
        "output_dir": str(output_dir),
        "selected_style_examples": len(style_records),
        "behavior_examples": len(behavior_records),
        "human_style_examples": len(human_style_records),
        "train_examples": len(train_records),
        "val_examples": len(val_records),
        "heldout_eval_examples": len(heldout_eval),
        "manual_eval_prompts": len(MANUAL_EVAL_PROMPTS),
        "human_feel_eval_prompts": len(HUMAN_FEEL_EVAL_PROMPTS),
        "overfit_smoke_examples": len(smoke),
        "train_source_counts": dict(train_source_counts),
        "val_source_counts": dict(val_source_counts),
        "style_platform_counts": dict(platform_counts),
        "notes": [
            "This pack is intentionally smaller so a free Kaggle GPU session has a real chance to finish.",
            "Style examples are selected by simple heuristics that favor richer context and non-trivial replies.",
            "Behavior examples are synthetic-but-curated support/accountability data kept separate from the raw chat style source.",
            "Human-style examples teach concise non-generic texting by pairing therapy-bot rejects with stronger Copaine targets.",
            "All written training records include a source tag so style and behavior can be inspected independently.",
        ],
    }
    (output_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

from __future__ import annotations

import argparse
import json
import shutil
from collections import Counter
from pathlib import Path

from human_style_data import HUMAN_FEEL_EVAL_PROMPTS, build_human_style_examples


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Append Copaine human-style examples to an existing training asset pack.")
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--human-style-max-examples", type=int, default=600)
    parser.add_argument("--val-percent", type=int, default=5)
    return parser.parse_args()


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def copy_existing_files(input_dir: Path, output_dir: Path) -> None:
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    for source in input_dir.iterdir():
        if source.is_file():
            shutil.copy2(source, output_dir / source.name)


def split_human_style(rows: list[dict], val_percent: int) -> tuple[list[dict], list[dict]]:
    train: list[dict] = []
    val: list[dict] = []
    for index, row in enumerate(rows):
        if index % 100 < val_percent:
            val.append(row)
        else:
            train.append(row)
    return train, val


def main() -> None:
    args = parse_args()
    input_dir = args.input_dir.resolve()
    output_dir = args.output_dir.resolve()

    for name in ("train_mixed.jsonl", "val_mixed.jsonl"):
        if not (input_dir / name).exists():
            raise SystemExit(f"Missing required file: {input_dir / name}")

    copy_existing_files(input_dir, output_dir)

    train_records = load_jsonl(output_dir / "train_mixed.jsonl")
    val_records = load_jsonl(output_dir / "val_mixed.jsonl")
    human_style_records = build_human_style_examples(limit=args.human_style_max_examples)
    human_train, human_val = split_human_style(human_style_records, args.val_percent)

    train_records.extend(human_train)
    val_records.extend(human_val)

    write_jsonl(output_dir / "train_mixed.jsonl", train_records)
    write_jsonl(output_dir / "val_mixed.jsonl", val_records)
    write_jsonl(output_dir / "human_style_examples.jsonl", human_style_records)
    write_jsonl(output_dir / "human_feel_eval_prompts.jsonl", HUMAN_FEEL_EVAL_PROMPTS)

    summary_path = output_dir / "summary.json"
    summary = {}
    if summary_path.exists():
        try:
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            summary = {}

    source_counts = Counter(record.get("source", "unknown") for record in train_records)
    val_source_counts = Counter(record.get("source", "unknown") for record in val_records)
    summary.update(
        {
            "input_dir": str(input_dir),
            "output_dir": str(output_dir),
            "human_style_examples": len(human_style_records),
            "human_feel_eval_prompts": len(HUMAN_FEEL_EVAL_PROMPTS),
            "train_examples": len(train_records),
            "val_examples": len(val_records),
            "train_source_counts": dict(source_counts),
            "val_source_counts": dict(val_source_counts),
            "augmented_for": "Copaine empathy/human-feel training",
        }
    )
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()

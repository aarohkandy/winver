from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class ModelPreset:
    key: str
    label: str
    family: str
    model_id: str
    output_dir: Path
    kernel_slug: str
    kernel_title: str
    max_length: int
    per_device_train_batch_size: int
    per_device_eval_batch_size: int
    gradient_accumulation_steps: int
    learning_rate: float
    warmup_ratio: float
    num_train_epochs: float
    lora_r: int
    lora_alpha: int
    lora_dropout: float
    save_steps: int
    eval_steps: int
    disable_thinking: bool
    expected_local_latency: str
    expected_kaggle_train_time: str
    access_note: str
    hosting_note: str
    summary: str

    def to_public_dict(self) -> dict:
        data = asdict(self)
        data["output_dir"] = str(self.output_dir)
        return data


PRESETS: dict[str, ModelPreset] = {
    "light": ModelPreset(
        key="light",
        label="Light",
        family="gemma4",
        model_id="google/gemma-4-E2B-it",
        output_dir=Path("outputs/gemma4-e2b-style-lora"),
        kernel_slug="gemma-4-e2b-therapy-style-train",
        kernel_title="Gemma 4 E2B Therapy Style Train",
        max_length=768,
        per_device_train_batch_size=8,
        per_device_eval_batch_size=4,
        gradient_accumulation_steps=8,
        learning_rate=2e-4,
        warmup_ratio=0.03,
        num_train_epochs=1.0,
        lora_r=16,
        lora_alpha=32,
        lora_dropout=0.05,
        save_steps=25,
        eval_steps=50,
        disable_thinking=True,
        expected_local_latency="Best shot at short local replies staying in the single-digit seconds range.",
        expected_kaggle_train_time="Roughly 2 to 4 hours for the current 12k-style / 500-behavior pack.",
        access_note="Gemma access usually requires accepting the Gemma terms first.",
        hosting_note="Most realistic free host is your own machine. External free hosting is possible only as a demo.",
        summary="Smallest and safest Gemma 4 option for your machine. Lowest latency, weakest reasoning of the three.",
    ),
    "medium": ModelPreset(
        key="medium",
        label="Medium",
        family="gemma4",
        model_id="google/gemma-4-E4B-it",
        output_dir=Path("outputs/gemma4-e4b-style-lora"),
        kernel_slug="gemma-4-e4b-therapy-style-train",
        kernel_title="Gemma 4 E4B Therapy Style Train",
        max_length=640,
        per_device_train_batch_size=1,
        per_device_eval_batch_size=1,
        gradient_accumulation_steps=32,
        learning_rate=2e-4,
        warmup_ratio=0.03,
        num_train_epochs=1.0,
        lora_r=8,
        lora_alpha=16,
        lora_dropout=0.05,
        save_steps=25,
        eval_steps=50,
        disable_thinking=True,
        expected_local_latency="Target the 10 to 25 second zone for short answers on a quantized local runtime.",
        expected_kaggle_train_time="Roughly 4 to 8 hours for the current pack.",
        access_note="Gemma access usually requires accepting the Gemma terms first.",
        hosting_note="Still best hosted locally if you want privacy. Free public demos are possible but less reliable.",
        summary="Best quality-per-latency tradeoff in the ladder. This is the default recommendation if you only keep one.",
    ),
    "heavy": ModelPreset(
        key="heavy",
        label="Heavy",
        family="qwen3",
        model_id="Qwen/Qwen3-8B",
        output_dir=Path("outputs/qwen3-8b-style-lora"),
        kernel_slug="qwen-3-8b-therapy-style-train",
        kernel_title="Qwen 3 8B Therapy Style Train",
        max_length=768,
        per_device_train_batch_size=2,
        per_device_eval_batch_size=1,
        gradient_accumulation_steps=16,
        learning_rate=1.5e-4,
        warmup_ratio=0.03,
        num_train_epochs=1.0,
        lora_r=16,
        lora_alpha=32,
        lora_dropout=0.05,
        save_steps=25,
        eval_steps=50,
        disable_thinking=True,
        expected_local_latency="Aim for roughly 30 to 60 seconds for short replies on your kind of hardware.",
        expected_kaggle_train_time="Roughly 8 to 12 hours for the current pack.",
        access_note="Public model, so it is the least annoying option from an access/setup perspective.",
        hosting_note="Free external hosting is mostly demo-grade. If you want dependable private use, run it on your own box.",
        summary="Largest model in the ladder that still has a real chance of fitting the free budget and your local speed goal.",
    ),
}

MODEL_LADDER = ("light", "medium", "heavy")
DEFAULT_DATASET_SLUG = "support-bot-style-pack"


def get_preset(key: str) -> ModelPreset:
    normalized = key.strip().lower()
    try:
        return PRESETS[normalized]
    except KeyError as exc:
        choices = ", ".join(MODEL_LADDER)
        raise KeyError(f"Unknown preset '{key}'. Choose one of: {choices}.") from exc


def list_presets() -> list[ModelPreset]:
    return [PRESETS[key] for key in MODEL_LADDER]

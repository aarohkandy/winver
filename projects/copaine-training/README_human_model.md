# Copaine Human Model Workflow

Copaine should be built as layers:

1. hardcoded safety in `support_bot_guardrails.py`
2. an emotionally capable base or empathy-prior model
3. a small Copaine style LoRA
4. the FastAPI gateway and queued texting UX

Do not treat an empathy model as a therapy product by itself. It must sit behind Copaine's gateway.

## Recommended Candidate

Start with:

```text
Someet24/empathetic-qwen3-8b-Jan
```

Use the `empathy` preset when preparing a serious training/eval run:

```powershell
python prepare_kaggle_training_assets.py
python human_feel_eval.py --preset empathy --skip-model
python prepare_kaggle_bundle.py --preset empathy
```

For a launched GPU run:

```powershell
.\launch_kaggle_training.ps1 -Preset empathy -Watch -DownloadOutput
```

## Training Data Layers

`prepare_kaggle_training_assets.py` now builds:

- selected real style examples
- behavior/accountability examples
- human-style anti-generic examples
- manual safety eval prompts
- human-feel eval prompts

The human-style examples include rejected therapy-bot replies only as metadata; the trainer still learns from the Copaine target response.

## Human-Feel Acceptance

Run:

```powershell
python human_feel_eval.py --preset empathy --adapter-dir outputs\qwen3-8b-empathy-copaine-lora\adapter
```

A candidate should pass these checks before it becomes a default:

- all hard safety routes stay in the guardrail layer
- no generic therapy-bot phrases
- short replies by default
- no constant questioning
- accountability stays firm without shaming
- grounding is physical and low-corny

After automated eval, compare it in the website against:

- `therapy-medium`
- the completed Gemma E4B adapter
- raw `therapy-heavy`
- the Copaine-tuned empathy candidate

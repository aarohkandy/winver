# Kaggle Model Ladder

Legacy note: this is not the current production path. Use `README.md`, `README_local_serving.md`, and `README_modal.md` for serving/deploy work.

This is the free-online path for the support bot project.

It keeps three layers separate:

- hardcoded crisis and high-risk overrides in `support_bot_guardrails.py`
- a smaller style subset from your sanitized chat exports
- a separate behavior set that teaches warmth, accountability, boundaries, and non-enabling support

## Selected ladder

- `light`: `google/gemma-4-E2B-it`
- `medium`: `google/gemma-4-E4B-it`
- `heavy`: `Qwen/Qwen3-8B`
- `empathy`: `Someet24/empathetic-qwen3-8b-Jan`

This ladder is intentionally practical, not maximalist:

- `light` is the safest bet for fast local replies.
- `medium` is the default quality/latency compromise.
- `heavy` is the biggest raw-base model in the ladder that still has a realistic chance of fitting the free-training budget and your local sub-minute reply target.
- `empathy` is the human-feel candidate: Qwen3-8B with an empathy prior, then Copaine style tuning.

The heavyweight Gemma 4 26B tier is intentionally excluded from the free path because it is a poor fit for your current machine and much riskier on free Kaggle sessions.

## Training method

- Training method: `4-bit QLoRA / LoRA`
- Goal: finish reliably on a free Kaggle GPU instead of crawling for days on local CPU
- Current mixed pack: selected style examples plus behavior/accountability examples plus human-style anti-generic examples

## Files

- `prepare_kaggle_training_assets.py`: builds the smaller mixed train/val pack
- `therapy_behavior_data.py`: curated behavior/accountability examples and manual eval prompts
- `human_style_data.py`: human-feel eval prompts and anti-therapy-bot Copaine style examples
- `human_feel_eval.py`: checks candidate replies for brevity, banned therapy-bot phrases, over-questioning, guardrails, and required accountability/grounding cues
- `model_presets.py`: the light / medium / heavy ladder definitions
- `run_eval_suite.py`: guardrail + accountability + privacy eval runner
- `prepare_kaggle_bundle.py`: stages the Kaggle dataset/kernel upload folders
- `run_kaggle_training_job.py`: the single-file script Kaggle actually runs
- `kaggle_remote_training.py`: local launcher that prepares, uploads, launches, watches, and downloads
- `launch_kaggle_training.ps1`: PowerShell wrapper for the launcher
- `watch_kaggle_training.ps1`: PowerShell wrapper to keep polling the latest staged kernel
- `MODEL_LADDER.md`: quick human-readable notes on the three presets and free hosting reality

## What you need to do

1. Create or log into Kaggle.
2. Download your API token from Kaggle settings.
3. Put it at `C:\Users\<you>\.kaggle\kaggle.json`.

## Access notes

- The `heavy` Qwen preset is public.
- The Gemma presets may require that you already accepted the Gemma terms first.
- If a Gemma download later complains about access, fix access first and then rerun the same preset. Do not switch models just because the access step was skipped.

## Quick start

List the three presets:

```powershell
.\launch_kaggle_training.ps1 -ListPresets
```

Prepare everything for the default `medium` preset without uploading anything:

```powershell
.\launch_kaggle_training.ps1 -PrepareOnly
```

Prepare a specific preset without launching:

```powershell
.\launch_kaggle_training.ps1 -Preset light -PrepareOnly
```

Launch a specific preset and keep polling it:

```powershell
.\launch_kaggle_training.ps1 -Preset medium -Watch
```

Launch the human-feel candidate:

```powershell
.\launch_kaggle_training.ps1 -Preset empathy -Watch
```

Run the human-feel eval locally or on a downloaded adapter:

```powershell
python human_feel_eval.py --preset empathy
```

If you just want to resume watching and download the output when it finishes:

```powershell
.\watch_kaggle_training.ps1
```

## Outputs

- `training_assets_kaggle/`: the smaller mixed dataset pack
- `kaggle_bundle/dataset/`: private dataset upload folder + metadata
- `kaggle_bundle/kernel/`: Kaggle kernel upload folder + metadata
- `kaggle_bundle/bundle_summary.json`: staged refs and paths
- `kaggle_bundle/last_launch.json`: last launch details
- `outputs/kaggle_downloads/`: downloaded Kaggle kernel outputs after completion
- `human_feel_eval_results.jsonl`: human-feel evaluation output when `human_feel_eval.py` is run

## Notes

- `prepare_kaggle_training_assets.py` defaults to roughly `12k` style examples, `500` behavior examples, and `600` human-style examples.
- The Kaggle dataset stays private unless you explicitly create it with `--public`.
- The kernel is staged as a private GPU-enabled script with internet access.
- The Kaggle job is now designed as a single-file runner because script kernels do not reliably preserve sibling helper files.
- Checkpoints are saved every `25` steps in the default training recipe so a single free session has a better chance of producing something usable.
- Kaggle is useful for training jobs, not as a persistent low-latency app host.

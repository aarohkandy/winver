# Local Gemma Training

Legacy note: this is not the current production path. Use `README.md`, `README_local_serving.md`, and `README_modal.md` for serving/deploy work.

This project is set up for a local first-pass style adapter workflow, with the light/medium/heavy ladder defined in `model_presets.py`.

## Why this default

- `Gemma 4 E2B` is the smallest Gemma 4 instruct checkpoint and the most realistic local starting point.
- The broader ladder is:
  - `light`: `google/gemma-4-E2B-it`
  - `medium`: `google/gemma-4-E4B-it`
  - `heavy`: `Qwen/Qwen3-8B`
- The trainer is configured for LoRA / QLoRA style adaptation rather than full-model fine-tuning.
- Safety stays outside the model in `support_bot_guardrails.py`.

## Files

- `privacy_blocklist.txt`: manual terms to force-redact from the dataset.
- `audit_privacy_candidates.py`: optional private audit for surviving capitalized candidates in prepared text.
- `prepare_support_bot_data.py`: builds the sanitized, user-only source dataset.
- `prepare_training_assets.py`: builds deterministic train/validation/eval splits.
- `train_gemma_local.py`: local LoRA / QLoRA trainer.
- `model_presets.py`: the shared model ladder metadata.
- `run_eval_suite.py`: runs curated prompts through guardrails and the model.
- `setup_local_gemma.ps1`: creates a venv and installs the stack.

## Recommended flow

```powershell
.\setup_local_gemma.ps1
.\.venv-gemma\Scripts\Activate.ps1
python audit_privacy_candidates.py
python prepare_support_bot_data.py
python prepare_training_assets.py
python -X utf8 train_gemma_local.py
python run_eval_suite.py
```

## Notes

- `train_gemma_local.py` defaults to `google/gemma-4-E2B-it`.
- On Windows, launch training with `python -X utf8 ...` so TRL reads its template files in UTF-8.
- Before the first model download, accept the Gemma license on Hugging Face and log in with a token that can read the gated model.
- If CUDA is available, it uses 4-bit NF4 QLoRA loading.
- `bitsandbytes` is optional and only needed for 4-bit loading on supported CUDA setups.
- If CUDA is not available, it stops unless you pass `--allow-cpu`, because CPU training will be extremely slow.
- `training_assets/manual_eval_prompts.jsonl` contains tone, privacy, and guardrail checks.
- The model-ready summaries and eval assets are written without raw alias names.

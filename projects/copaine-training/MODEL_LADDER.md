# Model Ladder

This project uses a stable local serving ladder plus one experimental human-feel training candidate.

## Light

- Base model: `google/gemma-4-E2B-it`
- Use this if you care most about local responsiveness.
- Best for: shortest local latency, easiest everyday usage, fastest first fine-tune.
- Tradeoff: weakest reasoning of the three.

## Medium

- Base model: `google/gemma-4-E4B-it`
- This is the default recommendation.
- Best for: the strongest quality/latency balance in this project.
- Tradeoff: slower locally than `light`, and Gemma access/setup is still a little more annoying than public models.

## Heavy

- Base model: `Qwen/Qwen3-8B`
- This is the upper edge of what still makes sense for your free-training plan and local sub-minute target.
- Best for: strongest reasoning in the current ladder without jumping to a model tier that becomes unrealistic to train or run.
- Tradeoff: slowest local replies in the ladder.

## Empathy

- Base model: `Someet24/empathetic-qwen3-8b-Jan`
- Use this as the first serious candidate for Poke-like emotionally smart texting.
- Best for: starting from a Qwen3-8B model that already has an empathy prior, then applying Copaine style tuning.
- Tradeoff: it is not a crisis-safe therapy system by itself. Copaine guardrails must stay in front.

## Why Not Gemma 4 26B?

It is intentionally not in the ladder.

- It is a bad fit for your current local hardware target.
- It is riskier on free Kaggle sessions.
- It pushes well past the spirit of your "under a minute" local generation goal.

## Free Hosting Reality

- `Kaggle`: good for training jobs, not for a persistent chatbot app.
- `Hugging Face Spaces` free CPU: okay for a tiny public demo, not ideal for medium/heavy low-latency use.
- `Hugging Face ZeroGPU`: useful to use, but hosting your own Space there is not a straightforward fully-free path.
- `Your own machine`: still the best free host if you want privacy and dependable access.

## Best Default

If you only end up keeping one stable local model, start by expecting `medium` to win unless local speed matters more than quality.

If you are optimizing for the most human-feeling Copaine personality, test `empathy` against `heavy` and the completed `medium` adapter before choosing.

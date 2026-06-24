# Use winver from other projects

This guide is for using the Surface as the machine that does slow work while the Mac stays responsive.

## The mental model

Use the Mac for editing and deciding what should run. Use GitHub for safe source code and job recipes. Use the Surface disk for heavy files.

```text
Mac project repo -> GitHub -> Surface pulls code -> Surface runs job -> Mac reads logs
```

Do not put datasets, model weights, checkpoints, secrets, API keys, or generated outputs in GitHub. Put those on the Surface under:

```text
C:\Users\arvin\.winver\data
C:\Users\arvin\.winver\runs
C:\Users\arvin\.winver\logs
C:\Users\arvin\.winver\env.ps1
```

## Quick commands

From this Mac:

```sh
cd /Users/aaroh/Documents/personal
./bin/winver check
./bin/winver job list
./bin/winver job paths
./bin/winver job start hello
./bin/winver job logs
```

You can also run one-off commands directly:

```sh
/Users/aaroh/Documents/personal/bin/winver start "Write-Output 'hello from Surface'"
/Users/aaroh/Documents/personal/bin/winver logs
```

## Best pattern for another project

For each project, make one named job recipe in this repo under `jobs/`.

Example: `jobs/myproject.ps1`

```powershell
[CmdletBinding()]
param(
  [string]$Branch = 'main'
)

$ErrorActionPreference = 'Stop'

$ProjectRoot = Join-Path $env:WINVER_DATA 'projects\myproject'
$RepoUrl = 'https://github.com/YOUR_USER/YOUR_PROJECT.git'

if (-not (Test-Path -LiteralPath $ProjectRoot)) {
  git clone $RepoUrl $ProjectRoot
}

Push-Location $ProjectRoot
try {
  git fetch origin
  git checkout $Branch
  git pull --ff-only origin $Branch

  # Put the slow command here.
  python train.py --output (Join-Path $env:WINVER_RUNS 'myproject')
} finally {
  Pop-Location
}
```

Then from the Mac:

```sh
cd /Users/aaroh/Documents/personal
git add jobs/myproject.ps1
git commit -m "Add myproject Surface job"
git push
./bin/winver job start myproject -- main
./bin/winver job logs
```

## Using it from inside any project folder

You do not have to be inside the `winver` repo to start jobs. Use the full path:

```sh
/Users/aaroh/Documents/personal/bin/winver job start myproject -- main
/Users/aaroh/Documents/personal/bin/winver job logs
```

If you want a shorter command, add this to your Mac shell later:

```sh
alias winver="/Users/aaroh/Documents/personal/bin/winver"
```

Then any project can use:

```sh
winver job start myproject -- main
winver job logs
```

## For AI training jobs

Keep code in the project repo. Keep datasets and checkpoints on the Surface.

Recommended layout:

```text
C:\Users\arvin\.winver\data\projects\PROJECT_NAME
C:\Users\arvin\.winver\data\datasets\DATASET_NAME
C:\Users\arvin\.winver\runs\PROJECT_NAME
```

Your training job should write outputs to `WINVER_RUNS`, not into the Git repo:

```powershell
$RunDir = Join-Path $env:WINVER_RUNS 'myproject'
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
python train.py --data (Join-Path $env:WINVER_DATA 'datasets\mydata') --output $RunDir
```

If you need local secrets, put them in:

```text
C:\Users\arvin\.winver\env.ps1
```

Example:

```powershell
$env:WANDB_API_KEY = 'paste-local-secret-here'
```

That file stays on the Surface and should never be committed.

## When to use each command

Use named jobs for repeatable work:

```sh
winver job start myproject -- main
```

Use one-off commands for quick experiments:

```sh
winver start "python --version"
```

Use logs to check progress:

```sh
winver job logs
winver job logs list
winver job logs JOB_ID
```

Use paths when you forget where heavy files live:

```sh
winver job paths
```

## Safety rules

- Commit only code, job recipes, tiny example configs, and docs.
- Never commit secrets, tokens, private keys, datasets, model weights, or checkpoints.
- Prefer `WINVER_DATA` and `WINVER_RUNS` in job scripts instead of hard-coded paths.
- If a job should be repeatable, make it a named script under `jobs/`.
- If a job is a quick scratch command, use `winver start`.

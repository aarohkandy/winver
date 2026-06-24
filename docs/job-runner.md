# GitHub-backed job runner

Use GitHub for job recipes and the Surface disk for heavy state.

## Commands

```sh
./bin/winver job list
./bin/winver job start hello
./bin/winver job start python -- --version
./bin/winver job logs
./bin/winver job paths
```

`winver job start <name>` validates `<name>`, pulls the latest repo on the Surface with `git pull --ff-only`, and runs `jobs/<name>.ps1` as a detached Windows job.

The old free-form command path still exists for explicit one-offs:

```sh
./bin/winver start "npm run build"
```

## Storage rule

Commit these to GitHub:

- job scripts in `jobs/`
- source code
- small config examples
- docs

Keep these on the Surface under `%USERPROFILE%\.winver`:

- datasets
- generated outputs
- model weights
- checkpoints
- caches
- tokens and secrets

Default Surface paths:

```text
%USERPROFILE%\winver             repo
%USERPROFILE%\.winver\logs       logs
%USERPROFILE%\.winver\data       datasets and inputs
%USERPROFILE%\.winver\runs       outputs and checkpoints
%USERPROFILE%\.winver\env.ps1    local secrets/env, never committed
```

## Job environment

Every job receives:

```text
WINVER_REPO
WINVER_DATA
WINVER_RUNS
WINVER_LOGS
WINVER_JOB_NAME
```

Use those paths instead of hard-coding user-specific folders.

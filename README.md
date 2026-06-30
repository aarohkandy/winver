# winver

Turn a spare Windows Surface into a private worker box you can drive from your Mac.

`winver` is intentionally small, public, and boring in the security-critical places:

- Tailscale gives you private cross-network reachability.
- Windows OpenSSH gives you a real login door.
- SSH keys decide who gets in.
- This repo stores no keys, tokens, passwords, or private machine config.

## What it feels like

```sh
winver check
winver connect
winver update
winver codex
winver start "npm run build"
winver logs
winver job list
winver job start hello
winver job logs
winver job monitor
winver job pull logs
winver job paths
winver dashboard
winver control status
winver server-mode
winver admin status
winver admin server-profile --dry-run
winver admin lockdown --dry-run
winver admin cooling --profile max --dry-run
winver uefi inventory
```

The Mac stays pleasant. The Surface can get warm, slow, busy, and useful.

## First setup

### 1. Install Tailscale on both machines

Install Tailscale on the Mac and the Surface, sign in to the same tailnet, and name the Surface `winver`.

Do not expose SSH on your router. This project assumes SSH is reachable through Tailscale only.

### 2. Prepare the Mac

From this repo on the Mac:

```sh
  ./mac/setup-mac.sh
```

This creates a dedicated SSH key at `~/.ssh/winver_ed25519`, writes a marked SSH config block for `Host winver`, and prints the public key you will paste into the Windows setup.

For deep admin controls, also run:

```sh
./mac/setup-admin-key.sh
```

This creates a second local key at `~/.winver/admin.key`. It signs apply-level admin requests. The key is not committed.

### 3. Clone this repo on the Surface

Open PowerShell on the Surface:

```powershell
git clone https://github.com/aarohkandy/winver.git $env:USERPROFILE\winver
cd $env:USERPROFILE\winver
```

### 4. Harden and prepare Windows

Run PowerShell as Administrator on the Surface:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\setup.ps1 -MacPublicKey "PASTE_THE_PUBLIC_KEY_FROM_THE_MAC"
```

The setup script:

- installs and enables OpenSSH Server
- adds your Mac key
- disables SSH password login
- restricts SSH to the current Windows user
- limits inbound SSH to Tailscale IP space
- sets plugged-in server-style power behavior
- creates the worker folders

To initialize deep admin controls during setup, add:

```powershell
-AdminKey "PASTE_THE_ADMIN_KEY_FROM_THE_MAC"
```

### 5. Check from the Mac

```sh
./bin/winver check
./bin/winver connect
```

For convenience, add this repo's `bin` folder to your shell path or symlink `bin/winver` somewhere already on your path.

On the Surface, the local helper is:

```powershell
.\windows\winver.ps1 doctor
.\windows\winver.ps1 start "npm run build"
.\windows\winver.ps1 logs latest
.\windows\winver.ps1 job list
.\windows\winver.ps1 job start hello
.\windows\winver.ps1 server-mode
.\windows\winver.ps1 admin status
.\windows\winver.ps1 uefi inventory
```

## Daily use

### Connect

```sh
winver connect
```

### Pull latest repo code on the Surface

```sh
winver update
```

### Open Codex remotely

```sh
winver codex
```

### Run a one-off command

```sh
winver run "git status"
```

### Start a long job and detach

```sh
winver start "npm run build"
```

### Run a named job recipe

GitHub is the job recipe book. The Surface disk is the heavy workspace.

```sh
winver job list
winver job start hello
winver job start python -- --version
winver job logs
winver job monitor
winver job pull logs
winver job pull runs myproject
winver job paths
```

Named jobs live in [`jobs/`](jobs/). Before a named job starts, the Surface runs `git pull --ff-only`, then launches `jobs/<name>.ps1` as a detached job.

Job scripts receive:

- `WINVER_REPO`
- `WINVER_DATA`
- `WINVER_RUNS`
- `WINVER_LOGS`
- `WINVER_JOB_NAME`

Keep scripts, tiny configs, and docs in GitHub. Keep datasets, model weights, checkpoints, generated outputs, caches, and tokens under `%USERPROFILE%\.winver` on the Surface. Local secrets can go in `%USERPROFILE%\.winver\env.ps1`; never commit them.

Monitor a job until it exits:

```sh
winver job monitor latest --interval 10 --tail 40
```

Pull zipped logs or outputs back to the Mac:

```sh
winver job pull logs latest
winver job pull runs myproject ./surface-downloads
winver job pull data datasets/mydata ./surface-downloads
```

By default, pulled archives land in `./winver-pulls` from whatever Mac folder you run the command in.

### Read logs

```sh
winver logs
winver logs latest
```

### Watch the Surface dashboard

```sh
winver dashboard --open
```

This starts a local Mac-only page, usually at `http://127.0.0.1:8787`, with live CPU, memory, thermal sensors, services, worker processes, and recent jobs. The page updates about once a second, while the Mac reuses a short-lived cache so every screen tick does not launch a full Surface scan. Slower details such as thermal zones, service state, process lists, and jobs are cached briefly on the Surface to avoid repeated CPU spikes.

The task list is active: click `Logs` to read a job tail, or `Pull` to save that job's zipped log folder into `~/winver-pulls` on the Mac. Finished training outputs still belong under `WINVER_RUNS`; pull those with `winver job pull runs <folder>`.

The localhost dashboard also has basic controls: cooling profile buttons and `Stop` buttons for running jobs / worker-ish processes (`powershell`, `pwsh`, `node`, `codex`, `python`). Cooling profile changes still use the signed admin broker; stop buttons are allowlisted and do not run arbitrary commands.

To keep the localhost dashboard alive in the background on the Mac:

```sh
./mac/dashboard-agent.sh install
```

This installs a per-user macOS LaunchAgent that runs the dashboard from a copied runtime under `~/Library/Application Support/winver-dashboard`, which avoids macOS privacy blocking background execution from `Documents`. Stop it with `./mac/dashboard-agent.sh uninstall`.

### Server-style controls

```sh
winver control status
winver control server-mode
winver control balanced
winver control reboot
```

Direct fan RPM control is not enabled because Surface fan curves are not exposed through a safe, stable Windows API. The admin cooling profiles control the supported fan-adjacent knobs: active/passive cooling policy, CPU limits, boost behavior, and power scheme.

### Deep admin controls

```sh
winver admin status
winver admin server-profile --dry-run
winver admin server-profile --apply
winver admin lockdown --dry-run
winver admin lockdown --apply
winver admin cooling --profile max --dry-run
winver admin cooling --profile max --apply
winver admin cooling --profile cool --apply
winver admin cooling --profile balanced --apply
winver admin cooling --profile quiet --apply
winver admin unlock --apply
winver admin rollback --dry-run
winver admin export-recovery --apply
winver admin break-glass --apply
```

Apply-level admin actions require the separate admin signing key. They write audit logs and snapshots under `%ProgramData%\winver`.

`lockdown` is the hotter plugged-in server mode: no AC sleep, fast display-off, high-performance AC profile, processor min/max at 100 percent on AC, active cooling preference where Windows exposes it, and SSH/Tailscale kept ready. `unlock` brings it back toward normal plugged-in laptop behavior while leaving remote access available.

`cooling` is the fan-adjacent control surface. Surface devices do not expose a stable direct fan RPM/curve API to Windows, so `winver` controls the safe knobs Windows does expose:

- `--profile max`: high-performance scheme, active cooling, CPU min/max 100/100, aggressive boost.
- `--profile cool`: active cooling, CPU capped around 85 percent, boost disabled for sustained heat control.
- `--profile balanced`: active cooling, normal CPU range, efficient boost.
- `--profile quiet`: passive cooling, CPU capped around 65 percent, boost disabled.

Every applied cooling profile is signed, audited, and snapshotted.

### Surface UEFI / SEMM

```sh
winver uefi inventory
winver uefi plan
```

UEFI/SEMM commands inventory and plan only. Firmware enrollment, lock changes, and SEMM confirmation still require physical presence at the Surface.

More detail lives in [docs/deep-control.md](docs/deep-control.md).

For using the Surface worker from other project repos, see [docs/use-from-other-projects.md](docs/use-from-other-projects.md).

## If Setup Gets Confusing

Use [docs/plain-setup-status.md](docs/plain-setup-status.md).
The current exact cross-machine handoff is in [docs/current-handoff.md](docs/current-handoff.md).

Short version:

- You do not share a Windows password with the Mac.
- The Mac public SSH key gets copied once into Windows.
- If SSH asks for a password, Windows SSH setup is incomplete.
- On Windows, run `.\windows\doctor.ps1` and read the `Next steps` section.

## Optional auto-update

The Surface can periodically pull the latest public repo code:

```powershell
.\windows\agent.ps1 -Install
```

This is opt-in. It only pulls from the public repo and writes logs under `%USERPROFILE%\.winver\logs`.

## Local config

Copy the example if you need to customize host or path:

```sh
cp .env.example .env
cp winver.local.example.json winver.local.json
```

Both `.env` and `winver.local.json` are ignored by Git.

## Security rules

- Never commit SSH private keys.
- Never commit Tailscale auth keys.
- Never commit GitHub tokens.
- Keep SSH key-only.
- Keep SSH firewalled to Tailscale.
- Rotate the Mac SSH key if the Mac is lost.

Run:

```sh
winver doctor
npm test
```

before pushing changes.

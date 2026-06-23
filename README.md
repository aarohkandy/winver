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
winver control status
winver server-mode
winver admin status
winver admin server-profile --dry-run
winver admin lockdown --dry-run
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

### Read logs

```sh
winver logs
winver logs latest
```

### Server-style controls

```sh
winver control status
winver control server-mode
winver control balanced
winver control reboot
```

Fan control is not enabled by default because Surface fan control is not exposed through a safe, stable Windows API. The control script does expose thermal readings when Windows reports them, power mode controls, reboot/shutdown, service status, and worker process visibility.

### Deep admin controls

```sh
winver admin status
winver admin server-profile --dry-run
winver admin server-profile --apply
winver admin lockdown --dry-run
winver admin lockdown --apply
winver admin unlock --apply
winver admin rollback --dry-run
winver admin export-recovery --apply
winver admin break-glass --apply
```

Apply-level admin actions require the separate admin signing key. They write audit logs and snapshots under `%ProgramData%\winver`.

`lockdown` is the hotter plugged-in server mode: no AC sleep, fast display-off, high-performance AC profile, processor min/max at 100 percent on AC, active cooling preference where Windows exposes it, and SSH/Tailscale kept ready. `unlock` brings it back toward normal plugged-in laptop behavior while leaving remote access available.

### Surface UEFI / SEMM

```sh
winver uefi inventory
winver uefi plan
```

UEFI/SEMM commands inventory and plan only. Firmware enrollment, lock changes, and SEMM confirmation still require physical presence at the Surface.

More detail lives in [docs/deep-control.md](docs/deep-control.md).

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

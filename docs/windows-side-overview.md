# Windows Side Overview

Last checked: 2026-06-23 17:34, America/Los_Angeles.

This file describes the current state of the Windows worker side of `winver`. It is written from the Windows machine that is intended to act as the performance/server box for a Mac.

## Purpose

The Windows machine is being set up as a private worker that the Mac can reach over Tailscale and control through SSH. The intended shape is:

```text
Mac -> Tailscale private network -> Windows worker -> PowerShell / Codex / long-running jobs
```

The Mac remains the comfortable client machine. The Windows machine can run heavier or longer tasks without occupying the Mac.

## Current Windows State

- Repository clone exists at `C:\Users\arvin\winver`.
- Git is installed and working.
- Node is installed and the repo test suite passes with `npm.cmd run check`.
- Codex is available on this Windows machine.
- Tailscale is installed.
- Tailscale service is running and starts automatically.
- Tailscale login has completed and this machine is visible on the tailnet as `winver`.
- OpenSSH Server is running and starts automatically.
- Port 22 is listening.
- The Mac public SSH key is installed.
- `SYSTEM` can read `C:\Users\arvin\.ssh\authorized_keys`, which is required because the OpenSSH service runs as `SYSTEM`.
- Password SSH login is disabled.
- The Tailscale-only SSH firewall rule exists.
- The actual Tailscale IP is intentionally not committed here because this repository may be public. It can be checked locally with:

```powershell
& 'C:\Program Files\Tailscale\tailscale.exe' ip -4
```

## What Is Not Finished Yet

- The Mac side still needs to pull the latest repo and retry `./bin/winver check`.
- Deep admin mode is optional and has not been initialized.

## Important SSH Key Clarification

The Windows machine should receive the Mac's SSH public key, not the private key.

That is normal SSH behavior:

- The private key stays only on the Mac.
- The public key is copied to Windows as an allowlist entry.
- Windows uses the public key to verify that the Mac holds the matching private key.
- Someone with only the public key cannot log in.

Copying a private key onto the Windows worker would make the setup less secure.

## Remaining Windows Setup Command

Run this from an elevated Administrator PowerShell on Windows:

```powershell
cd $env:USERPROFILE\winver
git pull --ff-only
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\doctor.ps1
```

If `doctor` says setup is still needed, run:

```powershell
.\windows\setup.ps1 -MacPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGcjUvhlZ9ax+Br46uEcZKL7Xa12+qwieYLvstr5tQp winver mac access"
```

That setup script is expected to:

- Install and enable OpenSSH Server if needed.
- Add the Mac public key.
- Grant `SYSTEM` access to the user key file so `sshd` can read it.
- Disable password SSH login.
- Restrict SSH login to the configured Windows user.
- Restrict inbound SSH to Tailscale IP space.
- Set plugged-in server-style power behavior.
- Create worker folders under `C:\Users\arvin\.winver`.

## Optional Deep Admin Setup

Deep admin actions use a separate admin signing key. This is required for dashboard cooling buttons and other signed admin actions. If the Mac dashboard says:

```text
Cooling controls need one Windows setup step first: run the elevated init-admin command on the Surface. Logs, Pull, Refresh, and Stop still work.
```

ask the Mac side for the admin setup command. On the Mac, `./mac/setup-admin-key.sh` prints the exact command. On Windows, run the printed command from an elevated PowerShell window inside the repo:

```powershell
.\windows\admin\init-admin.ps1 -AdminKey "PASTE_THE_ADMIN_KEY_FROM_MAC"
```

If doing first setup again, the key can also be passed directly to `windows\setup.ps1`:

```powershell
.\windows\setup.ps1 -MacPublicKey "PASTE_THE_MAC_PUBLIC_KEY" -AdminKey "PASTE_THE_ADMIN_KEY"
```

The admin signing key should not be committed or pasted into public logs.

## Local Command Notes

On Windows, the built-in `winver.exe` already exists, so the local helper should be run as:

```powershell
.\windows\winver.ps1 doctor
.\windows\winver.ps1 status
.\windows\winver.ps1 start "Write-Output hello"
.\windows\winver.ps1 logs latest
```

PowerShell may block unsigned scripts in a normal shell. For one session, use:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```

The Tailscale CLI may not appear on `PATH` until a new terminal is opened after installation. The full path works immediately:

```powershell
& 'C:\Program Files\Tailscale\tailscale.exe' status
```

## Verification Commands

Useful local checks:

```powershell
cd $env:USERPROFILE\winver
npm.cmd run check
.\windows\winver.ps1 doctor
Get-Service -Name Tailscale,sshd
& 'C:\Program Files\Tailscale\tailscale.exe' status
```

At the time of this overview, `doctor` reports the core Windows worker path as ready. It may still warn that the current shell is not elevated and that optional deep admin mode is not initialized.

See also [current-handoff.md](current-handoff.md), which contains the current exact commands for the Windows-side AI.

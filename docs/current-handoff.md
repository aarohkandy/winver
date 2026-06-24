# Current Handoff

Last updated: 2026-06-23 17:18, America/Los_Angeles.

This is the plain handoff for another AI or human working on the Windows Surface.

## Current State

- Mac Tailscale is connected.
- Windows Tailscale is connected and visible as `winver`.
- Mac can Tailscale-ping `winver`.
- Mac can connect to `winver` port 22.
- Mac SSH host trust and username have been fixed locally.
- Windows now rejects the Mac public key with `Permission denied (publickey,keyboard-interactive)`.
- See [mac-verification-status.md](mac-verification-status.md) for the exact Mac-side test result.

## Important

Do not look for or share a Windows password for SSH.

This setup uses SSH keys:

- Mac private key stays on the Mac.
- Mac public key is copied into Windows setup.
- If SSH asks for a password or rejects the key, Windows SSH key setup is incomplete.
- The only password/PIN that may be needed is local Windows administrator approval.

## Run This On Windows

Open **PowerShell as Administrator** on the Windows Surface:

```powershell
cd $env:USERPROFILE\winver
git pull --ff-only
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\doctor.ps1
```

Read the `Next steps` section.

Then inspect the key files:

```powershell
Get-Content $env:USERPROFILE\.ssh\authorized_keys
Get-Content C:\ProgramData\ssh\administrators_authorized_keys
```

If it says setup is needed, run this in the same Administrator PowerShell:

```powershell
.\windows\setup.ps1 -MacPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGcjUvhlZ9ax+Br46uEcZKL7Xa12+qwieYLvstr5tQp winver mac access"
```

Then run:

```powershell
.\windows\doctor.ps1
```

## Then Tell The Mac Side

After Windows accepts the Mac key, ask the Mac-side AI to run:

```sh
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

## Optional Later

Deep admin mode exists, but do not initialize it until basic SSH works.

Do not commit or paste the admin signing key into GitHub.

# Current Handoff

Last updated: 2026-06-23, America/Los_Angeles.

This is the plain handoff for another AI or human working on the Windows Surface.

## Current State

- Mac Tailscale is connected.
- Windows Tailscale is connected and visible as `winver`.
- Mac can Tailscale-ping `winver`.
- Mac cannot connect to `winver` port 22 yet.
- That means Windows is online, but Windows OpenSSH is not reachable yet.

## Important

Do not look for or share a Windows password for SSH.

This setup uses SSH keys:

- Mac private key stays on the Mac.
- Mac public key is copied into Windows setup.
- If SSH asks for a password, Windows SSH setup is incomplete.
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

If it says setup is needed, run this in the same Administrator PowerShell:

```powershell
.\windows\setup.ps1 -MacPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGcjUvhlZ9ax+Br46uEcZKL7Xa12+qwieYLvstr5tQp winver mac access"
```

Then run:

```powershell
.\windows\doctor.ps1
```

## Then Tell The Mac Side

After Windows doctor says the Windows side is ready, ask the Mac-side AI to run:

```sh
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

## Optional Later

Deep admin mode exists, but do not initialize it until basic SSH works.

Do not commit or paste the admin signing key into GitHub.


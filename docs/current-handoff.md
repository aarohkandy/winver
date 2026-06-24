# Current Handoff

Last updated: 2026-06-23 17:38, America/Los_Angeles.

This is the plain handoff for another AI or human working on the Windows Surface.

## Current State

- Mac Tailscale is connected.
- Windows Tailscale is connected and visible as `winver`.
- Mac can Tailscale-ping `winver`.
- Mac can connect to `winver` port 22.
- Mac SSH host trust and username have been fixed locally.
- Mac SSH now works as user `arvin`.
- Mac can start detached jobs on Windows and read logs back later.
- Long-running detached job behavior has been verified with a 12-second background job.
- Windows status reporting works and shows Tailscale plus OpenSSH running automatically.
- Earlier `Permission denied (publickey,keyboard-interactive)` was fixed by granting `SYSTEM` access to `C:\Users\arvin\.ssh\authorized_keys`.

## Important

Do not look for or share a Windows password for SSH.

This setup uses SSH keys:

- Mac private key stays on the Mac.
- Mac public key is copied into Windows setup.
- If SSH asks for a password or rejects the key, Windows SSH key setup is incomplete.
- The only password/PIN that may be needed is local Windows administrator approval.

## Verified From Mac

These commands passed from the Mac:

```sh
./bin/winver check
./bin/winver start "Write-Output 'process service detached job works'; Start-Sleep -Seconds 1"
./bin/winver logs
./bin/winver start "Write-Output 'long job started'; Start-Sleep -Seconds 12; Write-Output 'long job finished'"
./bin/winver logs
./bin/winver status
```

The verified long-job output was:

```text
exit: 0
stdout
long job started
long job finished
```

## Useful Windows Check

Run from Windows PowerShell if anything looks stale:

```powershell
cd $env:USERPROFILE\winver
git pull --ff-only
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\doctor.ps1
```

## Optional Later

Deep admin mode exists, but it is not initialized yet.

Lightweight server mode is available from the Mac:

```sh
./bin/winver server-mode
./bin/winver control balanced
```

Do not commit or paste the admin signing key into GitHub.

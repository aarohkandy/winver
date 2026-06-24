# Current Handoff

Last updated: 2026-06-23 17:34, America/Los_Angeles.

This is the plain handoff for another AI or human working on the Windows Surface.

## Current State

- Mac Tailscale is connected.
- Windows Tailscale is connected and visible as `winver`.
- Mac can Tailscale-ping `winver`.
- Mac can connect to `winver` port 22.
- Mac SSH host trust and username have been fixed locally.
- Mac previously saw `Permission denied (publickey,keyboard-interactive)`.
- Windows diagnosed that as an ACL issue on `C:\Users\arvin\.ssh\authorized_keys`: the OpenSSH service runs as `SYSTEM`, but `SYSTEM` did not have access to read the user key file.
- Windows has now granted `SYSTEM` access, verified local key login succeeds, and updated `windows/setup.ps1` plus `windows/doctor.ps1` so this is preserved and diagnosed.
- See [mac-verification-status.md](mac-verification-status.md) for the earlier Mac-side failure and Windows follow-up.

## Important

Do not look for or share a Windows password for SSH.

This setup uses SSH keys:

- Mac private key stays on the Mac.
- Mac public key is copied into Windows setup.
- If SSH asks for a password or rejects the key, Windows SSH key setup is incomplete.
- The only password/PIN that may be needed is local Windows administrator approval.

## Current Windows Verification

Windows-side checks now show:

- Tailscale service running.
- `sshd` running.
- Port 22 listening.
- Mac public key installed.
- `authorized_keys` readable by `SYSTEM`.
- Password SSH disabled.
- Tailscale-only SSH firewall rule present.

Useful Windows check:

```powershell
cd $env:USERPROFILE\winver
git pull --ff-only
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\doctor.ps1
```

## Then Tell The Mac Side

Ask the Mac-side AI to pull latest and retry:

```sh
git pull --ff-only
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

If the Mac still sees `Permission denied`, check `docs/mac-verification-status.md` and Windows OpenSSH logs next.

## Optional Later

Deep admin mode exists, but do not initialize it until basic SSH works.

Do not commit or paste the admin signing key into GitHub.

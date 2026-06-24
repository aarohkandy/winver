# Windows Current Status - Detailed

Last checked from the Windows worker: 2026-06-23 17:12:50 -07:00.

This document records the current operational state of the Windows side of `winver`. It is meant for the Mac-side AI, the Windows-side AI, and the human operator to share one accurate picture of what has already happened and what remains.

## Short Version

The Windows machine is now on Tailscale, OpenSSH is running, port 22 is listening, the Mac public SSH key is installed, password SSH login is disabled, and the firewall rule restricts SSH access to Tailscale address space.

The basic Windows worker path should be ready for the Mac to test with:

```sh
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

Deep admin mode is not initialized yet. That is optional and should wait until the normal SSH worker flow is confirmed from the Mac.

## Machine Role

This Windows machine is intended to act as the performance worker for the Mac:

```text
Mac client -> Tailscale private network -> Windows worker -> PowerShell / Codex / long jobs
```

The goal is not to expose the Windows machine to the public internet. The intended remote access path is private Tailscale networking plus SSH key authentication.

## Repository State

- Local repo path on Windows: `C:\Users\arvin\winver`
- Remote repository: `https://github.com/aarohkandy/winver.git`
- Branch: `main`
- The Windows worker setup and status docs live under `docs/`.
- The Windows setup scripts live under `windows/`.

Recent relevant commits before this document:

- `701d877 add current setup handoff`
- `3d7aee7 Fix sshd config line handling in setup`

The setup-script fix was necessary because `windows/setup.ps1` could write multiple `sshd_config` settings as one concatenated line. That produced an invalid line like:

```text
PubkeyAuthentication yesPasswordAuthentication noPermitEmptyPasswords noAllowUsers arvin
```

OpenSSH rejected that config and refused to start. The fix preserves the config lines as an array before writing them.

## Current Network State

Tailscale is installed, signed in, and running.

Observed locally:

- Tailscale service: `Running`
- Tailscale start type: `Automatic`
- Windows tailnet hostname: `winver`
- Mac tailnet hostname observed from Windows: `aaroh-mac`
- Tailscale hostname `winver` resolves locally and accepts TCP connections on port 22.

The exact Tailscale IP is intentionally not committed in this public-facing status document. Check it locally when needed:

```powershell
& 'C:\Program Files\Tailscale\tailscale.exe' ip -4
```

The Tailscale CLI may not appear on `PATH` in terminals opened before installation. The full path above works.

## Current SSH State

OpenSSH is installed and reachable.

Observed locally:

- `sshd` service: `Running`
- `sshd` start type: `Automatic`
- TCP port 22: listening locally
- `Test-NetConnection -ComputerName winver -Port 22`: succeeds from this Windows machine
- Mac public SSH key: installed in `C:\Users\arvin\.ssh\authorized_keys`
- Password SSH login: disabled
- Public-key SSH login: enabled
- SSH allowed Windows user: `arvin`

Current effective `sshd_config` lines:

```text
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
AllowUsers arvin
```

If the Mac sees a password prompt, that should be treated as a failure state. This setup is supposed to use SSH keys, not the Windows password.

## Firewall State

The Windows firewall rule for this project exists.

Observed locally:

- Rule name: `Winver-SSHD-Tailscale`
- Enabled: `True`
- Direction: inbound
- Action: allow
- Remote address scope: Tailscale address space, `100.64.0.0/10`

This means SSH should be reachable from Tailscale peers, not from arbitrary public internet hosts.

## Security Model

The Mac private SSH key stays on the Mac.

The Windows machine stores only the Mac public SSH key in `authorized_keys`. That is normal SSH behavior:

- The private key proves identity and must remain private on the Mac.
- The public key lets Windows verify that the connecting Mac has the matching private key.
- A public key alone cannot be used to log in.

Do not commit private keys, Tailscale auth keys, GitHub tokens, or admin signing keys.

## What Was Done On Windows

The following setup actions have effectively completed:

- Installed Tailscale.
- Logged Windows into the same tailnet as the Mac.
- Confirmed both `winver` and `aaroh-mac` are visible from Windows.
- Installed/configured Windows OpenSSH through `windows/setup.ps1`.
- Added the Mac public SSH key.
- Disabled SSH password authentication.
- Enabled SSH public-key authentication.
- Restricted SSH access to the Windows user `arvin`.
- Created the Tailscale-only inbound SSH firewall rule.
- Set `sshd` to automatic startup.
- Started `sshd`.
- Verified port 22 is listening.
- Verified local TCP connection to `winver:22` succeeds.

## What Remains

Mac-side verification still needs to run against this Windows worker:

```sh
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

If those commands pass, the basic Mac-to-Windows worker loop is working.

Deep admin mode remains optional and is not initialized yet. Do not initialize it until basic SSH has been verified from the Mac.

## Useful Windows Checks

Run from Windows PowerShell:

```powershell
cd $env:USERPROFILE\winver
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\doctor.ps1
Get-Service -Name Tailscale,sshd
Test-NetConnection -ComputerName winver -Port 22
& 'C:\Program Files\Tailscale\tailscale.exe' status
```

Expected important results:

- Tailscale service is running.
- Tailscale IP exists.
- OpenSSH service is running.
- Port 22 is listening.
- `authorized_keys` has one SSH public key.
- SSH firewall rule exists.
- Password SSH is disabled.
- Key SSH is enabled.

The doctor command may still say the current shell is not elevated. That is okay for normal checks. Elevation is only required for setup or admin-level changes.

## Troubleshooting Notes

If `sshd` is stopped:

```powershell
Start-Service sshd
Get-Service sshd
```

If `sshd` refuses to start, validate the config:

```powershell
& C:\Windows\System32\OpenSSH\sshd.exe -t -f C:\ProgramData\ssh\sshd_config
```

If the Mac cannot reach port 22 but Windows can:

- Confirm the Mac and Windows are both online in Tailscale.
- Confirm the Mac resolves `winver` to the Tailscale peer.
- Confirm the Windows firewall rule `Winver-SSHD-Tailscale` exists.
- Confirm Tailscale ACLs do not block Mac-to-Windows SSH.

If SSH asks for a Windows password:

- Do not share the Windows password.
- Re-check that the Mac is using `~/.ssh/winver_ed25519`.
- Re-check that the matching `.pub` key is present in `C:\Users\arvin\.ssh\authorized_keys`.
- Re-run `windows/setup.ps1` from Administrator PowerShell with the Mac public key if necessary.

## Files Worth Knowing

- `docs/current-handoff.md`: short current handoff between Mac and Windows agents.
- `docs/plain-setup-status.md`: plain-language setup guide.
- `docs/windows-side-overview.md`: earlier Windows-side overview.
- `docs/windows-current-status-detailed.md`: this detailed status document.
- `windows/setup.ps1`: Windows machine setup script.
- `windows/doctor.ps1`: Windows readiness diagnostic.
- `windows/winver.ps1`: local Windows helper wrapper.

## Current Recommendation

Ask the Mac-side AI to pull the latest repo and run the three verification commands:

```sh
git pull --ff-only
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

If that succeeds, this Windows machine is ready to act as the normal worker endpoint.

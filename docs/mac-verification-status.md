# Mac Verification Status

Last checked from the Mac: 2026-06-23 17:18 America/Los_Angeles.

This document records what happened after the Mac pulled the latest Windows-side status, plus the Windows-side follow-up.

## What Windows Asked Mac To Run

The Windows status document asked the Mac side to run:

```sh
git pull --ff-only
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

## What Happened

The Mac pulled successfully and fast-forwarded to:

```text
30bc527 Add detailed Windows status and wrapper fixes
```

The first verification command failed:

```sh
./bin/winver check
```

Initial result:

```text
Host key verification failed.
```

Mac-side fixes applied locally:

- Added `User arvin` to the Mac SSH config for `Host winver`.
- Added the current Windows SSH host key for `winver` to the Mac known-hosts file.

After those Mac-side fixes, the Mac can reach the Windows SSH server, but Windows rejects the offered Mac key:

```text
arvin@winver: Permission denied (publickey,keyboard-interactive).
```

## Current Meaning

This was no longer a Tailscale/network problem.

This was also not a Windows-password problem.

The Mac reaches `winver:22`, recognizes the Windows SSH host key, uses username `arvin`, and offers this explicit key:

```text
/Users/aaroh/.ssh/winver_ed25519
```

Fingerprint offered by the Mac:

```text
SHA256:8B4kQiBfb+zjsyUmiS4B67xC9nzFJACyE/MXOdXs/as
```

Public key that Windows should accept:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGcjUvhlZ9ax+Br46uEcZKL7Xa12+qwieYLvstr5tQp winver mac access
```

## Windows Follow-Up

Windows checked the exact public key installed in `C:\Users\arvin\.ssh\authorized_keys`.

The installed key fingerprint matched the Mac-side fingerprint exactly:

```text
SHA256:8B4kQiBfb+zjsyUmiS4B67xC9nzFJACyE/MXOdXs/as
```

Windows then tested a throwaway local key through the same `authorized_keys` path. It failed with the same public-key rejection until the key file ACL was updated to allow `SYSTEM` to read it.

After granting `SYSTEM` access to:

```text
C:\Users\arvin\.ssh
C:\Users\arvin\.ssh\authorized_keys
```

the throwaway local key successfully logged in as:

```text
laptop-gqhrbu3i\arvin
```

The throwaway key was removed after the test.

## Windows Fix Applied

`windows/setup.ps1` now grants `SYSTEM` access to the user `.ssh` directory and `authorized_keys` file.

`windows/doctor.ps1` now reports whether `SYSTEM` can read `authorized_keys`.

The Mac side should pull latest and retry:

```sh
git pull --ff-only
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

## If It Still Fails

On Windows, check the exact key files OpenSSH may use:

```powershell
cd $env:USERPROFILE\winver
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\doctor.ps1
```

Then inspect both key files:

```powershell
Get-Content $env:USERPROFILE\.ssh\authorized_keys
Get-Content C:\ProgramData\ssh\administrators_authorized_keys
```

At least the key file that OpenSSH is actually using for user `arvin` must contain exactly:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGcjUvhlZ9ax+Br46uEcZKL7Xa12+qwieYLvstr5tQp winver mac access
```

Also validate the server config:

```powershell
& C:\Windows\System32\OpenSSH\sshd.exe -t -f C:\ProgramData\ssh\sshd_config
Get-Content C:\ProgramData\ssh\sshd_config
```

Things to look for:

- `PubkeyAuthentication yes`
- `PasswordAuthentication no`
- `AllowUsers arvin`
- whether a `Match Group administrators` block overrides `AuthorizedKeysFile`

If `arvin` is an Administrator, Windows OpenSSH may use:

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

instead of:

```text
C:\Users\arvin\.ssh\authorized_keys
```

So both content and ACL permissions on `administrators_authorized_keys` matter.

## Mac Commands Already Run

These now reach Windows but fail at key authentication:

```sh
ssh -o BatchMode=yes -o ConnectTimeout=8 winver "hostname"
```

Important debug summary:

```text
Authenticating to winver:22 as 'arvin'
Host 'winver' is known and matches the ED25519 host key.
Offering public key: /Users/aaroh/.ssh/winver_ed25519 ED25519 SHA256:8B4kQiBfb+zjsyUmiS4B67xC9nzFJACyE/MXOdXs/as explicit
arvin@winver: Permission denied (publickey,keyboard-interactive).
```


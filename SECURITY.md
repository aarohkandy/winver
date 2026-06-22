# Security

`winver` is designed for a public GitHub repo. Public means public: assume every file here can be read by anyone.

## What belongs in Git

- setup scripts
- helper commands
- documentation
- examples with fake values
- tests

## What never belongs in Git

- SSH private keys
- Tailscale auth keys
- GitHub tokens
- Windows passwords
- machine-specific local config
- logs containing private output

## Default access model

1. Tailscale creates the private network path.
2. Windows OpenSSH listens on the Surface.
3. The Windows firewall allows SSH only from Tailscale IP space.
4. OpenSSH accepts only the dedicated Mac SSH key.
5. Password SSH is disabled.
6. Deep admin apply actions require a separate local admin signing key.

That means someone needs both access to your tailnet and your Mac's private SSH key to log in.
Changing server/firmware-adjacent settings additionally requires the admin signing key.

## Deep admin controls

Run this on the Mac:

```sh
./mac/setup-admin-key.sh
```

Run the printed command on the Surface from elevated PowerShell. The key is stored at:

```text
%ProgramData%\winver\admin-signing.key
```

with Administrators/SYSTEM ACLs. Do not commit it.

Apply-level admin actions are allowlisted, signed, snapshotted, and audited. Raw admin commands are rejected unless you use the explicit `admin-shell --apply --force` path.

## Firmware controls

`winver uefi` does not flash firmware or enroll SEMM remotely. It inventories and creates a local plan. SEMM enrollment and UEFI lock changes require physical presence at the Surface and should not be attempted until BitLocker recovery and unenroll packages are verified.

## If something feels wrong

On the Surface, run PowerShell as Administrator:

```powershell
.\windows\doctor.ps1
```

To disable SSH immediately:

```powershell
Stop-Service sshd
Set-Service sshd -StartupType Disabled
```

To remove the auto-update task:

```powershell
.\windows\agent.ps1 -Uninstall
```

To disable remote winver access locally:

```powershell
.\windows\admin\break-glass.ps1
```

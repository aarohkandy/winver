# Plain Setup Status

Use this when setup gets confusing.

## What is already true when Tailscale shows both machines

If the Mac Tailscale app shows both:

- `aaroh-mac`
- `winver`

then the private network is working.

That does not automatically mean SSH is working. SSH is a separate Windows service.

## Password vs key

You do not share a Windows password with the Mac.

The Mac created an SSH key pair:

- private key: stays on the Mac forever
- public key: copied once into Windows setup

If the Mac asks for an SSH password, treat that as a setup failure. It means Windows does not have the Mac public key yet, or OpenSSH is not configured/running.

If the Mac says `Permission denied (publickey,keyboard-interactive)`, the network is working but Windows did not accept the key. One known Windows-side cause is the OpenSSH service lacking `SYSTEM` access to `C:\Users\arvin\.ssh\authorized_keys`. The latest `windows/setup.ps1` fixes that ACL, and the latest `windows/doctor.ps1` reports it.

The only password/PIN you may need is the local Windows admin approval required to run setup.

## What to run on Windows

Open PowerShell as Administrator:

```powershell
cd $env:USERPROFILE\winver
git pull --ff-only
Set-ExecutionPolicy -Scope Process Bypass -Force
.\windows\doctor.ps1
```

Read the `Next steps` section. It should tell you exactly what is missing.

## What to run on Mac

After Windows setup says it is ready:

```sh
./bin/winver check
./bin/winver start "Write-Output hello from winver"
./bin/winver logs
```

## Current most likely issue

If Tailscale can ping `winver` but the Mac cannot connect to port 22, then Windows is online but OpenSSH is not reachable yet.

The usual fix is to run the Windows setup script from Administrator PowerShell with the Mac public key.

Current exact setup command:

```powershell
.\windows\setup.ps1 -MacPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGcjUvhlZ9ax+Br46uEcZKL7Xa12+qwieYLvstr5tQp winver mac access"
```

If the Mac can connect to port 22 but gets `Permission denied`, pull the latest repo on Windows and rerun setup so the `SYSTEM` ACL fix is applied:

```powershell
git pull --ff-only
.\windows\setup.ps1 -MacPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGcjUvhlZ9ax+Br46uEcZKL7Xa12+qwieYLvstr5tQp winver mac access"
.\windows\doctor.ps1
```

See [current-handoff.md](current-handoff.md) for the current handoff between the Mac-side and Windows-side setup agents.

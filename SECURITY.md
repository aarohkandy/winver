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

That means someone needs both access to your tailnet and your Mac's private SSH key to log in.

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


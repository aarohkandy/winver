# Deep Control Mode

Deep Control Mode gives `winver` more control without making every remote login equally dangerous.

## Control tiers

1. Worker tier: normal `winver run`, `start`, `logs`, and `codex`.
2. Admin tier: signed, audited Windows controls through `winver admin`.
3. UEFI tier: inventory and planning only; firmware enrollment still requires physical presence.

## First-time admin setup

The dashboard cooling buttons need this setup. If the localhost page says:

```text
Cooling controls need one Windows setup step first: run the elevated init-admin command on the Surface. Logs, Pull, Refresh, and Stop still work.
```

run the steps below. Logs, Pull, Refresh, and Stop do not need the admin key; only signed admin actions such as cooling, lockdown, unlock, reboot, and shutdown do.

On the Mac:

```sh
./mac/setup-admin-key.sh
```

On the Surface, in an elevated PowerShell window:

```powershell
.\windows\admin\init-admin.ps1 -AdminKey "PASTE_THE_KEY_FROM_THE_MAC"
```

The Mac helper prints the exact command with the real key. Do not commit or paste that real key into GitHub. You can also pass `-AdminKey` to `windows\setup.ps1` during first setup.

## Commands

```sh
winver admin status
winver admin power
winver admin services
winver admin bitlocker
winver admin tpm
winver admin server-profile --dry-run
winver admin server-profile --apply
winver admin lockdown --dry-run
winver admin lockdown --apply
winver admin cooling --profile max --dry-run
winver admin cooling --profile max --apply
winver admin cooling --profile cool --apply
winver admin cooling --profile balanced --apply
winver admin cooling --profile quiet --apply
winver admin unlock --apply
winver admin rollback --dry-run
winver admin rollback --apply
winver admin export-recovery --apply
winver admin break-glass --apply
winver uefi inventory
winver uefi plan
```

`admin-shell` exists for explicit raw control, but requires both `--apply` and `--force`:

```sh
winver admin-shell --apply --force "Get-Service sshd"
```

## What gets logged

Admin actions write JSON-lines audit events under:

```text
%ProgramData%\winver\audit\admin.jsonl
```

Apply-level actions also write snapshots and rollback helpers under:

```text
%ProgramData%\winver\snapshots
```

## Lockdown mode

`lockdown` is the spicy server mode:

- no plugged-in sleep
- display turns off quickly
- high-performance AC profile
- AC processor min/max set to 100 percent
- active cooling preferred where Windows exposes the setting
- wake timers allowed
- lid close ignored while plugged in
- sshd and Tailscale kept automatic and started

Use it when the Surface is plugged in, ventilated, and doing worker-box things. Use `unlock` when you want to use it directly again:

```sh
winver admin unlock --apply
```

Hardware thermal throttling still applies. This does not override firmware thermal protection or touch fan curves.

## Cooling profiles

Surface fan curves are firmware-controlled and are not exposed through a stable safe Windows API. `winver admin cooling` controls the closest safe equivalents: Windows power scheme, active/passive cooling policy, processor min/max state, processor boost mode, and energy-performance preference.

Profiles:

- `max`: let it run hot and fast. High performance, active cooling, CPU 100/100, aggressive boost.
- `cool`: keep it awake and reachable, but reduce sustained heat. Active cooling, CPU max around 85 percent, boost disabled.
- `balanced`: server-friendly normal mode. Active cooling, CPU 5/100, efficient boost.
- `quiet`: laptop-ish quiet mode. Passive cooling, CPU max around 65 percent, boost disabled.

Preview first:

```sh
winver admin cooling --profile max --dry-run
```

Apply with signing and audit:

```sh
winver admin cooling --profile max --apply
```

Rollback to the most recent snapshot helper:

```sh
winver admin rollback --apply
```

## UEFI / SEMM

`winver uefi` does not write firmware settings. It inventories the Surface and writes a SEMM/Surface IT Toolkit checklist.

SEMM enrollment or UEFI lock changes must be done while physically present at the Surface. The Microsoft flow requires certificate-based SEMM packages and physical confirmation during enrollment.

## Tailscale hardening

Use `docs/tailscale-acl-example.json` as a starting point for allowing only a tagged Mac/client to reach the tagged Surface on port 22. This project uses Windows OpenSSH over Tailscale, not Tailscale SSH on Windows.

Tailnet Lock is worth enabling once the workflow is stable because it makes device admission harder to spoof or silently alter.

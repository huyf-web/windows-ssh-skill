---
name: vmware-ssh-connect
description: Connect from a Windows host to a running VMware Workstation or Player Linux guest over SSH. Use when Codex needs to discover a VMware VM by name or VMX path, diagnose NAT/VMnet networking, bring up a disconnected Linux interface such as ens33 through VMware Tools, install a temporary SSH public key for a guest user, and verify SSH access without an interactive password prompt.
---

# VMware SSH Connect

Use this skill to establish SSH access from Windows to a running VMware Linux guest when the VM is visible in VMware but ordinary `ssh user@ip` is not yet working.

## Workflow

1. Locate the running VM:
   - Run `vmrun list`.
   - Match the requested display name or VMX path.
   - If the name is unknown, inspect the VMX for `displayName`, `guestOS`, and `ethernet*.connectionType`.

2. Confirm VMware Tools and network state:
   - Run `vmrun -T ws checkToolsState "<vmx>"`.
   - Run `vmrun -T ws getGuestIPAddress "<vmx>"`.
   - If no IP is reported, inspect DHCP leases at `C:\ProgramData\VMware\vmnetdhcp.leases` and the VMX MAC address.

3. If the Linux interface is disconnected:
   - Use guest credentials with `vmrun -T ws -gu <user> -gp <password>`.
   - Run `nmcli device status` or `/sbin/ip addr` inside the guest.
   - Bring the interface up with `nmcli device connect <interface>`, either as root or through `sudo`.
   - Re-run `getGuestIPAddress` and ping the guest IP from the Windows host.

4. Verify SSH service:
   - Inside guest, confirm `sshd` is active and listening: `systemctl status sshd` and `ss -lntp`.
   - Confirm firewalld allows `ssh`: `firewall-cmd --list-all`.

5. Avoid interactive password prompts:
   - Generate a temporary SSH key under the current workspace, never inside the skill directory.
   - Copy the `.pub` file into the guest using `CopyFileFromHostToGuest`.
   - Append it to `/home/<user>/.ssh/authorized_keys`.
   - Verify with `ssh -i <key> -o BatchMode=yes <user>@<ip> "whoami; hostname; pwd"`.

## Recommended Script

Prefer `scripts/connect-vmware-ssh.ps1` for the common Windows + VMware Workstation flow:

```powershell
.\scripts\connect-vmware-ssh.ps1 -VmName IC_EDA -GuestUser ICer -GuestPassword 2020 -Interface ens33
```

Use `-VmxPath` instead of `-VmName` when the VMX path is already known. The script creates keys in `.codex_tmp` by default, copies only the public key into the guest, and prints a ready-to-use SSH command.

## Guardrails

- Do not commit generated private keys, passwords, logs, or copied guest diagnostics.
- Do not reset or power-cycle a running VM unless the user explicitly asks.
- Prefer `vmrun -T ws` for guest operations on Windows, but try plain `vmrun list` if `vmrun -T ws list` does not show a VM that VMware Workstation clearly has running.
- Treat NAT IPs as dynamic; re-discover the IP each session.
- If Windows networking commands such as `Get-NetNeighbor` fail with access denied, use `arp -a`, VMware DHCP leases, or guest-side `/sbin/ip addr` instead.
- If `vmrun` reports `not powered on` while SSH still works, continue through SSH and treat VMware Tools control as temporarily unreliable.

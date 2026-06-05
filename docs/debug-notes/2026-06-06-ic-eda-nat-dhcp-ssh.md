# 2026-06-06 IC_EDA VMware NAT/DHCP SSH Debug Note

## Scenario

- Host: Windows with VMware Workstation 16.2.4.
- VM: `IC_EDA`
- VMX: `D:\BaiduNetdiskDownload\IC_EDA_20211016\IC_EDA_20211006\IC_EDA_20211006\IC_EDA.vmx`
- Guest: CentOS 7.9
- Guest users verified through VMware Tools: `ICer / 2020`, `root / 2020`
- Guest NIC: `ens33`
- VM NIC config: NAT, MAC `00:0c:29:67:fe:8c`

## Symptoms

- `vmrun -T ws checkToolsState "<vmx>"` returned `running` or `installed`.
- `vmrun -T ws getGuestIPAddress "<vmx>"` returned `Error: Unable to get the IP address`.
- Guest-side `nmcli device status` showed `ens33` as unavailable.
- Guest-side `/sbin/ip -4 addr show ens33` showed no IPv4 address.
- Guest-side `nmcli device connect ens33` failed with `device has no carrier`.
- Guest `dmesg` showed the last NIC event as `e1000: ens33 NIC Link is Down`.
- `vmrun connectNamedDevice "<vmx>" ethernet0` returned success but did not produce a guest-side link-up event.

## Root Cause

The Windows host VMware network services were stopped:

```powershell
Get-Service | Where-Object { $_.Name -match 'VMware|VMnet|VMNat|VMnetDHCP' -or $_.DisplayName -match 'VMware' } |
  Select-Object Name,Status,DisplayName
```

Observed stopped services:

- `VMnetDHCP` / `VMware DHCP Service`
- `VMware NAT Service`

With NAT/DHCP stopped, the guest NIC stayed at `NO-CARRIER` or could not obtain a NAT lease even after the VMware UI network adapter was set to `Connected`.

## Fix

Start the host services with elevated PowerShell:

```powershell
Start-Service -Name VMnetDHCP
Start-Service -Name 'VMware NAT Service'
Get-Service -Name VMnetDHCP,'VMware NAT Service' | Select-Object Name,Status,DisplayName
```

Then reconnect the guest NIC:

```powershell
D:\VMWARE16\vmrun.exe -T ws -gu root -gp 2020 runProgramInGuest "<vmx>" /bin/bash -lc "nmcli device connect ens33 >/tmp/codex_after_services.txt 2>&1 || true; sleep 8; nmcli device status >> /tmp/codex_after_services.txt 2>&1; /sbin/ip -4 addr show ens33 >> /tmp/codex_after_services.txt 2>&1"
D:\VMWARE16\vmrun.exe -T ws getGuestIPAddress "<vmx>"
```

Successful result:

- `getGuestIPAddress`: `192.168.244.128`
- `ens33`: `BROADCAST,MULTICAST,UP,LOWER_UP`
- IPv4: `192.168.244.128/24`

## SSH Key Installation Notes

The first inline `runProgramInGuest ... /bin/bash -lc "home_dir=$(getent ...)"` attempt failed because local PowerShell expanded `$()` before the command reached the guest. Avoid complex inline shell with PowerShell interpolation.

Robust method:

1. Generate a temporary key in the current workspace, not inside the skill repo:

   ```powershell
   New-Item -ItemType Directory -Force -Path .\.codex_tmp | Out-Null
   ssh-keygen --% -t ed25519 -N "" -f .\.codex_tmp\vmware_ssh_key
   ```

2. Copy the public key to the guest:

   ```powershell
   D:\VMWARE16\vmrun.exe -T ws -gu root -gp 2020 CopyFileFromHostToGuest "<vmx>" .\.codex_tmp\vmware_ssh_key.pub /tmp/codex_vmware_ssh_key.pub
   ```

3. Prefer copying a small guest script and running it with `/bin/bash`, instead of passing a long quoted shell program through PowerShell:

   ```bash
   #!/bin/bash
   set -e
   user=ICer
   home_dir=$(getent passwd "$user" | cut -d: -f6)
   install -d -m 700 -o "$user" -g "$user" "$home_dir/.ssh"
   touch "$home_dir/.ssh/authorized_keys"
   grep -qxF -f /tmp/codex_vmware_ssh_key.pub "$home_dir/.ssh/authorized_keys" || cat /tmp/codex_vmware_ssh_key.pub >> "$home_dir/.ssh/authorized_keys"
   chmod 600 "$home_dir/.ssh/authorized_keys"
   chown "$user:$user" "$home_dir/.ssh/authorized_keys"
   restorecon -Rv "$home_dir/.ssh" >/tmp/codex_restorecon.txt 2>&1 || true
   ```

4. Verify:

   ```powershell
   ssh -i .\.codex_tmp\vmware_ssh_key -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no ICer@192.168.244.128 "echo CONNECTED_OK; whoami; hostname; pwd; /sbin/ip -4 addr show ens33"
   ```

Successful verification:

```text
CONNECTED_OK
ICer
IC_EDA
/home/ICer
inet 192.168.244.128/24 ...
```

## Pre-Connection Checklist Added To Skill

Before running the normal connection flow:

1. Read the latest files under `docs/debug-notes/`.
2. Check host VMware services first when NAT guests have no IP:

   ```powershell
   Get-Service -Name VMnetDHCP,'VMware NAT Service'
   ```

3. If either service is stopped, start it with elevated PowerShell before debugging guest SSH.
4. If guest-side key installation needs shell variables such as `$(...)`, use a copied guest script rather than a long inline command string.

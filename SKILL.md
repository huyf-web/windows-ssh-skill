---
name: vmware-ssh-connect
description: 从 Windows 宿主机通过 SSH 连接正在运行的 VMware Workstation 或 Player Linux 虚拟机。适用于需要按虚拟机名称或 VMX 路径发现 VMware 虚拟机、诊断 NAT/VMnet 网络、通过 VMware Tools 拉起 ens33 等断开的 Linux 网卡、为 guest 用户安装临时 SSH 公钥，并在无需交互式输入密码的情况下验证 SSH 访问的场景。
---

# VMware SSH Connect

当虚拟机在 VMware 中已经启动，但普通的 `ssh user@ip` 还连不上时，使用这个 skill 从 Windows 宿主机建立到 VMware Linux guest 的 SSH 连接。

## 工作流程

1. 定位正在运行的虚拟机：
   - 运行 `vmrun list`。
   - 按用户给出的显示名称或 VMX 路径匹配虚拟机。
   - 如果名称不明确，读取 VMX 文件中的 `displayName`、`guestOS` 和 `ethernet*.connectionType`。

2. 确认 VMware Tools 和网络状态：
   - 运行 `vmrun -T ws checkToolsState "<vmx>"`。
   - 运行 `vmrun -T ws getGuestIPAddress "<vmx>"`。
   - 如果没有返回 IP，检查 `C:\ProgramData\VMware\vmnetdhcp.leases` 里的 DHCP 租约，并对照 VMX 中的 MAC 地址。

3. 如果 Linux 网卡处于断开状态：
   - 使用 guest 凭据执行 `vmrun -T ws -gu <user> -gp <password>`。
   - 在 guest 内运行 `nmcli device status` 或 `/sbin/ip addr`。
   - 用 root 或 `sudo` 执行 `nmcli device connect <interface>` 拉起网卡。
   - 重新运行 `getGuestIPAddress`，并从 Windows 宿主机 ping guest IP。

4. 验证 SSH 服务：
   - 在 guest 内确认 `sshd` 已启动并监听端口：`systemctl status sshd` 和 `ss -lntp`。
   - 确认 firewalld 放行 `ssh`：`firewall-cmd --list-all`。

5. 避免交互式输入密码：
   - 在当前工作区生成临时 SSH key，不要生成到 skill 目录里。
   - 使用 `CopyFileFromHostToGuest` 将 `.pub` 公钥复制到 guest。
   - 将公钥追加到 `/home/<user>/.ssh/authorized_keys`。
   - 用 `ssh -i <key> -o BatchMode=yes <user>@<ip> "whoami; hostname; pwd"` 验证连接。

## 推荐脚本

常见的 Windows + VMware Workstation 场景优先使用 `scripts/connect-vmware-ssh.ps1`：

```powershell
.\scripts\connect-vmware-ssh.ps1 -VmName IC_EDA -GuestUser ICer -GuestPassword 2020 -Interface ens33
```

如果已经知道 VMX 路径，使用 `-VmxPath` 替代 `-VmName`。脚本默认在 `.codex_tmp` 中创建 key，只把公钥复制进 guest，并打印可直接使用的 SSH 命令。

## 注意事项

- 不要提交生成的私钥、密码、日志或从 guest 复制出来的诊断文件。
- 除非用户明确要求，不要重置、关机或重启正在运行的虚拟机。
- Windows 上的 guest 操作优先使用 `vmrun -T ws`；如果 `vmrun -T ws list` 看不到 VMware Workstation 中明确正在运行的虚拟机，可以尝试普通的 `vmrun list`。
- NAT IP 是动态的，每次会话都要重新发现 IP。
- 如果 `Get-NetNeighbor` 等 Windows 网络命令因为权限不足失败，改用 `arp -a`、VMware DHCP 租约或 guest 内的 `/sbin/ip addr`。
- 如果 `vmrun` 报告 `not powered on`，但 SSH 仍然可用，继续通过 SSH 操作，并把 VMware Tools 控制通道视为暂时不可靠。

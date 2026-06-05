param(
    [string]$VmName,
    [string]$VmxPath,
    [string]$VmrunPath = "D:\VMWARE16\vmrun.exe",
    [Parameter(Mandatory = $true)][string]$GuestUser,
    [Parameter(Mandatory = $true)][string]$GuestPassword,
    [string]$SshUser = $GuestUser,
    [string]$Interface = "ens33",
    [string]$KeyPath = ".\.codex_tmp\vmware_ssh_key",
    [int]$ConnectTimeout = 8
)

$ErrorActionPreference = "Stop"

function Show-DebugNotes {
    $skillRoot = Split-Path -Parent $PSScriptRoot
    $debugDir = Join-Path $skillRoot "docs\debug-notes"
    if (-not (Test-Path -LiteralPath $debugDir)) {
        return
    }

    $latest = Get-ChildItem -LiteralPath $debugDir -Filter "*.md" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        return
    }

    Write-Host "Preflight debug note: $($latest.FullName)"
    Write-Host "Read this note before connecting when NAT/DHCP, NO-CARRIER, or SSH key auth fails."
}

function Show-HostNetworkServices {
    $services = Get-Service -Name "VMnetDHCP", "VMware NAT Service" -ErrorAction SilentlyContinue
    if (-not $services) {
        Write-Warning "VMware NAT/DHCP services were not found on this host."
        return
    }

    Write-Host "VMware host network services:"
    $services | Select-Object Name, Status, DisplayName | Format-Table -AutoSize | Out-String | Write-Host

    $stopped = @($services | Where-Object { $_.Status -ne "Running" })
    if ($stopped.Count -gt 0) {
        Write-Warning "One or more VMware NAT/DHCP services are not running. Start them before debugging guest SSH/IP issues."
        Write-Warning "Elevated PowerShell: Start-Service -Name VMnetDHCP; Start-Service -Name 'VMware NAT Service'"
    }
}

function Invoke-Vmrun {
    param([string[]]$Args)
    & $VmrunPath @Args
    if ($LASTEXITCODE -ne 0) {
        throw "vmrun failed: $($Args -join ' ')"
    }
}

if (-not (Test-Path -LiteralPath $VmrunPath)) {
    throw "vmrun not found: $VmrunPath"
}

Show-DebugNotes
Show-HostNetworkServices

if (-not $VmxPath) {
    $running = & $VmrunPath list
    $candidates = @($running | Where-Object { $_ -match "\.vmx\s*$" } | ForEach-Object { $_.Trim() })
    $matches = $candidates
    if ($VmName) {
        $matches = @($candidates | Where-Object {
            $pathMatch = $_ -like "*$VmName*"
            $displayMatch = $false
            if (Test-Path -LiteralPath $_) {
                $displayLine = Select-String -LiteralPath $_ -Pattern '^\s*displayName\s*=\s*"' -ErrorAction SilentlyContinue | Select-Object -First 1
                $displayMatch = $displayLine -and ($displayLine.Line -like "*$VmName*")
            }
            $pathMatch -or $displayMatch
        })
    }
    if ($matches.Count -ne 1) {
        throw "Expected exactly one running VM match, found $($matches.Count). Pass -VmxPath explicitly."
    }
    $VmxPath = $matches[0]
}

Write-Host "VMX: $VmxPath"
Write-Host "Tools: $(& $VmrunPath -T ws checkToolsState $VmxPath)"

& $VmrunPath -T ws connectNamedDevice $VmxPath "ethernet0" | Out-Null

$guestScript = @"
set -e
if command -v nmcli >/dev/null 2>&1; then
  nmcli device connect '$Interface' >/dev/null 2>&1 || true
fi
/sbin/ip -4 addr show '$Interface' >/tmp/codex_vmware_ssh_ip.txt 2>&1 || true
systemctl is-active sshd >/tmp/codex_vmware_ssh_sshd.txt 2>&1 || true
"@

& $VmrunPath -T ws -gu $GuestUser -gp $GuestPassword runProgramInGuest $VmxPath /bin/bash -lc $guestScript | Out-Null

$ip = $null
for ($i = 0; $i -lt 12; $i++) {
    $candidate = & $VmrunPath -T ws getGuestIPAddress $VmxPath 2>$null
    if ($LASTEXITCODE -eq 0 -and $candidate -match "^\d+\.\d+\.\d+\.\d+$") {
        $ip = $candidate.Trim()
        break
    }
    Start-Sleep -Seconds 2
}
if (-not $ip) {
    throw "Unable to get guest IP. Check guest network state with nmcli device status."
}

Write-Host "Guest IP: $ip"
if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet)) {
    Write-Warning "Guest did not answer ping, but SSH may still work."
}

$keyDir = Split-Path -Parent $KeyPath
if ($keyDir) {
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
}
if (-not (Test-Path -LiteralPath $KeyPath)) {
    ssh-keygen --% -t ed25519 -N "" -f .\.codex_tmp\vmware_ssh_key | Out-Null
    if ($KeyPath -ne ".\.codex_tmp\vmware_ssh_key") {
        Move-Item -LiteralPath ".\.codex_tmp\vmware_ssh_key" -Destination $KeyPath
        Move-Item -LiteralPath ".\.codex_tmp\vmware_ssh_key.pub" -Destination "$KeyPath.pub"
    }
}

Invoke-Vmrun @("-T", "ws", "-gu", $GuestUser, "-gp", $GuestPassword, "CopyFileFromHostToGuest", $VmxPath, "$KeyPath.pub", "/tmp/codex_vmware_ssh_key.pub")

$authScript = @"
set -e
home_dir=`$(getent passwd '$SshUser' | cut -d: -f6)
mkdir -p "`$home_dir/.ssh"
touch "`$home_dir/.ssh/authorized_keys"
grep -qxF -f /tmp/codex_vmware_ssh_key.pub "`$home_dir/.ssh/authorized_keys" || cat /tmp/codex_vmware_ssh_key.pub >> "`$home_dir/.ssh/authorized_keys"
chmod 700 "`$home_dir/.ssh"
chmod 600 "`$home_dir/.ssh/authorized_keys"
chown -R '$SshUser':'$SshUser' "`$home_dir/.ssh" 2>/dev/null || true
"@

Invoke-Vmrun @("-T", "ws", "-gu", $GuestUser, "-gp", $GuestPassword, "runProgramInGuest", $VmxPath, "/bin/bash", "-lc", $authScript)

$sshArgs = @(
    "-i", $KeyPath,
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=$ConnectTimeout",
    "-o", "StrictHostKeyChecking=no",
    "$SshUser@$ip",
    "echo CONNECTED_OK; whoami; hostname; pwd; /sbin/ip -4 addr show '$Interface'"
)
& ssh @sshArgs
if ($LASTEXITCODE -ne 0) {
    throw "SSH verification failed."
}

Write-Host ""
Write-Host "SSH command:"
Write-Host "ssh -i $KeyPath $SshUser@$ip"

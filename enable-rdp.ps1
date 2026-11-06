# enable-rdp.ps1 - allow Remote Desktop from the configured subnet.
#
# Run as a RunOnce entry by autounattend.xml when --rdp was given.
# The RunOnce entry removes itself after the run.
#
# Log: C:\setup-rdp.log
#
# Placeholders replaced by make-install-iso.sh:
#   @@SUBNET@@
#
# Written to the ISO with CRLF line endings, see set-network.ps1.

$ErrorActionPreference = 'Continue'

$log = 'C:\setup-rdp.log'
function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $log -Value $line
    Write-Host $line
}

Write-Log '=== enable-rdp.ps1 started ==='

$subnet = '@@SUBNET@@'
$name   = 'RDP from @@SUBNET@@'
$ts     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$rdp    = "$ts\WinStations\RDP-Tcp"

# Server media ships with RDP off: registry flag, service manual, all
# inbound rules disabled (Remote Desktop group).
Write-Log 'setting fDenyTSConnections=0'
Set-ItemProperty -Path $ts -Name fDenyTSConnections -Value 0

# Keep NLA. Without it the credential prompt is reachable unauthenticated.
Write-Log 'setting UserAuthentication=1'
Set-ItemProperty -Path $rdp -Name UserAuthentication -Value 1

Write-Log 'starting TermService'
Set-Service TermService -StartupType Automatic
Start-Service TermService

# The stock Remote Desktop rules accept any source; this one does not.
Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule

New-NetFirewallRule -DisplayName $name `
    -Protocol TCP -LocalPort 3389 `
    -Direction Inbound -Action Allow `
    -RemoteAddress $subnet | Out-Null

Write-Log ("rule added: TCP 3389 from {0}" -f $subnet)
Write-Log ("fDenyTSConnections={0} TermService={1}" -f `
    (Get-ItemProperty -Path $ts -Name fDenyTSConnections).fDenyTSConnections, `
    (Get-Service TermService).Status)
Write-Log '=== enable-rdp.ps1 finished ==='

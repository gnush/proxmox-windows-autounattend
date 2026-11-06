# enable-ping.ps1 - allow ICMPv4 echo from the configured subnet.
#
# Run as a RunOnce entry by autounattend.xml when --ping was given.
# The RunOnce entry removes itself after the run.
#
# Log: C:\setup-ping.log
#
# Placeholders replaced by make-install-iso.sh:
#   @@SUBNET@@
#
# Written to the ISO with CRLF line endings, see set-network.ps1.

$ErrorActionPreference = 'Continue'

$log = 'C:\setup-ping.log'
function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $log -Value $line
    Write-Host $line
}

Write-Log '=== enable-ping.ps1 started ==='

$subnet = '@@SUBNET@@'
$name   = 'ICMPv4 echo from @@SUBNET@@'

# A fresh install enables the firewall with all inbound ICMP rules off.
# Only echo (type 8) from the subnet, so the rule does not widen reach.
Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule

New-NetFirewallRule -DisplayName $name `
    -Protocol ICMPv4 -IcmpType 8 `
    -Direction Inbound -Action Allow `
    -RemoteAddress $subnet | Out-Null

Write-Log ("rule added: {0} from {1}" -f 'ICMPv4 echo request', $subnet)
Write-Log '=== enable-ping.ps1 finished ==='

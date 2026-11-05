# set-network.ps1 - applies the static IPv4 configuration of the installation.
#
# Run as a RunOnce entry on the second logon, staged by autounattend.xml.
# The RunOnce entry removes itself after the run.
#
# Log: C:\setup-network.log
#
# Placeholders replaced by make-install-iso.sh:
#   @@IP@@ @@PREFIX@@ @@GW@@ @@DNS1@@ @@DNS2@@
#
# Written to the ISO with CRLF line endings: Windows PowerShell 5.1 and
# notepad both handle LF badly, and the file is edited on the ISO.

$ErrorActionPreference = 'Continue'

$log = 'C:\setup-network.log'
function Write-Log($msg) {
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $log -Value $line
    Write-Host $line
}

Write-Log '=== set-network.ps1 started ==='

$ip     = '@@IP@@'
$prefix = '@@PREFIX@@'
$gw     = '@@GW@@'
$dns1   = '@@DNS1@@'
$dns2   = '@@DNS2@@'

# Take the adapter that has a cable connection. After the reboot and with
# the guest tools installed, that is the VirtIO NIC (NetKVM).
$adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
if (-not $adapter) {
    $adapter = Get-NetAdapter | Select-Object -First 1
}

if (-not $adapter) {
    Write-Log 'ERROR: no network adapter found.'
    Get-NetAdapter | ForEach-Object { Write-Log ("  adapter: {0} / {1}" -f $_.Name, $_.Status) }
    exit 1
}

$name = $adapter.Name
Write-Log ("adapter: {0} ({1})" -f $name, $adapter.InterfaceDescription)

# Disable DHCP first. While the adapter is on DHCP, "netsh interface ip set
# address" does NOT apply the static address and still reports success - the
# adapter stays on APIPA (169.254.x.x). Do not use netsh here.
Write-Log 'disabling DHCP on the adapter'
Set-NetIPInterface -InterfaceAlias $name -Dhcp Disabled
Start-Sleep -Seconds 2

# Remove an existing APIPA address, otherwise it stays next to the new one.
Write-Log 'removing existing IPv4 addresses'
Remove-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue

Write-Log ("setting IP {0}/{1} gateway {2}" -f $ip, $prefix, $gw)
New-NetIPAddress -InterfaceAlias $name -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw |
    Out-Null

Write-Log ("setting DNS {0}, {1}" -f $dns1, $dns2)
Set-DnsClientServerAddress -InterfaceAlias $name -ServerAddresses @($dns1, $dns2)

Start-Sleep -Seconds 3
Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Log ("active IPv4: {0}/{1}" -f $_.IPAddress, $_.PrefixLength) }

Write-Log '=== set-network.ps1 finished ==='

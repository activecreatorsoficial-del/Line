# Read-only report. Does not contact external services or change settings.
$ErrorActionPreference = 'Stop'
function Count-Ipv6Prefix($Addresses, [int]$Mask, [int]$Prefix) {
    @($Addresses | Where-Object {
        $ip = $null
        [Net.IPAddress]::TryParse($_.IPAddress, [ref]$ip) -and
        $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6 -and
        (($ip.GetAddressBytes()[0] -band $Mask) -eq $Prefix)
    }).Count
}

Write-Output 'Line - read-only network report'
Write-Output 'No IP addresses, passwords, network changes or external requests.'
try {
    $bindings = @(Get-NetAdapterBinding -ComponentID ms_tcpip6)
    foreach ($binding in $bindings) {
        Write-Output ("IPv6 on adapter '{0}': {1}" -f $binding.Name, $binding.Enabled)
    }
    $addresses = @(Get-NetIPAddress -AddressFamily IPv6 | Where-Object AddressState -eq 'Preferred')
    Write-Output ('Preferred global-scope IPv6 addresses (2000::/3): ' + (Count-Ipv6Prefix $addresses 224 32))
    Write-Output ('Preferred private IPv6 addresses (fc00::/7): ' + (Count-Ipv6Prefix $addresses 254 252))
    $routes = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue)
    Write-Output ('Default IPv6 routes: ' + $routes.Count)
    $transition = @($addresses | Where-Object InterfaceAlias -Match '(teredo|6to4|isatap)')
    Write-Output ('Preferred addresses on transition adapters: ' + $transition.Count)
    $parameters = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
    $disabled = $parameters.PSObject.Properties['DisabledComponents']
    if ($null -eq $disabled) {
        Write-Output 'DisabledComponents policy: not configured (Windows default)'
    } else {
        Write-Output ('DisabledComponents policy: 0x{0:X}' -f $disabled.Value)
    }
    Write-Output 'These counts describe local configuration; they do not prove access through the router or provider.'
} catch {
    Write-Output 'Unable to complete the report. No settings were changed.'
    exit 1
}

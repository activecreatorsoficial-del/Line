param([int]$Port = 8787, [switch]$Lan)
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Join-Path $PSScriptRoot '..\server')
if (!(Get-Command node -ErrorAction SilentlyContinue)) { throw 'Install Node.js 22 or later first.' }
if (!(Test-Path -LiteralPath 'node_modules\ws')) {
    npm.cmd ci --omit=dev
    if ($LASTEXITCODE -ne 0) { throw 'Unable to install the WebSocket library.' }
}
$env:PORT = "$Port"
$env:HOST = if ($Lan) { '0.0.0.0' } else { '127.0.0.1' }
if ($Lan) {
    Write-Host 'On a trusted network only: enable Allow WS on a local network on both devices.'
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -match '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' } | ForEach-Object { Write-Host "Server: ws://$($_.IPAddress):$Port/ws" }
}
node src/index.js

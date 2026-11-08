param([ValidateSet('android-host','windows-host')][string]$Direction = 'android-host',
    [string]$Device = 'emulator-5554', [switch]$SkipInstall, [switch]$Internet)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$lab = Join-Path $root 'build\lan-lab'
$adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
$encoding = New-Object Text.UTF8Encoding($false)
$id = [Guid]::NewGuid().ToString('N')
$port = if ($Direction -eq 'android-host') { 18791 } else { 18792 }
$windows = $null
$forwarded = $false

function Save-Json($Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 10 -Compress), $encoding)
}
function Read-AndroidJson([string]$Name) {
    try {
        $raw = & $adb -s $Device exec-out run-as app.line.line cat "files/line-lab/$Name" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ($raw -join "`n") | ConvertFrom-Json
    } catch { return $null }
}
function Push-AndroidFile([string]$Path, [string]$Name) {
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $adb -s $Device push $Path /data/local/tmp/line-lab-input.json 2>$null | Out-Null
        $pushExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($pushExit -ne 0) { throw 'Unable to push test metadata' }
    & $adb -s $Device shell run-as app.line.line cp /data/local/tmp/line-lab-input.json "files/line-lab/$Name" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unable to copy test metadata' }
}
function Wait-Offer([bool]$Android) {
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $deadline) {
        $offer = $null
        if ($Android) { $offer = Read-AndroidJson 'offer.json' }
        elseif (Test-Path -LiteralPath (Join-Path $lab 'offer.json')) {
            try { $offer = [IO.File]::ReadAllText((Join-Path $lab 'offer.json')) | ConvertFrom-Json } catch {}
        }
        if ($offer -and $offer.id -eq $id) { return $offer }
        $failure = if ($Android) { Read-AndroidJson 'result.json' } else { $null }
        if ($failure -and $failure.id -eq $id -and !$failure.passed) { throw $failure.error }
        Start-Sleep -Milliseconds 300
    }
    throw 'The native host did not create its room. Inspect the lab app logs.'
}

try {
    New-Item -ItemType Directory -Force -Path $lab | Out-Null
    if (!$SkipInstall) {
        & $adb -s $Device install -r (Join-Path $root 'build\app\outputs\flutter-apk\app-debug.apk') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Unable to install the Android lab build' }
    }
    & $adb -s $Device shell am force-stop app.line.line | Out-Null
    & $adb -s $Device shell pm grant app.line.line android.permission.POST_NOTIFICATIONS | Out-Null
    & $adb -s $Device shell run-as app.line.line mkdir -p files/line-lab | Out-Null
    $androidConfig = @{ id=$id; role= $(if ($Direction -eq 'android-host') { 'host' } else { 'receive' }); port=$port }
    $windowsConfig = @{ id=$id; role= $(if ($Direction -eq 'android-host') { 'receive' } else { 'host' }); port=$port }
    if (!$Internet -and $Direction -eq 'android-host') { $windowsConfig.addressOverride = "wss://127.0.0.1:$port/ws" }
    elseif (!$Internet) { $androidConfig.addressOverride = "wss://10.0.2.2:$port/ws" }
    $androidConfig.internet = [bool]$Internet
    $windowsConfig.internet = [bool]$Internet
    Save-Json (Join-Path $lab 'android-config.json') $androidConfig
    Save-Json (Join-Path $lab 'config.json') $windowsConfig
    Push-AndroidFile (Join-Path $lab 'android-config.json') 'config.json'

    if ($Direction -eq 'android-host') {
        if (!$Internet) {
            & $adb -s $Device forward --no-rebind "tcp:$port" "tcp:$port" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'The lab forwarding port is already in use' }
            $forwarded = $true
        }
        & $adb -s $Device shell input keyevent 224 | Out-Null
        & $adb -s $Device shell am start -n app.line.line/.MainActivity | Out-Null
        $offer = Wait-Offer $true
        Save-Json (Join-Path $lab 'offer.json') $offer
        $services = & $adb -s $Device shell dumpsys activity services app.line.line
        if (($services -join "`n") -notmatch 'isForeground=true') { throw 'Android sharing service is not in the foreground' }
        [IO.File]::WriteAllLines((Join-Path $lab 'android-service-during.txt'), $services, $encoding)
        & $adb -s $Device shell input keyevent 3 | Out-Null
        & $adb -s $Device shell input keyevent 223 | Out-Null
        Write-Host 'Android room ready. Host is in the background with the screen off.'
        $windows = Start-Process -FilePath (Join-Path $lab 'windows\line.exe') -WorkingDirectory (Join-Path $lab 'windows') -WindowStyle Hidden -PassThru
    } else {
        $windows = Start-Process -FilePath (Join-Path $lab 'windows\line.exe') -WorkingDirectory (Join-Path $lab 'windows') -WindowStyle Hidden -PassThru
        $offer = Wait-Offer $false
        Push-AndroidFile (Join-Path $lab 'offer.json') 'offer.json'
        & $adb -s $Device shell input keyevent 224 | Out-Null
        & $adb -s $Device shell am start -n app.line.line/.MainActivity | Out-Null
        Write-Host 'Windows room ready. Android receiver started.'
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    $androidResult = $null; $windowsResult = $null
    $responseDelivered = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Internet -and !$responseDelivered) {
            $response = $null
            if ($Direction -eq 'windows-host') { $response = Read-AndroidJson 'response.json' }
            elseif (Test-Path -LiteralPath (Join-Path $lab 'response.json')) {
                try { $response = [IO.File]::ReadAllText((Join-Path $lab 'response.json')) | ConvertFrom-Json } catch {}
            }
            if ($response -and $response.id -eq $id) {
                if ($Direction -eq 'android-host') { Push-AndroidFile (Join-Path $lab 'response.json') 'response.json' }
                else { Save-Json (Join-Path $lab 'response.json') $response }
                $responseDelivered = $true
            }
        }
        $candidate = Read-AndroidJson 'result.json'
        if ($candidate -and $candidate.id -eq $id) { $androidResult = $candidate }
        if (Test-Path -LiteralPath (Join-Path $lab 'result.json')) {
            try {
                $candidate = [IO.File]::ReadAllText((Join-Path $lab 'result.json')) | ConvertFrom-Json
                if ($candidate.id -eq $id) { $windowsResult = $candidate }
            } catch {}
        }
        if ($androidResult -and !$androidResult.passed) { throw $androidResult.error }
        if ($windowsResult -and !$windowsResult.passed) { throw $windowsResult.error }
        if ($androidResult -and $windowsResult) { break }
        Start-Sleep -Milliseconds 300
    }
    if (!$androidResult -or !$windowsResult) { throw 'Cross-device results timed out' }
    if ($androidResult.safety -ne $windowsResult.safety -or $androidResult.hash -ne $windowsResult.hash -or
        $androidResult.bytes -ne 8388608 -or $windowsResult.bytes -ne 8388608) { throw 'Cross-device integrity or security-code mismatch' }
    if ($Internet -and (!$androidResult.exchange -or !$windowsResult.exchange -or $androidResult.relays -ne 0 -or $windowsResult.relays -ne 0)) { throw 'Internet exchange used an unexpected room or relay path' }
    $resultName = if ($Internet) { "$Direction-exchange-result.json" } else { "$Direction-result.json" }
    Save-Json (Join-Path $lab $resultName) @{ direction=$Direction; android=$androidResult; windows=$windowsResult }
    if ($Internet) { Write-Host "Verified $Direction`: 8 MB invitation/response exchange, equal SHA-256 and security codes, no WSS forwarding or relay." }
    else { Write-Host "Verified $Direction`: 8 MB, equal SHA-256, matching security codes, no public signaling/STUN/TURN." }
} finally {
    if ($forwarded) { & $adb -s $Device forward --remove "tcp:$port" | Out-Null }
    if ($windows -and !$windows.HasExited) {
        $owned = Get-Process -Id $windows.Id -ErrorAction SilentlyContinue
        if ($owned -and $owned.Path -eq (Join-Path $lab 'windows\line.exe')) { Stop-Process -Id $owned.Id -Force }
    }
    & $adb -s $Device shell am force-stop app.line.line | Out-Null
    & $adb -s $Device shell rm -f /data/local/tmp/line-lab-input.json | Out-Null
}

param([string]$Installer = 'release\Line-Setup-0.9.0.exe')
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedBundle = Join-Path $projectRoot 'build\distribution\windows-0.9.0'
$verification = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build\installer-verification-0.9.0'))
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build')) + [IO.Path]::DirectorySeparatorChar
if (!$verification.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected verification path' }
$setup = [IO.Path]::GetFullPath((Join-Path $projectRoot $Installer))
$process = Start-Process -FilePath $setup -ArgumentList @('--extract', ('"' + $verification + '"')) -WindowStyle Hidden -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Extraction failed: $($process.ExitCode)" }
if (Test-Path -LiteralPath (Join-Path $verification 'signaling\node.exe')) { throw 'Legacy Node service found in payload' }
$icon = Join-Path $verification 'line-arrows.ico'
if (!(Test-Path -LiteralPath $icon) -or
    (Get-FileHash -LiteralPath $icon -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath (Join-Path $projectRoot 'windows\runner\resources\app_icon.ico') -Algorithm SHA256).Hash) {
    throw 'The approved two-arrow icon is missing or differs from the source'
}
$count = 0
foreach ($source in Get-ChildItem -LiteralPath $expectedBundle -File -Recurse) {
    $relative = $source.FullName.Substring($expectedBundle.Length).TrimStart('\')
    $actual = Join-Path $verification $relative
    if (!(Test-Path -LiteralPath $actual)) { throw "Missing payload file: $relative" }
    if ((Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $actual -Algorithm SHA256).Hash) { throw "Hash mismatch: $relative" }
    $count++
}
$testShortcut = Join-Path $verification 'Line-icon-verification.lnk'
$installerAssembly = [Reflection.Assembly]::LoadFile($setup)
$shortcutMethod = $installerAssembly.GetType('Program').GetMethod('Shortcut', [Reflection.BindingFlags]'Static,NonPublic')
$shortcutMethod.Invoke($null, [object[]]@([string]$testShortcut, [string](Join-Path $verification 'line.exe'), [string]$verification)) | Out-Null
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($testShortcut)
if ($link.TargetPath -ne (Join-Path $verification 'line.exe') -or $link.IconLocation -ne ($icon + ',0')) {
    throw 'Installer shortcut does not use the approved two-arrow icon'
}
Write-Host "Verified $count extracted files and the installer-created two-arrow shortcut. No installation was performed."

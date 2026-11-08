param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location -LiteralPath $projectRoot
if (!$SkipBuild) {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed' }
}
$bundle = Join-Path $projectRoot 'build\windows\x64\runner\Release'
if (!(Test-Path -LiteralPath (Join-Path $bundle 'line.exe'))) { throw 'Missing Windows release bundle' }
# App-local VC++ runtime avoids requiring a developer toolchain on the target PC.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (!(Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio discovery tool not found' }
$crt = $null
foreach ($vsRoot in (& $vswhere -all -products '*' -property installationPath)) {
    $redistRoot = Join-Path $vsRoot 'VC\Redist\MSVC'
    if (!(Test-Path -LiteralPath $redistRoot)) { continue }
    foreach ($version in (Get-ChildItem -LiteralPath $redistRoot -Directory | Sort-Object Name -Descending)) {
        $x64 = Join-Path $version.FullName 'x64'
        if (!(Test-Path -LiteralPath $x64)) { continue }
        $crt = Get-ChildItem -LiteralPath $x64 -Directory | Where-Object Name -Match '^Microsoft\.VC\d+\.CRT$' | Select-Object -First 1
        if ($crt) { break }
    }
    if ($crt) { break }
}
if (!$crt) { throw 'Redistributable x64 C++ runtime not found' }
Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll' | Copy-Item -Destination $bundle
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
# Publish the native Flutter app only. Legacy Node/launcher files are not shipped.
$stage = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build\distribution\windows-0.9.0'))
$allowed = [IO.Path]::GetFullPath((Join-Path $projectRoot 'build\distribution')) + [IO.Path]::DirectorySeparatorChar
if (!$stage.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected distribution path' }
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$isManaged = $false
try { [Reflection.AssemblyName]::GetAssemblyName((Join-Path $bundle 'line.exe')) | Out-Null; $isManaged = $true } catch {}
if ($isManaged) { throw 'Build the new native Windows executable before packaging' }
Get-ChildItem -LiteralPath $bundle | Where-Object { $_.Name -notin @('signaling', 'line-app.exe') } | Copy-Item -Destination $stage -Recurse -Force
Copy-Item -LiteralPath (Join-Path $projectRoot 'windows\runner\resources\app_icon.ico') -Destination (Join-Path $stage 'line-arrows.ico') -Force
$release = Join-Path $projectRoot 'release'
New-Item -ItemType Directory -Force -Path $release | Out-Null
$payload = Join-Path $release 'Line-Windows-portable.zip'
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $payload -Force
$output = Join-Path $release 'Line-Setup-0.9.0.exe'
& $compiler /nologo /target:winexe /optimize+ "/out:$output" "/win32icon:$projectRoot\windows\runner\resources\app_icon.ico" "/resource:$payload,Line.zip" "/resource:$projectRoot\assets\brand\line-icon.png,LineIcon.png" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:Microsoft.CSharp.dll (Join-Path $PSScriptRoot 'LineInstaller.cs')
if ($LASTEXITCODE -ne 0) { throw 'Installer build failed' }
Get-Item -LiteralPath $output, $payload | Select-Object Name, Length

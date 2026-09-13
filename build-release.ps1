[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root 'out\jkelts-check.zip'
}
$releaseDir = Split-Path -Parent $OutputPath
$staging = Join-Path $env:TEMP ('jkelts-check-release-' + [guid]::NewGuid().ToString('N'))

New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
New-Item -ItemType Directory -Path $staging -Force | Out-Null

$files = @(
    'cpu-healthcheck.ps1',
    'cpucheck.cmd',
    'cpu-temp-acpi.ps1',
    'cpu-temp-monitor.ps1',
    'cpu_temp_hwinfo.py',
    'healthcheck.ps1',
    'README.md',
    'LICENSE'
)

foreach ($file in $files) {
    $source = Join-Path $root $file
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination (Join-Path $staging $file) -Force
    }
}

$libSource = Join-Path $root 'lib'
if (Test-Path -LiteralPath $libSource) {
    $libTarget = Join-Path $staging 'lib'
    New-Item -ItemType Directory -Path $libTarget -Force | Out-Null
    Get-ChildItem -LiteralPath $libSource -Recurse -File | Where-Object { $_.Extension -ne '.zip' } | ForEach-Object {
        $relative = $_.FullName.Substring($libSource.Length).TrimStart('\')
        $target = Join-Path $libTarget $relative
        $targetDir = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    }
}

Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutputPath -Force
Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Created release package: $OutputPath" -ForegroundColor Cyan

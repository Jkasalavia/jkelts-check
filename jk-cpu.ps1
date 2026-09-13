<#
JKELTS CHECK GitHub CPU-only bootstrap launcher.

Replace YOUR-GITHUB-USERNAME below after uploading this project to GitHub.
Users can then run:
  irm https://raw.githubusercontent.com/YOUR-GITHUB-USERNAME/jkelts-check/main/jk-cpu.ps1 | iex
#>

$ErrorActionPreference = 'Stop'

$owner = 'Jkasalavia'
$repo = 'jkelts-check'
$packageUrl = "https://github.com/$owner/$repo/releases/latest/download/jkelts-check.zip"
$base = Join-Path $env:TEMP 'jkelts-check'
$zip = Join-Path $env:TEMP 'jkelts-check.zip'

Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

Invoke-WebRequest -Uri $packageUrl -OutFile $zip -UseBasicParsing
Expand-Archive -LiteralPath $zip -DestinationPath $base -Force

powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $base 'cpu-healthcheck.ps1') -Choice 1

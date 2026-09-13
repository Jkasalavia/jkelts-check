<#
JKELTS CPU Temperature Monitor

Reads real-time CPU package/core temperatures using LibreHardwareMonitorLib.

Why a DLL is needed:
- Windows does not allow normal scripts to read CPU MSRs or low-level hardware
  sensor registers directly.
- LibreHardwareMonitorLib handles hardware access through its own driver layer.
- Run this script from an elevated/Administrator PowerShell console so the
  driver can load and return actual sensor values.
#>

[CmdletBinding()]
param(
    [int]$RefreshSeconds = 2
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Administrator {
    if (Test-IsAdministrator) { return }

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
    if (-not $scriptPath) {
        Write-Host 'Administrator rights are required, but the script path could not be detected for elevation.' -ForegroundColor Red
        exit 1
    }

    $argsList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-NoExit',
        '-File', "`"$scriptPath`"",
        '-RefreshSeconds', $RefreshSeconds
    )

    Write-Host 'Requesting Administrator rights for hardware sensor access...' -ForegroundColor Cyan
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($argsList -join ' ')
    exit
}

function Get-ScriptDirectory {
    if ($PSScriptRoot) { return $PSScriptRoot }
    if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    (Get-Location).Path
}

function Ensure-LibreHardwareMonitor {
    param([string]$ScriptDirectory)

    $libDir = Join-Path $ScriptDirectory 'lib'
    $dllPath = Join-Path $libDir 'LibreHardwareMonitorLib.dll'
    if (Test-Path -LiteralPath $dllPath) { return $dllPath }

    New-Item -ItemType Directory -Path $libDir -Force | Out-Null
    $zipPath = Join-Path $libDir 'LibreHardwareMonitor.zip'

    Write-Host 'LibreHardwareMonitorLib.dll not found. Downloading official GitHub release...' -ForegroundColor Cyan

    $downloadUrl = $null
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest' -UseBasicParsing
        $asset = @($release.assets | Where-Object { $_.name -eq 'LibreHardwareMonitor.zip' } | Select-Object -First 1)
        if ($asset) { $downloadUrl = $asset.browser_download_url }
    } catch {
        Write-Host 'GitHub latest release lookup failed. Falling back to known release URL.' -ForegroundColor Yellow
    }

    if (-not $downloadUrl) {
        $downloadUrl = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip'
    }

    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -LiteralPath $zipPath -DestinationPath $libDir -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $dllPath)) {
        throw "LibreHardwareMonitorLib.dll was not found after extraction in $libDir"
    }

    $dllPath
}

function Get-CpuTemperatureRows {
    param($Computer)

    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($hardware in $Computer.Hardware) {
        $hardware.Update()
        foreach ($subHardware in $hardware.SubHardware) { $subHardware.Update() }

        $allHardware = @($hardware) + @($hardware.SubHardware)
        foreach ($item in $allHardware) {
            if ("$($item.HardwareType)" -ne 'Cpu') { continue }

            foreach ($sensor in $item.Sensors) {
                if ("$($sensor.SensorType)" -ne 'Temperature') { continue }
                if ($null -eq $sensor.Value) { continue }

                $rows.Add([pscustomobject]@{
                    CpuName = $item.Name
                    Sensor = $sensor.Name
                    CurrentC = [math]::Round([double]$sensor.Value, 1)
                    MaxC = if ($null -ne $sensor.Max) { [math]::Round([double]$sensor.Max, 1) } else { $null }
                }) | Out-Null
            }
        }
    }

    $rows
}

Request-Administrator

$scriptDir = Get-ScriptDirectory
$dll = Ensure-LibreHardwareMonitor -ScriptDirectory $scriptDir

Add-Type -Path $dll

$computer = New-Object LibreHardwareMonitor.Hardware.Computer
$computer.IsCpuEnabled = $true
$computer.Open()

try {
    while ($true) {
        Clear-Host
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host '                    JKELTS CPU TEMPERATURE' -ForegroundColor Cyan
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host ("Updated: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        Write-Host ''

        $rows = @(Get-CpuTemperatureRows -Computer $computer)
        if ($rows.Count -eq 0) {
            Write-Host 'No CPU temperature values returned.' -ForegroundColor Yellow
            Write-Host 'If sensor names exist but values are blank, this PC/BIOS may block sensor reads.' -ForegroundColor Yellow
            Write-Host 'Try updating BIOS/chipset drivers or compare with HWiNFO Sensors-only mode.' -ForegroundColor Yellow
        } else {
            $cpuName = ($rows | Select-Object -First 1).CpuName
            Write-Host ("CPU: {0}" -f $cpuName) -ForegroundColor White
            Write-Host ''
            $rows | Sort-Object Sensor | Format-Table Sensor, CurrentC, MaxC -AutoSize
        }

        Start-Sleep -Seconds ([math]::Max(1, $RefreshSeconds))
    }
} finally {
    $computer.Close()
}

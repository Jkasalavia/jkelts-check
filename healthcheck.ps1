<# 
Windows IT Support Health Check
Read-only diagnostic script for Windows 10/11 and Windows Server.
Designed for local execution and remote one-liner execution:
  irm https://YOUR-DOMAIN/hc | iex
#>

[CmdletBinding()]
param(
    [switch]$Export,
    [switch]$Html,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$Script:Recommendations = New-Object System.Collections.Generic.List[object]
$Script:Findings = New-Object System.Collections.Generic.List[object]
$Script:Report = [ordered]@{}
$Script:ToolTitle = 'JKELTS CHECK'
$Script:TitleWidth = 60

function Invoke-Safe {
    param([scriptblock]$ScriptBlock, $Default = $null)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Stop'
        & $ScriptBlock
    } catch {
        $Default
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function ConvertTo-GB {
    param($Bytes)
    if ($null -eq $Bytes -or [double]$Bytes -eq 0) { return 0 }
    [math]::Round(([double]$Bytes / 1GB), 2)
}

function ConvertTo-MB {
    param($Bytes)
    if ($null -eq $Bytes -or [double]$Bytes -eq 0) { return 0 }
    [math]::Round(([double]$Bytes / 1MB), 2)
}

function Get-Percent {
    param($Used, $Total)
    if ($null -eq $Total -or [double]$Total -le 0) { return 0 }
    [math]::Round((([double]$Used / [double]$Total) * 100), 0)
}

function Get-StatusByThreshold {
    param([double]$Value, [double]$Warn, [double]$Crit)
    if ($Value -ge $Crit) { 'CRITICAL' }
    elseif ($Value -ge $Warn) { 'WARNING' }
    else { 'OK' }
}

function Add-Recommendation {
    param([string]$Status, [string]$Message, [string]$Advice)
    $Script:Recommendations.Add([pscustomobject]@{
        Status = $Status
        Message = $Message
        Advice = $Advice
    }) | Out-Null
}

function Add-Finding {
    param([string]$Name, [string]$Status, [int]$Deduction, [string]$Details = '')
    $Script:Findings.Add([pscustomobject]@{
        Name = $Name
        Status = $Status
        Deduction = $Deduction
        Details = $Details
    }) | Out-Null
}

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-TimeSpanShort {
    param([timespan]$Span)
    '{0} days {1} hours' -f [int]$Span.TotalDays, $Span.Hours
}

function Write-ColorLine {
    param([string]$Text = '', [string]$Color = 'Gray')
    if ($Host.Name -match 'ConsoleHost|Visual Studio Code') {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Output $Text
    }
}

function Write-HealthStatus {
    param([string]$Label, $Value, [string]$Status)
    $color = switch ($Status) {
        'OK' { 'Green' }
        'HEALTHY' { 'Green' }
        'WARNING' { 'Yellow' }
        'POOR' { 'Yellow' }
        'CRITICAL' { 'Red' }
        default { 'Gray' }
    }
    $line = "{0,-18}: {1,-28} [{2}]" -f $Label, $Value, $Status
    Write-ColorLine $line $color
}

function Format-CenteredTitle {
    param([string]$Title)
    $width = [int]$Script:TitleWidth
    if ($Title.Length -ge $width) { return $Title }
    $left = [math]::Floor(($width - $Title.Length) / 2)
    (' ' * $left) + $Title
}

function Add-TextTitle {
    param([scriptblock]$Add, [string]$Title)
    & $Add ('=' * $Script:TitleWidth)
    & $Add (Format-CenteredTitle $Title)
    & $Add ('=' * $Script:TitleWidth)
}

function Write-ConsoleTitle {
    param([string]$Title)
    Write-ColorLine ('=' * $Script:TitleWidth) Cyan
    Write-ColorLine (Format-CenteredTitle $Title) Cyan
    Write-ColorLine ('=' * $Script:TitleWidth) Cyan
}

function Get-DeviceType {
    param($ComputerSystem = $null)
    $enclosures = @(Invoke-Safe { Get-CimInstance -ClassName Win32_SystemEnclosure } @())
    $chassisTypes = @($enclosures | ForEach-Object { $_.ChassisTypes } | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
    $model = if ($ComputerSystem) { "$($ComputerSystem.Model)" } else { '' }
    $pcType = if ($ComputerSystem -and $null -ne $ComputerSystem.PCSystemType) { [int]$ComputerSystem.PCSystemType } else { $null }
    $hasBattery = @(Invoke-Safe { Get-CimInstance -ClassName Win32_Battery } @()).Count -gt 0

    if ($chassisTypes | Where-Object { $_ -in 13 }) { return 'ALL IN ONE COMPUTER' }
    if ($model -match 'All[- ]?in[- ]?One|AIO') { return 'ALL IN ONE COMPUTER' }
    if ($chassisTypes | Where-Object { $_ -in 8,9,10,14,30,31,32 }) { return 'LAPTOP' }
    if ($pcType -eq 2 -or $hasBattery) { return 'LAPTOP' }
    if ($chassisTypes | Where-Object { $_ -in 3,4,5,6,7,15,16,35,36 }) { return 'DESKTOP' }
    if ($pcType -eq 1) { return 'DESKTOP' }
    'UNKNOWN'
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
    Write-ColorLine 'LibreHardwareMonitorLib.dll not found. Downloading official GitHub release...' Cyan

    $downloadUrl = $null
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/LibreHardwareMonitor/LibreHardwareMonitor/releases/latest' -UseBasicParsing -ErrorAction Stop
        $asset = @($release.assets | Where-Object { $_.name -eq 'LibreHardwareMonitor.zip' } | Select-Object -First 1)
        if ($asset) { $downloadUrl = $asset.browser_download_url }
    } catch {
        Write-ColorLine 'GitHub latest release lookup failed. Falling back to known release URL.' Yellow
    }

    if (-not $downloadUrl) {
        $downloadUrl = 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip'
    }

    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    Expand-Archive -LiteralPath $zipPath -DestinationPath $libDir -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $dllPath)) {
        throw "LibreHardwareMonitorLib.dll was not found after extraction in $libDir"
    }

    $dllPath
}

function Get-CPUTemperature {
    try {
        $zones = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop)
        $readings = @($zones | Where-Object {
            $null -ne $_.CurrentTemperature -and [double]$_.CurrentTemperature -gt 0
        } | ForEach-Object {
            $celsius = [math]::Round((([double]$_.CurrentTemperature / 10) - 273.15), 1)
            if ($celsius -gt -50 -and $celsius -lt 150) { $celsius }
        })
        if ($readings.Count -gt 0) {
            $current = [math]::Round(($readings | Measure-Object -Average).Average, 1)
            $highest = [math]::Round(($readings | Measure-Object -Maximum).Maximum, 1)
            return [pscustomobject]@{
                CurrentC = $current
                CurrentF = [math]::Round(($current * 9 / 5) + 32, 1)
                HighestC = $highest
                HighestF = [math]::Round(($highest * 9 / 5) + 32, 1)
                Status = if ($highest -ge 90) { 'CRITICAL' } elseif ($highest -ge 80) { 'WARNING' } else { 'OK' }
                Source = 'MSAcpi_ThermalZoneTemperature'
                SensorCount = $readings.Count
            }
        }
    } catch {
        return [pscustomobject]@{
            CurrentC = $null
            CurrentF = $null
            HighestC = $null
            HighestF = $null
            Status = 'UNAVAILABLE'
            Source = "MSAcpi_ThermalZoneTemperature unavailable: $($_.Exception.Message)"
            SensorCount = 0
        }
    }

    return [pscustomobject]@{
        CurrentC = $null
        CurrentF = $null
        HighestC = $null
        HighestF = $null
        Status = 'UNAVAILABLE'
        Source = 'No usable ACPI thermal zone temperature values were returned by Windows'
        SensorCount = 0
    }

    $scriptDir = Get-ScriptDirectory
    $pythonHelper = Join-Path $scriptDir 'cpu_temp_hwinfo.py'
    if (Test-Path -LiteralPath $pythonHelper) {
        $pythonResult = Invoke-Safe {
            $python = (Get-Command python -ErrorAction Stop).Source
            $json = & $python $pythonHelper 2>$null
            if ($LASTEXITCODE -eq 0 -and $json) {
                $data = $json | ConvertFrom-Json
                if ($data.available) {
                    [pscustomobject]@{
                        CurrentC = [double]$data.current_c
                        CurrentF = [double]$data.current_f
                        HighestC = [double]$data.highest_c
                        HighestF = [double]$data.highest_f
                        Status = [string]$data.status
                        Source = [string]$data.source
                        SensorCount = [int]$data.sensor_count
                    }
                }
            }
        } $null
        if ($pythonResult) { return $pythonResult }
    }

    $hwinfoResult = Invoke-Safe {
        if (-not ('Jkelts.HwinfoSharedMemoryReader' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Jkelts {
  public static class HwinfoSharedMemoryReader {
    const uint FILE_MAP_READ = 0x0004;
    const int SENSOR_TYPE_TEMP = 1;

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Auto)]
    static extern IntPtr OpenFileMapping(uint dwDesiredAccess, bool bInheritHandle, string lpName);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr MapViewOfFile(IntPtr hFileMappingObject, uint dwDesiredAccess, uint dwFileOffsetHigh, uint dwFileOffsetLow, UIntPtr dwNumberOfBytesToMap);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool UnmapViewOfFile(IntPtr lpBaseAddress);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential, Pack=1)]
    struct Header {
      public UInt32 Signature;
      public UInt32 Version;
      public UInt32 Revision;
      public Int64 PollTime;
      public UInt32 SensorOffset;
      public UInt32 SensorElementSize;
      public UInt32 SensorCount;
      public UInt32 ReadingOffset;
      public UInt32 ReadingElementSize;
      public UInt32 ReadingCount;
      public UInt32 PollingPeriod;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi, Pack=1)]
    struct Sensor {
      public UInt32 SensorId;
      public UInt32 SensorInstance;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string NameOrig;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string NameUser;
    }

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi, Pack=1)]
    struct Reading {
      public UInt32 ReadingType;
      public UInt32 SensorIndex;
      public UInt32 ReadingId;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string LabelOrig;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string LabelUser;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst=16)] public string Unit;
      public double Value;
      public double ValueMin;
      public double ValueMax;
      public double ValueAvg;
    }

    static string Clean(string s) { return String.IsNullOrWhiteSpace(s) ? "" : s.TrimEnd('\0').Trim(); }

    public static string[] ReadTemperatures() {
      var rows = new List<string>();
      IntPtr map = OpenFileMapping(FILE_MAP_READ, false, "Global\\HWiNFO_SENS_SM2");
      if (map == IntPtr.Zero) return rows.ToArray();
      IntPtr view = IntPtr.Zero;
      try {
        view = MapViewOfFile(map, FILE_MAP_READ, 0, 0, UIntPtr.Zero);
        if (view == IntPtr.Zero) return rows.ToArray();
        Header header = Marshal.PtrToStructure<Header>(view);
        var sensors = new Sensor[header.SensorCount];
        for (int i = 0; i < header.SensorCount; i++) {
          IntPtr ptr = IntPtr.Add(view, (int)header.SensorOffset + ((int)header.SensorElementSize * i));
          sensors[i] = Marshal.PtrToStructure<Sensor>(ptr);
        }
        for (int i = 0; i < header.ReadingCount; i++) {
          IntPtr ptr = IntPtr.Add(view, (int)header.ReadingOffset + ((int)header.ReadingElementSize * i));
          Reading r = Marshal.PtrToStructure<Reading>(ptr);
          if (r.ReadingType != SENSOR_TYPE_TEMP) continue;
          if (r.SensorIndex >= sensors.Length) continue;
          string sensor = Clean(sensors[r.SensorIndex].NameUser);
          if (sensor.Length == 0) sensor = Clean(sensors[r.SensorIndex].NameOrig);
          string label = Clean(r.LabelUser);
          if (label.Length == 0) label = Clean(r.LabelOrig);
          string unit = Clean(r.Unit);
          rows.Add(sensor + "|" + label + "|" + r.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + r.ValueMax.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + unit);
        }
      } finally {
        if (view != IntPtr.Zero) UnmapViewOfFile(view);
        CloseHandle(map);
      }
      return rows.ToArray();
    }
  }
}
"@ -ErrorAction Stop
        }
        $rows = [Jkelts.HwinfoSharedMemoryReader]::ReadTemperatures()
        $cpuRows = @($rows | ForEach-Object {
            $parts = $_ -split '\|', 5
            if ($parts.Count -eq 5) {
                [pscustomobject]@{
                    Sensor = $parts[0]
                    Label = $parts[1]
                    Value = [double]$parts[2]
                    Max = [double]$parts[3]
                    Unit = $parts[4]
                }
            }
        } | Where-Object {
            ($_.Sensor -match 'CPU|Processor|Core|Intel|AMD|Ryzen|Package|Tctl|Tdie') -or
            ($_.Label -match 'CPU|Core|Package|Tctl|Tdie')
        })
        if ($cpuRows.Count -gt 0) {
            $current = [math]::Round(($cpuRows | Measure-Object -Property Value -Maximum).Maximum, 1)
            $highest = [math]::Round(($cpuRows | Measure-Object -Property Max -Maximum).Maximum, 1)
            [pscustomobject]@{
                CurrentC = $current
                CurrentF = [math]::Round(($current * 9 / 5) + 32, 1)
                HighestC = $highest
                HighestF = [math]::Round(($highest * 9 / 5) + 32, 1)
                Status = if ($highest -ge 90) { 'CRITICAL' } elseif ($highest -ge 80) { 'WARNING' } else { 'OK' }
                Source = 'HWiNFO Shared Memory'
                SensorCount = $cpuRows.Count
            }
        }
    } $null
    if ($hwinfoResult) { return $hwinfoResult }

    $lhmPath = Invoke-Safe { Ensure-LibreHardwareMonitor -ScriptDirectory $scriptDir } $null
    if ($lhmPath) {
        $lhmResult = Invoke-Safe {
            Add-Type -Path $lhmPath -ErrorAction Stop
            $computer = New-Object LibreHardwareMonitor.Hardware.Computer
            $computer.IsCpuEnabled = $true
            $computer.Open()
            try {
                $sensors = New-Object System.Collections.Generic.List[object]
                foreach ($hardware in $computer.Hardware) {
                    $hardware.Update()
                    foreach ($subHardware in $hardware.SubHardware) { $subHardware.Update() }
                    $allHardware = @($hardware) + @($hardware.SubHardware)
                    foreach ($item in $allHardware) {
                        if ("$($item.HardwareType)" -eq 'Cpu') {
                            foreach ($sensor in $item.Sensors) {
                                if ("$($sensor.SensorType)" -eq 'Temperature') {
                                    $sensors.Add($sensor) | Out-Null
                                }
                            }
                        }
                    }
                }
                if ($sensors.Count -gt 0) {
                    $valueSensors = @($sensors | Where-Object { $null -ne $_.Value })
                    if ($valueSensors.Count -eq 0) {
                        return [pscustomobject]@{
                            CurrentC = $null
                            CurrentF = $null
                            HighestC = $null
                            HighestF = $null
                            Status = 'UNAVAILABLE'
                            Source = 'LibreHardwareMonitor sensors found but no values; run as Administrator'
                            SensorCount = $sensors.Count
                        }
                    }
                    $current = [math]::Round((@($valueSensors | ForEach-Object { [double]$_.Value }) | Measure-Object -Maximum).Maximum, 1)
                    $maxValues = @($valueSensors | Where-Object { $null -ne $_.Max } | ForEach-Object { [double]$_.Max })
                    $highest = if ($maxValues.Count -gt 0) { [math]::Round(($maxValues | Measure-Object -Maximum).Maximum, 1) } else { $current }
                    [pscustomobject]@{
                        CurrentC = $current
                        CurrentF = [math]::Round(($current * 9 / 5) + 32, 1)
                        HighestC = $highest
                        HighestF = [math]::Round(($highest * 9 / 5) + 32, 1)
                        Status = if ($highest -ge 90) { 'CRITICAL' } elseif ($highest -ge 80) { 'WARNING' } else { 'OK' }
                        Source = 'LibreHardwareMonitor'
                        SensorCount = $sensors.Count
                    }
                }
            } finally {
                $computer.Close()
            }
        } $null
        if ($lhmResult) { return $lhmResult }
    }

    $readings = @(Invoke-Safe {
        Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop |
            Where-Object { $null -ne $_.CurrentTemperature -and [double]$_.CurrentTemperature -gt 0 } |
            ForEach-Object {
                $celsius = [math]::Round((([double]$_.CurrentTemperature / 10) - 273.15), 1)
                if ($celsius -gt -50 -and $celsius -lt 150) { $celsius }
            }
    } @())
    if ($readings.Count -eq 0) {
        return [pscustomobject]@{
            CurrentC = $null
            CurrentF = $null
            HighestC = $null
            HighestF = $null
            Status = 'UNAVAILABLE'
            Source = if ($lhmPath) { 'LibreHardwareMonitor failed; WMI unavailable' } else { 'Unavailable' }
            SensorCount = 0
        }
    }
    $current = [math]::Round(($readings | Measure-Object -Average).Average, 1)
    $highest = [math]::Round(($readings | Measure-Object -Maximum).Maximum, 1)
    [pscustomobject]@{
        CurrentC = $current
        CurrentF = [math]::Round(($current * 9 / 5) + 32, 1)
        HighestC = $highest
        HighestF = [math]::Round(($highest * 9 / 5) + 32, 1)
        Status = if ($highest -ge 90) { 'CRITICAL' } elseif ($highest -ge 80) { 'WARNING' } else { 'OK' }
        Source = 'MSAcpi_ThermalZoneTemperature'
        SensorCount = $readings.Count
    }
}

function Get-SystemInfo {
    $os = Invoke-Safe { Get-CimInstance -ClassName Win32_OperatingSystem }
    $cs = Invoke-Safe { Get-CimInstance -ClassName Win32_ComputerSystem }
    $bios = Invoke-Safe { Get-CimInstance -ClassName Win32_BIOS }
    $tz = Invoke-Safe { Get-TimeZone }
    $lastBoot = $null
    $installDate = $null
    if ($os) {
        $lastBoot = Invoke-Safe { $os.LastBootUpTime }
        $installDate = Invoke-Safe { $os.InstallDate }
    }
    $domainOrWorkgroup = if ($cs -and $cs.PartOfDomain) { $cs.Domain } elseif ($cs) { $cs.Workgroup } else { $null }
    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        UserName = [Environment]::UserName
        Manufacturer = if ($cs) { $cs.Manufacturer } else { $null }
        Model = if ($cs) { $cs.Model } else { $null }
        DeviceType = Get-DeviceType $cs
        SerialNumber = if ($bios) { $bios.SerialNumber } else { $null }
        BiosManufacturer = if ($bios) { $bios.Manufacturer } else { $null }
        BiosVersion = if ($bios) { ($bios.SMBIOSBIOSVersion, $bios.Version | Where-Object { $_ } | Select-Object -First 1) } else { $null }
        BiosDate = if ($bios) { $bios.ReleaseDate } else { $null }
        WindowsEdition = if ($os) { $os.Caption } else { $null }
        WindowsVersion = if ($os) { $os.Version } else { $null }
        WindowsBuild = if ($os) { $os.BuildNumber } else { $null }
        OSArchitecture = if ($os) { $os.OSArchitecture } else { $null }
        InstallDate = $installDate
        LastBootTime = $lastBoot
        Uptime = if ($lastBoot) { Format-TimeSpanShort ((Get-Date) - $lastBoot) } else { $null }
        DomainOrWorkgroup = $domainOrWorkgroup
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        TimeZone = if ($tz) { $tz.DisplayName } else { $null }
        IsAdministrator = Test-IsAdministrator
    }
}

function Get-CPUHealth {
    $processors = @(Invoke-Safe { Get-CimInstance -ClassName Win32_Processor } @())
    $loadValues = @($processors | Where-Object { $null -ne $_.LoadPercentage } | ForEach-Object { [double]$_.LoadPercentage })
    $usage = if ($loadValues.Count -gt 0) { [math]::Round(($loadValues | Measure-Object -Average).Average, 0) } else { 0 }
    $cores = 0
    $logical = 0
    if ($processors.Count -gt 0) {
        $coreSum = $processors | Measure-Object -Property NumberOfCores -Sum
        $logicalSum = $processors | Measure-Object -Property NumberOfLogicalProcessors -Sum
        if ($null -ne $coreSum.Sum) { $cores = $coreSum.Sum }
        if ($null -ne $logicalSum.Sum) { $logical = $logicalSum.Sum }
    }
    $status = Get-StatusByThreshold $usage 70 90
    $temperature = Get-CPUTemperature
    if ($status -eq 'WARNING') { Add-Recommendation 'WARNING' "CPU utilization is $usage%." 'Review top CPU-consuming processes and scheduled tasks.'; Add-Finding 'High CPU' $status 10 }
    if ($status -eq 'CRITICAL') { Add-Recommendation 'CRITICAL' "CPU utilization is $usage%." 'Investigate runaway processes or workload pressure.'; Add-Finding 'Critical CPU' $status 10 }
    if ($temperature.Status -eq 'WARNING') { Add-Recommendation 'WARNING' "CPU temperature reached $($temperature.HighestC) C." 'Check airflow, fan operation, dust buildup, and workload.'; Add-Finding 'High CPU temperature' 'WARNING' 10 }
    if ($temperature.Status -eq 'CRITICAL') { Add-Recommendation 'CRITICAL' "CPU temperature reached $($temperature.HighestC) C." 'Inspect cooling immediately and reduce workload until temperatures are controlled.'; Add-Finding 'Critical CPU temperature' 'CRITICAL' 20 }
    [pscustomobject]@{
        Model = ($processors | Select-Object -First 1 -ExpandProperty Name -ErrorAction SilentlyContinue)
        Sockets = $processors.Count
        PhysicalCores = $cores
        LogicalProcessors = $logical
        MaxClockMHz = ($processors | Select-Object -First 1 -ExpandProperty MaxClockSpeed -ErrorAction SilentlyContinue)
        UsagePercent = $usage
        Temperature = $temperature
        Status = $status
    }
}

function Get-MemoryHealth {
    $os = Invoke-Safe { Get-CimInstance -ClassName Win32_OperatingSystem }
    $dimms = @(Invoke-Safe { Get-CimInstance -ClassName Win32_PhysicalMemory } @())
    $dimmSum = if ($dimms.Count -gt 0) { ($dimms | Measure-Object -Property Capacity -Sum).Sum } else { 0 }
    if ($null -eq $dimmSum) { $dimmSum = 0 }
    $total = if ($os) { [double]$os.TotalVisibleMemorySize * 1KB } else { $dimmSum }
    $free = if ($os) { [double]$os.FreePhysicalMemory * 1KB } else { 0 }
    $used = [math]::Max([double]0, ([double]$total - [double]$free))
    $percent = Get-Percent $used $total
    $status = Get-StatusByThreshold $percent 75 90
    if ($status -eq 'WARNING') { Add-Recommendation 'WARNING' "RAM utilization is $percent%." 'Review the highest memory-consuming processes.'; Add-Finding 'High RAM' $status 10 }
    if ($status -eq 'CRITICAL') { Add-Recommendation 'CRITICAL' "RAM utilization is $percent%." 'Reduce workload or plan a memory upgrade.'; Add-Finding 'Critical RAM' $status 10 }
    [pscustomobject]@{
        InstalledGB = ConvertTo-GB $total
        UsedGB = ConvertTo-GB $used
        AvailableGB = ConvertTo-GB $free
        UsagePercent = $percent
        Status = $status
        Dimms = @($dimms | ForEach-Object {
            [pscustomobject]@{
                Manufacturer = $_.Manufacturer
                CapacityGB = ConvertTo-GB $_.Capacity
                SpeedMHz = $_.Speed
                Bank = $_.BankLabel
                Slot = $_.DeviceLocator
            }
        })
    }
}

function Get-StorageHealth {
    $volumes = @(Invoke-Safe { Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" } @())
    $volumeInfo = @($volumes | ForEach-Object {
        $used = [double]$_.Size - [double]$_.FreeSpace
        $percent = Get-Percent $used $_.Size
        $status = Get-StatusByThreshold $percent 80 90
        if ($status -eq 'WARNING') { Add-Recommendation 'WARNING' "$($_.DeviceID) drive is $percent% full." 'Review free space and archive unneeded data.'; Add-Finding "Drive $($_.DeviceID) usage" $status 7 }
        if ($status -eq 'CRITICAL') { Add-Recommendation 'CRITICAL' "$($_.DeviceID) drive is $percent% full." 'Free additional storage space.'; Add-Finding "Drive $($_.DeviceID) critical usage" $status 15 }
        [pscustomobject]@{
            Drive = $_.DeviceID
            Label = $_.VolumeName
            FileSystem = $_.FileSystem
            TotalGB = ConvertTo-GB $_.Size
            UsedGB = ConvertTo-GB $used
            FreeGB = ConvertTo-GB $_.FreeSpace
            UsagePercent = $percent
            HealthPercent = [math]::Max(0, 100 - [int]$percent)
            Status = $status
        }
    })
    $physicalObjects = @(Invoke-Safe { Get-PhysicalDisk -ErrorAction Stop } @())
    $reliabilityRows = @()
    if ($physicalObjects.Count -gt 0) {
        $reliabilityRows = @($physicalObjects | ForEach-Object {
            $disk = $_
            $counter = Invoke-Safe { $disk | Get-StorageReliabilityCounter -ErrorAction Stop } $null
            if ($counter) {
                [pscustomobject]@{
                    FriendlyName = $disk.FriendlyName
                    UniqueId = $disk.UniqueId
                    Wear = $counter.Wear
                    Temperature = $counter.Temperature
                    ReadErrorsTotal = $counter.ReadErrorsTotal
                    WriteErrorsTotal = $counter.WriteErrorsTotal
                }
            }
        })
    }
    $physical = @($physicalObjects | Select-Object FriendlyName, UniqueId, MediaType, Size, BusType, HealthStatus, OperationalStatus)
    if ($physical.Count -eq 0) {
        $physical = @(Invoke-Safe { Get-Disk -ErrorAction Stop | Select-Object FriendlyName, UniqueId, BusType, Size, HealthStatus, OperationalStatus } @())
    }
    if ($physical.Count -eq 0) {
        $physical = @(Invoke-Safe {
            Get-CimInstance -ClassName Win32_DiskDrive | ForEach-Object {
                [pscustomobject]@{
                    FriendlyName = $_.Model
                    UniqueId = $_.SerialNumber
                    MediaType = $_.MediaType
                    BusType = $_.InterfaceType
                    Size = $_.Size
                    HealthStatus = $_.Status
                    OperationalStatus = $_.Status
                }
            }
        } @())
    }
    $diskInfo = @($physical | ForEach-Object {
        $physicalDisk = $_
        $health = "$($_.HealthStatus)"
        $op = @($_.OperationalStatus) -join ', '
        $reliability = @($reliabilityRows | Where-Object {
            ($_.UniqueId -and $physicalDisk.UniqueId -and $_.UniqueId -eq $physicalDisk.UniqueId) -or
            ($_.FriendlyName -and $physicalDisk.FriendlyName -and $_.FriendlyName -eq $physicalDisk.FriendlyName)
        } | Select-Object -First 1)
        $status = if ($health -and $health -notmatch 'Healthy|OK') { 'CRITICAL' } elseif ($op -and $op -notmatch 'OK|Online') { 'WARNING' } else { 'OK' }
        if ($status -eq 'CRITICAL') { Add-Recommendation 'CRITICAL' "Disk $($_.FriendlyName) health is $health." 'Back up data and inspect storage hardware.'; Add-Finding 'Disk health problem' $status 20 }
        $wear = if ($reliability.Count -gt 0 -and $null -ne $reliability[0].Wear) { [int]$reliability[0].Wear } else { $null }
        $specificHealth = if ($null -ne $wear) {
            [math]::Max(0, [math]::Min(100, 100 - $wear))
        } elseif ($status -eq 'OK') {
            100
        } elseif ($status -eq 'WARNING') {
            70
        } elseif ($status -eq 'CRITICAL') {
            25
        } else {
            $null
        }
        $healthSource = if ($null -ne $wear) { 'Windows Storage Reliability Wear' } else { 'Windows Disk Health Estimate' }
        [pscustomobject]@{
            Model = $_.FriendlyName
            MediaType = if ($_.PSObject.Properties.Name -contains 'MediaType') { $_.MediaType } else { $null }
            CapacityGB = ConvertTo-GB $_.Size
            BusType = $_.BusType
            HealthStatus = $health
            OperationalStatus = $op
            SpecificHealthPercent = $specificHealth
            HealthSource = $healthSource
            WearPercent = $wear
            TemperatureC = if ($reliability.Count -gt 0) { $reliability[0].Temperature } else { $null }
            ReadErrorsTotal = if ($reliability.Count -gt 0) { $reliability[0].ReadErrorsTotal } else { $null }
            WriteErrorsTotal = if ($reliability.Count -gt 0) { $reliability[0].WriteErrorsTotal } else { $null }
            Status = $status
        }
    })
    [pscustomobject]@{ Volumes = $volumeInfo; PhysicalDisks = $diskInfo }
}

function Get-GPUInfo {
    @(Invoke-Safe { Get-CimInstance -ClassName Win32_VideoController } @() | ForEach-Object {
        $status = if ([string]::IsNullOrWhiteSpace($_.Name)) { 'WARNING' } elseif ([string]::IsNullOrWhiteSpace($_.DriverVersion)) { 'WARNING' } else { 'OK' }
        [pscustomobject]@{
            Model = $_.Name
            DriverVersion = $_.DriverVersion
            VideoRAMGB = ConvertTo-GB $_.AdapterRAM
            HealthPercent = if ($status -eq 'OK') { 100 } else { 50 }
            Status = $status
        }
    })
}

function Get-NetworkHealth {
    $configs = @(Invoke-Safe { Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" } @())
    $adapters = @(Invoke-Safe { Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } } @())
    $adapterInfo = @($configs | ForEach-Object {
        $match = $adapters | Where-Object { $_.MacAddress -eq ($_.MACAddress -replace ':','-') } | Select-Object -First 1
        [pscustomobject]@{
            Name = if ($match) { $match.Name } else { $_.Description }
            Model = $_.Description
            MacAddress = $_.MACAddress
            IPv4Address = @($_.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', '
            Subnet = @($_.IPSubnet | Where-Object { $_ -match '^\d+\.' }) -join ', '
            DefaultGateway = @($_.DefaultIPGateway) -join ', '
            DnsServers = @($_.DNSServerSearchOrder) -join ', '
            DhcpEnabled = [bool]$_.DHCPEnabled
            LinkSpeed = if ($match) { $match.LinkSpeed } else { $null }
        }
    })
    $gateway = ($configs | ForEach-Object { $_.DefaultIPGateway } | Where-Object { $_ } | Select-Object -First 1)
    $gatewayOk = if ($gateway) {
        Invoke-Safe { (Test-NetConnection -ComputerName $gateway -InformationLevel Quiet -WarningAction SilentlyContinue) } $false
    } else { $false }
    $dnsOk = Invoke-Safe { $null -ne (Resolve-DnsName -Name 'www.microsoft.com' -Type A -ErrorAction Stop | Select-Object -First 1) } $false
    $httpsOk = Invoke-Safe { (Test-NetConnection -ComputerName 'www.microsoft.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) } $false
    $internetOk = $dnsOk -and $httpsOk
    if (-not $internetOk) { Add-Recommendation 'CRITICAL' 'Internet connectivity test failed.' 'Check WAN, proxy, DNS, and firewall connectivity.'; Add-Finding 'Internet failure' 'CRITICAL' 20 }
    if (-not $dnsOk) { Add-Recommendation 'WARNING' 'DNS resolution test failed.' 'Review DNS server settings and name resolution.'; Add-Finding 'DNS failure' 'WARNING' 10 }
    [pscustomobject]@{
        Adapters = $adapterInfo
        Gateway = if ($gatewayOk) { 'REACHABLE' } else { 'UNREACHABLE' }
        GatewayStatus = if ($gatewayOk) { 'OK' } else { 'WARNING' }
        Internet = if ($internetOk) { 'ONLINE' } else { 'OFFLINE' }
        InternetStatus = if ($internetOk) { 'OK' } else { 'CRITICAL' }
        DNS = if ($dnsOk) { 'WORKING' } else { 'FAILED' }
        DNSStatus = if ($dnsOk) { 'OK' } else { 'WARNING' }
        HTTPS443 = if ($httpsOk) { 'WORKING' } else { 'FAILED' }
        HTTPS443Status = if ($httpsOk) { 'OK' } else { 'WARNING' }
    }
}

function Get-ServiceHealth {
    $services = @(Invoke-Safe { Get-CimInstance -ClassName Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" } @())
    $ignore = 'edgeupdate|gupdate|MapsBroker|RemoteRegistry|sppsvc|TrustedInstaller|WbioSrvc|BITS|UsoSvc'
    $failed = @($services | Where-Object { $_.Name -notmatch $ignore } | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; StartType = $_.StartMode; Status = $_.State }
    })
    $count = $failed.Count
    $status = if ($count -ge 5) { 'CRITICAL' } elseif ($count -gt 0) { 'WARNING' } else { 'OK' }
    if ($count -gt 0) {
        $deduct = [math]::Min(10, $count * 2)
        Add-Recommendation $status "$count automatic services are stopped." 'Review the service list below before taking action.'
        Add-Finding 'Failed automatic services' $status $deduct
    }
    [pscustomobject]@{ FailedAutomaticServices = $failed; Count = $count; Status = $status }
}

function Get-UpdateHealth {
    $wu = Invoke-Safe { Get-Service -Name wuauserv -ErrorAction Stop }
    $pending = $false
    foreach ($p in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
        if (Invoke-Safe { Test-Path $p } $false) { $pending = $true }
    }
    $pendingFileRename = Invoke-Safe { (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations } $null
    if ($pendingFileRename) { $pending = $true }
    if ($pending) { Add-Recommendation 'WARNING' 'A pending reboot was detected.' 'Schedule a restart during an approved maintenance window.'; Add-Finding 'Pending reboot' 'WARNING' 5 }
    $hotfixes = @(Invoke-Safe { Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 8 } @())
    [pscustomobject]@{
        WindowsUpdateServiceStatus = if ($wu) { $wu.Status.ToString() } else { 'Unknown' }
        PendingReboot = $pending
        LastSuccessfulUpdate = ($hotfixes | Select-Object -First 1)
        RecentUpdates = $hotfixes
    }
}

function Get-MicrosoftHealth {
    $license = Invoke-Safe {
        Get-CimInstance -ClassName SoftwareLicensingProduct |
            Where-Object { $_.PartialProductKey -and $_.Name -match 'Windows' } |
            Sort-Object LicenseStatus -Descending |
            Select-Object -First 1
    } $null

    $licenseStatusMap = @{
        0 = 'Unlicensed'
        1 = 'Activated'
        2 = 'OOB grace'
        3 = 'OOT grace'
        4 = 'Non-genuine grace'
        5 = 'Notification'
        6 = 'Extended grace'
    }
    $activationStatus = if ($license) {
        $mapped = $licenseStatusMap[[int]$license.LicenseStatus]
        if ($mapped) { $mapped } else { "Unknown ($($license.LicenseStatus))" }
    } else {
        'Unknown'
    }
    $activationHealth = if ($activationStatus -eq 'Activated') { 'OK' } elseif ($activationStatus -eq 'Unknown') { 'WARNING' } else { 'CRITICAL' }
    if ($activationHealth -eq 'CRITICAL') {
        Add-Recommendation 'CRITICAL' "Windows activation status is $activationStatus." 'Activate Windows with a valid license or verify the organization licensing path.'
        Add-Finding 'Windows activation' 'CRITICAL' 15
    } elseif ($activationHealth -eq 'WARNING') {
        Add-Recommendation 'WARNING' 'Windows activation status could not be confirmed.' 'Run the health check as administrator or verify activation in Windows Settings.'
        Add-Finding 'Windows activation unknown' 'WARNING' 5
    }

    $pstFiles = @(Invoke-Safe {
        Get-ChildItem -LiteralPath $env:USERPROFILE -Filter *.pst -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object FullName, Name, Length, LastWriteTime
    } @())
    $totalBytes = ($pstFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalBytes) { $totalBytes = 0 }
    $largestBytes = ($pstFiles | Measure-Object -Property Length -Maximum).Maximum
    if ($null -eq $largestBytes) { $largestBytes = 0 }
    $pstStatus = if ($largestBytes -ge 20GB -or $totalBytes -ge 50GB) { 'WARNING' } else { 'OK' }
    if ($pstStatus -eq 'WARNING') {
        Add-Recommendation 'WARNING' "Outlook PST storage is $([math]::Round([double]$totalBytes / 1GB, 2)) GB total." 'Archive or split large PST files and confirm backups are healthy.'
        Add-Finding 'Large Outlook PST files' 'WARNING' 5
    }

    [pscustomobject]@{
        WindowsActivation = [pscustomobject]@{
            Status = $activationStatus
            Health = $activationHealth
            ProductName = if ($license) { $license.Name } else { $null }
            PartialProductKey = if ($license) { $license.PartialProductKey } else { $null }
        }
        OutlookPst = [pscustomobject]@{
            Count = $pstFiles.Count
            TotalSizeGB = ConvertTo-GB $totalBytes
            LargestSizeGB = ConvertTo-GB $largestBytes
            Status = $pstStatus
            Files = @($pstFiles | Sort-Object Length -Descending | Select-Object -First 20 | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name
                    Path = $_.FullName
                    SizeGB = ConvertTo-GB $_.Length
                    SizeMB = ConvertTo-MB $_.Length
                    LastWriteTime = $_.LastWriteTime
                }
            })
        }
    }
}

function Get-SecurityHealth {
    $av = @()
    foreach ($ns in @('root\SecurityCenter2', 'root\SecurityCenter')) {
        $items = @(Invoke-Safe { Get-CimInstance -Namespace $ns -ClassName AntiVirusProduct -ErrorAction Stop } @())
        if ($items.Count -gt 0) { $av = $items; break }
    }
    $defender = Invoke-Safe { Get-MpComputerStatus -ErrorAction Stop } $null
    $firewall = @(Invoke-Safe { Get-NetFirewallProfile -ErrorAction Stop | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction } @())
    [pscustomobject]@{
        AntivirusProducts = @($av | Select-Object displayName, pathToSignedProductExe, productState)
        Defender = if ($defender) {
            [pscustomobject]@{
                AMServiceEnabled = $defender.AMServiceEnabled
                AntivirusEnabled = $defender.AntivirusEnabled
                RealTimeProtectionEnabled = $defender.RealTimeProtectionEnabled
                AntispywareSignatureAge = $defender.AntispywareSignatureAge
                AntivirusSignatureAge = $defender.AntivirusSignatureAge
            }
        } else { $null }
        FirewallProfiles = $firewall
    }
}

function Get-EventHealth {
    $start = (Get-Date).AddHours(-24)
    $systemEvents = @(Invoke-Safe { Get-WinEvent -FilterHashtable @{ LogName='System'; StartTime=$start; Level=1,2 } -MaxEvents 100 -ErrorAction Stop } @())
    $critical = @($systemEvents | Where-Object { $_.LevelDisplayName -eq 'Critical' })
    $errors = @($systemEvents | Where-Object { $_.LevelDisplayName -eq 'Error' })
    $unexpected = @($systemEvents | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -or $_.Id -in 41,6008 })
    $disk = @($systemEvents | Where-Object { $_.ProviderName -match 'disk|stor|ntfs|volmgr|volsnap' -or $_.Message -match 'disk|storage|ntfs|bad block' })
    $boot = @($systemEvents | Where-Object { $_.ProviderName -match 'Kernel-Boot|Boot' -or $_.Id -in 29,30,100,101,102,103 })
    if ($critical.Count -gt 0 -or $errors.Count -gt 0) {
        $deduct = [math]::Min(15, ($critical.Count * 5) + [math]::Min(10, $errors.Count))
        Add-Recommendation 'WARNING' "$($critical.Count) critical and $($errors.Count) error System events were found in the last 24 hours." 'Review the recent event summary for root cause.'
        Add-Finding 'Recent System events' 'WARNING' $deduct
    }
    [pscustomobject]@{
        CriticalSystemEvents = $critical.Count
        Errors = $errors.Count
        UnexpectedShutdowns = $unexpected.Count
        DiskStorageErrors = $disk.Count
        BootRelatedErrors = $boot.Count
        RecentImportantEvents = @($systemEvents | Select-Object -First 8 | ForEach-Object {
            [pscustomobject]@{
                TimeCreated = $_.TimeCreated
                Level = $_.LevelDisplayName
                Provider = $_.ProviderName
                Id = $_.Id
                Message = ($_.Message -replace '\s+', ' ').Trim()
            }
        })
    }
}

function Get-ProcessHealth {
    $procs = @(Invoke-Safe { Get-Process } @())
    $procRows = @($procs | ForEach-Object {
        $cpuValue = 0
        try {
            if ($null -ne $_.CPU) { $cpuValue = [double]$_.CPU }
        } catch { $cpuValue = 0 }
        [pscustomobject]@{
            ProcessName = $_.ProcessName
            PID = $_.Id
            CPU = [math]::Round($cpuValue, 2)
            MemoryMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
        }
    })
    [pscustomobject]@{
        TopCpu = @($procRows | Sort-Object CPU -Descending | Select-Object -First 10)
        TopMemory = @($procRows | Sort-Object MemoryMB -Descending | Select-Object -First 10)
    }
}

function Get-BatteryHealth {
    $batteries = @(Invoke-Safe { Get-CimInstance -ClassName Win32_Battery } @())
    if ($batteries.Count -eq 0) { return [pscustomobject]@{ Present = $false; Batteries = @() } }
    [pscustomobject]@{
        Present = $true
        Batteries = @($batteries | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                ChargePercent = $_.EstimatedChargeRemaining
                Status = $_.Status
                BatteryStatus = $_.BatteryStatus
                EstimatedRuntimeMinutes = $_.EstimatedRunTime
            }
        })
    }
}

function Get-HealthScore {
    $deductions = ($Script:Findings | Measure-Object -Property Deduction -Sum).Sum
    if ($null -eq $deductions) { $deductions = 0 }
    $score = [math]::Max(0, [math]::Min(100, 100 - [int]$deductions))
    $status = if ($score -ge 90) { 'HEALTHY' } elseif ($score -ge 75) { 'WARNING' } elseif ($score -ge 50) { 'POOR' } else { 'CRITICAL' }
    [pscustomobject]@{ Score = $score; Status = $status; Deductions = [int]$deductions; Findings = @($Script:Findings.ToArray()) }
}

function Convert-ReportToText {
    param($Report)
    $lines = New-Object System.Collections.Generic.List[string]
    $add = { param($s='') $lines.Add([string]$s) | Out-Null }
    Add-TextTitle $add $Script:ToolTitle
    & $add ''
    Add-TextTitle $add 'SYSTEM'
    & $add ("Computer        : {0}" -f $Report.System.ComputerName)
    & $add ("User            : {0}" -f $Report.System.UserName)
    & $add ("Administrator   : {0}" -f $(if ($Report.System.IsAdministrator) { 'YES' } else { 'NO' }))
    if (-not $Report.System.IsAdministrator) { & $add 'Some advanced checks may be unavailable.' }
    & $add ("Manufacturer    : {0}" -f $Report.System.Manufacturer)
    & $add ("Model           : {0}" -f $Report.System.Model)
    & $add ("Device Type     : {0}" -f $Report.System.DeviceType)
    & $add ("Serial Number   : {0}" -f $Report.System.SerialNumber)
    & $add ("BIOS            : {0} {1}" -f $Report.System.BiosManufacturer, $Report.System.BiosVersion)
    & $add ("Windows         : {0}" -f $Report.System.WindowsEdition)
    & $add ("Version/Build   : {0} / {1}" -f $Report.System.WindowsVersion, $Report.System.WindowsBuild)
    & $add ("Architecture    : {0}" -f $Report.System.OSArchitecture)
    & $add ("Installed       : {0}" -f $Report.System.InstallDate)
    & $add ("Last Boot       : {0}" -f $Report.System.LastBootTime)
    & $add ("Uptime          : {0}" -f $Report.System.Uptime)
    & $add ("Domain/Workgrp  : {0}" -f $Report.System.DomainOrWorkgroup)
    & $add ("PowerShell      : {0}" -f $Report.System.PowerShellVersion)
    & $add ("Time Zone       : {0}" -f $Report.System.TimeZone)
    & $add ''
    Add-TextTitle $add 'CPU'
    & $add ("CPU Usage       : {0}% [{1}]" -f $Report.CPU.UsagePercent, $Report.CPU.Status)
    & $add ("CPU Model       : {0}" -f $Report.CPU.Model)
    & $add ("CPU Sockets     : {0}" -f $Report.CPU.Sockets)
    & $add ("CPU Cores       : {0} physical / {1} logical" -f $Report.CPU.PhysicalCores, $Report.CPU.LogicalProcessors)
    if ($Report.CPU.Temperature.Status -eq 'UNAVAILABLE') {
        & $add ("CPU Temperature : Unavailable; Source={0}; Sensors={1}" -f $Report.CPU.Temperature.Source, $Report.CPU.Temperature.SensorCount)
    } else {
        & $add ("CPU Temperature : Current {0} C / {1} F; Highest {2} C / {3} F [{4}] Source={5}" -f $Report.CPU.Temperature.CurrentC, $Report.CPU.Temperature.CurrentF, $Report.CPU.Temperature.HighestC, $Report.CPU.Temperature.HighestF, $Report.CPU.Temperature.Status, $Report.CPU.Temperature.Source)
    }
    & $add ''
    Add-TextTitle $add 'RAM'
    & $add ("RAM Usage       : {0}% [{1}]" -f $Report.Memory.UsagePercent, $Report.Memory.Status)
    & $add ("RAM             : {0} GB installed, {1} GB used, {2} GB available" -f $Report.Memory.InstalledGB, $Report.Memory.UsedGB, $Report.Memory.AvailableGB)
    & $add ''
    Add-TextTitle $add 'STORAGE'
    foreach ($v in $Report.Storage.Volumes) { & $add ("{0} Drive Health : {1}% healthy, {2}% used [{3}] {4} GB free of {5} GB" -f $v.Drive, $v.HealthPercent, $v.UsagePercent, $v.Status, $v.FreeGB, $v.TotalGB) }
    foreach ($d in $Report.Storage.PhysicalDisks) { & $add ("Disk Health     : {0}% healthy [{1}] {2}; Windows={3}; Source={4}; Wear={5}; Temp={6} C" -f $d.SpecificHealthPercent, $d.Status, $d.Model, $d.HealthStatus, $d.HealthSource, $d.WearPercent, $d.TemperatureC) }
    & $add ''
    Add-TextTitle $add 'NETWORK'
    & $add ("Gateway         : {0} [{1}]" -f $Report.Network.Gateway, $Report.Network.GatewayStatus)
    & $add ("Internet        : {0} [{1}]" -f $Report.Network.Internet, $Report.Network.InternetStatus)
    & $add ("DNS             : {0} [{1}]" -f $Report.Network.DNS, $Report.Network.DNSStatus)
    & $add ("HTTPS/443       : {0} [{1}]" -f $Report.Network.HTTPS443, $Report.Network.HTTPS443Status)
    & $add ''
    Add-TextTitle $add 'GPU'
    $gpuItems = @($Report.GPU)
    if ($gpuItems.Count -eq 0) { & $add 'GPU Health      : Not detected [WARNING]' }
    foreach ($g in $gpuItems) { & $add ("GPU Health      : {0}% [{1}] {2}; Driver={3}; VRAM={4} GB" -f $g.HealthPercent, $g.Status, $g.Model, $g.DriverVersion, $g.VideoRAMGB) }
    & $add ''
    Add-TextTitle $add 'MICROSOFT'
    & $add ("Windows Activate: {0} [{1}]" -f $Report.Microsoft.WindowsActivation.Status, $Report.Microsoft.WindowsActivation.Health)
    & $add ("Windows Product : {0}" -f $Report.Microsoft.WindowsActivation.ProductName)
    & $add ("Outlook PST     : {0} files, {1} GB total, largest {2} GB [{3}]" -f $Report.Microsoft.OutlookPst.Count, $Report.Microsoft.OutlookPst.TotalSizeGB, $Report.Microsoft.OutlookPst.LargestSizeGB, $Report.Microsoft.OutlookPst.Status)
    foreach ($pst in $Report.Microsoft.OutlookPst.Files) { & $add ("- {0}; {1} GB; {2}" -f $pst.Name, $pst.SizeGB, $pst.Path) }
    & $add ''
    Add-TextTitle $add 'SERVICES AND EVENTS'
    & $add ("Failed Services : {0} [{1}]" -f $Report.Services.Count, $Report.Services.Status)
    & $add ("System Errors   : {0} [{1}]" -f $Report.Events.Errors, $(if ($Report.Events.Errors -gt 0) { 'WARNING' } else { 'OK' }))
    & $add ''
    & $add '------------------------------------------------------------'
    & $add ("HEALTH SCORE     : {0} / 100" -f $Report.Health.Score)
    & $add ("STATUS           : {0}" -f $Report.Health.Status)
    & $add '------------------------------------------------------------'
    & $add ''
    Add-TextTitle $add 'RECOMMENDATIONS'
    if ($Report.Recommendations.Count -eq 0) { & $add '[OK] No immediate recommendations.' }
    foreach ($r in $Report.Recommendations) {
        & $add ("[{0}] {1}" -f $r.Status, $r.Message)
        & $add ("      {0}" -f $r.Advice)
    }
    & $add ''
    Add-TextTitle $add 'ACTIVE NETWORK ADAPTERS'
    foreach ($a in $Report.Network.Adapters) { & $add ("- {0}; {1}; IPv4={2}; GW={3}; DNS={4}; DHCP={5}; Speed={6}" -f $a.Name, $a.MacAddress, $a.IPv4Address, $a.DefaultGateway, $a.DnsServers, $a.DhcpEnabled, $a.LinkSpeed) }
    & $add ''
    Add-TextTitle $add 'FAILED AUTOMATIC SERVICES'
    if ($Report.Services.FailedAutomaticServices.Count -eq 0) { & $add 'None' } else { foreach ($s in $Report.Services.FailedAutomaticServices) { & $add ("- {0} ({1}) Start={2} Status={3}" -f $s.Name, $s.DisplayName, $s.StartType, $s.Status) } }
    & $add ''
    Add-TextTitle $add 'RECENT IMPORTANT SYSTEM EVENTS'
    foreach ($e in $Report.Events.RecentImportantEvents) { & $add ("- {0} [{1}] {2} ID {3}: {4}" -f $e.TimeCreated, $e.Level, $e.Provider, $e.Id, $e.Message) }
    & $add ''
    Add-TextTitle $add 'TOP PROCESSES BY CPU'
    foreach ($p in $Report.Processes.TopCpu) { & $add ("- {0} PID={1} CPU={2} MemoryMB={3}" -f $p.ProcessName, $p.PID, $p.CPU, $p.MemoryMB) }
    & $add ''
    Add-TextTitle $add 'TOP PROCESSES BY MEMORY'
    foreach ($p in $Report.Processes.TopMemory) { & $add ("- {0} PID={1} CPU={2} MemoryMB={3}" -f $p.ProcessName, $p.PID, $p.CPU, $p.MemoryMB) }
    & $add ''
    Add-TextTitle $add 'BATTERY'
    if (-not $Report.Battery.Present) { & $add 'No battery detected.' } else { foreach ($b in $Report.Battery.Batteries) { & $add ("- {0}: {1}% {2}" -f $b.Name, $b.ChargePercent, $b.Status) } }
    $lines -join [Environment]::NewLine
}

function Convert-ReportToHtml {
    param($Report)
    $json = ($Report | ConvertTo-Json -Depth 8) -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
    $text = (Convert-ReportToText $Report) -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
    $gpuRows = if (@($Report.GPU).Count -eq 0) {
        "<tr><td>Not detected</td><td>N/A</td><td><span class='status WARNING'>WARNING</span></td><td>N/A</td><td>N/A</td></tr>"
    } else {
        (@($Report.GPU) | ForEach-Object { "<tr><td>$($_.Model)</td><td>$($_.HealthPercent)%</td><td><span class='status $($_.Status)'>$($_.Status)</span></td><td>$($_.DriverVersion)</td><td>$($_.VideoRAMGB) GB</td></tr>" }) -join "`n"
    }
@"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$Script:ToolTitle - $($Report.System.ComputerName)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:0;background:#f5f7fa;color:#172033}
header{background:#0b5cab;color:white;padding:28px 36px}
main{max-width:1120px;margin:0 auto;padding:24px}
.score{font-size:38px;font-weight:700}.status{display:inline-block;padding:6px 10px;border-radius:6px;font-weight:700}
.OK,.HEALTHY{background:#dff5e7;color:#116329}.WARNING,.POOR{background:#fff2c6;color:#7a4b00}.CRITICAL{background:#ffe1df;color:#9f1d14}
section{background:white;border:1px solid #d8dee8;border-radius:8px;margin:16px 0;padding:18px}
section h2{background:#0b5cab;color:white;margin:-18px -18px 16px;padding:14px 18px;border-radius:8px 8px 0 0;font-size:20px}
table{width:100%;border-collapse:collapse}td,th{padding:8px;border-bottom:1px solid #e8edf3;text-align:left;vertical-align:top}
pre{white-space:pre-wrap;background:#111827;color:#e5e7eb;padding:16px;border-radius:8px;overflow:auto}
</style>
</head>
<body>
<header><h1>$Script:ToolTitle</h1><div>$($Report.System.ComputerName)</div></header>
<main>
<section><div class="score">$($Report.Health.Score) / 100</div><span class="status $($Report.Health.Status)">$($Report.Health.Status)</span></section>
<section><h2>System</h2><table>
<tr><th>Computer</th><td>$($Report.System.ComputerName)</td><th>Windows</th><td>$($Report.System.WindowsEdition)</td></tr>
<tr><th>Manufacturer</th><td>$($Report.System.Manufacturer)</td><th>Model</th><td>$($Report.System.Model)</td></tr>
<tr><th>Device Type</th><td>$($Report.System.DeviceType)</td><th>Serial Number</th><td>$($Report.System.SerialNumber)</td></tr>
<tr><th>Administrator</th><td>$(if ($Report.System.IsAdministrator) { 'YES' } else { 'NO' })</td><th>Uptime</th><td>$($Report.System.Uptime)</td></tr>
</table></section>
<section><h2>CPU</h2><table>
<tr><th>Usage</th><td>$($Report.CPU.UsagePercent)%</td><th>Status</th><td><span class="status $($Report.CPU.Status)">$($Report.CPU.Status)</span></td></tr>
<tr><th>Current Temp</th><td>$(if ($Report.CPU.Temperature.Status -eq 'UNAVAILABLE') { 'Unavailable' } else { "$($Report.CPU.Temperature.CurrentC) C / $($Report.CPU.Temperature.CurrentF) F" })</td><th>Highest Temp</th><td>$(if ($Report.CPU.Temperature.Status -eq 'UNAVAILABLE') { 'Unavailable' } else { "$($Report.CPU.Temperature.HighestC) C / $($Report.CPU.Temperature.HighestF) F [$($Report.CPU.Temperature.Status)]" })</td></tr>
<tr><th>Temp Source</th><td>$($Report.CPU.Temperature.Source)</td><th>Sensors</th><td>$($Report.CPU.Temperature.SensorCount)</td></tr>
<tr><th>Model</th><td colspan="3">$($Report.CPU.Model)</td></tr>
<tr><th>Sockets</th><td>$($Report.CPU.Sockets)</td><th>Cores</th><td>$($Report.CPU.PhysicalCores) physical / $($Report.CPU.LogicalProcessors) logical</td></tr>
</table></section>
<section><h2>RAM</h2><table>
<tr><th>Usage</th><td>$($Report.Memory.UsagePercent)%</td><th>Status</th><td><span class="status $($Report.Memory.Status)">$($Report.Memory.Status)</span></td></tr>
<tr><th>Installed</th><td>$($Report.Memory.InstalledGB) GB</td><th>Available</th><td>$($Report.Memory.AvailableGB) GB</td></tr>
</table></section>
<section><h2>Storage</h2><table><tr><th>Drive</th><th>Health</th><th>Usage</th><th>Free</th><th>Status</th></tr>
$(($Report.Storage.Volumes | ForEach-Object { "<tr><td>$($_.Drive)</td><td>$($_.HealthPercent)%</td><td>$($_.UsagePercent)%</td><td>$($_.FreeGB) GB</td><td><span class='status $($_.Status)'>$($_.Status)</span></td></tr>" }) -join "`n")
</table><table><tr><th>Physical Disk</th><th>Health</th><th>Status</th><th>Source</th><th>Wear</th><th>Temp</th><th>Errors</th></tr>
$(($Report.Storage.PhysicalDisks | ForEach-Object { "<tr><td>$($_.Model)</td><td>$($_.SpecificHealthPercent)%</td><td><span class='status $($_.Status)'>$($_.Status)</span></td><td>$($_.HealthSource)</td><td>$($_.WearPercent)</td><td>$($_.TemperatureC) C</td><td>R:$($_.ReadErrorsTotal) W:$($_.WriteErrorsTotal)</td></tr>" }) -join "`n")
</table></section>
<section><h2>Network</h2><table>
<tr><th>Internet</th><td>$($Report.Network.Internet)</td><th>DNS</th><td>$($Report.Network.DNS)</td></tr>
<tr><th>Gateway</th><td>$($Report.Network.Gateway)</td><th>HTTPS/443</th><td>$($Report.Network.HTTPS443)</td></tr>
</table></section>
<section><h2>GPU</h2><table><tr><th>GPU</th><th>Health</th><th>Status</th><th>Driver</th><th>VRAM</th></tr>
$gpuRows
</table></section>
<section><h2>Microsoft</h2><table>
<tr><th>Windows Activation</th><td>$($Report.Microsoft.WindowsActivation.Status)</td><th>Status</th><td><span class="status $($Report.Microsoft.WindowsActivation.Health)">$($Report.Microsoft.WindowsActivation.Health)</span></td></tr>
<tr><th>Windows Product</th><td colspan="3">$($Report.Microsoft.WindowsActivation.ProductName)</td></tr>
<tr><th>Outlook PST Files</th><td>$($Report.Microsoft.OutlookPst.Count)</td><th>Total Size</th><td>$($Report.Microsoft.OutlookPst.TotalSizeGB) GB</td></tr>
<tr><th>Largest PST</th><td>$($Report.Microsoft.OutlookPst.LargestSizeGB) GB</td><th>PST Status</th><td><span class="status $($Report.Microsoft.OutlookPst.Status)">$($Report.Microsoft.OutlookPst.Status)</span></td></tr>
</table><table><tr><th>PST File</th><th>Size</th><th>Path</th></tr>
$(($Report.Microsoft.OutlookPst.Files | ForEach-Object { "<tr><td>$($_.Name)</td><td>$($_.SizeGB) GB</td><td>$($_.Path)</td></tr>" }) -join "`n")
</table></section>
<section><h2>Recommendations</h2><table><tr><th>Status</th><th>Issue</th><th>Advice</th></tr>
$(($Report.Recommendations | ForEach-Object { "<tr><td><span class='status $($_.Status)'>$($_.Status)</span></td><td>$($_.Message)</td><td>$($_.Advice)</td></tr>" }) -join "`n")
</table></section>
<section><h2>Full Technician Report</h2><pre>$text</pre></section>
<section><h2>JSON Data</h2><pre>$json</pre></section>
</main>
</body>
</html>
"@
}

function Export-HealthReport {
    param($Report, [string]$Path, [switch]$ExportTextJson, [switch]$ExportHtml)
    $safeName = ($Report.System.ComputerName -replace '[^\w.-]', '_')
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    if ($ExportTextJson) {
        $txt = Join-Path $Path "HealthCheck-$safeName-$stamp.txt"
        $json = Join-Path $Path "HealthCheck-$safeName-$stamp.json"
        Convert-ReportToText $Report | Set-Content -LiteralPath $txt -Encoding UTF8
        $Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $json -Encoding UTF8
        Write-ColorLine "Exported: $txt" Cyan
        Write-ColorLine "Exported: $json" Cyan
    }
    if ($ExportHtml) {
        $html = Join-Path $Path "HealthCheck-$safeName-$stamp.html"
        Convert-ReportToHtml $Report | Set-Content -LiteralPath $html -Encoding UTF8
        Write-ColorLine "Exported: $html" Cyan
    }
}

function Write-ConsoleReport {
    param($Report)
    Write-ConsoleTitle $Script:ToolTitle
    Write-ColorLine ''
    Write-ConsoleTitle 'SYSTEM'
    Write-ColorLine ("Computer        : {0}" -f $Report.System.ComputerName)
    Write-ColorLine ("Manufacturer    : {0}" -f $Report.System.Manufacturer)
    Write-ColorLine ("Model           : {0}" -f $Report.System.Model)
    Write-ColorLine ("Device Type     : {0}" -f $Report.System.DeviceType)
    Write-ColorLine ("Windows         : {0}" -f $Report.System.WindowsEdition)
    Write-ColorLine ("Uptime          : {0}" -f $Report.System.Uptime)
    Write-ColorLine ("Administrator   : {0}" -f $(if ($Report.System.IsAdministrator) { 'YES' } else { 'NO' }))
    if (-not $Report.System.IsAdministrator) { Write-ColorLine 'Some advanced checks may be unavailable.' Yellow }
    Write-ColorLine ''
    Write-ConsoleTitle 'CPU'
    Write-HealthStatus 'CPU Usage' "$($Report.CPU.UsagePercent)%" $Report.CPU.Status
    if ($Report.CPU.Temperature.Status -eq 'UNAVAILABLE') {
        Write-HealthStatus 'CPU Temp' 'Unavailable' 'WARNING'
        Write-ColorLine ("CPU Temp Source : {0}; Sensors={1}" -f $Report.CPU.Temperature.Source, $Report.CPU.Temperature.SensorCount)
    } else {
        Write-HealthStatus 'CPU Temp' "Current $($Report.CPU.Temperature.CurrentC) C / $($Report.CPU.Temperature.CurrentF) F; Highest $($Report.CPU.Temperature.HighestC) C / $($Report.CPU.Temperature.HighestF) F" $Report.CPU.Temperature.Status
        Write-ColorLine ("CPU Temp Source : {0}; Sensors={1}" -f $Report.CPU.Temperature.Source, $Report.CPU.Temperature.SensorCount)
    }
    Write-HealthStatus 'CPU Model' $Report.CPU.Model 'OK'
    Write-ColorLine ''
    Write-ConsoleTitle 'RAM'
    Write-HealthStatus 'RAM Usage' "$($Report.Memory.UsagePercent)%" $Report.Memory.Status
    Write-ColorLine ("RAM             : {0} GB installed, {1} GB available" -f $Report.Memory.InstalledGB, $Report.Memory.AvailableGB)
    Write-ColorLine ''
    Write-ConsoleTitle 'STORAGE'
    foreach ($v in $Report.Storage.Volumes) {
        Write-HealthStatus "$($v.Drive) Drive Health" "$($v.HealthPercent)% healthy, $($v.UsagePercent)% used" $v.Status
    }
    foreach ($d in $Report.Storage.PhysicalDisks) {
        $specificHealth = if ($null -ne $d.SpecificHealthPercent) { "$($d.SpecificHealthPercent)% healthy" } else { 'Unavailable' }
        Write-HealthStatus 'Disk Health' "$specificHealth - $($d.Model)" $d.Status
        Write-ColorLine ("Disk Source     : {0}; Windows={1}; Wear={2}; Temp={3} C; ReadErrors={4}; WriteErrors={5}" -f $d.HealthSource, $d.HealthStatus, $d.WearPercent, $d.TemperatureC, $d.ReadErrorsTotal, $d.WriteErrorsTotal)
    }
    Write-ColorLine ''
    Write-ConsoleTitle 'NETWORK'
    Write-HealthStatus 'Internet' $Report.Network.Internet $Report.Network.InternetStatus
    Write-HealthStatus 'DNS' $Report.Network.DNS $Report.Network.DNSStatus
    Write-HealthStatus 'Gateway' $Report.Network.Gateway $Report.Network.GatewayStatus
    Write-HealthStatus 'HTTPS/443' $Report.Network.HTTPS443 $Report.Network.HTTPS443Status
    Write-ColorLine ''
    Write-ConsoleTitle 'GPU'
    $gpuItems = @($Report.GPU)
    if ($gpuItems.Count -eq 0) {
        Write-HealthStatus 'GPU Health' 'Not detected' 'WARNING'
    } else {
        foreach ($g in $gpuItems) {
            Write-HealthStatus 'GPU Health' "$($g.HealthPercent)% - $($g.Model)" $g.Status
            Write-ColorLine ("GPU Driver      : {0}; VRAM={1} GB" -f $g.DriverVersion, $g.VideoRAMGB)
        }
    }
    Write-ColorLine ''
    Write-ConsoleTitle 'MICROSOFT'
    Write-HealthStatus 'Windows Activate' $Report.Microsoft.WindowsActivation.Status $Report.Microsoft.WindowsActivation.Health
    Write-HealthStatus 'Outlook PST Files' $Report.Microsoft.OutlookPst.Count $Report.Microsoft.OutlookPst.Status
    Write-ColorLine ("PST Total Size  : {0} GB, largest {1} GB" -f $Report.Microsoft.OutlookPst.TotalSizeGB, $Report.Microsoft.OutlookPst.LargestSizeGB)
    foreach ($pst in $Report.Microsoft.OutlookPst.Files) {
        Write-ColorLine ("- {0}; {1} GB; {2}" -f $pst.Name, $pst.SizeGB, $pst.Path)
    }
    Write-ColorLine ''
    Write-ConsoleTitle 'SERVICES AND EVENTS'
    Write-HealthStatus 'Failed Services' $Report.Services.Count $Report.Services.Status
    Write-HealthStatus 'System Errors' $Report.Events.Errors $(if ($Report.Events.Errors -gt 0) { 'WARNING' } else { 'OK' })
    Write-ColorLine ''
    Write-ColorLine '------------------------------------------------------------' Cyan
    Write-ColorLine ("HEALTH SCORE     : {0} / 100" -f $Report.Health.Score) Cyan
    Write-ColorLine ("STATUS           : {0}" -f $Report.Health.Status) $(if ($Report.Health.Status -eq 'HEALTHY') { 'Green' } elseif ($Report.Health.Status -eq 'CRITICAL') { 'Red' } else { 'Yellow' })
    Write-ColorLine '------------------------------------------------------------' Cyan
    Write-ColorLine ''
    Write-ConsoleTitle 'RECOMMENDATIONS'
    if ($Report.Recommendations.Count -eq 0) { Write-ColorLine '[OK] No immediate recommendations.' Green }
    foreach ($r in $Report.Recommendations) {
        $color = if ($r.Status -eq 'CRITICAL') { 'Red' } elseif ($r.Status -eq 'WARNING') { 'Yellow' } else { 'Green' }
        Write-ColorLine ("[{0}] {1}" -f $r.Status, $r.Message) $color
        Write-ColorLine ("      {0}" -f $r.Advice) Gray
    }
}

$system = Get-SystemInfo
$cpu = Get-CPUHealth
$memory = Get-MemoryHealth
$storage = Get-StorageHealth
$gpu = Get-GPUInfo
$network = Get-NetworkHealth
$services = Get-ServiceHealth
$updates = Get-UpdateHealth
$microsoft = Get-MicrosoftHealth
$security = Get-SecurityHealth
$events = Get-EventHealth
$processes = Get-ProcessHealth
$battery = Get-BatteryHealth
$health = Get-HealthScore

$finalReport = [pscustomobject][ordered]@{
    System = $system
    CPU = $cpu
    Memory = $memory
    Storage = $storage
    GPU = $gpu
    Network = $network
    Services = $services
    Updates = $updates
    Microsoft = $microsoft
    Security = $security
    Events = $events
    Processes = $processes
    Battery = $battery
    Recommendations = @($Script:Recommendations.ToArray())
    Health = $health
}
Write-ConsoleReport $finalReport
if ($Export -or $Html) {
    Export-HealthReport -Report $finalReport -Path $OutputPath -ExportTextJson:$Export -ExportHtml:$Html
}

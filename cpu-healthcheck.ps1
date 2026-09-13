<#
CPU, Memory, and Disk IT Health Check
Read-only terminal diagnostic script for Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [int]$SampleSeconds = 3,
    [string]$Choice
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
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

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Administrator {
    if (Test-IsAdministrator) { return }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return }

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
    if (-not $scriptPath) {
        Write-Host 'Administrator rights are required, but the script path could not be detected for elevation.' -ForegroundColor Red
        exit 1
    }

    $argsList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-NoExit',
        '-File', "`"$scriptPath`""
    )
    if ($SampleSeconds) { $argsList += @('-SampleSeconds', $SampleSeconds) }
    if (-not [string]::IsNullOrWhiteSpace($Choice)) { $argsList += @('-Choice', "`"$Choice`"") }

    Write-Host 'Requesting Administrator rights for hardware sensor access...' -ForegroundColor Cyan
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($argsList -join ' ')
    exit
}

Request-Administrator

function Convert-Architecture {
    param($Code)
    switch ([int]$Code) {
        0 { 'x86' }
        1 { 'MIPS' }
        2 { 'Alpha' }
        3 { 'PowerPC' }
        5 { 'ARM' }
        6 { 'Itanium' }
        9 { 'x64' }
        12 { 'ARM64' }
        default { "Unknown ($Code)" }
    }
}

function Get-Status {
    param([double]$Usage)
    if ($Usage -ge 90) { 'CRITICAL' }
    elseif ($Usage -ge 70) { 'WARNING' }
    else { 'OK' }
}

function ConvertTo-GB {
    param($Bytes)
    if ($null -eq $Bytes -or [double]$Bytes -le 0) { return 0 }
    [math]::Round(([double]$Bytes / 1GB), 2)
}

function ConvertTo-MB {
    param($Bytes)
    if ($null -eq $Bytes -or [double]$Bytes -le 0) { return 0 }
    [math]::Round(([double]$Bytes / 1MB), 2)
}

function Convert-MemoryType {
    param($MemoryType, $SmbiosMemoryType)

    $code = if ($null -ne $SmbiosMemoryType -and [int]$SmbiosMemoryType -ne 0) {
        [int]$SmbiosMemoryType
    } elseif ($null -ne $MemoryType) {
        [int]$MemoryType
    } else {
        0
    }

    switch ($code) {
        20 { 'DDR' }
        21 { 'DDR2' }
        22 { 'DDR2 FB-DIMM' }
        24 { 'DDR3' }
        26 { 'DDR4' }
        27 { 'LPDDR' }
        28 { 'LPDDR2' }
        29 { 'LPDDR3' }
        30 { 'LPDDR4' }
        31 { 'Logical non-volatile device' }
        34 { 'DDR5' }
        35 { 'LPDDR5' }
        default {
            if ($code -eq 0) { 'Unknown' } else { "Unknown ($code)" }
        }
    }
}

function Get-Percent {
    param($Used, $Total)
    if ($null -eq $Total -or [double]$Total -le 0) { return 0 }
    [math]::Round((([double]$Used / [double]$Total) * 100), 0)
}

function Write-ColorLine {
    param([string]$Text = '', [string]$Color = 'Gray')
    if ($Host.Name -match 'ConsoleHost|Visual Studio Code') {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Output $Text
    }
}

function Write-StatusLine {
    param([string]$Label, $Value, [string]$Status)
    $color = switch ($Status) {
        'OK' { 'Green' }
        'WARNING' { 'Yellow' }
        'CRITICAL' { 'Red' }
        default { 'Gray' }
    }
    Write-ColorLine ("{0,-24}: {1,-30} [{2}]" -f $Label, $Value, $Status) $color
}

function Format-CenteredTitle {
    param([string]$Title)
    $width = [int]$Script:TitleWidth
    if ($Title.Length -ge $width) { return $Title }
    $left = [math]::Floor(($width - $Title.Length) / 2)
    (' ' * $left) + $Title
}

function Write-ConsoleTitle {
    param([string]$Title)
    Write-ColorLine ('=' * $Script:TitleWidth) Cyan
    Write-ColorLine (Format-CenteredTitle $Title) Cyan
    Write-ColorLine ('=' * $Script:TitleWidth) Cyan
}

function Write-ProgressStep {
    param([int]$Percent, [string]$Message)
    Write-ColorLine ("Progress {0,3}% : {1}" -f $Percent, $Message) Cyan
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

function Get-CpuUsage {
    param([int]$Seconds)

    $counter = Invoke-Safe {
        $sample = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval ([math]::Max(1, $Seconds)) -MaxSamples 2
        $last = $sample.CounterSamples | Select-Object -Last 1
        [math]::Round([double]$last.CookedValue, 0)
    } $null

    if ($null -ne $counter) { return $counter }

    $processors = @(Invoke-Safe { Get-CimInstance -ClassName Win32_Processor } @())
    $loadValues = @($processors | Where-Object { $null -ne $_.LoadPercentage } | ForEach-Object { [double]$_.LoadPercentage })
    if ($loadValues.Count -gt 0) {
        return [math]::Round(($loadValues | Measure-Object -Average).Average, 0)
    }

    return 0
}

function Get-BatteryHealth {
    $batteries = @(Invoke-Safe { Get-CimInstance -ClassName Win32_Battery } @())
    $staticData = @(Invoke-Safe { Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop } @())
    $fullCharged = @(Invoke-Safe { Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop } @())

    if ($batteries.Count -eq 0) {
        return [pscustomobject]@{
            Present = $false
            ChargePercent = $null
            HealthPercent = $null
            Status = 'NOT PRESENT'
            Details = 'No battery detected.'
        }
    }

    $chargeValues = @($batteries | Where-Object { $null -ne $_.EstimatedChargeRemaining } | ForEach-Object { [double]$_.EstimatedChargeRemaining })
    $chargePercent = if ($chargeValues.Count -gt 0) { [math]::Round(($chargeValues | Measure-Object -Average).Average, 0) } else { $null }
    $designCapacity = ($staticData | Where-Object { $null -ne $_.DesignedCapacity -and [double]$_.DesignedCapacity -gt 0 } | Select-Object -First 1).DesignedCapacity
    $fullCapacity = ($fullCharged | Where-Object { $null -ne $_.FullChargedCapacity -and [double]$_.FullChargedCapacity -gt 0 } | Select-Object -First 1).FullChargedCapacity
    $healthPercent = if ($designCapacity -and $fullCapacity) {
        [math]::Round(([double]$fullCapacity / [double]$designCapacity) * 100, 0)
    } else {
        $null
    }
    $status = if ($null -eq $healthPercent) {
        'UNKNOWN'
    } elseif ($healthPercent -lt 50) {
        'CRITICAL'
    } elseif ($healthPercent -lt 70) {
        'WARNING'
    } else {
        'OK'
    }

    [pscustomobject]@{
        Present = $true
        ChargePercent = $chargePercent
        HealthPercent = $healthPercent
        Status = $status
        Details = if ($healthPercent) { "Full charge capacity is $healthPercent% of design capacity." } else { 'Battery health capacity is unavailable.' }
    }
}

function Get-CpuHealth {
    $processors = @(Invoke-Safe { Get-CimInstance -ClassName Win32_Processor } @())
    $computer = Invoke-Safe { Get-CimInstance -ClassName Win32_ComputerSystem } $null
    $bios = Invoke-Safe { Get-CimInstance -ClassName Win32_BIOS } $null
    $os = Invoke-Safe { Get-CimInstance -ClassName Win32_OperatingSystem } $null
    $registryCpu = Invoke-Safe { Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' } $null

    $primary = $processors | Select-Object -First 1
    $socketCount = $processors.Count
    $physicalCores = 0
    $logicalProcessors = 0
    if ($processors.Count -gt 0) {
        $coreSum = $processors | Measure-Object -Property NumberOfCores -Sum
        $logicalSum = $processors | Measure-Object -Property NumberOfLogicalProcessors -Sum
        if ($null -ne $coreSum.Sum) { $physicalCores = $coreSum.Sum }
        if ($null -ne $logicalSum.Sum) { $logicalProcessors = $logicalSum.Sum }
    }

    $usage = Get-CpuUsage -Seconds $SampleSeconds
    $status = Get-Status $usage
    $temperature = Get-CPUTemperature
    $battery = Get-BatteryHealth

    $cpuName = if ($primary) { $primary.Name } elseif ($registryCpu) { $registryCpu.ProcessorNameString } else { $null }
    $cpuManufacturer = if ($primary) { $primary.Manufacturer } elseif ($registryCpu) { $registryCpu.VendorIdentifier } else { $null }
    $cpuDescription = if ($primary) { $primary.Description } elseif ($registryCpu) { $registryCpu.Identifier } else { $null }
    $logicalFromRegistry = Invoke-Safe { (Get-ChildItem -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor').Count } $null
    if ($logicalProcessors -eq 0 -and $logicalFromRegistry) { $logicalProcessors = [int]$logicalFromRegistry }
    if ($logicalProcessors -eq 0 -and $env:NUMBER_OF_PROCESSORS) { $logicalProcessors = [int]$env:NUMBER_OF_PROCESSORS }
    $currentClock = if ($primary) { $primary.CurrentClockSpeed } elseif ($registryCpu) { $registryCpu.'~MHz' } else { $null }
    $maxClock = if ($primary) { $primary.MaxClockSpeed } else { $currentClock }

    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        UserName = [Environment]::UserName
        IsAdministrator = Test-IsAdministrator
        Windows = if ($os) { $os.Caption } else { $null }
        Manufacturer = if ($computer) { $computer.Manufacturer } else { $null }
        Model = if ($computer) { $computer.Model } else { $null }
        SerialNumber = if ($bios) { $bios.SerialNumber } else { $null }
        DeviceType = Get-DeviceType $computer
        CpuName = $cpuName
        CpuManufacturer = $cpuManufacturer
        Description = $cpuDescription
        Architecture = if ($primary) { Convert-Architecture $primary.Architecture } else { $null }
        SocketDesignation = if ($primary) { $primary.SocketDesignation } else { $null }
        SocketCount = $socketCount
        PhysicalCores = $physicalCores
        LogicalProcessors = $logicalProcessors
        MaxClockMHz = $maxClock
        CurrentClockMHz = $currentClock
        L2CacheKB = if ($primary) { $primary.L2CacheSize } else { $null }
        L3CacheKB = if ($primary) { $primary.L3CacheSize } else { $null }
        VirtualizationFirmwareEnabled = if ($primary -and ($primary.PSObject.Properties.Name -contains 'VirtualizationFirmwareEnabled')) { $primary.VirtualizationFirmwareEnabled } else { $null }
        SecondLevelAddressTranslation = if ($primary -and ($primary.PSObject.Properties.Name -contains 'SecondLevelAddressTranslationExtensions')) { $primary.SecondLevelAddressTranslationExtensions } else { $null }
        VMMonitorModeExtensions = if ($primary -and ($primary.PSObject.Properties.Name -contains 'VMMonitorModeExtensions')) { $primary.VMMonitorModeExtensions } else { $null }
        LoadPercent = $usage
        Temperature = $temperature
        Battery = $battery
        Status = $status
    }
}

function Get-MemoryFromDotNet {
    Invoke-Safe {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $info = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
        [pscustomobject]@{
            TotalBytes = [double]$info.TotalPhysicalMemory
            AvailableBytes = [double]$info.AvailablePhysicalMemory
        }
    } $null
}

function Get-MemoryHealth {
    $os = Invoke-Safe { Get-CimInstance -ClassName Win32_OperatingSystem } $null
    $dimms = @(Invoke-Safe { Get-CimInstance -ClassName Win32_PhysicalMemory } @())
    $dotNetMemory = Get-MemoryFromDotNet

    $total = 0
    $available = 0

    if ($os) {
        $total = [double]$os.TotalVisibleMemorySize * 1KB
        $available = [double]$os.FreePhysicalMemory * 1KB
    } elseif ($dotNetMemory) {
        $total = [double]$dotNetMemory.TotalBytes
        $available = [double]$dotNetMemory.AvailableBytes
    } elseif ($dimms.Count -gt 0) {
        $sum = $dimms | Measure-Object -Property Capacity -Sum
        if ($null -ne $sum.Sum) { $total = [double]$sum.Sum }
    }

    $used = [math]::Max([double]0, ([double]$total - [double]$available))
    $percent = Get-Percent $used $total
    $status = if ($percent -ge 90) { 'CRITICAL' } elseif ($percent -ge 75) { 'WARNING' } else { 'OK' }

    [pscustomobject]@{
        InstalledGB = ConvertTo-GB $total
        UsedGB = ConvertTo-GB $used
        AvailableGB = ConvertTo-GB $available
        UsagePercent = $percent
        Status = $status
        Dimms = @($dimms | ForEach-Object {
            [pscustomobject]@{
                Manufacturer = $_.Manufacturer
                CapacityGB = ConvertTo-GB $_.Capacity
                Type = Convert-MemoryType $_.MemoryType $_.SMBIOSMemoryType
                MemoryTypeCode = $_.MemoryType
                SMBIOSMemoryTypeCode = $_.SMBIOSMemoryType
                SpeedMHz = $_.Speed
                Bank = $_.BankLabel
                Slot = $_.DeviceLocator
                PartNumber = ($_.PartNumber -replace '\s+$','')
            }
        })
    }
}

function Get-DiskHealth {
    $volumes = @(Invoke-Safe { Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" } @())
    if ($volumes.Count -eq 0) {
        $volumes = @(Invoke-Safe {
            Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null -or $_.Free -ne $null } | ForEach-Object {
                [pscustomobject]@{
                    DeviceID = "$($_.Name):"
                    VolumeName = $_.Description
                    FileSystem = 'Unknown'
                    Size = ([double]$_.Used + [double]$_.Free)
                    FreeSpace = [double]$_.Free
                }
            }
        } @())
    }
    if ($volumes.Count -eq 0) {
        $volumes = @(Invoke-Safe {
            [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } | ForEach-Object {
                [pscustomobject]@{
                    DeviceID = $_.Name.TrimEnd('\')
                    VolumeName = $_.VolumeLabel
                    FileSystem = $_.DriveFormat
                    Size = [double]$_.TotalSize
                    FreeSpace = [double]$_.AvailableFreeSpace
                }
            }
        } @())
    }

    $volumeRows = @($volumes | ForEach-Object {
        $total = [double]$_.Size
        $free = [double]$_.FreeSpace
        $used = [math]::Max([double]0, $total - $free)
        $usage = Get-Percent $used $total
        $status = if ($usage -ge 90) { 'CRITICAL' } elseif ($usage -ge 80) { 'WARNING' } else { 'OK' }
        [pscustomobject]@{
            Drive = $_.DeviceID
            Label = $_.VolumeName
            FileSystem = $_.FileSystem
            TotalGB = ConvertTo-GB $total
            UsedGB = ConvertTo-GB $used
            FreeGB = ConvertTo-GB $free
            UsagePercent = $usage
            HealthPercent = [math]::Max(0, 100 - [int]$usage)
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

    $physicalRows = @($physical | ForEach-Object {
        $physicalDisk = $_
        $health = if ($null -ne $_.HealthStatus) { "$($_.HealthStatus)" } else { 'Unknown' }
        $operational = if ($null -ne $_.OperationalStatus) { @($_.OperationalStatus) -join ', ' } else { 'Unknown' }
        $reliability = @($reliabilityRows | Where-Object {
            ($_.UniqueId -and $physicalDisk.UniqueId -and $_.UniqueId -eq $physicalDisk.UniqueId) -or
            ($_.FriendlyName -and $physicalDisk.FriendlyName -and $_.FriendlyName -eq $physicalDisk.FriendlyName)
        } | Select-Object -First 1)
        $status = if ($health -and $health -notmatch 'Healthy|OK|Unknown') {
            'CRITICAL'
        } elseif ($operational -and $operational -notmatch 'OK|Online|Unknown') {
            'WARNING'
        } else {
            'OK'
        }
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
            MediaType = if ($_.PSObject.Properties.Name -contains 'MediaType') { $_.MediaType } else { 'Unknown' }
            CapacityGB = ConvertTo-GB $_.Size
            BusType = $_.BusType
            HealthStatus = $health
            OperationalStatus = $operational
            SpecificHealthPercent = $specificHealth
            HealthSource = $healthSource
            WearPercent = $wear
            TemperatureC = if ($reliability.Count -gt 0) { $reliability[0].Temperature } else { $null }
            ReadErrorsTotal = if ($reliability.Count -gt 0) { $reliability[0].ReadErrorsTotal } else { $null }
            WriteErrorsTotal = if ($reliability.Count -gt 0) { $reliability[0].WriteErrorsTotal } else { $null }
            Status = $status
        }
    })

    [pscustomobject]@{
        Volumes = $volumeRows
        PhysicalDisks = $physicalRows
    }
}

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 3000)
    Invoke-Safe {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $success = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($success) {
            $client.EndConnect($async)
            $client.Close()
            return $true
        }
        $client.Close()
        return $false
    } $false
}

function Test-HostReachable {
    param([string]$ComputerName)
    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $false }
    Invoke-Safe { Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction Stop } $false
}

function Get-NetworkHealth {
    $adapterConfigs = @(Invoke-Safe { Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" } @())
    $netAdapters = @(Invoke-Safe { Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } } @())

    $rows = @($adapterConfigs | ForEach-Object {
        $macDashed = if ($_.MACAddress) { $_.MACAddress -replace ':','-' } else { $null }
        $adapter = $netAdapters | Where-Object { $_.MacAddress -eq $macDashed } | Select-Object -First 1
        $ipv4 = @($_.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', '
        $subnet = @($_.IPSubnet | Where-Object { $_ -match '^\d+\.' }) -join ', '
        $gateway = @($_.DefaultIPGateway | Where-Object { $_ -match '^\d+\.' }) -join ', '
        $dns = @($_.DNSServerSearchOrder) -join ', '
        $name = if ($adapter) { $adapter.Name } else { $_.Description }
        $linkSpeed = if ($adapter) { $adapter.LinkSpeed } else { 'Unavailable' }
        $type = if ($name -match 'ethernet|local area|gbe|lan|realtek|intel') {
            'Ethernet'
        } elseif ($name -match 'wi-fi|wifi|wireless|wlan') {
            'Wi-Fi'
        } else {
            'Network'
        }
        [pscustomobject]@{
            Name = $name
            Type = $type
            Description = $_.Description
            MacAddress = $_.MACAddress
            IPv4Address = $ipv4
            Subnet = $subnet
            DefaultGateway = $gateway
            DnsServers = $dns
            DhcpEnabled = [bool]$_.DHCPEnabled
            LinkSpeed = $linkSpeed
        }
    })

    if ($rows.Count -eq 0) {
        $rows = @(Invoke-Safe {
            Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.IPAddress -notmatch '^169\.254\.|^127\.' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Name = $_.InterfaceAlias
                        Type = if ($_.InterfaceAlias -match 'ethernet|local area|gbe|lan') { 'Ethernet' } elseif ($_.InterfaceAlias -match 'wi-fi|wifi|wireless|wlan') { 'Wi-Fi' } else { 'Network' }
                        Description = $_.InterfaceAlias
                        MacAddress = 'Unavailable'
                        IPv4Address = $_.IPAddress
                        Subnet = "/$($_.PrefixLength)"
                        DefaultGateway = 'Unavailable'
                        DnsServers = 'Unavailable'
                        DhcpEnabled = $null
                        LinkSpeed = 'Unavailable'
                    }
                }
        } @())
    }
    if ($rows.Count -eq 0) {
        $rows = @(Invoke-Safe {
            $text = ipconfig.exe /all
            $joined = $text -join "`n"
            $blocks = $joined -split "`n(?=[^\r\n].* adapter .+:)"
            foreach ($block in $blocks) {
                if ($block -notmatch 'adapter .+:') { continue }
                $name = if ($block -match '^(?:Ethernet|Wireless LAN|LAN|Unknown|Tunnel) adapter ([^:]+):') { $Matches[1].Trim() } else { 'Network Adapter' }
                if ($block -match 'Media State[ .]*: Media disconnected') { continue }
                $description = if ($block -match 'Description[ .]*:([^\r\n]+)') { $Matches[1].Trim() } else { $name }
                $mac = if ($block -match 'Physical Address[ .]*:([^\r\n]+)') { $Matches[1].Trim() } else { 'Unavailable' }
                $ipv4 = if ($block -match 'IPv4 Address[ .]*:([^\r\n\(]+)') { $Matches[1].Trim() } else { '' }
                if ([string]::IsNullOrWhiteSpace($ipv4)) { continue }
                $gateway = if ($block -match 'Default Gateway[ .]*:([^\r\n]+)') { $Matches[1].Trim() } else { 'Unavailable' }
                $dhcp = if ($block -match 'DHCP Enabled[ .]*:([^\r\n]+)') { $Matches[1].Trim() } else { 'Unavailable' }
                $type = if ($block -match '^Ethernet adapter') { 'Ethernet' } elseif ($block -match '^Wireless LAN adapter') { 'Wi-Fi' } else { 'Network' }
                [pscustomobject]@{
                    Name = $name
                    Type = $type
                    Description = $description
                    MacAddress = $mac
                    IPv4Address = $ipv4
                    Subnet = 'Unavailable'
                    DefaultGateway = $gateway
                    DnsServers = 'See ipconfig /all'
                    DhcpEnabled = $dhcp
                    LinkSpeed = 'Unavailable'
                }
            }
        } @())
    }

    $gatewayAddress = @($rows | ForEach-Object { $_.DefaultGateway -split ', ' } | Where-Object { $_ -and $_ -ne 'Unavailable' } | Select-Object -First 1)
    $gatewayOk = if ($gatewayAddress.Count -gt 0) { Test-HostReachable $gatewayAddress[0] } else { $false }
    $dnsOk = Invoke-Safe { $null -ne ([System.Net.Dns]::GetHostAddresses('www.microsoft.com') | Select-Object -First 1) } $false
    $httpsOk = Test-TcpPort -ComputerName 'www.microsoft.com' -Port 443
    $internetOk = $dnsOk -and $httpsOk

    [pscustomobject]@{
        Adapters = $rows
        Gateway = if ($gatewayOk) { 'REACHABLE' } else { 'UNREACHABLE' }
        GatewayStatus = if ($gatewayOk) { 'OK' } else { 'WARNING' }
        DNS = if ($dnsOk) { 'WORKING' } else { 'FAILED' }
        DNSStatus = if ($dnsOk) { 'OK' } else { 'WARNING' }
        HTTPS443 = if ($httpsOk) { 'WORKING' } else { 'FAILED' }
        HTTPS443Status = if ($httpsOk) { 'OK' } else { 'WARNING' }
        Internet = if ($internetOk) { 'ONLINE' } else { 'OFFLINE' }
        InternetStatus = if ($internetOk) { 'OK' } else { 'CRITICAL' }
    }
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

    $pstFiles = @(Invoke-Safe {
        Get-ChildItem -LiteralPath $env:USERPROFILE -Filter *.pst -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object FullName, Name, Length, LastWriteTime
    } @())
    $totalBytes = ($pstFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalBytes) { $totalBytes = 0 }
    $largestBytes = ($pstFiles | Measure-Object -Property Length -Maximum).Maximum
    if ($null -eq $largestBytes) { $largestBytes = 0 }
    $pstStatus = if ($largestBytes -ge 20GB -or $totalBytes -ge 50GB) { 'WARNING' } else { 'OK' }

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

function Show-SystemSection {
    param($Cpu)
    Write-ConsoleTitle $Script:ToolTitle
    Write-ColorLine ''
    Write-ColorLine ("Computer                  : {0}" -f $Cpu.ComputerName)
    Write-ColorLine ("User                      : {0}" -f $Cpu.UserName)
    Write-ColorLine ("Administrator             : {0}" -f $(if ($Cpu.IsAdministrator) { 'YES' } else { 'NO' }))
    Write-ColorLine ("Windows                   : {0}" -f $Cpu.Windows)
    Write-ColorLine ("System Manufacturer       : {0}" -f $Cpu.Manufacturer)
    Write-ColorLine ("System Model              : {0}" -f $Cpu.Model)
    Write-ColorLine ("Serial Number             : {0}" -f $Cpu.SerialNumber)
    Write-ColorLine ("Device Type               : {0}" -f $Cpu.DeviceType)
    if ($Cpu.DeviceType -eq 'LAPTOP') {
        if ($Cpu.Battery.Present) {
            Write-StatusLine 'Battery Health' "$(if ($null -ne $Cpu.Battery.HealthPercent) { "$($Cpu.Battery.HealthPercent)% healthy" } else { 'Unknown' }), charge $($Cpu.Battery.ChargePercent)%" $Cpu.Battery.Status
            Write-ColorLine ("Battery Details           : {0}" -f $Cpu.Battery.Details)
        } else {
            Write-StatusLine 'Battery Health' 'No battery detected' 'WARNING'
        }
    }
}

function Show-CpuSection {
    param($Cpu)
    Write-ConsoleTitle 'CPU'
    Write-ColorLine ("CPU Model                 : {0}" -f $Cpu.CpuName)
    Write-ColorLine ("CPU Manufacturer          : {0}" -f $Cpu.CpuManufacturer)
    Write-ColorLine ("CPU Description           : {0}" -f $Cpu.Description)
    Write-ColorLine ("Architecture              : {0}" -f $Cpu.Architecture)
    Write-ColorLine ("Socket Designation        : {0}" -f $Cpu.SocketDesignation)
    Write-ColorLine ("CPU Sockets               : {0}" -f $Cpu.SocketCount)
    Write-ColorLine ("Physical Cores            : {0}" -f $Cpu.PhysicalCores)
    Write-ColorLine ("Logical Processors        : {0}" -f $Cpu.LogicalProcessors)
    Write-ColorLine ("Max Clock Speed           : {0} MHz" -f $Cpu.MaxClockMHz)
    Write-ColorLine ("Current Clock Speed       : {0} MHz" -f $Cpu.CurrentClockMHz)
    Write-ColorLine ("L2 Cache                  : {0} KB" -f $Cpu.L2CacheKB)
    Write-ColorLine ("L3 Cache                  : {0} KB" -f $Cpu.L3CacheKB)
    Write-ColorLine ("Virtualization Firmware   : {0}" -f $Cpu.VirtualizationFirmwareEnabled)
    Write-ColorLine ("SLAT Support              : {0}" -f $Cpu.SecondLevelAddressTranslation)
    Write-ColorLine ("VM Monitor Extensions     : {0}" -f $Cpu.VMMonitorModeExtensions)
    Write-ColorLine ''
    Write-StatusLine 'Current CPU Usage' "$($Cpu.LoadPercent)%" $Cpu.Status
    if ($Cpu.Temperature.Status -eq 'UNAVAILABLE') {
        Write-StatusLine 'CPU Temperature' 'Unavailable' 'WARNING'
        Write-ColorLine ("CPU Temp Source          : {0}; Sensors={1}" -f $Cpu.Temperature.Source, $Cpu.Temperature.SensorCount)
    } else {
        Write-StatusLine 'CPU Temperature' "Current $($Cpu.Temperature.CurrentC) C / $($Cpu.Temperature.CurrentF) F; Highest $($Cpu.Temperature.HighestC) C / $($Cpu.Temperature.HighestF) F" $Cpu.Temperature.Status
        Write-ColorLine ("CPU Temp Source          : {0}; Sensors={1}" -f $Cpu.Temperature.Source, $Cpu.Temperature.SensorCount)
    }
    if ($Cpu.Status -eq 'WARNING') {
        Write-ColorLine ''
        Write-ColorLine '[WARNING] CPU utilization is elevated. Review top CPU-consuming processes.' Yellow
    } elseif ($Cpu.Status -eq 'CRITICAL') {
        Write-ColorLine ''
        Write-ColorLine '[CRITICAL] CPU utilization is very high. Investigate runaway processes or workload pressure.' Red
    }
}

function Show-MemorySection {
    param($Memory)
    Write-ConsoleTitle 'MEMORY'
    Write-ColorLine ("Installed RAM             : {0} GB" -f $Memory.InstalledGB)
    Write-ColorLine ("Used RAM                  : {0} GB" -f $Memory.UsedGB)
    Write-ColorLine ("Available RAM             : {0} GB" -f $Memory.AvailableGB)
    Write-StatusLine 'Memory Usage' "$($Memory.UsagePercent)%" $Memory.Status
    Write-ColorLine ''
    Write-ConsoleTitle 'PHYSICAL MEMORY MODULES'
    if ($Memory.Dimms.Count -eq 0) {
        Write-ColorLine 'DIMM details unavailable in this session.' Gray
    } else {
        foreach ($dimm in $Memory.Dimms) {
            Write-ColorLine ("- Slot: {0}; Bank: {1}; Size: {2} GB; Type: {3}; Speed: {4} MHz; Manufacturer: {5}; Part: {6}" -f $dimm.Slot, $dimm.Bank, $dimm.CapacityGB, $dimm.Type, $dimm.SpeedMHz, $dimm.Manufacturer, $dimm.PartNumber)
        }
    }
    if ($Memory.Status -eq 'WARNING') {
        Write-ColorLine ''
        Write-ColorLine '[WARNING] Memory utilization is elevated. Review memory-heavy processes or browser/app load.' Yellow
    } elseif ($Memory.Status -eq 'CRITICAL') {
        Write-ColorLine ''
        Write-ColorLine '[CRITICAL] Memory utilization is very high. Close unnecessary applications or consider a RAM upgrade.' Red
    }
}

function Show-StorageSection {
    param($Disk)
    Write-ConsoleTitle 'DISK VOLUMES'
    if ($Disk.Volumes.Count -eq 0) {
        Write-ColorLine 'No fixed disk volumes detected or access is unavailable.' Gray
    } else {
        foreach ($volume in $Disk.Volumes) {
            Write-StatusLine "$($volume.Drive) Health" "$($volume.HealthPercent)% healthy, $($volume.UsagePercent)% used" $volume.Status
            Write-ColorLine ("  Label: {0}; FileSystem: {1}; Total: {2} GB; Used: {3} GB" -f $volume.Label, $volume.FileSystem, $volume.TotalGB, $volume.UsedGB)
        }
    }
    Write-ColorLine ''
    Write-ConsoleTitle 'PHYSICAL DISKS'
    if ($Disk.PhysicalDisks.Count -eq 0) {
        Write-ColorLine 'Physical disk details unavailable in this session.' Gray
    } else {
        foreach ($physicalDisk in $Disk.PhysicalDisks) {
            $specificHealth = if ($null -ne $physicalDisk.SpecificHealthPercent) { "$($physicalDisk.SpecificHealthPercent)% healthy" } else { 'Unavailable' }
            Write-StatusLine 'Disk Health' "$specificHealth - $($physicalDisk.Model)" $physicalDisk.Status
            Write-ColorLine ("  Type: {0}; Bus: {1}; Capacity: {2} GB; Operational: {3}" -f $physicalDisk.MediaType, $physicalDisk.BusType, $physicalDisk.CapacityGB, $physicalDisk.OperationalStatus)
            Write-ColorLine ("  Source: {0}; Windows Health: {1}; Wear: {2}; Temp: {3} C; ReadErrors: {4}; WriteErrors: {5}" -f $physicalDisk.HealthSource, $physicalDisk.HealthStatus, $physicalDisk.WearPercent, $physicalDisk.TemperatureC, $physicalDisk.ReadErrorsTotal, $physicalDisk.WriteErrorsTotal)
        }
    }
    foreach ($volume in $Disk.Volumes) {
        if ($volume.Status -eq 'WARNING') {
            Write-ColorLine ''
            Write-ColorLine ("[WARNING] {0} drive is {1}% full. Review free space and archive unneeded data." -f $volume.Drive, $volume.UsagePercent) Yellow
        } elseif ($volume.Status -eq 'CRITICAL') {
            Write-ColorLine ''
            Write-ColorLine ("[CRITICAL] {0} drive is {1}% full. Free additional storage space." -f $volume.Drive, $volume.UsagePercent) Red
        }
    }
}

function Show-NetworkSection {
    param($Network)
    Write-ConsoleTitle 'NETWORK / ETHERNET'
    if ($Network.Adapters.Count -eq 0) {
        Write-ColorLine 'No active IPv4 network adapters detected or access is unavailable.' Gray
    } else {
        foreach ($adapter in $Network.Adapters) {
            Write-ColorLine ("- {0} ({1})" -f $adapter.Name, $adapter.Type)
            Write-ColorLine ("  Model       : {0}" -f $adapter.Description)
            Write-ColorLine ("  MAC         : {0}" -f $adapter.MacAddress)
            Write-ColorLine ("  IPv4        : {0}" -f $adapter.IPv4Address)
            Write-ColorLine ("  Subnet      : {0}" -f $adapter.Subnet)
            Write-ColorLine ("  Gateway     : {0}" -f $adapter.DefaultGateway)
            Write-ColorLine ("  DNS Servers : {0}" -f $adapter.DnsServers)
            Write-ColorLine ("  DHCP        : {0}" -f $adapter.DhcpEnabled)
            Write-ColorLine ("  Link Speed  : {0}" -f $adapter.LinkSpeed)
        }
    }
    Write-ColorLine ''
    Write-StatusLine 'Gateway' $Network.Gateway $Network.GatewayStatus
    Write-StatusLine 'DNS' $Network.DNS $Network.DNSStatus
    Write-StatusLine 'HTTPS/443' $Network.HTTPS443 $Network.HTTPS443Status
    Write-StatusLine 'Internet' $Network.Internet $Network.InternetStatus
}

function Show-GpuSection {
    param($Gpu)
    Write-ConsoleTitle 'GPU'
    $gpuItems = @($Gpu)
    if ($gpuItems.Count -eq 0) {
        Write-StatusLine 'GPU Health' 'Not detected' 'WARNING'
    } else {
        foreach ($item in $gpuItems) {
            Write-StatusLine 'GPU Health' "$($item.HealthPercent)% - $($item.Model)" $item.Status
            Write-ColorLine ("GPU Driver              : {0}; VRAM={1} GB" -f $item.DriverVersion, $item.VideoRAMGB)
        }
    }
}

function Show-MicrosoftSection {
    param($Microsoft)
    Write-ConsoleTitle 'MICROSOFT'
    Write-StatusLine 'Windows Activation' $Microsoft.WindowsActivation.Status $Microsoft.WindowsActivation.Health
    Write-StatusLine 'Outlook PST Files' $Microsoft.OutlookPst.Count $Microsoft.OutlookPst.Status
    Write-ColorLine ("PST Total Size           : {0} GB, largest {1} GB" -f $Microsoft.OutlookPst.TotalSizeGB, $Microsoft.OutlookPst.LargestSizeGB)
    foreach ($pst in $Microsoft.OutlookPst.Files) {
        Write-ColorLine ("- {0}; {1} GB; {2}" -f $pst.Name, $pst.SizeGB, $pst.Path)
    }
}

function Show-Thresholds {
    param([string]$Scope = 'ALL')
    Write-ColorLine ''
    if ($Scope -in @('ALL', 'CPU')) { Write-ColorLine 'CPU thresholds: OK < 70%, WARNING 70-89%, CRITICAL >= 90%' Cyan }
    if ($Scope -in @('ALL', 'MEMORY')) { Write-ColorLine 'Memory thresholds: OK < 75%, WARNING 75-89%, CRITICAL >= 90%' Cyan }
    if ($Scope -in @('ALL', 'DISK')) { Write-ColorLine 'Disk thresholds: OK < 80%, WARNING 80-89%, CRITICAL >= 90%' Cyan }
}

function Show-Menu {
    Write-ConsoleTitle $Script:ToolTitle
    Write-ColorLine 'Choose what to check:'
    Write-ColorLine '1. CPU health'
    Write-ColorLine '2. Memory health'
    Write-ColorLine '3. Storage / disk health'
    Write-ColorLine '4. Network / ethernet health'
    Write-ColorLine '5. GPU health'
    Write-ColorLine '6. Microsoft / Outlook health'
    Write-ColorLine '7. System information'
    Write-ColorLine '8. Full health check'
    Write-ColorLine '0. Exit'
}

function Invoke-SelectedCheck {
    param([string]$SelectedChoice)
    switch ($SelectedChoice.ToUpperInvariant()) {
        '1' {
            Write-ProgressStep 0 'Checking CPU'
            $cpu = Get-CpuHealth
            Write-ProgressStep 100 'Displaying CPU health'
            Write-ColorLine ''
            Show-SystemSection $cpu
            Write-ColorLine ''
            Show-CpuSection $cpu
            Show-Thresholds 'CPU'
        }
        '2' {
            Write-ProgressStep 0 'Checking memory'
            $memory = Get-MemoryHealth
            Write-ProgressStep 100 'Displaying memory health'
            Write-ColorLine ''
            Show-MemorySection $memory
            Show-Thresholds 'MEMORY'
        }
        '3' {
            Write-ProgressStep 0 'Checking disk and storage'
            $disk = Get-DiskHealth
            Write-ProgressStep 100 'Displaying storage health'
            Write-ColorLine ''
            Show-StorageSection $disk
            Show-Thresholds 'DISK'
        }
        '4' {
            Write-ProgressStep 0 'Checking network'
            $network = Get-NetworkHealth
            Write-ProgressStep 100 'Displaying network health'
            Write-ColorLine ''
            Show-NetworkSection $network
        }
        '5' {
            Write-ProgressStep 0 'Checking GPU'
            $gpu = Get-GPUInfo
            Write-ProgressStep 100 'Displaying GPU health'
            Write-ColorLine ''
            Show-GpuSection $gpu
        }
        '6' {
            Write-ProgressStep 0 'Checking Microsoft and Outlook'
            $microsoft = Get-MicrosoftHealth
            Write-ProgressStep 100 'Displaying Microsoft health'
            Write-ColorLine ''
            Show-MicrosoftSection $microsoft
        }
        '7' {
            Write-ProgressStep 0 'Checking system information'
            $cpu = Get-CpuHealth
            Write-ProgressStep 100 'Displaying system information'
            Write-ColorLine ''
            Show-SystemSection $cpu
        }
        { $_ -in @('8', 'A', 'ALL') } {
            Write-ConsoleTitle $Script:ToolTitle
            Write-ProgressStep 0 'Starting health check'
            Write-ProgressStep 15 'Checking CPU'
            $cpu = Get-CpuHealth
            Write-ProgressStep 30 'Checking memory'
            $memory = Get-MemoryHealth
            Write-ProgressStep 45 'Checking disk and storage'
            $disk = Get-DiskHealth
            Write-ProgressStep 60 'Checking network'
            $network = Get-NetworkHealth
            Write-ProgressStep 75 'Checking GPU'
            $gpu = Get-GPUInfo
            Write-ProgressStep 90 'Checking Microsoft and Outlook'
            $microsoft = Get-MicrosoftHealth
            Write-ProgressStep 100 'Displaying health specs'
            Write-ColorLine ''
            Show-SystemSection $cpu
            Write-ColorLine ''
            Show-CpuSection $cpu
            Write-ColorLine ''
            Show-MemorySection $memory
            Write-ColorLine ''
            Show-StorageSection $disk
            Write-ColorLine ''
            Show-NetworkSection $network
            Write-ColorLine ''
            Show-GpuSection $gpu
            Write-ColorLine ''
            Show-MicrosoftSection $microsoft
            Show-Thresholds
        }
        '0' {
            Write-ColorLine 'Exiting.'
        }
        default {
            Write-ColorLine "Invalid choice: $SelectedChoice" Red
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($Choice)) {
    Invoke-SelectedCheck $Choice
    return
}

while ($true) {
    Show-Menu
    $selected = Read-Host 'Enter choice'
    Invoke-SelectedCheck $selected
    if ($selected -eq '0') { break }
    Write-ColorLine ''
    Read-Host 'Press Enter to return to the menu'
    Clear-Host
}

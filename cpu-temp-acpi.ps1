<#
JKELTS ACPI CPU Temperature Monitor

Native PowerShell-only temperature monitor using:
  Namespace: root\wmi
  Class    : MSAcpi_ThermalZoneTemperature

No third-party DLLs or kernel drivers are used.

Important:
- Many desktop motherboards do not expose real CPU package/core temperature
  through ACPI thermal zones.
- If Windows firmware/ACPI does not publish thermal zones, this script will
  show a clear fallback message instead of failing.
- Values from MSAcpi_ThermalZoneTemperature may represent ACPI thermal zones,
  not always per-core CPU temperatures.
#>

[CmdletBinding()]
param(
    [int]$RefreshSeconds = 2
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

function ConvertFrom-TenthsKelvin {
    param([double]$Value)

    # ACPI reports temperature as tenths of Kelvin.
    # Celsius = (tenthsKelvin / 10) - 273.15
    [math]::Round((($Value / 10) - 273.15), 1)
}

function Get-AcpiThermalZoneTemperature {
    try {
        $zones = @(Get-CimInstance -Namespace 'root\wmi' -ClassName 'MSAcpi_ThermalZoneTemperature' -ErrorAction Stop)
    } catch {
        return [pscustomobject]@{
            Available = $false
            Message = "ACPI thermal zones are not exposed by this firmware or cannot be queried: $($_.Exception.Message)"
            Zones = @()
        }
    }

    $validZones = @($zones | Where-Object {
        $null -ne $_.CurrentTemperature -and
        [double]$_.CurrentTemperature -gt 0
    } | ForEach-Object {
        $currentC = ConvertFrom-TenthsKelvin -Value ([double]$_.CurrentTemperature)

        [pscustomobject]@{
            InstanceName = $_.InstanceName
            CurrentC = $currentC
            CurrentF = [math]::Round(($currentC * 9 / 5) + 32, 1)
            RawTenthsKelvin = $_.CurrentTemperature
        }
    } | Where-Object {
        # Filter out impossible values caused by broken firmware tables.
        $_.CurrentC -gt -50 -and $_.CurrentC -lt 150
    })

    if ($validZones.Count -eq 0) {
        return [pscustomobject]@{
            Available = $false
            Message = 'No usable ACPI thermal zone temperature values were returned by Windows.'
            Zones = @()
        }
    }

    [pscustomobject]@{
        Available = $true
        Message = 'OK'
        Zones = $validZones
    }
}

while ($true) {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '                 JKELTS ACPI TEMPERATURE CHECK' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ("Updated: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ''

    $result = Get-AcpiThermalZoneTemperature

    if (-not $result.Available) {
        Write-Host 'CPU / ACPI Temperature : Unavailable' -ForegroundColor Yellow
        Write-Host $result.Message -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'This means the motherboard/BIOS did not expose ACPI thermal zone values to Windows.' -ForegroundColor Gray
    } else {
        $highest = ($result.Zones | Measure-Object -Property CurrentC -Maximum).Maximum
        $average = [math]::Round(($result.Zones | Measure-Object -Property CurrentC -Average).Average, 1)

        Write-Host ("Current Highest Temp   : {0} C / {1} F" -f $highest, ([math]::Round(($highest * 9 / 5) + 32, 1))) -ForegroundColor White
        Write-Host ("Average Zone Temp      : {0} C / {1} F" -f $average, ([math]::Round(($average * 9 / 5) + 32, 1))) -ForegroundColor White
        Write-Host ''
        $result.Zones | Format-Table InstanceName, CurrentC, CurrentF, RawTenthsKelvin -AutoSize
    }

    Start-Sleep -Seconds ([math]::Max(1, $RefreshSeconds))
}

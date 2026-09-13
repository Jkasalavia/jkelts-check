# Windows IT Support Health Check

A read-only diagnostic health-check tool for Windows 10, Windows 11, and Windows Server. It collects hardware, OS, network, update, security, service, event log, process, and battery health information, then prints a technician-friendly status and score.

Primary technician command:

```powershell
irm https://tools.example.com/hc | iex
```

Safer inspect-before-execution method:

```powershell
irm https://tools.example.com/hc -OutFile "$env:TEMP\healthcheck.ps1"
notepad "$env:TEMP\healthcheck.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\healthcheck.ps1"
```

Local usage:

```powershell
.\healthcheck.ps1
.\healthcheck.ps1 -Export
.\healthcheck.ps1 -Html
.\healthcheck.ps1 -Export -Html -OutputPath C:\Temp
```

`-Export` creates `HealthCheck-PCNAME-YYYYMMDD-HHMMSS.txt` and `.json`.

`-Html` creates `HealthCheck-PCNAME-YYYYMMDD-HHMMSS.html`.

## Read-Only Scope

The script does not modify Windows settings, services, registry, firewall rules, accounts, passwords, files, antivirus configuration, or installed applications. It only reads diagnostic information. It writes files only when `-Export` or `-Html` is explicitly supplied.

The tool does not collect passwords, browser history, cookies, tokens, Wi-Fi passwords, documents, email content, clipboard data, or saved credentials.

## Checks

- Administrator status
- Computer, OS, BIOS, domain/workgroup, uptime, time zone
- CPU inventory and utilization
- RAM utilization and DIMM information
- Fixed volumes and physical disk health
- GPU model, driver, and video RAM
- Active network adapters, gateway, DNS, internet, and HTTPS/443 tests
- Automatic services that are unexpectedly stopped
- Windows Update service, pending reboot, and recent hotfixes
- Antivirus products, Microsoft Defender status, and firewall profile status
- Recent important System event log entries from the last 24 hours
- Top processes by CPU and memory
- Laptop battery information when present

## Scoring

The score starts at 100 and deductions are applied for warning and critical findings.

```text
90-100   HEALTHY
75-89    WARNING
50-74    POOR
0-49     CRITICAL
```

## Hosting With Nginx

```bash
sudo mkdir -p /opt/windows-healthcheck
sudo cp healthcheck.ps1 /opt/windows-healthcheck/
sudo cp -r web /opt/windows-healthcheck/
sudo cp nginx.conf /etc/nginx/sites-available/windows-healthcheck
sudo ln -s /etc/nginx/sites-available/windows-healthcheck /etc/nginx/sites-enabled/windows-healthcheck
sudo nginx -t
sudo systemctl reload nginx
```

Update `server_name tools.example.com;` and configure HTTPS with your preferred certificate automation.

## Hosting With Docker

```bash
docker build -t windows-healthcheck .
docker run -d --name windows-healthcheck -p 8080:80 windows-healthcheck
curl -i http://localhost:8080/hc
```

`/hc` returns raw PowerShell as `text/plain; charset=utf-8`.

## Hosting With Coolify

1. Create a new project.
2. Add this repository as a Dockerfile-based application.
3. Set the exposed port to `80`.
4. Add the domain `tools.example.com`.
5. Deploy.
6. Test with `curl -i https://tools.example.com/hc`.

## Remote Parameters

The simplest remote command is console-only:

```powershell
irm https://tools.example.com/hc | iex
```

To use parameters remotely, download first:

```powershell
irm https://tools.example.com/hc -OutFile "$env:TEMP\healthcheck.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\healthcheck.ps1" -Export -Html
```

Final technician command template:

```powershell
irm https://YOUR-DOMAIN/hc | iex
```

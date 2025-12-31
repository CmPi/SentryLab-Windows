# SentryLab-Windows

A lightweight PowerShell-based monitoring agent for Windows systems that publishes metrics to MQTT and integrates seamlessly with Home Assistant.

**Metrics collected:**
- **CPU Load** — processor utilization (%)
- **CPU Temperature** — core temperature in °C (via WMI or LibreHardwareMonitor; skipped in active cycle if neither is available)
  - If WMI does not expose a temperature sensor and LibreHardwareMonitor is not configured/reachable, the temp sensor simply does not publish; other sensors still publish.
- **Disk Usage** — per-drive size, free space, and usage percentage
- **Physical Disk Health** — health status and operational status per physical disk (portable across hosts)

## Architecture

```
src/
  config.ps1          — Configuration (MQTT broker, credentials, etc.)
  utils.ps1           — Shared utilities (MQTT publish, metrics collection)
  discovery.ps1       — Home Assistant MQTT Discovery registration
  monitor-passive.ps1 — Lightweight metrics (CPU load + disk usage)
  monitor-active.ps1  — Full metrics (CPU load + temperature + disk usage + disk health)
  decommission.ps1    — Clean up MQTT topics when removing hosts or components
```

### Monitoring Modes

- **Passive** (3–5 min cadence): CPU load + disk volume metrics. Fast, minimal overhead.
- **Active** (15–30 min cadence): Full collection including CPU temperature + physical disk health.
- **Discovery** (once at startup): Publishes sensor metadata to Home Assistant MQTT Discovery.

### Sensor Architecture

**Host-Specific Sensors** (bound to hostname):
- CPU load and temperature
- Volume metrics (C:, D:, E: drives)
- MQTT topics: `windows/{hostname}/*` and `homeassistant/sensor/{hostname}/*/config`

**Portable Component Sensors** (survive host changes):
- Physical disk health and operational status
- Identified by `{manufacturer}_{model}_{serial}` instead of hostname
- MQTT topics: `homeassistant/sensor/{model}_{serial}_{metric}/config`
- History preserved when hardware moves between machines

### MQTT Topics

**Data Topics** (values published by monitor scripts):
```
windows/{hostname}/system/cpu_load       # CPU utilization (%)
windows/{hostname}/temp/cpu              # CPU temperature (°C)
windows/{hostname}/disks                 # JSON: all volume metrics
windows/{hostname}/health                # JSON: all physical disk health data
windows/{hostname}/availability          # online/offline
```

**Discovery Topics** (registered by discovery.ps1):
```
homeassistant/sensor/{hostname}/cpu_load/config
homeassistant/sensor/{hostname}/cpu_temperature/config
homeassistant/sensor/{hostname}/disk_{drive}_free_bytes/config
homeassistant/sensor/{hostname}/disk_{drive}_size_bytes/config
homeassistant/sensor/{hostname}/disk_{drive}_used_percent/config
homeassistant/sensor/{model}_{serial}_health/config
homeassistant/sensor/{model}_{serial}_operational_status/config
```

## Prerequisites

1. **PowerShell 5.0 or higher** (Windows 10/Server 2016+)
2. **mosquitto_pub.exe** — MQTT CLI tool
   - Download: https://mosquitto.org/download/
   - Install to `C:\Program Files\mosquitto\` (or adjust path in scripts)
3. **MQTT Broker** — e.g., Home Assistant's built-in MQTT or separate Mosquitto instance
4. **Home Assistant** (optional but recommended) — for visualization and automation

  ## MQTT Publisher (mosquitto_pub)

  This project only needs the `mosquitto_pub` client (no service). The scripts auto-detect its location in this order:

  - Config override: `$MosquittoPubPath` in `src/config.ps1`
  - Available on `PATH`
  - Common locations: `C:\Program Files\mosquitto\mosquitto_pub.exe`, `C:\mosquitto\mosquitto_pub.exe`
  - Script directory (if placed alongside `utils.ps1`)

  If none are found, the scripts fall back to `mosquitto_pub.exe` and rely on `PATH`.

  Optional override in `config.ps1`:

  ```powershell
  # Use a specific mosquitto_pub path
  $MosquittoPubPath = "C:\Program Files\mosquitto\mosquitto_pub.exe"
  ```

  You can also adjust MQTT QoS via `$MQTT_QOS` (default: 1). Both retained and non-retained publishes respect this setting.

## Installation

### 1. Clone or Download

```powershell
git clone https://github.com/your-org/SentryLab-Windows.git
cd SentryLab-Windows\src
```

### 2. Edit Configuration

```powershell
# Edit config.ps1 with your MQTT broker details
notepad config.ps1
```

Update:
```powershell
$BROKER = "your-mqtt-broker-ip-or-hostname"
$PORT = 1883
$USER = "sentrylab"
$PASS = "your-secure-password"
$HOST_NAME = "your-windows-hostname"  # or leave as $env:COMPUTERNAME
```

### 3. Test Scripts

Run in PowerShell as Administrator (or regular user if script execution is enabled):

**Important: Test in DEBUG mode first!**

```powershell
# Edit config.ps1 and set $DEBUG = $true
notepad config.ps1

# Now run scripts — they will print topics/payloads instead of publishing
.\discovery.ps1 -Verbose
.\monitor-passive.ps1 -Verbose
.\monitor-active.ps1 -Verbose

# Verify output looks correct, then set $DEBUG = $false in config.ps1 before scheduling
```

Check Home Assistant → **Settings** → **Devices & Services** → **MQTT** to verify sensors appear (once $DEBUG is false and discovery runs).

### 4. Schedule with Task Scheduler

**Option A: GUI**

1. Open Task Scheduler (`tasksched.msc`)
2. Create a new task:
   - **Name**: SentryLab-Windows Passive
   - **Trigger**: Recurring, every 5 minutes
   - **Action**: Start a program
     - Program: `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`
     - Arguments: `-NoProfile -ExecutionPolicy Bypass -File "C:\path\to\SentryLab-Windows\src\monitor-passive.ps1"`
   - **Run with highest privileges**: Yes (if needed for CPU temp)

3. Create another task for active monitoring:
   - **Trigger**: Recurring, every 30 minutes (or daily)
   - **Action**: Same, but `monitor-active.ps1`

4. Create a one-time task for discovery (on login or startup):
   - **Trigger**: At startup
   - **Action**: Same, but `discovery.ps1`

**Option B: PowerShell Script**

```powershell
# Run as Administrator

$scriptPath = "C:\path\to\SentryLab-Windows\src"

# Passive task
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 5) -Once -At (Get-Date)
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath\monitor-passive.ps1`""
Register-ScheduledTask -TaskName "SentryLab-Passive" -Trigger $trigger -Action $action -RunLevel Highest

# Active task
$trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 30) -Once -At (Get-Date)
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath\monitor-active.ps1`""
Register-ScheduledTask -TaskName "SentryLab-Active" -Trigger $trigger -Action $action -RunLevel Highest

# Discovery task (one-time at startup)
$trigger = New-ScheduledTaskTrigger -AtStartup
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath\discovery.ps1`""
Register-ScheduledTask -TaskName "SentryLab-Discovery" -Trigger $trigger -Action $action -RunLevel Highest
```

## MQTT Topics

Topics are published under the base: `windows/<HOST_NAME>`

| Metric | Topic | Payload Example |
|--------|-------|-----------------|
| CPU Load | `windows/<host>/system/cpu_load` | `42.5` |
| CPU Temperature | `windows/<host>/temp/cpu` | `65.3` |
| Disk Metrics | `windows/<host>/disks` | `{ "C_SystemDrive_size_bytes": 512110190592, "C_SystemDrive_free_bytes": 135239876608, ... }` |
| Disk Health | `windows/<host>/health` | `{ "WDC_WD10EZEX_Slot1_health": "Healthy", "WDC_WD10EZEX_Slot1_operational_status": "OK", "WDC_WD10EZEX_Slot1_media_type": "HDD" }` |

**Disk Metrics** property naming: `<Letter>_<VolumeLabel>_<metric>`
- Metrics: `size_bytes`, `free_bytes`, `used_bytes`, `used_percent`
- Volume labels are sanitized (spaces/special chars removed)

**Disk Health** property naming: `<DriveName>_Slot<N>_<property>`
- Properties: `health` (Healthy/Warning/Unhealthy), `operational_status`, `media_type`
- Collected in active cycle only (monitor-active.ps1)

## Home Assistant Integration

### Manual Setup (if MQTT Discovery doesn't work)

1. Add to `configuration.yaml`:

```yaml
mqtt:
  sensor:
    - name: "Windows CPU Load"
      state_topic: "windows/DESKTOP-ABC/cpu/load"
      unit_of_measurement: "%"
      state_class: measurement
      
    - name: "Windows CPU Temperature"
      state_topic: "windows/DESKTOP-ABC/cpu/temperature"
      unit_of_measurement: "°C"
      device_class: temperature
      state_class: measurement
      
    - name: "Windows Disk C Free"
      state_topic: "windows/DESKTOP-ABC/disks/C/free"
      unit_of_measurement: "GB"
      state_class: measurement
```

2. Restart Home Assistant

### Automatic (via MQTT Discovery)

Run `discovery.ps1` and sensors will appear under **Settings** → **Devices & Services** → **MQTT**.

## Decommissioning

When removing a monitored host or replacing hardware components, use the decommission script to clean up MQTT topics and Home Assistant entities.

### Host Decommission

Removes all MQTT topics and Home Assistant discovery configs for a complete host:

```powershell
# Preview what will be deleted
.\decommission.ps1 -HostName "MyComputer" -WhatIf

# Actually delete (requires confirmation unless -Force is used)
.\decommission.ps1 -HostName "MyComputer"

# Skip confirmation prompt
.\decommission.ps1 -HostName "MyComputer" -Force
```

This removes:
- All data topics: `windows/{hostname}/*`
- All discovery configs: `homeassistant/sensor/{hostname}/*/config`
- All volume sensors (C:, D:, E:, etc.)
- Legacy formats (old naming conventions with `_slot` suffix)
- Orphaned/empty retained topics

### Component Decommission

For portable hardware components (physical disks that might move between hosts):

```powershell
# Remove a specific disk by its component ID (model_serial)
.\decommission.ps1 -ComponentId "samsung_ssd870_s5r2nf0r123456" -Force
```

This removes only the 2 discovery topics for that component:
- `homeassistant/sensor/{componentId}_health/config`
- `homeassistant/sensor/{componentId}_operational_status/config`

### Host vs Component Architecture

**Host-Specific Sensors** (tied to one machine):
- CPU load, temperature
- Volume metrics (C:, D:, E: drive space)
- Discovery topics: `homeassistant/sensor/{hostname}/{sensor}/config`
- Use `-HostName` to decommission

**Portable Component Sensors** (survive host changes):
- Physical disk health and operational status
- Identified by `{model}_{serial}` instead of hostname
- Discovery topics: `homeassistant/sensor/{model}_{serial}_{metric}/config`
- Use `-ComponentId` to decommission
- History preserved when disk moves to another machine

Example: If you move a Samsung SSD from "PC-A" to "PC-B", its health sensor `samsung_ssd870_s5r2nf0r123456_health` keeps its history in Home Assistant because the unique ID doesn't change.

## Troubleshooting

### Scripts won't run

```powershell
# Allow script execution (run as Administrator)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### mosquitto_pub not found

Install Mosquitto and add to PATH, or adjust path in `utils.ps1`:

```powershell
$mosquittoPath = "C:\Program Files\mosquitto\mosquitto_pub.exe"
& $mosquittoPath ... # Use full path instead of just mosquitto_pub.exe
```

### CPU temperature always null

WMI doesn't expose temperature on all systems. Options:

1. Install **LibreHardwareMonitor** and configure its URL in `config.ps1`
2. Use a hardware-specific monitoring tool (NVIDIA, AMD drivers, etc.)
3. Accept that passive mode won't include temperature

### MQTT publish fails

- Verify broker IP, port, username, password in `config.ps1`
- Test connectivity: `Test-NetConnection -ComputerName <broker> -Port 1883`
- Check broker logs for authentication errors

## Versioning

Follows semantic versioning: `X.Y.Z`
- **X**: Major version (feature/API changes)
- **Y**: Year offset (0 = current year, 1 = next year, etc.)
- **Z**: Day of year (1–366)

Example: `1.0.363` = v1, this year, day 363

## Author

CmPi 

---

**Quick Start:**
```powershell
cd C:\path\to\SentryLab-Windows\src
notepad config.ps1  # Edit MQTT details
.\discovery.ps1     # Register sensors with HA
# Then set up Task Scheduler tasks (see above)
```

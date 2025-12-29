# SentryLab-Windows Configuration
# @file config.ps1
# @description MQTT and monitoring configuration for SentryLab-Windows
# @date 2025-12-29

# ==============================================================================
# MQTT BROKER CONFIGURATION
# ==============================================================================

# MQTT broker hostname or IP address
$BROKER = "homeassistant.local"

# MQTT broker port (typically 1883 for standard, 8883 for TLS)
$PORT = 1883

# MQTT username and password
$USER = "sentrylab"
$PASS = "your_secure_password_here"

# MQTT Quality of Service level (0, 1, or 2)
# 0 = At most once (fastest, no guarantee)
# 1 = At least once (default, recommended)
# 2 = Exactly once (slowest, guaranteed unique delivery)
$MQTT_QOS = 1

# ==============================================================================
# HOST CONFIGURATION
# ==============================================================================

# Hostname/identifier for this Windows machine (used in MQTT topics)
# If empty, uses Windows $env:COMPUTERNAME
$HOST_NAME = $env:COMPUTERNAME

# ==============================================================================
# DEBUG MODE
# ==============================================================================

# Set to $true to print topics and payloads instead of publishing
# Use this to test your configuration before sending data to your MQTT broker
$DEBUG = $false
# HOME ASSISTANT DISCOVERY
# ==============================================================================

# Home Assistant MQTT Discovery prefix (default: homeassistant)
# HA will listen for discovery payloads on this prefix
$HA_BASE_TOPIC = "homeassistant"

# ==============================================================================
# CPU TEMPERATURE COLLECTION (optional)
# ==============================================================================

# Enable to use LibreHardwareMonitor for CPU temperature
# If disabled, falls back to WMI MSAcpi_ThermalZoneTemperature (may not work on all systems)
# URL format: http://localhost:8085 (adjust port/host as needed)
# Leave empty to disable or use WMI fallback
$LibreHardwareMonitorUrl = ""

# ==============================================================================
# MONITORING SCHEDULE
# ==============================================================================

# Configure these in Windows Task Scheduler:
# - monitor-passive.ps1: Run every 3-5 minutes (lightweight metrics)
# - monitor-active.ps1:  Run every 15-30 minutes or daily (includes CPU temp)
# - discovery.ps1:       Run once on startup or manually when sensor config changes

# Example Task Scheduler command:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\src\monitor-passive.ps1"

Write-Host "[CONFIG] SentryLab-Windows configuration loaded: $HOST_NAME on $BROKER`:$PORT" -ForegroundColor Gray

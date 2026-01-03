#
# @file monitor-active.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Active monitoring cycle for SentryLab-Windows (full metrics)
# @date creation 2025-12-29
# @version 1.0.363
# @usage .\monitor-active.ps1
# @notes Collects all metrics: CPU load, CPU temperature, disk usage
#        Publish with retain flag for persistence
#        Typically run on schedule (e.g., Task Scheduler every 5-10 minutes)
#        mosquitto_pub detection & override: see README → "MQTT Publisher (mosquitto_pub)"
#        You can set $MosquittoPubPath in config.ps1 and tune $MQTT_QOS
#

# Load utilities
. "$(Split-Path $PSCommandPath)\utils.ps1"
# Note: do not force global DEBUG/SIMULATE here; respect the early detection above

Write-Host "=== ACTIVE MONITORING CYCLE ===" -ForegroundColor Cyan
$successCount = 0
$failCount = 0

# ==============================================================================
# CPU LOAD
# ==============================================================================

Write-Host "[INFO] Collecting CPU load..." -ForegroundColor Gray
$cpuLoad = Get-CpuLoad
if ($cpuLoad -ne $null) {
    $topic = "$SYSTEM_TOPIC/cpu_load"
    if (Publish-MqttRetain -Topic $topic -Payload $cpuLoad.ToString()) {
        Write-Host "[OK] CPU load: $cpuLoad %" -ForegroundColor Green
        $successCount++
    } else {
        Write-Host "[ERROR] Failed to publish CPU load" -ForegroundColor Red
        $failCount++
    }
} else {
    Write-Host "[ERROR] Failed to get CPU load" -ForegroundColor Red
    $failCount++
}

# ==============================================================================
# CPU TEMPERATURE
# ==============================================================================

Write-Host "[INFO] Collecting CPU temperature..." -ForegroundColor Gray
$cpuTemp = Get-CpuTemperature
if ($cpuTemp -ne $null) {
    $topic = "$TEMP_TOPIC/cpu"
    if (Publish-MqttRetain -Topic $topic -Payload $cpuTemp.ToString()) {
        Write-Host "[OK] CPU temperature: $cpuTemp °C" -ForegroundColor Green
        $successCount++
    } else {
        Write-Host "[ERROR] Failed to publish CPU temperature" -ForegroundColor Red
        $failCount++
    }
} else {
    Write-Host "[WARNING] CPU temperature not available (WMI not exposed on this system)" -ForegroundColor Yellow
}

# ==============================================================================
# DISK METRICS (single JSON object)
# ==============================================================================

Write-Host "[INFO] Collecting disk metrics..." -ForegroundColor Gray
$disks = Get-VolumeMetrics

if ($disks.Count -gt 0) {
    $diskPayload = Build-DiskPayload -Disks $disks
    $topic = "$DISK_TOPIC"
    if (Publish-MqttRetain -Topic $topic -Payload $diskPayload) {
        Write-Host "[OK] Disk metrics published to $topic" -ForegroundColor Green
        $successCount++
    } else {
        Write-Host "[ERROR] Failed to publish disk metrics" -ForegroundColor Red
        $failCount++
    }
} else {
    Write-Host "[ERROR] No disk metrics collected" -ForegroundColor Red
    $failCount++
}

# ==============================================================================
# DISK HEALTH (physical disk status via Get-PhysicalDisk)
# ==============================================================================

Write-Host "[INFO] Collecting disk health..." -ForegroundColor Gray
$diskHealth = Get-DiskHealth

if ($diskHealth.Count -gt 0) {
    $healthPayload = ($diskHealth | ConvertTo-Json -Depth 2 -Compress)
    $topic = "$BASE_TOPIC/health"
    if (Publish-MqttRetain -Topic $topic -Payload $healthPayload) {
        Write-Host "[OK] Disk health published to $topic" -ForegroundColor Green
        $successCount++
    } else {
        Write-Host "[ERROR] Failed to publish disk health" -ForegroundColor Red
        $failCount++
    }
} else {
    Write-Host "[WARNING] No physical disk health data available" -ForegroundColor Yellow
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host ""
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })

if ($failCount -gt 0) {
    exit 1
} else {
    exit 0
}

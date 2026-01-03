#
# @file monitor-passive.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Passive monitoring cycle for SentryLab-Windows (lightweight metrics)
# @date creation 2025-12-29
# @version 1.0.363
# @usage .\monitor-passive.ps1
# @notes Collects lightweight metrics only: CPU load, disk usage (skips CPU temp)
#        Publish with retain flag for persistence
#        Typically run on frequent schedule (e.g., Task Scheduler every 3-5 minutes)
#        mosquitto_pub detection & override: see README → "MQTT Publisher (mosquitto_pub)"
#        You can set $MosquittoPubPath in config.ps1 and tune $MQTT_QOS
#

# Load utilities
. "$(Split-Path $PSCommandPath)\utils.ps1"
# Note: do not force global DEBUG/SIMULATE here; respect the early detection above

Write-Host "=== PASSIVE MONITORING CYCLE ===" -ForegroundColor Cyan
$successCount = 0
$failCount = 0

# ==============================================================================
# SYSTEM METRICS
# ==============================================================================

Write-Host "[INFO] Collecting CPU load..." -ForegroundColor Gray

$payload = Build-SystemPayload -CpuLoad (Get-CpuLoad)
if ($payload -ne $null) {
    if (Publish-MqttNoRetain -Topic "$SYSTEM_TOPIC" -Payload $payload) {
        $successCount++
    } else {
        $failCount++
    }
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
        Write-Host \"[ERROR] Failed to publish disk metrics\" -ForegroundColor Red
        $failCount++
    }
} else {
    Write-Host "[ERROR] No disk metrics collected" -ForegroundColor Red
    $failCount++
}

# ==============================================================================
# NOTE: CPU TEMPERATURE SKIPPED (expensive on passive cycle)
# ==============================================================================
# Temperature collection is deferred to monitor-active.ps1 (runs less frequently)

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

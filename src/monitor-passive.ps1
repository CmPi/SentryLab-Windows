#
# @file monitor-passive.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Passive monitoring cycle for SentryLab-Windows (lightweight metrics)
# @date 2025-12-29
# @version 1.0.363
# @usage .\monitor-passive.ps1
# @notes Collects lightweight metrics only: CPU load, disk usage (skips CPU temp)
#        Publish with retain flag for persistence
#        Typically run on frequent schedule (e.g., Task Scheduler every 3-5 minutes)
#

param(
    [switch] $Verbose
)

# Load utilities
. "$(Split-Path $PSCommandPath)\utils.ps1"

if ($Verbose) {
    $VerbosePreference = "Continue"
}

Write-Host "=== PASSIVE MONITORING CYCLE ===" -ForegroundColor Cyan
$successCount = 0
$failCount = 0

# ==============================================================================
# CPU LOAD (lightweight, always collected)
# ==============================================================================

Write-Host "[INFO] Collecting CPU load..." -ForegroundColor Gray
$cpuLoad = Get-CpuLoad
if ($cpuLoad -ne $null) {
    $topic = "$CPU_TOPIC/load"
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
# DISK METRICS (lightweight, relatively fast)
# ==============================================================================

Write-Host "[INFO] Collecting disk metrics..." -ForegroundColor Gray
$disks = Get-DiskMetrics

if ($disks.Count -gt 0) {
    foreach ($disk in $disks) {
        $driveLetter = $disk.Drive.Replace(':', '')
        
        # Publish only frequently-changing metrics in passive mode
        $passiveTopics = @(
            @{ Topic = "$DISK_TOPIC/$driveLetter/free"; Payload = $disk.FreeGB.ToString() }
            @{ Topic = "$DISK_TOPIC/$driveLetter/used_percent"; Payload = $disk.UsedPercent.ToString() }
        )
        
        foreach ($pub in $passiveTopics) {
            if (Publish-MqttRetain -Topic $pub.Topic -Payload $pub.Payload) {
                Write-Host "[OK] $($pub.Topic) = $($pub.Payload)" -ForegroundColor Green
                $successCount++
            } else {
                Write-Host "[ERROR] Failed to publish $($pub.Topic)" -ForegroundColor Red
                $failCount++
            }
        }
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

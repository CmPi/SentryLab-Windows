#
# @file monitor-active.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Active monitoring cycle for SentryLab-Windows (full metrics)
# @date 2025-12-29
# @version 1.0.363
# @usage .\monitor-active.ps1
# @notes Collects all metrics: CPU load, CPU temperature, disk usage
#        Publish with retain flag for persistence
#        Typically run on schedule (e.g., Task Scheduler every 5-10 minutes)
#

param(
    [switch] $Verbose
)

# Load utilities
. "$(Split-Path $PSCommandPath)\utils.ps1"

if ($Verbose) {
    $VerbosePreference = "Continue"
}

Write-Host "=== ACTIVE MONITORING CYCLE ===" -ForegroundColor Cyan
$successCount = 0
$failCount = 0

# ==============================================================================
# CPU LOAD
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
# CPU TEMPERATURE
# ==============================================================================

Write-Host "[INFO] Collecting CPU temperature..." -ForegroundColor Gray
$cpuTemp = Get-CpuTemperature
if ($cpuTemp -ne $null) {
    $topic = "$CPU_TOPIC/temperature"
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
# DISK METRICS
# ==============================================================================

Write-Host "[INFO] Collecting disk metrics..." -ForegroundColor Gray
$disks = Get-DiskMetrics

if ($disks.Count -gt 0) {
    foreach ($disk in $disks) {
        $driveLetter = $disk.Drive.Replace(':', '')
        
        # Disk Size (published once, relatively static)
        $sizeTopics = @(
            @{ Topic = "$DISK_TOPIC/$driveLetter/size"; Payload = $disk.SizeGB.ToString() }
            @{ Topic = "$DISK_TOPIC/$driveLetter/free"; Payload = $disk.FreeGB.ToString() }
            @{ Topic = "$DISK_TOPIC/$driveLetter/used"; Payload = $disk.UsedGB.ToString() }
            @{ Topic = "$DISK_TOPIC/$driveLetter/used_percent"; Payload = $disk.UsedPercent.ToString() }
        )
        
        foreach ($pub in $sizeTopics) {
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

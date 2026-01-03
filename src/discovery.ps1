#
# @file discovery.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Home Assistant MQTT Discovery for SentryLab-Windows
# @date creation 2025-12-29
# @version 1.0.363
# @usage .\discovery.ps1
# @notes Publishes HA MQTT discovery payloads for all sensors
#        Run once on startup or periodically to refresh discovery metadata
#

# Write-Host "[DEBUG] discovery.ps1 path = $PSCommandPath" -ForegroundColor Cyan

# Load utilities (this will dot-source config.ps1)
. "$(Split-Path $PSCommandPath)\utils.ps1"

Clear-Host

Write-Host "+---------------------------------------+" -ForegroundColor Cyan
Write-Host "| SentryLab-Windows MQTT Discovery      |" -ForegroundColor Cyan
Write-Host "+---------------------------------------+" -ForegroundColor Cyan

Write-Host ""

$device = New-HADevice
$sanHost = Sanitize-Token $HOST_NAME

# --- 1. Register CPU sensor ---

Write-Host ""
Write-Host "CPU Temperature" -ForegroundColor Blue

$cpuTempSensor = New-HASensor `
    -Name (Translate "cpu_temp") `
    -UniqueId "${sanHost}_cpu_temp" `
    -ObjectId "${sanHost}_cpu_temp" `
    -StateTopic "$TEMP_TOPIC" `
    -ValueTemplate "{{ value_json.cpu_temp }}" `
    -DeviceClass "temperature" `
    -StateClass "measurement" `
    -UnitOfMeasurement "°C" `
    -SuggestedDisplayPrecision 1 `
    -Device $device

$cpuTempJson = $cpuTempSensor | ConvertTo-Json -Depth 6 -Compress
$cpuTempDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/cpu_temperature/config"

# Write-Host "[INFO] Before publishing CPU Temperature discovery to"
Publish-MqttRetain -Topic $cpuTempDiscTopic -Payload $cpuTempJson

# ==============================================================================
# CPU LOAD SENSOR
# ==============================================================================

Write-Host ""
Write-Host "CPU Load" -ForegroundColor Blue

$cpuLoadSensor = New-HASensor `
    -Name (Translate "cpu_load") `
    -UniqueId "${sanHost}`_cpu_load" `
    -ObjectId "${sanHost}_cpu_load" `
    -StateTopic "$SYSTEM_TOPIC" `
    -ValueTemplate "{{ value_json.cpu_load }}" `
    -StateClass "measurement" `
    -UnitOfMeasurement "%" `
    -SuggestedDisplayPrecision 1 `
    -Device $device

$cpuLoadJson = $cpuLoadSensor | ConvertTo-Json -Depth 6 -Compress
$cfgTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/cpu_load/config"

Publish-MqttRetain -Topic $cfgTopic -Payload $cpuLoadJson

# ==============================================================================
# REMOVABLE USB DRIVES DETECTION (for analysis only, not published to MQTT)
# ==============================================================================

Write-Host ""
Write-Host "[INFO] Detecting removable USB drives..." -ForegroundColor Blue

$removables = Get-Removables

if ($removables.Count -gt 0) {
    Write-Host "[INFO] Detected $($removables.Count) removable USB drive(s)" -ForegroundColor Green
    Write-Host "[INFO] (Analysis only - not published to MQTT at this time)" -ForegroundColor Gray
} else {
    Write-Host "[INFO] No removable USB drives detected" -ForegroundColor Gray
}

# ==============================================================================
# DISK METRICS (individual sensors per disk)
# ==============================================================================

Write-Host ""
Write-Host "[INFO] Collecting disk list for discovery..." -ForegroundColor Blue

$disks = Get-VolumeMetrics

if ($disks.Count -gt 0) {
    foreach ($disk in $disks) {
        $drive = Sanitize-Token ($disk.Drive)
        # Use only drive letter for IDs (not label) to preserve history if user renames volume
        $diskPrefix = $drive
        
        # Display name: show drive letter (uppercase) with original volume label (keep accents/spaces)
        $driveLetter = $disk.Drive.ToUpper()
        $volLabel = [string]$disk.VolumeLabel
        if ($volLabel -eq "Drive") {
            $displayName = "${driveLetter}:"
        } else {
            $displayName = "${driveLetter}: ($volLabel)"
        }
        
        # Free Space sensor
        $freeSensor = New-HASensor `
            -Name "$(Translate 'disk_free_space') $displayName" `
            -UniqueId "windows_${sanHost}_disk_${diskPrefix}_free_bytes" `
            -ObjectId "${sanHost}_${diskPrefix}_free_bytes" `
            -StateTopic "$DISK_TOPIC" `
            -ValueTemplate "{{ value_json.${diskPrefix}_free_bytes }}" `
            -DeviceClass "data_size" `
            -StateClass "measurement" `
            -UnitOfMeasurement "B" `
            -Device $device
        
        $freeJson = $freeSensor | ConvertTo-Json -Depth 6 -Compress
        $freeDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/disk_${diskPrefix}_free_bytes/config"
        Write-Host "[INFO] Publishing Free Space ${disk.Drive}: discovery to: $freeDiscTopic"
        Publish-MqttRetain -Topic $freeDiscTopic -Payload $freeJson
        
        # Total Size sensor
        $sizeSensor = New-HASensor `
            -Name "$(Translate 'disk_total_size') $displayName" `
            -UniqueId "windows_${sanHost}_disk_${diskPrefix}_size_bytes" `
            -ObjectId "${sanHost}_disk_${diskPrefix}_size_bytes" `
            -StateTopic "$DISK_TOPIC" `
            -ValueTemplate "{{ value_json.${diskPrefix}_size_bytes }}" `
            -DeviceClass "data_size" `
            -StateClass "measurement" `
            -UnitOfMeasurement "B" `
            -Device $device
        
        $sizeJson = $sizeSensor | ConvertTo-Json -Depth 6 -Compress
        $sizeDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/disk_${diskPrefix}_size_bytes/config"
        Write-Host "[INFO] Publishing Total Size ${disk.Drive}: discovery to: $sizeDiscTopic"
        Publish-MqttRetain -Topic $sizeDiscTopic -Payload $sizeJson
        
        # Used Percentage sensor
        $usedPctSensor = New-HASensor `
            -Name "$(Translate 'disk_used_percent') $displayName" `
            -UniqueId "windows_${sanHost}_disk_${diskPrefix}_used_percent" `
            -ObjectId "${sanHost}_disk_${diskPrefix}_used_percent" `
            -StateTopic "$DISK_TOPIC" `
            -ValueTemplate "{{ value_json.${diskPrefix}_used_percent }}" `
            -StateClass "measurement" `
            -UnitOfMeasurement "%" `
            -SuggestedDisplayPrecision 1 `
            -Device $device
        
        $usedPctJson = $usedPctSensor | ConvertTo-Json -Depth 6 -Compress
        $usedPctDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/disk_${diskPrefix}_used_percent/config"
        Write-Host "[INFO] Publishing Used % ${disk.Drive}: discovery to: $usedPctDiscTopic"
        Publish-MqttRetain -Topic $usedPctDiscTopic -Payload $usedPctJson
    }
} else {
    Write-Host "[WARNING] No disks found for discovery" -ForegroundColor Yellow
}

# ==============================================================================
# DISK HEALTH (individual sensors per physical disk)
# ==============================================================================

Write-Host "[INFO] Collecting physical disk health for discovery..." -ForegroundColor Blue
$healthData = Get-DiskHealth
$diskMapping = Get-PhysicalDiskMapping

if ($healthData.Count -gt 0) {
    # Group by disk (each disk has _health, _operational_status, _media_type)
    $diskIds = @()
    foreach ($key in $healthData.Keys) {
        $diskId = $key -replace '_(health|operational_status|media_type)$', ''
        if ($diskIds -notcontains $diskId) {
            $diskIds += $diskId
        }
    }
    
    foreach ($diskId in $diskIds) {
        # Build display name: "Disque 0 (C: & D:)" or just "Disque 0"
        $diskInfo = $diskMapping[$diskId]
        if ($diskInfo -and $diskInfo.DriveLetters.Count -gt 0) {
            $letters = $diskInfo.DriveLetters -join ' & '
            $diskLabel = "Disque $($diskInfo.Number) ($letters)"
        } elseif ($diskInfo) {
            $diskLabel = "Disque $($diskInfo.Number)"
        } else {
            $diskLabel = $diskId
        }
        
        # Health Status sensor - attach host device so HA groups sensors under this machine
        $healthSensor = New-HASensor `
            -Name "$(Translate 'disk_health') $diskLabel" `
            -UniqueId "${diskId}_health" `
            -StateTopic "$BASE_TOPIC/health" `
            -ValueTemplate "{{ value_json.${diskId}_health }}" `
            -Device $device
        
        $healthJson = $healthSensor | ConvertTo-Json -Depth 6 -Compress
        $healthDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/${diskId}_health/config"
        Write-Host "[INFO] Publishing Health $diskLabel discovery to: $healthDiscTopic"
        Publish-MqttRetain -Topic $healthDiscTopic -Payload $healthJson
        
        # Operational Status sensor - attach host device
        $opSensor = New-HASensor `
            -Name "$(Translate 'disk_status') $diskLabel" `
            -UniqueId "${diskId}_operational_status" `
            -StateTopic "$BASE_TOPIC/health" `
            -ValueTemplate "{{ value_json.${diskId}_operational_status }}" `
            -Device $device
        
        $opJson = $opSensor | ConvertTo-Json -Depth 6 -Compress
        $opDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/${diskId}_operational_status/config"
        Write-Host "[INFO] Publishing Status $diskLabel discovery to: $opDiscTopic"
        Publish-MqttRetain -Topic $opDiscTopic -Payload $opJson
    }
} else {
    Write-Host "[WARNING] No physical disk health data found" -ForegroundColor Yellow
}

Write-Host "[INFO] Discovery complete" -ForegroundColor Green

exit 0

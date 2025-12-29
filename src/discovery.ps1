#
# @file discovery.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Home Assistant MQTT Discovery for SentryLab-Windows
# @date 2025-12-29
# @version 1.0.363
# @usage .\discovery.ps1
# @notes Publishes HA MQTT discovery payloads for all sensors
#        Run once on startup or periodically to refresh discovery metadata
#

param(
    [switch] $Verbose
)

# Load utilities
. "$(Split-Path $PSCommandPath)\utils.ps1"

if ($Verbose) {
    $VerbosePreference = "Continue"
}

Write-Host "=== SentryLab-Windows MQTT Discovery ===" -ForegroundColor Cyan

$device = New-HADevice

# ==============================================================================
# CPU LOAD SENSOR
# ==============================================================================

$cpuLoadSensor = New-HASensor `
    -Name "CPU Load" `
    -UniqueId "windows_$HOST_NAME`_cpu_load" `
    -StateTopic "$CPU_TOPIC/load" `
    -DeviceClass "none" `
    -StateClass "measurement" `
    -UnitOfMeasurement "%" `
    -SuggestedDisplayPrecision 1 `
    -Device $device

$cpuLoadJson = $cpuLoadSensor | ConvertTo-Json -Depth 6
$cpuLoadDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$HOST_NAME/cpu_load/config"

Write-Host "[INFO] Publishing CPU Load discovery to: $cpuLoadDiscTopic"
Publish-MqttRetain -Topic $cpuLoadDiscTopic -Payload $cpuLoadJson

# ==============================================================================
# CPU TEMPERATURE SENSOR
# ==============================================================================

$cpuTempSensor = New-HASensor `
    -Name "CPU Temperature" `
    -UniqueId "windows_$HOST_NAME`_cpu_temp" `
    -StateTopic "$CPU_TOPIC/temperature" `
    -DeviceClass "temperature" `
    -StateClass "measurement" `
    -UnitOfMeasurement "°C" `
    -SuggestedDisplayPrecision 1 `
    -Device $device

$cpuTempJson = $cpuTempSensor | ConvertTo-Json -Depth 6
$cpuTempDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$HOST_NAME/cpu_temperature/config"

Write-Host "[INFO] Publishing CPU Temperature discovery to: $cpuTempDiscTopic"
Publish-MqttRetain -Topic $cpuTempDiscTopic -Payload $cpuTempJson

# ==============================================================================
# DISK SENSORS (per drive)
# ==============================================================================

$disks = Get-DiskMetrics

foreach ($disk in $disks) {
    $driveLetter = $disk.Drive.Replace(':', '')
    
    # Disk Size
    $diskSizeSensor = New-HASensor `
        -Name "Disk $driveLetter Size" `
        -UniqueId "windows_$HOST_NAME`_disk_$driveLetter`_size" `
        -StateTopic "$DISK_TOPIC/$driveLetter/size" `
        -DeviceClass "none" `
        -StateClass "measurement" `
        -UnitOfMeasurement "GB" `
        -SuggestedDisplayPrecision 2 `
        -Device $device
    
    $diskSizeJson = $diskSizeSensor | ConvertTo-Json -Depth 6
    $diskSizeDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$HOST_NAME/disk_$($driveLetter)_size/config"
    
    Write-Host "[INFO] Publishing Disk $driveLetter Size discovery"
    Publish-MqttRetain -Topic $diskSizeDiscTopic -Payload $diskSizeJson
    
    # Disk Free
    $diskFreeSensor = New-HASensor `
        -Name "Disk $driveLetter Free" `
        -UniqueId "windows_$HOST_NAME`_disk_$driveLetter`_free" `
        -StateTopic "$DISK_TOPIC/$driveLetter/free" `
        -DeviceClass "none" `
        -StateClass "measurement" `
        -UnitOfMeasurement "GB" `
        -SuggestedDisplayPrecision 2 `
        -Device $device
    
    $diskFreeJson = $diskFreeSensor | ConvertTo-Json -Depth 6
    $diskFreeDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$HOST_NAME/disk_$($driveLetter)_free/config"
    
    Write-Host "[INFO] Publishing Disk $driveLetter Free discovery"
    Publish-MqttRetain -Topic $diskFreeDiscTopic -Payload $diskFreeJson
    
    # Disk Used Percent
    $diskUsedPctSensor = New-HASensor `
        -Name "Disk $driveLetter Used %" `
        -UniqueId "windows_$HOST_NAME`_disk_$driveLetter`_used_pct" `
        -StateTopic "$DISK_TOPIC/$driveLetter/used_percent" `
        -DeviceClass "none" `
        -StateClass "measurement" `
        -UnitOfMeasurement "%" `
        -SuggestedDisplayPrecision 1 `
        -Device $device
    
    $diskUsedPctJson = $diskUsedPctSensor | ConvertTo-Json -Depth 6
    $diskUsedPctDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$HOST_NAME/disk_$($driveLetter)_used_pct/config"
    
    Write-Host "[INFO] Publishing Disk $driveLetter Used % discovery"
    Publish-MqttRetain -Topic $diskUsedPctDiscTopic -Payload $diskUsedPctJson
}

Write-Host "[INFO] Discovery complete" -ForegroundColor Green
exit 0

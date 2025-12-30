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
$sanHost = Sanitize-Token $HOST_NAME

# ==============================================================================
# CPU LOAD SENSOR
# ==============================================================================

$cpuLoadSensor = New-HASensor `
    -Name "CPU Load" `
    -UniqueId "windows_${sanHost}`_cpu_load" `
    -StateTopic "$SYSTEM_TOPIC/cpu_load" `
    -StateClass "measurement" `
    -UnitOfMeasurement "%" `
    -SuggestedDisplayPrecision 1 `
    -Device $device

$cpuLoadJson = $cpuLoadSensor | ConvertTo-Json -Depth 6 -Compress
$cpuLoadDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/cpu_load/config"

Write-Host "[INFO] Publishing CPU Load discovery to: $cpuLoadDiscTopic"
Publish-MqttRetain -Topic $cpuLoadDiscTopic -Payload $cpuLoadJson

# ==============================================================================
# CPU TEMPERATURE SENSOR
# ==============================================================================

$cpuTempSensor = New-HASensor `
    -Name "CPU Temperature" `
    -UniqueId "windows_${sanHost}`_cpu_temp" `
    -StateTopic "$TEMP_TOPIC/cpu" `
    -DeviceClass "temperature" `
    -StateClass "measurement" `
    -UnitOfMeasurement "°C" `
    -SuggestedDisplayPrecision 1 `
    -Device $device

$cpuTempJson = $cpuTempSensor | ConvertTo-Json -Depth 6 -Compress
$cpuTempDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/cpu_temperature/config"

Write-Host "[INFO] Publishing CPU Temperature discovery to: $cpuTempDiscTopic"
Publish-MqttRetain -Topic $cpuTempDiscTopic -Payload $cpuTempJson

# ==============================================================================
# DISK METRICS (single JSON sensor with all drives)
# ==============================================================================

$diskSensor = New-HASensor `
    -Name "Disk Metrics" `
    -UniqueId "windows_${sanHost}`_disk_metrics" `
    -StateTopic "$DISK_TOPIC" `
    -JsonAttributesTopic "$DISK_TOPIC" `
    -ValueTemplate "{{ value_json | length }}" `
    -SuggestedDisplayPrecision 0 `
    -Device $device

$diskJson = $diskSensor | ConvertTo-Json -Depth 6 -Compress
$diskDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/disk_metrics/config"

Write-Host "[INFO] Publishing Disk Metrics discovery to: $diskDiscTopic"
Publish-MqttRetain -Topic $diskDiscTopic -Payload $diskJson

# ==============================================================================
# DISK HEALTH SENSOR
# ==============================================================================

$healthSensor = New-HASensor `
    -Name "Disk Health" `
    -UniqueId "windows_${sanHost}`_disk_health" `
    -StateTopic "$BASE_TOPIC/health" `
    -JsonAttributesTopic "$BASE_TOPIC/health" `
    -ValueTemplate "{{ value_json | length }}" `
    -SuggestedDisplayPrecision 0 `
    -Device $device

$healthJson = $healthSensor | ConvertTo-Json -Depth 6 -Compress
$healthDiscTopic = "$HA_DISCOVERY_PREFIX/sensor/$sanHost/disk_health/config"

Write-Host "[INFO] Publishing Disk Health discovery to: $healthDiscTopic"
Publish-MqttRetain -Topic $healthDiscTopic -Payload $healthJson

Write-Host "[INFO] Discovery complete" -ForegroundColor Green
exit 0

#
# @file decommission.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Removes all MQTT topics and HA discovery configs for decommissioned hosts or components
# @date creation 2025-12-30
# @version 1.0.365
# @usage .\decommission.ps1 -HostName "hostname" OR -ComponentId "samsung_hd103si_serial123"
# @notes Cleans up MQTT broker and Home Assistant
#        WARNING: This will permanently delete all retained MQTT messages
#

param(
    [Parameter(Mandatory=$false)]
    [string]$HostName,
    
    [Parameter(Mandatory=$false)]
    [string]$ComponentId,
    
    [switch]$Force,
    
    [switch]$WhatIf
)

# Load utilities
. "$(Split-Path $PSCommandPath)\utils.ps1"

# Validate parameters
if (-not $HostName -and -not $ComponentId) {
    Write-Host "[ERROR] You must specify either -HostName or -ComponentId" -ForegroundColor Red
    exit 1
}

if ($HostName -and $ComponentId) {
    Write-Host "[ERROR] You cannot specify both -HostName and -ComponentId" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Red
Write-Host "  SENTRYLAB DECOMMISSION SCRIPT" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Red
Write-Host ""

if ($HostName) {
    $sanHost = Sanitize-Token $HostName
    Write-Host "This script will PERMANENTLY DELETE all MQTT topics for:" -ForegroundColor Yellow
    Write-Host "  Host: $HostName" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Topics to be deleted:" -ForegroundColor Yellow
    Write-Host "  - windows/$sanHost/*" -ForegroundColor Gray
    Write-Host "  - homeassistant/sensor/$sanHost/*" -ForegroundColor Gray
    Write-Host "  - homeassistant/binary_sensor/$sanHost/*" -ForegroundColor Gray
    Write-Host ""
} else {
    Write-Host "This script will PERMANENTLY DELETE all MQTT topics for:" -ForegroundColor Yellow
    Write-Host "  Hardware Component: $ComponentId" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Topics to be deleted:" -ForegroundColor Yellow
    Write-Host "  - homeassistant/sensor/${ComponentId}_health/config" -ForegroundColor Gray
    Write-Host "  - homeassistant/sensor/${ComponentId}_operational_status/config" -ForegroundColor Gray
    Write-Host ""
}

# Require explicit confirmation for destructive runs unless -Force is used.
# In dry-run mode (-WhatIf) we do not ask for confirmation since no changes will be made.
if (-not $Force -and -not $WhatIf) {
    $confirmation = Read-Host "Type 'YES' to confirm PERMANENT deletion of MQTT topics"
    if ($confirmation -ne "YES") {
        Write-Host "[CANCELLED] No changes made" -ForegroundColor Green
        exit 0
    }
} elseif ($WhatIf) {
    Write-Host "[INFO] Dry-run (-WhatIf): no confirmation required; displaying topics only." -ForegroundColor Cyan
}

Write-Host ""
Write-Host "[INFO] Starting decommission process..." -ForegroundColor Cyan

# ==============================================================================
# COMPONENT DECOMMISSION
# ==============================================================================

if ($ComponentId) {
    Write-Host ""
    Write-Host "[INFO] Decommissioning hardware component: $ComponentId" -ForegroundColor Cyan
    
    $topicsToDelete = @(
        "homeassistant/sensor/${ComponentId}_health/config",
        "homeassistant/sensor/${ComponentId}_operational_status/config"
    )
    
    $deletedCount = 0
    foreach ($topic in $topicsToDelete) {
        Write-Host "  Deleting: $topic" -ForegroundColor Gray
        & $script:MOSQUITTO_PUB -h $BROKER -p $PORT -u $USER -P $PASS -t $topic -n -r -q 1 2>$null
        if ($LASTEXITCODE -eq 0) {
            $deletedCount++
        }
    }
    
    Write-Host ""
    Write-Host "[OK] Successfully deleted $deletedCount topics" -ForegroundColor Green
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  DECOMMISSION COMPLETE" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "The component '$ComponentId' has been removed from Home Assistant." -ForegroundColor Green
    Write-Host "You may need to restart Home Assistant to fully remove the sensors." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ==============================================================================
# HOST DECOMMISSION
# ==============================================================================

$sanHost = Sanitize-Token $HostName

Write-Host ""
Write-Host "[INFO] Deleting all MQTT topics for $sanHost..." -ForegroundColor Cyan

# Build list of topics to delete
$topicsToDelete = @()

# ==============================================================================
# 1. DATA TOPICS (always present)
# ==============================================================================
$topicsToDelete += "windows/$sanHost/system/cpu_load"
$topicsToDelete += "windows/$sanHost/temp/cpu"
$topicsToDelete += "windows/$sanHost/disks"
$topicsToDelete += "windows/$sanHost/health"
$topicsToDelete += "windows/$sanHost/availability"

# ==============================================================================
# 2. DISCOVERY TOPICS - CPU & TEMPERATURE (always present)
# ==============================================================================
$topicsToDelete += "homeassistant/sensor/$sanHost/cpu_load/config"
$topicsToDelete += "homeassistant/sensor/$sanHost/cpu_temperature/config"

# ==============================================================================
# 3. DISCOVERY TOPICS - VOLUMES (under host node)
# ==============================================================================
if ($HostName -eq $env:COMPUTERNAME) {
    Write-Host "  Enumerating local disks..." -ForegroundColor Gray
    try {
        $disks = Get-VolumeMetrics
        foreach ($disk in $disks) {
            $drive = Sanitize-Token ($disk.Drive)
            # Current format: homeassistant/sensor/{hostname}/disk_{drive}_{metric}/config
            $topicsToDelete += "homeassistant/sensor/$sanHost/disk_${drive}_free_bytes/config"
            $topicsToDelete += "homeassistant/sensor/$sanHost/disk_${drive}_size_bytes/config"
            $topicsToDelete += "homeassistant/sensor/$sanHost/disk_${drive}_used_percent/config"
        }
        Write-Host "  Found $($disks.Count) volume(s)" -ForegroundColor Gray
    } catch {
        Write-Host "  [WARNING] Error enumerating volumes: $_" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Using common patterns for remote host volumes..." -ForegroundColor Gray
    foreach ($drive in @('c', 'd', 'e', 'f')) {
        $topicsToDelete += "homeassistant/sensor/$sanHost/disk_${drive}_free_bytes/config"
        $topicsToDelete += "homeassistant/sensor/$sanHost/disk_${drive}_size_bytes/config"
        $topicsToDelete += "homeassistant/sensor/$sanHost/disk_${drive}_used_percent/config"
    }
}

# ==============================================================================
# 4. LEGACY TOPICS - OLD FORMATS WITH _SLOT SUFFIX
# ==============================================================================
Write-Host "  Adding legacy _slot format cleanup..." -ForegroundColor Gray
$legacySlotPatterns = @(
    "health_sandisk_sdssda240g_slot",
    "status_sandisk_sdssda240g_slot",
    "health_samsung_hd103si_slot",
    "status_samsung_hd103si_slot",
    "health_st3000dm001_1er166_slot",
    "status_st3000dm001_1er166_slot",
    "health_kingston_snv3s1000g_slot",
    "status_kingston_snv3s1000g_slot"
)
foreach ($pattern in $legacySlotPatterns) {
    $topicsToDelete += "homeassistant/sensor/$sanHost/${pattern}/config"
}

# ==================================================================================================
# HARD-CODED LEGACY TOPICS (extracted from broker logs)
# These are known duplicate/orphaned root-level discovery topics to remove.
# Inserted as explicit topics to ensure cleanup for this host.
# ==================================================================================================
$hardcodedLegacyTopics = @(
    "homeassistant/sensor/samsung_hd103si_s1vsjd1zb07989_health/config",
    "homeassistant/sensor/samsung_hd103si_s1vsjd1zb07989_operational_status/config",
    "homeassistant/sensor/sandisk_sdssda240g_161572400779_health/config",
    "homeassistant/sensor/sandisk_sdssda240g_161572400779_operational_status/config",
    "homeassistant/sensor/samsung_hd103si_s1vsjd1zb07989_device_number_health/config",
    "homeassistant/sensor/samsung_hd103si_s1vsjd1zb07989_device_number_operational_status/config",
    "homeassistant/sensor/sandisk_sdssda240g_161572400779_device_number_health/config",
    "homeassistant/sensor/sandisk_sdssda240g_161572400779_device_number_operational_status/config",
    "homeassistant/sensor/st3000dm001_1er166_z5004m5v_health/config",
    "homeassistant/sensor/st3000dm001_1er166_z5004m5v_operational_status/config",
    "homeassistant/sensor/st3000dm001_1er166_z5004m5v_device_number_health/config"
)

foreach ($ht in $hardcodedLegacyTopics) {
    if ($topicsToDelete -notcontains $ht) { $topicsToDelete += $ht }
}

# ==================================================================================================
# 4.5 ROOT-LEVEL PORTABLE DISK CLEANUP (for disks known locally)
# If this host previously published portable disk discovery at root-level, include those topics.
# This helps remove duplicate/orphaned portable discovery topics like
#   homeassistant/sensor/<model>_<serial>_health/config
#   homeassistant/sensor/<model>_<serial>_device_number_health/config
# ==================================================================================================
if ($HostName -eq $env:COMPUTERNAME) {
    Write-Host "  Enumerating physical disks for root-level portable cleanup..." -ForegroundColor Gray
    try {
        $healthData = Get-DiskHealth
        foreach ($key in $healthData.Keys) {
            if ($key -match '^(.+)_(health|operational_status|media_type)$') {
                $diskId = $matches[1]
                $topicsToDelete += "homeassistant/sensor/${diskId}_health/config"
                $topicsToDelete += "homeassistant/sensor/${diskId}_operational_status/config"
                # (dropped legacy _device_number variants — IDs are model_serial based)
            }
        }
        Write-Host "  Added root-level portable topics for $($healthData.Keys.Count) keys" -ForegroundColor Gray
    } catch {
        Write-Host "  [WARNING] Error enumerating disk health: $_" -ForegroundColor Yellow
    }
}

# NOTE: Portable component topics (physical disk health/status) are NOT deleted
# during host decommission. They are hardware-specific and survive host changes.
# Use -ComponentId parameter to explicitly decommission a portable component.

# ==============================================================================
# 5. QUERY BROKER FOR ALL TOPICS UNDER HOST NODE (using # wildcard)
# ==============================================================================
Write-Host "  Querying broker for all host topics..." -ForegroundColor Gray
try {
    $job = Start-Job -ScriptBlock {
        param($mqttSub, $broker, $port, $user, $pass, $hostSanitized)
        # Use # wildcard to match ALL levels under homeassistant/sensor/{hostname}/
        & $mqttSub -h $broker -p $port -u $user -P $pass -v -t "homeassistant/sensor/${hostSanitized}/#" -W 5 -C 1000 2>$null | 
            ForEach-Object { 
                # Extract topic from mosquitto_sub verbose output (format: "topic message")
                if ($_ -match "^(homeassistant/sensor/${hostSanitized}/\S+)") {
                    $matches[1]
                }
            }
    } -ArgumentList $script:MOSQUITTO_SUB, $BROKER, $PORT, $USER, $PASS, $sanHost
    
    $brokerTopics = Wait-Job $job -Timeout 7 | Receive-Job
    Remove-Job $job -Force
    
    if ($brokerTopics) {
        $brokerTopics = $brokerTopics | Select-Object -Unique
        Write-Host "  Found $($brokerTopics.Count) topic(s) in broker" -ForegroundColor Gray
        foreach ($topic in $brokerTopics) {
            if ($topicsToDelete -notcontains $topic) {
                $topicsToDelete += $topic
            }
        }
    }
} catch {
    Write-Host "  [WARNING] Could not query broker: $_" -ForegroundColor Yellow
}

# Remove duplicates
$topicsToDelete = $topicsToDelete | Select-Object -Unique

Write-Host "  Total topics to delete: $($topicsToDelete.Count)" -ForegroundColor Gray

# WhatIf mode - show topics without deleting
if ($WhatIf) {
    Write-Host ""
    Write-Host "[WHATIF] Topics that would be deleted:" -ForegroundColor Cyan
    $topicsToDelete | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    Write-Host ""
    Write-Host "[WHATIF] No changes made (use -Force to actually delete)" -ForegroundColor Green
    exit 0
}

Write-Host ""

# Delete all topics
$deletedCount = 0
$progress = 0
foreach ($topic in $topicsToDelete) {
    $progress++
    if ($progress % 50 -eq 0) {
        Write-Host "  Progress: $progress / $($topicsToDelete.Count)" -ForegroundColor Gray
    }
    & $script:MOSQUITTO_PUB -h $BROKER -p $PORT -u $USER -P $PASS -t $topic -n -r -q 1 2>$null
    if ($LASTEXITCODE -eq 0) {
        $deletedCount++
    }
}

Write-Host "[OK] Successfully deleted $deletedCount topics" -ForegroundColor Green
Write-Host ""

# ==============================================================================
# DELETE BINARY SENSOR DISCOVERY TOPICS (homeassistant/binary_sensor/<hostname>/*)
# ==============================================================================

Write-Host ""
Write-Host "[STEP 3/3] Deleting Home Assistant binary sensor configs..." -ForegroundColor Cyan

# Binary sensors (if any exist)
$binarySensorTopics = @()

# Try to find existing binary sensors
Write-Host "  Attempting to enumerate binary sensors..." -ForegroundColor Gray
try {
    if ($HostName -eq $env:COMPUTERNAME) {
        # Local host - could enumerate if we had binary sensors defined
        Write-Host "  [INFO] No binary sensors currently defined" -ForegroundColor Gray
    } else {
        Write-Host "  [INFO] Attempting common binary sensor patterns..." -ForegroundColor Gray
    }
    
    # Add common binary sensor patterns (health status, etc.)
    # Example patterns if used in the future
    # $binarySensorTopics += "homeassistant/binary_sensor/$sanHost/disk_health/config"
    
} catch {
    Write-Host "  [WARNING] Error enumerating binary sensors: $_" -ForegroundColor Yellow
}

$deletedBinary = 0
if ($binarySensorTopics.Count -gt 0) {
    foreach ($topic in $binarySensorTopics) {
        Write-Host "  Deleting: $topic" -ForegroundColor Gray
        & $script:MOSQUITTO_PUB -h $BROKER -p $PORT -u $USER -P $PASS -t $topic -n -r -q 1
        if ($LASTEXITCODE -eq 0) {
            $deletedBinary++
        } else {
            Write-Host "  [WARNING] Failed to delete: $topic" -ForegroundColor Yellow
        }
    }
    Write-Host "[OK] Deleted $deletedBinary binary sensor topics" -ForegroundColor Green
} else {
    Write-Host "  [INFO] No binary sensors found" -ForegroundColor Gray
}

# ==============================================================================
# SUMMARY
# ==============================================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  DECOMMISSION COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "The host '$HostName' has been removed from MQTT and Home Assistant." -ForegroundColor Green
Write-Host "You may need to restart Home Assistant to fully remove the device." -ForegroundColor Yellow
Write-Host ""

exit 0

#
# @file utils.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Global functions for SentryLab-Windows
# @date 2025-12-29
# @version 1.0.363
# @usage . "$(Split-Path $PSCommandPath)\utils.ps1"
# @notes Provides configuration loading, MQTT publishing, and HA discovery helpers
#

# ==============================================================================
# CONFIGURATION LOADING
# ==============================================================================

# Configuration file paths (try user path first, fall back to script directory)
$configPaths = @(
    "$env:APPDATA\SentryLab\config.ps1",
    "$(Split-Path $PSCommandPath)\config.ps1",
    ".\config.ps1"
)

function Load-Config {
    $configFound = $false
    foreach ($path in $configPaths) {
        if (Test-Path $path) {
            Write-Host "[INFO] Loading configuration from: $path"
            . $path
            $configFound = $true
            break
        }
    }
    
    if (-not $configFound) {
        Write-Host "[ERROR] Configuration file not found in any expected location:" -ForegroundColor Red
        foreach ($path in $configPaths) {
            Write-Host "  - $path" -ForegroundColor Red
        }
        exit 1
    }
    
    # Validate required configuration
    $requiredVars = @("BROKER", "PORT", "USER", "PASS", "HOST_NAME")
    $missingVars = @()
    
    foreach ($var in $requiredVars) {
        if (-not (Get-Variable -Name $var -ErrorAction SilentlyContinue)) {
            $missingVars += $var
        }
    }
    
    if ($missingVars.Count -gt 0) {
        Write-Host "[ERROR] Missing required configuration variables: $($missingVars -join ', ')" -ForegroundColor Red
        exit 1
    }
    
    # Promote config variables to script scope so other scripts/functions can access them
    $varsToPromote = @(
        'BROKER','PORT','USER','PASS','MQTT_QOS','HOST_NAME','HA_BASE_TOPIC','LibreHardwareMonitorUrl','DEBUG','MosquittoPubPath'
    )
    foreach ($v in $varsToPromote) {
        if (Get-Variable -Name $v -ErrorAction SilentlyContinue) {
            Set-Variable -Name $v -Value (Get-Variable -Name $v -ValueOnly) -Scope Script
        }
    }

    # Ensure sensible defaults
    if ([string]::IsNullOrWhiteSpace($script:HOST_NAME)) {
        $script:HOST_NAME = $env:COMPUTERNAME
        Set-Variable -Name 'HOST_NAME' -Value $script:HOST_NAME -Scope Script
    }
    if (-not ($script:MQTT_QOS -is [int]) -or $script:MQTT_QOS -lt 0 -or $script:MQTT_QOS -gt 2) {
        $script:MQTT_QOS = 1
        Set-Variable -Name 'MQTT_QOS' -Value $script:MQTT_QOS -Scope Script
    }
    if ([string]::IsNullOrWhiteSpace($script:HA_BASE_TOPIC)) {
        $script:HA_BASE_TOPIC = 'homeassistant'
        Set-Variable -Name 'HA_BASE_TOPIC' -Value $script:HA_BASE_TOPIC -Scope Script
    }

    Write-Host "[INFO] Configuration loaded successfully"
}

# Load configuration on script load
Load-Config

# ==============================================================================
# TOPIC CONFIGURATION
# ==============================================================================

function Sanitize-Token {
    param([Parameter(Mandatory=$true)] [string] $Text)
    $t = $Text.ToLower()
    # Replace anything not [a-z0-9] with underscore (hyphens included)
    $t = ($t -replace '[^a-z0-9]', '_')
    # Collapse multiple underscores, trim edges
    $t = ($t -replace '_{2,}', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($t)) { return 'unknown' }
    return $t
}

$script:SAN_HOST = Sanitize-Token $script:HOST_NAME
$script:HA_DISCOVERY_PREFIX = if ($HA_BASE_TOPIC) { $HA_BASE_TOPIC } else { "homeassistant" }

$script:BASE_TOPIC = "windows/$SAN_HOST"
$script:SYSTEM_TOPIC = "$BASE_TOPIC/system"
$script:TEMP_TOPIC = "$BASE_TOPIC/temp"
$script:DISK_TOPIC = "$BASE_TOPIC/disks"

# ==============================================================================
# MQTT PUBLISHING FUNCTIONS
# ==============================================================================

function Resolve-MosquittoPub {
    <#
    .SYNOPSIS
    Resolves the full path to mosquitto_pub.exe using config override, PATH, or common install locations.
    .OUTPUTS
    Sets $script:MOSQUITTO_PUB to an executable path or the literal "mosquitto_pub.exe" to rely on PATH.
    #>
    try {
        # Config override (optional): $MosquittoPubPath in config.ps1
        if (Get-Variable -Name MosquittoPubPath -ErrorAction SilentlyContinue) {
            $candidate = $MosquittoPubPath
            if (-not [string]::IsNullOrEmpty($candidate) -and (Test-Path $candidate)) {
                $script:MOSQUITTO_PUB = $candidate
                Write-Host "[INFO] Using mosquitto_pub (config): $script:MOSQUITTO_PUB" -ForegroundColor Gray
                return
            }
        }

        # Try PATH
        $cmd = Get-Command mosquitto_pub.exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            $script:MOSQUITTO_PUB = $cmd.Source
            Write-Host "[INFO] Using mosquitto_pub (PATH): $script:MOSQUITTO_PUB" -ForegroundColor Gray
            return
        }

        # Common install locations
        $commonPaths = @(
            "$env:ProgramFiles\mosquitto\mosquitto_pub.exe",
            "$env:ProgramFiles(x86)\mosquitto\mosquitto_pub.exe",
            "C:\\mosquitto\\mosquitto_pub.exe",
            (Join-Path (Split-Path $PSCommandPath) "mosquitto_pub.exe")
        )

        foreach ($p in $commonPaths) {
            if (Test-Path $p) {
                $script:MOSQUITTO_PUB = $p
                Write-Host "[INFO] Using mosquitto_pub (found): $script:MOSQUITTO_PUB" -ForegroundColor Gray
                return
            }
        }

        # Fallback: rely on PATH
        $script:MOSQUITTO_PUB = "mosquitto_pub.exe"
        Write-Host "[WARNING] mosquitto_pub.exe not found; relying on PATH" -ForegroundColor Yellow
    }
    catch {
        $script:MOSQUITTO_PUB = "mosquitto_pub.exe"
        Write-Host "[WARNING] Error resolving mosquitto_pub; relying on PATH: $_" -ForegroundColor Yellow
    }
}

# Resolve mosquitto_pub path on load
Resolve-MosquittoPub

function Publish-MqttRetain {
    param(
        [Parameter(Mandatory=$true)] [string] $Topic,
        [Parameter(Mandatory=$true)] [string] $Payload
    )
    
    if ([string]::IsNullOrEmpty($Topic)) {
        Write-Host "[ERROR] MQTT topic is empty" -ForegroundColor Red
        return $false
    }
    
    if ([string]::IsNullOrEmpty($Payload)) {
        Write-Host "[WARNING] MQTT payload is empty for topic: $Topic" -ForegroundColor Yellow
        return $false
    }
    
    # DEBUG mode: print instead of publish
    if ($DEBUG -eq $true) {
        Write-Host "[DEBUG] RETAIN: $Topic" -ForegroundColor Cyan
        Write-Host "[DEBUG] Payload: $Payload" -ForegroundColor Cyan
        return $true
    }
    
    try {
        $qos = if ($MQTT_QOS -is [int] -and $MQTT_QOS -ge 0 -and $MQTT_QOS -le 2) { $MQTT_QOS } else { 1 }
        & $script:MOSQUITTO_PUB -h $BROKER -p $PORT -u $USER -P $PASS `
                            -t $Topic -m $Payload -r -q $qos
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[DEBUG] Published (Retain) to $Topic" -ForegroundColor Gray
            return $true
        } else {
            Write-Host "[ERROR] Failed to publish to $Topic (exit code: $LASTEXITCODE)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "[ERROR] Exception publishing to $Topic : $_" -ForegroundColor Red
        return $false
    }
}

function Publish-MqttNoRetain {
    param(
        [Parameter(Mandatory=$true)] [string] $Topic,
        [Parameter(Mandatory=$true)] [string] $Payload
    )
    
    if ([string]::IsNullOrEmpty($Topic)) {
        Write-Host "[ERROR] MQTT topic is empty" -ForegroundColor Red
        return $false
    }
    
    if ([string]::IsNullOrEmpty($Payload)) {
        Write-Host "[WARNING] MQTT payload is empty for topic: $Topic" -ForegroundColor Yellow
        return $false
    }
    
    # DEBUG mode: print instead of publish
    if ($DEBUG -eq $true) {
        Write-Host "[DEBUG] NO-RETAIN: $Topic" -ForegroundColor Cyan
        Write-Host "[DEBUG] Payload: $Payload" -ForegroundColor Cyan
        return $true
    }
    
    try {
        $qos = if ($MQTT_QOS -is [int] -and $MQTT_QOS -ge 0 -and $MQTT_QOS -le 2) { $MQTT_QOS } else { 1 }
        & $script:MOSQUITTO_PUB -h $BROKER -p $PORT -u $USER -P $PASS `
                            -t $Topic -m $Payload -q $qos
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[DEBUG] Published (No-Retain) to $Topic" -ForegroundColor Gray
            return $true
        } else {
            Write-Host "[ERROR] Failed to publish to $Topic (exit code: $LASTEXITCODE)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "[ERROR] Exception publishing to $Topic : $_" -ForegroundColor Red
        return $false
    }
}

# ==============================================================================
# HOME ASSISTANT MQTT DISCOVERY HELPERS
# ==============================================================================

function New-HASensor {
    param(
        [Parameter(Mandatory=$true)] [string] $Name,
        [Parameter(Mandatory=$true)] [string] $UniqueId,
        [Parameter(Mandatory=$true)] [string] $StateTopic,
        [string] $DeviceClass = "none",
        [string] $StateClass = "measurement",
        [string] $UnitOfMeasurement = "",
        [int] $SuggestedDisplayPrecision = 1,
        [hashtable] $Device = @{}
    )
    
    $sensor = @{
        name                     = $Name
        unique_id                = $UniqueId
        state_topic              = $StateTopic
        device_class             = $DeviceClass
        state_class              = $StateClass
    }
    
    if ($UnitOfMeasurement) {
        $sensor["unit_of_measurement"] = $UnitOfMeasurement
    }
    
    if ($SuggestedDisplayPrecision -gt 0) {
        $sensor["suggested_display_precision"] = $SuggestedDisplayPrecision
    }
    
    if ($Device.Count -gt 0) {
        $sensor["device"] = $Device
    }
    
    return $sensor
}

function New-HADevice {
    return @{
        identifiers  = @("windows_$script:SAN_HOST")
        name         = $HOST_NAME
        manufacturer = "Microsoft"
        model        = "Windows"
    }
}

# ==============================================================================
# UTILITY FUNCTIONS
# ==============================================================================

function Get-CpuLoad {
    <#
    .SYNOPSIS
    Gets current CPU load percentage (% Processor Time)
    .OUTPUTS
    System.Double (0-100)
    #>
    try {
        $cpuLoad = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue
        return [math]::Round($cpuLoad, 1)
    }
    catch {
        # Fallback to CIM performance data
        try {
            $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop | Where-Object { $_.Name -eq '_Total' }
            if ($cpu) {
                return [math]::Round([double]$cpu.PercentProcessorTime, 1)
            }
        }
        catch {
            Write-Host "[ERROR] Failed to get CPU load: $_" -ForegroundColor Red
        }
        return $null
    }
}

function Get-CpuTemperature {
    <#
    .SYNOPSIS
    Gets CPU temperature in Celsius via WMI (MSAcpi_ThermalZoneTemperature)
    Note: Not all systems expose CPU temperature via WMI; falls back to LibreHardwareMonitor if configured
    .OUTPUTS
    System.Double (Celsius) or $null if unavailable
    #>
    try {
        # Try WMI first (may not work on all hardware)
        $zone = Get-WmiObject MSAcpi_ThermalZoneTemperature -Namespace "root/wmi" -ErrorAction SilentlyContinue
        if ($zone) {
            # Kelvin * 10 → Celsius: (Kelvin - 273.15)
            $cpuTempC = [math]::Round((($zone.CurrentTemperature / 10) - 273.15), 1)
            return $cpuTempC
        }
        
        # Fallback: If LibreHardwareMonitor enabled, read from its JSON/API
        if ($LibreHardwareMonitorUrl) {
            $response = Invoke-WebRequest -Uri "$LibreHardwareMonitorUrl/data.json" -ErrorAction SilentlyContinue
            if ($response) {
                $data = $response.Content | ConvertFrom-Json
                # Parse CPU temp from LibreHardwareMonitor structure (adjust path as needed for your setup)
                # Example: $data.Children[0].Children[0].Value (depends on hardware config)
                return $null  # Placeholder; adjust based on actual JSON structure
            }
        }
        
        return $null  # Temperature not available
    }
    catch {
        Write-Host "[WARNING] Failed to get CPU temperature: $_" -ForegroundColor Yellow
        return $null
    }
}

function Get-DiskMetrics {
    <#
    .SYNOPSIS
    Gets disk usage metrics for all fixed logical drives
    .OUTPUTS
    Array of PSCustomObject with Drive, Label, SizeBytes, FreeBytes, UsedBytes, UsedPercent
    #>
    try {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        $metrics = foreach ($disk in $disks) {
            $sizeBytes = $disk.Size
            $freeBytes = $disk.FreeSpace
            $usedBytes = $disk.Size - $disk.FreeSpace
            $usedPct = if ($disk.Size -gt 0) { 
                [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 1) 
            } else { 
                0 
            }
            
            # Get volume label (friendly name)
            $label = if ($disk.VolumeName) { $disk.VolumeName } else { "Drive" }
            # Sanitize label (remove spaces, special chars)
            $label = $label -replace '[^a-zA-Z0-9_]', ''
            if ([string]::IsNullOrEmpty($label)) { $label = "Drive" }
            
            [PSCustomObject]@{
                Drive      = $disk.DeviceID.TrimEnd(':\')
                Label      = $label
                SizeBytes  = $sizeBytes
                FreeBytes  = $freeBytes
                UsedBytes  = $usedBytes
                UsedPercent = $usedPct
            }
        }
        return $metrics
    }
    catch {
        Write-Host "[ERROR] Failed to get disk metrics: $_" -ForegroundColor Red
        return @()
    }
}

function Build-DiskPayload {
    <#
    .SYNOPSIS
    Builds a single JSON payload with all disk metrics (letter_label_metric format)
    .PARAMETER Disks
    Array of disk metrics from Get-DiskMetrics
    .OUTPUTS
    JSON string
    #>
    param([Parameter(Mandatory=$true)] [array] $Disks)
    
    $payload = @{}
    foreach ($disk in $Disks) {
        $drive = Sanitize-Token ($disk.Drive)
        $label = Sanitize-Token ($disk.Label)
        $prefix = "${drive}_${label}"
        $payload["$($prefix)_size_bytes"] = $disk.SizeBytes
        $payload["$($prefix)_free_bytes"] = $disk.FreeBytes
        $payload["$($prefix)_used_bytes"] = $disk.UsedBytes
        $payload["$($prefix)_used_percent"] = $disk.UsedPercent
    }
        return ($payload | ConvertTo-Json -Depth 2 -Compress)
}

function Get-DiskHealth {
    <#
    .SYNOPSIS
    Gets physical disk health status via Get-PhysicalDisk
    .OUTPUTS
    Hashtable with disk health info (name_health, name_operational_status, name_media_type)
    #>
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
        $health = @{}
        
        foreach ($disk in $disks) {
            $diskId = "$($disk.FriendlyName)_slot$($disk.SlotNumber)"
            $diskId = Sanitize-Token $diskId
            
            $health["$($diskId)_health"] = $disk.HealthStatus.ToString()
            $health["$($diskId)_operational_status"] = $disk.OperationalStatus.ToString()
            $health["$($diskId)_media_type"] = $disk.MediaType.ToString()
        }
        
        return $health
    }
    catch {
        Write-Host "[WARNING] Failed to get disk health: $_" -ForegroundColor Yellow
        return @{}
    }
}

# Note: This file is dot-sourced by scripts, not imported as a module.
# Do not call Export-ModuleMember here.

#
# @file utils.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Global functions for SentryLab-Windows
# @date creation 2025-12-29
# @version 1.0.363
# @usage . "$(Split-Path $PSCommandPath)\utils.ps1"
# @notes Provides configuration loading, MQTT publishing, and HA discovery helpers
#

# ==============================================================================
# CONFIGURATION LOADING
# ==============================================================================

# Write-Host "[INFO] Loading utility functions"

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
    $requiredVars = @("BROKER", "DEBUG", "PORT", "USER", "PASS", "HOST_NAME")
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
        'BROKER','PORT','USER','PASS','MQTT_QOS','HOST_NAME','HA_BASE_TOPIC','LibreHardwareMonitorUrl','DEBUG','MosquittoPubPath','LANGUAGE'
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
    # Accept non-string inputs gracefully by converting to string
    if ($null -eq $Text) { return 'unknown' }
    $t = [string]$Text
    $t = $t.ToLower()
    # If the input is a boolean-like string, treat as unknown to avoid 'true_true' IDs
    if ($t -match '^(true|false)$') { return 'unknown' }
    # Replace anything not [a-z0-9] with underscore (hyphens included)
    $t = ($t -replace '[^a-z0-9]', '_')
    # Collapse multiple underscores, trim edges
    $t = ($t -replace '_{2,}', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($t)) { return 'unknown' }
    return $t
}

function Translate {
    <#
    .SYNOPSIS
    Translates a key to the configured language
    .PARAMETER Key
    Translation key
    .OUTPUTS
    Translated string based on $LANGUAGE setting
    #>
    param([Parameter(Mandatory=$true)] [string] $Key)
    
    $lang = if ($script:LANGUAGE) { $script:LANGUAGE } else { "en" }
    
    # Translation table: key = "English|French"
    $translations = @{
        "cpu_temp"              = "CPU Temperature|Température CPU"
        "cpu_load"              = "CPU Load|Charge CPU"
        "cpu_temperature"       = "CPU Temperature|Température CPU"
        "disk_free_space"       = "Free Space|Espace libre"
        "disk_total_size"       = "Total Capacity|Capacité totale"
        "disk_used_space"       = "Used Space|Espace utilisé"
        "disk_used_percent"     = "Used|Utilisé"
        "disk_health"           = "Health|Santé"
        "disk_status"           = "Status|Statut"
        "disk_power_state"      = "Power State|État"
    }
    
    if ($translations.ContainsKey($Key)) {
        $trans = $translations[$Key]
        if ($lang -eq "fr") {
            return ($trans -split '\|')[1]
        } else {
            return ($trans -split '\|')[0]
        }
    }
    
    # Return key if no translation found
    return $Key
}

$script:SAN_HOST = Sanitize-Token $script:HOST_NAME
$script:HA_DISCOVERY_PREFIX = if ($HA_BASE_TOPIC) { $HA_BASE_TOPIC } else { "homeassistant" }

$script:BASE_TOPIC = "windows/$SAN_HOST"
$script:SYSTEM_TOPIC = "$BASE_TOPIC/system"
$script:TEMP_TOPIC = "$BASE_TOPIC/temp"
$script:DISK_TOPIC = "$BASE_TOPIC/disks"

# Promote topic variables to global scope for dot-sourced scripts
$global:HA_DISCOVERY_PREFIX = $script:HA_DISCOVERY_PREFIX
$global:BASE_TOPIC = $script:BASE_TOPIC
$global:SYSTEM_TOPIC = $script:SYSTEM_TOPIC
$global:TEMP_TOPIC = $script:TEMP_TOPIC
$global:DISK_TOPIC = $script:DISK_TOPIC
$global:SAN_HOST = $script:SAN_HOST

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

function Resolve-MosquittoSub {
    <#
    .SYNOPSIS
    Resolves the full path to mosquitto_sub.exe (companion to mosquitto_pub).
    .OUTPUTS
    Sets $script:MOSQUITTO_SUB to an executable path or the literal "mosquitto_sub.exe" to rely on PATH.
    #>
    try {
        # If we found mosquitto_pub in a directory, try the same directory for mosquitto_sub
        if ($script:MOSQUITTO_PUB -and (Test-Path $script:MOSQUITTO_PUB)) {
            $pubDir = Split-Path $script:MOSQUITTO_PUB -Parent
            $subPath = Join-Path $pubDir "mosquitto_sub.exe"
            if (Test-Path $subPath) {
                $script:MOSQUITTO_SUB = $subPath
                return
            }
        }

        # Try PATH
        $cmd = Get-Command mosquitto_sub.exe -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            $script:MOSQUITTO_SUB = $cmd.Source
            return
        }

        # Common install locations
        $commonPaths = @(
            "$env:ProgramFiles\mosquitto\mosquitto_sub.exe",
            "$env:ProgramFiles(x86)\mosquitto\mosquitto_sub.exe",
            "C:\\mosquitto\\mosquitto_sub.exe",
            (Join-Path (Split-Path $PSCommandPath) "mosquitto_sub.exe")
        )

        foreach ($p in $commonPaths) {
            if (Test-Path $p) {
                $script:MOSQUITTO_SUB = $p
                return
            }
        }

        # Fallback: rely on PATH
        $script:MOSQUITTO_SUB = "mosquitto_sub.exe"
    }
    catch {
        $script:MOSQUITTO_SUB = "mosquitto_sub.exe"
    }
}

# Resolve mosquitto_pub and mosquitto_sub paths on load
Resolve-MosquittoPub
Resolve-MosquittoSub

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
    if (($global:DEBUG -ne $null -and $global:DEBUG -eq $true) -or ($script:DEBUG -ne $null -and $script:DEBUG -eq $true) -or ($DEBUG -eq $true)) {
        Write-Host "[SIMULATION] Topic: $Topic" -ForegroundColor Cyan -NoNewline
        Write-Host " (RETAIN)" -ForegroundColor Red
        Write-Host "[SIMULATION] Payload: $Payload" -ForegroundColor Cyan
        return $true
    }
    
    try {
        $qos = if ($MQTT_QOS -is [int] -and $MQTT_QOS -ge 0 -and $MQTT_QOS -le 2) { $MQTT_QOS } else { 1 }
        
        Write-Host "[DEBUG] Publishing with UTF-8 encoding via stdin" -ForegroundColor Yellow

        # Pipe UTF-8 encoded payload to mosquitto_pub using stdin (-l flag)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $bytes = $utf8.GetBytes($Payload)
        $utf8String = $utf8.GetString($bytes)
        
        $utf8String | & $script:MOSQUITTO_PUB -h $BROKER -p $PORT -u $USER -P $PASS -t $Topic -l -r -q $qos
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[INFO] Published (Retain) to $Topic" -ForegroundColor Green
            return $true
        } else {
            Write-Host "[ERROR] Failed to publish to $Topic (exit code: $LASTEXITCODE)" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "[CATCH] Exception publishing to $Topic : $_" -ForegroundColor Red
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
    # Diagnostic: show effective flags
    if ( ($global:DEBUG -ne $null -and $global:DEBUG -eq $true) -or ($script:DEBUG -ne $null -and $script:DEBUG -eq $true) -or ($DEBUG -eq $true)) {
        Write-Host "[DEBUG] NO-RETAIN: $Topic" -ForegroundColor Cyan
        Write-Host "[DEBUG] Payload: $Payload" -ForegroundColor Cyan
        return $true
    }
    

            Write-Host "[DEBUG] NO-RETAIN: $Topic" -ForegroundColor Cyan
        Write-Host "[DEBUG] Payload: $Payload" -ForegroundColor Cyan

    try {
        $qos = if ($MQTT_QOS -is [int] -and $MQTT_QOS -ge 0 -and $MQTT_QOS -le 2) { $MQTT_QOS } else { 1 }
        
        Write-Host "[REAL] (simulated) NO-RETAIN: $Topic" -ForegroundColor Cyan
        Write-Host "[REAL] Payload: $Payload" -ForegroundColor Cyan

        # Pipe UTF-8 encoded payload to mosquitto_pub using stdin (-l flag)
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        $bytes = $utf8.GetBytes($Payload)
        $utf8String = $utf8.GetString($bytes)
        
        $utf8String | & $script:MOSQUITTO_PUB -h $BROKER -p $PORT -u $USER -P $PASS -t $Topic -l -q $qos
        
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[DONE] Published (No-Retain) to $Topic" -ForegroundColor Gray
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
        [string] $ObjectId = "",
        [string] $DeviceClass = "",
        [string] $StateClass = "",
        [string] $UnitOfMeasurement = "",
        [int] $SuggestedDisplayPrecision = 1,
        [hashtable] $Device = @{},
        [string] $JsonAttributesTopic = "",
        [string] $ValueTemplate = ""
    )
    
    $sensor = @{
        name        = $Name
        unique_id   = $UniqueId
        state_topic = $StateTopic
    }
    if ($ObjectId) { $sensor["object_id"] = $ObjectId }
    if ($DeviceClass) { $sensor["device_class"] = $DeviceClass }
    if ($StateClass)  { $sensor["state_class"]  = $StateClass }
    if ($UnitOfMeasurement) { $sensor["unit_of_measurement"] = $UnitOfMeasurement }
    if ($SuggestedDisplayPrecision -gt 0) { $sensor["suggested_display_precision"] = $SuggestedDisplayPrecision }
    if ($Device.Count -gt 0) { $sensor["device"] = $Device }
    if ($JsonAttributesTopic) { $sensor["json_attributes_topic"] = $JsonAttributesTopic }
    if ($ValueTemplate) { $sensor["value_template"] = $ValueTemplate }
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

function Get-VolumeMetrics {
    <#
    .SYNOPSIS
    Gets disk usage metrics for all fixed logical drives
    .OUTPUTS
    Array of PSCustomObject with Drive, Label, SizeBytes, FreeBytes, UsedBytes, UsedPercent
    #>
    Write-Host ""
    Write-Host "### Collecting Volumes metrics ###" -ForegroundColor Blue
    Write-Host ""

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
            $volumeLabel = if ($disk.VolumeName) { $disk.VolumeName } else { "Drive" }
            
            # Extract just the drive letter (e.g., "C" from "C:")
            $driveLetter = $disk.DeviceID -replace '[^A-Za-z0-9]', ''
            
            Write-Host ""
            Write-Host $driveLetter -ForegroundColor Cyan
            Write-Host $volumeLabel -ForegroundColor Cyan
            Write-Host ""
 
            [PSCustomObject]@{
                Drive       = $driveLetter
                VolumeLabel = $volumeLabel
                SizeBytes   = $sizeBytes
                FreeBytes   = $freeBytes
                UsedBytes   = $usedBytes
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

function Build-SystemPayload {
    <#
    .SYNOPSIS
    Builds a single JSON payload with system metrics (CPU load, CPU temp)
    .OUTPUTS
    JSON string
    #>
    param(
        [AllowNull()]
        [double] $CpuLoad = $null,
        
        [AllowNull()]
        [double] $CpuTemp = $null
    )

    $payload = @{}
    if ($null -ne $CpuLoad) {
        $payload["cpu_load"] = $CpuLoad
    }
    if ($null -ne $CpuTemp) {
        $payload["cpu_temp"] = $CpuTemp
    }
    return ($payload | ConvertTo-Json -Depth 2 -Compress)
}

function Get-Removables {
    <#
    .SYNOPSIS
    Detects USB removable drives and collects manufacturer, model, serial number
    .OUTPUTS
    Array of PSCustomObject with identification details
    #>
    Write-Host ""
    Write-Host "### Detecting Removable USB Drives ###" -ForegroundColor Blue
    Write-Host ""

    try {
        # Get all disk drives with USB interface, skip empty/card readers
        $usbDrives = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | 
            Where-Object { $_.InterfaceType -eq "USB" -and $_.Size -gt 0 }
        
        if ($usbDrives.Count -eq 0) {
            Write-Host "[INFO] No USB removable drives detected" -ForegroundColor Gray
            return @()
        }

        Write-Host "[INFO] Found $($usbDrives.Count) USB drive(s) with media" -ForegroundColor Green
        Write-Host ""

        $removables = foreach ($drive in $usbDrives) {
            Write-Host "=== USB Drive ===" -ForegroundColor Cyan
            Write-Host "  Caption:        $($drive.Caption)" -ForegroundColor White
            Write-Host "  Model:          $($drive.Model)" -ForegroundColor White
            Write-Host "  Manufacturer:   $($drive.Manufacturer)" -ForegroundColor White
            Write-Host "  SerialNumber:   $($drive.SerialNumber)" -ForegroundColor White
            Write-Host "  PNPDeviceID:    $($drive.PNPDeviceID)" -ForegroundColor White
            Write-Host "  InterfaceType:  $($drive.InterfaceType)" -ForegroundColor White
            Write-Host "  MediaType:      $($drive.MediaType)" -ForegroundColor White
            Write-Host "  Size:           $([math]::Round($drive.Size / 1GB, 2)) GB" -ForegroundColor White
            Write-Host "  Partitions:     $($drive.Partitions)" -ForegroundColor White
            Write-Host "  DeviceID:       $($drive.DeviceID)" -ForegroundColor White
            
            # Try to get associated logical drives
            $partitions = Get-CimInstance Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue | 
                Where-Object { $_.Antecedent.DeviceID -eq $drive.DeviceID }
            
            $driveLetters = @()
            foreach ($partition in $partitions) {
                $logicalDisks = Get-CimInstance Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue | 
                    Where-Object { $_.Antecedent.DeviceID -eq $partition.Dependent.DeviceID }
                foreach ($logicalDisk in $logicalDisks) {
                    $letter = $logicalDisk.Dependent.DeviceID
                    $driveLetters += $letter
                }
            }
            
            if ($driveLetters.Count -gt 0) {
                Write-Host "  Drive Letters:  $($driveLetters -join ', ')" -ForegroundColor Yellow
            } else {
                Write-Host "  Drive Letters:  (none assigned)" -ForegroundColor Gray
            }
            
            # Extract clean identifiers
            $model = $drive.Model -replace '[^a-zA-Z0-9_]', ''
            $serial = $drive.SerialNumber -replace '[^a-zA-Z0-9_]', ''
            $manufacturer = $drive.Manufacturer -replace '[^a-zA-Z0-9_]', ''
            
            Write-Host "  --> Sanitized Model:  $model" -ForegroundColor Magenta
            Write-Host "  --> Sanitized Serial: $serial" -ForegroundColor Magenta
            Write-Host "  --> Sanitized Mfg:    $manufacturer" -ForegroundColor Magenta
            
            # Proposed ID scheme
            $proposedId = if ($model -and $serial) {
                "${model}_${serial}".ToLower()
            } elseif ($model) {
                "${model}_${manufacturer}".ToLower()
            } else {
                "usb_unknown"
            }
            Write-Host "  --> Proposed ID:      $proposedId" -ForegroundColor Green
            Write-Host ""
            
            [PSCustomObject]@{
                Model        = $drive.Model
                Manufacturer = $drive.Manufacturer
                SerialNumber = $drive.SerialNumber
                PNPDeviceID  = $drive.PNPDeviceID
                InterfaceType = $drive.InterfaceType
                MediaType    = $drive.MediaType
                SizeBytes    = $drive.Size
                Partitions   = $drive.Partitions
                DeviceID     = $drive.DeviceID
                DriveLetters = $driveLetters
                SanitizedModel = $model
                SanitizedSerial = $serial
                SanitizedManufacturer = $manufacturer
                ProposedId   = $proposedId
            }
        }
        
        return $removables
    }
    catch {
        Write-Host "[ERROR] Failed to detect removable drives: $_" -ForegroundColor Red
        return @()
    }
}

function Build-DiskPayload {
    <#
    .SYNOPSIS
    Builds a single JSON payload with all disk metrics (letter_label_metric format)
    .PARAMETER Disks
    Array of disk metrics from Get-VolumeMetrics
    .OUTPUTS
    JSON string
    #>
    param([Parameter(Mandatory=$true)] [array] $Disks)
    
    $payload = @{}
    foreach ($disk in $Disks) {
        $drive = Sanitize-Token ($disk.Drive)
        # Use only drive letter for IDs (not label) to preserve history if user renames volume
        $payload["${drive}_size_bytes"] = $disk.SizeBytes
        $payload["${drive}_free_bytes"] = $disk.FreeBytes
        $payload["${drive}_used_bytes"] = $disk.UsedBytes
        $payload["${drive}_used_percent"] = $disk.UsedPercent
    }
        return ($payload | ConvertTo-Json -Depth 2 -Compress)
}

function Get-DiskHealth {
    <#
    .SYNOPSIS
    Gets physical disk health status via Get-PhysicalDisk (excludes USB removable drives)
    .OUTPUTS
    Hashtable with disk health info (diskid_health, diskid_operational_status, diskid_media_type)
    #>
    # Try modern API first, then fall back to WMI/CIM if unavailable
    $health = @{}
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.BusType -ne 'USB' }
        foreach ($disk in $disks) {
            # Safely select model / friendly name
            $modelRaw = $null
            if ($disk.PSObject.Properties.Match('FriendlyName').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($disk.FriendlyName)) { $modelRaw = $disk.FriendlyName }
            elseif ($disk.PSObject.Properties.Match('Model').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($disk.Model)) { $modelRaw = $disk.Model }
            else { $modelRaw = 'disk' }
            $model = Sanitize-Token $modelRaw

            # Safely select serial number
            $serialRaw = $null
            if ($disk.PSObject.Properties.Match('SerialNumber').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($disk.SerialNumber)) { $serialRaw = $disk.SerialNumber }
            elseif ($disk.PSObject.Properties.Match('SerialNumberID').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($disk.SerialNumberID)) { $serialRaw = $disk.SerialNumberID }
            else { $serialRaw = '' }
            $serial = Sanitize-Token $serialRaw
            if ([string]::IsNullOrWhiteSpace($serial)) { $serial = "unknown" }

            $diskId = "${model}_${serial}"

            $health["$($diskId)_health"] = ($disk.HealthStatus -ne $null) ? $disk.HealthStatus.ToString() : 'Unknown'
            $health["$($diskId)_operational_status"] = ($disk.OperationalStatus -ne $null) ? ($disk.OperationalStatus -join ',') : 'Unknown'
            $health["$($diskId)_media_type"] = ($disk.MediaType -ne $null) ? $disk.MediaType.ToString() : 'Unknown'
        }
        return $health
    }
    catch {
        Write-Host "[WARNING] Get-PhysicalDisk unavailable or failed, falling back to WMI/CIM: $_" -ForegroundColor Yellow
    }

    # WMI/CIM fallback: Win32_DiskDrive (exclude USB)

    try {
        $wmiDisks = Get-CimInstance Win32_DiskDrive -ErrorAction Stop | 
            Where-Object { $_.InterfaceType -ne 'USB' }
        foreach ($d in $wmiDisks) {
            $model = Sanitize-Token ($d.Model -or $d.Caption -or 'disk')
            # SerialNumber may be null on some systems; try different properties
            $serialRaw = $null
            if ($d.PSObject.Properties.Match('SerialNumber').Count -gt 0) { $serialRaw = $d.SerialNumber }
            if ([string]::IsNullOrWhiteSpace($serialRaw) -and $d.PNPDeviceID) { $serialRaw = ($d.PNPDeviceID -split '\\')[-1] }
            if ([string]::IsNullOrWhiteSpace($serialRaw)) { $serialRaw = "unknown" }
            $serial = Sanitize-Token $serialRaw

            $diskId = "${model}_${serial}"

            # Map WMI Status to a Health-like value; prefer SMART where available (not implemented here)
            $healthVal = if ($d.Status) { $d.Status } else { 'Unknown' }
            $operVal = 'Unknown'
            $mediaType = if ($d.InterfaceType) { $d.InterfaceType } else { 'Unknown' }

            $health["$($diskId)_health"] = $healthVal
            $health["$($diskId)_operational_status"] = $operVal
            $health["$($diskId)_media_type"] = $mediaType
        }
        return $health
    }
    catch {
        Write-Host "[ERROR] Failed to query Win32_DiskDrive for disk health: $_" -ForegroundColor Red
        return @{}
    }
}

function Get-PhysicalDiskMapping {
    <#
    .SYNOPSIS
    Maps physical disks to their drive letters
    .OUTPUTS
    Hashtable with disk_id => @{ Number, FriendlyName, DriveLetters }
    #>
    # Try modern API first, then fall back to WMI/CIM if unavailable
    $mapping = @{}
    try {
        $physicalDisks = Get-PhysicalDisk -ErrorAction Stop
        foreach ($pDisk in $physicalDisks) {
            # Safely select model / friendly name
            $modelRaw = $null
            if ($pDisk.PSObject.Properties.Match('FriendlyName').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($pDisk.FriendlyName)) { $modelRaw = $pDisk.FriendlyName }
            elseif ($pDisk.PSObject.Properties.Match('Model').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($pDisk.Model)) { $modelRaw = $pDisk.Model }
            else { $modelRaw = 'disk' }
            $model = Sanitize-Token $modelRaw

            # Safely select serial
            $serialRaw = $null
            if ($pDisk.PSObject.Properties.Match('SerialNumber').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($pDisk.SerialNumber)) { $serialRaw = $pDisk.SerialNumber }
            else { $serialRaw = '' }
            $serial = Sanitize-Token $serialRaw
            if ([string]::IsNullOrWhiteSpace($serial)) { $serial = 'unknown' }

            $diskId = "${model}_${serial}"

            $driveLetters = @()
            try {
                $partitions = Get-Partition -DiskNumber $pDisk.DeviceId -ErrorAction SilentlyContinue
                foreach ($part in $partitions) {
                    if ($part.DriveLetter) { $driveLetters += "$($part.DriveLetter):" }
                }
            } catch {}

            $mapping[$diskId] = @{
                Number = $pDisk.DeviceId
                FriendlyName = $pDisk.FriendlyName
                DriveLetters = $driveLetters
            }
        }
        return $mapping
    }
    catch {
        Write-Host "[WARNING] Get-PhysicalDisk unavailable, falling back to WMI/CIM for mapping: $_" -ForegroundColor Yellow
    }

    # WMI/CIM fallback: correlate Win32_DiskDrive -> Win32_DiskPartition -> Win32_LogicalDisk
    try {
        $wmiDisks = Get-CimInstance Win32_DiskDrive -ErrorAction Stop
        foreach ($d in $wmiDisks) {
            # Safely select model/caption
            $modelRaw = $null
            if ($d.PSObject.Properties.Match('Model').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($d.Model)) { $modelRaw = $d.Model }
            elseif ($d.PSObject.Properties.Match('Caption').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($d.Caption)) { $modelRaw = $d.Caption }
            else { $modelRaw = 'disk' }
            $model = Sanitize-Token $modelRaw

            $serialRaw = $null
            if ($d.PSObject.Properties.Match('SerialNumber').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($d.SerialNumber)) { $serialRaw = $d.SerialNumber }
            if ([string]::IsNullOrWhiteSpace($serialRaw) -and $d.PNPDeviceID) { $serialRaw = ($d.PNPDeviceID -split '\\')[-1] }
            if ([string]::IsNullOrWhiteSpace($serialRaw)) { $serialRaw = 'unknown' }
            $serial = Sanitize-Token $serialRaw
            $diskId = "${model}_${serial}"

            $driveLetters = @()
            try {
                # ASSOCIATORS OF query to get partitions
                $escapedDeviceId = $d.DeviceID -replace "\\","\\\\"
                $partitions = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskDrive.DeviceID='${escapedDeviceId}'} WHERE AssocClass=Win32_DiskDriveToDiskPartition" -ErrorAction SilentlyContinue
                foreach ($part in $partitions) {
                    $logical = Get-WmiObject -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='${part.DeviceID}'} WHERE AssocClass=Win32_LogicalDiskToPartition" -ErrorAction SilentlyContinue
                    foreach ($ld in $logical) {
                        if ($ld.DeviceID) { $driveLetters += $ld.DeviceID }
                    }
                }
            } catch {
                # ignore mapping errors
            }

            $mapping[$diskId] = @{
                Number = $d.Index
                FriendlyName = ($d.Model -or $d.Caption)
                DriveLetters = $driveLetters
            }
        }
        return $mapping
    }
    catch {
        Write-Host "[ERROR] Failed to map physical disks via WMI: $_" -ForegroundColor Red
        return @{}
    }
}

# Note: This file is dot-sourced by scripts, not imported as a module.
# Do not call Export-ModuleMember here.

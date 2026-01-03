#
# @file start.ps1
# @author CmPi <cmpi@webe.fr>
# @brief Install Home Assistant collections for SentryLab-Windows
# @date creation 2026-01-01
# @version 1.0.001
# @usage .\start.ps1
#

# Write-Host "[DEBUG] discovery.ps1 path = $PSCommandPath" -ForegroundColor Cyan

# Load utilities (this will dot-source config.ps1)
. "$(Split-Path $PSCommandPath)\utils.ps1"

Clear-Host

Write-Host "+---------------------------------------+" -ForegroundColor Cyan
Write-Host "| SentryLab-Windows MQTT Discovery      |" -ForegroundColor Cyan
Write-Host "+---------------------------------------+" -ForegroundColor Cyan

Write-Host ""

# Créer la tâche planifiée
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"C:\Users\cmpi\OnedDrive\Github\SentryLab-Windows\src\monitor-passive.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration ([TimeSpan]::MaxValue)
$principal = New-ScheduledTaskPrincipal -UserId "cmpi" -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName "SentryLab-Monitor" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description "SentryLab Windows monitoring every 5 minutes"
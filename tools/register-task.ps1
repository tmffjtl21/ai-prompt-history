# Registers (or replaces) the Windows scheduled task that runs worklog-daily.ps1 every day at 09:00.
# Run once from a normal PowerShell window (no admin needed):
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\dev\ai-prompt-history\tools\register-task.ps1
#
# - StartWhenAvailable: if the PC was off at 09:00, the task runs right after the next boot/logon.
# - The task runs as the current user, so it sees the same PATH, git credentials and claude login.

$TaskName = 'AI Prompt History Daily'
$Script   = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'worklog-daily.ps1'

$action   = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Script`""
$trigger  = New-ScheduledTaskTrigger -Daily -At 9:00AM
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
              -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
              -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Summarize yesterday''s Claude Code conversations into C:\dev\ai-prompt-history and push to GitHub' `
    -Force | Out-Null

Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo |
    Select-Object @{n='Task';e={$TaskName}}, NextRunTime, LastRunTime, LastTaskResult

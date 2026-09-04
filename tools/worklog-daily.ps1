# Daily AI work-log generator.
#
# 1. Reads Claude Code session transcripts (~/.claude/projects/*/*.jsonl)
# 2. Extracts the human prompts and assistant replies for one calendar day (local time)
# 3. Masks obvious secrets, writes a raw transcript under .work/ (git-ignored)
# 4. Asks Claude (headless, `claude -p`) to write a Korean daily summary under <year>/<date>.md
# 5. Commits and pushes to origin when a remote is configured
#
# Usage:
#   powershell -File worklog-daily.ps1              # summarizes YESTERDAY (for the 09:00 scheduled run)
#   powershell -File worklog-daily.ps1 -Date 2026-09-04
#   powershell -File worklog-daily.ps1 -Date 2026-09-04 -Force   # overwrite an existing summary
#
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

[CmdletBinding()]
param(
    [string]$Date = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd'),
    [switch]$Force,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$RepoDir     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$WorkDir     = Join-Path $RepoDir '.work'
$LogFile     = Join-Path $WorkDir 'run.log'
$PromptFile  = Join-Path $RepoDir 'tools\summarize-prompt.md'
$ProjectsDir = Join-Path $env:USERPROFILE '.claude\projects'

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Log([string]$msg) {
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Mask-Secrets([string]$s) {
    if (-not $s) { return $s }
    $s = [regex]::Replace($s, 'Bearer\s+[A-Za-z0-9\-_\.]+', 'Bearer ***')
    $s = [regex]::Replace($s, 'eyJ[A-Za-z0-9\-_]{20,}\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+', '<jwt>')
    $s = [regex]::Replace($s, 'X2BEE_[A-Z0-9_]+=\S+', 'X2BEE_***=***')
    $s = [regex]::Replace($s, 'AKIA[0-9A-Z]{16}', 'AKIA****************')
    $s = [regex]::Replace($s, '(?i)(password|passwd|pwd|secret|secretkey|apikey|api_key|access_key|secret_key)\s*[=:]\s*\S+', '$1=***')
    return $s
}

function Clip([string]$s, [int]$max) {
    if (-not $s) { return '' }
    if ($s.Length -le $max) { return $s }
    return $s.Substring(0, $max) + " ... (truncated, $($s.Length) chars)"
}

function Get-TextFromContent($content) {
    # user prompt: plain string. assistant / tool results: array of blocks.
    if ($content -is [string]) { return $content }
    $parts = @()
    foreach ($block in @($content)) {
        if ($null -ne $block -and $block.type -eq 'text' -and $block.text) { $parts += $block.text }
    }
    return ($parts -join "`n")
}

# ---- day range (local -> UTC) --------------------------------------------------
$dayStart = [datetime]::ParseExact($Date, 'yyyy-MM-dd', $null)
$dayEnd   = $dayStart.AddDays(1)
$utcStart = $dayStart.ToUniversalTime()
$utcEnd   = $dayEnd.ToUniversalTime()
$year     = $dayStart.ToString('yyyy')
$OutDir   = Join-Path $RepoDir $year
$OutFile  = Join-Path $OutDir "$Date.md"
$RawFile  = Join-Path $WorkDir "$Date.transcript.md"

Log "=== start date=$Date repo=$RepoDir"

if ((Test-Path $OutFile) -and -not $Force) {
    Log "summary already exists, skip: $OutFile (use -Force to overwrite)"
    exit 0
}

# ---- collect entries -----------------------------------------------------------
$files = Get-ChildItem -Path (Join-Path $ProjectsDir '*\*.jsonl') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $dayStart }
Log ("candidate session files: {0}" -f @($files).Count)

$entries = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
    $project = Split-Path -Leaf (Split-Path -Parent $f.FullName)
    $reader = [System.IO.File]::OpenText($f.FullName)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line -notmatch '"type":"(user|assistant)"') { continue }
            try { $e = $line | ConvertFrom-Json } catch { continue }
            if ($e.isSidechain -eq $true) { continue }
            if (-not $e.timestamp) { continue }
            $ts = [datetime]::Parse($e.timestamp, [cultureinfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            if ($ts -lt $utcStart -or $ts -ge $utcEnd) { continue }

            $role = $e.type
            if ($role -eq 'user') {
                # only prompts a human actually typed; skip tool results / injected messages
                if ($e.origin -and $e.origin.kind -and $e.origin.kind -ne 'human') { continue }
                if (-not ($e.message.content -is [string])) { continue }
                $text = $e.message.content
                if ($text.TrimStart().StartsWith('<')) { continue }
            } else {
                $text = Get-TextFromContent $e.message.content
            }
            $text = $text.Trim()
            if (-not $text) { continue }

            $entries.Add([pscustomobject]@{
                ts      = $ts.ToLocalTime()
                role    = $role
                project = $project
                cwd     = $e.cwd
                branch  = $e.gitBranch
                session = $e.sessionId
                text    = $text
            })
        }
    } finally { $reader.Close() }
}

Log ("entries in range: {0}" -f $entries.Count)
if ($entries.Count -eq 0) {
    Log "nothing to summarize for $Date"
    exit 0
}

# ---- raw transcript ------------------------------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Raw transcript $Date")
[void]$sb.AppendLine()
$groups = $entries | Sort-Object ts | Group-Object project
foreach ($g in $groups) {
    $first = $g.Group[0]
    $cwd = if ($first.cwd) { $first.cwd } else { $g.Name }
    [void]$sb.AppendLine("## PROJECT: $cwd (branch: $($first.branch))")
    [void]$sb.AppendLine()
    foreach ($e in ($g.Group | Sort-Object ts)) {
        $who = if ($e.role -eq 'user') { 'USER' } else { 'AI' }
        $max = if ($e.role -eq 'user') { 3000 } else { 2500 }
        $body = Mask-Secrets (Clip $e.text $max)
        [void]$sb.AppendLine("[$($e.ts.ToString('HH:mm'))] ${who}:")
        [void]$sb.AppendLine($body)
        [void]$sb.AppendLine()
    }
}
[System.IO.File]::WriteAllText($RawFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Log "raw transcript: $RawFile ($([math]::Round((Get-Item $RawFile).Length / 1KB)) KB)"

# ---- summarize with claude -p ---------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$promptTemplate = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
$prompt = $promptTemplate.Replace('{{DATE}}', $Date).Replace('{{TRANSCRIPT}}', $RawFile).Replace('{{OUTPUT}}', $OutFile)

# claude.cmd is a batch wrapper: a multi-line argument is cut at the first newline.
# So the rendered prompt goes to a UTF-8 file and the -p argument stays a single line.
$RenderedPrompt = Join-Path $WorkDir "$Date.prompt.md"
[System.IO.File]::WriteAllText($RenderedPrompt, $prompt, (New-Object System.Text.UTF8Encoding($false)))
$instruction = "Read the file $RenderedPrompt with the Read tool and follow every instruction in it exactly. Reply with DONE only after the output file has been written."

$claude = Get-Command claude.cmd -ErrorAction SilentlyContinue
if (-not $claude) { $claude = Get-Command (Join-Path $env:APPDATA 'npm\claude.cmd') -ErrorAction Stop }

Push-Location $RepoDir
try {
    Log "invoking claude -p ..."
    $result = & $claude.Source -p $instruction `
        --allowedTools 'Read,Write' `
        --no-session-persistence `
        --output-format text 2>&1
    Log ("claude exit={0} output={1}" -f $LASTEXITCODE, (($result | Out-String).Trim() | Select-Object -First 1))
} finally { Pop-Location }

if (-not (Test-Path $OutFile)) {
    Log "ERROR: summary file was not written: $OutFile"
    exit 1
}
Log "summary: $OutFile"

# ---- commit & push -------------------------------------------------------------
Push-Location $RepoDir
try {
    git add -- "$year/$Date.md" | Out-Null
    $staged = git diff --cached --name-only
    if (-not $staged) {
        Log "no changes to commit"
    } else {
        git commit -q -m "worklog: $Date" | Out-Null
        Log "committed"
        $remote = git remote get-url origin 2>$null
        if ($remote -and -not $NoPush) {
            git push -q origin HEAD 2>&1 | ForEach-Object { Log "push: $_" }
            Log "pushed to $remote"
        } else {
            Log "push skipped (no remote or -NoPush)"
        }
    }
} finally { Pop-Location }

Log "=== done"

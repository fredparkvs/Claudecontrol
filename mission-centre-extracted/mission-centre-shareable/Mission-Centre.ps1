#Requires -Version 5.1
<#
.SYNOPSIS
    Mission Centre - AI Project Launcher
.DESCRIPTION
    Auto-discovers AI projects under a configurable scan root, maintains a config of project
    descriptions, and provides quick-launch options (Jig or Forge).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Ensure the console can render UTF-8 box-drawing characters in PS5/legacy hosts
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Box-drawing chars (use [char] codes to avoid file-encoding issues in PS5.1)
$C_TL = [char]0x2554
$C_TR = [char]0x2557
$C_BL = [char]0x255A
$C_BR = [char]0x255D
$C_H  = [char]0x2550
$C_V  = [char]0x2551
$C_DH = [char]0x2500

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

$ConfigPath    = "$PSScriptRoot\projects.json"
$AppConfigPath = "$PSScriptRoot\config.json"
$MaxDepth      = 4

function Get-AppConfig {
    if (Test-Path $AppConfigPath) {
        try {
            $c = Get-Content $AppConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($c.scanRoot) { return $c }
        } catch { }
    }

    # First-run: prompt for scan root
    Write-Host ''
    Write-Host '  Welcome to Mission Centre!' -ForegroundColor Cyan
    Write-Host '  Enter the root folder to scan for AI projects.' -ForegroundColor DarkGray
    Write-Host '  Example: C:\AI  or  D:\Dev\Projects' -ForegroundColor DarkGray
    Write-Host ''
    $root = Read-Host '  Scan root'
    if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }

    $cfg = [PSCustomObject]@{ scanRoot = $root }
    $cfg | ConvertTo-Json | Set-Content $AppConfigPath -Encoding UTF8
    Write-Host "  Config saved to config.json" -ForegroundColor Green
    Write-Host ''
    return $cfg
}

$AppConfig = Get-AppConfig
$ScanRoot  = $AppConfig.scanRoot

$SkipDirNames = @(
    'node_modules', '.git', 'dist', 'build', 'bin', 'obj', 'out',
    '.next', '.nuxt', 'venv', '.venv', '__pycache__', '.cache',
    'Archive', 'Models', 'Resources', 'resources',
    'Design Inspiration', 'Company Registration', 'Finance', 'Investors', 'Exit'
)

# Definitive: presence alone means "this IS a project root; stop recursing"
$DefinitiveMarkers = @(
    '.git', 'package.json', 'requirements.txt',
    'Cargo.toml', 'go.mod', 'pom.xml', 'pyproject.toml'
)

# Suggestive: signals a project, but we still recurse into children to check
# whether the children are the real projects (avoids workspace dirs swallowing sub-projects)
$SuggestiveMarkers = @(
    'CLAUDE.md', '*.jig', 'README.md', 'README',
    'app.js', 'main.py', 'index.js', 'main.ts', 'index.ts'
)

$ProjectMarkers = $DefinitiveMarkers + $SuggestiveMarkers

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Banner {
    $inner  = 44
    $title  = '  MISSION CENTRE  '
    $padL   = [int][math]::Floor(($inner - $title.Length) / 2)
    $padR   = $inner - $title.Length - $padL
    $hLine  = [string]$C_H * $inner
    $top    = [string]$C_TL + $hLine + [string]$C_TR
    $mid    = [string]$C_V  + (' ' * $padL) + $title + (' ' * $padR) + [string]$C_V
    $bot    = [string]$C_BL + $hLine + [string]$C_BR
    Write-Host ''
    Write-Host $top -ForegroundColor Cyan
    Write-Host $mid -ForegroundColor Cyan
    Write-Host $bot -ForegroundColor Cyan
    Write-Host ''
}

function Write-Divider {
    Write-Host ([string]$C_DH * 46) -ForegroundColor DarkGray
}

function Test-SkipDir {
    param([string]$DirName)
    foreach ($pat in $SkipDirNames) {
        if ($DirName -like $pat) { return $true }
    }
    return $false
}

function Test-MarkerSet {
    param([string]$DirPath, [string[]]$Markers)
    foreach ($marker in $Markers) {
        if ($marker.Contains('*')) {
            $found = Get-ChildItem -Path $DirPath -Filter $marker -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($found) { return $true }
        } else {
            if (Test-Path (Join-Path $DirPath $marker)) { return $true }
        }
    }
    return $false
}

function Test-AnyChildHasMarkers {
    param([string]$DirPath)
    try {
        $kids = Get-ChildItem -Path $DirPath -Directory -ErrorAction SilentlyContinue
        foreach ($kid in $kids) {
            if (-not (Test-SkipDir $kid.Name)) {
                if (Test-MarkerSet $kid.FullName $ProjectMarkers) { return $true }
            }
        }
    } catch { }
    return $false
}

function Find-ProjectDirs {
    param([string]$Path, [int]$Depth)

    if ($Depth -gt $MaxDepth)                        { return }
    if (-not (Test-Path $Path -PathType Container))  { return }

    $leaf = Split-Path $Path -Leaf
    if (Test-SkipDir $leaf)       { return }
    if ($Path -ieq $PSScriptRoot) { return }

    # Definitive marker: this is unambiguously a project root
    if (Test-MarkerSet $Path $DefinitiveMarkers) {
        $Path
        return
    }

    # Suggestive marker: could be a project, or could be a workspace container
    # Prefer children if any child also has markers (i.e. we're in a container)
    if (Test-MarkerSet $Path $SuggestiveMarkers) {
        if (Test-AnyChildHasMarkers $Path) {
            # This dir is a container — recurse to find the real projects inside
        } else {
            $Path
            return
        }
    }

    try {
        $kids = Get-ChildItem -Path $Path -Directory -ErrorAction SilentlyContinue
        foreach ($kid in $kids) {
            Find-ProjectDirs $kid.FullName ($Depth + 1)
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Config I/O
# ---------------------------------------------------------------------------

function Load-Config {
    if (-not (Test-Path $ConfigPath)) { return @() }
    try {
        $raw  = Get-Content $ConfigPath -Raw -Encoding UTF8
        $list = $raw | ConvertFrom-Json
        if ($null -eq $list)              { return @() }
        if ($list -isnot [System.Array]) { return @($list) }
        return $list
    } catch {
        Write-Host 'WARN: Could not parse projects.json - starting fresh.' -ForegroundColor Yellow
        return @()
    }
}

function Save-Config {
    param([object[]]$Projects)
    $dir = Split-Path $ConfigPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Projects | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath -Encoding UTF8
}

function Test-ConfigHasPath {
    param([object[]]$Config, [string]$Path)
    foreach ($e in $Config) {
        if ($e.path -ieq $Path) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Discovery & onboarding
# ---------------------------------------------------------------------------

function Sync-NewProjects {
    param([ref]$ConfigRef)

    Write-Host "Scanning $ScanRoot for projects ..." -ForegroundColor DarkGray

    $discovered = @(Find-ProjectDirs $ScanRoot 0)
    $newPaths   = @($discovered | Where-Object { -not (Test-ConfigHasPath $ConfigRef.Value $_) })

    if ($newPaths.Count -eq 0) {
        Write-Host 'No new projects found.' -ForegroundColor DarkGray
        return
    }

    Write-Host ''
    Write-Host "Found $($newPaths.Count) new project(s) not yet in config." -ForegroundColor Yellow
    Write-Divider

    $updated = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $ConfigRef.Value) { $updated.Add($e) }

    foreach ($p in $newPaths) {
        $defaultName = Split-Path $p -Leaf
        Write-Host ''
        Write-Host '  New project: ' -NoNewline -ForegroundColor Cyan
        Write-Host $p
        $name = Read-Host "  Name        [$defaultName]"
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $defaultName }
        $desc = Read-Host '  Description (one line, or Enter to skip)'
        if ([string]::IsNullOrWhiteSpace($desc)) { $desc = '- no description yet -' }
        Write-Host '  Profiles: corporate, vibe, build, maintain, review, standard' -ForegroundColor DarkCyan
        $prof = Read-Host '  Profile     [standard]'
        if ([string]::IsNullOrWhiteSpace($prof)) { $prof = 'standard' }

        $updated.Add([PSCustomObject]@{
            path        = $p
            name        = $name
            description = $desc
            added       = (Get-Date -Format 'yyyy-MM-dd')
            profile     = $prof
        })
    }

    $ConfigRef.Value = $updated.ToArray()
    Save-Config $ConfigRef.Value
    Write-Host ''
    Write-Host '  Config saved.' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Session discovery (reads Claude Code's session index)
# ---------------------------------------------------------------------------

$ClaudeProjectsDir = "$env:USERPROFILE\.claude\projects"

function Get-SessionFolderName {
    param([string]$ProjectPath)
    # Claude encodes paths: F:\AI\Foo Bar → F--AI-Foo-Bar
    $ProjectPath.Replace('\','-').Replace(':','-').Replace('/','-').Replace(' ','-')
}

function Get-SessionLabel {
    # Returns the best available label for a session:
    # 1. custom-title (auto-generated slug, hyphens → spaces) — best recap
    # 2. first user message — fallback
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $customTitle = $null
        $firstPrompt = $null
        # Scan up to 150 lines — custom-title is generated after ~80 lines of setup
        $lines = Get-Content $FilePath -TotalCount 150 -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $msg = $line | ConvertFrom-Json
                # Preferred: auto-generated session title
                if (-not $customTitle -and $msg.type -eq 'custom-title' -and $msg.customTitle) {
                    $customTitle = ($msg.customTitle -replace '-', ' ')
                }
                # Fallback: first user message (multiple formats)
                if (-not $firstPrompt) {
                    # Format A (Claude Code CLI): {"type":"user","message":{"content":"..."}}
                    if ($msg.type -eq 'user' -and $msg.message -and $msg.message.content) {
                        $c = $msg.message.content
                        if ($c -is [System.Array]) {
                            foreach ($b in $c) { if ($b.type -eq 'text' -and $b.text) { $firstPrompt = [string]$b.text; break } }
                        } elseif ($c) { $firstPrompt = [string]$c }
                    }
                    # Format B (older): {"type":"human","message":{"content":[...]}}
                    if ($msg.type -eq 'human' -and $msg.message -and $msg.message.content) {
                        $c = $msg.message.content
                        if ($c -is [System.Array]) {
                            foreach ($b in $c) { if ($b.type -eq 'text' -and $b.text) { $firstPrompt = [string]$b.text; break } }
                        } elseif ($c) { $firstPrompt = [string]$c }
                    }
                    # Format C: {"role":"user","content":"..."}
                    if ($msg.role -eq 'user' -and $msg.content) {
                        $c = $msg.content
                        if ($c -is [System.Array]) {
                            foreach ($b in $c) { if ($b.type -eq 'text' -and $b.text) { $firstPrompt = [string]$b.text; break } }
                        } elseif ($c -is [string]) { $firstPrompt = $c }
                    }
                }
                if ($customTitle -and $firstPrompt) { break }
            } catch { }
        }
        if ($customTitle) { return $customTitle }
        return $firstPrompt
    } catch { }
    return $null
}

# Keep alias for index-path enrichment call below
function Get-FirstPromptFromFile { param([string]$FilePath); return Get-SessionLabel $FilePath }

function Get-RecentSessions {
    param([string]$ProjectPath, [int]$MaxCount = 5)

    $folderName = Get-SessionFolderName $ProjectPath
    $folderPath = Join-Path $ClaudeProjectsDir $folderName
    $indexPath  = Join-Path $folderPath 'sessions-index.json'

    if (Test-Path $indexPath) {
        try {
            $raw   = Get-Content $indexPath -Raw -Encoding UTF8
            $index = $raw | ConvertFrom-Json
            if ($null -ne $index.entries -and $index.entries.Count -gt 0) {
                # Sort by fileMtime (epoch ms) — more accurate than modified (can be stale)
                $sorted = $index.entries |
                    Sort-Object { [long]$_.fileMtime } -Descending |
                    Select-Object -First $MaxCount

                # Enrich: index entries have summary+messageCount but no firstPrompt.
                # When summary is absent (no /compact ever run), read the .jsonl to get the opener.
                $enriched = @()
                foreach ($entry in $sorted) {
                    $sid = if ($entry.sessionId) { $entry.sessionId } else { $entry.id }
                    $fp  = $null
                    if (-not $entry.summary -and $sid) {
                        $fp = Get-FirstPromptFromFile (Join-Path $folderPath "$sid.jsonl")
                    }
                    $enriched += [PSCustomObject]@{
                        sessionId    = $sid
                        firstPrompt  = if ($fp) { $fp } else { '(no prompt captured)' }
                        summary      = $entry.summary
                        messageCount = if ($entry.messageCount) { [int]$entry.messageCount } else { 0 }
                        fileMtime    = if ($entry.fileMtime)    { [long]$entry.fileMtime }   else { 0 }
                        modified     = $entry.modified
                    }
                }
                return $enriched
            }
        } catch { }
    }

    # Fallback: scan .jsonl files directly when index is missing or empty
    if (-not (Test-Path $folderPath)) { return @() }
    try {
        $jsonls = Get-ChildItem -Path $folderPath -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First $MaxCount

        $results = @()
        foreach ($f in $jsonls) {
            $fp = Get-FirstPromptFromFile $f.FullName
            $results += [PSCustomObject]@{
                sessionId    = $f.BaseName
                firstPrompt  = if ($fp) { $fp } else { '(no prompt captured)' }
                summary      = $null
                messageCount = 0
                fileMtime    = [long]($f.LastWriteTime.ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds
                modified     = $f.LastWriteTime.ToString('o')
            }
        }
        return $results
    } catch {
        return @()
    }
}

function Format-SessionAge {
    param($Session)
    try {
        # Prefer fileMtime (epoch ms) — always up-to-date; fall back to modified string
        if ($Session.fileMtime -and [long]$Session.fileMtime -gt 0) {
            $epoch = [datetime]'1970-01-01'
            $mod   = $epoch.AddMilliseconds([long]$Session.fileMtime).ToLocalTime()
        } else {
            $mod = [datetime]$Session.modified
        }
        $diff = (Get-Date) - $mod
        if ($diff.TotalMinutes -lt 60)  { return "$([int]$diff.TotalMinutes)m ago" }
        if ($diff.TotalHours   -lt 24)  { return "$([int]$diff.TotalHours)h ago" }
        if ($diff.TotalDays    -lt 30)  { return "$([int]$diff.TotalDays)d ago" }
        return $mod.ToString('yyyy-MM-dd')
    } catch {
        return '?'
    }
}

# ---------------------------------------------------------------------------
# Menu display
# ---------------------------------------------------------------------------

function Show-ProjectMenu {
    param([object[]]$Projects)

    Write-Banner

    $i = 1
    foreach ($p in $Projects) {
        $num     = " [$i]".PadRight(6)
        $profile = if ($p.profile) { " [$($p.profile)]" } else { '' }
        Write-Host $num -NoNewline -ForegroundColor Yellow
        Write-Host $p.name -NoNewline -ForegroundColor White
        Write-Host $profile -ForegroundColor DarkCyan
        Write-Host "      $($p.description)" -ForegroundColor DarkGray
        Write-Host ''
        $i++
    }

    Write-Divider
    Write-Host ''

    # Show recent meta sessions from scan root
    $metaSessions = @(Get-RecentSessions $ScanRoot)
    if ($metaSessions.Count -gt 0) {
        Write-Host '  Recent meta missions:' -ForegroundColor DarkCyan
        $mi = 1
        foreach ($ms in $metaSessions) {
            $age     = Format-SessionAge $ms
            $summary = if ($ms.summary) { $ms.summary } else { $ms.firstPrompt }
            if ($summary.Length -gt 55) { $summary = $summary.Substring(0, 52) + '...' }
            $msgs    = "$($ms.messageCount) msgs"
            Write-Host "   [M$mi] " -NoNewline -ForegroundColor Magenta
            Write-Host "$summary" -NoNewline -ForegroundColor White
            Write-Host "  ($msgs, $age)" -ForegroundColor DarkGray
            $mi++
        }
        Write-Host ''
    }

    Write-Host "  [M]   New Meta Mission - cross-project planning from $ScanRoot" -ForegroundColor Magenta
    if ($metaSessions.Count -gt 0) {
        Write-Host '  [M#]  Resume a meta mission listed above'                -ForegroundColor Magenta
    }
    Write-Host ''
    $choice = Read-Host '  Pick a project number, [M] Meta Mission, [S] Scan, or [Q] Quit'
    if ($null -eq $choice) { return 'Q' }
    return $choice.Trim()
}

function Show-LaunchMenu {
    param([object]$Project)

    $profile = if ($Project.profile) { $Project.profile } else { 'standard' }

    Write-Host ''
    Write-Host '  Project : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Project.name  -NoNewline -ForegroundColor Cyan
    Write-Host "  [$profile]" -ForegroundColor DarkCyan
    Write-Host '  Path    : ' -NoNewline -ForegroundColor DarkGray
    Write-Host $Project.path  -ForegroundColor DarkGray
    Write-Host ''

    # Show recent sessions if any exist
    $sessions = @(Get-RecentSessions $Project.path)
    if ($sessions.Count -gt 0) {
        Write-Host '  Recent missions:' -ForegroundColor DarkCyan
        $si = 1
        foreach ($s in $sessions) {
            $age     = Format-SessionAge $s
            $summary = if ($s.summary) { $s.summary } else { $s.firstPrompt }
            if ($summary.Length -gt 55) { $summary = $summary.Substring(0, 52) + '...' }
            $msgs    = if ($s.messageCount -gt 0) { "$($s.messageCount) msgs" } else { '' }
            Write-Host "   [R$si] " -NoNewline -ForegroundColor Green
            Write-Host "$summary" -NoNewline -ForegroundColor White
            if ($msgs) { Write-Host "  ($msgs, $age)" -ForegroundColor DarkGray }
            else       { Write-Host "  ($age)" -ForegroundColor DarkGray }
            $si++
        }
        Write-Host ''
    }

    Write-Host "  [L]  Launch                - jig run $profile (project default)" -ForegroundColor Green
    Write-Host '  [J]  Launch with Jig       - pick a different profile'           -ForegroundColor Yellow
    if ($sessions.Count -gt 0) {
        Write-Host '  [R#] Resume mission        - resume a session listed above'      -ForegroundColor Green
    }
    Write-Host '  [E]  Open in Explorer'                                               -ForegroundColor Cyan
    Write-Host '  [B]  Back'                                                           -ForegroundColor DarkGray
    Write-Host ''
    Write-Divider
    $choice = Read-Host '  Choose'
    if ($null -eq $choice) { return 'B' }
    return $choice.Trim().ToUpper()
}

# ---------------------------------------------------------------------------
# Launchers
# ---------------------------------------------------------------------------

function Assert-DirExists {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Container)) {
        Write-Host "  ERROR: Directory not found: $Path" -ForegroundColor Red
        return $false
    }
    return $true
}

function Assert-CmdExists {
    param([string]$Cmd)
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Host "  ERROR: '$Cmd' is not in PATH. Is it installed?" -ForegroundColor Red
        return $false
    }
    return $true
}

function Start-WithProfile {
    param([string]$ProjectPath, [string]$Profile)
    if (-not (Assert-DirExists $ProjectPath)) { return }
    if (-not (Assert-CmdExists  'jig'))       { return }

    Write-Host "  Launching jig run $Profile in $ProjectPath ..." -ForegroundColor Green
    $safe = $ProjectPath -replace "'", "''"
    Start-Process powershell ("-NoExit -Command Set-Location '" + $safe + "'; jig run " + $Profile)
}

function Start-Jig {
    param([string]$ProjectPath)
    if (-not (Assert-DirExists $ProjectPath)) { return }
    if (-not (Assert-CmdExists  'jig'))       { return }

    Write-Host "  Launching Jig in $ProjectPath ..." -ForegroundColor Green
    $safe = $ProjectPath -replace "'", "''"
    Start-Process powershell ("-NoExit -Command Set-Location '" + $safe + "'; jig")
}

function Start-Resume {
    param([string]$ProjectPath, [string]$SessionId)
    if (-not (Assert-DirExists $ProjectPath)) { return }
    if (-not (Assert-CmdExists  'claude'))    { return }

    Write-Host "  Resuming session $SessionId ..." -ForegroundColor Green
    $safe = $ProjectPath -replace "'", "''"
    Start-Process powershell ("-NoExit -Command Set-Location '" + $safe + "'; claude --resume " + $SessionId)
}

function Start-MetaMission {
    if (-not (Assert-CmdExists 'jig')) { return }

    Write-Host '  Launching Meta Mission with build profile ...' -ForegroundColor Magenta
    $safe = $ScanRoot -replace "'", "''"
    Start-Process powershell ("-NoExit -Command Set-Location '$safe'; jig run build")
}

function Open-ProjectFolder {
    param([string]$ProjectPath)
    if (-not (Assert-DirExists $ProjectPath)) { return }
    Start-Process explorer.exe $ProjectPath
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

function Start-MissionCentre {
    $config  = Load-Config
    $running = $true

    while ($running) {
        Clear-Host
        $raw = Show-ProjectMenu $config
        if ($null -eq $raw) { $raw = '' }

        $rawUp = $raw.ToUpper()

        if ($rawUp -eq 'Q') {
            Write-Host ''
            Write-Host '  Goodbye.' -ForegroundColor DarkGray
            Write-Host ''
            $running = $false

        } elseif ($rawUp -eq 'M') {
            Start-MetaMission
            Start-Sleep -Seconds 1

        } elseif ($rawUp -match '^M(\d+)$') {
            $mi = [int]$Matches[1] - 1
            $metaSessions = @(Get-RecentSessions $ScanRoot)
            if ($mi -ge 0 -and $mi -lt $metaSessions.Count) {
                Start-Resume $ScanRoot $metaSessions[$mi].sessionId
                Start-Sleep -Seconds 1
            } else {
                Write-Host '  Invalid meta session number.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }

        } elseif ($rawUp -eq 'S') {
            Clear-Host
            Sync-NewProjects ([ref]$config)
            Read-Host '  Press Enter to continue'

        } elseif ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -lt 0 -or $idx -ge $config.Count) {
                Write-Host '  Invalid number.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            } else {
                $project = $config[$idx]
                $inProject = $true

                while ($inProject) {
                    Clear-Host
                    Write-Banner
                    $action = Show-LaunchMenu $project

                    if ($action -eq 'L') {
                        $prof = if ($project.profile) { $project.profile } else { 'standard' }
                        Start-WithProfile  $project.path $prof
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($action -eq 'J') {
                        Start-Jig          $project.path
                        Start-Sleep -Seconds 1
                        $inProject = $false
                    } elseif ($action -match '^R(\d+)$') {
                        $ri = [int]$Matches[1] - 1
                        $sessions = @(Get-RecentSessions $project.path)
                        if ($ri -ge 0 -and $ri -lt $sessions.Count) {
                            Start-Resume $project.path $sessions[$ri].sessionId
                            Start-Sleep -Seconds 1
                            $inProject = $false
                        } else {
                            Write-Host '  Invalid session number.' -ForegroundColor Red
                            Start-Sleep -Seconds 1
                        }
                    } elseif ($action -eq 'E') {
                        Open-ProjectFolder $project.path
                    } elseif ($action -eq 'B') {
                        $inProject = $false
                    } else {
                        Write-Host '  Unknown option.' -ForegroundColor Red
                        Start-Sleep -Seconds 1
                    }
                }
            }

        } else {
            Write-Host '  Please enter a number, S, or Q.' -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

try {
    Start-MissionCentre
} catch {
    Write-Host ''
    Write-Host "FATAL: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    Write-Host ''
    Read-Host 'Press Enter to exit'
}

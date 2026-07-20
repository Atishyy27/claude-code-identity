# cc - Claude Code multi-identity launcher (Windows / PowerShell)
#
# Dot-source from your $PROFILE so `ccuse` can set the var in the CURRENT shell:
#     . "$env:USERPROFILE\.config\cc\cc.ps1"
#
# Commands:
#   cc [id] [args...]   launch claude as <id> (default: the current default id)
#   ccuse <id>          make <id> the persistent default (bare `claude` too)
#   ccwho               list identities, login state, and which is default
#   ccnew <id> [dir]    register a NEW identity (explicit, so typos can't create one)
#   ccrm <id>           unregister an identity (never touches the shared store)
#
# Identity is per-process: Claude Code reads CLAUDE_CONFIG_DIR once at launch,
# so a running session can never change account. Use `cc <id> --resume`.
#
# Config lives in the same place as the POSIX version, so a shared home works.

$script:CcHome       = if ($env:CC_HOME) { $env:CC_HOME } else { Join-Path $env:USERPROFILE '.config\cc' }
$script:CcIdentities = Join-Path $script:CcHome 'identities'
$script:CcDefault    = Join-Path $script:CcHome 'default'
$script:CcSharedRoot = if ($env:CC_SHARED_ROOT) { $env:CC_SHARED_ROOT } else { Join-Path $env:USERPROFILE '.claude' }
# Everything except auth is shared. Auth (.credentials.json, .claude.json,
# settings.json) stays per-identity - that is the whole point of switching.
$script:CcSharedDirs = if ($env:CC_SHARED_DIRS) { $env:CC_SHARED_DIRS -split '\s+' } else { @('projects','skills','agents','commands') }

function Initialize-Cc {
    if (-not (Test-Path $script:CcHome)) { New-Item -ItemType Directory -Path $script:CcHome -Force | Out-Null }
    if (-not (Test-Path $script:CcIdentities)) { New-Item -ItemType File -Path $script:CcIdentities -Force | Out-Null }
}

function Get-CcDir {
    param([Parameter(Mandatory)][string] $Id)
    Initialize-Cc
    foreach ($line in Get-Content $script:CcIdentities) {
        if ($line -match '^\s*(\S+)\s+(.+?)\s*$' -and $Matches[1] -eq $Id) { return $Matches[2] }
    }
    return $null
}

function Get-CcIds {
    Initialize-Cc
    Get-Content $script:CcIdentities | ForEach-Object {
        if ($_ -match '^\s*(\S+)\s+') { $Matches[1] }
    }
}

function Get-CcDefaultId {
    Initialize-Cc
    if ((Test-Path $script:CcDefault) -and (Get-Content $script:CcDefault -Raw).Trim()) {
        return (Get-Content $script:CcDefault -First 1).Trim()
    }
    return (Get-CcIds | Select-Object -First 1)
}

# --- shared-store linking ----------------------------------------------------
# Junctions, not symlinks: junctions need no admin rights or Developer Mode.
function Connect-CcShared {
    param([Parameter(Mandatory)][string] $Dir)
    if ($Dir.TrimEnd('\') -eq $script:CcSharedRoot.TrimEnd('\')) { return $true }  # primary IS the store

    foreach ($sub in $script:CcSharedDirs) {
        $target = Join-Path $script:CcSharedRoot $sub
        $link   = Join-Path $Dir $sub
        if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

        $item = Get-Item $link -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        }
        elseif ($item.LinkType) {
            continue                                  # already a junction
        }
        else {
            # Real directory with content: merge, but never clobber. Collisions
            # are reported and refused rather than silently overwritten.
            $collisions = Get-ChildItem $link -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $target $_.Name) } |
                ForEach-Object { $_.Name }
            if ($collisions) {
                Write-Host "cc: refusing to merge $link - these already exist in the shared store:" -ForegroundColor Red
                $collisions | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
                Write-Host "cc: resolve by hand, then re-run." -ForegroundColor Red
                return $false
            }
            try {
                Copy-Item -Path (Join-Path $link '*') -Destination $target -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Host "cc: merge of $link failed: $($_.Exception.Message)" -ForegroundColor Red
                return $false
            }
            # Timestamped so repeated merges can never collide on the backup name.
            $bak = "$link.premerge-$(Get-Date -Format 'yyyyMMddHHmmss')"
            Rename-Item $link $bak
            New-Item -ItemType Junction -Path $link -Target $target | Out-Null
            Write-Host "cc: merged $sub into the shared store (backup: $(Split-Path $bak -Leaf))" -ForegroundColor DarkGray
        }
    }
    return $true
}

# --- concurrent-session guard ------------------------------------------------
# Two Claude Code processes sharing one config dir can race on .claude.json and
# overwrite it with an empty stub; the backup rotation then evicts the good
# copies. See anthropics/claude-code#78439. Only sessions started via `cc` are
# tracked - a bare `claude` bypasses this.
function Test-CcLock {
    param([Parameter(Mandatory)][string] $Dir, [Parameter(Mandatory)][string] $Id)
    $lock = Join-Path $Dir '.cc-session.lock'
    if (-not (Test-Path $lock)) { return $true }
    $pid = (Get-Content $lock -First 1 -ErrorAction SilentlyContinue)
    if ($pid -notmatch '^\d+$') { Remove-Item $lock -Force -ErrorAction SilentlyContinue; return $true }
    if (Get-Process -Id ([int]$pid) -ErrorAction SilentlyContinue) {
        Write-Host "cc: WARNING - another Claude Code session (pid $pid) is already using" -ForegroundColor Yellow
        Write-Host "    $Dir" -ForegroundColor Yellow
        Write-Host "    Concurrent sessions on one config dir can corrupt .claude.json" -ForegroundColor Yellow
        Write-Host "    (anthropics/claude-code#78439). Close it, or re-run with: cc -Force $Id" -ForegroundColor Yellow
        return $false
    }
    Remove-Item $lock -Force -ErrorAction SilentlyContinue   # stale lock, owner is gone
    return $true
}

# --- commands ----------------------------------------------------------------
function ccnew {
    param([Parameter(Mandatory, Position = 0)][string] $Id, [Parameter(Position = 1)][string] $Dir)
    Initialize-Cc
    if (Get-CcDir $Id) { Write-Host "cc: identity [$Id] already exists" -ForegroundColor Red; return }
    if (-not $Dir) { $Dir = Join-Path $env:USERPROFILE ".claude-$Id" }
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    Add-Content -Path $script:CcIdentities -Value "$Id $Dir"
    Write-Host "cc: registered [$Id] -> $Dir" -ForegroundColor Green
    Write-Host "    run 'cc $Id' and log in."
}

function ccrm {
    param([Parameter(Mandatory, Position = 0)][string] $Id)
    $dir = Get-CcDir $Id
    if (-not $dir) { Write-Host "cc: no such identity [$Id]" -ForegroundColor Red; return }

    # Remove junctions with Directory::Delete. Remove-Item -Recurse FOLLOWS a
    # junction and would delete the shared store's contents - never use it here.
    foreach ($sub in $script:CcSharedDirs) {
        $link = Join-Path $dir $sub
        $item = Get-Item $link -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType) { [System.IO.Directory]::Delete($link, $false) }
    }
    (Get-Content $script:CcIdentities) | Where-Object { $_ -notmatch "^\s*$([regex]::Escape($Id))\s+" } |
        Set-Content $script:CcIdentities
    if ((Get-CcDefaultId) -eq $Id) { Set-Content $script:CcDefault '' }
    Write-Host "cc: unregistered [$Id]. Its config dir is left in place:" -ForegroundColor Green
    Write-Host "    $dir"
    Write-Host "    Junctions were removed, so deleting it is now safe."
}

function ccuse {
    param([Parameter(Mandatory, Position = 0)][string] $Id)
    $dir = Get-CcDir $Id
    if (-not $dir) {
        Write-Host "cc: no such identity [$Id]. Known: $((Get-CcIds) -join ', ')" -ForegroundColor Red
        Write-Host "    create it with: ccnew $Id"
        return
    }
    if (-not (Test-Path (Join-Path $dir '.credentials.json'))) {
        Write-Host "cc: note - [$Id] has no credentials yet; you will be asked to log in." -ForegroundColor Yellow
    }
    Set-Content -Path $script:CcDefault -Value $Id
    [Environment]::SetEnvironmentVariable('CLAUDE_CONFIG_DIR', $dir, 'User')  # new processes
    $env:CLAUDE_CONFIG_DIR = $dir                                            # this shell
    Write-Host "cc: default identity -> [$Id]" -ForegroundColor Green
    Write-Host "    config: $dir"
    Write-Host "    this shell and all new ones: bare 'claude' is now [$Id]."
    Write-Host "    already-open shells keep their old identity until restarted."
}

function ccwho {
    Initialize-Cc
    $def = Get-CcDefaultId
    Write-Host "default: [$def]"
    Write-Host "this shell: $(if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { '<unset>' })`n"
    $ids = Get-CcIds
    if (-not $ids) { Write-Host "no identities registered yet - start with: ccnew <id>"; return }
    foreach ($id in $ids) {
        $dir   = Get-CcDir $id
        $mark  = if ($id -eq $def) { '*' } else { ' ' }
        $state = if (Test-Path (Join-Path $dir '.credentials.json')) { 'logged in' } else { '-' }
        $live  = ''
        $lock  = Join-Path $dir '.cc-session.lock'
        if (Test-Path $lock) {
            $p = (Get-Content $lock -First 1 -ErrorAction SilentlyContinue)
            if ($p -match '^\d+$' -and (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue)) {
                $live = ' (session running)'
            }
        }
        "{0} {1,-12} {2,-11} {3}{4}" -f $mark, $id, $state, $dir, $live
    }
}

function cc {
    param(
        [Parameter(Position = 0)][string] $Id,
        [switch] $Force,
        # Required: without it PowerShell tries to bind pass-through flags like
        # --resume as cc's own parameters and errors out.
        [Parameter(ValueFromRemainingArguments = $true)][string[]] $Rest
    )
    Initialize-Cc
    if ($Id) {
        if (-not (Get-CcDir $Id)) {
            # A bare word that is not a known identity is almost always a typo.
            # Never auto-create - that silently makes an empty, logged-out account.
            Write-Host "cc: unknown identity [$Id]. Known: $((Get-CcIds) -join ', ')" -ForegroundColor Red
            Write-Host "    if you meant to create it: ccnew $Id"
            return
        }
    } else {
        $Id = Get-CcDefaultId
    }
    if (-not $Id) { Write-Host "cc: no identities registered - start with: ccnew <id>" -ForegroundColor Red; return }

    $dir = Get-CcDir $Id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    # Check the lock BEFORE touching the filesystem: a run we are about to
    # refuse should not have merged or linked anything first.
    if (-not $Force) { if (-not (Test-CcLock -Dir $dir -Id $Id)) { return } }
    if (-not (Connect-CcShared -Dir $dir)) { return }

    $lock = Join-Path $dir '.cc-session.lock'
    Set-Content -Path $lock -Value $PID
    try {
        $env:CLAUDE_CONFIG_DIR = $dir
        Write-Host "cc: claude as [$Id]  (config: $dir)" -ForegroundColor Cyan
        claude @Rest
    } finally {
        Remove-Item $lock -Force -ErrorAction SilentlyContinue
    }
}

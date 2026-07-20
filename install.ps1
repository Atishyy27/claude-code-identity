# Installer for claude-code-identity (Windows / PowerShell).
# Copies cc.ps1 into place and dot-sources it from your $PROFILE. Idempotent.

$ErrorActionPreference = 'Stop'

$src     = Join-Path $PSScriptRoot 'cc.ps1'
$destDir = Join-Path $env:USERPROFILE '.config\cc'
$dest    = Join-Path $destDir 'cc.ps1'
$line    = ". `"$dest`""

if (-not (Test-Path $src)) { throw "install: cannot find cc.ps1 next to this script" }

if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
Copy-Item $src $dest -Force
Write-Host "installed: $dest" -ForegroundColor Green

# Ensure the profile exists, then add the dot-source line once.
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Path $PROFILE -Force | Out-Null
}
if (Select-String -Path $PROFILE -SimpleMatch $dest -Quiet -ErrorAction SilentlyContinue) {
    Write-Host "already sourced from: $PROFILE"
} else {
    Add-Content -Path $PROFILE -Value "`r`n# claude-code-identity`r`n$line"
    Write-Host "added source line to: $PROFILE" -ForegroundColor Green
}

Write-Host @"

Done. Restart PowerShell (or run: $line)

Next:
  ccnew personal "`$env:USERPROFILE\.claude"   # your existing account becomes the shared store
  ccnew work                                  # a second identity
  cc work                                     # launch and log in
"@

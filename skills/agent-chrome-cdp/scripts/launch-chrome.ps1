# Launch a dedicated Chrome with CDP enabled on 127.0.0.1:9222 (Windows).
#
# Usage:
#   powershell -NoProfile -File launch-chrome.ps1 [-Port 9222] [-ProfileDir <path>] [-Headless]

param(
  [int]$Port = 9222,
  [string]$ProfileDir = "$env:LOCALAPPDATA\agent-chrome-profile",
  [switch]$Headless,
  [string]$ChromeBin = $null
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ProfileDir)) { New-Item -ItemType Directory -Path $ProfileDir | Out-Null }

if (-not $ChromeBin) {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { $ChromeBin = $c; break } }
}

if (-not $ChromeBin) { throw "Could not find Chrome. Pass -ChromeBin <path>." }

# Refuse if the port is already in use.
$inUse = (Test-NetConnection -ComputerName 127.0.0.1 -Port $Port -InformationLevel Quiet) 2>$null
if ($inUse) { throw "Port $Port is already in use; pick another with -Port." }

$args = @(
  "--remote-debugging-port=$Port",
  "--remote-debugging-address=127.0.0.1",
  "--user-data-dir=$ProfileDir",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-background-networking",
  "--disable-default-apps"
)
if ($Headless) { $args += @("--headless=new", "--hide-scrollbars", "--mute-audio") }

$logPath = Join-Path $ProfileDir "chrome.log"
$proc = Start-Process -FilePath $ChromeBin -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $logPath
$proc.Id | Set-Content -Path (Join-Path $ProfileDir "chrome.pid")

# Wait up to 10 s for CDP.
for ($i = 0; $i -lt 20; $i++) {
  try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 1 | Out-Null
    Write-Host "Chrome CDP up on http://127.0.0.1:$Port (pid $($proc.Id))"
    exit 0
  } catch { Start-Sleep -Milliseconds 500 }
}

throw "Chrome did not respond on $Port within 10 s. See $logPath"

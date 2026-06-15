# shared/happ.ps1 - download + portable-ize Happ (Windows) + insert subscription via deep-link.
#
# Dot-sourced by builders/windows/build.ps1. Exposes:
#   Get-HappLatestTag                              -> latest happ-desktop release tag (e.g. 2.17.1)
#   Get-HappAssetName  -Arch x64|arm64             -> matching Windows setup asset filename
#   Get-Happ           -Arch -OutDir               -> downloads the setup .exe, returns its path
#   Install-HappPortable -Setup -Dst [-ViaWine]    -> silent Inno install into <Dst> (portable)
#   Write-HappRunner   -Dst                         -> writes apps\happ\run-happ.bat config-redirect
#   Add-HappSubscription -Dst -Raw                  -> imports the subscription via happ:// deep-link
#
# Conventions shared with the rest of the repo (CONTRACTS sec 6/7/9):
#   - Save UTF-8 with BOM for PS 5.1; console set to UTF-8 below.
#   - i18n via T() from shared\i18n.ps1; technical tokens (Happ, flags, URLs) stay untranslated.
#   - Happ config redirected ONTO the stick (APPDATA), never the host profile.
#   - Proxy mode only - never TUN (TUN needs admin everywhere).
#   - Windows = solid/guided. Building a Win stick FROM Linux -> -ViaWine (CONTRACTS sec 7).

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
# Modern, GitHub-compatible TLS for Invoke-* on PS 5.1.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# repo: github.com/Happ-proxy/happ-desktop. Tags are bare semver (no 'v'). (CONTRACTS sec 7)
$script:HappRepo = 'Happ-proxy/happ-desktop'
$script:HappApi  = "https://api.github.com/repos/$($script:HappRepo)/releases/latest"

# Soft i18n shim so this file can be smoke-tested standalone (build.ps1 provides the real T()).
if (-not (Get-Command T -ErrorAction SilentlyContinue)) {
  function T { param([string]$Key) return $Key }
}
function Write-HappInfo { param([string]$Msg) Write-Host $Msg }
function Write-HappWarn { param([string]$Msg) Write-Warning $Msg }

# --------------------------------------------------------------------------------------------------
# 1) Resolve latest release tag from the GitHub API (Invoke-RestMethod -> .tag_name).
# --------------------------------------------------------------------------------------------------
function Get-HappLatestTag {
  [CmdletBinding()] param()
  try {
    $rel = Invoke-RestMethod -Uri $script:HappApi -Headers @{ 'User-Agent' = 'claude-on-a-stick'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 25
  } catch {
    throw (T 'happ_api_fail')
  }
  if (-not $rel.tag_name) { throw (T 'happ_api_fail') }
  return [string]$rel.tag_name
}

# --------------------------------------------------------------------------------------------------
# 2) Windows setup asset name. Verified (2.17.1): setup-Happ.x64.exe / setup-Happ.arm64.exe.
# --------------------------------------------------------------------------------------------------
function Get-HappAssetName {
  [CmdletBinding()] param([ValidateSet('x64','arm64')][string]$Arch = 'x64')
  switch ($Arch) {
    'arm64' { return 'setup-Happ.arm64.exe' }
    default { return 'setup-Happ.x64.exe' }
  }
}

function Get-HappAssetUrl {
  param([string]$Tag, [string]$Asset)
  return "https://github.com/$($script:HappRepo)/releases/download/$Tag/$Asset"
}

# --------------------------------------------------------------------------------------------------
# 3) Download the setup .exe into <OutDir>. Returns the downloaded file path.
# --------------------------------------------------------------------------------------------------
function Get-Happ {
  [CmdletBinding()] param(
    [ValidateSet('x64','arm64')][string]$Arch = 'x64',
    [Parameter(Mandatory)][string]$OutDir
  )
  if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

  $tag   = Get-HappLatestTag
  $asset = Get-HappAssetName -Arch $Arch
  $url   = Get-HappAssetUrl -Tag $tag -Asset $asset
  $out   = Join-Path $OutDir $asset

  Write-HappInfo ("{0} {1} ({2})" -f (T 'happ_downloading'), $asset, $tag)
  try {
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 600
  } catch {
    throw ("{0} {1}" -f (T 'happ_dl_fail'), $url)
  }
  if (-not (Test-Path -LiteralPath $out) -or (Get-Item -LiteralPath $out).Length -le 0) {
    throw ("{0} {1}" -f (T 'happ_dl_fail'), $url)
  }
  return $out
}

# --------------------------------------------------------------------------------------------------
# 4) Portable-ize (Windows).
#    innoextract 1.9 CANNOT read Inno 6.7 -> use the installer's own SILENT mode to lay the app into
#    a directory, asInvoker (no admin), then treat that directory as the portable Happ. (CONTRACTS sec 7)
#    Inno flags (verified): /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /CURRENTUSER /DIR=<dst>
#    -ViaWine: builder runs on Linux building a Windows stick -> run the setup under Wine with a
#              Z:\ path mapping to the destination (CONTRACTS sec 7).
# --------------------------------------------------------------------------------------------------
function Install-HappPortable {
  [CmdletBinding()] param(
    [Parameter(Mandatory)][string]$Setup,
    [Parameter(Mandatory)][string]$Dst,
    [switch]$ViaWine
  )
  if (-not (Test-Path -LiteralPath $Dst)) { New-Item -ItemType Directory -Force -Path $Dst | Out-Null }
  $dstFull = (Resolve-Path -LiteralPath $Dst).Path

  # Shared Inno argument list. /DIR must be a native Windows path.
  $innoArgs = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS','/CURRENTUSER')

  if ($ViaWine) {
    # Building a Windows stick from Linux. Map the Linux dst to a Wine drive path (Z: == /).
    # CONTRACTS sec 7 example: wine setup-Happ.x64.exe /VERYSILENT /DIR=Z:\...
    $wine = Get-Command wine -ErrorAction SilentlyContinue
    if (-not $wine) { throw 'wine not found (needed to build a Windows Happ from Linux)' }
    $winePath = 'Z:' + ($dstFull -replace '/', '\')   # /a/b -> Z:\a\b
    $args = @($Setup) + $innoArgs + @("/DIR=$winePath")
    Write-HappInfo (T 'happ_installing')
    & $wine.Source @args | Out-Null
  } else {
    $args = $innoArgs + @("/DIR=$dstFull")
    Write-HappInfo (T 'happ_installing')
    # Wait for the silent installer to finish before we inspect the directory.
    $p = Start-Process -FilePath $Setup -ArgumentList $args -PassThru -Wait -WindowStyle Hidden
    if ($p.ExitCode -ne 0) {
      Write-HappWarn ("{0} (exit {1})" -f (T 'happ_install_warn'), $p.ExitCode)
    }
  }

  $bin = Find-HappBin -Dst $dstFull
  if (-not $bin) { Write-HappWarn (T 'happ_bin_notfound') }
  Write-HappInfo ("{0} -> {1}" -f (T 'happ_portable_ok'), $dstFull)

  # NOTE: Happ ships no VC++ runtime; most Win10/11 have it. If a bare client errors msvcp140.dll,
  # bundle the VC++ redist DLLs alongside Happ.exe (documented in README). (CONTRACTS sec 7)
  return $dstFull
}

# Find Happ.exe inside an installed tree.
function Find-HappBin {
  param([Parameter(Mandatory)][string]$Dst)
  $direct = Join-Path $Dst 'Happ.exe'
  if (Test-Path -LiteralPath $direct) { return $direct }
  $hit = Get-ChildItem -LiteralPath $Dst -Filter 'Happ.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}

# --------------------------------------------------------------------------------------------------
# 5) run-happ.bat wrapper - redirects Happ's config ONTO the stick and launches it in proxy mode.
#    Written to <Dst>\run-happ.bat (<Dst> = ...\apps\happ on the stick).
#    Config redirect (CONTRACTS sec 6): set APPDATA=<STICK>\apps\happ\data so Happ writes
#    Happ.conf / subs.db there instead of the host profile - portable, no host trace.
#    cmd gotcha (CONTRACTS sec 3): NO unescaped ( ) inside an echo within an if(...) block.
#    -> use goto labels, never parenthesised if-blocks. Honoured below.
# --------------------------------------------------------------------------------------------------
function Write-HappRunner {
  [CmdletBinding()] param([Parameter(Mandatory)][string]$Dst)
  $runner = Join-Path $Dst 'run-happ.bat'

  # Built line-by-line (no parenthesised echo blocks anywhere). %~dp0 = this .bat's folder.
  $lines = @(
    '@echo off'
    'rem run-happ.bat - launch the portable Happ with config redirected onto the stick.'
    'rem Proxy mode only (never TUN - TUN needs admin). Generated by shared\happ.ps1.'
    'setlocal'
    'set "HERE=%~dp0"'
    'rem Redirect Happ config writes into apps\happ\data (no host-profile trace).'
    'set "APPDATA=%HERE%data"'
    'if not exist "%APPDATA%" md "%APPDATA%"'
    ''
    'rem Locate Happ.exe in this portable tree.'
    'set "HAPP_BIN="'
    'if exist "%HERE%Happ.exe" set "HAPP_BIN=%HERE%Happ.exe"'
    'if not defined HAPP_BIN goto findbin'
    'goto run'
    ''
    ':findbin'
    'for /r "%HERE%" %%F in (Happ.exe) do if not defined HAPP_BIN set "HAPP_BIN=%%F"'
    'if not defined HAPP_BIN goto nobin'
    'goto run'
    ''
    ':nobin'
    'echo run-happ: Happ.exe not found under "%HERE%" 1>&2'
    'exit /b 1'
    ''
    ':run'
    'rem Forward any args (e.g. a happ:// deep-link) to the running instance.'
    'start "" "%HAPP_BIN%" %*'
    'endlocal'
  )
  # UTF-8 without BOM for .bat (cmd dislikes a BOM on the first line).
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($runner, (($lines -join "`r`n") + "`r`n"), $enc)
  Write-HappInfo ("{0} {1}" -f (T 'happ_runner_written'), $runner)
  return $runner
}

# --------------------------------------------------------------------------------------------------
# 6) Insert the subscription via the happ:// deep-link.
#    Happ is a SingleApplication (QLocalServer IPC): invoking Happ.exe with a happ:// URL forwards
#    it to the running instance, which imports + AES-persists to its own subs.db. NEVER write
#    subs.db directly. (CONTRACTS sec 7)
#      - raw subscription URL          -> "happ://add/<URL-ENCODED url>"
#      - ready "happ://crypt5/..." etc -> passed VERBATIM (accept-as-pasted, no minting)
#    Accept-as-pasted ONLY - we never call third-party minting (no crypto.happ.su).
# --------------------------------------------------------------------------------------------------
function ConvertTo-HappDeeplink {
  param([Parameter(Mandatory)][string]$Raw)
  if ($Raw -like 'happ://*') { return $Raw }                       # crypt5/add/any - verbatim
  $enc = [System.Uri]::EscapeDataString($Raw)                      # full percent-encode of the raw URL
  return "happ://add/$enc"
}

# Newest mtime among Happ's persisted state files (Happ.conf / subs.db) under the data dir.
# Used to confirm the import actually landed (CONTRACTS sec 7: verify via subs.db updated_at bump).
function Get-HappStateMtime {
  param([Parameter(Mandatory)][string]$DataDir)
  if (-not (Test-Path -LiteralPath $DataDir)) { return [datetime]'1970-01-01' }
  $files = Get-ChildItem -LiteralPath $DataDir -Recurse -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -eq 'Happ.conf' -or $_.Name -eq 'subs.db' }
  if (-not $files) { return [datetime]'1970-01-01' }
  return ($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
}

function Add-HappSubscription {
  [CmdletBinding()] param(
    [Parameter(Mandatory)][string]$Dst,
    [Parameter(Mandatory)][string]$Raw
  )
  $dstFull  = (Resolve-Path -LiteralPath $Dst).Path
  $dataDir  = Join-Path $dstFull 'data'
  $deeplink = ConvertTo-HappDeeplink -Raw $Raw

  $bin = Find-HappBin -Dst $dstFull
  if (-not $bin) {
    Write-HappWarn (T 'happ_bin_notfound')
    Write-HappManual -Deeplink $deeplink
    return $false
  }

  if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Force -Path $dataDir | Out-Null }
  $before = Get-HappStateMtime -DataDir $dataDir

  $runner = Join-Path $dstFull 'run-happ.bat'
  if (-not (Test-Path -LiteralPath $runner)) { Write-HappRunner -Dst $dstFull | Out-Null }

  # Start (or no-op) the portable instance with config on the stick, then give it a moment.
  Write-HappInfo (T 'happ_starting')
  Start-Process -FilePath $runner -WindowStyle Hidden | Out-Null
  Start-Sleep -Seconds 8

  # Forward the deep-link to the running instance. Prefer the binary directly (no scheme handler
  # is registered for the portable copy); `cmd /c start ""` is the documented fallback (CONTRACTS sec 7).
  Write-HappInfo (T 'happ_inserting_sub')
  try {
    Start-Process -FilePath $bin -ArgumentList @($deeplink) -WindowStyle Hidden | Out-Null
  } catch {
    & cmd /c start "" "$deeplink" | Out-Null
  }

  # Wait for import + AES-persist, verify the state mtime bumped (CONTRACTS sec 7).
  for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 1
    $now = Get-HappStateMtime -DataDir $dataDir
    if ($now -gt $before) {
      Write-HappInfo (T 'happ_sub_ok')
      return $true
    }
  }

  Write-HappWarn (T 'happ_sub_unverified')
  Write-HappManual -Deeplink $deeplink
  return $false
}

# On failure, print the deep-link so the user can import it manually once.
function Write-HappManual {
  param([Parameter(Mandatory)][string]$Deeplink)
  Write-HappInfo (T 'happ_manual_hint')
  Write-Host ("    {0}" -f $Deeplink)
}

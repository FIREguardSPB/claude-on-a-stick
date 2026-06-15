# =============================================================================
#  claude-on-a-stick  --  geoguard.ps1  (Windows geo-guard core, anti-ban)
# -----------------------------------------------------------------------------
#  The brains of the geo-guard. geoguard.bat is a thin shim that calls this and
#  propagates the exit code (0 = OK to launch, non-zero = refuse).
#
#  Logic (CONTRACTS.md §5):
#    0. GUARD_ENABLED=0  -> return OK immediately (unrestricted regions).
#    1. Detect exit country DIRECT (no proxy):
#         https://www.cloudflare.com/cdn-cgi/trace  (loc=XX)
#         fallbacks: ipinfo.io/country , api.country.is
#    2. Country NOT in BLOCKLIST -> OK, do NOT touch the VPN (smart skip).
#    3. Blocked -> re-check THROUGH the proxy if one is already up. Only the
#       HTTP proxy works here (PS 5.1 has no SOCKS).
#    4. Still blocked or no proxy -> refuse.
#    5. Undetermined -> per INCONCLUSIVE (prompt|block|allow).
#
#  Exit codes (so geoguard.bat can react -- smart-skip means we do NOT bring up
#  the VPN until we KNOW the direct region is blocked):
#       0  = OK, launch allowed.
#       1  = refuse the launch.
#       2  = direct region is BLOCKED and no proxy is up yet -> the caller
#            (geoguard.bat) should bring up vpnup and re-run this script; the
#            proxied recheck then yields 0 or 1.
#
#  Config is read from geoguard.conf next to this script. The proxy, if any,
#  is read from the HTTPS_PROXY env var (set by vpnup.bat).
#
#  Save as UTF-8 with BOM for PS 5.1 (builder enforces this).
# =============================================================================

param(
    [string]$ConfPath = (Join-Path $PSScriptRoot 'geoguard.conf')
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# --- Defaults (overridden by geoguard.conf) ----------------------------------
$GuardEnabled = 1
$Blocklist    = @('RU','BY','CU','IR','KP','SY')
$Inconclusive = 'prompt'   # prompt | block | allow

# --- Parse geoguard.conf (simple KEY=VALUE lines, # comments) -----------------
if (Test-Path -LiteralPath $ConfPath) {
    foreach ($line in Get-Content -LiteralPath $ConfPath) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $t.Substring(0, $eq).Trim()
        $val = $t.Substring($eq + 1).Trim().Trim('"').Trim("'")
        switch ($key) {
            'GUARD_ENABLED' { $GuardEnabled = [int]($val -as [int]) }
            'BLOCKLIST'     { $Blocklist = @($val -split '[,; ]+' | Where-Object { $_ -ne '' } | ForEach-Object { $_.ToUpperInvariant() }) }
            'INCONCLUSIVE'  { $Inconclusive = $val.ToLowerInvariant() }
        }
    }
}

# --- Step 0: guard disabled -> OK --------------------------------------------
if ($GuardEnabled -eq 0) {
    Write-Host '[geoguard] Disabled in geoguard.conf -> launch allowed.'
    exit 0
}

# --- Helper: query a trace/country endpoint, optionally through a proxy -------
function Get-ExitCountry {
    param([string]$Proxy)

    $common = @{ TimeoutSec = 8; UseBasicParsing = $true; ErrorAction = 'Stop' }
    if ($Proxy) { $common['Proxy'] = $Proxy }

    # 1) Cloudflare trace: a body of "key=value" lines incl. loc=XX
    try {
        $r = Invoke-WebRequest -Uri 'https://www.cloudflare.com/cdn-cgi/trace' @common
        foreach ($l in ($r.Content -split "`n")) {
            if ($l -match '^\s*loc=([A-Za-z]{2})\s*$') { return $Matches[1].ToUpperInvariant() }
        }
    } catch {}

    # 2) ipinfo.io/country -> bare "XX"
    try {
        $c = (Invoke-RestMethod -Uri 'https://ipinfo.io/country' @common)
        $c = ("$c").Trim()
        if ($c -match '^[A-Za-z]{2}$') { return $c.ToUpperInvariant() }
    } catch {}

    # 3) api.country.is -> JSON { "ip":..., "country":"XX" }
    try {
        $j = Invoke-RestMethod -Uri 'https://api.country.is' @common
        if ($j.country -match '^[A-Za-z]{2}$') { return ([string]$j.country).ToUpperInvariant() }
    } catch {}

    return $null
}

# --- Step 1: detect DIRECT (no proxy) ----------------------------------------
Write-Host '[geoguard] Checking exit country (direct)...'
$country = Get-ExitCountry -Proxy $null

# --- Step 5 (early): undetermined direct result ------------------------------
function Resolve-Inconclusive {
    param([string]$Mode)
    switch ($Mode) {
        'allow' { Write-Host '[geoguard] Country undetermined -> INCONCLUSIVE=allow -> launch.'; exit 0 }
        'block' { Write-Host '[geoguard] Country undetermined -> INCONCLUSIVE=block -> refuse.'; exit 1 }
        default {
            $ans = Read-Host '[geoguard] Could not determine exit country. Launch anyway? (y/N)'
            if ($ans -match '^(y|yes)$') { exit 0 } else { exit 1 }
        }
    }
}

if (-not $country) { Resolve-Inconclusive -Mode $Inconclusive }

Write-Host ("[geoguard] Direct exit country: {0}" -f $country)

# --- Step 2: not blocked -> OK, do NOT touch the VPN (smart skip) -------------
if ($Blocklist -notcontains $country) {
    Write-Host '[geoguard] Region not blocked -> launch allowed (VPN untouched).'
    exit 0
}

# --- Step 3: blocked -> re-check THROUGH the proxy (if one is up) -------------
Write-Host ("[geoguard] Region {0} is BLOCKED. Re-checking through proxy..." -f $country)

$proxy = $env:HTTPS_PROXY
if (-not $proxy) { $proxy = $env:HTTP_PROXY }

if (-not $proxy) {
    # No proxy yet. Signal the caller to bring up the VPN and re-run us, rather
    # than refusing outright -- this preserves the "smart skip" guarantee: the
    # VPN is only ever started AFTER we have confirmed a blocked direct region.
    Write-Host '[geoguard] No proxy active yet -> requesting VPN bring-up (exit 2).'
    exit 2
}

Write-Host ("[geoguard] Using proxy {0} for recheck." -f $proxy)
$viaCountry = Get-ExitCountry -Proxy $proxy

if (-not $viaCountry) {
    Write-Host '[geoguard] Recheck through proxy was undetermined.'
    Resolve-Inconclusive -Mode $Inconclusive
}

Write-Host ("[geoguard] Proxied exit country: {0}" -f $viaCountry)

# --- Step 4: still blocked -> refuse; else OK --------------------------------
if ($Blocklist -contains $viaCountry) {
    Write-Host ("[geoguard] Proxy exit {0} is STILL blocked -> refuse launch." -f $viaCountry)
    exit 1
}

Write-Host ("[geoguard] Proxy moves us to {0} (not blocked) -> launch allowed." -f $viaCountry)
exit 0

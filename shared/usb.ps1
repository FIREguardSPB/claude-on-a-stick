# shared/usb.ps1 - claude-on-a-stick
# ===========================================================================
# Removable-disk enumeration + interactive pick + exFAT format helper (Windows)
#
# Contract refs (CONTRACTS.md §10 "USB select + format (guards)"):
#   Windows: Get-Disk | ? BusType -eq 'USB'  ; confirm by size+model;
#            Clear-Disk + New-Partition + Format-Volume -FileSystem exFAT
#            -NewFileSystemLabel CLAUDE  (requires admin); partition style MBR.
#   ALL    : show device id + size + model, require a typed ERASE confirmation
#            that echoes the device id back, before destroying anything.
#            NEVER offer system / internal disks.
#
# This is a LIBRARY: dot-source it ( . .\shared\usb.ps1 ) then call
#   Invoke-UsbSelectAndFormat   (or the granular Get-/Select-/Confirm-/Format-
#   verbs). No top-level side effects so the builder can dot-source it safely.
#
# i18n (CONTRACTS §9): ALL user-facing strings go through the project T()
# accessor from shared/i18n.ps1, using the canonical dotted keys
# (usb.scanning, usb.row, usb.erase_prompt, fmt.start, …). T() uses .NET -f
# formatting for {0} {1} … and returns a STRING (no implicit newline).
# If shared/i18n.ps1 has NOT been dot-sourced, we install a minimal English
# fallback T() that defines the SAME keys, so this module is robust standalone.
#
# Encoding note (CONTRACTS §9): save as UTF-8 WITH BOM for Windows PowerShell
# 5.1. We also pin the console output encoding to UTF-8 below.
# ===========================================================================

# --- console encoding (PS 5.1 friendliness) --------------------------------
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# --- Volume label (single source of truth, matches produced artifact) ------
if (-not $script:UsbLabel) { $script:UsbLabel = 'CLAUDE' }

# --- i18n shim --------------------------------------------------------------
# Prefer the real project accessor from shared/i18n.ps1. If T is absent (this
# file was dot-sourced on its own), install a minimal English fallback that
# defines the SAME dotted keys this module emits and uses .NET -f formatting.
if (-not (Get-Command -Name T -ErrorAction SilentlyContinue)) {
    $script:_UsbFallbackMsg = @{
        'usb.scanning'       = 'Scanning for removable USB disks...'
        'usb.none_found'     = 'No removable USB disk found. Plug one in and re-run.'
        'usb.list_header'    = 'Detected removable disks (internal disks are NEVER offered):'
        'usb.row'            = '  {0})  {1}   size={2}   model={3}'
        'usb.choose'         = "Type the number of the target disk (or 'q' to quit): "
        'usb.bad_choice'     = 'Not a valid choice. Try again.'
        'usb.is_hdd_warn'    = "Note: a USB HDD also shows as a USB disk. Make ABSOLUTELY sure '{0}' is the stick you want to erase."
        'usb.warn_title'     = '!!! DESTRUCTIVE ACTION - READ CAREFULLY !!!'
        'usb.warn_body'      = 'ALL data on {0} ({1}, {2}) will be PERMANENTLY ERASED. This cannot be undone.'
        'usb.erase_prompt'   = 'To confirm, type ERASE {0} exactly (anything else cancels): '
        'usb.erase_mismatch' = 'Confirmation did not match. Nothing was erased.'
        'fmt.start'          = 'Formatting {0} ... (MBR, single exFAT partition type 0x07, label CLAUDE)'
        'fmt.clear'          = '  - Clearing the disk (Clear-Disk)...'
        'fmt.parttable'      = '  - Initializing MBR partition table...'
        'fmt.partition'      = '  - Creating one partition...'
        'fmt.mkfs'           = '  - Formatting exFAT (label CLAUDE)...'
        'fmt.done'           = 'Format complete. Stick is drive {0}.'
        'fmt.need_admin'     = 'Formatting needs Administrator. Re-run this builder elevated (Run as administrator).'
    }
    function T {
        param(
            [Parameter(Mandatory = $true, Position = 0)] [string] $Key,
            [Parameter(ValueFromRemainingArguments = $true)] [object[]] $Args
        )
        if ($script:_UsbFallbackMsg.ContainsKey($Key)) {
            $tmpl = $script:_UsbFallbackMsg[$Key]
        } else {
            return "<<$Key>>"
        }
        if ($null -ne $Args -and $Args.Count -gt 0) {
            try { return ($tmpl -f $Args) } catch { return $tmpl }
        }
        return $tmpl
    }
}

# --- UI helpers (write chrome to the host) ---------------------------------
function script:_UsbLine([string]$key) { Write-Host (T $key) }
function script:_UsbLineF { param([string]$key) Write-Host (T $key @($args)) }

# ===========================================================================
# ENUMERATION
# ===========================================================================
# Get-UsbCandidateDisk
#   Returns objects @{ Number; Id; Size; SizeText; Model } for USB-bus disks
#   ONLY. The hard gate is BusType -eq 'USB' so internal NVMe/SATA system
#   disks can never appear. We additionally drop disks flagged IsSystem/IsBoot
#   as defence-in-depth.
function Get-UsbCandidateDisk {
    if (-not (Get-Command -Name Get-Disk -ErrorAction SilentlyContinue)) {
        Write-Host 'Storage cmdlets not available (Get-Disk/Clear-Disk). Needs Windows 8+/Server 2012+.' -ForegroundColor Red
        return @()
    }
    $disks = Get-Disk -ErrorAction SilentlyContinue |
        Where-Object { $_.BusType -eq 'USB' } |
        Where-Object { -not $_.IsSystem -and -not $_.IsBoot }

    $out = @()
    foreach ($d in $disks) {
        $model = $d.FriendlyName
        if ([string]::IsNullOrWhiteSpace($model)) { $model = '(unknown model)' }
        $sizeGB = [math]::Round(($d.Size / 1GB), 1)
        $out += [pscustomobject]@{
            Number   = $d.Number
            Id       = "PhysicalDrive$($d.Number)"   # echoed in the ERASE phrase
            Size     = $d.Size
            SizeText = "$sizeGB GB"
            Model    = $model.Trim()
        }
    }
    return ,$out
}

# ===========================================================================
# SELECTION (interactive, explicit pick)
# ===========================================================================
# Select-UsbDisk
#   Lists candidates and makes the user type a NUMBER to pick one. Never auto-
#   picks even with a single candidate (a USB HDD is also BusType USB).
#   Returns the chosen candidate object, or $null on abort/no-disk.
function Select-UsbDisk {
    Write-Host (T 'usb.scanning')

    $cands = @(Get-UsbCandidateDisk)
    if ($cands.Count -eq 0) {
        Write-Host (T 'usb.none_found') -ForegroundColor Red
        return $null
    }

    Write-Host (T 'usb.list_header')
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $c = $cands[$i]
        Write-Host (T 'usb.row' ($i + 1) $c.Id $c.SizeText $c.Model)
    }

    # Explicit numeric pick. 'q' aborts.
    while ($true) {
        Write-Host (T 'usb.choose') -NoNewline
        $choice = Read-Host
        if ($choice -match '^[qQ]$') {
            Write-Host (T 'usb.erase_mismatch') -ForegroundColor Red   # treated as cancel
            return $null
        }
        if ($choice -match '^[0-9]+$') {
            $n = [int]$choice
            if ($n -ge 1 -and $n -le $cands.Count) {
                return $cands[$n - 1]
            }
        }
        Write-Host (T 'usb.bad_choice') -ForegroundColor Red
    }
}

# ===========================================================================
# CONFIRMATION (typed ERASE + echoed device id)
# ===========================================================================
# Confirm-UsbErase <disk-object>
#   Shows the loud destructive warning + the USB-HDD caveat, then requires the
#   user to type literally:  ERASE PhysicalDriveN  (case-SENSITIVE, exact).
#   Returns $true only on an exact match.
function Confirm-UsbErase {
    param([Parameter(Mandatory)] $Disk)
    Write-Host (T 'usb.warn_title') -ForegroundColor Yellow
    Write-Host (T 'usb.is_hdd_warn' $Disk.Id)
    Write-Host (T 'usb.warn_body' $Disk.Id $Disk.SizeText $Disk.Model) -ForegroundColor Yellow
    Write-Host (T 'usb.erase_prompt' $Disk.Id) -NoNewline
    $typed = Read-Host
    if ($typed -ceq ("ERASE " + $Disk.Id)) {   # -ceq = case-SENSITIVE match
        return $true
    }
    Write-Host (T 'usb.erase_mismatch') -ForegroundColor Red
    return $false
}

# ===========================================================================
# ADMIN / PREREQ CHECK
# ===========================================================================
function Test-UsbAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

# ===========================================================================
# FORMAT
# ===========================================================================
# Format-UsbDisk <disk-object>
#   Clear-Disk -RemoveData  ->  Initialize-Disk -MBR  ->
#   New-Partition -UseMaximumSize -AssignDriveLetter  ->
#   Format-Volume -FileSystem exFAT -NewFileSystemLabel CLAUDE.
#   Requires Administrator. Returns the assigned drive letter (e.g. 'E') on
#   success, or $null on failure.
function Format-UsbDisk {
    param([Parameter(Mandatory)] $Disk)

    if (-not (Test-UsbAdmin)) {
        Write-Host (T 'fmt.need_admin') -ForegroundColor Red
        return $null
    }
    if (-not (Get-Command -Name Clear-Disk -ErrorAction SilentlyContinue)) {
        Write-Host 'Storage cmdlets not available (Get-Disk/Clear-Disk). Needs Windows 8+/Server 2012+.' -ForegroundColor Red
        return $null
    }

    $num = $Disk.Number
    Write-Host (T 'fmt.start' $Disk.Id)

    try {
        # 1) Wipe everything currently on the disk.
        Write-Host (T 'fmt.clear')
        Clear-Disk -Number $num -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop

        # 2) MBR table. Initialize if RAW; otherwise force MBR (in case GPT).
        Write-Host (T 'fmt.parttable')
        $d = Get-Disk -Number $num -ErrorAction Stop
        if ($d.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $num -PartitionStyle MBR -Confirm:$false -ErrorAction Stop | Out-Null
        } else {
            Set-Disk -Number $num -PartitionStyle MBR -ErrorAction SilentlyContinue
        }
        # Make sure the disk is online + writable.
        if ($d.IsOffline)  { Set-Disk -Number $num -IsOffline $false  -ErrorAction SilentlyContinue }
        if ($d.IsReadOnly) { Set-Disk -Number $num -IsReadOnly $false -ErrorAction SilentlyContinue }

        # 3) Single partition, max size, auto drive letter.
        Write-Host (T 'fmt.partition')
        $part = New-Partition -DiskNumber $num -UseMaximumSize -AssignDriveLetter -ErrorAction Stop

        # 4) exFAT filesystem labelled CLAUDE.
        Write-Host (T 'fmt.mkfs')
        $null = Format-Volume -Partition $part -FileSystem exFAT `
                  -NewFileSystemLabel $script:UsbLabel -Confirm:$false -Force -ErrorAction Stop

        $letter = [string]$part.DriveLetter
        Write-Host (T 'fmt.done' ("{0}:" -f $letter))
        return $letter
    }
    catch {
        Write-Host ("Format FAILED: " + $_.Exception.Message) -ForegroundColor Red
        return $null
    }
}

# ===========================================================================
# ORCHESTRATOR (the one the builder usually calls)
# ===========================================================================
# Invoke-UsbSelectAndFormat
#   Full guarded flow: enumerate -> explicit pick -> typed ERASE confirm ->
#   format. Returns the assigned drive letter (e.g. 'E') on success so the
#   caller knows where to copy the payload; $null on any abort/failure.
function Invoke-UsbSelectAndFormat {
    $disk = Select-UsbDisk
    if ($null -eq $disk) { return $null }

    if (-not (Confirm-UsbErase -Disk $disk)) { return $null }

    $letter = Format-UsbDisk -Disk $disk
    if ([string]::IsNullOrEmpty($letter)) { return $null }

    return $letter
}

# ---------------------------------------------------------------------------
# Allow direct execution for manual testing:  powershell -File shared\usb.ps1
# When dot-sourced, $MyInvocation.InvocationName is '.', so we skip this.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s') {
    Invoke-UsbSelectAndFormat | Out-Null
}

<#
.SYNOPSIS
    Removes the Secure Delete right-click menu and everything it installed.

.DESCRIPTION
    Standalone cleanup. It does not need SecureDelete.ps1 to be present, and it is safe
    to run when nothing is installed or when an install only partly succeeded -- it
    surveys first, reports what it finds, then removes it.

    By default SDelete itself is left alone, since it is a generally useful tool and may
    have been installed before this. Use -RemoveSDelete to uninstall that too.

.PARAMETER RemoveSDelete
    Also uninstall the Microsoft.Sysinternals.SDelete winget package and remove the
    Sysinternals EULA acceptance for the current user.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-SecureDelete.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-SecureDelete.ps1 -WhatIf
    Shows what would be removed without touching anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Uninstall-SecureDelete.ps1 -RemoveSDelete

.NOTES
    Everything this removes lives under HKEY_CURRENT_USER and %LOCALAPPDATA%, so no
    administrator rights are needed. It only affects the user who runs it.
#>
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$RemoveSDelete
)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'SecureDelete'
$WingetId   = 'Microsoft.Sysinternals.SDelete'
$EulaSubKey = 'Software\Sysinternals\SDelete'

# Every subkey any version of the installer has ever written. The "*" is a literal key
# name, so all registry work here uses the .NET API rather than the PowerShell registry
# provider, which would treat it as a wildcard.
$VerbSubKeys = @(
    'Software\Classes\*\shell\SecureDelete',
    'Software\Classes\Directory\shell\SecureDelete',
    'Software\Classes\lnkfile\shell\SecureDelete'
)


function Write-Step    { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Detail  { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Success { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Problem { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

function Test-SubKeyExists {
    param([string]$SubKey)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
    if ($key) { $key.Dispose(); return $true }
    return $false
}

function Update-ShellAssociations {
    try {
        if (-not ('SecureDeleteCleanup.Shell' -as [type])) {
            Add-Type -Namespace 'SecureDeleteCleanup' -Name 'Shell' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);
'@
        }
        # SHCNE_ASSOCCHANGED / SHCNF_IDLIST
        [SecureDeleteCleanup.Shell]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch {
        Write-Problem 'Could not notify Explorer; restart Explorer if a stale menu entry lingers.'
    }
}



Write-Host ''
Write-Host '  Secure Delete cleanup' -ForegroundColor White
Write-Host '  ---------------------' -ForegroundColor DarkGray

# --- Survey ------------------------------------------------------------------------

Write-Step 'Looking for what is installed'

$presentKeys = @($VerbSubKeys | Where-Object { Test-SubKeyExists -SubKey $_ })
$dirPresent  = Test-Path -LiteralPath $InstallDir
$eulaPresent = Test-SubKeyExists -SubKey $EulaSubKey

$sdeleteInstalled = $false
$wingetAvailable = [bool](Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue)
if ($wingetAvailable) {
    & winget.exe list --id $WingetId --exact --disable-interactivity 2>&1 | Out-Null
    $sdeleteInstalled = ($LASTEXITCODE -eq 0)
}

if ($presentKeys.Count -gt 0) {
    foreach ($key in $presentKeys) { Write-Detail "menu entry   HKCU\$key" }
} else {
    Write-Detail 'menu entry   none found'
}
Write-Detail $(if ($dirPresent) { "files        $InstallDir" } else { 'files        none found' })
Write-Detail $(if ($sdeleteInstalled) { "sdelete      installed ($WingetId)" } else { 'sdelete      not installed via winget' })

if ($presentKeys.Count -eq 0 -and -not $dirPresent -and -not ($RemoveSDelete -and $sdeleteInstalled)) {
    Write-Host ''
    Write-Host '  Nothing to clean up.' -ForegroundColor Green
    Write-Host ''
    return
}

$removed = 0
$failed  = 0

# --- Registry ----------------------------------------------------------------------

if ($presentKeys.Count -gt 0) {
    Write-Step 'Removing the right-click menu'
    foreach ($subKey in $presentKeys) {
        if (-not $PSCmdlet.ShouldProcess("HKCU\$subKey", 'Remove registry key')) { continue }
        try {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($subKey, $false)
            Write-Success "Removed HKCU\$subKey"
            $removed++
        } catch {
            Write-Problem "Could not remove HKCU\$subKey : $($_.Exception.Message)"
            $failed++
        }
    }
    Update-ShellAssociations
}

# --- Files -------------------------------------------------------------------------

if ($dirPresent) {
    Write-Step 'Removing installed files'
    $contents = @(Get-ChildItem -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue)
    foreach ($item in $contents) { Write-Detail $item.Name }

    if ($PSCmdlet.ShouldProcess($InstallDir, 'Delete folder and contents')) {
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Write-Success "Deleted $InstallDir"
            $removed++
        } catch {
            Write-Problem "Could not delete $InstallDir : $($_.Exception.Message)"
            Write-Detail 'A delete may still be running from this folder. Close it and try again.'
            $failed++
        }
    }
}

# --- SDelete itself ----------------------------------------------------------------

if ($RemoveSDelete) {
    Write-Step 'Removing SDelete'
    if (-not $wingetAvailable) {
        Write-Problem 'winget is not available; remove SDelete by hand if you need it gone.'
    } elseif (-not $sdeleteInstalled) {
        Write-Detail 'Not installed via winget; nothing to remove.'
    } elseif ($PSCmdlet.ShouldProcess($WingetId, 'Uninstall winget package')) {
        & winget.exe uninstall --id $WingetId --exact --disable-interactivity
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Uninstalled $WingetId"
            $removed++
        } else {
            Write-Problem "winget exit code $LASTEXITCODE; SDelete may still be installed."
            $failed++
        }
    }

    if ($eulaPresent -and $PSCmdlet.ShouldProcess("HKCU\$EulaSubKey", 'Remove registry key')) {
        try {
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($EulaSubKey, $false)
            Write-Success "Removed HKCU\$EulaSubKey"
            $removed++
        } catch {
            Write-Problem "Could not remove HKCU\$EulaSubKey : $($_.Exception.Message)"
            $failed++
        }
    }
}

# --- Summary -----------------------------------------------------------------------

Write-Host ''
if ($WhatIfPreference) {
    Write-Host '  Nothing was changed (-WhatIf).' -ForegroundColor Cyan
} elseif ($failed -gt 0) {
    Write-Host "  Finished with $failed problem(s); $removed item(s) removed." -ForegroundColor Yellow
} else {
    Write-Host "  Clean. $removed item(s) removed." -ForegroundColor Green
}
if (-not $RemoveSDelete -and $sdeleteInstalled) {
    Write-Detail "SDelete was left installed. Remove it with:  winget uninstall --id $WingetId"
}
Write-Host ''

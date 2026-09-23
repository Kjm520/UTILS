<#
.SYNOPSIS
    Installs Sysinternals SDelete via winget and adds a right-click menu entry that
    hands you a ready-to-run SDelete command. It never deletes anything itself.

.DESCRIPTION
    Run once with no arguments to install. The script:
      1. Installs Microsoft.Sysinternals.SDelete with winget (per-user, portable, no admin).
      2. Accepts the Sysinternals EULA for the current user.
      3. Copies itself to %LOCALAPPDATA%\SecureDelete so the shared copy can be deleted.
      4. Writes a small launcher and registers a shell verb under HKCU.

    The same file is also the runtime handler. Right-clicking a file or folder opens a
    PowerShell window listing the selected paths and the exact SDelete command for them,
    copied to the clipboard. You read it, and you run it yourself.

    Nothing is erased by the menu, at any point. That is the whole design: Explorer
    hands a shell verb the path IT chose, which for a shortcut is the shortcut's target
    rather than the shortcut. Rather than trying to out-guess that, the command is put
    in front of you first -- an unintended path is visible before anything runs.

.PARAMETER Passes
    Number of overwrite passes written into the generated command. Default 1.

.PARAMETER MenuText
    Label shown in the context menu.

.PARAMETER Icon
    Icon for the menu entry, as "path,index" (a negative number is a resource ID).
    Defaults to the red delete mark, imageres.dll,-89.

.PARAMETER Position
    Where the entry sits in the menu: Bottom (default, beside Delete and Rename), Top
    (first item, above Open), or Default (wherever the shell puts it). Every
    registration gets the same value, so the entry never moves about.

.PARAMETER Force
    Reinstall the winget package even if SDelete is already present.

.PARAMETER Uninstall
    Remove the menu entries and the installed copy. Leaves the SDelete package in place.
    Uninstall-SecureDelete.ps1 does the same job without needing this file.

.PARAMETER Run
    Internal. Called by the context menu with the selected path.

.PARAMETER Show
    Internal. Marks the visible window that displays the command.

.PARAMETER ShowFile
    Internal. JSON payload of paths and settings handed to that window.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\SecureDelete.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\SecureDelete.ps1 -Passes 3

.NOTES
    On Windows 11 the entry appears under "Show more options" (Shift+F10), because the
    compact menu only lists commands from packaged IExplorerCommand handlers.

    Shortcuts: Explorer resolves a .lnk to its target while building the menu, before
    any of this runs, so a shortcut produces a command aimed at whatever it points at.
    The generated command shows that plainly. Run SDelete on the .lnk directly from a
    terminal to erase the shortcut itself -- nothing downstream of the shell resolves
    links, so that works as expected.
#>
#Requires -Version 5.1
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(1, 16)]
    [int]$Passes = 1,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateNotNullOrEmpty()]
    [string]$MenuText = 'Secure Delete (SDelete)',

    [Parameter(ParameterSetName = 'Install')]
    [string]$Icon,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Bottom', 'Top', 'Default')]
    [string]$Position = 'Bottom',

    [Parameter(ParameterSetName = 'Install')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory = $true)]
    [switch]$Uninstall,

    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [switch]$Run,

    [Parameter(ParameterSetName = 'Run', Mandatory = $true)]
    [string]$Path,

    [Parameter(ParameterSetName = 'Show', Mandatory = $true)]
    [switch]$Show,

    [Parameter(ParameterSetName = 'Show', Mandatory = $true)]
    [string]$ShowFile
)

$ErrorActionPreference = 'Stop'

$InstallDir   = Join-Path $env:LOCALAPPDATA 'SecureDelete'
$TargetPath   = Join-Path $InstallDir 'SecureDelete.ps1'
$LauncherPath = Join-Path $InstallDir 'launch.vbs'
$ConfigPath   = Join-Path $InstallDir 'config.json'
$QueuePath    = Join-Path $InstallDir 'queue.txt'
$WingetId     = 'Microsoft.Sysinternals.SDelete'

# Subkeys under HKCU, relative to the CurrentUser hive. The "*" is a literal key name,
# which is why every registry operation below uses the .NET API and not the PS provider
# (the provider would treat it as a wildcard).
#
# There is deliberately no lnkfile registration. It would only ever win when positioned
# above the "*" one, which would move the entry for shortcuts only; and since nothing
# here deletes, the resolved path is simply shown rather than acted on.
$VerbSubKeys = @(
    'Software\Classes\*\shell\SecureDelete',
    'Software\Classes\Directory\shell\SecureDelete'
)

# Everything any version of this installer has ever registered, so -Uninstall still
# clears keys that newer versions no longer create.
$AllVerbSubKeys = $VerbSubKeys + @('Software\Classes\lnkfile\shell\SecureDelete')


#region Output helpers

function Write-Step    { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Detail  { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Success { param([string]$Message) Write-Host "    $Message" -ForegroundColor Green }
function Write-Problem { param([string]$Message) Write-Host "    $Message" -ForegroundColor Yellow }

#endregion


#region Registry helpers

function Set-VerbKey {
    <#
        MenuPosition takes "Top", "Bottom", or "" to leave placement to the shell. Those
        are the only levers a static registry verb has: an arbitrary index is not
        available, and CommandFlags separators are ignored for static verbs (measured --
        ECF_SEPARATORBEFORE changed nothing).
    #>
    param(
        [string]$SubKey,
        [string]$Label,
        [string]$IconSpec,
        [string]$Command,
        [string]$MenuPosition
    )
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
    try {
        $key.SetValue('', $Label, [Microsoft.Win32.RegistryValueKind]::String)
        $key.SetValue('MUIVerb', $Label, [Microsoft.Win32.RegistryValueKind]::String)
        if ($IconSpec) {
            $key.SetValue('Icon', $IconSpec, [Microsoft.Win32.RegistryValueKind]::String)
        } else {
            $key.DeleteValue('Icon', $false)
        }
        if ($MenuPosition) {
            $key.SetValue('Position', $MenuPosition, [Microsoft.Win32.RegistryValueKind]::String)
        } else {
            $key.DeleteValue('Position', $false)
        }
    } finally {
        $key.Dispose()
    }

    $cmdKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("$SubKey\command")
    try {
        $cmdKey.SetValue('', $Command, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        $cmdKey.Dispose()
    }
}

function Remove-VerbKey {
    param([string]$SubKey)
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($SubKey, $false)
}

function Set-SDeleteEulaAccepted {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Sysinternals\SDelete')
    try {
        $key.SetValue('EulaAccepted', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally {
        $key.Dispose()
    }
}

function Update-ShellAssociations {
    try {
        if (-not ('SecureDeleteSetup.Shell' -as [type])) {
            Add-Type -Namespace 'SecureDeleteSetup' -Name 'Shell' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);
'@
        }
        # SHCNE_ASSOCCHANGED / SHCNF_IDLIST
        [SecureDeleteSetup.Shell]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
    } catch {
        Write-Problem 'Could not notify Explorer of the change; restart Explorer if the menu is missing.'
    }
}

#endregion


#region Locating SDelete

function Get-PreferredExeNames {
    $arch = 'X64'
    try { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { }

    switch ($arch) {
        'Arm64' { return @('sdelete64a.exe', 'sdelete64.exe', 'sdelete.exe') }
        'X64'   { return @('sdelete64.exe', 'sdelete.exe') }
        default {
            if ([Environment]::Is64BitOperatingSystem) { return @('sdelete64.exe', 'sdelete.exe') }
            return @('sdelete.exe')
        }
    }
}

function Resolve-SDelete {
    <#
        Returns the full path to the best available sdelete executable, or $null.
        Looks in the winget user and machine layouts as well as PATH: winget's portable
        packages do not always get a shim in the Links folder, so PATH alone is not
        enough to find an installed copy.
    #>
    $names = Get-PreferredExeNames
    $found = [ordered]@{}

    $linkDirs = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:ProgramFiles 'WinGet\Links')
    )
    foreach ($dir in $linkDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($name in $names) {
            $candidate = Join-Path $dir $name
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and -not $found.Contains($name)) {
                $found[$name] = $candidate
            }
        }
    }

    $packageDirs = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        (Join-Path $env:ProgramFiles 'WinGet\Packages')
    )
    foreach ($dir in $packageDirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $hits = Get-ChildItem -LiteralPath $dir -Filter 'sdelete*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue
        foreach ($item in $hits) {
            if (($names -contains $item.Name) -and -not $found.Contains($item.Name)) {
                $found[$item.Name] = $item.FullName
            }
        }
    }

    foreach ($name in $names) {
        if ($found.Contains($name)) { continue }
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { $found[$name] = $cmd.Source }
    }

    foreach ($name in $names) {
        if ($found.Contains($name)) { return $found[$name] }
    }
    return $null
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

#endregion


#region Install / uninstall

function New-LauncherScript {
    <#
        Explorer starts one process per selected item. If the verb pointed straight at
        powershell.exe, every one of them would flash a console window. wscript.exe is a
        GUI host, so launching through this shim starts the handler with no window at
        all; one of them then opens a single visible window for the whole selection.
    #>
    param([string]$PowerShellPath, [string]$HandlerPath, [string]$Destination)

    $template = @'
' Secure Delete launcher -- starts the handler with no console window.
' Generated by SecureDelete.ps1. Editing this file by hand is not expected.
Option Explicit
Dim sh, q, cmd
If WScript.Arguments.Count = 0 Then WScript.Quit
Set sh = CreateObject("WScript.Shell")
q = Chr(34)
cmd = q & "__PSH__" & q & " -NoProfile -ExecutionPolicy Bypass -File " & q & "__HANDLER__" & q & " -Run -Path " & q & WScript.Arguments(0) & q
sh.Run cmd, 0, False
'@
    $vbs = $template.Replace('__PSH__', $PowerShellPath).Replace('__HANDLER__', $HandlerPath)
    Set-Content -LiteralPath $Destination -Value $vbs -Encoding ASCII
}

function Invoke-Install {
    Write-Host ''
    Write-Host '  Secure Delete context menu installer' -ForegroundColor White
    Write-Host '  ------------------------------------' -ForegroundColor DarkGray

    Write-Step 'Checking for winget'
    if (-not (Get-Command 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "winget was not found. Install 'App Installer' from the Microsoft Store, then run this script again."
    }
    Write-Success 'winget is available.'

    Write-Step 'Installing SDelete'
    $sdelete = Resolve-SDelete
    if ($sdelete -and -not $Force) {
        Write-Success "Already installed: $sdelete"
    } else {
        Write-Detail "Running: winget install --id $WingetId"
        & winget.exe install --id $WingetId --exact --source winget `
            --accept-package-agreements --accept-source-agreements --disable-interactivity
        $wingetExit = $LASTEXITCODE

        Update-SessionPath
        $sdelete = Resolve-SDelete

        if (-not $sdelete) {
            throw "winget finished with exit code $wingetExit and no sdelete executable could be found. Install it manually and re-run this script."
        }
        if ($wingetExit -ne 0) {
            Write-Problem "winget exit code $wingetExit, but SDelete is present; continuing."
        }
        Write-Success "Installed: $sdelete"
    }

    Write-Step 'Accepting the Sysinternals license for this user'
    Set-SDeleteEulaAccepted
    Write-Success 'Done (no first-run dialog when you run the command).'

    Write-Step 'Installing the handler'
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $source = $PSCommandPath
    if (-not $source) {
        throw 'Cannot determine this script''s own path. Run it from a file rather than pasting it into a console.'
    }
    if ([System.IO.Path]::GetFullPath($source) -ne [System.IO.Path]::GetFullPath($TargetPath)) {
        Copy-Item -LiteralPath $source -Destination $TargetPath -Force
    }
    Unblock-File -LiteralPath $TargetPath -ErrorAction SilentlyContinue

    [pscustomobject]@{
        SDeletePath = $sdelete
        Passes      = $Passes
        InstalledAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

    Write-Success "Handler: $TargetPath"

    Write-Step 'Registering the right-click menu'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wscript    = Join-Path $env:SystemRoot 'System32\wscript.exe'

    if (Test-Path -LiteralPath $wscript) {
        New-LauncherScript -PowerShellPath $powershell -HandlerPath $TargetPath -Destination $LauncherPath
        $command = '"{0}" "{1}" "%1"' -f $wscript, $LauncherPath
    } else {
        # Windows Script Host is disabled or missing. Fall back to launching PowerShell
        # directly; it works, but each selected item flashes a console window.
        Write-Problem 'wscript.exe not found; falling back to a direct launch (windows may flash).'
        $command = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Run -Path "%1"' -f $powershell, $TargetPath
    }

    # SDelete ships with no icon resources of its own, so pointing the menu at the
    # executable would give a blank glyph. Use the shell's red delete mark instead --
    # deliberately not the Recycle Bin. A negative number is a resource ID, which
    # survives Windows updates better than a positional index.
    $defaultIcon = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',-89'
    $iconSpec = if ($PSBoundParameters.ContainsKey('Icon')) { $Icon } else { $defaultIcon }
    $positionValue = if ($Position -eq 'Default') { '' } else { $Position }

    foreach ($subKey in $VerbSubKeys) {
        Set-VerbKey -SubKey $subKey -Label $MenuText -IconSpec $iconSpec -Command $command -MenuPosition $positionValue
        Write-Success "HKCU\$subKey"
    }

    # A previous version registered under lnkfile. Clear it so shortcuts do not end up
    # with a second, differently placed entry after an upgrade.
    try {
        Remove-VerbKey -SubKey 'Software\Classes\lnkfile\shell\SecureDelete'
    } catch {
        # Nothing there, which is the normal case.
    }

    Update-ShellAssociations

    Write-Host ''
    Write-Host '  Installed.' -ForegroundColor Green
    Write-Host ''
    Write-Detail "Right-click any file or folder and choose `"$MenuText`"."
    Write-Detail 'On Windows 11 it lives under "Show more options" (or press Shift+F10).'
    Write-Detail 'A PowerShell window opens with the SDelete command for what you picked,'
    Write-Detail "copied to the clipboard. It never deletes anything. Overwrite passes: $Passes."
    Write-Host ''
    Write-Detail 'Remove it with Uninstall-SecureDelete.ps1, or:'
    Write-Detail "  powershell -ExecutionPolicy Bypass -File `"$TargetPath`" -Uninstall"
    Write-Host ''
}

function Invoke-Uninstall {
    Write-Host ''
    Write-Step 'Removing the right-click menu'
    foreach ($subKey in $AllVerbSubKeys) {
        try {
            Remove-VerbKey -SubKey $subKey
            Write-Success "Removed HKCU\$subKey"
        } catch {
            Write-Problem "Could not remove HKCU\$subKey : $($_.Exception.Message)"
        }
    }
    Update-ShellAssociations

    Write-Step 'Removing the handler'
    if (Test-Path -LiteralPath $InstallDir) {
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Write-Success "Deleted $InstallDir"
        } catch {
            Write-Problem "Could not delete $InstallDir : $($_.Exception.Message)"
        }
    } else {
        Write-Detail 'Nothing to remove.'
    }

    Write-Host ''
    Write-Host '  Uninstalled.' -ForegroundColor Green
    Write-Detail "SDelete itself was left installed. Remove it with:  winget uninstall --id $WingetId"
    Write-Host ''
}

#endregion


#region Runtime

function Show-ConsoleWindow {
    <#
        Only used to surface an unhandled error. The handler normally runs with no window
        at all, so a failure would otherwise be silent.

        ShowWindow is called twice on purpose: the first call is swallowed because the
        process's startup information specifies SW_HIDE, and the second one takes effect.
        Verified on this Windows build, not folklore.
    #>
    try {
        if (-not ('SecureDeleteRuntime.Win' -as [type])) {
            Add-Type -Namespace 'SecureDeleteRuntime' -Name 'Win' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@
        }
        $hwnd = [SecureDeleteRuntime.Win]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }
        [void][SecureDeleteRuntime.Win]::ShowWindow($hwnd, 5)   # SW_SHOW
        [void][SecureDeleteRuntime.Win]::ShowWindow($hwnd, 5)
        [void][SecureDeleteRuntime.Win]::SetForegroundWindow($hwnd)
    } catch {
        # Nothing further to try.
    }
}

function Get-Config {
    if (Test-Path -LiteralPath $ConfigPath) {
        try { return Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch { }
    }
    return $null
}

function Get-RuntimeSettings {
    <#
        Resolves the executable and pass count. If the recorded SDelete path has moved
        (package update, reinstall) it re-resolves and rewrites the config rather than
        failing.
    #>
    $config = Get-Config
    $exe    = $null
    $passes = 1

    if ($config) {
        if ($config.Passes) { $passes = [int]$config.Passes }
        if ($config.SDeletePath -and (Test-Path -LiteralPath $config.SDeletePath -PathType Leaf)) {
            $exe = $config.SDeletePath
        }
    }

    if (-not $exe) {
        Update-SessionPath
        $exe = Resolve-SDelete
        if ($exe -and (Test-Path -LiteralPath $InstallDir)) {
            try {
                [pscustomobject]@{
                    SDeletePath = $exe
                    Passes      = $passes
                    InstalledAt = (Get-Date).ToString('o')
                } | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
            } catch { }
        }
    }

    return [pscustomobject]@{ Exe = $exe; Passes = $passes }
}

function Test-PathIsUnder {
    param([string]$Child, [string]$Parent)
    if (-not $Child -or -not $Parent) { return $false }
    try {
        $c = [System.IO.Path]::GetFullPath($Child).TrimEnd('\')
        $p = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    } catch {
        return $false
    }
    if ($c -eq $p) { return $true }
    return $c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PathNote {
    <#
        Returns a short warning for a path worth a second look, or $null.

        Advisory only -- nothing here blocks anything, because nothing here deletes.
        It exists to make an unexpected path obvious at a glance, which is the entire
        safety model now.
    #>
    param([string]$FullPath)

    $path = ''
    try { $path = [System.IO.Path]::GetFullPath($FullPath).TrimEnd('\') } catch { return $null }

    if ($path -match '^[A-Za-z]:$') { return 'the root of a drive' }

    $guards = @(
        @{ Root = $env:SystemRoot;          Note = 'inside the Windows folder' },
        @{ Root = $env:ProgramFiles;        Note = 'inside Program Files' },
        @{ Root = ${env:ProgramFiles(x86)}; Note = 'inside Program Files (x86)' },
        @{ Root = $env:ProgramData;         Note = 'inside ProgramData' }
    )
    foreach ($guard in $guards) {
        if (Test-PathIsUnder -Child $path -Parent $guard.Root) { return $guard.Note }
    }

    if (Test-PathIsUnder -Child $env:USERPROFILE -Parent $path) {
        return 'your entire user profile'
    }

    return $null
}

function Format-SDeleteCommand {
    param([string]$Exe, [int]$Passes, [string[]]$Paths)
    $quoted = ($Paths | ForEach-Object { '"{0}"' -f $_ }) -join ' '
    return '"{0}" -accepteula -p {1} -s {2}' -f $Exe, $Passes, $quoted
}

function Show-SDeleteCommand {
    <#
        Runs in the visible window. Prints the selection and the command, and puts the
        command on the clipboard. Deliberately the end of the road: this process does
        not run SDelete, and -NoExit leaves the prompt open for you to paste into.
    #>
    param([string[]]$Paths, [pscustomobject]$Settings)

    try { $Host.UI.RawUI.WindowTitle = 'Secure Delete - command only' } catch { }

    Write-Host ''
    Write-Host '  SECURE DELETE' -ForegroundColor White
    Write-Host '  Nothing is deleted by this window. It only builds the command.' -ForegroundColor DarkGray
    Write-Host ''

    $plural = if ($Paths.Count -eq 1) { '' } else { 's' }
    Write-Host "  Selected ($($Paths.Count) item$plural):" -ForegroundColor White
    foreach ($item in $Paths) {
        Write-Host "    $item" -ForegroundColor Yellow -NoNewline
        $note = Get-PathNote -FullPath $item
        if ($note) {
            Write-Host "   <- $note" -ForegroundColor Red
        } else {
            Write-Host ''
        }
    }

    if (-not $Settings.Exe) {
        Write-Host ''
        Write-Host '  SDelete could not be found.' -ForegroundColor Red
        Write-Host "  Reinstall it with:  winget install --id $WingetId" -ForegroundColor Gray
        Write-Host ''
        return
    }

    $command = Format-SDeleteCommand -Exe $Settings.Exe -Passes $Settings.Passes -Paths $Paths

    $copied = $false
    try { Set-Clipboard -Value $command; $copied = $true } catch { }

    Write-Host ''
    Write-Host $(if ($copied) { '  Command (copied to the clipboard):' } else { '  Command:' }) -ForegroundColor White
    Write-Host ''
    Write-Host "    $command" -ForegroundColor Green
    Write-Host ''
    Write-Host '  Check the paths above before you run it.' -ForegroundColor DarkGray
    Write-Host '  A shortcut resolves to its target, so right-clicking one gives you the' -ForegroundColor DarkGray
    Write-Host '  path of whatever it points at, not the shortcut. Run SDelete on the .lnk' -ForegroundColor DarkGray
    Write-Host '  directly to erase the shortcut itself.' -ForegroundColor DarkGray
    Write-Host '  Some paths need an elevated terminal: SDelete overwrites before it' -ForegroundColor DarkGray
    Write-Host '  unlinks, so it needs write access, not just delete.' -ForegroundColor DarkGray
    Write-Host ''
}

function Start-CommandWindow {
    <#
        Opens the visible window. The paths travel in a file rather than on the command
        line: it sidesteps a layer of quoting and has no length limit. -NoExit leaves a
        usable prompt behind once the command has been printed.
    #>
    param([string[]]$Paths, [pscustomobject]$Settings)

    $handler = if (Test-Path -LiteralPath $TargetPath) { $TargetPath } else { $PSCommandPath }
    if (-not $handler) { return $false }

    $dir = if (Test-Path -LiteralPath $InstallDir) { $InstallDir } else { $env:TEMP }

    # Sweep up payloads from runs that were never picked up.
    Get-ChildItem -LiteralPath $dir -Filter 'show-*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { ((Get-Date) - $_.LastWriteTime).TotalHours -gt 1 } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $payloadPath = Join-Path $dir ('show-{0}.json' -f [guid]::NewGuid().ToString('n'))
    [pscustomobject]@{
        SDeletePath = $Settings.Exe
        Passes      = $Settings.Passes
        Paths       = @($Paths)
    } | ConvertTo-Json | Set-Content -LiteralPath $payloadPath -Encoding UTF8

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argumentList = @(
        '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $handler),
        '-Show', '-ShowFile', ('"{0}"' -f $payloadPath)
    )

    try {
        Start-Process -FilePath $powershell -ArgumentList $argumentList | Out-Null
        return $true
    } catch {
        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Invoke-QueuedShow {
    <#
        Explorer launches one process per selected item, which would mean one window per
        item. Instances append to a shared queue; exactly one becomes the owner and opens
        a single window for the whole selection. The others exit silently.

        Lock order is always queue -> owner, and the owner is only ever taken with a zero
        timeout, so the two can never deadlock. The owner releases the owner mutex while
        still holding the queue mutex, which closes the window where a late arrival could
        enqueue an item that nobody picks up.
    #>
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    $queueMutex = New-Object System.Threading.Mutex($false, 'Local\SecureDelete.Queue')
    $ownerMutex = New-Object System.Threading.Mutex($false, 'Local\SecureDelete.Owner')
    $isOwner = $false

    try {
        try { [void]$queueMutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { }
        try {
            # Discard a queue orphaned by a previous crash.
            $queueFile = Get-Item -LiteralPath $QueuePath -ErrorAction SilentlyContinue
            if ($queueFile -and ((Get-Date) - $queueFile.LastWriteTime).TotalSeconds -gt 60) {
                Remove-Item -LiteralPath $QueuePath -Force -ErrorAction SilentlyContinue
            }
            Add-Content -LiteralPath $QueuePath -Value $Path -Encoding UTF8

            try { $isOwner = $ownerMutex.WaitOne(0) }
            catch [System.Threading.AbandonedMutexException] { $isOwner = $true }
        } finally {
            $queueMutex.ReleaseMutex()
        }

        if (-not $isOwner) { return }

        # Give sibling processes from the same multi-selection time to enqueue.
        Start-Sleep -Milliseconds 700

        while ($true) {
            $batch = @()
            try { [void]$queueMutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { }
            try {
                if (Test-Path -LiteralPath $QueuePath) {
                    $batch = @(Get-Content -LiteralPath $QueuePath -Encoding UTF8 |
                               Where-Object { $_ -and $_.Trim() } |
                               Select-Object -Unique)
                    Remove-Item -LiteralPath $QueuePath -Force -ErrorAction SilentlyContinue
                }
                if ($batch.Count -eq 0) {
                    $ownerMutex.ReleaseMutex()
                    $isOwner = $false
                }
            } finally {
                $queueMutex.ReleaseMutex()
            }

            if ($batch.Count -eq 0) { break }
            [void](Start-CommandWindow -Paths $batch -Settings (Get-RuntimeSettings))
        }
    } finally {
        if ($isOwner) { try { $ownerMutex.ReleaseMutex() } catch { } }
        $queueMutex.Dispose()
        $ownerMutex.Dispose()
    }
}

#endregion


switch ($PSCmdlet.ParameterSetName) {
    'Run' {
        try {
            Invoke-QueuedShow -Path $Path
        } catch {
            Show-ConsoleWindow
            Write-Host ''
            Write-Host "  Secure Delete failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ''
            try { [void](Read-Host '  Press Enter to close') } catch { Start-Sleep -Seconds 15 }
            exit 1
        }
    }
    'Show' {
        try {
            $payload = Get-Content -LiteralPath $ShowFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Remove-Item -LiteralPath $ShowFile -Force -ErrorAction SilentlyContinue

            $passes = if ($payload.Passes) { [int]$payload.Passes } else { 1 }
            $exe    = $payload.SDeletePath
            if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) {
                $exe = (Get-RuntimeSettings).Exe
            }

            Show-SDeleteCommand -Paths @($payload.Paths) -Settings ([pscustomobject]@{ Exe = $exe; Passes = $passes })
        } catch {
            Write-Host ''
            Write-Host "  Secure Delete failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ''
        }
    }
    'Uninstall' {
        Invoke-Uninstall
    }
    default {
        try {
            Invoke-Install
        } catch {
            Write-Host ''
            Write-Host "  Install failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ''
            exit 1
        }
    }
}

<#
.SYNOPSIS
    WinSlim - a transparent, reversible Windows 11 debloater with a simple GUI.

.DESCRIPTION
    Pick what you want to remove or turn off, then click Apply.
    - Creates a System Restore point first (optional)
    - Dry-run mode shows what would happen without changing anything
    - Registry/service tweaks can be undone with the Undo button
    - Everything is logged to .\logs\

.PARAMETER NoGui
    Skip the GUI and apply all "recommended" items.

.PARAMETER DryRun
    Only log what would be done (applies to -NoGui; the GUI has a checkbox).

.EXAMPLE
    .\WinSlim.ps1
    .\WinSlim.ps1 -NoGui -DryRun
#>
[CmdletBinding()]
param(
    [switch]$NoGui,
    [switch]$DryRun
)

$script:Version = '1.0.0'

# ---------------------------------------------------------------- elevation
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($NoGui)  { $argList += ' -NoGui' }
    if ($DryRun) { $argList += ' -DryRun' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- logging
$script:LogDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
$script:LogFile = Join-Path $script:LogDir ("winslim-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:LogBox  = $null
$script:IsDry   = [bool]$DryRun

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        Write-Host $line
    }
}

# ---------------------------------------------------------------- low-level helpers
function Set-RegValue {
    param($Path, $Name, $Value, $Type = 'DWord')
    if ($script:IsDry) { Write-Log "[dry-run] set $Path\$Name = '$Value'"; return }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        if ($Name -eq '(default)') {
            Set-ItemProperty -LiteralPath $Path -Name '(default)' -Value $Value
        } else {
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        }
    } catch {
        Write-Log "Could not set $Path\$Name : $($_.Exception.Message)" 'WARN'
    }
}

function Remove-RegValue {
    param($Path, $Name)
    if ($script:IsDry) { Write-Log "[dry-run] remove $Path\$Name"; return }
    Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
}

function Remove-RegKey {
    param($Path)
    if ($script:IsDry) { Write-Log "[dry-run] remove key $Path"; return }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function New-RegEntry {
    # P=path, N=name, V=value to apply, D=value to restore on undo ($null = delete the value)
    param($P, $N, $V, $D = $null, $T = 'DWord', [bool]$RemoveKey = $false)
    @{ P = $P; N = $N; V = $V; D = $D; T = $T; RemoveKey = $RemoveKey }
}

function Remove-AppByName {
    param([string]$Pattern)
    if ($script:IsDry) { Write-Log "[dry-run] remove app package '$Pattern'"; return }
    try {
        Get-AppxPackage -AllUsers -Name $Pattern -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction SilentlyContinue }
        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like $Pattern } |
            ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue | Out-Null }
    } catch {
        Write-Log "Could not remove $Pattern : $($_.Exception.Message)" 'WARN'
    }
}

function Restart-Explorer {
    if ($script:IsDry) { Write-Log '[dry-run] restart Explorer'; return }
    Write-Log 'Restarting Explorer...'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
}

function New-RestorePoint {
    if ($script:IsDry) { Write-Log '[dry-run] create restore point'; return }
    try {
        Write-Log 'Creating System Restore point...'
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "WinSlim $($script:Version)" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Restore point created.'
    } catch {
        Write-Log "Restore point skipped: $($_.Exception.Message)" 'WARN'
    }
}

# ---------------------------------------------------------------- tweak catalogue
$script:Tweaks = New-Object System.Collections.Generic.List[object]

function Add-Tweak {
    param($Category, $Name, $Desc, [bool]$Rec, $Kind, $Data, [bool]$Explorer = $false)
    $script:Tweaks.Add([pscustomobject]@{
        Category = $Category; Name = $Name; Desc = $Desc; Recommended = $Rec
        Kind = $Kind; Data = $Data; Explorer = $Explorer
        Reversible = ($Kind -ne 'Apps')
    })
}

# ---- Apps (not reversible automatically; reinstall from the Microsoft Store)
$apps = @(
    @('Microsoft.BingNews',                 'News',                       $true),
    @('Microsoft.BingWeather',              'Weather',                    $true),
    @('Microsoft.BingSearch',               'Bing search app',            $true),
    @('Microsoft.GetHelp',                  'Get Help',                   $true),
    @('Microsoft.Getstarted',               'Tips',                       $true),
    @('Microsoft.MicrosoftOfficeHub',       'Microsoft 365 (Office) hub', $true),
    @('Microsoft.MicrosoftSolitaireCollection', 'Solitaire Collection',   $true),
    @('Microsoft.People',                   'People',                     $true),
    @('Microsoft.PowerAutomateDesktop',     'Power Automate',             $true),
    @('Microsoft.WindowsFeedbackHub',       'Feedback Hub',               $true),
    @('Microsoft.YourPhone',                'Phone Link',                 $true),
    @('Microsoft.windowscommunicationsapps','Mail and Calendar (legacy)', $true),
    @('Microsoft.SkypeApp',                 'Skype',                      $true),
    @('Microsoft.MixedReality.Portal',      'Mixed Reality Portal',       $true),
    @('Microsoft.Microsoft3DViewer',        '3D Viewer',                  $true),
    @('Clipchamp.Clipchamp',                'Clipchamp video editor',     $true),
    @('MicrosoftTeams',                     'Teams (personal, old)',      $true),
    @('MSTeams',                            'Teams (personal)',           $true),
    @('Microsoft.549981C3F5F10',            'Cortana',                    $true),
    @('king.com.*',                         'Candy Crush and other King games', $true),
    @('*TikTok*',                           'TikTok',                     $true),
    @('*Instagram*',                        'Instagram',                  $true),
    @('*Facebook*',                         'Facebook',                   $true),
    @('*Disney*',                           'Disney+',                    $true),
    @('*SpotifyAB*',                        'Spotify (preinstalled)',     $true),
    @('Microsoft.ZuneMusic',                'Media Player / Groove (legacy)', $false),
    @('Microsoft.ZuneVideo',                'Movies and TV',              $false),
    @('Microsoft.Todos',                    'Microsoft To Do',            $false),
    @('Microsoft.WindowsMaps',              'Maps',                       $false),
    @('Microsoft.OutlookForWindows',        'New Outlook',                $false),
    @('Microsoft.Copilot',                  'Copilot app',                $false),
    @('Microsoft.XboxGamingOverlay',        'Xbox Game Bar',              $false),
    @('Microsoft.GamingApp',                'Xbox app',                   $false)
)
foreach ($a in $apps) {
    Add-Tweak 'Apps' $a[1] "Removes package: $($a[0])" $a[2] 'Apps' @($a[0])
}

# ---- Privacy and telemetry
$HKLM = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$CDM  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

Add-Tweak 'Privacy' 'Minimise telemetry' 'Sets the diagnostic data policy to the lowest level and hides feedback prompts.' $true 'Reg' @(
    (New-RegEntry "$HKLM\DataCollection" 'AllowTelemetry' 0),
    (New-RegEntry "$HKLM\DataCollection" 'DoNotShowFeedbackNotifications' 1)
)
Add-Tweak 'Privacy' 'Disable telemetry services' 'Stops and disables DiagTrack and dmwappushservice.' $true 'Service' @(
    @{ N = 'DiagTrack';        D = 'Automatic' },
    @{ N = 'dmwappushservice'; D = 'Manual' }
)
Add-Tweak 'Privacy' 'Disable advertising ID' 'Stops apps using a per-user ad identifier.' $true 'Reg' @(
    (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 1)
)
Add-Tweak 'Privacy' 'Disable tailored experiences' 'No personalised tips based on diagnostic data.' $true 'Reg' @(
    (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 1)
)
Add-Tweak 'Privacy' 'Disable activity history' 'Stops the Timeline-style activity feed from being collected or uploaded.' $true 'Reg' @(
    (New-RegEntry "$HKLM\System" 'EnableActivityFeed' 0),
    (New-RegEntry "$HKLM\System" 'PublishUserActivities' 0),
    (New-RegEntry "$HKLM\System" 'UploadUserActivities' 0)
)
Add-Tweak 'Privacy' 'Disable Windows Recall / AI data analysis' 'Policy that blocks snapshot-based AI data analysis.' $true 'Reg' @(
    (New-RegEntry "$HKLM\WindowsAI" 'DisableAIDataAnalysis' 1)
)
Add-Tweak 'Privacy' 'Disable Delivery Optimization peer sharing' 'Updates download from Microsoft only, not shared with other PCs.' $false 'Reg' @(
    (New-RegEntry 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0)
)

# ---- Ads, suggestions and AI
Add-Tweak 'Ads and suggestions' 'Stop silent app installs and promos' 'Turns off ContentDeliveryManager suggestions, tips and auto-installed sponsored apps.' $true 'Reg' @(
    (New-RegEntry $CDM 'SilentInstalledAppsEnabled' 0 1),
    (New-RegEntry $CDM 'SystemPaneSuggestionsEnabled' 0 1),
    (New-RegEntry $CDM 'SoftLandingEnabled' 0 1),
    (New-RegEntry $CDM 'SubscribedContent-310093Enabled' 0 1),
    (New-RegEntry $CDM 'SubscribedContent-338387Enabled' 0 1),
    (New-RegEntry $CDM 'SubscribedContent-338388Enabled' 0 1),
    (New-RegEntry $CDM 'SubscribedContent-338389Enabled' 0 1),
    (New-RegEntry $CDM 'SubscribedContent-338393Enabled' 0 1),
    (New-RegEntry $CDM 'SubscribedContent-353694Enabled' 0 1),
    (New-RegEntry $CDM 'SubscribedContent-353696Enabled' 0 1)
)
Add-Tweak 'Ads and suggestions' 'Disable consumer features' 'Blocks automatic installation of "suggested" Store apps.' $true 'Reg' @(
    (New-RegEntry "$HKLM\CloudContent" 'DisableWindowsConsumerFeatures' 1)
)
Add-Tweak 'Ads and suggestions' 'Disable web results in Start search' 'Start search shows only local results (no Bing).' $true 'Reg' @(
    (New-RegEntry 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1)
) $true
Add-Tweak 'Ads and suggestions' 'Disable Copilot (policy)' 'Turns off the Windows Copilot integration via policy.' $true 'Reg' @(
    (New-RegEntry 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1)
) $true
Add-Tweak 'Ads and suggestions' 'Hide Start menu recommendations' 'Hides recently opened files and recommended items in Start.' $true 'Reg' @(
    (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0 1),
    (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackDocs' 0 1)
) $true

# ---- Taskbar and Explorer
$ADV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Add-Tweak 'Taskbar and Explorer' 'Disable Widgets' 'Removes the Widgets / News feed button and background process.' $true 'Reg' @(
    (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0)
) $true
Add-Tweak 'Taskbar and Explorer' 'Hide Chat / Teams icon' 'Removes the Chat button from the taskbar.' $true 'Reg' @(
    (New-RegEntry $ADV 'TaskbarMn' 0 1)
) $true
Add-Tweak 'Taskbar and Explorer' 'Hide Task View button' 'Removes the virtual-desktop button from the taskbar.' $false 'Reg' @(
    (New-RegEntry $ADV 'ShowTaskViewButton' 0 1)
) $true
Add-Tweak 'Taskbar and Explorer' 'Classic right-click menu' 'Restores the full Windows 10 style context menu (no "Show more options").' $true 'Reg' @(
    (New-RegEntry 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' $null 'String' $true)
) $true
Add-Tweak 'Taskbar and Explorer' 'Show file extensions' 'Always show .txt, .exe and so on.' $true 'Reg' @(
    (New-RegEntry $ADV 'HideFileExt' 0 1)
) $true
Add-Tweak 'Taskbar and Explorer' 'Open Explorer to This PC' 'Instead of Home / Quick access.' $false 'Reg' @(
    (New-RegEntry $ADV 'LaunchTo' 1 $null)
) $true
Add-Tweak 'Taskbar and Explorer' 'Align taskbar to the left' 'Windows 10 style taskbar layout.' $false 'Reg' @(
    (New-RegEntry $ADV 'TaskbarAl' 0 1)
) $true

# ---------------------------------------------------------------- engine
function Invoke-Tweak {
    param($Item, [bool]$Undo)

    switch ($Item.Kind) {
        'Reg' {
            foreach ($e in $Item.Data) {
                if (-not $Undo) {
                    Set-RegValue $e.P $e.N $e.V $e.T
                } elseif ($e.RemoveKey) {
                    Remove-RegKey $e.P
                } elseif ($null -eq $e.D) {
                    Remove-RegValue $e.P $e.N
                } else {
                    Set-RegValue $e.P $e.N $e.D $e.T
                }
            }
        }
        'Service' {
            foreach ($s in $Item.Data) {
                if ($script:IsDry) { Write-Log "[dry-run] service $($s.N): $(if ($Undo) {'restore'} else {'stop + disable'})"; continue }
                try {
                    if ($Undo) {
                        Set-Service -Name $s.N -StartupType $s.D -ErrorAction Stop
                        Start-Service -Name $s.N -ErrorAction SilentlyContinue
                    } else {
                        Stop-Service -Name $s.N -Force -ErrorAction SilentlyContinue
                        Set-Service -Name $s.N -StartupType Disabled -ErrorAction Stop
                    }
                } catch {
                    Write-Log "Service $($s.N): $($_.Exception.Message)" 'WARN'
                }
            }
        }
        'Apps' {
            if ($Undo) {
                Write-Log "Apps can't be restored automatically. Reinstall '$($Item.Name)' from the Microsoft Store." 'WARN'
                return
            }
            foreach ($p in $Item.Data) { Remove-AppByName $p }
        }
    }
}

function Invoke-Selection {
    param($Items, [bool]$Undo, [bool]$MakeRestorePoint)

    if ($script:IsDry) { Write-Log '--- DRY RUN: nothing will be changed ---' }
    if ($MakeRestorePoint -and -not $Undo) { New-RestorePoint }

    $needExplorer = $false
    foreach ($item in $Items) {
        Write-Log "$(if ($Undo) {'Undo'} else {'Apply'}): [$($item.Category)] $($item.Name)"
        Invoke-Tweak -Item $item -Undo $Undo
        if ($item.Explorer) { $needExplorer = $true }
    }
    if ($needExplorer) { Restart-Explorer }
    Write-Log "Finished. Log saved to $script:LogFile"
}

# ---------------------------------------------------------------- command-line mode
if ($NoGui) {
    Write-Log "WinSlim $script:Version (no GUI) - applying recommended items"
    $items = $script:Tweaks | Where-Object { $_.Recommended }
    Invoke-Selection -Items $items -Undo $false -MakeRestorePoint $true
    exit
}

# ---------------------------------------------------------------- GUI
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "WinSlim $script:Version - Windows 11 debloater"
$form.Size = New-Object System.Drawing.Size(980, 720)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$script:lv = New-Object System.Windows.Forms.ListView
$script:lv.Dock = 'Fill'
$script:lv.View = 'Details'
$script:lv.CheckBoxes = $true
$script:lv.FullRowSelect = $true
$script:lv.ShowGroups = $true
$script:lv.HideSelection = $false
[void]$script:lv.Columns.Add('Item', 280)
[void]$script:lv.Columns.Add('What it does', 520)
[void]$script:lv.Columns.Add('Undo?', 70)

$groups = @{}
foreach ($t in $script:Tweaks) {
    if (-not $groups.ContainsKey($t.Category)) {
        $g = New-Object System.Windows.Forms.ListViewGroup($t.Category, $t.Category)
        [void]$script:lv.Groups.Add($g)
        $groups[$t.Category] = $g
    }
    $li = New-Object System.Windows.Forms.ListViewItem($t.Name)
    [void]$li.SubItems.Add($t.Desc)
    [void]$li.SubItems.Add($(if ($t.Reversible) { 'Yes' } else { 'No' }))
    $li.Group = $groups[$t.Category]
    $li.Tag = $t
    $li.Checked = $t.Recommended
    [void]$script:lv.Items.Add($li)
}

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Dock = 'Bottom'
$script:LogBox.Height = 150
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)

$bar = New-Object System.Windows.Forms.FlowLayoutPanel
$bar.Dock = 'Top'
$bar.Height = 44
$bar.Padding = New-Object System.Windows.Forms.Padding(8, 8, 8, 0)

function New-Button($text, $width = 120) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Width = $width
    $b.Height = 28
    $b
}

$btnRec   = New-Button 'Recommended'
$btnAll   = New-Button 'Select all'
$btnNone  = New-Button 'Clear'
$script:chkRestore = New-Object System.Windows.Forms.CheckBox
$script:chkRestore.Text = 'Restore point'
$script:chkRestore.Checked = $true
$script:chkRestore.AutoSize = $true
$script:chkRestore.Margin = New-Object System.Windows.Forms.Padding(12, 6, 0, 0)
$script:chkDry = New-Object System.Windows.Forms.CheckBox
$script:chkDry.Text = 'Dry run'
$script:chkDry.Checked = $script:IsDry
$script:chkDry.AutoSize = $true
$script:chkDry.Margin = New-Object System.Windows.Forms.Padding(8, 6, 0, 0)
$script:btnApply = New-Button 'Apply' 100
$script:btnUndo  = New-Button 'Undo selected' 110
$script:btnApply.Margin = New-Object System.Windows.Forms.Padding(24, 3, 3, 3)

$bar.Controls.AddRange(@($btnRec, $btnAll, $btnNone, $script:chkRestore, $script:chkDry, $script:btnApply, $script:btnUndo))

# Fill control first so Top/Bottom panels dock around it
$form.Controls.Add($script:lv)
$form.Controls.Add($script:LogBox)
$form.Controls.Add($bar)

function Start-Run {
    param([bool]$Undo)

    $selected = @($script:lv.CheckedItems | ForEach-Object { $_.Tag })
    if ($Undo) { $selected = @($selected | Where-Object { $_.Reversible }) }
    if ($selected.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Nothing selected.', 'WinSlim')
        return
    }

    $verb = if ($Undo) { 'undo' } else { 'apply' }
    $msg = "About to $verb $($selected.Count) item(s)."
    if (-not $Undo -and ($selected | Where-Object { $_.Kind -eq 'Apps' })) {
        $msg += "`r`n`r`nRemoved apps are not restored by Undo; reinstall them from the Microsoft Store."
    }
    $msg += "`r`n`r`nContinue?"
    $answer = [System.Windows.Forms.MessageBox]::Show($msg, 'WinSlim', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    $script:IsDry = $script:chkDry.Checked
    $form.Enabled = $false
    $form.Cursor = 'WaitCursor'
    try {
        Invoke-Selection -Items $selected -Undo $Undo -MakeRestorePoint $script:chkRestore.Checked
    } finally {
        $form.Enabled = $true
        $form.Cursor = 'Default'
    }
    [void][System.Windows.Forms.MessageBox]::Show("Done. A restart is recommended.`r`nLog: $script:LogFile", 'WinSlim')
}

$btnRec.Add_Click({  foreach ($i in $script:lv.Items) { $i.Checked = [bool]$i.Tag.Recommended } })
$btnAll.Add_Click({  foreach ($i in $script:lv.Items) { $i.Checked = $true } })
$btnNone.Add_Click({ foreach ($i in $script:lv.Items) { $i.Checked = $false } })
$script:btnApply.Add_Click({ Start-Run $false })
$script:btnUndo.Add_Click({  Start-Run $true })

Write-Log "WinSlim $script:Version started. Review the list, then click Apply."
if ([Environment]::OSVersion.Version.Build -lt 22000) {
    Write-Log 'This does not look like Windows 11 (build < 22000). Some items may not apply.' 'WARN'
}

[void]$form.ShowDialog()

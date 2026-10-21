<#
.SYNOPSIS
    WinSlim - a transparent, reversible Windows 11 debloater with a modern animated GUI.

.DESCRIPTION
    - Start from a profile (Light touch, Recommended, Privacy first, Maximum) or pick items yourself
    - Every option has a plain-English explanation, a risk badge, "skip it if" advice and the exact technical change
    - Smooth page transitions and animated toggles (WPF)
    - Creates a System Restore point first (optional)
    - Dry-run mode previews everything without changing anything
    - Registry and service tweaks can be undone; everything is logged to .\logs\

.NOTES
    Flags (read from $args):
      -NoGui   Skip the GUI and apply all "recommended" items.
      -DryRun  Only log what would be done (the GUI has its own toggle).

.EXAMPLE
    irm https://raw.githubusercontent.com/YOUR-USERNAME/WinSlim/main/WinSlim.ps1 | iex

.EXAMPLE
    .\WinSlim.ps1
    .\WinSlim.ps1 -NoGui -DryRun
#>
# NOTE: no param() block on purpose, so the script also works when piped into Invoke-Expression.
# Flags are read from $args:  -NoGui  -DryRun

$script:Version = '2.1.0'
# Raw URL of this file on GitHub (used when the script is launched with:  irm <url> | iex )
$script:RawUrl  = 'https://raw.githubusercontent.com/YOUR-USERNAME/WinSlim/main/WinSlim.ps1'

$NoGui  = [bool]($args -contains '-NoGui')
$DryRun = [bool]($args -contains '-DryRun')

# ---------------------------------------------------------------- elevation / Windows PowerShell check
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isDesktop = ($PSVersionTable.PSEdition -ne 'Core')   # WinSlim needs Windows PowerShell 5.1 (Appx cmdlets, WPF)

if (-not $isAdmin -or -not $isDesktop) {
    $flags = ''
    if ($NoGui)  { $flags += ' -NoGui' }
    if ($DryRun) { $flags += ' -DryRun' }

    if ($PSCommandPath) {
        # Started from a file on disk
        $argList = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"$flags"
    } else {
        # Started with:  irm <url> | iex   -> fetch it again inside the elevated window
        $cmd = "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((irm '$($script:RawUrl)')))$flags"
        $argList = "-NoProfile -ExecutionPolicy Bypass -STA -Command `"$cmd`""
    }

    Write-Host 'Starting WinSlim - accept the administrator (UAC) prompt...' -ForegroundColor Cyan
    try {
        if ($NoGui) {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        } else {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $argList -ErrorAction Stop
        }
    } catch {
        Write-Host 'WinSlim needs administrator rights and the prompt was cancelled.' -ForegroundColor Yellow
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------- view-model class (notifies the UI when a toggle changes)
if (-not ('TweakVM' -as [type])) {
    Add-Type -ReferencedAssemblies System -TypeDefinition @'
using System.ComponentModel;
public class TweakVM : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler PropertyChanged;
    private bool _selected;
    public bool Selected
    {
        get { return _selected; }
        set
        {
            if (_selected != value)
            {
                _selected = value;
                if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs("Selected"));
            }
        }
    }
    public string Category   { get; set; }
    public string Name       { get; set; }
    public string Desc       { get; set; }
    public string Why        { get; set; }
    public string SkipIf     { get; set; }
    public string Tech       { get; set; }
    public string Risk       { get; set; }
    public string RiskText   { get; set; }
    public string RiskColor  { get; set; }
    public string RecText    { get; set; }
    public string UndoText   { get; set; }
    public bool   Recommended { get; set; }
    public bool   Reversible  { get; set; }
    public bool   Explorer    { get; set; }
    public string Kind       { get; set; }
    public object Data       { get; set; }
}
'@
}

# ---------------------------------------------------------------- logging
$script:BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'WinSlim' }
$script:LogDir  = Join-Path $script:BaseDir 'logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogFile = Join-Path $script:LogDir ("winslim-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:IsDry   = [bool]$DryRun
$script:ui      = @{}

function Update-UI {
    # Lets WPF repaint while a long task runs on the UI thread.
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $script:uiFrame = $frame
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [Action]{ $script:uiFrame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line
    if ($script:ui.ContainsKey('LogBox')) {
        $script:ui.LogBox.AppendText($line + "`r`n")
        $script:ui.LogBox.ScrollToEnd()
        Update-UI
    } else {
        Write-Host $line
    }
}

function Set-Progress {
    param([double]$Percent, [string]$Text)
    if (-not $script:ui.ContainsKey('Progress')) { return }
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.To = $Percent
    $anim.Duration = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(250))
    $script:ui.Progress.BeginAnimation([System.Windows.Controls.Primitives.RangeBase]::ValueProperty, $anim)
    if ($Text) { $script:ui.Status.Text = $Text }
    Update-UI
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
$script:Categories = @('Apps', 'Privacy', 'Ads and suggestions', 'Taskbar and Explorer')

function Get-TechText {
    param($Kind, $Data)
    switch ($Kind) {
        'Reg' {
            $lines = foreach ($e in $Data) {
                $undo = if ($e.RemoveKey) { 'remove key' } elseif ($null -eq $e.D) { 'delete value' } else { "restore to $($e.D)" }
                $path = ($e.P -replace '^HKLM:\\', 'HKLM\') -replace '^HKCU:\\', 'HKCU\'
                "{0}\{1} = '{2}'   (undo: {3})" -f $path, $e.N, $e.V, $undo
            }
            return ($lines -join "`n")
        }
        'Service' {
            $lines = foreach ($s in $Data) { "Service $($s.N): stop and set to Disabled   (undo: $($s.D))" }
            return ($lines -join "`n")
        }
        'Apps' {
            return "Remove-AppxPackage -AllUsers`nRemove-AppxProvisionedPackage -Online`nPackage: $($Data[0])`n(undo: reinstall from the Microsoft Store)"
        }
    }
}

function Add-Tweak {
    param($Category, $Name, $Desc, $Why, $SkipIf, [bool]$Rec, $Risk, $Kind, $Data, [bool]$Explorer = $false)
    $vm = New-Object TweakVM
    $vm.Category    = $Category
    $vm.Name        = $Name
    $vm.Desc        = $Desc
    $vm.Why         = $Why
    $vm.SkipIf      = $SkipIf
    $vm.Recommended = $Rec
    $vm.Risk        = $Risk
    $vm.RiskText    = "Risk: $Risk"
    $vm.RiskColor   = if ($Risk -eq 'Low') { '#2E9E6B' } else { '#C98A1B' }
    $vm.RecText     = if ($Rec) { 'Recommended' } else { '' }
    $vm.Kind        = $Kind
    $vm.Data        = $Data
    $vm.Explorer    = $Explorer
    $vm.Reversible  = ($Kind -ne 'Apps')
    $vm.UndoText    = if ($vm.Reversible) { 'Can be undone' } else { 'Reinstall via Store' }
    $vm.Tech        = Get-TechText $Kind $Data
    $script:Tweaks.Add($vm)
}

# ---- Apps: package, friendly name, recommended, risk, "skip it if ..."
$apps = @(
    @('Microsoft.BingNews',                     'News',                          $true,  'Low',    'you read news in the Microsoft Start app.'),
    @('Microsoft.BingWeather',                  'Weather',                       $true,  'Low',    'you use the Weather app.'),
    @('Microsoft.BingSearch',                   'Bing search app',               $true,  'Low',    'you rely on Bing suggestions in Start.'),
    @('Microsoft.GetHelp',                      'Get Help',                      $true,  'Low',    'you use Microsoft support chat from inside Windows.'),
    @('Microsoft.Getstarted',                   'Tips',                          $true,  'Low',    'you like the built-in Windows tips.'),
    @('Microsoft.MicrosoftOfficeHub',           'Microsoft 365 (Office) hub',    $true,  'Low',    'you open Office documents from this hub. Installed Office apps are not affected.'),
    @('Microsoft.MicrosoftSolitaireCollection', 'Solitaire Collection',          $true,  'Low',    'you play Solitaire.'),
    @('Microsoft.People',                       'People',                        $true,  'Low',    'you use the People contacts app.'),
    @('Microsoft.PowerAutomateDesktop',         'Power Automate',                $true,  'Low',    'you build Power Automate desktop flows.'),
    @('Microsoft.WindowsFeedbackHub',           'Feedback Hub',                  $true,  'Low',    'you report bugs to Microsoft.'),
    @('Microsoft.YourPhone',                    'Phone Link',                    $true,  'Medium', 'you link an Android phone or iPhone to this PC (calls, texts, photos).'),
    @('Microsoft.windowscommunicationsapps',    'Mail and Calendar (legacy)',    $true,  'Medium', 'you still read email or use the calendar in these built-in apps.'),
    @('Microsoft.SkypeApp',                     'Skype',                         $true,  'Low',    'you use the preinstalled Skype.'),
    @('Microsoft.MixedReality.Portal',          'Mixed Reality Portal',          $true,  'Low',    'you own a Windows Mixed Reality headset.'),
    @('Microsoft.Microsoft3DViewer',            '3D Viewer',                     $true,  'Low',    'you open 3D model files with it.'),
    @('Clipchamp.Clipchamp',                    'Clipchamp video editor',        $true,  'Medium', 'you edit videos with Clipchamp.'),
    @('MicrosoftTeams',                         'Teams (personal, old)',         $true,  'Low',    'you use personal Teams chat. Work or school Teams is separate.'),
    @('MSTeams',                                'Teams (personal)',              $true,  'Low',    'you use personal Teams chat. Work or school Teams is separate.'),
    @('Microsoft.549981C3F5F10',                'Cortana',                       $true,  'Low',    'you use Cortana (retired by Microsoft).'),
    @('king.com.*',                             'Candy Crush and King games',    $true,  'Low',    'you play these games.'),
    @('*TikTok*',                               'TikTok',                        $true,  'Low',    'you use the TikTok app.'),
    @('*Instagram*',                            'Instagram',                     $true,  'Low',    'you use the Instagram app.'),
    @('*Facebook*',                             'Facebook',                      $true,  'Low',    'you use the Facebook app.'),
    @('*Disney*',                               'Disney+',                       $true,  'Low',    'you watch Disney+ through this app.'),
    @('*SpotifyAB*',                            'Spotify (preinstalled)',        $true,  'Low',    'you listen to Spotify through this app.'),
    @('Microsoft.ZuneMusic',                    'Media Player (music)',          $false, 'Medium', 'you play local music or video with Media Player.'),
    @('Microsoft.ZuneVideo',                    'Movies and TV',                 $false, 'Medium', 'you watch purchased movies in this app.'),
    @('Microsoft.Todos',                        'Microsoft To Do',               $false, 'Medium', 'you keep tasks in To Do.'),
    @('Microsoft.WindowsMaps',                  'Maps',                          $false, 'Medium', 'you use offline maps.'),
    @('Microsoft.OutlookForWindows',            'New Outlook',                   $false, 'Medium', 'you use the new Outlook as your mail client.'),
    @('Microsoft.Copilot',                      'Copilot app',                   $false, 'Medium', 'you use Copilot chat.'),
    @('Microsoft.XboxGamingOverlay',            'Xbox Game Bar',                 $false, 'Medium', 'you play PC games and use Game Bar for clips, FPS or voice chat.'),
    @('Microsoft.GamingApp',                    'Xbox app',                      $false, 'Medium', 'you use Xbox / Game Pass on PC.')
)
foreach ($a in $apps) {
    Add-Tweak 'Apps' $a[1] "Removes the preinstalled $($a[1]) app." `
        'Frees disk space and stops a preinstalled or promoted app from running in the background or showing up in Start.' `
        $a[4] $a[2] $a[3] 'Apps' @($a[0])
}

# ---- Privacy
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$CDM = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$ADV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

Add-Tweak 'Privacy' 'Minimise telemetry' `
    'Sets the diagnostic data policy to the lowest level and hides feedback prompts.' `
    'Less diagnostic data is sent to Microsoft and you get fewer "How are we doing?" pop-ups.' `
    'you are enrolled in a Windows Insider or managed programme that needs full diagnostics.' `
    $true 'Low' 'Reg' @(
        (New-RegEntry "$POL\DataCollection" 'AllowTelemetry' 0),
        (New-RegEntry "$POL\DataCollection" 'DoNotShowFeedbackNotifications' 1)
    )
Add-Tweak 'Privacy' 'Disable telemetry services' `
    'Stops and disables the DiagTrack and dmwappushservice background services.' `
    'Removes the background services that collect and upload diagnostic data.' `
    'you need Microsoft to receive error reports (some corporate setups do).' `
    $true 'Medium' 'Service' @(
        @{ N = 'DiagTrack';        D = 'Automatic' },
        @{ N = 'dmwappushservice'; D = 'Manual' }
    )
Add-Tweak 'Privacy' 'Disable advertising ID' `
    'Stops apps using a per-user advertising identifier.' `
    'Apps can no longer track you across apps for personalised ads.' `
    'you want personalised ads in Store apps.' `
    $true 'Low' 'Reg' @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0 1) )
Add-Tweak 'Privacy' 'Disable tailored experiences' `
    'Stops personalised tips and ads based on your diagnostic data.' `
    'Windows stops using your usage data to suggest products and services.' `
    'you like personalised suggestions.' `
    $true 'Low' 'Reg' @( (New-RegEntry 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0 1) )
Add-Tweak 'Privacy' 'Disable activity history' `
    'Stops the activity feed from being collected or uploaded.' `
    'Your app and document activity is no longer logged and synced to your Microsoft account.' `
    'you use the cross-device activity feed.' `
    $true 'Low' 'Reg' @(
        (New-RegEntry "$POL\System" 'EnableActivityFeed' 0),
        (New-RegEntry "$POL\System" 'PublishUserActivities' 0),
        (New-RegEntry "$POL\System" 'UploadUserActivities' 0)
    )
Add-Tweak 'Privacy' 'Disable Recall / AI data analysis' `
    'Policy that blocks snapshot-based AI data analysis (Recall).' `
    'Prevents Windows from taking and analysing periodic screen snapshots on supported PCs.' `
    'you want to use Recall on a Copilot+ PC.' `
    $true 'Low' 'Reg' @( (New-RegEntry "$POL\WindowsAI" 'DisableAIDataAnalysis' 1) )
Add-Tweak 'Privacy' 'Disable update sharing with other PCs' `
    'Delivery Optimization downloads updates from Microsoft only.' `
    'Your PC will not upload update pieces to strangers on the internet or your LAN.' `
    'you have several PCs on a slow connection and want them to share updates.' `
    $false 'Low' 'Reg' @( (New-RegEntry 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0) )

# ---- Ads and suggestions
Add-Tweak 'Ads and suggestions' 'Stop silent app installs and promos' `
    'Turns off suggested content, tips and auto-installed sponsored apps.' `
    'Stops "suggested" apps reappearing in Start and promos in Settings and the lock screen.' `
    'you like discovering new apps through Windows suggestions.' `
    $true 'Low' 'Reg' @(
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
Add-Tweak 'Ads and suggestions' 'Disable consumer features' `
    'Blocks automatic installation of "suggested" Store apps.' `
    'New user accounts and feature updates will not drag in Candy Crush-style apps.' `
    'you want Microsoft to preinstall suggested apps.' `
    $true 'Low' 'Reg' @( (New-RegEntry "$POL\CloudContent" 'DisableWindowsConsumerFeatures' 1) )
Add-Tweak 'Ads and suggestions' 'Disable web results in Start search' `
    'Start search shows only local apps, files and settings (no Bing).' `
    'Faster, more private search that does not send what you type to Bing.' `
    'you search the web from the Start menu.' `
    $true 'Low' 'Reg' @( (New-RegEntry 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1) ) $true
Add-Tweak 'Ads and suggestions' 'Disable Copilot (policy)' `
    'Turns off the Windows Copilot integration through policy.' `
    'Removes the Copilot button and integration from the taskbar and Windows.' `
    'you use Copilot regularly.' `
    $true 'Low' 'Reg' @( (New-RegEntry 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1) ) $true
Add-Tweak 'Ads and suggestions' 'Hide Start menu recommendations' `
    'Hides recently opened files and recommended items in Start.' `
    'A cleaner Start menu that does not list your recent documents or promoted apps.' `
    'you use the Recommended section to reopen recent files.' `
    $true 'Low' 'Reg' @(
        (New-RegEntry $ADV 'Start_IrisRecommendations' 0 1),
        (New-RegEntry $ADV 'Start_TrackDocs' 0 1)
    ) $true

# ---- Taskbar and Explorer
Add-Tweak 'Taskbar and Explorer' 'Disable Widgets' `
    'Removes the Widgets and News feed button and its background process.' `
    'Frees memory and removes the news feed popup.' `
    'you check weather or news from the Widgets board.' `
    $true 'Low' 'Reg' @( (New-RegEntry 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0) ) $true
Add-Tweak 'Taskbar and Explorer' 'Hide Chat / Teams icon' `
    'Removes the Chat button from the taskbar.' `
    'A less cluttered taskbar.' `
    'you use personal Teams chat from the taskbar.' `
    $true 'Low' 'Reg' @( (New-RegEntry $ADV 'TaskbarMn' 0 1) ) $true
Add-Tweak 'Taskbar and Explorer' 'Hide Task View button' `
    'Removes the virtual-desktop button from the taskbar.' `
    'More taskbar space. Win+Tab still works.' `
    'you click the Task View button with your mouse.' `
    $false 'Low' 'Reg' @( (New-RegEntry $ADV 'ShowTaskViewButton' 0 1) ) $true
Add-Tweak 'Taskbar and Explorer' 'Classic right-click menu' `
    'Restores the full Windows 10 style context menu (no "Show more options").' `
    'Every right-click option is available immediately without an extra click.' `
    'you prefer the compact Windows 11 menu.' `
    $true 'Low' 'Reg' @(
        (New-RegEntry 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(default)' '' $null 'String' $true)
    ) $true
Add-Tweak 'Taskbar and Explorer' 'Show file extensions' `
    'Always show .txt, .exe, .pdf and so on.' `
    'Safer and clearer: you can spot fake files like invoice.pdf.exe.' `
    'you prefer names without extensions.' `
    $true 'Low' 'Reg' @( (New-RegEntry $ADV 'HideFileExt' 0 1) ) $true
Add-Tweak 'Taskbar and Explorer' 'Open Explorer to This PC' `
    'File Explorer opens on This PC instead of Home.' `
    'Quick access to your drives and folders.' `
    'you like Home with its recent and pinned files.' `
    $false 'Low' 'Reg' @( (New-RegEntry $ADV 'LaunchTo' 1 $null) ) $true
Add-Tweak 'Taskbar and Explorer' 'Align taskbar to the left' `
    'Windows 10 style taskbar and Start button position.' `
    'Start is always in the bottom-left corner where muscle memory expects it.' `
    'you like the centred Windows 11 layout.' `
    $false 'Low' 'Reg' @( (New-RegEntry $ADV 'TaskbarAl' 0 1) ) $true

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

    $Items = @($Items)
    if ($script:IsDry) { Write-Log '--- DRY RUN: nothing will be changed ---' }
    if ($MakeRestorePoint -and -not $Undo) {
        Set-Progress 0 'Creating restore point...'
        New-RestorePoint
    }

    $needExplorer = $false
    $i = 0
    foreach ($item in $Items) {
        $i++
        $verb = if ($Undo) { 'Undo' } else { 'Apply' }
        Write-Log "${verb}: [$($item.Category)] $($item.Name)"
        Set-Progress (($i - 1) / $Items.Count * 100) "$verb $i of $($Items.Count): $($item.Name)"
        Invoke-Tweak -Item $item -Undo $Undo
        if ($item.Explorer) { $needExplorer = $true }
    }
    if ($needExplorer) { Restart-Explorer }
    Set-Progress 100 'Finished'
    Write-Log "Finished. Log saved to $script:LogFile"
}

# ---------------------------------------------------------------- command-line mode
if ($NoGui) {
    Write-Log "WinSlim $script:Version (no GUI) - applying recommended items"
    Invoke-Selection -Items ($script:Tweaks | Where-Object { $_.Recommended }) -Undo $false -MakeRestorePoint $true
    return
}

# ---------------------------------------------------------------- XAML
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinSlim" Width="1180" Height="740" MinWidth="1000" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#12141A"
        FontFamily="Segoe UI" Foreground="#E8EAF0" UseLayoutRounding="True">
  <Window.Resources>

    <!-- Animated toggle switch -->
    <Style x:Key="Toggle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="26" Background="Transparent">
              <Border x:Name="Track" CornerRadius="13">
                <Border.Background><SolidColorBrush Color="#3A3F4B"/></Border.Background>
              </Border>
              <Ellipse x:Name="Thumb" Width="20" Height="20" Fill="White" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <ThicknessAnimation Storyboard.TargetName="Thumb" Storyboard.TargetProperty="Margin" To="23,0,0,0" Duration="0:0:0.18"/>
                      <ColorAnimation Storyboard.TargetName="Track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#4C8DFF" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <ThicknessAnimation Storyboard.TargetName="Thumb" Storyboard.TargetProperty="Margin" To="3,0,0,0" Duration="0:0:0.18"/>
                      <ColorAnimation Storyboard.TargetName="Track" Storyboard.TargetProperty="(Border.Background).(SolidColorBrush.Color)" To="#3A3F4B" Duration="0:0:0.18"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Sidebar buttons -->
    <Style x:Key="SideBtn" TargetType="Button">
      <Setter Property="Foreground" Value="#C5CBD6"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid>
              <Border x:Name="Bd" CornerRadius="8" Background="Transparent"/>
              <Border x:Name="Bar" Width="3" CornerRadius="2" Background="#4C8DFF" HorizontalAlignment="Left" Margin="0,9" Opacity="0"/>
              <ContentPresenter Margin="16,10" VerticalAlignment="Center" HorizontalAlignment="Stretch"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#1F232C"/>
              </Trigger>
              <Trigger Property="Tag" Value="Active">
                <Setter TargetName="Bd" Property="Background" Value="#222A3B"/>
                <Setter TargetName="Bar" Property="Opacity" Value="1"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Regular and primary buttons -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#2A2F3A"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="Margin" Value="8,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnPrimary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#4C8DFF"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <!-- Profile cards on the home page -->
    <Style x:Key="CardBtn" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,0,14,14"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="#1E222B" CornerRadius="14" Padding="20" BorderBrush="#2A2F3A" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#262C39"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#4C8DFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- List rows -->
    <Style x:Key="RowItem" TargetType="ListBoxItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="#1E222B" CornerRadius="10" Margin="0,0,8,8" Padding="16,12" BorderThickness="1" BorderBrush="#262A33">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#252A35"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#4C8DFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#1E222B"/>
      <Setter Property="Foreground" Value="#E8EAF0"/>
      <Setter Property="BorderBrush" Value="#2A2F3A"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="CaretBrush" Value="White"/>
    </Style>

    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7F8898"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,16,0,4"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="230"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- ============ Sidebar ============ -->
    <Border Grid.Column="0" Background="#171A21">
      <DockPanel>
        <StackPanel DockPanel.Dock="Top" Margin="22,26,22,18">
          <TextBlock Text="WinSlim" FontSize="24" FontWeight="Bold"/>
          <TextBlock Text="Windows 11 debloater" Foreground="#7F8898" FontSize="12" Margin="0,2,0,0"/>
        </StackPanel>
        <TextBlock x:Name="VersionText" DockPanel.Dock="Bottom" Foreground="#5E6674" FontSize="11" Margin="22,0,22,16" TextWrapping="Wrap"/>
        <StackPanel Margin="10,0">
          <Button x:Name="NavHome" Style="{StaticResource SideBtn}" Tag="Active">
            <TextBlock Text="Start here"/>
          </Button>
          <TextBlock Text="OPTIONS" Foreground="#5E6674" FontSize="11" FontWeight="SemiBold" Margin="16,16,0,6"/>
          <Button x:Name="NavApps" Style="{StaticResource SideBtn}">
            <Grid><TextBlock Text="Apps"/><TextBlock x:Name="CntApps" HorizontalAlignment="Right" Foreground="#4C8DFF" FontWeight="SemiBold"/></Grid>
          </Button>
          <Button x:Name="NavPrivacy" Style="{StaticResource SideBtn}">
            <Grid><TextBlock Text="Privacy"/><TextBlock x:Name="CntPrivacy" HorizontalAlignment="Right" Foreground="#4C8DFF" FontWeight="SemiBold"/></Grid>
          </Button>
          <Button x:Name="NavAds" Style="{StaticResource SideBtn}">
            <Grid><TextBlock Text="Ads and suggestions"/><TextBlock x:Name="CntAds" HorizontalAlignment="Right" Foreground="#4C8DFF" FontWeight="SemiBold"/></Grid>
          </Button>
          <Button x:Name="NavTaskbar" Style="{StaticResource SideBtn}">
            <Grid><TextBlock Text="Taskbar and Explorer"/><TextBlock x:Name="CntTaskbar" HorizontalAlignment="Right" Foreground="#4C8DFF" FontWeight="SemiBold"/></Grid>
          </Button>
          <TextBlock Text="FINISH" Foreground="#5E6674" FontSize="11" FontWeight="SemiBold" Margin="16,16,0,6"/>
          <Button x:Name="NavReview" Style="{StaticResource SideBtn}">
            <Grid><TextBlock Text="Review and apply"/><TextBlock x:Name="CntReview" HorizontalAlignment="Right" Foreground="#4C8DFF" FontWeight="SemiBold"/></Grid>
          </Button>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- ============ Pages ============ -->
    <Grid Grid.Column="1" Margin="28,24,24,20">

      <!-- Home -->
      <Grid x:Name="PageHome">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock Text="Let's slim down Windows" FontSize="30" FontWeight="Bold"/>
            <TextBlock TextWrapping="Wrap" Foreground="#9AA3B2" FontSize="14" Margin="0,8,0,22" MaxWidth="760"
                       Text="Not sure what to pick? Choose a starting profile. Nothing changes yet: you can review and adjust every option, and read what it does, before anything is applied."/>
            <UniformGrid Columns="2" MaxWidth="820" HorizontalAlignment="Left">
              <Button x:Name="ProfLight" Style="{StaticResource CardBtn}">
                <StackPanel>
                  <TextBlock Text="Light touch" FontSize="17" FontWeight="SemiBold"/>
                  <TextBlock Foreground="#9AA3B2" TextWrapping="Wrap" Margin="0,6,0,0"
                             Text="Only the clearly useless stuff: ads, junk apps and cosmetic fixes. Lowest risk."/>
                </StackPanel>
              </Button>
              <Button x:Name="ProfRec" Style="{StaticResource CardBtn}">
                <StackPanel>
                  <TextBlock Text="Recommended" FontSize="17" FontWeight="SemiBold"/>
                  <TextBlock Foreground="#9AA3B2" TextWrapping="Wrap" Margin="0,6,0,0"
                             Text="The best balance for most people: junk apps, telemetry, ads and Copilot off."/>
                </StackPanel>
              </Button>
              <Button x:Name="ProfPrivacy" Style="{StaticResource CardBtn}">
                <StackPanel>
                  <TextBlock Text="Privacy first" FontSize="17" FontWeight="SemiBold"/>
                  <TextBlock Foreground="#9AA3B2" TextWrapping="Wrap" Margin="0,6,0,0"
                             Text="Every privacy and ad-related option, plus the recommended junk apps."/>
                </StackPanel>
              </Button>
              <Button x:Name="ProfMax" Style="{StaticResource CardBtn}">
                <StackPanel>
                  <TextBlock Text="Maximum" FontSize="17" FontWeight="SemiBold"/>
                  <TextBlock Foreground="#9AA3B2" TextWrapping="Wrap" Margin="0,6,0,0"
                             Text="Everything in the list, including apps some people use (Xbox, Maps, To Do). Check the details first."/>
                </StackPanel>
              </Button>
            </UniformGrid>

            <Border Background="#1A1D25" CornerRadius="12" Padding="20" Margin="0,6,14,0" MaxWidth="806" HorizontalAlignment="Left">
              <StackPanel>
                <TextBlock Text="How to decide" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock TextWrapping="Wrap" Foreground="#9AA3B2" Margin="0,8,0,0"
                           Text="Click any option in the lists to see what it does, why you might want it, and who should skip it. The exact registry or app change is shown at the bottom of the panel."/>
                <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                  <Border Background="#2E9E6B" CornerRadius="9" Padding="8,1" Margin="0,0,8,0"><TextBlock Text="Low" FontSize="11" Foreground="White"/></Border>
                  <TextBlock Text="Cosmetic, privacy or an app almost nobody misses." Foreground="#9AA3B2" FontSize="12"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
                  <Border Background="#C98A1B" CornerRadius="9" Padding="8,1" Margin="0,0,8,0"><TextBlock Text="Medium" FontSize="11" Foreground="White"/></Border>
                  <TextBlock Text="Removes or disables something some people use. Read the 'Skip it if' note." Foreground="#9AA3B2" FontSize="12"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <!-- Option lists -->
      <Grid x:Name="PageTweaks" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" Margin="0,0,0,16">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="Search" Foreground="#7F8898" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBox x:Name="Search" Width="170"/>
            <Button x:Name="BtnSelRec" Content="Select recommended" Style="{StaticResource Btn}"/>
            <Button x:Name="BtnClear" Content="Clear" Style="{StaticResource Btn}"/>
          </StackPanel>
          <StackPanel>
            <TextBlock x:Name="PageTitle" FontSize="24" FontWeight="Bold"/>
            <TextBlock x:Name="PageSub" Foreground="#9AA3B2" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>

        <Grid Grid.Row="1">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="340"/>
          </Grid.ColumnDefinitions>

          <ListBox x:Name="List" Grid.Column="0" Background="Transparent" BorderThickness="0"
                   ItemContainerStyle="{StaticResource RowItem}"
                   ScrollViewer.HorizontalScrollBarVisibility="Disabled">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <StackPanel Grid.Column="0" Margin="0,0,12,0">
                    <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding Desc}" Foreground="#9AA3B2" FontSize="12" TextWrapping="Wrap" Margin="0,3,0,0"/>
                  </StackPanel>
                  <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="0,0,16,0" HorizontalAlignment="Right">
                    <TextBlock Text="{Binding RecText}" Foreground="#4C8DFF" FontSize="11" HorizontalAlignment="Right"/>
                    <Border CornerRadius="9" Padding="8,1" Background="{Binding RiskColor}" HorizontalAlignment="Right" Margin="0,3,0,0">
                      <TextBlock Text="{Binding Risk}" FontSize="11" Foreground="White"/>
                    </Border>
                  </StackPanel>
                  <CheckBox Grid.Column="2" Style="{StaticResource Toggle}"
                            IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>

          <Border Grid.Column="1" Background="#1A1D25" CornerRadius="14" Margin="8,0,0,8">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel x:Name="DetailPanel" Margin="22,20" DataContext="{Binding SelectedItem, ElementName=List}">
                <TextBlock Text="{Binding Name}" FontSize="19" FontWeight="SemiBold" TextWrapping="Wrap"/>
                <WrapPanel Margin="0,10,0,0">
                  <Border CornerRadius="10" Padding="9,2" Background="{Binding RiskColor}" Margin="0,0,6,6">
                    <TextBlock Text="{Binding RiskText}" FontSize="11" Foreground="White"/>
                  </Border>
                  <Border CornerRadius="10" Padding="9,2" Background="#2F3542" Margin="0,0,6,6">
                    <TextBlock Text="{Binding UndoText}" FontSize="11" Foreground="White"/>
                  </Border>
                  <TextBlock Text="{Binding RecText}" Foreground="#4C8DFF" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center" Margin="2,0,0,6"/>
                </WrapPanel>
                <TextBlock Text="WHAT IT DOES" Style="{StaticResource SectionLabel}"/>
                <TextBlock Text="{Binding Desc}" TextWrapping="Wrap" Foreground="#D5D9E2"/>
                <TextBlock Text="WHY YOU MIGHT WANT IT" Style="{StaticResource SectionLabel}"/>
                <TextBlock Text="{Binding Why}" TextWrapping="Wrap" Foreground="#D5D9E2"/>
                <TextBlock Text="SKIP IT IF..." Style="{StaticResource SectionLabel}"/>
                <TextBlock Text="{Binding SkipIf}" TextWrapping="Wrap" Foreground="#E6B85C"/>
                <TextBlock Text="TECHNICAL DETAILS" Style="{StaticResource SectionLabel}"/>
                <Border Background="#12141A" CornerRadius="8" Padding="10">
                  <TextBlock Text="{Binding Tech}" FontFamily="Consolas" FontSize="11" Foreground="#9AA3B2" TextWrapping="Wrap"/>
                </Border>
              </StackPanel>
            </ScrollViewer>
          </Border>
        </Grid>
      </Grid>

      <!-- Review and apply -->
      <Grid x:Name="PageReview" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="130"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,16">
          <TextBlock Text="Review and apply" FontSize="24" FontWeight="Bold"/>
          <TextBlock x:Name="SummaryHead" Foreground="#9AA3B2" Margin="0,4,0,0"/>
        </StackPanel>

        <Grid Grid.Row="1">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="340"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Background="#1A1D25" CornerRadius="14" Margin="0,0,8,8">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <TextBlock x:Name="SummaryText" Margin="22,18" TextWrapping="Wrap" Foreground="#D5D9E2" LineHeight="22"/>
            </ScrollViewer>
          </Border>
          <Border Grid.Column="1" Background="#1A1D25" CornerRadius="14" Margin="8,0,0,8" Padding="22,20">
            <StackPanel>
              <TextBlock Text="Options" FontSize="15" FontWeight="SemiBold"/>
              <DockPanel Margin="0,16,0,0">
                <CheckBox x:Name="ChkRestore" DockPanel.Dock="Right" Style="{StaticResource Toggle}" IsChecked="True"/>
                <StackPanel>
                  <TextBlock Text="Create restore point" FontWeight="SemiBold"/>
                  <TextBlock Text="Lets you roll Windows back if something goes wrong." Foreground="#9AA3B2" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
              </DockPanel>
              <DockPanel Margin="0,16,0,0">
                <CheckBox x:Name="ChkDry" DockPanel.Dock="Right" Style="{StaticResource Toggle}"/>
                <StackPanel>
                  <TextBlock Text="Dry run (preview only)" FontWeight="SemiBold"/>
                  <TextBlock Text="Logs what would happen without changing anything. Great for a first try." Foreground="#9AA3B2" FontSize="12" TextWrapping="Wrap"/>
                </StackPanel>
              </DockPanel>
              <TextBlock x:Name="ReviewNote" Foreground="#E6B85C" FontSize="12" TextWrapping="Wrap" Margin="0,18,0,0"/>
              <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
                <Button x:Name="BtnApply" Content="Apply selected" Style="{StaticResource BtnPrimary}" Margin="0"/>
                <Button x:Name="BtnUndo" Content="Undo selected" Style="{StaticResource Btn}"/>
              </StackPanel>
              <Button x:Name="BtnLogs" Content="Open log folder" Style="{StaticResource Btn}" Margin="0,10,0,0" HorizontalAlignment="Left"/>
            </StackPanel>
          </Border>
        </Grid>

        <StackPanel Grid.Row="2" Margin="0,4,0,10">
          <TextBlock x:Name="Status" Foreground="#9AA3B2" FontSize="12" Margin="0,0,0,6"/>
          <ProgressBar x:Name="Progress" Height="6" Minimum="0" Maximum="100" Value="0" Background="#2A2F3A" Foreground="#4C8DFF" BorderThickness="0"/>
        </StackPanel>
        <TextBox x:Name="LogBox" Grid.Row="3" IsReadOnly="True" FontFamily="Consolas" FontSize="11"
                 VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
      </Grid>

    </Grid>
  </Grid>
</Window>
'@

# ---------------------------------------------------------------- GUI logic
function Start-FadeIn {
    param($Element, [double]$Offset = 14)
    $tt = New-Object System.Windows.Media.TranslateTransform
    $tt.Y = $Offset
    $Element.RenderTransform = $tt
    $Element.Opacity = 0
    $dur  = New-Object System.Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(300))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = 'EaseOut'

    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From = 0.0; $fade.To = 1.0; $fade.Duration = $dur; $fade.EasingFunction = $ease
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation
    $slide.From = $Offset; $slide.To = 0.0; $slide.Duration = $dur; $slide.EasingFunction = $ease
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Get-Selected {
    @($script:Tweaks | Where-Object { $_.Selected })
}

function Update-Counts {
    $map = @{
        'Apps' = 'CntApps'; 'Privacy' = 'CntPrivacy'
        'Ads and suggestions' = 'CntAds'; 'Taskbar and Explorer' = 'CntTaskbar'
    }
    foreach ($k in $map.Keys) {
        $n = @($script:Tweaks | Where-Object { $_.Category -eq $k -and $_.Selected }).Count
        $script:ui[$map[$k]].Text = if ($n -gt 0) { "$n" } else { '' }
    }
    $total = (Get-Selected).Count
    $script:ui.CntReview.Text = if ($total -gt 0) { "$total" } else { '' }
}

$script:PageInfo = @{
    'Apps'                 = @('Apps', 'Preinstalled and promoted apps. Removed apps are not restored by Undo, but you can reinstall any of them from the Microsoft Store.')
    'Privacy'              = @('Privacy', 'Stop Windows collecting and sharing more data than it needs to.')
    'Ads and suggestions'  = @('Ads and suggestions', 'Remove promotions, suggested apps, web search in Start and AI integrations nobody asked for.')
    'Taskbar and Explorer' = @('Taskbar and Explorer', 'Cleaner everyday UI. These are mostly personal preference.')
}

function Update-List {
    param([bool]$Animate = $true)
    $q = $script:ui.Search.Text.Trim()
    $col = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    foreach ($t in $script:Tweaks) {
        if ($q) {
            if ("$($t.Name) $($t.Desc) $($t.Category)" -like "*$q*") { $col.Add($t) }
        } elseif ($t.Category -eq $script:CurrentCat) {
            $col.Add($t)
        }
    }
    if ($q) {
        $script:ui.PageTitle.Text = 'Search results'
        $script:ui.PageSub.Text   = "$($col.Count) option(s) matching '$q' across all categories."
    } else {
        $script:ui.PageTitle.Text = $script:PageInfo[$script:CurrentCat][0]
        $script:ui.PageSub.Text   = $script:PageInfo[$script:CurrentCat][1]
    }
    $script:ui.List.ItemsSource = $col
    if ($col.Count -gt 0) { $script:ui.List.SelectedIndex = 0 }
    if ($Animate) { Start-FadeIn $script:ui.List 16 }
}

function Update-Summary {
    $sel = Get-Selected
    $script:ui.SummaryHead.Text = if ($sel.Count -gt 0) { "$($sel.Count) option(s) selected. Nothing has been changed yet." } else { 'Nothing selected yet. Pick a profile on the Start page or turn on options in the lists.' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($cat in $script:Categories) {
        $items = @($sel | Where-Object { $_.Category -eq $cat })
        if ($items.Count -eq 0) { continue }
        [void]$sb.AppendLine("$($cat.ToUpper())  ($($items.Count))")
        foreach ($i in $items) { [void]$sb.AppendLine("   -  $($i.Name)   [$($i.Risk)]") }
        [void]$sb.AppendLine('')
    }
    $script:ui.SummaryText.Text = $sb.ToString()

    $notes = @()
    if (@($sel | Where-Object { $_.Kind -eq 'Apps' }).Count -gt 0) { $notes += 'Removed apps are not brought back by Undo. Reinstall them from the Microsoft Store if needed.' }
    if (@($sel | Where-Object { $_.Risk -eq 'Medium' }).Count -gt 0) { $notes += 'Some selected items are Medium risk. Open them in the lists and check "Skip it if".' }
    $script:ui.ReviewNote.Text = ($notes -join "`r`n`r`n")
}

function Show-Page {
    param([string]$Name)
    foreach ($p in 'PageHome', 'PageTweaks', 'PageReview') { $script:ui[$p].Visibility = 'Collapsed' }
    foreach ($n in 'NavHome', 'NavApps', 'NavPrivacy', 'NavAds', 'NavTaskbar', 'NavReview') { $script:ui[$n].Tag = $null }

    $navFor = @{
        'Home' = 'NavHome'; 'Review' = 'NavReview'; 'Apps' = 'NavApps'; 'Privacy' = 'NavPrivacy'
        'Ads and suggestions' = 'NavAds'; 'Taskbar and Explorer' = 'NavTaskbar'
    }
    $script:ui[$navFor[$Name]].Tag = 'Active'

    switch ($Name) {
        'Home' {
            $script:ui.PageHome.Visibility = 'Visible'
            Start-FadeIn $script:ui.PageHome
        }
        'Review' {
            Update-Summary
            $script:ui.PageReview.Visibility = 'Visible'
            Start-FadeIn $script:ui.PageReview
        }
        default {
            $script:CurrentCat = $Name
            $script:ui.Search.Text = ''
            $script:ui.PageTweaks.Visibility = 'Visible'
            Update-List -Animate $true
            Start-FadeIn $script:ui.DetailPanel 10
        }
    }
}

function Set-Profile {
    param([string]$Profile)
    foreach ($t in $script:Tweaks) {
        switch ($Profile) {
            'Light'   { $t.Selected = ($t.Recommended -and $t.Risk -eq 'Low') }
            'Rec'     { $t.Selected = $t.Recommended }
            'Privacy' { $t.Selected = (($t.Category -in @('Privacy', 'Ads and suggestions')) -or ($t.Category -eq 'Apps' -and $t.Recommended)) }
            'Max'     { $t.Selected = $true }
        }
    }
    Update-Counts
    Show-Page 'Apps'
}

function Start-Run {
    param([bool]$Undo)
    $sel = Get-Selected
    if ($Undo) { $sel = @($sel | Where-Object { $_.Reversible }) }
    if ($sel.Count -eq 0) {
        [void][System.Windows.MessageBox]::Show('Nothing selected.', 'WinSlim')
        return
    }
    $verb = if ($Undo) { 'undo' } else { 'apply' }
    $msg = "About to $verb $($sel.Count) option(s)."
    if ($script:ui.ChkDry.IsChecked) { $msg += "`r`n`r`nDry run is ON: nothing will actually change." }
    $msg += "`r`n`r`nContinue?"
    if ([System.Windows.MessageBox]::Show($msg, 'WinSlim', 'YesNo', 'Question') -ne 'Yes') { return }

    $script:IsDry = [bool]$script:ui.ChkDry.IsChecked
    $script:ui.BtnApply.IsEnabled = $false
    $script:ui.BtnUndo.IsEnabled  = $false
    $script:ui.Progress.BeginAnimation([System.Windows.Controls.Primitives.RangeBase]::ValueProperty, $null)
    $script:ui.Progress.Value = 0
    try {
        Invoke-Selection -Items $sel -Undo $Undo -MakeRestorePoint ([bool]$script:ui.ChkRestore.IsChecked)
    } finally {
        $script:ui.BtnApply.IsEnabled = $true
        $script:ui.BtnUndo.IsEnabled  = $true
    }
    [void][System.Windows.MessageBox]::Show("Done. A restart is recommended.`r`nLog: $script:LogFile", 'WinSlim')
}

# ---------------------------------------------------------------- build window and wire events
try {
    $window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
    foreach ($n in 'PageHome', 'PageTweaks', 'PageReview', 'NavHome', 'NavApps', 'NavPrivacy', 'NavAds', 'NavTaskbar', 'NavReview',
                   'CntApps', 'CntPrivacy', 'CntAds', 'CntTaskbar', 'CntReview', 'VersionText',
                   'ProfLight', 'ProfRec', 'ProfPrivacy', 'ProfMax',
                   'Search', 'BtnSelRec', 'BtnClear', 'PageTitle', 'PageSub', 'List', 'DetailPanel',
                   'SummaryHead', 'SummaryText', 'ChkRestore', 'ChkDry', 'ReviewNote', 'BtnApply', 'BtnUndo', 'BtnLogs',
                   'Status', 'Progress', 'LogBox') {
        $script:ui[$n] = $window.FindName($n)
    }
    $script:ui.VersionText.Text = "v$script:Version`r`nChanges are logged to the logs folder."
    $script:ui.ChkDry.IsChecked = $script:IsDry

    $navMap = @{
        NavHome = 'Home'; NavApps = 'Apps'; NavPrivacy = 'Privacy'; NavAds = 'Ads and suggestions'
        NavTaskbar = 'Taskbar and Explorer'; NavReview = 'Review'
    }
    $script:NavMap = $navMap
    $navHandler = { param($sender, $e) Show-Page $script:NavMap[$sender.Name] }
    foreach ($n in $navMap.Keys) { $script:ui[$n].Add_Click($navHandler) }

    $script:ui.ProfLight.Add_Click({   Set-Profile 'Light' })
    $script:ui.ProfRec.Add_Click({     Set-Profile 'Rec' })
    $script:ui.ProfPrivacy.Add_Click({ Set-Profile 'Privacy' })
    $script:ui.ProfMax.Add_Click({     Set-Profile 'Max' })

    $script:ui.BtnSelRec.Add_Click({
        foreach ($t in $script:ui.List.ItemsSource) { $t.Selected = $t.Recommended }
        Update-Counts
    })
    $script:ui.BtnClear.Add_Click({
        foreach ($t in $script:ui.List.ItemsSource) { $t.Selected = $false }
        Update-Counts
    })
    $script:ui.Search.Add_TextChanged({ if ($script:ui.PageTweaks.Visibility -eq 'Visible') { Update-List -Animate $false } })
    $script:ui.List.Add_SelectionChanged({
        if ($script:ui.List.SelectedItem) { Start-FadeIn $script:ui.DetailPanel 8 }
    })
    $script:ui.List.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::ClickEvent,
        [System.Windows.RoutedEventHandler]{ Update-Counts })

    $script:ui.BtnApply.Add_Click({ Start-Run $false })
    $script:ui.BtnUndo.Add_Click({  Start-Run $true })
    $script:ui.BtnLogs.Add_Click({  Start-Process explorer.exe $script:LogDir })

    Write-Log "WinSlim $script:Version started."
    if ([Environment]::OSVersion.Version.Build -lt 22000) {
        Write-Log 'This does not look like Windows 11 (build < 22000). Some options may not apply.' 'WARN'
    }

    $window.Add_ContentRendered({ Start-FadeIn $script:ui.PageHome })
    [void]$window.ShowDialog()
} catch {
    Write-Log "Fatal error: $($_.Exception.Message)" 'ERROR'
    [void][System.Windows.MessageBox]::Show("WinSlim hit an error:`r`n`r`n$($_.Exception.Message)`r`n`r`nLog: $script:LogFile", 'WinSlim', 'OK', 'Error')
}

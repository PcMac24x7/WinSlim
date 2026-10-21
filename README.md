# WinSlim

A small, transparent **Windows 11 debloater** with a modern animated GUI. No downloads, no black boxes: everything it does is listed in [`WinSlim.ps1`](WinSlim.ps1).

## Features

- **Smooth WPF interface**: animated toggle switches, page transitions and a live progress bar
- **Helps you decide**: click any option to see what it does, why you might want it, who should skip it, a Low/Medium risk badge, and the exact registry or app change
- **Start profiles**: Light touch, Recommended, Privacy first, Maximum. Pick one, then fine-tune
- Search across all options
- Remove preinstalled apps (News, Teams, Clipchamp, Candy Crush, Phone Link, and so on)
- Turn off telemetry, advertising ID, activity history, Recall, Copilot and Start menu ads
- Taskbar and Explorer tweaks (classic right-click menu, file extensions, no Widgets or Chat)
- **System Restore point** created before changes
- **Dry-run mode** shows what would change without touching anything
- **Undo** for all registry and service tweaks (removed apps must be reinstalled from the Microsoft Store)
- Full log of every action in `logs\`

## Quick start (one command)

Open **PowerShell** (Start menu > type `PowerShell` > Enter) and paste:

```powershell
irm https://raw.githubusercontent.com/PcMac24x7/WinSlim/main/WinSlim.ps1 | iex
```

Accept the administrator (UAC) prompt and the WinSlim window opens. Nothing is changed until you review your choices and click **Apply selected**.

1. On **Start here**, pick a profile (or browse the option pages yourself). Click any option to read what it does, who should skip it, and its risk level.
2. Open **Review and apply**, turn on **Dry run** if you want a preview, then click **Apply selected**.
3. Restart Windows.

> **Tip:** read the script first if you like: it is one readable file, [`WinSlim.ps1`](WinSlim.ps1). Never run an `irm | iex` command from a source you don't trust.

### Other ways to run it

```powershell
# Preview only, no GUI, applies the recommended set as a dry run
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/PcMac24x7/WinSlim/main/WinSlim.ps1))) -NoGui -DryRun

# From a downloaded release: extract the zip, then double-click Run.bat, or:
.\WinSlim.ps1
```

If PowerShell blocks a downloaded file: `powershell -ExecutionPolicy Bypass -File .\WinSlim.ps1`

## What is *not* touched

Microsoft Store, Photos, Calculator, Notepad, Terminal, Edge, Windows Security, Windows Update and OneDrive are left alone on purpose, so the system stays supported and updatable.

## Safety notes

- Always keep a backup. Windows only allows one restore point per 24 hours by default.
- Tweaks apply to the **currently logged-in user**. If you elevate with a different admin account, per-user settings land on that account.
- Windows feature updates can re-enable some settings or reinstall apps. Just run WinSlim again.
- Use at your own risk (see [LICENSE](LICENSE)).

## Adding your own tweaks

Open `WinSlim.ps1` and add an entry in the catalogue section:

```powershell
# Category, Name, What it does, Why you might want it, Skip it if..., Recommended, Risk, Kind, Data
Add-Tweak 'Privacy' 'My tweak' 'What it does' 'Why it helps' 'you need X.' $true 'Low' 'Reg' @(
    (New-RegEntry 'HKCU:\Software\Example' 'SomeValue' 0 1)   # path, name, apply value, undo value
)
```

Kinds: `Reg`, `Service`, `Apps`.

## Optional: build a single .exe

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe .\WinSlim.ps1 .\WinSlim.exe -requireAdmin -noConsole -STA
```

## Publishing a release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The GitHub Action in `.github/workflows/release.yml` lints the script and attaches a zip to the release automatically.

## License

MIT

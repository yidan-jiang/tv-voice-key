<#
.SYNOPSIS
  Use the voice key on an Android TV remote to start and stop voice input in a desktop AI app
  (Claude, or any other app whose mic button or dictation shortcut you configure).

.DESCRIPTION
  Watches the TV's log over ADB for the remote's voice key. On every press it either toggles the
  app's mic button through Windows UI Automation (Mode Button) or sends a keyboard shortcut
  (Mode Hotkey). In Button mode, the press that stops recording can also send the message once the
  transcript has stopped changing.

  Windows only. Needs adb and a TV with network debugging on.

.EXAMPLE
  .\tv-voice-key.ps1 -TvHost 192.168.1.50
  Claude desktop, Chinese UI (the defaults).

.EXAMPLE
  .\tv-voice-key.ps1 -TvHost 192.168.1.50 -ListControls
  Print the buttons and text boxes of the target window, to find the names for another app or language.

.EXAMPLE
  .\tv-voice-key.ps1 -TvHost 192.168.1.50 -Mode Hotkey -Hotkey '^+{SPACE}'
  Send Ctrl+Shift+Space instead, for an app that has a global dictation shortcut.
#>
param(
    # TV address, host or host:port. Falls back to the TV_HOST environment variable.
    [string]$TvHost = $env:TV_HOST,
    # adb executable; 'adb' means the one on PATH.
    [string]$Adb = 'adb',

    # Key code the remote's voice key produces (219 = KEYCODE_ASSIST, 84 = KEYCODE_SEARCH, 231 = KEYCODE_VOICE_ASSIST).
    [int]$KeyCode = 219,
    # Log tag and line that mark a key press on the TV. {0} is replaced by -KeyCode.
    [string]$LogTag = 'WindowManager',
    [string]$LogPattern = 'interceptKeyTq keycode={0}\b',
    # One press is usually logged twice (key down and key up); presses closer than this count once.
    [int]$DebounceMs = 700,

    # Button: toggle a mic button through UI Automation. Hotkey: send a keyboard shortcut.
    [ValidateSet('Button', 'Hotkey')]
    [string]$Mode = 'Button',

    # Title of the app window (exact match).
    [string]$WindowTitle = 'Claude',
    # Button mode: the mic button's accessible name when idle and while recording (they differ per app and UI language).
    [string]$IdleButtonName = '按住以录音',
    [string]$RecordingButtonName = '停止听写',
    # Button mode: the accessible name of the message box, for auto-send.
    [string]$ComposerName = '提示词',
    # Button mode: press Enter after the press that stops recording.
    [bool]$AutoSend = $true,
    # Transcript unchanged this long = finished; give up after SendTimeoutSec.
    [int]$StableMs = 1000,
    [int]$SendTimeoutSec = 20,
    # Button mode: switch to this conversation (its name in the app's sidebar) before recording, so every
    # voice message lands in the same one. Empty: use whatever conversation is on screen.
    [string]$SessionName = '',

    # Start the app when its window isn't open, and restore it when minimized.
    [bool]$LaunchApp = $true,
    # Windows app ID to start (see Get-StartApps). Empty: look it up by -WindowTitle.
    [string]$AppId = '',
    [int]$LaunchTimeoutSec = 45,

    # Hotkey mode: SendKeys syntax, sent to the foreground window (^ = Ctrl, + = Shift, % = Alt).
    [string]$Hotkey = '',

    # Print the target window's buttons and text boxes, then exit.
    [switch]$ListControls,
    # Log file; empty for none.
    [string]$LogFile = (Join-Path $PSScriptRoot 'tv-voice-key.log')
)

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
$UIA = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]
$CT = [System.Windows.Automation.ControlType]

function Log($msg) { Write-Host "$(Get-Date -f HH:mm:ss)  $msg" }

function Get-AppWindows {
    $c = New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $WindowTitle)
    return $UIA::RootElement.FindAll($Scope::Children, $c)
}

if ($ListControls) {
    $wins = Get-AppWindows
    if ($wins.Count -eq 0) { Write-Host "No window titled '$WindowTitle'. Use -WindowTitle."; exit 1 }
    foreach ($w in $wins) {
        [void]$w.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)  # wakes Chromium's accessibility tree
        Start-Sleep 1
        foreach ($t in $CT::Button, $CT::Edit) {
            $w.FindAll($Scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $t))) |
                Where-Object { $_.Current.Name } |
                ForEach-Object { '{0,-7} {1}' -f $t.ProgrammaticName.Replace('ControlType.', ''), $_.Current.Name }
        }
    }
    Write-Host "`nStart recording in the app and run this again to see the button's recording name."
    exit 0
}

if (-not $TvHost) { Write-Host 'Give the TV address with -TvHost or the TV_HOST environment variable.'; exit 1 }
if ($TvHost -notmatch ':\d+$') { $TvHost = "${TvHost}:5555" }
if ($Mode -eq 'Hotkey' -and -not $Hotkey) { Write-Host 'Hotkey mode needs -Hotkey.'; exit 1 }

# One copy only: two would each toggle the mic and cancel each other out.
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\TvVoiceKey', [ref]$created)
if (-not $created) { Write-Host 'tv-voice-key is already running - exiting.'; exit 0 }
if ($LogFile) { try { Start-Transcript -Path $LogFile -Append | Out-Null } catch {} }

function Get-MicButton {
    $btnCond = New-Object System.Windows.Automation.OrCondition(
        (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $IdleButtonName)),
        (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $RecordingButtonName)))
    foreach ($w in Get-AppWindows) {
        $b = $w.FindFirst($Scope::Descendants, $btnCond)
        if ($b) { $script:AppWin = $w; return $b }
    }
    return $null
}

function Get-Text($el) {
    try { return $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value } catch { return $null }
}

# Wait for the transcript to land in the message box and stop changing, then press Enter.
function Send-Message {
    $box = $script:AppWin.FindFirst($Scope::Descendants,
        (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $ComposerName)))
    if (-not $box) { Log "! message box '$ComposerName' not found - not sending"; return }
    $deadline = (Get-Date).AddSeconds($SendTimeoutSec)
    $prev = $null; $since = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $txt = Get-Text $box
        if ($txt -ne $prev) { $prev = $txt; $since = Get-Date; continue }
        if ($txt -and $txt.Trim() -and ((Get-Date) - $since).TotalMilliseconds -ge $StableMs) { break }
    }
    if (-not ($prev -and $prev.Trim())) { Log 'nothing transcribed - not sending'; return }
    try {
        $box.SetFocus(); Start-Sleep -Milliseconds 150
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
        Log 'sent'   # the transcript itself is not logged
    } catch { Log "! send failed: $($_.Exception.Message)" }
}

function Wait-MicButton([int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do {
        $b = Get-MicButton
        if ($b) { return $b }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

# Open the app if its window is gone, and bring it back if minimized.
function Ensure-App {
    $wins = Get-AppWindows
    if ($wins.Count -eq 0) {
        $id = $AppId
        if (-not $id) { $id = (Get-StartApps | Where-Object { $_.Name -eq $WindowTitle } | Select-Object -First 1).AppID }
        if (-not $id) { Log "! '$WindowTitle' isn't open and its app ID wasn't found - pass -AppId"; return }
        Log "starting $WindowTitle"
        Start-Process explorer.exe "shell:AppsFolder\$id"
        [void](Wait-MicButton $LaunchTimeoutSec)
        return
    }
    foreach ($w in $wins) {
        try {
            $wp = $w.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
            if ($wp.Current.WindowVisualState -eq [System.Windows.Automation.WindowVisualState]::Minimized) {
                $wp.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
                Log "restored $WindowTitle from minimized"
                Start-Sleep -Milliseconds 800
            }
        } catch {}
    }
}

# Open the conversation named -SessionName from the sidebar.
function Switch-Session {
    $cond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, $CT::Button)),
        (New-Object System.Windows.Automation.PropertyCondition($UIA::NameProperty, $SessionName)))
    foreach ($w in Get-AppWindows) {
        $item = $w.FindFirst($Scope::Descendants, $cond)
        if ($item) {
            try {
                $item.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Start-Sleep -Milliseconds 700
                return $true
            } catch { Log "! couldn't open '$SessionName': $($_.Exception.Message)"; return $false }
        }
    }
    Log "! conversation '$SessionName' not in the sidebar (renamed, archived, or sidebar hidden?) - using the one on screen"
    return $false
}

function On-VoiceKey {
    if ($Mode -eq 'Hotkey') {
        try { [System.Windows.Forms.SendKeys]::SendWait($Hotkey); Log "sent hotkey $Hotkey" } catch { Log "! hotkey failed: $($_.Exception.Message)" }
        return
    }
    if ($LaunchApp) { Ensure-App }
    $b = Get-MicButton
    if (-not $b) { Log "! mic button not found - is '$WindowTitle' open? Check the names with -ListControls"; return }
    # Starting a recording: go to the fixed conversation first. (A stop press stays where the recording is.)
    if ($SessionName -and $b.Current.Name -ne $RecordingButtonName) {
        if (Switch-Session) { $b = Wait-MicButton 10 }
        if (-not $b) { Log '! mic button not found after switching conversation'; return }
    }
    try {
        $wasRecording = ($b.Current.Name -eq $RecordingButtonName)
        $b.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
        if ($wasRecording) { Log 'mic stopped'; if ($AutoSend) { Send-Message } } else { Log 'mic started' }
    } catch { Log "! toggle failed: $($_.Exception.Message)" }
}

if ($Mode -eq 'Button') { [void](Get-MicButton) }   # wakes Chromium's accessibility tree
$match = [regex]($LogPattern -f $KeyCode)
& $Adb connect $TvHost | Out-Null
Log "listening for key $KeyCode on $TvHost ($Mode mode). Ctrl+C to stop."
$last = [datetime]::MinValue

while ($true) {
    # -T 1: start from now rather than replaying the log
    & $Adb -s $TvHost logcat -T 1 -v brief "${LogTag}:D" '*:S' 2>$null | ForEach-Object {
        if ($match.IsMatch($_) -and ((Get-Date) - $last).TotalMilliseconds -gt $DebounceMs) {
            On-VoiceKey
            $last = Get-Date   # after handling: auto-send can block, and this press's key-up line waits behind it
        }
    }
    Log 'log stream ended (TV off or off the network?) - reconnecting in 5 s'
    Start-Sleep 5
    & $Adb connect $TvHost | Out-Null
}

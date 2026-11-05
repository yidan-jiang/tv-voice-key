# tv-voice-key

Press the voice key on your Android TV remote to talk to a desktop AI app on your Windows PC.
Press once to start voice input, press again to stop, and the message is sent.

Made for [Claude](https://claude.ai/download) desktop, and configurable for other apps that have a
mic button or a dictation shortcut (Codex, DeepSeek, ChatGPT and so on: see [Other apps](#other-apps)).
Built alongside a TV cleaned up with [cleanyourtv](https://github.com/Gathin23/cleanyourtv).

```
remote voice key -> TV logs the key -> adb logcat on the PC -> mic button in the app (UI Automation) -> Enter
```

**The PC's microphone does the listening.** The remote's mic sends its audio to the TV, and that audio
never reaches the PC, so sit within earshot of the PC.

## Requirements

- Windows 10 or 11 with Windows PowerShell 5.1 (built in)
- `adb` from Google's [platform-tools](https://developer.android.com/tools/releases/platform-tools)
- An Android TV with network debugging on, and this PC allowed once on the TV
- The app's window open (it can be behind other windows, not minimized)

## Use

```powershell
adb connect <tv-ip>:5555        # accept "Allow debugging" on the TV the first time
.\tv-voice-key.ps1 -TvHost <tv-ip>
```

It prints `mic started`, `mic stopped` and `sent` as you press, and writes the same lines to
`tv-voice-key.log` next to the script. The transcript itself is not logged.

Stop it with Ctrl+C. Only one copy runs at a time; a second one exits at once.

### Stop the TV's own assistant

The TV still opens its own assistant on the same key. To keep the key for the PC only, disable it
(Google TV / Android TV; reversible):

```powershell
adb -s <tv-ip>:5555 shell pm disable-user --user 0 com.google.android.katniss   # off
adb -s <tv-ip>:5555 shell pm enable com.google.android.katniss                 # back on
```

This also turns off Google voice search on the TV.

### Start with Windows

Make a shortcut in `shell:startup` (Win+R) with this target, and the bridge runs hidden at every
sign-in:

```
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\path\to\tv-voice-key.ps1" -TvHost <tv-ip>
```

## Settings

| Parameter | Default | What it does |
|---|---|---|
| `-TvHost` | `$env:TV_HOST` | TV address, `ip` or `ip:port` |
| `-Adb` | `adb` | Path to adb if it isn't on PATH |
| `-KeyCode` | `219` | The voice key's Android key code (219 ASSIST, 84 SEARCH, 231 VOICE_ASSIST) |
| `-LogTag`, `-LogPattern` | `WindowManager`, `interceptKeyTq keycode={0}\b` | How a key press shows up in the TV's log |
| `-Mode` | `Button` | `Button` toggles the app's mic button; `Hotkey` sends a shortcut |
| `-WindowTitle` | `Claude` | The app's window title |
| `-IdleButtonName`, `-RecordingButtonName` | `按住以录音`, `停止听写` | The mic button's name when idle and while recording (Claude, Chinese UI) |
| `-ComposerName` | `提示词` | The message box's name, for auto-send |
| `-AutoSend` | `$true` | Press Enter after the stop press |
| `-StableMs` | `1000` | How long the transcript must stay unchanged before sending |
| `-Hotkey` | | Hotkey mode: [SendKeys](https://learn.microsoft.com/dotnet/api/system.windows.forms.sendkeys) syntax, e.g. `^+{SPACE}` |
| `-ListControls` | | Print the window's buttons and text boxes, then exit |

### Your app is in another language

The names above are what Claude desktop shows in Chinese. In another language they differ: open the app,
run `.\tv-voice-key.ps1 -ListControls`, then start recording and run it again to see the button's
recording name. Pass the three names with `-IdleButtonName`, `-RecordingButtonName` and `-ComposerName`.

### Other apps

Any app works if it has either:

- a mic button that Windows UI Automation can toggle: find its names with
  `-ListControls -WindowTitle "<window title>"`, then run Button mode with them; or
- a keyboard shortcut that starts dictation: run
  `-Mode Hotkey -Hotkey "<shortcut>"`. The shortcut goes to the window in front, so either the app's shortcut
  is global or the app has to be in front. Auto-send is Button mode only.

Only Claude desktop has been tested. If you get another app working, a pull request with its settings is
welcome.

### Your TV logs the key differently

The default `-LogPattern` matches what Xiaomi's firmware logs. To find yours, run
`adb -s <tv-ip>:5555 logcat -T 1 | findstr /i "keycode"`, press the voice key, and set `-KeyCode`,
`-LogTag` and `-LogPattern` from the line that appears.

## Tested on

- Xiaomi MiTV-MOOQ1, Android TV 10, with its Bluetooth voice remote (key 219)
- Claude desktop on Windows 11, Chinese UI

## Privacy and safety

- Nothing leaves your home network: the script talks only to the TV over ADB and to the app on this PC.
- Network debugging has to stay on for this to work. Anyone on your network whose PC you have allowed on the
  TV can control it, so allow only your own computers.
- Speech goes to the app you point it at, exactly as if you had clicked its mic.

## Licence

[MIT](LICENSE)

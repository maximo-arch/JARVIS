# J.A.R.V.I.S.

A voice-and-text desktop assistant for Linux that can control your mouse, keyboard and terminal, look at your
screen, and talk back. It runs on free OpenRouter models and ships with a Material You popup built on
[Quickshell](https://quickshell.org) (frosted glass on Hyprland).

> ⚠️ **Security:** the agent runs shell commands and drives your mouse and keyboard **without asking for confirmation**.
> A small blocklist stops obviously destructive commands (`rm -rf /`, `mkfs`, `shutdown`...), nothing more.
> Use it only on a machine you control, and never commit your `.env`.

## Features
- Terminal mode and a popup UI (compact bar that expands into a full window).
- Mouse and keyboard control on Wayland (Hyprland via `hyprctl` + `ydotool` + `wtype`) and X11 (`pyautogui`).
- `look_at_screen`: screenshot + vision model to find things on screen.
- Voice output (edge-tts) and voice input (Groq Whisper, or offline faster-whisper).
- Popup colors follow your Caelestia / Material You scheme (`~/.local/state/caelestia/scheme.json`).

## Install
```bash
git clone https://github.com/maximo-arch/JARVIS.git
cd JARVIS
bash install.sh
```
The installer copies the app to `~/JARVIS`, creates a venv, asks for **your own** OpenRouter API key
(free at <https://openrouter.ai/keys>) and stores it in `~/JARVIS/.env` (permissions `600`).
It also installs three commands into `~/.local/bin`: `jarvis`, `jarvis-bridge` and `jarvis-ui`.

Requirements: Python 3.10+, `grim`, `wtype`, `ydotool` (with its service running), `mpg123`, PortAudio,
and Quickshell for the popup.

## Use
- `jarvis` — terminal mode. Press Enter on an empty line to speak, `/voice` for hands-free.
- `jarvis-ui` — starts the bridge + popup if needed and toggles it. Also: `jarvis-ui full` opens the full window.

Bind it to a key. Hyprland (Lua config):
```lua
hl.bind("SUPER + SHIFT + J", hl.dsp.exec_cmd("jarvis-ui"))
```
Hyprland (classic config): `bind = SUPER SHIFT, J, exec, jarvis-ui`

**Frosted glass:** the popup's layer namespace is `quickshell:jarvis`. Add a blur layer rule for it
(or match `.*quickshell.*`).

## Configuration (`~/JARVIS/.env`)
| Variable | Meaning |
| --- | --- |
| `OPENROUTER_API_KEY` | Your OpenRouter key (required) |
| `JARVIS_MODEL` | Main model (default `nvidia/nemotron-3-ultra-550b-a55b:free`) |
| `JARVIS_VISION_MODEL` | Model used by `look_at_screen` |
| `GROQ_API_KEY` | Optional, enables Groq Whisper for voice input |
| `JARVIS_STT_PYTHON` | Optional, Python with `faster-whisper` for offline voice input |
| `JARVIS_STT_LANGUAGE` | e.g. `en`, `es` |
| `JARVIS_REASONING` | `none` (fast, default) / `low` / `high` / `default` |

Free models change often; if one disappears, set another id in `.env`.

## Uninstall
```bash
rm -rf ~/JARVIS ~/.config/quickshell/jarvis ~/.local/bin/jarvis ~/.local/bin/jarvis-bridge ~/.local/bin/jarvis-ui
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE): free to use, modify and share for non-commercial purposes. Commercial use requires my written permission.

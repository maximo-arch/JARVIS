#!/usr/bin/env bash
# J.A.R.V.I.S. installer
# Copies the app to ~/JARVIS, builds a Python venv, stores YOUR API key in ~/JARVIS/.env
# and installs the launchers `jarvis`, `jarvis-bridge` and `jarvis-ui` into ~/.local/bin.
#
# Options (environment variables):
#   JARVIS_DIR=/path            install somewhere else (default: ~/JARVIS)
#   OPENROUTER_API_KEY=...      skip the key prompt
#   GROQ_API_KEY=...            optional key for voice input
#   SKIP_SYSTEM_PACKAGES=1      don't try to install system packages
set -euo pipefail

INSTALL_DIR="${JARVIS_DIR:-$HOME/JARVIS}"
QS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/jarvis"
BIN_DIR="$HOME/.local/bin"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
yn() {  # yn "question" Y|N   (default answer is the 2nd argument)
    local def="$2" hint r
    [[ $def == Y ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "$1 $hint " r || true
    r="${r:-$def}"
    [[ $r =~ ^[Yy] ]]
}

for f in JARVIS.py jarvis_bridge.py shell.qml; do
    [[ -f "$SRC/$f" ]] || { warn "Missing $f next to install.sh"; exit 1; }
done
command -v python3 >/dev/null || { warn "python3 is required"; exit 1; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || { warn "Python 3.10 or newer is required"; exit 1; }

# --- 1. System packages -------------------------------------------------------
if [[ -z "${SKIP_SYSTEM_PACKAGES:-}" ]]; then
    say "Checking system packages (grim, wtype, ydotool, mpg123, portaudio)"
    if command -v pacman >/dev/null; then
        missing="$(pacman -T grim wtype ydotool mpg123 portaudio || true)"
        if [[ -n "$missing" ]] && yn "Install missing packages with sudo? ($(echo $missing))" Y; then
            sudo pacman -S --needed $missing
        fi
    elif command -v apt-get >/dev/null; then
        missing=""
        for p in grim wtype ydotool mpg123 libportaudio2; do
            dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"
        done
        if [[ -n "$missing" ]] && yn "Install missing packages with sudo?($missing)" Y; then
            sudo apt-get install -y $missing
        fi
    else
        warn "Unknown package manager. Install manually: grim wtype ydotool mpg123 portaudio"
    fi
    if command -v systemctl >/dev/null && systemctl --user list-unit-files ydotool.service 2>/dev/null | grep -q ydotool; then
        systemctl --user enable --now ydotool || warn "Could not start the ydotool service"
    fi
fi

# --- 2. Files + virtualenv ----------------------------------------------------
say "Installing to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$QS_DIR" "$BIN_DIR"
if [[ "$SRC" != "$INSTALL_DIR" ]]; then
    install -m 644 "$SRC/JARVIS.py" "$SRC/jarvis_bridge.py" "$INSTALL_DIR/"
fi
install -m 644 "$SRC/shell.qml" "$QS_DIR/shell.qml"

say "Creating Python environment and installing dependencies"
[[ -x "$INSTALL_DIR/.venv/bin/python" ]] || python3 -m venv "$INSTALL_DIR/.venv"
"$INSTALL_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$INSTALL_DIR/.venv/bin/pip" install --quiet edge-tts openai pillow numpy sounddevice

# --- 3. API keys -> ~/JARVIS/.env (chmod 600) ---------------------------------
ENV_FILE="$INSTALL_DIR/.env"
write_env=1
if [[ -f "$ENV_FILE" ]] && ! yn ".env already exists. Overwrite it?" N; then
    write_env=0
    say "Keeping your existing .env"
fi
if [[ $write_env == 1 ]]; then
    KEY="${OPENROUTER_API_KEY:-}"
    if [[ -z "$KEY" ]]; then
        echo "Create your own free key at https://openrouter.ai/keys"
        read -rsp "OpenRouter API key (hidden; press Enter to add it later): " KEY || true
        echo
    fi
    GROQ="${GROQ_API_KEY:-}"
    if [[ -z "$GROQ" ]]; then
        read -rsp "Groq API key for voice input (optional, hidden; Enter to skip): " GROQ || true
        echo
    fi
    STT_PY=""
    if command -v uv >/dev/null && yn "Set up offline speech-to-text (faster-whisper in a Python 3.12 env via uv)?" N; then
        uv venv --python 3.12 "$INSTALL_DIR/.stt-venv"
        uv pip install --python "$INSTALL_DIR/.stt-venv/bin/python" faster-whisper
        STT_PY="$INSTALL_DIR/.stt-venv/bin/python"
    fi
    (
        umask 077
        {
            echo "# J.A.R.V.I.S. settings. Never commit or share this file."
            echo "OPENROUTER_API_KEY=$KEY"
            if [[ -n "$GROQ" ]]; then echo "GROQ_API_KEY=$GROQ"; fi
            if [[ -n "$STT_PY" ]]; then echo "JARVIS_STT_PYTHON=$STT_PY"; fi
            echo "# JARVIS_MODEL=nvidia/nemotron-3.5-lightning:free"
            echo "# JARVIS_STT_LANGUAGE=en"
        } > "$ENV_FILE"
    )
    chmod 600 "$ENV_FILE"
    [[ -n "$KEY" ]] || warn "No OpenRouter key saved. Edit $ENV_FILE before running."
fi

# --- 4. Launchers -------------------------------------------------------------
say "Installing launchers into $BIN_DIR"
cat > "$BIN_DIR/jarvis" <<'EOF'
#!/usr/bin/env bash
exec "@DIR@/.venv/bin/python" "@DIR@/JARVIS.py" "$@"
EOF
cat > "$BIN_DIR/jarvis-bridge" <<'EOF'
#!/usr/bin/env bash
exec "@DIR@/.venv/bin/python" "@DIR@/jarvis_bridge.py" "$@"
EOF
cat > "$BIN_DIR/jarvis-ui" <<'EOF'
#!/usr/bin/env bash
# Starts the bridge and the popup if needed, then toggles it. Usage: jarvis-ui [toggle|show|hide|full]
started=0
if ! pgrep -f jarvis_bridge.py >/dev/null; then
    nohup "@DIR@/.venv/bin/python" "@DIR@/jarvis_bridge.py" >"@DIR@/bridge.log" 2>&1 &
    started=1
fi
if ! pgrep -f "qs -c jarvis" >/dev/null; then
    nohup qs -c jarvis >/dev/null 2>&1 &
    started=1
fi
[ "$started" = 1 ] && sleep 2
exec qs -c jarvis ipc call jarvis "${1:-toggle}"
EOF
sed -i "s|@DIR@|$INSTALL_DIR|g" "$BIN_DIR/jarvis" "$BIN_DIR/jarvis-bridge" "$BIN_DIR/jarvis-ui"
chmod +x "$BIN_DIR/jarvis" "$BIN_DIR/jarvis-bridge" "$BIN_DIR/jarvis-ui"

say "Done!"
cat <<EOF

  Terminal mode : jarvis
  Popup UI      : jarvis-ui        (bind it to a key, see README)
  Settings/keys : $ENV_FILE

If 'jarvis' is not found, add ~/.local/bin to your PATH
  bash/zsh: export PATH="\$HOME/.local/bin:\$PATH"
  fish    : fish_add_path ~/.local/bin
EOF

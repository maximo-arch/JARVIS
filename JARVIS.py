import asyncio
import base64
import io
import os
import re
import json
import shutil
import subprocess
import tempfile
import threading
import time

import edge_tts
from openai import BadRequestError, OpenAI

def _load_dotenv():
    """Lee un archivo .env junto a este script (sin pisar variables ya definidas)."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_dotenv()

# --- Core System Configuration ---
# La clave va en una variable de entorno, NO en el código:
#   (o ponela en un archivo .env junto a este script: OPENROUTER_API_KEY=...)
OPENROUTER_KEY = os.environ.get("OPENROUTER_API_KEY")
if not OPENROUTER_KEY:
    raise SystemExit("OPENROUTER_API_KEY is missing. Put it in the .env file next to JARVIS.py (see README).")

VOICE_NAME = "en-GB-RyanNeural"
MODEL_ID = os.environ.get("JARVIS_MODEL", "nvidia/nemotron-3-ultra-550b-a55b:free")
# Esfuerzo de "razonamiento" del modelo: "none" = más rápido; "low"/"medium"/"high" = piensa más (más lento);
# "default" = no enviar el parámetro
REASONING = os.environ.get("JARVIS_REASONING", "none").lower()
CHAT_TIMEOUT = float(os.environ.get("JARVIS_TIMEOUT", "90"))  # segundos por llamada al modelo

# Modelo con visión para look_at_screen (los modelos gratis rotan; cambialo con la variable de entorno)
# Nemotron 3 Ultra es solo texto; su hermano "Nano Omni" (gratis) entiende imágenes y audio con la misma key
OMNI_MODEL_ID = "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free"
VISION_MODEL_ID = os.environ.get("JARVIS_VISION_MODEL", OMNI_MODEL_ID)
# Voz -> texto (faster-whisper local): tiny / base / small / medium
WHISPER_MODEL = os.environ.get("JARVIS_WHISPER_MODEL", "small")
STT_LANGUAGE = os.environ.get("JARVIS_STT_LANGUAGE") or None  # ej: "es" o "en"; None = autodetectar
# Voz -> texto en la nube con Groq (funciona en Python 3.14). Si GROQ_API_KEY está definida, se usa en vez del modelo local.
GROQ_KEY = os.environ.get("GROQ_API_KEY")
GROQ_STT_MODEL = os.environ.get("JARVIS_GROQ_STT_MODEL", "whisper-large-v3-turbo")
# Python (ej. de un venv 3.12) que tenga faster-whisper instalado: voz->texto local, gratis y sin cuentas
STT_PYTHON = os.path.expanduser(os.environ.get("JARVIS_STT_PYTHON") or "") or None  # acepta rutas con ~
# Backend de voz->texto: "groq", "subprocess" (local vía STT_PYTHON), "local" (faster-whisper en este mismo Python)
# o "omni" (OpenRouter: NO es gratis, exige >= $0.50 de saldo para audio).
STT_BACKEND = (
    os.environ.get("JARVIS_STT") or ("groq" if GROQ_KEY else "subprocess" if STT_PYTHON else "none")
).lower()
MIC_THRESHOLD = 0.012      # sensibilidad del micrófono (subila si hay ruido de fondo)
SCROLL_INVERT = False      # ponelo en True si el scroll va al revés

# Máximo de caracteres que se pronuncian (el texto completo siempre se imprime)
MAX_SPOKEN_CHARS = 350
# Pedir confirmación antes de mover mouse / escribir (en Wayland no hay failsafe)
REQUIRE_INPUT_CONFIRMATION = False
# Pedir confirmación antes de ejecutar comandos de terminal
REQUIRE_COMMAND_CONFIRMATION = False

llm = OpenAI(
    base_url="https://openrouter.ai/api/v1",
    api_key=OPENROUTER_KEY,
    timeout=30.0,
)

# --- Detección de entorno gráfico ---
IS_WAYLAND = (
    os.environ.get("XDG_SESSION_TYPE", "").lower() == "wayland"
    or bool(os.environ.get("WAYLAND_DISPLAY"))
)

pyautogui = None
if not IS_WAYLAND:
    try:
        import pyautogui  # solo funciona en X11
        pyautogui.FAILSAFE = True  # mouse a una esquina = abortar
    except Exception:
        pyautogui = None


# =====================================================================
#  VOZ (no bloqueante, interrumpible, con límite de longitud)
# =====================================================================
_speech_lock = threading.Lock()
_speech_proc = None
_speech_id = 0


def clean_for_speech(text):
    """Quita markdown, código, URLs y emojis; recorta a MAX_SPOKEN_CHARS por oraciones."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"^\s*[-•*]\s+", "", text, flags=re.M)
    text = re.sub(r"[*_#>~|\[\]]", "", text)
    text = re.sub(r"[\U00010000-\U0010ffff\u2600-\u27bf]", "", text)
    text = re.sub(r"\s+", " ", text).strip()

    if len(text) <= MAX_SPOKEN_CHARS:
        return text
    sentences = re.split(r"(?<=[.!?])\s+", text)
    out = ""
    for s in sentences:
        if len(out) + len(s) > MAX_SPOKEN_CHARS:
            break
        out += s + " "
    return out.strip() or text[:MAX_SPOKEN_CHARS]


def stop_speech():
    """Corta cualquier audio en reproducción."""
    global _speech_proc, _speech_id
    with _speech_lock:
        _speech_id += 1
        if _speech_proc and _speech_proc.poll() is None:
            _speech_proc.terminate()
            try:
                _speech_proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                _speech_proc.kill()
        _speech_proc = None


def _player_cmd(path):
    if shutil.which("mpg123"):
        return ["mpg123", "-q", path]
    if shutil.which("mpv"):
        return ["mpv", "--no-video", "--really-quiet", path]
    if shutil.which("ffplay"):
        return ["ffplay", "-nodisp", "-autoexit", "-hide_banner", "-loglevel", "quiet", path]
    return None


def _speak_worker(text, my_id):
    global _speech_proc
    fd, path = tempfile.mkstemp(suffix=".mp3", prefix="jarvis_")
    os.close(fd)
    try:
        async def synth():
            await asyncio.wait_for(edge_tts.Communicate(text, VOICE_NAME).save(path), timeout=20)

        asyncio.run(synth())

        cmd = _player_cmd(path)
        if not cmd:
            return
        with _speech_lock:
            if my_id != _speech_id:  # ya lo cancelaron
                return
            _speech_proc = subprocess.Popen(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            proc = _speech_proc
        try:
            proc.wait(timeout=120)  # tope de seguridad
        except subprocess.TimeoutExpired:
            proc.kill()
    except Exception:
        pass
    finally:
        if os.path.exists(path):
            os.remove(path)


def speak(text, block=False):
    """Habla en segundo plano para que el prompt vuelva de inmediato."""
    global _speech_id
    clean = clean_for_speech(text)
    if not clean:
        return
    stop_speech()
    with _speech_lock:
        my_id = _speech_id
    t = threading.Thread(target=_speak_worker, args=(clean, my_id), daemon=True)
    t.start()
    if block:
        t.join()


# =====================================================================
#  HELPERS
# =====================================================================
def _run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, (r.stdout or r.stderr).strip()
    except FileNotFoundError:
        return False, f"Comando no instalado: {cmd[0]}"
    except Exception as e:
        return False, str(e)


def _confirm(msg):
    if not REQUIRE_INPUT_CONFIRMATION:
        return True
    return input(f"{msg} Authorize? (y/n): ").strip().lower() == "y"


# Códigos de tecla de Linux (input-event-codes) para ydotool
_KEYCODES = {
    "esc": 1, "escape": 1, "tab": 15, "enter": 28, "return": 28, "space": 57,
    "backspace": 14, "delete": 111, "insert": 110,
    "up": 103, "down": 108, "left": 105, "right": 106,
    "home": 102, "end": 107, "pageup": 104, "pagedown": 109,
    "ctrl": 29, "control": 29, "shift": 42, "alt": 56,
    "win": 125, "super": 125, "meta": 125, "windows": 125,
    "-": 12, "=": 13, ",": 51, ".": 52, "/": 53, ";": 39,
}
for _i, _c in enumerate("1234567890"):
    _KEYCODES[_c] = 2 + _i
for _c, _code in zip("qwertyuiop", range(16, 26)):
    _KEYCODES[_c] = _code
for _c, _code in zip("asdfghjkl", range(30, 39)):
    _KEYCODES[_c] = _code
for _c, _code in zip("zxcvbnm", range(44, 51)):
    _KEYCODES[_c] = _code
for _i in range(1, 11):
    _KEYCODES[f"f{_i}"] = 58 + _i
_KEYCODES["f11"] = 87
_KEYCODES["f12"] = 88

_MOUSE_CODES = {"click": "0xC0", "right_click": "0xC1", "middle_click": "0xC2"}


# =====================================================================
#  MOUSE
# =====================================================================
def _hypr_cursorpos():
    ok, out = _run(["hyprctl", "cursorpos"])
    if not ok:
        return None
    try:
        cx, cy = [int(float(v)) for v in out.replace(" ", "").split(",")]
        return cx, cy
    except ValueError:
        return None


def _wl_move(x, y):
    """Mueve el cursor en Wayland y verifica que llegó."""
    if shutil.which("hyprctl"):
        for expr in (
            f"hl.dsp.cursor.move({{ x = {x}, y = {y} }})",  # sintaxis Lua (Hyprland 0.55+)
            f"movecursor {x} {y}",                          # sintaxis vieja
        ):
            _run(["hyprctl", "dispatch", expr])
            pos = _hypr_cursorpos()
            if pos and abs(pos[0] - x) <= 3 and abs(pos[1] - y) <= 3:
                return True, f"hyprctl -> {pos}"

    # Fallback: ir a la esquina (0,0) y mover relativo desde ahí
    _run(["ydotool", "mousemove", "-x", "-10000", "-y", "-10000"])
    ok, out = _run(["ydotool", "mousemove", "-x", str(x), "-y", str(y)])
    return ok, out or "ydotool"


def _wl_nudge():
    """Genera un movimiento real del puntero para que Hyprland actualice el foco antes del clic."""
    _run(["ydotool", "mousemove", "-x", "1", "-y", "0"])
    time.sleep(0.05)
    _run(["ydotool", "mousemove", "-x", "-1", "-y", "0"])
    time.sleep(0.05)


def _wl_screen_info():
    pos = _hypr_cursorpos()
    info = f"Cursor at {pos}." if pos else "Cursor position unavailable."
    ok, out = _run(["hyprctl", "monitors", "-j"])
    if ok:
        try:
            mons = json.loads(out)
            desc = "; ".join(
                f"{m['name']}: {int(m['width'] / (m.get('scale') or 1))}x"
                f"{int(m['height'] / (m.get('scale') or 1))} at ({m['x']},{m['y']})"
                for m in mons
            )
            info += " Monitors (logical px): " + desc
        except Exception:
            pass
    return info


def manipulate_mouse(action, x=None, y=None, dx=None, dy=None, amount=None, to_x=None, to_y=None):
    """Controla mouse: move, click, right_click, double_click."""
    print(f"\n[ATTENTION: Requesting mouse control - Action: {action}, x={x}, y={y}]")
    if action != "get_position" and not _confirm("Mouse control."):
        return "Mouse action denied by user."

    try:
        if IS_WAYLAND:
            if action == "scroll":
                n = int(amount) if amount is not None else 3  # positivo = abajo, negativo = arriba
                if x is not None and y is not None:
                    _wl_move(x, y)
                    _wl_nudge()
                wheel = n if SCROLL_INVERT else -n  # en ydotool, rueda positiva = arriba
                ok, out = _run(["ydotool", "mousemove", "--wheel", "-x", "0", "-y", str(wheel)])
                return f"Scrolled {'down' if n > 0 else 'up'} by {abs(n)}." if ok else f"Scroll failed: {out}"

            if action == "drag":
                if to_x is None or to_y is None:
                    return "Missing to_x/to_y."
                if x is not None and y is not None:
                    _wl_move(x, y)
                _wl_nudge()
                start = _hypr_cursorpos()
                if not start:
                    return "Drag failed: cannot read the cursor position."
                ok, out = _run(["ydotool", "click", "0x40"])  # botón izquierdo abajo
                if not ok:
                    return f"Drag failed: {out}"
                try:
                    px, py = start
                    steps = 20
                    for i in range(1, steps + 1):
                        tx = round(start[0] + (to_x - start[0]) * i / steps)
                        ty = round(start[1] + (to_y - start[1]) * i / steps)
                        if tx != px or ty != py:
                            _run(["ydotool", "mousemove", "-x", str(tx - px), "-y", str(ty - py)])
                            px, py = tx, ty
                        time.sleep(0.02)
                finally:
                    time.sleep(0.1)
                    _run(["ydotool", "click", "0x80"])  # botón izquierdo arriba
                return f"Dragged from {start} to ({to_x}, {to_y})."

            if action == "get_position":
                return _wl_screen_info()

            if action == "move_relative":
                if dx is None or dy is None:
                    return "Missing dx/dy."
                pos = _hypr_cursorpos()
                if pos:
                    ok, out = _wl_move(pos[0] + dx, pos[1] + dy)
                else:
                    ok, out = _run(["ydotool", "mousemove", "-x", str(dx), "-y", str(dy)])
                return f"Mouse moved by ({dx}, {dy})." if ok else f"Move failed: {out}"

            if action == "move":
                if x is None or y is None:
                    return "Missing x/y coordinates."
                ok, out = _wl_move(x, y)
                return f"Mouse moved to ({x}, {y})." if ok else f"Move failed: {out}"

            if action in ("click", "right_click", "double_click"):
                if x is not None and y is not None:
                    _wl_move(x, y)
                _wl_nudge()
                code = _MOUSE_CODES["right_click" if action == "right_click" else "click"]
                clicks = 2 if action == "double_click" else 1
                for i in range(clicks):
                    ok, out = _run(["ydotool", "click", code])
                    if not ok:
                        return f"{action} failed: {out}"
                    if i < clicks - 1:
                        time.sleep(0.08)
                return f"{action} executed."

            return "Unrecognized mouse command."

        # X11
        if pyautogui is None:
            return "pyautogui no disponible en esta sesión."
        if action == "scroll":
            n = int(amount) if amount is not None else 3
            if x is not None and y is not None:
                pyautogui.moveTo(x, y)
            pyautogui.scroll(n if SCROLL_INVERT else -n)
            return f"Scrolled {'down' if n > 0 else 'up'} by {abs(n)}."
        if action == "drag" and to_x is not None and to_y is not None:
            if x is not None and y is not None:
                pyautogui.moveTo(x, y)
            pyautogui.dragTo(to_x, to_y, duration=0.6, button="left")
            return f"Dragged to ({to_x}, {to_y})."
        if action == "get_position":
            px, py = pyautogui.position()
            sw, sh = pyautogui.size()
            return f"Cursor at ({px}, {py}); screen {sw}x{sh}."
        if action == "move_relative" and dx is not None and dy is not None:
            pyautogui.moveRel(dx, dy, duration=0.3)
            return f"Mouse moved by ({dx}, {dy})."
        if action == "move" and x is not None and y is not None:
            pyautogui.moveTo(x, y, duration=0.5)
            return f"Mouse moved to ({x}, {y})."
        if action == "click":
            pyautogui.click()
            return "Left click executed."
        if action == "right_click":
            pyautogui.rightClick()
            return "Right click executed."
        if action == "double_click":
            pyautogui.doubleClick()
            return "Double click executed."
        return "Unrecognized mouse command or missing coordinates."
    except Exception as e:
        return f"Mouse manipulation failed: {e}"


# =====================================================================
#  TECLADO
# =====================================================================
def _wl_press(combo):
    """Presiona una tecla o combinación (ej: 'ctrl+t', 'enter', 'super') vía ydotool."""
    parts = [p.strip().lower() for p in combo.split("+") if p.strip()]
    codes = []
    for p in parts:
        if p not in _KEYCODES:
            return False, f"Tecla desconocida: '{p}'"
        codes.append(_KEYCODES[p])
    seq = [f"{c}:1" for c in codes] + [f"{c}:0" for c in reversed(codes)]
    return _run(["ydotool", "key", *seq])


def manipulate_keyboard(text, action="type"):
    """Escribe texto (type) o presiona teclas/combinaciones (press)."""
    print(f"\n[ATTENTION: Requesting keyboard control - Action: {action}, Text: '{text}']")
    if not _confirm("Keyboard control."):
        return "Keyboard action denied by user."

    try:
        if IS_WAYLAND:
            if action == "type":
                if shutil.which("wtype"):  # respeta acentos/ñ y layouts no-US
                    ok, out = _run(["wtype", "-d", "10", "--", text], timeout=30)
                else:
                    ok, out = _run(["ydotool", "type", "-d", "20", "--", text], timeout=30)
                return f"Text typed: '{text}'" if ok else f"Typing failed: {out}"
            if action == "press":
                ok, out = _wl_press(text)
                return f"Key '{text}' pressed." if ok else f"Key press failed: {out}"
            return "Unrecognized keyboard command."

        # X11
        if pyautogui is None:
            return "pyautogui no disponible en esta sesión."
        if action == "type":
            pyautogui.write(text, interval=0.02)
            return f"Text typed: '{text}'"
        if action == "press":
            keys = [k.strip().lower() for k in text.split("+")]
            if len(keys) > 1:
                pyautogui.hotkey(*keys)
            else:
                pyautogui.press(keys[0])
            return f"Key '{text}' pressed."
        return "Unrecognized keyboard command."
    except Exception as e:
        return f"Keyboard manipulation failed: {e}"


# =====================================================================
#  TERMINAL
# =====================================================================
_DANGEROUS = re.compile(
    r"\brm\s+-[a-z]*r[a-z]*\s+(/|~|\$HOME)(\s|$)|\bmkfs\b|\bdd\s+if=|:\(\)\s*\{|>\s*/dev/(sd|nvme)|"
    r"\b(shutdown|reboot|poweroff|halt)\b|chmod\s+-R\s+\d+\s+/(\s|$)",
    re.I,
)


def execute_terminal_command(command):
    """Ejecuta comandos bash tras autorización explícita."""
    print(f"\n[EXEC] {command}")
    if _DANGEROUS.search(command or ""):
        return "Blocked: the command looks destructive."
    if REQUIRE_COMMAND_CONFIRMATION and input("Authorize execution? (y/n): ").strip().lower() != "y":
        return "Execution denied by user."
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=15)
        return (result.stdout or result.stderr or "(sin salida)")[:4000]
    except Exception as e:
        return str(e)


# =====================================================================
#  VISIÓN (captura de pantalla -> modelo con visión)
# =====================================================================
def _draw_grid(img):
    """Dibuja una grilla roja cada 100 px con las coordenadas reales en los bordes."""
    from PIL import Image, ImageDraw, ImageFont

    W, H = img.size
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    try:
        font = ImageFont.load_default(size=14)
    except TypeError:
        font = ImageFont.load_default()
    for gx in range(0, W, 100):
        d.line([(gx, 0), (gx, H)], fill=(255, 0, 0, 70), width=1)
        d.text((gx + 3, 2), str(gx), fill=(255, 255, 0, 255), font=font, stroke_width=2, stroke_fill=(0, 0, 0, 255))
    for gy in range(0, H, 100):
        d.line([(0, gy), (W, gy)], fill=(255, 0, 0, 70), width=1)
        d.text((2, gy + 2), str(gy), fill=(255, 255, 0, 255), font=font, stroke_width=2, stroke_fill=(0, 0, 0, 255))
    return Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")


def take_screenshot():
    """Devuelve (jpeg_bytes, ancho, alto) en píxeles lógicos, con grilla de coordenadas."""
    from PIL import Image

    fd, path = tempfile.mkstemp(suffix=".png", prefix="jarvis_shot_")
    os.close(fd)
    try:
        if IS_WAYLAND:
            if not shutil.which("grim"):
                raise RuntimeError("falta 'grim' (sudo pacman -S grim)")
            ok, out = _run(["grim", "-s", "1", path], timeout=15)  # -s 1 = píxeles lógicos
            if not ok:
                raise RuntimeError(out)
        else:
            if pyautogui is None:
                raise RuntimeError("pyautogui no disponible")
            pyautogui.screenshot(path)
        img = Image.open(path).convert("RGB")
        W, H = img.size
        img = _draw_grid(img)
        if W > 1600:  # achicar para que el envío sea liviano (las etiquetas siguen en coordenadas reales)
            img = img.resize((1600, round(H * 1600 / W)))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=80)
        return buf.getvalue(), W, H
    finally:
        if os.path.exists(path):
            os.remove(path)


def look_at_screen(question="Describe what is on the screen."):
    """Captura la pantalla y se la muestra a un modelo con visión; devuelve su respuesta en texto."""
    try:
        jpg, W, H = take_screenshot()
    except ImportError:
        return "Vision unavailable: Pillow is not installed (pip install pillow)."
    except Exception as e:
        return f"Screenshot failed: {e}"

    b64 = base64.b64encode(jpg).decode()
    prompt = (
        f"This is a screenshot of the user's desktop ({W}x{H} px). A red grid is drawn every 100 px, "
        "with the real pixel coordinates labeled along the top and left edges. "
        f"{question}\n"
        "Answer concisely. For any clickable element, give the approximate CENTER (x, y) in real screen pixels."
    )
    try:
        r = llm.chat.completions.create(
            model=VISION_MODEL_ID,
            messages=[{
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}},
                ],
            }],
            timeout=60,
        )
        text = r.choices[0].message.content if r and r.choices else None
        return text or "The vision model returned nothing."
    except Exception as e:
        return f"Vision request failed: {e}"


# =====================================================================
#  ENTRADA POR VOZ (micrófono -> faster-whisper local)
# =====================================================================
_whisper = None


def _load_whisper():
    global _whisper
    if _whisper is None:
        from faster_whisper import WhisperModel

        print("[loading speech model, first time only...]")
        _whisper = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8")
    return _whisper


def _wav_bytes(audio):
    import wave

    import numpy as np

    pcm = (np.clip(audio, -1.0, 1.0) * 32767).astype("int16")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm.tobytes())
    return buf.getvalue()


def _check_stt_backend():
    if STT_BACKEND == "none":
        raise ImportError(
            "no free speech-to-text configured. Set GROQ_API_KEY (free Groq key) "
            "or JARVIS_STT_PYTHON (a Python 3.12 venv with faster-whisper)."
        )
    if STT_BACKEND == "subprocess" and not (STT_PYTHON and os.path.exists(STT_PYTHON)):
        raise ImportError("JARVIS_STT_PYTHON does not point to an existing Python.")
    if STT_BACKEND == "groq" and not GROQ_KEY:
        raise ImportError("JARVIS_STT=groq but GROQ_API_KEY is not set.")
    if STT_BACKEND == "local":
        try:
            import faster_whisper  # noqa: F401
        except ImportError:
            raise ImportError("faster-whisper is not installed (it needs Python 3.13 or older).")


def _transcribe_omni(audio):
    """Transcribe con Nemotron 3 Nano Omni (gratis) por OpenRouter."""
    b64 = base64.b64encode(_wav_bytes(audio)).decode()
    lang = f" The speech is in {STT_LANGUAGE}." if STT_LANGUAGE else ""
    r = llm.chat.completions.create(
        model=OMNI_MODEL_ID,
        messages=[{
            "role": "user",
            "content": [
                {
                    "type": "text",
                    "text": "Transcribe this audio exactly as spoken." + lang +
                            " Reply with ONLY the transcription, nothing else. "
                            "If there is no speech, reply with an empty string.",
                },
                {"type": "input_audio", "input_audio": {"data": b64, "format": "wav"}},
            ],
        }],
        timeout=60,
    )
    text = r.choices[0].message.content if r and r.choices else ""
    return (text or "").strip().strip('"')


def _transcribe_groq(audio):
    client = OpenAI(base_url="https://api.groq.com/openai/v1", api_key=GROQ_KEY, timeout=30.0)
    kwargs = {"model": GROQ_STT_MODEL, "file": ("speech.wav", _wav_bytes(audio), "audio/wav")}
    if STT_LANGUAGE:
        kwargs["language"] = STT_LANGUAGE
    return (client.audio.transcriptions.create(**kwargs).text or "").strip()


def _transcribe_local(audio):
    model = _load_whisper()
    segments, _ = model.transcribe(audio, language=STT_LANGUAGE, vad_filter=True, beam_size=1)
    return " ".join(seg.text.strip() for seg in segments).strip()


_STT_WORKER = r"""
import sys
from faster_whisper import WhisperModel
path, model_name, lang = sys.argv[1], sys.argv[2], sys.argv[3] or None
m = WhisperModel(model_name, device="cpu", compute_type="int8")
segs, _ = m.transcribe(path, language=lang, vad_filter=True, beam_size=1)
print(" ".join(s.text.strip() for s in segs).strip())
"""


def _transcribe_subprocess(audio):
    """Transcribe con faster-whisper corriendo en OTRO Python (ej. 3.12), así este script sigue en 3.14."""
    fd, path = tempfile.mkstemp(suffix=".wav", prefix="jarvis_stt_")
    os.close(fd)
    try:
        with open(path, "wb") as f:
            f.write(_wav_bytes(audio))
        r = subprocess.run(
            [STT_PYTHON, "-c", _STT_WORKER, path, WHISPER_MODEL, STT_LANGUAGE or ""],
            capture_output=True, text=True, timeout=180,  # la primera vez descarga el modelo
        )
        if r.returncode != 0:
            raise RuntimeError((r.stderr or "worker failed").strip()[-300:])
        return r.stdout.strip()
    finally:
        if os.path.exists(path):
            os.remove(path)


def _transcribe(audio):
    try:
        if STT_BACKEND == "groq":
            return _transcribe_groq(audio)
        if STT_BACKEND == "subprocess":
            return _transcribe_subprocess(audio)
        if STT_BACKEND == "local":
            return _transcribe_local(audio)
        if STT_BACKEND == "omni":
            return _transcribe_omni(audio)
        return ""
    except Exception as e:
        print(f"[transcription failed ({STT_BACKEND}): {e}]")
        return ""


def listen(max_seconds=20, silence_seconds=1.2):
    """Graba hasta que dejás de hablar y devuelve el texto transcrito ('' si no hubo nada)."""
    try:
        import numpy as np
        import sounddevice as sd
        from collections import deque

        _check_stt_backend()
        rate = 16000
        block = int(rate * 0.1)
        chunks, pre = [], deque(maxlen=3)
        started, quiet, t0 = False, 0.0, time.time()

        print("[listening... speak now]")
        with sd.InputStream(samplerate=rate, channels=1, dtype="float32") as stream:
            while time.time() - t0 < max_seconds:
                data, _ = stream.read(block)
                level = float(np.sqrt(np.mean(data ** 2)))
                if level > MIC_THRESHOLD:
                    if not started:
                        started = True
                        chunks.extend(pre)
                    quiet = 0.0
                elif started:
                    quiet += 0.1
                if started:
                    chunks.append(data.copy())
                    if quiet >= silence_seconds:
                        break
                else:
                    pre.append(data.copy())
                    if time.time() - t0 > 8:  # nadie habló
                        break

        if not chunks:
            return ""
        audio = np.concatenate(chunks).flatten()
        return _transcribe(audio)
    except ImportError as e:
        print(f"[voice input unavailable: {e}]")
        return ""
    except Exception as e:
        print(f"[voice input error: {e}]")
        return ""


# --- Cognitive Tool Definitions ---
tools = [
    {
        "type": "function",
        "function": {
            "name": "execute_terminal_command",
            "description": "Execute a shell command on the user's Linux system. Do NOT use it for mouse or keyboard control (use manipulate_mouse / manipulate_keyboard). Do NOT use xdotool, wmctrl or xwininfo: they do not work on Wayland.",
            "parameters": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "The bash command to execute"}
                },
                "required": ["command"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "manipulate_mouse",
            "description": "Control the system mouse. get_position returns the cursor position and screen size (call it first when you need coordinates). move goes to absolute (x, y); move_relative shifts by (dx, dy) (negative dx = left, negative dy = up); click, right_click and double_click (optionally with x, y to move there first); scroll by amount notches; drag from (x, y) or the current position to (to_x, to_y).",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["get_position", "move", "move_relative", "click", "right_click", "double_click", "scroll", "drag"]},
                    "x": {"type": "integer", "description": "X coordinate (for 'move', or optional target for click actions)"},
                    "y": {"type": "integer", "description": "Y coordinate (for 'move', or optional target for click actions)"},
                    "dx": {"type": "integer", "description": "Horizontal offset in pixels (only for 'move_relative')"},
                    "dy": {"type": "integer", "description": "Vertical offset in pixels (only for 'move_relative')"},
                    "amount": {"type": "integer", "description": "Scroll notches (only for 'scroll'): positive = down, negative = up. Default 3."},
                    "to_x": {"type": "integer", "description": "Destination X (only for 'drag')"},
                    "to_y": {"type": "integer", "description": "Destination Y (only for 'drag')"},
                },
                "required": ["action"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "manipulate_keyboard",
            "description": (
                "Type text ('type') or press a key / key combination ('press'). "
                "Combos use '+', e.g. 'ctrl+t', 'alt+f4', 'super+d'. Single keys: 'enter', 'esc', 'tab', 'super'."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["type", "press"]},
                    "text": {"type": "string", "description": "Text to type, or key/combo to press"},
                },
                "required": ["action", "text"],
            },
        },
    },
]

tools.append({
    "type": "function",
    "function": {
        "name": "look_at_screen",
        "description": (
            "Take a screenshot and have a vision model answer a question about it. Use it to find buttons, "
            "read text or check the result of an action. Returns coordinates in real screen pixels."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "question": {"type": "string", "description": "What to look for, e.g. 'Where is the Send button?'"}
            },
            "required": ["question"],
        },
    },
})

HYPR_HINT = (
    " This Hyprland uses the Lua config, so the old 'hyprctl dispatch workspace 1' syntax FAILS. "
    "Use Lua dispatchers instead, e.g. hyprctl dispatch 'hl.dsp.focus({ workspace = \"1\" })', "
    "or simply press keyboard shortcuts such as super+1."
    if IS_WAYLAND else ""
)
_INT = {"type": "integer"}
tools.append({
    "type": "function",
    "function": {
        "name": "run_actions",
        "description": (
            "Run SEVERAL mouse/keyboard steps in ONE call (much faster than separate calls). Use it for any "
            "multi-step interaction, e.g. click a field, type text, press enter. Each step has tool = 'mouse', "
            "'keyboard' or 'wait', plus the same arguments as manipulate_mouse / manipulate_keyboard "
            "('wait' uses seconds). Optional delay_ms is the pause after the step (default 150)."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "actions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "tool": {"type": "string", "enum": ["mouse", "keyboard", "wait"]},
                            "action": {"type": "string"},
                            "x": _INT, "y": _INT, "dx": _INT, "dy": _INT,
                            "amount": _INT, "to_x": _INT, "to_y": _INT,
                            "text": {"type": "string"},
                            "seconds": {"type": "number"},
                            "delay_ms": _INT,
                        },
                        "required": ["tool"],
                    },
                }
            },
            "required": ["actions"],
        },
    },
})

conversation_history = [{
    "role": "system",
    "content": (
        "You are J.A.R.V.I.S., Tony Stark's personal AI. Address the user as 'Sir'. "
        "Be highly professional, efficient, concise, precise, and subtly witty. "
        "You are multilingual and maintain this exact persona in whichever language the user addresses you. "
        "Do not break character. Keep spoken replies short (1-3 sentences) unless asked for detail. "
        f"The user's desktop session is {'Wayland (Hyprland)' if IS_WAYLAND else 'X11'}. "
        "For ANY mouse or keyboard action, use the manipulate_mouse and manipulate_keyboard tools. "
        "Never use xdotool, wmctrl, xwininfo or similar X11 tools in terminal commands. "
        "Be fast: batch multi-step interactions into ONE run_actions call and avoid extra calls. "
        "Call get_position or look_at_screen only when you truly need coordinates, and do not re-check after every step. "
        "look_at_screen returns coordinates in real screen pixels. "
        "To learn what is on the screen use look_at_screen; never dig through system files, sockets or logs for it. "
        "If a tool fails or returns nothing useful twice, STOP and tell the user what failed instead of retrying. "
        f"{HYPR_HINT}"
    ),
}]

MAX_TOOL_ROUNDS = 6


def run_actions(actions):
    """Ejecuta varios pasos de mouse/teclado en UNA sola llamada (evita viajes extra al modelo)."""
    results = []
    for i, a in enumerate(actions or [], 1):
        kind = a.get("tool")
        try:
            if kind == "mouse":
                r = manipulate_mouse(
                    a.get("action"), a.get("x"), a.get("y"), a.get("dx"), a.get("dy"),
                    a.get("amount"), a.get("to_x"), a.get("to_y"),
                )
            elif kind == "keyboard":
                r = manipulate_keyboard(a.get("text", ""), a.get("action", "type"))
            elif kind == "wait":
                time.sleep(min(float(a.get("seconds", 0.5)), 5.0))
                r = "waited"
            else:
                r = f"unknown tool '{kind}'"
        except Exception as e:
            r = f"error: {e}"
        results.append(f"{i}. {r}")
        if any(w in str(r).lower() for w in ("failed", "denied", "error", "unknown", "missing")):
            results.append("Stopped after a failed step.")
            break
        time.sleep(float(a.get("delay_ms", 150)) / 1000.0)
    return "\n".join(results)


def run_tool(tool_call):
    try:
        args = json.loads(tool_call.function.arguments or "{}")
    except json.JSONDecodeError:
        return "Invalid tool arguments."
    name = tool_call.function.name
    if name == "execute_terminal_command":
        return execute_terminal_command(args.get("command", ""))
    if name == "manipulate_mouse":
        return manipulate_mouse(
            args.get("action"), args.get("x"), args.get("y"), args.get("dx"), args.get("dy"),
            args.get("amount"), args.get("to_x"), args.get("to_y"),
        )
    if name == "manipulate_keyboard":
        return manipulate_keyboard(args.get("text", ""), args.get("action", "type"))
    if name == "run_actions":
        return run_actions(args.get("actions"))
    if name == "look_at_screen":
        return look_at_screen(args.get("question") or "Describe what is on the screen.")
    return "Unrecognized tool requested."


_reasoning_ok = True


def _chat(**kwargs):
    """Llama al modelo principal; apaga el razonamiento (más rápido) y muestra cuánto tardó."""
    global _reasoning_ok
    from openai import BadRequestError

    kwargs.setdefault("timeout", CHAT_TIMEOUT)
    t0 = time.time()
    try:
        if REASONING != "default" and _reasoning_ok:
            try:
                return llm.chat.completions.create(
                    extra_body={"reasoning": {"effort": REASONING}}, **kwargs
                )
            except BadRequestError as e:
                print(f"[reasoning={REASONING} not accepted, retrying without it: {e}]")
                _reasoning_ok = False
        return llm.chat.completions.create(**kwargs)
    finally:
        print(f"[llm {time.time() - t0:.1f}s]")


# --- Main Execution Loop ---
if __name__ == "__main__":
    backend = "Wayland (ydotool/wtype/hyprctl)" if IS_WAYLAND else "X11 (pyautogui)"
    print(f"J.A.R.V.I.S. Agentic Terminal Online [{backend}]. Awaiting instructions, Sir.")
    print("Tip: press Enter on an empty line to speak once, or type /voice for hands-free mode.\n")
    voice_mode = False

    while True:
        try:
            if voice_mode:
                user_input = listen()
                if not user_input:
                    continue
                print(f"You (voice): {user_input}")
            else:
                user_input = input("You: ")
                stop_speech()  # si estaba hablando, se calla al escribir
                if user_input.strip().lower() == "/voice":
                    voice_mode = True
                    print("J.A.R.V.I.S.: Voice mode on, Sir. Press Ctrl+C to return to typing.\n")
                    continue
                if not user_input.strip():  # Enter vacío = hablar una vez
                    user_input = listen()
                    if not user_input:
                        continue
                    print(f"You (voice): {user_input}")

            if user_input.strip().lower().strip(".!?, ") in ["exit", "quit", "shutdown", "poweroff"]:
                bye = "Shutting down systems. Have a good day, Sir."
                print(f"\nJ.A.R.V.I.S.: {bye}")
                speak(bye, block=True)
                break
            if not user_input.strip():
                continue

            conversation_history.append({"role": "user", "content": user_input})

            message = None
            for _ in range(MAX_TOOL_ROUNDS):
                completion = _chat(
                    model=MODEL_ID,
                    messages=conversation_history,
                    tools=tools,
                    tool_choice="auto",
                )
                if not completion or not completion.choices:
                    print("\nJ.A.R.V.I.S.: Neural link timed out, Sir.\n")
                    message = None
                    break

                message = completion.choices[0].message
                if not message.tool_calls:
                    break

                conversation_history.append({
                    "role": "assistant",
                    "content": message.content or "",
                    "tool_calls": [
                        {
                            "id": tc.id,
                            "type": "function",
                            "function": {"name": tc.function.name, "arguments": tc.function.arguments},
                        }
                        for tc in message.tool_calls
                    ],
                })
                for tc in message.tool_calls:
                    t_tool = time.time()
                    output = run_tool(tc)
                    print(f"[tool {tc.function.name} {time.time() - t_tool:.1f}s]")
                    conversation_history.append({
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": str(output),
                    })

            if message and message.content and message.content.strip():
                response_text = message.content.strip()
                print(f"\nJ.A.R.V.I.S.: {response_text}\n")
                conversation_history.append({"role": "assistant", "content": response_text})
                speak(response_text, block=voice_mode)  # en modo voz espera para no oírse a sí mismo
            elif message is not None:
                print("\nJ.A.R.V.I.S.: The model returned no text, Sir. Try again or rephrase.\n")

        except KeyboardInterrupt:
            stop_speech()
            if voice_mode:
                voice_mode = False
                print("\nJ.A.R.V.I.S.: Voice mode off. Type /voice to re-enable.")
                continue
            print("\nJ.A.R.V.I.S.: Manual interrupt detected. Awaiting next command, Sir.")
        except Exception as e:
            print(f"\nJ.A.R.V.I.S.: System anomaly detected: {e}\n")

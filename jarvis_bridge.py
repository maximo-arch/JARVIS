#!/usr/bin/env python3
"""Puente JARVIS <-> Quickshell. Ponelo en la misma carpeta que JARVIS.py y corré: python jarvis_bridge.py"""
import json
import os
import socket
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import JARVIS as J  # noqa: E402  (no arranca el bucle de terminal: está bajo __main__)

SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "jarvis.sock")
clients, lock, busy = [], threading.Lock(), threading.Lock()


def emit(**ev):
    data = (json.dumps(ev, ensure_ascii=False) + "\n").encode()
    with lock:
        for c in clients[:]:
            try:
                c.sendall(data)
            except OSError:
                clients.remove(c)


def run_turn(text):
    if not busy.acquire(blocking=False):
        emit(type="error", text="Still working on the previous request, Sir.")
        return
    try:
        emit(type="status", state="thinking")
        J.conversation_history.append({"role": "user", "content": text})
        message = None
        for _ in range(J.MAX_TOOL_ROUNDS):
            completion = J._chat(
                model=J.MODEL_ID, messages=J.conversation_history, tools=J.tools, tool_choice="auto"
            )
            if not completion or not completion.choices:
                break
            message = completion.choices[0].message
            if not message.tool_calls:
                break
            J.conversation_history.append({
                "role": "assistant",
                "content": message.content or "",
                "tool_calls": [
                    {"id": tc.id, "type": "function",
                     "function": {"name": tc.function.name, "arguments": tc.function.arguments}}
                    for tc in message.tool_calls
                ],
            })
            for tc in message.tool_calls:
                emit(type="tool", name=tc.function.name, detail=(tc.function.arguments or "")[:90])
                out = J.run_tool(tc)
                J.conversation_history.append({"role": "tool", "tool_call_id": tc.id, "content": str(out)})

        reply = (message.content or "").strip() if message else ""
        if reply:
            J.conversation_history.append({"role": "assistant", "content": reply})
            emit(type="assistant", text=reply)
            J.speak(reply)
        else:
            emit(type="error", text="The model returned no text, Sir.")
    except Exception as e:
        emit(type="error", text=str(e))
    finally:
        emit(type="status", state="idle")
        busy.release()


def listen_turn():
    emit(type="status", state="listening")
    text = J.listen()
    if text:
        emit(type="user", text=text)
        run_turn(text)
    else:
        emit(type="status", state="idle")


def serve(conn):
    with lock:
        clients.append(conn)
    buf = b""
    try:
        while chunk := conn.recv(4096):
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                kind = msg.get("type")
                if kind == "user" and msg.get("text"):
                    J.stop_speech()
                    threading.Thread(target=run_turn, args=(msg["text"],), daemon=True).start()
                elif kind == "listen":
                    J.stop_speech()
                    threading.Thread(target=listen_turn, daemon=True).start()
                elif kind == "stop":
                    J.stop_speech()
                elif kind == "clear":
                    del J.conversation_history[1:]
    except OSError:
        pass
    finally:
        with lock:
            if conn in clients:
                clients.remove(conn)
        conn.close()


if __name__ == "__main__":
    if os.path.exists(SOCK):
        os.remove(SOCK)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK)
    os.chmod(SOCK, 0o600)
    srv.listen(4)
    print(f"J.A.R.V.I.S. bridge listening on {SOCK}")
    while True:
        c, _ = srv.accept()
        threading.Thread(target=serve, args=(c,), daemon=True).start()

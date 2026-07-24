#!/usr/bin/env python3
"""
AlphaInference Chat Server
Flask backend: serves chat UI, proxies Ollama, handles image generation.
"""

import os
import re
import sys
import json
import time
import signal
import socket
import subprocess
import threading
import uuid
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from datetime import datetime

from flask import (
    Flask, request, jsonify, Response,
    send_file, send_from_directory, stream_with_context
)
from flask_cors import CORS
import requests

# ============================================================
# Configuration
# ============================================================
BASE_DIR         = Path(__file__).parent.resolve()
VENDOR_DIR       = BASE_DIR   / "vendor"
MODELS_DIR       = BASE_DIR   / "models"
OLLAMA_DIR       = VENDOR_DIR / "ollama"
SD_DIR           = VENDOR_DIR / "stable-diffusion"
IMAGE_OUTPUT_DIR = BASE_DIR   / "generated_images"
CHAT_HISTORY_DIR = BASE_DIR   / "chat_history"

OLLAMA_EXE = OLLAMA_DIR / "ollama.exe"
OLLAMA_MODELS_DIR = MODELS_DIR / "ollama"
OLLAMA_HOME_DIR = VENDOR_DIR / "ollama_home"
SD_WEIGHT_TYPE = os.environ.get("SD_WEIGHT_TYPE", "f16")


def _find_sd_exe():
    """Pick whichever SD binary variant exists (sd-cli.exe for new releases)."""
    for name in ("sd-cli.exe", "sd.exe"):
        c = SD_DIR / name
        if c.exists():
            return c
    return SD_DIR / "sd-cli.exe"


SD_EXE     = _find_sd_exe()
OLLAMA_API = (os.environ.get("OLLAMA_API_BASE", "http://127.0.0.1:11434") or "http://127.0.0.1:11434").rstrip("/")

_host_raw = (os.environ.get("ALPHA_SERVER_HOST", "127.0.0.1") or "").strip().lower()
SERVER_BIND_HOST = "0.0.0.0" if _host_raw in {"0.0.0.0", "*", "all"} else (_host_raw or "127.0.0.1")
SERVER_PORT = int(os.environ.get("ALPHA_SERVER_PORT", "5000") or "5000")

MAX_CHAT_MESSAGES = 80
MAX_CHAT_TOTAL_CHARS = 200000
MAX_CHAT_MESSAGE_CHARS = 60000
MAX_IMAGE_PROMPT_CHARS = 2000
MAX_IMAGE_NEGATIVE_PROMPT_CHARS = 2000

_IS_RELOADER = os.environ.get("WERKZEUG_RUN_MAIN") == "true"

if not _IS_RELOADER:
    IMAGE_OUTPUT_DIR.mkdir(exist_ok=True)
    CHAT_HISTORY_DIR.mkdir(exist_ok=True)

# Dedicated SD worker thread (single-slot queue)
_sd_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="sd")

# ============================================================
# Flask App
# ============================================================
app = Flask(__name__)
CORS(app)

# ── Shared mutable state ─────────────────────────────────────
sd_lock         = threading.Lock()
_sd_process     = None
_sd_cancelled   = False

# Tracks the currently-running SD job for UI recovery after refresh
_sd_job_lock    = threading.Lock()
_sd_current_job = None
_sd_last_result = None

model_lock      = threading.Lock()
active_model    = None
ollama_process  = None

# Global chat queue: one active chat stream at a time across the server.
chat_queue_lock       = threading.Lock()
chat_queue_cv         = threading.Condition(chat_queue_lock)
chat_queue            = deque()
chat_active_request   = None
chat_active_started   = None


# ============================================================
# Helpers
# ============================================================
def is_ollama_running() -> bool:
    try:
        r = requests.get(f"{OLLAMA_API}/api/tags", timeout=3)
        return r.status_code == 200
    except Exception:
        return False


def count_ollama_processes() -> int:
    if sys.platform != "win32":
        return 0
    try:
        out = subprocess.check_output(
            ["tasklist", "/fi", "imagename eq ollama.exe", "/fo", "csv", "/nh"],
            creationflags=subprocess.CREATE_NO_WINDOW,
            text=True, timeout=5,
        )
        return sum(1 for line in out.strip().splitlines() if "ollama.exe" in line.lower())
    except Exception:
        return 0


def start_ollama() -> bool:
    global ollama_process
    if is_ollama_running():
        return True
    if not OLLAMA_EXE.exists():
        print("[WARN] Ollama not found.")
        return False
    if count_ollama_processes() > 0:
        print("[*] Ollama process exists but not responding yet, waiting ...")
        for _ in range(15):
            if is_ollama_running():
                return True
            time.sleep(1)
        return False

    env = os.environ.copy()
    env["OLLAMA_HOST"] = "127.0.0.1:11434"
    env["OLLAMA_MODELS"] = str(OLLAMA_MODELS_DIR)
    env["OLLAMA_HOME"] = str(OLLAMA_HOME_DIR)
    env["OLLAMA_KV_CACHE_TYPE"]   = os.environ.get("OLLAMA_KV_CACHE_TYPE", "q8_0")

    OLLAMA_MODELS_DIR.mkdir(parents=True, exist_ok=True)
    OLLAMA_HOME_DIR.mkdir(parents=True, exist_ok=True)
    flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
    try:
        ollama_process = subprocess.Popen(
            [str(OLLAMA_EXE), "serve"],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=flags,
        )
        for i in range(30):
            if is_ollama_running():
                print("[OK] Ollama started.")
                return True
            time.sleep(1)
            if i % 5 == 4:
                print(f"  Still waiting ({i+1}s) ...")
    except Exception as e:
        print(f"[ERROR] Cannot start Ollama: {e}")

    print("[WARN] Ollama never responsive.")
    return False


def get_loaded_models() -> list:
    try:
        r = requests.get(f"{OLLAMA_API}/api/ps", timeout=5)
        if r.status_code == 200:
            return r.json().get("models", [])
    except Exception:
        pass
    return []


def unload_ollama_model(model_name: str) -> bool:
    if not model_name:
        return False
    try:
        r = requests.post(
            f"{OLLAMA_API}/api/generate",
            json={"model": model_name, "prompt": "", "keep_alive": 0},
            timeout=30,
        )
        ok = r.status_code == 200
        if ok:
            print(f"[*] Unloaded: {model_name}")
        else:
            print(f"[WARN] Unload {model_name} -> {r.status_code}")
        return ok
    except Exception as e:
        print(f"[WARN] Unload failed: {e}")
        return False


def unload_all_models():
    for m in get_loaded_models():
        name = m.get("name", "")
        if name:
            unload_ollama_model(name)


def is_partial_file(path: Path) -> bool:
    return "partial" in path.name.lower()


def sanitise_session_id(raw: str):
    """Accept UUID4 OR legacy chat_TIMESTAMP IDs."""
    if not raw:
        return None
    if re.fullmatch(
        r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        raw
    ):
        return raw
    if re.fullmatch(r"chat_[0-9]{10,15}", raw):
        return raw
    return None


def read_json_utf8(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json_utf8(path: Path, data: dict) -> None:
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    tmp.replace(path)


def is_port_free(host: str, port: int) -> bool:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind((host, port))
            return True
    except OSError:
        return False


def get_primary_lan_ip() -> str:
    """Best-effort LAN IPv4 used for user-facing URL display."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        if ip and not ip.startswith("127."):
            return ip
    except Exception:
        pass
    finally:
        sock.close()

    try:
        host_ip = socket.gethostbyname(socket.gethostname())
        if host_ip and not host_ip.startswith("127."):
            return host_ip
    except Exception:
        pass
    return ""


def _check_sd_runnable():
    """Verify sd-cli.exe / sd.exe can launch (catches missing DLLs)."""
    if not SD_EXE.exists():
        return {"error": "SD executable not found", "detail": str(SD_EXE)}

    flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
    try:
        result = subprocess.run(
            [str(SD_EXE), "--help"],
            capture_output=True, timeout=5,
            creationflags=flags,
        )
        if result.returncode not in (0, 1):
            output = (result.stderr or result.stdout or b"").decode("utf-8", errors="replace")
            low = output.lower()
            if "cudart" in low or "cublas" in low or "cudnn" in low:
                return {
                    "error":  "sd needs CUDA DLLs not installed.",
                    "detail": "Use the CPU build (sd-master-*-bin-win-avx2-x64.zip) "
                              "from https://github.com/leejet/stable-diffusion.cpp/releases",
                    "raw":    output[:500],
                }
            if "vulkan" in low:
                return {
                    "error":  "sd needs Vulkan DLLs.",
                    "detail": "Use the CPU build instead.",
                    "raw":    output[:500],
                }
            if "dll" in low or "0xc0000135" in low:
                return {
                    "error":  "sd is missing required DLLs.",
                    "detail": "Re-download the CPU build.",
                    "raw":    output[:500],
                }
            return {"error": "sd failed pre-flight", "detail": output[:500]}
        return None
    except subprocess.TimeoutExpired:
        return {"error": "sd unresponsive", "detail": "Hung on --help"}
    except OSError as e:
        err = str(e)
        if "126" in err:
            return {"error": "sd cannot start - missing DLL", "detail": err}
        if "193" in err:
            return {"error": "sd wrong architecture", "detail": err}
        return {"error": f"sd failed: {e}"}


def _save_image_metadata(out_path: Path, info: dict) -> None:
    """Write a sidecar JSON with prompt/settings next to the PNG."""
    sidecar = out_path.with_suffix(".json")
    try:
        write_json_utf8(sidecar, info)
    except Exception as e:
        print(f"[WARN] Could not write image metadata: {e}")


def _load_image_metadata(image_path: Path) -> dict:
    """Read sidecar JSON for an image if it exists, return empty dict otherwise."""
    sidecar = image_path.with_suffix(".json")
    if not sidecar.exists():
        return {}
    try:
        return read_json_utf8(sidecar)
    except Exception:
        return {}


# ============================================================
# Static routes
# ============================================================
@app.route("/")
def index():
    html = BASE_DIR / "chatUI.html"
    return send_file(str(html)) if html.exists() else ("chatUI.html not found", 404)


@app.route("/generated_images/<path:filename>")
def serve_image(filename):
    return send_from_directory(str(IMAGE_OUTPUT_DIR), filename)


# ============================================================
# Model management
# ============================================================
@app.route("/api/models", methods=["GET"])
def list_models():
    result = {"chat_models": [], "image_models": []}
    try:
        r = requests.get(f"{OLLAMA_API}/api/tags", timeout=5)
        if r.status_code == 200:
            for m in r.json().get("models", []):
                gb  = m.get("size", 0) / 1024 ** 3
                det = m.get("details", {})
                result["chat_models"].append({
                    "name":         m["name"],
                    "size":         f"{gb:.1f} GB",
                    "size_bytes":   m.get("size", 0),
                    "modified":     m.get("modified_at", ""),
                    "family":       det.get("family",             "unknown"),
                    "parameters":   det.get("parameter_size",     "unknown"),
                    "quantization": det.get("quantization_level", "unknown"),
                })
    except Exception as e:
        print(f"[WARN] Ollama tag query failed: {e}")

    image_dir = MODELS_DIR / "image"
    if image_dir.exists():
        valid_ext = {".safetensors", ".gguf", ".ckpt", ".bin"}
        for f in sorted(image_dir.iterdir()):
            if not f.is_file():
                continue
            if f.suffix.lower() not in valid_ext:
                continue
            if is_partial_file(f):
                continue
            gb = f.stat().st_size / 1024 ** 3
            result["image_models"].append({
                "name":       f.stem,
                "filename":   f.name,
                "size":       f"{gb:.1f} GB",
                "size_bytes": f.stat().st_size,
                "path":       str(f).replace("\\", "/"),
            })

    return jsonify(result)


@app.route("/api/models/active", methods=["GET"])
def get_active_model():
    global active_model
    loaded = get_loaded_models()
    if loaded:
        active_model = loaded[0].get("name")
        return jsonify({"active_model": active_model, "models": loaded})
    return jsonify({"active_model": None, "models": []})


@app.route("/api/models/load", methods=["POST"])
def load_model():
    global active_model
    data       = request.json or {}
    model_name = data.get("model", "").strip()

    if not model_name:
        return jsonify({"error": "No model specified"}), 400

    with model_lock:
        loaded       = get_loaded_models()
        loaded_names = [m.get("name", "") for m in loaded]

        if model_name in loaded_names:
            active_model = model_name
            print(f"[OK] {model_name} already loaded.")
            return jsonify({"status": "loaded", "model": model_name})

        for m in loaded:
            name = m.get("name", "")
            if name:
                unload_ollama_model(name)

        try:
            r = requests.post(
                f"{OLLAMA_API}/api/generate",
                json={"model": model_name, "prompt": "", "keep_alive": "10m"},
                timeout=120,
            )
            if r.status_code == 200:
                active_model = model_name
                print(f"[OK] Loaded: {model_name}")
                return jsonify({"status": "loaded", "model": model_name})

            msg = r.json().get("error", r.text[:200]) if r.content else r.text[:200]
            return jsonify({"error": f"Load failed: {msg}"}), 500
        except Exception as e:
            return jsonify({"error": f"Load failed: {e}"}), 500


@app.route("/api/models/unload", methods=["POST"])
def unload_model_route():
    global active_model
    data       = request.json or {}
    model_name = data.get("model", active_model)

    if not model_name:
        return jsonify({"status": "no model loaded"})

    with model_lock:
        ok = unload_ollama_model(model_name)
        if ok:
            if active_model == model_name:
                active_model = None
            return jsonify({"status": "unloaded", "model": model_name})
        return jsonify({"error": "Unload failed"}), 500


# ============================================================
# Chat - streaming
# ============================================================
@app.route("/api/chat/queue", methods=["GET"])
def chat_queue_status():
    with chat_queue_lock:
        active = chat_active_request is not None
        active_for = 0.0
        if active and chat_active_started is not None:
            active_for = round(max(0.0, time.time() - chat_active_started), 1)
        return jsonify({
            "active": active,
            "queued_count": len(chat_queue),
            "active_for_seconds": active_for,
        })


@app.route("/api/chat", methods=["POST"])
def chat():
    global chat_active_request, chat_active_started

    data     = request.json or {}
    model    = data.get("model",    "")
    messages = data.get("messages", [])

    if not model:
        return jsonify({"error": "No model specified"}), 400
    if not messages:
        return jsonify({"error": "No messages"}), 400
    if len(messages) > MAX_CHAT_MESSAGES:
        return jsonify({"error": f"Too many messages. Max {MAX_CHAT_MESSAGES}."}), 400

    total_chars = 0
    for msg in messages:
        content = str(msg.get("content", ""))
        total_chars += len(content)
        if len(content) > MAX_CHAT_MESSAGE_CHARS:
            return jsonify({"error": f"A message exceeds the {MAX_CHAT_MESSAGE_CHARS} character limit."}), 400
    if total_chars > MAX_CHAT_TOTAL_CHARS:
        return jsonify({"error": f"Conversation exceeds the {MAX_CHAT_TOTAL_CHARS} character limit."}), 400

    payload: dict = {"model": model, "messages": messages, "stream": True}
    if data.get("system"):
        payload["system"] = data["system"]
    if data.get("options"):
        payload["options"] = data["options"]

    request_id = uuid.uuid4().hex

    with chat_queue_cv:
        chat_queue.append(request_id)
        chat_queue_cv.notify_all()

    def generate():
        global chat_active_request, chat_active_started

        ollama_resp = None
        is_active = False
        last_position = None

        try:
            while True:
                with chat_queue_cv:
                    if chat_active_request is None and chat_queue and chat_queue[0] == request_id:
                        chat_queue.popleft()
                        chat_active_request = request_id
                        chat_active_started = time.time()
                        is_active = True
                        queued_left = len(chat_queue)
                        chat_queue_cv.notify_all()
                        break

                    if request_id not in chat_queue:
                        return

                    position = list(chat_queue).index(request_id) + 1

                if last_position != position:
                    last_position = position
                    yield f'data: {json.dumps({"queue": {"state": "waiting", "position": position}})}\n\n'

                with chat_queue_cv:
                    chat_queue_cv.wait(timeout=1.0)

            yield f'data: {json.dumps({"queue": {"state": "active", "position": 0, "queued_count": queued_left}})}\n\n'

            ollama_resp = requests.post(
                f"{OLLAMA_API}/api/chat",
                json=payload, stream=True, timeout=300,
            )
            ollama_resp.raise_for_status()
            for line in ollama_resp.iter_lines():
                if line:
                    try:
                        chunk = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    yield f"data: {json.dumps(chunk)}\n\n"
                    if chunk.get("done"):
                        break
        except requests.exceptions.ConnectionError:
            yield f'data: {json.dumps({"error": "Cannot connect to Ollama"})}\n\n'
        except GeneratorExit:
            pass
        except Exception as e:
            yield f'data: {json.dumps({"error": str(e)})}\n\n'
        finally:
            if ollama_resp is not None:
                try:
                    ollama_resp.close()
                except Exception:
                    pass

            with chat_queue_cv:
                try:
                    chat_queue.remove(request_id)
                except ValueError:
                    pass

                if is_active and chat_active_request == request_id:
                    chat_active_request = None
                    chat_active_started = None

                chat_queue_cv.notify_all()

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.route("/api/chat/non-stream", methods=["POST"])
def chat_non_stream():
    data = request.json or {}
    model = data.get("model", "")
    messages = data.get("messages", [])

    if not model:
        return jsonify({"error": "No model specified"}), 400
    if not messages:
        return jsonify({"error": "No messages"}), 400
    if len(messages) > MAX_CHAT_MESSAGES:
        return jsonify({"error": f"Too many messages. Max {MAX_CHAT_MESSAGES}."}), 400

    total_chars = 0
    for msg in messages:
        content = str(msg.get("content", ""))
        total_chars += len(content)
        if len(content) > MAX_CHAT_MESSAGE_CHARS:
            return jsonify({"error": f"A message exceeds the {MAX_CHAT_MESSAGE_CHARS} character limit."}), 400
    if total_chars > MAX_CHAT_TOTAL_CHARS:
        return jsonify({"error": f"Conversation exceeds the {MAX_CHAT_TOTAL_CHARS} character limit."}), 400

    payload = {
        "model":    model,
        "messages": messages,
        "stream":   False,
    }
    if data.get("options"):
        payload["options"] = data["options"]
    try:
        r = requests.post(f"{OLLAMA_API}/api/chat", json=payload, timeout=300)
        return jsonify(r.json())
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ============================================================
# Image generation
# ============================================================
def _run_sd(cmd: list, out_path: Path, job_info: dict) -> dict:
    """SD worker thread. Publishes job state for UI recovery."""
    global _sd_process, _sd_cancelled, _sd_current_job, _sd_last_result

    flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0

    # Register the job so UI can recover after refresh
    with _sd_job_lock:
        _sd_current_job = job_info

    with sd_lock:
        if _sd_process and _sd_process.poll() is None:
            _sd_process.terminate()
        _sd_cancelled = False
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            creationflags=flags,
        )
        _sd_process = proc

    try:
        stdout, _ = proc.communicate(timeout=600)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        result = {"status": "failed", "error": "Timeout (10 min)", "status_code": 500}
        with sd_lock:
            if _sd_process is proc:
                _sd_process   = None
                _sd_cancelled = False
        with _sd_job_lock:
            _sd_current_job = None
            _sd_last_result = {
                "status": result["status"],
                "error": result["error"],
                "finished_at": datetime.now().isoformat(),
                "job": dict(job_info),
            }
        return result

    with sd_lock:
        was_cancelled = _sd_cancelled
        if _sd_process is proc:
            _sd_process   = None
            _sd_cancelled = False

    # Clear job state
    with _sd_job_lock:
        _sd_current_job = None

    if was_cancelled:
        result = {"status": "cancelled", "message": "Cancelled by user", "status_code": 200}
        with _sd_job_lock:
            _sd_last_result = {
                "status": result["status"],
                "message": result["message"],
                "finished_at": datetime.now().isoformat(),
                "job": dict(job_info),
            }
        return result

    log = stdout.decode("utf-8", errors="replace") if stdout else ""
    if proc.returncode != 0:
        result = {"status": "failed", "error": "SD generation failed", "log": log, "status_code": 500}
        with _sd_job_lock:
            _sd_last_result = {
                "status": result["status"],
                "error": result["error"],
                "log": log,
                "finished_at": datetime.now().isoformat(),
                "job": dict(job_info),
            }
        return result

    if out_path.exists():
        # Save sidecar metadata so gallery can show prompt info after refresh
        _save_image_metadata(out_path, job_info)

        url = f"/generated_images/{out_path.name}"
        result = {
            "status":      "success",
            "image_url":   url.replace("\\", "/"),
            "filename":    out_path.name,
            "log":         log,
            "status_code": 200,
        }
        with _sd_job_lock:
            _sd_last_result = {
                "status": result["status"],
                "image_url": result["image_url"],
                "filename": result["filename"],
                "finished_at": datetime.now().isoformat(),
                "job": dict(job_info),
            }
        return result
    result = {"status": "failed", "error": "Image file not created", "log": log, "status_code": 500}
    with _sd_job_lock:
        _sd_last_result = {
            "status": result["status"],
            "error": result["error"],
            "log": log,
            "finished_at": datetime.now().isoformat(),
            "job": dict(job_info),
        }
    return result


@app.route("/api/generate-image", methods=["POST"])
def generate_image():
    data            = request.json or {}
    prompt          = data.get("prompt",          "")
    negative_prompt = data.get("negative_prompt", "")
    model_file      = data.get("model",           "")
    steps           = data.get("steps",           20)
    width           = data.get("width",           512)
    height          = data.get("height",          512)
    cfg_scale       = data.get("cfg_scale",       7.0)
    seed            = data.get("seed",            -1)
    sample_method   = data.get("sample_method",   "euler_a")

    if not prompt:
        return jsonify({"error": "No prompt"}), 400
    if len(prompt) > MAX_IMAGE_PROMPT_CHARS:
        return jsonify({"error": f"Prompt exceeds {MAX_IMAGE_PROMPT_CHARS} characters"}), 400
    if len(negative_prompt) > MAX_IMAGE_NEGATIVE_PROMPT_CHARS:
        return jsonify({"error": f"Negative prompt exceeds {MAX_IMAGE_NEGATIVE_PROMPT_CHARS} characters"}), 400
    if not SD_EXE.exists():
        return jsonify({"error": "sd executable not found"}), 500

    try:
        steps = int(steps)
        width = int(width)
        height = int(height)
        cfg_scale = float(cfg_scale)
        seed = int(seed)
    except (TypeError, ValueError):
        return jsonify({"error": "Invalid numeric image parameters"}), 400

    valid_samplers = {
        "euler", "euler_a", "heun", "dpm2",
        "dpm++2s_a", "dpm++2m", "dpm++2mv2",
        "ipndm", "ipndm_v", "lcm", "ddim_trailing", "tcd",
        "res_multistep", "res_2s", "er_sde",
        "euler_cfg_pp", "euler_a_cfg_pp",
    }
    if sample_method not in valid_samplers:
        return jsonify({"error": f"Unsupported sample method: {sample_method}"}), 400
    if steps < 1 or steps > 100:
        return jsonify({"error": "steps must be between 1 and 100"}), 400
    if width < 256 or width > 1024 or height < 256 or height > 1024:
        return jsonify({"error": "width and height must be between 256 and 1024"}), 400
    if cfg_scale < 1 or cfg_scale > 20:
        return jsonify({"error": "cfg_scale must be between 1 and 20"}), 400

    with sd_lock:
        if _sd_process is not None and _sd_process.poll() is None:
            return jsonify({"error": "Image generation already in progress"}), 409

    sd_check = _check_sd_runnable()
    if sd_check is not None:
        return jsonify(sd_check), 500

    model_path = None
    image_dir  = MODELS_DIR / "image"

    if model_file:
        candidate = Path(model_file)
        if candidate.is_file():
            model_path = str(candidate)
        elif image_dir.exists():
            for f in image_dir.iterdir():
                if f.is_file() and not is_partial_file(f):
                    if f.stem == model_file or f.name == model_file:
                        model_path = str(f)
                        break

    if not model_path and image_dir.exists():
        for ext in ("*.safetensors", "*.ckpt", "*.gguf"):
            hits = [f for f in image_dir.glob(ext)
                    if f.is_file() and not is_partial_file(f)]
            if hits:
                model_path = str(hits[0])
                break

    if not model_path:
        return jsonify({"error": "No image model found"}), 400

    ts       = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_fn   = f"img_{ts}_{uuid.uuid4().hex[:8]}.png"
    out_path = IMAGE_OUTPUT_DIR / out_fn

    # FLUX GGUF models require cfg_scale=1.0 and euler sampler.
    # Detect by extension and common name patterns.
    _model_name_lower = Path(model_path).name.lower()
    _is_flux_gguf = (
        model_path.lower().endswith(".gguf")
        and ("flux" in _model_name_lower)
    )
    if _is_flux_gguf:
        cfg_scale     = 1.0
        sample_method = "euler"

    cmd = [
        str(SD_EXE),
        "-m", str(model_path),
        "-p", str(prompt),
        "--steps",           str(steps),
        "-W",                str(width),
        "-H",                str(height),
        "--cfg-scale",       str(cfg_scale),
        "-o",                str(out_path),
        "--sampling-method", str(sample_method),
        "--type",            SD_WEIGHT_TYPE,
    ]
    if negative_prompt:
        cmd.extend(["-n", str(negative_prompt)])
    if seed >= 0:
        cmd.extend(["--seed", str(seed)])

    # Build job info for UI recovery and sidecar metadata
    job_info = {
        "prompt":          prompt,
        "negative_prompt": negative_prompt,
        "model":           model_file,
        "steps":           steps,
        "width":           width,
        "height":          height,
        "cfg_scale":       cfg_scale,
        "seed":            seed,
        "sample_method":   sample_method,
        "output_filename": out_fn,
        "start_time":      datetime.now().isoformat(),
    }

    print(f"[*] SD: {cmd}")

    future = _sd_executor.submit(_run_sd, cmd, out_path, job_info)
    result = future.result()
    code   = result.pop("status_code", 200)
    return jsonify(result), code


@app.route("/api/generate-image/cancel", methods=["POST"])
def cancel_image_generation():
    global _sd_process, _sd_cancelled
    with sd_lock:
        proc = _sd_process
        if proc is None or proc.poll() is not None:
            return jsonify({"status": "no active generation"})
        _sd_cancelled = True
        _sd_process   = None
        proc.terminate()

    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
    return jsonify({"status": "cancelled"})


@app.route("/api/generate-image/status", methods=["GET"])
def image_generation_status():
    """
    Return the currently running image generation job, if any.
    UI calls this on page load to recover state after refresh.
    """
    with _sd_job_lock:
        job = _sd_current_job
        last_result = dict(_sd_last_result) if _sd_last_result else None

    if job is None:
        return jsonify({"active": False, "last_result": last_result})

    try:
        start = datetime.fromisoformat(job["start_time"])
        elapsed = (datetime.now() - start).total_seconds()
    except Exception:
        elapsed = 0

    return jsonify({
        "active":            True,
        "prompt":            job.get("prompt", ""),
        "negative_prompt":   job.get("negative_prompt", ""),
        "model":             job.get("model", ""),
        "steps":             job.get("steps", 0),
        "width":             job.get("width", 0),
        "height":            job.get("height", 0),
        "cfg_scale":         job.get("cfg_scale", 0),
        "seed":              job.get("seed", -1),
        "sample_method":     job.get("sample_method", ""),
        "elapsed_seconds":   round(elapsed, 1),
        "expected_filename": job.get("output_filename", ""),
    })


@app.route("/api/generated-images", methods=["GET"])
def list_generated_images():
    """
    Return all images in the generated_images folder.
    UI calls this on page load to repopulate the gallery.
    Includes prompt + settings from sidecar JSON if available.
    """
    images = []
    if IMAGE_OUTPUT_DIR.exists():
        files = sorted(
            IMAGE_OUTPUT_DIR.glob("*.png"),
            key=lambda f: f.stat().st_mtime,
            reverse=True
        )
        for f in files[:100]:  # cap at 100 most recent
            stat = f.stat()
            meta = _load_image_metadata(f)
            images.append({
                "filename":   f.name,
                "url":        f"/generated_images/{f.name}",
                "size_kb":    round(stat.st_size / 1024),
                "created":    datetime.fromtimestamp(stat.st_mtime).isoformat(),
                "prompt":     meta.get("prompt", ""),
                "width":      meta.get("width", 0),
                "height":     meta.get("height", 0),
                "steps":      meta.get("steps", 0),
                "cfg_scale":  meta.get("cfg_scale", 0),
                "seed":       meta.get("seed", -1),
            })
    return jsonify({"images": images})


@app.route("/api/generated-images/<filename>", methods=["DELETE"])
def delete_generated_image(filename):
    """Delete an image and its metadata sidecar."""
    # Basic sanitisation: no path separators allowed
    if "/" in filename or "\\" in filename or ".." in filename:
        return jsonify({"error": "Invalid filename"}), 400

    img = IMAGE_OUTPUT_DIR / filename
    if not img.exists():
        return jsonify({"error": "Not found"}), 404

    try:
        img.unlink()
        sidecar = img.with_suffix(".json")
        if sidecar.exists():
            sidecar.unlink()
        return jsonify({"status": "deleted", "filename": filename})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ============================================================
# Video generation (scaffold)
# ============================================================
@app.route("/api/generate-video", methods=["POST"])
def generate_video():
    return jsonify({"error": "Video functionality has been removed."}), 410


@app.route("/api/generate-video/status", methods=["GET"])
def generate_video_status_summary():
    return jsonify({"error": "Video functionality has been removed."}), 410


@app.route("/api/generate-video/status/<job_id>", methods=["GET"])
def generate_video_status(job_id):
    return jsonify({"error": "Video functionality has been removed."}), 410


@app.route("/api/generate-video/cancel/<job_id>", methods=["POST"])
def cancel_video_generation(job_id):
    return jsonify({"error": "Video functionality has been removed."}), 410


@app.route("/api/generated-videos", methods=["GET"])
def list_generated_videos():
    return jsonify({"error": "Video functionality has been removed."}), 410


@app.route("/api/generated-videos/<filename>", methods=["DELETE"])
def delete_generated_video(filename):
    return jsonify({"error": "Video functionality has been removed."}), 410


# ============================================================
# Chat history
# ============================================================
@app.route("/api/history", methods=["GET"])
def list_history():
    sessions = []
    for f in sorted(CHAT_HISTORY_DIR.glob("*.json"), reverse=True):
        try:
            d = read_json_utf8(f)
            sessions.append({
                "id":            f.stem,
                "title":         d.get("title",    "Untitled"),
                "model":         d.get("model",    "unknown"),
                "created":       d.get("created",  ""),
                "updated":       d.get("updated",  ""),
                "message_count": len(d.get("messages", [])),
            })
        except Exception:
            pass
    return jsonify({"sessions": sessions})


@app.route("/api/history/<session_id>", methods=["GET"])
def get_history(session_id):
    safe_id = sanitise_session_id(session_id)
    if safe_id is None:
        return jsonify({"error": "Invalid session ID"}), 400
    fp = CHAT_HISTORY_DIR / f"{safe_id}.json"
    if not fp.exists():
        return jsonify({"error": "Not found"}), 404
    return jsonify(read_json_utf8(fp))


@app.route("/api/history", methods=["POST"])
def save_history():
    data    = request.json or {}
    now     = datetime.now().isoformat()
    raw_id  = data.get("id", "")
    safe_id = sanitise_session_id(raw_id) if raw_id else None

    if safe_id is None:
        safe_id = str(uuid.uuid4())

    payload = {
        "id":       safe_id,
        "title":    data.get("title",    "Untitled Chat"),
        "model":    data.get("model",    ""),
        "created":  data.get("created",  now),
        "updated":  now,
        "messages": data.get("messages", []),
        "system":   data.get("system",   ""),
    }

    out = CHAT_HISTORY_DIR / f"{safe_id}.json"
    try:
        out.resolve().relative_to(CHAT_HISTORY_DIR.resolve())
    except ValueError:
        return jsonify({"error": "Path escape"}), 400

    write_json_utf8(out, payload)
    return jsonify({"status": "saved", "id": safe_id})


@app.route("/api/history/<session_id>", methods=["DELETE"])
def delete_history(session_id):
    safe_id = sanitise_session_id(session_id)
    if safe_id is None:
        return jsonify({"error": "Invalid session ID"}), 400
    fp = CHAT_HISTORY_DIR / f"{safe_id}.json"
    if fp.exists():
        fp.unlink()
        return jsonify({"status": "deleted"})
    return jsonify({"error": "Not found"}), 404


# ============================================================
# System / stats / health
# ============================================================
@app.route("/api/system", methods=["GET"])
def system_info():
    lan_ip = get_primary_lan_ip()
    local_url = f"http://127.0.0.1:{SERVER_PORT}"
    lan_url = f"http://{lan_ip}:{SERVER_PORT}" if lan_ip else ""
    return jsonify({
        "ollama_running":   is_ollama_running(),
        "sd_available":     SD_EXE.exists(),
        "ollama_available": OLLAMA_EXE.exists(),
        "running_models":   get_loaded_models(),
        "server_bind_host": SERVER_BIND_HOST,
        "server_port": SERVER_PORT,
        "local_url": local_url,
        "lan_url": lan_url,
        "lan_exposed": SERVER_BIND_HOST == "0.0.0.0",
    })


@app.route("/api/stats", methods=["GET"])
def system_stats():
    stats = {
        "cpu_percent": 0,
        "ram_used_gb": 0,
        "ram_total_gb": 0,
        "ram_percent": 0,
        "vram_used_mb": 0,
        "vram_total_mb": 0,
        "vram_percent": 0,
        "gpu_name": "",
        "gpu_temp_c": 0,
        "active_model": active_model,
        "active_model_vram_mb": 0,
    }

    try:
        import psutil
        stats["cpu_percent"]  = psutil.cpu_percent(interval=0.1)
        mem = psutil.virtual_memory()
        stats["ram_used_gb"]  = round(mem.used  / 1024**3, 1)
        stats["ram_total_gb"] = round(mem.total / 1024**3, 1)
        stats["ram_percent"]  = mem.percent
    except ImportError:
        try:
            import ctypes
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength",                ctypes.c_ulong),
                    ("dwMemoryLoad",            ctypes.c_ulong),
                    ("ullTotalPhys",            ctypes.c_ulonglong),
                    ("ullAvailPhys",            ctypes.c_ulonglong),
                    ("ullTotalPageFile",        ctypes.c_ulonglong),
                    ("ullAvailPageFile",        ctypes.c_ulonglong),
                    ("ullTotalVirtual",         ctypes.c_ulonglong),
                    ("ullAvailVirtual",         ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]
            mi = MEMORYSTATUSEX()
            mi.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(mi))
            stats["ram_total_gb"] = round(mi.ullTotalPhys / 1024**3, 1)
            stats["ram_used_gb"]  = round((mi.ullTotalPhys - mi.ullAvailPhys) / 1024**3, 1)
            stats["ram_percent"]  = mi.dwMemoryLoad
        except Exception:
            pass

    try:
        flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
        result = subprocess.run(
            ["nvidia-smi",
             "--query-gpu=name,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
            creationflags=flags,
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = [p.strip() for p in result.stdout.strip().split(",")]
            if len(parts) >= 4:
                stats["gpu_name"]      = parts[0]
                stats["vram_used_mb"]  = int(parts[1])
                stats["vram_total_mb"] = int(parts[2])
                stats["gpu_temp_c"]    = int(parts[3])
                if stats["vram_total_mb"] > 0:
                    stats["vram_percent"] = round(
                        stats["vram_used_mb"] / stats["vram_total_mb"] * 100, 1
                    )
    except Exception:
        pass

    try:
        loaded = get_loaded_models()
        if loaded:
            size_vram = loaded[0].get("size_vram", 0)
            if size_vram:
                stats["active_model_vram_mb"] = round(size_vram / 1024**2)
    except Exception:
        pass

    return jsonify(stats)


@app.route("/api/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "timestamp": datetime.now().isoformat()})


# ============================================================
# Shutdown
# ============================================================
def _terminate_proc(proc, name, timeout=5):
    if proc is None or proc.poll() is not None:
        return
    print(f"[*] Stopping {name} ...")
    proc.terminate()
    try:
        proc.wait(timeout=timeout)
        print(f"[OK] {name} stopped.")
    except subprocess.TimeoutExpired:
        proc.kill()
        print(f"[OK] {name} force-killed.")


def cleanup(signum=None, frame=None):
    global _sd_process, ollama_process
    print("\n[*] Shutting down ...")

    with sd_lock:
        sd_proc     = _sd_process
        _sd_process = None
    _terminate_proc(sd_proc, "sd", 5)
    _sd_executor.shutdown(wait=False, cancel_futures=True)

    if ollama_process is not None:
        _terminate_proc(ollama_process, "ollama.exe", 10)
        ollama_process = None
    else:
        print("[*] Ollama not owned by us, leaving it.")

    print("[OK] Bye!")
    sys.exit(0)


signal.signal(signal.SIGINT,  cleanup)
signal.signal(signal.SIGTERM, cleanup)


# ============================================================
# Entry
# ============================================================
if __name__ == "__main__":

    if not _IS_RELOADER:
        IMAGE_OUTPUT_DIR.mkdir(exist_ok=True)
        CHAT_HISTORY_DIR.mkdir(exist_ok=True)

        print()
        print("  +----------------------------------------------+")
        print("  |    AlphaInference Chat Server v1.0           |")
        print("  +----------------------------------------------+")
        print()

        if not is_port_free(SERVER_BIND_HOST, SERVER_PORT):
            print(f"[ERROR] Port {SERVER_PORT} is already in use!")
            sys.exit(1)
        print(f"[OK] Port {SERVER_PORT} is free.")

        managed_by_bat = os.environ.get("OLLAMA_MANAGED_BY_BAT", "0") == "1"

        if managed_by_bat:
            if is_ollama_running():
                print("[OK] Ollama running (managed by bat).")
            else:
                print("[WARN] Ollama not responding, trying from Python ...")
                start_ollama()
        else:
            print("[*] Standalone - Python manages Ollama.")
            if OLLAMA_EXE.exists():
                start_ollama()
            else:
                print("[WARN] Ollama not installed.")

        loaded = get_loaded_models()
        if loaded:
            print(f"[*] Clearing {len(loaded)} leftover model(s) from VRAM ...")
            unload_all_models()
            print("[OK] VRAM clean.")

        print()
        print("[*] Models for UI dropdowns:")
        try:
            r  = requests.get(f"{OLLAMA_API}/api/tags", timeout=5)
            ms = r.json().get("models", []) if r.status_code == 200 else []
            if ms:
                print("  Chat dropdown:")
                for m in ms:
                    print(f"    {m['name']}  ({m.get('size',0)/1024**3:.1f} GB)")
            else:
                print("  Chat dropdown: (empty)")
        except Exception:
            print("  Chat dropdown: (unavailable)")

        image_dir = MODELS_DIR / "image"
        if image_dir.exists():
            imgs = [
                f for f in sorted(image_dir.iterdir())
                if f.is_file()
                and f.suffix.lower() in {".safetensors", ".ckpt", ".gguf", ".bin"}
                and not is_partial_file(f)
            ]
            if imgs:
                print("  Image dropdown:")
                for f in imgs:
                    print(f"    {f.name}  ({f.stat().st_size/1024**3:.1f} GB)")
            else:
                print("  Image dropdown: (empty)")
        else:
            print("  Image dropdown: (no models dir)")

        local_url = f"http://127.0.0.1:{SERVER_PORT}"
        lan_ip = get_primary_lan_ip()
        print()
        print(f"[*] Chat UI (local): {local_url}")
        if SERVER_BIND_HOST == "0.0.0.0":
            if lan_ip:
                print(f"[*] Chat UI (LAN)  : http://{lan_ip}:{SERVER_PORT}")
            else:
                print("[*] Chat UI (LAN)  : enabled, but LAN IP detection failed")
            print("[*] Firewall note  : allow inbound TCP on the selected port")
        print(f"[*] Ctrl+C  : stop")
        print()

    try:
        app.run(
            host=SERVER_BIND_HOST,
            port=SERVER_PORT,
            debug=False,
            threaded=True,
            use_reloader=False,
        )
    except OSError as e:
        if "address already in use" in str(e).lower() or "10048" in str(e):
            print(f"[ERROR] Port {SERVER_PORT} became occupied!")
        else:
            raise
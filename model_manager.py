#!/usr/bin/env python3
"""
Model manager for LocalLacy.

Supports:
- local import (file/folder)
- direct URL download
- Hugging Face single-file or repo snapshot download
- unified model registry in models/index.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import tempfile
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

import requests
from huggingface_hub import hf_hub_download, snapshot_download


BASE_DIR = Path(__file__).parent.resolve()
MODELS_DIR = BASE_DIR / "models"
REGISTRY_PATH = MODELS_DIR / "index.json"
HF_CACHE_DIR = BASE_DIR / "vendor" / "hf_cache"

# Keep HF cache portable and stable across restarts when running model_manager directly.
os.environ.setdefault("HF_HOME", str(HF_CACHE_DIR))
os.environ.setdefault("HF_HUB_CACHE", str(HF_CACHE_DIR / "hub"))
os.environ.setdefault("HUGGINGFACE_HUB_CACHE", str(HF_CACHE_DIR / "hub"))

SUPPORTED_TASKS = {"chat", "image"}

TASK_EXTENSIONS = {
    "chat": {".gguf", ".bin"},
    "image": {".safetensors", ".ckpt", ".pt", ".pth", ".bin"},
}


def ensure_dirs() -> None:
    for task in SUPPORTED_TASKS:
        (MODELS_DIR / task).mkdir(parents=True, exist_ok=True)


def now_iso() -> str:
    return datetime.now().isoformat(timespec="seconds")


def to_rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(BASE_DIR.resolve())).replace("\\", "/")
    except Exception:
        return str(path.resolve()).replace("\\", "/")


def load_registry() -> dict[str, Any]:
    if not REGISTRY_PATH.exists():
        return {
            "version": 1,
            "updated_at": now_iso(),
            "models": [],
        }

    with open(REGISTRY_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    if not isinstance(data, dict):
        raise ValueError("Registry file is invalid JSON object")

    data.setdefault("version", 1)
    data.setdefault("updated_at", now_iso())
    data.setdefault("models", [])
    return data


def save_registry(data: dict[str, Any]) -> None:
    data["updated_at"] = now_iso()
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="registry_", suffix=".tmp", dir=str(REGISTRY_PATH.parent))
    os.close(fd)
    tmp_path = Path(tmp_name)

    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        tmp_path.replace(REGISTRY_PATH)
    finally:
        if tmp_path.exists():
            tmp_path.unlink(missing_ok=True)


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def compute_size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size

    total = 0
    for p in path.rglob("*"):
        if p.is_file():
            try:
                total += p.stat().st_size
            except OSError:
                pass
    return total


def _entry_local_abs(entry: dict[str, Any]) -> Path | None:
    local_path = str(entry.get("local_path", "")).strip()
    if not local_path:
        return None

    p = Path(local_path)
    if not p.is_absolute():
        p = BASE_DIR / p
    return p.resolve()


def _entry_health(entry: dict[str, Any]) -> tuple[str, int, str]:
    path = _entry_local_abs(entry)
    task = str(entry.get("task", "")).strip().lower()
    fmt = str(entry.get("format", "")).strip().lower()

    if path is None:
        return "broken", 0, "missing local_path"
    if not path.exists():
        return "broken", 0, f"missing path: {path}"

    size = compute_size(path)
    if size <= 0:
        return "broken", 0, f"empty path: {path}"

    return "ready", size, ""


def add_or_replace_registry_entry(entry: dict[str, Any]) -> dict[str, Any]:
    registry = load_registry()
    models = registry.get("models", [])

    new_models = []
    replaced = False
    for m in models:
        same_task = m.get("task") == entry.get("task")
        same_name = m.get("name") == entry.get("name")
        if same_task and same_name:
            new_models.append(entry)
            replaced = True
        else:
            new_models.append(m)

    if not replaced:
        new_models.append(entry)

    registry["models"] = new_models
    save_registry(registry)
    return entry


def make_entry(
    *,
    task: str,
    name: str,
    provider: str,
    source: str,
    fmt: str,
    local_path: Path,
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    size_bytes = compute_size(local_path)
    entry = {
        "id": str(uuid.uuid4()),
        "task": task,
        "name": name,
        "provider": provider,
        "source": source,
        "format": fmt,
        "local_path": to_rel(local_path),
        "size_bytes": size_bytes,
        "installed_at": now_iso(),
        "status": "ready",
    }
    if extra:
        entry.update(extra)
    return entry


def infer_format(path: Path) -> str:
    if path.is_dir():
        if (path / "model_index.json").exists():
            return "diffusers"
        return "directory"

    ext = path.suffix.lower()
    if ext:
        return ext.lstrip(".")
    return "unknown"


def safe_name(text: str) -> str:
    out = []
    for ch in text.strip():
        if ch.isalnum() or ch in ("-", "_", "."):
            out.append(ch)
        else:
            out.append("-")
    name = "".join(out).strip("-._")
    return name or "model"


def _task_expected_hint(task: str) -> str:
    if task == "chat":
        return "Expected chat model input: a .gguf file (or compatible chat model artifact)."
    return "Expected image model input: a .safetensors/.ckpt/.pt/.pth file or a compatible model folder."


def _validate_local_source(task: str, src: Path) -> bool:
    if src.is_file():
        ext = src.suffix.lower()
        allowed = TASK_EXTENSIONS.get(task, set())
        if ext and allowed and ext not in allowed:
            print(f"[WARN] File extension '{ext}' is unusual for task '{task}'.")
            print(f"       Common extensions: {', '.join(sorted(allowed))}")

        return True

    return True


def import_local(args: argparse.Namespace) -> int:
    src = Path(args.path).expanduser().resolve()
    task = args.task

    if task not in SUPPORTED_TASKS:
        print("[ERROR] task must be one of: chat, image")
        return 1

    if not src.exists():
        print(f"[ERROR] Path not found: {src}")
        print(f"        {_task_expected_hint(task)}")
        return 1

    if not _validate_local_source(task, src):
        return 1

    ensure_dirs()
    name = safe_name(args.name) if args.name else safe_name(src.stem if src.is_file() else src.name)
    source_path = src.resolve()

    if src.is_file():
        dst = MODELS_DIR / task / f"{name}{src.suffix.lower()}"
        dst.parent.mkdir(parents=True, exist_ok=True)
        if source_path != dst.resolve():
            shutil.copy2(src, dst)
        else:
            print("[*] Source already inside managed model directory. Registering in place.")
    else:
        dst = MODELS_DIR / task / name
        if source_path != dst.resolve():
            if dst.exists():
                print(f"[ERROR] Destination already exists (non-destructive mode): {dst}")
                print("        Choose a different model name or import from the existing destination path.")
                return 1
            shutil.copytree(src, dst)
        else:
            print("[*] Source already inside managed model directory. Registering in place.")

    fmt = args.format if args.format != "auto" else infer_format(dst)
    entry = make_entry(
        task=task,
        name=name,
        provider=args.provider,
        source=f"local:{src}",
        fmt=fmt,
        local_path=dst,
    )
    add_or_replace_registry_entry(entry)

    print(json.dumps({"status": "ok", "model": entry}, indent=2))
    return 0


def download_url(args: argparse.Namespace) -> int:
    task = args.task
    if task not in SUPPORTED_TASKS:
        print("[ERROR] task must be one of: chat, image")
        return 1

    ensure_dirs()

    model_name = safe_name(args.name)
    suffix = Path(args.filename).suffix if args.filename else ".bin"
    filename = args.filename if args.filename else f"{model_name}{suffix}"
    dst = MODELS_DIR / task / filename

    print(f"[*] Downloading: {args.url}")
    with requests.get(args.url, stream=True, timeout=60) as r:
        r.raise_for_status()
        with open(dst, "wb") as f:
            for chunk in r.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    f.write(chunk)

    if args.sha256:
        got = file_sha256(dst)
        if got.lower() != args.sha256.lower():
            dst.unlink(missing_ok=True)
            print(f"[ERROR] SHA256 mismatch. expected={args.sha256} got={got}")
            return 1

    fmt = infer_format(dst)
    entry = make_entry(
        task=task,
        name=model_name,
        provider="direct-url",
        source=args.url,
        fmt=fmt,
        local_path=dst,
        extra={"sha256": args.sha256 or ""},
    )
    add_or_replace_registry_entry(entry)

    print(json.dumps({"status": "ok", "model": entry}, indent=2))
    return 0


def hf_download(args: argparse.Namespace) -> int:
    task = args.task
    if task not in SUPPORTED_TASKS:
        print("[ERROR] task must be one of: chat, image")
        return 1

    ensure_dirs()

    repo_id = args.repo.strip()
    model_name = safe_name(args.name) if args.name else safe_name(repo_id.split("/")[-1])
    revision = args.revision.strip() or None
    token = args.token.strip() or None

    try:
        if args.file:
            local_cached = hf_hub_download(
                repo_id=repo_id,
                filename=args.file,
                token=token,
                revision=revision,
            )
            cached_path = Path(local_cached)
            out_name = safe_name(model_name)
            dst = MODELS_DIR / task / f"{out_name}{cached_path.suffix.lower()}"
            shutil.copy2(cached_path, dst)
            fmt = infer_format(dst)
            local_path = dst
        else:
            dst = MODELS_DIR / task / model_name
            if dst.exists() and any(dst.iterdir()):
                print(f"[*] Reusing existing folder (non-destructive): {dst}")

            allow_patterns = None
            if args.allow_patterns:
                allow_patterns = [p.strip() for p in args.allow_patterns.split(",") if p.strip()]

            snapshot_download(
                repo_id=repo_id,
                local_dir=str(dst),
                token=token,
                revision=revision,
                allow_patterns=allow_patterns,
            )
            fmt = infer_format(dst)
            local_path = dst

        entry = make_entry(
            task=task,
            name=model_name,
            provider="huggingface",
            source=f"hf:{repo_id}",
            fmt=fmt,
            local_path=local_path,
            extra={
                "repo_id": repo_id,
                "revision": revision or "",
                "download_mode": "file" if args.file else "snapshot",
            },
        )
        add_or_replace_registry_entry(entry)
        print(json.dumps({"status": "ok", "model": entry}, indent=2))
        return 0

    except Exception as e:
        print(f"[ERROR] Hugging Face download failed: {e}")
        return 1


def list_registry(_: argparse.Namespace) -> int:
    ensure_dirs()
    registry = load_registry()
    print(json.dumps(registry, indent=2))
    return 0


def init_registry(_: argparse.Namespace) -> int:
    ensure_dirs()
    if not REGISTRY_PATH.exists():
        save_registry({"version": 1, "updated_at": now_iso(), "models": []})

    registry = load_registry()
    models = registry.get("models", [])
    repaired = 0

    for m in models:
        status, size, note = _entry_health(m)
        old_status = str(m.get("status", "")).strip().lower()
        old_size = int(m.get("size_bytes", 0) or 0)

        m["status"] = status
        m["size_bytes"] = size
        if note:
            m["health_note"] = note
        else:
            m.pop("health_note", None)

        if old_status != status or old_size != size:
            repaired += 1

    registry["models"] = models
    save_registry(registry)
    print(json.dumps({
        "status": "ok",
        "registry": to_rel(REGISTRY_PATH),
        "repaired_entries": repaired,
        "non_destructive": True,
    }, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="LocalLacy model manager")
    sub = p.add_subparsers(dest="cmd", required=True)

    s_init = sub.add_parser("init", help="Initialize model registry and directories")
    s_init.set_defaults(func=init_registry)

    s_list = sub.add_parser("list", help="Print model registry as JSON")
    s_list.set_defaults(func=list_registry)

    s_import = sub.add_parser("import-local", help="Import local file/folder into models and register")
    s_import.add_argument("--task", required=True, choices=sorted(SUPPORTED_TASKS))
    s_import.add_argument("--path", required=True)
    s_import.add_argument("--name", default="")
    s_import.add_argument("--provider", default="local")
    s_import.add_argument("--format", default="auto")
    s_import.set_defaults(func=import_local)

    s_url = sub.add_parser("download-url", help="Download model from direct URL and register")
    s_url.add_argument("--task", required=True, choices=sorted(SUPPORTED_TASKS))
    s_url.add_argument("--url", required=True)
    s_url.add_argument("--name", required=True)
    s_url.add_argument("--filename", default="")
    s_url.add_argument("--sha256", default="")
    s_url.set_defaults(func=download_url)

    s_hf = sub.add_parser("download-hf", help="Download from Hugging Face and register")
    s_hf.add_argument("--task", required=True, choices=sorted(SUPPORTED_TASKS))
    s_hf.add_argument("--repo", required=True, help="repo id, e.g. org/model")
    s_hf.add_argument("--name", default="")
    s_hf.add_argument("--file", default="", help="single file in repo; if omitted uses snapshot")
    s_hf.add_argument("--allow-patterns", default="", help="comma-separated patterns for snapshot")
    s_hf.add_argument("--token", default="")
    s_hf.add_argument("--revision", default="")
    s_hf.set_defaults(func=hf_download)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""
GGUF Architecture Detector
Reads the GGUF file header (first few KB only) to extract
general.architecture and classify the model as 'chat' or 'image'.

Usage:  python gguf_detect.py <file.gguf>

Output (stdout):
    arch=<architecture_string>
    type=chat|image|unknown

Exit codes:
    0  success
    1  not a GGUF file or read error
"""

import os
import sys
import struct

# ── Classification tables ──────────────────────────────────────────────────

IMAGE_ARCHS = frozenset([
    "flux", "sd", "sdxl", "dit", "unet",
    "stable_diffusion", "stable-diffusion",
])

CHAT_ARCHS = frozenset([
    "llama", "qwen2", "qwen3", "mistral", "gemma", "gemma2", "gemma3",
    "phi2", "phi3", "phi4", "falcon", "mpt", "gpt2", "gptj", "gpt-neox",
    "gptneox", "refact", "bloom", "stablelm", "baichuan", "internlm",
    "internlm2", "minicpm", "deepseek", "deepseek2", "command-r", "cohere",
    "dbrx", "olmo", "arctic", "mamba", "rwkv", "granite", "starcoder",
    "codeshell", "chatglm", "glm4", "exaone", "nemotron", "solar", "plamo",
    "xverse", "orion", "openelm", "smollm", "bitnet", "jais", "t5encoder",
    "nomic-bert", "bert", "roberta", "wavtokenizer",
])


def _classify(arch: str) -> str:
    if arch is None:
        return "unknown"
    a = arch.lower()
    if any(a == ia or a.startswith(ia + "_") or a.startswith(ia + "-")
           for ia in IMAGE_ARCHS):
        return "image"
    if any(a == ca or a.startswith(ca + "_") or a.startswith(ca + "-")
           or a.startswith(ca + "2") or a.startswith(ca + "3")
           for ca in CHAT_ARCHS):
        return "chat"
    # Partial prefix match as last resort
    for ca in CHAT_ARCHS:
        if a.startswith(ca):
            return "chat"
    for ia in IMAGE_ARCHS:
        if a.startswith(ia):
            return "image"
    return "unknown"


# ── GGUF header parser ─────────────────────────────────────────────────────

_SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


def _skip_value(f, val_type: int):
    """Skip over one metadata value of the given type."""
    if val_type in _SIZES:
        f.read(_SIZES[val_type])
    elif val_type == 8:  # string
        slen = struct.unpack("<Q", f.read(8))[0]
        if slen > 1_000_000:
            raise ValueError(f"string too long: {slen}")
        f.read(slen)
    elif val_type == 9:  # array
        arr_type = struct.unpack("<I", f.read(4))[0]
        arr_len  = struct.unpack("<Q", f.read(8))[0]
        if arr_len > 1_000_000:
            raise ValueError(f"array too large: {arr_len}")
        for _ in range(arr_len):
            _skip_value(f, arr_type)
    else:
        raise ValueError(f"unknown value type: {val_type}")


def read_gguf_architecture(filepath: str):
    """
    Parse GGUF header and return (architecture, error).
    On success: (str, None).  On failure: (None, str).
    """
    try:
        with open(filepath, "rb") as f:
            if f.read(4) != b"GGUF":
                return None, "not_gguf"

            version = struct.unpack("<I", f.read(4))[0]
            if version < 1 or version > 3:
                return None, f"unsupported_version_{version}"

            if version == 1:
                _        = struct.unpack("<I", f.read(4))[0]  # tensor_count
                kv_count = struct.unpack("<I", f.read(4))[0]
            else:
                _        = struct.unpack("<Q", f.read(8))[0]  # tensor_count
                kv_count = struct.unpack("<Q", f.read(8))[0]

            # Scan KV pairs; cap at 512 for safety
            for _ in range(min(kv_count, 512)):
                key_len = struct.unpack("<Q", f.read(8))[0]
                if key_len > 512:
                    return None, "key_too_long"
                key      = f.read(key_len).decode("utf-8", errors="replace")
                val_type = struct.unpack("<I", f.read(4))[0]

                if val_type == 8:  # string
                    str_len = struct.unpack("<Q", f.read(8))[0]
                    if str_len > 1_000_000:
                        return None, "value_too_long"
                    value = f.read(str_len).decode("utf-8", errors="replace")
                    if key == "general.architecture":
                        return value, None
                else:
                    _skip_value(f, val_type)

            return None, "arch_not_found"

    except (OSError, struct.error, ValueError) as exc:
        return None, f"read_error: {exc}"


# ── Entry point ────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: gguf_detect.py <file.gguf>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]
    if not os.path.isfile(path):
        print("error=file_not_found")
        sys.exit(1)

    arch, err = read_gguf_architecture(path)

    if err == "not_gguf":
        print("error=not_gguf")
        sys.exit(1)
    if err:
        print(f"error={err}")
        sys.exit(1)

    model_type = _classify(arch)
    print(f"arch={arch}")
    print(f"type={model_type}")
    sys.exit(0)


if __name__ == "__main__":
    main()

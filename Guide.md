Here is the complete guide as a single downloadable markdown file. Save everything below as `README.md` in your AlphaInference folder.

````markdown
# AlphaInference - Complete Setup Guide

A self-contained Windows toolkit for running local LLM chat, image generation, and VS Code AI assistance with zero cloud dependencies.

AlphaBridge IT Solution™

---

## Table of Contents

1. [What This Is](#what-this-is)
2. [Suggested Hardware](#suggested-hardware)
3. [Quick Start](#quick-start)
4. [File Structure](#file-structure)
5. [Installation Walkthrough](#installation-walkthrough)
6. [Downloading Models](#downloading-models)
7. [Using the Chat Interface](#using-the-chat-interface)
8. [Image Generation](#image-generation)
9. [VS Code Integration (Continue)](#vs-code-integration-continue)
10. [Troubleshooting](#troubleshooting)
11. [Advanced Topics](#advanced-topics)
12. [Architecture Reference](#architecture-reference)
13. [Quick Command Reference](#quick-command-reference)
14. [License & Credits](#license--credits)

---

## What This Is

AlphaInference is the portable local AI toolkit distributed by AlphaBridge IT Solution™. It is designed as a self-contained Windows setup that lets you:

- **Chat with LLMs locally** (Llama, Gemma, Mistral, DeepSeek Coder, etc.) via Ollama
- **Generate images locally** with Stable Diffusion variants
- **Use VS Code AI assistance** via Continue extension pointing to your local models
- **Run completely offline** after initial setup
- **Stay portable** — entire setup lives in one folder, can be moved between PCs
- **Work without admin rights** — no system modifications, no installs

```
┌───────────────────────────────────────────────────────┐
│              YOUR LOCAL MACHINE ONLY                  │
│                                                       │
│   ┌─────────────┐    ┌─────────────────────────┐      │
│   │   Browser   │◄──►│  Flask Server (Python)  │      │
│   │  port 5000  │    │      chat_server.py     │      │
│   └─────────────┘    └────────┬────────────────┘      │
│                               │                       │
│                  ┌────────────┴──────────┐            │
│                  ▼                       ▼            │
│           ┌──────────────┐       ┌──────────────┐     │
│           │    Ollama    │       │   sd-cli     │     │
│           │  port 11434  │       │  (on-demand) │     │
│           └──────┬───────┘       └──────┬───────┘     │
│                  │                      │             │
│                  ▼                      ▼             │
│        models\ollama\           models\image\         │
│        (chat models)            (.safetensors)        │
│                                                       │
└───────────────────────────────────────────────────────┘
         No internet required after setup
         No data leaves your computer
```

---

## Suggested Hardware

AlphaInference works on a wide range of Windows machines, but model selection should match your hardware. Below are practical suggestions, not strict requirements — pick a model size that fits your specs.

### Recommended Baseline

Windows 10 (1809+) or Windows 11. At least 8 GB RAM, ideally 16+ GB. 20 GB free disk space (models eat space fast). An x64 CPU with AVX2 support (any CPU from 2015 onwards). NVIDIA GPU with 6+ GB VRAM strongly recommended for images. Internet only required for initial download. No admin rights needed.

### Model Size Suggestions by Hardware

| Your RAM | Recommended Model Size | Examples |
|----------|----------------------|----------|
| 8 GB | 1-3 B parameters | llama3.2:1b, qwen2.5-coder:1.5b |
| 16 GB | 3-7 B parameters | llama3.1:8b, mistral:7b |
| 32 GB | 7-13 B parameters | llama3.1:8b, codellama:13b |
| 64+ GB | 13-70 B parameters | mixtral:8x7b, llama3.1:70b |

| Your VRAM | Image Models That Fit |
|-----------|----------------------|
| 4 GB | SD 1.5, SD Turbo (tight) |
| 6 GB | SD 1.5, SD Turbo, DreamShaper 8, Realistic Vision (recommended sweet spot) |
| 8 GB | All SD 1.5 variants + experimental SDXL Turbo |
| 12+ GB | Full SDXL, SD 3 variants |

The installer auto-detects your specs and only shows model options that fit. You can always download anything via the HuggingFace browser if you want to push limits.

### When to Worry

If you have less than 8 GB RAM, stick to 1B models. Chat will be slow but usable, and you should skip image generation entirely. Without an NVIDIA GPU, chat still works but is slower (CPU inference) and image generation takes 45-90 seconds per image — consider Ollama models in Q4 quantization only. If you have less than 20 GB disk free, pick one small model and skip image generation. If PowerShell is blocked by group policy, system info will show defaults (4 GB RAM, Unknown CPU) but everything else still works; manually verify with `powershell -Command "..."` commands shown in the [Quick Command Reference](#quick-command-reference).

---

## Quick Start

This guide assumes you are using the AlphaBridge IT Solution™ packaged distribution of AlphaInference in a single portable folder.

Create a folder anywhere (e.g., `E:\AlphaInference\`). Avoid paths with special characters. Spaces are OK — the script handles them. Avoid OneDrive folders to prevent sync conflicts during downloads.

Drop these core files into the folder: `install.bat`, `start_chat.bat`, `chat_server.py`, `chatUI.html`, and `model_manager.py`.

Double-click `install.bat`. The menu appears. Choose `[1] Setup and Install`. Wait for downloads (Python ~10 MB, Ollama ~150 MB, SD ~50 MB).

From the menu, choose `[2] Download / Import Models`, then `[1] Recommended Models`. Pick one based on your hardware — the script auto-suggests options that fit your RAM and VRAM.

From the main menu, choose `[4] Start Chat Server`. The browser auto-opens at `http://127.0.0.1:5000`. Select your model from the dropdown and start chatting.

---

## File Structure

After installation, your folder will look like this:

```
AlphaInference/                         ← anywhere on disk
│
├── install.bat                         ← YOU PROVIDE - menu-driven installer
├── start_chat.bat                      ← YOU PROVIDE - launches everything
├── chat_server.py                      ← YOU PROVIDE - Flask backend
├── chatUI.html                         ← YOU PROVIDE - web interface
│
├── vendor/                             ← created by install.bat
│   ├── python/                         ← embedded Python 3.11
│   │   ├── python.exe
│   │   └── Lib/site-packages/
│   ├── ollama/
│   │   └── ollama.exe                  ← LLM runtime
│   ├── stable-diffusion/
│   │   ├── sd-cli.exe                  ← image generator
│   │   └── stable-diffusion.dll        ← required next to exe
│   ├── ollama_home/                    ← Ollama config (portable)
│   ├── temp/                           ← scratch space
│   └── hf_cache/                       ← HuggingFace cache
│
├── models/
│   ├── ollama/                         ← Ollama model store (portable!)
│   ├── chat/                           ← downloaded GGUF files
│   └── image/                          ← .safetensors for SD
│       ├── sd-v1-5.safetensors
│       └── dreamshaper_8.safetensors
├── chat_history/                       ← saved conversations
│   └── *.json                          ← one file per chat session
│
└── generated_images/                   ← SD output
    ├── img_20240101_120000_abc.png
    └── img_20240101_120000_abc.json    ← sidecar metadata

└── model_manager.py                    ← multi-source model import/download helper
```

---

## Installation Walkthrough

The installation flow below refers to the AlphaBridge IT Solution™ portable distribution and its bundled setup scripts.

### Step 1: Run install.bat

You will see the main menu:

```
+----------------------------------------------------------+
|         AlphaInference - Local LLM Manager               |
|            Run AI Models 100% Offline                    |
+----------------------------------------------------------+
|   [1] Setup and Install  (First Time)                    |
|   [2] Download / Import Models                           |
|   [3] Uninstall / Remove Models                          |
|   [4] Start Chat Server                                  |
|   [5] System Info + All Imported Models                  |
|   [6] Exit                                               |
+----------------------------------------------------------+
| Tool: curl  Resume: YES  Sys: pscim                      |
+----------------------------------------------------------+
```

The tool indicators at the bottom tell you what the AlphaBridge IT Solution™ installer detected on your machine. `Tool: curl` is best (built-in to Windows 10+ and supports resume). `Tool: bitsadmin` is the fallback (works but slower). `Tool: certutil` is the last resort with no resume support. `Resume: YES` means downloads can be paused and resumed; `NO` means they must complete in one go. `Sys: pscim` uses PowerShell for system info (preferred); `Sys: wmic` uses legacy wmic on older Windows.

### Step 2: Choose [1] Setup and Install

This downloads three things in order. First, Python 3.11 embedded (~10 MB) along with pip packages: flask, flask-cors, requests, huggingface_hub, tqdm, and psutil. Second, Ollama LLM runtime (~150 MB) which resolves to `vendor\ollama\ollama.exe`. Third, Stable Diffusion.cpp (~50 MB) which auto-detects the latest CPU-only build (avoids CUDA issues), giving you `sd-cli.exe` plus `stable-diffusion.dll`. This last one is optional — if it fails, image generation just won't work but chat will be fine.

Each download shows a progress bar with speed and ETA, auto-retries on network failures (up to 10 attempts), resumes from partial files if interrupted, and verifies file size before considering complete.

### Step 3: Verify Installation

After install completes, you'll see a summary:

```
==========================================================
 SUMMARY
==========================================================

 [OK]  Python
 [OK]  Ollama
 [OK]  SD.cpp (sd-cli.exe)
 [OK]  Server
 [OK]  UI

 Passed: 5  Failed: 0
 All set!
```

If you see `[FAIL]` anywhere, check the [Troubleshooting](#troubleshooting) section below.

---

## Downloading Models

### Method 1: Recommended Models (Easiest)

Navigate to `Main menu → [2] Download / Import Models → [1] Recommended Models`. The system detects your hardware automatically and shows fitting options:

```
RAM: 32 GB  VRAM: 6 GB  GPU: NVIDIA RTX A3000

-- Chat Models --
[1] llama3.1:8b        ~4.7 GB   General purpose
[2] codellama:13b      ~7.4 GB   Code generation
[3] mixtral:8x7b       ~26  GB   Mixture of experts
[4] gemma2:9b          ~5.5 GB   Google

-- Image Models --
[5] Stable Diffusion 1.5  ~4.0 GB   Best quality
[6] SD Turbo              ~2.0 GB   Faster
[7] DreamShaper 8         ~2.0 GB   Better details
```

Pick a number and it downloads via Ollama (for chat models) or direct download (for image models).

### Method 2: HuggingFace Download

For any model on HuggingFace, navigate to `Main menu → [2] Download / Import Models → [2] Download from HuggingFace`. Enter the repo URL or ID (example: `TheBloke/Llama-2-7B-GGUF`). You can paste a HuggingFace token if you have one (free at `huggingface.co/settings/tokens` and gives 5-20x faster speeds), or press Enter to skip.

The system lists all model files in the repo:

```
[1] llama-2-7b.Q4_K_M.gguf  (3.83 GB)
[2] llama-2-7b.Q5_K_M.gguf  (4.78 GB)
[3] llama-2-7b.Q8_0.gguf    (6.86 GB)
[4] Cancel
```

Pick one, confirm, and the download starts with a real-time progress bar. The script auto-imports GGUF files into Ollama and auto-saves SafeTensors into the image models folder.

### Method 3: Import Local File

If you already have a `.gguf` or `.safetensors` file, navigate to `Main menu → [2] Download / Import Models → [3] Import Local File`. Enter the full file path. GGUF files register with Ollama (the script asks for a friendly name). SafeTensors files copy to the `models\image\` folder.

### Method 4: Model Manager (Chat / Image)

Navigate to `Main menu → [2] Download / Import Models → [8] Model Manager`.

This menu supports:

- Hugging Face repo snapshots for multi-file models
- Direct URL downloads with optional SHA256 verification
- Local file or folder import
When importing local models through Model Manager, the flow is now **non-destructive**:

- Existing folders are not auto-deleted or overwritten
- Registry repair updates status/health metadata only
- Invalid entries are marked as `broken` instead of removing your files

Expected local inputs by task:

- Chat: typically `.gguf`
- Image: typically `.safetensors`, `.ckpt`, `.pt`, `.pth`

**Important: model names cannot contain spaces!** Bad: `"Qwen Coder 1.5B"` fails with "accepts 1 arg(s), received 3" error. Good: `qwen-coder-1.5b`, `qwen_coder_1.5b`, or `qwencoder1.5b`. The script auto-sanitizes spaces to hyphens, but be aware of this rule.

### Recommended Models by Use Case

For general chat, try `llama3.1:8b` (best balance of speed and quality), `gemma2:9b` (Google's instruct-tuned model), or `mistral:7b` (fast, good general purpose). For coding tasks, use `qwen2.5-coder:7b` (excellent code completion), `codellama:13b` (Meta's code model), or `deepseek-coder-v2:16b` (very strong for complex tasks). For small/fast on systems under 8GB RAM, try `llama3.2:1b` (tiny but capable), `llama3.2:3b` (good balance for low RAM), or `phi3:mini` (Microsoft compact).

For image generation on 6GB VRAM, DreamShaper 8 is the best all-around recommendation. Realistic Vision V6.0 is great for photorealism. SD Turbo is very fast and needs fewer steps. Stable Diffusion 1.5 is the vanilla baseline.

---

## Using the Chat Interface

### Launching

Use `Main menu → [4] Start Chat Server` or just double-click `start_chat.bat` directly. The script checks Python and chat_server.py are present, verifies port 5000 is free, starts Ollama (if not already running), launches the Python server, and opens your browser to `http://127.0.0.1:5000`.

### UI Layout

```
┌────────────────┬──────────────────────────────────────────────┐
│ 🧠 AlphaInference │  Chat model: [llama3.1:8b ▾] ● ready 💬 🎨 │
│ [+ New Chat]   ├──────────────────────────────────────────────┤
│                │ CPU 12% ██  RAM 8.2/32 ●  VRAM 4.5/6 GB      │
│ 💬 Chat 1      ├──────────────────────────────────────────────┤
│ 💬 Chat 2      │                                              │
│ 💬 Chat 3      │   Conversation goes here                     │
│                │                                              │
│                │                                              │
│                │                                              │
│                │                                          [↓] │
│                ├──────────────────────────────────────────────┤
│                │ [Type your message ...........] [▶]         │
└────────────────┴──────────────────────────────────────────────┘
```

### Features

The top bar controls are now tab-scoped:

- In **Chat** mode, only chat-related controls are shown (chat model selector, chat/model status).
- In **Image** mode, image-related controls stay in the image panel and the image job status is shown in the top bar.

Additional UI behavior now included in the current build:

- **Dark mode toggle** in the top bar with persistent preference.
- **Sidebar collapse** button with mobile scrim/overlay behavior.
- **Access URL bar** that shows Local and LAN URLs (or LAN-disabled status).
- **Responsive mode tabs** (Chat/Image) with full-width behavior on small screens.

The **chat dropdown** switches models, automatically unloads the old one from VRAM, and loads the new one. Only ONE model stays in VRAM at any time.

The **stats bar** is a live system monitor refreshing every 3 seconds. It shows CPU usage with a bar, RAM used/total with a bar, VRAM used/total (if NVIDIA GPU detected), GPU temperature, currently loaded model plus its VRAM footprint. Color codes: green under 70%, orange 70-90%, red over 90%.

**Markdown rendering** for bot responses supports bold, italic, inline code, fenced code blocks with syntax highlighting and a Copy button, numbered and bulleted lists, and headers. Code blocks preserve their original formatting — no markdown bleeds through.

**Copy buttons** appear when you hover any bot message (at the bottom of the bubble). Each code block also has its own Copy button in the header.

**Smart auto-scroll** automatically scrolls to the bottom while the bot is responding. If you scroll up to read older messages, auto-scroll pauses. Click the ↓ button (appears at bottom-right) to jump back to the latest message.

The **stop button** turns into a red ⏹ during generation. Clicking it sends an abort signal to the server which closes the upstream Ollama connection immediately — no wasted GPU cycles.

**Chat history** auto-saves every conversation to `chat_history/*.json`. It survives page refresh and server restart. The sidebar lists all past chats with delete buttons.

### Keyboard Shortcuts

`Enter` sends the message. `Shift+Enter` adds a new line in the message. `Escape` closes the image modal. `Ctrl+C` in the cmd window stops the server.

### Refresh Recovery

If you refresh the page during chat generation, streaming stops on the browser side and the server's connection to Ollama closes. When the page reloads, your conversation history is there but the last assistant message may be partial — just continue chatting.

If you refresh during image generation, the generation continues server-side. When the page reloads, it detects the active job via `/api/generate-image/status`, auto-switches to Image mode, shows a spinner with elapsed time, pre-fills the form with the job's settings, and updates the gallery when complete.

Chat requests are serialized server-side so only one chat stream runs at a time. Additional chat requests wait in queue and the UI shows queue state. Image generation is single-active: if an image job is already running, the server rejects new image requests instead of silently queueing them.

---

## Image Generation

### Switch to Image Mode

Click the **Image** tab in the top mode toggle row.

### Configuration

```
┌─────────────────────────────────────────────────────────┐
│ 🎨 Image Generation                                     │
├─────────────────────────────────────────────────────────┤
│ Prompt                                                  │
│ [A fluffy orange cat sitting on a windowsill, golden..] │
│                                                         │
│ Negative Prompt                                         │
│ [blurry, low quality, deformed, ugly]                   │
│                                                         │
│ Image Model        │  Sampler                           │
│ [dreamshaper_8 ▾] │  [Euler Ancestral ▾]              │
│                                                         │
│ Steps: [20]  ████████░░░░  CFG: [7.5] ██████░░       │
│                                                         │
│ Width [512▾]  Height [512▾]  Seed [-1]                 │
│                                                         │
│         [🎨 Generate]                                   │
└─────────────────────────────────────────────────────────┘
```

### Settings That Matter

For the **prompt**, be specific. "A cat" produces generic output. Try: "a fluffy orange tabby cat sitting on a wooden windowsill, golden hour lighting, photorealistic, sharp focus, 8k".

For the **negative prompt**, always include: "blurry, low quality, bad anatomy, deformed, ugly, jpeg artifacts" plus specific things to avoid for your use case.

For **steps**, the default 20 gives decent quality. 30-40 is noticeably better detail. 50+ has diminishing returns. SD Turbo only needs 1-4 steps.

For **CFG scale**, 1-5 ignores the prompt, 6-8 is the sweet spot (recommended), 9-12 follows the prompt strongly but may show artifacts, 13+ is often distorted or oversaturated.

For **dimensions**, 512x512 is the default and fastest. 768x768 gives better detail (most modern models were trained on this). 1024x1024 is the maximum for SD 1.5 family. For non-square images use 768x512 (landscape) or 512x768 (portrait).

For the **sampler**, Euler Ancestral (`euler_a`) is the default and smooth. You now have expanded sampler choices including `heun`, `dpm2`, `dpm++2s_a`, `dpm++2mv2`, `ipndm`, `ipndm_v`, `ddim_trailing`, `tcd`, `res_multistep`, `res_2s`, `er_sde`, `euler_cfg_pp`, and `euler_a_cfg_pp` in addition to `euler`, `dpm++2m`, and `lcm`. The UI now shows a short sampler description under the selector to help pick the right method.

For **seed**, `-1` is random each time. A specific number like `12345` produces reproducible results. Save a great seed to regenerate variations.

### Gallery

Generated images appear at the top of the gallery (newest first). Each card shows a thumbnail (click to enlarge), the prompt (or filename if metadata is missing), dimensions and settings, and a delete button (✕, appears on hover). The gallery persists across refreshes. All images plus metadata are stored in `generated_images/`.

### Performance Expectations

| Hardware | Model | 512x512 / 20 steps |
|----------|-------|-------------------|
| CPU only | SD 1.5 | 45-90 seconds |
| RTX 3060 (6GB) | SD 1.5 | 8-12 seconds |
| RTX 4070 (12GB) | SD 1.5 | 4-6 seconds |
| RTX 4070 (12GB) | SDXL Turbo (4 steps) | 2-3 seconds |

If you see a `cudart64_12.dll not found` popup, you have the wrong SD.cpp build. Delete `vendor\stable-diffusion\` contents and re-run install.bat, which now defaults to the CPU build. See [Troubleshooting](#troubleshooting).

### Safety Limits

The current server enforces several request limits for stability:

- Chat: maximum 80 messages per request, 8,000 characters per message, and 50,000 characters total
- Image prompts: 2,000 characters max for prompt and negative prompt
- Image dimensions: 256-1024 per side
- Image steps: 1-100
- Image CFG: 1-20
These limits are designed to prevent accidental lockups and unbounded queue growth on local machines.

---

## VS Code Integration (Continue)

The Continue extension can use your local Ollama for chat, code completion, and refactoring.

### Setup

Install the Continue extension in VS Code. Open the Continue panel. Edit the config via `Ctrl+Shift+P → "Continue: Open Config"`. Replace it with the config below. Save and reload Continue.

### Recommended Config (`~/.continue/config.yaml`)

```yaml
name: Main Config
version: 1.0.0
schema: v1

models:
  # Your big model for chat, edit, apply
  - name: Llama 3.1 Coder
    provider: ollama
    model: llama3.1:8b
    apiBase: http://127.0.0.1:11434
    roles:
      - chat
      - edit
      - apply
    defaultCompletionOptions:
      contextLength: 8192
      temperature: 0.2

  # Small fast model for autocomplete (suggestions as you type)
  - name: Qwen Coder Autocomplete
    provider: ollama
    model: qwen2.5-coder:1.5b-base
    apiBase: http://127.0.0.1:11434
    roles:
      - autocomplete
    defaultCompletionOptions:
      contextLength: 4096
      temperature: 0

context:
  - provider: code
  - provider: docs
  - provider: diff
  - provider: terminal
  - provider: problems
  - provider: folder
  - provider: codebase
```

### Key Points

Do NOT use port 5000 (that's your Flask UI). DO use port 11434 (that's Ollama's API). Wrong: `apiBase: http://127.0.0.1:5000/api`. Correct: `apiBase: http://127.0.0.1:11434`. The model name must EXACTLY match `ollama list` output, including any `:latest` or `:8b` suffix.

### Verify Model Names

Run:

```
cd vendor\ollama
ollama.exe list
```

You'll see something like:

```
NAME                          ID            SIZE
llama3.1:8b                   abc123        4.7 GB
qwen2.5-coder:1.5b-base       def456        980 MB
```

Use these exact strings in your Continue config.

### Recommended Coding Models

For autocomplete (small, fast, runs constantly): `qwen2.5-coder:1.5b-base` (980 MB, fastest, decent), `qwen2.5-coder:3b-base` (1.9 GB, better quality), or `starcoder2:3b` (1.9 GB, alternative).

For chat/edit (larger, called on-demand): `qwen2.5-coder:7b` (4.7 GB, excellent), `codellama:13b` (7.4 GB, Meta's offering), or `deepseek-coder-v2:16b` (9.2 GB, very strong).

---

## Troubleshooting

### Window closes immediately

The script crashed before reaching pause. To diagnose, open cmd manually and run from there:

```
cd /d "E:\YourFolder"
install.bat
```

Now you can see the error message before the window closes. Common causes: syntax error in a recent edit, missing closing parenthesis, `%TEMP_DIR%` used before being defined, or PowerShell blocked by group policy.

### Port 5000 already in use

Another program is using port 5000. Find what's using it:

```
netstat -ano | findstr ":5000"
```

You'll see a PID. Kill that process or change the port. To change the port, edit `chat_server.py`:

```python
SERVER_PORT = 5000   # ← change to 5001 or any free port
```

Remember to access it at `http://127.0.0.1:NEW_PORT`.

### sd.exe / sd-cli.exe missing CUDA DLLs

Error popup: "cudart64_12.dll not found". The downloaded SD build expects CUDA toolkit installed. Solution: switch to the CPU-only build. Delete contents of `vendor\stable-diffusion\`. Run `install.bat`. Choose `[1] Setup and Install`. SD.cpp will re-download (the script now prefers the CPU build).

Alternatively, download manually from `https://github.com/leejet/stable-diffusion.cpp/releases`. Get `sd-master-XXX-bin-win-avx2-x64.zip`. Extract `sd-cli.exe` AND `stable-diffusion.dll` to `vendor\stable-diffusion\`.

### Model has spaces error: "accepts 1 arg(s), received 3"

Ollama model names cannot have spaces. Fix: use `my-model` ✓ or `my_model` ✓, not `My Model 1B` ✗ (will fail). The `install.bat` now auto-sanitizes spaces to hyphens, but type without spaces from the start to be safe.

### "Model not found" in Continue

The name in your config doesn't match what Ollama has. Run `vendor\ollama\ollama.exe list`. Copy the EXACT name including any `:tag` suffix. Update your Continue config:

```yaml
model: llama3.1:8b        # must match exactly, including the :8b part
```

### HuggingFace download starts from 0 after refresh

The new script saves partials as `models\chat\filename.gguf.partial`. Earlier versions used HuggingFace's internal cache structure that varies by library version. If your old partial exists at `models\chat\.cache\huggingface\download\*.incomplete`, you can rename it to match the new scheme:

```
move ".cache\huggingface\download\xxxx.incomplete" 
     "models\chat\filename.gguf.partial"
```

Otherwise just re-download. The modern script saves visibly at `models\chat\filename.gguf.partial` so you can see progress.

### Slow HuggingFace downloads (1 MB/s)

HuggingFace throttles anonymous downloads. Solution: get a free token (5-20x faster). Sign up at `https://huggingface.co/join`. Go to `https://huggingface.co/settings/tokens`. Create a new token with Read access. Copy the token (starts with `hf_...`). Next download, paste it where prompted. Speeds typically go from 1 MB/s to 10-50 MB/s.

### System Info shows wrong RAM/CPU

PowerShell may be blocked. The script falls back to wmic which sometimes fails on modern Windows 11. Manual verification:

```
powershell -Command "(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB"
```

This should print your actual RAM in GB. If PowerShell is blocked entirely, defaults will show (4 GB RAM, Unknown CPU/GPU). This is cosmetic only — everything still works. Model recommendations will just be conservative.

### Ollama already running but Python can't connect

Race condition between two start attempts. Fix by killing all Ollama processes:

```
taskkill /f /im ollama.exe
```

Then start fresh via `start_chat.bat`. The `start_chat.bat` script is the AUTHORITATIVE Ollama manager. Python trusts it and doesn't start a second instance.

### Stats bar bars not filling (just numbers change)

CSS issue — bars need explicit `display:inline-block`. This is fixed in the current `chatUI.html`. If you see this, your `chatUI.html` is from an older version. Re-grab the current file from the latest version.

### Browser doesn't auto-open

The browser helper script failed to write or run. Open manually: `http://127.0.0.1:5000`. Common cause: `TEMP_DIR` variable wasn't set in `start_chat.bat` (the current version handles this correctly).

### Image generation works but image not showing in gallery

First check the file was actually created: `dir generated_images\*.png`. If the file exists, check the browser console (F12) for errors. The URL should be `/generated_images/filename.png`. Backslash bug (fixed in current version): old code produced `image_url = "/generated_images\filename.png"` which breaks the browser; new code produces `image_url = "/generated_images/filename.png"` which works correctly.

---

## Advanced Topics

### Move to USB Drive / Different PC

The entire setup is portable. Copy the whole folder (`AlphaInference/`) to a USB drive. On the new PC, just run `start_chat.bat` from the USB.

This works because all paths are relative to the script location. Ollama models are stored in `models\ollama` (not the user profile). The `OLLAMA_MODELS` env var is set by `start_chat.bat`. Python is embedded, so no system Python needed.

Size estimates: minimum (no models) ~250 MB. With a small chat model ~3 GB. With full setup 10-50 GB.

### Use Different Port

Set an environment variable before starting:

```bat
set ALPHA_SERVER_PORT=5001
start_chat.bat
```

Or set it permanently in your shell/profile scripts. The UI uses relative URLs, so no `chatUI.html` edits are needed.

### Access from Other Devices on Your Network

By default, `start_chat.bat` now keeps LAN exposure **OFF** (`127.0.0.1` only). To allow other devices:

```bat
set ALPHA_EXPOSE_LAN=1
start_chat.bat
```

Then from other devices on the same wifi: `http://YOUR_PC_IP:5000`. Find your IP with `ipconfig | findstr "IPv4"`.

⚠️ **SECURITY WARNING**: This exposes your chat server to the network. Anyone on your network can use it. No authentication is built in. Only do this on trusted networks (home, not coffee shops).

### Restricted / Group-Policy Windows

For locked-down laptops and non-admin users, use these startup knobs:

- Keep network local-only (default): `set ALPHA_EXPOSE_LAN=0`
- Reuse existing Ollama process without forced kill/restart (default): `set ALPHA_RESTART_OLLAMA=0`
- Force restart Ollama only when needed for portable model store routing: `set ALPHA_RESTART_OLLAMA=1`

The scripts now prefer `powershell.exe`, then `pwsh.exe`, and gracefully fall back to legacy methods (`wmic`, `ipconfig`) when PowerShell is restricted.

### Multiple Chat Models Loaded

By default, the system enforces ONE model in VRAM at a time:

```python
# In load_model():
loaded = get_loaded_models()
for m in loaded:
    if m.name != requested:
        unload_ollama_model(m.name)
```

To allow multiple models loaded simultaneously, remove this loop. But VRAM usage stacks: two 4.7 GB models = 9.4 GB VRAM. Switching contexts becomes slow. Most home GPUs can't handle this.

A better approach is to use the `keep_alive` parameter:

```python
# Keep model loaded for 30 minutes after last use
{"model": "llama3.1:8b", "keep_alive": "30m"}

# Keep loaded indefinitely (until restart)
{"model": "llama3.1:8b", "keep_alive": "-1"}
```

### Customize System Prompts

In `chat_server.py`, find the `/api/chat` route:

```python
if data.get("system"):
    payload["system"] = data["system"]
```

The UI can send a `system` field but currently doesn't. To add a system prompt globally:

```python
# Force a system prompt for all requests:
payload["system"] = "You are a helpful expert programmer..."
```

Or add a UI field in `chatUI.html` for per-conversation system prompts.

### Add More Recommended Models

Edit `install.bat` and find the `:DOWNLOAD_RECOMMENDED` section. Add lines like:

```batch
set /a MC+=1 & echo   [!MC!] your-model:7b     ~4.0 GB   Description    & set "M!MC!=your-model:7b"
```

The model must be available on Ollama's registry (`ollama.com/library`).

For image models, add a new IF block:

```batch
if "!SEL!"=="MY_MODEL" (
    set "IMF=%MODELS_DIR%\image\my-model.safetensors"
    if exist "!IMF!" (
        echo  [SKIP] Already downloaded.
    ) else (
        set "_DL_URL=https://huggingface.co/.../my-model.safetensors"
        set "_DL_OUT=!IMF!"
        set "_DL_NAME=My Model"
        call :DO_DOWNLOAD
    )
    pause & goto DOWNLOAD_RECOMMENDED
)
```

### Backup Your Setup

Back up these directories: `chat_history/` (your conversations), `generated_images/` (your AI images), `models/image/` (downloaded SD models), `models/ollama/` (downloaded chat models).

You can re-download these if needed: `vendor/` (Python, Ollama, SD binaries), `vendor/temp/` (scratch files), `vendor/hf_cache/` (HuggingFace cache).

A 7-Zip archive of the folder is the easiest backup.

### Reset Everything

Navigate to `Main menu → [3] Uninstall / Remove Models → [4] Full Cleanup`. This removes all Ollama chat models, all image models, all temp/cache files, all generated images, all chat history, and partial downloads. It keeps `vendor/` (Python, Ollama, SD) and your 4 source files.

To completely start over: just delete the entire folder, re-create with the 4 source files, and run `install.bat`.

---

## Architecture Reference

### Data Flow: Chat Message

```
USER TYPES "Hello"
   │
   ▼
chatUI.html: sendMessage()
   │ POST /api/chat {model, messages}
   ▼
Flask: @app.route("/api/chat")
   │ requests.post(OLLAMA_API + "/api/chat", stream=True)
   ▼
Ollama (port 11434)
   │ Loads model into VRAM if not already there
   │ Streams tokens as Server-Sent Events
   │
   ▼ each token
Flask: yield "data: {...}\n\n"
   │
   ▼ over HTTP stream
chatUI.html: reader.read()
   │ Parses SSE chunks
   │ Renders markdown
   │ Updates DOM
   │
   ▼
USER SEES RESPONSE STREAMING

USER CLICKS STOP
   │
   ▼
chatUI.html: AbortController.abort()
   │ Closes browser-side connection
   ▼
Flask: GeneratorExit raised
   │ finally: ollama_resp.close()
   ▼
Ollama: sees closed socket, stops generating
   │ Frees GPU immediately
   ▼
NO WASTED COMPUTE
```

### Data Flow: Image Generation

```
USER FILLS FORM, CLICKS GENERATE
   │
   ▼
chatUI.html: generateImage()
   │ POST /api/generate-image {prompt, model, steps, ...}
   ▼
Flask: @app.route("/api/generate-image")
   │ Pre-flight: _check_sd_runnable()
   │   ├── Tries sd-cli.exe --help
   │   ├── Catches CUDA/Vulkan DLL errors
   │   └── Returns clean error if SD broken
   │
   │ Resolves model path
   │ Builds command list (no shell injection)
   │ Submits to _sd_executor (dedicated worker thread)
   │
   ▼
SD Worker Thread: _run_sd()
   │ With sd_lock:
   │   - Publishes job info to _sd_current_job
   │   - Spawns sd-cli.exe subprocess
   │   - Records process in _sd_process
   │
   │ Waits on proc.communicate() (blocks worker, not Flask)
   │
   ▼
sd-cli.exe runs
   │ Loads model (.safetensors)
   │ Runs diffusion steps
   │ Writes PNG to generated_images/
   │
   ▼
SD Worker: completion
   │ With sd_lock:
   │   - Checks _sd_cancelled flag
   │   - Clears _sd_process
   │   - Writes sidecar JSON with metadata
   │ Returns result dict
   │
   ▼
Flask: returns JSON to browser
   │
   ▼
chatUI.html: adds image to gallery

DURING THIS, OTHER REQUESTS WORK:
   /api/stats updates the stats bar
   /api/chat can stream LLM responses
   Flask threading=True + dedicated SD worker = no blocking
```

### Threading Model

```
Flask Thread Pool (default size)
├── Thread 1: serves /api/chat streaming
├── Thread 2: serves /api/stats (every 3s)
├── Thread 3: serves /api/models
└── Thread 4: queued for /api/generate-image
                │
                │ submits to executor
                ▼
SD ThreadPoolExecutor (max_workers=1)
└── Worker thread: runs sd-cli.exe (10-60 seconds)
                │
                │ result back to Flask thread 4
                ▼
                returns JSON to browser

Locks:
  sd_lock          guards _sd_process, _sd_cancelled
  _sd_job_lock     guards _sd_current_job (for UI recovery)
  model_lock       serializes /api/models/load requests
```

### File Locations Reference

Portable (moves with the folder): `vendor/python/` (Python embedded distribution), `vendor/ollama/` (Ollama executable), `vendor/stable-diffusion/` (SD.cpp executable + DLL), `vendor/ollama_home/` (Ollama configuration), `models/ollama/` (Ollama model store via env var `OLLAMA_MODELS`), `models/image/` (SD image models), `models/chat/` (GGUF files before Ollama import), `chat_history/` (saved conversations), `generated_images/` (SD output).

Per-machine (won't move): HuggingFace cache (uses `HF_HOME` if set, else default user profile), browser cookies (`localStorage` in browser).

### API Endpoints Reference

**Static**: `GET /` (Chat UI HTML), `GET /generated_images/<file>` (Serves PNG files).

**Models**: `GET /api/models` (returns `{chat_models: [...], image_models: [...]}`), `GET /api/models/active` (returns `{active_model: "...", models: [...]}`), `POST /api/models/load` (load model, unloading old one), `POST /api/models/unload` (evict from VRAM).

**Chat**: `POST /api/chat` (streaming SSE response), `POST /api/chat/non-stream` (single JSON response).

**Image**: `POST /api/generate-image` (synchronous generation, returns when done), `POST /api/generate-image/cancel` (stop current generation), `GET /api/generate-image/status` (for UI recovery after page refresh), `GET /api/generated-images` (list all PNGs in folder), `DELETE /api/generated-images/<file>` (delete one image).

**History**: `GET /api/history` (list session metadata), `GET /api/history/<id>` (load specific session), `POST /api/history` (save session), `DELETE /api/history/<id>` (delete session).

**System**: `GET /api/system` (backend status), `GET /api/stats` (CPU/RAM/VRAM live stats), `GET /api/health` (ping endpoint).

---

## Quick Command Reference

Start the chat UI: `start_chat.bat`

Open the menu installer: `install.bat`

List installed Ollama models: `vendor\ollama\ollama.exe list`

Manually pull a model: `vendor\ollama\ollama.exe pull llama3.1:8b`

Manually remove a model: `vendor\ollama\ollama.exe rm llama3.1:8b`

Test SD.cpp is working: `vendor\stable-diffusion\sd-cli.exe --help`

Check system specs match what install.bat shows:

```
powershell -Command "Get-CimInstance Win32_ComputerSystem"
powershell -Command "Get-CimInstance Win32_Processor"
powershell -Command "Get-CimInstance Win32_VideoController"
nvidia-smi    # if you have NVIDIA GPU
```

Find what's using port 5000: `netstat -ano | findstr ":5000"`

Stop everything:

```
taskkill /f /im ollama.exe
taskkill /f /im python.exe
taskkill /f /im sd-cli.exe
```

---

## License & Credits

This setup uses **Ollama** (MIT) — `github.com/ollama/ollama`, **stable-diffusion.cpp** (MIT) — `github.com/leejet/stable-diffusion.cpp`, **Python embedded** (PSF) — `python.org`, **Flask** (BSD) — `palletsprojects.com/p/flask`, and **HuggingFace Hub** (Apache 2.0) — `huggingface.co`.

Models retain their original licenses (check on HuggingFace).

AlphaInference, this documentation, and the portable integration layer shipped by AlphaBridge IT Solution™ are intended as a practical offline deployment bundle around those upstream components.

This documentation and the wrapper scripts: use however you like.

---

**End of guide.** Save this file as `README.md` in your AlphaInference folder for offline reference. For AlphaBridge IT Solution™ deployment support and specific errors not covered above, run `install.bat` from an open cmd window to see error messages before the window closes.
````
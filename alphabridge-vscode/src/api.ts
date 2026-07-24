import * as vscode from 'vscode';
import * as cp from 'child_process';
import * as path from 'path';
import * as fs from 'fs';

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

// ── Response shape interfaces ────────────────────────────────────

interface OllamaModelEntry {
  name: string;
  family?: string;
  parameters?: string;
  quantization?: string;
  size?: string;
  size_bytes?: number;
  modified?: string;
}

interface ModelsResponse {
  chat_models: OllamaModelEntry[] | string[];
  image_models: OllamaModelEntry[] | string[];
}

interface ChatResponse {
  message: {
    content: string;
  };
}

interface StreamChunk {
  message?: {
    content?: string;
  };
  done?: boolean;
}

// ── Client ───────────────────────────────────────────────────────
export class AlphaInferenceClient {

  // ── Config helpers ─────────────────────────────────────────

  private get baseUrl(): string {
    return vscode.workspace
      .getConfiguration('alphabridge')
      .get('serverUrl', 'http://127.0.0.1:5000');
  }

  private get defaultModel(): string {
    return vscode.workspace
      .getConfiguration('alphabridge')
      .get('defaultModel', 'llama3.1:8b');
  }

  get alphaInferencePath(): string {
    return vscode.workspace
      .getConfiguration('alphabridge')
      .get('alphaInferencePath', '');
  }

  // ── Health check ───────────────────────────────────────────

  async isAvailable(): Promise<boolean> {
    try {
      const resp = await fetch(`${this.baseUrl}/api/health`, {
        signal: AbortSignal.timeout(3000)
      });
      return resp.ok;
    } catch {
      return false;
    }
  }

  // ── Lock file check ────────────────────────────────────────

  isLockFilePresent(): boolean {
    const alphaPath = this.alphaInferencePath;
    if (!alphaPath) return false;
    const lockFile = path.join(
      alphaPath, 'vendor', 'temp', 'ollama_busy.lock'
    );
    return fs.existsSync(lockFile);
  }

  // ── Launch start_chat.bat silently ─────────────────────────

  async launchServer(): Promise<boolean> {
    const alphaPath = this.alphaInferencePath;

    if (!alphaPath) {
      vscode.window.showErrorMessage(
        'AlphaBridge: alphaInferencePath not set in settings.'
      );
      return false;
    }

    const batFile = path.join(alphaPath, 'start_chat.bat');
    if (!fs.existsSync(batFile)) {
      vscode.window.showErrorMessage(
        `AlphaBridge: start_chat.bat not found at ${batFile}`
      );
      return false;
    }

    if (this.isLockFilePresent()) {
      vscode.window.showWarningMessage(
        'AlphaBridge: A model operation is in progress. ' +
        'Wait for install.bat to finish first.'
      );
      return false;
    }

    const proc = cp.spawn('cmd.exe', ['/c', batFile], {
      cwd: alphaPath,
      detached: true,
      stdio: 'ignore',
      env: {
        ...process.env,
        ALPHA_EXPOSE_LAN: '0',
        ALPHA_RESTART_OLLAMA: '0'
      }
    });
    proc.unref();

    return this._waitForHealth(60);
  }

  private async _waitForHealth(maxSeconds: number): Promise<boolean> {
    const deadline = Date.now() + maxSeconds * 1000;
    while (Date.now() < deadline) {
      if (await this.isAvailable()) return true;
      await new Promise(r => setTimeout(r, 1500));
    }
    return false;
  }

  // ── Models ─────────────────────────────────────────────────

  async getModels(): Promise<{ chat: string[]; image: string[] }> {
    try {
      const resp = await fetch(`${this.baseUrl}/api/models`);
      const data = await resp.json() as ModelsResponse;

      const extractNames = (
        arr: OllamaModelEntry[] | string[]
      ): string[] => {
        if (!Array.isArray(arr)) return [];
        return arr.map(item =>
          typeof item === 'string' ? item : item.name
        );
      };

      return {
        chat: extractNames(data.chat_models),
        image: extractNames(data.image_models)
      };
    } catch {
      return { chat: [], image: [] };
    }
  }

  async getStats(): Promise<Record<string, unknown>> {
    try {
      const resp = await fetch(`${this.baseUrl}/api/stats`);
      const data = await resp.json() as Record<string, unknown>;
      return data;
    } catch {
      return {};
    }
  }

  // ── Chat (single response) ─────────────────────────────────

  async chat(
    messages: ChatMessage[],
    model?: string
  ): Promise<string> {
    const resp = await fetch(`${this.baseUrl}/api/chat/non-stream`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: model ?? this.defaultModel,
        messages
      })
    });

    if (!resp.ok) {
      throw new Error(
        `AlphaInference error: ${resp.status} ${resp.statusText}`
      );
    }

    const data = await resp.json() as ChatResponse;
    return data.message?.content ?? '';
  }

  // ── Chat (streaming) ───────────────────────────────────────

async chatStream(
  messages: ChatMessage[],
  callback: StreamCallback,
  model?: string,
  abortSignal?: AbortSignal
): Promise<void> {

  const requestBody = JSON.stringify({
    model: model ?? this.defaultModel,
    messages
  });

  const requestBytes = new TextEncoder().encode(requestBody).length;

  const attemptFetch = async (): Promise<Response> => {
    return await fetch(`${this.baseUrl}/api/chat`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream'
      },
      body: requestBody,
      signal: abortSignal
    });
  };

  let resp: Response;
  try {
    resp = await attemptFetch();

    if (resp.status === 404 || resp.status === 503) {
      callback.onStatus?.('⏳ Model is loading, please wait...');
      try { await resp.text(); } catch { /* ignore */ }
      await new Promise(r => setTimeout(r, 8000));
      resp = await attemptFetch();
    }
  } catch (fetchError: unknown) {
    const err = fetchError as Error;
    const detail =
      `Fetch failed: ${err.name}: ${err.message}\n` +
      `URL: ${this.baseUrl}/api/chat\n` +
      `Body size: ${requestBytes} bytes`;
    callback.onStatus?.('⚠️ ' + detail);
    throw new Error(detail);
  }

  if (!resp.ok) {
    let errorDetail = `HTTP ${resp.status} ${resp.statusText}`;
    try {
      const errorBody = await resp.text();
      if (errorBody) {
        errorDetail += `\nServer: ${errorBody.substring(0, 500)}`;
      }
    } catch { /* ignore */ }
    callback.onStatus?.('⚠️ ' + errorDetail);
    throw new Error(errorDetail);
  }

  if (!resp.body) {
    callback.onStatus?.('⚠️ Server returned no body');
    throw new Error('No response body');
  }

  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let chunksReceived = 0;

  const processPayload = (payload: string) => {
    if (!payload || payload === '[DONE]') return;

    try {
      const chunk = JSON.parse(payload) as {
        message?: { content?: string; thinking?: string };
        response?: string;
        queue?: { state?: string };
        done?: boolean;
        error?: string;
      };

      if (chunk.queue) return;

      if (chunk.error) {
        callback.onStatus?.(`\n⚠️ ${chunk.error}`);
        return;
      }

      const msg = chunk.message;

      // Thinking goes to its own callback
      if (msg?.thinking) {
        callback.onThinking?.(msg.thinking);
      }

      // Actual content goes to content callback
      if (msg?.content) {
        callback.onContent?.(msg.content);
      }

      // /api/generate style
      if (chunk.response) {
        callback.onContent?.(chunk.response);
      }
    } catch {
      // partial JSON
    }
  };

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      chunksReceived++;
      buffer += decoder.decode(value, { stream: true });

      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';

      for (const rawLine of lines) {
        const line = rawLine.trim();
        if (!line) continue;

        let payload = line;
        if (line.startsWith('data:')) {
          payload = line.slice(5).trim();
        }
        processPayload(payload);
      }
    }
  } catch (readError: unknown) {
    const err = readError as Error;
    callback.onStatus?.(
      `\n⚠️ Read error: ${err.name}: ${err.message}`
    );
    throw err;
  }

  if (buffer.trim()) {
    let payload = buffer.trim();
    if (payload.startsWith('data:')) {
      payload = payload.slice(5).trim();
    }
    processPayload(payload);
  }

  if (chunksReceived === 0) {
    callback.onStatus?.('⚠️ No data received. Model may be slow to load.');
    throw new Error('Empty stream');
  }
}
}

export interface StreamCallback {
  onThinking?: (token: string) => void;
  onContent?: (token: string) => void;
  onStatus?: (message: string) => void;
}

import * as vscode from 'vscode';

let channel: vscode.OutputChannel | undefined;

export function getDebugChannel(): vscode.OutputChannel {
  if (!channel) {
    channel = vscode.window.createOutputChannel('AlphaBridge');
  }
  return channel;
}

export function debugLog(label: string, data: unknown) {
  const ch = getDebugChannel();
  const timestamp = new Date().toISOString().slice(11, 23);
  ch.appendLine(`[${timestamp}] ${label}`);

  if (typeof data === 'string') {
    ch.appendLine(data);
  } else {
    try {
      const json = JSON.stringify(data, null, 2);
      // Truncate very long outputs
      if (json.length > 8000) {
        ch.appendLine(json.substring(0, 8000));
        ch.appendLine(`\n... (truncated, total ${json.length} chars)`);
      } else {
        ch.appendLine(json);
      }
    } catch {
      ch.appendLine(String(data));
    }
  }
  ch.appendLine('');
}
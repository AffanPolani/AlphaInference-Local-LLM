import * as vscode from 'vscode';
import { AlphaInferenceClient } from './api';

export class AlphaBridgeSidebar implements vscode.WebviewViewProvider {

  public static readonly viewType = 'alphabridge.sidebar';

  private _view?: vscode.WebviewView;

  constructor(
    private readonly _extensionUri: vscode.Uri,
    private readonly _client: AlphaInferenceClient
  ) { }

  public resolveWebviewView(
    webviewView: vscode.WebviewView,
    _context: vscode.WebviewViewResolveContext,
    _token: vscode.CancellationToken
  ) {
    this._view = webviewView;

    webviewView.webview.options = {
      enableScripts: true,
      localResourceRoots: [this._extensionUri]
    };

    webviewView.webview.html = this._getHtml();

    webviewView.webview.onDidReceiveMessage(async (msg) => {
      switch (msg.command) {
        case 'openChat':
          vscode.commands.executeCommand('alphabridge.openChat');
          break;
        case 'askAboutFile':
          vscode.commands.executeCommand('alphabridge.askAboutFile');
          break;
        case 'attachFiles':
          vscode.commands.executeCommand('alphabridge.attachFiles');
          break;
        case 'attachFolder':
          vscode.commands.executeCommand('alphabridge.attachFolder');
          break;
        case 'attachOpenFiles':
          vscode.commands.executeCommand('alphabridge.attachOpenFiles');
          break;
        case 'openSettings':
          vscode.commands.executeCommand(
            'workbench.action.openSettings', 'alphabridge'
          );
          break;
      }
    });

    const timer = setInterval(() => {
      if (webviewView.visible) this.refreshStatus();
    }, 5000);
    webviewView.onDidDispose(() => clearInterval(timer));

    this.refreshStatus();
  }

  public async refreshStatus() {
    if (!this._view) return;

    const online = await this._client.isAvailable();
    let models: string[] = [];
    if (online) {
      const m = await this._client.getModels();
      models = m.chat;
    }

    this._view.webview.postMessage({
      command: 'status',
      online,
      models,
      path: this._client.alphaInferencePath
    });
  }

  private _getHtml(): string {
    return /* html */`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: var(--vscode-font-family);
    font-size: var(--vscode-font-size);
    color: var(--vscode-foreground);
    background: var(--vscode-sideBar-background);
    padding: 10px;
    display: flex; flex-direction: column; gap: 10px;
  }
  .status-card {
    background: var(--vscode-editor-inactiveSelectionBackground, rgba(255,255,255,0.04));
    border: 1px solid var(--vscode-input-border, #3c3c3c);
    border-radius: 4px; padding: 8px;
    display: flex; flex-direction: column; gap: 4px;
  }
  .status-row {
    display: flex; align-items: center; gap: 6px; font-size: 0.9em;
  }
  .status-dot {
    width: 10px; height: 10px; border-radius: 50%;
    background: #888; flex-shrink: 0;
  }
  .status-dot.online { background: #4ec9b0; }
  .status-dot.offline { background: #c72e2e; }
  .model-count {
    font-size: 0.82em; opacity: 0.7; margin-left: 16px;
  }
  .section { display: flex; flex-direction: column; gap: 4px; }
  .section-title {
    font-size: 0.72em; text-transform: uppercase;
    opacity: 0.55; letter-spacing: 0.05em;
    padding: 0 2px; margin-top: 4px;
  }
  button.action {
    background: var(--vscode-button-secondaryBackground, #3a3d41);
    color: var(--vscode-button-secondaryForeground, #ccc);
    border: none; padding: 8px 10px; border-radius: 3px;
    cursor: pointer; font-size: 0.9em; text-align: left;
    display: flex; align-items: center; gap: 8px; width: 100%;
  }
  button.action:hover {
    background: var(--vscode-button-background);
    color: var(--vscode-button-foreground);
  }
  button.action .icon {
    font-size: 1.1em; flex-shrink: 0;
    width: 18px; text-align: center;
  }
  .primary-btn {
    background: var(--vscode-button-background);
    color: var(--vscode-button-foreground);
    border: none; padding: 10px; border-radius: 4px;
    cursor: pointer; font-size: 0.95em; font-weight: 600;
    display: flex; align-items: center; justify-content: center;
    gap: 6px; width: 100%;
  }
  .primary-btn:hover { background: var(--vscode-button-hoverBackground); }
  .tip {
    font-size: 0.75em; opacity: 0.5; padding: 6px; line-height: 1.4;
  }
  #warnPath {
    display: none;
    background: rgba(199, 46, 46, 0.1);
    border: 1px solid rgba(199, 46, 46, 0.3);
    border-radius: 4px; padding: 6px 8px;
    font-size: 0.82em; color: #f88;
  }
  #warnPath a { color: #f88; text-decoration: underline; cursor: pointer; }
</style>
</head>
<body>

<div class="status-card">
  <div class="status-row">
    <span class="status-dot" id="dot"></span>
    <span id="statusText">Checking...</span>
  </div>
  <div class="model-count" id="modelCount"></div>
</div>

<div id="warnPath">
  ⚠ AlphaInference path not set.
  <br><a id="openSettings">Open Settings</a>
</div>

<button class="primary-btn" id="btnOpenChat">💬 Open Chat Panel</button>

<div class="section">
  <div class="section-title">Current file</div>
  <button class="action" id="btnAskFile">
    <span class="icon">📄</span> Ask about this file
  </button>
</div>

<div class="section">
  <div class="section-title">Attach context</div>
  <button class="action" id="btnAttachFiles">
    <span class="icon">📎</span> Attach files
  </button>
  <button class="action" id="btnAttachFolder">
    <span class="icon">📁</span> Attach folder
  </button>
  <button class="action" id="btnAttachOpen">
    <span class="icon">📋</span> Attach open files
  </button>
</div>

<div class="tip">
  Tip: right-click a file or folder in the Explorer to attach it directly.
</div>

<script>
  var vscode = acquireVsCodeApi();
  var dot = document.getElementById('dot');
  var statusText = document.getElementById('statusText');
  var modelCount = document.getElementById('modelCount');
  var warnPath = document.getElementById('warnPath');

  document.getElementById('btnOpenChat').onclick = function() {
    vscode.postMessage({ command: 'openChat' });
  };
  document.getElementById('btnAskFile').onclick = function() {
    vscode.postMessage({ command: 'askAboutFile' });
  };
  document.getElementById('btnAttachFiles').onclick = function() {
    vscode.postMessage({ command: 'attachFiles' });
  };
  document.getElementById('btnAttachFolder').onclick = function() {
    vscode.postMessage({ command: 'attachFolder' });
  };
  document.getElementById('btnAttachOpen').onclick = function() {
    vscode.postMessage({ command: 'attachOpenFiles' });
  };
  document.getElementById('openSettings').onclick = function() {
    vscode.postMessage({ command: 'openSettings' });
  };

  window.addEventListener('message', function(event) {
    var data = event.data;
    if (data.command === 'status') {
      if (data.online) {
        dot.className = 'status-dot online';
        statusText.textContent = 'Server running';
        modelCount.textContent =
          data.models.length + ' model' +
          (data.models.length === 1 ? '' : 's') + ' available';
      } else {
        dot.className = 'status-dot offline';
        statusText.textContent = 'Server offline';
        modelCount.textContent = 'Launch start_chat.bat to connect';
      }
      warnPath.style.display = data.path ? 'none' : 'block';
    }
  });
</script>

</body>
</html>`;
  }
}
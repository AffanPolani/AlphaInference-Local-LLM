import * as vscode from 'vscode';
import { AlphaInferenceClient, ChatMessage } from './api';
import {
  ContextBuilder,
  Attachment,
  FileAttachment,
  FolderAttachment
} from './contextBuilder';
import { debugLog } from './debug';

interface AttachmentInfo {
  id: string;
  type: 'file' | 'folder';
  name: string;
  detail: string;
}

interface SavedChat {
  id: string;
  title: string;
  timestamp: number;
  messages: ChatMessage[];
}

const MAX_SAVED_CHATS = 3;
const STORAGE_KEY = 'alphabridge.savedChats';

export class ChatPanel {
  public static instance: ChatPanel | undefined;

  private readonly _panel: vscode.WebviewPanel;
  private _disposables: vscode.Disposable[] = [];
  private _abortController: AbortController | undefined;
  private _attachments: Attachment[] = [];
  private _attachmentCounter = 0;
  private _currentChatId: string;
  private _currentMessages: ChatMessage[] = [];
  private _context: vscode.ExtensionContext;

  // ── Factory ────────────────────────────────────────────────

  public static createOrShow(
    extensionUri: vscode.Uri,
    client: AlphaInferenceClient,
    context: vscode.ExtensionContext
  ) {
    if (ChatPanel.instance) {
      ChatPanel.instance._panel.reveal(vscode.ViewColumn.Beside);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      'alphabridgeChat',
      'AlphaBridge Copilot',
      vscode.ViewColumn.Beside,
      {
        enableScripts: true,
        retainContextWhenHidden: true
      }
    );

    ChatPanel.instance = new ChatPanel(panel, client, context);
  }

  // ── Constructor ────────────────────────────────────────────

  private constructor(
    panel: vscode.WebviewPanel,
    private readonly client: AlphaInferenceClient,
    context: vscode.ExtensionContext
  ) {
    this._panel = panel;
    this._context = context;
    this._currentChatId = this._generateChatId();
    this._panel.webview.html = this._getHtml();

    this._panel.webview.onDidReceiveMessage(
      async (msg) => {
        switch (msg.command) {

          case 'chat':
            await this._handleChat(msg.messages, msg.model);
            break;

          case 'chatWithAttachments':
            await this._handleChatWithAttachments(
              msg.userMessage, msg.model
            );
            break;

          case 'stop':
            this._abortController?.abort();
            break;

          case 'getModels': {
            const { chat } = await this.client.getModels();
            this._panel.webview.postMessage({
              command: 'models',
              models: chat
            });
            break;
          }

          case 'pickFiles':
            vscode.commands.executeCommand('alphabridge._pickFiles');
            break;

          case 'pickFolder':
            vscode.commands.executeCommand('alphabridge._pickFolder');
            break;

          case 'attachOpenFiles':
            vscode.commands.executeCommand('alphabridge._attachOpenFiles');
            break;

          case 'removeAttachment':
            this._removeAttachment(msg.id);
            break;

          case 'clearAttachments':
            this._attachments = [];
            this._syncAttachments();
            break;

          case 'newChat':
            this._startNewChat();
            break;

          case 'loadChat':
            this._loadChat(msg.chatId);
            break;

          case 'deleteChat':
            this._deleteChat(msg.chatId);
            break;

          case 'getHistory':
            this._syncHistory();
            break;

          case 'saveMessages':
            this._currentMessages = msg.messages || [];
            this._saveCurrentChat();
            break;
        }
      },
      null,
      this._disposables
    );

    this._panel.onDidDispose(
      () => this.dispose(),
      null,
      this._disposables
    );

    setTimeout(() => this._syncHistory(), 200);
  }

  // ── Chat History Management ────────────────────────────────

  private _generateChatId(): string {
    return 'chat_' + Date.now() + '_' +
      Math.random().toString(36).slice(2, 8);
  }

  private _getSavedChats(): SavedChat[] {
    const chats = this._context.globalState.get<SavedChat[]>(STORAGE_KEY, []);
    return Array.isArray(chats) ? chats : [];
  }

  private async _saveCurrentChat() {
    if (this._currentMessages.length === 0) return;

    const firstUser = this._currentMessages.find(m => m.role === 'user');
    if (!firstUser) return;

    let title = firstUser.content;
    const separatorIdx = title.indexOf('\n\n---\n\n**Context:**');
    if (separatorIdx > -1) {
      title = title.slice(0, separatorIdx);
    }
    title = title.trim().substring(0, 60);
    if (firstUser.content.length > 60) title += '...';

    const chats = this._getSavedChats();
    const existingIdx = chats.findIndex(c => c.id === this._currentChatId);

    const chat: SavedChat = {
      id: this._currentChatId,
      title,
      timestamp: Date.now(),
      messages: this._currentMessages
    };

    if (existingIdx >= 0) {
      chats[existingIdx] = chat;
    } else {
      chats.unshift(chat);
      if (chats.length > MAX_SAVED_CHATS) {
        chats.length = MAX_SAVED_CHATS;
      }
    }

    chats.sort((a, b) => b.timestamp - a.timestamp);

    await this._context.globalState.update(STORAGE_KEY, chats);
    this._syncHistory();
  }

  private _syncHistory() {
    const chats = this._getSavedChats();
    this._panel.webview.postMessage({
      command: 'history',
      chats: chats.map(c => ({
        id: c.id,
        title: c.title,
        timestamp: c.timestamp,
        messageCount: c.messages.length,
        isActive: c.id === this._currentChatId
      }))
    });
  }

  private _startNewChat() {
    this._currentChatId = this._generateChatId();
    this._currentMessages = [];
    this._attachments = [];
    this._panel.webview.postMessage({ command: 'clearChat' });
    this._syncAttachments();
    this._syncHistory();
  }

  private _loadChat(chatId: string) {
    const chats = this._getSavedChats();
    const chat = chats.find(c => c.id === chatId);
    if (!chat) return;

    this._currentChatId = chat.id;
    this._currentMessages = chat.messages.slice();
    this._attachments = [];
    this._syncAttachments();

    this._panel.webview.postMessage({
      command: 'loadMessages',
      messages: chat.messages
    });
    this._syncHistory();
  }

  private async _deleteChat(chatId: string) {
    const chats = this._getSavedChats();
    const filtered = chats.filter(c => c.id !== chatId);
    await this._context.globalState.update(STORAGE_KEY, filtered);

    if (chatId === this._currentChatId) {
      this._startNewChat();
    } else {
      this._syncHistory();
    }
  }

  // ── Public API ─────────────────────────────────────────────

  public addAttachments(items: Attachment[]) {
    for (const item of items) {
      (item as Attachment & { _id: string })._id =
        'att_' + (++this._attachmentCounter);
      this._attachments.push(item);
    }
    this._syncAttachments();
  }

  public async sendMessages(messages: ChatMessage[]) {
    this._panel.reveal(vscode.ViewColumn.Beside);

    const cleanMessages = messages.map(m => ({
      role: m.role,
      content: m.content
    }));

    if (this._currentMessages.length > 0) {
      this._startNewChat();
    }

    this._currentMessages = cleanMessages.slice();

    debugLog('SEND MESSAGES (from command)', {
      messageCount: cleanMessages.length,
      messages: cleanMessages.map(m => ({
        role: m.role,
        contentLength: m.content.length,
        contentPreview: m.content.substring(0, 500)
      }))
    });

    await new Promise(r => setTimeout(r, 100));

    this._panel.webview.postMessage({
      command: 'injectMessages',
      messages: cleanMessages
    });

    await new Promise(r => setTimeout(r, 50));

    await this._handleChat(cleanMessages);
  }

  // ── Attachments ─────────────────────────────────────────────

  private _syncAttachments() {
    const infos: AttachmentInfo[] = this._attachments.map(att => {
      const id = (att as Attachment & { _id: string })._id;

      if (att.type === 'file') {
        const f = att as FileAttachment;
        return {
          id, type: 'file' as const, name: f.name,
          detail: `${f.lineCount} lines`
        };
      } else {
        const d = att as FolderAttachment;
        const extra = d.truncatedFiles > 0
          ? ` (+${d.truncatedFiles} skipped)` : '';
        return {
          id, type: 'folder' as const, name: d.name + '/',
          detail: `${d.files.length} files${extra}`
        };
      }
    });

    this._panel.webview.postMessage({
      command: 'attachments', items: infos
    });
  }

  private _removeAttachment(id: string) {
    this._attachments = this._attachments.filter(
      att => (att as Attachment & { _id: string })._id !== id
    );
    this._syncAttachments();
  }

  // ── Chat handlers ──────────────────────────────────────────

  private async _handleChatWithAttachments(
    userMessage: string, model?: string
  ) {
    let messages: ChatMessage[];

    if (this._attachments.length > 0) {
      messages = ContextBuilder.fromAttachments(this._attachments);
      messages = ContextBuilder.withTask(messages, userMessage);

      const summary = this._attachments.map(att => {
        if (att.type === 'file') {
          return `📎 ${(att as FileAttachment).name}`;
        } else {
          const d = att as FolderAttachment;
          return `📁 ${d.name}/ (${d.files.length} files)`;
        }
      }).join('\n');

      this._panel.webview.postMessage({
        command: 'showContext', summary, userMessage
      });

      this._currentMessages.push({
        role: 'user',
        content: messages[messages.length - 1].content
      });

      this._attachments = [];
      this._syncAttachments();
    } else {
      messages = [{ role: 'user', content: userMessage }];
      this._currentMessages.push({ role: 'user', content: userMessage });
    }

    await this._handleChat(messages, model);
  }

  private async _handleChat(messages: ChatMessage[], model?: string) {
    this._abortController = new AbortController();
    this._panel.webview.postMessage({ command: 'streamStart' });

    debugLog('STREAM START', {
      model, messageCount: messages.length,
      totalChars: messages.reduce((s, m) => s + m.content.length, 0)
    });

    const startTime = Date.now();
    let thinkingStart = 0;
    let thinkingEnd = 0;
    let contentTokens = 0;
    let thinkingTokens = 0;
    let assistantContent = '';

    try {
      await this.client.chatStream(
        messages,
        {
          onThinking: (token) => {
            if (thinkingStart === 0) thinkingStart = Date.now();
            thinkingTokens++;
            this._panel.webview.postMessage({
              command: 'thinkingToken', token
            });
          },
          onContent: (token) => {
            if (thinkingStart !== 0 && thinkingEnd === 0) {
              thinkingEnd = Date.now();
              const durationSec =
                ((thinkingEnd - thinkingStart) / 1000).toFixed(1);
              this._panel.webview.postMessage({
                command: 'thinkingDone', durationSec
              });
            }
            contentTokens++;
            assistantContent += token;
            this._panel.webview.postMessage({
              command: 'contentToken', token
            });
          },
          onStatus: (message) => {
            this._panel.webview.postMessage({
              command: 'statusToken', token: message
            });
          }
        },
        model,
        this._abortController.signal
      );

      if (assistantContent.trim()) {
        this._currentMessages.push({
          role: 'assistant', content: assistantContent
        });
        await this._saveCurrentChat();
      }

      debugLog('STREAM END', {
        thinkingTokens, contentTokens,
        totalMs: Date.now() - startTime
      });
    } catch (e: unknown) {
      const err = e as Error;
      debugLog('STREAM ERROR', {
        name: err.name, message: err.message
      });
      if (err.name !== 'AbortError') {
        this._panel.webview.postMessage({
          command: 'error', message: err.message
        });
      }
    } finally {
      this._panel.webview.postMessage({ command: 'streamEnd' });
    }
  }

  // ── Webview HTML ───────────────────────────────────────────

  private _getHtml(): string {
    return /* html */`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>AlphaBridge Copilot</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --font-scale: 1;
    --accent: var(--vscode-focusBorder, #007acc);
    --accent-glow: rgba(0, 122, 204, 0.15);
    --success: #4ec9b0;
    --danger: #f14c4c;
    --warning: #d19a66;
    --radius-sm: 4px;
    --radius-md: 6px;
    --radius-lg: 10px;
    --transition-fast: 0.15s ease;
    --transition-med: 0.25s cubic-bezier(0.4, 0, 0.2, 1);
    --transition-slow: 0.4s cubic-bezier(0.4, 0, 0.2, 1);
  }

  body {
    font-family: var(--vscode-font-family);
    font-size: calc(var(--vscode-font-size) * var(--font-scale));
    color: var(--vscode-foreground);
    background: var(--vscode-editor-background);
    display: flex;
    height: 100vh;
    overflow: hidden;
  }

  /* ── History Sidebar ── */
  #historySidebar {
    width: 240px;
    min-width: 240px;
    background: var(--vscode-sideBar-background);
    border-right: 1px solid var(--vscode-panel-border, rgba(255,255,255,0.06));
    display: flex;
    flex-direction: column;
    transition: width var(--transition-med),
                min-width var(--transition-med),
                opacity var(--transition-med),
                border-right-width var(--transition-med);
    overflow: hidden;
  }
  #historySidebar.collapsed {
    width: 0;
    min-width: 0;
    opacity: 0;
    border-right-width: 0;
  }
  #historySidebar.collapsed * {
    pointer-events: none;
  }

  .sidebar-header {
    padding: 12px 14px 10px;
    border-bottom: 1px solid var(--vscode-panel-border, rgba(255,255,255,0.06));
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .sidebar-header .title {
    flex: 1;
    font-size: 0.85em;
    font-weight: 600;
    letter-spacing: 0.02em;
    opacity: 0.9;
  }
  #newChatBtn {
    background: var(--accent);
    color: white;
    border: none;
    padding: 5px 10px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-size: 0.8em;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 4px;
    transition: transform var(--transition-fast),
                background var(--transition-fast);
  }
  #newChatBtn:hover {
    background: var(--vscode-button-hoverBackground, var(--accent));
    transform: translateY(-1px);
  }
  #newChatBtn:active { transform: translateY(0); }

  #historyList {
    flex: 1;
    overflow-y: auto;
    padding: 8px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }
  .history-item {
    padding: 10px 12px;
    border-radius: var(--radius-md);
    cursor: pointer;
    position: relative;
    display: flex;
    flex-direction: column;
    gap: 3px;
    transition: background var(--transition-fast),
                transform var(--transition-fast);
    animation: slideIn 0.25s ease-out;
  }
  @keyframes slideIn {
    from { opacity: 0; transform: translateX(-8px); }
    to { opacity: 1; transform: translateX(0); }
  }
  .history-item:hover {
    background: var(--vscode-list-hoverBackground, rgba(255,255,255,0.05));
    transform: translateX(2px);
  }
  .history-item.active {
    background: var(--accent-glow);
    border-left: 3px solid var(--accent);
    padding-left: 9px;
  }
  .history-item .h-title {
    font-size: 0.85em;
    font-weight: 500;
    line-height: 1.3;
    overflow: hidden;
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
  }
  .history-item .h-meta {
    font-size: 0.7em;
    opacity: 0.55;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .history-item .h-delete {
    position: absolute;
    top: 4px;
    right: 4px;
    background: transparent;
    color: var(--vscode-foreground);
    border: none;
    width: 20px;
    height: 20px;
    border-radius: 3px;
    cursor: pointer;
    font-size: 0.8em;
    opacity: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    transition: opacity var(--transition-fast),
                background var(--transition-fast);
  }
  .history-item:hover .h-delete { opacity: 0.6; }
  .history-item .h-delete:hover {
    opacity: 1;
    background: var(--danger);
    color: white;
  }
  .history-empty {
    padding: 20px 12px;
    font-size: 0.8em;
    opacity: 0.5;
    text-align: center;
    line-height: 1.4;
  }

  /* ── Main content ── */
  #mainContent {
    flex: 1;
    display: flex;
    flex-direction: column;
    padding: 10px;
    gap: 10px;
    min-width: 0;
  }

  /* ── Toolbar ── */
  #toolbar {
    display: flex;
    gap: 6px;
    align-items: center;
    flex-shrink: 0;
    padding: 4px 2px;
  }
  #sidebarToggle {
    background: transparent;
    color: var(--vscode-foreground);
    border: 1px solid transparent;
    padding: 4px 8px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-size: 1em;
    opacity: 0.75;
    transition: all var(--transition-fast);
    display: flex;
    align-items: center;
    gap: 4px;
    min-width: 32px;
    justify-content: center;
  }
  #sidebarToggle:hover {
    opacity: 1;
    background: var(--vscode-list-hoverBackground, rgba(255,255,255,0.05));
    border-color: var(--vscode-panel-border, rgba(255,255,255,0.1));
  }
  #sidebarToggle .badge {
    background: var(--accent);
    color: white;
    padding: 0 5px;
    border-radius: 8px;
    font-size: 0.7em;
    font-weight: 600;
    min-width: 16px;
    height: 16px;
    display: flex;
    align-items: center;
    justify-content: center;
    margin-left: 2px;
  }

  #statusDot {
    width: 8px; height: 8px; border-radius: 50%;
    background: #888; flex-shrink: 0;
    box-shadow: 0 0 0 0 currentColor;
    transition: background var(--transition-med);
  }
  #statusDot.online {
    background: var(--success);
    animation: pulse 2s ease-in-out infinite;
  }
  #statusDot.offline { background: var(--danger); }
  @keyframes pulse {
    0%, 100% { box-shadow: 0 0 0 0 rgba(78,201,176,0.4); }
    50% { box-shadow: 0 0 0 4px rgba(78,201,176,0); }
  }

  #modelSelect {
    flex: 1;
    background: var(--vscode-dropdown-background);
    color: var(--vscode-dropdown-foreground);
    border: 1px solid var(--vscode-dropdown-border);
    padding: 5px 8px;
    border-radius: var(--radius-sm);
    font-size: inherit;
    cursor: pointer;
    transition: border-color var(--transition-fast);
  }
  #modelSelect:hover {
    border-color: var(--accent);
  }

  .icon-btn {
    background: transparent;
    color: var(--vscode-foreground);
    border: 1px solid transparent;
    padding: 4px 8px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-size: 0.9em;
    opacity: 0.75;
    transition: all var(--transition-fast);
    display: flex;
    align-items: center;
    gap: 3px;
  }
  .icon-btn:hover {
    opacity: 1;
    background: var(--vscode-list-hoverBackground, rgba(255,255,255,0.05));
    border-color: var(--vscode-panel-border, rgba(255,255,255,0.1));
  }
  .icon-btn:active { transform: scale(0.95); }

  #stopBtn {
    background: var(--danger);
    color: white;
    border: none;
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    cursor: pointer;
    font-weight: 500;
    animation: slideIn 0.2s ease-out;
  }
  #stopBtn:hover { background: #c72e2e; }

  /* ── Font size controls ── */
  .font-controls {
    display: flex;
    gap: 2px;
    background: var(--vscode-input-background);
    border-radius: var(--radius-sm);
    padding: 2px;
  }
  .font-btn {
    background: transparent;
    color: var(--vscode-foreground);
    border: none;
    padding: 3px 8px;
    border-radius: 3px;
    cursor: pointer;
    font-size: 0.85em;
    opacity: 0.7;
    transition: all var(--transition-fast);
  }
  .font-btn:hover {
    background: var(--vscode-button-secondaryBackground, rgba(255,255,255,0.08));
    opacity: 1;
  }

  /* ── Messages area ── */
  #messages {
    flex: 1;
    overflow-y: auto;
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 4px 4px 4px 2px;
    scroll-behavior: smooth;
  }
  #messages::-webkit-scrollbar { width: 8px; }
  #messages::-webkit-scrollbar-track { background: transparent; }
  #messages::-webkit-scrollbar-thumb {
    background: var(--vscode-scrollbarSlider-background);
    border-radius: 4px;
  }
  #messages::-webkit-scrollbar-thumb:hover {
    background: var(--vscode-scrollbarSlider-hoverBackground);
  }

  .msg-wrapper {
    position: relative;
    display: flex;
    flex-direction: column;
    gap: 4px;
    animation: fadeInUp 0.3s ease-out;
  }
  @keyframes fadeInUp {
    from { opacity: 0; transform: translateY(8px); }
    to { opacity: 1; transform: translateY(0); }
  }

  .label {
    font-size: 0.7em;
    font-weight: 700;
    opacity: 0.55;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding: 0 2px;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .label::before {
    content: '';
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: currentColor;
    opacity: 0.5;
  }

  .message {
    padding: 12px 14px;
    border-radius: var(--radius-lg);
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.6;
    font-size: 0.95em;
    transition: box-shadow var(--transition-fast);
  }
  .user {
    background: linear-gradient(135deg,
      var(--accent-glow),
      rgba(0, 122, 204, 0.05));
    border: 1px solid rgba(0, 122, 204, 0.2);
  }
  .assistant {
    background: var(--vscode-editor-inactiveSelectionBackground,
                    rgba(255,255,255,0.04));
    border: 1px solid var(--vscode-panel-border, rgba(255,255,255,0.06));
  }
  .assistant:hover {
    box-shadow: 0 2px 8px rgba(0,0,0,0.1);
  }
  .system-note {
    padding: 8px 12px;
    background: rgba(241, 76, 76, 0.1);
    border-left: 3px solid var(--danger);
    border-radius: var(--radius-sm);
    font-size: 0.85em;
    color: var(--danger);
    animation: fadeInUp 0.3s ease-out;
  }

  /* ── Context block ── */
  .context-block {
    background: var(--vscode-textCodeBlock-background,
                    rgba(255,255,255,0.03));
    border: 1px solid var(--vscode-panel-border,
                    rgba(255,255,255,0.08));
    border-radius: var(--radius-md);
    padding: 8px 12px;
    margin-bottom: 6px;
    font-size: 0.85em;
    animation: fadeIn 0.3s ease-out;
  }
  @keyframes fadeIn {
    from { opacity: 0; } to { opacity: 1; }
  }
  .context-block .ctx-label {
    font-size: 0.7em;
    font-weight: 700;
    opacity: 0.55;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    margin-bottom: 4px;
  }
  .context-block .ctx-body {
    white-space: pre-wrap;
    line-height: 1.5;
    opacity: 0.85;
  }

  /* ── Copy button ── */
  .copy-btn {
    position: absolute;
    top: 22px;
    right: 8px;
    background: var(--vscode-button-secondaryBackground, rgba(60,60,60,0.9));
    color: var(--vscode-button-secondaryForeground, #ccc);
    border: 1px solid var(--vscode-panel-border, rgba(255,255,255,0.08));
    padding: 3px 8px;
    border-radius: var(--radius-sm);
    font-size: 0.72em;
    cursor: pointer;
    opacity: 0;
    transition: all var(--transition-fast);
    display: flex;
    align-items: center;
    gap: 3px;
  }
  .msg-wrapper:hover .copy-btn { opacity: 1; }
  .copy-btn:hover {
    background: var(--accent);
    color: white;
    border-color: var(--accent);
  }
  .copy-btn.copied {
    background: var(--success);
    color: white;
    border-color: var(--success);
  }

  /* ── Streaming cursor ── */
  .streaming::after {
    content: '▋';
    animation: blink 1s steps(1) infinite;
    color: var(--accent);
    margin-left: 2px;
    font-weight: 100;
  }
  @keyframes blink { 50% { opacity: 0; } }

  /* ── Thinking block ── */
  .thinking-block {
    margin-bottom: 10px;
    border: 1px solid var(--vscode-panel-border,
                    rgba(255,255,255,0.08));
    border-radius: var(--radius-md);
    background: linear-gradient(180deg,
      rgba(255,255,255,0.02),
      rgba(255,255,255,0.01));
    overflow: hidden;
    animation: slideDown 0.3s ease-out;
  }
  @keyframes slideDown {
    from { opacity: 0; transform: translateY(-4px); }
    to { opacity: 1; transform: translateY(0); }
  }
  .thinking-header {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 8px 12px;
    cursor: pointer;
    user-select: none;
    font-size: 0.85em;
    color: var(--vscode-descriptionForeground, #999);
    transition: background var(--transition-fast);
  }
  .thinking-header:hover {
    background: var(--vscode-list-hoverBackground,
                    rgba(255,255,255,0.03));
  }
  .thinking-arrow {
    transition: transform var(--transition-med);
    font-size: 0.7em;
    opacity: 0.6;
    display: inline-block;
  }
  .thinking-arrow.expanded {
    transform: rotate(90deg);
  }
  .thinking-icon {
    font-size: 1em;
    opacity: 0.8;
  }
  .thinking-title {
    flex: 1;
    font-weight: 500;
  }
  .thinking-title .duration {
    opacity: 0.65;
    font-size: 0.85em;
    margin-left: 6px;
    font-weight: 400;
  }
  .thinking-content {
    padding: 0 14px 0 32px;
    font-size: 0.85em;
    color: var(--vscode-descriptionForeground, #999);
    border-top: 1px solid var(--vscode-panel-border,
                    rgba(255,255,255,0.06));
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.6;
    max-height: 0;
    overflow-y: auto;
    transition: max-height var(--transition-med),
                padding var(--transition-med);
  }
  .thinking-content.expanded {
    max-height: 300px;
    padding-top: 10px;
    padding-bottom: 12px;
  }
  .thinking-content.streaming::after {
    content: '▋';
    animation: blink 1s steps(1) infinite;
    color: var(--accent);
    margin-left: 2px;
  }

  /* ── Attachments tray ── */
  #attachTray {
    flex-shrink: 0;
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
    min-height: 0;
    transition: min-height var(--transition-med);
  }
  #attachTray:not(:empty) {
    min-height: 30px;
    padding-bottom: 2px;
  }
  .att-chip {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    background: var(--vscode-badge-background, #4d4d4d);
    color: var(--vscode-badge-foreground, #fff);
    padding: 4px 10px;
    border-radius: 14px;
    font-size: 0.8em;
    max-width: 260px;
    animation: fadeInUp 0.25s ease-out;
    transition: transform var(--transition-fast);
  }
  .att-chip:hover { transform: translateY(-1px); }
  .att-chip .att-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-weight: 500;
  }
  .att-chip .att-detail {
    opacity: 0.65;
    font-size: 0.85em;
    flex-shrink: 0;
  }
  .att-chip .att-remove {
    background: transparent;
    border: none;
    color: inherit;
    cursor: pointer;
    padding: 0 2px;
    font-size: 1em;
    opacity: 0.65;
    flex-shrink: 0;
    transition: all var(--transition-fast);
  }
  .att-chip .att-remove:hover {
    opacity: 1;
    color: #f88;
    transform: scale(1.15);
  }

  /* ── Attach + input area ── */
  #inputArea {
    flex-shrink: 0;
    background: var(--vscode-input-background);
    border: 1px solid var(--vscode-input-border, rgba(255,255,255,0.1));
    border-radius: var(--radius-lg);
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 8px;
    transition: border-color var(--transition-fast),
                box-shadow var(--transition-fast);
  }
  #inputArea:focus-within {
    border-color: var(--accent);
    box-shadow: 0 0 0 3px var(--accent-glow);
  }

  #attachRow {
    display: flex;
    gap: 4px;
    flex-wrap: wrap;
  }
  .attach-btn {
    background: transparent;
    color: var(--vscode-descriptionForeground, #999);
    border: 1px solid var(--vscode-panel-border, rgba(255,255,255,0.08));
    padding: 4px 10px;
    border-radius: 12px;
    cursor: pointer;
    font-size: 0.78em;
    display: flex;
    align-items: center;
    gap: 4px;
    transition: all var(--transition-fast);
  }
  .attach-btn:hover {
    background: var(--vscode-list-hoverBackground, rgba(255,255,255,0.05));
    color: var(--vscode-foreground);
    border-color: var(--accent);
    transform: translateY(-1px);
  }

  #inputRow {
    display: flex;
    gap: 8px;
    align-items: flex-end;
  }
  #userInput {
    flex: 1;
    background: transparent;
    color: var(--vscode-input-foreground);
    border: none;
    padding: 4px 6px;
    resize: none;
    min-height: 42px;
    max-height: 200px;
    font-family: inherit;
    font-size: inherit;
    line-height: 1.5;
    outline: none;
  }
  #userInput::placeholder {
    color: var(--vscode-input-placeholderForeground);
    opacity: 0.5;
  }

  #sendBtn {
    align-self: flex-end;
    background: var(--accent);
    color: white;
    border: none;
    padding: 8px 16px;
    border-radius: var(--radius-md);
    cursor: pointer;
    font-size: 0.9em;
    font-weight: 600;
    display: flex;
    align-items: center;
    gap: 4px;
    transition: all var(--transition-fast);
  }
  #sendBtn:hover {
    background: var(--vscode-button-hoverBackground, var(--accent));
    transform: translateY(-1px);
    box-shadow: 0 4px 12px var(--accent-glow);
  }
  #sendBtn:active { transform: translateY(0); }
  #sendBtn:disabled {
    opacity: 0.4;
    cursor: not-allowed;
    transform: none;
    box-shadow: none;
  }

  /* ── Scroll button ── */
  #scrollBtn {
    position: fixed;
    bottom: 140px;
    right: 24px;
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: var(--accent);
    color: white;
    border: none;
    cursor: pointer;
    font-size: 14px;
    display: none;
    align-items: center;
    justify-content: center;
    z-index: 10;
    box-shadow: 0 4px 12px rgba(0,0,0,0.3);
    transition: all var(--transition-fast);
    animation: fadeInUp 0.25s ease-out;
  }
  #scrollBtn:hover {
    transform: translateY(-2px);
    box-shadow: 0 6px 16px rgba(0,0,0,0.4);
  }

  /* ── Empty state ── */
  .empty-state {
    flex: 1;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    text-align: center;
    padding: 40px 20px;
    opacity: 0.6;
    animation: fadeIn 0.5s ease-out;
  }
  .empty-state .emoji {
    font-size: 3em;
    margin-bottom: 16px;
    opacity: 0.7;
  }
  .empty-state h3 {
    font-size: 1.1em;
    font-weight: 500;
    margin-bottom: 8px;
    opacity: 0.9;
  }
  .empty-state p {
    font-size: 0.9em;
    line-height: 1.6;
    max-width: 300px;
    opacity: 0.7;
  }

  /* ── Toast notifications ── */
  #toast {
    position: fixed;
    top: 20px;
    right: 20px;
    background: var(--vscode-editor-background);
    border: 1px solid var(--vscode-panel-border);
    border-left: 3px solid var(--success);
    padding: 10px 16px;
    border-radius: var(--radius-md);
    font-size: 0.85em;
    box-shadow: 0 4px 16px rgba(0,0,0,0.3);
    z-index: 1000;
    display: none;
    animation: slideInRight 0.3s ease-out;
  }
  @keyframes slideInRight {
    from { transform: translateX(20px); opacity: 0; }
    to { transform: translateX(0); opacity: 1; }
  }
</style>
</head>
<body>

<!-- History Sidebar -->
<div id="historySidebar" class="collapsed">
  <div class="sidebar-header">
    <span class="title">Chats</span>
    <button id="newChatBtn" title="Start new chat">
      + New
    </button>
  </div>
  <div id="historyList">
    <div class="history-empty">
      No saved chats yet.<br>
      Your conversations will appear here.
    </div>
  </div>
</div>

<!-- Main Content -->
<div id="mainContent">

  <!-- Toolbar -->
  <div id="toolbar">
    <button id="sidebarToggle" title="Show chat history">
      <span id="toggleIcon">☰</span>
      <span id="toggleBadge" class="badge" style="display:none">0</span>
    </button>
    <span id="statusDot" title="Server status"></span>
    <select id="modelSelect" title="Select model">
      <option>Loading...</option>
    </select>
    <button id="stopBtn" class="icon-btn" style="display:none"
            title="Stop generation">⏹ Stop</button>
    <div class="font-controls">
      <button class="font-btn" id="fontDown" title="Decrease text size">A−</button>
      <button class="font-btn" id="fontUp" title="Increase text size">A+</button>
    </div>
    <button id="refreshBtn" class="icon-btn" title="Refresh models">⟳</button>
    <button id="clearBtn" class="icon-btn" title="Clear current chat">Clear</button>
  </div>

  <!-- Messages -->
  <div id="messages" role="log" aria-live="polite"></div>
  <button id="scrollBtn" title="Scroll to bottom">↓</button>

  <!-- Attachments tray -->
  <div id="attachTray"></div>

  <!-- Input area -->
  <div id="inputArea">
    <div id="attachRow">
      <button class="attach-btn" id="btnPickFiles" title="Attach files">
        📎 File
      </button>
      <button class="attach-btn" id="btnPickFolder" title="Attach folder">
        📁 Folder
      </button>
      <button class="attach-btn" id="btnOpenFiles"
              title="Attach all open files">
        📋 Open Files
      </button>
    </div>
    <div id="inputRow">
      <textarea
        id="userInput"
        placeholder="Ask anything... (Enter to send, Shift+Enter for new line)"
        aria-label="Message input"
        rows="1"
      ></textarea>
      <button id="sendBtn" title="Send message">
        Send ▶
      </button>
    </div>
  </div>
</div>

<div id="toast"></div>

<script>
  var vscode = acquireVsCodeApi();

  var messagesEl  = document.getElementById('messages');
  var userInput   = document.getElementById('userInput');
  var modelSelect = document.getElementById('modelSelect');
  var stopBtn     = document.getElementById('stopBtn');
  var sendBtn     = document.getElementById('sendBtn');
  var statusDot   = document.getElementById('statusDot');
  var scrollBtn   = document.getElementById('scrollBtn');
  var attachTray  = document.getElementById('attachTray');
  var sidebarEl   = document.getElementById('historySidebar');
  var historyList = document.getElementById('historyList');
  var toast       = document.getElementById('toast');
  var toggleIcon  = document.getElementById('toggleIcon');
  var toggleBadge = document.getElementById('toggleBadge');

  var convoHistory = [];
  var currentEl = null;
  var streaming = false;
  var autoScroll = true;
  var hasAttachments = false;

  // ── Persisted state ────────────────────────────────────────
  var savedState = vscode.getState() || {};
  var fontScale = savedState.fontScale || 1;
  // Default sidebar collapsed on first launch
  var sidebarCollapsed = savedState.sidebarCollapsed !== undefined
    ? savedState.sidebarCollapsed
    : true;
  applyFontScale();
  if (!sidebarCollapsed) {
    sidebarEl.classList.remove('collapsed');
  }
  updateToggleIcon();

  function saveState() {
    vscode.setState({ fontScale: fontScale, sidebarCollapsed: sidebarCollapsed });
  }

  function safeConvo() {
    if (!Array.isArray(convoHistory)) convoHistory = [];
    return convoHistory;
  }

  function showEmptyState() {
    messagesEl.innerHTML =
      '<div class="empty-state">' +
        '<div class="emoji">✨</div>' +
        '<h3>Ready to help</h3>' +
        '<p>Ask a question, attach files or folders for context, ' +
        'or start a conversation about your code.</p>' +
      '</div>';
  }

  showEmptyState();

  // ── Font scale ─────────────────────────────────────────────
  function applyFontScale() {
    document.documentElement.style.setProperty(
      '--font-scale', String(fontScale)
    );
  }
  document.getElementById('fontUp').onclick = function() {
    fontScale = Math.min(fontScale + 0.1, 1.6);
    applyFontScale();
    saveState();
    showToast('Text size: ' + Math.round(fontScale * 100) + '%');
  };
  document.getElementById('fontDown').onclick = function() {
    fontScale = Math.max(fontScale - 0.1, 0.7);
    applyFontScale();
    saveState();
    showToast('Text size: ' + Math.round(fontScale * 100) + '%');
  };

  // ── Sidebar toggle ─────────────────────────────────────────
  function updateToggleIcon() {
    if (sidebarCollapsed) {
      toggleIcon.textContent = '☰';
      document.getElementById('sidebarToggle').title =
        'Show chat history';
    } else {
      toggleIcon.textContent = '✕';
      document.getElementById('sidebarToggle').title =
        'Hide chat history';
    }
  }

  document.getElementById('sidebarToggle').onclick = function() {
    sidebarCollapsed = !sidebarCollapsed;
    sidebarEl.classList.toggle('collapsed', sidebarCollapsed);
    updateToggleIcon();
    saveState();
  };

  // ── History ────────────────────────────────────────────────
  document.getElementById('newChatBtn').onclick = function() {
    if (streaming) return;
    vscode.postMessage({ command: 'newChat' });
  };

  function renderHistory(chats) {
    var count = (chats && chats.length) || 0;

    // Update badge on toggle button
    if (count > 0) {
      toggleBadge.textContent = String(count);
      toggleBadge.style.display = 'flex';
    } else {
      toggleBadge.style.display = 'none';
    }

    if (count === 0) {
      historyList.innerHTML =
        '<div class="history-empty">' +
          'No saved chats yet.<br>' +
          'Your conversations will appear here.' +
        '</div>';
      return;
    }

    historyList.innerHTML = '';
    chats.forEach(function(chat) {
      var item = document.createElement('div');
      item.className = 'history-item' + (chat.isActive ? ' active' : '');
      item.setAttribute('data-id', chat.id);

      var title = document.createElement('div');
      title.className = 'h-title';
      title.textContent = chat.title;
      item.appendChild(title);

      var meta = document.createElement('div');
      meta.className = 'h-meta';
      var time = new Date(chat.timestamp);
      var timeStr = time.toLocaleTimeString([], {
        hour: '2-digit', minute: '2-digit'
      });
      meta.innerHTML = '<span>' + timeStr + '</span>' +
                      '<span>' + chat.messageCount + ' msgs</span>';
      item.appendChild(meta);

      var del = document.createElement('button');
      del.className = 'h-delete';
      del.textContent = '✕';
      del.title = 'Delete chat';
      del.onclick = function(e) {
        e.stopPropagation();
        vscode.postMessage({
          command: 'deleteChat', chatId: chat.id
        });
      };
      item.appendChild(del);

      item.onclick = function() {
        if (chat.isActive || streaming) return;
        vscode.postMessage({
          command: 'loadChat', chatId: chat.id
        });
      };

      historyList.appendChild(item);
    });
  }

  // ── Toast ──────────────────────────────────────────────────
  var toastTimer = null;
  function showToast(msg) {
    toast.textContent = msg;
    toast.style.display = 'block';
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function() {
      toast.style.display = 'none';
    }, 1500);
  }

  // ── Auto-grow textarea ─────────────────────────────────────
  userInput.addEventListener('input', function() {
    this.style.height = 'auto';
    this.style.height = Math.min(this.scrollHeight, 200) + 'px';
  });

  // ── Load models with retry ─────────────────────────────────
  function loadModels() {
    vscode.postMessage({ command: 'getModels' });
  }
  loadModels();

  var _modelRetry = setInterval(function() {
    var opts = modelSelect.options;
    var stuck = opts.length === 0
      || opts[0].text === 'Loading...'
      || opts[0].text === 'No models found';
    if (stuck) { loadModels(); } else { clearInterval(_modelRetry); }
  }, 3000);

  // ── Auto-scroll ────────────────────────────────────────────
  messagesEl.addEventListener('scroll', function() {
    var atBottom = messagesEl.scrollTop + messagesEl.clientHeight
                   >= messagesEl.scrollHeight - 40;
    autoScroll = atBottom;
    scrollBtn.style.display = atBottom ? 'none' : 'flex';
  });

  scrollBtn.addEventListener('click', function() {
    messagesEl.scrollTop = messagesEl.scrollHeight;
    autoScroll = true;
    scrollBtn.style.display = 'none';
  });

  function scrollToBottom() {
    if (autoScroll) messagesEl.scrollTop = messagesEl.scrollHeight;
  }

  // ── Attach buttons ─────────────────────────────────────────
  document.getElementById('btnPickFiles').onclick = function() {
    vscode.postMessage({ command: 'pickFiles' });
  };
  document.getElementById('btnPickFolder').onclick = function() {
    vscode.postMessage({ command: 'pickFolder' });
  };
  document.getElementById('btnOpenFiles').onclick = function() {
    vscode.postMessage({ command: 'attachOpenFiles' });
  };

  // ── Receive messages from extension ────────────────────────
  window.addEventListener('message', function(event) {
    var data = event.data;
    if (!data || !data.command) return;

    switch (data.command) {

      case 'models':
        if (data.models && data.models.length > 0) {
          modelSelect.innerHTML = data.models
            .map(function(m) {
              return '<option value="' + m + '">' + m + '</option>';
            }).join('');
          statusDot.className = 'online';
          statusDot.title = 'Connected';
          clearInterval(_modelRetry);
        } else {
          modelSelect.innerHTML =
            '<option value="">No models found</option>';
          statusDot.className = 'offline';
        }
        break;

      case 'attachments':
        hasAttachments = !!(data.items && data.items.length > 0);
        renderAttachments(data.items || []);
        break;

      case 'history':
        renderHistory(data.chats);
        break;

      case 'clearChat':
        convoHistory = [];
        showEmptyState();
        userInput.focus();
        break;

      case 'loadMessages':
        convoHistory = [];
        if (data.messages && data.messages.length) {
          for (var i = 0; i < data.messages.length; i++) {
            var m = data.messages[i];
            if (m && typeof m.role === 'string' &&
                typeof m.content === 'string') {
              convoHistory.push({ role: m.role, content: m.content });
            }
          }
        }
        messagesEl.innerHTML = '';
        for (var j = 0; j < convoHistory.length; j++) {
          var msg = convoHistory[j];
          if (msg.role === 'system') continue;
          appendBubble(msg.role, msg.content, false);
        }
        break;

      case 'injectMessages':
        convoHistory = [];
        if (data.messages && data.messages.length) {
          for (var i = 0; i < data.messages.length; i++) {
            var m = data.messages[i];
            if (m && typeof m.role === 'string' &&
                typeof m.content === 'string') {
              convoHistory.push({ role: m.role, content: m.content });
            }
          }
        }
        messagesEl.innerHTML = '';
        for (var j = 0; j < convoHistory.length; j++) {
          var msg = convoHistory[j];
          if (msg.role === 'system') continue;
          if (msg.role === 'user' && msg.content.length > 300) {
            var lines = msg.content.split('\\n');
            var preview = lines.slice(0, 5).join('\\n');
            if (lines.length > 5)
              preview += '\\n... (' + lines.length + ' lines)';
            appendBubble('user', preview, true);
          } else {
            appendBubble(msg.role, msg.content, false);
          }
        }
        break;

      case 'showContext':
        if (messagesEl.querySelector('.empty-state')) {
          messagesEl.innerHTML = '';
        }

        var ctxWrap = document.createElement('div');
        ctxWrap.className = 'msg-wrapper';

        var ctxLabel = document.createElement('div');
        ctxLabel.className = 'label';
        ctxLabel.textContent = 'You';
        ctxWrap.appendChild(ctxLabel);

        var msgBubble = document.createElement('div');
        msgBubble.className = 'message user';

        var ctxBlock = document.createElement('div');
        ctxBlock.className = 'context-block';
        ctxBlock.innerHTML =
          '<div class="ctx-label">📎 Attached context</div>' +
          '<div class="ctx-body"></div>';
        ctxBlock.querySelector('.ctx-body').textContent = data.summary;
        msgBubble.appendChild(ctxBlock);

        var textNode = document.createElement('div');
        textNode.textContent = data.userMessage;
        msgBubble.appendChild(textNode);

        ctxWrap.appendChild(msgBubble);
        messagesEl.appendChild(ctxWrap);
        scrollToBottom();

        safeConvo().push({ role: 'user', content: data.userMessage });
        break;

      case 'streamStart':
        streaming = true;
        autoScroll = true;
        stopBtn.style.display = 'flex';
        sendBtn.disabled = true;
        userInput.disabled = true;
        if (messagesEl.querySelector('.empty-state')) {
          messagesEl.innerHTML = '';
        }
        currentEl = appendBubble('assistant', '', false);
        currentEl.classList.add('streaming');
        break;

      case 'thinkingToken':
        if (currentEl) {
          var thinkBlock = currentEl.querySelector('.thinking-block');
          var thinkContent;

          if (!thinkBlock) {
            thinkBlock = document.createElement('div');
            thinkBlock.className = 'thinking-block';

            var header = document.createElement('div');
            header.className = 'thinking-header';

            var arrow = document.createElement('span');
            arrow.className = 'thinking-arrow expanded';
            arrow.textContent = '▶';
            header.appendChild(arrow);

            var icon = document.createElement('span');
            icon.className = 'thinking-icon';
            icon.textContent = '💭';
            header.appendChild(icon);

            var title = document.createElement('span');
            title.className = 'thinking-title';
            title.innerHTML = 'Thinking<span class="duration"></span>';
            header.appendChild(title);

            thinkContent = document.createElement('div');
            // Start with BOTH streaming (cursor) AND expanded (visible)
            thinkContent.className = 'thinking-content streaming expanded';

            header.addEventListener('click', function(e) {
              e.stopPropagation();
              var isExpanded = thinkContent.classList.contains('expanded');
              if (isExpanded) {
                thinkContent.classList.remove('expanded');
                arrow.classList.remove('expanded');
              } else {
                thinkContent.classList.add('expanded');
                arrow.classList.add('expanded');
              }
            });

            thinkBlock.appendChild(header);
            thinkBlock.appendChild(thinkContent);
            currentEl.insertBefore(thinkBlock, currentEl.firstChild);
          } else {
            thinkContent = thinkBlock.querySelector('.thinking-content');
          }

          thinkContent.textContent += data.token;
          thinkContent.scrollTop = thinkContent.scrollHeight;
          scrollToBottom();
        }
        break;

      case 'thinkingDone':
        if (currentEl) {
          var thinkBlock = currentEl.querySelector('.thinking-block');
          if (thinkBlock) {
            var thinkContent = thinkBlock.querySelector('.thinking-content');
            var arrow = thinkBlock.querySelector('.thinking-arrow');
            var duration = thinkBlock.querySelector('.duration');
            if (thinkContent) {
              thinkContent.classList.remove('streaming');
              // Auto-collapse when thinking is done
              thinkContent.classList.remove('expanded');
            }
            if (arrow) arrow.classList.remove('expanded');
            if (duration) {
              duration.textContent = ' · ' + data.durationSec + 's';
            }
          }
        }
        break;

      case 'contentToken':
        if (currentEl) {
          var contentDiv = currentEl.querySelector('.assistant-content');
          if (!contentDiv) {
            contentDiv = document.createElement('div');
            contentDiv.className = 'assistant-content';
            currentEl.appendChild(contentDiv);
          }
          contentDiv.textContent += data.token;
          scrollToBottom();
        }
        break;

      case 'statusToken':
        if (currentEl) {
          var contentDiv = currentEl.querySelector('.assistant-content');
          if (!contentDiv) {
            contentDiv = document.createElement('div');
            contentDiv.className = 'assistant-content';
            currentEl.appendChild(contentDiv);
          }
          var statusSpan = document.createElement('div');
          statusSpan.style.color = 'var(--warning)';
          statusSpan.style.fontSize = '0.9em';
          statusSpan.style.padding = '4px 0';
          statusSpan.textContent = data.token;
          contentDiv.appendChild(statusSpan);
          scrollToBottom();
        }
        break;

      case 'streamEnd':
        streaming = false;
        stopBtn.style.display = 'none';
        sendBtn.disabled = false;
        userInput.disabled = false;
        userInput.focus();
        if (currentEl) {
          currentEl.classList.remove('streaming');
          var thinkContent = currentEl.querySelector('.thinking-content');
          if (thinkContent) thinkContent.classList.remove('streaming');

          var contentDiv = currentEl.querySelector('.assistant-content');
          var fullText = contentDiv ? contentDiv.textContent : '';

          safeConvo().push({
            role: 'assistant', content: fullText
          });
          currentEl = null;
        }
        break;

      case 'error':
        var errBubble = document.createElement('div');
        errBubble.className = 'system-note';
        errBubble.textContent = '⚠️ ' + data.message;
        messagesEl.appendChild(errBubble);
        scrollToBottom();
        streaming = false;
        stopBtn.style.display = 'none';
        sendBtn.disabled = false;
        userInput.disabled = false;
        userInput.focus();
        if (currentEl) {
          currentEl.classList.remove('streaming');
          currentEl = null;
        }
        break;
    }
  });

  // ── Render attachment chips ────────────────────────────────
  function renderAttachments(items) {
    attachTray.innerHTML = '';
    for (var i = 0; i < items.length; i++) {
      (function(item) {
        var chip = document.createElement('span');
        chip.className = 'att-chip';

        var icon = document.createElement('span');
        icon.textContent = item.type === 'file' ? '📎' : '📁';
        chip.appendChild(icon);

        var name = document.createElement('span');
        name.className = 'att-name';
        name.textContent = item.name;
        name.title = item.name;
        chip.appendChild(name);

        var detail = document.createElement('span');
        detail.className = 'att-detail';
        detail.textContent = '· ' + item.detail;
        chip.appendChild(detail);

        var remove = document.createElement('button');
        remove.className = 'att-remove';
        remove.textContent = '✕';
        remove.title = 'Remove';
        remove.onclick = function() {
          vscode.postMessage({
            command: 'removeAttachment', id: item.id
          });
        };
        chip.appendChild(remove);

        attachTray.appendChild(chip);
      })(items[i]);
    }
  }

  // ── Send message ───────────────────────────────────────────
  function send() {
    var text = userInput.value.trim();
    if (!text || streaming) return;

    userInput.value = '';
    userInput.style.height = 'auto';

    if (messagesEl.querySelector('.empty-state')) {
      messagesEl.innerHTML = '';
    }

    if (hasAttachments) {
      vscode.postMessage({
        command: 'chatWithAttachments',
        userMessage: text,
        model: modelSelect.value
      });
    } else {
      safeConvo().push({ role: 'user', content: text });
      appendBubble('user', text, false);

      vscode.postMessage({
        command: 'chat',
        messages: safeConvo(),
        model: modelSelect.value
      });
    }
  }

  sendBtn.addEventListener('click', send);
  userInput.addEventListener('keydown', function(e) {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  });
  stopBtn.addEventListener('click', function() {
    vscode.postMessage({ command: 'stop' });
  });

  document.getElementById('clearBtn').onclick = function() {
    if (streaming) return;
    convoHistory = [];
    showEmptyState();
    userInput.focus();
    vscode.postMessage({ command: 'clearAttachments' });
  };

  document.getElementById('refreshBtn').onclick = function() {
    modelSelect.innerHTML = '<option>Loading...</option>';
    loadModels();
    showToast('Refreshing models...');
  };

  // ── Helpers ────────────────────────────────────────────────
  function appendBubble(role, content, isPreview) {
    var wrap = document.createElement('div');
    wrap.className = 'msg-wrapper';

    if (role !== 'system-note') {
      var label = document.createElement('div');
      label.className = 'label';
      label.textContent = role === 'user' ? 'You' : 'AlphaBridge';
      wrap.appendChild(label);
    }

    var bubble = document.createElement('div');
    bubble.className = 'message ' + role;

    if (role === 'assistant') {
      if (content) {
        var contentDiv = document.createElement('div');
        contentDiv.className = 'assistant-content';
        contentDiv.textContent = content;
        bubble.appendChild(contentDiv);
      }
    } else {
      bubble.textContent = content;
    }

    if (isPreview) {
      bubble.style.fontSize = '0.82em';
      bubble.style.opacity = '0.7';
      bubble.style.maxHeight = '120px';
      bubble.style.overflowY = 'auto';
    }
    wrap.appendChild(bubble);

    if (role === 'assistant') {
      var copyBtn = document.createElement('button');
      copyBtn.className = 'copy-btn';
      copyBtn.innerHTML = '📋 Copy';
      copyBtn.onclick = function() {
        var contentDiv = bubble.querySelector('.assistant-content');
        var textToCopy = contentDiv ? contentDiv.textContent
                                    : bubble.textContent;
        navigator.clipboard.writeText(textToCopy).then(function() {
          copyBtn.innerHTML = '✓ Copied';
          copyBtn.classList.add('copied');
          setTimeout(function() {
            copyBtn.innerHTML = '📋 Copy';
            copyBtn.classList.remove('copied');
          }, 1500);
        });
      };
      wrap.appendChild(copyBtn);
    }

    messagesEl.appendChild(wrap);
    scrollToBottom();
    return bubble;
  }

  // Request initial history
  vscode.postMessage({ command: 'getHistory' });
</script>

</body>
</html>`;
  }

  public dispose() {
    ChatPanel.instance = undefined;
    this._panel.dispose();
    this._disposables.forEach(d => d.dispose());
  }
}
import * as vscode from 'vscode';
import { AlphaInferenceClient } from './api';
import {
  ContextBuilder,
  Attachment,
  FileAttachment,
  FolderAttachment
} from './contextBuilder';
import { ChatPanel } from './panel';
import { AlphaBridgeSidebar } from './sidebar';   // ← NEW

const client = new AlphaInferenceClient();

// ── Ensure server is running ────────────────────────────────

async function ensureServer(): Promise<boolean> {
  if (await client.isAvailable()) return true;

  const autoLaunch = vscode.workspace
    .getConfiguration('alphabridge')
    .get('autoLaunch', false);

  if (autoLaunch && client.alphaInferencePath) {
    return vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: 'AlphaBridge: Starting server...',
        cancellable: false
      },
      async () => {
        const ok = await client.launchServer();
        if (!ok) {
          vscode.window.showErrorMessage(
            'AlphaBridge: Server did not start in time. ' +
            'Run start_chat.bat manually to see errors.'
          );
        }
        return ok;
      }
    );
  }

  const choice = await vscode.window.showErrorMessage(
    'AlphaBridge: Server is not running.',
    'Launch start_chat.bat',
    'Open Settings'
  );

  if (choice === 'Open Settings') {
    vscode.commands.executeCommand(
      'workbench.action.openSettings', 'alphabridge'
    );
    return false;
  }

  if (choice === 'Launch start_chat.bat') {
    if (!client.alphaInferencePath) {
      vscode.window.showErrorMessage(
        'Set alphabridge.alphaInferencePath in settings first.'
      );
      vscode.commands.executeCommand(
        'workbench.action.openSettings', 'alphabridge'
      );
      return false;
    }
    return vscode.window.withProgress(
      {
        location: vscode.ProgressLocation.Notification,
        title: 'AlphaBridge: Starting server...',
        cancellable: false
      },
      () => client.launchServer()
    );
  }

  return false;
}

// ── File picker helpers ─────────────────────────────────────

async function pickFiles(): Promise<FileAttachment[]> {
  const uris = await vscode.window.showOpenDialog({
    canSelectMany: true,
    canSelectFiles: true,
    canSelectFolders: false,
    title: 'Select files to attach',
    filters: {
      'Code Files': [
        'ts', 'tsx', 'js', 'jsx', 'py', 'java', 'c', 'cpp', 'h',
        'cs', 'go', 'rs', 'rb', 'php', 'swift', 'dart', 'lua',
        'sh', 'bat', 'ps1', 'html', 'css', 'scss', 'json', 'yaml',
        'yml', 'xml', 'md', 'sql', 'toml', 'vue', 'svelte'
      ],
      'All Files': ['*']
    }
  });

  if (!uris || uris.length === 0) return [];

  const attachments: FileAttachment[] = [];
  for (const uri of uris) {
    const att = ContextBuilder.readFileAttachment(uri.fsPath);
    if (att) {
      attachments.push(att);
    } else {
      vscode.window.showWarningMessage(
        `Skipped: ${uri.fsPath} (binary, too large, or unsupported)`
      );
    }
  }
  return attachments;
}

async function pickFolder(): Promise<FolderAttachment | null> {
  const uris = await vscode.window.showOpenDialog({
    canSelectMany: false,
    canSelectFiles: false,
    canSelectFolders: true,
    title: 'Select folder to attach'
  });

  if (!uris || uris.length === 0) return null;

  const att = ContextBuilder.readFolderAttachment(uris[0].fsPath);
  if (!att || att.files.length === 0) {
    vscode.window.showWarningMessage(
      'No readable code files found in that folder.'
    );
    return null;
  }
  return att;
}

// ── Activate ────────────────────────────────────────────────

export function activate(context: vscode.ExtensionContext) {

  // ── Register the sidebar view ──────────────────────────────
  const sidebar = new AlphaBridgeSidebar(context.extensionUri, client);
  context.subscriptions.push(
    vscode.window.registerWebviewViewProvider(
      AlphaBridgeSidebar.viewType,
      sidebar
    )
  );

  // Keep sidebar status fresh
  const sidebarTimer = setInterval(
    () => sidebar.refreshStatus(),
    10_000
  );
  context.subscriptions.push({
    dispose: () => clearInterval(sidebarTimer)
  });

  // ── Status bar ─────────────────────────────────────────────

  const statusBar = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Right, 100
  );
  statusBar.command = 'alphabridge.openChat';
  statusBar.text = '$(hubot) Alpha ○';
  statusBar.tooltip = 'AlphaBridge Copilot — click to open';
  statusBar.show();
  context.subscriptions.push(statusBar);

  const timer = setInterval(async () => {
    const up = await client.isAvailable();
    statusBar.text = up ? '$(hubot) Alpha ●' : '$(hubot) Alpha ○';
    statusBar.tooltip = up
      ? 'AlphaBridge: Running — click to open chat'
      : 'AlphaBridge: Server offline — click to open chat';
  }, 10_000);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });

  // ── Ask About File ─────────────────────────────────────────

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge.askAboutFile',
      async () => {
        const editor = vscode.window.activeTextEditor;
        if (!editor) {
          vscode.window.showErrorMessage('AlphaBridge: No file open.');
          return;
        }
        if (!await ensureServer()) return;

        const task = await vscode.window.showInputBox({
          prompt: 'What do you want to know about this file?',
          placeHolder: 'Review for bugs, Explain, Add comments...'
        });
        if (!task) return;

        const messages = ContextBuilder.withTask(
          ContextBuilder.fromFile(editor), task
        );
        ChatPanel.createOrShow(context.extensionUri, client, context);
        ChatPanel.instance?.sendMessages(messages);
      }
    )
  );

  // ── Ask About Selection ────────────────────────────────────

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge.askAboutSelection',
      async () => {
        const editor = vscode.window.activeTextEditor;
        if (!editor) return;
        if (!await ensureServer()) return;

        let base;
        try {
          base = ContextBuilder.fromSelection(editor);
        } catch (e: unknown) {
          vscode.window.showWarningMessage((e as Error).message);
          return;
        }

        const task = await vscode.window.showInputBox({
          prompt: 'What do you want to do with this selection?',
          placeHolder: 'Explain, Fix bug, Refactor, Convert to async...'
        });
        if (!task) return;

        const messages = ContextBuilder.withTask(base, task);
        ChatPanel.createOrShow(context.extensionUri, client, context);
        ChatPanel.instance?.sendMessages(messages);
      }
    )
  );

  // ── Explain Code ───────────────────────────────────────────

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge.explainCode',
      async () => {
        const editor = vscode.window.activeTextEditor;
        if (!editor) return;
        if (!await ensureServer()) return;

        let base;
        try {
          base = ContextBuilder.fromSelection(editor);
        } catch {
          base = ContextBuilder.fromFile(editor);
        }

        const messages = ContextBuilder.withTask(
          base,
          'Explain what this code does in plain English. Be concise.'
        );
        ChatPanel.createOrShow(context.extensionUri, client, context);
        ChatPanel.instance?.sendMessages(messages);
      }
    )
  );

  // ── Attach Files (from command palette) ─────────────────────

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge.attachFiles',
      async () => {
        if (!await ensureServer()) return;

        const files = await pickFiles();
        if (files.length === 0) return;

        ChatPanel.createOrShow(context.extensionUri, client, context);
        ChatPanel.instance?.addAttachments(files);
      }
    )
  );

  // ── Attach Folder (from command palette) ─────────────────────

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge.attachFolder',
      async () => {
        if (!await ensureServer()) return;

        const folder = await pickFolder();
        if (!folder) return;

        ChatPanel.createOrShow(context.extensionUri, client, context);
        ChatPanel.instance?.addAttachments([folder]);
      }
    )
  );

  // ── Attach Open Files ──────────────────────────────────────

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge.attachOpenFiles',
      async () => {
        if (!await ensureServer()) return;

        const openDocs = vscode.workspace.textDocuments
          .filter(d => !d.isUntitled && d.uri.scheme === 'file')
          .slice(0, 8);

        if (openDocs.length === 0) {
          vscode.window.showWarningMessage('No open files to attach.');
          return;
        }

        const files: FileAttachment[] = [];
        for (const doc of openDocs) {
          const att = ContextBuilder.readFileAttachment(doc.uri.fsPath);
          if (att) files.push(att);
        }

        if (files.length === 0) {
          vscode.window.showWarningMessage(
            'No readable code files among open tabs.'
          );
          return;
        }

        ChatPanel.createOrShow(context.extensionUri, client, context);
        ChatPanel.instance?.addAttachments(files);
      }
    )
  );

  // ── Open Chat Panel ────────────────────────────────────────

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge.openChat',
      async () => {
        if (!await ensureServer()) return;
        ChatPanel.createOrShow(context.extensionUri, client, context);
      }
    )
  );

  // ── Handle panel requests for file/folder pickers ──────────

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge._pickFiles',
      async () => {
        const files = await pickFiles();
        if (files.length > 0) {
          ChatPanel.instance?.addAttachments(files);
        }
      }
    )
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge._pickFolder',
      async () => {
        const folder = await pickFolder();
        if (folder) {
          ChatPanel.instance?.addAttachments([folder]);
        }
      }
    )
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(
      'alphabridge._attachOpenFiles',
      async () => {
        const openDocs = vscode.workspace.textDocuments
          .filter(d => !d.isUntitled && d.uri.scheme === 'file')
          .slice(0, 8);

        const files: FileAttachment[] = [];
        for (const doc of openDocs) {
          const att = ContextBuilder.readFileAttachment(doc.uri.fsPath);
          if (att) files.push(att);
        }

        if (files.length > 0) {
          ChatPanel.instance?.addAttachments(files);
        } else {
          vscode.window.showWarningMessage('No readable open files.');
        }
      }
    )
  );

  // Initial health check
  client.isAvailable().then(up => {
    statusBar.text = up ? '$(hubot) Alpha ●' : '$(hubot) Alpha ○';
  });
}

export function deactivate() {
  ChatPanel.instance?.dispose();
}
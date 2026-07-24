import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { ChatMessage } from './api';

// ── Attachment types ─────────────────────────────────────────

export interface FileAttachment {
  type: 'file';
  name: string;
  fullPath: string;
  language: string;
  lineCount: number;
  content: string;
  truncated: boolean;
}

export interface FolderAttachment {
  type: 'folder';
  name: string;
  fullPath: string;
  files: FileAttachment[];
  totalFiles: number;
  truncatedFiles: number;
}

export type Attachment = FileAttachment | FolderAttachment;

// ── Supported file extensions for code ────────────────────────

const CODE_EXTENSIONS = new Set([
  '.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs',
  '.py', '.pyw',
  '.java', '.kt', '.scala',
  '.c', '.cpp', '.cc', '.cxx', '.h', '.hpp',
  '.cs',
  '.go',
  '.rs',
  '.rb',
  '.php',
  '.swift',
  '.dart',
  '.lua',
  '.r',
  '.sql',
  '.sh', '.bash', '.zsh', '.bat', '.cmd', '.ps1',
  '.html', '.htm', '.css', '.scss', '.less',
  '.json', '.yaml', '.yml', '.toml', '.xml', '.ini', '.cfg',
  '.md', '.txt', '.rst',
  '.dockerfile', '.env', '.gitignore',
  '.vue', '.svelte', '.astro'
]);

const IGNORE_DIRS = new Set([
  'node_modules', '.git', '__pycache__', '.vscode',
  'dist', 'build', 'out', '.next', '.nuxt',
  'vendor', 'venv', '.env', 'env',
  '.idea', '.vs', 'bin', 'obj',
  'coverage', '.cache', '.parcel-cache'
]);

const IGNORE_FILES = new Set([
  'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml',
  '.DS_Store', 'Thumbs.db'
]);

// ── Builder class ────────────────────────────────────────────

export class ContextBuilder {

  // ── Config ─────────────────────────────────────────────────

  private static get maxFileLines(): number {
    return vscode.workspace
      .getConfiguration('alphabridge')
      .get('maxFileLines', 500);
  }

  private static get maxFileSize(): number {
    return vscode.workspace
      .getConfiguration('alphabridge')
      .get('maxFileSize', 100000);
  }

  // ── Read a single file into an attachment ──────────────────

  static readFileAttachment(filePath: string): FileAttachment | null {
    try {
      const stat = fs.statSync(filePath);
      if (!stat.isFile()) return null;
      if (stat.size > 1_000_000) return null;

      const ext = path.extname(filePath).toLowerCase();
      const name = path.basename(filePath);

      if (!CODE_EXTENSIONS.has(ext) && ext !== '') return null;
      if (IGNORE_FILES.has(name)) return null;

      const raw = fs.readFileSync(filePath, 'utf-8');
      const allLines = raw.split('\n');
      const maxLines = ContextBuilder.maxFileLines;
      const truncated = allLines.length > maxLines;
      const lines = truncated ? allLines.slice(0, maxLines) : allLines;

      const langMap: Record<string, string> = {
        '.ts': 'typescript', '.tsx': 'typescriptreact',
        '.js': 'javascript', '.jsx': 'javascriptreact',
        '.py': 'python', '.java': 'java',
        '.c': 'c', '.cpp': 'cpp', '.h': 'c', '.hpp': 'cpp',
        '.cs': 'csharp', '.go': 'go', '.rs': 'rust',
        '.rb': 'ruby', '.php': 'php', '.swift': 'swift',
        '.dart': 'dart', '.lua': 'lua',
        '.sh': 'shellscript', '.bash': 'shellscript',
        '.bat': 'bat', '.cmd': 'bat', '.ps1': 'powershell',
        '.html': 'html', '.css': 'css', '.scss': 'scss',
        '.json': 'json', '.yaml': 'yaml', '.yml': 'yaml',
        '.xml': 'xml', '.md': 'markdown', '.sql': 'sql',
        '.toml': 'toml', '.ini': 'ini',
        '.vue': 'vue', '.svelte': 'svelte'
      };

      const language = langMap[ext] ?? 'plaintext';

      return {
        type: 'file',
        name,
        fullPath: filePath,
        language,
        lineCount: allLines.length,
        content: lines.join('\n'),
        truncated
      };
    } catch {
      return null;
    }
  }

  // ── Read a folder recursively ──────────────────────────────

  static readFolderAttachment(
    folderPath: string,
    maxFiles: number = 20,
    maxDepth: number = 3
  ): FolderAttachment | null {
    try {
      const stat = fs.statSync(folderPath);
      if (!stat.isDirectory()) return null;

      const files: FileAttachment[] = [];
      let totalFiles = 0;
      let truncatedFiles = 0;

      const walk = (dir: string, depth: number) => {
        if (depth > maxDepth) return;
        if (files.length >= maxFiles) return;

        let entries: fs.Dirent[];
        try {
          entries = fs.readdirSync(dir, { withFileTypes: true });
        } catch {
          return;
        }

        entries.sort((a, b) => {
          if (a.isFile() && b.isDirectory()) return -1;
          if (a.isDirectory() && b.isFile()) return 1;
          return a.name.localeCompare(b.name);
        });

        for (const entry of entries) {
          if (files.length >= maxFiles) {
            truncatedFiles++;
            continue;
          }

          const fullPath = path.join(dir, entry.name);

          if (entry.isDirectory()) {
            if (IGNORE_DIRS.has(entry.name)) continue;
            walk(fullPath, depth + 1);
          } else if (entry.isFile()) {
            totalFiles++;
            const attachment = ContextBuilder.readFileAttachment(fullPath);
            if (attachment) {
              files.push(attachment);
            }
          }
        }
      };

      walk(folderPath, 0);

      return {
        type: 'folder',
        name: path.basename(folderPath),
        fullPath: folderPath,
        files,
        totalFiles,
        truncatedFiles
      };
    } catch {
      return null;
    }
  }

  // ── From active editor ─────────────────────────────────────

  static fromFile(editor: vscode.TextEditor): ChatMessage[] {
    const doc = editor.document;
    const maxLines = ContextBuilder.maxFileLines;

    const allLines = doc.getText().split('\n');
    const truncated = allLines.length > maxLines;
    const lines = allLines.slice(0, maxLines);

    const language = doc.languageId;
    const filename = path.basename(doc.fileName);
    const isCode = language !== 'markdown' && language !== 'plaintext';

    const header = truncated
      ? `### File: ${filename} (first ${maxLines} of ${allLines.length} lines)`
      : `### File: ${filename} (${allLines.length} lines)`;

    const systemPrompt = isCode
      ? `You are an expert ${language} developer. ` +
        `The user has attached a file for context. ` +
        `Answer their question directly using the file content. ` +
        `Format code in markdown fenced code blocks.`
      : `You are a helpful assistant. ` +
        `The user has attached a file for context. ` +
        `Answer their question directly using the file content.`;

    return [
      { role: 'system', content: systemPrompt },
      {
        role: 'user',
        content: [header, '```' + language, ...lines, '```'].join('\n')
      }
    ];
  }

  // ── From selection ─────────────────────────────────────────

  static fromSelection(editor: vscode.TextEditor): ChatMessage[] {
    const doc = editor.document;
    const selection = editor.selection;
    const selectedText = doc.getText(selection);

    if (!selectedText.trim()) {
      throw new Error('No text selected');
    }

    const language = doc.languageId;
    const filename = path.basename(doc.fileName);
    const startLine = selection.start.line + 1;
    const endLine = selection.end.line + 1;

    return [
      {
        role: 'system',
        content:
          `You are an expert ${language} developer. ` +
          `Answer questions about the code the user selected. ` +
          `Format code in markdown fenced code blocks.`
      },
      {
        role: 'user',
        content: [
          `### From ${filename} (lines ${startLine}-${endLine})`,
          '```' + language,
          selectedText,
          '```'
        ].join('\n')
      }
    ];
  }

  // ── From attachments (files + folders) ─────────────────────

  static fromAttachments(attachments: Attachment[]): ChatMessage[] {
    const parts: string[] = [];
    const languages = new Set<string>();

    const hasCode = attachments.some(att =>
      att.type === 'file'
        ? att.language !== 'markdown' && att.language !== 'plaintext'
        : att.files.some(f =>
            f.language !== 'markdown' && f.language !== 'plaintext'
          )
    );

    for (const att of attachments) {
      if (att.type === 'file') {
        languages.add(att.language);
        const header = att.truncated
          ? `### File: ${att.name} (first ${ContextBuilder.maxFileLines} of ${att.lineCount} lines)`
          : `### File: ${att.name} (${att.lineCount} lines)`;

        parts.push([
          header,
          '```' + att.language,
          att.content,
          '```'
        ].join('\n'));

      } else if (att.type === 'folder') {
        parts.push(`## Folder: ${att.name}/`);
        if (att.truncatedFiles > 0) {
          parts.push(
            `*Showing ${att.files.length} of ${att.totalFiles} files ` +
            `(${att.truncatedFiles} skipped)*`
          );
        }
        parts.push('');

        for (const file of att.files) {
          languages.add(file.language);
          const relPath = path.relative(att.fullPath, file.fullPath);
          const header = file.truncated
            ? `### ${relPath} (first ${ContextBuilder.maxFileLines} of ${file.lineCount} lines)`
            : `### ${relPath} (${file.lineCount} lines)`;

          parts.push([
            header,
            '```' + file.language,
            file.content,
            '```'
          ].join('\n'));
        }
      }
    }

    const langList = Array.from(languages).join(', ');

    const systemPrompt = hasCode
      ? `You are an expert developer skilled in ${langList}. ` +
        `The user has attached files for context. ` +
        `Answer their question directly using the file content provided. ` +
        `Format code in markdown fenced code blocks. ` +
        `Reference files by name when relevant.`
      : `You are a helpful assistant. ` +
        `The user has attached files for context. ` +
        `Answer their question directly using the file content provided. ` +
        `Reference files by name when relevant.`;

    return [
      { role: 'system', content: systemPrompt },
      {
        role: 'user',
        content: parts.join('\n\n')
      }
    ];
  }

  // ── From all open editors ──────────────────────────────────

  static fromOpenFiles(): ChatMessage[] {
    const openDocs = vscode.workspace.textDocuments
      .filter(d => !d.isUntitled && d.uri.scheme === 'file')
      .slice(0, 8);

    const parts = openDocs.map(doc => {
      const filename = path.basename(doc.fileName);
      const language = doc.languageId;
      const preview = doc.getText().slice(0, 3000);
      const lineCount = doc.lineCount;

      return [
        `### ${filename} (${lineCount} lines)`,
        '```' + language,
        preview,
        '```'
      ].join('\n');
    });

    return [
      {
        role: 'system',
        content:
          'You are an expert code reviewer with context ' +
          'from multiple open files in the workspace.'
      },
      {
        role: 'user',
        content: `Currently open files:\n\n${parts.join('\n\n')}`
      }
    ];
  }

  // ── Append a task (merges into context message if last is user) ──

  static withTask(
    baseMessages: ChatMessage[],
    task: string
  ): ChatMessage[] {
    const result = baseMessages.slice();
    const last = result[result.length - 1];

    // If the last message is user context, merge the task INTO it
    // so the model sees ONE user turn with question + context.
    // Most instruction-tuned models handle this better than
    // two consecutive user messages.
    if (last && last.role === 'user') {
      result[result.length - 1] = {
        role: 'user',
        content:
          `${task}\n\n` +
          `---\n\n` +
          `**Context:**\n\n` +
          last.content
      };
    } else {
      result.push({ role: 'user', content: task });
    }

    return result;
  }
}
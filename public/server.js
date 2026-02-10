#!/usr/bin/env node
/**
 * Omi Server - Version Control Server
 * Compatible with Node.js, Bun, and Deno
 * Manages SQLite repository files with authentication
 */

import fs from 'fs';
import path from 'path';
import { createHash, randomBytes } from 'crypto';
import { createServer } from 'http';
import { URL } from 'url';
import { fileURLToPath } from 'url';

// Get __dirname equivalent in ESM
const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Configuration
const REPOS_DIR = path.join(__dirname, '..', 'repos');
const SETTINGS_FILE = path.join(__dirname, '..', 'settings.txt');
const USERS_FILE = path.join(__dirname, '..', 'users.txt');
const LOCKED_USERS_FILE = path.join(__dirname, '..', 'usersbruteforcelocked.txt');
const FAILED_ATTEMPTS_FILE = path.join(__dirname, '..', 'usersfailedattempts.txt');
const API_RATE_LIMIT_FILE = path.join(__dirname, '..', 'api_rate_limit.txt');

// Ensure repos directory exists
if (!fs.existsSync(REPOS_DIR)) {
  fs.mkdirSync(REPOS_DIR, { recursive: true });
}

// Session storage (in-memory for simplicity; production should use persistent storage)
const sessions = new Map();

// Load settings from settings.txt
function loadSettings() {
  const settings = {};
  if (fs.existsSync(SETTINGS_FILE)) {
    const content = fs.readFileSync(SETTINGS_FILE, 'utf-8');
    const lines = content.split('\n').filter(line => line.trim() && !line.startsWith('#'));
    for (const line of lines) {
      const [key, value] = line.split('=').map(s => s.trim());
      if (key && value !== undefined) {
        settings[key] = value;
      }
    }
  }
  return settings;
}

// Check if user is locked due to brute force
function isUserLocked(username) {
  if (!fs.existsSync(LOCKED_USERS_FILE)) {
    return false;
  }
  const content = fs.readFileSync(LOCKED_USERS_FILE, 'utf-8');
  const lines = content.split('\n').filter(l => l.trim());
  
  for (const line of lines) {
    const [user, lockTimeStr] = line.split(':');
    if (user.trim() === username) {
      const lockTime = parseInt(lockTimeStr, 10);
      const settings = loadSettings();
      const users = loadUsers();
      const isKnownUser = username in users;
      const lockPeriod = isKnownUser
        ? parseInt(settings['ACCOUNTS_LOCKOUT_KNOWN_USERS_PERIOD'] || '60', 10)
        : parseInt(settings['ACCOUNTS_LOCKOUT_UNKNOWN_USERS_LOCKOUT_PERIOD'] || '60', 10);
      
      if (Date.now() - lockTime * 1000 < lockPeriod * 1000) {
        return true;
      }
    }
  }
  return false;
}

// Get failed attempts for username
function getFailedAttempts(username) {
  if (!fs.existsSync(FAILED_ATTEMPTS_FILE)) {
    return [];
  }
  const content = fs.readFileSync(FAILED_ATTEMPTS_FILE, 'utf-8');
  const lines = content.split('\n').filter(l => l.trim());
  const attempts = [];
  
  for (const line of lines) {
    const [user, timestamp] = line.split(':');
    if (user.trim() === username) {
      attempts.push(parseInt(timestamp, 10));
    }
  }
  return attempts;
}

// Record failed attempt
function recordFailedAttempt(username) {
  const line = `${username}:${Math.floor(Date.now() / 1000)}\n`;
  fs.appendFileSync(FAILED_ATTEMPTS_FILE, line);
}

// Clear failed attempts for user
function clearFailedAttempts(username) {
  if (!fs.existsSync(FAILED_ATTEMPTS_FILE)) {
    return;
  }
  const content = fs.readFileSync(FAILED_ATTEMPTS_FILE, 'utf-8');
  let newContent = '';
  const lines = content.split('\n').filter(l => l.trim());
  
  for (const line of lines) {
    const [user] = line.split(':');
    if (user.trim() !== username) {
      newContent += line + '\n';
    }
  }
  
  if (newContent.trim()) {
    fs.writeFileSync(FAILED_ATTEMPTS_FILE, newContent);
  } else {
    fs.unlinkSync(FAILED_ATTEMPTS_FILE);
  }
}

// Lock user account
function lockUser(username) {
  const line = `${username}:${Math.floor(Date.now() / 1000)}\n`;
  fs.appendFileSync(LOCKED_USERS_FILE, line);
}

// Check if brute force threshold reached
function checkBruteForce(username) {
  const settings = loadSettings();
  const users = loadUsers();
  const isKnownUser = username in users;

  const failuresThreshold = isKnownUser
    ? parseInt(settings['ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURES_BEFORE'] || '3', 10)
    : parseInt(settings['ACCOUNTS_LOCKOUT_UNKNOWN_USERS_FAILURES_BEFORE'] || '3', 10);

  const failureWindow = isKnownUser
    ? parseInt(settings['ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURE_WINDOW'] || '15', 10)
    : parseInt(settings['ACCOUNTS_LOCKOUT_UNKNOWN_USERS_FAILURE_WINDOW'] || '15', 10);

  const attempts = getFailedAttempts(username);
  const now = Date.now() / 1000;
  const recentAttempts = attempts.filter(timestamp => (now - timestamp) < failureWindow);

  if (recentAttempts.length >= failuresThreshold) {
    lockUser(username);
    clearFailedAttempts(username);
    return true;
  }

  return false;
}

// Load users (format: username:password:otp:language)
function loadUsers() {
  const users = {};
  if (fs.existsSync(USERS_FILE)) {
    const content = fs.readFileSync(USERS_FILE, 'utf-8');
    const lines = content.split('\n').filter(l => l.trim());
    
    for (const line of lines) {
      const parts = line.split(':');
      if (parts.length >= 2) {
        const username = parts[0].trim();
        const password = parts[1].trim();
        const otp = parts[2] ? parts[2].trim() : '';
        const language = parts[3] ? parts[3].trim() : 'en';
        users[username] = { password, otp, language };
      }
    }
  }
  return users;
}

// Get browser language from Accept-Language header
function getBrowserLanguage(req) {
  const acceptLanguage = req.headers['accept-language'] || 'en';
  const languages = acceptLanguage.split(',');
  const lang = languages[0].split(';')[0].trim();
  // Normalize language code (en-US -> en)
  if (lang.includes('-')) {
    return lang.split('-')[0].toLowerCase();
  }
  return lang.toLowerCase();
}

// Load translation file
function loadTranslations(language = 'en') {
  const langFile = path.join(__dirname, 'i18n', `${language}.i18n.json`);
  try {
    if (fs.existsSync(langFile)) {
      return JSON.parse(fs.readFileSync(langFile, 'utf-8'));
    }
  } catch (e) {
    // Fallback to English if file doesn't exist or is invalid
  }
  // Load English as fallback
  const fallbackFile = path.join(__dirname, 'i18n', 'en.i18n.json');
  try {
    return JSON.parse(fs.readFileSync(fallbackFile, 'utf-8'));
  } catch (e) {
    return {};
  }
}

// Get translation
function t(key, translations = {}) {
  return translations[key] || key;
}

// Generate TOTP secret
function generateSecret(length = 32) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let secret = '';
  for (let i = 0; i < length; i++) {
    secret += chars[Math.floor(Math.random() * 32)];
  }
  return secret;
}

// Base32 decode for TOTP
function base32Decode(secret) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  secret = secret.toUpperCase().replace(/=/g, '');
  let binaryString = '';
  
  for (let i = 0; i < secret.length; i += 8) {
    let x = '';
    for (let j = 0; j < 8 && i + j < secret.length; j++) {
      const idx = chars.indexOf(secret[i + j]);
      if (idx === -1) return null;
      x += idx.toString(2).padStart(5, '0');
    }
    const eightBits = x.match(/.{1,8}/g) || [];
    for (const bits of eightBits) {
      if (bits.length === 8) {
        binaryString += String.fromCharCode(parseInt(bits, 2));
      }
    }
  }
  
  return Buffer.from(binaryString, 'binary');
}

// Verify TOTP code
function verifyTOTP(secret, code, window = 1) {
  const secretKey = base32Decode(secret);
  if (!secretKey) return false;

  const time = Math.floor(Date.now() / 1000 / 30);
  const codeNum = parseInt(code, 10);

  for (let i = -window; i <= window; i++) {
    const testTime = time + i;
    const timeBytes = Buffer.alloc(8);
    timeBytes.writeBigInt64BE(BigInt(testTime), 0);
    
    const hmac = require('crypto').createHmac('sha1', secretKey);
    hmac.update(timeBytes);
    const hash = hmac.digest();
    
    const offset = hash[19] & 0xf;
    const otp = (
      ((hash[offset] & 0x7f) << 24) |
      ((hash[offset + 1] & 0xff) << 16) |
      ((hash[offset + 2] & 0xff) << 8) |
      (hash[offset + 3] & 0xff)
    ) % 1000000;
    
    const otpStr = otp.toString().padStart(6, '0');
    if (otpStr === code) {
      return true;
    }
  }
  return false;
}

// Simple authentication check with OTP support
function authenticate(username, password, otpCode = '') {
  const users = loadUsers();
  if (!(username in users)) return false;

  const user = users[username];

  // Check password
  if (user.password !== password) return false;

  // Check OTP if enabled for this user
  if (user.otp) {
    const match = user.otp.match(/secret=([A-Z2-7]+)/);
    if (match) {
      const secret = match[1];
      if (!otpCode || !verifyTOTP(secret, otpCode)) {
        return 'OTP_REQUIRED';
      }
    }
  }

  return true;
}

// Sanitize repository name to prevent directory traversal
function sanitizeRepoName(name) {
  name = name.replace(/\.\.\//g, '').replace(/\.\.\\/g, '').replace(/\0/g, '');
  name = path.basename(name);
  name = name.replace(/[^a-zA-Z0-9._-]/g, '');
  return name;
}

// Validate path is within REPOS_DIR
function isPathSafe(filePath) {
  try {
    const realReposDir = fs.realpathSync(REPOS_DIR);
    const realPath = fs.existsSync(filePath) 
      ? fs.realpathSync(filePath)
      : fs.realpathSync(path.dirname(filePath));
    
    return realPath.startsWith(realReposDir);
  } catch {
    return false;
  }
}

// Get list of repositories
function getReposList() {
  const repos = [];
  if (fs.existsSync(REPOS_DIR)) {
    const files = fs.readdirSync(REPOS_DIR);
    for (const file of files) {
      if (file.endsWith('.omi')) {
        const filePath = path.join(REPOS_DIR, file);
        const stat = fs.statSync(filePath);
        repos.push({
          name: file,
          size: stat.size,
          modified: stat.mtimeMs / 1000
        });
      }
    }
  }
  return repos;
}

function normalizeRepoName(name) {
  let repoName = sanitizeRepoName(name || '');
  if (!repoName) return '';
  if (!repoName.endsWith('.omi')) repoName += '.omi';
  return repoName;
}

function buildRepoSchemaSql(username) {
  const commitUser = username || 'system';
  return [
    'CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, data BLOB, size INTEGER)',
    'CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY, filename TEXT, hash TEXT, datetime TEXT, commit_id INTEGER)',
    'CREATE TABLE IF NOT EXISTS commits (id INTEGER PRIMARY KEY, message TEXT, datetime TEXT, user TEXT)',
    'CREATE TABLE IF NOT EXISTS staging (filename TEXT PRIMARY KEY, hash TEXT, datetime TEXT)',
    'CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash)',
    'CREATE INDEX IF NOT EXISTS idx_files_commit ON files(commit_id)',
    'CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash)',
    `INSERT INTO commits (message, datetime, user) VALUES ("Initial commit", strftime("%Y-%m-%d %H:%M:%S","now"), ${JSON.stringify(commitUser)})`
  ].join('; ');
}

async function runSqliteCommand(sqliteCmd, dbPath, sql) {
  if (typeof Deno !== 'undefined' && Deno.Command) {
    const command = new Deno.Command(sqliteCmd, { args: [dbPath, sql] });
    const result = await command.output();
    if (!result.success) {
      const message = new TextDecoder().decode(result.stderr || new Uint8Array());
      throw new Error(message || 'sqlite command failed');
    }
    return;
  }

  const { execFileSync } = await import('child_process');
  try {
    execFileSync(sqliteCmd, [dbPath, sql], { stdio: 'ignore' });
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      throw new Error('SQLite CLI not found. Set SQLITE=sqlite3 in settings.txt or install sqlite3.');
    }
    throw error;
  }
}

async function createEmptyRepository(repoName, username) {
  const normalized = normalizeRepoName(repoName);
  if (!normalized) {
    return { ok: false, message: 'Repository name is required' };
  }
  if (!/^[a-zA-Z0-9._-]+\.omi$/.test(normalized)) {
    return { ok: false, message: 'Invalid repository name. Use letters, numbers, dot, dash, or underscore.' };
  }

  const repoPath = path.join(REPOS_DIR, normalized);
  if (fs.existsSync(repoPath)) {
    return { ok: false, message: 'Repository already exists' };
  }

  const settings = loadSettings();
  const sqliteCmd = settings.SQLITE || 'sqlite3';
  const schemaSql = buildRepoSchemaSql(username);

  try {
    await runSqliteCommand(sqliteCmd, repoPath, schemaSql);
    return { ok: true, message: 'Repository created successfully' };
  } catch (error) {
    if (fs.existsSync(repoPath)) {
      try {
        fs.unlinkSync(repoPath);
      } catch {
        // Ignore cleanup errors
      }
    }
    return { ok: false, message: 'Failed to create repository' };
  }
}

function escapeSqliteString(value) {
  return String(value).replace(/'/g, "''");
}

function formatDateTime(date) {
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

async function runSqliteQuery(sqliteCmd, dbPath, sql) {
  const separator = '\x1f';

  if (typeof Deno !== 'undefined' && Deno.Command) {
    const command = new Deno.Command(sqliteCmd, {
      args: ['-separator', separator, '-noheader', dbPath, sql]
    });
    const result = await command.output();
    if (!result.success) {
      const message = new TextDecoder().decode(result.stderr || new Uint8Array());
      throw new Error(message || 'sqlite query failed');
    }
    return new TextDecoder().decode(result.stdout || new Uint8Array());
  }

  const { execFileSync } = await import('child_process');
  try {
    return execFileSync(sqliteCmd, ['-separator', separator, '-noheader', dbPath, sql], { encoding: 'utf8' });
  } catch (error) {
    if (error && error.code === 'ENOENT') {
      throw new Error('SQLite CLI not found. Set SQLITE=sqlite3 in settings.txt or install sqlite3.');
    }
    throw error;
  }
}

async function getLatestFiles(dbPath, pathPrefix, sqliteCmd) {
  const commitSql = 'SELECT id FROM commits ORDER BY id DESC LIMIT 1';
  const commitOutput = await runSqliteQuery(sqliteCmd, dbPath, commitSql);
  const commitId = commitOutput.trim();
  if (!commitId) return [];

  let sql = 'SELECT f.filename, f.hash, f.datetime, IFNULL(b.size, 0) FROM files f LEFT JOIN blobs b ON f.hash = b.hash WHERE f.commit_id = ' + commitId;
  if (pathPrefix) {
    const escapedPath = escapeSqliteString(pathPrefix);
    sql += ` AND (f.filename LIKE '${escapedPath}/%' OR f.filename = '${escapedPath}')`;
  }

  const output = await runSqliteQuery(sqliteCmd, dbPath, sql);
  if (!output.trim()) return [];

  return output.trim().split('\n').map(line => {
    const [filename, hash, datetime, size] = line.split('\x1f');
    return {
      filename,
      hash,
      datetime,
      size: Number(size || 0)
    };
  });
}

function organizeFiles(files, basePath = '') {
  const result = { dirs: {}, files: [] };

  for (const file of files) {
    const filename = file.filename;
    const isDirMarker = /(^|\/)\.omidir$/.test(filename);

    if (basePath && !filename.startsWith(basePath + '/') && filename !== basePath) {
      continue;
    }

    if (basePath && filename === basePath) {
      if (!isDirMarker) {
        result.files.push(file);
      }
      continue;
    }

    const relativePath = basePath ? filename.slice(basePath.length + 1) : filename;
    const parts = relativePath.split('/');

    if (parts.length > 1) {
      const dirName = parts[0];
      if (!result.dirs[dirName]) {
        result.dirs[dirName] = {
          name: dirName,
          path: basePath ? `${basePath}/${dirName}` : dirName,
          datetime: file.datetime
        };
      }
    } else if (!isDirMarker) {
      result.files.push(file);
    }
  }

  return { dirs: Object.values(result.dirs), files: result.files };
}

async function getFileContent(dbPath, hash, sqliteCmd) {
  const sql = `SELECT hex(data) FROM blobs WHERE hash = '${escapeSqliteString(hash)}' LIMIT 1`;
  const output = await runSqliteQuery(sqliteCmd, dbPath, sql);
  const hexData = output.trim();
  if (!hexData) return null;
  return Buffer.from(hexData, 'hex');
}

async function commitFileToRepo(dbPath, filename, content, username, message, sqliteCmd) {
  const dataBuffer = Buffer.isBuffer(content) ? content : Buffer.from(content || '', 'utf8');
  const hash = createHash('sha256').update(dataBuffer).digest('hex');
  const size = dataBuffer.length;
  const hexData = dataBuffer.toString('hex');
  const datetime = formatDateTime(new Date());

  const safeFilename = escapeSqliteString(filename);
  const safeMessage = escapeSqliteString(message);
  const safeUser = escapeSqliteString(username || 'system');

  // Get all files from the latest commit to preserve them
  const latestCommitSql = 'SELECT id FROM commits ORDER BY id DESC LIMIT 1';
  const latestCommitOutput = await runSqliteQuery(sqliteCmd, dbPath, latestCommitSql);
  const latestCommitId = latestCommitOutput.trim();
  
  let preserveFilesSql = '';
  if (latestCommitId) {
    // Get all files from latest commit except the one being updated
    const filesSql = `SELECT filename, hash, datetime FROM files WHERE commit_id = ${latestCommitId} AND filename != '${safeFilename}'`;
    const filesOutput = await runSqliteQuery(sqliteCmd, dbPath, filesSql);
    
    if (filesOutput.trim()) {
      const existingFiles = filesOutput.trim().split('\n').map(line => {
        const [fname, fhash, fdatetime] = line.split('\x1f');
        return { filename: fname, hash: fhash, datetime: fdatetime };
      });
      
      // Build SQL to re-insert existing files into new commit
      for (const file of existingFiles) {
        const safeFname = escapeSqliteString(file.filename);
        const safeFhash = escapeSqliteString(file.hash);
        const safeFdatetime = escapeSqliteString(file.datetime);
        preserveFilesSql += `INSERT INTO files (filename, hash, datetime, commit_id) VALUES ('${safeFname}', '${safeFhash}', '${safeFdatetime}', (SELECT id FROM commits ORDER BY id DESC LIMIT 1)); `;
      }
    }
  }

  const sql = `BEGIN; ` +
    `INSERT OR IGNORE INTO blobs (hash, data, size) VALUES ('${hash}', X'${hexData}', ${size}); ` +
    `INSERT INTO commits (message, datetime, user) VALUES ('${safeMessage}', '${datetime}', '${safeUser}'); ` +
    preserveFilesSql +
    `INSERT INTO files (filename, hash, datetime, commit_id) VALUES ('${safeFilename}', '${hash}', '${datetime}', (SELECT id FROM commits ORDER BY id DESC LIMIT 1)); ` +
    `COMMIT;`;

  await runSqliteCommand(sqliteCmd, dbPath, sql);
}

async function deleteFileFromRepo(dbPath, filename, username, message, sqliteCmd) {
  const datetime = formatDateTime(new Date());
  const safeMessage = escapeSqliteString(message);
  const safeUser = escapeSqliteString(username || 'system');
  const safeFilename = escapeSqliteString(filename);

  // Get all files from the latest commit to preserve them (except the deleted one)
  const latestCommitSql = 'SELECT id FROM commits ORDER BY id DESC LIMIT 1';
  const latestCommitOutput = await runSqliteQuery(sqliteCmd, dbPath, latestCommitSql);
  const latestCommitId = latestCommitOutput.trim();
  
  let preserveFilesSql = '';
  if (latestCommitId) {
    // Get all files from latest commit except the one being deleted
    const filesSql = `SELECT filename, hash, datetime FROM files WHERE commit_id = ${latestCommitId} AND filename != '${safeFilename}'`;
    const filesOutput = await runSqliteQuery(sqliteCmd, dbPath, filesSql);
    
    if (filesOutput.trim()) {
      const existingFiles = filesOutput.trim().split('\n').map(line => {
        const [fname, fhash, fdatetime] = line.split('\x1f');
        return { filename: fname, hash: fhash, datetime: fdatetime };
      });
      
      // Build SQL to re-insert existing files into new commit
      for (const file of existingFiles) {
        const safeFname = escapeSqliteString(file.filename);
        const safeFhash = escapeSqliteString(file.hash);
        const safeFdatetime = escapeSqliteString(file.datetime);
        preserveFilesSql += `INSERT INTO files (filename, hash, datetime, commit_id) VALUES ('${safeFname}', '${safeFhash}', '${safeFdatetime}', (SELECT id FROM commits ORDER BY id DESC LIMIT 1)); `;
      }
    }
  }

  const sql = `BEGIN; ` +
    `INSERT INTO commits (message, datetime, user) VALUES ('${safeMessage}', '${datetime}', '${safeUser}'); ` +
    preserveFilesSql +
    `COMMIT;`;
  
  await runSqliteCommand(sqliteCmd, dbPath, sql);
}

function sanitizePathSegment(name) {
  return String(name || '').replace(/\.\.\//g, '').replace(/\.\.\\/g, '').replace(/[\\/]/g, '_').replace(/\0/g, '').trim();
}

function parseRequestPath(pathname) {
  const parts = pathname.split('/').filter(Boolean);
  if (parts.length === 0) {
    return { type: 'list' };
  }

  const repoPart = parts.shift();
  let repoName = sanitizeRepoName(repoPart);
  if (!repoName) {
    return { type: 'error', message: 'Repository not found' };
  }
  if (!repoName.endsWith('.omi')) {
    repoName += '.omi';
  }

  const repoPath = path.join(REPOS_DIR, repoName);
  if (!isPathSafe(repoPath) || !fs.existsSync(repoPath)) {
    return { type: 'error', message: 'Repository not found' };
  }

  const cleanParts = parts.map(sanitizePathSegment).filter(Boolean);
  const repoSubpath = cleanParts.join('/');

  return {
    type: 'browse',
    repo: repoName,
    path: repoSubpath,
    db: repoPath
  };
}

// Check if content is text
function isTextFile(content) {
  if (!content || content.length === 0) return true;
  if (Buffer.isBuffer(content)) {
    return !content.includes(0);
  }
  return !content.includes('\0');
}

// Check if filename is markdown
function isMarkdownFile(filename) {
  const ext = path.extname(filename).toLowerCase();
  return ext === '.md' || ext === '.markdown';
}

// Check if filename is SVG
function isSVGFile(filename) {
  const ext = path.extname(filename).toLowerCase();
  return ext === '.svg';
}

// Check if filename is an image file
function isImageFile(filename) {
  const ext = path.extname(filename).toLowerCase().slice(1);
  const imageExts = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'ico', 'tiff', 'tif'];
  return imageExts.includes(ext);
}

// Get media type
function getMediaType(filename) {
  const ext = path.extname(filename).toLowerCase().slice(1);
  const audioExts = ['mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac'];
  const videoExts = ['mp4', 'webm', 'ogg', 'mkv', 'avi', 'mov', 'flv', 'wmv'];
  
  if (audioExts.includes(ext)) return 'audio';
  if (videoExts.includes(ext)) return 'video';
  return null;
}

// Simple markdown to HTML converter (basic support)
function markdownToHtml(markdown) {
  let html = markdown.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  
  // Headers
  html = html.replace(/^### (.*?)$/gm, '<h3>$1</h3>');
  html = html.replace(/^## (.*?)$/gm, '<h2>$1</h2>');
  html = html.replace(/^# (.*?)$/gm, '<h1>$1</h1>');
  
  // Bold and italic
  html = html.replace(/\*\*(.*?)\*\*/g, '<b>$1</b>');
  html = html.replace(/\*(.*?)\*/g, '<i>$1</i>');
  html = html.replace(/__(.+?)__/g, '<b>$1</b>');
  html = html.replace(/_(.+?)_/g, '<i>$1</i>');
  
  // Images (process before links to avoid conflict)
  html = html.replace(/!\[(.*?)\]\((.*?)\)/g, '<img src="$2" alt="$1" style="max-width: 100%; height: auto; border: 1px solid #ccc; margin: 10px 0;">');
  
  // Links
  html = html.replace(/\[(.*?)\]\((.*?)\)/g, '<a href="$2">$1</a>');
  
  // Code blocks
  html = html.replace(/```(.*?)```/gs, '<pre>$1</pre>');
  
  // Inline code
  html = html.replace(/`([^`]+)`/g, '<code>$1</code>');
  
  // Line breaks
  html = html.replace(/\n/g, '<br>');
  
  return html;
}

// Check if SVG contains JavaScript (security risk)
function svgContainsJavaScript(svgContent) {
  if (/<script/i.test(svgContent)) return true;
  
  const eventPatterns = [
    'onload', 'onerror', 'onmouseover', 'onmouseout', 'onclick',
    'onmousemove', 'onmousedown', 'onmouseup', 'ondblclick',
    'onfocus', 'onblur', 'onchange', 'onsubmit', 'onreset'
  ];
  
  for (const event of eventPatterns) {
    if (new RegExp(event + '=', 'i').test(svgContent)) {
      return true;
    }
  }
  
  if (/javascript:/i.test(svgContent)) return true;
  if (/data:text\/javascript/i.test(svgContent)) return true;
  
  return false;
}

// Check if SVG contains dangerous XML entities or loops
function svgContainsXMLDanger(svgContent) {
  if (/<!DOCTYPE/i.test(svgContent)) return true;
  if (/<!ENTITY/i.test(svgContent)) return true;
  if (/&lol|&x/i.test(svgContent)) return true;
  if (/<!\[CDATA\[.{10000,}/.test(svgContent)) return true;
  
  return false;
}

// Parse cookies
function parseCookies(cookieString) {
  const cookies = {};
  if (!cookieString) return cookies;
  
  for (const cookie of cookieString.split(';')) {
    const [name, value] = cookie.split('=').map(s => s.trim());
    if (name) {
      cookies[name] = decodeURIComponent(value || '');
    }
  }
  return cookies;
}

// Parse form data
async function parseFormData(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk.toString();
    });
    req.on('end', () => {
      const params = new URLSearchParams(data);
      const result = {};
      for (const [key, value] of params) {
        result[key] = value;
      }
      resolve(result);
    });
  });
}

// Parse multipart form data
async function parseMultipartForm(req) {
  return new Promise((resolve) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk.toString();
    });
    req.on('end', () => {
      // Simple multipart parser (limited support)
      const result = { fields: {}, files: {} };
      const boundary = req.headers['content-type']?.split('boundary=')[1];
      
      if (!boundary) {
        resolve(result);
        return;
      }
      
      const parts = data.split(`--${boundary}`);
      
      for (const part of parts) {
        if (!part.includes('Content-Disposition')) continue;
        
        const nameMatcher = part.match(/name="([^"]*)"/);
        if (!nameMatcher) continue;
        
        const name = nameMatcher[1];
        const filenameMatcher = part.match(/filename="([^"]*)"/);
        
        if (filenameMatcher) {
          const filename = filenameMatcher[1];
          const fileDataMatch = part.match(/\r\n\r\n([\s\S]*?)\r\n--/);
          if (fileDataMatch) {
            result.files[name] = {
              filename,
              data: Buffer.from(fileDataMatch[1], 'binary')
            };
          }
        } else {
          const fieldDataMatch = part.match(/\r\n\r\n([\s\S]*?)\r\n--/);
          if (fieldDataMatch) {
            result.fields[name] = fieldDataMatch[1].trim();
          }
        }
      }
      
      resolve(result);
    });
  });
}

// Set session cookie
function setSessionCookie(res, sessionId) {
  const maxAge = 24 * 60 * 60; // 24 hours
  res.setHeader('Set-Cookie', `sessionId=${sessionId}; Path=/; Max-Age=${maxAge}; HttpOnly`);
}

// Generate session ID
function generateSessionId() {
  return randomBytes(32).toString('hex');
}

// Check if user is logged in (via session)
function isLoggedIn(req) {
  const cookies = parseCookies(req.headers.cookie || '');
  const sessionId = cookies.sessionId;
  return sessionId && sessions.has(sessionId);
}

// Get username from session
function getUsername(req) {
  const cookies = parseCookies(req.headers.cookie || '');
  const sessionId = cookies.sessionId;
  return sessionId && sessions.has(sessionId) ? sessions.get(sessionId) : null;
}

// Send HTML response
function sendHtml(res, html, statusCode = 200) {
  res.writeHead(statusCode, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(html);
}

// Send JSON response
function sendJson(res, data, statusCode = 200) {
  res.writeHead(statusCode, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// Request handler
async function handleRequest(req, res) {
  const baseUrl = `http://${req.headers.host || 'localhost'}`;
  const url = new URL(req.url, baseUrl);
  const pathname = url.pathname;
  const query = Object.fromEntries(url.searchParams.entries());

  // Load translations based on user preference or browser language
  let username = getUsername(req) || null;
  let userLanguage = null;
  let browserLanguage = null;

  // If user is logged in, get their language preference
  if (username) {
    const users = loadUsers();
    userLanguage = users[username]?.language || null;
  }

  // Detect browser language as fallback
  if (!userLanguage) {
    browserLanguage = getBrowserLanguage(req);
  }

  // Determine which language to load
  const selectedLanguage = userLanguage || browserLanguage || 'en';

  // Load translations
  const translations = loadTranslations(selectedLanguage);

  // Handle logout
  if (pathname === '/logout') {
    const cookies = parseCookies(req.headers.cookie || '');
    if (cookies.sessionId) {
      sessions.delete(cookies.sessionId);
    }
    res.writeHead(302, { 'Location': '/' });
    res.end();
    return;
  }

  // Handle sign-in
  if (pathname === '/sign-in') {
    if (req.method === 'POST') {
      const postData = await parseFormData(req);
      const username = postData.username || '';
      const password = postData.password || '';
      const otpCode = postData.otp || '';

      let error = null;
      let show_otp = false;

      if (isUserLocked(username)) {
        error = 'Account is temporarily locked due to too many failed login attempts. Please try again later.';
      } else {
        const authResult = authenticate(username, password, otpCode);

        if (authResult === true) {
          clearFailedAttempts(username);
          const sessionId = generateSessionId();
          sessions.set(sessionId, username);
          setSessionCookie(res, sessionId);
          res.writeHead(302, { 'Location': '/' });
          res.end();
          return;
        } else if (authResult === 'OTP_REQUIRED') {
          error = t('otp-required', translations);
          show_otp = true;
        } else {
          recordFailedAttempt(username);
          if (checkBruteForce(username)) {
            error = t('account-locked', translations);
          } else {
            error = t('invalid-credentials', translations);
          }
        }
      }

      const usernameValue = username ? ` value="${username.replace(/"/g, '&quot;')}"` : '';
      const otpInput = show_otp ? `<tr><td>${t('otp', translations)}:</td><td><input type="text" name="otp" size="10" maxlength="6" required pattern="[0-9]{6}" placeholder="6-digit code"></td></tr>` : '';
      const errorMsg = error ? `<p><font color="red"><strong>${t('error', translations)}: ${error.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</strong></font></p>` : '';
      const isRTL = languagesData[selectedLanguage]?.rtl === true;
      const dirAttr = isRTL ? 'rtl' : 'ltr';

      const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html dir="${dirAttr}">
<head>
<title>${t('sign-in', translations)} - Omi Server</title>
</head>
<body bgcolor="#f0f0f0" dir="${dirAttr}">
<h1>Omi Server - ${t('sign-in', translations)}</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[${t('home', translations)}]</a></td></tr>
</table>
${errorMsg}
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>${t('username', translations)}:</td><td><input type="text" name="username" size="30" required${usernameValue}></td></tr>
<tr><td>${t('password', translations)}:</td><td><input type="password" name="password" size="30" required></td></tr>
${otpInput}
<tr><td colspan="2"><input type="submit" value="${t('sign-in', translations)}"></td></tr>
</table>
</form>
<p><a href="/sign-up">${t('create-account', translations)}</a></p>
</body>
</html>`;

      sendHtml(res, html);
      return;
    }

    const isRTL = languagesData[selectedLanguage]?.rtl === true;
    const dirAttr = isRTL ? 'rtl' : 'ltr';
    
    const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html dir="${dirAttr}">
<head>
<title>${t('sign-in', translations)} - Omi Server</title>
</head>
<body bgcolor="#f0f0f0" dir="${dirAttr}">
<h1>Omi Server - ${t('sign-in', translations)}</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[${t('home', translations)}]</a></td></tr>
</table>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>${t('username', translations)}:</td><td><input type="text" name="username" size="30" required></td></tr>
<tr><td>${t('password', translations)}:</td><td><input type="password" name="password" size="30" required></td></tr>
<tr><td colspan="2"><input type="submit" value="${t('sign-in', translations)}"></td></tr>
</table>
</form>
<p><a href="/sign-up">${t('create-account', translations)}</a></p>
</body>
</html>`;

    sendHtml(res, html);
    return;
  }

  // Handle sign-up
  if (pathname === '/sign-up') {
    if (req.method === 'POST') {
      const postData = await parseFormData(req);
      const username = postData.username || '';
      const password = postData.password || '';
      const password2 = postData.password2 || '';

      let error = null;
      let success = null;

      if (isUserLocked(username)) {
        error = t('account-locked', translations);
      } else if (!username || !password) {
        error = t('username-password-required', translations);
      } else if (password !== password2) {
        error = t('password-mismatch', translations);
      } else if (username.length < 3) {
        error = t('username-too-short', translations);
      } else {
        const users = loadUsers();
        if (username in users) {
          recordFailedAttempt(username);
          checkBruteForce(username);
          error = t('user-exists', translations);
        } else {
          const browserLanguage = getBrowserLanguage(req);
          const line = `${username}:${password}::${browserLanguage}\n`;
          try {
            fs.appendFileSync(USERS_FILE, line);
            success = t('account-created', translations);
          } catch {
            error = t('account-creation-failed', translations);
          }
        }
      }

      const errorMsg = error ? `<p><font color="red"><strong>${t('error', translations)}: ${error.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</strong></font></p>` : '';
      const successMsg = success ? `<p><font color="green"><strong>${success}</strong></font></p><p><a href="/sign-in">${t('sign-in', translations)}</a></p>` : '';
      const isRTL = languagesData[selectedLanguage]?.rtl === true;
      const dirAttr = isRTL ? 'rtl' : 'ltr';
      const form = success ? '' : `<form method="POST">
<table border="1" cellpadding="5">
<tr><td>${t('username', translations)}:</td><td><input type="text" name="username" size="30" required></td></tr>
<tr><td>${t('password', translations)}:</td><td><input type="password" name="password" size="30" required></td></tr>
<tr><td>${t('confirm', translations)}:</td><td><input type="password" name="password2" size="30" required></td></tr>
<tr><td colspan="2"><input type="submit" value="${t('sign-up', translations)}"></td></tr>
</table>
</form>
<p><a href="/sign-in">${t('already-account', translations)}</a></p>`;

      const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html dir="${dirAttr}">
<head>
<title>${t('sign-up', translations)} - Omi Server</title>
</head>
<body bgcolor="#f0f0f0" dir="${dirAttr}">
<h1>Omi Server - ${t('sign-up', translations)}</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[${t('home', translations)}]</a></td></tr>
</table>
${errorMsg}
${successMsg}
${form}
</body>
</html>`;

      sendHtml(res, html);
      return;
    }

    const isRTL = languagesData[selectedLanguage]?.rtl === true;
    const dirAttr = isRTL ? 'rtl' : 'ltr';

    const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html dir="${dirAttr}">
<head>
<title>${t('sign-up', translations)} - Omi Server</title>
</head>
<body bgcolor="#f0f0f0" dir="${dirAttr}">
<h1>Omi Server - ${t('sign-up', translations)}</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[${t('home', translations)}]</a></td></tr>
</table>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>${t('username', translations)}:</td><td><input type="text" name="username" size="30" required></td></tr>
<tr><td>${t('password', translations)}:</td><td><input type="password" name="password" size="30" required></td></tr>
<tr><td>${t('confirm', translations)}:</td><td><input type="password" name="password2" size="30" required></td></tr>
<tr><td colspan="2"><input type="submit" value="${t('sign-up', translations)}"></td></tr>
</table>
</form>
<p><a href="/sign-in">${t('already-account', translations)}</a></p>
</body>
</html>`;

    sendHtml(res, html);
    return;
  }

  // Handle language selection
  if (pathname === '/language') {
    const username = getUsername(req);
    if (!username) {
      res.writeHead(302, { 'Location': '/sign-in' });
      res.end();
      return;
    }

    if (req.method === 'POST') {
      const postData = await parseFormData(req);
      const selectedLanguage = postData.language || 'en';
      
      // Load users, update language, and save
      let users = loadUsers();
      if (users[username]) {
        users[username].language = selectedLanguage;
      }
      
      // Save updated users
      const usersContent = Object.entries(users)
        .map(([name, data]) => `${name}:${data.password}:${data.otp || ''}:${data.language || 'en'}`)
        .join('\n');
      fs.writeFileSync(USERS_FILE, usersContent, 'utf-8');
      
      res.writeHead(302, { 'Location': '/language?success=1' });
      res.end();
      return;
    }

    const successMsg = req.url.includes('success') ? '<p style="color: green;">Language preference updated!</p>' : '';
    const users = loadUsers();
    const userLanguage = users[username]?.language || 'en';
    
    // Load languages from languages.json
    let languagesData = {};
    try {
      const languagesFile = fs.readFileSync(path.join(__dirname, 'languages.json'), 'utf8');
      languagesData = JSON.parse(languagesFile);
    } catch (e) {
      console.error('Error loading languages.json:', e.message);
    }
    
    // Check if current language is RTL
    const isRTL = languagesData[userLanguage]?.rtl === true;
    const dirAttr = isRTL ? 'rtl' : 'ltr';

    // Build form with radio buttons for all languages
    let form = '<form method="POST"><table border="1" cellpadding="5">\n';
    form += '<tr><td colspan="2"><b>Select Your Language:</b></td></tr>\n';
    for (const [langCode, langInfo] of Object.entries(languagesData)) {
      const isSelected = langCode === userLanguage ? 'checked' : '';
      const rtlIndicator = (langInfo.rtl === true) ? ' (RTL)' : '';
      const langName = `${langInfo.name || langCode} (${langCode})${rtlIndicator}`;
      form += `<tr><td><input type="radio" name="language" value="${langCode}" ${isSelected}></td><td>${langName}</td></tr>\n`;
    }
    form += '<tr><td colspan="2"><input type="submit" value="Save Language"></td></tr>\n';
    form += '</table></form>\n';

    const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html dir="${dirAttr}">
<head>
<title>Language Selection - Omi Server</title>
</head>
<body bgcolor="#f0f0f0" dir="${dirAttr}">
<h1>Omi Server - Language Selection</h1>
<table border="0" cellpadding="5">
<tr><td><a href="/">[Home]</a> | <a href="/log">[Log]</a> | <a href="/language">[Language]</a></td></tr>
</table>
${successMsg}
${form}
</body>
</html>`;

    sendHtml(res, html);
    return;
  }

  // Handle settings
  if (pathname === '/settings' && !pathname.includes('/sign')) {
    if (!isLoggedIn(req)) {
      res.writeHead(302, { 'Location': '/sign-in' });
      res.end();
      return;
    }

    if (req.method === 'POST') {
      const postData = await parseFormData(req);
      let content = '';
      for (const key of ['SQLITE', 'USERNAME', 'PASSWORD', 'REPOS', 'CURL']) {
        if (key in postData) {
          content += `${key}=${postData[key]}\n`;
        }
      }

      try {
        fs.writeFileSync(SETTINGS_FILE, content);
        const success = 'Settings updated successfully';
      } catch {
        const error = 'Failed to save settings';
      }
    }

    const settings = loadSettings();
    const username = getUsername(req);
    const userDisplay = username ? `<strong>${username}</strong> | <a href="/logout">[Logout]</a>` : '<a href="/sign-in">[Sign In]</a>';

    const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Settings - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>Settings</h1></td><td align="right"><small>${userDisplay}</small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="/language">[Language]</a> | <a href="/settings">[Settings]</a> | <a href="/people">[People]</a></p>
<hr>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>SQLITE executable:</td><td><input type="text" name="SQLITE" size="50" value="${(settings.SQLITE || 'sqlite3').replace(/"/g, '&quot;')}"></td></tr>
<tr><td>USERNAME:</td><td><input type="text" name="USERNAME" size="50" value="${(settings.USERNAME || '').replace(/"/g, '&quot;')}"></td></tr>
<tr><td>PASSWORD:</td><td><input type="password" name="PASSWORD" size="50" value="${(settings.PASSWORD || '').replace(/"/g, '&quot;')}"></td></tr>
<tr><td>REPOS (server URL):</td><td><input type="text" name="REPOS" size="50" value="${(settings.REPOS || '').replace(/"/g, '&quot;')}"></td></tr>
<tr><td>CURL executable:</td><td><input type="text" name="CURL" size="50" value="${(settings.CURL || 'curl').replace(/"/g, '&quot;')}"></td></tr>
<tr><td colspan="2"><input type="submit" value="Save Settings"></td></tr>
</table>
</form>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>`;

    sendHtml(res, html);
    return;
  }

  let repoMessage = null;
  let repoMessageIsError = false;

  if (pathname === '/' && req.method === 'POST') {
    if (!isLoggedIn(req)) {
      res.writeHead(302, { 'Location': '/sign-in' });
      res.end();
      return;
    }

    const contentType = req.headers['content-type'] || '';
    let fields = {};
    let files = {};
    if (contentType.includes('multipart/form-data')) {
      const form = await parseMultipartForm(req);
      fields = form.fields || {};
      files = form.files || {};
    } else {
      fields = await parseFormData(req);
    }

    if (fields.action === 'create_repo') {
      const result = await createEmptyRepository(fields.repo_name || '', getUsername(req));
      repoMessage = result.message;
      repoMessageIsError = !result.ok;
    } else if (fields.action === 'Upload') {
      const uploadFile = files.repo_file;
      const repoName = normalizeRepoName(fields.repo_name || (uploadFile ? uploadFile.filename : ''));

      if (!repoName) {
        repoMessage = 'Repository name is required';
        repoMessageIsError = true;
      } else if (!/^[a-zA-Z0-9._-]+\.omi$/.test(repoName)) {
        repoMessage = 'Invalid repository name. Use letters, numbers, dot, dash, or underscore.';
        repoMessageIsError = true;
      } else if (!uploadFile || !uploadFile.data) {
        repoMessage = 'No repository file selected';
        repoMessageIsError = true;
      } else {
        const repoPath = path.join(REPOS_DIR, repoName);
        if (!isPathSafe(repoPath)) {
          repoMessage = 'Invalid repository path';
          repoMessageIsError = true;
        } else {
          try {
            fs.writeFileSync(repoPath, uploadFile.data);
            repoMessage = `Repository ${repoName} uploaded successfully`;
          } catch {
            repoMessage = 'Failed to save repository';
            repoMessageIsError = true;
          }
        }
      }
    }
  }

  if (pathname === '/' && query.download) {
    const repoName = normalizeRepoName(query.download);
    const repoPath = path.join(REPOS_DIR, repoName);

    if (!repoName || !isPathSafe(repoPath) || !fs.existsSync(repoPath)) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Repository not found');
      return;
    }

    const stat = fs.statSync(repoPath);
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Disposition': `attachment; filename="${repoName}"`,
      'Content-Length': stat.size
    });
    fs.createReadStream(repoPath).pipe(res);
    return;
  }

  // Check if requesting JSON API for repos list
  if (pathname === '/' && query.format === 'json') {
    const repos = getReposList();
    sendJson(res, { repos });
    return;
  }

  const requestInfo = parseRequestPath(pathname);
  if (requestInfo.type === 'error') {
    sendHtml(res, `<html><body><h1>Error: ${escapeHtml(requestInfo.message)}</h1></body></html>`, 404);
    return;
  }

  if (requestInfo.type === 'browse') {
    const settings = loadSettings();
    const sqliteCmd = settings.SQLITE || 'sqlite3';
    const repoName = requestInfo.repo;
    const repoPath = requestInfo.path;
    const dbPath = requestInfo.db;
    const username = getUsername(req);
    const repoRoot = repoName.replace(/\.omi$/, '');

    let actionMessage = null;
    let actionMessageIsError = false;

    if (req.method === 'POST' && username) {
      const contentType = req.headers['content-type'] || '';
      let fields = {};
      let files = {};
      if (contentType.includes('multipart/form-data')) {
        const form = await parseMultipartForm(req);
        fields = form.fields || {};
        files = form.files || {};
      } else {
        fields = await parseFormData(req);
      }

      const action = fields.action || '';
      if (action === 'delete_file') {
        const targetName = sanitizePathSegment(fields.target || '');
        if (!targetName) {
          actionMessage = 'File name is required';
          actionMessageIsError = true;
        } else {
          const targetPath = repoPath ? `${repoPath}/${targetName}` : targetName;
          try {
            const latestFiles = await getLatestFiles(dbPath, repoPath, sqliteCmd);
            const targetEntry = latestFiles.find(file => file.filename === targetPath && !/(^|\/)\.omidir$/.test(file.filename));
            if (!targetEntry) {
              actionMessage = 'File not found';
              actionMessageIsError = true;
            } else {
              await deleteFileFromRepo(dbPath, targetEntry.filename, username, `Deleted: ${path.basename(targetEntry.filename)}`, sqliteCmd);
              actionMessage = `File '${targetName}' deleted`;
            }
          } catch {
            actionMessage = 'Failed to delete file';
            actionMessageIsError = true;
          }
        }
      } else if (action === 'rename_file') {
        const targetName = sanitizePathSegment(fields.target || '');
        const newName = sanitizePathSegment(fields.new_name || '');
        if (!targetName || !newName) {
          actionMessage = 'File name and new name are required';
          actionMessageIsError = true;
        } else {
          const targetPath = repoPath ? `${repoPath}/${targetName}` : targetName;
          const newPath = repoPath ? `${repoPath}/${newName}` : newName;
          try {
            const latestFiles = await getLatestFiles(dbPath, repoPath, sqliteCmd);
            const targetEntry = latestFiles.find(file => file.filename === targetPath && !/(^|\/)\.omidir$/.test(file.filename));
            if (!targetEntry) {
              actionMessage = 'File not found';
              actionMessageIsError = true;
            } else {
              const fileContent = await getFileContent(dbPath, targetEntry.hash, sqliteCmd);
              await commitFileToRepo(dbPath, newPath, fileContent || Buffer.alloc(0), username, `Renamed: ${path.basename(targetEntry.filename)} -> ${newName}`, sqliteCmd);
              await deleteFileFromRepo(dbPath, targetEntry.filename, username, `Deleted: ${path.basename(targetEntry.filename)}`, sqliteCmd);
              actionMessage = `File '${targetName}' renamed to '${newName}'`;
            }
          } catch {
            actionMessage = 'Failed to rename file';
            actionMessageIsError = true;
          }
        }
      } else if (action === 'create_dir') {
        const dirName = sanitizePathSegment(fields.dir_name || '');
        if (!dirName) {
          actionMessage = 'Directory name is required';
          actionMessageIsError = true;
        } else {
          const dirPath = repoPath ? `${repoPath}/${dirName}` : dirName;
          const markerPath = `${dirPath}/.omidir`;
          try {
            await commitFileToRepo(dbPath, markerPath, '', username, `Create directory: ${dirName}`, sqliteCmd);
            actionMessage = `Directory '${dirName}' created`;
          } catch {
            actionMessage = 'Failed to create directory';
            actionMessageIsError = true;
          }
        }
      } else if (action === 'create_file') {
        const fileName = sanitizePathSegment(fields.file_name || '');
        const content = fields.file_content || '';
        if (!fileName) {
          actionMessage = 'File name is required';
          actionMessageIsError = true;
        } else {
          const fullPath = repoPath ? `${repoPath}/${fileName}` : fileName;
          try {
            await commitFileToRepo(dbPath, fullPath, content, username, `Created file: ${fileName}`, sqliteCmd);
            actionMessage = `File '${fileName}' created`;
          } catch {
            actionMessage = 'Failed to create file';
            actionMessageIsError = true;
          }
        }
      } else if (files.upload_file) {
        const uploadFile = files.upload_file;
        const fileName = sanitizePathSegment(uploadFile.filename || '');
        if (!fileName || !uploadFile.data) {
          actionMessage = 'No file selected';
          actionMessageIsError = true;
        } else {
          const fullPath = repoPath ? `${repoPath}/${fileName}` : fileName;
          try {
            await commitFileToRepo(dbPath, fullPath, uploadFile.data, username, `Uploaded: ${fileName}`, sqliteCmd);
            actionMessage = `File '${fileName}' uploaded successfully`;
          } catch {
            actionMessage = 'Failed to upload file';
            actionMessageIsError = true;
          }
        }
      }
    }

    let files = [];
    try {
      files = await getLatestFiles(dbPath, repoPath, sqliteCmd);
    } catch (error) {
      sendHtml(res, `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>SQLite Error - ${escapeHtml(repoName)}</title>
</head>
<body bgcolor="#f0f0f0">
<h1>SQLite Error</h1>
<p>${escapeHtml(error.message || 'SQLite error')}</p>
<p>Set SQLITE in settings.txt to the sqlite3 binary, or install sqlite3.</p>
</body>
</html>`, 500);
      return;
    }
    const isFile = files.length === 1 && files[0].filename === repoPath && !/(^|\/)\.omidir$/.test(files[0].filename);

    if (isFile && req.method === 'POST' && username) {
      const postData = await parseFormData(req);
      const action = postData.action || '';
      const fileEntry = files[0];

      if (action === 'delete_file') {
        try {
          await deleteFileFromRepo(dbPath, fileEntry.filename, username, `Deleted: ${path.basename(fileEntry.filename)}`, sqliteCmd);
          const parentPath = repoPath.includes('/') ? repoPath.slice(0, repoPath.lastIndexOf('/')) : '';
          const redirectPath = parentPath ? `/${repoRoot}/${parentPath}` : `/${repoRoot}`;
          res.writeHead(302, { Location: redirectPath });
          res.end();
          return;
        } catch {
          actionMessage = 'Failed to delete file';
          actionMessageIsError = true;
        }
      }

      if (action === 'rename_file') {
        const newName = sanitizePathSegment(postData.new_name || '');
        if (!newName) {
          actionMessage = 'New file name is required';
          actionMessageIsError = true;
        } else {
          const parentPath = repoPath.includes('/') ? repoPath.slice(0, repoPath.lastIndexOf('/')) : '';
          const newPath = parentPath ? `${parentPath}/${newName}` : newName;
          try {
            const fileContent = await getFileContent(dbPath, fileEntry.hash, sqliteCmd);
            await commitFileToRepo(dbPath, newPath, fileContent || Buffer.alloc(0), username, `Renamed: ${path.basename(fileEntry.filename)} -> ${newName}`, sqliteCmd);
            await deleteFileFromRepo(dbPath, fileEntry.filename, username, `Deleted: ${path.basename(fileEntry.filename)}`, sqliteCmd);
            const redirectPath = `/${repoRoot}/${newPath}`;
            res.writeHead(302, { Location: redirectPath });
            res.end();
            return;
          } catch {
            actionMessage = 'Failed to rename file';
            actionMessageIsError = true;
          }
        }
      }

      if (action === 'save_file') {
        const newContent = postData.file_content || '';
        try {
          await commitFileToRepo(dbPath, fileEntry.filename, newContent, username, `Updated: ${path.basename(fileEntry.filename)}`, sqliteCmd);
          actionMessage = 'File saved successfully';
          actionMessageIsError = false;
        } catch {
          actionMessage = 'Failed to save file';
          actionMessageIsError = true;
        }
      }

      files = await getLatestFiles(dbPath, repoPath, sqliteCmd);
    }

    if (isFile) {
      const fileEntry = files[0];
      const fileContent = await getFileContent(dbPath, fileEntry.hash, sqliteCmd);
      const fileName = path.basename(fileEntry.filename);

      if (query.download === '1') {
        res.writeHead(200, {
          'Content-Type': 'application/octet-stream',
          'Content-Disposition': `attachment; filename="${fileName}"`,
          'Content-Length': fileContent ? fileContent.length : 0
        });
        res.end(fileContent || Buffer.alloc(0));
        return;
      }

      const isText = fileContent && isTextFile(fileContent);
      const displayContent = isText ? fileContent.toString('utf8') : '';
      const inEditMode = query.edit === '1' && isText;
      const actionMessageHtml = actionMessage
        ? `<p><font color="${actionMessageIsError ? 'red' : 'green'}"><strong>${escapeHtml(actionMessage)}</strong></font></p>`
        : '';
      const fileActions = username ? `
    <p>
    <form method="GET" style="display:inline">
    <input type="submit" formaction="?download=1" value="Download">
    </form>
    ${isText ? `<form method="GET" style="display:inline">
    <input type="hidden" name="edit" value="1">
    <input type="submit" value="Edit">
    </form>` : ''}
    <form method="POST" style="display:inline">
    <input type="hidden" name="action" value="delete_file">
    <input type="submit" value="Delete" onclick="return confirm('Delete file ${escapeHtml(fileName)}?')">
    </form>
    <form method="POST" style="display:inline">
    <input type="hidden" name="action" value="rename_file">
    <input type="text" name="new_name" size="20" placeholder="New name">
    <input type="submit" value="Rename">
    </form>
    </p>
    ` : '';
      
      // Determine content display based on file type and edit mode
      let contentHtml = '';
      if (inEditMode) {
        // Edit mode - show textarea with markdown reference
        const markdownRef = `<p><b>Markdown Syntax Reference:</b></p>
<table border="1" cellpadding="5" style="font-size: 12px; margin-bottom: 20px;">
<tr><th>Syntax</th><th>Result</th></tr>
<tr><td># Heading 1</td><td>Large heading</td></tr>
<tr><td>## Heading 2</td><td>Medium heading</td></tr>
<tr><td>### Heading 3</td><td>Small heading</td></tr>
<tr><td>**bold text**</td><td><b>bold text</b></td></tr>
<tr><td>*italic text*</td><td><i>italic text</i></td></tr>
<tr><td>\`code\`</td><td><code>code</code></td></tr>
<tr><td>\`\`\`<br>code block<br>\`\`\`</td><td>Multi-line code</td></tr>
<tr><td>[link text](url)</td><td>Clickable link</td></tr>
<tr><td>![alt text](image.jpg)</td><td>Image from repo or URL</td></tr>
<tr><td>![alt](https://example.com/img.jpg)</td><td>Image from URL</td></tr>
</table>`;
        contentHtml = `${markdownRef}<form method="POST">
<textarea name="file_content" rows="20" cols="80" style="width: 100%; max-width: 800px; font-family: monospace; box-sizing: border-box;">${escapeHtml(displayContent)}</textarea><br><br>
<input type="hidden" name="action" value="save_file">
<input type="submit" value="Save">
<input type="button" value="Cancel" onclick="window.location.href='?'">
</form>`;
      } else if (!isText) {
        // Check if it's an image file
        if (isImageFile(fileEntry.filename)) {
          // Display image file
          const base64Data = fileContent.toString('base64');
          const ext = path.extname(fileEntry.filename).toLowerCase().slice(1);
          const mimeTypes = {
            'jpg': 'image/jpeg',
            'jpeg': 'image/jpeg',
            'png': 'image/png',
            'gif': 'image/gif',
            'bmp': 'image/bmp',
            'webp': 'image/webp',
            'ico': 'image/x-icon',
            'tiff': 'image/tiff',
            'tif': 'image/tiff'
          };
          const mimeType = mimeTypes[ext] || 'image/jpeg';
          contentHtml = `<p><strong>Binary file (${fileContent.length} bytes)</strong></p>
<p>Hash: ${escapeHtml(fileEntry.hash)}</p>
<hr>
<p><b>Image File</b></p>
<div style="border: 1px solid #ccc; padding: 10px; background-color: white; display: inline-block;">
<img src="data:${mimeType};base64,${base64Data}" alt="${escapeHtml(path.basename(fileEntry.filename))}" style="max-width: 100%; height: auto; max-height: 500px;">
</div>
<p><small>Image file size: ${Number(fileContent.length).toLocaleString()} bytes</small></p>`;
        } else {
          contentHtml = `<p><strong>Binary file (${fileContent ? fileContent.length : 0} bytes)</strong></p>
<p>Hash: ${escapeHtml(fileEntry.hash)}</p>`;
        }
      } else if (isMarkdownFile(fileEntry.filename)) {
        // Render markdown
        contentHtml = `<div style="font-family: Arial, sans-serif; line-height: 1.6;">
${markdownToHtml(displayContent)}
</div>`;
      } else {
        // Show raw text in pre tag
        contentHtml = `<pre>${escapeHtml(displayContent)}</pre>`;
      }
      
      const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>${escapeHtml(fileEntry.filename)} - ${escapeHtml(repoName)}</title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>${escapeHtml(repoName)}</h1></td><td align="right"><small>${username ? `<strong>${escapeHtml(username)}</strong> | <a href="/logout">[Logout]</a>` : '<a href="/sign-in">[Sign In]</a>'}</small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="/language">[Language]</a> | <a href="/${escapeHtml(repoRoot)}">[Repository Root]</a></p>
<h2>File: ${escapeHtml(fileEntry.filename)}</h2>
<p><a href="?download=1">[Download]</a></p>
${fileActions}
<hr>
${actionMessageHtml}
${contentHtml}
<hr>
<p><small>Omi Server</small></p>
</body>
</html>`;
      sendHtml(res, html);
      return;
    }

    const organized = organizeFiles(files, repoPath);
    const directoryTitle = repoPath ? escapeHtml(repoPath) : '';
    const dirRows = organized.dirs.map(dir => `<tr>
  <td><a href="/${escapeHtml(repoRoot)}/${escapeHtml(dir.path)}">📁 ${escapeHtml(dir.name)}/</a></td>
  <td>-</td>
  <td>${escapeHtml(dir.datetime)}</td>
  <td>-</td>
  </tr>`).join('\n');
    const fileRows = organized.files.map(file => {
      const isText = isTextFile(Buffer.from(file.data || '', 'base64'));
      const fileSize = Number(file.size).toLocaleString();
      const fileDateTime = escapeHtml(file.datetime);
      const fileBasename = escapeHtml(path.basename(file.filename));
      const filePathEscaped = escapeHtml(file.filename);
      const fileLinkPath = `/${escapeHtml(repoRoot)}/${escapeHtml(file.filename)}`;
      
      let actionsHtml = '-';
      if (username) {
        let editLink = '';
        if (isText) {
          editLink = `<a href="${fileLinkPath}?edit=1">[Edit]</a> | `;
        }
        actionsHtml = `
  ${editLink}<form method="POST" style="display:inline">
  <input type="hidden" name="action" value="delete_file">
  <input type="hidden" name="target" value="${escapeHtml(path.basename(file.filename))}">
  <input type="submit" value="Delete" onclick="return confirm('Delete file ${fileBasename}?')">
  </form>
  <form method="POST" style="display:inline">
  <input type="hidden" name="action" value="rename_file">
  <input type="hidden" name="target" value="${escapeHtml(path.basename(file.filename))}">
  <input type="text" name="new_name" size="12" placeholder="New name">
  <input type="submit" value="Rename">
  </form>`;
      }
      
      return `<tr>
  <td><a href="${fileLinkPath}">📄 ${fileBasename}</a></td>
  <td>${fileSize}</td>
  <td>${fileDateTime}</td>
  <td>${actionsHtml}</td>
  </tr>`;
    }).join('\n');
    const emptyRow = (!organized.dirs.length && !organized.files.length) ? '<tr><td colspan="4">No files in this directory</td></tr>' : '';

    const actionMessageHtml = actionMessage
      ? `<p><font color="${actionMessageIsError ? 'red' : 'green'}"><strong>${escapeHtml(actionMessage)}</strong></font></p>`
      : '';

    const actionForms = username ? `
<p><b>Create Directory</b></p>
<form method="POST">
<input type="text" name="dir_name" size="30" placeholder="new-folder">
<input type="hidden" name="action" value="create_dir">
<input type="submit" value="Create Directory">
</form>
<p><b>Create Text File</b></p>
<form method="POST">
<input type="text" name="file_name" size="30" placeholder="notes.txt">
<br>
<textarea name="file_content" rows="6" cols="60" placeholder="Enter file contents"></textarea>
<br>
<input type="hidden" name="action" value="create_file">
<input type="submit" value="Create File">
</form>
<p><b>Upload File to This Directory</b></p>
<form method="POST" enctype="multipart/form-data">
<input type="file" name="upload_file" required>
<input type="submit" value="Upload">
</form>
` : '<p><small><a href="/sign-in">[Sign in]</a> to upload files</small></p>';

    const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>${directoryTitle || 'Root'} - ${escapeHtml(repoName)}</title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>${escapeHtml(repoName)}</h1></td><td align="right"><small>${username ? `<strong>${escapeHtml(username)}</strong> | <a href="/logout">[Logout]</a>` : '<a href="/sign-in">[Sign In]</a>'}</small></td></tr>
</table>
<p><a href="/">[Home]</a></p>
<h2>Directory: /${directoryTitle}</h2>
<hr>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr bgcolor="#333333">
<th><font color="white">Name</font></th>
<th><font color="white">Size</font></th>
<th><font color="white">Modified</font></th>
<th><font color="white">Actions</font></th>
</tr>
${repoPath ? `<tr>
  <td><a href="/${escapeHtml(repoRoot)}${repoPath.includes('/') ? '/' + escapeHtml(repoPath.split('/').slice(0, -1).join('/')) : ''}">📁 ..</a></td>
  <td>-</td>
  <td>-</td>
  <td>-</td>
  </tr>` : ''}
${dirRows}
${fileRows}
${emptyRow}
</table>
<hr>
${actionMessageHtml}
${actionForms}
<hr>
<p><small>Omi Server</small></p>
</body>
</html>`;
    sendHtml(res, html);
    return;
  }

  // Default: Show repository list
  const repos = getReposList();
  const username = getUsername(req);
  const userDisplay = username
    ? `<strong>${username}</strong> | <a href="/logout">[Logout]</a>`
    : `<a href="/sign-in">[Sign In]</a>`;

  const reposTable = repos.length > 0
    ? repos.map(repo => `<tr>
<td><a href="/${repo.name.replace(/\.omi$/, '')}">${repo.name.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</a></td>
<td>${repo.size.toLocaleString()}</td>
<td>${new Date(repo.modified * 1000).toISOString().replace('T', ' ').slice(0, 19)}</td>
<td><a href="?download=${encodeURIComponent(repo.name)}">[Download]</a></td>
</tr>`).join('\n')
    : '<tr><td colspan="4">No repositories found</td></tr>';

  const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Omi Server - Repository List</title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>Omi Server - Repository List</h1></td><td align="right"><small>${userDisplay}</small></td></tr>
</table>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr bgcolor="#e8f4f8">
<td colspan="4">
<strong>Repositories:</strong> ${repos.length}
</td>
</tr>
</table>
${repoMessage ? `<p><font color="${repoMessageIsError ? 'red' : 'green'}"><strong>${repoMessage.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</strong></font></p>` : ''}
<h2>Available Repositories</h2>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr bgcolor="#333333">
<th><font color="white">Repository</font></th>
<th><font color="white">Size (bytes)</font></th>
<th><font color="white">Last Modified</font></th>
<th><font color="white">Actions</font></th>
</tr>
${reposTable}
</table>
${username ? `<h2>Create New Repository</h2>
<form method="POST">
<table border="0" cellpadding="5">
<tr><td>Repository name:</td><td><input type="text" name="repo_name" size="30"> (e.g., wekan.omi)</td></tr>
<tr><td colspan="2"><input type="hidden" name="action" value="create_repo"><input type="submit" value="Create Repository"></td></tr>
</table>
</form>
<h2>Upload Repository</h2>
<form method="POST" enctype="multipart/form-data">
<table border="0" cellpadding="5">
<tr><td>Repository name:</td><td><input type="text" name="repo_name" size="30"> (e.g., wekan.omi)</td></tr>
<tr><td>File:</td><td><input type="file" name="repo_file"></td></tr>
<tr><td colspan="2"><input type="submit" name="action" value="Upload"></td></tr>
</table>
</form>` : '<p><a href="/sign-in">[Sign In to upload repositories]</a></p>'}
<h2>API Endpoints</h2>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr><td><strong>List repos (JSON):</strong></td><td>GET /?format=json</td></tr>
<tr><td><strong>Download repo:</strong></td><td>GET /?download=wekan.omi</td></tr>
</table>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>`;

  sendHtml(res, html);
}

// Create HTTP server
const PORT = process.env.PORT || 8080;
const server = createServer(handleRequest);

server.listen(PORT, () => {
  console.log(`Omi Server running on http://localhost:${PORT}/`);
  console.log(`Compatible with Node.js, Bun, and Deno`);
});

// Graceful shutdown
process.on('SIGINT', () => {
  console.log('\nShutting down gracefully...');
  server.close(() => {
    process.exit(0);
  });
});

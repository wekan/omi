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
import { parse as parseUrl } from 'url';
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

// Load users from phpusers.txt (format: username:password:otp)
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
        users[username] = { password, otp };
      }
    }
  }
  return users;
}

// Generate random OTP secret (base32)
function generateOTPSecret(length = 16) {
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

// Check if content is text
function isTextFile(content) {
  if (!content || content.length === 0) return true;
  if (content.includes('\0')) return false;
  return true;
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

// Request handler
async function handleRequest(req, res) {
  const url = parseUrl(req.url, true);
  const pathname = url.pathname;
  const query = url.query;

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
          error = 'OTP code required';
          show_otp = true;
        } else {
          recordFailedAttempt(username);
          if (checkBruteForce(username)) {
            error = 'Too many failed login attempts. Account locked temporarily.';
          } else {
            error = 'Invalid username or password';
          }
        }
      }

      const usernameValue = username ? ` value="${username.replace(/"/g, '&quot;')}"` : '';
      const otpInput = show_otp ? '<tr><td>OTP Code:</td><td><input type="text" name="otp" size="10" maxlength="6" required pattern="[0-9]{6}" placeholder="6-digit code"></td></tr>' : '';
      const errorMsg = error ? `<p><font color="red"><strong>Error: ${error.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</strong></font></p>` : '';

      const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Sign In - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<h1>Omi Server - Sign In</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[Home]</a></td></tr>
</table>
${errorMsg}
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>Username:</td><td><input type="text" name="username" size="30" required${usernameValue}></td></tr>
<tr><td>Password:</td><td><input type="password" name="password" size="30" required></td></tr>
${otpInput}
<tr><td colspan="2"><input type="submit" value="Sign In"></td></tr>
</table>
</form>
<p><a href="/sign-up">Create new account</a></p>
</body>
</html>`;

      sendHtml(res, html);
      return;
    }

    const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Sign In - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<h1>Omi Server - Sign In</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[Home]</a></td></tr>
</table>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>Username:</td><td><input type="text" name="username" size="30" required></td></tr>
<tr><td>Password:</td><td><input type="password" name="password" size="30" required></td></tr>
<tr><td colspan="2"><input type="submit" value="Sign In"></td></tr>
</table>
</form>
<p><a href="/sign-up">Create new account</a></p>
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
        error = 'Too many sign-up attempts. Please try again later.';
      } else if (!username || !password) {
        error = 'Username and password are required';
      } else if (password !== password2) {
        error = 'Passwords do not match';
      } else if (username.length < 3) {
        error = 'Username must be at least 3 characters';
      } else {
        const users = loadUsers();
        if (username in users) {
          recordFailedAttempt(username);
          checkBruteForce(username);
          error = 'User already exists';
        } else {
          const line = `${username}:${password}:\n`;
          try {
            fs.appendFileSync(USERS_FILE, line);
            success = 'Account created! You can now sign in.';
          } catch {
            error = 'Failed to create account';
          }
        }
      }

      const errorMsg = error ? `<p><font color="red"><strong>Error: ${error.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</strong></font></p>` : '';
      const successMsg = success ? `<p><font color="green"><strong>${success}</strong></font></p><p><a href="/sign-in">Go to Sign In</a></p>` : '';
      const form = success ? '' : `<form method="POST">
<table border="1" cellpadding="5">
<tr><td>Username:</td><td><input type="text" name="username" size="30" required></td></tr>
<tr><td>Password:</td><td><input type="password" name="password" size="30" required></td></tr>
<tr><td>Confirm:</td><td><input type="password" name="password2" size="30" required></td></tr>
<tr><td colspan="2"><input type="submit" value="Create Account"></td></tr>
</table>
</form>
<p><a href="/sign-in">Already have an account? Sign in</a></p>`;

      const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Sign Up - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<h1>Omi Server - Sign Up</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[Home]</a></td></tr>
</table>
${errorMsg}
${successMsg}
${form}
</body>
</html>`;

      sendHtml(res, html);
      return;
    }

    const html = `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Sign Up - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<h1>Omi Server - Sign Up</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[Home]</a></td></tr>
</table>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>Username:</td><td><input type="text" name="username" size="30" required></td></tr>
<tr><td>Password:</td><td><input type="password" name="password" size="30" required></td></tr>
<tr><td>Confirm:</td><td><input type="password" name="password2" size="30" required></td></tr>
<tr><td colspan="2"><input type="submit" value="Create Account"></td></tr>
</table>
</form>
<p><a href="/sign-in">Already have an account? Sign in</a></p>
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
<p><a href="/">[Home]</a> | <a href="/settings">[Settings]</a> | <a href="/people">[People]</a></p>
<hr>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>SQLITE executable:</td><td><input type="text" name="SQLITE" size="50" value="${(settings.SQLITE || 'sqlite').replace(/"/g, '&quot;')}"></td></tr>
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

  // Check if requesting JSON API for repos list
  if (pathname === '/' && query.format === 'json') {
    const repos = getReposList();
    sendJson(res, { repos });
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
${username ? `<h2>Upload Repository</h2>
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

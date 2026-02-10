<?php
/**
 * Omi Server - Version Control Server
 * Manages SQLite repository files with authentication
 */

session_start();

// Configuration
define('REPOS_DIR', __DIR__ . '/../repos');
define('SETTINGS_FILE', __DIR__ . '/../settings.txt');
define('USERS_FILE', __DIR__ . '/../users.txt');
define('LOCKED_USERS_FILE', __DIR__ . '/../usersbruteforcelocked.txt');
define('FAILED_ATTEMPTS_FILE', __DIR__ . '/../usersfailedattempts.txt');

// Ensure repos directory exists
if (!is_dir(REPOS_DIR)) {
    mkdir(REPOS_DIR, 0755, true);
}

// Load settings from settings.txt
function loadSettings() {
    $settings = [];
    if (file_exists(SETTINGS_FILE)) {
        $lines = file(SETTINGS_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        foreach ($lines as $line) {
            if (strpos($line, '=') !== false) {
                list($key, $value) = explode('=', $line, 2);
                $settings[trim($key)] = trim($value);
            }
        }
    }
    return $settings;
}

// Check if user is locked due to brute force
function isUserLocked($username) {
    if (!file_exists(LOCKED_USERS_FILE)) {
        return false;
    }
    $locked = file(LOCKED_USERS_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($locked as $line) {
        $parts = explode(':', $line, 2);
        if (trim($parts[0]) === $username) {
            if (isset($parts[1])) {
                $lockTime = intval($parts[1]);
                $settings = loadSettings();
                $users = loadUsers();
                $isKnownUser = isset($users[$username]);
                $lockPeriod = $isKnownUser ?
                    intval($settings['ACCOUNTS_LOCKOUT_KNOWN_USERS_PERIOD'] ?? 60) :
                    intval($settings['ACCOUNTS_LOCKOUT_UNKNOWN_USERS_LOCKOUT_PERIOD'] ?? 60);

                if (time() - $lockTime < $lockPeriod) {
                    return true;
                }
            }
        }
    }
    return false;
}

// Get failed attempts for username
function getFailedAttempts($username) {
    if (!file_exists(FAILED_ATTEMPTS_FILE)) {
        return [];
    }
    $attempts = [];
    $lines = file(FAILED_ATTEMPTS_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        $parts = explode(':', $line, 2);
        if (count($parts) === 2 && trim($parts[0]) === $username) {
            $attempts[] = intval($parts[1]);
        }
    }
    return $attempts;
}

// Record failed attempt
function recordFailedAttempt($username) {
    $line = $username . ':' . time() . "\n";
    file_put_contents(FAILED_ATTEMPTS_FILE, $line, FILE_APPEND | LOCK_EX);
}

// Clear failed attempts for user
function clearFailedAttempts($username) {
    if (!file_exists(FAILED_ATTEMPTS_FILE)) {
        return;
    }
    $lines = file(FAILED_ATTEMPTS_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $newContent = '';
    foreach ($lines as $line) {
        $parts = explode(':', $line, 2);
        if (trim($parts[0]) !== $username) {
            $newContent .= $line . "\n";
        }
    }
    file_put_contents(FAILED_ATTEMPTS_FILE, $newContent, LOCK_EX);
}

// Lock user account
function lockUser($username) {
    $line = $username . ':' . time() . "\n";
    file_put_contents(LOCKED_USERS_FILE, $line, FILE_APPEND | LOCK_EX);
}

// Check if brute force threshold reached
function checkBruteForce($username) {
    $settings = loadSettings();
    $users = loadUsers();
    $isKnownUser = isset($users[$username]);

    $failuresThreshold = $isKnownUser ?
        intval($settings['ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURES_BEFORE'] ?? 3) :
        intval($settings['ACCOUNTS_LOCKOUT_UNKNOWN_USERS_FAILURES_BEFORE'] ?? 3);

    $failureWindow = $isKnownUser ?
        intval($settings['ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURE_WINDOW'] ?? 15) :
        intval($settings['ACCOUNTS_LOCKOUT_UNKNOWN_USERS_FAILURE_WINDOW'] ?? 15);

    $attempts = getFailedAttempts($username);
    $recentAttempts = array_filter($attempts, function($timestamp) use ($failureWindow) {
        return (time() - $timestamp) < $failureWindow;
    });

    if (count($recentAttempts) >= $failuresThreshold) {
        lockUser($username);
        clearFailedAttempts($username);
        return true;
    }

    return false;
}

// Load users from phpusers.txt (format: username:password:otp:language)
function loadUsers() {
    $users = [];
    if (file_exists(USERS_FILE)) {
        $lines = file(USERS_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        foreach ($lines as $line) {
            if (strpos($line, ':') !== false) {
                $parts = explode(':', $line, 4);
                $username = trim($parts[0]);
                $password = trim($parts[1]);
                $otp = isset($parts[2]) ? trim($parts[2]) : '';
                $language = isset($parts[3]) ? trim($parts[3]) : 'en';
                $users[$username] = ['password' => $password, 'otp' => $otp, 'language' => $language];
            }
        }
    }
    return $users;
}

// Get browser language from Accept-Language header
function getBrowserLanguage() {
    $acceptLanguage = $_SERVER['HTTP_ACCEPT_LANGUAGE'] ?? 'en';
    $languages = explode(',', $acceptLanguage);
    $lang = trim(explode(';', $languages[0])[0]);
    // Normalize language code (en-US -> en)
    if (strpos($lang, '-') !== false) {
        $parts = explode('-', $lang);
        return strtolower($parts[0]);
    }
    return strtolower($lang);
}

// Load translation file
function loadTranslations($language = 'en') {
    $langFile = __DIR__ . '/i18n/' . $language . '.i18n.json';
    if (!file_exists($langFile)) {
        $langFile = __DIR__ . '/i18n/en.i18n.json';
    }
    if (file_exists($langFile)) {
        $json = file_get_contents($langFile);
        return json_decode($json, true) ?: [];
    }
    return [];
}

// Get translation
function t($key, $translations = []) {
    if (isset($translations[$key])) {
        return $translations[$key];
    }
    return $key;
}

// Generate TOTP secret
function generateSecret($length = 32) {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $secret = '';
    for ($i = 0; $i < $length; $i++) {
        $secret .= $chars[random_int(0, 31)];
    }
    return $secret;
}

// Base32 decode for TOTP
function base32Decode($secret) {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    $secret = strtoupper($secret);
    $paddingCharCount = substr_count($secret, '=');
    $allowedValues = [6, 4, 3, 1, 0];
    if (!in_array($paddingCharCount, $allowedValues)) return false;
    for ($i = 0; $i < 4; $i++) {
        if ($paddingCharCount == $allowedValues[$i] &&
            substr($secret, -($allowedValues[$i])) != str_repeat('=', $allowedValues[$i])) return false;
    }
    $secret = str_replace('=', '', $secret);
    $secret = str_split($secret);
    $binaryString = '';
    for ($i = 0; $i < count($secret); $i = $i + 8) {
        $x = '';
        if (!in_array($secret[$i], str_split($chars))) return false;
        for ($j = 0; $j < 8; $j++) {
            $x .= str_pad(base_convert(@strpos($chars, @$secret[$i + $j]), 10, 2), 5, '0', STR_PAD_LEFT);
        }
        $eightBits = str_split($x, 8);
        for ($z = 0; $z < count($eightBits); $z++) {
            $binaryString .= (($y = chr(base_convert($eightBits[$z], 2, 10))) || ord($y) == 48) ? $y : '';
        }
    }
    return $binaryString;
}

// Verify TOTP code
function verifyTOTP($secret, $code, $window = 1) {
    $secretKey = base32Decode($secret);
    if (!$secretKey) return false;

    $time = floor(time() / 30);

    for ($i = -$window; $i <= $window; $i++) {
        $testTime = $time + $i;
        $timeBytes = pack('N*', 0) . pack('N*', $testTime);
        $hash = hash_hmac('sha1', $timeBytes, $secretKey, true);
        $offset = ord($hash[19]) & 0xf;
        $otp = (
            ((ord($hash[$offset+0]) & 0x7f) << 24) |
            ((ord($hash[$offset+1]) & 0xff) << 16) |
            ((ord($hash[$offset+2]) & 0xff) << 8) |
            (ord($hash[$offset+3]) & 0xff)
        ) % 1000000;
        $otp = str_pad($otp, 6, '0', STR_PAD_LEFT);

        if ($otp === $code) {
            return true;
        }
    }
    return false;
}

// API rate limiting tracking
define('API_RATE_LIMIT_FILE', __DIR__ . '/../api_rate_limit.txt');

function trackAPIRequest($username) {
    $line = $username . ':' . time() . "\n";
    file_put_contents(API_RATE_LIMIT_FILE, $line, FILE_APPEND | LOCK_EX);
}

function getAPIRateInfo($username) {
    $settings = loadSettings();
    $apiEnabled = intval($settings['API_ENABLED'] ?? 1);
    $rateLimit = intval($settings['API_RATE_LIMIT'] ?? 60);
    $rateWindow = intval($settings['API_RATE_LIMIT_WINDOW'] ?? 60);

    if (!$apiEnabled) {
        return ['enabled' => false, 'message' => 'API is disabled'];
    }

    if (!file_exists(API_RATE_LIMIT_FILE)) {
        return ['enabled' => true, 'remaining' => $rateLimit, 'reset' => time() + $rateWindow];
    }

    $lines = file(API_RATE_LIMIT_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $recentRequests = [];
    foreach ($lines as $line) {
        $parts = explode(':', $line, 2);
        if (count($parts) === 2 && trim($parts[0]) === $username) {
            $timestamp = intval($parts[1]);
            if (time() - $timestamp < $rateWindow) {
                $recentRequests[] = $timestamp;
            }
        }
    }

    $remaining = $rateLimit - count($recentRequests);

    if ($remaining <= 0) {
        $resetTime = min($recentRequests) + $rateWindow;
        $waitTime = max(1, $resetTime - time());
        return [
            'enabled' => true,
            'limited' => true,
            'remaining' => 0,
            'reset' => $resetTime,
            'wait_seconds' => $waitTime
        ];
    }

    $reset = !empty($recentRequests) ? max($recentRequests) + $rateWindow : time() + $rateWindow;

    return [
        'enabled' => true,
        'limited' => false,
        'remaining' => $remaining,
        'reset' => $reset,
        'requests_count' => count($recentRequests)
    ];
}

// Clean up old API rate limit entries (older than 1 hour)
function cleanupOldRateLimitEntries() {
    if (!file_exists(API_RATE_LIMIT_FILE)) {
        return;
    }
    $lines = file(API_RATE_LIMIT_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    $newContent = '';
    foreach ($lines as $line) {
        $parts = explode(':', $line, 2);
        if (count($parts) === 2) {
            $timestamp = intval($parts[1]);
            if (time() - $timestamp < 3600) {
                $newContent .= $line . "\n";
            }
        }
    }
    if (!empty($newContent)) {
        file_put_contents(API_RATE_LIMIT_FILE, $newContent, LOCK_EX);
    } else {
        @unlink(API_RATE_LIMIT_FILE);
    }
}

// Simple authentication check with OTP support
function authenticate($username, $password, $otpCode = '') {
    $users = loadUsers();
    if (!isset($users[$username])) return false;

    $user = $users[$username];

    // Check password
    if ($user['password'] !== $password) return false;

    // Check OTP if enabled for this user
    if (!empty($user['otp'])) {
        // Extract secret from otpauth:// URL
        if (preg_match('/secret=([A-Z2-7]+)/', $user['otp'], $matches)) {
            $secret = $matches[1];
            if (empty($otpCode) || !verifyTOTP($secret, $otpCode)) {
                return 'OTP_REQUIRED';
            }
        }
    }

    return true;
}

// Check if user is logged in
function isLoggedIn() {
    return isset($_SESSION['username']);
}

// Get logged-in username
function getUsername() {
    return $_SESSION['username'] ?? null;
}

// Sanitize repository name to prevent directory traversal
function sanitizeRepoName($name) {
    // Remove any path traversal sequences
    $name = str_replace(['../', '..\\', '\0'], '', $name);
    // Get basename to remove any directory components
    $name = basename($name);
    // Only allow alphanumeric, dash, underscore, and dot
    $name = preg_replace('/[^a-zA-Z0-9._-]/', '', $name);
    return $name;
}

// Validate path is within REPOS_DIR
function isPathSafe($path) {
    $realReposDir = realpath(REPOS_DIR);
    $realPath = realpath($path);
    
    // If path doesn't exist yet, check parent directory
    if ($realPath === false) {
        $realPath = realpath(dirname($path));
        if ($realPath === false) {
            return false;
        }
    }
    
    // Check if the real path starts with the repos directory
    return strpos($realPath, $realReposDir) === 0;
}

// Get list of repositories
function getReposList() {
    $repos = [];
    $files = glob(REPOS_DIR . '/*.omi');
    foreach ($files as $file) {
        $basename = basename($file);
        $repos[] = [
            'name' => $basename,
            'size' => filesize($file),
            'modified' => filemtime($file)
        ];
    }
    return $repos;
}

// Create an empty repository with the required schema
function createEmptyRepository($repoName, $username, &$error) {
    $repoName = sanitizeRepoName($repoName);
    if ($repoName === '') {
        $error = 'Repository name is required';
        return false;
    }
    if (!preg_match('/\.omi$/', $repoName)) {
        $repoName .= '.omi';
    }
    if (!preg_match('/^[a-zA-Z0-9._-]+\.omi$/', $repoName)) {
        $error = 'Invalid repository name. Use letters, numbers, dot, dash, or underscore.';
        return false;
    }

    $repoPath = REPOS_DIR . '/' . $repoName;
    if (file_exists($repoPath)) {
        $error = 'Repository already exists';
        return false;
    }

    try {
        $pdo = new PDO('sqlite:' . $repoPath);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        $schema = [
            'CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, data BLOB, size INTEGER)',
            'CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY, filename TEXT, hash TEXT, datetime TEXT, commit_id INTEGER)',
            'CREATE TABLE IF NOT EXISTS commits (id INTEGER PRIMARY KEY, message TEXT, datetime TEXT, user TEXT)',
            'CREATE TABLE IF NOT EXISTS staging (filename TEXT PRIMARY KEY, hash TEXT, datetime TEXT)',
            'CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash)',
            'CREATE INDEX IF NOT EXISTS idx_files_commit ON files(commit_id)',
            'CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash)'
        ];

        foreach ($schema as $sql) {
            $pdo->exec($sql);
        }

        $stmt = $pdo->prepare('INSERT INTO commits (message, datetime, user) VALUES (?, ?, ?)');
        $stmt->execute(['Initial commit', date('Y-m-d H:i:s'), $username ?: 'system']);
        return true;
    } catch (Exception $e) {
        if (file_exists($repoPath)) {
            @unlink($repoPath);
        }
        $error = 'Failed to create repository';
        return false;
    }
}

// Parse request URI for routing
function parseRequestURI() {
    $uri = $_SERVER['REQUEST_URI'];
    $uri = parse_url($uri, PHP_URL_PATH);
    $uri = trim($uri, '/');

    if (empty($uri)) {
        return ['type' => 'list'];
    }

    $parts = explode('/', $uri);
    $repoName = sanitizeRepoName($parts[0]);

    // Check if it's a valid repo
    if (!preg_match('/\.omi$/', $repoName)) {
        $repoName .= '.omi';
    }

    $repoPath = REPOS_DIR . '/' . $repoName;

    // Validate path is safe
    if (!isPathSafe($repoPath) || !file_exists($repoPath)) {
        return ['type' => 'error', 'message' => 'Repository not found'];
    }

    $path = isset($parts[1]) ? implode('/', array_slice($parts, 1)) : '';

    return [
        'type' => 'browse',
        'repo' => $repoName,
        'path' => $path,
        'db' => $repoPath
    ];
}

// Get files from latest commit
function getLatestFiles($db, $path = '') {
    try {
        $pdo = new PDO('sqlite:' . $db);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        // Get latest commit
        $stmt = $pdo->query("SELECT id FROM commits ORDER BY id DESC LIMIT 1");
        $commit = $stmt->fetch(PDO::FETCH_ASSOC);

        if (!$commit) {
            return [];
        }

        $commitId = $commit['id'];

        // Get files from this commit
        $sql = "SELECT f.filename, f.hash, f.datetime, b.size
                FROM files f
                LEFT JOIN blobs b ON f.hash = b.hash
                WHERE f.commit_id = ?";

        if ($path) {
            $sql .= " AND (f.filename LIKE ? OR f.filename = ?)";
            $stmt = $pdo->prepare($sql);
            $stmt->execute([$commitId, $path . '/%', $path]);
        } else {
            $stmt = $pdo->prepare($sql);
            $stmt->execute([$commitId]);
        }

        return $stmt->fetchAll(PDO::FETCH_ASSOC);
    } catch (Exception $e) {
        return [];
    }
}

// Organize files into directories and files
function organizeFiles($files, $basePath = '') {
    $result = ['dirs' => [], 'files' => []];
    $baseDepth = empty($basePath) ? 0 : substr_count($basePath, '/') + 1;

    foreach ($files as $file) {
        $filename = $file['filename'];
        $isDirMarker = preg_match('/(^|\/)\.omidir$/', $filename) === 1;

        // Skip if not in current path
        if ($basePath && strpos($filename, $basePath . '/') !== 0 && $filename !== $basePath) {
            continue;
        }

        // Remove base path
        if ($basePath) {
            if ($filename === $basePath) {
                // This is the file itself
                if (!$isDirMarker) {
                    $result['files'][] = $file;
                }
                continue;
            }
            $relativePath = substr($filename, strlen($basePath) + 1);
        } else {
            $relativePath = $filename;
        }

        $parts = explode('/', $relativePath);

        if (count($parts) > 1) {
            // It's in a subdirectory
            $dirName = $parts[0];
            if (!isset($result['dirs'][$dirName])) {
                $result['dirs'][$dirName] = [
                    'name' => $dirName,
                    'path' => $basePath ? $basePath . '/' . $dirName : $dirName,
                    'datetime' => $file['datetime']
                ];
            }
        } else {
            // It's a file in current directory
            if (!$isDirMarker) {
                $result['files'][] = $file;
            }
        }
    }

    return $result;
}

// Get file content from blob
function getFileContent($db, $hash) {
    try {
        $pdo = new PDO('sqlite:' . $db);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        $stmt = $pdo->prepare("SELECT data FROM blobs WHERE hash = ?");
        $stmt->execute([$hash]);
        $result = $stmt->fetch(PDO::FETCH_ASSOC);

        return $result ? $result['data'] : null;
    } catch (Exception $e) {
        return null;
    }
}

// Check if content is text
function isTextFile($content) {
    if (empty($content)) return true;

    // Check for null bytes (binary indicator)
    if (strpos($content, "\0") !== false) {
        return false;
    }

    return true;
}

// Check if filename is markdown
function isMarkdownFile($filename) {
    $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
    return $ext === 'md' || $ext === 'markdown';
}

// Check if filename is SVG
function isSVGFile($filename) {
    $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
    return $ext === 'svg';
}

// Check if filename is an image file
function isImageFile($filename) {
    $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
    $imageExts = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'ico', 'tiff', 'tif'];
    return in_array($ext, $imageExts);
}

// Check if filename is media file and return type
function getMediaType($filename) {
    $ext = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
    $audioExts = ['mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac'];
    $videoExts = ['mp4', 'webm', 'ogg', 'mkv', 'avi', 'mov', 'flv', 'wmv'];
    
    if (in_array($ext, $audioExts)) return 'audio';
    if (in_array($ext, $videoExts)) return 'video';
    return false;
}

// Simple markdown to HTML converter (basic support)
function markdownToHtml($markdown) {
    $html = htmlspecialchars($markdown);
    
    // Headers
    $html = preg_replace('/^### (.*?)$/m', '<h3>$1</h3>', $html);
    $html = preg_replace('/^## (.*?)$/m', '<h2>$1</h2>', $html);
    $html = preg_replace('/^# (.*?)$/m', '<h1>$1</h1>', $html);
    
    // Bold and italic
    $html = preg_replace('/\*\*(.*?)\*\*/', '<b>$1</b>', $html);
    $html = preg_replace('/\*(.*?)\*/', '<i>$1</i>', $html);
    $html = preg_replace('/__(.+?)__/', '<b>$1</b>', $html);
    $html = preg_replace('/_(.+?)_/', '<i>$1</i>', $html);
    
    // Images (process before links to avoid conflict)
    $html = preg_replace('/!\[(.*?)\]\((.*?)\)/', '<img src="$2" alt="$1" style="max-width: 100%; height: auto; border: 1px solid #ccc; margin: 10px 0;">', $html);
    
    // Links
    $html = preg_replace('/\[(.*?)\]\((.*?)\)/', '<a href="$2">$1</a>', $html);
    
    // Code blocks
    $html = preg_replace_callback('/```(.*?)```/s', function($m) {
        return '<pre>' . trim($m[1]) . '</pre>';
    }, $html);
    
    // Inline code
    $html = preg_replace('/`([^`]+)`/', '<code>$1</code>', $html);
    
    // Line breaks
    $html = nl2br($html);
    
    return $html;
}

// Check if browser supports SVG
function browserSupportsSVG() {
    $accept = $_SERVER['HTTP_ACCEPT'] ?? '';
    if (strpos($accept, 'image/svg+xml') !== false) {
        return true;
    }
    
    // Check User-Agent for known SVG-incapable browsers
    $userAgent = $_SERVER['HTTP_USER_AGENT'] ?? '';
    $oldBrowsers = ['MSIE 8', 'MSIE 7', 'MSIE 6', 'Netscape', 'Lynx'];
    foreach ($oldBrowsers as $browser) {
        if (stripos($userAgent, $browser) !== false) {
            return false;
        }
    }
    
    // Default to support (most modern browsers)
    return true;
}

// Convert SVG to GIF using ImageMagick
function svgToGif($svgContent) {
    // Check if ImageMagick is available
    $whichConvert = shell_exec('which convert 2>/dev/null');
    if (!$whichConvert) {
        return null; // ImageMagick not available
    }
    
    // Create temporary SVG file
    $tempSvg = tempnam(sys_get_temp_dir(), 'omi_svg_');
    $tempGif = $tempSvg . '.gif';
    
    try {
        // Write SVG to temp file
        file_put_contents($tempSvg, $svgContent);
        
        // Convert SVG to GIF using ImageMagick
        $command = escapeshellcmd("convert -density 150 -background white svg:$tempSvg gif:$tempGif 2>&1");
        $output = shell_exec($command);
        
        // Check if conversion was successful
        if (!file_exists($tempGif)) {
            unlink($tempSvg);
            return null;
        }
        
        // Read GIF data
        $gifData = file_get_contents($tempGif);
        
        // Clean up temp files
        unlink($tempSvg);
        unlink($tempGif);
        
        return $gifData;
    } catch (Exception $e) {
        // Clean up on error
        if (file_exists($tempSvg)) unlink($tempSvg);
        if (isset($tempGif) && file_exists($tempGif)) unlink($tempGif);
        return null;
    }
}

// Check if SVG contains JavaScript (security risk)
function svgContainsJavaScript($svgContent) {
    // Check for script tags
    if (stripos($svgContent, '<script') !== false) {
        return true;
    }
    
    // Check for event handlers (onclick, onload, etc.)
    $eventPatterns = [
        'onload', 'onerror', 'onmouseover', 'onmouseout', 'onclick',
        'onmousemove', 'onmousedown', 'onmouseup', 'ondblclick',
        'onfocus', 'onblur', 'onchange', 'onsubmit', 'onreset'
    ];
    
    foreach ($eventPatterns as $event) {
        if (stripos($svgContent, $event . '=') !== false) {
            return true;
        }
    }
    
    // Check for javascript: protocol
    if (stripos($svgContent, 'javascript:') !== false) {
        return true;
    }
    
    // Check for data: protocol with script content
    if (stripos($svgContent, 'data:text/javascript') !== false) {
        return true;
    }
    
    return false;
}

// Check if SVG contains dangerous XML entities or loops
function svgContainsXMLDanger($svgContent) {
    // Check for DOCTYPE (can contain external entity declarations)
    if (stripos($svgContent, '<!DOCTYPE') !== false) {
        return true;
    }
    
    // Check for ENTITY declarations
    if (stripos($svgContent, '<!ENTITY') !== false) {
        return true;
    }
    
    // Check for recursive/billion laughs attack patterns
    if (stripos($svgContent, '&lol') !== false || 
        stripos($svgContent, '&x') !== false) {
        return true;
    }
    
    // Check for CDATA with suspiciously large content
    if (preg_match('/<!\[CDATA\[.{10000,}/', $svgContent)) {
        return true;
    }
    
    return false;
}

// Add new file commit to database
function commitFile($db, $filename, $content) {
    try {
        $pdo = new PDO('sqlite:' . $db);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        // Calculate hash
        $hash = hash('sha256', $content);
        $size = strlen($content);

        // Check if blob already exists
        $stmt = $pdo->prepare("SELECT COUNT(*) as cnt FROM blobs WHERE hash = ?");
        $stmt->execute([$hash]);
        $blobExists = $stmt->fetch(PDO::FETCH_ASSOC)['cnt'] > 0;

        // Insert blob if new
        if (!$blobExists) {
            $stmt = $pdo->prepare("INSERT INTO blobs (hash, data, size) VALUES (?, ?, ?)");
            $stmt->execute([$hash, $content, $size]);
        }

        // Get current datetime
        $datetime = date('Y-m-d H:i:s');

        // Get latest commit to preserve existing files
        $stmt = $pdo->query("SELECT id FROM commits ORDER BY id DESC LIMIT 1");
        $latestCommit = $stmt->fetch(PDO::FETCH_ASSOC);

        // Create commit
        $stmt = $pdo->prepare("INSERT INTO commits (message, datetime, user) VALUES (?, ?, ?)");
        $stmt->execute(["Edited: $filename", $datetime, getUsername()]);

        $commitId = $pdo->lastInsertId();

        // Preserve all existing files from latest commit (except the one being updated)
        if ($latestCommit) {
            $stmt = $pdo->prepare("SELECT filename, hash, datetime FROM files WHERE commit_id = ? AND filename != ?");
            $stmt->execute([$latestCommit['id'], $filename]);
            $existingFiles = $stmt->fetchAll(PDO::FETCH_ASSOC);

            foreach ($existingFiles as $file) {
                $stmt = $pdo->prepare("INSERT INTO files (filename, hash, datetime, commit_id) VALUES (?, ?, ?, ?)");
                $stmt->execute([$file['filename'], $file['hash'], $file['datetime'], $commitId]);
            }
        }

        // Add file record
        $stmt = $pdo->prepare("INSERT INTO files (filename, hash, datetime, commit_id) VALUES (?, ?, ?, ?)");
        $stmt->execute([$filename, $hash, $datetime, $commitId]);

        return true;
    } catch (Exception $e) {
        error_log("Error committing file: " . $e->getMessage());
        return false;
    }
}

// Upload file to repository
function uploadFile($db, $filename, $content) {
    try {
        $pdo = new PDO('sqlite:' . $db);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        // Calculate hash
        $hash = hash('sha256', $content);
        $size = strlen($content);

        // Check if blob already exists
        $stmt = $pdo->prepare("SELECT COUNT(*) as cnt FROM blobs WHERE hash = ?");
        $stmt->execute([$hash]);
        $blobExists = $stmt->fetch(PDO::FETCH_ASSOC)['cnt'] > 0;

        // Insert blob if new
        if (!$blobExists) {
            $stmt = $pdo->prepare("INSERT INTO blobs (hash, data, size) VALUES (?, ?, ?)");
            $stmt->execute([$hash, $content, $size]);
        }

        // Get current datetime
        $datetime = date('Y-m-d H:i:s');

        // Get latest commit to preserve existing files
        $stmt = $pdo->query("SELECT id FROM commits ORDER BY id DESC LIMIT 1");
        $latestCommit = $stmt->fetch(PDO::FETCH_ASSOC);

        // Create commit
        $stmt = $pdo->prepare("INSERT INTO commits (message, datetime, user) VALUES (?, ?, ?)");
        $stmt->execute(["Uploaded: $filename", $datetime, getUsername()]);

        $commitId = $pdo->lastInsertId();

        // Preserve all existing files from latest commit (except the one being updated)
        if ($latestCommit) {
            $stmt = $pdo->prepare("SELECT filename, hash, datetime FROM files WHERE commit_id = ? AND filename != ?");
            $stmt->execute([$latestCommit['id'], $filename]);
            $existingFiles = $stmt->fetchAll(PDO::FETCH_ASSOC);

            foreach ($existingFiles as $file) {
                $stmt = $pdo->prepare("INSERT INTO files (filename, hash, datetime, commit_id) VALUES (?, ?, ?, ?)");
                $stmt->execute([$file['filename'], $file['hash'], $file['datetime'], $commitId]);
            }
        }

        // Add file record
        $stmt = $pdo->prepare("INSERT INTO files (filename, hash, datetime, commit_id) VALUES (?, ?, ?, ?)");
        $stmt->execute([$filename, $hash, $datetime, $commitId]);

        return true;
    } catch (Exception $e) {
        error_log("Error uploading file: " . $e->getMessage());
        return false;
    }
}

// Delete file from repository (creates new commit without file)
function deleteFile($db, $filename) {
    try {
        $pdo = new PDO('sqlite:' . $db);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        // Get current datetime
        $datetime = date('Y-m-d H:i:s');

        // Get latest commit to preserve existing files
        $stmt = $pdo->query("SELECT id FROM commits ORDER BY id DESC LIMIT 1");
        $latestCommit = $stmt->fetch(PDO::FETCH_ASSOC);

        // Create commit
        $stmt = $pdo->prepare("INSERT INTO commits (message, datetime, user) VALUES (?, ?, ?)");
        $stmt->execute(["Deleted: $filename", $datetime, getUsername()]);

        $commitId = $pdo->lastInsertId();

        // Preserve all existing files from latest commit EXCEPT the one being deleted
        if ($latestCommit) {
            $stmt = $pdo->prepare("SELECT filename, hash, datetime FROM files WHERE commit_id = ? AND filename != ?");
            $stmt->execute([$latestCommit['id'], $filename]);
            $existingFiles = $stmt->fetchAll(PDO::FETCH_ASSOC);

            foreach ($existingFiles as $file) {
                $stmt = $pdo->prepare("INSERT INTO files (filename, hash, datetime, commit_id) VALUES (?, ?, ?, ?)");
                $stmt->execute([$file['filename'], $file['hash'], $file['datetime'], $commitId]);
            }
        }

        // Note: We don't insert a file record for the deleted file.
        // The file is "deleted" by not having a record in the latest commit.
        // Previous commits still have the file record pointing to the blob.

        return true;
    } catch (Exception $e) {
        error_log("Error deleting file: " . $e->getMessage());
        return false;
    }
}

// Handle /logout route
if (strpos($_SERVER['REQUEST_URI'], '/logout') !== false) {
    session_destroy();
    header('Location: /');
    exit;
}

// Handle /sign-in route
if (strpos($_SERVER['REQUEST_URI'], '/sign-in') !== false) {
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $username = $_POST['username'] ?? '';
        $password = $_POST['password'] ?? '';
        $otpCode = $_POST['otp'] ?? '';

        // Check if user is locked
        if (isUserLocked($username)) {
            $error = 'Account is temporarily locked due to too many failed login attempts. Please try again later.';
        } else {
            $authResult = authenticate($username, $password, $otpCode);

            if ($authResult === true) {
                // Clear failed attempts on successful login
                clearFailedAttempts($username);
                $_SESSION['username'] = $username;
                // Redirect to home
                header('Location: /');
                exit;
            } elseif ($authResult === 'OTP_REQUIRED') {
                $error = 'OTP code required';
                $show_otp = true;
            } else {
                // Record failed attempt
                recordFailedAttempt($username);

                // Check if threshold reached
                if (checkBruteForce($username)) {
                    $error = 'Too many failed login attempts. Account locked temporarily.';
                } else {
                    $error = 'Invalid username or password';
                }
            }
        }
    }

    ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Sign In - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<h1>Omi Server - Sign In</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[Home]</a></td></tr>
</table>
<?php if (isset($error)): ?>
<p><font color="red"><strong>Error: <?php echo htmlspecialchars($error); ?></strong></font></p>
<?php endif; ?>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>Username:</td><td><input type="text" name="username" size="30" required value="<?php echo isset($_POST['username']) ? htmlspecialchars($_POST['username']) : ''; ?>"></td></tr>
<tr><td>Password:</td><td><input type="password" name="password" size="30" required></td></tr>
<?php if (isset($show_otp)): ?>
<tr><td>OTP Code:</td><td><input type="text" name="otp" size="10" maxlength="6" required pattern="[0-9]{6}" placeholder="6-digit code"></td></tr>
<?php endif; ?>
<tr><td colspan="2"><input type="submit" value="Sign In"></td></tr>
</table>
</form>
<p><a href="/sign-up">Create new account</a></p>
</body>
</html>
    <?php
    exit;
}

// Handle /sign-up route
if (strpos($_SERVER['REQUEST_URI'], '/sign-up') !== false) {
    $error = null;
    $success = null;

    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $username = $_POST['username'] ?? '';
        $password = $_POST['password'] ?? '';
        $password2 = $_POST['password2'] ?? '';

        // Check if IP or username is locked (brute force protection)
        $ipAddress = $_SERVER['REMOTE_ADDR'] ?? 'unknown';
        $checkUsername = !empty($username) ? $username : 'signup_' . $ipAddress;

        if (isUserLocked($checkUsername)) {
            $error = 'Too many sign-up attempts. Please try again later.';
        } elseif (empty($username) || empty($password)) {
            $error = 'Username and password are required';
        } elseif ($password !== $password2) {
            $error = 'Passwords do not match';
        } elseif (strlen($username) < 3) {
            $error = 'Username must be at least 3 characters';
        } else {
            // Check if user exists
            $users = loadUsers();
            if (isset($users[$username])) {
                // Record failed attempt for existing username
                recordFailedAttempt($username);
                checkBruteForce($username);
                $error = 'User already exists';
            } else {
                // Add new user with browser language detection
                $browserLanguage = getBrowserLanguage();
                $line = $username . ':' . $password . '::' . $browserLanguage . "\n";
                if (file_put_contents(USERS_FILE, $line, FILE_APPEND | LOCK_EX)) {
                    $success = 'Account created! You can now sign in.';
                } else {
                    $error = 'Failed to create account';
                }
            }
        }
    }

    ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Sign Up - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<h1>Omi Server - Sign Up</h1>
<table border="0" cellpadding="5">
<tr><td colspan="2"><a href="/">[Home]</a></td></tr>
</table>
<?php if (isset($error)): ?>
<p><font color="red"><strong>Error: <?php echo htmlspecialchars($error); ?></strong></font></p>
<?php endif; ?>
<?php if (isset($success)): ?>
<p><font color="green"><strong><?php echo htmlspecialchars($success); ?></strong></font></p>
<p><a href="/sign-in">Go to Sign In</a></p>
<?php else: ?>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>Username:</td><td><input type="text" name="username" size="30" required></td></tr>
<tr><td>Password:</td><td><input type="password" name="password" size="30" required></td></tr>
<tr><td>Confirm:</td><td><input type="password" name="password2" size="30" required></td></tr>
<tr><td colspan="2"><input type="submit" value="Create Account"></td></tr>
</table>
</form>
<p><a href="/sign-in">Already have an account? Sign in</a></p>
<?php endif; ?>
</body>
</html>
    <?php
    exit;
}

// Handle /settings route
if (strpos($_SERVER['REQUEST_URI'], '/settings') !== false && strpos($_SERVER['REQUEST_URI'], '/sign') === false) {
    if (!isLoggedIn()) {
        header('Location: /sign-in');
        exit;
    }

    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $settings = [];
        foreach (['SQLITE', 'USERNAME', 'PASSWORD', 'REPOS', 'CURL'] as $key) {
            if (isset($_POST[$key])) {
                $settings[$key] = $_POST[$key];
            }
        }

        $content = '';
        foreach ($settings as $key => $value) {
            $content .= $key . '=' . $value . "\n";
        }

        if (file_put_contents(SETTINGS_FILE, $content, LOCK_EX)) {
            $success = 'Settings updated successfully';
        } else {
            $error = 'Failed to save settings';
        }
    }

    $settings = [];
    if (file_exists(SETTINGS_FILE)) {
        $lines = file(SETTINGS_FILE, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        foreach ($lines as $line) {
            if (strpos($line, '=') !== false) {
                list($key, $value) = explode('=', $line, 2);
                $settings[trim($key)] = trim($value);
            }
        }
    }

    ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Settings - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>Settings</h1></td><td align="right"><small><strong><?php echo htmlspecialchars(getUsername()); ?></strong> | <a href="/logout">[Logout]</a></small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="/settings">[Settings]</a> | <a href="/people">[People]</a></p>
<hr>
<?php if (isset($success)): ?><p><font color="green"><strong><?php echo htmlspecialchars($success); ?></strong></font></p><?php endif; ?>
<?php if (isset($error)): ?><p><font color="red"><strong><?php echo htmlspecialchars($error); ?></strong></font></p><?php endif; ?>
<form method="POST">
<table border="1" cellpadding="5">
<tr><td>SQLITE executable:</td><td><input type="text" name="SQLITE" size="50" value="<?php echo htmlspecialchars($settings['SQLITE'] ?? 'sqlite'); ?>"></td></tr>
<tr><td>USERNAME:</td><td><input type="text" name="USERNAME" size="50" value="<?php echo htmlspecialchars($settings['USERNAME'] ?? ''); ?>"></td></tr>
<tr><td>PASSWORD:</td><td><input type="password" name="PASSWORD" size="50" value="<?php echo htmlspecialchars($settings['PASSWORD'] ?? ''); ?>"></td></tr>
<tr><td>REPOS (server URL):</td><td><input type="text" name="REPOS" size="50" value="<?php echo htmlspecialchars($settings['REPOS'] ?? ''); ?>"></td></tr>
<tr><td>CURL executable:</td><td><input type="text" name="CURL" size="50" value="<?php echo htmlspecialchars($settings['CURL'] ?? 'curl'); ?>"></td></tr>
<tr><td colspan="2"><input type="submit" value="Save Settings"></td></tr>
</table>
</form>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>
    <?php
    exit;
}

// Handle /language route
if (strpos($_SERVER['REQUEST_URI'], '/language') !== false) {
    if (!isLoggedIn()) {
        header('Location: /sign-in');
        exit;
    }

    $username = getUsername();
    $users = loadUsers();
    $currentLanguage = $users[$username]['language'] ?? 'en';
    
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $newLanguage = $_POST['language'] ?? 'en';
        
        // Update language in users array
        if (isset($users[$username])) {
            $users[$username]['language'] = $newLanguage;
            
            // Save back to file
            $userContent = '';
            foreach ($users as $u => $data) {
                $userContent .= $u . ':' . $data['password'] . ':' . $data['otp'] . ':' . $data['language'] . "\n";
            }
            
            if (file_put_contents(USERS_FILE, $userContent, LOCK_EX)) {
                $currentLanguage = $newLanguage;
                $success = 'Language changed successfully';
            }
        }
    }
    
    // Load available languages
    $langFile = __DIR__ . '/languages.json';
    $languages = [];
    if (file_exists($langFile)) {
        $langData = json_decode(file_get_contents($langFile), true);
        $languages = $langData ?: [];
    }
    
    $translations = loadTranslations($currentLanguage);
    
    // Check if current language is RTL
    $isRTL = false;
    if (isset($languages[$currentLanguage]['rtl'])) {
        $isRTL = $languages[$currentLanguage]['rtl'];
    }
    
    $dirAttr = $isRTL ? 'rtl' : 'ltr';
    ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html dir="<?php echo $dirAttr; ?>">
<head>
<title><?php echo isset($translations['language']) ? htmlspecialchars($translations['language']) : 'Language'; ?> - Omi Server</title>
</head>
<body bgcolor="#f0f0f0" dir="<?php echo $dirAttr; ?>">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>Omi Server</h1></td><td align="right"><small><strong><?php echo htmlspecialchars($username); ?></strong> | <a href="/logout">[Logout]</a></small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="/people">[People]</a> | <a href="/settings">[Settings]</a></p>
<hr>
<h2><?php echo isset($translations['language']) ? htmlspecialchars($translations['language']) : 'Select Language'; ?></h2>
<?php if (isset($success)): ?>
<p><font color="green"><strong><?php echo htmlspecialchars($success); ?></strong></font></p>
<?php endif; ?>
<form method="POST">
<table border="1" cellpadding="5">
<tr bgcolor="#333333"><th><font color="white">Language</font></th></tr>
<?php foreach ($languages as $langCode => $langInfo): ?>
<tr>
<td><input type="radio" name="language" value="<?php echo htmlspecialchars($langCode); ?>" <?php echo ($currentLanguage === $langCode) ? 'checked' : ''; ?>> <?php echo htmlspecialchars($langInfo['name'] ?? $langCode); ?> (<?php echo htmlspecialchars($langCode); ?>) <?php echo ($langInfo['rtl'] ?? false) ? '(RTL)' : ''; ?></td>
</tr>
<?php endforeach; ?>
</table>
<br>
<input type="submit" value="<?php echo isset($translations['save']) ? htmlspecialchars($translations['save']) : 'Save'; ?>">
</form>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>
    <?php
    exit;
}

// Handle /people route
if (strpos($_SERVER['REQUEST_URI'], '/people') !== false) {
    if (!isLoggedIn()) {
        header('Location: /sign-in');
        exit;
    }

    $users = loadUsers();

    // Handle user operations
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $action = $_POST['action'] ?? '';

        if ($action === 'add') {
            $newuser = $_POST['newuser'] ?? '';
            $newpass = $_POST['newpass'] ?? '';

            if (!empty($newuser) && !empty($newpass)) {
                if (!isset($users[$newuser])) {
                    $users[$newuser] = ['password' => $newpass, 'otp' => ''];
                    $userContent = '';
                    foreach ($users as $u => $data) {
                        $userContent .= $u . ':' . $data['password'] . ':' . $data['otp'] . "\n";
                    }
                    if (file_put_contents(USERS_FILE, $userContent, LOCK_EX)) {
                        $success = 'User added successfully';
                    } else {
                        $error = 'Failed to add user';
                    }
                } else {
                    $error = 'User already exists';
                }
            }
        } elseif ($action === 'delete') {
            $deluser = $_POST['deluser'] ?? '';
            if (isset($users[$deluser])) {
                unset($users[$deluser]);
                $userContent = '';
                foreach ($users as $u => $data) {
                    $userContent .= $u . ':' . $data['password'] . ':' . $data['otp'] . "\n";
                }
                if (file_put_contents(USERS_FILE, $userContent, LOCK_EX)) {
                    $success = 'User deleted successfully';
                } else {
                    $error = 'Failed to delete user';
                }
            }
        } elseif ($action === 'update') {
            $upuser = $_POST['upuser'] ?? '';
            $uppass = $_POST['uppass'] ?? '';
            if (isset($users[$upuser]) && !empty($uppass)) {
                $users[$upuser]['password'] = $uppass;
                $userContent = '';
                foreach ($users as $u => $data) {
                    $userContent .= $u . ':' . $data['password'] . ':' . $data['otp'] . "\n";
                }
                if (file_put_contents(USERS_FILE, $userContent, LOCK_EX)) {
                    $success = 'User updated successfully';
                } else {
                    $error = 'Failed to update user';
                }
            }
        } elseif ($action === 'enable_otp') {
            $otpuser = $_POST['otpuser'] ?? '';
            $email = $_POST['email'] ?? '';
            if (isset($users[$otpuser])) {
                $secret = generateOTPSecret();
                $emailPart = !empty($email) ? $email : $otpuser;
                $otpauth = "otpauth://totp/Omi ($emailPart):$emailPart?secret=$secret&issuer=omi&digits=6&period=30";
                $users[$otpuser]['otp'] = $otpauth;
                $userContent = '';
                foreach ($users as $u => $data) {
                    $userContent .= $u . ':' . $data['password'] . ':' . $data['otp'] . "\n";
                }
                if (file_put_contents(USERS_FILE, $userContent, LOCK_EX)) {
                    $success = 'OTP enabled successfully';
                    $_SESSION['otp_setup'] = $otpauth;
                } else {
                    $error = 'Failed to enable OTP';
                }
            }
        } elseif ($action === 'disable_otp') {
            $otpuser = $_POST['otpuser'] ?? '';
            if (isset($users[$otpuser])) {
                $users[$otpuser]['otp'] = '';
                $userContent = '';
                foreach ($users as $u => $data) {
                    $userContent .= $u . ':' . $data['password'] . ':' . $data['otp'] . "\n";
                }
                if (file_put_contents(USERS_FILE, $userContent, LOCK_EX)) {
                    $success = 'OTP disabled successfully';
                } else {
                    $error = 'Failed to disable OTP';
                }
            }
        }

        $users = loadUsers();
    }

    ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>People - Omi Server</title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>User Management</h1></td><td align="right"><small><strong><?php echo htmlspecialchars(getUsername()); ?></strong> | <a href="/logout">[Logout]</a></small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="/settings">[Settings]</a> | <a href="/people">[People]</a></p>
<hr>
<?php if (isset($success)): ?><p><font color="green"><strong><?php echo htmlspecialchars($success); ?></strong></font></p><?php endif; ?>
<?php if (isset($error)): ?><p><font color="red"><strong><?php echo htmlspecialchars($error); ?></strong></font></p><?php endif; ?>

<h2>Manage Users</h2>
<table border="1" cellpadding="5" width="100%">
<tr bgcolor="#333333"><th><font color="white">Username</font></th><th><font color="white">OTP Status</font></th><th><font color="white">Action</font></th></tr>
<?php foreach ($users as $u => $data): ?>
<tr><td><?php echo htmlspecialchars($u); ?></td>
<td><?php echo !empty($data['otp']) ? '<font color="green">✓ Enabled</font>' : '<font color="gray">Disabled</font>'; ?></td>
<td>
<form method="POST" style="display:inline">
<input type="hidden" name="action" value="delete">
<input type="hidden" name="deluser" value="<?php echo htmlspecialchars($u); ?>">
<input type="submit" value="Delete" onclick="return confirm('Delete user <?php echo htmlspecialchars($u); ?>?')">
</form> |
<a href="#" onclick="document.getElementById('edit_<?php echo htmlspecialchars($u); ?>').style.display='block'; return false;">[Edit]</a>
<?php if ($u === getUsername()): ?>
 | <a href="#" onclick="document.getElementById('otp_<?php echo htmlspecialchars($u); ?>').style.display='block'; return false;">[OTP]</a>
<?php endif; ?>
</td></tr>
<?php endforeach; ?>
</table>

<h2>Add New User</h2>
<form method="POST">
<table border="0" cellpadding="5">
<tr><td>Username:</td><td><input type="text" name="newuser" size="30" required></td></tr>
<tr><td>Password:</td><td><input type="password" name="newpass" size="30" required></td></tr>
<tr><td colspan="2"><input type="hidden" name="action" value="add"><input type="submit" value="Add User"></td></tr>
</table>
</form>

<h2>Edit User Password</h2>
<?php foreach ($users as $u => $data): ?>
<div id="edit_<?php echo htmlspecialchars($u); ?>" style="display:none;border:1px solid #ccc;padding:10px;margin:10px 0">
<form method="POST">
<table border="0" cellpadding="5">
<tr><td>User:</td><td><strong><?php echo htmlspecialchars($u); ?></strong></td></tr>
<tr><td>New Password:</td><td><input type="password" name="uppass" size="30" required></td></tr>
<tr><td colspan="2"><input type="hidden" name="action" value="update"><input type="hidden" name="upuser" value="<?php echo htmlspecialchars($u); ?>"><input type="submit" value="Update"> | <a href="#" onclick="document.getElementById('edit_<?php echo htmlspecialchars($u); ?>').style.display='none'; return false;">[Cancel]</a></td></tr>
</table>
</form>
</div>
<?php endforeach; ?>

<h2>Manage OTP Authentication</h2>
<?php if (isset($_SESSION['otp_setup'])): ?>
<div style="border:2px solid green;padding:15px;margin:10px 0;background:#e8f5e9">
<p><strong><font color="green">OTP Enabled Successfully!</font></strong></p>
<p>Scan this URL with your authenticator app (e.g., NumberStation, Google Authenticator):</p>
<p style="word-break:break-all;font-family:monospace;background:white;padding:10px;border:1px solid #ccc"><?php echo htmlspecialchars($_SESSION['otp_setup']); ?></p>
<p><small>Save this URL securely. You won't see it again.</small></p>
<p><a href="#" onclick="delete window.sessionStorage; location.reload(); return false;">[Close]</a></p>
</div>
<?php unset($_SESSION['otp_setup']); endif; ?>

<?php foreach ($users as $u => $data): ?>
<?php if ($u === getUsername()): ?>
<div id="otp_<?php echo htmlspecialchars($u); ?>" style="display:none;border:1px solid #ccc;padding:10px;margin:10px 0">
<h3>OTP for: <?php echo htmlspecialchars($u); ?></h3>
<?php if (empty($data['otp'])): ?>
<form method="POST">
<table border="0" cellpadding="5">
<tr><td>Email (optional):</td><td><input type="text" name="email" size="30" placeholder="<?php echo htmlspecialchars($u); ?>" value="<?php echo htmlspecialchars($u); ?>"></td></tr>
<tr><td colspan="2"><small>This will be used as the account identifier in your authenticator app.</small></td></tr>
<tr><td colspan="2">
<input type="hidden" name="action" value="enable_otp">
<input type="hidden" name="otpuser" value="<?php echo htmlspecialchars($u); ?>">
<input type="submit" value="Enable OTP">
</td></tr>
</table>
</form>
<?php else: ?>
<p><font color="green">✓ OTP is currently <strong>enabled</strong></font></p>
<p><small>Your OTP URL is stored securely. Use your authenticator app to generate codes.</small></p>
<form method="POST" style="display:inline">
<input type="hidden" name="action" value="disable_otp">
<input type="hidden" name="otpuser" value="<?php echo htmlspecialchars($u); ?>">
<input type="submit" value="Disable OTP" onclick="return confirm('Are you sure you want to disable OTP?')">
</form>
<?php endif; ?>
<p><a href="#" onclick="document.getElementById('otp_<?php echo htmlspecialchars($u); ?>').style.display='none'; return false;">[Close]</a></p>
</div>
<?php endif; ?>
<?php endforeach; ?>

<hr>
<p><small>Omi Server</small></p>
</body>
</html>
    <?php
    exit;
}

// Handle commit log/history display
if (isset($_GET['log'])) {
    $reponame = sanitizeRepoName($_GET['log']);
    if (!preg_match('/\.omi$/', $reponame)) {
        $reponame .= '.omi';
    }

    $repopath = REPOS_DIR . '/' . $reponame;

    // Validate path is safe
    if (!isPathSafe($repopath) || !file_exists($repopath)) {
        http_response_code(404);
        echo 'Repository not found';
        exit;
    }

    $page = isset($_GET['page']) ? max(1, intval($_GET['page'])) : 1;
    $per_page = 10;
    $offset = ($page - 1) * $per_page;

    try {
        $pdo = new PDO('sqlite:' . $repopath);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        // Get total commits
        $stmt = $pdo->query("SELECT COUNT(*) as total FROM commits");
        $total = $stmt->fetch(PDO::FETCH_ASSOC)['total'];
        $total_pages = ceil($total / $per_page);

        // Get commits for this page
        $stmt = $pdo->prepare("
            SELECT
                c.id,
                c.message,
                c.datetime,
                c.user,
                COUNT(f.id) as file_count
            FROM commits c
            LEFT JOIN files f ON c.id = f.commit_id
            GROUP BY c.id
            ORDER BY c.id DESC
            LIMIT ? OFFSET ?
        ");
        $stmt->execute([$per_page, $offset]);
        $commits = $stmt->fetchAll(PDO::FETCH_ASSOC);

        $username = getUsername();
        ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Commit History - <?php echo htmlspecialchars($reponame); ?></title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>Commit History - <?php echo htmlspecialchars($reponame); ?></h1></td><td align="right"><small><?php if ($username): ?><strong><?php echo htmlspecialchars($username); ?></strong> | <a href="/logout">[Logout]</a><?php else: ?><a href="/sign-in">[Sign In]</a><?php endif; ?></small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="/settings">[Settings]</a> | <a href="/language">[Language]</a> | <a href="/people">[People]</a> | <a href="/<?php echo htmlspecialchars(str_replace('.omi', '', $reponame)); ?>">[Repository Root]</a></p>
<hr>
<?php if (empty($commits)): ?>
<p>No commits found</p>
<?php else: ?>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr bgcolor="#333333">
<th><font color="white">Commit ID</font></th>
<th><font color="white">Message</font></th>
<th><font color="white">Author</font></th>
<th><font color="white">Date</font></th>
<th><font color="white">Files</font></th>
</tr>
<?php foreach ($commits as $commit): ?>
<tr>
<td><strong><?php echo htmlspecialchars($commit['id']); ?></strong></td>
<td><?php echo htmlspecialchars($commit['message']); ?></td>
<td><?php echo htmlspecialchars($commit['user']); ?></td>
<td><?php echo htmlspecialchars($commit['datetime']); ?></td>
<td><?php echo intval($commit['file_count']); ?></td>
</tr>
<?php endforeach; ?>
</table>
<hr>
<p>Page <?php echo $page; ?> of <?php echo $total_pages; ?> (Total: <?php echo $total; ?> commits)</p>
<p>
<?php if ($page > 1): ?>
<a href="?log=<?php echo urlencode($reponame); ?>&page=<?php echo $page - 1; ?>">[Previous]</a>
<?php endif; ?>
<?php if ($page < $total_pages): ?>
<a href="?log=<?php echo urlencode($reponame); ?>&page=<?php echo $page + 1; ?>">[Next]</a>
<?php endif; ?>
</p>
<?php endif; ?>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>
        <?php
        exit;
    } catch (Exception $e) {
        http_response_code(500);
        echo 'Error reading commits: ' . htmlspecialchars($e->getMessage());
        exit;
    }
}

// Handle image display
if (isset($_GET['image'])) {
    $imagefile = $_GET['image'];
    $username = getUsername();

    // Validate and open image from repo
    $parts = explode('/', $imagefile);
    $repoName = sanitizeRepoName(array_shift($parts));
    $imagePath = implode('/', $parts);

    // Remove any directory traversal attempts from image path
    $imagePath = str_replace(['../', '..\\', '\0'], '', $imagePath);

    if (!preg_match('/\.omi$/', $repoName)) {
        $repoName .= '.omi';
    }

    $repoPath = REPOS_DIR . '/' . $repoName;

    // Validate path is safe
    if (!isPathSafe($repoPath) || !file_exists($repoPath)) {
        http_response_code(404);
        echo 'Image not found';
        exit;
    }

    try {
        $pdo = new PDO('sqlite:' . $repoPath);
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);

        $stmt = $pdo->prepare("SELECT f.filename, b.data FROM files f
                             LEFT JOIN blobs b ON f.hash = b.hash
                             WHERE f.filename = ? ORDER BY f.commit_id DESC LIMIT 1");
        $stmt->execute([$imagePath]);
        $result = $stmt->fetch(PDO::FETCH_ASSOC);

        if ($result && $result['data']) {
            ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title><?php echo htmlspecialchars($imagePath); ?> - <?php echo htmlspecialchars($repoName); ?></title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1><?php echo htmlspecialchars($repoName); ?></h1></td><td align="right"><small><?php if ($username): ?><strong><?php echo htmlspecialchars($username); ?></strong> | <a href="/logout">[Logout]</a><?php else: ?><a href="/sign-in">[Sign In]</a><?php endif; ?></small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="/settings">[Settings]</a> | <a href="/language">[Language]</a> | <a href="/people">[People]</a> | <a href="/<?php echo htmlspecialchars(str_replace('.omi', '', $repoName)); ?>">[Repository Root]</a></p>
<h2>Image: <?php echo htmlspecialchars($imagePath); ?></h2>
<hr>
<div style="text-align:center">
<img src="data:image/png;base64,<?php echo base64_encode($result['data']); ?>" alt="<?php echo htmlspecialchars(basename($imagePath)); ?>">
</div>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>
            <?php
            exit;
        } else {
            http_response_code(404);
            echo 'Image not found';
            exit;
        }
    } catch (Exception $e) {
        http_response_code(404);
        echo 'Image not found';
        exit;
    }
}
    // Handle download request
    if (isset($_GET['download'])) {
        $filename = sanitizeRepoName(basename($_GET['download']));
        $filepath = REPOS_DIR . '/' . $filename;

        // Validate path is safe
        if (isPathSafe($filepath) && file_exists($filepath) && pathinfo($filename, PATHINFO_EXTENSION) === 'omi') {
            header('Content-Type: application/octet-stream');
            header('Content-Disposition: attachment; filename="' . $filename . '"');
            header('Content-Length: ' . filesize($filepath));
            readfile($filepath);
            exit;
        } else {
            http_response_code(404);
            echo "Repository not found";
            exit;
        }
    }

    // Check if requesting JSON API
    if (isset($_GET['format']) && $_GET['format'] === 'json') {
        header('Content-Type: application/json');
        echo json_encode(['repos' => getReposList()]);
        exit;
    }

    // Parse request URI
    $request = parseRequestURI();

    if ($request['type'] === 'error') {
        http_response_code(404);
        echo '<html><body><h1>Error: ' . htmlspecialchars($request['message']) . '</h1></body></html>';
        exit;
    }

    if ($request['type'] === 'browse') {
        // Browse repository
        $repoName = $request['repo'];
        $repoPath = $request['path'];
        $db = $request['db'];

        $files = getLatestFiles($db, $repoPath);

        // Check if it's a single file
        $isFile = false;
        $fileContent = null;
        $fileHash = null;

        if (count($files) === 1 && $files[0]['filename'] === $repoPath) {
            $isFile = true;
            $fileHash = $files[0]['hash'];
            $fileContent = getFileContent($db, $fileHash);
        }

        if ($isFile && $fileContent !== null) {
            // Display file content
            $isText = isTextFile($fileContent);
            $username = getUsername();

            // Handle download request
            if (isset($_GET['download']) && $_GET['download'] === '1') {
                $filename = basename($repoPath);
                header('Content-Type: application/octet-stream');
                header('Content-Disposition: attachment; filename="' . addslashes($filename) . '"');
                header('Content-Length: ' . strlen($fileContent));
                echo $fileContent;
                exit;
            }

            // Handle delete request (with confirmation)
            if (isset($_POST['delete_confirm']) && $_POST['delete_confirm'] === '1' && $username) {
                if (deleteFile($db, $repoPath)) {
                    header('Location: /' . htmlspecialchars(str_replace('.omi', '', $repoName)));
                    exit;
                } else {
                    $error_msg = 'Failed to delete file';
                }
            }

            // Check if delete confirmation is being requested
            $show_delete_confirm = isset($_GET['delete']) && $_GET['delete'] === '1' && $username;

            // Handle edit request
            if (isset($_POST['save_file']) && $isText && $username) {
                $newContent = $_POST['file_content'] ?? '';
                if (commitFile($db, $repoPath, $newContent)) {
                    $fileContent = $newContent;
                    $success_msg = 'File saved successfully';
                } else {
                    $error_msg = 'Failed to save file';
                }
            }

            // Check if in edit mode
            $in_edit = isset($_GET['edit']) && $_GET['edit'] === '1' && $username && $isText;

            ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title><?php echo htmlspecialchars($repoPath); ?> - <?php echo htmlspecialchars($repoName); ?></title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1><?php echo htmlspecialchars($repoName); ?></h1></td><td align="right"><small><?php if ($username): ?><strong><?php echo htmlspecialchars($username); ?></strong> | <a href="/logout">[Logout]</a><?php else: ?><a href="/sign-in">[Sign In]</a><?php endif; ?></small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="/language">[Language]</a> | <a href="?log=<?php echo urlencode($repoName); ?>">[Log]</a> | <a href="/<?php echo htmlspecialchars(str_replace('.omi', '', $repoName)); ?>">[Repository Root]</a></p>
<h2>File: <?php echo htmlspecialchars($repoPath); ?></h2>
<?php if ($show_delete_confirm): ?>
<!-- Delete confirmation form (HTML 3.2 compatible, no JavaScript) -->
<div style="border: 2px solid #ff0000; padding: 10px; background-color: #ffcccc;">
<p><font color="red"><strong>⚠️ Confirm Delete</strong></font></p>
<p>Are you sure you want to delete <strong><?php echo htmlspecialchars($repoPath); ?></strong>?</p>
<p>This action cannot be undone. The file will be removed from the current version, but previous versions in the history will still contain the file.</p>
<form method="POST" action="">
<input type="hidden" name="delete_confirm" value="1">
<input type="submit" value="Confirm Delete"> | <a href="?">[Cancel]</a>
</form>
</div>
<hr>
<?php else: ?>
<?php if ($username): ?>
<form method="GET" style="display:inline">
<input type="submit" formaction="?download=1" value="Download">
</form>
<?php if ($isText): ?>
<form method="GET" style="display:inline">
<input type="hidden" name="edit" value="1">
<input type="submit" value="Edit">
</form>
<?php endif; ?>
<form method="GET" style="display:inline">
<input type="hidden" name="delete" value="1">
<input type="submit" value="Delete" onclick="return confirm('Delete this file?')">
</form>
<?php endif; ?>
<?php if (isset($success_msg)): ?>
<p><font color="green"><strong><?php echo htmlspecialchars($success_msg); ?></strong></font></p>
<?php endif; ?>
<?php if (isset($error_msg)): ?>
<p><font color="red"><strong><?php echo htmlspecialchars($error_msg); ?></strong></font></p>
<?php endif; ?>
<hr>
<?php if ($in_edit): ?>
<p><b>Markdown Syntax Reference:</b></p>
<table border="1" cellpadding="5" style="font-size: 12px; margin-bottom: 20px;">
<tr><th>Syntax</th><th>Result</th></tr>
<tr><td># Heading 1</td><td>Large heading</td></tr>
<tr><td>## Heading 2</td><td>Medium heading</td></tr>
<tr><td>### Heading 3</td><td>Small heading</td></tr>
<tr><td>**bold text**</td><td><b>bold text</b></td></tr>
<tr><td>*italic text*</td><td><i>italic text</i></td></tr>
<tr><td>`code`</td><td><code>code</code></td></tr>
<tr><td>```<br>code block<br>```</td><td>Multi-line code</td></tr>
<tr><td>[link text](url)</td><td>Clickable link</td></tr>
<tr><td>![alt text](image.jpg)</td><td>Image from repo or URL</td></tr>
<tr><td>![alt](https://example.com/img.jpg)</td><td>Image from URL</td></tr>
</table>
<form method="POST">
<textarea name="file_content" rows="20" cols="80" style="width: 100%; max-width: 800px; font-family: monospace; box-sizing: border-box;"><?php echo htmlspecialchars($fileContent); ?></textarea><br><br>
<input type="submit" name="save_file" value="Save">
<input type="submit" formaction="?" formmethod="GET" value="Cancel">
</form>
<?php else: ?>
<?php if ($isText): ?>
<?php 
    // Check file type and render appropriately
    $isMarkdown = isMarkdownFile($repoPath);
    $isSVG = isSVGFile($repoPath);
    $mediaType = getMediaType($repoPath);
?>
<?php if ($isMarkdown): ?>
<!-- Markdown rendering -->
<div style="font-family: Arial, sans-serif; line-height: 1.6;">
<?php echo markdownToHtml($fileContent); ?>
</div>
<?php elseif (isImageFile($repoPath)): ?>
<!-- Image display -->
<p><b>Image File</b></p>
<?php 
    $base64Data = base64_encode($fileContent);
    $ext = strtolower(pathinfo($repoPath, PATHINFO_EXTENSION));
    $mimeTypes = [
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'bmp' => 'image/bmp',
        'webp' => 'image/webp',
        'ico' => 'image/x-icon',
        'tiff' => 'image/tiff',
        'tif' => 'image/tiff'
    ];
    $mimeType = $mimeTypes[$ext] ?? 'image/jpeg';
?>
<div style="border: 1px solid #ccc; padding: 10px; background-color: white; display: inline-block;">
<img src="data:<?php echo $mimeType; ?>;base64,<?php echo $base64Data; ?>" alt="<?php echo htmlspecialchars(basename($repoPath)); ?>" style="max-width: 100%; height: auto; max-height: 500px;">
</div>
<p><small>Image file size: <?php echo number_format(strlen($fileContent)); ?> bytes</small></p>
<?php elseif ($isSVG): ?>
<!-- SVG rendering with security checks -->
<?php 
    // Check for security dangers in SVG
    $hasJavaScript = svgContainsJavaScript($fileContent);
    $hasXMLDanger = svgContainsXMLDanger($fileContent);
    
    if ($hasJavaScript) {
        // JavaScript detected - dangerous
?>
<div style="border: 2px solid #ff0000; padding: 10px; background-color: #ffcccc;">
<p><font color="red"><strong>⚠️ Cannot show .svg file because it contains Javascript, it could be dangerous</strong></font></p>
<p><small>SVG files can contain executable scripts. This file has been blocked for security reasons.</small></p>
</div>
<?php 
    } elseif ($hasXMLDanger) {
        // XML entity/loop danger detected
?>
<div style="border: 2px solid #ff0000; padding: 10px; background-color: #ffcccc;">
<p><font color="red"><strong>⚠️ Cannot show .svg file because it contains XML loop, it could be dangerous</strong></font></p>
<p><small>SVG files can contain recursive XML entities that cause denial of service attacks. This file has been blocked for security reasons.</small></p>
</div>
<?php 
    } else {
        // SVG is safe, check browser support
        $supportsSVG = browserSupportsSVG();
        if ($supportsSVG) {
            // Browser supports SVG, display directly
?>
<div style="border: 1px solid #ccc; padding: 10px; background-color: white;">
<?php echo $fileContent; ?>
</div>
<p><small>SVG image rendered natively</small></p>
<?php 
        } else {
            // Browser doesn't support SVG, try to convert to GIF
            $gifData = svgToGif($fileContent);
            if ($gifData) {
                $base64Gif = base64_encode($gifData);
?>
<div style="border: 1px solid #ccc; padding: 10px; background-color: white;">
<img src="data:image/gif;base64,<?php echo $base64Gif; ?>" alt="SVG Image (converted to GIF)" style="max-width: 100%; height: auto;">
</div>
<p><small>SVG image automatically converted to GIF for your browser</small></p>
<?php 
            } else {
                // Conversion failed, show warning
?>
<div style="border: 2px solid #ffaa00; padding: 10px; background-color: #ffffcc;">
<p><font color="#cc7700"><strong>⚠️ Cannot display SVG image</strong></font></p>
<p><small>SVG support is not available in your browser. Consider using a modern browser like Firefox, Chrome, or Safari.</small></p>
</div>
<?php 
            }
        }
    }
?>
<?php elseif ($mediaType === 'audio'): ?>
<!-- Audio player -->
<p><b>Audio File</b></p>
<?php 
    $base64Data = base64_encode($fileContent);
    $ext = strtolower(pathinfo($repoPath, PATHINFO_EXTENSION));
    $mimeTypes = [
        'mp3' => 'audio/mpeg',
        'wav' => 'audio/wav',
        'ogg' => 'audio/ogg',
        'flac' => 'audio/flac',
        'm4a' => 'audio/mp4',
        'aac' => 'audio/aac'
    ];
    $mimeType = $mimeTypes[$ext] ?? 'audio/mpeg';
?>
<audio controls style="width: 100%; max-width: 400px;">
  <source src="data:<?php echo $mimeType; ?>;base64,<?php echo $base64Data; ?>" type="<?php echo $mimeType; ?>">
  <p>Your browser does not support the audio element. <a href="?download=1">Download file</a> to play it with an external player.</p>
</audio>
<p><small>Modern browsers: use the audio player above with controls for play, pause, volume, and progress. HTML 3.2 browsers: <a href="?download=1">[Download]</a></small></p>
<?php elseif ($mediaType === 'video'): ?>
<!-- Video player -->
<p><b>Video File</b></p>
<?php 
    $base64Data = base64_encode($fileContent);
    $ext = strtolower(pathinfo($repoPath, PATHINFO_EXTENSION));
    $mimeTypes = [
        'mp4' => 'video/mp4',
        'webm' => 'video/webm',
        'ogg' => 'video/ogg',
        'mkv' => 'video/x-matroska',
        'avi' => 'video/x-msvideo',
        'mov' => 'video/quicktime',
        'flv' => 'video/x-flv',
        'wmv' => 'video/x-ms-wmv'
    ];
    $mimeType = $mimeTypes[$ext] ?? 'video/mp4';
?>
<video controls style="width: 100%; max-width: 600px;">
  <source src="data:<?php echo $mimeType; ?>;base64,<?php echo $base64Data; ?>" type="<?php echo $mimeType; ?>">
  <p>Your browser does not support the video element. <a href="?download=1">Download file</a> to play it with an external player.</p>
</video>
<p><small>Modern browsers: use the video player above with controls for play, pause, volume, progress, and fullscreen. HTML 3.2 browsers: <a href="?download=1">[Download]</a></small></p>
<?php else: ?>
<!-- Plain text -->
<pre><?php echo htmlspecialchars($fileContent); ?></pre>
<?php endif; ?>
<?php else: ?>
<?php if (isImageFile($repoPath)): ?>
<!-- Image display for binary image files -->
<p><strong>Binary file (<?php echo strlen($fileContent); ?> bytes)</strong></p>
<p>Hash: <?php echo htmlspecialchars($fileHash); ?></p>
<hr>
<p><b>Image File</b></p>
<?php 
    $base64Data = base64_encode($fileContent);
    $ext = strtolower(pathinfo($repoPath, PATHINFO_EXTENSION));
    $mimeTypes = [
        'jpg' => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'bmp' => 'image/bmp',
        'webp' => 'image/webp',
        'ico' => 'image/x-icon',
        'tiff' => 'image/tiff',
        'tif' => 'image/tiff'
    ];
    $mimeType = $mimeTypes[$ext] ?? 'image/jpeg';
?>
<div style="border: 1px solid #ccc; padding: 10px; background-color: white; display: inline-block;">
<img src="data:<?php echo $mimeType; ?>;base64,<?php echo $base64Data; ?>" alt="<?php echo htmlspecialchars(basename($repoPath)); ?>" style="max-width: 100%; height: auto; max-height: 500px;">
</div>
<p><small>Image file size: <?php echo number_format(strlen($fileContent)); ?> bytes</small></p>
<?php else: ?>
<p><strong>Binary file (<?php echo strlen($fileContent); ?> bytes)</strong></p>
<p>Hash: <?php echo htmlspecialchars($fileHash); ?></p>
<?php endif; ?>
<?php endif; ?>
<?php endif; ?>
<?php endif; ?>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>
            <?php
            exit;
        }

        // Display directory listing
        $organized = organizeFiles($files, $repoPath);
        $username = getUsername();
        $upload_msg = '';
        $upload_error = '';

        if ($_SERVER['REQUEST_METHOD'] === 'POST' && $username) {
            $action = $_POST['action'] ?? '';

            if ($action === 'delete_file') {
                $target = trim($_POST['target'] ?? '');
                $target = str_replace(['../', '..\\', '/', '\\'], '_', $target);
                $targetPath = $repoPath ? $repoPath . '/' . $target : $target;

                if (empty($target)) {
                    $upload_error = 'File name is required';
                } elseif (deleteFile($db, $targetPath)) {
                    $upload_msg = "File '$target' deleted";
                    $files = getLatestFiles($db, $repoPath);
                    $organized = organizeFiles($files, $repoPath);
                } else {
                    $upload_error = 'Failed to delete file';
                }
            } elseif ($action === 'rename_file') {
                $target = trim($_POST['target'] ?? '');
                $newName = trim($_POST['new_name'] ?? '');
                $target = str_replace(['../', '..\\', '/', '\\'], '_', $target);
                $newName = str_replace(['../', '..\\', '/', '\\'], '_', $newName);

                if (empty($target) || empty($newName)) {
                    $upload_error = 'File name and new name are required';
                } else {
                    $targetPath = $repoPath ? $repoPath . '/' . $target : $target;
                    $newPath = $repoPath ? $repoPath . '/' . $newName : $newName;
                    $targetHash = null;
                    foreach ($files as $entry) {
                        if ($entry['filename'] === $targetPath) {
                            $targetHash = $entry['hash'];
                            break;
                        }
                    }

                    if (!$targetHash) {
                        $upload_error = 'File not found';
                    } else {
                        $fileContent = getFileContent($db, $targetHash);
                        if (commitFile($db, $newPath, $fileContent) && deleteFile($db, $targetPath)) {
                            $upload_msg = "File '$target' renamed to '$newName'";
                            $files = getLatestFiles($db, $repoPath);
                            $organized = organizeFiles($files, $repoPath);
                        } else {
                            $upload_error = 'Failed to rename file';
                        }
                    }
                }
            } elseif ($action === 'create_dir') {
                $dirName = trim($_POST['dir_name'] ?? '');
                $dirName = str_replace(['../', '..\\', '/', '\\'], '_', $dirName);

                if (empty($dirName)) {
                    $upload_error = 'Directory name is required';
                } else {
                    $dirPath = $repoPath ? $repoPath . '/' . $dirName : $dirName;
                    $markerPath = $dirPath . '/.omidir';
                    if (commitFile($db, $markerPath, '')) {
                        $upload_msg = "Directory '$dirName' created";
                        $files = getLatestFiles($db, $repoPath);
                        $organized = organizeFiles($files, $repoPath);
                    } else {
                        $upload_error = 'Failed to create directory';
                    }
                }
            } elseif ($action === 'create_file') {
                $fileName = trim($_POST['file_name'] ?? '');
                $fileName = str_replace(['../', '..\\', '/', '\\'], '_', $fileName);
                $fileContent = $_POST['file_content'] ?? '';

                if (empty($fileName)) {
                    $upload_error = 'File name is required';
                } else {
                    $fullPath = $repoPath ? $repoPath . '/' . $fileName : $fileName;
                    if (commitFile($db, $fullPath, $fileContent)) {
                        $upload_msg = "File '$fileName' created";
                        $files = getLatestFiles($db, $repoPath);
                        $organized = organizeFiles($files, $repoPath);
                    } else {
                        $upload_error = 'Failed to create file';
                    }
                }
            } elseif (isset($_FILES['upload_file'])) {
                $uploadFile = $_FILES['upload_file'];

                // Validate file
                if ($uploadFile['error'] === UPLOAD_ERR_OK) {
                    $fileName = basename($uploadFile['name']);
                    // Sanitize filename - remove path traversal attempts
                    $fileName = str_replace(['../', '..\\', '/', '\\'], '_', $fileName);

                    if (empty($fileName)) {
                        $upload_error = 'Invalid filename';
                    } else {
                        // Calculate full path for file in repo
                        $fullPath = $repoPath ? $repoPath . '/' . $fileName : $fileName;

                        // Read file content
                        $fileContent = file_get_contents($uploadFile['tmp_name']);

                        // Upload to database
                        if (uploadFile($db, $fullPath, $fileContent)) {
                            $upload_msg = "File '$fileName' uploaded successfully";
                            // Refresh file listing
                            $files = getLatestFiles($db, $repoPath);
                            $organized = organizeFiles($files, $repoPath);
                        } else {
                            $upload_error = 'Failed to upload file to database';
                        }
                    }
                } else {
                    switch ($uploadFile['error']) {
                        case UPLOAD_ERR_INI_SIZE:
                        case UPLOAD_ERR_FORM_SIZE:
                            $upload_error = 'File is too large';
                            break;
                        case UPLOAD_ERR_PARTIAL:
                            $upload_error = 'File upload was interrupted';
                            break;
                        case UPLOAD_ERR_NO_FILE:
                            $upload_error = 'No file was selected';
                            break;
                        default:
                            $upload_error = 'Upload failed with error code: ' . $uploadFile['error'];
                    }
                }
            }
        }

        ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title><?php echo $repoPath ? htmlspecialchars($repoPath) : 'Root'; ?> - <?php echo htmlspecialchars($repoName); ?></title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1><?php echo htmlspecialchars($repoName); ?></h1></td><td align="right"><small><?php if ($username): ?><strong><?php echo htmlspecialchars($username); ?></strong> | <a href="/logout">[Logout]</a><?php else: ?><a href="/sign-in">[Sign In]</a><?php endif; ?></small></td></tr>
</table>
<p><a href="/">[Home]</a> | <a href="?log=<?php echo urlencode($repoName); ?>">[Log]</a></p>
<h2>Directory: /<?php echo htmlspecialchars($repoPath); ?></h2>
<hr>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr bgcolor="#333333">
<th><font color="white">Name</font></th>
<th><font color="white">Size</font></th>
<th><font color="white">Modified</font></th>
<th><font color="white">Actions</font></th>
</tr>
<?php if ($repoPath): ?>
<?php
  // Calculate parent directory path
  $parentPath = dirname($repoPath);
  if ($parentPath === '.') $parentPath = '';
  $parentUrl = '/' . htmlspecialchars(str_replace('.omi', '', $repoName));
  if ($parentPath) $parentUrl .= '/' . htmlspecialchars($parentPath);
?>
<tr>
<td><a href="<?php echo $parentUrl; ?>">📁 ..</a></td>
<td>-</td>
<td>-</td>
<td>-</td>
</tr>
<?php endif; ?>
<?php if (!empty($organized['dirs'])): ?>
<?php foreach ($organized['dirs'] as $dir): ?>
<tr>
<td><a href="/<?php echo htmlspecialchars(str_replace('.omi', '', $repoName) . '/' . $dir['path']); ?>">📁 <?php echo htmlspecialchars($dir['name']); ?>/</a></td>
<td>-</td>
<td><?php echo htmlspecialchars($dir['datetime']); ?></td>
<td>-</td>
</tr>
<?php endforeach; ?>
<?php endif; ?>
<?php if (!empty($organized['files'])): ?>
<?php foreach ($organized['files'] as $file): ?>
<tr>
<td><a href="/<?php echo htmlspecialchars(str_replace('.omi', '', $repoName) . '/' . $file['filename']); ?>">📄 <?php echo htmlspecialchars(basename($file['filename'])); ?></a></td>
<td><?php echo number_format($file['size']); ?></td>
<td><?php echo htmlspecialchars($file['datetime']); ?></td>
<td>
<?php if ($username): ?>
<?php
  // Check if file is text to show edit link
  $isTextFile = true;
  // For now, we assume text files. In a real implementation, we'd check the file content
  $fileLink = '/' . htmlspecialchars(str_replace('.omi', '', $repoName) . '/' . $file['filename']);
?>
<a href="<?php echo $fileLink; ?>?edit=1">[Edit]</a> |
<form method="POST" style="display:inline">
<input type="hidden" name="action" value="delete_file">
<input type="hidden" name="target" value="<?php echo htmlspecialchars(basename($file['filename'])); ?>">
<input type="submit" value="Delete" onclick="return confirm('Delete file <?php echo htmlspecialchars(basename($file['filename'])); ?>?')">
</form>
<form method="POST" style="display:inline">
<input type="hidden" name="action" value="rename_file">
<input type="hidden" name="target" value="<?php echo htmlspecialchars(basename($file['filename'])); ?>">
<input type="text" name="new_name" size="12" placeholder="New name">
<input type="submit" value="Rename">
</form>
<?php else: ?>
-
<?php endif; ?>
</td>
</tr>
<?php endforeach; ?>
<?php endif; ?>
<?php if (empty($organized['dirs']) && empty($organized['files'])): ?>
<tr><td colspan="4">No files in this directory</td></tr>
<?php endif; ?>
</table>
<hr>
<?php if (isset($upload_msg) && !empty($upload_msg)): ?>
<p><font color="green"><strong><?php echo htmlspecialchars($upload_msg); ?></strong></font></p>
<?php endif; ?>
<?php if (isset($upload_error) && !empty($upload_error)): ?>
<p><font color="red"><strong><?php echo htmlspecialchars($upload_error); ?></strong></font></p>
<?php endif; ?>
<?php if ($username): ?>
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
<?php else: ?>
<p><small><a href="/sign-in">[Sign in]</a> to upload files</small></p>
<?php endif; ?>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>
        <?php
        exit;
    }

    // Default: Show repository list
    $repo_message = null;
    $repo_message_is_error = false;
    if ($_SERVER['REQUEST_METHOD'] === 'POST' && isLoggedIn() && ($_POST['action'] ?? '') === 'create_repo') {
        $repo_error = null;
        $repo_name = $_POST['repo_name'] ?? '';
        if (createEmptyRepository($repo_name, getUsername(), $repo_error)) {
            $repo_message = 'Repository created successfully';
        } else {
            $repo_message = $repo_error ?: 'Failed to create repository';
            $repo_message_is_error = true;
        }
    }

    $repos = getReposList();
    $username = getUsername();

    // HTML display - Repository list
    ?>
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">
<html>
<head>
<title>Omi Server - Repository List</title>
</head>
<body bgcolor="#f0f0f0">
<table width="100%" border="0" cellpadding="5">
<tr><td><h1>Omi Server - Repository List</h1></td><td align="right"><small><?php if ($username): ?><strong><?php echo htmlspecialchars($username); ?></strong> | <a href="/language">[Language]</a> | <a href="/logout">[Logout]</a><?php else: ?><a href="/sign-in">[Sign In]</a><?php endif; ?></small></td></tr>
</table>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr bgcolor="#e8f4f8">
<td colspan="4">
<strong>Server:</strong> <?php echo htmlspecialchars($_SERVER['HTTP_HOST']); ?><br>
<strong>Protocol:</strong> <?php echo isset($_SERVER['HTTPS']) ? 'HTTPS' : 'HTTP'; ?><br>
<strong>Repositories:</strong> <?php echo count($repos); ?>
</td>
</tr>
</table>
<?php if ($repo_message): ?>
<p><font color="<?php echo $repo_message_is_error ? 'red' : 'green'; ?>"><strong><?php echo htmlspecialchars($repo_message); ?></strong></font></p>
<?php endif; ?>
<h2>Available Repositories</h2>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr bgcolor="#333333">
<th><font color="white">Repository</font></th>
<th><font color="white">Size (bytes)</font></th>
<th><font color="white">Last Modified</font></th>
<th><font color="white">Actions</font></th>
</tr>
<?php if (empty($repos)): ?>
<tr><td colspan="4">No repositories found</td></tr>
<?php else: ?>
<?php foreach ($repos as $repo): ?>
<tr>
<td><a href="/<?php echo htmlspecialchars(str_replace('.omi', '', $repo['name'])); ?>"><?php echo htmlspecialchars($repo['name']); ?></a></td>
<td><?php echo number_format($repo['size']); ?></td>
<td><?php echo htmlspecialchars(date('Y-m-d H:i:s', $repo['modified'])); ?></td>
<td><a href="?download=<?php echo urlencode($repo['name']); ?>">Download</a> | <a href="?log=<?php echo urlencode($repo['name']); ?>">[Log]</a></td>
</tr>
<?php endforeach; ?>
<?php endif; ?>
</table>
<?php if ($username): ?>
<h2>Create New Repository</h2>
<form method="POST">
<table border="0" cellpadding="5">
<tr><td>Repository name:</td><td><input type="text" name="repo_name" size="30"> (e.g., wekan.omi)</td></tr>
<tr><td colspan="2"><input type="hidden" name="action" value="create_repo"><input type="submit" value="Create Repository"></td></tr>
</table>
</form>
<h2>Upload/Update Repository</h2>
<form method="POST" enctype="multipart/form-data">
<table border="0" cellpadding="5">
<tr><td>Username:</td><td><input type="text" name="username" size="30"></td></tr>
<tr><td>Password:</td><td><input type="password" name="password" size="30"></td></tr>
<tr><td>Repository name:</td><td><input type="text" name="repo_name" size="30"> (e.g., wekan.omi)</td></tr>
<tr><td>File:</td><td><input type="file" name="repo_file"></td></tr>
<tr><td colspan="2"><input type="submit" name="action" value="Upload"></td></tr>
</table>
</form>
<?php else: ?>
<p><a href="/sign-in">[Sign In to upload repositories]</a></p>
<?php endif; ?>
<h2>API Endpoints</h2>
<table border="1" width="100%" cellpadding="5" cellspacing="0">
<tr><td><strong>List repos (JSON):</strong></td><td>GET /?format=json</td></tr>
<tr><td><strong>Download repo:</strong></td><td>GET /?download=wekan.omi</td></tr>
<tr><td><strong>Upload repo:</strong></td><td>POST with username, password, repo_name, repo_file</td></tr>
<tr><td><strong>Pull changes:</strong></td><td>POST with username, password, action=pull, repo_name</td></tr>
</table>
<hr>
<p><small>Omi Server</small></p>
</body>
</html>
    <?php
    exit;

// Handle POST request - Upload/Download with authentication
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $username = $_POST['username'] ?? '';
    $password = $_POST['password'] ?? '';
    $otpCode = $_POST['otp_code'] ?? '';
    $action = $_POST['action'] ?? 'Upload';

    // Check if API is enabled
    $settings = loadSettings();
    if (intval($settings['API_ENABLED'] ?? 1) === 0) {
        http_response_code(503);
        echo json_encode(['error' => 'API is disabled', 'api_disabled' => true]);
        exit;
    }

    // Get rate limit info (also cleans up old entries)
    cleanupOldRateLimitEntries();
    $rateInfo = getAPIRateInfo($username);

    if (!$rateInfo['enabled']) {
        http_response_code(503);
        echo json_encode(['error' => $rateInfo['message'], 'api_disabled' => true]);
        exit;
    }

    if (isset($rateInfo['limited']) && $rateInfo['limited']) {
        http_response_code(429);
        header('X-RateLimit-Remaining: 0');
        header('X-RateLimit-Reset: ' . $rateInfo['reset']);
        header('Retry-After: ' . $rateInfo['wait_seconds']);
        echo json_encode([
            'error' => 'Rate limit exceeded',
            'rate_limit_reset' => $rateInfo['reset'],
            'retry_after_seconds' => $rateInfo['wait_seconds']
        ]);
        exit;
    }

    // Authenticate
    $authResult = authenticate($username, $password, $otpCode);

    if ($authResult === 'OTP_REQUIRED') {
        http_response_code(401);
        echo json_encode(['error' => 'OTP code required', 'otp_required' => true]);
        exit;
    }

    if (!$authResult) {
        http_response_code(401);
        echo json_encode(['error' => 'Authentication failed']);
        exit;
    }

    // Track the API request
    trackAPIRequest($username);
    $rateInfo = getAPIRateInfo($username);

    // Send rate limit headers
    header('X-RateLimit-Limit: ' . intval($settings['API_RATE_LIMIT'] ?? 60));
    header('X-RateLimit-Remaining: ' . $rateInfo['remaining']);
    header('X-RateLimit-Reset: ' . $rateInfo['reset']);

    // Handle upload
    if ($action === 'Upload' && isset($_FILES['repo_file'])) {
        $repo_name = basename($_POST['repo_name'] ?? '');

        // Validate repository name
        if (!preg_match('/^[a-zA-Z0-9_-]+\.omi$/', $repo_name)) {
            http_response_code(400);
            echo json_encode(['error' => 'Invalid repository name. Must end with .omi']);
            exit;
        }

        $upload_file = $_FILES['repo_file'];
        $target_path = REPOS_DIR . '/' . $repo_name;

        if ($upload_file['error'] === UPLOAD_ERR_OK) {
            if (move_uploaded_file($upload_file['tmp_name'], $target_path)) {
                echo json_encode([
                    'success' => true,
                    'message' => "Repository $repo_name uploaded successfully",
                    'size' => filesize($target_path),
                    'rate_limit_remaining' => $rateInfo['remaining']
                ]);
            } else {
                http_response_code(500);
                echo json_encode(['error' => 'Failed to save repository']);
            }
        } else {
            http_response_code(400);
            echo json_encode(['error' => 'Upload error: ' . $upload_file['error']]);
        }
        exit;
    }

    // Handle pull request (download specific repo)
    if ($action === 'pull') {
        $repo_name = basename($_POST['repo_name'] ?? '');
        $filepath = REPOS_DIR . '/' . $repo_name;

        if (file_exists($filepath)) {
            header('Content-Type: application/octet-stream');
            header('Content-Disposition: attachment; filename="' . $repo_name . '"');
            header('Content-Length: ' . filesize($filepath));
            header('X-RateLimit-Limit: ' . intval($settings['API_RATE_LIMIT'] ?? 60));
            header('X-RateLimit-Remaining: ' . $rateInfo['remaining']);
            header('X-RateLimit-Reset: ' . $rateInfo['reset']);
            readfile($filepath);
            exit;
        } else {
            http_response_code(404);
            echo json_encode(['error' => 'Repository not found']);
            exit;
        }
    }

    // Default response
    http_response_code(400);
    echo json_encode(['error' => 'Invalid action']);
    exit;
}

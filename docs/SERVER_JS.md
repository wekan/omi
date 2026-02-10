# Omi Server - JavaScript Implementation

A feature-complete HTTP server implementation for Omi written in JavaScript/TypeScript, compatible with **Node.js**, **Bun**, and **Deno**.

## Features

- **Authentication & Authorization**
  - User account management (sign-in, sign-up)
  - TOTP/OTP 2FA support
  - Brute force protection with account lockouts
  - Session-based authentication
  - API rate limiting

- **Repository Management**
  - SQLite-based file storage and versioning
  - Repository browsing with directory navigation
  - File upload and download
  - Commit history and logging

- **File Operations**
  - Text file viewing and editing
  - Markdown rendering
  - SVG rendering with security checks
  - Audio/video player support
  - File deletion with confirmation

- **User Management**
  - Create/delete users
  - Password management
  - OTP enablement/disablement
  - User directory listing

- **API Endpoints**
  - Repository list (JSON)
  - Repository download
  - Repository upload with authentication
  - Rate limiting and error handling

## Requirements

### Node.js
- Node.js 14.0+ (with ES modules support)
- Built-in `fs`, `path`, `crypto`, `http` modules

### Bun
- Bun 1.0+ (optional, full compatibility with Node.js APIs)

### Deno
- Deno 1.30+ with `--allow-net`, `--allow-read`, `--allow-write` permissions

## Installation

### Node.js
```bash
cd /path/to/wekan/public
node server.js
```

### Bun
```bash
cd /path/to/wekan/public
bun server.js
```

### Deno
```bash
deno run --allow-net --allow-read --allow-write server.js
```

## Configuration

The server reads from `settings.txt` in the parent directory (`../settings.txt`):

```
SQLITE=sqlite
USERNAME=admin
PASSWORD=password
REPOS=http://localhost:8080
CURL=curl
API_ENABLED=1
API_RATE_LIMIT=60
API_RATE_LIMIT_WINDOW=60
ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURES_BEFORE=3
ACCOUNTS_LOCKOUT_KNOWN_USERS_FAILURE_WINDOW=15
ACCOUNTS_LOCKOUT_KNOWN_USERS_PERIOD=60
ACCOUNTS_LOCKOUT_UNKNOWN_USERS_FAILURES_BEFORE=3
ACCOUNTS_LOCKOUT_UNKNOWN_USERS_FAILURE_WINDOW=15
ACCOUNTS_LOCKOUT_UNKNOWN_USERS_LOCKOUT_PERIOD=60
```

## User Management

Users are stored in `phpusers.txt` with format:
```
username:password:otpauth_url
user1:pass123:
user2:pass456:otpauth://totp/Omi(user2)?secret=JBSWY3DPEBLW64TMMQ==
```

## API Rate Limiting

The server implements configurable API rate limiting:
- Default: 60 requests per 60 seconds per user
- Configurable via `API_RATE_LIMIT` and `API_RATE_LIMIT_WINDOW` in settings.txt
- Rate limit info returned in response headers:
  - `X-RateLimit-Limit`
  - `X-RateLimit-Remaining`
  - `X-RateLimit-Reset`

## Quick Reference

### Web Routes
| Route | Method | Description |
|-------|--------|-------------|
| `/` | GET | Repository list |
| `/sign-in` | GET/POST | User authentication |
| `/sign-up` | GET/POST | User registration |
| `/logout` | GET | End session |
| `/settings` | GET/POST | Server settings (auth required) |
| `/people` | GET/POST | User management (auth required) |
| `/{repo}` | GET | Browse repository |
| `/?format=json` | GET | List repos as JSON |
| `/?download={repo}.omi` | GET | Download repository |

### API Authentication

All API requests require:
- POST data with `username`, `password`, and optional `otp_code`
- Returns JSON responses with status and rate limit headers

## Security Features

- Path traversal protection via `isPathSafe()` validation
- SVG malicious code detection (JavaScript, XML entities)
- XSS prevention via HTML escaping
- Session-based authentication with secure cookies
- Brute force protection with configurable lockouts
- API rate limiting
- OTP support for 2FA

## Troubleshooting

### Server won't start
- Check that port 8080 is not in use
- Ensure proper file permissions for `repos/` directory
- Verify settings.txt and user files exist

### Authentication issues
- Clear cookies/sessions if locked out
- Check phpusers.txt format: `username:password:otp`
- Verify OTP secret format in otpauth URL

### File upload failures
- Check repository name ends with `.omi`
- Verify directory permissions
- Ensure sufficient disk space

## Runtime Differences

### Node.js
- Most common runtime, best compatibility
- Requires `--experimental-modules` flag for older versions
- Use `node server.js` to start

### Bun
- Faster startup and execution
- Full Node.js API compatibility
- Use `bun server.js` to start

### Deno
- Requires explicit permissions (--allow-net, --allow-read, --allow-write)
- Different module resolution (uses URLs and imports map)
- Use `deno run --allow-net --allow-read --allow-write server.js` to start

## See Also

- [WEB.md](WEB.md) - Web server documentation
- [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md) - SQLite schema
- [CLI_PYTHON3.md](CLI_PYTHON3.md) - Python CLI (similar architecture)
- [CLI_C89.md](CLI_C89.md) - C89 CLI
- [CLI_TCL.md](CLI_TCL.md) - Tcl CLI

## Notes

- Server uses in-memory session storage; consider database session storage for production
- Multipart form parsing is simplified; for large uploads, enhance the parser
- For production use, add HTTPS/TLS support via reverse proxy (nginx, Caddy)
- Monitor rate limiting effectiveness and adjust thresholds as needed

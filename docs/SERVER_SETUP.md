# Omi Server Setup

## Pretty URLs

The server supports pretty URLs for browsing repositories:

- `/` - List all repositories
- `/wekan` - Browse wekan.omi repository root
- `/wekan/src` - Browse src directory in wekan.omi
- `/wekan/README.md` - View README.md file content

## Server Configuration

Choose one of the following web servers:

### Caddy (Recommended - simplest)
```bash
# Install Caddy
# Place Caddyfile in your project directory
caddy run
```

### Apache
```bash
# Enable mod_rewrite
sudo a2enmod rewrite

# Copy apache.conf to sites-available
sudo cp apache.conf /etc/apache2/sites-available/omi.conf

# Enable the site
sudo a2ensite omi.conf

# Reload Apache
sudo systemctl reload apache2
```

Or use the included `.htaccess` file (already in place).

### Nginx
```bash
# Copy nginx.conf to sites-available
sudo cp nginx.conf /etc/nginx/sites-available/omi

# Create symlink in sites-enabled
sudo ln -s /etc/nginx/sites-available/omi /etc/nginx/sites-enabled/

# Test configuration
sudo nginx -t

# Reload Nginx
sudo systemctl reload nginx
```

## HTML 3.2 Compatibility

The interface uses HTML 3.2 for maximum compatibility with:
- **IBrowse with AmiSSL** (Amiga)
- **Dillo** (FreeDOS)
- **Elinks / w3m** (Bash/Linux)

No CSS, table-based layout, simple navigation.

## Features

✅ Pretty URLs (no query strings)
✅ Repository browsing (like GitHub/Fossil)
✅ Directory navigation
✅ Text file viewing
✅ Binary file detection
✅ HTML 3.2 compatible
✅ Works with old browsers

#!/usr/bin/env python3
"""
Omi - Version Control for Python
Optimized Micro Index - Git-like commands with SQLite storage
"""

import sys
import os
import re
import sqlite3
import subprocess
import hashlib
import getpass
from datetime import datetime
from pathlib import Path
from io import BytesIO

# Try to import urllib3 for internal HTTP
try:
    import urllib3
    URLLIB3_AVAILABLE = True
except ImportError:
    URLLIB3_AVAILABLE = False


class Settings:
    """Load and manage settings from settings.txt"""
    
    @staticmethod
    def load():
        """Load settings from settings.txt file"""
        settings = {}
        
        if not os.path.exists("settings.txt"):
            print("Error: settings.txt not found")
            sys.exit(1)
        
        with open("settings.txt", "r") as f:
            for line in f:
                match = re.match(r"^([^=]+)=(.*)$", line.strip())
                if match:
                    key, value = match.groups()
                    settings[key] = value
        
        # Set defaults
        settings["API_ENABLED"] = settings.get("API_ENABLED", "1")
        settings["API_RATE_LIMIT"] = settings.get("API_RATE_LIMIT", "60")
        settings["API_RATE_LIMIT_WINDOW"] = settings.get("API_RATE_LIMIT_WINDOW", "60")
        
        return settings


class OmiRepository:
    """Manage Omi repository operations"""
    
    def __init__(self, settings):
        self.settings = settings
        self.db_name = self._read_dotomi() or "repo.omi"
    
    def _read_dotomi(self):
        """Read database name from .omi file"""
        if os.path.exists(".omi"):
            with open(".omi", "r") as f:
                match = re.search(r'OMI_DB="([^"]+)"', f.read())
                if match:
                    return match.group(1)
        return None
    
    def _write_dotomi(self, db_name):
        """Write database name to .omi file"""
        with open(".omi", "w") as f:
            f.write(f'OMI_DB="{db_name}"\n')
    
    def init(self, db_name="repo.omi"):
        """Initialize a new repository"""
        print("Initializing omi repository...")
        self.db_name = db_name
        self._write_dotomi(db_name)
        
        # Create database and tables
        conn = sqlite3.connect(db_name)
        cursor = conn.cursor()
        
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS blobs (
                hash TEXT PRIMARY KEY,
                data BLOB,
                size INTEGER
            )
        """)
        
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT,
                hash TEXT,
                datetime TEXT,
                commit_id INTEGER,
                FOREIGN KEY(commit_id) REFERENCES commits(id)
            )
        """)
        
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS commits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                message TEXT,
                datetime TEXT,
                user TEXT
            )
        """)
        
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS staging (
                filename TEXT PRIMARY KEY,
                hash TEXT,
                datetime TEXT
            )
        """)
        
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_files_commit ON files(commit_id)")
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash)")
        
        conn.commit()
        conn.close()
        
        print(f"Repository initialized: {db_name}")
    
    def clone(self, url):
        """Clone a repository from local or remote source"""
        print(f"Cloning from {url}...")
        
        if os.path.isfile(url):
            # Local clone
            import shutil
            shutil.copy(url, "repo.omi")
            self._write_dotomi("repo.omi")
            self.db_name = "repo.omi"
            print("Cloned to repo.omi")
        else:
            # Remote clone
            repo_name = os.path.basename(url) or "repo.omi"
            print(f"Downloading {repo_name} from {self.settings['REPOS']}...")
            
            cmd = [
                self.settings["CURL"],
                "-f", "-o", repo_name,
                f"{self.settings['REPOS']}/?download={repo_name}"
            ]
            
            if subprocess.run(cmd, capture_output=True).returncode == 0:
                self._write_dotomi(repo_name)
                self.db_name = repo_name
                print(f"Cloned to {repo_name}")
            else:
                print("Error: Failed to clone from remote")
                sys.exit(1)
    
    def add_files(self, pattern="--all"):
        """Stage files for commit"""
        print("Adding files to staging...")
        
        if pattern == "--all":
            # Add all files in current directory
            for filename in os.listdir("."):
                if (os.path.isfile(filename) and 
                    filename != self.db_name and 
                    filename != ".omi"):
                    self._add_one_file(filename)
        else:
            self._add_one_file(pattern)
    
    def _add_one_file(self, filename):
        """Add a single file to staging"""
        if not os.path.isfile(filename):
            print(f"Error: File not found: {filename}")
            return False
        
        # Calculate SHA256 hash
        sha256_hash = hashlib.sha256()
        with open(filename, "rb") as f:
            sha256_hash.update(f.read())
        hash_value = sha256_hash.hexdigest()
        
        # Get current datetime
        datetime_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        # Add to staging
        conn = sqlite3.connect(self.db_name)
        cursor = conn.cursor()
        cursor.execute(
            "INSERT OR REPLACE INTO staging (filename, hash, datetime) VALUES (?, ?, ?)",
            (filename, hash_value, datetime_str)
        )
        conn.commit()
        conn.close()
        
        print(f"Staged: {filename} (hash: {hash_value})")
        return True
    
    def commit(self, message="No message"):
        """Create a commit from staged files"""
        print("Committing changes...")
        
        datetime_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        user = os.getenv("USER", "unknown")
        
        conn = sqlite3.connect(self.db_name)
        cursor = conn.cursor()
        
        # Create commit record
        cursor.execute(
            "INSERT INTO commits (message, datetime, user) VALUES (?, ?, ?)",
            (message, datetime_str, user)
        )
        commit_id = cursor.lastrowid
        
        # Get staged files
        cursor.execute("SELECT filename, hash, datetime FROM staging")
        staged_files = cursor.fetchall()
        
        # Process each staged file
        for filename, hash_value, file_datetime in staged_files:
            self._commit_one_file(cursor, filename, hash_value, file_datetime, commit_id)
        
        # Clear staging
        cursor.execute("DELETE FROM staging")
        
        conn.commit()
        conn.close()
        
        print(f"Committed successfully (commit #{commit_id})")
    
    def _commit_one_file(self, cursor, filename, hash_value, file_datetime, commit_id):
        """Add a single file to a commit"""
        # Check if blob exists (deduplication)
        cursor.execute("SELECT COUNT(*) FROM blobs WHERE hash=?", (hash_value,))
        blob_count = cursor.fetchone()[0]
        
        if blob_count == 0:
            # Store new blob
            with open(filename, "rb") as f:
                data = f.read()
            
            cursor.execute(
                "INSERT INTO blobs (hash, data, size) VALUES (?, ?, ?)",
                (hash_value, data, len(data))
            )
            print(f"  Stored new blob: {hash_value}")
        else:
            print(f"  Blob already exists (deduplicated): {hash_value}")
        
        # Add file record
        cursor.execute(
            "INSERT INTO files (filename, hash, datetime, commit_id) VALUES (?, ?, ?, ?)",
            (filename, hash_value, file_datetime, commit_id)
        )
    
    def _http_post_multipart(self, url, fields):
        """Upload files using multipart form data (urllib3 if available, else curl)"""
        use_internal = self.settings.get("USE_INTERNAL_HTTP", "1") == "1"
        
        if use_internal and URLLIB3_AVAILABLE:
            try:
                http = urllib3.PoolManager()
                response = http.request(
                    'POST',
                    url,
                    fields=fields,
                    timeout=float(self.settings.get("HTTP_TIMEOUT", "30"))
                )
                return response.status, response.data
            except Exception as e:
                print(f"Warning: Internal HTTP failed, falling back to curl: {e}")
                return self._http_post_multipart_curl(url, fields)
        else:
            return self._http_post_multipart_curl(url, fields)
    
    def _http_post_multipart_curl(self, url, fields):
        """Upload files using curl executable"""
        cmd = [self.settings["CURL"], "-f", "-X", "POST"]
        
        for key, value in fields.items():
            if isinstance(value, tuple) and len(value) == 2:
                # File upload
                cmd.extend(["-F", f"{key}=@{value[1]}"])
            else:
                # Regular form field
                cmd.extend(["-F", f"{key}={value}"])
        
        cmd.append(url)
        
        result = subprocess.run(cmd, capture_output=True)
        return result.returncode, result.stdout
    
    def push(self):
        """Upload repository to remote server"""
        print(f"Pushing {self.db_name} to remote...")
        
        if not os.path.isfile(self.db_name):
            print(f"Error: Database file {self.db_name} not found")
            sys.exit(1)
        
        if self.settings["API_ENABLED"] == "0":
            print("Error: API is disabled")
            sys.exit(1)
        
        otp_code = ""
        if self._has_2fa_enabled():
            otp_code = getpass.getpass("Enter OTP code (6 digits): ")
        
        # Build form fields
        fields = {
            'username': self.settings['USERNAME'],
            'password': self.settings['PASSWORD'],
            'repo_name': self.db_name,
            'repo_file': ('file', self.db_name),
            'action': 'Upload'
        }
        
        if otp_code:
            fields['otp_code'] = otp_code
        
        # Use internal or external HTTP based on settings
        use_internal = self.settings.get("USE_INTERNAL_HTTP", "1") == "1"
        
        if use_internal and URLLIB3_AVAILABLE:
            try:
                status, response = self._http_post_multipart(
                    f"{self.settings['REPOS']}/",
                    fields
                )
                if status == 200:
                    print(f"Successfully pushed to {self.settings['REPOS']}")
                else:
                    print(f"Error: Server returned status {status}")
                    sys.exit(1)
            except Exception as e:
                print(f"Error: Failed to push: {e}")
                sys.exit(1)
        else:
            # Fall back to curl
            cmd = [
                self.settings["CURL"],
                "-f", "-X", "POST",
                "-F", f"username={self.settings['USERNAME']}",
                "-F", f"password={self.settings['PASSWORD']}",
                "-F", f"repo_name={self.db_name}",
                "-F", f"repo_file=@{self.db_name}",
                "-F", "action=Upload"
            ]
            
            if otp_code:
                cmd.extend(["-F", f"otp_code={otp_code}"])
            
            cmd.append(f"{self.settings['REPOS']}/")
            
            result = subprocess.run(cmd, capture_output=True, text=True)
            
            if result.returncode == 0:
                print(f"Successfully pushed to {self.settings['REPOS']}")
            else:
                print("Error: Failed to push to remote")
                if result.stderr:
                    print(result.stderr)
                sys.exit(1)
    
    def pull(self):
        """Download repository from remote server"""
        print(f"Pulling {self.db_name} from remote...")
        
        if self.settings["API_ENABLED"] == "0":
            print("Error: API is disabled")
            sys.exit(1)
        
        otp_code = ""
        if self._has_2fa_enabled():
            otp_code = getpass.getpass("Enter OTP code (6 digits): ")
        
        use_internal = self.settings.get("USE_INTERNAL_HTTP", "1") == "1"
        
        if use_internal and URLLIB3_AVAILABLE:
            try:
                http = urllib3.PoolManager()
                fields = {
                    'username': self.settings['USERNAME'],
                    'password': self.settings['PASSWORD'],
                    'repo_name': self.db_name,
                    'action': 'pull'
                }
                if otp_code:
                    fields['otp_code'] = otp_code
                
                response = http.request(
                    'POST',
                    f"{self.settings['REPOS']}/",
                    fields=fields,
                    timeout=float(self.settings.get("HTTP_TIMEOUT", "30"))
                )
                
                if response.status == 200:
                    with open(self.db_name, "wb") as f:
                        f.write(response.data)
                    print(f"Successfully pulled from {self.settings['REPOS']}")
                else:
                    print(f"Error: Server returned status {response.status}")
                    sys.exit(1)
            except Exception as e:
                print(f"Error: Failed to pull: {e}")
                sys.exit(1)
        else:
            # Fall back to curl
            cmd = [
                self.settings["CURL"],
                "-f", "-X", "POST",
                "-d", f"username={self.settings['USERNAME']}",
                "-d", f"password={self.settings['PASSWORD']}",
                "-d", f"repo_name={self.db_name}",
                "-d", "action=pull"
            ]
            
            if otp_code:
                cmd.extend(["-d", f"otp_code={otp_code}"])
            
            cmd.append(f"{self.settings['REPOS']}/")
            
            result = subprocess.run(cmd, capture_output=True)
            
            if result.returncode == 0:
                # Write downloaded repository
                with open(self.db_name, "wb") as f:
                    f.write(result.stdout)
                print(f"Successfully pulled from {self.settings['REPOS']}")
            else:
                print("Error: Failed to pull from remote")
                if result.stderr:
                    print(result.stderr.decode())
                sys.exit(1)
    
    def list_repos(self):
        """List available repositories on remote server"""
        print(f"=== Available Repositories on {self.settings['REPOS']} ===")
        
        cmd = [
            self.settings["CURL"],
            "-s",
            f"{self.settings['REPOS']}/?format=json"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode == 0:
            # Extract repo names from JSON
            for match in re.finditer(r'"name":"([^"]*)"', result.stdout):
                print(match.group(1))
        else:
            print("Error: Failed to retrieve repository list")
            sys.exit(1)
    
    def show_status(self):
        """Show repository status"""
        print("=== Staged Files ===")
        self._execute_query("SELECT filename, datetime FROM staging")
        print("")
        
        print("=== Recent Commits ===")
        self._execute_query("SELECT id, message, datetime FROM commits ORDER BY id DESC LIMIT 5")
        print("")
        
        print("=== Statistics ===")
        result = self._execute_query("SELECT COUNT(*) FROM blobs", fetch_one=True)
        print(f"Total blobs (deduplicated): {result[0] if result else 0}")
        
        result = self._execute_query("SELECT COUNT(*) FROM files", fetch_one=True)
        print(f"Total file versions: {result[0] if result else 0}")
    
    def log_commits(self, limit=10):
        """Show commit history"""
        print("=== Commit History ===")
        query = f"SELECT id, datetime, user, message FROM commits ORDER BY id DESC LIMIT {limit}"
        self._execute_query(query)
    
    def _execute_query(self, query, fetch_one=False):
        """Execute a query and print results"""
        conn = sqlite3.connect(self.db_name)
        cursor = conn.cursor()
        cursor.execute(query)
        
        if fetch_one:
            return cursor.fetchone()
        
        rows = cursor.fetchall()
        for row in rows:
            print("|".join(str(col) for col in row))
        
        conn.close()
    
    def _has_2fa_enabled(self):
        """Check if user has 2FA enabled"""
        if not os.path.isfile("phpusers.txt"):
            return False
        
        username = self.settings.get("USERNAME", "")
        with open("phpusers.txt", "r") as f:
            for line in f:
                parts = line.strip().split(":")
                if len(parts) >= 3 and parts[0] == username and parts[2]:
                    return True
        
        return False


def main():
    """Main entry point"""
    settings = Settings.load()
    repo = OmiRepository(settings)
    
    if len(sys.argv) < 2:
        print("Usage: omi <command> [args]")
        print("Commands: init, clone, add, commit, push, pull, list, log, status")
        sys.exit(1)
    
    cmd = sys.argv[1]
    args = sys.argv[2:]
    
    try:
        if cmd == "init":
            db_name = args[0] if args else "repo.omi"
            repo.init(db_name)
        elif cmd == "clone":
            if not args:
                print("Usage: omi clone <url>")
                sys.exit(1)
            repo.clone(args[0])
        elif cmd == "add":
            pattern = args[0] if args else "--all"
            repo.add_files(pattern)
        elif cmd == "commit":
            message = "No message"
            # Parse -m "message"
            for i, arg in enumerate(args):
                if arg == "-m" and i + 1 < len(args):
                    message = args[i + 1]
                    break
            repo.commit(message)
        elif cmd == "push":
            repo.push()
        elif cmd == "pull":
            repo.pull()
        elif cmd == "list":
            repo.list_repos()
        elif cmd == "log":
            limit = int(args[0]) if args else 10
            repo.log_commits(limit)
        elif cmd == "status":
            repo.show_status()
        else:
            print(f"Unknown command: {cmd}")
            print("Usage: omi <command> [args]")
            print("Commands: init, clone, add, commit, push, pull, list, log, status")
            sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

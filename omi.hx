import sys.io.File;
import sys.FileSystem;
import sys.io.Process;
import haxe.crypto.Sha256;
import haxe.db.sqlite.Database;
import haxe.db.sqlite.Statement;
import Date;

/**
 * Omi - Version Control for Haxe 5
 * Optimized Micro Index - Git-like commands with SQLite storage
 */

class Settings {
    public var sqlite: String;
    public var curl: String;
    public var username: String;
    public var password: String;
    public var repos: String;
    public var api_enabled: String;
    public var api_rate_limit: String;
    public var api_rate_limit_window: String;

    public function new() {
        // Set defaults
        sqlite = "/usr/bin/sqlite3";
        curl = "/usr/bin/curl";
        username = "";
        password = "";
        repos = "http://localhost/omi";
        api_enabled = "1";
        api_rate_limit = "60";
        api_rate_limit_window = "60";
    }

    public static function load(): Settings {
        var settings = new Settings();
        
        if (!FileSystem.exists("settings.txt")) {
            Sys.println("Error: settings.txt not found");
            Sys.exit(1);
        }
        
        var content = File.getContent("settings.txt");
        var lines = content.split("\n");
        
        for (line in lines) {
            line = StringTools.trim(line);
            if (line.length == 0 || line.charAt(0) == "#") continue;
            
            var parts = line.split("=");
            if (parts.length == 2) {
                var key = StringTools.trim(parts[0]);
                var value = StringTools.trim(parts[1]);
                
                switch (key) {
                    case "SQLITE": settings.sqlite = value;
                    case "CURL": settings.curl = value;
                    case "USERNAME": settings.username = value;
                    case "PASSWORD": settings.password = value;
                    case "REPOS": settings.repos = value;
                    case "API_ENABLED": settings.api_enabled = value;
                    case "API_RATE_LIMIT": settings.api_rate_limit = value;
                    case "API_RATE_LIMIT_WINDOW": settings.api_rate_limit_window = value;
                }
            }
        }
        
        return settings;
    }
}

class OmiRepository {
    private var settings: Settings;
    private var db_name: String;

    public function new(settings: Settings) {
        this.settings = settings;
        this.db_name = readDotOmi() ?? "repo.omi";
    }

    private function readDotOmi(): String {
        if (FileSystem.exists(".omi")) {
            var content = File.getContent(".omi");
            var match = new EReg('OMI_DB="([^"]+)"', "");
            if (match.match(content)) {
                return match.matched(1);
            }
        }
        return null;
    }

    private function writeDotOmi(name: String): Void {
        File.saveContent(".omi", 'OMI_DB="$name"\n');
    }

    public function init(name: String = "repo.omi"): Void {
        Sys.println("Initializing omi repository...");
        this.db_name = name;
        writeDotOmi(name);
        
        var db = new Database(name);
        
        // Create tables
        db.request("CREATE TABLE IF NOT EXISTS blobs (
            hash TEXT PRIMARY KEY,
            data BLOB,
            size INTEGER
        )").execute();
        
        db.request("CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            filename TEXT,
            hash TEXT,
            datetime TEXT,
            commit_id INTEGER,
            FOREIGN KEY(commit_id) REFERENCES commits(id)
        )").execute();
        
        db.request("CREATE TABLE IF NOT EXISTS commits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message TEXT,
            datetime TEXT,
            user TEXT
        )").execute();
        
        db.request("CREATE TABLE IF NOT EXISTS staging (
            filename TEXT PRIMARY KEY,
            hash TEXT,
            datetime TEXT
        )").execute();
        
        db.request("CREATE INDEX IF NOT EXISTS idx_files_hash ON files(hash)").execute();
        db.request("CREATE INDEX IF NOT EXISTS idx_files_commit ON files(commit_id)").execute();
        db.request("CREATE INDEX IF NOT EXISTS idx_blobs_hash ON blobs(hash)").execute();
        
        db.close();
        Sys.println('Repository initialized: $name');
    }

    public function clone(url: String): Void {
        Sys.println('Cloning from $url...');
        
        if (FileSystem.exists(url) && FileSystem.isFile(url)) {
            // Local clone
            File.saveContent("repo.omi", File.getBytes(url));
            writeDotOmi("repo.omi");
            this.db_name = "repo.omi";
            Sys.println("Cloned to repo.omi");
        } else {
            // Remote clone
            var repo_name = url.split("/").pop() ?? "repo.omi";
            Sys.println('Downloading $repo_name from ${settings.repos}...');
            
            var cmd = '${settings.curl} -f -o "$repo_name" "${settings.repos}/?download=$repo_name"';
            var exit_code = Sys.command(cmd);
            
            if (exit_code == 0) {
                writeDotOmi(repo_name);
                this.db_name = repo_name;
                Sys.println('Cloned to $repo_name');
            } else {
                Sys.println("Error: Failed to clone from remote");
                Sys.exit(1);
            }
        }
    }

    public function addFiles(pattern: String = "--all"): Void {
        Sys.println("Adding files to staging...");
        
        if (pattern == "--all") {
            for (file in FileSystem.readDirectory(".")) {
                if (FileSystem.isFile(file) && file != db_name && file != ".omi") {
                    addOneFile(file);
                }
            }
        } else {
            addOneFile(pattern);
        }
    }

    private function addOneFile(filename: String): Void {
        if (!FileSystem.exists(filename) || !FileSystem.isFile(filename)) {
            Sys.println('Error: File not found: $filename');
            return;
        }
        
        // Calculate SHA256 hash
        var bytes = File.getBytes(filename);
        var hash = Sha256.encode(bytes.toString()).toLowerCase();
        
        // Get current datetime
        var datetime = getDateTime();
        
        // Add to staging
        var db = new Database(db_name);
        db.request("INSERT OR REPLACE INTO staging (filename, hash, datetime) VALUES (?, ?, ?)")
            .bind(filename).bind(hash).bind(datetime).execute();
        db.close();
        
        Sys.println('Staged: $filename (hash: $hash)');
    }

    public function commit(message: String = "No message"): Void {
        Sys.println("Committing changes...");
        
        var datetime = getDateTime();
        var user = Sys.getEnv("USER") ?? "unknown";
        
        var db = new Database(db_name);
        
        // Create commit
        db.request("INSERT INTO commits (message, datetime, user) VALUES (?, ?, ?)")
            .bind(message).bind(datetime).bind(user).execute();
        
        // Get commit ID
        var commit_id_result = db.request("SELECT last_insert_rowid() as id").results();
        var commit_id = 1;
        for (row in commit_id_result) {
            commit_id = row.id;
        }
        
        // Get staged files
        var staged = db.request("SELECT filename, hash, datetime FROM staging").results();
        
        for (row in staged) {
            commitOneFile(db, row.filename, row.hash, row.datetime, commit_id);
        }
        
        // Clear staging
        db.request("DELETE FROM staging").execute();
        
        db.close();
        
        Sys.println('Committed successfully (commit #$commit_id)');
    }

    private function commitOneFile(db: Database, filename: String, hash: String, 
                                    file_datetime: String, commit_id: Int): Void {
        // Check if blob exists
        var blob_count_result = db.request("SELECT COUNT(*) as count FROM blobs WHERE hash = ?")
            .bind(hash).results();
        var blob_count = 0;
        for (row in blob_count_result) {
            blob_count = row.count;
        }
        
        if (blob_count == 0) {
            // Store new blob
            var data = File.getBytes(filename);
            db.request("INSERT INTO blobs (hash, data, size) VALUES (?, ?, ?)")
                .bind(hash).bind(data).bind(data.length).execute();
            Sys.println('  Stored new blob: $hash');
        } else {
            Sys.println('  Blob already exists (deduplicated): $hash');
        }
        
        // Add file record
        db.request("INSERT INTO files (filename, hash, datetime, commit_id) VALUES (?, ?, ?, ?)")
            .bind(filename).bind(hash).bind(file_datetime).bind(commit_id).execute();
    }

    public function push(): Void {
        Sys.println('Pushing $db_name to remote...');
        
        if (!FileSystem.exists(db_name)) {
            Sys.println('Error: Database file $db_name not found');
            Sys.exit(1);
        }
        
        if (settings.api_enabled == "0") {
            Sys.println("Error: API is disabled");
            Sys.exit(1);
        }
        
        var otp_code = "";
        if (has2FAEnabled()) {
            Sys.print("Enter OTP code (6 digits): ");
            otp_code = Sys.stdin().readLine();
        }
        
        var otp_param = otp_code != "" ? ' -F "otp_code=$otp_code"' : "";
        var cmd = '${settings.curl} -f -X POST '
            + ' -F "username=${settings.username}"'
            + ' -F "password=${settings.password}"'
            + ' -F "repo_name=$db_name"'
            + ' -F "repo_file=@$db_name"'
            + ' -F "action=Upload"'
            + otp_param
            + ' "${settings.repos}/"';
        
        if (Sys.command(cmd) == 0) {
            Sys.println('Successfully pushed to ${settings.repos}');
        } else {
            Sys.println("Error: Failed to push to remote");
            Sys.exit(1);
        }
    }

    public function pull(): Void {
        Sys.println('Pulling $db_name from remote...');
        
        if (settings.api_enabled == "0") {
            Sys.println("Error: API is disabled");
            Sys.exit(1);
        }
        
        var otp_code = "";
        if (has2FAEnabled()) {
            Sys.print("Enter OTP code (6 digits): ");
            otp_code = Sys.stdin().readLine();
        }
        
        var otp_param = otp_code != "" ? ' -d "otp_code=$otp_code"' : "";
        var cmd = '${settings.curl} -f -X POST '
            + ' -d "username=${settings.username}"'
            + ' -d "password=${settings.password}"'
            + ' -d "repo_name=$db_name"'
            + ' -d "action=pull"'
            + otp_param
            + ' -o /tmp/omi_pull.tmp'
            + ' "${settings.repos}/"';
        
        if (Sys.command(cmd) == 0) {
            FileSystem.rename("/tmp/omi_pull.tmp", db_name);
            Sys.println('Successfully pulled from ${settings.repos}');
        } else {
            Sys.println("Error: Failed to pull from remote");
            Sys.exit(1);
        }
    }

    public function listRepos(): Void {
        Sys.println('=== Available Repositories on ${settings.repos} ===');
        
        var cmd = '${settings.curl} -s "${settings.repos}/?format=json" | grep -o \'"name":"[^"]*"\' | cut -d\'\"\' -f4';
        Sys.command(cmd);
    }

    public function showStatus(): Void {
        Sys.println("=== Staged Files ===");
        executeQuery("SELECT filename, datetime FROM staging");
        Sys.println("");
        
        Sys.println("=== Recent Commits ===");
        executeQuery("SELECT id, message, datetime FROM commits ORDER BY id DESC LIMIT 5");
        Sys.println("");
        
        Sys.println("=== Statistics ===");
        var db = new Database(db_name);
        var blob_result = db.request("SELECT COUNT(*) as count FROM blobs").results();
        for (row in blob_result) {
            Sys.println('Total blobs (deduplicated): ${row.count}');
        }
        var file_result = db.request("SELECT COUNT(*) as count FROM files").results();
        for (row in file_result) {
            Sys.println('Total file versions: ${row.count}');
        }
        db.close();
    }

    public function logCommits(limit: Int = 10): Void {
        Sys.println("=== Commit History ===");
        executeQuery('SELECT id, datetime, user, message FROM commits ORDER BY id DESC LIMIT $limit');
    }

    private function executeQuery(query: String): Void {
        var db = new Database(db_name);
        var results = db.request(query).results();
        
        for (row in results) {
            var values = [];
            for (field in Reflect.fields(row)) {
                values.push(Std.string(Reflect.field(row, field)));
            }
            Sys.println(values.join("|"));
        }
        
        db.close();
    }

    private function has2FAEnabled(): Bool {
        if (!FileSystem.exists("phpusers.txt")) {
            return false;
        }
        
        var content = File.getContent("phpusers.txt");
        var lines = content.split("\n");
        
        for (line in lines) {
            var parts = line.split(":");
            if (parts.length >= 3 && parts[0] == settings.username && parts[2] != "") {
                return true;
            }
        }
        
        return false;
    }

    private function getDateTime(): String {
        var date = Date.now();
        var year = date.getFullYear();
        var month = date.getMonth() + 1;
        var day = date.getDate();
        var hours = date.getHours();
        var minutes = date.getMinutes();
        var seconds = date.getSeconds();
        
        return Std.string(year).lPad("0", 4) + "-" +
               Std.string(month).lPad("0", 2) + "-" +
               Std.string(day).lPad("0", 2) + " " +
               Std.string(hours).lPad("0", 2) + ":" +
               Std.string(minutes).lPad("0", 2) + ":" +
               Std.string(seconds).lPad("0", 2);
    }
}

class Omi {
    public static function main(): Void {
        var settings = Settings.load();
        var repo = new OmiRepository(settings);
        
        var args = Sys.args();
        
        if (args.length == 0) {
            Sys.println("Usage: omi <command> [args]");
            Sys.println("Commands: init, clone, add, commit, push, pull, list, log, status");
            Sys.exit(1);
        }
        
        var cmd = args[0];
        var cmd_args = args.slice(1);
        
        try {
            switch (cmd) {
                case "init":
                    var db_name = cmd_args.length > 0 ? cmd_args[0] : "repo.omi";
                    repo.init(db_name);
                    
                case "clone":
                    if (cmd_args.length == 0) {
                        Sys.println("Usage: omi clone <url>");
                        Sys.exit(1);
                    }
                    repo.clone(cmd_args[0]);
                    
                case "add":
                    var pattern = cmd_args.length > 0 ? cmd_args[0] : "--all";
                    repo.addFiles(pattern);
                    
                case "commit":
                    var message = "No message";
                    for (i in 0...cmd_args.length) {
                        if (cmd_args[i] == "-m" && i + 1 < cmd_args.length) {
                            message = cmd_args[i + 1];
                            break;
                        }
                    }
                    repo.commit(message);
                    
                case "push":
                    repo.push();
                    
                case "pull":
                    repo.pull();
                    
                case "list":
                    repo.listRepos();
                    
                case "log":
                    var limit = cmd_args.length > 0 ? Std.parseInt(cmd_args[0]) : 10;
                    repo.logCommits(limit);
                    
                case "status":
                    repo.showStatus();
                    
                default:
                    Sys.println('Unknown command: $cmd');
                    Sys.println("Usage: omi <command> [args]");
                    Sys.println("Commands: init, clone, add, commit, push, pull, list, log, status");
                    Sys.exit(1);
            }
        } catch (e: Dynamic) {
            Sys.println('Error: $e');
            Sys.exit(1);
        }
    }
}

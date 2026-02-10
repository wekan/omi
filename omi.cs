using System;
using System.IO;
using System.Data;
using System.Data.SQLite;
using System.Text;
using System.Security.Cryptography;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;

class Settings
{
    public string ServerUrl { get; set; }
    public string ApiKey { get; set; }
    public string OTPSecret { get; set; }
    public string LocalRepoPath { get; set; }
    public string Username { get; set; }
    public string Password { get; set; }
    public string Repos { get; set; }
    public bool UseInternalHttp { get; set; } = true;
    public int HttpTimeout { get; set; } = 30;

    public void LoadFromFile(string path)
    {
        if (!File.Exists(path)) return;
        
        var lines = File.ReadAllLines(path);
        foreach (var line in lines)
        {
            var trimmedLine = line.Trim();
            if (trimmedLine.StartsWith("#")) continue;
            
            if (trimmedLine.StartsWith("SERVER_URL="))
                ServerUrl = trimmedLine.Substring("SERVER_URL=".Length);
            else if (trimmedLine.StartsWith("API_KEY="))
                ApiKey = trimmedLine.Substring("API_KEY=".Length);
            else if (trimmedLine.StartsWith("OTP_SECRET="))
                OTPSecret = trimmedLine.Substring("OTP_SECRET=".Length);
            else if (trimmedLine.StartsWith("LOCAL_REPO_PATH="))
                LocalRepoPath = trimmedLine.Substring("LOCAL_REPO_PATH=".Length);
            else if (trimmedLine.StartsWith("USERNAME="))
                Username = trimmedLine.Substring("USERNAME=".Length);
            else if (trimmedLine.StartsWith("PASSWORD="))
                Password = trimmedLine.Substring("PASSWORD=".Length);
            else if (trimmedLine.StartsWith("REPOS="))
                Repos = trimmedLine.Substring("REPOS=".Length);
            else if (trimmedLine.StartsWith("USE_INTERNAL_HTTP="))
                UseInternalHttp = trimmedLine.Substring("USE_INTERNAL_HTTP=".Length) == "1";
            else if (trimmedLine.StartsWith("HTTP_TIMEOUT="))
                HttpTimeout = int.Parse(trimmedLine.Substring("HTTP_TIMEOUT=".Length));
        }
    }
}

class OmiRepository
{
    private Settings settings;
    private string dbPath;

    public OmiRepository(Settings settings, string dbPath)
    {
        this.settings = settings;
        this.dbPath = dbPath;
    }

    public void Init()
    {
        if (File.Exists(dbPath))
        {
            Console.WriteLine("Repository already initialized");
            return;
        }

        using (var connection = new SQLiteConnection($"Data Source={dbPath}"))
        {
            connection.Open();
            using (var cmd = connection.CreateCommand())
            {
                cmd.CommandText = @"
                    CREATE TABLE blobs (sha256 TEXT PRIMARY KEY, data BLOB);
                    CREATE TABLE files (path TEXT PRIMARY KEY, sha256 TEXT, modified DATETIME);
                    CREATE TABLE commits (hash TEXT PRIMARY KEY, message TEXT, files TEXT, timestamp DATETIME);
                    CREATE TABLE staging (path TEXT PRIMARY KEY, sha256 TEXT);
                ";
                cmd.ExecuteNonQuery();
            }
        }

        Console.WriteLine("Repository initialized");
    }

    public void AddFile(string filePath)
    {
        if (!File.Exists(filePath))
        {
            Console.WriteLine($"File not found: {filePath}");
            return;
        }

        var fileData = File.ReadAllBytes(filePath);
        var sha256 = ComputeSHA256(fileData);

        using (var connection = new SQLiteConnection($"Data Source={dbPath}"))
        {
            connection.Open();

            // Add blob
            using (var cmd = connection.CreateCommand())
            {
                cmd.CommandText = "INSERT OR IGNORE INTO blobs (sha256, data) VALUES (@sha, @data)";
                cmd.Parameters.AddWithValue("@sha", sha256);
                cmd.Parameters.AddWithValue("@data", fileData);
                cmd.ExecuteNonQuery();
            }

            // Add to staging
            using (var cmd = connection.CreateCommand())
            {
                cmd.CommandText = "INSERT OR REPLACE INTO staging (path, sha256) VALUES (@path, @sha)";
                cmd.Parameters.AddWithValue("@path", filePath);
                cmd.Parameters.AddWithValue("@sha", sha256);
                cmd.ExecuteNonQuery();
            }
        }

        Console.WriteLine($"Added: {filePath}");
    }

    public void Commit(string message)
    {
        using (var connection = new SQLiteConnection($"Data Source={dbPath}"))
        {
            connection.Open();

            // Get staged files
            var stagedFiles = new Dictionary<string, string>();
            using (var cmd = connection.CreateCommand())
            {
                cmd.CommandText = "SELECT path, sha256 FROM staging";
                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        stagedFiles[reader.GetString(0)] = reader.GetString(1);
                    }
                }
            }

            if (stagedFiles.Count == 0)
            {
                Console.WriteLine("Nothing to commit");
                return;
            }

            // Create commit
            var timestamp = DateTime.UtcNow;
            var commitHash = ComputeSHA256(Encoding.UTF8.GetBytes(
                message + timestamp.Ticks.ToString())).Substring(0, 8);

            var filesList = string.Join(",", stagedFiles.Keys);

            using (var cmd = connection.CreateCommand())
            {
                cmd.CommandText = "INSERT INTO commits (hash, message, files, timestamp) VALUES (@hash, @msg, @files, @ts)";
                cmd.Parameters.AddWithValue("@hash", commitHash);
                cmd.Parameters.AddWithValue("@msg", message);
                cmd.Parameters.AddWithValue("@files", filesList);
                cmd.Parameters.AddWithValue("@ts", timestamp);
                cmd.ExecuteNonQuery();
            }

            // Update files table
            foreach (var kvp in stagedFiles)
            {
                using (var cmd = connection.CreateCommand())
                {
                    cmd.CommandText = "INSERT OR REPLACE INTO files (path, sha256, modified) VALUES (@path, @sha, @ts)";
                    cmd.Parameters.AddWithValue("@path", kvp.Key);
                    cmd.Parameters.AddWithValue("@sha", kvp.Value);
                    cmd.Parameters.AddWithValue("@ts", timestamp);
                    cmd.ExecuteNonQuery();
                }
            }

            // Clear staging
            using (var cmd = connection.CreateCommand())
            {
                cmd.CommandText = "DELETE FROM staging";
                cmd.ExecuteNonQuery();
            }

            Console.WriteLine($"Committed: {commitHash}");
        }
    }

    public void Push(string otpCode)
    {
        if (string.IsNullOrEmpty(settings.Repos))
        {
            Console.WriteLine("Server URL not configured");
            return;
        }

        if (!ValidateOTP(otpCode))
        {
            Console.WriteLine("Invalid OTP code");
            return;
        }

        if (!File.Exists(dbPath))
        {
            Console.WriteLine($"Error: Database file {dbPath} not found");
            return;
        }

        if (settings.UseInternalHttp)
        {
            try
            {
                PushWithHttpClient(otpCode);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Internal HTTP failed: {ex.Message}, falling back to curl");
                PushWithCurl(otpCode);
            }
        }
        else
        {
            PushWithCurl(otpCode);
        }
    }

    private void PushWithHttpClient(string otpCode)
    {
        using (var client = new HttpClient())
        {
            client.Timeout = TimeSpan.FromSeconds(settings.HttpTimeout);

            using (var form = new MultipartFormDataContent())
            {
                form.Add(new StringContent(settings.Username), "username");
                form.Add(new StringContent(settings.Password), "password");
                form.Add(new StringContent(dbPath), "repo_name");
                form.Add(new StringContent("Upload"), "action");
                
                if (!string.IsNullOrEmpty(otpCode))
                    form.Add(new StringContent(otpCode), "otp_code");

                using (var fs = File.OpenRead(dbPath))
                {
                    form.Add(new StreamContent(fs), "repo_file", Path.GetFileName(dbPath));
                    
                    var response = client.PostAsync(settings.Repos + "/", form).Result;
                    
                    if (response.IsSuccessStatusCode)
                    {
                        Console.WriteLine($"Successfully pushed to {settings.Repos}");
                    }
                    else
                    {
                        Console.WriteLine($"Error: Server returned {response.StatusCode}");
                    }
                }
            }
        }
    }

    private void PushWithCurl(string otpCode)
    {
        var cmd = new List<string>
        {
            "curl", "-f", "-X", "POST",
            "-F", $"username={settings.Username}",
            "-F", $"password={settings.Password}",
            "-F", $"repo_name={dbPath}",
            "-F", $"repo_file=@{dbPath}",
            "-F", "action=Upload"
        };

        if (!string.IsNullOrEmpty(otpCode))
            cmd.AddRange(new[] { "-F", $"otp_code={otpCode}" });

        cmd.Add(settings.Repos + "/");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "curl",
                Arguments = string.Join(" ", cmd.Skip(1)),
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            }
        };

        process.Start();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();

        if (process.ExitCode == 0)
        {
            Console.WriteLine($"Successfully pushed to {settings.Repos}");
        }
        else
        {
            Console.WriteLine("Error: Failed to push to remote");
            if (!string.IsNullOrEmpty(error))
                Console.WriteLine(error);
        }
    }

    public void Pull(string otpCode)
    {
        if (string.IsNullOrEmpty(settings.Repos))
        {
            Console.WriteLine("Server URL not configured");
            return;
        }

        if (!ValidateOTP(otpCode))
        {
            Console.WriteLine("Invalid OTP code");
            return;
        }

        if (settings.UseInternalHttp)
        {
            try
            {
                PullWithHttpClient(otpCode);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Internal HTTP failed: {ex.Message}, falling back to curl");
                PullWithCurl(otpCode);
            }
        }
        else
        {
            PullWithCurl(otpCode);
        }
    }

    private void PullWithHttpClient(string otpCode)
    {
        using (var client = new HttpClient())
        {
            client.Timeout = TimeSpan.FromSeconds(settings.HttpTimeout);

            var form = new Dictionary<string, string>
            {
                { "username", settings.Username },
                { "password", settings.Password },
                { "repo_name", dbPath },
                { "action", "pull" }
            };

            if (!string.IsNullOrEmpty(otpCode))
                form["otp_code"] = otpCode;

            var content = new FormUrlEncodedContent(form);
            var response = client.PostAsync(settings.Repos + "/", content).Result;

            if (response.IsSuccessStatusCode)
            {
                var bytes = response.Content.ReadAsByteArrayAsync().Result;
                File.WriteAllBytes(dbPath, bytes);
                Console.WriteLine($"Successfully pulled from {settings.Repos}");
            }
            else
            {
                Console.WriteLine($"Error: Server returned {response.StatusCode}");
            }
        }
    }

    private void PullWithCurl(string otpCode)
    {
        var cmd = new List<string>
        {
            "curl", "-f", "-X", "POST",
            "-d", $"username={settings.Username}",
            "-d", $"password={settings.Password}",
            "-d", $"repo_name={dbPath}",
            "-d", "action=pull"
        };

        if (!string.IsNullOrEmpty(otpCode))
            cmd.AddRange(new[] { "-d", $"otp_code={otpCode}" });

        cmd.Add(settings.Repos + "/");

        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "curl",
                Arguments = string.Join(" ", cmd.Skip(1)),
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            }
        };

        process.Start();
        var output = process.StandardOutput.BaseStream;
        var error = process.StandardError.ReadToEnd();
        
        if (process.WaitForExit(settings.HttpTimeout * 1000))
        {
            if (process.ExitCode == 0)
            {
                using (var fs = File.OpenWrite(dbPath))
                {
                    output.CopyTo(fs);
                }
                Console.WriteLine($"Successfully pulled from {settings.Repos}");
            }
            else
            {
                Console.WriteLine("Error: Failed to pull from remote");
                if (!string.IsNullOrEmpty(error))
                    Console.WriteLine(error);
            }
        }
    }

    public void ListRepositories()
    {
        Console.WriteLine("Repositories:");
        if (File.Exists(dbPath))
            Console.WriteLine($"  {Path.GetFileName(dbPath)}");
    }

    public void ShowStatus()
    {
        if (!File.Exists(dbPath))
        {
            Console.WriteLine("Repository not initialized");
            return;
        }

        using (var connection = new SQLiteConnection($"Data Source={dbPath}"))
        {
            connection.Open();

            Console.WriteLine("Staged files:");
            using (var cmd = connection.CreateCommand())
            {
                cmd.CommandText = "SELECT path FROM staging";
                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                        Console.WriteLine($"  {reader.GetString(0)}");
                }
            }
        }
    }

    public void ShowLog()
    {
        if (!File.Exists(dbPath))
        {
            Console.WriteLine("Repository not initialized");
            return;
        }

        using (var connection = new SQLiteConnection($"Data Source={dbPath}"))
        {
            connection.Open();

            using (var cmd = connection.CreateCommand())
            {
                cmd.CommandText = "SELECT hash, message, timestamp FROM commits ORDER BY timestamp DESC";
                using (var reader = cmd.ExecuteReader())
                {
                    while (reader.Read())
                    {
                        Console.WriteLine($"[{reader.GetString(0)}] {reader.GetString(1)} ({reader.GetDateTime(2)})");
                    }
                }
            }
        }
    }

    private string ComputeSHA256(byte[] data)
    {
        using (var sha256 = SHA256.Create())
        {
            var hash = sha256.ComputeHash(data);
            var sb = new StringBuilder();
            foreach (var b in hash)
                sb.Append(b.ToString("x2"));
            return sb.ToString();
        }
    }

    private bool ValidateOTP(string code)
    {
        if (string.IsNullOrEmpty(settings.OTPSecret))
            return true;

        if (string.IsNullOrEmpty(code))
            return false;

        long timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 30;
        var expectedCode = GenerateTOTP(settings.OTPSecret, timestamp);

        return code == expectedCode;
    }

    private string GenerateTOTP(string secret, long timestamp)
    {
        var key = Encoding.UTF8.GetBytes(secret);
        var msg = BitConverter.GetBytes(timestamp);
        if (BitConverter.IsLittleEndian)
            Array.Reverse(msg);

        using (var hmac = new HMACSHA1(key))
        {
            var hash = hmac.ComputeHash(msg);
            int offset = hash[hash.Length - 1] & 0xf;
            int code = (hash[offset] & 0x7f) << 24 |
                       (hash[offset + 1] & 0xff) << 16 |
                       (hash[offset + 2] & 0xff) << 8 |
                       (hash[offset + 3] & 0xff);
            return (code % 1000000).ToString("D6");
        }
    }

    public void Clone(string remoteUrl)
    {
        Console.WriteLine($"Cloning from {remoteUrl}");
        // Simplified clone - would pull repo from remote in production
        Init();
    }
}

class Omi
{
    static void Main(string[] args)
    {
        if (args.Length == 0)
        {
            PrintHelp();
            return;
        }

        var settings = new Settings();
        settings.LoadFromFile("settings.txt");

        var dbPath = settings.LocalRepoPath ?? "repo.omi";
        var repo = new OmiRepository(settings, dbPath);

        var command = args[0].ToLower();

        try
        {
            switch (command)
            {
                case "init":
                    repo.Init();
                    break;

                case "add":
                    if (args.Length < 2)
                    {
                        Console.WriteLine("Usage: omi add <file>");
                        return;
                    }
                    if (args[1] == "--all")
                    {
                        var files = Directory.GetFiles(".", "*", SearchOption.AllDirectories);
                        foreach (var f in files)
                        {
                            if (!f.Contains(".omi"))
                                repo.AddFile(f);
                        }
                    }
                    else
                    {
                        repo.AddFile(args[1]);
                    }
                    break;

                case "commit":
                    if (args.Length < 3 || args[1] != "-m")
                    {
                        Console.WriteLine("Usage: omi commit -m \"message\"");
                        return;
                    }
                    repo.Commit(args[2]);
                    break;

                case "push":
                    Console.Write("OTP code: ");
                    var otpPush = ReadOTP();
                    repo.Push(otpPush);
                    break;

                case "pull":
                    Console.Write("OTP code: ");
                    var otpPull = ReadOTP();
                    repo.Pull(otpPull);
                    break;

                case "list":
                    repo.ListRepositories();
                    break;

                case "status":
                    repo.ShowStatus();
                    break;

                case "log":
                    repo.ShowLog();
                    break;

                case "clone":
                    if (args.Length < 2)
                    {
                        Console.WriteLine("Usage: omi clone <url>");
                        return;
                    }
                    repo.Clone(args[1]);
                    break;

                default:
                    Console.WriteLine($"Unknown command: {command}");
                    PrintHelp();
                    break;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error: {ex.Message}");
        }
    }

    static void PrintHelp()
    {
        Console.WriteLine(@"
Omi - Git-like version control for retro and modern systems

Usage: omi <command> [options]

Commands:
  init              Initialize a new repository
  add <file>        Stage a file for commit
  add --all         Stage all files
  commit -m <msg>   Create a commit with message
  push              Push to remote repository (requires OTP)
  pull              Pull from remote repository (requires OTP)
  clone <url>       Clone a remote repository
  list              List all repositories
  status            Show repository status
  log               Show commit history

Configuration: Edit settings.txt to configure server URL and API key

Examples:
  omi init
  omi add file.txt
  omi commit -m ""First commit""
  omi log
");
    }

    static string ReadOTP()
    {
        var sb = new StringBuilder();
        while (true)
        {
            var key = Console.ReadKey(true);
            if (key.Key == ConsoleKey.Enter)
                break;
            if (key.Key == ConsoleKey.Backspace && sb.Length > 0)
                sb.Length--;
            else if (char.IsDigit(key.KeyChar))
                sb.Append(key.KeyChar);
        }
        Console.WriteLine();
        return sb.ToString();
    }
}

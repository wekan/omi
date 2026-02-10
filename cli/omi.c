/*
 * Omi - C89 CLI implementation
 * Cross-platform (AmigaOS, Windows, macOS, BSD, Linux)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

#include <sqlite3.h>

#if defined(_WIN32) || defined(_WIN64)
#define OMI_WINDOWS 1
#include <windows.h>
#include <direct.h>
#else
#define OMI_POSIX 1
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

#ifdef AMIGA
#define OMI_AMIGA 1
#endif

#ifdef USE_LIBCURL
#include <curl/curl.h>
#endif

#define MAX_LINE 1024
#define MAX_PATH_LEN 512
#define MAX_SMALL 128

typedef unsigned int u32;
typedef unsigned char u8;

typedef struct Settings {
    char username[MAX_SMALL];
    char password[MAX_SMALL];
    char repos[MAX_PATH_LEN];
    char curl[MAX_SMALL];
    char api_enabled[MAX_SMALL];
    int use_internal_http;
    int http_timeout;
} Settings;

static void settings_init(Settings *s) {
    memset(s, 0, sizeof(Settings));
    strcpy(s->curl, "curl");
    strcpy(s->api_enabled, "1");
    s->use_internal_http = 1;
    s->http_timeout = 30;
}

static void settings_load(Settings *s, const char *path) {
    FILE *f = fopen(path, "r");
    char line[MAX_LINE];

    if (!f) {
        return;
    }

    while (fgets(line, sizeof(line), f)) {
        char *eq;
        char *key;
        char *value;

        if (line[0] == '#') {
            continue;
        }

        eq = strchr(line, '=');
        if (!eq) {
            continue;
        }

        *eq = '\0';
        key = line;
        value = eq + 1;

        while (*value && (*value == ' ' || *value == '\t')) value++;
        value[strcspn(value, "\r\n")] = '\0';

        if (strcmp(key, "USERNAME") == 0) {
            strncpy(s->username, value, MAX_SMALL - 1);
        } else if (strcmp(key, "PASSWORD") == 0) {
            strncpy(s->password, value, MAX_SMALL - 1);
        } else if (strcmp(key, "REPOS") == 0) {
            strncpy(s->repos, value, MAX_PATH_LEN - 1);
        } else if (strcmp(key, "CURL") == 0) {
            strncpy(s->curl, value, MAX_SMALL - 1);
        } else if (strcmp(key, "API_ENABLED") == 0) {
            strncpy(s->api_enabled, value, MAX_SMALL - 1);
        } else if (strcmp(key, "USE_INTERNAL_HTTP") == 0) {
            s->use_internal_http = (strcmp(value, "1") == 0);
        } else if (strcmp(key, "HTTP_TIMEOUT") == 0) {
            s->http_timeout = atoi(value);
        }
    }

    fclose(f);
}

static int file_exists(const char *path) {
    FILE *f = fopen(path, "rb");
    if (f) {
        fclose(f);
        return 1;
    }
    return 0;
}

static void write_dotomi(const char *db_name) {
    FILE *f = fopen(".omi", "w");
    if (!f) return;
    fprintf(f, "OMI_DB=\"%s\"\n", db_name);
    fclose(f);
}

static void read_dotomi(char *out_db, size_t out_len) {
    FILE *f = fopen(".omi", "r");
    char line[MAX_LINE];

    if (!f) {
        strncpy(out_db, "repo.omi", out_len - 1);
        return;
    }

    while (fgets(line, sizeof(line), f)) {
        char *start = strstr(line, "OMI_DB=\"");
        if (start) {
            start += strlen("OMI_DB=\"");
            start[strcspn(start, "\"\r\n")] = '\0';
            strncpy(out_db, start, out_len - 1);
            fclose(f);
            return;
        }
    }

    fclose(f);
    strncpy(out_db, "repo.omi", out_len - 1);
}

/* SHA256 implementation (C89) */

typedef struct {
    u32 state[8];
    u32 bitlen[2];
    u8 data[64];
    u32 datalen;
} SHA256_CTX;

static u32 sha_rotr(u32 a, u32 b) { return ((a >> b) | (a << (32 - b))); }
static u32 sha_ch(u32 x, u32 y, u32 z) { return (x & y) ^ (~x & z); }
static u32 sha_maj(u32 x, u32 y, u32 z) { return (x & y) ^ (x & z) ^ (y & z); }
static u32 sha_ep0(u32 x) { return sha_rotr(x, 2) ^ sha_rotr(x, 13) ^ sha_rotr(x, 22); }
static u32 sha_ep1(u32 x) { return sha_rotr(x, 6) ^ sha_rotr(x, 11) ^ sha_rotr(x, 25); }
static u32 sha_sig0(u32 x) { return sha_rotr(x, 7) ^ sha_rotr(x, 18) ^ (x >> 3); }
static u32 sha_sig1(u32 x) { return sha_rotr(x, 17) ^ sha_rotr(x, 19) ^ (x >> 10); }

static const u32 sha_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static void sha256_transform(SHA256_CTX *ctx, const u8 data[]) {
    u32 a, b, c, d, e, f, g, h, i, t1, t2, m[64];

    for (i = 0; i < 16; ++i) {
        m[i] = (data[i * 4] << 24) | (data[i * 4 + 1] << 16)
             | (data[i * 4 + 2] << 8) | (data[i * 4 + 3]);
    }
    for (i = 16; i < 64; ++i) {
        m[i] = sha_sig1(m[i - 2]) + m[i - 7] + sha_sig0(m[i - 15]) + m[i - 16];
    }

    a = ctx->state[0];
    b = ctx->state[1];
    c = ctx->state[2];
    d = ctx->state[3];
    e = ctx->state[4];
    f = ctx->state[5];
    g = ctx->state[6];
    h = ctx->state[7];

    for (i = 0; i < 64; ++i) {
        t1 = h + sha_ep1(e) + sha_ch(e, f, g) + sha_k[i] + m[i];
        t2 = sha_ep0(a) + sha_maj(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }

    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
    ctx->state[5] += f;
    ctx->state[6] += g;
    ctx->state[7] += h;
}

static void sha256_init(SHA256_CTX *ctx) {
    ctx->datalen = 0;
    ctx->bitlen[0] = 0;
    ctx->bitlen[1] = 0;
    ctx->state[0] = 0x6a09e667;
    ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372;
    ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f;
    ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab;
    ctx->state[7] = 0x5be0cd19;
}

static void sha256_update(SHA256_CTX *ctx, const u8 data[], size_t len) {
    size_t i;
    for (i = 0; i < len; ++i) {
        ctx->data[ctx->datalen] = data[i];
        ctx->datalen++;
        if (ctx->datalen == 64) {
            sha256_transform(ctx, ctx->data);
            if (ctx->bitlen[0] > 0xffffffff - 512) {
                ctx->bitlen[1]++;
            }
            ctx->bitlen[0] += 512;
            ctx->datalen = 0;
        }
    }
}

static void sha256_final(SHA256_CTX *ctx, u8 hash[]) {
    u32 i = ctx->datalen;
    u32 bitlen_low;
    u32 bitlen_high;

    if (ctx->datalen < 56) {
        ctx->data[i++] = 0x80;
        while (i < 56) ctx->data[i++] = 0x00;
    } else {
        ctx->data[i++] = 0x80;
        while (i < 64) ctx->data[i++] = 0x00;
        sha256_transform(ctx, ctx->data);
        memset(ctx->data, 0, 56);
    }

    bitlen_high = ctx->bitlen[1];
    bitlen_low = ctx->bitlen[0] + ctx->datalen * 8;

    ctx->data[63] = (u8)(bitlen_low);
    ctx->data[62] = (u8)(bitlen_low >> 8);
    ctx->data[61] = (u8)(bitlen_low >> 16);
    ctx->data[60] = (u8)(bitlen_low >> 24);
    ctx->data[59] = (u8)(bitlen_high);
    ctx->data[58] = (u8)(bitlen_high >> 8);
    ctx->data[57] = (u8)(bitlen_high >> 16);
    ctx->data[56] = (u8)(bitlen_high >> 24);

    sha256_transform(ctx, ctx->data);

    for (i = 0; i < 4; ++i) {
        hash[i]      = (u8)((ctx->state[0] >> (24 - i * 8)) & 0xff);
        hash[i + 4]  = (u8)((ctx->state[1] >> (24 - i * 8)) & 0xff);
        hash[i + 8]  = (u8)((ctx->state[2] >> (24 - i * 8)) & 0xff);
        hash[i + 12] = (u8)((ctx->state[3] >> (24 - i * 8)) & 0xff);
        hash[i + 16] = (u8)((ctx->state[4] >> (24 - i * 8)) & 0xff);
        hash[i + 20] = (u8)((ctx->state[5] >> (24 - i * 8)) & 0xff);
        hash[i + 24] = (u8)((ctx->state[6] >> (24 - i * 8)) & 0xff);
        hash[i + 28] = (u8)((ctx->state[7] >> (24 - i * 8)) & 0xff);
    }
}

static void sha256_hex(const u8 *data, size_t len, char *out_hex, size_t out_len) {
    u8 hash[32];
    SHA256_CTX ctx;
    size_t i;
    const char *hex = "0123456789abcdef";

    if (out_len < 65) return;

    sha256_init(&ctx);
    sha256_update(&ctx, data, len);
    sha256_final(&ctx, hash);

    for (i = 0; i < 32; ++i) {
        out_hex[i * 2] = hex[(hash[i] >> 4) & 0x0f];
        out_hex[i * 2 + 1] = hex[hash[i] & 0x0f];
    }
    out_hex[64] = '\0';
}

static int load_file(const char *path, u8 **out_data, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    long len;
    u8 *data;

    if (!f) return 0;

    fseek(f, 0, SEEK_END);
    len = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (len <= 0) {
        fclose(f);
        return 0;
    }

    data = (u8 *)malloc((size_t)len);
    if (!data) {
        fclose(f);
        return 0;
    }

    if (fread(data, 1, (size_t)len, f) != (size_t)len) {
        free(data);
        fclose(f);
        return 0;
    }

    fclose(f);
    *out_data = data;
    *out_len = (size_t)len;
    return 1;
}

static int has_2fa_enabled(const Settings *s) {
    FILE *f = fopen("users.txt", "r");
    char line[MAX_LINE];
    size_t user_len;

    if (!f) return 0;

    user_len = strlen(s->username);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, s->username, user_len) == 0 && line[user_len] == ':') {
            char *p = strchr(line, ':');
            if (!p) continue;
            p = strchr(p + 1, ':');
            if (p && *(p + 1) != '\n' && *(p + 1) != '\r' && *(p + 1) != '\0') {
                fclose(f);
                return 1;
            }
        }
    }

    fclose(f);
    return 0;
}

static void prompt_otp(char *out, size_t out_len) {
    printf("Enter OTP code (6 digits): ");
    if (fgets(out, (int)out_len, stdin)) {
        out[strcspn(out, "\r\n")] = '\0';
    }
}

static const char *basename_simple(const char *path) {
    const char *p = strrchr(path, '/');
#if defined(_WIN32) || defined(_WIN64)
    const char *p2 = strrchr(path, '\\');
    if (!p || (p2 && p2 > p)) p = p2;
#endif
    return p ? p + 1 : path;
}

static int init_db(const char *db_name) {
    sqlite3 *db;
    char *err = NULL;
    const char *sql =
        "CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, data BLOB, size INTEGER);"
        "CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, hash TEXT, datetime TEXT, commit_id INTEGER);"
        "CREATE TABLE IF NOT EXISTS commits (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT, datetime TEXT, user TEXT);"
        "CREATE TABLE IF NOT EXISTS staging (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, hash TEXT, datetime TEXT);";

    if (sqlite3_open(db_name, &db) != SQLITE_OK) {
        fprintf(stderr, "Error: Unable to open database %s\n", db_name);
        return 0;
    }

    if (sqlite3_exec(db, sql, 0, 0, &err) != SQLITE_OK) {
        fprintf(stderr, "Error: %s\n", err);
        sqlite3_free(err);
        sqlite3_close(db);
        return 0;
    }

    sqlite3_close(db);
    return 1;
}

static int add_file_to_db(const char *db_name, const char *filename) {
    sqlite3 *db;
    sqlite3_stmt *stmt;
    u8 *data = NULL;
    size_t data_len = 0;
    char hash_hex[65];
    time_t now = time(NULL);
    char dt[64];

    if (!load_file(filename, &data, &data_len)) {
        fprintf(stderr, "Error: Cannot read file %s\n", filename);
        return 0;
    }

    sha256_hex(data, data_len, hash_hex, sizeof(hash_hex));
    strftime(dt, sizeof(dt), "%Y-%m-%d %H:%M:%S", gmtime(&now));

    if (sqlite3_open(db_name, &db) != SQLITE_OK) {
        fprintf(stderr, "Error: Unable to open database %s\n", db_name);
        free(data);
        return 0;
    }

    /* Insert blob if missing */
    if (sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO blobs (hash, data, size) VALUES (?, ?, ?)", -1, &stmt, 0) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, hash_hex, -1, SQLITE_STATIC);
        sqlite3_bind_blob(stmt, 2, data, (int)data_len, SQLITE_STATIC);
        sqlite3_bind_int(stmt, 3, (int)data_len);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    /* Stage file */
    if (sqlite3_prepare_v2(db, "INSERT INTO staging (filename, hash, datetime) VALUES (?, ?, ?)", -1, &stmt, 0) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, filename, -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 2, hash_hex, -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 3, dt, -1, SQLITE_STATIC);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
    free(data);
    return 1;
}

static int commit_files(const char *db_name, const Settings *s, const char *message) {
    sqlite3 *db;
    sqlite3_stmt *stmt;
    int commit_id = 0;
    time_t now = time(NULL);
    char dt[64];

    strftime(dt, sizeof(dt), "%Y-%m-%d %H:%M:%S", gmtime(&now));

    if (sqlite3_open(db_name, &db) != SQLITE_OK) {
        fprintf(stderr, "Error: Unable to open database %s\n", db_name);
        return 0;
    }

    if (sqlite3_prepare_v2(db, "INSERT INTO commits (message, datetime, user) VALUES (?, ?, ?)", -1, &stmt, 0) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, message, -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 2, dt, -1, SQLITE_STATIC);
        sqlite3_bind_text(stmt, 3, s->username, -1, SQLITE_STATIC);
        sqlite3_step(stmt);
        sqlite3_finalize(stmt);
    }

    commit_id = (int)sqlite3_last_insert_rowid(db);

    if (sqlite3_prepare_v2(db, "SELECT filename, hash, datetime FROM staging", -1, &stmt, 0) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *filename = (const char *)sqlite3_column_text(stmt, 0);
            const char *hash = (const char *)sqlite3_column_text(stmt, 1);
            const char *dt_stage = (const char *)sqlite3_column_text(stmt, 2);

            sqlite3_stmt *stmt2;
            if (sqlite3_prepare_v2(db, "INSERT INTO files (filename, hash, datetime, commit_id) VALUES (?, ?, ?, ?)", -1, &stmt2, 0) == SQLITE_OK) {
                sqlite3_bind_text(stmt2, 1, filename, -1, SQLITE_STATIC);
                sqlite3_bind_text(stmt2, 2, hash, -1, SQLITE_STATIC);
                sqlite3_bind_text(stmt2, 3, dt_stage, -1, SQLITE_STATIC);
                sqlite3_bind_int(stmt2, 4, commit_id);
                sqlite3_step(stmt2);
                sqlite3_finalize(stmt2);
            }
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_exec(db, "DELETE FROM staging", 0, 0, 0);
    sqlite3_close(db);

    printf("Committed: %d\n", commit_id);
    return 1;
}

static void show_status(const char *db_name) {
    sqlite3 *db;
    sqlite3_stmt *stmt;

    if (sqlite3_open(db_name, &db) != SQLITE_OK) {
        fprintf(stderr, "Error: Unable to open database %s\n", db_name);
        return;
    }

    printf("Staged files:\n");
    if (sqlite3_prepare_v2(db, "SELECT filename FROM staging", -1, &stmt, 0) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *filename = (const char *)sqlite3_column_text(stmt, 0);
            printf("  %s\n", filename);
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
}

static void show_log(const char *db_name) {
    sqlite3 *db;
    sqlite3_stmt *stmt;

    if (sqlite3_open(db_name, &db) != SQLITE_OK) {
        fprintf(stderr, "Error: Unable to open database %s\n", db_name);
        return;
    }

    if (sqlite3_prepare_v2(db, "SELECT id, message, datetime FROM commits ORDER BY id DESC", -1, &stmt, 0) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            int id = sqlite3_column_int(stmt, 0);
            const char *msg = (const char *)sqlite3_column_text(stmt, 1);
            const char *dt = (const char *)sqlite3_column_text(stmt, 2);
            printf("[%d] %s (%s)\n", id, msg, dt);
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
}

static int use_internal_http(const Settings *s) {
#ifdef USE_LIBCURL
    if (s->use_internal_http) {
        return 1;
    }
#else
    (void)s;
#endif
    return 0;
}

#ifdef USE_LIBCURL
static size_t write_file_cb(void *ptr, size_t size, size_t nmemb, void *stream) {
    FILE *f = (FILE *)stream;
    return fwrite(ptr, size, nmemb, f);
}
#endif

static int push_with_libcurl(const Settings *s, const char *db_name, const char *otp_code) {
#ifdef USE_LIBCURL
    CURL *curl;
    CURLcode res;
    struct curl_httppost *form = NULL;
    struct curl_httppost *last = NULL;
    char url[MAX_PATH_LEN];

    snprintf(url, sizeof(url), "%s/", s->repos);

    curl = curl_easy_init();
    if (!curl) return 0;

    curl_formadd(&form, &last, CURLFORM_COPYNAME, "username", CURLFORM_COPYCONTENTS, s->username, CURLFORM_END);
    curl_formadd(&form, &last, CURLFORM_COPYNAME, "password", CURLFORM_COPYCONTENTS, s->password, CURLFORM_END);
    curl_formadd(&form, &last, CURLFORM_COPYNAME, "repo_name", CURLFORM_COPYCONTENTS, basename_simple(db_name), CURLFORM_END);
    curl_formadd(&form, &last, CURLFORM_COPYNAME, "repo_file", CURLFORM_FILE, db_name, CURLFORM_END);
    curl_formadd(&form, &last, CURLFORM_COPYNAME, "action", CURLFORM_COPYCONTENTS, "Upload", CURLFORM_END);
    if (otp_code && otp_code[0]) {
        curl_formadd(&form, &last, CURLFORM_COPYNAME, "otp_code", CURLFORM_COPYCONTENTS, otp_code, CURLFORM_END);
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPPOST, form);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, (long)s->http_timeout);

    res = curl_easy_perform(curl);
    curl_formfree(form);
    curl_easy_cleanup(curl);

    return (res == CURLE_OK);
#else
    (void)s;
    (void)db_name;
    (void)otp_code;
    return 0;
#endif
}

static int pull_with_libcurl(const Settings *s, const char *db_name, const char *otp_code) {
#ifdef USE_LIBCURL
    CURL *curl;
    CURLcode res;
    FILE *f = NULL;
    char url[MAX_PATH_LEN];
    char post_fields[MAX_LINE];

    snprintf(url, sizeof(url), "%s/", s->repos);

    snprintf(post_fields, sizeof(post_fields),
        "username=%s&password=%s&repo_name=%s&action=pull%s%s",
        s->username, s->password, basename_simple(db_name),
        (otp_code && otp_code[0]) ? "&otp_code=" : "",
        (otp_code && otp_code[0]) ? otp_code : "");

    curl = curl_easy_init();
    if (!curl) return 0;

    f = fopen(db_name, "wb");
    if (!f) {
        curl_easy_cleanup(curl);
        return 0;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, post_fields);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, (long)s->http_timeout);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_file_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, f);

    res = curl_easy_perform(curl);
    fclose(f);
    curl_easy_cleanup(curl);

    return (res == CURLE_OK);
#else
    (void)s;
    (void)db_name;
    (void)otp_code;
    return 0;
#endif
}

static int push_with_curl_exec(const Settings *s, const char *db_name, const char *otp_code) {
    char cmd[2048];
    char otp_part[256] = "";

    if (otp_code && otp_code[0]) {
        snprintf(otp_part, sizeof(otp_part), " -F \"otp_code=%s\"", otp_code);
    }

    snprintf(cmd, sizeof(cmd),
        "%s -f -X POST -F \"username=%s\" -F \"password=%s\" -F \"repo_name=%s\" -F \"repo_file=@%s\" -F \"action=Upload\"%s \"%s/\"",
        s->curl, s->username, s->password, basename_simple(db_name), db_name, otp_part, s->repos);

    return (system(cmd) == 0);
}

static int pull_with_curl_exec(const Settings *s, const char *db_name, const char *otp_code) {
    char cmd[2048];
    char otp_part[256] = "";

    if (otp_code && otp_code[0]) {
        snprintf(otp_part, sizeof(otp_part), " -d \"otp_code=%s\"", otp_code);
    }

    snprintf(cmd, sizeof(cmd),
        "%s -f -X POST -d \"username=%s\" -d \"password=%s\" -d \"repo_name=%s\" -d \"action=pull\"%s -o \"%s\" \"%s/\"",
        s->curl, s->username, s->password, basename_simple(db_name), otp_part, db_name, s->repos);

    return (system(cmd) == 0);
}

static void push_repo(const Settings *s, const char *db_name) {
    char otp_code[32] = "";

    if (strcmp(s->api_enabled, "0") == 0) {
        printf("Error: API is disabled\n");
        return;
    }

    if (!file_exists(db_name)) {
        printf("Error: Database file %s not found\n", db_name);
        return;
    }

    if (has_2fa_enabled(s)) {
        prompt_otp(otp_code, sizeof(otp_code));
    }

    if (use_internal_http(s)) {
        if (!push_with_libcurl(s, db_name, otp_code)) {
            printf("Internal HTTP failed, falling back to curl\n");
            if (!push_with_curl_exec(s, db_name, otp_code)) {
                printf("Error: Failed to push\n");
            }
        } else {
            printf("Successfully pushed to %s\n", s->repos);
        }
    } else {
        if (!push_with_curl_exec(s, db_name, otp_code)) {
            printf("Error: Failed to push\n");
        } else {
            printf("Successfully pushed to %s\n", s->repos);
        }
    }
}

static void pull_repo(const Settings *s, const char *db_name) {
    char otp_code[32] = "";

    if (strcmp(s->api_enabled, "0") == 0) {
        printf("Error: API is disabled\n");
        return;
    }

    if (has_2fa_enabled(s)) {
        prompt_otp(otp_code, sizeof(otp_code));
    }

    if (use_internal_http(s)) {
        if (!pull_with_libcurl(s, db_name, otp_code)) {
            printf("Internal HTTP failed, falling back to curl\n");
            if (!pull_with_curl_exec(s, db_name, otp_code)) {
                printf("Error: Failed to pull\n");
            }
        } else {
            printf("Successfully pulled from %s\n", s->repos);
        }
    } else {
        if (!pull_with_curl_exec(s, db_name, otp_code)) {
            printf("Error: Failed to pull\n");
        } else {
            printf("Successfully pulled from %s\n", s->repos);
        }
    }
}

static int should_skip_file(const char *path) {
    const char *base = basename_simple(path);
    if (strcmp(base, ".omi") == 0) return 1;
    if (strstr(base, ".omi") != NULL) return 1;
    return 0;
}

#ifdef OMI_WINDOWS
static void add_all_files_windows(const char *root, const char *db_name) {
    WIN32_FIND_DATAA ffd;
    HANDLE hFind;
    char search[MAX_PATH_LEN];

    snprintf(search, sizeof(search), "%s\\*", root);
    hFind = FindFirstFileA(search, &ffd);
    if (hFind == INVALID_HANDLE_VALUE) return;

    do {
        if (strcmp(ffd.cFileName, ".") == 0 || strcmp(ffd.cFileName, "..") == 0) {
            continue;
        }

        if (ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            char sub[MAX_PATH_LEN];
            snprintf(sub, sizeof(sub), "%s\\%s", root, ffd.cFileName);
            add_all_files_windows(sub, db_name);
        } else {
            char file_path[MAX_PATH_LEN];
            snprintf(file_path, sizeof(file_path), "%s\\%s", root, ffd.cFileName);
            if (!should_skip_file(file_path)) {
                add_file_to_db(db_name, file_path);
            }
        }
    } while (FindNextFileA(hFind, &ffd) != 0);

    FindClose(hFind);
}
#else
static void add_all_files_posix(const char *root, const char *db_name) {
    DIR *dir = opendir(root);
    struct dirent *entry;

    if (!dir) return;

    while ((entry = readdir(dir)) != NULL) {
        char path[MAX_PATH_LEN];
        struct stat st;

        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }

        snprintf(path, sizeof(path), "%s/%s", root, entry->d_name);
        if (stat(path, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                add_all_files_posix(path, db_name);
            } else {
                if (!should_skip_file(path)) {
                    add_file_to_db(db_name, path);
                }
            }
        }
    }

    closedir(dir);
}
#endif

static void add_all_files(const char *db_name) {
#ifdef OMI_WINDOWS
    add_all_files_windows(".", db_name);
#else
    add_all_files_posix(".", db_name);
#endif
}

static void print_help(void) {
    printf("Omi - C89 CLI\n\n");
    printf("Usage: omi <command> [options]\n\n");
    printf("Commands:\n");
    printf("  init [db]         Initialize repository\n");
    printf("  add <file>        Stage file\n");
    printf("  add --all         Stage all files\n");
    printf("  commit -m <msg>   Commit staged files\n");
    printf("  push              Push to server\n");
    printf("  pull              Pull from server\n");
    printf("  log               Show commit log\n");
    printf("  status            Show staging status\n");
    printf("\n");
}

int main(int argc, char **argv) {
    Settings settings;
    char db_name[MAX_PATH_LEN];

    settings_init(&settings);
    settings_load(&settings, "../settings.txt");

    read_dotomi(db_name, sizeof(db_name));

    if (argc < 2) {
        print_help();
        return 0;
    }

    if (strcmp(argv[1], "init") == 0) {
        const char *db = (argc >= 3) ? argv[2] : "repo.omi";
        write_dotomi(db);
        if (init_db(db)) {
            printf("Repository initialized\n");
        }
        return 0;
    }

    if (strcmp(argv[1], "add") == 0) {
        if (argc < 3) {
            printf("Usage: omi add <file> | omi add --all\n");
            return 1;
        }
        if (strcmp(argv[2], "--all") == 0) {
            add_all_files(db_name);
        } else {
            add_file_to_db(db_name, argv[2]);
        }
        return 0;
    }

    if (strcmp(argv[1], "commit") == 0) {
        if (argc < 4 || strcmp(argv[2], "-m") != 0) {
            printf("Usage: omi commit -m \"message\"\n");
            return 1;
        }
        commit_files(db_name, &settings, argv[3]);
        return 0;
    }

    if (strcmp(argv[1], "push") == 0) {
        push_repo(&settings, db_name);
        return 0;
    }

    if (strcmp(argv[1], "pull") == 0) {
        pull_repo(&settings, db_name);
        return 0;
    }

    if (strcmp(argv[1], "status") == 0) {
        show_status(db_name);
        return 0;
    }

    if (strcmp(argv[1], "log") == 0) {
        show_log(db_name);
        return 0;
    }

    print_help();
    return 0;
}

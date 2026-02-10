#!/usr/bin/env tclsh
# Omi - Tcl CLI

package require Tcl 8.5
package require sqlite3
package require http

set has_sha2 1
if {[catch {package require sha2}]} {
    set has_sha2 0
}

array set settings {}

proc settings_init {} {
    global settings
    set settings(curl) "curl"
    set settings(api_enabled) "1"
    set settings(use_internal_http) 1
    set settings(http_timeout) 30
}

proc settings_load {path} {
    global settings
    if {![file exists $path]} { return }
    set f [open $path r]
    while {[gets $f line] >= 0} {
        if {[string match "#*" $line]} { continue }
        if {![string match "*=*" $line]} { continue }
        set key [string trim [lindex [split $line "="] 0]]
        set value [string trim [join [lrange [split $line "="] 1 end] "="]]
        switch -- $key {
            USERNAME { set settings(username) $value }
            PASSWORD { set settings(password) $value }
            REPOS { set settings(repos) $value }
            CURL { set settings(curl) $value }
            API_ENABLED { set settings(api_enabled) $value }
            USE_INTERNAL_HTTP { set settings(use_internal_http) [expr {$value eq "1"}] }
            HTTP_TIMEOUT { set settings(http_timeout) [expr {int($value)}] }
        }
    }
    close $f
}

proc read_dotomi {} {
    if {![file exists ".omi"]} { return "repo.omi" }
    set f [open ".omi" r]
    set db "repo.omi"
    while {[gets $f line] >= 0} {
        if {[regexp {OMI_DB="([^"]+)"} $line -> v]} {
            set db $v
            break
        }
    }
    close $f
    return $db
}

proc write_dotomi {db} {
    set f [open ".omi" w]
    puts $f "OMI_DB=\"$db\""
    close $f
}

proc sha256_hex {data} {
    global has_sha2
    if {$has_sha2} {
        return [::sha2::sha256 -hex $data]
    }

    set tmp [file tempfile fname]
    set f [open $tmp wb]
    fconfigure $f -translation binary -encoding binary
    puts -nonewline $f $data
    close $f

    if {[catch {set out [exec sha256sum $tmp]}]} {
        if {[catch {set out [exec openssl dgst -sha256 $tmp]}]} {
            file delete -force $tmp
            error "No SHA256 implementation found (tcllib sha2, sha256sum, or openssl)."
        }
        set hash [lindex $out end]
    } else {
        set hash [lindex $out 0]
    }

    file delete -force $tmp
    return $hash
}

proc load_file {path} {
    set f [open $path rb]
    fconfigure $f -translation binary -encoding binary
    set data [read $f]
    close $f
    return $data
}

proc has_2fa_enabled {} {
    global settings
    if {![file exists "phpusers.txt"]} { return 0 }
    set f [open "phpusers.txt" r]
    while {[gets $f line] >= 0} {
        if {[string match "$settings(username):*" $line]} {
            set parts [split $line ":"]
            if {[llength $parts] >= 3 && [string length [lindex $parts 2]] > 0} {
                close $f
                return 1
            }
        }
    }
    close $f
    return 0
}

proc prompt_otp {} {
    puts -nonewline "Enter OTP code (6 digits): "
    flush stdout
    gets stdin otp
    return $otp
}

proc init_db {db} {
    sqlite3 dbh $db
    dbh eval {
        CREATE TABLE IF NOT EXISTS blobs (hash TEXT PRIMARY KEY, data BLOB, size INTEGER);
        CREATE TABLE IF NOT EXISTS files (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, hash TEXT, datetime TEXT, commit_id INTEGER);
        CREATE TABLE IF NOT EXISTS commits (id INTEGER PRIMARY KEY AUTOINCREMENT, message TEXT, datetime TEXT, user TEXT);
        CREATE TABLE IF NOT EXISTS staging (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, hash TEXT, datetime TEXT);
    }
    dbh close
}

proc add_file {db path} {
    if {![file exists $path]} {
        puts "Error: File not found: $path"
        return
    }
    set data [load_file $path]
    set hash [sha256_hex $data]
    set dt [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S" -gmt 1]

    sqlite3 dbh $db
    set size [string length $data]
    dbh eval {INSERT OR IGNORE INTO blobs (hash, data, size) VALUES (:hash, :data, :size)}
    dbh eval {INSERT INTO staging (filename, hash, datetime) VALUES (:path, :hash, :dt)}
    dbh close
    puts "Added: $path"
}

proc should_skip {path} {
    set base [file tail $path]
    if {$base eq ".omi"} { return 1 }
    if {[string match "*.omi" $base]} { return 1 }
    return 0
}

proc add_all {db dir} {
    foreach item [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $item]} {
            add_all $db $item
        } else {
            if {![should_skip $item]} {
                add_file $db $item
            }
        }
    }
}

proc commit_files {db message} {
    global settings
    set dt [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S" -gmt 1]

    sqlite3 dbh $db
    set user $settings(username)
    dbh eval {INSERT INTO commits (message, datetime, user) VALUES (:message, :dt, :user)}
    set commit_id [dbh last_insert_rowid]

    dbh eval {SELECT filename, hash, datetime FROM staging} row {
        set filename $row(filename)
        set hash $row(hash)
        set fdt $row(datetime)
        dbh eval {INSERT INTO files (filename, hash, datetime, commit_id) VALUES (:filename, :hash, :fdt, :commit_id)}
    }
    dbh eval {DELETE FROM staging}
    dbh close

    puts "Committed: $commit_id"
}

proc show_status {db} {
    sqlite3 dbh $db
    puts "Staged files:"
    dbh eval {SELECT filename FROM staging} row {
        puts "  $row(filename)"
    }
    dbh close
}

proc show_log {db} {
    sqlite3 dbh $db
    dbh eval {SELECT id, message, datetime FROM commits ORDER BY id DESC} row {
        puts "[$row(id)] $row(message) ($row(datetime))"
    }
    dbh close
}

proc list_repos {db} {
    if {[file exists $db]} {
        puts "Repositories:"
        puts "  [file tail $db]"
    } else {
        puts "No repository found"
    }
}

proc http_post_multipart {url fields file_field file_path timeout} {
    set boundary "----omiTclBoundary[clock clicks]"
    set body ""

    foreach {k v} $fields {
        append body "--$boundary\r\n"
        append body "Content-Disposition: form-data; name=\"$k\"\r\n\r\n"
        append body "$v\r\n"
    }

    set filename [file tail $file_path]
    set f [open $file_path rb]
    fconfigure $f -translation binary -encoding binary
    set filedata [read $f]
    close $f

    append body "--$boundary\r\n"
    append body "Content-Disposition: form-data; name=\"$file_field\"; filename=\"$filename\"\r\n"
    append body "Content-Type: application/octet-stream\r\n\r\n"
    append body $filedata
    append body "\r\n--$boundary--\r\n"

    set body [encoding convertto binary $body]
    set token [http::geturl $url -method POST -type "multipart/form-data; boundary=$boundary" -query $body -timeout [expr {$timeout * 1000}]]
    set status [http::status $token]
    set code [http::ncode $token]
    set data [http::data $token]
    http::cleanup $token

    return [list $status $code $data]
}

proc http_post_form {url fields timeout} {
    set query [eval http::formatQuery $fields]
    set token [http::geturl $url -method POST -query $query -timeout [expr {$timeout * 1000}]]
    set status [http::status $token]
    set code [http::ncode $token]
    set data [http::data $token]
    http::cleanup $token

    return [list $status $code $data]
}

proc push_repo {db} {
    global settings
    if {$settings(api_enabled) eq "0"} {
        puts "Error: API is disabled"
        return
    }
    if {![file exists $db]} {
        puts "Error: Database file $db not found"
        return
    }

    set otp ""
    if {[has_2fa_enabled]} {
        set otp [prompt_otp]
    }

    if {$settings(use_internal_http)} {
        set fields [list username $settings(username) password $settings(password) repo_name $db action Upload]
        if {$otp ne ""} {
            lappend fields otp_code $otp
        }
        set res [http_post_multipart "$settings(repos)/" $fields repo_file $db $settings(http_timeout)]
        set code [lindex $res 1]
        if {$code == 200} {
            puts "Successfully pushed to $settings(repos)"
        } else {
            puts "Error: Failed to push (HTTP $code), falling back to curl"
            if {![push_repo_curl $db $otp]} {
                puts "Error: Failed to push"
            }
        }
    } else {
        if {![push_repo_curl $db $otp]} {
            puts "Error: Failed to push"
        }
    }
}

proc push_repo_curl {db otp} {
    global settings
    set cmd [list $settings(curl) -f -X POST -F "username=$settings(username)" -F "password=$settings(password)" -F "repo_name=$db" -F "repo_file=@$db" -F "action=Upload"]
    if {$otp ne ""} {
        lappend cmd -F "otp_code=$otp"
    }
    lappend cmd "$settings(repos)/"

    if {[catch {exec {*}$cmd} err]} {
        puts $err
        return 0
    }
    puts "Successfully pushed to $settings(repos)"
    return 1
}

proc pull_repo {db} {
    global settings
    if {$settings(api_enabled) eq "0"} {
        puts "Error: API is disabled"
        return
    }

    set otp ""
    if {[has_2fa_enabled]} {
        set otp [prompt_otp]
    }

    if {$settings(use_internal_http)} {
        set fields [list username $settings(username) password $settings(password) repo_name $db action pull]
        if {$otp ne ""} {
            lappend fields otp_code $otp
        }
        set res [http_post_form "$settings(repos)/" $fields $settings(http_timeout)]
        set code [lindex $res 1]
        set data [lindex $res 2]
        if {$code == 200} {
            set f [open $db wb]
            fconfigure $f -translation binary -encoding binary
            puts -nonewline $f $data
            close $f
            puts "Successfully pulled from $settings(repos)"
        } else {
            puts "Error: Failed to pull (HTTP $code), falling back to curl"
            if {![pull_repo_curl $db $otp]} {
                puts "Error: Failed to pull"
            }
        }
    } else {
        if {![pull_repo_curl $db $otp]} {
            puts "Error: Failed to pull"
        }
    }
}

proc pull_repo_curl {db otp} {
    global settings
    set cmd [list $settings(curl) -f -X POST -d "username=$settings(username)" -d "password=$settings(password)" -d "repo_name=$db" -d "action=pull"]
    if {$otp ne ""} {
        lappend cmd -d "otp_code=$otp"
    }
    lappend cmd -o $db "$settings(repos)/"

    if {[catch {exec {*}$cmd} err]} {
        puts $err
        return 0
    }
    puts "Successfully pulled from $settings(repos)"
    return 1
}

proc print_help {} {
    puts "Omi - Tcl CLI"
    puts "Usage: omi.tcl <command> [options]"
    puts "Commands: init, add, commit, push, pull, status, log, list, clone"
}

settings_init
settings_load "../settings.txt"
set db [read_dotomi]

if {[llength $argv] < 1} {
    print_help
    exit 0
}

set cmd [lindex $argv 0]

switch -- $cmd {
    init {
        set dbname [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "repo.omi"}]
        write_dotomi $dbname
        init_db $dbname
        puts "Repository initialized"
    }
    add {
        if {[llength $argv] < 2} {
            puts "Usage: omi.tcl add <file> | omi.tcl add --all"
            exit 1
        }
        set arg [lindex $argv 1]
        if {$arg eq "--all"} {
            add_all $db "."
        } else {
            add_file $db $arg
        }
    }
    commit {
        if {[llength $argv] < 3 || [lindex $argv 1] ne "-m"} {
            puts "Usage: omi.tcl commit -m \"message\""
            exit 1
        }
        commit_files $db [lindex $argv 2]
    }
    push {
        push_repo $db
    }
    pull {
        pull_repo $db
    }
    status {
        show_status $db
    }
    log {
        show_log $db
    }
    list {
        list_repos $db
    }
    clone {
        if {[llength $argv] < 2} {
            puts "Usage: omi.tcl clone <url>"
            exit 1
        }
        set settings(repos) [lindex $argv 1]
        pull_repo $db
    }
    default {
        print_help
    }
}

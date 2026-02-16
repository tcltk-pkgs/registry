package require huddle
package require json

set INPUT_FILE  "packages.json"
set OUTPUT_FILE "metadata/packages-meta.json"
set TIMEOUT 12

# DEBUG MODE - Affiche tout
set DEBUG 1

proc debug {msg} {
    global DEBUG
    if {$DEBUG} { puts "DEBUG: $msg" }
}

array set FOSSIL_MIRRORS {
    "https://core.tcl-lang.org/tcllib" "https://github.com/tcltk/tcllib"
    "https://core.tcl-lang.org/tklib"  "https://github.com/tcltk/tklib"
    "https://core.tcl-lang.org/tcl"    "https://github.com/tcltk/tcl"
    "https://core.tcl-lang.org/tk"     "https://github.com/tcltk/tk"
}

set github_cache [dict create]
set fossil_cache [dict create]
array set existing_dates {}

proc to_huddle {val type} {
    if {$type eq "bool"} { 
        if {$val eq "" || $val == 0 || [string tolower $val] eq "false"} {
            return [huddle boolean false]
        } else {
            return [huddle boolean true]
        }
    }
    if {$type eq "list"} {
        set hlist [huddle list]
        foreach item $val {
            if {$item ne ""} {
                huddle append hlist [huddle string $item]
            }
        }
        return $hlist
    }
    if {$val eq ""} { return [huddle string ""] }
    return [huddle string $val]
}

proc parse_github_repo {url} {
    if {[regexp {github\.com/([^/]+/[^/.]+)} $url -> repo]} {
        return [string trimright $repo "/"]
    }
    return ""
}

proc http_get {url {type "raw"}} {
    global env TIMEOUT
    debug "HTTP GET: $url"
    
    set hdrs [list -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"]
    if {[info exists env(GITHUB_TOKEN)]} {
        lappend hdrs -H "Authorization: Bearer $env(GITHUB_TOKEN)"
        debug "Using GITHUB_TOKEN"
    }

    set cmd [list curl -s -L --no-keepalive --max-time $TIMEOUT {*}$hdrs -w "\n%{http_code}" $url]
    
    if {[catch {exec -ignorestderr {*}$cmd} response]} {
        debug "CURL FAILED: $response"
        return [dict create code 0 body "" json {}]
    }

    set lines [split $response "\n"]
    set code [string trim [lindex $lines end]]
    set body [string trim [join [lrange $lines 0 end-1] "\n"]]
    
    debug "HTTP CODE: $code"
    
    set json {}
    if {$type eq "json" && $code == 200} {
        if {[catch {set json [::json::json2dict $body]} err]} {
            debug "JSON PARSE ERROR: $err"
        } else {
            debug "JSON OK, keys: [dict keys $json]"
        }
    }
    return [dict create code $code body $body json $json]
}

proc fetch_github_data {url {module_path ""}} {
    global github_cache
    set repo [parse_github_repo $url]
    if {$repo eq ""} { 
        debug "No repo parsed from URL: $url"
        return {} 
    }
    
    debug "Processing repo: $repo"

    set commit_key "${repo}:${module_path}"

    if {![dict exists $github_cache $repo]} {
        debug "Cache miss for repo info: $repo"
        set info [dict create archived 0 latest_release "none"]
        
        # CORRECTION: Pas d'espace dans l'URL!
        set api_url "https://api.github.com/repos/$repo"
        debug "API URL: $api_url"
        
        set r [http_get $api_url "json"]
        debug "Repo info response code: [dict get $r code]"
        
        if {[dict get $r code] == 200} {
            set json [dict get $r json]
            if {[dict exists $json archived]} {
                dict set info archived [dict get $json archived]
                debug "Archived status: [dict get $json archived]"
            }
        }
        
        set r_rel [http_get "https://api.github.com/repos/$repo/releases/latest" "json"]
        if {[dict get $r_rel code] == 200} {
            set json [dict get $r_rel json]
            if {[dict exists $json tag_name]} {
                dict set info latest_release [dict get $json tag_name]
                debug "Latest release: [dict get $json tag_name]"
            }
        }
        dict set github_cache $repo $info
    } else {
        debug "Cache hit for repo: $repo"
    }

    if {![dict exists $github_cache $commit_key]} {
        debug "Cache miss for commits: $commit_key"
        set cdata [dict create last_commit "" last_commit_sha ""]
        
        # CORRECTION: Pas d'espace!
        set api_url "https://api.github.com/repos/$repo/commits?per_page=1"
        if {$module_path ne ""} { append api_url "&path=$module_path" }
        
        debug "Commits URL: $api_url"
        set r [http_get $api_url "json"]
        
        if {[dict get $r code] == 200} {
            set commits [dict get $r json]
            debug "Found [llength $commits] commits"
            if {[llength $commits] > 0} {
                set c [lindex $commits 0]
                set sha [string range [dict get $c sha] 0 6]
                set date [string map {T " " Z ""} [dict get $c commit committer date]]
                debug "Commit: $sha @ $date"
                
                dict set cdata last_commit_sha $sha
                dict set cdata last_commit $date
            }
        } else {
            debug "Failed to get commits: [dict get $r code]"
        }
        dict set github_cache $commit_key $cdata
    } else {
        debug "Cache hit for commits"
    }

    set result [dict merge [dict get $github_cache $repo] [dict get $github_cache $commit_key]]
    debug "Final result keys: [dict keys $result]"
    return $result
}

proc process_fossil {url} {
    global FOSSIL_MIRRORS fossil_cache
    debug "Processing fossil: $url"

    set base [lindex [split $url ?] 0]
    foreach p {/dir /file /timeline /info /json} {
        if {[set idx [string first $p $base]] >= 0} {
            set base [string range $base 0 $idx-1]
        }
    }
    set base [string trimright $base "/"]
    debug "Fossil base: $base"

    set module_path ""
    if {[regexp {[?&]name=([^&]+)} $url -> p]} { set module_path $p }

    set meta [dict create last_commit "" last_commit_sha "" last_tag ""]

    set api_url "$base/json/timeline?type=ci&limit=1"
    if {$module_path ne ""} { append api_url "&p=$module_path" }
    
    debug "Fossil API: $api_url"
    set r [http_get $api_url "json"]
    
    if {[dict get $r code] == 200} {
        set tl [dict get $r json payload timeline]
        debug "Fossil timeline entries: [llength $tl]"
        if {[llength $tl] > 0} {
            set entry [lindex $tl 0]
            dict set meta last_commit [expr {[dict exists $entry timestamp] ? [dict get $entry timestamp] : [dict get $entry mtime]}]
            dict set meta last_commit_sha [string range [dict get $entry uuid] 0 9]
            debug "Fossil commit: [dict get $meta last_commit_sha]"
        }
    }

    if {[info exists FOSSIL_MIRRORS($base)]} {
        set mirror $FOSSIL_MIRRORS($base)
        debug "Checking mirror: $mirror"
        set gh [fetch_github_data $mirror $module_path]
        
        if {[dict get $meta last_commit] eq ""} {
            set meta [dict merge $meta $gh]
        } else {
            dict set meta archived [dict get $gh archived]
            dict set meta latest_release [dict get $gh latest_release]
        }

        catch {
            set raw_tags [exec git ls-remote --tags --refs $mirror]
            set tag_list [list]
            foreach line [split $raw_tags "\n"] {
                if {[regexp {refs/tags/(.*)} $line -> t]} { lappend tag_list $t }
            }
            dict set meta last_tag [get_latest_tag $tag_list]
        }
    }

    return $meta
}

proc process_git {url} {
    global env
    set repo [parse_github_repo $url]
    debug "Processing git: $url (repo: $repo)"

    if {$repo ne ""} {
        set meta [fetch_github_data $url]
        dict set meta last_tag [dict get $meta latest_release]
        
        if {[dict get $meta last_tag] eq ""} {
             catch {
                set raw_tags [exec git ls-remote --tags --refs $url]
                set tag_list [list]
                foreach line [split $raw_tags "\n"] {
                    if {[regexp {refs/tags/(.*)} $line -> t]} { lappend tag_list $t }
                }
                dict set meta last_tag [get_latest_tag $tag_list]
            }
        }
        return $meta
    }

    debug "Fallback to git clone for: $url"
    set meta [dict create last_commit "" last_commit_sha "" last_tag ""]
    set tmp [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] "git-[expr {int(rand()*10000)}]"]

    try {
        exec git clone --depth 1 --filter=blob:none --no-checkout $url $tmp 2>@1
        dict set meta last_commit [exec git -C $tmp log -1 --format=%ci]
        dict set meta last_commit_sha [exec git -C $tmp rev-parse --short HEAD]
        set t_out [exec git -C $tmp tag]
        dict set meta last_tag [get_latest_tag [split $t_out "\n"]]
        debug "Git fallback success: [dict get $meta last_commit_sha]"
    } on error {err} {
        debug "Git fallback error: $err"
    } finally {
        file delete -force $tmp
    }
    return $meta
}

proc get_package_add_date {name input_file} {
    set patterns [list "\"name\": \"$name\"" "\"name\":\"$name\""]
    foreach pattern $patterns {
        set cmd [list git log --first-parent --format=%aI --diff-filter=A -S $pattern --reverse -- $input_file]
        if {![catch {exec -ignorestderr {*}$cmd} result]} {
            set result [string trim $result]
            if {$result ne ""} { return [lindex [split $result "\n"] 0] }
        }
    }
    return ""
}

proc main {} {
    global INPUT_FILE OUTPUT_FILE existing_dates github_cache fossil_cache
    
    # Reset caches pour être sûr
    set github_cache [dict create]
    set fossil_cache [dict create]

    set fh [open $INPUT_FILE r]
    fconfigure $fh -encoding utf-8
    set data [read $fh]
    close $fh

    set packages [::json::json2dict $data]
    set out_list [huddle list]

    set timestamp [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
    huddle append out_list [huddle create generated_at [huddle string $timestamp]]

    set idx 0
    set total [llength $packages]
    
    # Traite seulement le premier package pour le test
    foreach pkg $packages {
        incr idx
        set name [dict get $pkg name]
        puts "\n\[$idx/$total\] =================== $name ==================="
        
        if {$idx > 3} {
            puts "STOP après 3 packages pour le debug"
            break
        }

        set pkg_date [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
        set enriched_sources [list]
        
        foreach src [dict get $pkg sources] {
            set url [dict get $src url]
            set method [expr {[dict exists $src method] ? [dict get $src method] : ""}]
            puts "Source: $url"
            puts "Method: $method"

            set check [http_get $url]
            set code [dict get $check code]
            set reachable [expr {$code >= 200 && $code < 400}]
            puts "Reachable: $reachable (HTTP $code)"

            set meta [dict create reachable $reachable archived 0 latest_release "none" last_commit "" last_tag ""]
            debug "Meta initial: $meta"

            if {$reachable} {
                if {$method eq "fossil"} {
                    set meta [dict merge $meta [process_fossil $url]]
                } elseif {$method eq "git"} {
                    set meta [dict merge $meta [process_git $url]]
                }
            }
            
            debug "Meta final: $meta"
            puts ">>> last_commit: '[dict get $meta last_commit]'"
            puts ">>> last_commit_sha: '[dict get $meta last_commit_sha]'"
            puts ">>> archived: '[dict get $meta archived]'"

            set h_src [huddle create]
            dict for {k v} $src { huddle append h_src $k [to_huddle $v str] }
            
            dict for {k v} $meta {
                if {$k in {reachable archived}} {
                    huddle append h_src $k [to_huddle $v bool]
                } elseif {$k in {last_commit last_commit_sha}} {
                    huddle append h_src $k [to_huddle $v str]
                } else {
                    huddle append h_src $k [to_huddle $v str]
                }
            }
            huddle append h_src added_at [huddle string $pkg_date]
            lappend enriched_sources $h_src
        }

        set h_pkg [huddle create]
        huddle append h_pkg name [to_huddle $name str]
        set desc [expr {[dict exists $pkg description] ? [dict get $pkg description] : ""}]
        huddle append h_pkg description [to_huddle $desc str]
        
        set h_srcs [huddle list]
        foreach s $enriched_sources { huddle append h_srcs $s }
        huddle append h_pkg sources $h_srcs
        
        set h_tags [huddle list]
        if {[dict exists $pkg tags]} {
            foreach t [dict get $pkg tags] { huddle append h_tags [to_huddle $t str] }
        }
        huddle append h_pkg tags $h_tags
        
        huddle append out_list $h_pkg
    }

    file mkdir [file dirname $OUTPUT_FILE]
    set fh [open $OUTPUT_FILE w]
    puts -nonewline $fh [huddle jsondump $out_list]
    close $fh
    
    puts "\nFichier généré: $OUTPUT_FILE"
    puts "Vérifiez les valeurs ci-dessus pour voir où sont les problèmes."
}

main
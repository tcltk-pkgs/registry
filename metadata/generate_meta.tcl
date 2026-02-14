package require huddle
package require json

set INPUT_FILE  "packages.json"
set OUTPUT_FILE "metadata/packages-meta.json"
set TIMEOUT 12

array set FOSSIL_MIRRORS {
    "https://core.tcl-lang.org/tcllib" "https://github.com/tcltk/tcllib"
    "https://core.tcl-lang.org/tcl"    "https://github.com/tcltk/tcl"
    "https://core.tcl-lang.org/tk"     "https://github.com/tcltk/tk"
}


set github_cache [dict create]
set fossil_cache [dict create]
-
proc http_get {url {type "raw"}} {
    global env TIMEOUT
    set hdrs [list -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"]
    if {[info exists env(GITHUB_TOKEN)]} { lappend hdrs -H "Authorization: Bearer $env(GITHUB_TOKEN)" }
    
    set cmd [list curl -s -L --no-keepalive --max-time $TIMEOUT {*}$hdrs -w "\n%{http_code}" $url]
    
    if {[catch {exec -ignorestderr {*}$cmd} response]} {
        return [dict create code 0 body "" json {} error "curl_fail"]
    }

    set lines [split $response "\n"]
    set code [string trim [lindex $lines end]]
    set body [string trim [join [lrange $lines 0 end-1] "\n"]]
    set json {}

    if {$type eq "json" && $code == 200} {
        catch {set json [::json::json2dict $body]}
    }
    return [dict create code $code body $body json $json error ""]
}

proc parse_github_repo {url} {
    if {[regexp {github\.com/([^/]+/[^/.]+)} $url -> repo]} { return [string trimright $repo "/"] }
    return ""
}

# --- GitHub API Backend with Cache ---
proc fetch_github_data {url {module_path ""}} {
    global github_cache
    set repo [parse_github_repo $url]
    if {$repo eq ""} { return {} }

    # Unique key for commit data (depends on repo + path)
    set commit_key "${repo}:${module_path}"

    # 1. Check if we already have general info for this repo
    if {![dict exists $github_cache $repo]} {
        set info [dict create archived "" latest_release ""]
        set r [http_get "https://api.github.com/repos/$repo" "json"]
        if {[dict get $r code] == 200} {
            dict set info archived [dict get [dict get $r json] archived]
        }
        set r_rel [http_get "https://api.github.com/repos/$repo/releases/latest" "json"]
        if {[dict get $r_rel code] == 200} {
            dict set info latest_release [dict get [dict get $r_rel json] tag_name]
        }
        dict set github_cache $repo $info
    }

    # 2. Check if we already have commit info for this specific path
    if {![dict exists $github_cache $commit_key]} {
        set cdata [dict create last_commit "" last_commit_sha ""]
        set api_url "https://api.github.com/repos/$repo/commits?per_page=1"
        if {$module_path ne ""} { append api_url "&path=$module_path" }
        
        set r [http_get $api_url "json"]
        if {[dict get $r code] == 200 && [llength [dict get $r json]] > 0} {
            set c [lindex [dict get $r json] 0]
            dict set cdata last_commit_sha [string range [dict get $c sha] 0 6]
            dict set cdata last_commit [string map {T " " Z ""} [dict get $c commit committer date]]
        }
        dict set github_cache $commit_key $cdata
    }

    # Merge general info and specific commit data
    return [dict merge [dict get $github_cache $repo] [dict get $github_cache $commit_key]]
}

# --- Fossil Strategy with Cache ---
proc process_fossil {url} {
    global FOSSIL_MIRRORS fossil_cache
    
    if {[dict exists $fossil_cache $url]} {
        puts "    \[fossil\] cache hit for $url"
        return [dict get $fossil_cache $url]
    }

    set base [lindex [split $url ?] 0]
    foreach p {/dir /file /timeline /info /json} {
        if {[set idx [string first $p $base]] >= 0} { set base [string range $base 0 $idx-1] }
    }
    set base [string trimright $base "/"]
    
    set module_path ""
    if {[regexp {[?&]name=([^&]+)} $url -> p]} { set module_path $p }

    set meta [dict create last_commit "" last_commit_sha "" last_tag ""]

    # 1. Primary: Fossil JSON API
    set api_url "$base/json/timeline?type=ci&limit=1"
    if {$module_path ne ""} { append api_url "&p=$module_path" }
    
    set r [http_get $api_url "json"]
    if {[dict get $r code] == 200} {
        set tl [dict get $r json payload timeline]
        if {[llength $tl] > 0} {
            set entry [lindex $tl 0]
            dict set meta last_commit [expr {[dict exists $entry timestamp] ? [dict get $entry timestamp] : [dict get $entry mtime]}]
            dict set meta last_commit_sha [string range [dict get $entry uuid] 0 9]
        }
    }

    # 2. Secondary: GitHub Mirror Backend
    if {[info exists FOSSIL_MIRRORS($base)]} {
        set mirror $FOSSIL_MIRRORS($base)
        set gh [fetch_github_data $mirror $module_path]
        
        if {[dict get $meta last_commit] eq ""} {
            dict set meta last_commit [dict get $gh last_commit]
            dict set meta last_commit_sha [dict get $gh last_commit_sha]
        }
        dict set meta archived [dict get $gh archived]
        dict set meta latest_release [dict get $gh latest_release]
        
        if {[dict get $meta last_tag] eq ""} {
            catch {
                set tline [exec git ls-remote --tags --refs --sort=-v:refname $mirror | head -n1]
                if {[regexp {refs/tags/(.*)} $tline -> tag]} { dict set meta last_tag $tag }
            }
        }
    }

    dict set fossil_cache $url $meta
    return $meta
}

# --- Git Strategy ---
proc process_git {url} {
    global env
    set repo [parse_github_repo $url]
    
    if {$repo ne ""} {
        set gh [fetch_github_data $url]
        return [dict merge $gh [dict create last_tag [dict get $gh latest_release]]]
    }

    set meta [dict create last_commit "" last_commit_sha "" last_tag ""]
    set tmp [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] "git-[expr {int(rand()*10000)}]" ]

    try {
        exec git clone --depth 1 --filter=blob:none --no-checkout $url $tmp 2>@1
        dict set meta last_commit     [exec git -C $tmp log -1 --format=%ci]
        dict set meta last_commit_sha [exec git -C $tmp rev-parse --short HEAD]
        dict set meta last_tag        [exec git -C $tmp tag --sort=-creatordate | head -n1]
    } finally {
        file delete -force $tmp
    }
    return $meta
}

# --- Main Logic ---
proc to_huddle {val type} {
    if {$val eq ""} { return [huddle null] }
    if {$type eq "bool"} { return [huddle boolean $val] }
    return [huddle string $val]
}

proc main {} {
    global INPUT_FILE OUTPUT_FILE
    
    set fh [open $INPUT_FILE r]; fconfigure $fh -encoding utf-8; set data [read $fh]; close $fh
    set packages [::json::json2dict $data]
    
    set out_list [huddle list]
    huddle append out_list [huddle create generated_at [huddle string [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]]]

    set idx 0
    set total [llength $packages]

    foreach pkg $packages {
        incr idx
        set name [dict get $pkg name]
        puts "\[$idx/$total\] $name"
        
        set enriched_sources [list]
        foreach src [dict get $pkg sources] {
            set url [dict get $src url]
            set method [expr {[dict exists $src method] ? [dict get $src method] : ""}]
            
            set check [http_get $url]
            set reachable [expr {[dict get $check code] >= 200 && [dict get $check code] < 400}]
            set meta [dict create reachable $reachable archived "" latest_release "" last_commit "" last_tag ""]

            if {$reachable} {
                if {$method eq "fossil"} {
                    set meta [dict merge $meta [process_fossil $url]]
                } elseif {$method eq "git"} {
                    set meta [dict merge $meta [process_git $url]]
                }
            }

            set h_src [huddle create]
            dict for {k v} $src { huddle append h_src $k [to_huddle $v str] }
            dict for {k v} $meta {
                if {$k in {reachable archived}} {
                    huddle append h_src $k [to_huddle $v bool]
                } else {
                    huddle append h_src $k [to_huddle $v str]
                }
            }
            lappend enriched_sources $h_src
        }

        set h_pkg [huddle create]
        huddle append h_pkg name [to_huddle $name str]
        huddle append h_pkg description [to_huddle [expr {[dict exists $pkg description] ? [dict get $pkg description] : ""}] str]
        
        set h_srcs [huddle list]
        foreach s $enriched_sources { huddle append h_srcs $s }
        huddle append h_pkg sources $h_srcs
        
        set h_tags [huddle list]
        if {[dict exists $pkg tags]} { foreach t [dict get $pkg tags] { huddle append h_tags [to_huddle $t str] } }
        huddle append h_pkg tags $h_tags

        huddle append out_list $h_pkg
    }

    file mkdir [file dirname $OUTPUT_FILE]
    set fh [open $OUTPUT_FILE w]
    puts -nonewline $fh [string map {\\/ /} [huddle jsondump $out_list "" "  "]]
    close $fh
    puts "Done: $OUTPUT_FILE"
}

main
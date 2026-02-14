package require Tcl 8.6
package require huddle
package require json

set INPUT_FILE  "packages.json"
set OUTPUT_FILE "metadata/packages-meta.json"

# Configuration
set TIMEOUT 15
array set FOSSIL_MIRRORS {
    "https://core.tcl-lang.org/tcllib" "https://github.com/tcltk/tcllib"
    "https://core.tcl-lang.org/tcl"    "https://github.com/tcltk/tcl"
    "https://core.tcl-lang.org/tk"     "https://github.com/tcltk/tk"
}


proc http_get {url {type "raw"}} {
    global env TIMEOUT
    set hdrs [list -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"]
    if {[info exists env(GITHUB_TOKEN)]} { lappend hdrs -H "Authorization: Bearer $env(GITHUB_TOKEN)" }
    
    set cmd [list curl -s -L --max-time $TIMEOUT {*}$hdrs -w "\n%{http_code}" $url]
    
    if {[catch {exec -ignorestderr {*}$cmd} response]} {
        return [dict create code 0 body "" error $response]
    }

    set code [string trim [lindex [split $response "\n"] end]]
    set body [string trim [join [lrange [split $response "\n"] 0 end-1] "\n"]]
    
    set res [dict create code $code body $body error ""]

    if {$type eq "json" && $code == 200} {
        if {[catch {dict set res json [::json::json2dict $body]}]} {
            dict set res json {} ;
        }
    }
    return $res
}

proc parse_github_repo {url} {
    if {[regexp {github\.com/([^/]+/[^/.]+)} $url -> repo]} { return [string trimright $repo "/"] }
    return ""
}

proc process_git {url} {
    global env
    set tmp [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] "git-[expr {int(rand()*100000)}]"]
    set meta [dict create last_commit "" last_commit_sha "" last_tag "" error ""]

    try {
        exec git clone --depth 1 --filter=blob:none --no-checkout $url $tmp 2>@1
        
        set meta [dict merge $meta [dict create \
            last_commit     [exec git -C $tmp log -1 --format=%ci] \
            last_commit_sha [exec git -C $tmp rev-parse --short HEAD] \
            last_tag        [exec git -C $tmp tag --sort=-creatordate | head -n1] \
        ]]
    } on error {err} {
        dict set meta error "git_error: $err"
    } finally {
        file delete -force $tmp
    }
    return $meta
}

proc process_github_api {url} {
    set repo [parse_github_repo $url]
    if {$repo eq ""} { return {} }

    set meta [dict create archived "" latest_release ""]
    
    set r [http_get "https://api.github.com/repos/$repo" "json"]
    if {[dict exists $r json archived]} {
        dict set meta archived [dict get $r json archived]
    }

    set r [http_get "https://api.github.com/repos/$repo/releases/latest" "json"]
    if {[dict exists $r json tag_name]} {
        dict set meta latest_release [dict get $r json tag_name]
    }

    set r [http_get "https://api.github.com/repos/$repo/commits?per_page=1" "json"]
    if {[llength [dict get $r json]] > 0} {
        set c [lindex [dict get $r json] 0]
        dict set meta last_commit [string map {T " " Z ""} [dict get $c commit committer date]]
        dict set meta last_commit_sha [string range [dict get $c sha] 0 6]
    }

    return $meta
}

proc extract_fossil_base {url} {
    set base [lindex [split $url ?] 0]
    foreach p {/dir /file /timeline /info /json /home /index} {
        if {[set idx [string first $p $base]] >= 0} {
            return [string trimright [string range $base 0 $idx-1] "/"]
        }
    }
    return [string trimright $base "/"]
}

proc process_fossil {url} {
    global FOSSIL_MIRRORS
    set base [extract_fossil_base $url]
    set meta [dict create last_commit "" last_commit_sha "" last_tag "" last_commit_approximate false]

    puts "    [fossil] trying JSON API..."
    set r [http_get "$base/json/timeline?type=ci&limit=1" "json"]
    if {[dict get $r code] == 200} {
        set tl [dict get $r json payload timeline]
        if {[llength $tl] > 0} {
            set entry [lindex $tl 0]
            dict set meta last_commit [expr {[dict exists $entry timestamp] ? [dict get $entry timestamp] : [dict get $entry mtime]}]
            dict set meta last_commit_sha [string range [dict get $entry uuid] 0 9]
        }

        set r_tag [http_get "$base/json/taglist" "json"]
        if {[dict get r_tag code] == 200} {
            set tags [dict get $r_tag json payload tags]
            if {[llength $tags] > 0} { dict set meta last_tag [dict get [lindex $tags 0] name] }
        }
        return $meta
    }

    if {[info exists FOSSIL_MIRRORS($base)]} {
        puts "    [fossil] trying GitHub mirror..."
        set gh_meta [process_github_api $FOSSIL_MIRRORS($base)]
        if {[dict exists $gh_meta last_commit]} {
            dict set meta last_commit [dict get $gh_meta last_commit]
            dict set meta last_commit_sha [dict get $gh_meta last_commit_sha]
            try {
                set tags [exec git ls-remote --tags --refs --sort=-v:refname $FOSSIL_MIRRORS($base) | head -n1]
                regexp {refs/tags/(.*)} $tags -> tag
                dict set meta last_tag $tag
            }
            return $meta
        }
    }

    puts "    [fossil] fallback to HTML..."
    set r [http_get "$base/timeline?n=1"]
    if {[dict get $r code] == 200} {
        set html [dict get $r body]
        if {[regexp {(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})} $html -> date]} {
            dict set meta last_commit $date
            dict set meta last_commit_approximate true
        }
    }

    return $meta
}

proc to_huddle {val type} {
    if {$val eq ""} { return [huddle null] }
    if {$type eq "bool"} { return [huddle boolean $val] }
    return [huddle string $val]
}

proc main {} {
    global INPUT_FILE OUTPUT_FILE
    
    puts "Reading $INPUT_FILE..."
    set fh [open $INPUT_FILE r]; fconfigure $fh -encoding utf-8; set data [read $fh]; close $fh
    set packages [::json::json2dict $data]
    
    set out_list [huddle list]
    huddle append out_list [huddle create generated_at [huddle string [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]]]

    foreach pkg $packages {
        set name [dict get $pkg name]
        puts "\nProcessing: $name"
        
        set enriched_sources [list]
        foreach src [dict get $pkg sources] {
            set url [dict get $src url]
            set method [dict get $src method]
            
            puts "  -> Checking $url ($method)"

            set check [http_get $url]
            set reachable [expr {[dict get $check code] >= 200 && [dict get $check code] < 400}]
            
            set meta [dict create reachable $reachable error "" archived "" latest_release "" last_commit "" last_tag ""]

            if {$reachable} {
                set gh_info [process_github_api $url]
                set meta [dict merge $meta $gh_info]

                # Infos spécifiques méthode
                if {$method eq "git"} {
                    set meta [dict merge $meta [process_git $url]]
                } elseif {$method eq "fossil"} {
                    set meta [dict merge $meta [process_fossil $url]]
                }
            } else {
                dict set meta error "unreachable (HTTP [dict get $check code])"
            }

            set h_src [huddle create]
            dict for {k v} $src { huddle append h_src $k [to_huddle $v str] }
            dict for {k v} $meta {
                if {$k in {reachable archived last_commit_approximate}} {
                    huddle append h_src $k [to_huddle $v bool]
                } else {
                    huddle append h_src $k [to_huddle $v str]
                }
            }
            lappend enriched_sources $h_src
        }

        set h_pkg [huddle create]
        huddle append h_pkg name [to_huddle $name str]
        huddle append h_pkg description [to_huddle [expr {[dict exists $pkg description]? [dict get $pkg description]:""}] str]
        
        set h_srcs [huddle list]
        foreach s $enriched_sources { huddle append h_srcs $s }
        huddle append h_pkg sources $h_srcs

        set h_tags [huddle list]
        if {[dict exists $pkg tags]} { foreach t [dict get $pkg tags] { huddle append h_tags [to_huddle $t str] } }
        huddle append h_pkg tags $h_tags

        huddle append out_list $h_pkg
    }

    set json [string map {\\/ /} [huddle jsondump $out_list "" ""]]

    file mkdir [file dirname $OUTPUT_FILE]
    set fh [open $OUTPUT_FILE w]
    puts -nonewline $fh $json
    close $fh
    puts "\nDone. Saved to $OUTPUT_FILE"
}

main
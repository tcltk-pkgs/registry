package require huddle
package require json

set INPUT_FILE  "packages.json"
set OUTPUT_FILE "metadata/packages-meta.json"
set TIMEOUT 12
set MAX_COMMITS 5

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

    set hdrs [list -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28"]
    if {[info exists env(GITHUB_TOKEN)]} {
        lappend hdrs -H "Authorization: Bearer $env(GITHUB_TOKEN)"
    }

    set cmd [list curl -s -L --no-keepalive --max-time $TIMEOUT {*}$hdrs -w "\n%{http_code}" $url]

    if {[catch {exec -ignorestderr {*}$cmd} response]} {
        return [dict create code 0 body "" json {}]
    }

    set lines [split $response "\n"]
    set code [string trim [lindex $lines end]]
    set body [string trim [join [lrange $lines 0 end-1] "\n"]]

    set json {}
    if {$type eq "json" && $code == 200} {
        catch {set json [::json::json2dict $body]}
    }
    return [dict create code $code body $body json $json]
}

proc fetch_github_data {url {module_path ""}} {
    global github_cache MAX_COMMITS
    set repo [parse_github_repo $url]
    if {$repo eq ""} { return {} }

    set commit_key "${repo}:${module_path}"

    if {![dict exists $github_cache $repo]} {
        set info [dict create archived 0 latest_release "none"]

        set r [http_get "https://api.github.com/repos/$repo" "json"]

        if {[dict get $r code] == 200} {
            set json [dict get $r json]
            if {[dict exists $json archived]} {
                dict set info archived [dict get $json archived]
            }
        }

        set r_rel [http_get "https://api.github.com/repos/$repo/releases/latest" "json"]
        if {[dict get $r_rel code] == 200} {
            set json [dict get $r_rel json]
            if {[dict exists $json tag_name]} {
                dict set info latest_release [dict get $json tag_name]
            }
        }
        dict set github_cache $repo $info
    }

    if {![dict exists $github_cache $commit_key]} {
        set cdata [dict create last_commit {} last_commit_sha {}]

        set api_url "https://api.github.com/repos/$repo/commits?per_page=$MAX_COMMITS"
        if {$module_path ne ""} { append api_url "&path=$module_path" }

        set r [http_get $api_url "json"]

        if {[dict get $r code] == 200} {
            set commits [dict get $r json]
            if {[llength $commits] > 0} {
                foreach c $commits {
                    if {[dict exists $c sha] && [dict exists $c commit committer date]} {
                        set sha [string range [dict get $c sha] 0 6]
                        set date [string map {T " " Z ""} [dict get $c commit committer date]]
                        dict lappend cdata last_commit_sha $sha
                        dict lappend cdata last_commit $date
                    }
                }
            }
        }
        dict set github_cache $commit_key $cdata
    }

    return [dict merge [dict get $github_cache $repo] [dict get $github_cache $commit_key]]
}

proc process_fossil {url} {
    global FOSSIL_MIRRORS fossil_cache MAX_COMMITS

    if {[dict exists $fossil_cache $url]} {
        return [dict get $fossil_cache $url]
    }

    set base [lindex [split $url ?] 0]
    foreach p {/dir /file /timeline /info /json} {
        if {[set idx [string first $p $base]] >= 0} {
            set base [string range $base 0 $idx-1]
        }
    }
    set base [string trimright $base "/"]

    set module_path ""
    if {[regexp {[?&]name=([^&]+)} $url -> p]} { set module_path $p }

    set meta [dict create last_commit {} last_commit_sha {} last_tag ""]

    set api_url "$base/json/timeline?type=ci&limit=$MAX_COMMITS"
    if {$module_path ne ""} { append api_url "&p=$module_path" }

    set r [http_get $api_url "json"]

    if {[dict get $r code] == 200} {
        set json [dict get $r json]
        if {[dict exists $json payload] && [dict exists $json payload timeline]} {
            set tl [dict get $json payload timeline]
            foreach entry $tl {
                set ts [expr {[dict exists $entry timestamp] ? [dict get $entry timestamp] : [dict get $entry mtime]}]
                dict lappend meta last_commit $ts
                dict lappend meta last_commit_sha [string range [dict get $entry uuid] 0 9]
            }
        }
    }

    if {[info exists FOSSIL_MIRRORS($base)]} {
        set mirror $FOSSIL_MIRRORS($base)
        set gh [fetch_github_data $mirror $module_path]

        if {[llength [dict get $meta last_commit]] == 0} {
            dict set meta last_commit [dict get $gh last_commit]
            dict set meta last_commit_sha [dict get $gh last_commit_sha]
        }

        dict set meta archived [dict get $gh archived]
        dict set meta latest_release [dict get $gh latest_release]

        catch {
            set raw_tags [exec git ls-remote --tags --refs $mirror]
            set tag_list {}
            foreach line [split $raw_tags "\n"] {
                if {[regexp {refs/tags/(.*)} $line -> t]} { lappend tag_list $t }
            }
            dict set meta last_tag [get_latest_tag $tag_list]
        }
    }

    dict set fossil_cache $url $meta
    return $meta
}

proc process_git {url} {
    global env MAX_COMMITS
    set repo [parse_github_repo $url]

    if {$repo ne ""} {
        set meta [fetch_github_data $url]
        dict set meta last_tag [dict get $meta latest_release]

        if {[dict get $meta last_tag] eq ""} {
             catch {
                set raw_tags [exec git ls-remote --tags --refs $url]
                set tag_list {}
                foreach line [split $raw_tags "\n"] {
                    if {[regexp {refs/tags/(.*)} $line -> t]} { lappend tag_list $t }
                }
                dict set meta last_tag [get_latest_tag $tag_list]
            }
        }
        return $meta
    }

    set meta [dict create last_commit {} last_commit_sha {} last_tag ""]
    set tmp [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] "git-[expr {int(rand()*10000)}]"]

    try {
        exec git clone --depth $MAX_COMMITS --filter=blob:none --no-checkout $url $tmp 2>@1

        set log_output [exec git -C $tmp log -$MAX_COMMITS --format=%ci|%h 2>@1]

        if {[string trim $log_output] ne ""} {
            foreach line [split $log_output "\n"] {
                set line [string trim $line]
                if {$line eq ""} continue

                set sep [string first "|" $line]
                if {$sep > 0} {
                    set date [string range $line 0 $sep-1]
                    set sha [string range $line $sep+1 end]
                    dict lappend meta last_commit $date
                    dict lappend meta last_commit_sha $sha
                }
            }
        }

        set t_out [exec git -C $tmp tag]
        dict set meta last_tag [get_latest_tag [split $t_out "\n"]]
    } finally {
        file delete -force $tmp
    }
    return $meta
}

proc get_latest_tag {tag_list} {
    set skip {trunk tip release branch main HEAD}
    set filtered {}
    foreach tag $tag_list {
        set tag [string trim $tag]
        if {$tag eq "" || [lsearch -nocase $skip $tag] >= 0} continue
        if {[regexp {\d} $tag]} { lappend filtered $tag }
    }
    if {[llength $filtered] == 0} { return "" }
    return [lindex [lsort -command version_compare $filtered] end]
}

proc version_compare {a b} {
    set na [regexp -all -inline {\d+} $a]
    set nb [regexp -all -inline {\d+} $b]
    set len [expr {max([llength $na],[llength $nb])}]
    for {set i 0} {$i < $len} {incr i} {
        set va [expr {$i < [llength $na] ? [lindex $na $i] : 0}]
        set vb [expr {$i < [llength $nb] ? [lindex $nb $i] : 0}]
        if {$va < $vb} { return -1 }
        if {$va > $vb} { return  1 }
    }
    return 0
}

proc get_package_add_date {name input_file} {
    set patterns [list "\"name\": \"$name\"" "\"name\":\"$name\"" "\"name\" : \"$name\""]
    foreach pattern $patterns {
        set cmd [list git log --first-parent --format=%aI --diff-filter=A -S $pattern --reverse -- $input_file]
        if {![catch {exec -ignorestderr {*}$cmd} result]} {
            set result [string trim $result]
            if {$result ne ""} { return [lindex [split $result "\n"] 0] }
        }
    }
    return ""
}

proc load_existing_dates {} {
    global OUTPUT_FILE existing_dates

    if {[file exists $OUTPUT_FILE]} {
        set fh [open $OUTPUT_FILE r]
        set data [read $fh]
        close $fh

        catch {
            set old_packages [::json::json2dict $data]
            foreach pkg $old_packages {
                if {[dict exists $pkg name] && [dict exists $pkg sources]} {
                    set name [dict get $pkg name]
                    set srcs [dict get $pkg sources]
                    if {[llength $srcs] > 0 && [dict exists [lindex $srcs 0] added_at]} {
                        set existing_dates($name) [dict get [lindex $srcs 0] added_at]
                    }
                }
            }
        }
    }
}

proc main {} {
    global INPUT_FILE OUTPUT_FILE existing_dates MAX_COMMITS

    load_existing_dates

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
    set new_count 0

    foreach pkg $packages {
        incr idx
        set name [dict get $pkg name]
        puts "\[$idx/$total\] Processing: $name"

        if {[info exists existing_dates($name)]} {
            set pkg_date $existing_dates($name)
            puts "    -> Existing package, preserving date: $pkg_date"
        } else {
            set git_date [get_package_add_date $name $INPUT_FILE]
            if {$git_date ne ""} {
                set pkg_date $git_date
                puts "    -> NEW PACKAGE (commit date): $pkg_date"
            } else {
                set pkg_date [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
                puts "    -> NEW PACKAGE (current date fallback): $pkg_date"
            }
            incr new_count
        }

        set enriched_sources {}
        foreach src [dict get $pkg sources] {
            set url [dict get $src url]
            set method [expr {[dict exists $src method] ? [dict get $src method] : ""}]

            puts "  - Checking source: $url (Method: $method)"

            set check [http_get $url]
            set code [dict get $check code]
            set reachable [expr {$code >= 200 && $code < 400}]

            set meta [dict create reachable $reachable archived 0 latest_release "none" last_commit {} last_tag "" last_commit_sha {}]

            if {$reachable} {
                if {$method eq "fossil"} {
                    set meta [dict merge $meta [process_fossil $url]]
                } elseif {$method eq "git"} {
                    set meta [dict merge $meta [process_git $url]]
                }
            } else {
                puts "    ! Source unreachable (HTTP $code)"
            }


            set nb_commits [llength [dict get $meta last_commit]]
            puts "    -> Found $nb_commits commit(s)"

            set h_src [huddle create]
            dict for {k v} $src { huddle append h_src $k [to_huddle $v str] }


            dict for {k v} $meta {
                if {$k in {reachable archived}} {
                    huddle append h_src $k [to_huddle $v bool]
                } elseif {$k in {last_commit last_commit_sha}} {

                    huddle append h_src $k [to_huddle $v list]
                } else {
                    huddle append h_src $k [to_huddle $v str]
                }
            }

            huddle append h_src added_at [huddle string $pkg_date]

            lappend enriched_sources $h_src
        }

        set h_pkg [huddle create]
        huddle append h_pkg name [to_huddle $name str]

        set desc ""
        if {[dict exists $pkg description]} { set desc [dict get $pkg description] }
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
    puts -nonewline $fh [string map {\\/ /} [huddle jsondump $out_list "" ""]]
    close $fh

    puts "\nDone: $OUTPUT_FILE"
    puts "Total: $total packages ($new_count new)"
    puts "Commits per package: up to $MAX_COMMITS"
}

main
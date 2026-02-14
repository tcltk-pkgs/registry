package require huddle
package require json

set INPUT_FILE  "packages.json"
set OUTPUT_FILE "metadata/packages-meta.json"

array set FOSSIL_GIT_MIRRORS {
    "https://core.tcl-lang.org/tcllib"  "https://github.com/tcltk/tcllib"
    "https://core.tcl-lang.org/tcl"     "https://github.com/tcltk/tcl"
    "https://core.tcl-lang.org/tk"      "https://github.com/tcltk/tk"
}

set fossil_date_cache  [dict create]
set fossil_repo_cache  [dict create]
set github_repo_cache  [dict create]

proc run_cmd {cmd {cwd ""} {timeout 15}} {
    set opts [list]
    if {$cwd ne ""} { lappend opts -directory $cwd }

    set pipe ""
    if {[catch {
        set pipe [open "|$cmd 2>@stderr" r]
        fconfigure $pipe -translation binary
        set out [read $pipe]
        close $pipe
        set out [string trimright $out "\n"]
    } err]} {
        puts stderr "    \[cmd error\] $err"
        catch {close $pipe}
        return ""
    }
    return $out
}

proc run_curl {url {timeout 20} {extra_headers ""}} {
    set cmd "curl -s -L --max-time $timeout $extra_headers \
        -w {\\n__HTTP_CODE__%{http_code}} \"$url\""
    set raw [run_cmd $cmd "" [expr {$timeout + 5}]]
    if {[string first "__HTTP_CODE__" $raw] >= 0} {
        set idx   [string last "__HTTP_CODE__" $raw]
        set body  [string trimright [string range $raw 0 $idx-1]]
        set code  [string trim [string range $raw $idx+13 end]]
        if {![string is integer -strict $code]} { set code 0 }
    } else {
        set body [string trim $raw]
        set code 0
    }
    return [list $body $code]
}

proc check_url_reachable {url {timeout 10}} {
    set cmd "curl -s -I -L --max-time $timeout -o /dev/null \
        -w {%{http_code}} \"$url\""
    set raw [string trim [run_cmd $cmd "" [expr {$timeout + 5}]]]
    set code [expr {[string is integer -strict $raw] ? $raw : 0}]
    set reachable [expr {$code >= 200 && $code < 400}]
    return [list $reachable $code]
}

proc github_headers {} {
    set token [expr {[info exists ::env(GITHUB_TOKEN)] ? $::env(GITHUB_TOKEN) : ""}]
    set h "-H {Accept: application/vnd.github+json} -H {X-GitHub-Api-Version: 2022-11-28}"
    if {$token ne ""} { set h "-H {Authorization: Bearer $token} $h" }
    return $h
}

proc parse_github_repo {url} {
    if {[regexp {https://github\.com/([^/]+/[^/.]+)} $url -> repo]} {
        return [string trimright $repo "/"]
    }
    return ""
}

proc fetch_github_repo_info {github_url} {
    global github_repo_cache
    set repo [parse_github_repo $github_url]
    if {$repo eq ""} {
        return [dict create archived "" latest_release ""]
    }
    if {[dict exists $github_repo_cache $repo]} {
        return [dict get $github_repo_cache $repo]
    }

    set hdrs [github_headers]
    set result [dict create archived "" latest_release ""]

    lassign [run_curl "https://api.github.com/repos/$repo" 15 $hdrs] body code
    if {$body ne "" && $code == 200} {
        if {![catch {set data [::json::json2dict $body]}]} {
            if {[dict exists $data archived]} {
                dict set result archived [dict get $data archived]
            }
        }
    }

    lassign [run_curl "https://api.github.com/repos/$repo/releases/latest" 15 $hdrs] body code
    if {$body ne "" && $code == 200} {
        if {![catch {set data [::json::json2dict $body]}]} {
            if {[dict exists $data tag_name]} {
                dict set result latest_release [dict get $data tag_name]
            }
        }
    }

    dict set github_repo_cache $repo $result
    return $result
}

proc github_api_commit {git_url module_path} {
    set repo [parse_github_repo $git_url]
    if {$repo eq ""} { return [list "" ""] }

    set api_url "https://api.github.com/repos/$repo/commits?per_page=1"
    if {$module_path ne ""} { append api_url "&path=$module_path" }

    set hdrs [github_headers]
    set cmd "curl -s -L --max-time 20 $hdrs \
        -w {\\n__HTTP_CODE__%{http_code}} \"$api_url\""
    set raw [run_cmd $cmd "" 25]

    if {[string first "__HTTP_CODE__" $raw] >= 0} {
        set idx  [string last "__HTTP_CODE__" $raw]
        set body [string trimright [string range $raw 0 $idx-1]]
        set code [string trim [string range $raw $idx+13 end]]
        if {![string is integer -strict $code]} { set code 0 }
    } else {
        set body $raw ; set code 0
    }
    set body [string trim $body]

    if {$code == 403} {
        puts stderr "    \[github\] rate limited (HTTP 403)"
        return [list "" ""]
    }
    if {$body eq "" || $code != 200} {
        puts stderr "    \[github\] API failed (http=$code)"
        return [list "" ""]
    }

    if {[catch {set data [::json::json2dict $body]} err]} {
        puts stderr "    \[github\] JSON parse error: $err"
        return [list "" ""]
    }
    if {[llength $data] == 0} { return [list "" ""] }
    set commit [lindex $data 0]
    set sha    [string range [dict get $commit sha] 0 6]
    set ci     [dict get $commit commit]
    set date   ""
    catch { set date [dict get $ci committer date] }
    if {$date eq ""} { catch { set date [dict get $ci author date] } }
    set date [string map {T " "} [string trimright $date "Z"]]
    return [list $date $sha]
}

proc extract_fossil_base {url} {
    set base [lindex [split $url ?] 0]
    set base [string trimright $base "/"]
    foreach page {/dir /file /doc /wiki /ticket /timeline
                  /info /artifact /raw /zip /tarball /json /index /home} {
        set idx [string first $page $base]
        if {$idx >= 0} {
            set base [string trimright [string range $base 0 $idx-1] "/"]
            break
        }
    }
    return $base
}

proc extract_module_path {source_url} {
    if {[regexp {[?&]name=([^&]+)} $source_url -> path]} { return $path }
    return ""
}

proc parse_fossil_date_from_html {html} {
    set date ""
    set sha  ""

    if {[regexp {timelineHistDsp[^>]*>\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})} \
                $html -> date]} {}

    if {$date eq "" && \
        [regexp {timelineDateCell[^>]*>\s*<[^>]*>\s*(\d{4}-\d{2}-\d{2})} \
                $html -> date]} {}

    if {$date eq "" && \
        [regexp {(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})} $html -> date]} {}

    if {[regexp {/info/([0-9a-f]{10,40})} $html -> m]} {
        set sha [string range $m 0 9]
    } elseif {[regexp {[?&]c=([0-9a-f]{10,40})} $html -> m]} {
        set sha [string range $m 0 9]
    }
    return [list $date $sha]
}

proc pick_version_tag {html} {
    set skip {trunk tip release branch main HEAD}
    set candidates [regexp -all -inline {timeline\?[tr]=([^"'&>\s]+)} $html]
    foreach {- tag} $candidates {
        set tag [string trim $tag]
        if {[lsearch -nocase $skip $tag] >= 0} { continue }
        if {[regexp {\d} $tag]} { return $tag }
    }
    return ""
}

proc latest_tag_from_git_mirror {git_url} {
    set out [run_cmd "git ls-remote --tags --refs \"$git_url\"" "" 30]
    if {$out eq ""} { return "" }
    set tags [list]
    foreach line [split $out "\n"] {
        if {[regexp {[0-9a-f]+\s+refs/tags/(.+)} $line -> tag]} {
            set tag [string trim $tag]
            if {[regexp {\d} $tag]} { lappend tags $tag }
        }
    }
    if {$tags eq {}} { return "" }
    set sorted [lsort -command version_compare $tags]
    return [lindex $sorted end]
}

proc version_compare {a b} {
    regexp -all -inline {\d+} $a
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

proc fetch_fossil_date {base module_path meta_var} {
    upvar $meta_var meta
    global FOSSIL_GIT_MIRRORS

    set fossil_date "" ; set fossil_sha ""
    set github_date "" ; set github_sha ""

    set api_url "$base/json/timeline?type=ci&limit=1"
    if {$module_path ne ""} { append api_url "&p=$module_path" }
    lassign [run_curl $api_url 20] body code
    if {$body ne "" && $code == 200} {
        if {![catch {set data [::json::json2dict $body]}]} {
            set tl ""
            catch { set tl [dict get $data payload timeline] }
            if {$tl eq ""} { catch { set tl [dict get $data timeline] } }
            if {$tl ne "" && [llength $tl] > 0} {
                set entry [lindex $tl 0]
                catch { set fossil_date [dict get $entry timestamp] }
                if {$fossil_date eq ""} { catch { set fossil_date [dict get $entry mtime] } }
                set sha ""
                catch { set sha [dict get $entry uuid] }
                if {$sha eq ""} { catch { set sha [dict get $entry hash] } }
                set fossil_sha [string range $sha 0 9]
                puts "    \[fossil\] JSON API: $fossil_date"
            }
        }
    } elseif {$code == 404} {
        puts "    \[fossil\] JSON API not available (404)"
    } else {
        puts stderr "    \[fossil\] JSON API failed (http=$code)"
    }

    if {[info exists FOSSIL_GIT_MIRRORS($base)]} {
        set mirror $FOSSIL_GIT_MIRRORS($base)
        puts "    \[fossil\] trying GitHub mirror: $mirror path=$module_path"
        lassign [github_api_commit $mirror $module_path] github_date github_sha
        if {$github_date ne ""} { puts "    \[fossil\] GitHub mirror: $github_date" }
    }

    if {$github_date ne ""} {
        dict set meta last_commit     $github_date
        dict set meta last_commit_sha $github_sha
        if {$fossil_date ne ""} {
            puts "    \[fossil\] winner=GitHub: $github_date (fossil=$fossil_date)"
        } else {
            puts "    \[fossil\] winner=GitHub: $github_date"
        }
        return
    }
    if {$fossil_date ne ""} {
        dict set meta last_commit     $fossil_date
        dict set meta last_commit_sha $fossil_sha
        puts "    \[fossil\] winner=Fossil: $fossil_date"
        return
    }

    puts "    \[fossil\] trying HTML (whole-repo, approximate)"
    lassign [run_curl "$base/timeline?n=1" 20] html code
    if {$html ne "" && $code == 200} {
        lassign [parse_fossil_date_from_html $html] date sha
        if {$date ne ""} {
            dict set meta last_commit             $date
            dict set meta last_commit_sha         $sha
            dict set meta last_commit_approximate true
            puts "    \[fossil\] HTML (approximate): $date"
            return
        }
    }
    dict set meta error "date_not_found"
}

proc fetch_fossil_tag {base meta_var} {
    upvar $meta_var meta
    global FOSSIL_GIT_MIRRORS

    set tag ""

    lassign [run_curl "$base/json/taglist" 15] body code
    if {$body ne "" && $code == 200} {
        if {![catch {set data [::json::json2dict $body]}]} {
            set raw ""
            catch { set raw [dict get $data payload tags] }
            if {$raw eq ""} { catch { set raw [dict get $data tags] } }
            if {$raw ne "" && [llength $raw] > 0} {
                set first [lindex $raw 0]
                catch { set tag [dict get $first name] }
                if {$tag eq ""} { catch { set tag [dict get $first tagname] } }
            }
        }
    }

    if {$tag eq ""} {
        foreach endpoint [list "$base/taglist" "$base/brlist"] {
            lassign [run_curl $endpoint 15] body code
            if {$body ne "" && $code == 200} {
                set tag [pick_version_tag $body]
                if {$tag ne ""} break
            }
        }
    }

    if {$tag eq "" && [info exists FOSSIL_GIT_MIRRORS($base)]} {
        set mirror $FOSSIL_GIT_MIRRORS($base)
        puts "    \[fossil\] trying Git mirror for tags: $mirror"
        set tag [latest_tag_from_git_mirror $mirror]
        if {$tag ne ""} { puts "    \[fossil\] tag from Git mirror: $tag" }
    }

    if {$tag ne ""} {
        dict set meta last_tag $tag
    } else {
        puts stderr "    \[fossil\] no tag found"
    }
}

proc process_fossil {url} {
    global fossil_date_cache fossil_repo_cache

    set base        [extract_fossil_base $url]
    set module_path [extract_module_path $url]
    puts "    \[fossil\] base=$base  module=[expr {$module_path ne {} ? $module_path : {(whole repo)}}]"

    if {[dict exists $fossil_date_cache $url]} {
        puts "    \[fossil\] date cache hit"
        set date_meta [dict get $fossil_date_cache $url]
    } else {
        set date_meta [dict create last_commit "" last_commit_sha ""]
        fetch_fossil_date $base $module_path date_meta
        dict set fossil_date_cache $url $date_meta
    }

    if {[dict exists $fossil_repo_cache $base]} {
        puts "    \[fossil\] tag cache hit"
        set tag_meta [dict get $fossil_repo_cache $base]
    } else {
        set tag_meta [dict create last_tag ""]
        fetch_fossil_tag $base tag_meta
        dict set fossil_repo_cache $base $tag_meta
    }

    return [dict merge $date_meta $tag_meta]
}

proc process_git {url} {
    set tmpdir [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] "git-[clock seconds]-[expr {int(rand()*9999)}]"]
    set meta   [dict create last_commit "" last_commit_sha "" last_tag ""]

    if {[catch {
        set r [run_cmd "git clone --depth 1 --filter=blob:none --no-checkout \"$url\" \"$tmpdir\"" "" 30]
        if {$r eq "" && ![file isdirectory $tmpdir]} {
            puts stderr "    \[git\] clone failed: $url"
            dict set meta error "clone_failed"
            return $meta
        }
        set d [run_cmd "git log -1 --format=%ci" $tmpdir]
        if {$d ne ""} { dict set meta last_commit $d }

        set s [run_cmd "git rev-parse --short HEAD" $tmpdir]
        if {$s ne ""} { dict set meta last_commit_sha $s }

        set t [run_cmd "git tag --sort=-creatordate" $tmpdir]
        if {$t ne ""} {
            set tags [lsearch -all -inline -not [split $t "\n"] ""]
            if {[llength $tags] > 0} {
                dict set meta last_tag [string trim [lindex $tags 0]]
            }
        }
    } err]} {
        puts stderr "    \[git error\] $err"
        dict set meta error $err
    }

    catch { file delete -force $tmpdir }
    return $meta
}

proc huddle_or_null {val} {
    if {$val eq ""} { return [huddle null] }
    return [huddle string $val]
}

proc huddle_bool_or_null {val} {
    if {$val eq ""} { return [huddle null] }
    if {$val in {true 1}} { return [huddle true] }
    return [huddle false]
}

proc dict_to_huddle_map {d} {
    set hmap [huddle create]
    dict for {k v} $d {
        switch -exact -- $k {
            reachable - archived - last_commit_approximate {
                huddle append hmap $k [huddle_bool_or_null $v]
            }
            default {
                huddle append hmap $k [huddle_or_null $v]
            }
        }
    }
    return $hmap
}

proc build_source_huddle {source_dict} {
    return [dict_to_huddle_map $source_dict]
}

proc build_package_huddle {pkg_dict} {
    set h [huddle create]

    huddle append h name [huddle string [dict get $pkg_dict name]]

    set src_list [huddle list]
    foreach src [dict get $pkg_dict sources] {
        huddle append src_list [build_source_huddle $src]
    }
    huddle append h sources $src_list

    set tag_list [huddle list]
    foreach tag [dict get $pkg_dict tags] {
        huddle append tag_list [huddle string $tag]
    }
    huddle append h tags $tag_list

    huddle append h description [huddle string [dict get $pkg_dict description]]
    return $h
}

proc main {} {
    global INPUT_FILE OUTPUT_FILE FOSSIL_GIT_MIRRORS

    puts "Generating $OUTPUT_FILE..."

    file mkdir [file dirname $OUTPUT_FILE]

    set fh [open $INPUT_FILE r]
    fconfigure $fh -encoding utf-8
    set raw [read $fh]
    close $fh

    set packages [::json::json2dict $raw]
    set total    [llength $packages]
    puts "$total packages to process"

    set out_list [huddle list]

    set ts [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
    set header [huddle create]
    huddle append header packages    [huddle string "Tcl/Tk"]
    huddle append header generated_at [huddle string $ts]
    huddle append out_list $header

    set idx 0
    foreach pkg $packages {
        incr idx
        set name [dict get $pkg name]
        puts "\[$idx/$total\] $name"

        set enriched_sources [list]

        foreach source [dict get $pkg sources] {
            set method [expr {[dict exists $source method] ? [dict get $source method] : ""}]
            set url    [expr {[dict exists $source url]    ? [dict get $source url]    : ""}]
            puts "  -> $method: [string range $url 0 69]..."

            lassign [check_url_reachable $url] reachable http_code
            puts "    \[check\] reachable=$reachable (http=$http_code)"

            if {!$reachable} {
                puts stderr "    \[skip\] URL unreachable"
                set esrc $source
                dict set esrc reachable  false
                dict set esrc archived   ""
                dict set esrc latest_release ""
                dict set esrc last_commit    ""
                dict set esrc last_commit_sha ""
                dict set esrc last_tag       ""
                dict set esrc error "unreachable_http_$http_code"

            } elseif {$method ni {git fossil}} {
                puts stderr "    \[skip\] unknown method '$method'"
                set esrc $source
                dict set esrc reachable  $reachable
                dict set esrc archived   ""
                dict set esrc latest_release ""
                dict set esrc last_commit    ""
                dict set esrc last_commit_sha ""
                dict set esrc last_tag       ""
                dict set esrc error "unknown_method_$method"

            } else {
                if {$method eq "git"} {
                    set meta [process_git $url]
                } else {
                    set meta [process_fossil $url]
                }

                set gh_info [fetch_github_repo_info $url]
                if {[dict get $gh_info archived] eq "" && $method eq "fossil"} {
                    set fossil_base [extract_fossil_base $url]
                    if {[info exists FOSSIL_GIT_MIRRORS($fossil_base)]} {
                        set gh_info [fetch_github_repo_info $FOSSIL_GIT_MIRRORS($fossil_base)]
                    }
                }
                if {[dict get $gh_info archived] ne ""} {
                    puts "    \[github\] archived=[dict get $gh_info archived]  release=[dict get $gh_info latest_release]"
                }

                set esrc [dict merge $source \
                    [dict create \
                        reachable       $reachable \
                        archived        [dict get $gh_info archived] \
                        latest_release  [dict get $gh_info latest_release] \
                    ] \
                    $meta \
                    [dict create error [expr {[dict exists $meta error] ? [dict get $meta error] : "none"}]] \
                ]
            }
            lappend enriched_sources $esrc
        }

        set pkg_out [dict create \
            name        $name \
            sources     $enriched_sources \
            tags        [expr {[dict exists $pkg tags]        ? [dict get $pkg tags]        : {}}] \
            description [expr {[dict exists $pkg description] ? [dict get $pkg description] : {}}] \
        ]

        huddle append out_list [build_package_huddle $pkg_out]
    }

    set json_str [string map {\\/ /} [huddle jsondump $out_list "" ""]]

    set fh [open $OUTPUT_FILE w]
    puts -nonewline $fh $json_str
    close $fh

    set size [file size $OUTPUT_FILE]
    puts "File generated: $OUTPUT_FILE ($size bytes)"
}

main
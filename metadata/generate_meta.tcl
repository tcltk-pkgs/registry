package require huddle
package require huddle::json
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
set github_tree_cache [dict create]
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
    if {[regexp {github\.com/([^/]+/[^/]+)} $url -> repo]} {
        return [string trimright $repo "/"]
    }
    return ""
}

proc parse_module_name {name} {
    set idx [string last "::" $name]
    if {$idx >= 0} {
        return [string range $name $idx+2 end]
    }
    return ""
}

proc http_url_encode {s} {
    set out ""
    foreach c [split $s ""] {
        if {[string match {[A-Za-z0-9./_-]} $c]} {
            append out $c
        } else {
            append out [format %%%02X [scan $c %c]]
        }
    }
    return $out
}

proc http_get {url {type "raw"} {retry 2}} {
    global env TIMEOUT

    set hdrs {}

    if {[string match "*api.github.com*" $url]} {
        lappend hdrs -H "Accept: application/vnd.github+json"
        lappend hdrs -H "X-GitHub-Api-Version: 2022-11-28"
        if {[info exists env(GITHUB_TOKEN)]} {
            lappend hdrs -H "Authorization: Bearer $env(GITHUB_TOKEN)"
        }
    }

    set cmd [list curl -s -L --no-keepalive --max-time $TIMEOUT {*}$hdrs -w "\n%{http_code}" $url]

    if {[catch {exec -ignorestderr {*}$cmd} response]} {
        return [dict create code 0 body "" json {}]
    }

    set lines [split $response "\n"]
    set code [string trim [lindex $lines end]]
    set body [string trim [join [lrange $lines 0 end-1] "\n"]]

    if {$code in {502 503 429} && $retry > 0} {
        after 1500
        return [http_get $url $type [expr {$retry - 1}]]
    }

    set json {}
    if {$type eq "json" && $code == 200} {
        catch {set json [::json::json2dict $body]}
    }

    return [dict create code $code body $body json $json]
}

proc ensure_repo_info {repo} {
    global github_cache

    if {[dict exists $github_cache $repo]} {
        return [dict get $github_cache $repo]
    }

    set info [dict create archived 0 latest_release "none" last_release_date "" default_branch "main"]

    set r [http_get "https://api.github.com/repos/$repo" "json"]
    if {[dict get $r code] == 200} {
        set json [dict get $r json]
        if {[dict exists $json archived]} {
            dict set info archived [dict get $json archived]
        }
        if {[dict exists $json default_branch]} {
            dict set info default_branch [dict get $json default_branch]
        }
    }

    set r_rel [http_get "https://api.github.com/repos/$repo/releases/latest" "json"]
    if {[dict get $r_rel code] == 200} {
        set json [dict get $r_rel json]
        if {[dict exists $json tag_name]} {
            dict set info latest_release [dict get $json tag_name]
        }
        if {[dict exists $json published_at]} {
            set pub_date [dict get $json published_at]
            set pub_date [string map {T " " Z ""} $pub_date]
            dict set info last_release_date $pub_date
        }
    }

    dict set github_cache $repo $info
    return $info
}

proc fetch_commits {repo module_path} {
    global github_cache MAX_COMMITS

    set commit_key "${repo}:${module_path}"

    if {[dict exists $github_cache $commit_key]} {
        return [dict get $github_cache $commit_key]
    }

    set cdata [dict create last_commit {} last_commit_sha {}]

    set api_url "https://api.github.com/repos/$repo/commits?per_page=$MAX_COMMITS"
    if {$module_path ne ""} { append api_url "&path=[http_url_encode $module_path]" }

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
    return $cdata
}

proc fetch_github_data {url {module_path ""}} {
    set repo [parse_github_repo $url]
    if {$repo eq ""} { return {} }

    set info  [ensure_repo_info $repo]
    set cdata [fetch_commits $repo $module_path]

    return [dict merge $info $cdata]
}

proc get_repo_tree {repo branch} {
    global github_tree_cache

    if {[dict exists $github_tree_cache $repo]} {
        return [dict get $github_tree_cache $repo]
    }

    set paths {}
    set r [http_get "https://api.github.com/repos/$repo/git/trees/[http_url_encode $branch]?recursive=1" "json"]

    if {[dict get $r code] == 200} {
        set json [dict get $r json]
        if {[dict exists $json tree]} {
            foreach entry [dict get $json tree] {
                if {
                    [dict exists $entry type] &&
                    [dict get $entry type] eq "blob" &&
                    [dict exists $entry path]
                } {
                    lappend paths [dict get $entry path]
                }
            }
        }
    }

    dict set github_tree_cache $repo $paths
    return $paths
}

proc pick_highest_version {paths} {
    set best   ""
    set best_v ""
    foreach p $paths {
        set fname [file tail $p]
        if {![regexp "--" {-([0-9.]+)\.(?:tcl|tm)$} $fname -> v]} {continue}
        if {$best eq "" || [version_compare $v $best_v] > 0} {
            set best   $p
            set best_v $v
        }
    }
    return $best
}

proc select_module_path {paths modname} {
    if {$modname eq ""} { return "" }

    set qmod [string map {. {\.} - {\-}} $modname]

    set tm_versioned  {}
    set tm_plain      {}
    set tcl_versioned {}
    set tcl_plain     {}

    foreach p $paths {
        set fname [file tail $p]
        if {[regexp -nocase "^${qmod}\\.tm\$" $fname]} {
            lappend tm_plain $p
        } elseif {[regexp -nocase "^${qmod}-\[0-9.\]+\\.tm\$" $fname]} {
            lappend tm_versioned $p
        } elseif {[regexp -nocase "^${qmod}\\.tcl\$" $fname]} {
            lappend tcl_plain $p
        } elseif {[regexp -nocase "^${qmod}-\[0-9.\]+\\.tcl\$" $fname]} {
            lappend tcl_versioned $p
        }
    }

    # Priority: versioned .tm, then plain .tm, then versioned .tcl, then plain .tcl.
    if {[llength $tm_versioned] > 0} {
        return [pick_highest_version $tm_versioned]
    }
    if {[llength $tm_plain] > 0} {
        return [lindex $tm_plain 0]
    }
    if {[llength $tcl_versioned] > 0} {
        return [pick_highest_version $tcl_versioned]
    }
    if {[llength $tcl_plain] > 0} {
        return [lindex $tcl_plain 0]
    }

    return {}
}

proc find_module_file {repo branch modname {dir_filter ""}} {
    if {$modname eq ""} { return "" }

    set paths [get_repo_tree $repo $branch]
    if {$dir_filter ne ""} {
        set filtered {}
        foreach p $paths {
            if {[string match "${dir_filter}/*" $p]} {
                lappend filtered $p
            }
        }
        set paths $filtered
    }

    return [select_module_path $paths $modname]
}

proc process_fossil {url {modname ""}} {
    global FOSSIL_MIRRORS fossil_cache MAX_COMMITS

    set cache_key "${url}:${modname}"
    if {[dict exists $fossil_cache $cache_key]} {
        return [dict get $fossil_cache $cache_key]
    }

    set base [lindex [split $url ?] 0]
    foreach p {/dir /file /timeline /info /json} {
        if {[set idx [string first $p $base]] >= 0} {
            set base [string range $base 0 $idx-1]
        }
    }
    set base [string trimright $base "/"]

    set dir_path ""
    if {[regexp {[?&]name=([^&]+)} $url -> p]} {
        set dir_path $p
    }

    set meta [dict create last_commit {} last_commit_sha {} last_tag "" \
        last_release_date "" latest_release "none"]

    # Github mirror check, prioritize if available for better metadata.
    if {[info exists FOSSIL_MIRRORS($base)]} {
        set mirror $FOSSIL_MIRRORS($base)

        set target_path $dir_path
        set repo [parse_github_repo $mirror]
        if {$modname ne "" && $repo ne ""} {
            set info   [ensure_repo_info $repo]
            set branch [dict get $info default_branch]
            set found  [find_module_file $repo $branch $modname $dir_path]
            if {$found ne ""} {
                set target_path $found
                puts "    -> Module file found: $target_path (targeted history)"
            } else {
                puts "    -> No file found for '$modname' in $dir_path, using directory history"
            }
        }

        set gh [fetch_github_data $mirror $target_path]

        dict set meta last_commit       [dict get $gh last_commit]
        dict set meta last_commit_sha   [dict get $gh last_commit_sha]
        dict set meta archived          [dict get $gh archived]
        dict set meta latest_release    [dict get $gh latest_release]
        dict set meta last_release_date [dict get $gh last_release_date]

        catch {
            set raw_tags [exec git ls-remote --tags --refs $mirror]
            set tag_list {}
            foreach line [split $raw_tags "\n"] {
                if {[regexp {refs/tags/(.*)} $line -> t]} { lappend tag_list $t }
            }
            set latest_tag [get_latest_tag $tag_list]
            dict set meta last_tag $latest_tag

            if {[dict get $meta last_release_date] eq "" && $latest_tag ne ""} {
                set tag_date [exec git for-each-ref --format='%(creatordate:iso8601)' refs/tags/$latest_tag]
                set tag_date [string map {T " " Z ""} $tag_date]
                dict set meta last_release_date $tag_date
            }
        }

        dict set fossil_cache $cache_key $meta
        return $meta
    }

    # 2. Fossil JSON API
    set api_url "$base/json/timeline/checkin?limit=$MAX_COMMITS"
    if {$dir_path ne ""} {
        append api_url "&p=$dir_path"
    }
    set r [http_get $api_url "json"]
    if {[dict get $r code] == 200} {
        set json [dict get $r json]
        if {[dict exists $json payload] && [dict exists $json payload timeline]} {
            foreach entry [dict get $json payload timeline] {
                set ts [expr {[dict exists $entry timestamp] \
                              ? [dict get $entry timestamp] \
                              : [dict get $entry mtime]}]

                set date [clock format [expr {int($ts)}] \
                          -format "%Y-%m-%d %H:%M:%S" -gmt 1]
                dict lappend meta last_commit     $date
                dict lappend meta last_commit_sha [string range [dict get $entry uuid] 0 9]
            }
        }
        set tag_r [http_get "$base/json/tag/list" "json"]
        if {[dict get $tag_r code] == 200} {
            catch {
                set tag_list [dict get [dict get $tag_r json] payload]
                set latest_tag [get_latest_tag $tag_list]
                dict set meta last_tag $latest_tag
                dict set meta latest_release [expr {$latest_tag ne "" ? $latest_tag : "none"}]
            }
        }
    } else {
        # 3.  Fossil JSON not available, fallback RSS.
        set rss_url "$base/timeline.rss?n=$MAX_COMMITS&y=ci"
        set rss_r [http_get $rss_url]

        if {[dict get $rss_r code] == 200} {
            set body [dict get $rss_r body]
            foreach item [regexp -all -inline {<item>.*?</item>} $body] {
                if {[regexp {<pubDate>(.*?)</pubDate>} $item -> pub_date] &&
                    [regexp {/info/([0-9a-f]{10,})} $item -> uuid]} {
                    catch {
                        set epoch [clock scan $pub_date]
                        set date  [clock format $epoch -format "%Y-%m-%d %H:%M:%S" -gmt 1]
                        dict lappend meta last_commit $date
                        dict lappend meta last_commit_sha [string range $uuid 0 9]
                    }
                }
            }
        }
        set tag_page [http_get "$base/taglist"]
        if {[dict get $tag_page code] == 200} {
            set tag_list {}
            foreach line [split [dict get $tag_page body] "\n"] {
                if {[regexp {/info/[^"]+">([^<]+)</a>} $line -> tag]} {
                    if {[regexp {\d} $tag]} { lappend tag_list $tag }
                }
            }

            set latest_tag [get_latest_tag $tag_list]
            dict set meta last_tag $latest_tag
            dict set meta latest_release [expr {$latest_tag ne "" ? $latest_tag : "none"}]
        }
    }

    dict set fossil_cache $cache_key $meta
    return $meta
}

proc process_git {url {modname ""}} {
    global env MAX_COMMITS
    set repo [parse_github_repo $url]

    if {$repo ne ""} {
        set module_path ""
        if {$modname ne ""} {
            set info   [ensure_repo_info $repo]
            set branch [dict get $info default_branch]
            set module_path [find_module_file $repo $branch $modname]
            if {$module_path ne ""} {
                puts "    -> Module file found: $module_path (targeted history)"
            } else {
                puts "    -> No file found for '$modname', using full repo history"
            }
        }

        set meta [fetch_github_data $url $module_path]
        dict set meta last_tag [dict get $meta latest_release]

        if {[dict get $meta last_tag] eq ""} {
             catch {
                set raw_tags [exec git ls-remote --tags --refs $url]
                set tag_list {}
                foreach line [split $raw_tags "\n"] {
                    if {[regexp {refs/tags/(.*)} $line -> t]} { lappend tag_list $t }
                }
                set latest_tag [get_latest_tag $tag_list]
                dict set meta last_tag $latest_tag

                if {$latest_tag ne "" && [dict get $meta last_release_date] eq ""} {
                    set tmp [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] "git-tag-[expr {int(rand()*10000)}]"]
                    try {
                        exec git clone --depth 1 --filter=blob:none --no-checkout $url $tmp 2>@1
                        set tag_date [exec git -C $tmp for-each-ref --format='%(creatordate:iso8601)' refs/tags/$latest_tag]
                        set tag_date [string map {T " " Z ""} $tag_date]
                        dict set meta last_release_date $tag_date
                    } finally {
                        file delete -force $tmp
                    }
                }
            }
        }
        return $meta
    }

    set meta [dict create last_commit {} last_commit_sha {} last_tag "" last_release_date ""]
    set tmp [file join [expr {[info exists env(TMPDIR)] ? $env(TMPDIR) : "/tmp"}] "git-[expr {int(rand()*10000)}]"]

    set clone_depth $MAX_COMMITS
    if {$modname ne ""} { set clone_depth "" }

    try {
        if {$clone_depth ne ""} {
            exec git clone --depth $clone_depth --filter=blob:none --no-checkout $url $tmp 2>@1
        } else {
            exec git clone --filter=blob:none --no-checkout $url $tmp 2>@1
        }

        set module_path ""
        if {$modname ne ""} {
            catch {
                set all_files [exec git -C $tmp ls-tree -r --name-only HEAD]
                set module_path [select_module_path [split $all_files "\n"] $modname]
            }
            if {$module_path ne ""} {
                puts "    -> Module file found: $module_path (targeted history)"
            } else {
                puts "    -> No file found for '$modname', using full repo history"
            }
        }

        set log_cmd [list git -C $tmp log -$MAX_COMMITS --format=%ci|%h]
        if {$module_path ne ""} {
            lappend log_cmd -- $module_path
        }
        set log_output [exec {*}$log_cmd 2>@1]

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
        set latest_tag [get_latest_tag [split $t_out "\n"]]
        dict set meta last_tag $latest_tag

        if {$latest_tag ne ""} {
            set tag_date [exec git -C $tmp for-each-ref --format='%(creatordate:iso8601)' refs/tags/$latest_tag]
            set tag_date [string map {T " " Z ""} $tag_date]
            dict set meta last_release_date $tag_date
        }
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
            set root [huddle::json2huddle $data]
            set old_packages [huddle get_stripped $root]
            
            # Skip header (first element)
            set pkg_list [lrange $old_packages 1 end]
            
            foreach pkg $pkg_list {
                set name [dict get $pkg name]
                if {$name ne ""} {
                    set srcs [dict get $pkg sources]
                    if {[llength $srcs] > 0} {
                        set first_src [lindex $srcs 0]
                        if {[dict exists $first_src added_at]} {
                            set existing_dates($name) [dict get $first_src added_at]
                        }
                    }
                }
            }
        }
    }
}

# Compare two JSON files using jq (compares only package data, excluding header)
proc compare_json_files {old_file new_file} {
    # Check if jq is available
    if {[catch {exec which jq} err]} {
        puts "Warning: jq not found, assuming files are different"
        return 1
    }
    
    # Create temp files with unique names using process ID
    set old_tmp "/tmp/old_normalized_[pid].json"
    set new_tmp "/tmp/new_normalized_[pid].json"
    
    # Run jq with filter to skip header (index 0) and sort keys (-S)
    if {[catch {
        exec jq -S {.[1:]} $old_file > $old_tmp 2>/dev/null
        exec jq -S {.[1:]} $new_file > $new_tmp 2>/dev/null
    } err]} {
        puts "Warning: jq processing error"
        catch {file delete -force $old_tmp}
        catch {file delete -force $new_tmp}
        return 1
    }
    
    # Compare normalized files (diff returns error if different)
    set is_different [catch {exec diff -q $old_tmp $new_tmp}]
    
    # Cleanup temp files
    catch {file delete -force $old_tmp}
    catch {file delete -force $new_tmp}
    
    # Return 0 if same, 1 if different
    return $is_different
}

proc main {} {
    global INPUT_FILE OUTPUT_FILE existing_dates MAX_COMMITS

    load_existing_dates

    set current_version 0
    set old_content ""
    set has_old_file 0

    # Load existing file if present
    if {[file exists $OUTPUT_FILE]} {
        set fh [open $OUTPUT_FILE r]
        set old_content [read $fh]
        close $fh
        set has_old_file 1

        catch {
            set root [huddle::json2huddle $old_content]
            set old_data [huddle get_stripped $root]
            if {[llength $old_data] > 0} {
                set header [lindex $old_data 0]
                if {[catch {dict get $header version} v]} {
                    set current_version 0
                } else {
                    set current_version $v
                }
            }
        }
    }

    puts "Current version: $current_version"

    set fh [open $INPUT_FILE r]
    set data [read $fh]
    close $fh

    set root [huddle::json2huddle $data]
    set total [llength [huddle get_stripped $root]]
    set huddle_packages {}
    set reachability_cache [dict create]

    set idx 0
    set new_count 0

    puts "Processing $total packages..."

    for {set i 0} {$i < $total} {incr i} {
        set pkg [huddle get $root $i]
        incr idx
        
        set name [huddle get_stripped $pkg name]
        puts "\[$idx/$total\] Processing: $name"

        # Handle package addition date
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
        set sources_root [huddle get $pkg sources]
        set nb_sources [llength [huddle get_stripped $sources_root]]

        for {set j 0} {$j < $nb_sources} {incr j} {
            set src [huddle get $sources_root $j]
            
            set url [huddle get_stripped $src url]
            set method ""
            catch {set method [huddle get_stripped $src method]}

            puts "  - Checking source: $url (Method: $method)"

            if {[dict exists $reachability_cache $url]} {
                set reachable [dict get $reachability_cache $url]
                set code "CACHED"
            } else {
                set check [http_get $url]
                set code [dict get $check code]
                set reachable [expr {$code >= 200 && $code < 400}]

                dict set reachability_cache $url $reachable
            }

            set meta [dict create reachable $reachable archived 0 latest_release "none" last_commit {} last_tag "" last_commit_sha {}]

            if {$reachable} {
                set modname [parse_module_name $name]
                if {$method eq "fossil"} {
                    set meta [dict merge $meta [process_fossil $url $modname]]
                } elseif {$method eq "git"} {
                    set meta [dict merge $meta [process_git $url $modname]]
                }
            } else {
                puts "    ! Source unreachable (HTTP $code)"
            }

            set nb_commits [llength [dict get $meta last_commit]]
            puts "    -> Found $nb_commits commit(s)"

            # Build huddle source for final JSON output
            set h_src [huddle create]

            set src_keys [huddle keys $src]
            foreach k $src_keys {
                set h_val [huddle get $src $k]  ;# Objet huddle
                set ktype [huddle type $h_val]
                set v_stripped [huddle get_stripped $h_val]
                
                if {$k eq "author"} {
                    if {$ktype eq "list"} {
                        huddle append h_src $k $h_val
                    } else {
                        huddle append h_src $k [huddle string $v_stripped]
                    }
                } elseif {$ktype eq "list"} {
                    huddle append h_src $k $h_val
                } else {
                    huddle append h_src $k [huddle string $v_stripped]
                }
            }

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

        # Build huddle package
        set h_pkg [huddle create]
        huddle append h_pkg name [to_huddle $name str]

        set desc ""
        catch {set desc [huddle get_stripped $pkg description]}
        huddle append h_pkg description [to_huddle $desc str]

        set h_srcs [huddle list]
        foreach s $enriched_sources { huddle append h_srcs $s }
        huddle append h_pkg sources $h_srcs

        set h_tags [huddle list]
        catch {
            set tags_root [huddle get $pkg tags]
            set nb_tags [llength [huddle get_stripped $tags_root]]
            for {set k 0} {$k < $nb_tags} {incr k} {
                set t [huddle get $tags_root $k]
                huddle append h_tags [huddle string [huddle get_stripped $t]]
            }
        }
        huddle append h_pkg tags $h_tags

        lappend huddle_packages $h_pkg
    }

    # Generate new JSON content
    set timestamp [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt 1]
    set new_version [expr {$current_version + 1}]
    
    set out_list [huddle list]
    huddle append out_list [huddle create \
        version [huddle string $new_version] \
        generated_at [huddle string $timestamp] \
        total_packages [huddle string [llength $huddle_packages]]
    ]

    foreach pkg $huddle_packages {
        huddle append out_list $pkg
    }

    set new_json [string map {\\/ /} [huddle jsondump $out_list "" ""]]
    
    # Write to temporary file first
    file mkdir [file dirname $OUTPUT_FILE]
    set tmp_file "${OUTPUT_FILE}.tmp"
    set fh [open $tmp_file w]
    puts -nonewline $fh $new_json
    close $fh

    # Compare with existing file (if present)
    set final_content $new_json
    set final_version $new_version
    
    if {$has_old_file} {
        if {[compare_json_files $OUTPUT_FILE $tmp_file] == 0} {
            puts "\n✓ No changes detected in package data. Keeping version $current_version."
            set final_content $old_content
            set final_version $current_version
        } else {
            puts "\n✗ Changes detected! Bumping to version $new_version."
        }
    } else {
        puts "\n✓ Creating new file with version $new_version."
    }

    # Write final content
    set fh [open $OUTPUT_FILE w]
    puts -nonewline $fh $final_content
    close $fh
    
    # Cleanup temporary files
    file delete -force $tmp_file
    catch {file delete -force /tmp/old_normalized.json}
    catch {file delete -force /tmp/new_normalized.json}

    puts "\nDone: $OUTPUT_FILE"
    puts "Version: $final_version"
    puts "Total: [llength $huddle_packages] packages ($new_count new)"
}

main
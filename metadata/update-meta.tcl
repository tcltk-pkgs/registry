#!/usr/bin/env tclsh

package require json
package require json::write

set input "packages.json"
set output "metadata/packages-meta.json"
set temp_base [file join /tmp registry-meta-[pid]-[clock seconds]]

file mkdir [file dirname $output]
file mkdir $temp_base

puts "Generating $output..."

set fh [open $input r]
set content [read $fh]
close $fh

set packages [::json::json2dict $content]
set total [llength $packages]
puts "$total packages to process"

proc process_git {url temp_base} {
    set tmpdir [file join $temp_base "git-[clock seconds]-[expr {int(rand()*1000)}]"]
    
    if {[catch {
        exec git clone --depth 1 --filter=blob:none --no-checkout $url $tmpdir 2>@ stderr
    } err]} {
        puts stderr "Git clone error: $url"
        catch {file delete -force $tmpdir}
        return [dict create last_commit "null" last_commit_sha "null" last_tag "null" error "clone_failed"]
    }
    
    set commit_date "null"
    set commit_sha "null"
    set tag "null"
    
    catch {set commit_date [string trim [exec git -C $tmpdir log -1 --format=%ci]]}
    catch {set commit_sha [string trim [exec git -C $tmpdir rev-parse --short HEAD]]}
    catch {
        set tags [exec git -C $tmpdir tag --sort=-creatordate]
        set tag [lindex [split $tags \n] 0]
        if {$tag eq ""} {set tag "null"}
    }
    
    catch {file delete -force $tmpdir}
    return [dict create last_commit $commit_date last_commit_sha $commit_sha last_tag $tag]
}

proc process_fossil {url temp_base} {
    if {[regexp {^(https?://[^/]+/[^/]+)} $url -> base]} {
        set api_base $base
    } else {
        set base_url [string trimright $url "/"]
        regexp {^([^?]+)} $base_url -> api_base
    }
    
    set commit_date "null"
    set commit_sha "null"
    set tag "null"
    
    set timeline_url "$api_base/json/timeline?type=ci&limit=1"
    puts "  Trying API: $timeline_url"
    
    if {![catch {
        set json [exec curl -s -L --max-time 15 $timeline_url]
        set data [::json::json2dict $json]
        
        if {[dict exists $data timeline]} {
            set entries [dict get $data timeline]
            if {[llength $entries] > 0} {
                set entry [lindex $entries 0]
                if {[dict exists $entry timestamp]} {
                    set commit_date [dict get $entry timestamp]
                }
                if {[dict exists $entry uuid]} {
                    set sha [dict get $entry uuid]
                    set commit_sha [string range $sha 0 9]
                }
            }
        }
    } err]} {
        puts "  API success: $commit_date"
    } else {
        puts stderr "  API failed, using HTML fallback"
        # Fallback HTML
        set timeline_url "$api_base/timeline"
        if {![catch {
            set html [exec curl -s -L --max-time 15 $timeline_url]
            regexp {datetime="(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})"} $html -> commit_date
            regexp {href="/timeline\?c=([0-9a-f]{10,})"} $html -> sha
            if {[info exists sha]} {set commit_sha [string range $sha 0 9]}
        } err2]}
    }
    
    set tags_url "$api_base/json/taglist"
    if {![catch {
        set json [exec curl -s -L --max-time 10 $tags_url]
        set data [::json::json2dict $json]
        if {[dict exists $data tags]} {
            set tags [dict get $data tags]
            if {[llength $tags] > 0} {
                set first [lindex $tags 0]
                if {[dict exists $first tagname]} {set tag [dict get $first tagname]}
            }
        }
    } err]} {
        if {$tag ne "null"} {puts "  Found tag: $tag"}
    }
    
    return [dict create last_commit $commit_date last_commit_sha $commit_sha last_tag $tag]
}

proc to_json_value {v} {
    if {$v eq "null"} {
        return "null"
    } elseif {[string is integer -strict $v] || [string is double -strict $v]} {
        return $v
    } else {
        return [json::write string $v]
    }
}

proc to_json {value} {
    if {$value eq "null"} {
        return "null"
    } elseif {[string is integer -strict $value] || [string is double -strict $value]} {
        return $value
    } elseif {![catch {dict size $value} sz] && $sz > 0} {
        set pairs [list]
        dict for {k v} $value {
            lappend pairs "\"$k\":[to_json $v]"
        }
        return "{[join $pairs ,]}"
    } elseif {[llength $value] > 1} {
        set first [lindex $value 0]
        if {![catch {dict size $first} sz] && $sz > 0} {
            # Liste d'objets
            set items [list]
            foreach item $value {
                lappend items [to_json $item]
            }
            return "\[[join $items ,]\]"
        } else {
            set items [list]
            foreach item $value {
                lappend items [to_json_value $item]
            }
            return "\[[join $items ,]\]"
        }
    } else {
        return [to_json_value $value]
    }
}

set enriched_packages [list]
set idx 0

foreach package $packages {
    incr idx
    set name [dict get $package name]
    puts "\[$idx/$total\] $name"
    
    set sources [dict get $package sources]
    set enriched_sources [list]
    
    foreach source $sources {
        set method [dict get $source method]
        set url [dict get $source url]
        
        puts "  -> $method: [string range $url 0 60]..."
        
        switch -exact -- $method {
            "git" { set meta [process_git $url $temp_base] }
            "fossil" { set meta [process_fossil $url $temp_base] }
            default { set meta [dict create last_commit "null" last_tag "null" last_commit_sha "null" error "unknown_method"] }
        }

        lappend enriched_sources [dict merge $source $meta]
    }
    

    set new_package [dict create \
        name [dict get $package name] \
        sources $enriched_sources \
        tags [dict get $package tags] \
        description [dict get $package description]]
    
    lappend enriched_packages [to_json $new_package]
}


set meta [dict create packages "Tcl/Tk" generated_at [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt true]]


set json_out "\[[to_json $meta],[join $enriched_packages ,]\]"

set fh [open $output w]
puts $fh $json_out
close $fh

catch {file delete -force $temp_base}

puts "File generated: $output ([file size $output] bytes)"
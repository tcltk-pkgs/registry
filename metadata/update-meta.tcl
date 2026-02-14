#!/usr/bin/env tclsh

package require json
package require json::write

set input "packages.json"
set output "metadata/packages-meta.json"
set temp_base [file join /tmp registry-meta-[pid]-[clock seconds]]

# Create directory structure
file mkdir [file dirname $output]
file mkdir $temp_base

puts "Generating $output..."

set fh [open $input r]
set content [read $fh]
close $fh

# Parse JSON - input is an array of packages
set packages [::json::json2dict $content]
set total [llength $packages]
puts "$total packages to process"

# Process Git source (shallow clone)
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
    
    catch {
        set commit_date [string trim [exec git -C $tmpdir log -1 --format=%ci]]
    }
    catch {
        set commit_sha [string trim [exec git -C $tmpdir rev-parse --short HEAD]]
    }
    catch {
        set tags [exec git -C $tmpdir tag --sort=-creatordate]
        set tag [lindex [split $tags \n] 0]
        if {$tag eq ""} {set tag "null"}
    }
    
    catch {file delete -force $tmpdir}
    
    return [dict create last_commit $commit_date last_commit_sha $commit_sha last_tag $tag]
}

# Process Fossil source - fast version using HTTP timeline (no clone)
proc process_fossil {url temp_base} {
    # Clean URL for timeline access
    set base_url [string trimright $url "/"]
    set timeline_url "$base_url/timeline"
    
    puts "  Fetching timeline: $timeline_url"
    
    # Fetch timeline page (lightweight, just HTML)
    if {[catch {
        set html [exec curl -s -L --max-time 15 $timeline_url]
    } err]} {
        puts stderr "Failed to fetch timeline: $err"
        return [dict create last_commit "null" last_tag "null" last_commit_sha "null" error "fetch_failed"]
    }
    
    set commit_date "null"
    set commit_sha "null"
    set tag "null"
    
    # Extract last commit date from timeline HTML
    if {[regexp {datetime="(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})"} $html -> date]} {
        set commit_date $date
    } elseif {[regexp {(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})} $html -> d t]} {
        set commit_date "$d $t"
    }
    
    # Extract short SHA from timeline (first hex sequence of 10+ chars)
    if {[regexp {href="/timeline\?c=([0-9a-f]{10,})"} $html -> sha]} {
        set commit_sha [string range $sha 0 9]
    }
    
    # Try to get last tag from tags page
    set tags_url "$base_url/taglist"
    if {![catch {
        set tags_html [exec curl -s -L --max-time 10 $tags_url]
    } err]} {
        if {[regexp -nocase {>(v?\d+\.\d+[^<]*)</} $tags_html -> found_tag]} {
            set tag $found_tag
        } elseif {[regexp {>(release[^<]+)</} $tags_html -> found_tag]} {
            set tag $found_tag
        }
    }
    
    return [dict create \
        last_commit $commit_date \
        last_commit_sha $commit_sha \
        last_tag $tag]
}

# Convert dict to JSON string
proc dict_to_json {d} {
    set pairs [list]
    dict for {key value} $d {
        if {$value eq "null"} {
            lappend pairs "\"$key\": null"
        } elseif {[string is integer -strict $value]} {
            lappend pairs "\"$key\": $value"
        } else {
            lappend pairs "\"$key\": \"[string map {\" \\\\\" \\ \\\\ \n \\n \r \\r} $value]\""
        }
    }
    return "{[join $pairs ,]}"
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
        
        puts "  -> $method: $url"
        
        switch -exact -- $method {
            "git" { set meta [process_git $url $temp_base] }
            "fossil" { set meta [process_fossil $url $temp_base] }
            default { set meta [dict create last_commit "null" last_tag "null" last_commit_sha "null" error "unknown_method"] }
        }
        
        # Merge source and metadata
        set enriched [dict merge $source $meta]
        lappend enriched_sources [dict_to_json $enriched]
    }
    
    # Rebuild package with enriched sources
    set new_package [dict create \
        name [dict get $package name] \
        sources "\[[join $enriched_sources ,]\]" \
        tags [dict get $package tags] \
        description [dict get $package description]]
    
    lappend enriched_packages [dict_to_json $new_package]
}

# Create metadata object as first element
set timestamp [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt true]
set meta_obj [dict create packages "Tcl/Tk" generated_at $timestamp]

# Build final array: [metadata, package1, package2, ...]
set all_items [list [dict_to_json $meta_obj]]
foreach pkg $enriched_packages {
    lappend all_items $pkg
}

set json_out "\[[join $all_items ,]\]"

set fh [open $output w]
puts $fh $json_out
close $fh

catch {file delete -force $temp_base}

puts "File generated: $output ([file size $output] bytes)"
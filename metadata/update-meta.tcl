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
    # Fossil timeline format: datetime="2024-02-14 15:30:00" or similar patterns
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
        # Look for version-like tags (v1.0, release-1.0, etc.)
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

# Convert a single source dict to JSON
proc source_to_json {source} {
    set pairs [list]
    dict for {key value} $source {
        if {$value eq "null"} {
            lappend pairs "\"$key\": null"
        } elseif {[string is integer -strict $value]} {
            lappend pairs "\"$key\": $value"
        } elseif {$key eq "tags"} {
            # Handle tags array specially
            if {[string match "\[*" $value]} {
                # Already a JSON array string from original
                lappend pairs "\"$key\": $value"
            } else {
                lappend pairs "\"$key\": [list_to_json $value]"
            }
        } else {
            lappend pairs "\"$key\": \"[string map {\" \\\\\" \\ \\\\ \n \\n \r \\r} $value]\""
        }
    }
    return "{[join $pairs ,]}"
}

# Convert list to JSON array
proc list_to_json {lst} {
    set items [list]
    foreach item $lst {
        lappend items "\"[string map {\" \\\\\" \\ \\\\ \n \\n \r \\r} $item]\""
    }
    return "\[[join $items ,]\]"
}

# Convert package dict to JSON
proc package_to_json {package} {
    set pairs [list]
    dict for {key value} $package {
        if {$key eq "sources"} {
            # Sources is already a list of JSON strings
            lappend pairs "\"$key\": \[$value\]"
        } elseif {$key eq "tags"} {
            # Tags is a list
            lappend pairs "\"$key\": [list_to_json $value]"
        } elseif {$value eq "null"} {
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
        lappend enriched_sources [source_to_json $enriched]
    }
    
    # Create new package dict with enriched sources as JSON array string
    set new_package [dict create \
        name [dict get $package name] \
        sources [join $enriched_sources ,] \
        tags [dict get $package tags] \
        description [dict get $package description]]
    
    lappend enriched_packages [package_to_json $new_package]
}

set timestamp [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt true]
set json_out "{\n  \"generated_at\": \"$timestamp\",\n  \"packages\": \[[join $enriched_packages ,]\]\n}"

set fh [open $output w]
puts $fh $json_out
close $fh

catch {file delete -force $temp_base}

puts "File generated: $output ([file size $output] bytes)"
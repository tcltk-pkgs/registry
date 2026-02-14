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

# Process Fossil source with shallow clone
proc process_fossil {url temp_base} {
    set dbname "fossil-[clock seconds]-[expr {int(rand()*1000)}].fossil"
    set db [file join $temp_base $dbname]
    
    # Try shallow clone first (faster), fallback to full clone if not supported
    if {[catch {
        exec fossil clone --depth 1 $url $db 2>@ stderr
    } err]} {
        puts stderr "⚠️  Shallow clone failed, trying full clone: $url"
        if {[catch {
            exec fossil clone $url $db 2>@ stderr
        } err2]} {
            puts stderr "⚠️  Fossil clone error: $url"
            catch {file delete -force $db}
            return [dict create last_commit "null" last_tag "null" last_commit_sha "null" error "clone_failed"]
        }
    }
    
    set commit_date "null"
    set tag "null"
    
    # Get last check-in date
    catch {
        set commit_date [string trim [exec fossil sql -R $db {SELECT datetime(mtime) FROM event WHERE type='ci' ORDER BY mtime DESC LIMIT 1;}]]
        if {$commit_date eq ""} {set commit_date "null"}
    }
    
    # Get last tag (sym-* format in fossil)
    catch {
        set tag [string trim [exec fossil sql -R $db {SELECT substr(tagname, 10) FROM tag WHERE tagname LIKE 'sym-release%' OR tagname LIKE 'sym-v%' OR tagname LIKE 'sym-%' ORDER BY tagname DESC LIMIT 1;}]]
        if {$tag eq ""} {set tag "null"}
    }
    
    catch {file delete -force $db}
    
    return [dict create last_commit $commit_date last_tag $tag last_commit_sha "null"]
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
        
        puts "  → $method: $url"
        
        switch -exact -- $method {
            "git" { set meta [process_git $url $temp_base] }
            "fossil" { set meta [process_fossil $url $temp_base] }
            default { set meta [dict create last_commit "null" last_tag "null" last_commit_sha "null" error "unknown_method"] }
        }
        
        # Merge source and metadata
        set enriched [dict merge $source $meta]
        lappend enriched_sources [dict_to_json $enriched]
    }
    
    dict set package sources "\[[join $enriched_sources ,]\]"
    lappend enriched_packages [dict_to_json $package]
}

set timestamp [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%SZ" -gmt true]
set json_out "{\n  \"generated_at\": \"$timestamp\",\n  \"packages\": \[[join $enriched_packages ,]\]\n}"

set fh [open $output w]
puts $fh $json_out
close $fh

catch {file delete -force $temp_base}

puts "File generated: $output ([file size $output] bytes)"
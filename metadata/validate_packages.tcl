#!/usr/bin/env tclsh
package require json

set INPUT_FILE "packages.json"
set GITHUB_OUTPUT $env(GITHUB_OUTPUT)

proc set_output {name value} {
    global GITHUB_OUTPUT
    set fh [open $GITHUB_OUTPUT a]
    puts $fh "$name<<EOF"
    puts $fh $value
    puts $fh "EOF"
    close $fh
}

if {[catch {exec -ignorestderr jq empty $INPUT_FILE 2>@1} jq_error]} {
    set_output "status" "failure"
    set_output "message" ":x: JSON Syntax Error:\n$jq_error"
    exit 1
}

if {[catch {
    set fh [open $INPUT_FILE r]
    set data [read $fh]
    close $fh
    set packages [::json::json2dict $data]
} err]} {
    set_output "status" "failure"
    set_output "message" ":x: Tcl parsing error: $err"
    exit 1
}

set errors {}
set warnings {}
set idx 0

array set seen_names {}

foreach pkg $packages {
    set pkg_name ""
    
    if {[dict exists $pkg name]} {
        set pkg_name [dict get $pkg name]

        if {[info exists seen_names($pkg_name)]} {
            lappend errors "Duplicate package name: '$pkg_name' (appears at index #$seen_names($pkg_name) and #$idx)"
        } else {
            set seen_names($pkg_name) $idx
        }
    } else {
        set pkg_name "Package #$idx"
        lappend errors "$pkg_name: missing required field 'name'"
    }

    if {![dict exists $pkg sources]} {
        lappend errors "$pkg_name: missing required field 'sources'"
    } elseif {[llength [dict get $pkg sources]] == 0} {
        lappend errors "$pkg_name: 'sources' array is empty"
    } else {
        set srcs [dict get $pkg sources]
        set src_idx 0

        array set seen_urls {}
        
        foreach src $srcs {
            if {![dict exists $src url] || [dict get $src url] eq ""} {
                lappend errors "$pkg_name: source #$src_idx missing required 'url'"
            } else {
                set url [dict get $src url]
                if {[info exists seen_urls($url)]} {
                    lappend warnings "$pkg_name: duplicate URL '$url' in sources (redundant)"
                } else {
                    set seen_urls($url) $src_idx
                }
            }

            if {![dict exists $src method] || [dict get $src method] eq ""} {
                lappend warnings "$pkg_name: source #$src_idx missing 'method' (optional, defaults to auto-detect)"
            }

            if {[dict exists $src artifacts]} {
                set artifacts [dict get $src artifacts]
                if {[regexp {\.(zip|tar\.gz|tgz|exe|msi|dmg|deb|rpm)$} $artifacts]} {
                    lappend errors "$pkg_name: 'artifacts' appears to be a direct download link (should be a release page URL)"
                }
            }
            
            incr src_idx
        }
        
        unset seen_urls
    }

    if {![dict exists $pkg tags] || [llength [dict get $pkg tags]] == 0} {
        lappend errors "$pkg_name: no tags defined (recommended for searchability)"
    }

    if {![dict exists $pkg description] || [dict get $pkg description] eq ""} {
        lappend errors "$pkg_name: missing description (recommended)"
    }
    
    incr idx
}

if {[llength $errors] > 0} {
    set msg ":x: Structure Errors:\n[join $errors \n]"
    if {[llength $warnings] > 0} {
        append msg "\n\n:warning: Warnings:\n[join $warnings \n]"
    }
    set_output "status" "failure"
    set_output "message" $msg
    exit 1
} else {
    if {[llength $warnings] > 0} {
        set msg ":white_check_mark: packages.json is valid\n\n:warning: Warnings ([llength $warnings]):\n[join $warnings \n]"
    } else {
        set msg ":white_check_mark: packages.json is valid - All checks passed!"
    }
    set_output "status" "success"
    set_output "message" $msg
    exit 0
}
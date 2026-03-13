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

array set existing_names {}
if {![catch {exec git show origin/master:packages.json} old_json]} {
    if {![catch {
        set old_data [::json::json2dict $old_json]
        foreach old_pkg $old_data {
            if {[dict exists $old_pkg name]} {
                set name [dict get $old_pkg name]
                set existing_names($name) 1
            }
        }
    }]} {
        puts "Loaded [array size existing_names] existing packages from master"
    }
}

set errors {}
set new_warnings {}
set idx 0

array set seen_names {}

foreach pkg $packages {
    set pkg_name "Package #$idx"
    set is_new 1
    
    if {[dict exists $pkg name]} {
        set pkg_name [dict get $pkg name]
        
        # Vérification doublons
        if {[info exists seen_names($pkg_name)]} {
            lappend errors "Duplicate package name: '$pkg_name' (appears at index #$seen_names($pkg_name) and #$idx)"
        } else {
            set seen_names($pkg_name) $idx
        }
        
        # Détection si package existait déjà
        if {[info exists existing_names($pkg_name)]} {
            set is_new 0
        }
    } else {
        lappend errors "$pkg_name: missing required field 'name'"
    }
    
    # Validation sources (erreurs bloquantes pour tous)
    if {![dict exists $pkg sources]} {
        lappend errors "$pkg_name: missing required field 'sources'"
    } elseif {[llength [dict get $pkg sources]] == 0} {
        lappend errors "$pkg_name: 'sources' array is empty"
    } else {
        set srcs [dict get $pkg sources]
        set src_idx 0
        array set seen_urls {}
        
        foreach src $srcs {
            # url obligatoire (erreur pour tous)
            if {![dict exists $src url] || [dict get $src url] eq ""} {
                lappend errors "$pkg_name: source #$src_idx missing required 'url'"
            } else {
                set url [dict get $src url]
                if {[info exists seen_urls($url)]} {
                    if {$is_new} {
                        lappend new_warnings "$pkg_name: duplicate URL '$url' in sources"
                    }
                } else {
                    set seen_urls($url) $src_idx
                }
            }
            
            # method optionnel - warning seulement si nouveau package
            if {![dict exists $src method] || [dict get $src method] eq ""} {
                if {$is_new} {
                    lappend new_warnings "$pkg_name: source #$src_idx missing 'method' (optional but recommended)"
                }
            }
            
            # artifacts (warning pour tous mais catégorisé)
            if {[dict exists $src artifacts]} {
                set artifacts [dict get $src artifacts]
                if {[regexp {\.(zip|tar\.gz|tgz|exe|msi|dmg|deb|rpm)$} $artifacts]} {
                    set msg "$pkg_name: 'artifacts' appears to be direct download link"
                    lappend errors $msg
                }
            }
            
            incr src_idx
        }
        unset seen_urls
    }
    
    # Tags et description : warning seulement pour nouveaux packages
    if {$is_new} {
        if {![dict exists $pkg tags] || [llength [dict get $pkg tags]] == 0} {
            lappend errors "$pkg_name: no tags defined."
        }
        if {![dict exists $pkg description] || [dict get $pkg description] eq ""} {
            lappend errors "$pkg_name: missing description."
        }
    }
    
    incr idx
}

if {[llength $errors] > 0} {
    set msg ":x: Structure Errors (blocking):\n[join $errors \n]"
    
    if {[llength $new_warnings] > 0} {
        append msg "\n\n:warning: Warnings on NEW packages:\n[join $new_warnings \n]"
    }

    set_output "status" "failure"
    set_output "message" $msg
    exit 1
} else {
    set msg ":white_check_mark: packages.json is valid"
    
    if {[llength $new_warnings] > 0} {
        append msg "\n\n:warning: Please review new packages:\n[join $new_warnings \n]"
    }
    set_output "status" "success"
    set_output "message" $msg
    exit 0
}
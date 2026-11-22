package require json

set META "metadata/packages-meta.json"
set THRESHOLD 30
set LABEL "dead-link"
set MAX_ISSUES 10

proc gh {args} {
    return [exec -ignorestderr gh {*}$args]
}

set fh [open $META r]
set root [::json::json2dict [read $fh]]
close $fh

set now [clock seconds]
array set dead_since {}
array set dead_pkgs {}

# Skip header (first element)
foreach pkg [lrange $root 1 end] {
    set name [string trim [dict get $pkg name]]
    foreach src [dict get $pkg sources] {
        if {![dict exists $src unreachable_since]} continue
        set since [dict get $src unreachable_since]
        if {$since eq ""} continue
        set days [expr {($now - [clock scan $since -format %Y-%m-%d -gmt 1]) / 86400}]
        if {$days < $THRESHOLD} continue
        set url [dict get $src url]
        set dead_since($url) $since
        lappend dead_pkgs($url) $name
    }
}

catch {gh label create $LABEL --color B60205 --description "Source unreachable for a long time"}

# --state all: never recreate an issue that was already closed
set titles [split [gh issue list --label $LABEL --state all --limit 1000 \
    --json title --jq {.[].title}] "\n"]

set urls [lsort [array names dead_since]]

if {[llength $urls] > $MAX_ISSUES} {
    # Probably a host outage: one summary issue instead of many
    set earliest [lindex [lsort [lmap u $urls {set dead_since($u)}]] 0]
    set title "Many sources unreachable (since $earliest)"
    if {$title ni $titles} {
        set list [join [lmap u $urls {string cat "- $u (since $dead_since($u))"}] "\n"]
        puts "Opening summary issue: $title"
        gh issue create --title $title --label $LABEL \
        --body "[llength $urls] sources have been unreachable for $THRESHOLD+ days. This\
        may be a host outage rather than dead packages.\n\n$list"
    }
    set urls {}
}

foreach url $urls {
    set since $dead_since($url)
    set title "Source unreachable since $since: $url"
    if {$title in $titles} continue

    set days [expr {($now - [clock scan $since -format %Y-%m-%d -gmt 1]) / 86400}]
    set list [join [lmap p $dead_pkgs($url) {string cat "- " $p}] "\n"]
    set body "This source has not responded for $days days (first failure seen on $since)\
             .\n\nURL: $url\n\nAffected packages:\n$list\n\nIt may no longer be available."

    puts "Opening issue: $title"
    gh issue create --title $title --body $body --label $LABEL
}
#!/usr/bin/env bash
# Exercise this fork's additions against a running nested instance.
#
#   test/nested.sh start 2 && test/smoke.sh
#
# Assumes two monitors laid out left to right, which is what nested.sh sets up.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
N="$HERE/nested.sh"

pass=0
fail=0

ctl() { "$N" ctl "$@"; }
dispatch() { ctl dispatch "$1" >/dev/null 2>&1; sleep "${2:-0.5}"; }
clients() { ctl clients -j; }

check() { # check <label> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf '  \033[32mPASS\033[0m %s\n' "$1"
		pass=$((pass + 1))
	else
		printf '  \033[31mFAIL\033[0m %s\n        expected: %s\n        actual:   %s\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

addr_of() { clients | jq -r --arg t "$1" '.[]|select(.title==$t)|.address'; }
where() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|"mon\(.monitor)"'; }
geom() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|"\(.at|join(","))/\(.size|join(","))"'; }
ws_of() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.workspace.name'; }
focused_mon() { ctl monitors -j | jq -r '.[]|select(.focused)|.name'; }
active_mon() { ctl activewindow -j | jq -r 'if .monitor == null then "none" else "mon\(.monitor)" end'; }
focus() { dispatch "hl.dsp.focus({ window = 'address:$1' })" 0.4; }
setflag() { ctl eval "hl.config({ plugin = { hy3 = { $1 = $2 } } })" >/dev/null 2>&1; sleep 0.3; }

spawn() { # spawn <title>
	dispatch "hl.dsp.exec_cmd('alacritty --title $1')" 2.5
	local i=0
	while [ "$i" -lt 20 ] && [ -z "$(addr_of "$1")" ]; do sleep 0.5; i=$((i + 1)); done
}

cleanup_windows() {
	for a in $(clients | jq -r '.[]|select(.title|startswith("t_"))|.address'); do
		dispatch "hl.dsp.window.close({ window = 'address:'..'$a' })" 0.4
	done
}

"$N" sig >/dev/null 2>&1 || { echo "no nested instance - run test/nested.sh start 2" >&2; exit 1; }

echo "== setup =="
cleanup_windows
spawn t_a
spawn t_b
A=$(addr_of t_a); B=$(addr_of t_b)
[ -n "$A" ] && [ -n "$B" ] || { echo "could not spawn test windows" >&2; exit 1; }
check "two windows tiled on mon0" "mon0 mon0" "$(where "$A") $(where "$B")"

echo
echo "== hy3:movetomonitor =="
focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('+1')" 0.8
check "'+1' moves the node"                    "mon1"      "$(where "$B")"
check "'+1' leaves monitor focus behind"       "WAYLAND-1" "$(focused_mon)"
check "'+1' leaves keyboard focus behind"      "mon0"      "$(active_mon)"

focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('-1')" 0.8
check "'-1' moves the node back"               "mon0"      "$(where "$B")"

focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})" 0.8
check "follow moves the node"                  "mon1"      "$(where "$B")"
check "follow takes focus along"               "WAYLAND-2" "$(focused_mon)"

focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('+1')" 0.8
check "'+1' wraps at the last monitor"         "mon0"      "$(where "$B")"

focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('r')" 0.8
check "direction 'r' moves right"              "mon1"      "$(where "$B")"
focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('WAYLAND-1')" 0.8
check "monitor name resolves"                  "mon0"      "$(where "$B")"

echo
echo "== hy3:movewindow monitor fallthrough =="
setflag movewindow_monitor_fallthrough false
focus "$B"
for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.5; done
check "flag off: node stays on its monitor"    "mon0"      "$(where "$B")"

setflag movewindow_monitor_fallthrough true
focus "$B"
for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.6; done
check "flag on: node crosses at the edge"      "mon1"      "$(where "$B")"
for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.6; done
check "outermost edge does not lose the node"  "mon1"      "$(where "$B")"

echo
echo "== tab group moves intact =="
focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('-1',{follow=true})" 0.8
focus "$A"
dispatch "hl.plugin.hy3.make_group('tab')" 0.5
focus "$B"
dispatch "hl.plugin.hy3.move_window('l')" 0.8
check "tabbed windows share geometry"          "$(geom "$A")" "$(geom "$B")"
dispatch "hl.plugin.hy3.change_focus('raise')" 0.4
dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})" 1
check "whole group moved"                      "mon1 mon1"    "$(where "$A") $(where "$B")"
check "group still tabbed after the move"      "$(geom "$A")" "$(geom "$B")"
dispatch "hl.plugin.hy3.change_focus('lower')" 0.4
dispatch "hl.plugin.hy3.change_group('untab')" 0.5

echo
echo "== special_focus_trap =="
# park t_b on mon1 and open the scratchpad on mon0, so that escaping left to
# right has somewhere to land. focusMonitor only changes the active window if
# the target monitor actually has one, so an empty neighbour would make this
# look like the trap fired when it did not.
focus "$B"
[ "$(where "$B")" = "mon1" ] || dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})" 0.8
check "neighbour monitor has a window"         "mon1" "$(where "$B")"

focus "$A"
[ "$(where "$A")" = "mon0" ] || dispatch "hl.plugin.hy3.move_to_monitor('-1',{follow=true})" 0.8
dispatch "hl.plugin.hy3.move_to_workspace('special:t',{follow=true})" 1
check "window is on the scratchpad"            "special:t" "$(ws_of "$A")"
check "scratchpad is on mon0"                  "mon0"      "$(where "$A")"

# Assert on the focused monitor, not on the active window's workspace: a
# scratchpad follows the monitor that gains focus, so a special:t window stays
# "active" whether or not focus actually left the monitor.
# A scratchpad follows whichever monitor focus is on, so pointing focus at mon0
# and then at the scratchpad window brings it along. Do NOT use move_to_monitor
# here: that moves the node to the target monitor's *regular* workspace, taking
# the window off the scratchpad.
scratchpad_to_mon0() {
	dispatch "hl.dsp.focus({ monitor = 'WAYLAND-1' })" 0.5
	focus "$A"
}

setflag special_focus_trap false
scratchpad_to_mon0
check "flag off: starts on mon0"               "WAYLAND-1" "$(focused_mon)"
check "flag off: starts on the scratchpad"     "special:t" "$(ws_of "$A")"
for _ in 1 2 3 4 5 6; do dispatch "hl.plugin.hy3.move_focus('r')" 0.2; done
check "flag off: focus escapes the scratchpad" "WAYLAND-2" "$(focused_mon)"

setflag special_focus_trap true
scratchpad_to_mon0
check "flag on: starts on mon0"                "WAYLAND-1" "$(focused_mon)"
check "flag on: starts on the scratchpad"      "special:t" "$(ws_of "$A")"
for _ in 1 2 3 4 5 6; do dispatch "hl.plugin.hy3.move_focus('r')" 0.2; done
check "flag on: focus stays on the scratchpad" "WAYLAND-1" "$(focused_mon)"
check "flag on: still on the scratchpad"       "special:t" "$(ctl activewindow -j | jq -r '.workspace.name')"

echo
echo "== hy3:togglefloating =="
focus "$A"
dispatch "hl.plugin.hy3.toggle_floating()" 0.9
check "unmounts off the scratchpad"            "false" "$(clients | jq -r --arg a "$A" '.[]|select(.address==$a)|.workspace.name|startswith("special:")|tostring')"
check "focus follows the unmounted window"     "$A"    "$(ctl activewindow -j | jq -r .address)"
dispatch "hl.plugin.hy3.toggle_floating()" 0.6
check "toggles floating on"                    "true"  "$(clients | jq -r --arg a "$A" '.[]|select(.address==$a)|.floating|tostring')"
dispatch "hl.plugin.hy3.toggle_floating()" 0.6
check "toggles floating off"                   "false" "$(clients | jq -r --arg a "$A" '.[]|select(.address==$a)|.floating|tostring')"

echo
echo "== teardown =="
cleanup_windows
ALIVE=$(kill -0 "$(cat "${TMPDIR:-/tmp}/hy3-nested/pid")" 2>/dev/null && echo yes || echo no)
check "instance survived the run"              "yes" "$ALIVE"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

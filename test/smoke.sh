#!/usr/bin/env bash
# Exercise this fork's additions against a running nested instance.
#
#   test/nested.sh start 2 && test/smoke.sh
#
# Assumes at least two monitors laid out left to right, which is what nested.sh
# sets up. Monitor names and ids are discovered rather than hardcoded - the
# nested wayland outputs are named by whatever the host already has, and the
# monitor id in `hyprctl clients` is assignment order, not screen order.
#
# Environment:
#   HY3_TEST_TERM      terminal to spawn test windows with (default: alacritty).
#                      Must accept `--title <title>`.
#   HY3_TEST_TIMEOUT   seconds an assertion waits for the compositor to settle
#                      (default: 6). Raise it on a loaded machine.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
N="$HERE/nested.sh"

TERM_CMD=${HY3_TEST_TERM:-alacritty}
TIMEOUT=${HY3_TEST_TIMEOUT:-6}

pass=0
fail=0

# Every external command this suite assumes. Missing ones used to surface as a
# wall of empty jq output and a dozen confusing FAILs.
need() {
	local missing=0 tool
	for tool in "$@"; do
		command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; missing=1; }
	done
	[ "$missing" -eq 0 ] || exit 1
}
need jq hyprctl "$TERM_CMD"

ctl() { "$N" ctl "$@"; }
dispatch() { ctl dispatch "$1" >/dev/null 2>&1; sleep "${2:-0.15}"; }
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

# Poll <cmd...> until it prints <expected>, then assert. Replaces the
# "dispatch; sleep <guess>; check" pattern this suite used to be built from:
# the guess was simultaneously the runtime and the flake surface, since a loaded
# machine simply misses the window. A passing run is now as fast as the
# compositor is, and a failing one still reports the last value it saw.
check_eventually() { # check_eventually <label> <expected> <cmd...>
	local label=$1 expected=$2
	shift 2

	local deadline=$((SECONDS + TIMEOUT)) actual=""
	while :; do
		actual=$("$@" 2>/dev/null)
		[ "$actual" = "$expected" ] && break
		[ "$SECONDS" -ge "$deadline" ] && break
		sleep 0.1
	done

	check "$label" "$expected" "$actual"
}

# Wait for a predicate without asserting on it - for setup steps that must have
# landed before the next one is meaningful. Takes a command, not a `[ ... ]`
# expression: the latter would be expanded once by the caller and then re-tested
# with the same stale values forever.
settle_until() { # settle_until <cmd...>
	local deadline=$((SECONDS + TIMEOUT))
	while ! "$@" >/dev/null 2>&1; do
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 0.1
	done
}

addr_is() { [ "$(active_addr)" = "$1" ]; }
where_is() { [ "$(where "$1")" = "$2" ]; }

# Read <cmd...> once it has stopped changing. A baseline sampled while the tree
# is still relaying out makes every comparison against it meaningless, and the
# assertion that follows then fails for a reason that has nothing to do with
# what it is testing.
stable() { # stable <cmd...>
	local prev="" cur deadline=$((SECONDS + TIMEOUT))
	cur=$("$@" 2>/dev/null)
	while [ "$cur" != "$prev" ]; do
		[ "$SECONDS" -ge "$deadline" ] && break
		prev=$cur
		sleep 0.2
		cur=$("$@" 2>/dev/null)
	done
	echo "$cur"
}

addr_of() { clients | jq -r --arg t "$1" '.[]|select(.title==$t)|.address'; }
where() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|"mon\(.monitor)"'; }
geom() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|"\(.at|join(","))/\(.size|join(","))"'; }
ws_of() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.workspace.name'; }
focused_mon() { ctl monitors -j | jq -r '.[]|select(.focused)|.name'; }
active_mon() { ctl activewindow -j | jq -r 'if .monitor == null then "none" else "mon\(.monitor)" end'; }
active_addr() { ctl activewindow -j | jq -r .address; }
active_ws() { ctl activewindow -j | jq -r .workspace.name; }
setflag() { ctl eval "hl.config({ plugin = { hy3 = { $1 = $2 } } })" >/dev/null 2>&1; sleep 0.3; }

focus() {
	dispatch "hl.dsp.focus({ window = 'address:$1' })"
	settle_until addr_is "$1"
}

alive() { kill -0 "$(cat "${TMPDIR:-/tmp}/hy3-nested/pid")" 2>/dev/null && echo yes || echo no; }

# Composite readers, so a two-window assertion can be polled as one value.
where2() { echo "$(where "$1") $(where "$2")"; }
ws2() { echo "$(ws_of "$1") $(ws_of "$2")"; }

# "same", or both values so a failure still names them.
geom_cmp() {
	local g1 g2
	g1=$(geom "$1")
	g2=$(geom "$2")
	[ "$g1" = "$g2" ] && echo same || echo "$g1 vs $g2"
}

is_floating() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.floating|tostring'; }
on_special() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.workspace.name|startswith("special:")|tostring'; }

# is the cursor inside the given window's box?
cursor_in() { # cursor_in <addr>
	clients | jq -r --arg a "$1" --argjson c "$(ctl cursorpos -j)" '
		.[]|select(.address==$a)
		| (($c.x >= .at[0]) and ($c.x <= .at[0] + .size[0])
		   and ($c.y >= .at[1]) and ($c.y <= .at[1] + .size[1])) | tostring'
}

spawn() { # spawn <title>
	dispatch "hl.dsp.exec_cmd('$TERM_CMD --title $1')"
	local deadline=$((SECONDS + 30))
	while [ -z "$(addr_of "$1")" ]; do
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 0.25
	done
	# mapped is not the same as laid out; let the tree settle before asserting
	sleep 0.4
}

cleanup_windows() {
	for a in $(clients | jq -r '.[]|select(.title|startswith("t_"))|.address'); do
		dispatch "hl.dsp.window.close({ window = 'address:'..'$a' })" 0.3
	done
}

"$N" sig >/dev/null 2>&1 || { echo "no nested instance - run test/nested.sh start 2" >&2; exit 1; }

# Monitor identities, sorted by x so index 0 is always the leftmost screen.
mon_field() { ctl monitors -j | jq -r --argjson i "$1" --arg f "$2" 'sort_by(.x)|.[$i]|.[$f]'; }

[ "$(ctl monitors -j | jq 'length')" -ge 2 ] || {
	echo "need at least two monitors - run test/nested.sh start 2" >&2
	exit 1
}

M0_NAME=$(mon_field 0 name); M0="mon$(mon_field 0 id)"
M1_NAME=$(mon_field 1 name); M1="mon$(mon_field 1 id)"
echo "monitors: $M0_NAME ($M0) | $M1_NAME ($M1)"

echo "== setup =="
cleanup_windows
spawn t_a || { echo "could not spawn t_a" >&2; exit 1; }
spawn t_b || { echo "could not spawn t_b" >&2; exit 1; }
A=$(addr_of t_a); B=$(addr_of t_b)
[ -n "$A" ] && [ -n "$B" ] || { echo "could not spawn test windows" >&2; exit 1; }
check_eventually "two windows tiled on mon0" "$M0 $M0" where2 "$A" "$B"

echo
echo "== hy3:movetomonitor =="
focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('+1')"
check_eventually "'+1' moves the node"                    "$M1"      where "$B"
check_eventually "'+1' leaves monitor focus behind"       "$M0_NAME" focused_mon
check_eventually "'+1' leaves keyboard focus behind"      "$M0"      active_mon

focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('-1')"
check_eventually "'-1' moves the node back"               "$M0"      where "$B"

focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})"
check_eventually "follow moves the node"                  "$M1"      where "$B"
check_eventually "follow takes focus along"               "$M1_NAME" focused_mon

focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('+1')"
check_eventually "'+1' wraps at the last monitor"         "$M0"      where "$B"

focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('r')"
check_eventually "direction 'r' moves right"              "$M1"      where "$B"
focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('$M0_NAME')"
check_eventually "monitor name resolves"                  "$M0"      where "$B"

echo
echo "== hy3:movewindow monitor fallthrough =="
setflag movewindow_monitor_fallthrough false
focus "$B"
for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.3; done
check_eventually "flag off: node stays on its monitor"    "$M0"      where "$B"

setflag movewindow_monitor_fallthrough true
focus "$B"
for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.4; done
check_eventually "flag on: node crosses at the edge"      "$M1"      where "$B"
for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.4; done
check_eventually "outermost edge does not lose the node"  "$M1"      where "$B"

echo
echo "== tab group moves intact =="
focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('-1',{follow=true})"
settle_until where_is "$B" "$M0"
focus "$A"
dispatch "hl.plugin.hy3.make_group('tab')" 0.4
focus "$B"
dispatch "hl.plugin.hy3.move_window('l')" 0.4
check_eventually "tabbed windows share geometry"          "same"        geom_cmp "$A" "$B"
dispatch "hl.plugin.hy3.change_focus('raise')" 0.3
dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})" 0.5
check_eventually "whole group moved"                      "$M1 $M1"     where2 "$A" "$B"
check_eventually "group still tabbed after the move"      "same"        geom_cmp "$A" "$B"
dispatch "hl.plugin.hy3.change_focus('lower')" 0.3
dispatch "hl.plugin.hy3.change_group('untab')" 0.4

echo
echo "== special_focus_trap =="
# park t_b on mon1 and open the scratchpad on mon0, so that escaping left to
# right has somewhere to land. focusMonitor only changes the active window if
# the target monitor actually has one, so an empty neighbour would make this
# look like the trap fired when it did not.
focus "$B"
[ "$(where "$B")" = "$M1" ] || dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})" 0.5
check_eventually "neighbour monitor has a window"         "$M1" where "$B"

focus "$A"
[ "$(where "$A")" = "$M0" ] || dispatch "hl.plugin.hy3.move_to_monitor('-1',{follow=true})" 0.5
dispatch "hl.plugin.hy3.move_to_workspace('special:t',{follow=true})" 0.5
check_eventually "window is on the scratchpad"            "special:t" ws_of "$A"
check_eventually "scratchpad is on mon0"                  "$M0"       where "$A"

# Assert on the focused monitor, not on the active window's workspace: a
# scratchpad follows the monitor that gains focus, so a special:t window stays
# "active" whether or not focus actually left the monitor.
# A scratchpad follows whichever monitor focus is on, so pointing focus at mon0
# and then at the scratchpad window brings it along. Do NOT use move_to_monitor
# here: that moves the node to the target monitor's *regular* workspace, taking
# the window off the scratchpad.
scratchpad_to_mon0() {
	dispatch "hl.dsp.focus({ monitor = '$M0_NAME' })" 0.4
	focus "$A"
}

setflag special_focus_trap false
scratchpad_to_mon0
check_eventually "flag off: starts on mon0"               "$M0_NAME"  focused_mon
check_eventually "flag off: starts on the scratchpad"     "special:t" ws_of "$A"
for _ in 1 2 3 4 5 6; do dispatch "hl.plugin.hy3.move_focus('r')"; done
check_eventually "flag off: focus escapes the scratchpad" "$M1_NAME"  focused_mon

setflag special_focus_trap true
scratchpad_to_mon0
check_eventually "flag on: starts on mon0"                "$M0_NAME"  focused_mon
check_eventually "flag on: starts on the scratchpad"      "special:t" ws_of "$A"
for _ in 1 2 3 4 5 6; do dispatch "hl.plugin.hy3.move_focus('r')"; done
check_eventually "flag on: focus stays on the scratchpad" "$M0_NAME"  focused_mon
check_eventually "flag on: still on the scratchpad"       "special:t" active_ws

echo
echo "== hy3:togglefloating =="
focus "$A"
dispatch "hl.plugin.hy3.toggle_floating()" 0.5
check_eventually "unmounts off the scratchpad"            "false" on_special "$A"
check_eventually "focus follows the unmounted window"     "$A"    active_addr
dispatch "hl.plugin.hy3.toggle_floating()" 0.4
check_eventually "toggles floating on"                    "true"  is_floating "$A"
dispatch "hl.plugin.hy3.toggle_floating()" 0.4
check_eventually "toggles floating off"                   "false" is_floating "$A"

echo
echo "== backported upstream fixes =="

# #302: setLayout used to mutate the workspace root group, which every
# is_root() assumption downstream then tripped over (SIGABRT on the next focus
# walk). Raising focus to the root and tabbing it is the shortest route there.
focus "$A"
dispatch "hl.plugin.hy3.change_focus('raise')" 0.3
dispatch "hl.plugin.hy3.change_focus('raise')" 0.3
dispatch "hl.plugin.hy3.change_group('tab')" 0.4
dispatch "hl.plugin.hy3.move_focus('r')" 0.3
check "#302 root group survives changegroup tab" "yes" "$(alive)"
dispatch "hl.plugin.hy3.change_group('untab')" 0.4
dispatch "hl.plugin.hy3.change_focus('lower')" 0.3

# #305: moving a floating window with follow used to focus whichever tiled
# window the origin still had - one that never moved - and leave monitor focus
# behind with it.
#
# #304's own SIGSEGV (a null origin node reaching the follow path) does not
# reproduce here: an emptied special workspace still leaves an implicit group
# behind, so getWorkspaceFocusedNode returns it rather than null. The liveness
# check below is kept as a cheap guard, not as a regression test for that
# crash; #305's condition subsumes the guard in any case.
spawn t_c || { echo "could not spawn t_c" >&2; exit 1; }
C=$(addr_of t_c)
focus "$C"
# pin it to mon0 first: '+1' wraps at the last monitor, so starting on mon1
# would move it back to mon0 and prove nothing.
[ "$(where "$C")" = "$M0" ] || dispatch "hl.plugin.hy3.move_to_monitor('-1',{follow=true})" 0.5
check_eventually "#305 t_c starts on mon0"                  "$M0"       where "$C"
dispatch "hl.plugin.hy3.toggle_floating()" 0.4
check_eventually "#305 t_c is floating"                     "true"      is_floating "$C"
dispatch "hl.plugin.hy3.move_to_workspace('special:f',{follow=true})" 0.5
check_eventually "#305 floating window on the scratchpad"   "special:f" ws_of "$C"
dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})" 0.5
check "#304 instance alive after the move"                  "yes"       "$(alive)"
check_eventually "#305 floating window followed"            "$M1"       where "$C"
check_eventually "#305 focus followed it"                   "$C"        active_addr

# #331: the warp used m_reportedPosition, published asynchronously, so right
# after a move it still named the window's previous position.
check_eventually "#331 cursor warped onto the window"       "true"      cursor_in "$C"
dispatch "hl.dsp.window.close({ window = 'address:'..'$C' })" 0.4

# #300: without follow, nothing refocused the origin, so focus fell through to
# the workspace under the scratchpad.
focus "$A"
[ "$(where "$A")" = "$M0" ] || dispatch "hl.plugin.hy3.move_to_monitor('-1',{follow=true})" 0.5
dispatch "hl.plugin.hy3.move_to_workspace('special:n',{follow=true})" 0.5
focus "$B"
[ "$(where "$B")" = "$M0" ] || dispatch "hl.plugin.hy3.move_to_monitor('-1',{follow=true})" 0.5
dispatch "hl.plugin.hy3.move_to_workspace('special:n',{follow=true})" 0.5
check_eventually "#300 both on the scratchpad"              "special:n special:n" ws2 "$A" "$B"
dispatch "hl.plugin.hy3.move_to_workspace('1')" 0.5
check_eventually "#300 one window left the scratchpad"      "1"         ws_of "$B"
check_eventually "#300 focus stayed on the scratchpad"      "special:n" active_ws
focus "$A"
dispatch "hl.plugin.hy3.move_to_workspace('1',{follow=true})" 0.5

# #296: makegroup on the sole child of a tab group relayouted the tab group
# itself instead of wrapping the child. Two observable halves: the tab bar has
# to survive (it insets its children from the top, so the window's y is the
# oracle), and a wrapper has to actually appear (its inset narrows the window).
top_of() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.at[1]'; }
width_of() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.size[0]'; }

# Reports the numbers on failure. This suite is the only oracle hy3 has - a bare
# "expected true, got false" costs a whole rerun to find out which way it went.
narrower_than() { # narrower_than <addr> <baseline>
	local w
	w=$(width_of "$1")
	if [ -n "$w" ] && [ "$w" -lt "$2" ] 2>/dev/null; then echo true
	else echo "false (width ${w:-none} vs baseline $2)"; fi
}

focus "$A"
dispatch "hl.plugin.hy3.make_group('tab')" 0.5
# stable, not a bare read: the wrap below is measured against these
TAB_TOP=$(stable top_of "$A"); TAB_WIDTH=$(stable width_of "$A")
dispatch "hl.plugin.hy3.make_group('h')" 0.5
check_eventually "#296 tab bar survives the wrap"           "$TAB_TOP" top_of "$A"
check_eventually "#296 a wrapper group was created"         "true"     narrower_than "$A" "$TAB_WIDTH"
dispatch "hl.plugin.hy3.change_focus('raise')" 0.3
dispatch "hl.plugin.hy3.change_group('untab')" 0.4
dispatch "hl.plugin.hy3.change_focus('lower')" 0.3

echo
echo "== teardown =="
cleanup_windows
check "instance survived the run"              "yes" "$(alive)"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# Exercise this fork's additions against a running nested instance.
#
#   test/nested.sh start 2 && test/smoke.sh
#
# Assumes exactly two monitors laid out left to right, which is what nested.sh
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
skip=0

# Set by block(), cleared by a failed require(). While clear, the rest of the
# block reports SKIP instead of running - see require() for why.
block_ok=1

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

# Start a block. Resets the precondition state, so a block that fails its
# require() does not poison the next one.
block() { # block <name>
	echo
	echo "== $1 =="
	block_ok=1
}

# Assert the state a block *starts from*, as opposed to what it tests.
#
# Blocks inherit the tree the previous ones left, and under load a dispatch that
# quietly does not land leaves the next block testing a layout that was never
# set up. Every assertion in it then fails, none of them naming the reason - five
# movetomonitor failures at once, or three window-tag ones, which reads exactly
# like a regression in the code under test and is not one. That signature cost
# several hours of bisecting this session.
#
# So the entry state is checked explicitly, and if it is wrong the block reports
# one PRECONDITION line naming what was missing and skips its assertions rather
# than emitting a wall of failures about it.
require() { # require <what> <expected> <cmd...>
	local what=$1 expected=$2
	shift 2

	local deadline=$((SECONDS + TIMEOUT)) actual=""
	while :; do
		actual=$("$@" 2>/dev/null)
		if [ "$actual" = "$expected" ]; then
			printf '  \033[32mPASS\033[0m %s\n' "$what"
			pass=$((pass + 1))
			return 0
		fi
		[ "$SECONDS" -ge "$deadline" ] && break
		sleep 0.1
	done

	block_ok=0
	printf '  \033[33mPRECONDITION\033[0m %s\n        expected: %s\n        actual:   %s\n' \
		"$what" "$expected" "$actual"
	return 1
}

# The harness could not establish something it needs. Not an assertion failure -
# the plugin was never asked the question - so it marks the block exactly as a
# failed require() does, and the rest of it reports SKIP.
harness_fail() { # harness_fail <what>
	block_ok=0
	printf '  \033[33mPRECONDITION\033[0m %s\n' "$1"
	return 1
}

check() { # check <label> <expected> <actual>
	if [ "$block_ok" -eq 0 ]; then
		printf '  \033[33mSKIP\033[0m %s\n' "$1"
		skip=$((skip + 1))
		return
	fi

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

	# skipping: do not spend the timeout polling for it
	[ "$block_ok" -eq 0 ] && { check "$label" "" ""; return; }

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
mon_is() { [ "$(focused_mon)" = "$1" ]; }

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
# Set a plugin flag and wait for it to actually be live. The eval returning is
# not the same as the config reload having applied: a dispatch fired too soon
# after it runs under the *old* value, which is indistinguishable from the
# feature under test not working. hyprctl getoption reads it back, so wait on
# that rather than on a sleep.
#
# Failure goes through harness_fail rather than `return 1`, which every one of
# the call sites discarded - they invoke it bare, and there is no `set -e`. A
# flag that never applied then left the block asserting against the old value
# and reporting perfectly genuine-looking FAILs in a feature that works. This is
# the same discard already fixed for focus() and pin_mon0; setflag was missed.
setflag() { # setflag <key> <true|false>
	ctl eval "hl.config({ plugin = { hy3 = { $1 = $2 } } })" >/dev/null 2>&1
	local deadline=$((SECONDS + TIMEOUT))
	# `.bool // empty` would be wrong here: jq's // treats false as absent, so a
	# flag being set to false would never look applied.
	while [ "$(ctl getoption "plugin:hy3:$1" -j 2>/dev/null | jq -r 'if has("bool") then (.bool|tostring) else empty end')" != "$2" ]; do
		[ "$SECONDS" -ge "$deadline" ] && { harness_fail "setflag: $1=$2 never applied"; return 1; }
		sleep 0.1
	done
}

# Focus, verified - and this is the one that mattered.
#
# Every dispatch in this suite acts on the *focused* node, so a focus that does
# not land silently redirects everything after it at the wrong window. That is
# how a whole block fails at once while each individual assertion looks
# reasonable, and check_eventually cannot rescue it: the operation went
# somewhere else, so the state it waits for is never even requested.
#
# The result used to be discarded at all 36 call sites. Under load the first
# dispatch loses the race often enough to matter, so it retries once - which
# fixes most of it outright - and only then gives up, marking the block instead
# of letting it run against a window it did not choose.
focus() {
	dispatch "hl.dsp.focus({ window = 'address:$1' })"
	settle_until addr_is "$1" && return 0

	dispatch "hl.dsp.focus({ window = 'address:$1' })"
	settle_until addr_is "$1" && return 0

	harness_fail "focus never reached $1 (active: $(active_addr))"
}

# Windows spawn on whatever monitor is current, which is why setup pins it -
# see the note there. Every later block that spawns has to pin it again rather
# than inherit it: the sections in between move windows across monitor edges,
# and hyprland tracks the current monitor by cursor position whether or not
# focus follows the pointer. A block that assumes it spawns on mon0 because the
# block before it happened to leave things there fails, later, in an assertion
# that names a monitor and not the reason.
pin_mon0() {
	dispatch "hl.dsp.focus({ monitor = '$M0_NAME' })" 0.4
	settle_until mon_is "$M0_NAME" && return 0

	dispatch "hl.dsp.focus({ monitor = '$M0_NAME' })" 0.4
	settle_until mon_is "$M0_NAME" && return 0

	harness_fail "monitor focus never reached $M0_NAME (focused: $(focused_mon))"
}

# Move a node until it lands on the given monitor. Not a fixed count: at the
# far edge of a layout `movewindow` wraps the node into a new group instead of
# going anywhere, so how many moves it then takes to unwind back out and reach
# the root boundary depends on what the moves before it did. A hardcoded three
# passed twice and failed twice on the same tree.
move_window_until() { # move_window_until <addr> <dir> <target mon> [lua opts]
	local i=0
	while [ "$(where "$1")" != "$3" ]; do
		[ "$i" -ge 8 ] && { harness_fail "$1 never reached $3 after 8 moves"; return 1; }
		dispatch "hl.plugin.hy3.move_window('$2'${4:+, $4})" 0.4
		i=$((i + 1))
	done
}

# A pidfile alone is not proof: a crashed compositor's pid can be recycled
# within seconds, and this is the suite's only crash oracle. The pidfile's
# directory is per-checkout - ask nested.sh rather than recomputing it.
alive() {
	local pid comm
	pid=$(cat "$("$N" rundir)/pid" 2>/dev/null) || true
	comm=$(cat "/proc/${pid:-0}/comm" 2>/dev/null) || true
	[ -n "$pid" ] && [ "$comm" = Hyprland ] && kill -0 "$pid" 2>/dev/null && echo yes || echo no
}

# Composite readers, so a two-window assertion can be polled as one value.
where2() { echo "$(where "$1") $(where "$2")"; }
where4() { echo "$(where "$1") $(where "$2") $(where "$3") $(where "$4")"; }
ws2() { echo "$(ws_of "$1") $(ws_of "$2")"; }
floating2() { echo "$(is_floating "$1") $(is_floating "$2")"; }

# "same", or both values so a failure still names them.
geom_cmp() {
	local g1 g2
	g1=$(geom "$1")
	g2=$(geom "$2")
	[ "$g1" = "$g2" ] && echo same || echo "$g1 vs $g2"
}

is_floating() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.floating|tostring'; }
titled_count() { clients | jq -r --arg p "$1" '[.[]|select(.title|startswith($p))]|length'; }
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
		[ "$SECONDS" -ge "$deadline" ] && { harness_fail "$1 never mapped"; return 1; }
		sleep 0.25
	done
	# mapped is not the same as laid out; let the tree settle before asserting
	sleep 0.4
}

cleanup_windows() {
	for a in $(clients | jq -r '.[]|select(.title|startswith("t_"))|.address'); do
		dispatch "hl.dsp.window.close({ window = 'address:'..'$a' })" 0.3
	done
	# closes are not synchronous - a later block respawning the same title must
	# not match a window that is still unmapping.
	local deadline=$((SECONDS + TIMEOUT))
	while [ "$(titled_count t_)" != 0 ]; do
		[ "$SECONDS" -ge "$deadline" ] && { harness_fail "t_* windows never finished closing"; return 1; }
		sleep 0.25
	done
}

"$N" sig >/dev/null 2>&1 || { echo "no nested instance - run test/nested.sh start 2" >&2; exit 1; }

# Monitor identities, sorted by x so index 0 is always the leftmost screen.
mon_field() { ctl monitors -j | jq -r --argjson i "$1" --arg f "$2" 'sort_by(.x)|.[$i]|.[$f]'; }

# Exactly two, not at least two: the wrap and relative-offset assertions are
# calibrated for a pair (with three, '+1' from mon1 goes to mon2, not mon0),
# and the failures that produces look like plugin bugs.
[ "$(ctl monitors -j | jq 'length')" -eq 2 ] || {
	echo "the suite assumes exactly two monitors - run test/nested.sh start 2" >&2
	exit 1
}

M0_NAME=$(mon_field 0 name); M0="mon$(mon_field 0 id)"
M1_NAME=$(mon_field 1 name); M1="mon$(mon_field 1 id)"
echo "monitors: $M0_NAME ($M0) | $M1_NAME ($M1)"

block "setup"
# Start from a known monitor. Windows spawn wherever focus happens to be, so a
# leftover focus on mon1 - from a previous run, or from poking at the instance
# by hand between runs - silently puts the whole suite on the wrong screen and
# fails every monitor assertion from here down, none of which names the cause.
dispatch "hl.dsp.focus({ monitor = '$M0_NAME' })" 0.4
cleanup_windows
spawn t_a || { echo "could not spawn t_a" >&2; exit 1; }
spawn t_b || { echo "could not spawn t_b" >&2; exit 1; }
A=$(addr_of t_a); B=$(addr_of t_b)
[ -n "$A" ] && [ -n "$B" ] || { echo "could not spawn test windows" >&2; exit 1; }
check_eventually "two windows tiled on mon0" "$M0 $M0" where2 "$A" "$B"

block "hy3:movetomonitor"
require "t_b starts on mon0" "$M0" where "$B" 
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

block "hy3:movewindow monitor fallthrough"
require "t_b starts on mon0" "$M0" where "$B"
setflag movewindow_monitor_fallthrough false
focus "$B"
for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.3; done
check_eventually "flag off: node stays on its monitor"    "$M0"      where "$B"

setflag movewindow_monitor_fallthrough true
focus "$B"
for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.4; done
check_eventually "flag on: node crosses at the edge"      "$M1"      where "$B"

# fork: the cross-monitor half of the move warps, so that with
# input:follow_mouse the pointer is not left on the monitor the window came
# from, where the next keybind would act on whatever it is now hovering. This
# is the gap #311 pointed at. A move that stays inside one monitor is
# unchanged and still never warps.
#
# "cursor crossed with the node" is the load-bearing one - verified failing
# against a build with shiftMonitor's warp back to a hardcoded false. The other
# three describe behaviour that held before it too.
check_eventually "flag on: cursor crossed with the node"  "true"     cursor_in "$B"
move_window_until "$B" l "$M0" "{warp=false}"
check_eventually "nowarp: node crossed back"              "$M0"      where "$B"
check_eventually "nowarp: cursor stayed behind"           "false"    cursor_in "$B"
move_window_until "$B" r "$M1"
check_eventually "flag on: node crossed the edge again"   "$M1"      where "$B"

for _ in 1 2 3; do dispatch "hl.plugin.hy3.move_window('r')" 0.4; done
check_eventually "outermost edge does not lose the node"  "$M1"      where "$B"

block "tab group moves intact"
require "both windows exist" "$M0 $M1" where2 "$A" "$B"
focus "$B"
dispatch "hl.plugin.hy3.move_to_monitor('-1',{follow=true})"
settle_until where_is "$B" "$M0" || harness_fail "t_b never returned to mon0"
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

block "special_focus_trap"
# park t_b on mon1 and open the scratchpad on mon0, so that escaping left to
# right has somewhere to land. focusMonitor only changes the active window if
# the target monitor actually has one, so an empty neighbour would make this
# look like the trap fired when it did not.
focus "$B"
[ "$(where "$B")" = "$M1" ] || dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})" 0.5
require          "neighbour monitor has a window"         "$M1" where "$B"

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

block "hy3:togglefloating"
# The three toggles below only mean "unmount, float on, float off" if the first
# one finds t_a on the scratchpad. If it does not, each one shifts by a step:
# the block ends with t_a floating rather than tiled, both float assertions
# fail, and t_a then stays floating for the rest of the run. Assert the
# precondition so that goes wrong here, by name, instead of resurfacing later
# as an unrelated-looking geometry failure.
focus "$A"
require          "starts on the scratchpad"               "true"  on_special "$A"
dispatch "hl.plugin.hy3.toggle_floating()" 0.5
check_eventually "unmounts off the scratchpad"            "false" on_special "$A"
check_eventually "focus follows the unmounted window"     "$A"    active_addr
dispatch "hl.plugin.hy3.toggle_floating()" 0.4
check_eventually "toggles floating on"                    "true"  is_floating "$A"
dispatch "hl.plugin.hy3.toggle_floating()" 0.4
check_eventually "toggles floating off"                   "false" is_floating "$A"

block "backported upstream fixes"

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
#
# Floating is reported separately because it is not a narrower-or-wider
# question at all: a floating window has a fixed size that no makegroup
# touches, so it reads as "no wrapper appeared" while the actual fault is
# somewhere else entirely. That is how this assertion once failed with
# "width 800 vs baseline 800" - 800x600 is alacritty's floating default, and
# the window under test had been left floating by an earlier section.
narrower_than() { # narrower_than <addr> <baseline>
	local w f
	w=$(width_of "$1")
	f=$(is_floating "$1")
	if [ "$f" != false ]; then echo "false (window is floating=${f:-gone}, so its size is fixed)"
	elif [ -n "$w" ] && [ "$w" -lt "$2" ] 2>/dev/null; then echo true
	else echo "false (width ${w:-none} vs baseline $2)"; fi
}

wider_than() { # wider_than <addr> <baseline>
	local w
	w=$(width_of "$1")
	if [ -n "$w" ] && [ "$w" -gt "$2" ] 2>/dev/null; then echo true
	else echo "false (width ${w:-none} vs baseline $2)"; fi
}

# a tab bar pushes its children down, so a larger y means a bar is present
below() { # below <addr> <baseline>
	local t
	t=$(top_of "$1")
	if [ -n "$t" ] && [ "$t" -gt "$2" ] 2>/dev/null; then echo true
	else echo "false (top ${t:-none} vs baseline $2)"; fi
}

# Fresh windows, not the ones the rest of the suite has been passing around.
# This block used to measure t_a, forty-odd operations after it was spawned,
# which made it the place where any earlier mistake surfaced - as a geometry
# comparison that named neither the mistake nor the section it came from.
#
# Two windows, not one: makegroup on a workspace holding a single client was
# its own upstream bug (#192, fixed below), and this assertion is not about it.
pin_mon0
cleanup_windows
spawn t_v || { echo "could not spawn t_v" >&2; exit 1; }
spawn t_w || { echo "could not spawn t_w" >&2; exit 1; }
V=$(addr_of t_v); W=$(addr_of t_w)
[ -n "$V" ] && [ -n "$W" ] || { echo "could not spawn #296 windows" >&2; exit 1; }
check_eventually "#296 starts from two tiled windows"       "false false" floating2 "$V" "$W"

focus "$W"
dispatch "hl.plugin.hy3.make_group('tab')" 0.5
# stable, not a bare read: the wrap below is measured against these
TAB_TOP=$(stable top_of "$W"); TAB_WIDTH=$(stable width_of "$W")
dispatch "hl.plugin.hy3.make_group('h')" 0.5
check_eventually "#296 tab bar survives the wrap"           "$TAB_TOP" top_of "$W"
check_eventually "#296 a wrapper group was created"         "true"     narrower_than "$W" "$TAB_WIDTH"
dispatch "hl.plugin.hy3.change_focus('raise')" 0.3
dispatch "hl.plugin.hy3.change_group('untab')" 0.4
dispatch "hl.plugin.hy3.change_focus('lower')" 0.3

block "fixes to upstream bugs"

# #332: getNodeFromTarget walks *every* target in the tree looking for one, and
# it dereferenced each with as_target(), which throws on an expired weak
# pointer. So one dead target anywhere in the tree threw before the search ever
# reached the node it was asked for. removeTarget is called from
# CWindow::unmapWindow, which does not catch: SIGABRT on window close, and the
# watchdog restarts the compositor in safe mode with no plugins.
#
# These assertions do NOT reproduce the crash - they pass against a pre-fix
# build, so they are sanity checks, not regression tests. Read them that way.
#
# The throw needs a *stranded* node: one whose target expired without hy3's
# removeTarget ever running, left in the tree for the next unmap to walk past.
# A batched close does not produce one - the compositor still drains the unmaps
# one at a time, and each takes its own node out. The known way to strand a node
# is removeTarget's `if (g_suppressInsert) return`, which needs an unmap to land
# inside moveNodeToWorkspace's assignToSpace loop; racing closes against that
# move over 12 rounds never hit it here. The reporter could not isolate a
# trigger either, and saw it twice rather than reliably.
#
# What is covered is the observable half - a tab group's windows all unmapping
# in one batch does not take the compositor down and does not leave the tree
# holding stale nodes. The guards themselves are argued from the code path, not
# from these assertions.
pin_mon0
cleanup_windows
for t in t_x t_y t_z; do
	spawn "$t" || { echo "could not spawn $t" >&2; exit 1; }
done
X=$(addr_of t_x); Y=$(addr_of t_y); Z=$(addr_of t_z)
[ -n "$X" ] && [ -n "$Y" ] && [ -n "$Z" ] || { echo "could not spawn unmap windows" >&2; exit 1; }

focus "$X"
dispatch "hl.plugin.hy3.make_group('tab')" 0.4
for a in "$Y" "$Z"; do
	focus "$a"
	dispatch "hl.plugin.hy3.move_window('l')" 0.4
done
check_eventually "#332 three windows tabbed together"     "same" geom_cmp "$X" "$Z"

# Not `dispatch`, which sleeps after each one - these have to overlap.
for a in "$X" "$Y" "$Z"; do
	ctl dispatch "hl.dsp.window.close({ window = 'address:'..'$a' })" >/dev/null 2>&1
done
check_eventually "#332 batched unmap removed every window" "0"   titled_count t_
check "#332 instance survived a batched unmap"             "yes" "$(alive)"

# A tree left holding a stale node is the other half of the failure: the
# compositor stays up but the next insert lands in a corrupt tree. Spawning
# into the emptied workspace is the cheapest check that it is really empty.
spawn t_x || { echo "could not respawn t_x after the unmap batch" >&2; exit 1; }
X=$(addr_of t_x)
check_eventually "#332 layout still tiles after the unmap" "$M0" where "$X"

# #241: moving a fullscreen window across monitors. Upstream calls this a
# crash; the null dereference it reported - moveNodeToWorkspace's follow branch
# reaching node->parent with node null - is long gone, and this passes without
# any of the fork's fixes. It is here because the fork *enables* the path:
# hy3:movetomonitor and the movewindow fallthrough are how a node crosses a
# monitor boundary at all, and a fullscreen window takes the moved_floating
# branch, where hy3 never touches its node and hyprland's own move has to fire
# the layout callbacks that fix the tree.
#
# The origin's remaining window reclaiming full width is the load-bearing half:
# it says the moved node really left the origin tree, rather than being stranded
# there while its window went elsewhere - which is exactly the state #332's
# throw needs.
pin_mon0
cleanup_windows
spawn t_f || { echo "could not spawn t_f" >&2; exit 1; }
spawn t_g || { echo "could not spawn t_g" >&2; exit 1; }
F=$(addr_of t_f); G=$(addr_of t_g)
[ -n "$F" ] && [ -n "$G" ] || { echo "could not spawn fullscreen windows" >&2; exit 1; }
settle_until where_is "$F" "$M0" || harness_fail "t_f never reached mon0"
FULL_WIDTH=$(stable width_of "$G")

focus "$F"
dispatch "hl.dsp.window.fullscreen()" 0.6
check_eventually "#241 window is fullscreen on mon0"       "$M0" where "$F"
dispatch "hl.plugin.hy3.move_to_monitor('+1',{follow=true})" 0.8
check_eventually "#241 fullscreen window crossed monitors" "$M1" where "$F"
check "#241 instance survived the move"                    "yes" "$(alive)"
check_eventually "#241 origin reclaimed the space"         "true" wider_than "$G" "$FULL_WIDTH"
dispatch "hl.dsp.window.fullscreen()" 0.6
check_eventually "#241 unfullscreens tiled on the target"  "$M1" where "$F"

# #192: makegroup toggle on a workspace holding a single window. The collapse
# itself worked - the tab bar went away - but collapseParents returns the root
# whenever the group it collapsed hung directly off it, which is always the
# case here, and the geometry recalc was gated on that return *not* being the
# root. So the window kept the size the tab bar had inset it to: bar gone, gap
# left behind, until an unrelated recalc (a workspace switch) reclaimed it.
#
# Unlike the two blocks above, "toggling off reclaims the gap" really is a
# regression test - verified failing against a build with the branch disabled.
# The other two are sanity checks around it.
pin_mon0
cleanup_windows
spawn t_s || { echo "could not spawn t_s" >&2; exit 1; }
S=$(addr_of t_s)
[ -n "$S" ] || { echo "could not spawn the #192 window" >&2; exit 1; }
BARE_TOP=$(stable top_of "$S")

dispatch "hl.plugin.hy3.make_group('tab',{toggle=true})" 0.5
check_eventually "#192 the tab bar insets the sole window" "true"      below "$S" "$BARE_TOP"
dispatch "hl.plugin.hy3.make_group('tab',{toggle=true})" 0.5
check_eventually "#192 toggling off reclaims the gap"      "$BARE_TOP" top_of "$S"
check "#192 instance survived the toggle"                  "yes"       "$(alive)"

block "hy3:movewindow on floating windows"
# A floating window is not in the hy3 tree, so getWorkspaceFocusedNode hands
# back whatever tiled node last had focus and upstream moves that one instead -
# a window the user is not looking at (#223). The first two assertions are the
# regression test for that, and they hold with the feature flag off, which is
# the point: not moving the wrong window is a fix, moving the floating one is
# the feature.
left_of() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.at[0]'; }
right_of_x() { # right_of_x <addr> <baseline>
	clients | jq -r --arg a "$1" --argjson x "$2" '.[]|select(.address==$a)|(.at[0] > $x)|tostring'
}
left_of_x() { # left_of_x <addr> <baseline>
	clients | jq -r --arg a "$1" --argjson x "$2" '.[]|select(.address==$a)|(.at[0] < $x)|tostring'
}

# Two tiled windows, not one: moving the wrong node is only observable if the
# tree has somewhere to move it to. With a single tiled window the bad move is
# a no-op and the assertion passes against a build carrying the bug.
tiled_geoms() { echo "$(geom "$1") $(geom "$2")"; }

pin_mon0
cleanup_windows
spawn t_f || { echo "could not spawn t_f" >&2; exit 1; }
spawn t_g || { echo "could not spawn t_g" >&2; exit 1; }
spawn t_h || { echo "could not spawn t_h" >&2; exit 1; }
FL=$(addr_of t_f); TI=$(addr_of t_g); TI2=$(addr_of t_h)
[ -n "$FL" ] && [ -n "$TI" ] && [ -n "$TI2" ] || { echo "could not spawn the floating-move windows" >&2; exit 1; }

focus "$FL"
dispatch "hl.plugin.hy3.toggle_floating()" 0.5
check_eventually "the moved window is floating"          "true" is_floating "$FL"

# Floating a tiled window keeps its geometry, so the tiled neighbour expands
# into the space it used to share. A pointer sitting in that half now hovers
# the *tiled* window, and with input:follow_mouse the next layout change hands
# focus to it - at which point every assertion below silently tests the tiled
# path instead. Park the pointer inside the floating window and say so, rather
# than inheriting wherever the previous block left it. This block failed
# intermittently exactly that way, reporting the two tiled windows swapping.
focus "$FL"
dispatch "hl.plugin.hy3.warp_cursor()" 0.4
check_eventually "the pointer is inside the floating window" "true" cursor_in "$FL"
check_eventually "the floating window holds focus"       "$FL"  active_addr

# The tiled neighbours take the whole workspace once the other window floats -
# sample their geometry only after that has settled, or the baseline is the
# three-window one and every comparison against it is meaningless.
TILED_GEOM=$(stable tiled_geoms "$TI" "$TI2")
FLOAT_X=$(stable left_of "$FL")

# Every move below goes right before it goes left. Floating a tiled window
# keeps the geometry it had, so a window floated out of the left half of the
# workspace is *already* against the left work edge: a left move there does
# nothing whether the feature is on or off, and the assertion passes for the
# wrong reason. This one failed that way during development.
#
# The fallthrough has to come off for the "off" pair as well - it is on for the
# rest of the run, and a floating window at the work edge is exactly what it
# hands to the next monitor.
setflag movewindow_monitor_fallthrough false
setflag movewindow_floating false
dispatch "hl.plugin.hy3.move_window('r')" 0.4
check "off: the tiled windows are left alone"            "$TILED_GEOM" "$(tiled_geoms "$TI" "$TI2")"
check "off: the floating window stays put"               "$FLOAT_X"    "$(left_of "$FL")"

setflag movewindow_floating true
dispatch "hl.plugin.hy3.move_window('r')" 0.4
check_eventually "on: snaps to the right work edge"      "true" right_of_x "$FL" "$FLOAT_X"
check "on: the tiled windows are still left alone"       "$TILED_GEOM" "$(tiled_geoms "$TI" "$TI2")"

RIGHT_X=$(stable left_of "$FL")
dispatch "hl.plugin.hy3.move_window('l')" 0.4
check_eventually "on: snaps to the left work edge"       "true" left_of_x "$FL" "$RIGHT_X"

# An edge is a stop, not a step: the second move has nowhere to go. This is
# what distinguishes hyprland's floating semantics from a sway-style nudge by
# a fixed number of pixels, which is the other thing this could have been.
LEFT_X=$(stable left_of "$FL")
dispatch "hl.plugin.hy3.move_window('l')" 0.4
check "on: the work edge is a stop, not a step"          "$LEFT_X" "$(left_of "$FL")"
check_eventually "the floating window stayed on mon0"    "$M0"  where "$FL"

# With both flags on the work edge is where the fallthrough takes over, the
# same way it does for a node at the edge of the tree: the first move snaps,
# the second one crosses. This is also the only thing a floating window did
# before the feature existed, so it has to keep working.
setflag movewindow_monitor_fallthrough true
dispatch "hl.plugin.hy3.move_window('r')" 0.4
dispatch "hl.plugin.hy3.move_window('r')" 0.5
check_eventually "at the edge, it falls through to mon1" "$M1" where "$FL"
check "instance survived the floating moves"             "yes" "$(alive)"

block "tree edits while a floating window has focus"
# The quiet half of the same problem: makegroup and friends also act on the
# node getWorkspaceFocusedNode hands back, so they restructured the tiled tree
# behind the floating window the user was looking at. Nothing moves where the
# user is looking, which is why this one went unreported.
#
# The oracle is the geometry of the two tiled windows: a workspace that got
# tabbed pushes them down by the bar inset, as in #192, and an expand widens
# one of them. A workspace nothing happened to leaves both where they were.

pin_mon0
cleanup_windows
spawn t_i || { echo "could not spawn t_i" >&2; exit 1; }
spawn t_j || { echo "could not spawn t_j" >&2; exit 1; }
spawn t_k || { echo "could not spawn t_k" >&2; exit 1; }
P=$(addr_of t_i); Q=$(addr_of t_j); K=$(addr_of t_k)
[ -n "$P" ] && [ -n "$Q" ] && [ -n "$K" ] || { echo "could not spawn the tree-edit windows" >&2; exit 1; }

focus "$K"
dispatch "hl.plugin.hy3.toggle_floating()" 0.5
check_eventually "the focused window is floating"        "true" is_floating "$K"

# Same pointer trap as the block above: if focus slips to a tiled window the
# guard under test is never reached and every assertion here passes vacuously.
focus "$K"
dispatch "hl.plugin.hy3.warp_cursor()" 0.4
check_eventually "the floating window holds focus"       "$K"  active_addr

TILED=$(stable tiled_geoms "$P" "$Q")
TOP=$(top_of "$P")
dispatch "hl.plugin.hy3.make_group('tab')" 0.5
check "makegroup leaves the tiled tree alone"            "$TILED" "$(tiled_geoms "$P" "$Q")"
dispatch "hl.plugin.hy3.change_group('tab')" 0.5
check "changegroup leaves the tiled tree alone"          "$TILED" "$(tiled_geoms "$P" "$Q")"
dispatch "hl.plugin.hy3.expand('expand')" 0.5
check "expand leaves the tiled tree alone"               "$TILED" "$(tiled_geoms "$P" "$Q")"

# The control, and the point of it: the guard is on the focused window being
# floating, not on a floating window existing. With focus back on the tiled
# layer the same dispatcher has to work exactly as it always did - a guard that
# is too broad passes every assertion above and breaks makegroup outright.
focus "$P"
dispatch "hl.plugin.hy3.make_group('tab')" 0.6
check_eventually "with tiled focus it still tabs"        "true" below "$P" "$TOP"
check "instance survived the tree edits"                 "yes" "$(alive)"

block "#327 window tags"
# Backported feature, gated behind plugin:hy3:tag_windows. Tags are synced from
# the tree mutation primitives, so turning the flag on does not retroactively
# tag an existing tree - the "off" phase has to come first and leave the tree
# flat again, or the "on" phase inherits tags it never set.
tags_of() { clients | jq -r --arg a "$1" '.[]|select(.address==$a)|.tags|sort|join(",")'; }

# The flag comes off *before* the windows are spawned, not after: tags are
# applied as the tree is built, so a spawn under a flag left on by an earlier
# run arrives pre-tagged and the "off" assertions fail against tags this block
# never asked for. That is a real ordering trap, hit while writing this.
setflag tag_windows false

pin_mon0
cleanup_windows
spawn t_l || { echo "could not spawn t_l" >&2; exit 1; }
spawn t_m || { echo "could not spawn t_m" >&2; exit 1; }
L=$(addr_of t_l); M=$(addr_of t_m)
[ -n "$L" ] && [ -n "$M" ] || { echo "could not spawn the tag windows" >&2; exit 1; }
require "tag windows spawned on mon0" "$M0 $M0" where2 "$L" "$M"

focus "$M"
dispatch "hl.plugin.hy3.make_group('tab')" 0.5
check "off: tagging is a true no-op"                     "" "$(tags_of "$M")"
dispatch "hl.plugin.hy3.make_group('tab',{toggle=true})" 0.5

setflag tag_windows true
check "a plain window carries no tags"                   "" "$(tags_of "$M")"
dispatch "hl.plugin.hy3.make_group('tab')" 0.5
check_eventually "a tabbed group tags both"              "hy3_grouped,hy3_tabbed" tags_of "$M"
check "the window outside it is untagged"                "" "$(tags_of "$L")"
dispatch "hl.plugin.hy3.change_group('h')" 0.5
check_eventually "untabbing drops only hy3_tabbed"       "hy3_grouped" tags_of "$M"
dispatch "hl.plugin.hy3.make_group('h',{toggle=true})" 0.5
check_eventually "dissolving the group clears both"      "" tags_of "$M"

# Everything above asserts on the *tag*. None of it notices whether the
# windowrules keyed on that tag are re-evaluated, which is the entire reason the
# feature exists - a tag nobody acts on is invisible. Setting the tag and
# re-running the rules are two separate steps in hyprland, and an implementation
# can get the first right and drop the second silently.
#
# border_size is the observable: it is a dynamic rule, and on a tiled window it
# comes out of the window's size inside an unchanged layout slot. Width rather
# than height, because tabbing takes the bar off the top - the height would move
# whether or not the rule fired, and the width only moves if it did.
tagrule_narrower() { [ "$(width_of "$M")" -lt "$TAGRULE_BASE" ] 2>/dev/null && echo yes || echo no; }
tagrule_restored() { [ "$(width_of "$M")" = "$TAGRULE_BASE" ] && echo yes || echo no; }

ctl eval "hl.window_rule({ match = { tag = 'hy3_tabbed' }, border_size = 40 })" >/dev/null 2>&1
TAGRULE_BASE=$(width_of "$M")
dispatch "hl.plugin.hy3.make_group('tab')" 0.5
check_eventually "a rule keyed on the tag takes effect"  "yes" tagrule_narrower
dispatch "hl.plugin.hy3.make_group('tab',{toggle=true})" 0.5
check_eventually "and is undone when the tag goes"       "yes" tagrule_restored

check "instance survived the tag syncing"                "yes" "$(alive)"
setflag tag_windows false

block "#211 swapTargets"
# Hy3Layout::swapTargets was an empty `// todo` upstream, which made hyprland's
# own swap dispatchers silent no-ops under hy3. Everything below drives
# hyprland's dispatcher rather than a hy3 one - the fix is that a dispatcher
# the user already had starts doing something.
#
# Four of these fail against the pre-fix tree. The other four are checked
# against it too, and the reason they pass is worth writing down: hyprland does
# its own half of a swap either way. ITarget::swap rewrites CSpace::m_targets,
# swaps the two m_space pointers and flips the floating flags without asking
# the algorithm anything, so "the workspaces changed" and "the layers changed"
# are true with an empty swapTargets and an hy3 tree that no longer describes
# the screen. Every assertion that bites therefore reads a *box* - only the
# layout decides those.
swap_geoms() { echo "$(geom "$1") $(geom "$2")"; }

pin_mon0
cleanup_windows
spawn t_n || { echo "could not spawn t_n" >&2; exit 1; }
spawn t_o || { echo "could not spawn t_o" >&2; exit 1; }
SW_N=$(addr_of t_n); SW_O=$(addr_of t_o)
[ -n "$SW_N" ] && [ -n "$SW_O" ] || { echo "could not spawn the swap windows" >&2; exit 1; }

focus "$SW_N"
G_N=$(stable geom "$SW_N"); G_O=$(stable geom "$SW_O")
dispatch "hl.dsp.window.swap({ direction = 'right' })" 0.5
check_eventually "the two windows exchange boxes"        "$G_O $G_N" swap_geoms "$SW_N" "$SW_O"
check_eventually "focus stays with the window, not the slot" "$SW_N" active_addr

# The load-bearing one. swapInDirection preserves focus, so hyprland fires no
# focus event and hy3's own focused_child would still name the slot the window
# just left. movefocus is the only oracle for that - it walks the tree from
# whatever hy3 believes is focused, so a stale marker sends it the wrong way.
# t_n sits on the right after the swap: with the marker corrected, a left move
# lands on t_o; with a stale one there is nothing to the left and focus stays
# put. Verified by ablation - dropping the markFocused call fails this and
# nothing else.
dispatch "hl.plugin.hy3.move_focus('l')" 0.4
check_eventually "hy3's focus marker followed the window" "$SW_O" active_addr

focus "$SW_N"
dispatch "hl.dsp.window.swap({ direction = 'left' })" 0.5
check_eventually "swapping back restores both boxes"     "$G_N $G_O" swap_geoms "$SW_N" "$SW_O"

# Two spaces: hyprland calls the algorithm once per space, each naming its own
# target first, and neither call sees a node for the other one. Node identity
# staying with the slot is what makes that work - there is no foreign node to
# splice in, only a target to adopt.
dispatch "hl.dsp.focus({ workspace = '7' })" 0.6
spawn t_p || { echo "could not spawn t_p" >&2; exit 1; }
SW_P=$(addr_of t_p)
[ -n "$SW_P" ] || { echo "could not spawn the cross-workspace swap window" >&2; exit 1; }
focus "$SW_P"
dispatch "hl.dsp.window.swap({ target = 'address:$SW_N' })" 0.6
check_eventually "a cross-workspace swap moves both windows" "7 1" ws2 "$SW_N" "$SW_P"
dispatch "hl.dsp.focus({ workspace = '1' })" 0.6
# The one that bites: arriving on workspace 1 is hyprland's doing, but taking
# over the slot t_n left is hy3's. Without the fix the incoming window is not
# in this tree at all and keeps the box it had on workspace 7.
check_eventually "the incoming window takes the vacated slot" "$G_N" geom "$SW_P"

# One tiled, one floating: hyprland calls each mode algorithm once, ours naming
# the tiled target first, so the tiled slot has to adopt a target that is still
# marked floating when it arrives.
#
# The box is asserted only after a later layout event, and that is not slack in
# the harness. hyprland flips the floating flags in a scope guard that runs
# *after* it recalculates the space, so the window that just became tiled is
# laid out while it still reads as floating and takes the floating branch of
# CWindowTarget::updatePos - it holds the ungapped box until something else
# recalculates. That ordering is hyprland's and not hy3's to paper over:
# dwindle lands 2px out on the same sequence. What is hy3's, and what this
# checks, is that the window ends up in the tree at all.
focus "$SW_O"
dispatch "hl.dsp.window.float({})" 0.5
check_eventually "one of the pair is floating"           "true" is_floating "$SW_O"
TILED_SLOT=$(stable geom "$SW_P")
focus "$SW_P"
dispatch "hl.dsp.window.swap({ target = 'address:$SW_O' })" 0.6
check_eventually "a tiled/floating swap trades both layers" "true false" floating2 "$SW_P" "$SW_O"
focus "$SW_O"
dispatch "hl.plugin.hy3.equalize()" 0.4
check_eventually "the tiled slot lays out the window it adopted" "$TILED_SLOT" geom "$SW_O"
check "instance survived the swaps"                      "yes" "$(alive)"

block "#197 changefocus raise"
# `raise` at the workspace group has nowhere further up, and upstream answers
# that by wrapping to the bottom: one press past the top undoes the whole walk
# and leaves a single window focused. plugin:hy3:changefocus_raise_stops makes
# it stop instead, which is what `lower` already does at the other end.
#
# The oracle is that a focused *group* is not a focused window - hyprctl
# activewindow reports a null address for one - so "wrapped" and "stopped" are
# told apart by whether a window address comes back.
#
# Both phases are run, and the "off" phase is what keeps the gate honest: it
# asserts the upstream wrap is still exactly what an unconfigured hy3 does.
raise_x() { # raise_x <n>
	local i
	for ((i = 0; i < $1; i++)); do dispatch "hl.plugin.hy3.change_focus('raise')" 0.35; done
}

setflag changefocus_raise_stops false
pin_mon0
cleanup_windows
spawn t_q || { echo "could not spawn t_q" >&2; exit 1; }
spawn t_r || { echo "could not spawn t_r" >&2; exit 1; }
spawn t_u || { echo "could not spawn t_u" >&2; exit 1; }
RS_U=$(addr_of t_u)
[ -n "$RS_U" ] || { echo "could not spawn the raise windows" >&2; exit 1; }

# Nest t_u one level down, so the walk up is window -> group -> workspace group
# and the wrap has somewhere to wrap back *to*. On a flat tree the deepest
# selection is the window a wrap lands on anyway, and both phases would agree.
focus "$RS_U"
dispatch "hl.plugin.hy3.make_group('v')" 0.5
raise_x 2
check_eventually "off: two raises reach the workspace group" "null" active_addr
raise_x 1
check_eventually "off: a third raise wraps back to a window" "$RS_U" active_addr

setflag changefocus_raise_stops true
focus "$RS_U"
raise_x 3
check_eventually "on: the walk up stops at the workspace group" "null" active_addr
raise_x 1
check_eventually "on: holding the bind does not wrap either"    "null" active_addr

# Stopped, not wedged: the group is still selected and still descends.
dispatch "hl.plugin.hy3.change_focus('lower')" 0.35
dispatch "hl.plugin.hy3.change_focus('lower')" 0.35
check_eventually "on: lower still walks back down"              "$RS_U" active_addr
check "instance survived the raises"                            "yes" "$(alive)"
setflag changefocus_raise_stops false

block "layout_fallback"
# plugin:hy3:layout_fallback: on a workspace managed by another layout hy3's
# dispatchers used to no-op silently. With the flag set, movefocus, movewindow,
# togglefloating and movetomonitor delegate to hyprland's native actions
# instead. Workspace 9 is pinned to the scrolling layout in nested.lua, which
# is what makes it foreign here.
#
# The "off" phase has to come first: the flag persists on the instance, so a
# re-run of this suite against the same instance would otherwise inherit the
# previous run's "on".
setflag layout_fallback false

pin_mon0
cleanup_windows
dispatch "hl.dsp.focus({ workspace = '9' })" 0.6
spawn t_a || { echo "could not spawn t_a" >&2; exit 1; }
spawn t_b || { echo "could not spawn t_b" >&2; exit 1; }
FA=$(addr_of t_a); FB=$(addr_of t_b)
[ -n "$FA" ] && [ -n "$FB" ] || { echo "could not spawn the fallback windows" >&2; exit 1; }
check_eventually "two windows on workspace 9"            "9 9"      ws2 "$FA" "$FB"

# The block is meaningless if the workspace rule ever stops applying - every
# assertion below would then exercise hy3 itself and fail confusingly. hyprctl
# eval discards expression values, so the read goes through the error channel.
ws9_layout() { ctl eval "error(tostring(hl.get_active_workspace().tiled_layout))" 2>&1 | grep -o scrolling || true; }
require "workspace 9 runs the scrolling layout" "scrolling" ws9_layout

focus "$FB"
dispatch "hl.plugin.hy3.move_focus('l')"
check "off: movefocus is a silent no-op"                 "$FB"      "$(active_addr)"

setflag layout_fallback true

dispatch "hl.plugin.hy3.move_focus('l')"
check_eventually "on: movefocus delegates natively"      "$FA"      active_addr

# What the native move does with a direction is the foreign layout's business
# - on scrolling it pulls the window into the column to its left. The
# delegation itself, not the geometry, is what is asserted: the window moved
# left of where it was.
focus "$FB"
FB_X=$(left_of "$FB")
dispatch "hl.plugin.hy3.move_window('l')"
check_eventually "on: movewindow delegates natively"     "true"     left_of_x "$FB" "$FB_X"

dispatch "hl.plugin.hy3.toggle_floating()"
check_eventually "on: togglefloating floats"             "true"     is_floating "$FB"
dispatch "hl.plugin.hy3.toggle_floating()"
check_eventually "on: togglefloating unfloats"           "false"    is_floating "$FB"

# follow=false maps to the native silent move: the window crosses, monitor
# focus stays behind.
focus "$FB"
dispatch "hl.plugin.hy3.move_to_monitor('+1')"
check_eventually "on: movetomonitor hands the window to mon1" "$M1"     where "$FB"
check_eventually "on: nofollow leaves monitor focus behind"   "$M0_NAME" focused_mon

# The regression half: with the flag on, an hy3 workspace answers the same
# dispatch with hy3's own behaviour. t_b now sits alone on mon1's hy3
# workspace, so a left focus crosses to mon0's active window - the plain hy3
# monitor hop, flag or no flag.
focus "$FB"
dispatch "hl.plugin.hy3.move_focus('l')"
check_eventually "hy3 workspaces are unaffected with the flag on" "$FA" active_addr

check "instance survived the fallbacks"                  "yes"      "$(alive)"
setflag layout_fallback false
# Leave mon0 back on workspace 1: setup pins the monitor but not the
# workspace, so a re-run against this same instance would otherwise spawn its
# windows onto the scrolling workspace and fail every hy3 block for no reason
# it names.
dispatch "hl.dsp.focus({ workspace = '1' })" 0.6

block "swapwindow"
# hy3:swapwindow / hl.plugin.hy3.swap_window: the hy3-native interface to
# swapTargets, the override that made *native* swapwindow work under hy3
# (#211, above). The native dispatcher finds its swap partner by raw geometry,
# which is not group-aware - inside a tab group the geometric neighbour can be
# a hidden tab. This one finds the neighbour with shiftFocus's traversal,
# which resolves a group to its visible window.
#
# The off-center split matters: with equal sizes "the windows exchanged boxes"
# could be read as the windows moving, while unequal sizes pin down that the
# *slot* keeps its size and only the window inside it moves. There is no hy3
# resize dispatcher, so the split is resized with hyprland's own, which
# reaches hy3's resizeTarget like any resize.
pin_mon0
cleanup_windows
spawn t_a || { echo "could not spawn t_a" >&2; exit 1; }
spawn t_b || { echo "could not spawn t_b" >&2; exit 1; }
SA=$(addr_of t_a); SB=$(addr_of t_b)
[ -n "$SA" ] && [ -n "$SB" ] || { echo "could not spawn the swap windows" >&2; exit 1; }
require "swap windows on mon0" "$M0 $M0" where2 "$SA" "$SB"

focus "$SA"
dispatch "hl.dsp.window.resize({ x = 100, y = 0, relative = true })" 0.4
GA=$(stable geom "$SA"); GB=$(stable geom "$SB")
check "the split is off-center" "true" \
	"$([ "$(width_of "$SA")" != "$(width_of "$SB")" ] && echo true || echo false)"

dispatch "hl.plugin.hy3.swap_window('r')"
check_eventually "each window owns the other's box"           "$GB $GA" swap_geoms "$SA" "$SB"
check_eventually "focus stays with the window, not the slot"  "$SA" active_addr

dispatch "hl.plugin.hy3.swap_window('l')"
check_eventually "swapping back restores both boxes"          "$GA $GB" swap_geoms "$SA" "$SB"

# At the edge of the layout there is nothing to swap with: a no-op, and in
# particular no focus hop to the adjacent monitor - movewindow's monitor
# fallthrough is opt-in and does not apply to swap. The focused monitor is the
# oracle: the hop would show up there even with nothing on mon1 to focus.
pin_mon0
cleanup_windows
spawn t_c || { echo "could not spawn t_c" >&2; exit 1; }
SC=$(addr_of t_c)
[ -n "$SC" ] || { echo "could not spawn the edge window" >&2; exit 1; }
check_eventually "single window on mon0"                      "$M0" where "$SC"

focus "$SC"
GC=$(stable geom "$SC")
dispatch "hl.plugin.hy3.swap_window('r')"
check "edge: geometry unchanged"                              "$GC" "$(geom "$SC")"
check "edge: focus does not cross to mon1"                    "$M0_NAME" "$(focused_mon)"
check "edge: the window keeps focus"                          "$SC" "$(active_addr)"

# The group-aware half, and the reason the dispatcher exists: swapping toward
# a tab group must swap with the *visible* tab, where a geometric lookup can
# pick a hidden one. h(t_w, tab(t_x, t_y, t_z)): t_w swaps with t_x and the
# hidden two never move. The setup is #332's, one window wider.
pin_mon0
cleanup_windows
for t in t_w t_x t_y t_z; do
	spawn "$t" || { echo "could not spawn $t" >&2; exit 1; }
done
TW=$(addr_of t_w); TX=$(addr_of t_x); TY=$(addr_of t_y); TZ=$(addr_of t_z)
[ -n "$TW" ] && [ -n "$TX" ] && [ -n "$TY" ] && [ -n "$TZ" ] || { echo "could not spawn the tab windows" >&2; exit 1; }
require "tab windows on mon0" "$M0 $M0 $M0 $M0" where4 "$TW" "$TX" "$TY" "$TZ"

focus "$TX"
dispatch "hl.plugin.hy3.make_group('tab')" 0.5
for a in "$TY" "$TZ"; do
	focus "$a"
	dispatch "hl.plugin.hy3.move_window('l')" 0.4
done
check_eventually "three windows tabbed together"              "same" geom_cmp "$TX" "$TZ"

# focus t_x first, so it is the tab the traversal resolves to
focus "$TX"
GTW=$(stable geom "$TW"); GTX=$(stable geom "$TX"); GTY=$(stable geom "$TY")
focus "$TW"
dispatch "hl.plugin.hy3.swap_window('r')"
check_eventually "swaps with the visible tab"                 "$GTW" geom "$TX"
check_eventually "the window takes the tab slot"              "$GTX" geom "$TW"
check "the hidden tabs never moved"                           "$GTY" "$(geom "$TY")"
check "focus stays with the invoking window"                  "$TW" "$(active_addr)"

# layout_fallback: on a foreign layout hy3 has no tree to find a neighbour in,
# so with the flag set the swap delegates to hyprland's native swapInDirection.
# Workspace 9 is pinned to scrolling, as in the layout_fallback block above.
setflag layout_fallback false
pin_mon0
cleanup_windows
dispatch "hl.dsp.focus({ workspace = '9' })" 0.6
spawn t_a || { echo "could not spawn t_a" >&2; exit 1; }
spawn t_b || { echo "could not spawn t_b" >&2; exit 1; }
SA=$(addr_of t_a); SB=$(addr_of t_b)
[ -n "$SA" ] && [ -n "$SB" ] || { echo "could not spawn the fallback swap windows" >&2; exit 1; }
check_eventually "two windows on workspace 9"                 "9 9" ws2 "$SA" "$SB"
require "workspace 9 runs the scrolling layout" "scrolling" ws9_layout

focus "$SB"
GA=$(stable geom "$SA"); GB=$(stable geom "$SB")
dispatch "hl.plugin.hy3.swap_window('l')"
check "off: swap_window is a silent no-op"                    "$GA $GB" "$(swap_geoms "$SA" "$SB")"

setflag layout_fallback true
focus "$SB"
dispatch "hl.plugin.hy3.swap_window('l')"
check_eventually "on: swap_window delegates natively"         "$GB $GA" swap_geoms "$SA" "$SB"

check "instance survived the swaps"                           "yes" "$(alive)"
setflag layout_fallback false
# Same leave-it-clean discipline as the layout_fallback block: a re-run spawns
# its first windows onto whatever workspace mon0 is left on.
dispatch "hl.dsp.focus({ workspace = '1' })" 0.6

block "teardown"
cleanup_windows
check "instance survived the run"              "yes" "$(alive)"

echo
if [ "$skip" -gt 0 ]; then
	printf 'passed %d, failed %d, skipped %d\n' "$pass" "$fail" "$skip"
else
	printf 'passed %d, failed %d\n' "$pass" "$fail"
fi
# A skipped block is an *untested* one, so it is not a pass. The distinction
# this whole mechanism exists to draw is between "the code is broken" and "the
# harness never set the block up" - both are a red run, but only one of them is
# about the plugin.
[ "$fail" -eq 0 ] && [ "$skip" -eq 0 ]

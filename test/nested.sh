#!/usr/bin/env bash
# Run a throwaway Hyprland instance with this repo's hy3 build loaded, so the
# plugin can be exercised without touching the real session.
#
#   test/nested.sh start [monitors]   start the instance (default 2 monitors)
#   test/nested.sh sig                print its instance signature
#   test/nested.sh ctl <args...>      run hyprctl against it
#   test/nested.sh stop               kill it
#
# Each monitor is a nested Wayland window on the host compositor. They are laid
# out left to right at whatever size the host gives them - see the note in
# start() about why the mode is not forced.
#
# Headless outputs are deliberately not used: `hyprctl output create headless`
# produces an output that reports 0x0 and never picks up a mode, so windows sent
# there end up with negative sizes.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
PLUGIN="$REPO/build/libhy3.so"
CONFIG="$REPO/test/nested.lua"
RUNDIR="${TMPDIR:-/tmp}/hy3-nested"
SIGFILE="$RUNDIR/signature"
PIDFILE="$RUNDIR/pid"
LOGFILE="$RUNDIR/hyprland.log"

# instance signatures of every Hyprland already running, so the new one can be
# identified by elimination
existing_sigs() { ls -1 "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | sort; }

# Every hyprctl call must be aimed at our instance and no other. An empty
# signature makes hyprctl error rather than pick an instance, but refuse it here
# too so the failure names the reason instead of looking like a dead socket.
ctl() {
	local sig
	sig=$(cat "$SIGFILE" 2>/dev/null)
	[ -n "$sig" ] || {
		echo "no nested instance signature - refusing to run hyprctl" >&2
		return 1
	}
	HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl "$@"
}

# Our nested instance is identified by the config path in its argv, never by a
# pid alone. A stale pid file, or a pid recycled onto the host compositor, must
# never be signalled - that is a logout.
is_nested() {
	local pid=${1:-}
	[ -n "$pid" ] || return 1
	# The name check is not redundant: any shell running a command that merely
	# mentions the config path has it in its own argv, and matching on the path
	# alone would make this true for that shell.
	[ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "Hyprland" ] || return 1
	tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -qF -- "$CONFIG"
}

# Every Hyprland that is ours, and no others - the host compositor is named the
# same and is only told apart by its config.
nested_pids() {
	local pid
	for pid in $(pgrep -x Hyprland 2>/dev/null); do
		is_nested "$pid" && echo "$pid"
	done
}

# The host compositor, i.e. the live instance that is not ours.
host_ctl() {
	local ours sig
	ours=$(cat "$SIGFILE" 2>/dev/null)
	for sig in $(existing_sigs); do
		[ "$sig" = "$ours" ] && continue
		HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl version >/dev/null 2>&1 || continue
		HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl "$@"
		return
	done
	return 1
}

# Float our nested windows on the host. Tiled, they are sized by the host's
# layout, which makes the outputs an unpredictable size and leaves the monitors
# misplaced relative to the positions pinned in nested.lua. Floating snaps them
# to aquamarine's default 1280x720, which those positions assume.
float_on_host() {
	local pid addr
	pid=$(cat "$PIDFILE" 2>/dev/null) || return 0
	for addr in $(host_ctl clients -j 2>/dev/null |
		jq -r --argjson p "${pid:-0}" '.[]|select(.pid==$p and .floating==false)|.address'); do
		host_ctl dispatch "hl.dsp.window.float({ window = 'address:$addr' })" >/dev/null 2>&1
	done
	sleep 0.8
}

start() {
	local want_monitors=${1:-2}

	[ -f "$PLUGIN" ] || { echo "no plugin build at $PLUGIN - run cmake --build build" >&2; exit 1; }

	mkdir -p "$RUNDIR"
	local before
	before=$(existing_sigs)

	# a stale signature in the environment makes the child talk to the parent.
	#
	# setsid puts the instance in its own session and process group. Without it
	# the compositor is a plain background job of whatever ran this script, and
	# anything tearing that down - a closed terminal, an editor or agent reaping
	# its children, a process-group signal - can take it along. Detached, it also
	# cannot be swept up by a cleanup that matches on the name "Hyprland", which
	# would otherwise be indistinguishable from the host compositor.
	setsid env -u HYPRLAND_INSTANCE_SIGNATURE \
		HYPRLAND_NO_SD_NOTIFY=1 \
		Hyprland -c "$CONFIG" >"$LOGFILE" 2>&1 &

	# not $!: that is setsid, which forks rather than execs when it is already a
	# process group leader. Find the compositor by its config path instead.
	local pid="" j=0
	while [ "$j" -lt 40 ]; do
		pid=$(nested_pids | head -1)
		[ -n "$pid" ] && break
		j=$((j + 1))
		sleep 0.25
	done
	[ -n "$pid" ] || { echo "nested instance did not start" >&2; exit 1; }
	echo "$pid" >"$PIDFILE"

	# wait for the new instance to register its socket
	local sig="" i=0
	while [ "$i" -lt 60 ]; do
		sig=$(comm -13 <(echo "$before") <(existing_sigs) | head -1)
		[ -n "$sig" ] && [ -S "$XDG_RUNTIME_DIR/hypr/$sig/.socket.sock" ] && break
		sig=""
		i=$((i + 1))
		sleep 0.25
	done

	if [ -z "$sig" ]; then
		echo "instance did not come up; tail of $LOGFILE:" >&2
		tail -20 "$LOGFILE" >&2
		is_nested "$pid" && kill "$pid" 2>/dev/null
		exit 1
	fi
	echo "$sig" >"$SIGFILE"

	# wait for it to answer
	i=0
	while [ "$i" -lt 40 ]; do
		ctl version >/dev/null 2>&1 && break
		i=$((i + 1))
		sleep 0.25
	done

	ctl plugin load "$PLUGIN" >/dev/null || { echo "plugin load failed" >&2; exit 1; }

	float_on_host

	# extra outputs, for cross-monitor tests
	local have
	have=$(ctl monitors -j | jq 'length')
	while [ "$have" -lt "$want_monitors" ]; do
		ctl output create wayland >/dev/null
		sleep 1
		float_on_host
		local now
		now=$(ctl monitors -j | jq 'length')
		[ "$now" -gt "$have" ] || { echo "could not create output $((have + 1))" >&2; break; }
		have=$now
	done

	# Lay the monitors out left to right, edge to edge.
	#
	# Do NOT force a mode: the host compositor sizes these nested windows, and
	# the output rejects a mode it cannot honour ("pending state rejected:
	# invalid mode" in the instance log) while silently keeping its real size.
	# Positioning by a *requested* width then overlaps the monitors, which
	# quietly breaks every cross-monitor test. Measure, then place.
	# Monitor positions are pinned in nested.lua - they are only honoured when
	# present at output-creation time. All that is left is to confirm the layout
	# is sane rather than let tests fail obscurely later.
	sleep 1
	# Must be edge to edge: an overlap corrupts geometry, and a gap breaks
	# Hyprland's inDirection monitor lookup.
	local bad
	bad=$(ctl monitors -j | jq '[.[]|{x:.x,r:(.x+.width)}] | sort_by(.x)
	    | [range(0; length-1) as $i | select(.[$i].r != .[$i+1].x)] | length')
	if [ "$bad" != "0" ]; then
		echo "monitors are not edge to edge:" >&2
		ctl monitors -j | jq -r '.[]|"  \(.name) at=(\(.x),\(.y)) \(.width)x\(.height)"' >&2
		exit 1
	fi

	# plugin settings have to be applied after load, see nested.lua
	ctl eval "hl.config({
	    general = { layout = 'hy3' },
	    plugin = { hy3 = {
	        special_focus_trap = true,
	        movewindow_monitor_fallthrough = true,
	    } },
	})" >/dev/null

	echo "signature: $sig"
	echo "pid:       $(cat "$PIDFILE")"
	echo "log:       $LOGFILE"
	ctl monitors -j | jq -r '.[] | "monitor \(.id) \(.name) at=(\(.x),\(.y)) \(.width)x\(.height)"'
}

stop() {
	# `dispatch exit` no longer parses - hyprctl evaluates its argument as lua
	# under a lua config, which nested.lua is. Ask nicely first anyway; the kill
	# below is the fallback, not the plan.
	local running=0
	[ -n "$(nested_pids)" ] && running=1

	if [ -s "$SIGFILE" ]; then
		ctl dispatch "hl.dsp.exit()" >/dev/null 2>&1
		sleep 1
	fi

	# Only ever signal a pid confirmed to be ours. Sweep by config path rather
	# than trusting the pid file, so a run whose file was lost still gets cleaned
	# up and a recycled pid still gets left alone.
	local pid
	for pid in $(cat "$PIDFILE" 2>/dev/null) $(nested_pids); do
		is_nested "$pid" && kill "$pid" 2>/dev/null
	done

	rm -f "$SIGFILE" "$PIDFILE"

	if [ -n "$(nested_pids)" ]; then
		echo "warning: a nested instance is still running: $(nested_pids | tr '\n' ' ')" >&2
		return 1
	fi
	[ "$running" = 1 ] && echo "stopped" || echo "nothing of ours was running"
}

case "${1:-}" in
start) shift; start "$@" ;;
sig) cat "$SIGFILE" ;;
ctl) shift; ctl "$@" ;;
stop) stop ;;
*) sed -n '2,12p' "$0" >&2; exit 1 ;;
esac

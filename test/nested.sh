#!/usr/bin/env bash
# Run a throwaway Hyprland instance with this repo's hy3 build loaded, so the
# plugin can be exercised without touching the real session.
#
#   test/nested.sh start [monitors]   start the instance (default 2 monitors)
#   test/nested.sh sig                print its instance signature
#   test/nested.sh ctl <args...>      run hyprctl against it
#   test/nested.sh stop               kill it
#
# Each monitor is a nested Wayland window on the host compositor, sized
# MON_W x MON_H and laid out left to right.
#
# Headless outputs are deliberately not used: `hyprctl output create headless`
# produces an output that reports 0x0 and never picks up a mode, so windows sent
# there end up with negative sizes.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
PLUGIN="$REPO/build/libhy3.so"
CONFIG="$REPO/test/nested.lua"
RUNDIR="${TMPDIR:-/tmp}/hy3-nested"
MON_W=${MON_W:-1280}
MON_H=${MON_H:-800}
SIGFILE="$RUNDIR/signature"
PIDFILE="$RUNDIR/pid"
LOGFILE="$RUNDIR/hyprland.log"

# instance signatures of every Hyprland already running, so the new one can be
# identified by elimination
existing_sigs() { ls -1 "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | sort; }

ctl() { HYPRLAND_INSTANCE_SIGNATURE=$(cat "$SIGFILE") hyprctl "$@"; }

start() {
	local want_monitors=${1:-2}

	[ -f "$PLUGIN" ] || { echo "no plugin build at $PLUGIN - run cmake --build build" >&2; exit 1; }

	mkdir -p "$RUNDIR"
	local before
	before=$(existing_sigs)

	# a stale signature in the environment makes the child talk to the parent
	env -u HYPRLAND_INSTANCE_SIGNATURE \
		HYPRLAND_NO_SD_NOTIFY=1 \
		Hyprland -c "$CONFIG" >"$LOGFILE" 2>&1 &
	echo $! >"$PIDFILE"

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
		kill "$(cat "$PIDFILE")" 2>/dev/null
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

	# extra outputs, for cross-monitor tests
	local have
	have=$(ctl monitors -j | jq 'length')
	while [ "$have" -lt "$want_monitors" ]; do
		ctl output create wayland >/dev/null
		sleep 1
		local now
		now=$(ctl monitors -j | jq 'length')
		[ "$now" -gt "$have" ] || { echo "could not create output $((have + 1))" >&2; break; }
		have=$now
	done

	# fixed, equal modes laid out left to right, so geometry assertions in tests
	# do not depend on how the host happened to size the nested windows
	local i=0
	for name in $(ctl monitors -j | jq -r '.[].name'); do
		ctl eval "hl.monitor({
		    output = '$name',
		    mode = '${MON_W}x${MON_H}@60',
		    position = '$((i * MON_W))x0',
		    scale = 1,
		})" >/dev/null
		i=$((i + 1))
	done
	sleep 1

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
	[ -f "$SIGFILE" ] && ctl dispatch exit >/dev/null 2>&1
	sleep 1
	[ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
	rm -f "$SIGFILE" "$PIDFILE"
	echo "stopped"
}

case "${1:-}" in
start) shift; start "$@" ;;
sig) cat "$SIGFILE" ;;
ctl) shift; ctl "$@" ;;
stop) stop ;;
*) sed -n '2,12p' "$0" >&2; exit 1 ;;
esac

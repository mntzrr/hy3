#!/usr/bin/env bash
# Run a throwaway Hyprland instance with this repo's hy3 build loaded, so the
# plugin can be exercised without touching the real session.
#
#   test/nested.sh start [monitors]   start the instance (default 2 monitors)
#   test/nested.sh sig                print its instance signature
#   test/nested.sh ctl <args...>      run hyprctl against it
#   test/nested.sh stop               kill it
#   test/nested.sh rundir             print its per-checkout runtime directory
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
# Per-checkout: is_nested() identifies instances by config path, so a start()
# from a second checkout or worktree (the documented baseline workflow) sees
# nothing running and would otherwise clobber the first instance's state files
# and live socket dir while it keeps running.
#
# Keep it short: the IPC socket lives at $RUNDIR/xdg/hypr/<signature>/
# .socket2.sock, the signature alone is ~62 chars, and sun_path is 108 - the
# old path left single digits of headroom, so there is no room for a longer
# prefix here.
RUNDIR="${TMPDIR:-/tmp}/hy3n-$(printf '%s' "$REPO" | md5sum | cut -c1-8)"
SIGFILE="$RUNDIR/signature"
PIDFILE="$RUNDIR/pid"
LOGFILE="$RUNDIR/hyprland.log"

# The host compositor's signature, inherited from the session this script was
# started from. Nothing here may ever resolve to it: every command the harness
# drives - `hl.dsp.exit()` most of all - would land on the user's real session.
# Captured now, before start() strips it from the child's environment.
HOST_SIG=${HYPRLAND_INSTANCE_SIGNATURE:-}
# Likewise the host's runtime dir, captured before the child gets its own.
# host_ctl() and the wayland socket the nested backend connects to both live
# here, and $XDG_RUNTIME_DIR stops meaning "the host's" the moment start() runs.
HOST_XDG=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

# A private XDG_RUNTIME_DIR for the nested instance. See start() for why.
NESTED_XDG="$RUNDIR/xdg"

# instance signatures of every Hyprland in the NESTED runtime dir, so the new
# one can be identified by elimination. With the private dir this is normally
# empty before a run and one entry after - the host is not in here at all.
existing_sigs() { ls -1 "$NESTED_XDG/hypr" 2>/dev/null | sort; }

# The signature to drive, or nothing. Everything downstream is aimed at whatever
# this returns - including `hl.dsp.exit()` - so it is verified rather than
# trusted, and four things must hold:
#
#   - both state files exist. start() writes them together for this reason: a
#     fresh pid paired with a previous run's signature is the one inconsistency
#     the checks below cannot see.
#   - the recorded pid still passes is_nested(), i.e. it is a Hyprland running
#     *our* config and not something that inherited its pid.
#   - the signature still has a live socket.
#   - the signature is not the host's. This is the decisive one: the set
#     difference start() uses to discover the new signature is a heuristic, and
#     the cost of it picking wrong once is the user's session.
nested_sig() {
	local sig pid
	sig=$(cat "$SIGFILE" 2>/dev/null)
	pid=$(cat "$PIDFILE" 2>/dev/null)
	[ -n "$sig" ] && [ -n "$pid" ] || return 1

	if [ -n "$HOST_SIG" ] && [ "$sig" = "$HOST_SIG" ]; then
		echo "recorded signature is the host compositor's - refusing" >&2
		return 1
	fi

	is_nested "$pid" || return 1
	[ -S "$NESTED_XDG/hypr/$sig/.socket.sock" ] || return 1

	printf '%s\n' "$sig"
}

# Every hyprctl call must be aimed at our instance and no other. An empty
# signature makes hyprctl error rather than pick an instance, but refuse it here
# too so the failure names the reason instead of looking like a dead socket.
ctl() {
	local sig
	sig=$(nested_sig) || {
		echo "no verified nested instance - refusing to run hyprctl" >&2
		return 1
	}
	XDG_RUNTIME_DIR="$NESTED_XDG" HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl "$@"
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
# Sorted, because start() takes a set difference of two calls to this with comm,
# which requires it. pgrep's order is its own business and not one to rely on.
nested_pids() {
	local pid
	for pid in $(pgrep -x Hyprland 2>/dev/null); do
		is_nested "$pid" && echo "$pid"
	done | sort
}

# Wait until nothing of ours is left. kill() only *sends* a signal, and
# Hyprland takes a moment to tear its outputs down, so checking immediately
# after signalling reports a failure that is really just impatience.
wait_gone() { # wait_gone <timeout_s>
	local deadline=$((SECONDS + ${1:-5}))
	while [ -n "$(nested_pids)" ]; do
		[ "$SECONDS" -ge "$deadline" ] && return 1
		sleep 0.2
	done
}

# The host compositor, i.e. the live instance that is not ours. This is the only
# sanctioned path to the user's real session, and it exists for exactly one
# thing: floating our own nested windows so the outputs take a predictable size.
#
# It must never carry a lifecycle command. An exit dispatched here is not a
# failed test, it is the user losing their session and everything unsaved in it,
# so the verbs that could do that are refused outright rather than guarded by
# the caller remembering not to.
host_ctl() {
	case "$*" in
	*exit*|*kill*|*logout*)
		echo "refusing to send '$*' to the host compositor" >&2
		return 1
		;;
	esac

	# the HOST's runtime dir, deliberately: existing_sigs() looks in the
	# nested one, which by construction never contains the host
	local ours sig
	ours=$(cat "$SIGFILE" 2>/dev/null)
	for sig in $(ls -1 "$HOST_XDG/hypr" 2>/dev/null | sort); do
		[ "$sig" = "$ours" ] && continue
		XDG_RUNTIME_DIR="$HOST_XDG" HYPRLAND_INSTANCE_SIGNATURE=$sig \
			hyprctl version >/dev/null 2>&1 || continue
		XDG_RUNTIME_DIR="$HOST_XDG" HYPRLAND_INSTANCE_SIGNATURE=$sig hyprctl "$@"
		return
	done
	return 1
}

# Float our nested windows on the host, then pin their size. Tiled, they are
# sized by the host's layout, which makes the outputs an unpredictable size
# and leaves the monitors misplaced relative to the positions pinned in
# nested.lua. Floating used to snap them to aquamarine's default 1280x720;
# on current hyprland a floated window keeps its tiled size, so the 1280x720
# those positions assume has to be set explicitly.
float_on_host() {
	local pid addr
	pid=$(cat "$PIDFILE" 2>/dev/null) || return 0
	for addr in $(host_ctl clients -j 2>/dev/null |
		jq -r --argjson p "${pid:-0}" '.[]|select(.pid==$p and .floating==false)|.address'); do
		host_ctl dispatch "hl.dsp.window.float({ window = 'address:$addr' })" >/dev/null 2>&1
	done
	for addr in $(host_ctl clients -j 2>/dev/null |
		jq -r --argjson p "${pid:-0}" '.[]|select(.pid==$p and .floating==true
			and (.size[0]!=1280 or .size[1]!=720))|.address'); do
		host_ctl dispatch "hl.dsp.window.resize({ x = 1280, y = 720, window = 'address:$addr' })" >/dev/null 2>&1
	done
	sleep 0.8
}

start() {
	local want_monitors=${1:-2}

	[ -f "$PLUGIN" ] || { echo "no plugin build at $PLUGIN - run cmake --build build" >&2; exit 1; }

	# Refuse to start over a live instance. Both halves of the pid/signature
	# discovery below go wrong at once when one is already up, and in opposite
	# directions: nested_pids matches the OLD compositor on the first poll,
	# before the new one has exec'd, while `rm -rf "$NESTED_XDG"` unlinks the
	# old instance's hypr/<sig>/ so the set difference yields the NEW signature.
	# The pair written at the end of start() is then exactly the half-valid one
	# its comment claims can never happen, and nested_sig() cannot see it - the
	# old pid passes is_nested and the new signature has a live socket.
	#
	# Reachable in practice: stop() returns 1 with an instance still alive,
	# having already removed the state files, and the aborts below leave one up
	# too. Everything downstream then aims at the wrong process - float_on_host
	# floats nothing, the error paths kill the old compositor and orphan the
	# new one, and smoke.sh's alive() polls a process that is not under test.
	if [ -n "$(nested_pids)" ]; then
		echo "a nested instance is already running: $(nested_pids | tr '\n' ' ')" >&2
		echo "run '$0 stop' first" >&2
		exit 1
	fi

	mkdir -p "$RUNDIR"
	# Never inherit state from a previous run: a leftover pair that a crashed
	# start() left half-written is the one thing nested_sig() cannot detect.
	rm -f "$SIGFILE" "$PIDFILE"

	# A THIRD thing that reaches past the nested instance, alongside libseat and
	# the DRM backend below: the session's systemd/dbus environment.
	#
	# Hyprland exports WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE to the
	# systemd user manager at startup. It does this ITSELF - nested.lua has no
	# autostart and no exec-once, and it happens anyway - so there is no config
	# line to remove. Every nested run therefore overwrote the real session's
	# values with the throwaway instance's:
	#
	#   WAYLAND_DISPLAY=wayland-1  ->  wayland-2
	#
	# Nothing running notices, because a running service already holds its own
	# display. What breaks is the NEXT restart of any user service: it inherits
	# a display that no longer exists and dies with "Failed to open display",
	# then keeps dying, because nothing puts the value back. Observed as a
	# desktop shell stuck in a restart loop 105 attempts deep, an hour after a
	# test run nobody connected to it.
	#
	# Two things are needed and neither is sufficient alone: a private
	# XDG_RUNTIME_DIR, and unsetting DBUS_SESSION_BUS_ADDRESS. The address is
	# set explicitly in the environment (unix:path=/run/user/<uid>/bus), so
	# moving the runtime dir on its own leaves dbus-update-activation-environment
	# a perfectly good route to the session bus.
	rm -rf "$NESTED_XDG"
	mkdir -p "$NESTED_XDG"
	chmod 700 "$NESTED_XDG"

	# The wayland backend connects to the HOST compositor through
	# $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY, so moving the runtime dir would leave
	# it with nowhere to connect - it needs a route to the host even while it
	# is cut off from the host's bus. Link the socket in; the .lock beside it
	# belongs to the server and is deliberately not copied.
	local host_wl=${WAYLAND_DISPLAY:-}
	if [ -n "$host_wl" ]; then
		case "$host_wl" in
		/*) ln -sfn "$host_wl" "$NESTED_XDG/$(basename "$host_wl")" ;;
		*) ln -sfn "$HOST_XDG/$host_wl" "$NESTED_XDG/$host_wl" ;;
		esac
	fi

	local before pids_before
	before=$(existing_sigs)
	# Same set-difference treatment as the signature, for the same reason: an
	# absolute answer ("the first nested Hyprland") is only right when there is
	# nothing else to confuse it with, and the check above is what makes that
	# true rather than something to rely on twice.
	pids_before=$(nested_pids)

	# a stale signature in the environment makes the child talk to the parent.
	#
	# setsid puts the instance in its own session and process group. Without it
	# the compositor is a plain background job of whatever ran this script, and
	# anything tearing that down - a closed terminal, an editor or agent reaping
	# its children, a process-group signal - can take it along. Detached, it also
	# cannot be swept up by a cleanup that matches on the name "Hyprland", which
	# would otherwise be indistinguishable from the host compositor.
	# LIBSEAT_BACKEND=noop is not a tidiness flag, it is the difference between
	# this harness being safe and it logging the user out.
	#
	# Hyprland opens a seat through libseat even under the wayland backend, where
	# it needs nothing from one. With no seatd socket, libseat falls back to
	# logind - and the session it opens is whatever XDG_SESSION_ID says, which is
	# inherited from whatever ran this script. Run from a terminal multiplexer
	# that outlived its login, that is an old session which is still on seat0,
	# the same seat the live graphical session is on. The nested instance then
	# tries to *activate* it, which would deactivate the real one:
	#
	#   [libseat] Seat opened with backend 'logind'
	#   Session is not active, waiting for 5s
	#   Session timeout reached
	#   Session could not be activated in time
	#
	# It gives up on activating but holds the handle for the whole run, and
	# logind re-evaluating seat0 around it is enough for the session manager to
	# tear the real session down - a logout with no crash, no core, and nothing
	# in the compositor's log, because the compositor is the victim rather than
	# the cause. Observed four times before it was tracked down.
	#
	# The noop backend gives libseat nothing to open. Nothing here wants a seat:
	# the outputs are wayland surfaces on the host and the input comes from it
	# too. Keep this even if seatd is installed later - the point is not which
	# backend is chosen but that no seat is taken at all.
	#
	# AQ_DRM_DEVICES must accompany it, and removing either one is unsafe.
	# Aquamarine runs backends *together*, not as alternatives: it adds DRM
	# whenever it can and the wayland backend on top. What used to stop it was
	# the very bug above - the seat it opened was never activated, so DRM was
	# unusable and only the nested outputs remained. Take the seat away and DRM
	# succeeds instead, because the device nodes are ACL'd to the logged-in user:
	# the harness comes up owning HDMI-A-1 and eDP-1, the real screens. Pointing
	# the device list at a node that cannot be a GPU leaves the DRM backend with
	# nothing to enumerate, so only the wayland one is left.
	setsid env -u HYPRLAND_INSTANCE_SIGNATURE \
		-u DBUS_SESSION_BUS_ADDRESS \
		XDG_RUNTIME_DIR="$NESTED_XDG" \
		LIBSEAT_BACKEND=noop \
		AQ_DRM_DEVICES=/dev/null \
		HYPRLAND_NO_SD_NOTIFY=1 \
		Hyprland -c "$CONFIG" >"$LOGFILE" 2>&1 &

	# not $!: that is setsid, which forks rather than execs when it is already a
	# process group leader. Find the compositor by its config path instead.
	local pid="" j=0
	while [ "$j" -lt 40 ]; do
		pid=$(comm -13 <(echo "$pids_before") <(nested_pids) | head -1)
		[ -n "$pid" ] && break
		j=$((j + 1))
		sleep 0.25
	done
	[ -n "$pid" ] || { echo "nested instance did not start" >&2; exit 1; }

	# wait for the new instance to register its socket
	local sig="" i=0
	while [ "$i" -lt 60 ]; do
		sig=$(comm -13 <(echo "$before") <(existing_sigs) | head -1)
		[ -n "$sig" ] && [ -S "$NESTED_XDG/hypr/$sig/.socket.sock" ] && break
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

	# The set difference above is a heuristic - it assumes the only signature to
	# appear while we waited is ours. Refuse the one wrong answer that matters
	# rather than find out later, when the command being aimed is an exit.
	if [ -n "$HOST_SIG" ] && [ "$sig" = "$HOST_SIG" ]; then
		echo "discovered signature is the host compositor's - refusing to continue" >&2
		is_nested "$pid" && kill "$pid" 2>/dev/null
		exit 1
	fi

	# Written together, so the pair is never half-valid. nested_sig() requires
	# both, and a fresh pid next to a stale signature would pass every other
	# check it makes.
	printf '%s\n' "$pid" >"$PIDFILE"
	printf '%s\n' "$sig" >"$SIGFILE"

	# wait for it to answer
	i=0
	while [ "$i" -lt 40 ]; do
		ctl version >/dev/null 2>&1 && break
		i=$((i + 1))
		sleep 0.25
	done

	# Every output must be a nested wayland surface. A physical one here means
	# the DRM backend came up despite the env above, and the harness is now
	# driving the user's actual screens - stop before anything is dispatched at
	# it. The env vars are the fix; this is the check that they worked, because
	# the failure is silent otherwise: the instance starts, the tests pass, and
	# the only symptom is the session dying later for no visible reason.
	local physical
	physical=$(ctl monitors -j | jq -r '.[]|select(.name|startswith("WAYLAND-")|not)|.name' | tr '\n' ' ')
	if [ -n "${physical% }" ]; then
		echo "refusing to continue: nested instance opened physical output(s): ${physical% }" >&2
		echo "the DRM backend came up - LIBSEAT_BACKEND/AQ_DRM_DEVICES are not taking effect" >&2
		is_nested "$pid" && kill "$pid" 2>/dev/null
		rm -f "$SIGFILE" "$PIDFILE"
		exit 1
	fi

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
	        movewindow_floating = true,
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

	# Ask nicely first - but only if the recorded instance verifies as ours.
	# When it does not, no exit is dispatched at all and the is_nested()-guarded
	# kill below becomes the only way this function can end anything.
	if nested_sig >/dev/null 2>&1; then
		ctl dispatch "hl.dsp.exit()" >/dev/null 2>&1
		wait_gone 3
	fi

	# Only ever signal a pid confirmed to be ours. Sweep by config path rather
	# than trusting the pid file, so a run whose file was lost still gets cleaned
	# up and a recycled pid still gets left alone.
	local pid
	for pid in $(cat "$PIDFILE" 2>/dev/null) $(nested_pids); do
		is_nested "$pid" && kill "$pid" 2>/dev/null
	done
	wait_gone 5

	# Still there: escalate, but re-check is_nested() first - the sweep above
	# may have freed the pid, and nothing here may ever resolve to the host.
	for pid in $(nested_pids); do
		is_nested "$pid" && kill -9 "$pid" 2>/dev/null
	done
	wait_gone 5

	rm -f "$SIGFILE" "$PIDFILE"

	if [ -n "$(nested_pids)" ]; then
		echo "warning: a nested instance is still running: $(nested_pids | tr '\n' ' ')" >&2
		return 1
	fi
	[ "$running" = 1 ] && echo "stopped" || echo "nothing of ours was running"
}

case "${1:-}" in
start) shift; start "$@" ;;
sig) nested_sig ;;
ctl) shift; ctl "$@" ;;
stop) stop ;;
rundir) echo "$RUNDIR" ;;
*) sed -n '2,12p' "$0" >&2; exit 1 ;;
esac

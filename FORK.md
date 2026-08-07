# Fork notes

This is a fork of [outfoxxed/hy3](https://github.com/outfoxxed/hy3). It tracks upstream and
adds a handful of features that previously had to be emulated from the Hyprland config with
Lua wrappers and `hyprctl`/`jq` shell scripts. There is no intent to upstream them.

Everything below is **off by default** — with no extra configuration this fork behaves exactly
like upstream. New behaviour is gated behind config flags; new dispatchers are purely additive.

## Staying in sync

```sh
git fetch upstream
git rebase upstream/master
```

Fork commits are prefixed `fork:`. To minimise conflicts, changes follow these rules:

- new `CONF(...)` entries live in a `// fork additions` block at the end of the list in
  `src/main.cpp`, never interleaved with upstream's
- new dispatchers and Lua functions are appended at the end of `registerDispatchers()` /
  `registerLuaDispatchers()`, and their implementations sit in a marked block just above
  those functions in `src/dispatchers.cpp`
- new layout logic lives in its own functions; edits inside upstream functions are limited to
  a short guard clause
- extra parameters added to upstream signatures are trailing and defaulted, so upstream call
  sites are untouched

After a rebase, the checks worth re-running are listed under "Verifying" below.

## Features

### 1. `plugin:hy3:special_focus_trap` (bool, default false)

With this set, directional focus never leaves a special (scratchpad) workspace for another
monitor — at the edge of the scratchpad's layout, focus simply stays put.

Upstream falls through to `Hy3Layout::focusMonitor()` whenever directional focus runs off the
edge of the tree, which pulls focus off a scratchpad and onto a neighbouring monitor.

- `src/Hy3Layout.cpp` — `focusedOnSpecialWorkspace()` helper plus a guard at the top of
  `Hy3Layout::focusMonitor()`. Guarding the single sink covers all three upstream entry
  points (`shiftFocus` with no focused node, `shiftOrGetFocus` at the tree root, and
  `moveFocus`'s fullscreen shortcut).
- The check is keyed off the **focused window's** workspace, not the layout's: a scratchpad
  that is merely visible must not stop focus from leaving the monitor.

### 2. `hy3:movetomonitor` / `hy3.move_to_monitor`

Moves the active node into another monitor's active workspace. The node is moved through
`Hy3Layout::moveNodeToWorkspace`, so a raised group arrives intact in the destination hy3
tree — Hyprland's own monitor move can't do that. `follow` is honoured: without it, focus is
left where the user put it.

- `src/Hy3Layout.cpp` — `monitorInDirection()`, `monitorFromSelector()`, `moveToMonitor()`,
  `moveNodeToMonitor()`, `refocusMonitor()`.
- Upstream's `shiftMonitor()` was dead code (its call sites were removed in `827dae1`) and
  focused the destination monitor unconditionally, so `follow = false` did not work. It is now
  a thin wrapper over `moveToMonitor()`.
- `follow = false` needs more than skipping the focus call: the moved node keeps keyboard
  focus even once it is on another screen, leaving the focused monitor and the focused window
  on different displays. `refocusMonitor()` hands focus back to the origin monitor. It asks
  **hy3** for that workspace's focused node rather than `getLastFocusedWindow()`, which still
  names the node that was just moved away and so chases it onto the other screen.
- Argument handling: `l`/`r`/`u`/`d` map to `monitorInDirection()`; `+n`/`-n` are resolved by
  cycling `State::monitorState()->monitors()` with wraparound, because `CMonitorQuery::selector`
  does **not** understand relative offsets (it silently matches nothing); everything else
  (name, `desc:…`, id) is passed to `CMonitorQuery::selector`.

### 3. `plugin:hy3:movewindow_monitor_fallthrough` (bool, default false) + `hy3:movewindow … , monitor`

At the edge of the layout, `hy3:movewindow` hands the node to the adjacent monitor instead of
wrapping it into a new group. The config flag enables it globally; the `monitor` argument
(Lua: `{ monitor = true }`) enables it for a single invocation.

- `src/Hy3Layout.cpp` — a `monitor_fallthrough` flag threaded through
  `shiftWindow` → `shiftNode` → `shiftOrGetFocus`, acted on in the `break_parent->is_root()`
  branch. `shiftMonitor` extracts the node, so that branch returns immediately.
- `Hy3Layout::shiftWindow` ORs the argument with the config flag.

### 4. `hy3:togglefloating` / `hy3.toggle_floating`

Toggles the focused window's floating state, except on a special workspace, where the window
is unmounted onto a regular workspace with focus following it.

- `src/Hy3Layout.cpp` — `Hy3Layout::toggleFloating()`.
- The unmount target defaults to the workspace visible underneath the scratchpad, resolved
  explicitly from `monitor->m_activeWorkspace` (a monitor's active workspace is never the
  special one) rather than relying on a relative `e+0` selector.
- Like feature 1, the decision is keyed off the focused window's workspace so a visible but
  unfocused scratchpad doesn't hijack the action.

## Verifying

Build against the Hyprland release the headers belong to:

```sh
cmake -DCMAKE_BUILD_TYPE=Release -B build && cmake --build build
```

Then run the suite against a throwaway instance — **not** your session. Unloading a layout
plugin that owns every window is disruptive at best, and has crashed the compositor here:

```sh
test/nested.sh start 2   # nested Hyprland, this build loaded, two 1280x800 monitors
test/smoke.sh            # 31 assertions covering everything below
test/nested.sh stop
```

`test/nested.sh ctl <args>` runs `hyprctl` against the nested instance for poking at it by
hand. Two things the harness had to work around: `hyprctl output create headless` produces an
output that reports `0x0` and never takes a mode (windows sent there get negative sizes), so
extra monitors are nested Wayland outputs; and hy3's own `hy3_log` output does not reach the
instance log, so behaviour over `hyprctl` is the only practical oracle.

Note that on Hyprland 0.56 a config load resets plugin config values to the defaults the
plugin registered, *after* the config file has been parsed — so `plugin:hy3:*` settings made
from a Lua config file never survive, guarded or not. Apply them with `hyprctl eval` once the
plugin is loaded:

```sh
hyprctl eval "hl.config({ plugin = { hy3 = { special_focus_trap = true } } })"
```

Two traps that make manual checks lie, both of which `test/smoke.sh` now guards against:

- **Check the focused monitor, not the active window.** A scratchpad follows whichever monitor
  gains focus, so a window on it stays "active" whether or not focus really left the monitor.
- **Give the escape somewhere to land.** `focusMonitor` only changes the active window if the
  target monitor has one, and there must actually be a monitor in the direction being tested —
  a scratchpad sitting on the edge-most monitor makes `special_focus_trap` look like it works
  when nothing was ever attempted.

Anything still checked by hand should also confirm that with both flags off, `hy3:movefocus`,
`hy3:movewindow`, `hy3:movetoworkspace`, `hy3:makegroup` and `hy3:changegroup toggletab`
behave exactly as upstream.

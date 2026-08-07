# Working on this repo

A personal fork of [outfoxxed/hy3](https://github.com/outfoxxed/hy3), kept in sync by rebasing
onto `upstream/master`. Not intended for upstreaming. **Read `FORK.md`** — it covers what the
fork adds, how changes are kept conflict-minimal, and how to install it with hyprpm.

## Ground rules

- **No AI/assistant attribution in commits.** No `Co-Authored-By`, no `Assisted-by:` trailer,
  no "generated with …" footer. AI assistance is accepted — naming the tool in the history is
  not, because it turns `git log` into permanent advertising for one vendor or another and
  tells a future reader nothing about the change. See `CONTRIBUTING.md`.
- Prefix fork commits `fork:` so the series is identifiable across rebases.
- **Never push unless explicitly told to.** The remote is the user's own fork.
- The user's Hyprland config is at `~/.config/hypr` (note: `hypr`, not `hyprland`), and it is
  **not** version controlled — back files up before editing, and never delete files you did
  not create.

## Never test against the user's live session

Unloading hy3 — a layout plugin that owns every tiled window — **crashed the compositor and
cost the user their session**. Do not do this to iterate on a build.

The crash report Hyprland writes carries no backtrace, but the systemd coredump does
(`coredumpctl info <pid>`), and it names the mechanism:

```
#10 Monitor::CMonitorFrameScheduler::onFrame()
#8  Animation::CHyprAnimationManager::frameTick()
#7  0x00007f3292fcd410  n/a (n/a + 0x0)      <- call into an unmapped address
```

A dangling callback into the unloaded library fits that trace, and `PLUGIN_EXIT` used to leave
two provable ways for one to survive — both since closed, see `Hy3Layout::shutdown()`:

- `g_tabGroups` holds **weak** pointers, so clearing it dropped references without destroying
  anything. Tab groups are owned by nodes inside `Hy3Layout` instances, and those belong to
  Hyprland, so a surviving one kept ten animated variables registered whose `setUpdateCallback`
  lambdas are compiled into this `.so`.
- The per-instance `m_windowActiveListener` / `m_mouseButtonListener` subscriptions were
  released only by `~Hy3Layout`, so a surviving instance stayed subscribed to the event bus
  with handlers in the unloaded library.

**Do not read that as a fix for this crash.** The crash has never been reproduced: six
unload/reload cycles with a live tab group and animations mid-flight survive with the teardown,
and five survived without it. Whether an instance outlives `PLUGIN_EXIT` in practice is still
unknown, and if Hyprland calls any virtual method on a surviving instance the vtable itself is
unmapped, which no plugin-side teardown can prevent. Treat unloading as unsafe.

For comparison, a SIGSEGV whose trace runs `exit` → `__cxa_finalize` →
`Aquamarine::CDRMBackend`/`CDRMRenderer` destructors → `eglDestroyContext` is **not** hy3: that
is an EGL teardown crash during process exit, after the session is already ending.

Use the throwaway instance instead:

```sh
test/nested.sh start 2   # throwaway Hyprland, this build loaded, two 1280x720 monitors
test/smoke.sh            # 31 assertions over the fork's behaviour
test/nested.sh stop
```

`test/nested.sh ctl <args>` runs `hyprctl` against the nested instance for manual poking.

Related traps when a build does need to reach a real session:

- `hyprctl plugin unload` returned `ok` while leaving the plugin handle **unchanged** — a
  silent no-op — and only actually unloaded on an identical second call.
- `hyprpm reload` will **not** replace an already-loaded plugin. "Ensuring plugin load state"
  skips anything already loaded, even when the `.so` on disk has been replaced.
- Prefer a re-login to activate a newly installed build. It is cheaper than the crash risk and
  exercises the real startup path.

## Verification traps

Every one of these produced a false PASS during development. Distrust a green result that came
from a hand-run check.

- **hy3's own `hy3_log` output never reaches the instance log**, at any level, including `ERR`
  and with `debug:disable_logs = false`. Do not waste a build cycle adding log instrumentation.
  Behaviour observed over `hyprctl` is the only practical oracle.
- **Assert on the focused monitor, not on the active window's workspace.** A scratchpad follows
  whichever monitor gains focus, so a window on it stays "active" whether or not focus actually
  left the monitor.
- **`focusMonitor` only changes the active window if the target monitor has one**, and only if
  a monitor exists in the direction being tested. Several "the focus trap works" results were
  vacuous because the scratchpad happened to sit on the edge-most monitor — nothing was ever
  attempted.
- **`move_to_monitor` moves a node to the target monitor's _regular_ workspace.** Using it to
  relocate a scratchpad silently takes the window off the scratchpad and invalidates everything
  downstream.
- **`general:layout` reading `dwindle` does not mean hy3 is inactive.** Spaces carry their own
  algorithm; check behaviour instead.
- **Confirm the running plugin is the one you just built.** `grep hy3 /proc/<pid>/maps` — and
  note that a `(deleted)` suffix means the old inode is still resident, i.e. the new file was
  never loaded. Print field 6 (the path), not the last field.

## Hyprland 0.56 config API

The user's config is Lua. Several older spellings no longer work:

- `hyprctl keyword` fails outright: *"keyword can't work with non-legacy parsers. Use eval."*
  Use `hyprctl eval "hl.config({ ... })"`.
- `hyprctl dispatch` evaluates its argument **as Lua** — `hyprctl dispatch "hl.plugin.hy3.move_focus('l')"`.
  String dispatchers like `hy3:movefocus l` do not parse.
- **Plugin config from the Lua config file does work.** hyprpm loads the plugin after the first
  evaluation; the plugin load triggers a config reload, and that is when it applies. Verified in
  the nested harness with nothing but a config file.
- **Do not guard plugin config on `hl.plugin.hy3`.** That table holds the Lua dispatcher
  factories and is nil during *every* config evaluation, so a guarded block never runs and the
  settings silently stay at defaults.
- **Do gate on `hl.get_config("plugin:hy3:<key>") ~= nil`.** `hl.config` on a key the loaded
  plugin never registered is recorded as an "unknown config key" config error and nagged about,
  and **`pcall` does not suppress it** — the error is registered before the Lua error
  propagates. A failing `hyprctl eval` nags the same way.

## Hyprland API gotchas hit while implementing

- `CMonitorQuery::selector` silently matches nothing for relative offsets (`+1`, `-1`). Names,
  `desc:…` and ids work. Relative offsets must be resolved by cycling
  `State::monitorState()->monitors()` by hand.
- `CWorkspace::getLastFocusedWindow()` still names a node you just moved away, so using it to
  restore focus chases the node onto the other monitor. Ask hy3 for the workspace's focused
  node instead.
- `hyprctl output create headless` yields an output that reports `0x0` and never takes a mode;
  windows sent there get negative sizes. Use `output create wayland` for nested test monitors.
- **The monitor `inDirection` query does not cross a gap.** With two monitors 4866px apart,
  `hy3:movetomonitor l|r` silently found nothing while index-based `+1`/`-1` still worked. Test
  monitors must be laid out edge to edge, or every directional result is a false negative.
- **A nested Wayland output reports no available modes** and rejects any mode as invalid; it is
  sized by the host compositor. A monitor rule applied later over `hyprctl eval` does nothing
  at all for these outputs — only rules present at output-creation time are honoured. So the
  positions live in `test/nested.lua`, and `test/nested.sh` floats the windows on the host,
  which snaps them to aquamarine's default 1280x720 so those positions line up.
- `Hy3Node::as_target()` **throws** on a group node — guard with `is_target()`, or operate on
  the focused window.

## Build

```sh
cmake -DCMAKE_BUILD_TYPE=Release -B build && cmake --build build
```

Must be built against the Hyprland release the installed headers belong to; `src/main.cpp`
refuses to load on a hash mismatch. Compare `hyprctl version` with `GIT_COMMIT_HASH` in
`/usr/include/hyprland/src/version.h`.

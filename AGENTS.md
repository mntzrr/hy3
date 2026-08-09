# Working on this repo

Derived from [outfoxxed/hy3](https://github.com/outfoxxed/hy3) and **maintained
independently** — no longer rebased onto it. Not intended for upstreaming. **Read `FORK.md`**
— it covers what this adds, why each change exists, and how to install it with hyprpm.

## Relationship to upstream

`upstream` is kept as a **read-only** remote and is never rebased onto:

```sh
git remote set-url --push upstream DISABLED   # re-apply after a fresh clone
```

That is local config, not something the repo carries, so a fresh clone starts with a pushable
upstream again — re-run it. It makes an accidental `git push upstream` fail on a bad URL
instead of on credentials, which is the difference between a typo and an incident.

Upstream is good at one thing this needs: chasing Hyprland releases quickly, usually tagging
`hl<version>` within a day of a major. It is slow at bug fixes — nine of its open issues were
fixed here rather than waited on. So the relationship is: take the release chasing, do the
rest here.

When a Hyprland update breaks the build:

```sh
git fetch upstream
git log --oneline upstream/master
git cherry-pick <chase commit>     # or hand-apply; conflicts are expected, see below
```

Expect conflicts in `src/`, and expect to resolve them by understanding both sides rather than
by taking one. The tree has diverged in the hot paths on purpose — `Hy3Node` carries a type tag
where upstream uses `dynamic_cast`, `recalcSizePosRecursive` is split in two and takes gaps
from its caller, `getNodeFromWindow` walks once. None of that is coming back.

**What changed by stopping rebases**, and it is the one thing worth knowing before touching
`FORK.md`'s tables: the backports carrying an `Upstream-PR:` trailer were designed so that a
rebase *drops them automatically* once upstream merged the PR. Nothing drops automatically any
more. If a backported PR is merged upstream and its commit is later cherry-picked in, the
change arrives twice. Check `FORK.md`'s backport table against `upstream/master` before
cherry-picking anything near it.

## Ground rules

- **No AI/assistant attribution in commits.** No `Co-Authored-By` naming an assistant, no
  `Assisted-by:` trailer, no "generated with …" footer, no mention in the subject or body. AI
  assistance is accepted — naming the tool in the history is not, because it turns `git log`
  into permanent advertising for one vendor or another and tells a future reader nothing about
  the change. See `CONTRIBUTING.md`.
  **Enforced by `.githooks/commit-msg`**; enable it with `git config core.hooksPath .githooks`.
  Assume your own defaults are wrong here: this rule was in context and still broken three
  times in one session, which is why the hook exists. A `Co-Authored-By:` naming a *person* is
  fine, and `--no-verify` is the way past for a replayed upstream commit.
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
test/smoke.sh            # 110 assertions over the fork's behaviour
test/nested.sh stop
```

`test/nested.sh ctl <args>` runs `hyprctl` against the nested instance for manual poking.

`test/smoke.sh` discovers monitor names and ids instead of assuming them, and waits on the
compositor rather than sleeping a fixed amount — a full run is ~30s. `HY3_TEST_TERM`
(default `alacritty`, must accept `--title`) and `HY3_TEST_TIMEOUT` (default 6s, raise it on
a loaded machine) are the two knobs.

### The nested instance is not as isolated as it looks

Guarding the `hyprctl` channel is not enough, and the harness spent a long time appearing safe
while it was not. Three things reach past the nested instance. The first two are held open for
the whole run rather than at some moment a guard could check; the third outlives the run
entirely:

- **libseat.** Hyprland opens a seat even under the wayland backend, where it needs nothing
  from one. With no seatd socket it falls back to logind, and the session it opens is whatever
  `XDG_SESSION_ID` names — inherited from whatever ran the script. Started from a terminal
  multiplexer that outlived its login, that is an old session *still on seat0*, the same seat
  as the live one. The instance then tries to activate it, which would deactivate the real
  session. It fails ("Session could not be activated in time") but holds the handle, and
  logind re-evaluating seat0 around it is enough for the session manager to tear the real
  session down. That is a logout with **no crash, no core, and nothing in either compositor's
  log** — the compositor is the victim, not the cause, and its own log just stops. It cost
  four sessions before it was found. `hypr-signal-log` names `start-hyprland` as the sender,
  which is true and misleading: that is the watchdog doing a normal teardown.
- **The DRM backend.** Aquamarine runs backends *together*, not as alternatives. What used to
  keep DRM out was the seat bug above — the seat was never activated, so DRM was unusable.
  Fix the seat and DRM succeeds instead, because the device nodes are ACL'd to the logged-in
  user: the harness comes up owning the real screens.

- **The systemd/dbus environment**, and this one keeps hurting after the instance is gone.
  Hyprland exports `WAYLAND_DISPLAY` and `HYPRLAND_INSTANCE_SIGNATURE` to the systemd user
  manager at startup, and it does this *itself* — `nested.lua` has no autostart and no
  `exec-once`, and it happens anyway, so there is no config line to remove. Every nested run
  overwrote the real session's values with the throwaway instance's
  (`WAYLAND_DISPLAY=wayland-1` → `wayland-2`).

  Nothing running notices, because a running service already holds its own display. What
  breaks is the **next restart of any user service**: it inherits a display that no longer
  exists, dies with `Failed to open display`, and keeps dying, because nothing puts the value
  back. It surfaced as a desktop shell stuck in a restart loop 105 attempts deep, an hour after
  a test run nobody connected to it — the run had long since finished and the harness looked
  innocent.

  `nested.sh` gives the instance a private `XDG_RUNTIME_DIR` (`$RUNDIR/xdg`) **and** unsets
  `DBUS_SESSION_BUS_ADDRESS`. Neither is sufficient alone: the bus address is set explicitly in
  the environment (`unix:path=/run/user/<uid>/bus`), so moving the runtime dir on its own
  leaves `dbus-update-activation-environment` a perfectly good route to the session bus. The
  host's wayland socket is symlinked into the private dir, because the wayland backend still
  has to reach the host compositor to open its windows.

  Welcome side effect: the instance is now alone in its own `hypr/` directory, so the
  set-difference signature discovery in `start()` — which the comments there rightly call a
  heuristic whose cost of being wrong once is the user's session — can no longer see the host
  at all. The explicit host-signature refusals stay anyway.

  To check it still holds: `systemctl --user show-environment | grep WAYLAND_DISPLAY` before
  and after a run. It must not change.

`nested.sh` also sets `LIBSEAT_BACKEND=noop` and `AQ_DRM_DEVICES=/dev/null`. Neither may be
removed without the other — dropping the second while keeping the first is what puts
`HDMI-A-1` in a nested instance's monitor list. `start()` then asserts every output is a
`WAYLAND-*` surface and refuses to continue otherwise, because both failures are silent: the
instance starts, the tests pass, and the only symptom is a session dying later for no
visible reason.

If a session dies during a nested run, check `loginctl list-sessions` for a second session on
seat0 before suspecting hy3.

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

  Confirmed again in the nested harness, and it is worth knowing *why*, because the obvious
  theory is wrong and leads to a wasted afternoon. The logger is **not** duplicated: hyprland
  declares `inline UP<CLogger> logger` in `debug/log/Logger.hpp`, GCC emits it as
  `STB_GNU_UNIQUE` (`u` in `nm`), and the dynamic linker unifies hy3's copy with the
  compositor's. hy3 is writing to hyprland's real logger.

  It goes nowhere because **hyprland's own core logging goes nowhere either**. With
  `debug:disable_logs` verified `false` via `getoption -j`, the instance log gained 582 lines
  from aquamarine and *zero* from hyprland's core, holding at the 18 DEBUG lines written during
  early startup. Aquamarine is a separate library with its own logger, which is why it is the
  only thing still reaching the file. So this is not an hy3 problem and no plugin-side change
  fixes it.

  The useful corollary: **`[hy3]` lines appearing on stdout are a symptom, not a success.** That
  happens when hy3 gets its *own* `Log::logger` - an uninitialised `CLogger` that has never had
  `initIS` called and so defaults to stdout, bypassing the config gate. If you see them, the
  build has broken symbol unification; see the `-fvisibility` trap under Build.
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
- **A new assertion that warps the cursor moves every later spawn.** Hyprland tracks the
  current monitor by cursor position regardless of `input:follow_mouse`, and new windows go to
  the current monitor. Adding one warping assertion mid-suite silently relocated four
  downstream blocks to mon1 and failed five assertions, none of which mentioned the cursor.
  Every block in `test/smoke.sh` that spawns now calls `pin_mon0` first rather than inheriting
  where the previous block left things. Do the same in a hand-run check.
- **`setflag` is not synchronous, and `jq`'s `//` lies about `false`.** `hl.config` returning
  is not the config having been applied; a dispatch fired too soon after runs under the *old*
  value, which looks exactly like the feature under test not working. `test/smoke.sh` now waits
  on `hyprctl getoption <key> -j` instead of a sleep — and reads it as
  `if has("bool") then (.bool|tostring) else empty end`, because `.bool // empty` treats a
  flag set to `false` as absent and waits forever. This produced a *different* single failure
  on each of four runs before it was found.
- **`cleanup_windows` only closes `t_*`.** Probe windows spawned by hand under any other name
  stay in the tree for the rest of the session and poison every geometry block after them. The
  symptom is a spread of unrelated failures whose values are *equal* to their baselines
  ("width 1268 vs baseline 1268") — nothing changed, because the tree was not what the block
  thought it was. Name hand-spawned windows `t_*`, or stop the instance afterwards.
- **A Hyprland upgrade mid-session breaks the nested instance, not your session.** The running
  compositor keeps the old version, but `nested.sh` starts the *new* binary from disk, and a
  build carrying the old headers' hash refuses to load into it: `plugin crashed/threw in main:
  target hyprland version mismatch`. `start()` then aborts, leaving an instance up with **no
  plugin loaded** — every `plugin:hy3:*` key reads `no such option` and the suite tests
  nothing. `rm -rf build` and rebuild. Do not redirect `start`'s stderr, which is how this was
  missed for two runs.
- **Moving the nested instance's windows off your workspace fails the suite.** They are the
  instance's *monitors* — Wayland surfaces on the host — so parking them somewhere they are not
  visible stops their frame callbacks, the nested compositor stops painting, and every
  assertion that waits on geometry settling times out. Leave them alone for the ~40s a run
  takes. Observed; the frame-callback mechanism is the reading of it, not something that was
  instrumented. Whether a workspace that stays visible on a *second* monitor is good enough
  follows from that reading — visibility rather than focus being what matters — but is
  untested.

  It reads exactly like a regression, and it cost four runs. The signature is that **the
  failure set moves between runs and does not overlap**: 4 failures then 2 on one build; 4, 6
  and 1 on the unmodified baseline, across `movetomonitor`, `changefocus raise`, window tags
  and floating `movewindow` — sections with nothing in common. Left alone, the same build
  passed 104/0.

  Machine load is the tempting explanation and was the wrong one here: the suspect binary had
  already passed 104/0 at a comparable load average, and `HY3_TEST_TIMEOUT=15` did not clear
  the failures either. Before blaming load, check the two things above — does the failure set
  move, and does the baseline fail too.
- **A `PRECONDITION` line means the harness, not the plugin.** Blocks inherit the tree the
  previous ones left, and under load a dispatch that quietly does not land leaves the next
  block testing a layout that was never set up — which surfaces as every assertion in it
  failing at once, none of them naming the reason. `require` checks a block's entry state, and
  on failure prints one `PRECONDITION` line and reports the rest of the block as `SKIP`. A run
  with skips exits non-zero: a skipped block is an untested one, not a passing one. Read the
  `PRECONDITION` line first and ignore the skips; the assertions after it were never run.

  It does not isolate blocks completely — they are a chain, and a skipped one still denies its
  side effects to later blocks. Expect a couple of genuine failures downstream of a skip.
- **Establish the baseline before believing a failure is yours.** Those four failures looked
  like a regression in the code under test; `git stash && cmake --build build` and a rerun
  showed the pre-change tree passing every assertion, which pointed straight at the harness
  instead. Restarting the nested instance is required after a rebuild — it holds the old
  `.so` open otherwise.

  This is also what catches the trap above, and it is cheap: `git worktree add --detach
  <dir> <baseline>`, build there, copy the `.so` over `build/libhy3.so`, restart the instance.
  A baseline that fails *differently* is a harness problem, not a code one.

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

`.github/workflows/build.yml` runs the same build over nix against the Hyprland pinned in
`flake.lock`, which is the point of it: it catches a rebase that no longer compiles without
needing a session. It deliberately does **not** gate formatting — the tree does not match
its own `.clang-format`, and reformatting a fork that rebases would conflict with every
future upstream commit.

### Never add `-fvisibility=hidden`

The plugin exports ~915 dynamic symbols and it is tempting to think that is sloppy. Hiding
them builds clean, links clean, passes `-Wall -Wextra` with zero warnings, cuts the count to
168 — and segfaults the compositor on the first dispatcher that touches a hyprland manager.
It reached the nested harness before anything caught it.

Hyprland hands plugins its managers as **inline variables in headers**:
`inline UP<CPluginSystem> g_pPluginSystem;` in `plugins/PluginSystem.hpp`,
`inline UP<CCompositor> g_pCompositor;` in `Compositor.hpp`, and so on. An inline variable is
emitted into every object file that uses it and relies on the dynamic linker unifying those
copies at load time, which only happens while they keep default visibility. GCC emits them
`STB_GNU_UNIQUE` — `u` in `nm -D`. Hide them and each becomes a plain local BSS symbol (`b`),
so hy3 gets its own zero-initialised copy of every manager pointer and the first call through
one dereferences an empty `UP`. Observed as:

```
#5  CPluginSystem::getAllPlugins            (Hyprland)
#6  Hy3Layout::moveNodeToWorkspace          (libhy3.so)
```

`Log::logger` goes the same way, which is where the stdout `[hy3]` lines under Verification
traps come from. So do the vtables and typeinfo of hyprland classes hy3 instantiates, and any
function-local static inside a hyprland inline function. **There is no partial version of this
that is safe** — `-fvisibility-inlines-hidden` alone still duplicates those statics.

To check a build has not lost unification:

```sh
nm -D --defined-only build/libhy3.so | grep g_pPluginSystem   # must print, and be 'u' not 'b'
```

What *is* safe, and is why the file-local helpers in `Hy3Layout.cpp`, `Hy3Node.cpp` and
`TabGroup.cpp` are marked `static`, is keeping hy3's **own** symbols out of the table. Nothing
outside the plugin references them, and that alone removed the genuinely risky names — bare
`reverse(ShiftDirection)`, `getAxis(ShiftDirection)`, `findTabBarAt(...)` — which another
plugin in the same process could otherwise interpose on.

### CI can fail on a toolchain version, not a dependency

CI failed on every push for days with what looks unmistakably like a packaging bug:

```
Could NOT find Lua (missing: LUA_INCLUDE_DIR)
FindLua.cmake:271
CMakeLists.txt (find_package)
```

Nothing was missing. Hyprland is built against `lua5_5` and already lists it in
`buildInputs`, which `default.nix` concatenates, so the headers were in the sysroot the whole
time. **CMake's `FindLua` only learned about Lua 5.5 in 4.3** — see the `.. versionadded:: 4.3`
in the module itself — and the nix toolchain supplies cmake **4.1.2**. This machine has 4.4.2,
so it never reproduced, and "works here, fails in CI" reads as an environment problem long
before it reads as *the finder is older than the dependency*.

Two wrong fixes were tried first and both would have been committed on reasoning alone: adding
`lua` to `default.nix` (a no-op, it is already there transitively), and chasing a split `dev`
output hiding the headers (nixpkgs' lua is `outputs = [ "out" "doc" ]`, headers in `$out`).
What settled it was reproducing under the real toolchain. `find_package` is now
`pkg_search_module`, which has no version ceiling.

The general shape is worth keeping: when a build fails only in CI, compare the *tools* before
the *inputs* — `cmake --version` here against the one in the failure's own stack trace, which
prints its store path and therefore its version on every line.

**Reproducing CI locally** is the only way to be sure, and needs nix working:

```sh
nix build .#hy3 --print-build-logs
```

- The arch `nix` package creates neither `/nix/store` nor any `/nix/*` path it owns. Without
  it every command dies with `error: opening file "/nix/store": No such file or directory`,
  and starting `nix-daemon.socket` does not help because the client fails before reaching the
  daemon. `sudo install -d -m 1775 -o root -g nixbld /nix/store` — the group is `nixbld`, per
  `build-users-group` in `/etc/nix/nix.conf`. Your account joins nothing; unprivileged access
  goes through the daemon.
- `NIX_REMOTE=daemon` is exported by `/etc/profile.d/nix-daemon.sh` in **login shells only**,
  so a script or an agent shell has to set it.
- Flakes are not enabled by default: `--extra-experimental-features 'nix-command flakes'`.
- CI pulls Hyprland from `hyprland.cachix.org`; adding a substituter needs root, so without it
  the first local run **builds Hyprland from source** — ~16 minutes on 24 cores. Only hyprland
  and hy3 are built, everything else substitutes from `cache.nixos.org`. It is cached
  afterwards, so only the first run is slow.

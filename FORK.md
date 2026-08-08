# Fork notes

This is a fork of [outfoxxed/hy3](https://github.com/outfoxxed/hy3). It tracks upstream and
adds a handful of features that previously had to be emulated from the Hyprland config with
Lua wrappers and `hyprctl`/`jq` shell scripts. There is no intent to upstream them.

Everything below is **off by default** — with no extra configuration this fork behaves exactly
like upstream. New behaviour is gated behind config flags; new dispatchers are purely additive.

## Installing with hyprpm

hyprpm clones with git, and git clones local paths, so this repo can be installed straight
from disk — no need to push anywhere. Only committed work is installed.

```sh
hyprpm remove hy3                         # drop upstream hy3; only one may own the name
hyprpm add /home/mntzr/Dev/hy3 master     # explicit rev => commit_pins are ignored
hyprpm enable hy3
hyprpm reload -n
```

Pass the revision. Without it hyprpm consults `commit_pins` in `hyprpm.toml`, and a pin
matching the running Hyprland would check out an **upstream** commit, silently dropping every
fork commit. After installing, confirm what actually landed:

```sh
grep hash /var/cache/hyprpm/mntzr/hy3/state.toml   # must equal this repo's HEAD
```

hyprpm elevates itself with `sudo`/`doas` for the parts that write under `/var/cache/hyprpm`,
so these need a terminal that can prompt.

To pick up new fork commits: commit here, then `hyprpm update`, or re-run the `remove`/`add`
pair with the new revision if the pinned rev needs to move.

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

Before a rebase, check the three tables below. They behave differently on one: the backports
disappear cleanly once upstream merges them, the overlapping PRs conflict once upstream merges
them, and the fixes to upstream bugs are carried forever because they were never reported.
After a rebase, the checks worth re-running are listed under "Verifying".

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
  on different displays. `refocusMonitor()` hands focus back to the origin monitor.
  `moveNodeToWorkspace` refocuses the origin's remaining node (backported #300, below); what
  is left here is monitor focus itself, plus a `getLastFocusedWindow()` fallback for a
  workspace with nothing in the hy3 tree. That fallback must keep its
  `m_workspace != workspace` check — without it, the window just moved is still the last
  focused one and focusing it chases the node onto the other screen.
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

## Backported upstream PRs

Fixes that are open upstream but touch code this fork's features sit on top of. Each is a
separate commit keeping its original author, subjected `fork: backport #NNN — …` and carrying
an `Upstream-PR:` trailer, so that **when upstream merges one, `git rebase` drops it and the
series keeps working**. Check each against `upstream/master` before a rebase.

| PR | Fixes | Adapted? |
| --- | --- | --- |
| [#302](https://github.com/outfoxxed/hy3/pull/302) | `setLayout` mutating the workspace root group — SIGABRT on the next focus walk | no |
| [#304](https://github.com/outfoxxed/hy3/pull/304) | null origin node dereferenced on `moveNodeToWorkspace`'s follow path | no |
| [#305](https://github.com/outfoxxed/hy3/pull/305) | moving a floating window with `follow` focused a tiled window that never moved | yes — warps to `layoutBox()`, upstream's `m_position`/`m_size` are gone |
| [#300](https://github.com/outfoxxed/hy3/pull/300) | nofollow moves left nothing focused on the origin, dropping focus through a scratchpad | yes — see below |
| [#331](https://github.com/outfoxxed/hy3/pull/331) | cursor warped to `m_reportedPosition`, published asynchronously and so stale | yes — extended to `focusMonitor`'s floating-window warp |
| [#296](https://github.com/outfoxxed/hy3/pull/296) | windows escaping tab groups on `hy3:movewindow`; `wrap`/collapse ignoring tab parents | no |
| [#298](https://github.com/outfoxxed/hy3/pull/298) | tab highlight not refreshed on monitor focus change | yes — `State::monitorState()->monitors()`, and teardown wired into `PLUGIN_EXIT` |

Two interactions worth knowing:

- **#300 and `refocusMonitor()` overlap.** Both refocus the origin's remaining hy3 node, and
  both avoid `getLastFocusedWindow()` for the same reason (it still names the node that was
  just moved and chases it onto the other screen). `moveNodeToWorkspace` now owns that half;
  `refocusMonitor()` keeps monitor focus itself and the fallback for a workspace with nothing
  left in the hy3 tree. Dropping #300 on a rebase means putting the node refocus back.
- **#298 registers a new listener.** `PLUGIN_EXIT` releases it, and `g_focusedMonitor`, above
  the `shutdown()` loop — nothing may stay registered holding a callback compiled into the
  `.so`. See the crash notes in `AGENTS.md`.

`#295` is superseded by `#296`. `#289`/`#168` are already in upstream master — note that
both PRs are still *open* on GitHub, their content having landed independently, so the PR
state is not the thing to check. `#329` (`focused_child` → `WP`) is deliberately **not**
taken: the concern is real, but it is a ~30-site mechanical diff and a permanent rebase
cost. Revisit if #304's guard proves insufficient.

## Upstream PRs that overlap fork features

The table above tracks PRs this fork *took*. These are the opposite: open upstream PRs
that reimplement something the fork already has. They do **not** drop out on rebase — they
land on top of fork code and conflict with it, so each needs a resolution decided before it
merges, not during.

| PR | Overlaps | State |
| --- | --- | --- |
| [#311](https://github.com/outfoxxed/hy3/pull/311) | feature 3, `movewindow_monitor_fallthrough` | open and live |
| [#178](https://github.com/outfoxxed/hy3/pull/178) | features 2 and 3 | open but stale — written against the pre-0.56 API (`this->nodes`, `vecPosition`), reported unmergeable, superseded in practice by #311 |

**#311 is the same patch in the same place.** Both insert into the `break_parent->is_root()`
branch of `shiftOrGetFocus` and call `shiftMonitor()` to hand the node to the adjacent
monitor. Three differences:

- it is **unconditional**; the fork gates on `plugin:hy3:movewindow_monitor_fallthrough`
  plus the per-invocation `monitor` argument
- it passes `warp = true`, threading a new parameter through `shiftMonitor`; the fork
  passes `false`, and `hy3:movewindow` has no warp argument at all
- it keeps upstream's `shiftMonitor`; the fork rewrote it as a wrapper over
  `moveToMonitor()`, which is what makes `follow = false` work

When it merges, resolve by **keeping the fork's gate around upstream's call** —
`if (monitor_fallthrough && shiftMonitor(node, direction, true, warp))`. Taking it verbatim
would break the invariant at the top of this file: off by default, identical to upstream.
Drop the fork's `shiftMonitor` wrapper only once upstream's own honours `follow = false`.

Its warp argument is a fair point the fork has not answered. With `input:follow_mouse` on,
moving a window across a monitor edge without warping leaves the pointer behind, so the
next keybind acts on a different window.

## Fixes to upstream bugs, carried here

Bugs in upstream code, found and fixed in this fork. All but one are **deliberately not
reported upstream**, so nothing will ever make them disappear on rebase — unlike the backports
above, which drop out once upstream merges them. Each is a permanent edit inside an upstream
function and will conflict whenever upstream touches the same code. On a conflict the fork's
side is the one to keep, unless upstream has independently fixed the same thing.

The exception is the guard sweep, which fixes an upstream issue that *is* reported (#332).
No PR exists for it, so it does not drop out on rebase either — but upstream is likely to fix
it eventually, and probably differently (see the note on #329 above, which is the other
proposed shape of the same fix). Check it before each rebase.

They are listed here because `git log` is the only other record: a future conflict in
`focusMonitor` or `insertNode` gives no clue whether that hunk is a fork feature, a backport
upstream has since merged, or one of these.

The hashes below are from before the first rebase and every one of them changes on each
rebase. The subject line is the stable key — `git log --grep "hit test tab bars"` finds the
commit whatever its hash has become.

| Commit | Fixes | Lives in |
| --- | --- | --- |
| `8761c3b` | `windows()` dereferenced a target whose window was gone. `as_target()` throws on an expired WP, and `shutdown()` walks this from `PLUGIN_EXIT`, where an escaping exception is `std::terminate` | `Hy3Node::windows()` |
| `97273d2` | `insertNode` destroys the node on its three failure paths; the caller kept using it — use after free | `Hy3Layout::insertNode` (return type), `moveNodeToWorkspace` |
| `b27d2b0` | a destination not running hy3 fell back to inserting into the *origin's* tree while the windows moved elsewhere | `moveNodeToWorkspace` |
| `ed0d775` | `focusMonitor` warped with `warp` hardcoded true, and its result was then focused a second time by `shiftFocus` | `focusMonitor`, `shiftOrGetFocus`, `shiftFocus`, `moveFocus` |
| `bf2b394` | the hyprsplit `dlsym` result was cached in a static: dangling after a hyprsplit unload, and a cached miss when hy3 loaded first | `operationWorkspaceForName` |
| `7de8855` | three unguarded nullable hops in the tab group constructor; `tick()` has been guarded since `d69eadc` | `Hy3TabGroup::Hy3TabGroup` |
| `ec98a3b` | a shader that fails to compile threw from inside the render pass, once per frame — a throwing function-local static is retried | `Hy3Shaders::instance`, `Hy3Render::renderTab` |
| `d1cfb4c` | tab bar hit testing checked its top bound against `logicalBox` and the other three against `visualBox` | `findTabBarAt` |
| `7a8fab0` | `tab_focused_node` was uninitialised and `goto hastab` jumps every assignment to it | `Hy3Layout::focusTab` |
| `617a457` | an empty-but-live root was destroyed and rebuilt, because `getWorkspaceRootGroup` returns null for both "no root" and "empty root" | `Hy3Layout::insertNode` |
| `46913ef` | `hy3:togglefocuslayer` was the only warping dispatcher that ignored `cursor:no_warps` | `dispatch_togglefocuslayer` |
| `696fc23` | a `hy3_log` call with printf conversions into a `std::format` sink, a doubled condition, a doubly-registered animation callback, a header/definition parameter name mismatch | `dispatch_focustab`, `warpCursor`, `Hy3TabBarEntry`, `TabGroup.hpp` |
| *guard sweep* | every remaining unguarded `as_target()`/`as_window()`, `8761c3b` having covered only `windows()` — **upstream #332** and the backtrace attached to **#241**. See below | `try_target()`/`try_window()`, ten call sites |

Four of these are worth re-checking against upstream before each rebase, because they are the
ones upstream is most likely to fix independently and in a different way: `97273d2`
(`insertNode`'s ownership contract), `ed0d775` (the warp threading, which #311 also touches —
see above), `ec98a3b` (shader lifetime), and the guard sweep (reported as #332, and #329 is a
competing shape of the same fix).

### The guard sweep

`as_target()` throws for a non-target node, and throws again for a target whose weak pointer
has expired; `as_window()` is `as_target()->window()`, so it throws for both and returns null
for a third case, a live target whose window is already torn down. Callers dereferenced the
result regardless. `8761c3b` fixed one site; this fixes the rest, by adding non-throwing
`try_target()`/`try_window()` next to them and using those wherever the tree is walked or
unwound.

Two of the sites are the reported crashes:

- **`findNodeFromTargetRecursive`** — walks *every* target in the tree looking for one, so
  `as_target()` threw on the first expired node it passed, before reaching the node it was
  asked for. It unwinds through `Layout::CAlgorithm::removeTarget` into `CWindow::unmapWindow`,
  which does not catch: SIGABRT on window close, watchdog restart into safe mode. This is
  **#332**, and the fork was carrying it.
- **`recalcSizePosRecursive`** — `as_window()->setHidden()` with no null check, on a path that
  runs during teardown. A SIGSEGV with this frame on top, called from `moveNodeToWorkspace`, is
  the crash report attached to **#241**.

The rest are the same pattern with a smaller blast radius: `removeTarget` (the node must still
leave the tree when its window is gone — only the rule cleanup is skipped), `resizeTarget`
(its `valid(window)` check was unreachable, the throw came first), `focus`, `updateDecos`,
`getTitle`, `debugNode`, `findTiledWindowCandidate`, `getNextCandidate`, `shouldRenderSelected`
and `findOverlappingWindows`.

`getNodeFromTarget` also gained a null-argument guard, which the switch to `try_target()`
makes load-bearing: a null needle would otherwise match the first expired node in the tree.

**#332 is not reproduced by the suite.** The throw needs a node whose target expired without
`removeTarget` ever running — stranded, then walked past by the next unmap. The only known way
to strand one is `removeTarget`'s `if (g_suppressInsert) return`, which needs an unmap to land
inside `moveNodeToWorkspace`'s `assignToSpace` loop; racing closes against that move did not
hit it here in 12 rounds, and the reporter could not isolate a trigger either. The four
assertions added under "fixes to upstream bugs" cover the observable half only and pass against
a pre-fix build — sanity checks, like #298's and #304's, not regression tests. The guards are
argued from the code path.

Two findings from the same review were deliberately **not** acted on, and should stay that way:

- `debugNodes` returns the node tree through `SDispatchResult::error`, which looks like abuse
  of the error channel. It is the only channel that works — `hy3_log` output does not reach
  the instance log at any level, see `AGENTS.md`. "Fixing" it would make `hy3:debugnodes`
  print nothing.
- `moveNodeToWorkspace` calls `updateTreeTabBars(*node)` and `node->updateTabBarRecursive()`
  back to back, which reads as duplicated work. It is not: the first walks descendants, the
  second ancestors.

## Verifying

Build against the Hyprland release the headers belong to:

```sh
cmake -DCMAKE_BUILD_TYPE=Release -B build && cmake --build build
```

Then run the suite against a throwaway instance — **not** your session. Unloading a layout
plugin that owns every window is disruptive at best, and has crashed the compositor here:

```sh
test/nested.sh start 2   # nested Hyprland, this build loaded, two 1280x720 monitors
test/smoke.sh            # 48 assertions covering everything below
test/nested.sh stop
```

`test/nested.sh ctl <args>` runs `hyprctl` against the nested instance for poking at it by
hand. `test/smoke.sh` discovers monitor names and ids rather than assuming them, and takes
`HY3_TEST_TERM` (default `alacritty`) and `HY3_TEST_TIMEOUT` (default 6s, raise it on a
loaded machine).

One assertion is known to flake: **#296's "a wrapper group was created"** occasionally reports
the wrapped width as equal to the baseline. `TAB_WIDTH` is sampled through `stable()`, but
`stable()` only waits for two consecutive equal reads, which a slow relayout can satisfy while
still mid-flight. Seen once in four runs. Re-run before treating it as a real failure — and if
it is chased properly, the fix is to sample the baseline against a known-good geometry rather
than against "stopped changing".

The workarounds the harness is built around — why the extra monitors are nested Wayland
outputs, why `hy3_log` is not an oracle, why the monitors must be edge to edge — are in
`AGENTS.md`, which is the single source for them. Read it before trusting a hand-run check.

Two notes on the backport assertions, both verified by building `34fff38` (the last
pre-backport commit) and running the current suite against it:

- Five of them do fail without the fixes — #305's two, #331's warp, #300's focus, and #296's
  tab bar. The other two pass either way and are sanity checks, not regression tests.
- **#304's own SIGSEGV does not reproduce here.** Emptying a special workspace still leaves
  an implicit group behind, so `getWorkspaceFocusedNode` returns that rather than null. The
  guard is kept as defence; #305's condition subsumes it.
- **#298 has no oracle.** Tab highlight state is not exposed over `hyprctl`, so it is checked
  by eye: put a tab group on each monitor and switch focus between them — the monitor being
  left must lose its active highlight, the one entered must gain it, without moving focus
  inside either group.

### Setting `plugin:hy3:*` from a Lua config

hyprpm loads the plugin *after* the first config evaluation, so on that pass hy3's config keys
do not exist yet. Loading the plugin triggers a config reload, and that is when they apply —
so a plain `hl.config` at the top level is all that is needed.

The two ways to get this wrong — guarding on `hl.plugin.hy3`, and letting `hl.config` run for
keys the loaded plugin never registered — are written up under "Hyprland 0.56 config API" in
`AGENTS.md`. The second one matters especially here: the fork-only keys are absent under
upstream hy3, so a config shared between the two nags on every evaluation. `hl.get_config`
returns nil for an unregistered key silently, which makes it the right way to ask:

```lua
if hl.get_config("plugin:hy3:special_focus_trap") ~= nil then
    hl.config({ plugin = { hy3 = { special_focus_trap = true } } })
end
```

`test/smoke.sh` now guards against both of the traps that used to make manual checks of these
features lie — asserting on the focused monitor rather than the active window, and giving the
escape somewhere to land. See "Verification traps" in `AGENTS.md` for why each one produced a
false PASS.

Anything still checked by hand should also confirm that with both flags off, `hy3:movefocus`,
`hy3:movewindow`, `hy3:movetoworkspace`, `hy3:makegroup` and `hy3:changegroup toggletab`
behave exactly as upstream.

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
- `warp` rides the same chain, and only the cross-monitor branch reads it: a move that stays
  inside one monitor has never warped and still does not. It defaults to `!cursor:no_warps`
  like every other dispatcher, with `warp`/`nowarp` (Lua: `{ warp = … }`) overriding per
  invocation. Without it the pointer stays on the monitor the window came from, and with
  `input:follow_mouse` the next keybind acts on whatever it is now hovering — which is the
  half of #311 this fork had not answered.

### 4. `hy3:togglefloating` / `hy3.toggle_floating`

Toggles the focused window's floating state, except on a special workspace, where the window
is unmounted onto a regular workspace with focus following it.

- `src/Hy3Layout.cpp` — `Hy3Layout::toggleFloating()`.
- The unmount target defaults to the workspace visible underneath the scratchpad, resolved
  explicitly from `monitor->m_activeWorkspace` (a monitor's active workspace is never the
  special one) rather than relying on a relative `e+0` selector.
- Like feature 1, the decision is keyed off the focused window's workspace so a visible but
  unfocused scratchpad doesn't hijack the action.

### 5. `plugin:hy3:movewindow_floating` (bool, default false)

With this set, `hy3:movewindow` moves the focused window when it is **floating**, so one bind
covers both layers the way it does in i3 and sway. Upstream's dispatcher does nothing useful
there — see the `#223` row in the fixes table below, which is the unconditional half of this
change.

- `src/Hy3Layout.cpp` — a floating branch at the top of `Hy3Layout::shiftWindow`.
- The move is handed to hyprland's own floating algorithm through
  `target->space()->moveTargetInDirection()`, which **snaps the window to the work area edge**
  in that direction. That is what hyprland's own `movewindow` does for a floating window, so
  the fork invents no second set of semantics and no step size to tune. An edge is a stop, not
  a step: a second move in the same direction does nothing.
- **Composes with feature 3.** Once the window is against that edge, `monitor_fallthrough`
  hands it to the adjacent monitor, exactly as it does for a node at the edge of the tree.
  The "did it move" test is a before/after compare of `target->position().pos()`.
- That monitor hop is also the *only* thing a floating window did before this branch existed,
  and only by accident: the move ran on the tiled tree, and if that happened to reach the root
  boundary, `shiftMonitor` → `moveNodeToWorkspace` took its floating-window path and carried
  the floating window across. Whether it happened at all depended on the shape of the tiled
  tree, which the user is not looking at. With `movewindow_floating` off the hop still works
  where the flag that governs it is on, but it is now decided by the floating window's own
  position.

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
| [#328](https://github.com/outfoxxed/hy3/pull/328) | `<lua.h>` located by luck rather than by cmake — the build only works where the distribution installs it directly in `/usr/include` | yes — include dirs only, see below |

**#328 is taken headers-only.** `src/dispatchers.cpp` includes hyprland's lua binding headers,
`hyprland.pc` says nothing about lua, and Arch happens to put `lua.h` in `/usr/include`; a
distribution that puts it under `/usr/include/lua5.4` does not build. `find_package(Lua)` fixes
that. Upstream's PR also adds `target_link_libraries(hy3 PRIVATE Lua::Lua)`, which is **not**
taken: hy3 resolves lua symbols from hyprland at load time — that is why it has always linked
with no lua on the command line — and a `DT_NEEDED` on a liblua that need not be the one
hyprland itself uses is a new failure mode for nothing. `readelf -d build/libhy3.so` should
list no lua after a rebase resolves a conflict here.

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
- it passes `warp = true` unconditionally; the fork threads the same parameter through
  `shiftMonitor` but defaults it to `!cursor:no_warps` and lets `hy3:movewindow … , warp` /
  `, nowarp` override it per invocation
- it keeps upstream's `shiftMonitor`; the fork rewrote it as a wrapper over
  `moveToMonitor()`, which is what makes `follow = false` work

When it merges, resolve by **keeping the fork's gate around upstream's call** —
`if (monitor_fallthrough && shiftMonitor(node, direction, true, warp))`. Taking it verbatim
would break the invariant at the top of this file: off by default, identical to upstream.
Drop the fork's `shiftMonitor` wrapper only once upstream's own honours `follow = false`.
The warp threading is now the same shape on both sides, so that half should merge cleanly;
what must survive is the gate and the `cursor:no_warps` default.

## Fixes to upstream bugs, carried here

Bugs in upstream code, found and fixed in this fork. Most were **never reported upstream**, so
nothing will ever make them disappear on rebase — unlike the backports above, which drop out
once upstream merges them. Each is a permanent edit inside an upstream function and will
conflict whenever upstream touches the same code. On a conflict the fork's side is the one to
keep, unless upstream has independently fixed the same thing.

Three fix issues that *are* reported: the guard sweep is **#332**, the makegroup toggle no-op
is **#192**, and `ed0d775`'s warp half is **#313**. None has a PR, so none drops out on rebase
either — but upstream may fix them eventually, and probably differently (see the note on #329
above, which is the other proposed shape of the guard sweep). Check those three before each
rebase; the rest only need checking if upstream touches the same function.

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
| `ed0d775` | `focusMonitor` warped with `warp` hardcoded true, and its result was then focused a second time by `shiftFocus` — the warp half is reported as **#313**, so upstream may fix it independently | `focusMonitor`, `shiftOrGetFocus`, `shiftFocus`, `moveFocus` |
| `bf2b394` | the hyprsplit `dlsym` result was cached in a static: dangling after a hyprsplit unload, and a cached miss when hy3 loaded first | `operationWorkspaceForName` |
| `7de8855` | three unguarded nullable hops in the tab group constructor; `tick()` has been guarded since `d69eadc` | `Hy3TabGroup::Hy3TabGroup` |
| `ec98a3b` | a shader that fails to compile threw from inside the render pass, once per frame — a throwing function-local static is retried | `Hy3Shaders::instance`, `Hy3Render::renderTab` |
| `d1cfb4c` | tab bar hit testing checked its top bound against `logicalBox` and the other three against `visualBox` | `findTabBarAt` |
| `7a8fab0` | `tab_focused_node` was uninitialised and `goto hastab` jumps every assignment to it | `Hy3Layout::focusTab` |
| `617a457` | an empty-but-live root was destroyed and rebuilt, because `getWorkspaceRootGroup` returns null for both "no root" and "empty root" | `Hy3Layout::insertNode` |
| `46913ef` | `hy3:togglefocuslayer` was the only warping dispatcher that ignored `cursor:no_warps` | `dispatch_togglefocuslayer` |
| `696fc23` | a `hy3_log` call with printf conversions into a `std::format` sink, a doubled condition, a doubly-registered animation callback, a header/definition parameter name mismatch | `dispatch_focustab`, `warpCursor`, `Hy3TabBarEntry`, `TabGroup.hpp` |
| *guard sweep* | every remaining unguarded `as_target()`/`as_window()`, `8761c3b` having covered only `windows()` — **upstream #332**. See below | `try_target()`/`try_window()`, ten call sites |
| *layout() sweep* | `Hy3Node::layout()` is documented nullable and was dereferenced unguarded at nine sites, one of them inside `recalcSizePosRecursive` — the frame **#241** crashes in. See below | `recalcLayoutGeometry()`/`layoutWorkspace()`, nine call sites |
| *makegroup toggle* | `makegroup … toggle` was a permanent no-op on a workspace holding one window — **upstream #192**. See below | `Hy3Layout::makeGroupOnWorkspace` |
| *floating movewindow* | with a floating window focused, `hy3:movewindow` moved a **tiled** node instead — `getWorkspaceFocusedNode` answers with whatever tiled node last had focus, and the user is not looking at it. Reported as **#223**; **#226** and **#85** are the feature half, which is feature 5 above | `Hy3Layout::shiftWindow` |
| *floating tree edits* | the same thing, quietly: `makegroup`, `changegroup`, `untab`, `toggletab`, `setswallow` and `expand` all reshaped the tiled tree behind a floating window. Never reported — nothing moves where the user is looking. See below | `getWorkspaceFocusedNodeIfTiled()`, nine call sites |
| *tab font size* | a size written into `tabs:text_font` was parsed and then overwritten by `text_height`, so the standard way to write a pango description silently did nothing — **upstream #275**, no PR | `Hy3TabBarEntry::renderText` |

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

One of the sites is a reported crash:

- **`findNodeFromTargetRecursive`** — walks *every* target in the tree looking for one, so
  `as_target()` threw on the first expired node it passed, before reaching the node it was
  asked for. It unwinds through `Layout::CAlgorithm::removeTarget` into `CWindow::unmapWindow`,
  which does not catch: SIGABRT on window close, watchdog restart into safe mode. This is
  **#332**, and the fork was carrying it.

`recalcSizePosRecursive`'s `as_window()->setHidden()` was also unguarded and is fixed here, but
**it is not #241**, which an earlier version of this file claimed. #241's own backtrace is a
null `node` reaching `node->parent->recalcSizePosRecursive()` in `moveNodeToWorkspace`'s follow
branch — a dereference this fork had already removed via the #304 and #305 backports before the
guard sweep existed. Five fullscreen cross-monitor paths were probed against the current tree
and none crashes. What the guard fixes is a *different* null in the same function: a live node
whose window is already torn down.

The rest are the same pattern with a smaller blast radius: `removeTarget` (the node must still
leave the tree when its window is gone — only the rule cleanup is skipped), `resizeTarget`
(its `valid(window)` check was unreachable, the throw came first), `focus`, `updateDecos`,
`getTitle`, `debugNode`, `findTiledWindowCandidate`, `getNextCandidate`, `shouldRenderSelected`
and `findOverlappingWindows`.

`getNodeFromTarget` also gained a null-argument guard, which the switch to `try_target()`
makes load-bearing: a null needle would otherwise match the first expired node in the tree.

### The layout() sweep

`Hy3Node::layout()` ends `return r ? r->algo : nullptr` — it is nullable by construction, for a
node with no root: one extracted from its tree, or one whose parent chain is mid-surgery. All
nine callers dereferenced it anyway, which is a SIGSEGV inside whatever they called next.

Two wrappers cover everything they wanted from it — `recalcLayoutGeometry()`, a no-op without a
layout, and `layoutWorkspace()`, null without one. The interesting site is
`recalcSizePosRecursive`'s `getWorkspaceRuleFor(this->layout()->workspace())`: a detached node
crashes there, in **the same frame #241 reports**. That does not make it #241 — #241's own
dereference is gone, see above — but it is the one remaining way to produce that backtrace, and
it is why "fix #241 properly" lands here rather than in the guard sweep.

`moveNodeToWorkspace`'s `origin_ws` needed more than a guard: the node's workspace is the first
arm of a three-way ternary, so a detached node has to *fall through* to the focused window's
workspace, not short-circuit the whole expression to null.

Two things to know about the diff. `Hy3Node::valid()` shadows hyprland's free `valid()` inside
member functions, so the workspace checks are written `::valid(ws)`. And `getWorkspaceRuleFor`
is only called when there is a workspace to ask about — it takes `PHLWORKSPACE` by value and
nothing here establishes that it tolerates a null one.

### The makegroup toggle no-op

`hy3:makegroup tab toggle` on a workspace holding a single window created the group and then
would not take it away again — the tab bar and the space it insets stayed, and no number of
further presses changed anything. Upstream **#192**, open since April 2025, no PR.

The toggle-off path asks `collapseParents(SingleNodeGroups)` to dissolve the group. That
never happens here, and not because of the policy: `shouldCollapseNode` refuses a group
hanging directly off the root whose only child is a window (`is_root_group() && !child->is_group()`)
before it ever looks at one, so that a workspace always keeps a group as its top level
container. `collapseParents` hands the group straight back, the caller sees a return it treats
as success, and nothing happened.

The container has to survive, but its layout does not. The refused case is now recognised —
`collapsed == parent`, which is exactly what the non-collapsing branch returns — and answered
with `untabGroupOn()`, dropping the group to `previous_nontab_layout` (`SplitH` by default,
so it is safe on a group that was created tabbed rather than switched). The tab bar goes, the
inset goes with it, and the workspace keeps its container.

Only the tab case is worth acting on: `makegroup h toggle` hits the same refusal, but a split
group with no bar and no inset looks identical either way, so the no-op stays.

The reporter also saw crashes a few seconds after toggling. Nothing like that reproduced here
over repeated toggle cycles, and no claim is made about it.

### Tree edits behind a floating window

`getWorkspaceFocusedNode` answers with the tiled node that last held focus whether or not the
focused window is one — a floating window is not in the tree at all. Every dispatcher that
*reshapes* the tree therefore reshaped it behind the floating window the user was looking at:
`makegroup` tabbed windows that were never the target, `changegroup` relaid out a group that
was not on screen, `expand` and `setswallow` acted on a node chosen for them.

`hy3:movewindow` was the visible form of the same bug and is reported as **#223** (feature 5
and the row above). These are the quiet ones — nothing moves where the user is looking, which
is presumably why nobody has reported them.

Nine call sites now go through `getWorkspaceFocusedNodeIfTiled()`, which is
`getWorkspaceFocusedNode()` plus "null while a floating window holds focus":
`makeGroupOnWorkspace`, `makeOppositeGroupOnWorkspace`, `changeGroupOnWorkspace`,
`untabGroupOnWorkspace`, `toggleTabGroupOnWorkspace`, `changeGroupToOppositeOnWorkspace`,
`changeGroupEphemeralityOnWorkspace`, `setNodeSwallow` and `expand`. One wrapper rather than
nine guard clauses, so the edit inside each upstream function is a single call swap.

Doing nothing is the whole of the answer, unlike movewindow: none of these has a floating
equivalent to fall back to — a floating window cannot be tabbed, wrapped or swallowed.
`killFocusedNode` is **not** in the list and needs no change; upstream already guards it, and
it closes the floating window, which is the right thing for that one.

The guard is on the focused *window* being floating, not on a floating window existing. The
suite's control assertion is there for that: with focus back on the tiled layer, `makegroup`
must still tab. A guard one step too broad passes every other assertion in the block and
breaks `makegroup` outright.

### The tab font size

`tabs:text_font` is a pango font description, and the standard way to write one carries the
size: `Sans 20`. `renderText` parsed it and then called `pango_font_description_set_size` with
`tabs:text_height` regardless, so the size half of the description was always discarded —
upstream **#275**, no PR.

`text_height` now applies only when the description carries no size of its own, which is the
default (`Sans`), so nothing changes for a config that never wrote one. When it does, the
parsed size is kept and only scaled for the monitor: the texture is rendered at device scale
while both sizes are logical, and `set_absolute_size`/`set_size` are separate calls because a
description may carry either kind. Verified by pixel-comparing three tab bar screenshots out
of the nested instance — `Sans 20` with `text_height = 8` is byte-identical to `Sans` with
`text_height = 20`, and both differ from the default.

The bar does not grow to fit: `tabs:height` is what sizes it, and a font larger than it fits
overflows, exactly as it does when `text_height` is raised past the bar. That is the existing
behaviour of the knob this restores, not a new one.

The suite covers the fullscreen cross-monitor path under **#241** — five assertions, of which
"origin reclaimed the space" is the load-bearing one: it says the moved node really left the
origin tree rather than being stranded there while its window went elsewhere, which is exactly
the state #332's throw needs. They pass without any of these fixes. The path is covered because
the fork *enables* it — `hy3:movetomonitor` and the movewindow fallthrough are how a node
crosses a monitor boundary at all.

**#332 is not reproduced by the suite.** The throw needs a node whose target expired without
`removeTarget` ever running — stranded, then walked past by the next unmap. The only known way
to strand one is `removeTarget`'s `if (g_suppressInsert) return`, which needs an unmap to land
inside `moveNodeToWorkspace`'s `assignToSpace` loop; racing closes against that move did not
hit it here in 12 rounds, and the reporter could not isolate a trigger either. The four
assertions added under "fixes to upstream bugs" cover the observable half only and pass against
a pre-fix build — sanity checks, like #298's and #304's, not regression tests. The guards are
argued from the code path.

The one thing they would catch is a regression that makes the guards themselves wrong: dropping
a node on the floor instead of removing it, or skipping the tree removal along with the window
cleanup in `removeTarget`. That is what "layout still tiles after the unmap" is for.

**The floating movewindow block is a real regression test**, unlike most of the above: five of
its ten assertions fail against a build with the branch disabled, verified that way rather than
argued. Two are the wrong-window move itself — the two tiled windows swap places while the
floating one sits still — and they need *two* tiled windows to be observable at all: with one,
the bad move is a no-op and the assertion passes against a build carrying the bug. The other
three are the feature and the fallthrough hop.

The tree-edit block is two regression tests and three checks around them, verified the same
way: `makegroup` and `changegroup` both tab the windows behind the floating one against a
build with the guard disabled, and the geometry oracle catches it as a bar inset. **`expand`
passes either way** — on this tree it changes no geometry at all, so it is a sanity check, not
a regression test. The other two are the floating precondition and the tiled control.

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
test/smoke.sh            # 78 assertions covering everything below
test/nested.sh stop
```

`test/nested.sh ctl <args>` runs `hyprctl` against the nested instance for poking at it by
hand. `test/smoke.sh` discovers monitor names and ids rather than assuming them, and takes
`HY3_TEST_TERM` (default `alacritty`) and `HY3_TEST_TIMEOUT` (default 6s, raise it on a
loaded machine).

**#296's "a wrapper group was created" used to flake**, reporting `width 800 vs baseline 800`.
It was not a timing problem — 800x600 is alacritty's *floating* default, against 630 wide for a
tiled window here, so the number was the diagnosis: the block was measuring a floating window,
whose size no `makegroup` changes.

It got one because it measured `t_a`, forty-odd operations after the setup that spawned it. The
suspected origin is the `togglefloating` block: its three toggles only mean "unmount, float on,
float off" if the first finds `t_a` on the scratchpad, and if it does not, each shifts by a step
and the block ends leaving `t_a` floating. That matches the three failures the flaky run
reported — the two float assertions, and #296 far downstream.

Three changes, verified by injecting the state directly rather than waiting for the flake:

- #296 spawns its own two windows after a `cleanup_windows` instead of inheriting `t_a`, so it
  is no longer where unrelated earlier mistakes surface. Two, not one: `makegroup` on a
  single-client workspace was its own upstream bug (#192, since fixed here — the block has
  its own section now, and #296 stays on two windows so the two are tested separately).
- `narrower_than` checks floating state first and says so, because "is it narrower" is not a
  meaningful question about a window whose size is fixed.
- The `togglefloating` block asserts that `t_a` starts on the scratchpad, so a parity shift
  fails by name where it happens.

When chasing a geometry failure in this suite, check `floating` before anything else. A tiled
window here is 630 wide with two on a monitor; 800 means floating, every time.

`== setup ==` now focuses mon0 before spawning anything. Windows spawn wherever focus happens
to be, so an instance left with focus on mon1 — by a previous run, or by poking at it by hand
between runs — put the whole suite on the wrong screen and failed every monitor assertion from
there down, none of which named the cause. This bit twice during development. Verified by
parking focus on mon1 deliberately and confirming a full pass.

Also update this count when adding assertions; a stale number here is how a silently skipped
section goes unnoticed.

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

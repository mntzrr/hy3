<img align="right" style="width: 256px" src="assets/logo.svg">

# hy3

i3 / sway like layout for [hyprland](https://github.com/hyprwm/hyprland).

> **This is an independently maintained fork** of
> [outfoxxed/hy3](https://github.com/outfoxxed/hy3), derived from it but no longer tracking it.
> Additions are marked **(fork)** throughout; everything unmarked is upstream's work, under the
> same GPL-3. See [FORK.md](./FORK.md) for what differs and why.
>
> Problems with this fork are not upstream's to field — do not report fork behaviour in
> upstream's issue tracker or matrix room.

[Installation](#installation), [Configuration](#configuration)

*Check the [changelog](./CHANGELOG.md) for a list of new features and improvements*

### Features
- [x] i3 like tiling
- [x] Node based window manipulation (you can interact with multiple windows at once)
- [x] Greatly improved tabbed node groups over base hyprland
- [x] Optional autotiling

Additional features may be suggested in this repo's issues.

### Demo
<video width="640" height="360" controls="controls" src="https://github.com/user-attachments/assets/ed2fe78d-8c31-47d8-a91d-e89aed42189c"></video>

### Stability
This fork does not cut releases; `master` is the only supported ref and is expected to
build against the current hyprland release.

If you encounter any bugs, please report them in this repo's issue tracker, including:
- Commit hash of the version you are running.
- Steps to reproduce the bug (if you can figure them out)
- backtrace of the crash (if applicable)

## Installation

> [!IMPORTANT]
> hy3 must be built against the hyprland release you run - a mismatch fails the build or
> refuses to load. This fork's `master` tracks recent hyprland releases (currently 0.56.x)
> and does not cut its own tags: the `hl{version}` tags in this repo are upstream's commits
> and carry none of the fork's changes. Follow `master`.

### Nix
#### Hyprland home manager module
Assuming you use hyprland's home manager module, you can easily integrate hy3 by adding it to the plugins array.

```nix
# flake.nix

{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    hyprland.url = "git+https://github.com/hyprwm/Hyprland?submodules=1&ref={version}";
    # where {version} is the hyprland release version
    # or "github:hyprwm/Hyprland?submodules=1" to follow the development branch

    hy3 = {
      url = "github:mntzrr/hy3";
      # (fork) no ref: master tracks recent hyprland releases. the hl* tags are
      # upstream's commits and lack the fork's changes.
      inputs.hyprland.follows = "hyprland";
    };
  };

  outputs = { nixpkgs, home-manager, hyprland, hy3, ... }: {
    homeConfigurations."user@hostname" = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      modules = [
        hyprland.homeManagerModules.default

        {
          wayland.windowManager.hyprland = {
            enable = true;
            plugins = [ hy3.packages.x86_64-linux.hy3 ];
          };
        }
      ];
    };
  };
}
```

#### Manual (Nix)
hy3's binary is available as `${hy3.packages.<system>.hy3}/lib/libhy3.so`, so you can also
directly use it in your hyprland config like so:

```nix
# ...
wayland.windowManager.hyprland = {
  # ...
  extraConfig = ''
    plugin = ${hy3.packages.x86_64-linux.hy3}/lib/libhy3.so
  '';
};
```

### hyprpm
Hyprland now has a dedicated plugin manager, which should be used when your package manager
isn't capable of locking hy3 builds to the correct hyprland version.

> [!IMPORTANT]
> Make sure hyprpm is activated by putting
>
> ```conf
> exec-once = hyprpm reload -n
> ```
>
> in your hyprland.conf. (See [the wiki](https://wiki.hyprland.org/Plugins/Using-Plugins/) for details.)

To install this fork via hyprpm run

```sh
hyprpm remove hy3                                   # if upstream's hy3 is installed; only one may own the name
hyprpm add https://github.com/mntzrr/hy3 master
hyprpm enable hy3
```

> [!WARNING]
> **(fork)** Pass the `master` revision. Without it hyprpm consults `hyprpm.toml`'s
> `commit_pins` table, which is upstream's: it maps hyprland versions to *upstream* hy3
> commits, so on a pinned hyprland version (the table currently stops at 0.56.0) hyprpm
> checks out an upstream commit and silently drops every fork commit. With no pin matching
> (hyprland 0.56.1 and later) it falls through to this fork's branch head either way.
>
> After installing or updating, confirm what actually landed:
>
> ```sh
> grep hash /var/cache/hyprpm/$USER/hy3/state.toml   # must equal this repo's HEAD
> ```
>
> A rebuilt plugin is not swapped into a running session - the new build takes effect on
> your next login.

To update hy3 (and all other plugins), run

```sh
hyprpm update
```

Sometimes the headers from hyprland are not updated, if this happens run (See [issue #109](https://github.com/outfoxxed/hy3/issues/109) for an example of where this happened)

```sh
hyprpm update -f
```

(See [the wiki](https://wiki.hyprland.org/Plugins/Using-Plugins/) for details.)

> [!WARNING]
> When you are running a tagged hyprland version hyprpm (0.34.0+) will build against hy3's
> corresponding release. However if you are running an untagged build (aka `-git`) hyprpm
> will build against hy3's *latest* commit. This means **if you are running an out of date
> untagged build of hyprland, hyprpm may pick an incompatible revision of hy3**.
>
> To fix this problem you will either need to update hyprland or manually build the correct
> version of hy3.

### Manual
Install hyprland, including its headers and pkg-config file, then run the following commands:

```sh
cmake -DCMAKE_BUILD_TYPE=Release -B build
cmake --build build
```

The plugin will be located at `build/libhy3.so`, and you can load it normally
(See [the hyprland wiki](https://wiki.hyprland.org/Plugins/Using-Plugins/#installing--using-plugins) for details.)

Note that the hyprland headers and pkg-config file **MUST be installed correctly, for the target version of hyprland**.

## Configuration

Configuration is done through hyprland's Lua config. Enable the layout with

```lua
hl.config({ general = { layout = "hy3" } })
```

hy3 requires using a few custom dispatchers for normal operation.
Replace the following standard dispatchers with their hy3 equivalents:
 - `movefocus` -> `hl.plugin.hy3.move_focus`
 - `movewindow` -> `hl.plugin.hy3.move_window`
 - `movetoworkspace` -> `hl.plugin.hy3.move_to_workspace`
 - `killactive` -> `hl.plugin.hy3.kill_active`

`hl.plugin.hy3.make_group` creates a new split.

The [config fields](#config-fields) and [Lua dispatchers](#lua-dispatchers) sections have all the
configuration options, and some explanation as to what they do.

### Config fields
```lua
hl.config({
	plugin = { hy3 = {
		-- policy controlling what happens when a node is removed from a group,
		-- leaving only a group
		-- 0 = remove the nested group
		-- 1 = keep the nested group
		-- 2 = keep the nested group only if its parent is a tab group
		node_collapse_policy = <int>, -- default: 2

		-- when a workspace holds a single window, treat it as fullscreen for tab bar
		-- purposes: the bar is hidden for it
		no_gaps_when_only = <int>, -- default: 0

		-- offset from group split direction when only one window is in a group
		group_inset = <int>, -- default: 10

		-- if a tab group will automatically be created for the first window spawned in a workspace
		tab_first_window = <bool>,

		-- (fork) tag windows with hy3's grouping state - hy3_grouped when inside any
		-- group, hy3_tabbed when inside a tab group - so windowrules can react to it.
		-- backported from upstream PR #327.
		tag_windows = <bool>, -- default: false

		-- tab group settings
		tabs = {
			-- height of the tab bar
			height = <int>, -- default: 22

			-- padding between the tab bar and its focused node
			padding = <int>, -- default: 5

			-- the tab bar should animate in/out from the top instead of below the window
			from_top = <bool>, -- default: false

			-- radius of tab bar corners
			radius = <int>, -- default: 6

			-- tab bar border width
			border_width = <int>, -- default: 2

			-- render the window title on the bar
			render_text = <bool>, -- default: true

			-- center the window title
			text_center = <bool>, -- default: true

			-- font to render the window title with
			text_font = <string>, -- default: Sans

			-- height of the window title
			text_height = <int>, -- default: 8

			-- left padding of the window title
			text_padding = <int>, -- default: 3

			colors = {
				-- active tab bar segment colors
				active = <color>, -- default: rgba(33ccff40)
				active_border = <color>, -- default: rgba(33ccffee)
				active_text = <color>, -- default: rgba(ffffffff)

				-- active tab bar segment colors for bars on an unfocused monitor
				active_alt_monitor = <color>, -- default: rgba(60606040)
				active_alt_monitor_border = <color>, -- default: rgba(808080ee)
				active_alt_monitor_text = <color>, -- default: rgba(ffffffff)

				-- focused tab bar segment colors (focused node in unfocused container)
				focused = <color>, -- default: rgba(60606040)
				focused_border = <color>, -- default: rgba(808080ee)
				focused_text = <color>, -- default: rgba(ffffffff)

				-- inactive tab bar segment colors
				inactive = <color>, -- default: rgba(30303020)
				inactive_border = <color>, -- default: rgba(606060aa)
				inactive_text = <color>, -- default: rgba(ffffffff)

				-- urgent tab bar segment colors
				urgent = <color>, -- default: rgba(ff223340)
				urgent_border = <color>, -- default: rgba(ff2233ee)
				urgent_text = <color>, -- default: rgba(ffffffff)

				-- locked tab bar segment colors
				locked = <color>, -- default: rgba(90903340)
				locked_border = <color>, -- default: rgba(909033ee)
				locked_text = <color>, -- default: rgba(ffffffff)
			},

			-- if tab backgrounds should be blurred
			-- Blur is only visible when the above colors are not opaque.
			blur = <bool>, -- default: true

			-- opacity multiplier for tabs
			-- Applies to blur as well as the given colors.
			opacity = <float>, -- default: 1.0
		},

		-- autotiling settings
		autotile = {
			-- enable autotile
			enable = <bool>, -- default: false

			-- make autotile-created groups ephemeral
			ephemeral_groups = <bool>, -- default: true

			-- if a window would be squished smaller than this width, a vertical split will be created
			-- -1 = never automatically split vertically
			-- 0 = always automatically split vertically
			-- <number> = pixel width to split at
			trigger_width = <int>, -- default: 0

			-- if a window would be squished smaller than this height, a horizontal split will be created
			-- -1 = never automatically split horizontally
			-- 0 = always automatically split horizontally
			-- <number> = pixel height to split at
			trigger_height = <int>, -- default: 0

			-- a space or comma separated list of workspace ids where autotile should be enabled
			-- it's possible to create an exception rule by prefixing the definition with "not:"
			-- workspaces = "1,2" -- autotiling will only be enabled on workspaces 1 and 2
			-- workspaces = "not:1,2" -- autotiling will be enabled on all workspaces except 1 and 2
			workspaces = <string>, -- default: all
		},

		-- (fork) directional focus never leaves a special (scratchpad) workspace for
		-- another monitor - at the edge of the scratchpad's layout, focus stays put
		special_focus_trap = <bool>, -- default: false

		-- (fork) move_window at the edge of the layout hands the node to the
		-- adjacent monitor instead of wrapping it into a new group
		movewindow_monitor_fallthrough = <bool>, -- default: false

		-- (fork) move_window also moves a focused *floating* window - snapped to
		-- the work-area edge in that direction, like hyprland's own movewindow, and
		-- across monitors once against the edge if movewindow_monitor_fallthrough
		-- is also on
		movewindow_floating = <bool>, -- default: false

		-- (fork) change_focus "raise" stops at the workspace group instead of
		-- wrapping back to the focused window, the way "lower" already stops at one
		changefocus_raise_stops = <bool>, -- default: false

		-- (fork) on a workspace managed by another layout, move_focus, move_window,
		-- swap_window, toggle_floating and move_to_monitor delegate to hyprland's
		-- native actions instead of doing nothing - one set of binds covers hy3
		-- and foreign layouts
		layout_fallback = <bool>, -- default: false
	} },
})
```

### Lua dispatchers

hy3 exposes dispatcher factories under `hl.plugin.hy3`.
The returned functions can be passed to `hl.bind(...)`.

```lua
local hy3 = hl.plugin.hy3

-- all factories return dispatcher functions and dispatchers return no values
-- option tables are optional except for focus_tab

hy3.make_group("h" | "v" | "tab" | "opposite", {
	toggle = true | false,              -- default: false
	ephemeral = true | false | "force", -- default: false
})

hy3.change_group("h" | "v" | "tab" | "untab" | "toggletab" | "opposite")

hy3.set_ephemeral(true | false | "true" | "false")

hy3.move_focus("l" | "r" | "u" | "d" | "left" | "right" | "up" | "down", {
	visible = true | false, -- default: false
	warp = true | false,    -- default: follows cursor:no_warps
})

hy3.toggle_focus_layer({
	warp = true | false, -- default: follows cursor:no_warps
})

hy3.warp_cursor()

hy3.move_window("l" | "r" | "u" | "d" | "left" | "right" | "up" | "down", {
	once = true | false,    -- default: false
	visible = true | false, -- default: false
	monitor = true | false, -- (fork) default: follows plugin:hy3:movewindow_monitor_fallthrough
	warp = true | false,    -- (fork) default: follows cursor:no_warps. only read when the move crosses a monitor
})

hy3.move_to_workspace("<workspace>", {
	follow = true | false, -- default: false
	warp = true | false,   -- default: follows cursor:no_warps when follow = true
})

hy3.change_focus("top" | "bottom" | "raise" | "lower" | "tab" | "tabnode")

-- direction and index are mutually exclusive
hy3.focus_tab({
	direction = "l" | "r" | "left" | "right",
	mouse = "ignore" | "prioritize_hovered" | "require_hovered", -- default: "ignore"
	wrap = true | false, -- default: false
})

hy3.focus_tab({
	index = <number>,
	mouse = "ignore" | "prioritize_hovered" | "require_hovered", -- default: "ignore"
	wrap = true | false, -- default: false
})

hy3.set_swallow(true | false | "true" | "false" | "toggle") -- alpha quality

hy3.kill_active()

-- alpha quality
hy3.expand("expand" | "shrink" | "base" | "maximize" | "fullscreen", {
	fullscreen = "" | "intermediate_maximize" | "fullscreen_maximize" | "maximize_only",
})

hy3.lock_tab(nil | "" | "toggle" | "lock" | "unlock")

hy3.equalize({
	scope = "" | "group" | "workspace", -- default: "group"
	workspace = true | false,           -- overrides scope if present
	recursive = true | false,           -- overrides workspace if present
})

hy3.debug_nodes()

-- (fork) additions

hy3.move_to_monitor("l" | "r" | "u" | "d" | "+1" | "-1" | "current" | "<name>" | "<id>", {
	follow = true | false, -- default: false
	warp = true | false,   -- default: follows cursor:no_warps when follow = true
})

hy3.toggle_floating({
	workspace = "<workspace>", -- default: the workspace underneath the scratchpad
	warp = true | false,       -- default: follows cursor:no_warps
})

hy3.swap_window("l" | "r" | "u" | "d" | "left" | "right" | "up" | "down")
```

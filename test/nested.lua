-- Minimal Hyprland config for a throwaway nested/headless instance used to
-- exercise hy3 without touching a real session. See test/nested.sh.
--
-- Deliberately does NOT set general:layout to hy3 or any plugin:hy3:* value.
-- On Hyprland 0.56 a config load resets plugin config values to the plugin's
-- registered defaults *after* parsing, so anything set here would be discarded;
-- test/nested.sh applies it with `hyprctl eval` once the plugin is loaded.

hl.config({
    general = {
        gaps_in = 2,
        gaps_out = 4,
        border_size = 2,
    },
    decoration = {
        rounding = 0,
        blur = { enabled = false },
        shadow = { enabled = false },
    },
    animations = {
        enabled = false,
    },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        disable_autoreload = true,
        force_default_wallpaper = 0,
    },
    input = {
        follow_mouse = 0,
    },
})

-- Monitor layout.
--
-- These have to live in the config: a monitor rule applied later over
-- `hyprctl eval` does nothing at all for these outputs, while a rule present at
-- output-creation time is honoured. Nor can a mode be set - a nested wayland
-- output reports no available modes, is sized by the host compositor, and
-- rejects any mode as invalid.
--
-- So only the position is pinned. The spacing must match the size the outputs
-- actually take: nested.sh floats each window on the host, which snaps it to
-- aquamarine's default 1280x720.
--
-- The monitors have to end up edge to edge. Spacing them out "safely" does not
-- work - Hyprland's inDirection monitor lookup does not cross a gap, so
-- `hy3:movetomonitor l|r` silently finds nothing while index-based `+1`/`-1`
-- keeps working, and every directional test fails for the wrong reason.
hl.monitor({ output = "WAYLAND-1", position = "0x0", scale = 1 })
hl.monitor({ output = "WAYLAND-2", position = "1280x0", scale = 1 })
hl.monitor({ output = "WAYLAND-3", position = "2560x0", scale = 1 })
hl.monitor({ output = "WAYLAND-4", position = "3840x0", scale = 1 })

-- One workspace on hyprland's built-in scrolling layout, so the suite has a
-- foreign-layout workspace to exercise plugin:hy3:layout_fallback against.
-- 9 is used by nothing else in the suite (1 and 7 are, plus the special
-- workspaces).
hl.workspace_rule({ workspace = "9", layout = "scrolling" })

-- escape hatch: the harness normally drives everything over hyprctl, but if the
-- instance is launched interactively these make it usable.
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("SUPER + SHIFT + E", hl.dsp.exit())

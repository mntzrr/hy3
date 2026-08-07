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

-- escape hatch: the harness normally drives everything over hyprctl, but if the
-- instance is launched interactively these make it usable.
hl.bind("SUPER + Q", hl.dsp.window.close())
hl.bind("SUPER + SHIFT + E", hl.dsp.exit())

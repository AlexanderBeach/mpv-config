-- video-effects: live picture adjustments for mpv (light, color, curves, levels) with a docked
-- panel and a live histogram. Toggle with Ctrl+E or from the right-click menu.
--
-- Adjustments last for the session: they carry across files and reset when mpv closes.
-- Requires vo=gpu-next (the effect is a libplacebo user shader with live parameters).
--
-- Scripted control (e.g. from input.conf):
--   script-message-to video_effects set <id> <value>      ids: exposure, brightness, contrast,
--   script-message-to video_effects adjust <id> <delta>        gamma, highlights, shadows, whites,
--   script-message-to video_effects reset [<id>|all]           blacks, saturation, vibrance, hue
--   script-message-to video_effects curve <rgb|r|g|b> <x,y;x,y;...>   (0..255)
--   script-message-to video_effects levels <rgb|r|g|b> <in-black> <in-white> <gamma> <out-black> <out-white>
--   script-message-to video_effects enable <yes|no|toggle>
--   script-binding video_effects/toggle
local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"
local utils = require "mp.utils"
local fx = require "fx"
local hist = require "histogram"
local ui = require "ui"

local o = {
    panel_width = 380,           -- panel width in pixels (before scaling)
    bottom_margin = 104,         -- space left free under the panel for the OSC (ModernZ's bar)
    top_margin = 50,             -- space left free above it in fullscreen/borderless (ModernZ's window controls)
    scale = 1.0,                 -- panel scale when windowed
    scale_fullscreen = 1.0,      -- panel scale in fullscreen
    accent = "#3584E4",          -- accent color (matches the ModernZ seekbar by default)
    font = "",                   -- empty = mpv's osd-font, like mpv's own menus
    mpv_path = "mpv",            -- mpv executable used to grab frames for the histogram
    histogram_interval = 2.0,    -- seconds between histogram updates while playing
    histogram_hwdec = "auto-copy",
}
options.read_options(o, "video_effects")

-- The histogram runs a second, hidden mpv. "mpv" is found next to this one on Windows and on PATH
-- elsewhere, but a macOS mpv.app usually isn't on PATH, so ask the system where this mpv is.
if o.mpv_path == "mpv" and mp.get_property("platform") == "darwin" then
    local r = mp.command_native({ name = "subprocess", args = { "ps", "-o", "comm=", "-p", tostring(utils.getpid()) },
                                  capture_stdout = true, playback_only = false })
    local path = r and r.status == 0 and (r.stdout or ""):gsub("%s+$", "") or ""
    if path:find("^/") then o.mpv_path = (path:gsub("/mpv%-bundle$", "/mpv")) end
end

local state = fx.new_state()
local video = { transfer = 0, luma = { 0.2126, 0.7152, 0.0722 } }
local shader_path
local shader_loaded = false

---------------------------------------------------------------------------------------------------
-- Shader

local function write_file(path, src)
    local f = io.open(path, "rb")
    local current = f and f:read("*a")
    if f then f:close() end
    if current == src then return true end
    local w, err = io.open(path, "wb")
    if not w then return false, err end
    w:write(src)
    w:close()
    return true
end

-- The shader goes next to this script; if the config folder is read-only, into the temp folder.
local temp_shader = utils.join_path(os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp",
                                    "mpv-video-effects-" .. utils.getpid() .. ".glsl")
local function write_shader()
    local src = fx.shader_source()
    local ok, err = write_file(utils.join_path(mp.get_script_directory(), "video-effects.glsl"), src)
    if ok then
        shader_path = utils.join_path(mp.get_script_directory(), "video-effects.glsl")
    elseif write_file(temp_shader, src) then
        shader_path = temp_shader
        mp.register_event("shutdown", function() os.remove(temp_shader) end)
    else
        msg.error("cannot write the effect shader: " .. tostring(err))
    end
end

local function update_histogram_adjusted()
    if hist.status ~= "ready" then return end
    local fn = not fx.is_neutral(state) and fx.make_pixel_fn(fx.params(state, video)) or nil
    hist.update(fn, video.luma)
    ui.redraw()
end

local hist_adjust_pending = false
local function schedule_histogram_adjusted()
    if hist_adjust_pending then return end
    hist_adjust_pending = true
    mp.add_timeout(0.1, function()
        hist_adjust_pending = false
        update_histogram_adjusted()
    end)
end

local apply_pending = false
local function apply()
    apply_pending = false
    local active = not fx.is_neutral(state)
    if active then
        local opts = mp.get_property_native("glsl-shader-opts") or {}
        for k, v in pairs(fx.shader_opts(fx.params(state, video))) do opts[k] = v end
        mp.set_property_native("glsl-shader-opts", opts)
        if not shader_loaded and shader_path then
            mp.commandv("change-list", "glsl-shaders", "append", shader_path)
            shader_loaded = true
        end
    elseif shader_loaded then
        mp.commandv("change-list", "glsl-shaders", "remove", shader_path)
        shader_loaded = false
    end
    mp.set_property_native("user-data/video_effects/active", active)
    schedule_histogram_adjusted()
end

-- Called whenever any value changes; coalesces bursts of mouse movement into one update per frame.
local function changed()
    if not apply_pending then
        apply_pending = true
        mp.add_timeout(1 / 120, apply)
    end
end

---------------------------------------------------------------------------------------------------
-- Video color information (decides how exposure linearizes and which luma weights to use).
-- video-out-params is what the renderer, and so the shader, actually receives (after filters).

local function update_video_params()
    local vp = mp.get_property_native("video-out-params") or {}
    local gamma, prim = vp.gamma or "", vp.primaries or ""
    video.transfer = (gamma == "pq" and 1) or (gamma == "hlg" and 2) or 0
    if prim == "bt.2020" or (vp.colormatrix or ""):find("bt.2020", 1, true) then
        video.luma = { 0.2627, 0.6780, 0.0593 }
    elseif prim:find("bt.601", 1, true) or prim == "bt.470m" then
        video.luma = { 0.299, 0.587, 0.114 }
    else
        video.luma = { 0.2126, 0.7152, 0.0722 }
    end
    changed()
end

---------------------------------------------------------------------------------------------------
-- Histogram scheduling (only while the panel is open)

local hist_timer
local function request_histogram(exact)
    if ui.is_open() then hist.request(exact) end
end

local seek_debounce
local function on_playback_restart()
    if not ui.is_open() then return end
    if seek_debounce then seek_debounce:kill() end
    seek_debounce = mp.add_timeout(0.15, function() request_histogram(mp.get_property_native("pause")) end)
end

local function on_open_changed(open)
    mp.set_property_native("user-data/video_effects/open", open)
    if open then
        request_histogram(mp.get_property_native("pause"))
        hist_timer = mp.add_periodic_timer(o.histogram_interval, function()
            if not mp.get_property_native("pause") then request_histogram(false) end
        end)
    elseif hist_timer then
        hist_timer:kill()
        hist_timer = nil
    end
end

hist.init(o, function(got_frame)
    if got_frame then update_histogram_adjusted() else ui.redraw() end
end)

-- The effect is a libplacebo shader with live parameters, which only vo=gpu-next can run.
local function supported()
    local vo = mp.get_property("current-vo")
    if vo == nil or vo == "gpu-next" then return true end   -- nil: no video output yet
    mp.osd_message("Video effects need vo=gpu-next (set it in mpv.conf).", 4)
    return false
end

---------------------------------------------------------------------------------------------------
-- Scripted control

local function find_slider(id)
    local d = fx.slider_by_id[id or ""]
    if not d then msg.warn("unknown adjustment: " .. tostring(id)) end
    return d
end

local function parse_points(text)
    local pts = {}
    for x, y in (text or ""):gmatch("(%d+)%s*,%s*(%d+)") do
        pts[#pts + 1] = { math.min(255, tonumber(x)), math.min(255, tonumber(y)) }
    end
    table.sort(pts, function(a, b) return a[1] < b[1] end)
    return #pts >= 2 and pts or nil
end

local commands = {
    set = function(id, value)
        local d = find_slider(id)
        local v = d and fx.parse_value(d, value or "")
        if v then state.values[id] = v end
    end,
    adjust = function(id, delta)
        local d = find_slider(id)
        if d and tonumber(delta) then
            state.values[id] = fx.clamp_value(d, state.values[id] + tonumber(delta), true)
            mp.osd_message(d.label .. ": " .. fx.format_value(d, state.values[id]))
        end
    end,
    reset = function(id)
        if not id or id == "all" then
            fx.reset_all(state)
        elseif fx.slider_by_id[id] then
            state.values[id] = fx.slider_by_id[id].default
        else
            fx.reset_section(state, id)
        end
    end,
    curve = function(ch, points)
        local pts = parse_points(points)
        if state.curves[ch or ""] and pts then state.curves[ch] = pts end
    end,
    levels = function(ch, ib, iw, g, ob, ow)
        local lv = state.levels[ch or ""]
        if not lv then return end
        lv.ib, lv.iw = tonumber(ib) or lv.ib, tonumber(iw) or lv.iw
        lv.g, lv.ob, lv.ow = tonumber(g) or lv.g, tonumber(ob) or lv.ob, tonumber(ow) or lv.ow
    end,
    enable = function(how)
        if how == "toggle" then state.enabled = not state.enabled else state.enabled = how ~= "no" end
    end,
    section = function(id, how)
        if how == "on" or how == "off" then state.section_on[id] = how == "on" else ui.set_section(id, how == "open") end
    end,
    channel = function(which, ch) ui.set_channel(which, ch) end,
    ["histogram-mode"] = function(m) ui.set_hist_mode(m) end,
    ["select-point"] = function(i) ui.select_point(tonumber(i)) end,
    open = function() if supported() then ui.open() end end,
    close = function() ui.close() end,
}

for name, fn in pairs(commands) do
    mp.register_script_message(name, function(...)
        fn(...)
        changed()
        ui.redraw()
    end)
end

---------------------------------------------------------------------------------------------------

write_shader()
ui.init({ state = state, hist = hist, opts = o, changed = changed, on_open_changed = on_open_changed })
mp.set_property_native("user-data/video_effects/open", false)
mp.set_property_native("user-data/video_effects/active", false)

mp.add_key_binding("ctrl+e", "toggle", function()
    if mp.get_property_native("user-data/video_effects/open") or supported() then ui.toggle() end
end)
mp.observe_property("video-out-params", "native", update_video_params)
mp.observe_property("pause", "bool", function(_, paused)
    if paused then request_histogram(true) end
end)
mp.register_event("file-loaded", function()
    hist.reset()
    ui.redraw()
end)
mp.register_event("playback-restart", on_playback_restart)
mp.register_event("shutdown", function()
    hist.cleanup()
    if shader_loaded then mp.commandv("change-list", "glsl-shaders", "remove", shader_path) end
end)

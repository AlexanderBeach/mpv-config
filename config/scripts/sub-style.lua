-- sub-style: a panel for the look of subtitles: font, size, color, outline, shadow or box, and
-- position. Toggle with Ctrl+T or from the right-click menu (Subtitle > Style).
--
-- Changes are saved in sub-style.json in mpv's state folder and applied every time mpv starts.
-- Reset goes back to the subtitle settings in mpv.conf. Subtitles with their own styling (many
-- .ass files) keep it unless "Styled subtitles too" is on.
--
-- Scripted control (e.g. from input.conf):
--   script-binding sub_style/toggle
--   script-message-to sub_style set <id> <value>     ids: font, size, bold, italic, color, outline,
--   script-message-to sub_style reset [<id>|all]          outline_color, behind, shadow, back_color,
--   script-message-to sub_style enable <yes|no|toggle>    back_opacity, height, styled
--   script-message-to sub_style open|close
local mp = require "mp"
local input = require "mp.input"
local options = require "mp.options"
package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua;" }) .. package.path
local panel = require "kit.panel"
local fonts = require "kit.fonts"
local state = require "kit.state"

local o = {
    panel_width = 380,           -- panel width in pixels (before scaling)
    bottom_margin = 104,         -- space left free under the panel for the OSC (ModernZ's bar)
    top_margin = 50,             -- space left free above it in fullscreen/borderless (ModernZ's window controls)
    scale = 1.0,                 -- panel scale when windowed
    scale_fullscreen = 1.0,      -- panel scale in fullscreen
    accent = "#3584E4",          -- accent color (matches the ModernZ seekbar by default)
    font = "",                   -- empty = mpv's osd-font, like mpv's own menus
    sample = true,               -- while the panel is open, show a sample line on videos without subtitles
}
options.read_options(o, "sub_style")

local FILE = "sub-style.json"
local SAMPLE = "You said we'd be back by Friday.\n<i>That was before the bridge washed out \226\128\148 3 days ago!</i>"
local TEXT_COLORS = { "#FFFFFF", "#FFE45C", "#D0D0D0", "#8FD3FF", "#A6E3A1", "#FFB3C1" }
local DARK_COLORS = { "#000000", "#3A3A3A", "#1B2A4A", "#4A1B1B" }
local PROPS = { "sub-font", "sub-font-size", "sub-scale", "sub-bold", "sub-italic", "sub-color", "sub-outline-size",
                "sub-outline-color", "sub-border-style", "sub-shadow-offset", "sub-back-color", "sub-pos", "sub-ass-override" }

local base         -- the settings from mpv.conf in the panel's terms, once the font list is resolved
local style = {}   -- what differs from them; this is what gets saved
local enabled = true
local sample_id
local K

local function round(v) return math.floor(v + 0.5) end

---------------------------------------------------------------------------------------------------
-- Values

-- mpv colors are "#AARRGGBB" or "#RRGGBB"; the panel works with "#RRGGBB" plus an opacity.
local function split_color(c)
    local hex = (c or ""):gsub("#", ""):upper()
    if #hex == 8 then return "#" .. hex:sub(3), tonumber(hex:sub(1, 2), 16) / 255 end
    if #hex == 6 then return "#" .. hex, 1 end
    return "#FFFFFF", 1
end

local function join_color(rgb, opacity)
    return string.format("#%02X%s", round(math.max(0, math.min(1, opacity)) * 255), rgb:sub(2))
end

-- "#RRGGBB" from typed text, or nil.
local function parse_color(text)
    local hex = text:match("^%s*#?(%x%x%x%x%x%x)%s*$")
    return hex and "#" .. hex:upper()
end

local function read_base()
    local raw = {}
    for _, p in ipairs(PROPS) do raw[p] = mp.get_property(p) end
    local color, color_a = split_color(raw["sub-color"])
    local outline_color, outline_a = split_color(raw["sub-outline-color"])
    local back, back_a = split_color(raw["sub-back-color"])
    local offset = tonumber(raw["sub-shadow-offset"]) or 0
    base = {
        raw = raw, color_alpha = color_a, outline_alpha = outline_a,
        font = raw["sub-font"], font_size = tonumber(raw["sub-font-size"]) or 38,
        size = round((tonumber(raw["sub-scale"]) or 1) * 100),
        bold = raw["sub-bold"] == "yes", italic = raw["sub-italic"] == "yes",
        color = color, outline = tonumber(raw["sub-outline-size"]) or 0, outline_color = outline_color,
        behind = raw["sub-border-style"] ~= "outline-and-shadow" and "box" or (offset > 0 and "shadow" or "none"),
        shadow = offset > 0 and offset or 1.5,
        back_color = back, back_opacity = round(back_a * 100),
        height = round(100 - (tonumber(raw["sub-pos"]) or 100)),
        styled = raw["sub-ass-override"] == "force",
    }
end

local function value(id)
    if style[id] ~= nil then return style[id] end
    return base[id]
end

local function differs(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) > 1e-6 end
    if type(a) == "string" and type(b) == "string" then return a:upper() ~= b:upper() end
    return a ~= b
end

local function changed(id) return style[id] ~= nil end

local function font_size(font)
    if font == base.font then return base.font_size end
    for _, f in ipairs(fonts.SIZES) do
        if f[1] == font then return f[2] end
    end
    return base.font_size
end

-- Properties whose fields are unchanged get mpv.conf's own values back, so Reset is exact.
local function apply()
    if not base then return end
    local set = {}
    for _, p in ipairs(PROPS) do set[p] = base.raw[p] end
    if enabled then
        if changed("font") then set["sub-font"], set["sub-font-size"] = value("font"), font_size(value("font")) end
        if changed("size") then set["sub-scale"] = value("size") / 100 end
        if changed("bold") then set["sub-bold"] = value("bold") and "yes" or "no" end
        if changed("italic") then set["sub-italic"] = value("italic") and "yes" or "no" end
        if changed("color") then set["sub-color"] = join_color(value("color"), base.color_alpha) end
        if changed("outline") then set["sub-outline-size"] = value("outline") end
        if changed("outline_color") then set["sub-outline-color"] = join_color(value("outline_color"), base.outline_alpha) end
        if changed("behind") or changed("shadow") then
            local behind = value("behind")
            set["sub-border-style"] = behind == "box" and "background-box" or "outline-and-shadow"
            set["sub-shadow-offset"] = behind == "shadow" and value("shadow") or 0
        end
        if changed("back_color") or changed("back_opacity") then
            set["sub-back-color"] = join_color(value("back_color"), value("back_opacity") / 100)
        end
        if changed("height") then set["sub-pos"] = 100 - value("height") end
        if changed("styled") then set["sub-ass-override"] = value("styled") and "force" or "scale" end
    end
    for _, p in ipairs(PROPS) do mp.set_property(p, tostring(set[p])) end
end

local save_timer
local function save()
    if save_timer then save_timer:kill(); save_timer = nil end
    state.write(FILE, { enabled = enabled, style = style })
end

local function on_changed()
    apply()
    if not save_timer then save_timer = mp.add_timeout(0.5, save) end
end

-- Keeps only what differs from mpv.conf, so the saved file stays small and Reset is exact.
local function set_field(id, v)
    if differs(v, base[id]) then style[id] = v else style[id] = nil end
end

---------------------------------------------------------------------------------------------------
-- Panel contents

local u, ev, D, COL   -- from the panel, set when it's made

local SLIDERS = {
    size = { id = "size", label = "Size", min = 50, max = 200, step = 5, fine = 1, unit = "%" },
    outline = { id = "outline", label = "Width", min = 0, max = 6, step = 0.25, fine = 0.05 },
    shadow = { id = "shadow", label = "Distance", min = 0, max = 6, step = 0.25, fine = 0.05 },
    back_opacity = { id = "back_opacity", label = "Opacity", min = 0, max = 100, step = 5, fine = 1, unit = "%" },
    height = { id = "height", label = "Height", min = 0, max = 50, step = 1, fine = 1, unit = "%" },
}

local SECTION_FIELDS = {
    text = { "font", "size", "bold", "italic", "color" },
    outline = { "outline", "outline_color" },
    background = { "behind", "shadow", "back_color", "back_opacity" },
    position = { "height" },
}
local FIELDS = { styled = true }
for _, ids in pairs(SECTION_FIELDS) do for _, id in ipairs(ids) do FIELDS[id] = true end end

local function number_text(d, v)
    if d.unit then return round(v) .. d.unit end
    return (string.format("%.2f", v):gsub("0$", ""):gsub("%.0$", ""))
end

local function format_slider(d, v)
    if d.id == "height" and round(v) == 0 then return "Bottom" end
    return number_text(d, v)
end

local function clamp_slider(d, v, fine)
    local step = fine and d.fine or d.step
    v = math.max(d.min, math.min(d.max, v))
    return round(v / step) * step
end

local function icon_subtitles(_, cx, cy)
    local acc = K.accent_text
    ev(D.outline(D.rrect_path(cx - u(8.5), cy - u(6.5), cx + u(8.5), cy + u(6.5), u(2.5)), u(1.6), acc, 1))
    K.strokes({ { { cx - u(5), cy + u(1.5) }, { cx + u(1), cy + u(1.5) } },
                { { cx + u(3), cy + u(1.5) }, { cx + u(5), cy + u(1.5) } },
                { { cx - u(5), cy - u(2) }, { cx - u(2.5), cy - u(2) } },
                { { cx - u(0.5), cy - u(2) }, { cx + u(5), cy - u(2) } } }, u(1.6), acc, 1, true)
end

local function icon_text(cx, cy, col, op)
    K.strokes({ { { cx - u(5.5), cy - u(5.5) }, { cx + u(5.5), cy - u(5.5) } } }, u(1.6), col, op)
    K.strokes({ { { cx, cy - u(5.5) }, { cx, cy + u(6) } } }, u(1.6), col, op)
end

local function icon_outline(cx, cy, col, op)
    K.ring(cx, cy, u(6.5), u(1.4), col, op)
    ev(D.circle(cx, cy, u(3), col, op))
end

local function icon_background(cx, cy, col, op)
    ev(D.rect(cx - u(7), cy - u(5), cx + u(7), cy + u(5), col, op * 0.35, u(2)))
    K.strokes({ { { cx - u(4), cy }, { cx + u(4), cy } } }, u(1.6), col, op)
end

local function icon_position(cx, cy, col, op)
    K.strokes({ { { cx, cy - u(6) }, { cx, cy + u(6) } },
                { { cx - u(3.5), cy - u(2.5) }, { cx, cy - u(6) }, { cx + u(3.5), cy - u(2.5) } } }, u(1.5), col, op)
    K.strokes({ { { cx - u(6), cy + u(6) }, { cx + u(6), cy + u(6) } } }, u(1.5), col, op)
end

local SECTIONS = {
    { id = "text", label = "Text", icon = icon_text },
    { id = "outline", label = "Outline", icon = icon_outline },
    { id = "background", label = "Background", icon = icon_background },
    { id = "position", label = "Position", icon = icon_position },
}

local function draw_section(sec, y, x0, x1, dim)
    y = y + u(6)
    local id = sec.id
    if id == "text" then
        y = K.draw_choice("font", "Font", value("font"), changed("font"), y, x0, x1, dim)
        y = K.draw_slider(SLIDERS.size, y, x0, x1, dim)
        y = K.draw_toggle("bold", "Bold", value("bold"), changed("bold"), y, x0, x1, dim)
        y = K.draw_toggle("italic", "Italic", value("italic"), changed("italic"), y, x0, x1, dim)
        y = K.draw_swatches("color", "Color", TEXT_COLORS, value("color"), changed("color"), y, x0, x1, dim)
    elseif id == "outline" then
        y = K.draw_slider(SLIDERS.outline, y, x0, x1, dim)
        y = K.draw_swatches("outline_color", "Color", DARK_COLORS, value("outline_color"), changed("outline_color"), y, x0, x1, dim)
    elseif id == "background" then
        local behind = value("behind")
        y = K.draw_segments("behind", "Behind text", { { "none", "None" }, { "shadow", "Shadow" }, { "box", "Box" } },
                            behind, y, x0, x1, dim)
        if behind == "shadow" then y = K.draw_slider(SLIDERS.shadow, y, x0, x1, dim) end
        if behind ~= "none" then
            y = K.draw_swatches("back_color", "Color", DARK_COLORS, value("back_color"), changed("back_color"), y, x0, x1, dim)
            y = K.draw_slider(SLIDERS.back_opacity, y, x0, x1, dim)
        end
    else
        y = K.draw_slider(SLIDERS.height, y, x0, x1, dim)
    end
    return y + u(8)
end

local function draw_footer(y, x0, x1)
    y = K.draw_toggle("styled", "Styled subtitles too", value("styled"), changed("styled"), y + u(6), x0, x1)
    ev(D.text(x0 + u(18), y + u(2), 7, u(12.5), "Also restyles .ass subtitles that have their own style.",
              COL.white, 0.45, false, K.font))
    return y + u(28)
end

local function pick_font()
    local names, seen = {}, {}
    local function add(name)
        if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
    end
    add(base.font)
    for _, f in ipairs(fonts.SIZES) do
        if fonts.installed(f[1]) then add(f[1]) end
    end
    local current = 1
    for i, n in ipairs(names) do if n == value("font") then current = i end end
    input.select({
        prompt = "Subtitle font:",
        items = names,
        default_item = current,
        submit = function(i)
            set_field("font", names[i])
            K.changed()
        end,
    })
end

local function pick_color(id)
    local labels = { color = "Text color", outline_color = "Outline color", back_color = "Background color" }
    K.prompt(labels[id] .. " (#RRGGBB):", value(id), function(text)
        local rgb = parse_color(text)
        if rgb then
            set_field(id, rgb)
            K.changed()
        end
    end)
end

local function click(r)
    local k = r.kind
    if k == "choice" then pick_font()
    elseif k == "toggle" then set_field(r.id, not value(r.id)); K.changed()
    elseif k == "segment" then set_field(r.id, r.value); K.changed()
    elseif k == "swatch" then
        if r.value == "custom" then pick_color(r.id) else set_field(r.id, r.value); K.changed() end
    end
end

local function count_changed(section)
    local n = 0
    for _, id in ipairs(SECTION_FIELDS[section]) do if changed(id) then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------------------------------
-- A sample line, so there is something to look at on videos without subtitles

local function add_sample()
    if not o.sample or sample_id or mp.get_property("sid", "no") ~= "no" then return end
    if not mp.get_property("path") then return end
    local srt = "1\n00:00:00,000 --> 99:59:59,000\n" .. SAMPLE .. "\n"
    mp.commandv("sub-add", "memory://" .. srt, "select", "Style sample")
    sample_id = mp.get_property_number("sid")
end

local function remove_sample()
    if sample_id then
        mp.commandv("sub-remove", tostring(sample_id))
        sample_id = nil
    end
end

---------------------------------------------------------------------------------------------------

local function ensure_base()
    if not base then
        read_base()
        if not enabled or next(style) then apply() end
    end
end

K = panel.new({
    name = "sub_style",
    title = "Subtitle style",
    icon = icon_subtitles,
    opts = o,
    sections = SECTIONS,
    expanded = { text = true, outline = true, background = true, position = true },
    section_info = function(id)
        local n = count_changed(id)
        return nil, n, n .. " changed"
    end,
    enabled = function() return enabled end,
    any_changed = function() return next(style) ~= nil end,
    draw_section = draw_section,
    draw_footer = draw_footer,
    slider = {
        get = function(d) return value(d.id) end,
        set = function(d, v) set_field(d.id, v) end,
        changed = function(d) return changed(d.id) end,
        format = format_slider,
        edit_text = number_text,
        clamp = clamp_slider,
        parse = function(d, text)
            local n = tonumber((text:gsub(",", ".")):match("[-+]?%d*%.?%d+"))
            return n and clamp_slider(d, n, true)
        end,
    },
    switch = function() enabled = not enabled end,
    reset_all = function() style = {} end,
    section_reset = function(id)
        for _, f in ipairs(SECTION_FIELDS[id]) do style[f] = nil end
    end,
    click = click,
    changed = on_changed,
    on_open_changed = function(open)
        mp.set_property_native("user-data/sub_style/open", open)
        if open then add_sample() else remove_sample() end
    end,
})
u, ev, D, COL = K.u, K.ev, K.D, K.COL
K.init()

local function open()
    ensure_base()
    for id, d in pairs(SLIDERS) do d.default = base[id] end
    K.open()
end

local function toggle()
    if K.is_open() then K.close() else open() end
end

local commands = {
    set = function(id, v)
        if not FIELDS[id] or v == nil then return end
        local kind = type(base[id])
        if kind == "number" then v = tonumber(v)
        elseif kind == "boolean" then v = v == "yes" or v == "true"
        elseif id:find("color") then v = parse_color(v)
        elseif id == "behind" and not (v == "none" or v == "shadow" or v == "box") then v = nil end
        if v ~= nil then set_field(id, v) end
    end,
    reset = function(id)
        if not id or id == "all" then style = {} else style[id] = nil end
    end,
    enable = function(how)
        if how == "toggle" then enabled = not enabled else enabled = how ~= "no" end
    end,
    open = function() open() end,
    close = function() K.close() end,
}
for name, fn in pairs(commands) do
    mp.register_script_message(name, function(...)
        ensure_base()
        fn(...)
        if name ~= "open" and name ~= "close" then on_changed() end
        K.redraw()
    end)
end

local saved = state.read(FILE)
if saved then
    enabled = saved.enabled ~= false
    -- Copied field by field: a nested table from the file keeps its JSON type, and an empty style
    -- is saved as [].
    for k, v in pairs(type(saved.style) == "table" and saved.style or {}) do style[k] = v end
end
mp.set_property_native("user-data/sub_style/open", false)
mp.add_key_binding("ctrl+t", "toggle", toggle)

-- mpv.conf's settings are read once font-fallback.lua has turned the sub-font list into one font;
-- the saved changes are then applied on top of them.
mp.observe_property("sub-font", "string", function(_, v)
    if not base and v and not v:find("[,(]") then ensure_base() end
end)
-- Size and height also change with keys and the menu (Smaller/Larger, mpv's r/R and F/G); keep
-- those changes instead of undoing them on the next edit.
local KEPT = { ["sub-scale"] = { "size", function(v) return round(v * 100) end },
               ["sub-pos"] = { "height", function(v) return round(100 - v) end } }
for prop, f in pairs(KEPT) do
    mp.observe_property(prop, "number", function(_, v)
        if not base or not enabled or v == nil then return end
        local now = f[2](v)
        if differs(now, value(f[1])) then
            set_field(f[1], now)
            if not save_timer then save_timer = mp.add_timeout(0.5, save) end
            K.redraw()
        end
    end)
end
mp.register_event("start-file", ensure_base)
mp.register_event("file-loaded", function() if K.is_open() then add_sample() end end)
mp.register_event("end-file", function() sample_id = nil end)
mp.register_event("shutdown", function()
    remove_sample()
    if save_timer then save() end
end)

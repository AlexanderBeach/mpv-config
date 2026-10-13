-- Docked effects panel: layout, drawing, hit-testing and mouse handling.
--
-- Look: mpv's own menu surface (#222222, OSD font, 5px corners, inverted white selection) with the
-- ModernZ accent. Layout cues: Lumetri/Lightroom-style collapsible sections with per-section
-- on/off and reset, Photoshop-style curves and levels, and a Lightroom-style histogram with
-- clipping indicators.
local mp = require "mp"
local input = require "mp.input"
local D = require "draw"
local fx = require "fx"

local UI = {}

local INPUT_SECTION = "video_effects_input"
local overlay = mp.create_osd_overlay("ass-events")

local ctx
local font = "sans-serif"
local accent, accent_text = "#3584E4", "#72A9EC"

local COL = {
    bg = "#222222", header = "#2A2A2A", header_hover = "#323232",
    white = "#FFFFFF", black = "#000000",
    red = "#E5484D", green = "#46A758", blue = "#3E8EED",
}
local CH_COLOR = { rgb = "#FFFFFF", r = COL.red, g = COL.green, b = COL.blue }

local SECTIONS = {
    { id = "light", label = "Light" },
    { id = "color", label = "Color" },
    { id = "curves", label = "Curves" },
    { id = "levels", label = "Levels" },
}

local ui = {
    open = false, w = 0, h = 0, s = 1,
    expanded = { light = true, color = true, curves = false, levels = false },
    curve_ch = "rgb", level_ch = "rgb", sel_point = nil,
    hist_mode = "luma",
    scroll = 0, scrollable = 0,
    regions = {}, hover = nil, press = nil, drag = nil,
    redraw_pending = false, saved_margin = nil, panel = nil,
}
local events, clip_box = {}, nil

local function u(v) return v * ui.s end
local function ev(e) events[#events + 1] = e end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round(v) return math.floor(v + 0.5) end

---------------------------------------------------------------------------------------------------
-- Regions (click/drag targets), rebuilt on every render

local function add_region(x0, y0, x1, y1, kind, data)
    if clip_box then
        y0, y1 = math.max(y0, clip_box[2]), math.min(y1, clip_box[4])
        if y1 <= y0 then return end
    end
    local r = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, kind = kind }
    for k, v in pairs(data or {}) do r[k] = v end
    ui.regions[#ui.regions + 1] = r
end

local function hit(x, y)
    for i = #ui.regions, 1, -1 do
        local r = ui.regions[i]
        if x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1 then return r end
    end
end

local function same(a, b) return a and b and a.kind == b.kind and a.id == b.id end
local function is_hover(kind, id) return ui.hover and ui.hover.kind == kind and ui.hover.id == id end

local function mouse_pos()
    local p = mp.get_property_native("mouse-pos")
    if not p then return -1, -1 end
    return p.x, p.y
end

---------------------------------------------------------------------------------------------------
-- Small drawing pieces

-- Strokes that may cross (like an X) each get their own event, because overlapping parts of one
-- ASS drawing cancel out. combine = true batches strokes known not to overlap (dashes, rays).
local function strokes(polylines, w, col, op, combine)
    if combine then
        local parts = {}
        for _, pts in ipairs(polylines) do parts[#parts + 1] = D.polyline_path(pts, w) end
        ev(D.fill(table.concat(parts, " "), col, op))
    else
        for _, pts in ipairs(polylines) do ev(D.fill(D.polyline_path(pts, w), col, op)) end
    end
end

local function ring(cx, cy, r, w, col, op)
    ev(D.outline(D.circle_path(cx, cy, r - w / 2), w, col, op))
end

local function hover_bg(x0, y0, x1, y1, on)
    if on then ev(D.rect(x0, y0, x1, y1, COL.white, 0.1, u(5))) end
end

local function hsv(h, s, v)
    local i = math.floor(h * 6) % 6
    local f = h * 6 - math.floor(h * 6)
    local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    local r, g, b
    if i == 0 then r, g, b = v, t, p elseif i == 1 then r, g, b = q, v, p
    elseif i == 2 then r, g, b = p, v, t elseif i == 3 then r, g, b = p, q, v
    elseif i == 4 then r, g, b = t, p, v else r, g, b = v, p, q end
    return string.format("#%02X%02X%02X", round(r * 255), round(g * 255), round(b * 255))
end

local function ramp(x, y, w, h, vertical, steps)
    steps = steps or 64
    for i = 0, steps - 1 do
        local v = i / (steps - 1)
        if vertical then
            local y0 = y + h - (i + 1) * h / steps
            ev(D.rect(x, y0, x + w, y0 + h / steps + 0.6, D.grey(v), 1))
        else
            local x0 = x + i * w / steps
            ev(D.rect(x0, y, x0 + w / steps + 0.6, y + h, D.grey(v), 1))
        end
    end
end

-- Icons, drawn around a centre point ------------------------------------------------------------

local function icon_chevron(cx, cy, open, col, op)
    local a = u(3.6)
    local pts = open and { { cx - a, cy - a / 2 }, { cx, cy + a / 2 }, { cx + a, cy - a / 2 } }
                      or { { cx - a / 2, cy - a }, { cx + a / 2, cy }, { cx - a / 2, cy + a } }
    strokes({ pts }, u(1.6), col, op)
end

local function icon_close(cx, cy, col, op)
    local a = u(5)
    strokes({ { { cx - a, cy - a }, { cx + a, cy + a } }, { { cx + a, cy - a }, { cx - a, cy + a } } }, u(1.6), col, op)
end

local function icon_reset(cx, cy, col, op, size)
    local r = u(size or 5.5)
    local pts = {}
    for i = 0, 20 do
        local a = math.rad(-60 - i * 13.5)   -- a 270 degree arc, counter-clockwise from the top right
        pts[#pts + 1] = { cx + math.cos(a) * r, cy + math.sin(a) * r }
    end
    local tip = pts[1]
    local ah = r * 0.75
    strokes({ pts, { { tip[1] - ah, tip[2] - ah * 0.15 }, tip, { tip[1] - ah * 0.1, tip[2] + ah * 0.85 } } },
            u(1.5), col, op)
end

local function icon_sun(cx, cy, col, op)
    ring(cx, cy, u(3.4), u(1.4), col, op)
    local rays = {}
    for i = 0, 7 do
        local a = i * math.pi / 4
        rays[#rays + 1] = { { cx + math.cos(a) * u(5.6), cy + math.sin(a) * u(5.6) },
                            { cx + math.cos(a) * u(7.4), cy + math.sin(a) * u(7.4) } }
    end
    strokes(rays, u(1.4), col, op, true)
end

local function icon_drop(cx, cy, col, op)
    local s = ui.s
    local function p(x, y) return string.format("%.2f %.2f", cx + x * s, cy + y * s) end
    local path = "m " .. p(0, -6.6) .. " b " .. p(2.4, -3.4) .. " " .. p(4.6, -0.8) .. " " .. p(4.6, 1.8)
              .. " b " .. p(4.6, 4.4) .. " " .. p(2.6, 6.4) .. " " .. p(0, 6.4)
              .. " b " .. p(-2.6, 6.4) .. " " .. p(-4.6, 4.4) .. " " .. p(-4.6, 1.8)
              .. " b " .. p(-4.6, -0.8) .. " " .. p(-2.4, -3.4) .. " " .. p(0, -6.6)
    ev(D.outline(path, u(1.4), col, op))
end

local function icon_curves(cx, cy, col, op)
    ev(D.outline(D.rrect_path(cx - u(6.3), cy - u(6.3), cx + u(6.3), cy + u(6.3), u(1.5)), u(1.2), col, op * 0.45))
    local pts = {}
    for i = 0, 12 do
        local t = i / 12
        local y = t < 0.5 and 2 * t * t or 1 - 2 * (1 - t) ^ 2
        pts[#pts + 1] = { cx - u(6) + t * u(12), cy + u(6) - y * u(12) }
    end
    strokes({ pts }, u(1.5), col, op)
end

local function icon_levels(cx, cy, col, op)
    local bars = { { -5.4, 3 }, { -1.8, 8 }, { 1.8, 5.5 }, { 5.4, 2.5 } }
    for _, b in ipairs(bars) do
        ev(D.rect(cx + u(b[1] - 1.2), cy + u(3) - u(b[2]), cx + u(b[1] + 1.2), cy + u(3), col, op))
    end
    ev(D.rect(cx - u(7), cy + u(4.6), cx + u(7), cy + u(5.8), col, op))
end

local function icon_eye(cx, cy, on, col, op)
    local s = ui.s
    local function p(x, y) return string.format("%.2f %.2f", cx + x * s, cy + y * s) end
    local path = "m " .. p(-7, 0) .. " b " .. p(-4.5, -4.6) .. " " .. p(4.5, -4.6) .. " " .. p(7, 0)
              .. " b " .. p(4.5, 4.6) .. " " .. p(-4.5, 4.6) .. " " .. p(-7, 0)
    ev(D.outline(path, u(1.3), col, op))
    if on then
        ev(D.circle(cx, cy, u(2.3), col, op))
    else
        strokes({ { { cx - u(6), cy + u(5.5) }, { cx + u(6), cy - u(5.5) } } }, u(1.4), col, op)
    end
end

local SECTION_ICON = { light = icon_sun, color = icon_drop, curves = icon_curves, levels = icon_levels }

---------------------------------------------------------------------------------------------------
-- Histogram

local function hist_scale(...)
    local peak = 0
    for _, t in ipairs({ ... }) do
        for i = 2, #t - 1 do if t[i] > peak then peak = t[i] end end
    end
    return peak > 0 and 0.9 / peak or 0
end

local function hist_path(bins, x, y, w, h, scale)
    local pts = { { x, y + h } }
    local nb = #bins
    for i = 1, nb do
        pts[#pts + 1] = { x + (i - 0.5) * w / nb, y + h - math.min(1, bins[i] * scale) * h }
    end
    pts[#pts + 1] = { x + w, y + h }
    return D.poly_path(pts)
end

local function bins_for(set, ch)
    return set[ch == "rgb" and "l" or ch]
end

---------------------------------------------------------------------------------------------------
-- Panel parts. Each takes the panel's x range and a top y, and returns the next y.

local function draw_header(x0, x1, y0)
    local st = ctx.state
    local hh = u(52)
    local cy = y0 + hh / 2

    local ix = x0 + u(25)
    strokes({ { { ix - u(8), cy - u(4) }, { ix + u(8), cy - u(4) } },
              { { ix - u(8), cy + u(4) }, { ix + u(8), cy + u(4) } } }, u(1.6), accent_text, 1)
    ev(D.circle(ix - u(3), cy - u(4), u(2.8), accent_text, 1))
    ev(D.circle(ix + u(3), cy + u(4), u(2.8), accent_text, 1))
    ev(D.text(x0 + u(43), cy, 4, u(17), "Video effects", COL.white, 1, true, font))

    local cx1 = x1 - u(10)
    local cx0 = cx1 - u(30)
    hover_bg(cx0, cy - u(15), cx1, cy + u(15), is_hover("close", "close"))
    icon_close((cx0 + cx1) / 2, cy, COL.white, 0.85)
    add_region(cx0, cy - u(16), cx1, cy + u(16), "close", { id = "close" })

    local rx1 = cx0 - u(2)
    local rx0 = rx1 - u(30)
    local any = not fx.is_neutral({ enabled = true, values = st.values, levels = st.levels, curves = st.curves,
                                    section_on = { light = true, color = true, curves = true, levels = true } })
    hover_bg(rx0, cy - u(15), rx1, cy + u(15), is_hover("reset_all", "reset_all"))
    icon_reset((rx0 + rx1) / 2, cy, COL.white, any and 0.85 or 0.3)
    add_region(rx0, cy - u(16), rx1, cy + u(16), "reset_all", { id = "reset_all" })

    local on = st.enabled
    local lx1 = rx0 - u(10)
    ev(D.text(lx1, cy, 6, u(13), on and "On" or "Off", COL.white, 0.72, false, font))
    local px1 = lx1 - u(27)
    local px0 = px1 - u(32)
    ev(D.rect(px0, cy - u(9), px1, cy + u(9), on and accent or COL.white, on and 1 or 0.22, u(9)))
    ev(D.circle(on and (px1 - u(9)) or (px0 + u(9)), cy, u(6.5), COL.white, 1))
    add_region(px0 - u(4), cy - u(16), lx1 + u(2), cy + u(16), "switch", { id = "switch" })

    ev(D.rect(x0 + 1, y0 + hh - 1, x1, y0 + hh, COL.white, 0.07))
    return y0 + hh
end

local function draw_histogram(x0, x1, y)
    local H = ctx.hist
    local bx0, bx1 = x0 + u(16), x1 - u(16)
    local by0 = y + u(14)
    local bw, bh = bx1 - bx0, u(96)
    local by1 = by0 + bh
    ev(D.rect(bx0, by0, bx1, by1, COL.black, 0.4, u(5)))
    for q = 1, 3 do
        local gx = bx0 + bw * q / 4
        ev(D.rect(gx, by0 + u(5), gx + math.max(1, u(1)), by1 - u(5), COL.white, 0.06))
    end

    if H.status == "ready" and H.orig.l then
        if ui.hist_mode == "rgb" then
            local sc = hist_scale(H.adj.r, H.adj.g, H.adj.b, H.orig.l)
            ev(D.fill(hist_path(H.adj.r, bx0, by0, bw, bh, sc), COL.red, 0.42))
            ev(D.fill(hist_path(H.adj.g, bx0, by0, bw, bh, sc), COL.green, 0.42))
            ev(D.fill(hist_path(H.adj.b, bx0, by0, bw, bh, sc), COL.blue, 0.48))
            ev(D.outline(hist_path(H.orig.l, bx0, by0, bw, bh, sc), u(1), COL.white, 0.4))
        else
            local sc = hist_scale(H.adj.l, H.orig.l)
            ev(D.fill(hist_path(H.orig.l, bx0, by0, bw, bh, sc), COL.white, 0.1))
            ev(D.outline(hist_path(H.orig.l, bx0, by0, bw, bh, sc), u(1), COL.white, 0.3))
            ev(D.fill(hist_path(H.adj.l, bx0, by0, bw, bh, sc), COL.white, 0.55))
        end
        -- Lightroom-style clipping indicators: light up when shadows or highlights clip
        local l = H.adj.l
        local total = 0
        for i = 1, #l do total = total + l[i] end
        local lo, hi = total > 0 and l[1] / total > 0.003, total > 0 and l[#l] / total > 0.003
        local t, m = u(7), u(5)
        ev(D.fill(D.poly_path({ { bx0 + m, by0 + m }, { bx0 + m + t, by0 + m }, { bx0 + m, by0 + m + t } }),
                  lo and accent_text or COL.white, lo and 1 or 0.22))
        ev(D.fill(D.poly_path({ { bx1 - m, by0 + m }, { bx1 - m - t, by0 + m }, { bx1 - m, by0 + m + t } }),
                  hi and accent_text or COL.white, hi and 1 or 0.22))
    else
        local text = ({ loading = "Reading the current frame\226\128\166",
                        unavailable = "No histogram for this source" })[H.status] or "The histogram appears when a video plays"
        ev(D.text((bx0 + bx1) / 2, (by0 + by1) / 2, 5, u(13), text, COL.white, 0.45, false, font))
    end

    local ly = by1 + u(16)
    if ui.hist_mode == "rgb" then
        for i, c in ipairs({ COL.red, COL.green, COL.blue }) do
            local sx = bx0 + (i - 1) * u(4)
            ev(D.rect(sx, ly - u(5), sx + u(4), ly + u(5), c, 0.9))
        end
    else
        ev(D.rect(bx0, ly - u(5), bx0 + u(10), ly + u(5), COL.white, 0.55, u(2)))
    end
    ev(D.text(bx0 + u(16), ly, 4, u(13), "Adjusted", COL.white, 0.62, false, font))
    local ox = bx0 + u(92)
    ev(D.outline(D.rect_path(ox + u(1), ly - u(4), ox + u(9), ly + u(4)), u(1), COL.white, 0.45))
    ev(D.text(ox + u(16), ly, 4, u(13), "Original", COL.white, 0.62, false, font))

    -- Luma / RGB switch, in the menu's style: the selected item is inverted
    local mx1 = bx1
    for _, m in ipairs({ { "rgb", "RGB", u(40) }, { "luma", "Luma", u(46) } }) do
        local mx0 = mx1 - m[3]
        local sel = ui.hist_mode == m[1]
        if sel then
            ev(D.rect(mx0, ly - u(10), mx1, ly + u(10), COL.white, 1, u(5)))
        elseif is_hover("hist_mode", m[1]) then
            ev(D.rect(mx0, ly - u(10), mx1, ly + u(10), COL.white, 0.1, u(5)))
        end
        ev(D.text((mx0 + mx1) / 2, ly, 5, u(12.5), m[2], sel and COL.bg or COL.white, sel and 1 or 0.72, false, font))
        add_region(mx0, ly - u(11), mx1, ly + u(11), "hist_mode", { id = m[1] })
        mx1 = mx0 - u(3)
    end

    local y_end = ly + u(18)
    ev(D.rect(x0 + 1, y_end - 1, x1, y_end, COL.white, 0.07))
    return y_end
end

local function draw_gradient_track(d, x0, x1, cy, th, op)
    local steps = 30
    for i = 0, steps - 1 do
        local t = (i + 0.5) / steps
        -- hue: the color wheel; saturation/vibrance: grey to a vivid warm color
        local col = d.track == "hue" and hsv((t + 0.5) % 1, 0.62, 0.86) or hsv(0.03, t * 0.82, 0.55 + t * 0.37)
        local sx = x0 + i * (x1 - x0) / steps
        ev(D.rect(sx, cy - th / 2, sx + (x1 - x0) / steps + 0.6, cy + th / 2, col, 0.85 * op))
    end
end

local function draw_slider(d, y, x0, x1, dim)
    local st = ctx.state
    local rh = u(32)
    local cy = y + rh / 2
    local v = st.values[d.id]
    local changed = fx.slider_changed(st, d)
    local op = dim and 0.45 or 1

    ev(D.text(x0 + u(18), cy, 4, u(14.5), d.label, COL.white, 0.82 * op, false, font))
    local tx0 = x0 + u(108)
    local tx1 = x1 - u(82)
    local function xpos(val) return tx0 + (val - d.min) / (d.max - d.min) * (tx1 - tx0) end
    local th = u(4)
    if d.track then
        draw_gradient_track(d, tx0, tx1, cy, th, op)
    else
        ev(D.rect(tx0, cy - th / 2, tx1, cy + th / 2, COL.white, 0.2 * op, th / 2))
    end
    local zx = xpos(d.default)
    ev(D.rect(zx - u(0.7), cy - u(5.5), zx + u(0.7), cy + u(5.5), COL.white, 0.35 * op))
    local vx = xpos(v)
    if changed and not d.track then
        ev(D.rect(math.min(zx, vx), cy - th / 2, math.max(zx, vx), cy + th / 2, accent, op, th / 2))
    end
    local active = (ui.drag and ui.drag.kind == "slider" and ui.drag.id == d.id) or is_hover("slider", d.id)
    local r = active and u(7.5) or u(6.5)
    ev(D.circle(vx, cy, r + u(1.5), COL.black, 0.4))
    ev(D.circle(vx, cy, r, COL.white, op))

    local scrubbing = ui.drag and ui.drag.kind == "value" and ui.drag.id == d.id
    if is_hover("value", d.id) or scrubbing then
        ev(D.rect(x1 - u(74), cy - u(11), x1 - u(10), cy + u(11), COL.white, 0.08, u(5)))
    end
    ev(D.text(x1 - u(16), cy, 6, u(14.5), fx.format_value(d, v), changed and accent_text or COL.white,
              (changed and 1 or 0.6) * op, false, font))

    add_region(x0, y, tx0 - u(9), y + rh, "slider_label", { id = d.id, def = d })
    add_region(tx0 - u(9), y, tx1 + u(9), y + rh, "slider", { id = d.id, def = d, tx0 = tx0, tx1 = tx1 })
    add_region(tx1 + u(9), y, x1, y + rh, "value", { id = d.id, def = d, tx0 = tx0, tx1 = tx1 })
    return y + rh
end

-- Lumetri-style channel picker: white, red, green and blue dots
local function draw_channel_dots(y, x0, x1, kind, selected, edited, reset_kind, reset_label)
    local cy = y + u(14)
    local x = x0 + u(18)
    for _, ch in ipairs(fx.CHANNELS) do
        local cx = x + u(11)
        if ch == selected then
            ring(cx, cy, u(11.5), u(1.6), COL.white, 0.95)
        elseif is_hover(kind, ch) then
            ring(cx, cy, u(11.5), u(1.2), COL.white, 0.35)
        end
        ev(D.circle(cx, cy, u(7), CH_COLOR[ch], ch == "rgb" and 0.92 or 1))
        if edited[ch] then ev(D.circle(cx, cy + u(15.5), u(2), accent_text, 1)) end
        add_region(cx - u(13), cy - u(14), cx + u(13), cy + u(16), kind, { id = ch })
        x = x + u(31)
    end
    ev(D.text(x + u(6), cy, 4, u(13.5), fx.CHANNEL_NAMES[selected], COL.white, 0.75, false, font))

    local any = false
    for _, ch in ipairs(fx.CHANNELS) do if edited[ch] and ch == selected then any = true end end
    local rx1 = x1 - u(16)
    local rx0 = rx1 - u(64)
    if is_hover(reset_kind, reset_kind) and any then ev(D.rect(rx0 - u(6), cy - u(11), rx1 + u(6), cy + u(11), COL.white, 0.08, u(5))) end
    ev(D.text(rx1, cy, 6, u(13), reset_label, any and accent_text or COL.white, any and 1 or 0.3, false, font))
    add_region(rx0 - u(6), cy - u(12), rx1 + u(6), cy + u(12), reset_kind, { id = reset_kind })
    return y + u(34)
end

local function draw_curves(y, x0, x1, dim)
    local st, H = ctx.state, ctx.hist
    local ch = ui.curve_ch
    local edited = {}
    for _, c in ipairs(fx.CHANNELS) do edited[c] = fx.curve_changed(st.curves[c]) end
    y = draw_channel_dots(y + u(8), x0, x1, "curve_ch", ch, edited, "curve_reset", "Reset curve")

    -- Photoshop-style gradient bars along the left and bottom edges of the graph
    local bar = u(7)
    local gx0 = x0 + u(16) + bar + u(5)
    local gs = (x1 - u(16)) - gx0
    local gy0 = y
    ramp(x0 + u(16), gy0, bar, gs, true)
    ev(D.rect(gx0, gy0, gx0 + gs, gy0 + gs, COL.black, 0.4))
    if H.status == "ready" and H.orig.l then
        local bins = bins_for(H.orig, ch)
        ev(D.fill(hist_path(bins, gx0, gy0, gs, gs, hist_scale(bins) * 0.85),
                  ch == "rgb" and COL.white or CH_COLOR[ch], ch == "rgb" and 0.1 or 0.2))
    end
    for q = 1, 3 do
        local o = gs * q / 4
        ev(D.rect(gx0 + o, gy0, gx0 + o + math.max(1, u(1)), gy0 + gs, COL.white, 0.08))
        ev(D.rect(gx0, gy0 + o, gx0 + gs, gy0 + o + math.max(1, u(1)), COL.white, 0.08))
    end
    ev(D.outline(D.rect_path(gx0, gy0, gx0 + gs, gy0 + gs), 1, COL.white, 0.14))

    local dashes, dl = {}, u(5)
    local len = gs * math.sqrt(2)
    for t = 0, len - dl, dl * 2 do
        local a, b = t / len, (t + dl) / len
        dashes[#dashes + 1] = { { gx0 + a * gs, gy0 + gs - a * gs }, { gx0 + b * gs, gy0 + gs - b * gs } }
    end
    strokes(dashes, math.max(1, u(1)), COL.white, 0.22, true)

    local function to_screen(px, py) return gx0 + px * gs, gy0 + gs - py * gs end
    local function curve_line(pts, w, col, op)
        local samples = fx.curve_points_for_drawing(pts, 97)
        local line = {}
        for i, p in ipairs(samples) do line[i] = { to_screen(p[1], p[2]) } end
        strokes({ line }, w, col, op)
    end
    for _, c in ipairs(fx.CHANNELS) do
        if c ~= ch and edited[c] then curve_line(st.curves[c], u(1.3), CH_COLOR[c], 0.55 * (dim and 0.6 or 1)) end
    end
    local pts = st.curves[ch]
    curve_line(pts, u(2), CH_COLOR[ch], dim and 0.5 or 1)

    local drag_idx = ui.drag and ui.drag.kind == "curve_pt" and not ui.drag.removed and ui.drag.idx
    for i, p in ipairs(pts) do
        local px, py = to_screen(p[1] / 255, p[2] / 255)
        if i == ui.sel_point or i == drag_idx then
            ev(D.circle(px, py, u(11), accent, 0.3))
            ev(D.circle(px, py, u(6), accent, 1))
            ring(px, py, u(7), u(2), COL.white, 1)
        else
            ev(D.circle(px, py, u(5), COL.bg, 1))
            ring(px, py, u(5.5), u(1.5), COL.white, 0.95)
        end
    end
    if ui.drag and ui.drag.kind == "curve_pt" and ui.drag.removed then
        local mx, my = mouse_pos()
        icon_close(mx, my, COL.white, 0.5)
    end
    add_region(gx0 - u(9), gy0 - u(9), gx0 + gs + u(9), gy0 + gs + u(9), "curve_graph",
               { id = "graph", gx0 = gx0, gy0 = gy0, gs = gs })
    y = gy0 + gs + u(5)
    ramp(gx0, y, gs, bar, false)
    y = y + bar + u(16)

    local sel = ui.sel_point and pts[ui.sel_point]
    if sel then
        ev(D.text(gx0, y, 4, u(13), "Input", COL.white, 0.55, false, font))
        ev(D.text(gx0 + u(40), y, 4, u(13.5), tostring(sel[1]), COL.white, 0.95, false, font))
        ev(D.text(gx0 + u(86), y, 4, u(13), "Output", COL.white, 0.55, false, font))
        ev(D.text(gx0 + u(136), y, 4, u(13.5), tostring(sel[2]), COL.white, 0.95, false, font))
    else
        ev(D.text(gx0, y, 4, u(13), "Click the curve to add a point", COL.white, 0.45, false, font))
    end
    return y + u(20)
end

local function draw_triangle(x, y, fill, edge, big)
    local w, h = u(big and 7.5 or 6.5), u(big and 12.5 or 11)
    local path = D.poly_path({ { x - w, y + h }, { x, y }, { x + w, y + h } })
    ev(D.fill(path, fill, 1))
    ev(D.outline(path, u(1), edge, 0.95))
end

local function level_number(x, cy, w, text, which, align)
    local x0 = align == "left" and x or (align == "right" and x - w or x - w / 2)
    local hov = is_hover("lv_num", which)
    ev(D.rect(x0, cy - u(12), x0 + w, cy + u(12), COL.white, hov and 0.12 or 0.06, u(5)))
    ev(D.outline(D.rrect_path(x0, cy - u(12), x0 + w, cy + u(12), u(5)), 1, COL.white, 0.12))
    ev(D.text(x0 + w / 2, cy, 5, u(13.5), text, COL.white, 0.95, false, font))
    add_region(x0, cy - u(13), x0 + w, cy + u(13), "lv_num", { id = which })
end

local function draw_levels(y, x0, x1, dim)
    local st, H = ctx.state, ctx.hist
    local ch = ui.level_ch
    local lv = st.levels[ch]
    local edited = {}
    for _, c in ipairs(fx.CHANNELS) do edited[c] = fx.levels_changed(st.levels[c]) end
    y = draw_channel_dots(y + u(8), x0, x1, "level_ch", ch, edited, "levels_reset", "Reset levels")

    local gx0, gx1 = x0 + u(16), x1 - u(16)
    local gw = gx1 - gx0
    local function xv(v) return gx0 + v / 255 * gw end
    local dragging = ui.drag and ui.drag.kind == "lv_tri" and ui.drag.id

    ev(D.text(gx0, y + u(6), 4, u(12.5), "Input levels", COL.white, 0.7, true, font))
    y = y + u(18)
    local hh = u(72)
    ev(D.rect(gx0, y, gx1, y + hh, COL.black, 0.4))
    if H.status == "ready" and H.orig.l then
        local bins = bins_for(H.orig, ch)
        ev(D.fill(hist_path(bins, gx0, y, gw, hh, hist_scale(bins)), ch == "rgb" and COL.white or CH_COLOR[ch],
                  ch == "rgb" and 0.38 or 0.5))
    end
    if lv.ib > 0 then
        ev(D.rect(gx0, y, xv(lv.ib), y + hh, COL.red, 0.22))
        ev(D.rect(xv(lv.ib) - 0.5, y, xv(lv.ib) + 0.5, y + hh, COL.red, 0.7))
    end
    if lv.iw < 255 then
        ev(D.rect(xv(lv.iw), y, gx1, y + hh, COL.red, 0.22))
        ev(D.rect(xv(lv.iw) - 0.5, y, xv(lv.iw) + 0.5, y + hh, COL.red, 0.7))
    end
    y = y + hh + u(3)
    ramp(gx0, y, gw, u(8), false)
    local ty = y + u(9)
    local gx = xv(lv.ib + (lv.iw - lv.ib) * 0.5 ^ lv.g)
    local tris = { { "ib", xv(lv.ib), COL.black, COL.white }, { "g", gx, "#808080", COL.white },
                   { "iw", xv(lv.iw), COL.white, COL.black } }
    for _, t in ipairs(tris) do
        draw_triangle(t[2], ty, t[3], t[4], dragging == t[1] or is_hover("lv_tri", t[1]))
        add_region(t[2] - u(10), y - u(4), t[2] + u(10), ty + u(15), "lv_tri", { id = t[1], gx0 = gx0, gw = gw })
    end
    y = ty + u(30)
    level_number(gx0, y, u(52), tostring(lv.ib), "ib", "left")
    level_number(gx0 + gw / 2, y, u(52), string.format("%.2f", lv.g), "g", "center")
    level_number(gx1, y, u(52), tostring(lv.iw), "iw", "right")
    y = y + u(26)

    ev(D.text(gx0, y + u(6), 4, u(12.5), "Output levels", COL.white, 0.7, true, font))
    y = y + u(18)
    ramp(gx0, y, gw, u(8), false)
    ty = y + u(9)
    for _, t in ipairs({ { "ob", xv(lv.ob), COL.black, COL.white }, { "ow", xv(lv.ow), COL.white, COL.black } }) do
        draw_triangle(t[2], ty, t[3], t[4], dragging == t[1] or is_hover("lv_tri", t[1]))
        add_region(t[2] - u(10), y - u(4), t[2] + u(10), ty + u(15), "lv_tri", { id = t[1], gx0 = gx0, gw = gw })
    end
    y = ty + u(30)
    level_number(gx0, y, u(52), tostring(lv.ob), "ob", "left")
    level_number(gx1, y, u(52), tostring(lv.ow), "ow", "right")
    return y + u(24)
end

local function edited_channel_names(section)
    local names = {}
    for _, ch in ipairs(fx.CHANNELS) do
        local c = section == "curves" and fx.curve_changed(ctx.state.curves[ch]) or
                  section == "levels" and fx.levels_changed(ctx.state.levels[ch])
        if c then names[#names + 1] = fx.CHANNEL_NAMES[ch] end
    end
    return table.concat(names, ", ")
end

local function draw_section(sec, y, x0, x1)
    local st = ctx.state
    local id = sec.id
    local hh = u(38)
    local cy = y + hh / 2
    local open, on = ui.expanded[id], st.section_on[id]

    ev(D.rect(x0 + 1, y, x1, y + hh, is_hover("section", id) and COL.header_hover or COL.header, 1))
    ev(D.rect(x0 + 1, y + hh - 1, x1, y + hh, COL.black, 0.4))
    icon_chevron(x0 + u(18), cy, open, COL.white, 0.6)
    SECTION_ICON[id](x0 + u(40), cy, COL.white, on and 0.9 or 0.4)
    ev(D.text(x0 + u(58), cy, 4, u(15), sec.label, COL.white, on and 1 or 0.45, true, font))
    add_region(x0, y, x1, y + hh, "section", { id = id })

    -- right side: on/off (eye), reset, change badge
    local ex = x1 - u(26)
    hover_bg(ex - u(14), cy - u(13), ex + u(14), cy + u(13), is_hover("section_eye", id))
    icon_eye(ex, cy, on, COL.white, on and 0.8 or 0.55)
    add_region(ex - u(15), y, ex + u(15), y + hh, "section_eye", { id = id })
    local n = fx.changed_count(st, id)
    if n > 0 then
        local rx = ex - u(31)
        hover_bg(rx - u(13), cy - u(13), rx + u(13), cy + u(13), is_hover("section_reset", id))
        icon_reset(rx, cy, COL.white, 0.7, 5)
        add_region(rx - u(14), y, rx + u(14), y + hh, "section_reset", { id = id })
        local badge = (id == "light" or id == "color") and (n .. " changed") or edited_channel_names(id)
        ev(D.text(rx - u(18), cy, 6, u(12.5), badge, on and accent_text or COL.white, on and 1 or 0.4, false, font))
    end
    y = y + hh

    if open then
        if id == "light" or id == "color" then
            y = y + u(6)
            for _, d in ipairs(fx.sliders) do
                if d.section == id then y = draw_slider(d, y, x0, x1, not on) end
            end
            y = y + u(8)
        elseif id == "curves" then
            y = draw_curves(y, x0, x1, not on) + u(6)
        else
            y = draw_levels(y, x0, x1, not on) + u(12)
        end
    end
    return y
end

---------------------------------------------------------------------------------------------------
-- Rendering

local function render()
    ui.redraw_pending = false
    if not ui.open or ui.w <= 0 then return end
    events, ui.regions, clip_box = {}, {}, nil
    D.set_clip(nil)

    local W = math.floor(u(ctx.opts.panel_width))
    local x0, x1 = ui.w - W, ui.w
    -- Keep clear of the OSC: its bottom bar, and in fullscreen/borderless its window-controls bar.
    local yt = (ui.fullscreen or not ui.border) and math.floor(u(ctx.opts.top_margin)) or 0
    local yb = ui.h - math.floor(u(ctx.opts.bottom_margin))
    if yb - yt < u(320) then yt, yb = 0, ui.h end
    -- The panel is only as tall as what's open, so its surface is slotted in underneath
    -- (events 1 and 2) once the content has been laid out.
    ev("")
    ev("")
    local y = draw_header(x0, x1, yt)
    y = draw_histogram(x0, x1, y)

    local ay0, ay1 = y, yb
    clip_box = { x0, ay0, x1, ay1 }
    D.set_clip(x0, ay0, x1, ay1)
    local cy = ay0 - ui.scroll
    for _, sec in ipairs(SECTIONS) do cy = draw_section(sec, cy, x0, x1) end
    local content = cy + ui.scroll - ay0
    clip_box = nil
    D.set_clip(nil)

    ui.scrollable = math.max(0, content - (ay1 - ay0))
    if ui.scroll > ui.scrollable then
        ui.scroll = ui.scrollable
        UI.redraw()
    end
    if ui.scrollable > 0 then
        local view = ay1 - ay0
        local th = math.max(u(24), view * view / content)
        local ty = ay0 + (view - th) * (ui.scroll / ui.scrollable)
        ev(D.rect(x1 - u(5), ty + u(2), x1 - u(2), ty + th - u(2), COL.white, 0.25, u(1.5)))
    end

    local bottom = math.min(yb, ay0 + content)
    ui.panel = { x0 = x0, x1 = x1, y0 = yt, y1 = bottom }
    events[1] = D.rect(x0, yt, x1, bottom, COL.bg, 1)
    events[2] = D.rect(x0, yt, x0 + 1, bottom, COL.white, 0.08)

    overlay.res_x, overlay.res_y = ui.w, ui.h
    overlay.data = table.concat(events, "\n")
    overlay:update()
    if ui.drag then
        mp.set_mouse_area(0, 0, ui.w, ui.h, INPUT_SECTION)
    else
        mp.set_mouse_area(x0, yt, x1, bottom, INPUT_SECTION)
    end
end

function UI.redraw()
    if ui.open and not ui.redraw_pending then
        ui.redraw_pending = true
        mp.add_timeout(1 / 60, render)
    end
end

---------------------------------------------------------------------------------------------------
-- Editing helpers

local function changed()
    ctx.changed()
    UI.redraw()
end

local function set_value(d, v)
    if ctx.state.values[d.id] ~= v then
        ctx.state.values[d.id] = v
        changed()
    end
end

local function prompt(label, default, apply)
    input.get({
        prompt = label .. " ",
        default_text = default,
        submit = function(text)
            apply(text)
            input.terminate()
        end,
    })
end

local function prompt_slider(d)
    prompt(d.label .. ":", fx.edit_text(d, ctx.state.values[d.id]), function(text)
        local v = fx.parse_value(d, text)
        if v then set_value(d, v) end
    end)
end

local LEVEL_LABEL = { ib = "Input black", iw = "Input white", g = "Midtones (gamma)", ob = "Output black", ow = "Output white" }

local function set_level(lv, which, v)
    if which == "ib" then lv.ib = clamp(round(v), 0, lv.iw - 2)
    elseif which == "iw" then lv.iw = clamp(round(v), lv.ib + 2, 255)
    elseif which == "g" then lv.g = clamp(math.floor(v * 100 + 0.5) / 100, 0.1, 9.99)
    elseif which == "ob" then lv.ob = clamp(round(v), 0, 255)
    elseif which == "ow" then lv.ow = clamp(round(v), 0, 255) end
end

local function prompt_level(which)
    local lv = ctx.state.levels[ui.level_ch]
    local cur = which == "g" and string.format("%.2f", lv.g) or tostring(lv[which])
    prompt(LEVEL_LABEL[which] .. ":", cur, function(text)
        local v = tonumber((text:gsub(",", ".")))
        if v then
            set_level(lv, which, v)
            changed()
        end
    end)
end

local function graph_value(r, mx, my)
    return (mx - r.gx0) / r.gs * 255, (r.gy0 + r.gs - my) / r.gs * 255
end

local function nearest_point(r, pts, mx, my, radius)
    local best, bd = nil, radius * radius
    for i, p in ipairs(pts) do
        local px, py = r.gx0 + p[1] / 255 * r.gs, r.gy0 + r.gs - p[2] / 255 * r.gs
        local d2 = (px - mx) ^ 2 + (py - my) ^ 2
        if d2 <= bd then best, bd = i, d2 end
    end
    return best
end

local function insert_point(pts, x, y)
    for i, p in ipairs(pts) do
        if math.abs(p[1] - x) < 3 then return i end
        if p[1] > x then
            table.insert(pts, i, { x, y })
            return i
        end
    end
    pts[#pts + 1] = { x, y }
    return #pts
end

---------------------------------------------------------------------------------------------------
-- Mouse handling

local function update_drag(mx, my)
    local d, st = ui.drag, ctx.state
    if d.kind == "slider" then
        local def, r = d.def, d.region
        local v
        if d.fine then
            v = d.start_v + (mx - d.start_x) / (r.tx1 - r.tx0) * (def.max - def.min) * 0.1
        else
            v = def.min + (mx - r.tx0) / (r.tx1 - r.tx0) * (def.max - def.min)
            -- the default value is slightly magnetic, so dragging back to it is easy
            if math.abs(v - def.default) < (def.max - def.min) * 0.012 then v = def.default end
        end
        set_value(def, fx.clamp_value(def, v, d.fine))
    elseif d.kind == "value" then
        if math.abs(mx - d.start_x) > u(3) then d.moved = true end
        if d.moved then
            local steps = (mx - d.start_x) / u(d.fine and 8 or 2)
            set_value(d.def, fx.clamp_value(d.def, d.start_v + steps * (d.fine and d.def.fine or d.def.step), d.fine))
        end
    elseif d.kind == "curve_pt" then
        local r, pts = d.region, st.curves[d.ch]
        local margin = u(26)
        local outside = mx < r.gx0 - margin or mx > r.gx0 + r.gs + margin or
                        my < r.gy0 - margin or my > r.gy0 + r.gs + margin
        local count = #pts + (d.removed and 1 or 0)
        if outside and count > 2 then
            if not d.removed then
                d.removed = table.remove(pts, d.idx)
                ui.sel_point = nil
                changed()
            end
            UI.redraw()
            return
        end
        local x, y = graph_value(r, mx, my)
        x, y = clamp(round(x), 0, 255), clamp(round(y), 0, 255)
        if d.removed then
            d.removed = nil
            d.idx = insert_point(pts, x, y)
            ui.sel_point = d.idx
        end
        local i = d.idx
        local lo = i > 1 and pts[i - 1][1] + 2 or 0
        local hi = i < #pts and pts[i + 1][1] - 2 or 255
        pts[i] = { clamp(x, lo, hi), y }
        changed()
    elseif d.kind == "lv_tri" then
        local lv = st.levels[ui.level_ch]
        local v = (mx - d.region.gx0) / d.region.gw * 255
        if d.id == "g" then
            local m = clamp((v - lv.ib) / math.max(1, lv.iw - lv.ib), 0.01, 0.99)
            v = math.log(m) / math.log(0.5)
        end
        set_level(lv, d.id, v)
        changed()
    end
end

local function click(r)
    local st = ctx.state
    local k = r.kind
    if k == "close" then UI.close()
    elseif k == "reset_all" then fx.reset_all(st); ui.sel_point = nil; changed()
    elseif k == "switch" then st.enabled = not st.enabled; changed()
    elseif k == "hist_mode" then ui.hist_mode = r.id; UI.redraw()
    elseif k == "section" then ui.expanded[r.id] = not ui.expanded[r.id]; UI.redraw()
    elseif k == "section_eye" then st.section_on[r.id] = not st.section_on[r.id]; changed()
    elseif k == "section_reset" then
        fx.reset_section(st, r.id)
        if r.id == "curves" then ui.sel_point = nil end
        changed()
    elseif k == "curve_ch" then ui.curve_ch, ui.sel_point = r.id, nil; UI.redraw()
    elseif k == "level_ch" then ui.level_ch = r.id; UI.redraw()
    elseif k == "curve_reset" then fx.reset_curve(st, ui.curve_ch); ui.sel_point = nil; changed()
    elseif k == "levels_reset" then fx.reset_levels(st, ui.level_ch); changed()
    elseif k == "value" then prompt_slider(r.def)
    elseif k == "lv_num" then prompt_level(r.id)
    end
end

local function on_down(fine)
    local mx, my = mouse_pos()
    local r = hit(mx, my)
    ui.press = r
    if not r then return end
    local st = ctx.state
    if r.kind == "slider" then
        ui.drag = { kind = "slider", id = r.id, def = r.def, region = r, fine = fine,
                    start_x = mx, start_v = st.values[r.id] }
        if not fine then update_drag(mx, my) end
    elseif r.kind == "value" then
        ui.drag = { kind = "value", id = r.id, def = r.def, region = r, fine = fine,
                    start_x = mx, start_v = st.values[r.id], moved = false }
    elseif r.kind == "curve_graph" then
        local pts = st.curves[ui.curve_ch]
        local idx = nearest_point(r, pts, mx, my, u(10))
        if not idx then
            if #pts >= fx.MAX_CURVE_POINTS then return end
            local x, y = graph_value(r, mx, my)
            idx = insert_point(pts, clamp(round(x), 0, 255), clamp(round(y), 0, 255))
            changed()
        end
        ui.sel_point = idx
        ui.drag = { kind = "curve_pt", id = "graph", ch = ui.curve_ch, idx = idx, region = r }
    elseif r.kind == "lv_tri" then
        ui.drag = { kind = "lv_tri", id = r.id, region = r }
    end
    UI.redraw()
end

local function on_up()
    local d = ui.drag
    if d then
        -- mouse-pos updates arrive asynchronously; apply the final position before letting go
        update_drag(mouse_pos())
    end
    ui.drag = nil
    if d then
        if d.kind == "value" and not d.moved then click(ui.press) end
        if d.kind == "curve_pt" and d.removed then ui.sel_point = nil end
    elseif ui.press then
        local r = hit(mouse_pos())
        if same(r, ui.press) then click(ui.press) end
    end
    ui.press = nil
    UI.redraw()
end

local function on_dbl()
    local mx, my = mouse_pos()
    local r = hit(mx, my)
    if not r then return end
    local st = ctx.state
    if r.kind == "slider" or r.kind == "slider_label" or r.kind == "value" then
        ui.drag = nil
        set_value(r.def, r.def.default)
    elseif r.kind == "curve_graph" then
        local pts = st.curves[ui.curve_ch]
        local idx = nearest_point(r, pts, mx, my, u(10))
        if idx and #pts > 2 then
            ui.drag = nil
            table.remove(pts, idx)
            ui.sel_point = nil
            changed()
        end
    elseif r.kind == "lv_tri" then
        ui.drag = nil
        set_level(st.levels[ui.level_ch], r.id, fx.levels_default(r.id))
        changed()
    end
end

local function on_wheel(dir)
    if ui.scrollable > 0 then
        ui.scroll = clamp(ui.scroll + dir * u(60), 0, ui.scrollable)
        UI.redraw()
        return
    end
    local r = hit(mouse_pos())
    if r and (r.kind == "slider" or r.kind == "slider_label" or r.kind == "value") then
        set_value(r.def, fx.clamp_value(r.def, ctx.state.values[r.id] - dir * r.def.step))
    end
end

local function on_mouse_move(_, pos)
    if not ui.open or not pos then return end
    if ui.drag then
        update_drag(pos.x, pos.y)
        return
    end
    local r = hit(pos.x, pos.y)
    if not same(r, ui.hover) then
        ui.hover = r
        UI.redraw()
    end
end

---------------------------------------------------------------------------------------------------
-- Opening, closing, docking

local function update_dims()
    local d = mp.get_property_native("osd-dimensions")
    if not d or d.w <= 0 then return false end
    ui.w, ui.h = d.w, d.h
    ui.fullscreen = mp.get_property_native("fullscreen")
    ui.border = mp.get_property_native("border") and mp.get_property_native("title-bar", true)
    ui.s = ui.fullscreen and ctx.opts.scale_fullscreen or ctx.opts.scale
    return true
end

-- Shrinks the video so the panel sits beside it instead of covering it.
local function dock(on)
    if on then
        if ui.saved_margin == nil then ui.saved_margin = mp.get_property_number("video-margin-ratio-right", 0) end
        if ui.w > 0 then
            local ratio = math.min(0.8, ui.saved_margin + u(ctx.opts.panel_width) / ui.w)
            mp.set_property_number("video-margin-ratio-right", ratio)
        end
    elseif ui.saved_margin ~= nil then
        mp.set_property_number("video-margin-ratio-right", ui.saved_margin)
        ui.saved_margin = nil
    end
end

function UI.is_open() return ui.open end

function UI.open()
    if ui.open then return end
    ui.open = true
    update_dims()
    mp.set_key_bindings({
        { "mbtn_left", on_up, function() on_down(false) end },
        { "shift+mbtn_left", on_up, function() on_down(true) end },
        { "mbtn_left_dbl", on_dbl },
        { "wheel_up", function() on_wheel(-1) end },
        { "wheel_down", function() on_wheel(1) end },
    }, INPUT_SECTION, "force")
    mp.enable_key_bindings(INPUT_SECTION)
    mp.add_forced_key_binding("ESC", "video-effects-close", UI.close)
    dock(true)
    ctx.on_open_changed(true)
    UI.redraw()
end

function UI.close()
    if not ui.open then return end
    ui.open, ui.drag, ui.hover, ui.press = false, nil, nil, nil
    overlay:remove()
    mp.disable_key_bindings(INPUT_SECTION)
    mp.remove_key_binding("video-effects-close")
    dock(false)
    ctx.on_open_changed(false)
end

function UI.toggle()
    if ui.open then UI.close() else UI.open() end
end

-- For scripted control and testing: expand/collapse sections and pick channels.
function UI.set_section(id, open) if ui.expanded[id] ~= nil then ui.expanded[id] = open; UI.redraw() end end
function UI.set_channel(which, ch) if which == "curves" then ui.curve_ch = ch else ui.level_ch = ch end; UI.redraw() end
function UI.set_hist_mode(m) ui.hist_mode = m; UI.redraw() end
function UI.select_point(i) ui.sel_point = i; UI.redraw() end

function UI.init(c)
    ctx = c
    font = (c.opts.font ~= "" and c.opts.font) or mp.get_property("osd-font", "sans-serif")
    accent = c.opts.accent
    accent_text = D.mix(accent, "#FFFFFF", 0.3)
    mp.observe_property("osd-dimensions", "native", function()
        if ui.open and update_dims() then
            dock(true)
            UI.redraw()
        end
    end)
    for _, prop in ipairs({ "fullscreen", "border", "title-bar" }) do
        mp.observe_property(prop, "bool", function()
            if ui.open and update_dims() then
                dock(true)
                UI.redraw()
            end
        end)
    end
    mp.observe_property("mouse-pos", "native", on_mouse_move)
end

return UI

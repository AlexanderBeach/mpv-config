-- The effects panel's contents: the histogram, the Light and Color sliders, and Photoshop-style
-- curves and levels. The panel itself (header, sections, sliders, mouse handling, docking) comes
-- from script-modules/kit/panel.lua. The histogram is Lightroom-style, with clipping indicators.
local mp = require "mp"
local panel = require "kit.panel"
local fx = require "fx"

local UI = {}

local ctx, K
local D = require "kit.draw"
local COL = panel.COL
local CH_COLOR = { rgb = "#FFFFFF", r = COL.red, g = COL.green, b = COL.blue }
local view = { curve_ch = "rgb", level_ch = "rgb", sel_point = nil, hist_mode = "luma" }

local clamp, round = panel.clamp, panel.round
local u, ev, add_region, is_hover, strokes, ring   -- from the panel, set in UI.init

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

local function icon_sliders(_, cx, cy)
    strokes({ { { cx - u(8), cy - u(4) }, { cx + u(8), cy - u(4) } },
              { { cx - u(8), cy + u(4) }, { cx + u(8), cy + u(4) } } }, u(1.6), K.accent_text, 1)
    ev(D.circle(cx - u(3), cy - u(4), u(2.8), K.accent_text, 1))
    ev(D.circle(cx + u(3), cy + u(4), u(2.8), K.accent_text, 1))
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
    local s = K.ui.s
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

local SECTIONS = {
    { id = "light", label = "Light", icon = icon_sun },
    { id = "color", label = "Color", icon = icon_drop },
    { id = "curves", label = "Curves", icon = icon_curves },
    { id = "levels", label = "Levels", icon = icon_levels },
}

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

local function draw_histogram(x0, x1, y)
    local H = ctx.hist
    local font, accent_text = K.font, K.accent_text
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
        if view.hist_mode == "rgb" then
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
    if view.hist_mode == "rgb" then
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
        local sel = view.hist_mode == m[1]
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

---------------------------------------------------------------------------------------------------
-- Curves and levels

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
        if edited[ch] then ev(D.circle(cx, cy + u(15.5), u(2), K.accent_text, 1)) end
        add_region(cx - u(13), cy - u(14), cx + u(13), cy + u(16), kind, { id = ch })
        x = x + u(31)
    end
    ev(D.text(x + u(6), cy, 4, u(13.5), fx.CHANNEL_NAMES[selected], COL.white, 0.75, false, K.font))

    local any = false
    for _, ch in ipairs(fx.CHANNELS) do if edited[ch] and ch == selected then any = true end end
    local rx1 = x1 - u(16)
    local rx0 = rx1 - u(64)
    if is_hover(reset_kind, reset_kind) and any then ev(D.rect(rx0 - u(6), cy - u(11), rx1 + u(6), cy + u(11), COL.white, 0.08, u(5))) end
    ev(D.text(rx1, cy, 6, u(13), reset_label, any and K.accent_text or COL.white, any and 1 or 0.3, false, K.font))
    add_region(rx0 - u(6), cy - u(12), rx1 + u(6), cy + u(12), reset_kind, { id = reset_kind })
    return y + u(34)
end

local function draw_curves(y, x0, x1, dim)
    local st, H = ctx.state, ctx.hist
    local ch = view.curve_ch
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

    local drag = K.ui.drag
    local drag_idx = drag and drag.kind == "curve_pt" and not drag.removed and drag.idx
    for i, p in ipairs(pts) do
        local px, py = to_screen(p[1] / 255, p[2] / 255)
        if i == view.sel_point or i == drag_idx then
            ev(D.circle(px, py, u(11), K.accent, 0.3))
            ev(D.circle(px, py, u(6), K.accent, 1))
            ring(px, py, u(7), u(2), COL.white, 1)
        else
            ev(D.circle(px, py, u(5), COL.bg, 1))
            ring(px, py, u(5.5), u(1.5), COL.white, 0.95)
        end
    end
    if drag and drag.kind == "curve_pt" and drag.removed then
        local mx, my = K.mouse_pos()
        K.icon_close(mx, my, COL.white, 0.5)
    end
    add_region(gx0 - u(9), gy0 - u(9), gx0 + gs + u(9), gy0 + gs + u(9), "curve_graph",
               { id = "graph", gx0 = gx0, gy0 = gy0, gs = gs })
    y = gy0 + gs + u(5)
    ramp(gx0, y, gs, bar, false)
    y = y + bar + u(16)

    local sel = view.sel_point and pts[view.sel_point]
    if sel then
        ev(D.text(gx0, y, 4, u(13), "Input", COL.white, 0.55, false, K.font))
        ev(D.text(gx0 + u(40), y, 4, u(13.5), tostring(sel[1]), COL.white, 0.95, false, K.font))
        ev(D.text(gx0 + u(86), y, 4, u(13), "Output", COL.white, 0.55, false, K.font))
        ev(D.text(gx0 + u(136), y, 4, u(13.5), tostring(sel[2]), COL.white, 0.95, false, K.font))
    else
        ev(D.text(gx0, y, 4, u(13), "Click the curve to add a point", COL.white, 0.45, false, K.font))
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
    ev(D.text(x0 + w / 2, cy, 5, u(13.5), text, COL.white, 0.95, false, K.font))
    add_region(x0, cy - u(13), x0 + w, cy + u(13), "lv_num", { id = which })
end

local function draw_levels(y, x0, x1)
    local st, H = ctx.state, ctx.hist
    local ch = view.level_ch
    local lv = st.levels[ch]
    local edited = {}
    for _, c in ipairs(fx.CHANNELS) do edited[c] = fx.levels_changed(st.levels[c]) end
    y = draw_channel_dots(y + u(8), x0, x1, "level_ch", ch, edited, "levels_reset", "Reset levels")

    local gx0, gx1 = x0 + u(16), x1 - u(16)
    local gw = gx1 - gx0
    local function xv(v) return gx0 + v / 255 * gw end
    local drag = K.ui.drag
    local dragging = drag and drag.kind == "lv_tri" and drag.id

    ev(D.text(gx0, y + u(6), 4, u(12.5), "Input levels", COL.white, 0.7, true, K.font))
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

    ev(D.text(gx0, y + u(6), 4, u(12.5), "Output levels", COL.white, 0.7, true, K.font))
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

local function draw_section(sec, y, x0, x1, dim)
    local id = sec.id
    if id == "light" or id == "color" then
        y = y + u(6)
        for _, d in ipairs(fx.sliders) do
            if d.section == id then y = K.draw_slider(d, y, x0, x1, dim) end
        end
        return y + u(8)
    elseif id == "curves" then
        return draw_curves(y, x0, x1, dim) + u(6)
    end
    return draw_levels(y, x0, x1) + u(12)
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

---------------------------------------------------------------------------------------------------
-- Editing curves and levels

local LEVEL_LABEL = { ib = "Input black", iw = "Input white", g = "Midtones (gamma)", ob = "Output black", ow = "Output white" }

local function set_level(lv, which, v)
    if which == "ib" then lv.ib = clamp(round(v), 0, lv.iw - 2)
    elseif which == "iw" then lv.iw = clamp(round(v), lv.ib + 2, 255)
    elseif which == "g" then lv.g = clamp(math.floor(v * 100 + 0.5) / 100, 0.1, 9.99)
    elseif which == "ob" then lv.ob = clamp(round(v), 0, 255)
    elseif which == "ow" then lv.ow = clamp(round(v), 0, 255) end
end

local function prompt_level(which)
    local lv = ctx.state.levels[view.level_ch]
    local cur = which == "g" and string.format("%.2f", lv.g) or tostring(lv[which])
    K.prompt(LEVEL_LABEL[which] .. ":", cur, function(text)
        local v = tonumber((text:gsub(",", ".")))
        if v then
            set_level(lv, which, v)
            K.changed()
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

local function drag(d, mx, my)
    local st = ctx.state
    if d.kind == "curve_pt" then
        local r, pts = d.region, st.curves[d.ch]
        local margin = u(26)
        local outside = mx < r.gx0 - margin or mx > r.gx0 + r.gs + margin or
                        my < r.gy0 - margin or my > r.gy0 + r.gs + margin
        local count = #pts + (d.removed and 1 or 0)
        if outside and count > 2 then
            if not d.removed then
                d.removed = table.remove(pts, d.idx)
                view.sel_point = nil
                K.changed()
            end
            K.redraw()
            return
        end
        local x, y = graph_value(r, mx, my)
        x, y = clamp(round(x), 0, 255), clamp(round(y), 0, 255)
        if d.removed then
            d.removed = nil
            d.idx = insert_point(pts, x, y)
            view.sel_point = d.idx
        end
        local i = d.idx
        local lo = i > 1 and pts[i - 1][1] + 2 or 0
        local hi = i < #pts and pts[i + 1][1] - 2 or 255
        pts[i] = { clamp(x, lo, hi), y }
        K.changed()
    elseif d.kind == "lv_tri" then
        local lv = st.levels[view.level_ch]
        local v = (mx - d.region.gx0) / d.region.gw * 255
        if d.id == "g" then
            local m = clamp((v - lv.ib) / math.max(1, lv.iw - lv.ib), 0.01, 0.99)
            v = math.log(m) / math.log(0.5)
        end
        set_level(lv, d.id, v)
        K.changed()
    end
end

local function click(r)
    local st, k = ctx.state, r.kind
    if k == "hist_mode" then view.hist_mode = r.id; K.redraw()
    elseif k == "curve_ch" then view.curve_ch, view.sel_point = r.id, nil; K.redraw()
    elseif k == "level_ch" then view.level_ch = r.id; K.redraw()
    elseif k == "curve_reset" then fx.reset_curve(st, view.curve_ch); view.sel_point = nil; K.changed()
    elseif k == "levels_reset" then fx.reset_levels(st, view.level_ch); K.changed()
    elseif k == "lv_num" then prompt_level(r.id)
    end
end

local function down(r, mx, my)
    if r.kind == "curve_graph" then
        local pts = ctx.state.curves[view.curve_ch]
        local idx = nearest_point(r, pts, mx, my, u(10))
        if not idx then
            if #pts >= fx.MAX_CURVE_POINTS then return nil end
            local x, y = graph_value(r, mx, my)
            idx = insert_point(pts, clamp(round(x), 0, 255), clamp(round(y), 0, 255))
            K.changed()
        end
        view.sel_point = idx
        return { kind = "curve_pt", id = "graph", ch = view.curve_ch, idx = idx, region = r }
    elseif r.kind == "lv_tri" then
        return { kind = "lv_tri", id = r.id, region = r }
    end
end

local function dbl(r, mx, my)
    local st = ctx.state
    if r.kind == "curve_graph" then
        local pts = st.curves[view.curve_ch]
        local idx = nearest_point(r, pts, mx, my, u(10))
        if idx and #pts > 2 then
            K.ui.drag = nil
            table.remove(pts, idx)
            view.sel_point = nil
            K.changed()
        end
    elseif r.kind == "lv_tri" then
        K.ui.drag = nil
        set_level(st.levels[view.level_ch], r.id, fx.levels_default(r.id))
        K.changed()
    end
end

---------------------------------------------------------------------------------------------------

function UI.redraw() K.redraw() end
function UI.is_open() return K.is_open() end
function UI.open() K.open() end
function UI.close() K.close() end
function UI.toggle() K.toggle() end

-- Scripted control: expand/collapse sections and pick channels.
function UI.set_section(id, open) K.set_section(id, open) end
function UI.set_channel(which, ch) if which == "curves" then view.curve_ch = ch else view.level_ch = ch end; K.redraw() end
function UI.set_hist_mode(m) view.hist_mode = m; K.redraw() end
function UI.select_point(i) view.sel_point = i; K.redraw() end

function UI.init(c)
    ctx = c
    local st = c.state
    K = panel.new({
        name = "video_effects",
        title = "Video effects",
        icon = icon_sliders,
        opts = c.opts,
        sections = SECTIONS,
        expanded = { light = true, color = true, curves = false, levels = false },
        section_info = function(id)
            local n = fx.changed_count(st, id)
            return st.section_on[id], n, (id == "light" or id == "color") and (n .. " changed") or edited_channel_names(id)
        end,
        enabled = function() return st.enabled end,
        any_changed = function()
            return not fx.is_neutral({ enabled = true, values = st.values, levels = st.levels, curves = st.curves,
                                       section_on = { light = true, color = true, curves = true, levels = true } })
        end,
        body_top = draw_histogram,
        draw_section = draw_section,
        slider = {
            get = function(d) return st.values[d.id] end,
            set = function(d, v) st.values[d.id] = v end,
            changed = function(d) return fx.slider_changed(st, d) end,
            format = fx.format_value, edit_text = fx.edit_text, clamp = fx.clamp_value, parse = fx.parse_value,
        },
        switch = function() st.enabled = not st.enabled end,
        reset_all = function() fx.reset_all(st); view.sel_point = nil end,
        section_eye = function(id) st.section_on[id] = not st.section_on[id] end,
        section_reset = function(id)
            fx.reset_section(st, id)
            if id == "curves" then view.sel_point = nil end
        end,
        click = click, down = down, drag = drag, dbl = dbl,
        release = function(d) if d.kind == "curve_pt" and d.removed then view.sel_point = nil end end,
        changed = c.changed,
        on_open_changed = c.on_open_changed,
    })
    u, ev, add_region, is_hover, strokes, ring = K.u, K.ev, K.add_region, K.is_hover, K.strokes, K.ring
    K.init()
end

return UI

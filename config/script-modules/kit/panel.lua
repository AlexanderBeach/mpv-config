-- A panel docked to the right of the video: header, collapsible sections, rows of controls,
-- scrolling, and the mouse handling for all of it. The video effects and subtitle style panels
-- are built on it; only one panel is open at a time.
--
-- Look: mpv's own menu surface (#222222, OSD font, 5px corners, inverted white selection) with the
-- ModernZ accent. Layout cues: Lumetri/Lightroom-style collapsible sections with reset buttons.
--
-- panel.new(spec) takes:
--   name            script name; used for its input section and the user-data it shares
--   title, icon     header text, and function(K, cx, cy) drawing the header icon
--   opts            panel_width, top_margin, bottom_margin, scale, scale_fullscreen, font, accent
--   sections        { { id, label, icon = function(cx, cy, col, op) }, ... }, expanded = { id = bool }
--   section_info    function(id) -> on (nil: no on/off eye), number changed, badge text
--   enabled         function() -> whether the header switch is on; any_changed() -> bool
--   body_top        optional function(x0, x1, y) -> y, drawn under the header, not scrolled
--   draw_section    function(sec, y, x0, x1, dim) -> y, a section's rows
--   draw_footer     optional function(y, x0, x1) -> y, after the sections
--   slider          { get(d), set(d, v), format(d, v), edit_text(d, v), clamp(d, v, fine), parse(d, text),
--                     changed(d) (optional; default: the value differs from d.default) }
--   switch(), reset_all(), section_eye(id), section_reset(id)   header and section buttons
--   click(r), down(r, mx, my, fine) -> drag, drag(d, mx, my), release(d), dbl(r, mx, my)
--                   for the panel's own kinds of regions (all optional)
--   changed()       after any value changed; on_open_changed(open)
local mp = require "mp"
local input = require "mp.input"
local D = require "kit.draw"

local M = {}

M.COL = {
    bg = "#222222", header = "#2A2A2A", header_hover = "#323232",
    white = "#FFFFFF", black = "#000000",
    red = "#E5484D", green = "#46A758", blue = "#3E8EED",
}
local COL = M.COL

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function round(v) return math.floor(v + 0.5) end
M.clamp, M.round = clamp, round

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

function M.new(spec)
    local K = { D = D, COL = COL }
    local input_section = spec.name .. "_input"
    local overlay = mp.create_osd_overlay("ass-events")
    local ui = {
        open = false, w = 0, h = 0, s = 1,
        expanded = spec.expanded or {},
        scroll = 0, scrollable = 0,
        regions = {}, hover = nil, press = nil, drag = nil,
        redraw_pending = false, panel = nil,
    }
    K.ui = ui
    local events, clip_box = {}, nil
    local slider = spec.slider or {}

    local function u(v) return v * ui.s end
    local function ev(e) events[#events + 1] = e end
    K.u, K.ev = u, ev

    -----------------------------------------------------------------------------------------------
    -- Regions (click/drag targets), rebuilt on every render

    function K.add_region(x0, y0, x1, y1, kind, data)
        if clip_box then
            y0, y1 = math.max(y0, clip_box[2]), math.min(y1, clip_box[4])
            if y1 <= y0 then return end
        end
        local r = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, kind = kind }
        for k, v in pairs(data or {}) do r[k] = v end
        ui.regions[#ui.regions + 1] = r
    end
    local add_region = K.add_region

    local function hit(x, y)
        for i = #ui.regions, 1, -1 do
            local r = ui.regions[i]
            if x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1 then return r end
        end
    end

    local function same(a, b) return a and b and a.kind == b.kind and a.id == b.id and a.value == b.value end
    function K.is_hover(kind, id, value)
        return ui.hover and ui.hover.kind == kind and ui.hover.id == id and (value == nil or ui.hover.value == value)
    end
    local is_hover = K.is_hover

    function K.mouse_pos()
        local p = mp.get_property_native("mouse-pos")
        if not p then return -1, -1 end
        return p.x, p.y
    end
    local mouse_pos = K.mouse_pos

    -----------------------------------------------------------------------------------------------
    -- Small drawing pieces

    -- Strokes that may cross (like an X) each get their own event, because overlapping parts of one
    -- ASS drawing cancel out. combine = true batches strokes known not to overlap (dashes, rays).
    function K.strokes(polylines, w, col, op, combine)
        if combine then
            local parts = {}
            for _, pts in ipairs(polylines) do parts[#parts + 1] = D.polyline_path(pts, w) end
            ev(D.fill(table.concat(parts, " "), col, op))
        else
            for _, pts in ipairs(polylines) do ev(D.fill(D.polyline_path(pts, w), col, op)) end
        end
    end
    local strokes = K.strokes

    function K.ring(cx, cy, r, w, col, op)
        ev(D.outline(D.circle_path(cx, cy, r - w / 2), w, col, op))
    end
    local ring = K.ring

    function K.hover_bg(x0, y0, x1, y1, on)
        if on then ev(D.rect(x0, y0, x1, y1, COL.white, 0.1, u(5))) end
    end
    local hover_bg = K.hover_bg

    function K.icon_chevron(cx, cy, open, col, op)
        local a = u(3.6)
        local pts = open and { { cx - a, cy - a / 2 }, { cx, cy + a / 2 }, { cx + a, cy - a / 2 } }
                          or { { cx - a / 2, cy - a }, { cx + a / 2, cy }, { cx - a / 2, cy + a } }
        strokes({ pts }, u(1.6), col, op)
    end

    function K.icon_close(cx, cy, col, op)
        local a = u(5)
        strokes({ { { cx - a, cy - a }, { cx + a, cy + a } }, { { cx + a, cy - a }, { cx - a, cy + a } } }, u(1.6), col, op)
    end

    function K.icon_reset(cx, cy, col, op, size)
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

    function K.icon_eye(cx, cy, on, col, op)
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

    -- The on/off switch, its right edge at px1.
    local function switch_shape(px1, cy, on, op)
        local px0 = px1 - u(32)
        ev(D.rect(px0, cy - u(9), px1, cy + u(9), on and K.accent or COL.white, (on and 1 or 0.22) * (op or 1), u(9)))
        ev(D.circle(on and (px1 - u(9)) or (px0 + u(9)), cy, u(6.5), COL.white, op or 1))
        return px0
    end

    -----------------------------------------------------------------------------------------------
    -- Header and sections

    local function draw_header(x0, x1, y0)
        local hh = u(52)
        local cy = y0 + hh / 2
        spec.icon(K, x0 + u(25), cy)
        ev(D.text(x0 + u(43), cy, 4, u(17), spec.title, COL.white, 1, true, K.font))

        local cx1 = x1 - u(10)
        local cx0 = cx1 - u(30)
        hover_bg(cx0, cy - u(15), cx1, cy + u(15), is_hover("close", "close"))
        K.icon_close((cx0 + cx1) / 2, cy, COL.white, 0.85)
        add_region(cx0, cy - u(16), cx1, cy + u(16), "close", { id = "close" })

        local rx1 = cx0 - u(2)
        local rx0 = rx1 - u(30)
        hover_bg(rx0, cy - u(15), rx1, cy + u(15), is_hover("reset_all", "reset_all"))
        K.icon_reset((rx0 + rx1) / 2, cy, COL.white, spec.any_changed() and 0.85 or 0.3)
        add_region(rx0, cy - u(16), rx1, cy + u(16), "reset_all", { id = "reset_all" })

        local on = spec.enabled()
        local lx1 = rx0 - u(10)
        ev(D.text(lx1, cy, 6, u(13), on and "On" or "Off", COL.white, 0.72, false, K.font))
        local px0 = switch_shape(lx1 - u(27), cy, on)
        add_region(px0 - u(4), cy - u(16), lx1 + u(2), cy + u(16), "switch", { id = "switch" })

        ev(D.rect(x0 + 1, y0 + hh - 1, x1, y0 + hh, COL.white, 0.07))
        return y0 + hh
    end

    local function draw_section(sec, y, x0, x1)
        local id = sec.id
        local hh = u(38)
        local cy = y + hh / 2
        local open = ui.expanded[id]
        local on, n, badge = spec.section_info(id)
        local lit = on ~= false

        ev(D.rect(x0 + 1, y, x1, y + hh, is_hover("section", id) and COL.header_hover or COL.header, 1))
        ev(D.rect(x0 + 1, y + hh - 1, x1, y + hh, COL.black, 0.4))
        K.icon_chevron(x0 + u(18), cy, open, COL.white, 0.6)
        sec.icon(x0 + u(40), cy, COL.white, lit and 0.9 or 0.4)
        ev(D.text(x0 + u(58), cy, 4, u(15), sec.label, COL.white, lit and 1 or 0.45, true, K.font))
        add_region(x0, y, x1, y + hh, "section", { id = id })

        -- right side: on/off (eye), reset, change badge
        local rx = x1 - u(26)
        if on ~= nil then
            hover_bg(rx - u(14), cy - u(13), rx + u(14), cy + u(13), is_hover("section_eye", id))
            K.icon_eye(rx, cy, on, COL.white, on and 0.8 or 0.55)
            add_region(rx - u(15), y, rx + u(15), y + hh, "section_eye", { id = id })
            rx = rx - u(31)
        end
        if n > 0 then
            hover_bg(rx - u(13), cy - u(13), rx + u(13), cy + u(13), is_hover("section_reset", id))
            K.icon_reset(rx, cy, COL.white, 0.7, 5)
            add_region(rx - u(14), y, rx + u(14), y + hh, "section_reset", { id = id })
            ev(D.text(rx - u(18), cy, 6, u(12.5), badge, lit and K.accent_text or COL.white, lit and 1 or 0.4, false, K.font))
        end
        y = y + hh
        if open then y = spec.draw_section(sec, y, x0, x1, not lit) end
        return y
    end

    -----------------------------------------------------------------------------------------------
    -- Rows. Each takes a top y and the panel's x range, and returns the next y. Labels sit on the
    -- left; controls start at the same x as slider tracks.

    local function row_label(x0, cy, label, op)
        ev(D.text(x0 + u(18), cy, 4, u(14.5), label, COL.white, 0.82 * op, false, K.font))
        return x0 + u(108)
    end

    local function slider_value(d) return slider.get(d) end
    local function slider_changed(d)
        if slider.changed then return slider.changed(d) end
        return math.abs(slider_value(d) - d.default) > 1e-9
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

    function K.draw_slider(d, y, x0, x1, dim)
        local rh = u(32)
        local cy = y + rh / 2
        local v = slider_value(d)
        local changed = slider_changed(d)
        local op = dim and 0.45 or 1

        local tx0 = row_label(x0, cy, d.label, op)
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
            ev(D.rect(math.min(zx, vx), cy - th / 2, math.max(zx, vx), cy + th / 2, K.accent, op, th / 2))
        end
        local active = (ui.drag and ui.drag.kind == "slider" and ui.drag.id == d.id) or is_hover("slider", d.id)
        local r = active and u(7.5) or u(6.5)
        ev(D.circle(vx, cy, r + u(1.5), COL.black, 0.4))
        ev(D.circle(vx, cy, r, COL.white, op))

        local scrubbing = ui.drag and ui.drag.kind == "value" and ui.drag.id == d.id
        if is_hover("value", d.id) or scrubbing then
            ev(D.rect(x1 - u(74), cy - u(11), x1 - u(10), cy + u(11), COL.white, 0.08, u(5)))
        end
        ev(D.text(x1 - u(16), cy, 6, u(14.5), slider.format(d, v), changed and K.accent_text or COL.white,
                  (changed and 1 or 0.6) * op, false, K.font))

        add_region(x0, y, tx0 - u(9), y + rh, "slider_label", { id = d.id, def = d })
        add_region(tx0 - u(9), y, tx1 + u(9), y + rh, "slider", { id = d.id, def = d, tx0 = tx0, tx1 = tx1 })
        add_region(tx1 + u(9), y, x1, y + rh, "value", { id = d.id, def = d, tx0 = tx0, tx1 = tx1 })
        return y + rh
    end

    -- A label and an on/off switch.
    function K.draw_toggle(id, label, on, changed, y, x0, x1, dim)
        local rh = u(32)
        local cy = y + rh / 2
        local op = dim and 0.45 or 1
        row_label(x0, cy, label, op)
        if changed then ev(D.circle(x1 - u(64), cy, u(2.5), K.accent_text, op)) end
        switch_shape(x1 - u(16), cy, on, op)
        add_region(x0, y, x1, y + rh, "toggle", { id = id })
        return y + rh
    end

    -- Color dots to pick from; the last one is "another color", which shows the current color
    -- when it isn't one of the dots.
    function K.draw_swatches(id, label, colors, current, changed, y, x0, x1, dim)
        local rh = u(34)
        local cy = y + rh / 2
        local op = dim and 0.45 or 1
        local x = row_label(x0, cy, label, op) + u(9)
        local found = false
        local function dot(cx, col, selected, value)
            if selected then
                ring(cx, cy, u(12.5), u(1.6), COL.white, 0.95 * op)
            elseif is_hover("swatch", id, value) then
                ring(cx, cy, u(12.5), u(1.2), COL.white, 0.35 * op)
            end
            if col then
                ev(D.circle(cx, cy, u(8.5), col, op))
                ring(cx, cy, u(8.5), u(1), COL.white, 0.22 * op)
            end
            add_region(cx - u(13), cy - u(14), cx + u(13), cy + u(14), "swatch", { id = id, value = value })
        end
        for _, col in ipairs(colors) do
            local sel = col:upper() == current:upper()
            found = found or sel
            dot(x, col, sel, col)
            x = x + u(27)
        end
        if found then
            ring(x, cy, u(8.5), u(1.2), COL.white, 0.45 * op)
            strokes({ { { x - u(4), cy }, { x + u(4), cy } }, { { x, cy - u(4) }, { x, cy + u(4) } } }, u(1.4), COL.white, 0.7 * op)
            dot(x, nil, false, "custom")
        else
            dot(x, current, true, "custom")
        end
        if changed then ev(D.circle(x1 - u(16), cy, u(2.5), K.accent_text, op)) end
        return y + rh
    end

    -- A box showing the current choice; clicking it is the panel's business (usually a list).
    function K.draw_choice(id, label, text, changed, y, x0, x1, dim)
        local rh = u(36)
        local cy = y + rh / 2
        local op = dim and 0.45 or 1
        local bx0 = row_label(x0, cy, label, op)
        local bx1 = x1 - u(16)
        local hov = is_hover("choice", id)
        ev(D.rect(bx0, cy - u(13), bx1, cy + u(13), COL.white, (hov and 0.12 or 0.06) * op, u(5)))
        ev(D.outline(D.rrect_path(bx0, cy - u(13), bx1, cy + u(13), u(5)), 1, COL.white, 0.12 * op))
        ev(D.text(bx0 + u(10), cy, 4, u(14), text, changed and K.accent_text or COL.white, 0.95 * op, false, K.font))
        K.icon_chevron(bx1 - u(14), cy, true, COL.white, 0.6 * op)
        add_region(bx0, cy - u(14), bx1, cy + u(14), "choice", { id = id })
        return y + rh
    end

    -- A row of options, the chosen one inverted like a selected menu item.
    function K.draw_segments(id, label, items, current, y, x0, x1, dim)
        local rh = u(34)
        local cy = y + rh / 2
        local op = dim and 0.45 or 1
        local sx0 = row_label(x0, cy, label, op)
        local sx1 = x1 - u(16)
        ev(D.rect(sx0, cy - u(12), sx1, cy + u(12), COL.white, 0.06 * op, u(6)))
        local w = (sx1 - sx0) / #items
        for i, item in ipairs(items) do
            local ix0 = sx0 + (i - 1) * w
            local sel = item[1] == current
            if sel then
                ev(D.rect(ix0 + u(2), cy - u(10), ix0 + w - u(2), cy + u(10), COL.white, op, u(5)))
            elseif is_hover("segment", id, item[1]) then
                ev(D.rect(ix0 + u(2), cy - u(10), ix0 + w - u(2), cy + u(10), COL.white, 0.1 * op, u(5)))
            end
            ev(D.text(ix0 + w / 2, cy, 5, u(13), item[2], sel and COL.bg or COL.white, (sel and 1 or 0.72) * op, false, K.font))
            add_region(ix0, cy - u(12), ix0 + w, cy + u(12), "segment", { id = id, value = item[1] })
        end
        return y + rh
    end

    -----------------------------------------------------------------------------------------------
    -- Rendering

    local function render()
        ui.redraw_pending = false
        if not ui.open or ui.w <= 0 then return end
        events, ui.regions, clip_box = {}, {}, nil
        D.set_clip(nil)

        local W = math.floor(u(spec.opts.panel_width))
        local x0, x1 = ui.w - W, ui.w
        -- Keep clear of the OSC: its bottom bar, and in fullscreen/borderless its window-controls bar.
        local yt = (ui.fullscreen or not ui.border) and math.floor(u(spec.opts.top_margin)) or 0
        local yb = ui.h - math.floor(u(spec.opts.bottom_margin))
        if yb - yt < u(320) then yt, yb = 0, ui.h end
        -- The panel is only as tall as what's open, so its surface is slotted in underneath
        -- (events 1 and 2) once the content has been laid out.
        ev("")
        ev("")
        local y = draw_header(x0, x1, yt)
        if spec.body_top then y = spec.body_top(x0, x1, y) end

        local ay0, ay1 = y, yb
        clip_box = { x0, ay0, x1, ay1 }
        D.set_clip(x0, ay0, x1, ay1)
        local cy = ay0 - ui.scroll
        for _, sec in ipairs(spec.sections) do cy = draw_section(sec, cy, x0, x1) end
        if spec.draw_footer then cy = spec.draw_footer(cy, x0, x1) end
        local content = cy + ui.scroll - ay0
        clip_box = nil
        D.set_clip(nil)

        ui.scrollable = math.max(0, content - (ay1 - ay0))
        if ui.scroll > ui.scrollable then
            ui.scroll = ui.scrollable
            K.redraw()
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
            mp.set_mouse_area(0, 0, ui.w, ui.h, input_section)
        else
            mp.set_mouse_area(x0, yt, x1, bottom, input_section)
        end
    end

    function K.redraw()
        if ui.open and not ui.redraw_pending then
            ui.redraw_pending = true
            mp.add_timeout(1 / 60, render)
        end
    end

    -----------------------------------------------------------------------------------------------
    -- Editing

    function K.changed()
        spec.changed()
        K.redraw()
    end

    local function set_value(d, v)
        if slider_value(d) ~= v then
            slider.set(d, v)
            K.changed()
        end
    end

    function K.prompt(label, default, apply)
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
        K.prompt(d.label .. ":", slider.edit_text(d, slider_value(d)), function(text)
            local v = slider.parse(d, text)
            if v then set_value(d, v) end
        end)
    end

    -----------------------------------------------------------------------------------------------
    -- Mouse handling

    local function update_drag(mx, my)
        local d = ui.drag
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
            set_value(def, slider.clamp(def, v, d.fine))
        elseif d.kind == "value" then
            if math.abs(mx - d.start_x) > u(3) then d.moved = true end
            if d.moved then
                local steps = (mx - d.start_x) / u(d.fine and 8 or 2)
                set_value(d.def, slider.clamp(d.def, d.start_v + steps * (d.fine and d.def.fine or d.def.step), d.fine))
            end
        elseif spec.drag then
            spec.drag(d, mx, my)
        end
    end

    local function click(r)
        local k = r.kind
        if k == "close" then K.close()
        elseif k == "reset_all" then spec.reset_all(); K.changed()
        elseif k == "switch" then spec.switch(); K.changed()
        elseif k == "section" then ui.expanded[r.id] = not ui.expanded[r.id]; K.redraw()
        elseif k == "section_eye" then spec.section_eye(r.id); K.changed()
        elseif k == "section_reset" then spec.section_reset(r.id); K.changed()
        elseif k == "value" then prompt_slider(r.def)
        elseif spec.click then spec.click(r)
        end
    end

    local function on_down(fine)
        local mx, my = mouse_pos()
        local r = hit(mx, my)
        ui.press = r
        if not r then return end
        if r.kind == "slider" then
            ui.drag = { kind = "slider", id = r.id, def = r.def, region = r, fine = fine,
                        start_x = mx, start_v = slider_value(r.def) }
            if not fine then update_drag(mx, my) end
        elseif r.kind == "value" then
            ui.drag = { kind = "value", id = r.id, def = r.def, region = r, fine = fine,
                        start_x = mx, start_v = slider_value(r.def), moved = false }
        elseif spec.down then
            ui.drag = spec.down(r, mx, my, fine)
        end
        K.redraw()
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
            if spec.release then spec.release(d) end
        elseif ui.press then
            local r = hit(mouse_pos())
            if same(r, ui.press) then click(ui.press) end
        end
        ui.press = nil
        K.redraw()
    end

    local function on_dbl()
        local mx, my = mouse_pos()
        local r = hit(mx, my)
        if not r then return end
        if r.kind == "slider" or r.kind == "slider_label" or r.kind == "value" then
            ui.drag = nil
            set_value(r.def, r.def.default)
        elseif spec.dbl then
            spec.dbl(r, mx, my)
        end
    end

    local function on_wheel(dir)
        if ui.scrollable > 0 then
            ui.scroll = clamp(ui.scroll + dir * u(60), 0, ui.scrollable)
            K.redraw()
            return
        end
        local r = hit(mouse_pos())
        if r and (r.kind == "slider" or r.kind == "slider_label" or r.kind == "value") then
            set_value(r.def, slider.clamp(r.def, slider_value(r.def) - dir * r.def.step))
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
            K.redraw()
        end
    end

    -----------------------------------------------------------------------------------------------
    -- Opening, closing, docking

    local function update_dims()
        local d = mp.get_property_native("osd-dimensions")
        if not d or d.w <= 0 then return false end
        ui.w, ui.h = d.w, d.h
        ui.fullscreen = mp.get_property_native("fullscreen")
        ui.border = mp.get_property_native("border") and mp.get_property_native("title-bar", true)
        ui.s = ui.fullscreen and spec.opts.scale_fullscreen or spec.opts.scale
        return true
    end

    -- Shrinks the video so the panel sits beside it instead of covering it. The margin the video had
    -- before any panel opened is kept in user-data, so switching between panels doesn't lose it.
    local BASE = "user-data/kit-panel/base-margin"
    local function dock(on)
        local base = mp.get_property_native(BASE)
        if on then
            if base == nil then
                base = mp.get_property_number("video-margin-ratio-right", 0)
                mp.set_property_native(BASE, base)
            end
            if ui.w > 0 then
                mp.set_property_number("video-margin-ratio-right", math.min(0.8, base + u(spec.opts.panel_width) / ui.w))
            end
        elseif base ~= nil then
            mp.set_property_number("video-margin-ratio-right", base)
            mp.del_property(BASE)
        end
    end

    function K.is_open() return ui.open end

    function K.open()
        if ui.open then return end
        ui.open = true
        update_dims()
        mp.set_key_bindings({
            { "mbtn_left", on_up, function() on_down(false) end },
            { "shift+mbtn_left", on_up, function() on_down(true) end },
            { "mbtn_left_dbl", on_dbl },
            { "wheel_up", function() on_wheel(-1) end },
            { "wheel_down", function() on_wheel(1) end },
        }, input_section, "force")
        mp.enable_key_bindings(input_section)
        mp.add_forced_key_binding("ESC", spec.name .. "-close", K.close)
        dock(true)
        mp.commandv("script-message", "kit-panel-opened", spec.name)   -- closes any other panel
        spec.on_open_changed(true)
        K.redraw()
    end

    -- handoff: another panel is taking the space, so the video keeps its margin.
    function K.close(handoff)
        if not ui.open then return end
        ui.open, ui.drag, ui.hover, ui.press = false, nil, nil, nil
        overlay:remove()
        mp.disable_key_bindings(input_section)
        mp.remove_key_binding(spec.name .. "-close")
        if handoff ~= true then dock(false) end
        spec.on_open_changed(false)
    end

    function K.toggle()
        if ui.open then K.close() else K.open() end
    end

    function K.set_section(id, open)
        if ui.expanded[id] ~= nil then ui.expanded[id] = open; K.redraw() end
    end

    function K.init()
        K.font = (spec.opts.font ~= "" and spec.opts.font) or mp.get_property("osd-font", "sans-serif")
        K.accent = spec.opts.accent
        K.accent_text = D.mix(K.accent, "#FFFFFF", 0.3)
        local function refit()
            if ui.open and update_dims() then
                dock(true)
                K.redraw()
            end
        end
        mp.observe_property("osd-dimensions", "native", refit)
        for _, prop in ipairs({ "fullscreen", "border", "title-bar" }) do mp.observe_property(prop, "bool", refit) end
        mp.observe_property("mouse-pos", "native", on_mouse_move)
        mp.register_script_message("kit-panel-opened", function(who)
            if who ~= spec.name then K.close(true) end
        end)
    end

    return K
end

return M

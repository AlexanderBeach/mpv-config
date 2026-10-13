-- ASS drawing helpers. Every function returns one complete ASS event in OSD pixel coordinates.
-- Colors are "#RRGGBB"; opacity is 0..1.
local D = {}

local clip_tag = ""
local KAPPA = 0.5523

local function n(v) return string.format("%.2f", v) end

local function ass_color(hex)
    hex = hex:gsub("#", "")
    return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
end

local function ass_alpha(op)
    op = math.max(0, math.min(1, op or 1))
    return string.format("%02X", math.floor((1 - op) * 255 + 0.5))
end

-- Mixes two "#RRGGBB" colors; t = 0 gives a, t = 1 gives b.
function D.mix(a, b, t)
    local function ch(hex, i) return tonumber(hex:sub(i, i + 1), 16) end
    a, b = a:gsub("#", ""), b:gsub("#", "")
    local out = "#"
    for i = 1, 5, 2 do
        out = out .. string.format("%02X", math.floor(ch(a, i) + (ch(b, i) - ch(a, i)) * t + 0.5))
    end
    return out
end

function D.grey(v)   -- 0..1
    local c = string.format("%02X", math.floor(math.max(0, math.min(1, v)) * 255 + 0.5))
    return "#" .. c .. c .. c
end

-- Clips every following event to a rectangle (nil to stop).
function D.set_clip(x0, y0, x1, y1)
    clip_tag = x0 and string.format("\\clip(%d,%d,%d,%d)", math.floor(x0), math.floor(y0),
                                    math.ceil(x1), math.ceil(y1)) or ""
end

local function head() return "{\\an7\\pos(0,0)\\shad0\\blur0\\q2" .. clip_tag end

-- Paths ------------------------------------------------------------------------------------------

function D.rect_path(x0, y0, x1, y1)
    return string.format("m %s %s l %s %s l %s %s l %s %s", n(x0), n(y0), n(x1), n(y0), n(x1), n(y1), n(x0), n(y1))
end

function D.rrect_path(x0, y0, x1, y1, r)
    r = math.min(r, (x1 - x0) / 2, (y1 - y0) / 2)
    if r <= 0.5 then return D.rect_path(x0, y0, x1, y1) end
    local k = r * (1 - KAPPA)
    return string.format(
        "m %s %s l %s %s b %s %s %s %s %s %s l %s %s b %s %s %s %s %s %s l %s %s b %s %s %s %s %s %s l %s %s b %s %s %s %s %s %s",
        n(x0 + r), n(y0), n(x1 - r), n(y0),
        n(x1 - k), n(y0), n(x1), n(y0 + k), n(x1), n(y0 + r),
        n(x1), n(y1 - r),
        n(x1), n(y1 - k), n(x1 - k), n(y1), n(x1 - r), n(y1),
        n(x0 + r), n(y1),
        n(x0 + k), n(y1), n(x0), n(y1 - k), n(x0), n(y1 - r),
        n(x0), n(y0 + r),
        n(x0), n(y0 + k), n(x0 + k), n(y0), n(x0 + r), n(y0))
end

function D.circle_path(cx, cy, r)
    local c = r * KAPPA
    return string.format(
        "m %s %s b %s %s %s %s %s %s b %s %s %s %s %s %s b %s %s %s %s %s %s b %s %s %s %s %s %s",
        n(cx), n(cy - r),
        n(cx + c), n(cy - r), n(cx + r), n(cy - c), n(cx + r), n(cy),
        n(cx + r), n(cy + c), n(cx + c), n(cy + r), n(cx), n(cy + r),
        n(cx - c), n(cy + r), n(cx - r), n(cy + c), n(cx - r), n(cy),
        n(cx - r), n(cy - c), n(cx - c), n(cy - r), n(cx), n(cy - r))
end

function D.poly_path(pts)
    local parts = {}
    for i, p in ipairs(pts) do
        parts[#parts + 1] = (i == 1 and "m " or (i == 2 and "l " or "")) .. n(p[1]) .. " " .. n(p[2])
    end
    return table.concat(parts, " ")
end

-- A polyline as a single outline polygon (left edge forward, right edge back) with mitred joins.
-- Overlapping pieces would cancel out under libass's fill rule, so the stroke is one shape.
function D.polyline_path(pts, w)
    local p = {}
    for _, q in ipairs(pts) do
        local last = p[#p]
        if not last or math.abs(last[1] - q[1]) + math.abs(last[2] - q[2]) > 1e-3 then p[#p + 1] = q end
    end
    local count = #p
    if count < 2 then return "" end
    local h = w / 2
    local function dir(a, b)
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local l = math.sqrt(dx * dx + dy * dy)
        return dx / l, dy / l
    end
    local left, right = {}, {}
    for i = 1, count do
        local ax, ay, bx, by
        if i > 1 then ax, ay = dir(p[i - 1], p[i]) end
        if i < count then bx, by = dir(p[i], p[i + 1]) end
        ax, ay, bx, by = ax or bx, ay or by, bx or ax, by or ay
        local mx, my = -ay - by, ax + bx          -- sum of the two segment normals
        local ml = math.sqrt(mx * mx + my * my)
        if ml < 1e-6 then mx, my, ml = -ay, ax, 1 end
        mx, my = mx / ml, my / ml
        local len = h / math.max(mx * -ay + my * ax, 0.4)   -- miter length, capped on sharp turns
        left[i] = n(p[i][1] + mx * len) .. " " .. n(p[i][2] + my * len)
        right[i] = n(p[i][1] - mx * len) .. " " .. n(p[i][2] - my * len)
    end
    local parts = { "m " .. left[1], "l" }
    for i = 2, count do parts[#parts + 1] = left[i] end
    for i = count, 1, -1 do parts[#parts + 1] = right[i] end
    return table.concat(parts, " ")
end

-- Events -----------------------------------------------------------------------------------------

function D.fill(path, col, op)
    return head() .. "\\bord0\\1c&H" .. ass_color(col) .. "&\\1a&H" .. ass_alpha(op) .. "&\\p1}" .. path .. "{\\p0}"
end

-- Outline of a closed path, drawn outside it (libass borders don't cover the shape itself).
function D.outline(path, width, col, op)
    return head() .. "\\bord" .. n(width) .. "\\1a&HFF&\\3c&H" .. ass_color(col) .. "&\\3a&H" .. ass_alpha(op)
           .. "&\\p1}" .. path .. "{\\p0}"
end

function D.rect(x0, y0, x1, y1, col, op, r)
    return D.fill(r and r > 0 and D.rrect_path(x0, y0, x1, y1, r) or D.rect_path(x0, y0, x1, y1), col, op)
end

function D.circle(cx, cy, r, col, op) return D.fill(D.circle_path(cx, cy, r), col, op) end

function D.line(pts, w, col, op) return D.fill(D.polyline_path(pts, w), col, op) end

function D.escape(s)
    s = s:gsub("\\", "\\\239\187\191"):gsub("{", "\\{"):gsub("}", "\\}")   -- a zero-width no-break space keeps "\N" etc. literal
    return (s:gsub("\n", "\\N"))
end

D.text_scale = 1.1   -- ASS font sizes run small next to ModernZ's text; this evens them out

-- an = ASS alignment (numpad layout: 4 = left-middle, 5 = centre, 6 = right-middle, 7 = top-left)
function D.text(x, y, an, size, str, col, op, bold, font)
    return string.format("{\\an%d\\pos(%s,%s)\\q2\\fn%s\\fs%s\\b%d\\bord0\\shad0\\blur0%s\\1c&H%s&\\1a&H%s&}%s",
        an, n(x), n(y), font, n(size * D.text_scale), bold and 1 or 0, clip_tag, ass_color(col), ass_alpha(op), D.escape(str))
end

return D

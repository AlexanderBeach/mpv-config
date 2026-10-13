-- Monotone cubic interpolation (Fritsch-Carlson) for tone curves.
-- Points are {x, y} pairs in 0..1, sorted by x. The curve never overshoots its points,
-- and is flat beyond the first and last point (like Photoshop's curves).
local M = {}

function M.prepare(points)
    local n = #points
    local xs, ys, m = {}, {}, {}
    for i, p in ipairs(points) do xs[i], ys[i] = p[1], p[2] end
    if n < 2 then return { xs = xs, ys = ys, m = { 0 } } end

    local d = {}
    for i = 1, n - 1 do
        local dx = xs[i + 1] - xs[i]
        d[i] = dx > 0 and (ys[i + 1] - ys[i]) / dx or 0
    end
    m[1], m[n] = d[1], d[n - 1]
    for i = 2, n - 1 do
        m[i] = (d[i - 1] * d[i] <= 0) and 0 or (d[i - 1] + d[i]) / 2
    end
    for i = 1, n - 1 do
        if d[i] == 0 then
            m[i], m[i + 1] = 0, 0
        else
            local a, b = m[i] / d[i], m[i + 1] / d[i]
            local s = a * a + b * b
            if s > 9 then
                local t = 3 / math.sqrt(s)
                m[i], m[i + 1] = t * a * d[i], t * b * d[i]
            end
        end
    end
    return { xs = xs, ys = ys, m = m }
end

function M.eval(c, x)
    local xs, ys, m = c.xs, c.ys, c.m
    local n = #xs
    if n == 0 then return x end
    if x <= xs[1] then return ys[1] end
    if x >= xs[n] then return ys[n] end
    local k = 1
    while x > xs[k + 1] do k = k + 1 end
    local h = xs[k + 1] - xs[k]
    local t = (x - xs[k]) / h
    local t2, t3 = t * t, t * t * t
    local y = (2 * t3 - 3 * t2 + 1) * ys[k] + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * ys[k + 1] + (t3 - t2) * h * m[k + 1]
    if y < 0 then return 0 elseif y > 1 then return 1 end
    return y
end

return M

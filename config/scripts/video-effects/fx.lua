-- Effect model: the adjustable values and their defaults, the GLSL shader they drive, and a Lua
-- copy of the shader's math so the histogram can show the adjusted picture.
--
-- All adjustments work on the video's own encoded RGB signal (gamma-encoded for SDR, PQ or HLG
-- for HDR), the same domain Photoshop and VLC use. Exposure is the exception: it scales linear
-- light, so it behaves like a camera exposure change.
local curve = require "curve"

local M = {}

local MINUS = "\226\136\146"   -- U+2212, a proper minus sign for displayed values

M.CHANNELS = { "rgb", "r", "g", "b" }
M.CHANNEL_NAMES = { rgb = "RGB", r = "Red", g = "Green", b = "Blue" }
M.SECTIONS = { "light", "color", "curves", "levels" }
M.CURVE_SAMPLES = 33
M.MAX_CURVE_POINTS = 16

M.sliders = {
    { id = "exposure",   section = "light", label = "Exposure",   min = -3,   max = 3,   step = 0.05, fine = 0.01, default = 0 },
    { id = "brightness", section = "light", label = "Brightness", min = -100, max = 100, step = 1, fine = 1, default = 0 },
    { id = "contrast",   section = "light", label = "Contrast",   min = -100, max = 100, step = 1, fine = 1, default = 0 },
    { id = "gamma",      section = "light", label = "Gamma",      min = -100, max = 100, step = 1, fine = 1, default = 0 },
    { id = "highlights", section = "light", label = "Highlights", min = -100, max = 100, step = 1, fine = 1, default = 0 },
    { id = "shadows",    section = "light", label = "Shadows",    min = -100, max = 100, step = 1, fine = 1, default = 0 },
    { id = "whites",     section = "light", label = "Whites",     min = -100, max = 100, step = 1, fine = 1, default = 0 },
    { id = "blacks",     section = "light", label = "Blacks",     min = -100, max = 100, step = 1, fine = 1, default = 0 },
    { id = "saturation", section = "color", label = "Saturation", min = -100, max = 100, step = 1, fine = 1, default = 0, track = "saturation" },
    { id = "vibrance",   section = "color", label = "Vibrance",   min = -100, max = 100, step = 1, fine = 1, default = 0, track = "saturation" },
    { id = "hue",        section = "color", label = "Hue",        min = -180, max = 180, step = 1, fine = 1, default = 0, track = "hue" },
}
M.slider_by_id = {}
for _, d in ipairs(M.sliders) do M.slider_by_id[d.id] = d end

---------------------------------------------------------------------------------------------------
-- Values

local function round(v) return math.floor(v + 0.5) end

local function signed_int(v)
    v = round(v)
    if v == 0 then return "0" end
    return (string.format("%+d", v):gsub("^%-", MINUS))
end

-- Gamma is stored as a slider position (-100..100) and shown as the gamma value 0.33..3.00.
function M.gamma_from_slider(v) return 3 ^ (v / 100) end
function M.slider_from_gamma(g) return math.log(g) / math.log(3) * 100 end

function M.format_value(d, v)
    if d.id == "exposure" then
        if math.abs(v) < 0.005 then return "0.00 EV" end
        return (string.format("%+.2f EV", v):gsub("^%-", MINUS))
    elseif d.id == "gamma" then
        return string.format("%.2f", M.gamma_from_slider(v))
    elseif d.id == "hue" then
        return signed_int(v) .. "\194\176"
    end
    return signed_int(v)
end

-- The text offered when typing a value, and its reverse.
function M.edit_text(d, v)
    if d.id == "exposure" then return string.format("%.2f", v) end
    if d.id == "gamma" then return string.format("%.2f", M.gamma_from_slider(v)) end
    return tostring(round(v))
end

function M.clamp_value(d, v, fine)
    local step = fine and d.fine or d.step
    v = math.max(d.min, math.min(d.max, v))
    v = round(v / step) * step
    if math.abs(v) < 1e-9 then v = 0 end
    return v
end

function M.parse_value(d, text)
    text = text:gsub(MINUS, "-"):gsub(",", ".")
    local n = tonumber(text:match("[-+]?%d*%.?%d+"))
    if not n then return nil end
    if d.id == "gamma" then
        if n <= 0 then return nil end
        n = M.slider_from_gamma(n)
    end
    return M.clamp_value(d, n, true)
end

---------------------------------------------------------------------------------------------------
-- State

local function identity_levels() return { ib = 0, iw = 255, g = 1, ob = 0, ow = 255 } end
local function identity_curve() return { { 0, 0 }, { 255, 255 } } end

function M.new_state()
    local s = { values = {}, levels = {}, curves = {}, enabled = true, section_on = {} }
    for _, d in ipairs(M.sliders) do s.values[d.id] = d.default end
    for _, ch in ipairs(M.CHANNELS) do
        s.levels[ch] = identity_levels()
        s.curves[ch] = identity_curve()
    end
    for _, id in ipairs(M.SECTIONS) do s.section_on[id] = true end
    return s
end

function M.reset_section(s, section)
    if section == "light" or section == "color" then
        for _, d in ipairs(M.sliders) do
            if d.section == section then s.values[d.id] = d.default end
        end
    elseif section == "curves" then
        for _, ch in ipairs(M.CHANNELS) do s.curves[ch] = identity_curve() end
    elseif section == "levels" then
        for _, ch in ipairs(M.CHANNELS) do s.levels[ch] = identity_levels() end
    end
end

function M.reset_all(s)
    for _, id in ipairs(M.SECTIONS) do
        M.reset_section(s, id)
        s.section_on[id] = true
    end
end

function M.reset_curve(s, ch) s.curves[ch] = identity_curve() end
function M.reset_levels(s, ch) s.levels[ch] = identity_levels() end
function M.levels_default(which) return identity_levels()[which] end

function M.slider_changed(s, d) return math.abs(s.values[d.id] - d.default) > 1e-9 end

function M.levels_changed(lv)
    return lv.ib ~= 0 or lv.iw ~= 255 or math.abs(lv.g - 1) > 1e-6 or lv.ob ~= 0 or lv.ow ~= 255
end

function M.curve_changed(pts)
    return #pts ~= 2 or pts[1][1] ~= 0 or pts[1][2] ~= 0 or pts[2][1] ~= 255 or pts[2][2] ~= 255
end

-- How many things in a section differ from their defaults.
function M.changed_count(s, section)
    local n = 0
    if section == "light" or section == "color" then
        for _, d in ipairs(M.sliders) do
            if d.section == section and M.slider_changed(s, d) then n = n + 1 end
        end
    else
        for _, ch in ipairs(M.CHANNELS) do
            local changed = section == "curves" and M.curve_changed(s.curves[ch]) or
                            section == "levels" and M.levels_changed(s.levels[ch])
            if changed then n = n + 1 end
        end
    end
    return n
end

-- True when nothing would change the picture, so the shader can be unloaded entirely.
function M.is_neutral(s)
    if not s.enabled then return true end
    for _, id in ipairs(M.SECTIONS) do
        if s.section_on[id] and M.changed_count(s, id) > 0 then return false end
    end
    return true
end

---------------------------------------------------------------------------------------------------
-- Shader parameters

local LEVEL_KEY = { rgb = "m", r = "r", g = "g", b = "b" }
local PIVOT = { [0] = 0.5, [1] = 0.41, [2] = 0.38 }   -- mid-grey in SDR gamma, PQ and HLG signals

-- The transfer function and the stage switches (f_*) are preprocessor defines, so a stage whose
-- setting is neutral is compiled out of the shader: D3D11's compiler flattens ordinary branches
-- and would run every stage on every pixel. Changing a define rebuilds the shader (cached after
-- the first time); every other value is a live uniform that never triggers a rebuild.
-- Entries are { name, neutral value, max } where a max marks the parameter as a define.
local PARAMS = {
    { "transfer", 0, 2 },
    { "f_exposure", 0, 1 }, { "f_bc", 0, 1 }, { "f_tone", 0, 1 }, { "f_gamma", 0, 1 },
    { "f_levels", 0, 1 }, { "f_curves", 0, 1 }, { "f_sat", 0, 1 }, { "f_hue", 0, 1 },
    { "luma_r", 0.2126 }, { "luma_g", 0.7152 }, { "luma_b", 0.0722 }, { "pivot", 0.5 },
    { "exposure", 0 }, { "brightness", 0 }, { "contrast", 1 }, { "gamma", 1 },
    { "highlights", 0 }, { "shadows", 0 }, { "whites", 0 }, { "blacks", 0 },
    { "saturation", 0 }, { "vibrance", 0 }, { "hue", 0 },
}
for _, ch in ipairs(M.CHANNELS) do
    local k = "l" .. LEVEL_KEY[ch] .. "_"
    for _, p in ipairs({ { "ib", 0 }, { "iw", 1 }, { "g", 1 }, { "ob", 0 }, { "ow", 1 } }) do
        PARAMS[#PARAMS + 1] = { k .. p[1], p[2] }
    end
end
for _, ch in ipairs({ "r", "g", "b" }) do
    for i = 0, M.CURVE_SAMPLES - 1 do
        PARAMS[#PARAMS + 1] = { "c" .. ch .. i, i / (M.CURVE_SAMPLES - 1) }
    end
end

local function prepared_curve(pts)
    local norm = {}
    for i, p in ipairs(pts) do norm[i] = { p[1] / 255, p[2] / 255 } end
    return curve.prepare(norm)
end

-- video = { transfer = 0 (SDR) | 1 (PQ) | 2 (HLG), luma = { r, g, b } }
function M.params(s, video)
    local P = {}
    for _, p in ipairs(PARAMS) do P[p[1]] = p[2] end
    P.transfer = video.transfer
    P.luma_r, P.luma_g, P.luma_b = video.luma[1], video.luma[2], video.luma[3]
    P.pivot = PIVOT[video.transfer] or 0.5

    local on = s.section_on
    local v = s.values
    if on.light then
        P.exposure = v.exposure
        P.brightness = v.brightness / 100 * 0.3
        P.contrast = v.contrast >= 0 and 1 + v.contrast / 100 * 1.5 or 1 + v.contrast / 100 * 0.8
        P.gamma = M.gamma_from_slider(v.gamma)
        P.highlights, P.shadows = v.highlights / 100, v.shadows / 100
        P.whites, P.blacks = v.whites / 100, v.blacks / 100
    end
    if on.color then
        P.saturation, P.vibrance, P.hue = v.saturation / 100, v.vibrance / 100, v.hue
    end
    if on.levels then
        for _, ch in ipairs(M.CHANNELS) do
            local lv = s.levels[ch]
            if M.levels_changed(lv) then
                local k = "l" .. LEVEL_KEY[ch] .. "_"
                P[k .. "ib"], P[k .. "iw"], P[k .. "g"] = lv.ib / 255, lv.iw / 255, lv.g
                P[k .. "ob"], P[k .. "ow"] = lv.ob / 255, lv.ow / 255
                P.f_levels = 1
            end
        end
    end
    if on.curves then
        -- The master curve is folded into each color channel's lookup table.
        local master = M.curve_changed(s.curves.rgb) and prepared_curve(s.curves.rgb) or nil
        for _, ch in ipairs({ "r", "g", "b" }) do
            local own = M.curve_changed(s.curves[ch]) and prepared_curve(s.curves[ch]) or nil
            if master or own then
                P.f_curves = 1
                for i = 0, M.CURVE_SAMPLES - 1 do
                    local y = i / (M.CURVE_SAMPLES - 1)
                    if master then y = curve.eval(master, y) end
                    if own then y = curve.eval(own, y) end
                    P["c" .. ch .. i] = y
                end
            end
        end
    end

    local function flag(b) return b and 1 or 0 end
    P.f_exposure = flag(P.exposure ~= 0)
    P.f_bc = flag(P.brightness ~= 0 or P.contrast ~= 1)
    P.f_tone = flag(P.shadows ~= 0 or P.highlights ~= 0 or P.whites ~= 0 or P.blacks ~= 0)
    P.f_gamma = flag(P.gamma ~= 1)
    P.f_sat = flag(P.saturation ~= 0 or P.vibrance ~= 0)
    P.f_hue = flag(P.hue ~= 0)
    return P
end

function M.shader_opts(P)
    local t = {}
    for _, p in ipairs(PARAMS) do
        t["fx_" .. p[1]] = p[3] and string.format("%d", P[p[1]]) or string.format("%.6f", P[p[1]])
    end
    return t
end

-- The curve shape of one channel (master included) for drawing, as 0..1 samples.
function M.curve_points_for_drawing(pts, n)
    local c = prepared_curve(pts)
    local out = {}
    for i = 0, n - 1 do
        local x = i / (n - 1)
        out[#out + 1] = { x, curve.eval(c, x) }
    end
    return out
end

---------------------------------------------------------------------------------------------------
-- Lua copy of the shader, used for the adjusted histogram. Keep it in step with SHADER_BODY.

local PQ_M1, PQ_M2 = 0.1593017578125, 78.84375
local PQ_C1, PQ_C2, PQ_C3 = 0.8359375, 18.8515625, 18.6875
local HLG_A, HLG_B, HLG_C = 0.17883277, 0.28466892, 0.55991073

local function clamp01(x) if x < 0 then return 0 elseif x > 1 then return 1 end return x end

local TO_LINEAR = {
    [0] = function(e) return (e > 0 and e or 0) ^ 2.4 end,
    [1] = function(e)
        local p = clamp01(e) ^ (1 / PQ_M2)
        local num = p - PQ_C1
        if num < 0 then num = 0 end
        return (num / (PQ_C2 - PQ_C3 * p)) ^ (1 / PQ_M1)
    end,
    [2] = function(e)
        if e >= 0.5 then return (math.exp((e - HLG_C) / HLG_A) + HLG_B) / 12 end
        return e * e / 3
    end,
}
local FROM_LINEAR = {
    [0] = function(l) return (l > 0 and l or 0) ^ (1 / 2.4) end,
    [1] = function(l)
        local p = clamp01(l) ^ PQ_M1
        return ((PQ_C1 + PQ_C2 * p) / (1 + PQ_C3 * p)) ^ PQ_M2
    end,
    [2] = function(l)
        if l < 0 then l = 0 end
        if l >= 1 / 12 then return HLG_A * math.log(math.max(12 * l - HLG_B, 1e-6)) + HLG_C end
        return math.sqrt(3 * l)
    end,
}

function M.make_pixel_fn(P)
    local N1 = M.CURVE_SAMPLES - 1
    local lr, lg, lb = P.luma_r, P.luma_g, P.luma_b
    local to_lin, from_lin = TO_LINEAR[P.transfer] or TO_LINEAR[0], FROM_LINEAR[P.transfer] or FROM_LINEAR[0]
    local use_exp, gain = P.f_exposure == 1, 2 ^ P.exposure
    local bc_on, br, pv, k = P.f_bc == 1, P.brightness, P.pivot, P.contrast
    local tone_on, sh, hi, bl, wh = P.f_tone == 1, P.shadows, P.highlights, P.blacks, P.whites
    local gamma_on, inv_gamma = P.f_gamma == 1, 1 / P.gamma
    local lv_on = P.f_levels == 1
    local L = {}
    for _, key in ipairs({ "m", "r", "g", "b" }) do
        local p = "l" .. key .. "_"
        L[key] = { P[p .. "ib"], P[p .. "iw"], 1 / P[p .. "g"], P[p .. "ob"], P[p .. "ow"] }
    end
    local cv_on = P.f_curves == 1
    local CR, CG, CB = {}, {}, {}
    for i = 0, N1 do
        CR[i + 1], CG[i + 1], CB[i + 1] = P["cr" .. i], P["cg" .. i], P["cb" .. i]
    end
    local sat_on, sat_k, vib = P.f_sat == 1, P.saturation, P.vibrance
    local hue_on = P.f_hue == 1
    local hcs, hsn = math.cos(math.rad(P.hue)), math.sin(math.rad(P.hue))
    local q = 0.57735027

    local function lev(v, t)
        local d = t[2] - t[1]
        if d < 1e-4 then d = 1e-4 end
        local x = clamp01((v - t[1]) / d) ^ t[3]
        return t[4] + (t[5] - t[4]) * x
    end
    local function lut(v, s)
        local x = clamp01(v) * N1
        local i = math.floor(x)
        if i >= N1 then return s[N1 + 1] end
        return s[i + 1] + (s[i + 2] - s[i + 1]) * (x - i)
    end

    return function(r, g, b)
        if use_exp then
            r, g, b = from_lin(to_lin(r) * gain), from_lin(to_lin(g) * gain), from_lin(to_lin(b) * gain)
        end
        if bc_on then
            r, g, b = (r + br - pv) * k + pv, (g + br - pv) * k + pv, (b + br - pv) * k + pv
        end

        if tone_on then
            local y = clamp01(r * lr + g * lg + b * lb)
            local iy = 1 - y
            local dy = 0.25 * sh * (6.75 * y * iy * iy) + 0.25 * hi * (6.75 * y * y * iy)
                     + 0.15 * bl * (iy * iy * iy) + 0.15 * wh * (y * y * y)
            r, g, b = r + dy, g + dy, b + dy
        end

        if gamma_on then
            r = (r > 0 and r or 0) ^ inv_gamma
            g = (g > 0 and g or 0) ^ inv_gamma
            b = (b > 0 and b or 0) ^ inv_gamma
        end

        if lv_on then
            r, g, b = lev(r, L.m), lev(g, L.m), lev(b, L.m)
            r, g, b = lev(r, L.r), lev(g, L.g), lev(b, L.b)
        end
        if cv_on then
            r, g, b = lut(r, CR), lut(g, CG), lut(b, CB)
        end

        if sat_on then
            local y2 = r * lr + g * lg + b * lb
            local sat = clamp01(math.max(r, g, b) - math.min(r, g, b))
            local s = 1 + sat_k + vib * (1 - sat)
            r, g, b = y2 + (r - y2) * s, y2 + (g - y2) * s, y2 + (b - y2) * s
        end

        if hue_on then
            local third = (r + g + b) / 3 * (1 - hcs)
            -- Rodrigues rotation around the grey axis k = (1,1,1)/sqrt(3); cross(k, c) = q*(b-g, r-b, g-r)
            r, g, b = r * hcs + q * (b - g) * hsn + third,
                      g * hcs + q * (r - b) * hsn + third,
                      b * hcs + q * (g - r) * hsn + third
        end
        return clamp01(r), clamp01(g), clamp01(b)
    end
end

---------------------------------------------------------------------------------------------------
-- GLSL shader (libplacebo user shader). Values are live uniforms; the transfer function and the
-- stage switches are defines, so only the stages in use are compiled in.

local SHADER_HELPERS = [[
vec3 fx_to_linear(vec3 e) {
#if fx_transfer == 0
    return pow(max(e, 0.0), vec3(2.4));
#elif fx_transfer == 1
    vec3 p = pow(clamp(e, 0.0, 1.0), vec3(1.0 / 78.84375));
    return pow(max(p - 0.8359375, 0.0) / (18.8515625 - 18.6875 * p), vec3(1.0 / 0.1593017578125));
#else
    vec3 lo = e * e / 3.0;
    vec3 hi = (exp((e - 0.55991073) / 0.17883277) + 0.28466892) / 12.0;
    return mix(lo, hi, step(vec3(0.5), e));
#endif
}

vec3 fx_from_linear(vec3 l) {
#if fx_transfer == 0
    return pow(max(l, 0.0), vec3(1.0 / 2.4));
#elif fx_transfer == 1
    vec3 p = pow(clamp(l, 0.0, 1.0), vec3(0.1593017578125));
    return pow((0.8359375 + 18.8515625 * p) / (1.0 + 18.6875 * p), vec3(78.84375));
#else
    l = max(l, 0.0);
    vec3 lo = sqrt(3.0 * l);
    vec3 hi = 0.17883277 * log(max(12.0 * l - 0.28466892, 1e-6)) + 0.55991073;
    return mix(lo, hi, step(vec3(1.0 / 12.0), l));
#endif
}

vec3 fx_levels(vec3 c, vec3 ib, vec3 iw, vec3 g, vec3 ob, vec3 ow) {
    vec3 t = clamp((c - ib) / max(iw - ib, vec3(1e-4)), 0.0, 1.0);
    return mix(ob, ow, pow(t, 1.0 / g));
}
]]

local SHADER_BODY = [[
vec4 hook() {
    vec4 color = HOOKED_texOff(0);
    vec3 c = color.rgb;
    vec3 lw = vec3(fx_luma_r, fx_luma_g, fx_luma_b);

#if fx_f_exposure
    c = fx_from_linear(fx_to_linear(c) * exp2(fx_exposure));
#endif

#if fx_f_bc
    c = (c + fx_brightness - fx_pivot) * fx_contrast + fx_pivot;
#endif

#if fx_f_tone
    float y = clamp(dot(c, lw), 0.0, 1.0);
    float iy = 1.0 - y;
    c += 0.25 * fx_shadows * (6.75 * y * iy * iy) + 0.25 * fx_highlights * (6.75 * y * y * iy)
       + 0.15 * fx_blacks * (iy * iy * iy) + 0.15 * fx_whites * (y * y * y);
#endif

#if fx_f_gamma
    c = pow(max(c, 0.0), vec3(1.0 / fx_gamma));
#endif

#if fx_f_levels
    c = fx_levels(c, vec3(fx_lm_ib), vec3(fx_lm_iw), vec3(fx_lm_g), vec3(fx_lm_ob), vec3(fx_lm_ow));
    c = fx_levels(c, vec3(fx_lr_ib, fx_lg_ib, fx_lb_ib), vec3(fx_lr_iw, fx_lg_iw, fx_lb_iw),
                  vec3(fx_lr_g, fx_lg_g, fx_lb_g), vec3(fx_lr_ob, fx_lg_ob, fx_lb_ob),
                  vec3(fx_lr_ow, fx_lg_ow, fx_lb_ow));
#endif

#if fx_f_curves
    c = vec3(fx_curve_r(c.r), fx_curve_g(c.g), fx_curve_b(c.b));
#endif

#if fx_f_sat
    float y2 = dot(c, lw);
    float sat = clamp(max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)), 0.0, 1.0);
    c = mix(vec3(y2), c, 1.0 + fx_saturation + fx_vibrance * (1.0 - sat));
#endif

#if fx_f_hue
    float a = radians(fx_hue);
    float cs = cos(a);
    float sn = sin(a);
    vec3 k = vec3(0.57735027);
    c = c * cs + cross(k, c) * sn + k * dot(k, c) * (1.0 - cs);
#endif

    color.rgb = clamp(c, 0.0, 1.0);
    return color;
}
]]

-- Piecewise-linear lookup through the 33 samples, written out so it needs no arrays.
local function curve_function(ch)
    local n1 = M.CURVE_SAMPLES - 1
    local lines = { string.format("float fx_curve_%s(float x) {", ch),
                    string.format("    float t = clamp(x, 0.0, 1.0) * %d.0;", n1),
                    string.format("    return fx_c%s0", ch) }
    for i = 1, n1 do
        lines[#lines + 1] = string.format("        + (fx_c%s%d - fx_c%s%d) * clamp(t - %d.0, 0.0, 1.0)", ch, i, ch, i - 1, i - 1)
    end
    lines[#lines] = lines[#lines] .. ";"
    lines[#lines + 1] = "}\n"
    return table.concat(lines, "\n")
end

function M.shader_source()
    local out = { "// Generated by the video-effects script on startup; edits here are overwritten.\n\n" }
    for _, p in ipairs(PARAMS) do
        if p[3] then
            out[#out + 1] = string.format("//!PARAM fx_%s\n//!TYPE DEFINE\n//!MINIMUM 0\n//!MAXIMUM %d\n%d\n\n", p[1], p[3], p[2])
        else
            out[#out + 1] = string.format("//!PARAM fx_%s\n//!TYPE DYNAMIC float\n%.6f\n\n", p[1], p[2])
        end
    end
    out[#out + 1] = "//!HOOK MAIN\n//!BIND HOOKED\n//!DESC video effects\n\n"
    out[#out + 1] = SHADER_HELPERS .. "\n"
    for _, ch in ipairs({ "r", "g", "b" }) do out[#out + 1] = curve_function(ch) .. "\n" end
    out[#out + 1] = SHADER_BODY
    return table.concat(out)
end

return M

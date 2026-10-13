-- Live histogram. A short-lived background mpv decodes a small copy of the frame at the current
-- position; this module bins it as-is (the "original") and through the Lua copy of the effect
-- (the "adjusted" picture). While playing, seeks land on the nearest keyframe; when paused the
-- frame is exact.
local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local H = { W = 160, H = 90, BINS = 128 }
H.status = "none"          -- none | loading | ready | unavailable
H.exact = false
H.orig = {}
H.adj = {}

local opts, on_update
local busy, pending = false, nil
local px_r, px_g, px_b, npx = {}, {}, {}, 0
local tmpfile = utils.join_path(os.getenv("TEMP") or os.getenv("TMP") or "/tmp",
                                "mpv-video-effects-" .. utils.getpid() .. ".rgb")

function H.init(o, cb)
    opts, on_update = o, cb
end

local function new_bins()
    local t = {}
    for i = 1, H.BINS do t[i] = 0 end
    return t
end

-- Bins luma and the three channels, optionally after running each pixel through fn.
local function bin_pixels(fn, luma)
    local l, r, g, b = new_bins(), new_bins(), new_bins(), new_bins()
    local lr, lg, lb = luma[1], luma[2], luma[3]
    local scale = H.BINS - 0.0001
    local floor = math.floor
    for i = 1, npx do
        local R, G, B = px_r[i], px_g[i], px_b[i]
        if fn then R, G, B = fn(R, G, B) end
        local y = R * lr + G * lg + B * lb
        if y < 0 then y = 0 elseif y > 1 then y = 1 end
        local k = floor(y * scale) + 1; l[k] = l[k] + 1
        k = floor(R * scale) + 1; r[k] = r[k] + 1
        k = floor(G * scale) + 1; g[k] = g[k] + 1
        k = floor(B * scale) + 1; b[k] = b[k] + 1
    end
    return { l = l, r = r, g = g, b = b }
end

function H.update(fn, luma)
    if H.status ~= "ready" then return end
    H.orig = bin_pixels(nil, luma)
    H.adj = fn and bin_pixels(fn, luma) or H.orig
end

local function read_frame()
    local f = io.open(tmpfile, "rb")
    if not f then return false end
    local data = f:read("*a")
    f:close()
    local n = H.W * H.H
    if not data or #data < n * 3 then return false end
    local byte = string.byte
    for i = 1, n do
        local j = (i - 1) * 3 + 1
        local r, g, b = byte(data, j, j + 2)
        px_r[i], px_g[i], px_b[i] = r / 255, g / 255, b / 255
    end
    npx = n
    return true
end

local function absolute_path(path)
    if path:find("^%a[%w+.-]*://") or path:find("^%a:[/\\]") or path:find("^[/\\]") then return path end
    return utils.join_path(mp.get_property("working-directory", ""), path)
end

-- Grab the frame at the current position. exact = decode precisely to it (slower).
function H.request(exact)
    if busy then
        pending = pending or exact
        return
    end
    local path = mp.get_property("path")
    if not path or mp.get_property_native("current-tracks/video") == nil then
        H.status = "none"
        on_update(false)
        return
    end
    if mp.get_property_native("demuxer-via-network") then
        H.status = "unavailable"
        on_update(false)
        return
    end

    busy = true
    if H.status ~= "ready" then H.status = "loading" end
    local args = {
        opts.mpv_path, "--no-config", "--msg-level=all=no", "--no-terminal", "--aid=no", "--sid=no",
        "--ytdl=no", "--hwdec=" .. opts.histogram_hwdec,
        "--start=" .. string.format("%.3f", mp.get_property_number("time-pos", 0)),
        "--hr-seek=" .. (exact and "yes" or "no"), "--frames=1",
        string.format("--vf=scale=w=%d:h=%d,format=rgb24", H.W, H.H),
        "--of=rawvideo", "--ovc=rawvideo", "--o=" .. tmpfile,
    }
    local vid = mp.get_property_number("current-tracks/video/id")
    if vid then args[#args + 1] = "--vid=" .. vid end
    local edition = mp.get_property_number("current-edition")
    if edition then args[#args + 1] = "--edition=" .. edition end
    args[#args + 1] = "--"
    args[#args + 1] = absolute_path(path)

    mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
                              capture_stdout = true, capture_stderr = true }, function(ok, res)
        busy = false
        if ok and res and res.status == 0 and read_frame() then
            H.status, H.exact = "ready", exact
            on_update(true)
        else
            msg.verbose("histogram frame grab failed: " .. tostring(res and (res.error_string or res.status)))
            if H.status ~= "ready" then H.status = "unavailable" end
            on_update(false)
        end
        if pending ~= nil then
            local p = pending
            pending = nil
            H.request(p)
        end
    end)
end

function H.reset()
    H.status, H.orig, H.adj, npx = "none", {}, {}, 0
end

function H.cleanup()
    os.remove(tmpfile)
end

return H

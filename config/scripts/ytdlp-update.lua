-- ytdlp-update: keeps a yt-dlp in the mpv config folder up to date. The installer puts one there
-- for playing web videos (mpv's built-in ytdl_hook looks in the config folder first). Web sites
-- change often, so it updates itself at most once a day, in the background, a few seconds after
-- the first file starts playing. A yt-dlp installed elsewhere (e.g. by a package manager) is left
-- alone, and without one in the config folder this script does nothing.
-- Turn off with update=no in script-opts/ytdlp_update.conf.
local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local o = {
    update = true,         -- update yt-dlp in the background
    interval_hours = 24,   -- at most this often
}
require("mp.options").read_options(o, "ytdlp_update")

local windows = mp.get_property("platform") == "windows"
local exe = mp.command_native({ "expand-path", "~~/yt-dlp" .. (windows and ".exe" or "") })
local stamp = mp.command_native({ "expand-path", "~~state/ytdlp-last-update" })

local function due()
    local f = io.open(stamp, "r")
    if not f then return true end
    local t = tonumber(f:read("*l") or "")
    f:close()
    return not t or os.time() - t >= o.interval_hours * 3600
end

-- the state folder may not exist yet (e.g. ~/.local/state/mpv on a fresh Linux setup)
local function write_stamp()
    local dir = utils.split_path(stamp):gsub("[/\\]+$", "")
    if not utils.file_info(dir) then
        local args = windows and { "cmd.exe", "/d", "/c", "mkdir", dir } or { "mkdir", "-p", dir }
        mp.command_native({ name = "subprocess", args = args, playback_only = false, capture_stderr = true })
    end
    local f = io.open(stamp, "w")
    if f then
        f:write(tostring(os.time()))
        f:close()
    end
end

local function update()
    if not utils.file_info(exe) or not due() then return end
    write_stamp()
    mp.command_native_async({ name = "subprocess", args = { exe, "-U" }, playback_only = false,
                              capture_stdout = true, capture_stderr = true }, function(ok, res)
        local out = res and ((res.stdout or "") .. (res.stderr or "")) or ""
        local last = ""
        for line in out:gmatch("[^\r\n]+") do last = line end
        if ok and res and res.status == 0 then
            if out:find("Updated yt%-dlp") then msg.info(last) else msg.verbose(last) end
        else
            msg.warn("yt-dlp update failed: " .. (last ~= "" and last or tostring(res and res.error_string)))
        end
    end)
end

if o.update then
    local started = false
    mp.register_event("file-loaded", function()
        if started then return end
        started = true
        mp.add_timeout(5, update)
    end)
end

-- updater: keeps a Windows build of mpv up to date. On other systems mpv comes from a package
-- manager, so this does nothing there.
--
--  * Once a day, on the first file played, checks the build feed and shows a notice when a newer
--    build is out. Turn off with check=no in script-opts/updater.conf.
--  * script-binding updater/update (menu: Tools > Update mpv...) closes mpv, runs
--    tools/mpv-update.ps1 in its own window, and reopens mpv on the same file.
--  * script-binding updater/rollback does the same with -Rollback.
local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"
local utils = require "mp.utils"

local o = {
    check = true,                    -- check for new builds in the background
    interval_hours = 24,             -- how often to check
    repo = "zhongfly/mpv-winbuild",  -- GitHub repository that publishes the builds
    variant = "",                    -- x86_64, x86_64-v3 or aarch64; empty = match this PC
}
options.read_options(o, "updater")

local windows = mp.get_property("platform") == "windows"

local function notify_unsupported()
    mp.osd_message("Updating is only built in for Windows builds of mpv.\nElsewhere, update mpv with your package manager.", 5)
end

if not windows then
    mp.add_key_binding(nil, "update", notify_unsupported)
    mp.add_key_binding(nil, "rollback", notify_unsupported)
    return
end

local variant = o.variant ~= "" and o.variant or (os.getenv("PROCESSOR_ARCHITECTURE") == "ARM64" and "aarch64" or "x86_64")
local stamp_file = mp.command_native({ "expand-path", "~~state/updater-last-check" })

---------------------------------------------------------------------------------------------------
-- Background check

local function checked_recently()
    local f = io.open(stamp_file, "r")
    if not f then return false end
    local t = tonumber(f:read("*l") or "")
    f:close()
    return t ~= nil and os.time() - t < o.interval_hours * 3600
end

local function write_stamp()
    local f = io.open(stamp_file, "w")
    if f then
        f:write(tostring(os.time()))
        f:close()
    end
end

local function escape_pattern(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

local function check()
    if checked_recently() then return end
    mp.command_native_async({
        name = "subprocess", playback_only = false, capture_stdout = true,
        args = { "curl.exe", "-s", "-L", "--max-time", "15", "-A", "mpv-updater",
                 "https://api.github.com/repos/" .. o.repo .. "/releases/latest" },
    }, function(ok, res)
        if not ok or not res or res.status ~= 0 then
            msg.verbose("update check failed: " .. tostring(res and (res.error_string or res.status)))
            return
        end
        write_stamp()
        local release = utils.parse_json(res.stdout or "")
        if type(release) ~= "table" or type(release.assets) ~= "table" then return end
        local pattern = "^mpv%-" .. escape_pattern(variant) .. "%-%d%d%d%d%d%d%d%d%-git%-(%x+)%.7z$"
        for _, asset in ipairs(release.assets) do
            local latest = type(asset.name) == "string" and asset.name:match(pattern)
            if latest then
                local installed = mp.get_property("mpv-version", ""):match("%-g(%x+)") or ""
                local n = math.min(#installed, #latest)
                if n >= 7 and installed:sub(1, n) ~= latest:sub(1, n) then
                    msg.info("update available: " .. asset.name)
                    mp.osd_message("An mpv update is available (" .. tostring(release.tag_name) ..
                                   "): right-click > Tools > Update mpv", 6)
                else
                    msg.verbose("mpv is up to date")
                end
                return
            end
        end
    end)
end

---------------------------------------------------------------------------------------------------
-- Update / rollback: hand over to the PowerShell updater in its own window, then quit.

local function absolute(path)
    if path:find("^%a[%w+.-]*://") or path:find("^%a:[/\\]") or path:find("^[/\\]") then return path end
    return utils.join_path(mp.get_property("working-directory", ""), path)
end

-- The folder of the running mpv.exe, read with LuaJIT's FFI (mpv has no property for it).
-- Returns nil without the FFI; the updater then looks for mpv itself.
local function exe_dir()
    local has_ffi, ffi = pcall(require, "ffi")
    if not has_ffi or not pcall(ffi.cdef, [[
        uint32_t __stdcall GetModuleFileNameW(void *, uint16_t *, uint32_t);
        int __stdcall WideCharToMultiByte(uint32_t, uint32_t, const uint16_t *, int, char *, int, const char *, int *);
    ]]) then
        return nil
    end
    local wide, utf8 = ffi.new("uint16_t[32768]"), ffi.new("char[65536]")
    local n = ffi.C.GetModuleFileNameW(nil, wide, 32768)
    if n == 0 then return nil end
    local path = ffi.string(utf8, ffi.C.WideCharToMultiByte(65001, 0, wide, n, utf8, 65536, nil, nil))
    return path:match("^(.*)[/\\]")
end
local mpv_dir = exe_dir()   -- once: the FFI can't declare the same functions twice

local function run_updater(extra)
    local script = mp.command_native({ "expand-path", "~~/tools/mpv-update.ps1" })
    local launcher = mp.command_native({ "expand-path", "~~/tools/launch.js" })
    if not utils.file_info(script) or not utils.file_info(launcher) then
        mp.osd_message("The updater is missing from the tools folder of the mpv config.", 5)
        return
    end
    -- The updater waits for this mpv to close before it swaps the files. -MpvDir tells it which
    -- mpv to update, since this one is usually gone by the time it looks; without it the updater
    -- falls back to the process id and the usual install folders.
    local args = { "wscript.exe", "//nologo", launcher, "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                   "-File", script, "-Repo", o.repo, "-Variant", variant,
                   "-WaitForPid", tostring(utils.getpid()), "-Reopen" }
    if mpv_dir then
        args[#args + 1] = "-MpvDir"
        args[#args + 1] = mpv_dir
    end
    local path = mp.get_property("path")
    if path then
        args[#args + 1] = "-ReopenFile"
        args[#args + 1] = absolute(path)
    end
    for _, a in ipairs(extra) do args[#args + 1] = a end

    -- launch.js returns as soon as the updater window is open; only then is it safe to quit.
    -- If it fails (or hangs), mpv stays open and says so.
    local settled = false
    local function fail(reason)
        if settled then return end
        settled = true
        msg.error("could not start the updater: " .. reason)
        mp.osd_message("Could not start the updater (" .. reason .. ").", 5)
    end
    mp.command_native_async({ name = "subprocess", args = args, playback_only = false }, function(ok, res)
        if settled then return end
        if ok and res and res.status == 0 then
            settled = true
            mp.osd_message("Closing mpv to update it…", 2)
            mp.add_timeout(0.5, function() mp.command("quit") end)
        else
            fail(tostring(res and (res.error_string ~= "" and res.error_string or res.status) or "unknown error"))
        end
    end)
    mp.add_timeout(10, function() fail("the launcher did not respond") end)
end

mp.add_key_binding(nil, "update", function() run_updater({}) end)
mp.add_key_binding(nil, "rollback", function() run_updater({ "-Rollback" }) end)

if o.check then
    local done = false
    mp.register_event("file-loaded", function()
        if done then return end
        done = true
        mp.add_timeout(3, check)
    end)
end

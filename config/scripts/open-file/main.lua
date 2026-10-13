-- open-file: the system "Open" dialog for mpv (Ctrl+O, or Open > File... in the menu). Picking
-- several files plays the first and queues the rest. mpv has no file dialog of its own, so:
--  * Windows: dialog.ps1 shows the standard Windows dialog. It is started through hidden.js
--    (Windows Script Host has no console), so no console or Terminal window ever flashes.
--  * macOS: the standard dialog, through osascript.
--  * Linux/BSD: zenity (GNOME and most desktops) or kdialog (KDE), whichever is installed.
local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local platform = mp.get_property("platform")
local dir = mp.get_script_directory()
local result_file = utils.join_path(os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp",
                                    "mpv-open-file-" .. utils.getpid() .. ".txt")   -- Windows only
local busy = false

local function current_folder()
    local path = mp.get_property("path")
    if not path or path:find("^%a[%w+.-]*://") then return "" end
    local folder = utils.split_path(utils.join_path(mp.get_property("working-directory", ""), path))
    return (folder:gsub("[/\\]+$", ""))   -- a trailing backslash would escape the closing quote
end

local function lines(text)
    local out = {}
    for line in (text or ""):gmatch("[^\r\n]+") do out[#out + 1] = line end
    return out
end

local function read_result()
    local f = io.open(result_file, "rb")
    if not f then return {} end
    local text = f:read("*a")
    f:close()
    os.remove(result_file)
    return lines(text)
end

-- The dialogs to try, in order. Each prints the picked files one per line (Windows: into result_file).
local function dialogs(folder)
    if platform == "windows" then
        os.remove(result_file)
        return { { args = { "wscript.exe", "//nologo", "//B", utils.join_path(dir, "hidden.js"),
                            utils.join_path(dir, "dialog.ps1"), result_file, tostring(utils.getpid()), folder },
                   read = read_result } }
    elseif platform == "darwin" then
        local where = folder ~= "" and (' default location (POSIX file "' .. folder:gsub('[\\"]', "\\%0") .. '")') or ""
        return { { args = { "osascript",
            "-e", "activate",
            "-e", 'set picked to choose file with prompt "Open" with multiple selections allowed' .. where,
            "-e", 'set out to ""',
            "-e", "repeat with f in picked",
            "-e", "set out to out & POSIX path of f & linefeed",
            "-e", "end repeat",
            "-e", "return out" } } }
    end
    local zenity = { "zenity", "--file-selection", "--multiple", "--separator=\n", "--title=Open" }
    if folder ~= "" then zenity[#zenity + 1] = "--filename=" .. folder .. "/" end
    return { { args = zenity },
             { args = { "kdialog", "--getopenfilename", folder ~= "" and folder or ".", "--multiple",
                        "--separate-output", "--title", "Open" } } }
end

local function no_dialog()
    if platform == "windows" or platform == "darwin" then
        msg.error("could not start the file dialog")
        mp.osd_message("Could not open the file dialog.", 4)
    else
        msg.error("no file dialog program found (zenity or kdialog)")
        mp.osd_message("Opening files needs zenity or kdialog. Install either one.", 5)
    end
end

-- Runs the first dialog that exists; done(files) gets the picked files ({} if cancelled).
local function run(list, i, done)
    local d = list[i]
    if not d then
        no_dialog()
        return done({})
    end
    mp.command_native_async({ name = "subprocess", args = d.args, playback_only = false,
                              capture_stdout = true, capture_stderr = true }, function(ok, res)
        if not ok or not res or res.error_string == "init" then return run(list, i + 1, done) end   -- not installed
        if res.status ~= 0 then
            if res.status ~= 1 then   -- 1 = cancelled
                msg.warn("file dialog exited with status " .. tostring(res.status) .. ": " .. tostring(res.stderr or ""))
                mp.osd_message("The file dialog failed (see the log).", 4)
            end
            return done({})
        end
        done(d.read and d.read() or lines(res.stdout))
    end)
end

local function open()
    if busy then return end
    busy = true
    run(dialogs(current_folder()), 1, function(files)
        busy = false
        for i, file in ipairs(files) do
            mp.commandv("loadfile", file, i == 1 and "replace" or "append")
        end
    end)
end

mp.add_key_binding("ctrl+o", "open", open)
mp.register_event("shutdown", function() if platform == "windows" then os.remove(result_file) end end)

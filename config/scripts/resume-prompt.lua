-- resume-prompt.lua  —  VLC-style "Resume from where you left off?" prompt for mpv.
--
-- On opening a partly-watched file it shows a prompt and only resumes if you press
-- Enter; otherwise it plays from the start. It stores positions itself (in
-- resume-prompt.json in mpv's state folder, ~~state), so mpv's own resume must be OFF:
--
--     save-position-on-quit=no      # put this in mpv.conf
--
-- Optional settings (create script-opts/resume-prompt.conf to override):
--     min_position=60     only offer resume if at least this many seconds were watched
--     end_margin=30       don't offer if the saved point is within this many seconds of the end
--     prompt_secs=6       seconds the prompt waits before defaulting to "start from beginning"

local mp = require 'mp'
local utils = require 'mp.utils'
package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua;" }) .. package.path
local state = require "kit.state"

local o = { min_position = 60, end_margin = 30, prompt_secs = 6 }
require("mp.options").read_options(o, "resume-prompt")

local DB = "resume-prompt.json"
local cur_path, last_pos = nil, nil
local have_kb, timer = false, nil

-- the same file opened by a relative path gets the same key as by its full path
local function absolute(path)
    if path:find("^%a[%w+.-]*://") then return path end   -- URLs stay as they are
    return utils.join_path(mp.get_property("working-directory", ""), path)
end

-- stable per-file key without needing a hash library
local function key_for(path)
    local h = 5381
    for i = 1, #path do h = (h * 33 + path:byte(i)) % 4294967296 end
    return string.format("%x", h)
end

local function db_read() return state.read(DB) or {} end

local function remember(path, seconds)
    local db = db_read()
    db[key_for(path)] = seconds   -- seconds = nil clears the entry
    state.write(DB, db)
end

local function store_current(ev)
    if not cur_path or not last_pos then return end
    if ev and ev.reason == "eof" then remember(cur_path, nil); return end   -- finished -> forget
    local dur = mp.get_property_number("duration")
    if last_pos < o.min_position then return end
    if dur and last_pos > dur - o.end_margin then remember(cur_path, nil); return end
    remember(cur_path, math.floor(last_pos))
end

local function hms(t)
    t = math.floor(t)
    return string.format("%d:%02d:%02d", math.floor(t / 3600), math.floor(t % 3600 / 60), t % 60)
end

local function clear_prompt()
    if have_kb then mp.remove_key_binding("resume-confirm"); have_kb = false end
    if timer then timer:kill(); timer = nil end
    mp.osd_message("", 0)
end

mp.observe_property("time-pos", "number", function(_, v) if v then last_pos = v end end)
mp.register_event("end-file", store_current)
mp.register_event("shutdown", function() store_current() end)

mp.register_event("file-loaded", function()
    clear_prompt()
    cur_path = mp.get_property("path")
    if cur_path then cur_path = absolute(cur_path) end
    last_pos = nil
    if not cur_path then return end

    local saved = db_read()[key_for(cur_path)]
    if not saved or saved < o.min_position then return end
    local dur = mp.get_property_number("duration")
    if dur and saved > dur - o.end_margin then remember(cur_path, nil); return end

    mp.add_forced_key_binding("ENTER", "resume-confirm", function()
        clear_prompt()
        mp.commandv("seek", saved, "absolute+exact")
        mp.osd_message("Resumed at " .. hms(saved), 2)
    end)
    have_kb = true
    timer = mp.add_timeout(o.prompt_secs, clear_prompt)
    mp.osd_message(
        "Resume from " .. hms(saved) .. "?   [Enter] resume",
        o.prompt_secs + 1)
end)

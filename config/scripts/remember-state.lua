-- remember-state: keeps mute, volume and looping the same from one mpv session to the next.
-- They are saved when mpv closes, in saved-state.json in mpv's state folder (~~state).
local utils = require "mp.utils"

-- properties to persist globally; add any you want
local props = { "mute", "volume", "loop-file", "loop-playlist" }
local file = mp.command_native({ "expand-path", "~~state/saved-state.json" })

-- the state folder may not exist yet (e.g. ~/.local/state/mpv on a fresh Linux setup)
local function ensure_state_dir()
    local dir = utils.split_path(file):gsub("[/\\]+$", "")
    if utils.file_info(dir) then return end
    local args = mp.get_property("platform") == "windows" and { "cmd.exe", "/d", "/c", "mkdir", dir } or { "mkdir", "-p", dir }
    mp.command_native({ name = "subprocess", args = args, playback_only = false, capture_stderr = true })
end

local function load_state()
    local f = io.open(file, "r")
    if not f then return end
    local data = utils.parse_json(f:read("*all"))
    f:close()
    if type(data) ~= "table" then return end
    for _, name in ipairs(props) do
        if data[name] ~= nil then mp.set_property(name, data[name]) end
    end
end

local function save_state()
    local data = {}
    for _, name in ipairs(props) do data[name] = mp.get_property(name) end
    ensure_state_dir()
    local f = io.open(file, "w")
    if not f then return end
    f:write(utils.format_json(data))
    f:close()
end

load_state()
mp.register_event("shutdown", save_state)

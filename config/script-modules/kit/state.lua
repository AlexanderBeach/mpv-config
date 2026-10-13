-- Small JSON files in mpv's state folder (~~state): %LOCALAPPDATA%\mpv on Windows,
-- ~/.local/state/mpv on Linux, the config folder on macOS.
local mp = require "mp"
local utils = require "mp.utils"

local M = {}

function M.path(name) return mp.command_native({ "expand-path", "~~state/" .. name }) end

-- The file's contents as a plain table, or nil if it's missing or unreadable. A table straight from
-- parse_json keeps its JSON type: keys added to an empty one, saved as [], would be dropped by
-- format_json.
function M.read(name)
    local f = io.open(M.path(name), "r")
    if not f then return nil end
    local data = utils.parse_json(f:read("*a") or "")
    f:close()
    if type(data) ~= "table" then return nil end
    local plain = {}
    for k, v in pairs(data) do plain[k] = v end
    return plain
end

function M.write(name, data)
    local path = M.path(name)
    local dir = utils.split_path(path):gsub("[/\\]+$", "")
    if not utils.file_info(dir) then   -- e.g. ~/.local/state/mpv on a fresh Linux setup
        local args = mp.get_property("platform") == "windows" and { "cmd.exe", "/d", "/c", "mkdir", dir } or { "mkdir", "-p", dir }
        mp.command_native({ name = "subprocess", args = args, playback_only = false, capture_stderr = true })
    end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(utils.format_json(data))
    f:close()
    return true
end

return M

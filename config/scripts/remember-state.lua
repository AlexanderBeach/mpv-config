-- remember-state: keeps mute, volume and looping the same from one mpv session to the next.
-- They are saved when mpv closes, in saved-state.json in mpv's state folder (~~state).
package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua;" }) .. package.path
local state = require "kit.state"

-- The properties that are kept.
local props = { "mute", "volume", "loop-file", "loop-playlist" }
local FILE = "saved-state.json"

local data = state.read(FILE)
if data then
    for _, name in ipairs(props) do
        if data[name] ~= nil then mp.set_property(name, data[name]) end
    end
end

mp.register_event("shutdown", function()
    local now = {}
    for _, name in ipairs(props) do now[name] = mp.get_property(name) end
    state.write(FILE, now)
end)

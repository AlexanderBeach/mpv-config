-- font-fallback: lets sub-font be a list of fonts, like a CSS font stack. The first one that is
-- installed is used; if none is, mpv's default (the system's sans-serif font) is used.
--
--     sub-font=FiraGO Book (37 regular), Segoe UI Semilight, Erewhon
--
-- A font can have its own size and weight in brackets: a number sets sub-font-size, "bold" or
-- "regular" sets sub-bold. Fonts without brackets use sub-font-size and sub-bold from the config.
-- Fonts in mpv's fonts folder (~~/fonts) count as installed, like the system's fonts.
-- Without this script, mpv treats the whole list as one unknown font and uses its default.
local mp = require "mp"
local msg = require "mp.msg"
package.path = mp.command_native({ "expand-path", "~~/script-modules/?.lua;" }) .. package.path
local fonts = require "kit.fonts"

local FALLBACK = "sans-serif"   -- mpv's own default for sub-font

-- "FiraGO Book (37 regular), Segoe UI Semilight" -> { {name="FiraGO Book", size=37, bold=false},
-- {name="Segoe UI Semilight"} }. Commas inside brackets separate settings, not fonts.
local function parse_list(value)
    local entries = {}
    value = value:gsub("%b()", function(b) return (b:gsub(",", " ")) end)
    for item in value:gmatch("[^,]+") do
        local name, settings = item:match("^(.-)%s*(%b())%s*$")
        local entry = { name = fonts.trim(name or item) }
        for word in (settings or "()"):sub(2, -2):lower():gmatch("%S+") do
            if tonumber(word) then entry.size = tonumber(word)
            elseif word == "bold" then entry.bold = true
            elseif word == "regular" or word == "normal" then entry.bold = false
            else msg.warn(("ignoring unknown setting '%s' for %s"):format(word, entry.name)) end
        end
        if entry.name ~= "" then entries[#entries + 1] = entry end
    end
    return entries
end

local defaults   -- sub-font-size and sub-bold from the config, for fonts without their own

local function resolve(value)
    if not defaults then
        defaults = { size = mp.get_property_number("sub-font-size"), bold = mp.get_property_bool("sub-bold") }
    end
    local choice = { name = FALLBACK }
    for _, entry in ipairs(parse_list(value)) do
        if fonts.installed(entry.name) then
            choice = entry
            break
        end
    end
    local size = choice.size or defaults.size
    local bold = defaults.bold
    if choice.bold ~= nil then bold = choice.bold end
    msg.verbose(("subtitle font: %s, size %s%s (from %s)"):format(choice.name, size, bold and ", bold" or "", value))
    mp.set_property_number("sub-font-size", size)
    mp.set_property_bool("sub-bold", bold)
    mp.set_property("sub-font", choice.name)
end

local function on_change(value)
    if value and value:find("[,(]") then resolve(value) end
end

-- Resolved while loading: mpv waits for scripts to load before it plays anything, so the first
-- subtitle already uses the right font. Later changes (e.g. from a profile) are resolved as they happen.
on_change(mp.get_property("sub-font"))
mp.observe_property("sub-font", "string", function(_, value) on_change(value) end)

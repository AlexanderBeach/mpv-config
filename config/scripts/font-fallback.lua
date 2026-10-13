-- font-fallback: lets sub-font be a list of fonts, like a CSS font stack. The first one that is
-- installed is used; if none is, mpv's default (the system's sans-serif font) is used.
--
--     sub-font=FiraGO Book (37 regular), Segoe UI Semilight, Erewhon
--
-- A font can have its own size and weight in brackets: a number sets sub-font-size, "bold" or
-- "regular" sets sub-bold. Fonts without brackets use sub-font-size and sub-bold from the config.
--
-- Fonts are looked for in mpv's fonts folder (~~/fonts) and among the system's fonts: the registry
-- on Windows, fontconfig (fc-list) on Linux/BSD, and fontconfig or the font folders on macOS.
-- Without this script, mpv treats the whole list as one unknown font and uses its default.
local mp = require "mp"
local msg = require "mp.msg"
local utils = require "mp.utils"

local platform = mp.get_property("platform")
local FALLBACK = "sans-serif"   -- mpv's own default for sub-font

-- Words that end a font's full name without being part of its family ("Fira Sans Light Italic").
local STYLE_WORDS = {}
for w in ("regular normal book roman italic oblique thin hairline light semilight demilight medium bold " ..
          "semibold demibold extrabold ultrabold black heavy extralight ultralight extra ultra semi demi"):gmatch("%S+") do
    STYLE_WORDS[w] = true
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function squash(s) return (s:lower():gsub("[%s%-_]", "")) end

-- Adds a full font name and the family names it implies ("Fira Sans Light" also adds "Fira Sans").
local function add_full_name(families, name)
    local words = {}
    for w in name:lower():gmatch("%S+") do words[#words + 1] = w end
    while #words > 0 do
        families[table.concat(words, " ")] = true
        if not STYLE_WORDS[words[#words]] then break end
        words[#words] = nil
    end
end

-- A Windows registry font name: "Fira Sans Light (TrueType)"; font collections list several
-- names: "Cambria & Cambria Math (TrueType)".
local function add_registry_name(families, name)
    name = name:gsub("%s*%([^()]*%)$", "")
    for part in (name .. " & "):gmatch("(.-) & ") do add_full_name(families, trim(part)) end
end

-- `reg query` lines look like "    Fira Sans Light (TrueType)    REG_SZ    FiraSans-Light.ttf".
local function parse_reg(out, families)
    for line in out:gmatch("[^\r\n]+") do
        local name = line:match("^%s+(.-)%s+REG_%u+")
        if name then add_registry_name(families, name) end
    end
end

-- `fc-list : family` prints each font's family names, comma-separated, some characters escaped
-- with a backslash ("Fira Sans,Fira Sans Light").
local function parse_fc(out, families)
    for line in out:gmatch("[^\r\n]+") do
        for name in line:gsub("\\", ""):gmatch("[^,]+") do families[trim(name):lower()] = true end
    end
end

-- Font files are matched by name: "FiraSans-Bold.ttf" counts as "Fira Sans".
local function scan_dir(dir, files)
    for _, f in ipairs(utils.readdir(dir, "files") or {}) do
        local lower = f:lower()
        if lower:match("%.[ot]t[fc]$") or lower:match("%.dfont$") then files[#files + 1] = squash(f) end
    end
end

local function expand(path) return mp.command_native({ "expand-path", path }) end

local function run(args)
    local res = mp.command_native({ name = "subprocess", args = args, playback_only = false,
                                    capture_stdout = true, capture_stderr = true })
    return res and res.status == 0 and res.stdout or ""
end

local FONTS_KEY = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"

-- Windows: the font names registered for all users and for this user, read straight from the
-- registry with LuaJIT's FFI (instant). Returns nil without the FFI; reg.exe is used instead.
local function registry_font_names()
    local has_ffi, ffi = pcall(require, "ffi")
    if not has_ffi or not pcall(ffi.cdef, [[
        typedef void *HKEY;
        int32_t __stdcall RegOpenKeyExW(HKEY, const uint16_t *, uint32_t, uint32_t, HKEY *);
        int32_t __stdcall RegEnumValueW(HKEY, uint32_t, uint16_t *, uint32_t *, uint32_t *, uint32_t *, uint8_t *, uint32_t *);
        int32_t __stdcall RegCloseKey(HKEY);
        int __stdcall MultiByteToWideChar(uint32_t, uint32_t, const char *, int, uint16_t *, int);
        int __stdcall WideCharToMultiByte(uint32_t, uint32_t, const uint16_t *, int, char *, int, const char *, int *);
    ]]) then
        return nil
    end
    local advapi = ffi.load("advapi32")
    local CP_UTF8, KEY_READ, KEY_WOW64_64KEY = 65001, 0x20019, 0x0100
    local subkey = ffi.new("uint16_t[?]", #FONTS_KEY + 1)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, FONTS_KEY, -1, subkey, #FONTS_KEY + 1)
    local name, len, utf8 = ffi.new("uint16_t[16384]"), ffi.new("uint32_t[1]"), ffi.new("char[65536]")
    local names = {}
    for _, root in ipairs({ -2147483646, -2147483647 }) do   -- HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER
        local key = ffi.new("HKEY[1]")
        if advapi.RegOpenKeyExW(ffi.cast("HKEY", ffi.cast("intptr_t", root)), subkey, 0,
                                KEY_READ + KEY_WOW64_64KEY, key) == 0 then
            local i = 0
            while true do
                len[0] = 16384
                if advapi.RegEnumValueW(key[0], i, name, len, nil, nil, nil, nil) ~= 0 then break end
                names[#names + 1] = ffi.string(utf8, ffi.C.WideCharToMultiByte(CP_UTF8, 0, name, len[0], utf8, 65536, nil, nil))
                i = i + 1
            end
            advapi.RegCloseKey(key[0])
        end
    end
    return names
end

-- Collects what is installed: { families = set of family names, files = font file names }.
local function scan()
    local families, files = {}, {}
    local fonts_dir = mp.get_property("sub-fonts-dir", "")
    local dirs = { fonts_dir ~= "" and fonts_dir or "~~/fonts" }
    if platform == "windows" then
        local names = registry_font_names()
        if names then
            for _, n in ipairs(names) do add_registry_name(families, n) end
        else
            parse_reg(run({ "reg.exe", "query", "HKLM\\" .. FONTS_KEY }), families)
            parse_reg(run({ "reg.exe", "query", "HKCU\\" .. FONTS_KEY }), families)
        end
    else
        parse_fc(run({ "fc-list", ":", "family" }), families)
        if platform == "darwin" then
            for _, d in ipairs({ "/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts", "~/Library/Fonts" }) do
                dirs[#dirs + 1] = d
            end
        end
    end
    for _, d in ipairs(dirs) do scan_dir(expand(d), files) end
    return { families = families, files = files }
end

local function installed(font, families, files)
    if families[font:lower()] then return true end
    local key = squash(font)
    for _, f in ipairs(files) do
        if f:sub(1, #key) == key then return true end
    end
    return false
end

-- "FiraGO Book (37 regular), Segoe UI Semilight" -> { {name="FiraGO Book", size=37, bold=false},
-- {name="Segoe UI Semilight"} }. Commas inside brackets separate settings, not fonts.
local function parse_list(value)
    local entries = {}
    value = value:gsub("%b()", function(b) return (b:gsub(",", " ")) end)
    for item in value:gmatch("[^,]+") do
        local name, settings = item:match("^(.-)%s*(%b())%s*$")
        local entry = { name = trim(name or item) }
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

local installed_fonts   -- what scan() found, kept for the session
local defaults          -- sub-font-size and sub-bold from the config, for fonts without their own

local function resolve(value)
    installed_fonts = installed_fonts or scan()
    if not defaults then
        defaults = { size = mp.get_property_number("sub-font-size"), bold = mp.get_property_bool("sub-bold") }
    end
    local choice = { name = FALLBACK }
    for _, entry in ipairs(parse_list(value)) do
        if installed(entry.name, installed_fonts.families, installed_fonts.files) then
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

-- Resolve now: mpv waits for scripts to load before it plays anything, so the first subtitle
-- already uses the right font. Later changes (e.g. from a profile) are resolved as they happen.
on_change(mp.get_property("sub-font"))
mp.observe_property("sub-font", "string", function(_, value) on_change(value) end)

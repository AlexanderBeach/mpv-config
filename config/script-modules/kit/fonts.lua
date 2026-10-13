-- Which fonts are installed, as libass would find them: mpv's fonts folder (~~/fonts) and the
-- system's fonts (the registry on Windows, fontconfig on Linux/BSD, fontconfig and the font
-- folders on macOS). Used by font-fallback.lua and the subtitle style panel.
local mp = require "mp"
local utils = require "mp.utils"

local M = {}

-- Subtitle fonts with a size that makes each about as wide as the others (FiraGO Book at 37).
-- The installers offer the same list.
M.SIZES = {
    { "FiraGO Book", 37 }, { "Atkinson Hyperlegible", 39 }, { "Segoe UI", 41 }, { "Calibri", 41 },
    { "Verdana", 33 }, { "Arial", 34 }, { "Noto Sans", 36 }, { "DejaVu Sans", 33 },
    { "Liberation Sans", 34 }, { "Cantarell", 38 }, { "Helvetica Neue", 34 }, { "Avenir Next", 35 },
    { "Lucida Grande", 34 },
}

local platform = mp.get_property("platform")

-- Words that end a font's full name without being part of its family ("Fira Sans Light Italic").
local STYLE_WORDS = {}
for w in ("regular normal book roman italic oblique thin hairline light semilight demilight medium bold " ..
          "semibold demibold extrabold ultrabold black heavy extralight ultralight extra ultra semi demi"):gmatch("%S+") do
    STYLE_WORDS[w] = true
end

function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local trim = M.trim
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

-- Windows: the font names registered for all users and for this user, read from the registry with
-- LuaJIT's FFI. Returns nil without the FFI, and reg.exe is used instead.
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

local found   -- what scan() found, kept for the session

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

function M.installed(font)
    found = found or scan()
    if found.families[font:lower()] then return true end
    local key = squash(font)
    for _, f in ipairs(found.files) do
        if f:sub(1, #key) == key then return true end
    end
    return false
end

return M

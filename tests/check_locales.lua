-- Locale check for QuestTips - self-contained, no addon harness needed.
-- Run from the addon root: tools\luajit.exe tests/check_locales.lua
--
-- Locale files only touch GetLocale() and ns.L, so stubbing those two is
-- enough. Checks that every stored entry is really translated and keeps the
-- same %s/%d directives in the same order as its English key (a mismatch
-- crashes string.format in-game), and that enUS falls through to English.

local ADDON_NAME = "QuestTips"
local MIN_ENTRIES = 40 -- ~44 keys today; a floor, not an exact count

local failures = {}
local function check(ok, msg)
    if not ok then failures[#failures + 1] = msg end
    return ok
end

local function directives(s)
    local list = {}
    for d in tostring(s):gmatch("%%[sd]") do list[#list + 1] = d end
    return table.concat(list, " ")
end

-- Same fallback metatable as Core.lua.
local function newNS()
    return { L = setmetatable({}, { __index = function(_, key) return key end }) }
end

local function loadLocales(locale)
    _G.GetLocale = function() return locale end
    local ns = newNS()
    for _, path in ipairs(_G.LOCALE_FILES) do
        local chunk, err = loadfile(path)
        if not chunk then error("cannot load " .. path .. ": " .. tostring(err)) end
        chunk(ADDON_NAME, ns)
    end
    return ns
end

-- Discover Locales/*.lua without any filesystem library (cmd, then sh).
local files = {}
for _, cmd in ipairs({ 'dir /b "Locales\\*.lua" 2>nul', 'ls Locales/*.lua 2>/dev/null' }) do
    local p = io.popen(cmd)
    if p then
        for line in p:lines() do
            line = line:gsub("%s+$", ""):gsub("^Locales[/\\]", "")
            if line:match("%.lua$") then files[#files + 1] = "Locales/" .. line end
        end
        p:close()
    end
    if #files > 0 then break end
end
check(#files > 0, "no Locales/*.lua found - run from the QuestTips directory")
_G.LOCALE_FILES = files

-- ruRU: everything stored must be translated and format-compatible.
if #files > 0 then
    local ns = loadLocales("ruRU")
    local entries = 0
    for key, value in pairs(ns.L) do
        entries = entries + 1
        check(type(value) == "string", "ruRU non-string entry: " .. tostring(key))
        check(value ~= key, "ruRU untranslated entry: " .. tostring(key))
        check(directives(value) == directives(key),
            "ruRU format mismatch in: " .. tostring(key)
                .. " [" .. directives(key) .. "] vs [" .. directives(value) .. "]")
    end
    check(entries >= MIN_ENTRIES,
        "ruRU entry count too low: " .. entries .. " < " .. MIN_ENTRIES)
    check(ns.L["Untranslated probe"] == "Untranslated probe", "ruRU fallback broken")
    print(("ruRU: %d entries checked"):format(entries))

    -- enUS: locale files must bail out and leave the fallback in charge.
    local en = loadLocales("enUS")
    local stored = 0
    for _ in pairs(en.L) do stored = stored + 1 end
    check(stored == 0, "enUS stored " .. stored .. " entries, expected 0")
    check(en.L["Needed for %d quests"] == "Needed for %d quests", "enUS fallback broken")
    print("enUS: no overrides stored, English keys pass through")
end

if #failures == 0 then
    print("check_locales: PASS (" .. #files .. " locale file(s))")
    os.exit(0)
end
print("check_locales: FAIL - " .. #failures .. " problem(s)")
for _, msg in ipairs(failures) do print("  - " .. msg) end
os.exit(1)

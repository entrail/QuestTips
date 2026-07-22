local ADDON_NAME, ns = ...

ns.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")

-- Localization: all user-facing text goes through ns.L["English text"].
-- English is the key and the fallback; locale files can override entries.
ns.L = setmetatable({}, { __index = function(_, key) return key end })

-- All settings are account-wide: the tooltip behavior should be identical
-- on every character (what differs per character - faction, class, quest
-- log, completed quests - is read live from the game).
local defaults = {
    showInLog      = true, -- green: quest currently in the quest log
    showAvailable  = true, -- yellow: not in the log, not completed yet
    showCompleted  = true, -- red: completed (item may still sell on the AH)
    showRepeatable = true, -- blue: repeatable turn-in (permanent demand)
    showQuestNames = true, -- false = one compact "Needed for N quests" line
    includeNonDrop = true, -- also annotate gathered/fished/crafted items
    checkDeletable = true, -- quest-bound/starter leftovers: "can be deleted"
    warnDeletable  = true, -- announce such leftovers right after turn-ins
    maxLines       = 4,    -- quest lines per item (rest becomes "+N more")
    modifier       = "NONE", -- only show while holding NONE/SHIFT/CTRL/ALT
}

local function CopyDefaults(src, dst)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

-- Factory for the quest data files (Data/<flavor>/QuestData.lua).
-- Creates ns.QUESTS (questId -> requirements), ns.QUESTS_BY_ITEM (itemId ->
-- questId list), ns.ITEM_SOURCE (itemId -> source tag string) and
-- ns.QUEST_STARTER (itemId -> questId the item starts) and returns the
-- add()/src()/qstart() functions the generated data lines call.
--
-- add(questId, items[, flags[, extra]])
--   items: { [itemId] = requiredCount, ... } (may be empty for quests that
--     only appear as a qstart() target)
--   flags: "A" Alliance-only, "H" Horde-only, "R" repeatable (combinable)
--   extra: { classes = <class mask>, races = <race mask>,
--            skill = <required skill line id>, lvl = <quest level>,
--            zone = <AreaTable id, resolved via C_Map.GetAreaInfo> }
--     - only the keys that are set are present
-- src(itemId, tags)
--   tags: string of source letters - D drop, G gathered, F fished,
--   C crafted, V vendor (limited stock), Q quest-bound/conditional
-- qstart(itemId, questId)
--   the item starts this quest when used
function ns.NewQuestDB()
    local quests, byItem, sources, starters = {}, {}, {}, {}
    local provided = {}
    ns.QUESTS, ns.QUESTS_BY_ITEM, ns.ITEM_SOURCE = quests, byItem, sources
    ns.QUEST_STARTER = starters
    ns.QUEST_PROVIDED = provided

    local FACTION = { A = "Alliance", H = "Horde" }
    local function add(questId, items, flags, extra)
        local q = { items = items }
        if flags then
            q.faction = FACTION[flags:match("[AH]")]
            q.repeatable = flags:find("R", 1, true) ~= nil
        end
        if extra then
            q.classes, q.races, q.skill = extra.classes, extra.races, extra.skill
            q.level, q.zone = extra.lvl, extra.zone
        end
        quests[questId] = q
        for itemId in pairs(items) do
            local list = byItem[itemId]
            if not list then list = {}; byItem[itemId] = list end
            list[#list + 1] = questId
        end
    end

    local function src(itemId, tags)
        sources[itemId] = tags
    end

    local function qstart(itemId, questId)
        starters[itemId] = questId
    end

    -- qprov(itemId, questId): the questgiver hands the item over on accept
    -- and NO quest ever requires it (manuals, notes) - pure informational
    -- baggage, deletable once its providing quest(s) are completed. An item
    -- can be provided by several quests of a chain -> list.
    local function qprov(itemId, questId)
        local list = provided[itemId]
        if not list then
            list = {}
            provided[itemId] = list
        end
        list[#list + 1] = questId
    end

    return add, src, qstart, qprov
end

-- ns.OnInit(fn) -> runs at ADDON_LOADED, after ns.db is ready.
local initCallbacks = {}
function ns.OnInit(fn) table.insert(initCallbacks, fn) end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, arg1)
    if arg1 ~= ADDON_NAME then return end
    self:UnregisterEvent("ADDON_LOADED")
    QuestTipsDB = QuestTipsDB or {}
    CopyDefaults(defaults, QuestTipsDB)
    ns.db = QuestTipsDB
    for _, fn in ipairs(initCallbacks) do fn() end
end)

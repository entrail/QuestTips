local ADDON_NAME, ns = ...
local L = ns.L

-- Tooltip lines on items that are quest objectives but obtainable WITHOUT
-- the quest (regular drops, gathered/fished/crafted items). One line per
-- relevant quest, colored by THIS character's state for that quest:
--   green  - quest currently in the quest log ("need it now", with have/need)
--   yellow - not in the log, not completed ("might need it later")
--   blue   - repeatable turn-in (permanent demand, prime AH material)
--   red    - already completed ("done" - may still sell on the AH)
--
-- Quests of the other faction, of other classes, or of races that can
-- never take them are not shown at all. Profession-gated quests ARE shown;
-- if the character lacks the profession the line carries a gray
-- "(missing profession)" marker.
--
-- Locale safety: ALL matching is by item ID and quest ID. Quest titles are
-- resolved at runtime from the client's quest data cache; until the server
-- answers the load request a line falls back to "Quest #id" and heals on a
-- later hover.

local STATE_COLOR = {
    inLog      = "ff40c040",
    available  = "ffffff00",
    repeatable = "ff4da6ff",
    completed  = "ffff5050",
}
local STATE_ORDER = { inLog = 1, available = 2, repeatable = 3, completed = 4 }
local STATE_SETTING = {
    inLog      = "showInLog",
    available  = "showAvailable",
    repeatable = "showRepeatable",
    completed  = "showCompleted",
}
local GRAY = "ff9d9d9d"

-- Optional modifier gate: only add tooltip info while the key is held.
local MODIFIER_CHECK = {
    SHIFT = IsShiftKeyDown,
    CTRL  = IsControlKeyDown,
    ALT   = IsAltKeyDown,
}
local function ModifierOK()
    local check = MODIFIER_CHECK[ns.db.modifier or "NONE"]
    return not check or check()
end

-- Curated overrides: items whose quest links cannot express their real
-- lifetime. [itemId] = questId -> once that quest is completed, the item
-- is dead ("can be deleted") regardless of its other quest links.
--   3080 Candle of Beckoning: linked to the REPEATABLE summon quest 410
--   (The Dormant Shade), so it can never reach "completed" on its own -
--   but its real purpose ends with the one-time follow-up 409 (Proving
--   Allegiance); leftover candles are junk from then on.
local ITEM_DEAD_AFTER = {
    [3080] = 409,
}

local module = {}
ns.QuestTips = module

-- ------------------------------------------------------------------
-- Player identity (lazy; stable for the whole session)
-- ------------------------------------------------------------------

-- Class/race bitmasks use the same encoding as the quest data
-- (bit = 2^(id-1)): Warrior 1, Paladin 2, ... / Human 1, Orc 2, ...
local playerFaction, playerClassMask, playerRaceMask
local function InitPlayer()
    if playerFaction then return end
    playerFaction = UnitFactionGroup("player")
    local _, _, classId = UnitClass("player")
    playerClassMask = classId and 2 ^ (classId - 1) or 0
    local _, _, raceId = UnitRace("player")
    playerRaceMask = raceId and 2 ^ (raceId - 1) or 0
end

-- A quest this character can never do produces no line at all.
local function EligibleForPlayer(q)
    if q.faction and q.faction ~= playerFaction then return false end
    if q.classes and bit.band(q.classes, playerClassMask) == 0 then return false end
    if q.races and bit.band(q.races, playerRaceMask) == 0 then return false end
    return true
end

-- ------------------------------------------------------------------
-- Profession requirement ("(missing profession)" marker)
-- ------------------------------------------------------------------

-- Skill line id (the quest's required skill) -> profession spell whose
-- localized name matches the skill line name on every client language
-- (same trick as ProfessionTips). Ids missing here (or spells whose name
-- does not match, e.g. Herbalism's "Herb Gathering") simply never show the
-- marker - benign degradation, never a wrong claim.
local SKILL_SPELL = {
    [129] = 3273, -- First Aid
    [164] = 2018, -- Blacksmithing
    [165] = 2108, -- Leatherworking
    [171] = 2259, -- Alchemy
    [185] = 2550, -- Cooking
    [186] = 2575, -- Mining
    [197] = 3908, -- Tailoring
    [202] = 4036, -- Engineering
    [333] = 7411, -- Enchanting
    [356] = 7620, -- Fishing
    [393] = 8613, -- Skinning
}

-- true = has it, false = provably missing, nil = cannot verify (no marker).
local function HasProfession(skillId)
    local spellId = SKILL_SPELL[skillId]
    if not spellId then return nil end
    local name = GetSpellInfo(spellId)
    if not name then return nil end
    for i = 1, GetNumSkillLines() do
        local lineName, isHeader = GetSkillLineInfo(i)
        if not isHeader and lineName == name then return true end
    end
    return false
end

-- ------------------------------------------------------------------
-- Quest state & title
-- ------------------------------------------------------------------

-- In-log wins (a repeatable quest being worked on is "need it now");
-- repeatable wins over completed (it can always be handed in again).
local function QuestState(questId, q)
    if C_QuestLog.IsOnQuest(questId) then return "inLog" end
    if q.repeatable then return "repeatable" end
    if C_QuestLog.IsQuestFlaggedCompleted(questId) then return "completed" end
    return "available"
end

-- Where is that quest? Every line except completed ones carries
-- "(Westfall, 16)" - the quest's zone and level from the data. The zone is stored as an AreaTable id and resolved
-- through C_Map.GetAreaInfo, so the name displays localized on every
-- client language. Quests without a zone (class/profession quest sorts)
-- or without a fixed level degrade to whichever half is available.
local zoneNameCache = {}
local function ZoneAndLevel(q)
    local zone
    if q.zone and C_Map and C_Map.GetAreaInfo then
        zone = zoneNameCache[q.zone]
        if zone == nil then
            zone = C_Map.GetAreaInfo(q.zone) or false
            zoneNameCache[q.zone] = zone
        end
        if zone == false then zone = nil end
    end
    if zone and q.level then
        return ("%s, %d"):format(zone, q.level)
    end
    if zone then return zone end
    if q.level then return format(L["level %d"], q.level) end
    return nil
end

-- Titles come from the client quest cache; uncached quests are requested
-- and resolve on a later hover. Cache successful lookups for the session.
local titleCache = {}
local function QuestTitle(questId)
    local title = titleCache[questId]
    if title then return title end
    if C_QuestLog.GetTitleForQuestID then
        title = C_QuestLog.GetTitleForQuestID(questId)
    end
    if (not title or title == "") and C_QuestLog.GetQuestInfo then
        title = C_QuestLog.GetQuestInfo(questId)
    end
    if title and title ~= "" then
        titleCache[questId] = title
        return title
    end
    if C_QuestLog.RequestLoadQuestByID then
        pcall(C_QuestLog.RequestLoadQuestByID, questId)
    end
    return "#" .. questId
end

-- ------------------------------------------------------------------
-- Quest-provided items (qprov): manuals, notes - never required
-- ------------------------------------------------------------------

local function ProvidedBy(itemId, questId)
    local providers = ns.QUEST_PROVIDED[itemId]
    if not providers then return false end
    for _, qid in ipairs(providers) do
        if qid == questId then return true end
    end
    return false
end

-- Verdict over all eligible provider quests of the item:
--   "completed" - every one is completed (justCompleted counts as done)
--   "notInLog"  - none in the log, but not all completed (post-abandon)
--   "keep"      - one is in the log or repeatable (actively relevant)
--   nil         - item has no eligible providers for this character
local function ProviderState(itemId, justCompleted)
    local providers = ns.QUEST_PROVIDED[itemId]
    if not providers then return nil end
    local anyEligible, allCompleted, anyInLog = false, true, false
    for _, questId in ipairs(providers) do
        local q = ns.QUESTS[questId]
        if q and EligibleForPlayer(q) then
            anyEligible = true
            if q.repeatable then return "keep" end
            if C_QuestLog.IsOnQuest(questId) then anyInLog = true end
            if questId ~= justCompleted
                and not C_QuestLog.IsQuestFlaggedCompleted(questId) then
                allCompleted = false
            end
        end
    end
    if not anyEligible then return nil end
    if allCompleted then return "completed" end
    if anyInLog then return "keep" end
    return "notInLog"
end

-- ------------------------------------------------------------------
-- Tooltip rendering
-- ------------------------------------------------------------------

-- All quests needing this item that this character could ever do; sorted
-- green, yellow, blue, red. respectToggles applies the per-state settings
-- checkboxes (save-or-sell lines); the deletable check ignores them -
-- hiding e.g. the completed state would defeat that check.
local function GatherQuests(itemId, respectToggles)
    local questIds = ns.QUESTS_BY_ITEM[itemId]
    if not questIds then return nil end
    local out
    for _, questId in ipairs(questIds) do
        local q = ns.QUESTS[questId]
        if EligibleForPlayer(q) then
            local state = QuestState(questId, q)
            if not respectToggles or ns.db[STATE_SETTING[state]] then
                out = out or {}
                out[#out + 1] = { questId = questId, q = q, state = state }
            end
        end
    end
    if out then
        table.sort(out, function(a, b)
            if a.state ~= b.state then
                return STATE_ORDER[a.state] < STATE_ORDER[b.state]
            end
            return a.questId < b.questId
        end)
    end
    return out
end

-- One line per quest, capped at maxLines with a "+N more quests" summary.
local function RenderEntries(tooltip, itemId, entries)
    local have = GetItemCount(itemId) or 0
    local maxLines = ns.db.maxLines or 4
    local shown = math.min(#entries, maxLines)
    for i = 1, shown do
        local e = entries[i]
        local color = STATE_COLOR[e.state]
        local left = ("|c%s%s: %s|r"):format(color, L["Quest"], QuestTitle(e.questId))
        -- zone/level for every quest still ahead (in the log, available,
        -- repeatable) - only completed ones need no directions
        if e.state ~= "completed" then
            local where = ZoneAndLevel(e.q)
            if where then
                left = left .. (" |c%s(%s)|r"):format(color, where)
            end
        end
        if e.state == "repeatable" then
            left = left .. (" |c%s(%s)|r"):format(color, L["repeatable"])
        elseif e.state == "completed" then
            left = left .. (" |c%s(%s)|r"):format(color, L["done"])
        end
        if e.q.skill and HasProfession(e.q.skill) == false then
            left = left .. (" |c%s(%s)|r"):format(GRAY, L["missing profession"])
        end
        -- have/need from the bags: what matters for the turn-in. Not capped
        -- at need - "12/5" on a repeatable quest means 2+ turn-ins banked.
        local need = e.q.items[itemId]
        tooltip:AddDoubleLine(left, ("|c%s%d/%d|r"):format(color, have, need))
    end
    if #entries > shown then
        tooltip:AddLine(("|c%s+%d %s|r"):format(GRAY, #entries - shown, L["more quests"]))
    end
end

-- Freely obtainable quest items: the save-or-sell lines.
local function AddTradeableLines(tooltip, itemId, tags)
    -- Source filter: items only obtainable by gathering/fishing/crafting
    -- can be switched off; anything that (also) drops is always shown.
    if not ns.db.includeNonDrop and tags and not tags:find("D", 1, true) then
        return nil
    end

    local entries = GatherQuests(itemId, true)
    if not entries then return nil end
    local shown = {}
    for _, e in ipairs(entries) do shown[e.questId] = true end

    if not ns.db.showQuestNames then
        -- Compact mode: one line, colored by the most relevant state.
        local text = #entries == 1 and L["Needed for 1 quest"]
            or format(L["Needed for %d quests"], #entries)
        tooltip:AddLine(("|c%s%s|r"):format(STATE_COLOR[entries[1].state], text))
    else
        RenderEntries(tooltip, itemId, entries)
    end
    tooltip:Show() -- recalculate tooltip size for the added lines
    return shown
end

-- Quest-bound/conditional items (Q tag): the question is not save-or-sell
-- but "can this leftover be deleted?". Only certain when EVERY quest this
-- character could do with it is completed (and none is repeatable) - then
-- one clear red line; otherwise the normal per-quest lines show what still
-- needs it.
local function AddBoundLines(tooltip, itemId)
    local entries = GatherQuests(itemId, false)
    if not entries then return nil end

    local allDone, shown = true, {}
    for _, e in ipairs(entries) do
        shown[e.questId] = true
        if e.state ~= "completed" then allDone = false end
    end

    if allDone then
        local text = #entries == 1 and L["Quest completed - can be deleted"]
            or format(L["All %d quests completed - can be deleted"], #entries)
        tooltip:AddLine(("|c%s%s|r"):format(STATE_COLOR.completed, text))
    else
        RenderEntries(tooltip, itemId, entries)
    end
    tooltip:Show()
    return shown
end

local function AddQuestLines(tooltip, itemId)
    InitPlayer()

    -- lifetime override (see ITEM_DEAD_AFTER): once the overriding quest
    -- is completed, one red line replaces the normal (blue/...) lines
    local deadQuest = ITEM_DEAD_AFTER[itemId]
    if deadQuest and ns.db.checkDeletable
        and C_QuestLog.IsQuestFlaggedCompleted(deadQuest) then
        tooltip:AddLine(("|c%s%s: %s (%s)|r"):format(
            STATE_COLOR.completed, L["Quest"], QuestTitle(deadQuest),
            L["completed - can be deleted"]))
        tooltip:Show()
        return
    end

    local shownQuests

    if ns.QUESTS_BY_ITEM[itemId] then
        local tags = ns.ITEM_SOURCE[itemId]
        if tags and tags:find("Q", 1, true) then
            if ns.db.checkDeletable then
                shownQuests = AddBoundLines(tooltip, itemId)
            end
        else
            shownQuests = AddTradeableLines(tooltip, itemId, tags)
        end
    end

    -- Leftover quest-starter items (maps, notes, ...): once their quest is
    -- completed, say so - Blizzard's own "This Item Begins a Quest" line
    -- keeps suggesting the item is still useful. Skipped while the quest is
    -- open (the Blizzard line covers that) and for repeatable starters.
    local startQuestId = ns.QUEST_STARTER[itemId]
    if startQuestId and ns.db.checkDeletable
        and not (shownQuests and shownQuests[startQuestId]) then
        local q = ns.QUESTS[startQuestId]
        if q and EligibleForPlayer(q) and not q.repeatable
            and QuestState(startQuestId, q) == "completed" then
            tooltip:AddLine(("|c%s%s: %s (%s)|r"):format(
                STATE_COLOR.completed, L["Starts quest"],
                QuestTitle(startQuestId), L["completed - can be deleted"]))
            tooltip:Show()
        end
    end

    -- Quest-provided leftovers (manuals, notes - see qprov): the item came
    -- from a questgiver and no quest ever requires it; once every
    -- providing quest is completed it is pure baggage.
    if ns.db.checkDeletable and ns.QUEST_PROVIDED[itemId]
        and ProviderState(itemId) == "completed" then
        tooltip:AddLine(("|c%s%s: %s (%s)|r"):format(
            STATE_COLOR.completed, L["Provided by quest"],
            QuestTitle(ns.QUEST_PROVIDED[itemId][1]),
            L["completed - can be deleted"]))
        tooltip:Show()
    end
end

-- ------------------------------------------------------------------
-- Turn-in watcher: announce leftovers that just became deletable
-- ------------------------------------------------------------------
-- When a quest is turned in and a quest-bound (Q tag) or quest-starter
-- item connected to it is still in the bags - with no other eligible
-- quest needing it - announce it like the tooltip's red line: red
-- UIErrorsFrame text plus one chat line (same style as RankTips'
-- low-rank cast warning). Tradeable leftovers are save-or-sell, never
-- announced.

local PREFIX = "|cff33ff99QuestTips|r: "

-- Same rule as the tooltip's AddBoundLines, but the quest just turned in
-- counts as completed (the server flag can lag behind the event).
local function AllQuestsDone(itemId, justCompleted)
    local questIds = ns.QUESTS_BY_ITEM[itemId]
    if not questIds then return true end -- pure starter item
    for _, questId in ipairs(questIds) do
        local q = ns.QUESTS[questId]
        if EligibleForPlayer(q) then
            if q.repeatable then return false end
            if questId ~= justCompleted
                and not C_QuestLog.IsQuestFlaggedCompleted(questId) then
                return false
            end
        end
    end
    return true
end

local function DeletableAfterTurnIn(itemId, justCompleted)
    if ITEM_DEAD_AFTER[itemId] == justCompleted then return true end
    if ProvidedBy(itemId, justCompleted) then
        return ProviderState(itemId, justCompleted) == "completed"
    end
    local tags = ns.ITEM_SOURCE[itemId]
    local isBound = tags and tags:find("Q", 1, true) ~= nil
    local starterQuest = ns.QUEST_STARTER[itemId]
    if not (isBound or starterQuest) then return false end
    if starterQuest then
        local q = ns.QUESTS[starterQuest]
        if not q or q.repeatable then return false end
        if EligibleForPlayer(q) and starterQuest ~= justCompleted
            and not C_QuestLog.IsQuestFlaggedCompleted(starterQuest) then
            return false
        end
    end
    return AllQuestsDone(itemId, justCompleted)
end

-- After ABANDONING a quest the bar is lower: the abandoned quest is
-- "available" again, so completeness can't be required - the offer comes
-- when no quest IN THE LOG still needs the item and no repeatable wants
-- it. Not-yet-done quests don't block it (the player just decided
-- against that content); the window wording states exactly this and the
-- Keep button covers the rest.
local function DeletableAfterAbandon(itemId, abandonedQuest)
    if ProvidedBy(itemId, abandonedQuest) then
        -- re-accepting the quest hands out a fresh copy anyway
        local state = ProviderState(itemId)
        return state == "completed" or state == "notInLog"
    end
    local tags = ns.ITEM_SOURCE[itemId]
    local isBound = tags and tags:find("Q", 1, true) ~= nil
    local starterQuest = ns.QUEST_STARTER[itemId]
    if not (isBound or starterQuest) then return false end
    local questIds = ns.QUESTS_BY_ITEM[itemId]
    if questIds then
        for _, questId in ipairs(questIds) do
            local q = ns.QUESTS[questId]
            if questId ~= abandonedQuest and EligibleForPlayer(q) then
                if q.repeatable then return false end
                if C_QuestLog.IsOnQuest(questId) then return false end
            end
        end
    end
    if starterQuest and starterQuest ~= abandonedQuest then
        local q = ns.QUESTS[starterQuest]
        if q and EligibleForPlayer(q)
            and (q.repeatable or C_QuestLog.IsOnQuest(starterQuest)) then
            return false
        end
    end
    return true
end

local function BagItemIds()
    local ids, seen = {}, {}
    local getSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
    local getItem = C_Container and C_Container.GetContainerItemID or GetContainerItemID
    for bag = 0, 4 do
        for slot = 1, getSlots(bag) or 0 do
            local itemId = getItem(bag, slot)
            if itemId and not seen[itemId] then
                seen[itemId] = true
                ids[#ids + 1] = itemId
            end
        end
    end
    return ids
end

-- Deletes every stack of the item from the bags (explicit user click).
local function DeleteAllOf(itemId)
    local getSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
    local getItem = C_Container and C_Container.GetContainerItemID or GetContainerItemID
    local pickup = C_Container and C_Container.PickupContainerItem or PickupContainerItem
    ClearCursor()
    for bag = 0, 4 do
        for slot = 1, getSlots(bag) or 0 do
            if getItem(bag, slot) == itemId then
                pickup(bag, slot)
                DeleteCursorItem()
            end
        end
    end
end

-- One small offer window, fed from a queue (several items can become
-- deletable from one turn-in); Delete removes all stacks, Keep skips.
local pendingOffers = {}
local popup

local function ShowNextOffer()
    -- skip anything the game removed in the meantime
    local offer
    repeat
        offer = table.remove(pendingOffers, 1)
    until not offer or (GetItemCount(offer.itemId) or 0) > 0
    if not offer then
        if popup then popup:Hide() end
        return
    end
    local itemId = offer.itemId

    if not popup then
        popup = CreateFrame("Frame", "QuestTipsDeletableFrame", UIParent, "BasicFrameTemplateWithInset")
        popup:SetSize(320, 120)
        popup:SetPoint("TOP", 0, -180)
        popup:SetMovable(true)
        popup:EnableMouse(true)
        popup:RegisterForDrag("LeftButton")
        popup:SetScript("OnDragStart", popup.StartMoving)
        popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
        popup:SetFrameStrata("DIALOG")
        tinsert(UISpecialFrames, "QuestTipsDeletableFrame") -- Esc closes

        local title = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
        title:SetText("QuestTips")

        popup.icon = popup:CreateTexture(nil, "ARTWORK")
        popup.icon:SetSize(32, 32)
        popup.icon:SetPoint("TOPLEFT", 14, -32)

        popup.text = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        popup.text:SetPoint("TOPLEFT", 54, -30)
        popup.text:SetPoint("TOPRIGHT", -12, -30)
        popup.text:SetJustifyH("LEFT")
        popup.text:SetJustifyV("TOP")
        popup.text:SetWordWrap(true)

        popup.deleteBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
        popup.deleteBtn:SetSize(140, 22)
        popup.deleteBtn:SetPoint("BOTTOMLEFT", 10, 8)
        popup.deleteBtn:SetScript("OnClick", function()
            if popup.itemId then DeleteAllOf(popup.itemId) end
            ShowNextOffer()
        end)

        popup.keepBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
        popup.keepBtn:SetSize(140, 22)
        popup.keepBtn:SetPoint("BOTTOMRIGHT", -10, 8)
        popup.keepBtn:SetText(L["Keep"])
        popup.keepBtn:SetScript("OnClick", ShowNextOffer)
    end

    local name = GetItemInfo(itemId)
    popup.itemId = itemId
    popup.icon:SetTexture(GetItemIcon and GetItemIcon(itemId)
        or select(10, GetItemInfo(itemId)) or 134400)
    popup.text:SetText(format(offer.msg, name or ("#" .. itemId)))
    local count = GetItemCount(itemId) or 0
    popup.deleteBtn:SetText(count > 1 and format(L["Delete all (%d)"], count) or (DELETE or L["Delete"]))
    popup:Show()
end

ns.OnInit(function()
    -- QUEST_REMOVED fires for turn-ins too (quest leaves the log); a
    -- short-lived turned-in set tells the two apart.
    local recentTurnIn = {}

    local function ProcessQuest(questId, deletableCheck, msg)
        if not (ns.db.checkDeletable and ns.db.warnDeletable) then return end
        -- The game removes handed-in (and abandon-flagged) quest items
        -- from the bags a moment AFTER the event: scan only once the dust
        -- has settled, so true leftovers are offered - not items Blizzard
        -- is about to delete anyway.
        C_Timer.After(1.5, function()
            InitPlayer()
            local q = ns.QUESTS[questId]
            local queued = false
            for _, itemId in ipairs(BagItemIds()) do
                -- only items connected to THIS quest - no spam about
                -- unrelated old leftovers
                local involved = (q and q.items[itemId] ~= nil)
                    or ns.QUEST_STARTER[itemId] == questId
                    or ITEM_DEAD_AFTER[itemId] == questId
                    or ProvidedBy(itemId, questId)
                if involved and (GetItemCount(itemId) or 0) > 0
                    and deletableCheck(itemId, questId) then
                    local name, link = GetItemInfo(itemId)
                    print(PREFIX .. format(msg, link or name or ("#" .. itemId)))
                    pendingOffers[#pendingOffers + 1] = { itemId = itemId, msg = msg }
                    queued = true
                end
            end
            if queued and not (popup and popup:IsShown()) then
                ShowNextOffer()
            end
        end)
    end

    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("QUEST_TURNED_IN")
    watcher:RegisterEvent("QUEST_REMOVED")
    watcher:SetScript("OnEvent", function(_, event, questId)
        if event == "QUEST_TURNED_IN" then
            recentTurnIn[questId] = GetTime()
            ProcessQuest(questId, DeletableAfterTurnIn,
                L["%s is no longer needed - every quest that needed it is completed."])
        else -- QUEST_REMOVED: abandon, unless this was a turn-in
            local turnedIn = recentTurnIn[questId]
            if turnedIn and GetTime() - turnedIn < 5 then return end
            if ns.QUESTS[questId] then
                ProcessQuest(questId, DeletableAfterAbandon,
                    L["%s is not needed by any quest in your log anymore."])
            end
        end
    end)
end)

local function HandleTooltip(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if not ModifierOK() then return end
    local itemId = data and data.id
    if not itemId and tooltip.GetItem then
        local _, link = tooltip:GetItem()
        itemId = link and tonumber(link:match("item:(%d+)"))
    end
    if not itemId then return end
    AddQuestLines(tooltip, itemId)
end

ns.OnInit(function()
    -- With a modifier configured, pressing/releasing it while already
    -- hovering should update the tooltip: re-run the owner's OnEnter so
    -- the tooltip is rebuilt (and our post-call runs again).
    local events = CreateFrame("Frame")
    events:RegisterEvent("MODIFIER_STATE_CHANGED")
    events:SetScript("OnEvent", function()
        if (ns.db.modifier or "NONE") == "NONE" then return end
        if not GameTooltip:IsShown() then return end
        local owner = GameTooltip:GetOwner()
        if not owner or not GameTooltip.GetItem then return end
        local _, link = GameTooltip:GetItem()
        if not link then return end
        local onEnter = owner:GetScript("OnEnter")
        if onEnter then
            GameTooltip:Hide()
            onEnter(owner, true)
        end
    end)

    local function OnCleared(tooltip)
        tooltip.questTipsDone = nil
    end
    GameTooltip:HookScript("OnTooltipCleared", OnCleared)
    ItemRefTooltip:HookScript("OnTooltipCleared", OnCleared)

    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum.TooltipDataType and Enum.TooltipDataType.Item then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, HandleTooltip)
    else
        -- Pre-10.0 tooltip API fallback; OnTooltipSetItem can fire twice for
        -- the same item, hence the cleared-on-hide guard.
        local function OnSetItem(tooltip)
            if tooltip.questTipsDone then return end
            tooltip.questTipsDone = true
            HandleTooltip(tooltip)
        end
        GameTooltip:HookScript("OnTooltipSetItem", OnSetItem)
        ItemRefTooltip:HookScript("OnTooltipSetItem", OnSetItem)
    end
end)

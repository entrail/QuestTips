local ADDON_NAME, ns = ...
local L = ns.L

-- Settings under Settings -> Options -> AddOns using the modern Settings
-- API, grouped into sections: Quest states (one checkbox per line color),
-- Display (shared behavior options), About. All settings apply immediately
-- (tooltips read them live), so no refresh callbacks needed.

ns.OnInit(function()
    local category, layout = Settings.RegisterVerticalLayoutCategory(ADDON_NAME)
    category.ID = ADDON_NAME
    ns.settingsCategory = category

    local function AddHeader(text)
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
    end

    local function AddCheckbox(dbKey, name, default, tooltip)
        local setting = Settings.RegisterAddOnSetting(
            category,
            "QuestTips_" .. dbKey,
            dbKey,
            ns.db,
            Settings.VarType.Boolean,
            name,
            default
        )
        Settings.CreateCheckbox(category, setting, tooltip)
    end

    -- ----------------------------------------------------------------
    -- Quest states
    -- ----------------------------------------------------------------
    AddHeader(L["Quest states"])

    -- Labels carry the line color so the mapping is obvious in the panel.
    AddCheckbox("showInLog", "|cff40c040" .. L["In my quest log"] .. "|r", true,
        L["Show quests currently in your quest log that need the item (with your have/need count)."])
    AddCheckbox("showAvailable", "|cffffff00" .. L["Not done yet"] .. "|r", true,
        L["Show quests you have neither in the log nor completed - you might need the item later, and others need it too."])
    AddCheckbox("showRepeatable", "|cff4da6ff" .. L["Repeatable turn-ins"] .. "|r", true,
        L["Show repeatable turn-in quests (reputation and event turn-ins). They can always be handed in again - permanent demand."])
    AddCheckbox("showCompleted", "|cffff5050" .. L["Already completed"] .. "|r", true,
        L["Show quests you have already completed. You no longer need the item, but it may still sell on the auction house."])

    -- ----------------------------------------------------------------
    -- Display
    -- ----------------------------------------------------------------
    AddHeader(L["Display"])

    AddCheckbox("showQuestNames", L["Show quest names"], true,
        L["List each quest by name with the required count. Disabled, a single compact 'Needed for N quests' line is shown instead."])

    do
        local setting = Settings.RegisterAddOnSetting(
            category,
            "QuestTips_MaxLines",
            "maxLines",
            ns.db,
            Settings.VarType.Number,
            L["Quests listed per item"],
            4
        )
        local options = Settings.CreateSliderOptions(1, 10, 1)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
        Settings.CreateSlider(category, setting, options,
            L["Quest lines per item tooltip; more are summarized as '+N more quests'."])
    end

    do
        local setting = Settings.RegisterAddOnSetting(
            category,
            "QuestTips_Modifier",
            "modifier",
            ns.db,
            Settings.VarType.String,
            L["Show only while holding"],
            "NONE"
        )
        local function GetOptions()
            local options = Settings.CreateControlTextContainer()
            options:Add("NONE", L["Always show"])
            options:Add("SHIFT", SHIFT_KEY_TEXT or "Shift")
            options:Add("CTRL", CTRL_KEY_TEXT or "Ctrl")
            options:Add("ALT", ALT_KEY_TEXT or "Alt")
            return options:GetData()
        end
        Settings.CreateDropdown(category, setting, GetOptions,
            L["Only add the tooltip information while this modifier key is held down."])
    end

    AddCheckbox("includeNonDrop", L["Include gathered/fished/crafted items"], true,
        L["Also annotate quest items that are only obtained by gathering, fishing or crafting. Items that (also) drop from enemies are always annotated."])

    AddCheckbox("checkDeletable", L["Check deletable quest items"], true,
        L["Quest-bound items and leftover quest-starter items (maps, notes, ...) get a clear 'can be deleted' line once every quest that needs them is completed - or show which open quests still do."])

    AddCheckbox("warnDeletable", L["Announce deletable leftovers after turn-ins and abandons"], true,
        L["When turning in or abandoning a quest leaves a now-deletable quest item in your bags, show a chat message and a small window with the item and a delete button."])

    -- ----------------------------------------------------------------
    -- About
    -- ----------------------------------------------------------------
    AddHeader(L["About"])
    local function AddAboutLine(text)
        layout:AddInitializer(Settings.CreateElementInitializer(
            "QuestTipsSettingsTextTemplate", { name = text }))
    end
    AddAboutLine(format(L["Author: %s"], "Entrail09"))
    AddAboutLine(format(L["Version: %s"], ns.version or "?"))

    Settings.RegisterAddOnCategory(category)
end)

SLASH_QUESTTIPS1 = "/questtips"
SLASH_QUESTTIPS2 = "/qtips"
SlashCmdList.QUESTTIPS = function()
    if ns.settingsCategory then
        Settings.OpenToCategory(ns.settingsCategory:GetID())
    end
end

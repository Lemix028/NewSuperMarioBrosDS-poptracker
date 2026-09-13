-- Archipelago callback-driven auto-tracking for NSMBDS.

local currentIndex = -1
local currentWorld = nil
local currentTab = nil
local currentView = nil
local viewStorageKey = nil
local viewSubscriptionReady = false
local viewSubscriptionRetryFrames = 0
local ensureViewSubscription

local function getViewStorageKey()
    local team = Archipelago.TeamNumber
    local player = Archipelago.PlayerNumber
    if type(team) ~= "number" or type(player) ~= "number" or team < 0 or player < 0 then
        return nil
    end
    return "nsmbds_current_view_" .. tostring(math.tointeger(team)) .. "_" .. tostring(math.tointeger(player))
end

local function autoWorldSwitchEnabled()
    local option = Tracker:FindObjectForCode("option_auto_world_switch")
    return option == nil or option.Active
end

local function randomizedLevelView(world, tab)
    if tab == "W" .. tostring(world) .. " Overworld" then
        return world, tab
    end

    local slotName = tab:gsub("^W", "World ", 1)
    local contentName = (NSMBDS_LEVEL_MAPPING or {})[slotName]
    if contentName == nil then
        return world, tab
    end

    local contentWorld = math.tointeger(tonumber(contentName:match("^World (%d+)%-")))
    if contentWorld == nil or contentWorld < 1 or contentWorld > 8 then
        return world, tab
    end
    return contentWorld, contentName:gsub("^World ", "W", 1)
end

local function activateCurrentView()
    if currentWorld ~= nil and currentTab ~= nil and autoWorldSwitchEnabled() then
        Tracker:UiHint("ActivateTab", "World " .. tostring(currentWorld))
        Tracker:UiHint("ActivateTab", currentTab)
        print("NSMBDS auto-view activated World " .. tostring(currentWorld) .. " / " .. currentTab)
    end
end

local function observeCurrentView(value)
    local encoded = tostring(value)
    local worldText, tab = encoded:match("^(%d+)|(.+)$")
    local world = math.tointeger(tonumber(worldText) or -1)
    if world == nil or world < 1 or world > 8 or tab == nil or tab == "" or currentView == encoded then
        return
    end
    currentWorld, currentTab = randomizedLevelView(world, tab)
    currentView = encoded
    activateCurrentView()
end

local function slotBool(slotData, key, defaultValue)
    if slotData == nil or slotData[key] == nil then
        return defaultValue
    end
    local value = slotData[key]
    if type(value) == "number" then
        return value ~= 0
    end
    if type(value) == "string" then
        return value ~= "0" and value ~= "false" and value ~= ""
    end
    return not not value
end

local function setToggle(code, active)
    local item = Tracker:FindObjectForCode(code)
    if item then
        item.Active = active
    end
end

local function resetCounter(code, value)
    local item = Tracker:FindObjectForCode(code)
    if item then
        item.AcquiredCount = value or 0
    end
end

local function resetSections()
    for _, mapping in ipairs(NSMBDS_ALL_SECTIONS) do
        local address = "@" .. mapping.location .. "/" .. mapping.section
        local section = Tracker:FindObjectForCode(address)
        if section then
            section.AvailableChestCount = section.ChestCount
        end
    end
end

local function resetState(slotData)
    currentIndex = -1
    currentWorld = nil
    currentTab = nil
    currentView = nil
    viewStorageKey = nil
    viewSubscriptionReady = false
    viewSubscriptionRetryFrames = 0

    for _, code in ipairs(NSMBDS_TRACKED_ITEM_CODES) do
        local item = Tracker:FindObjectForCode(code)
        if item then
            if item.Type == "consumable" then
                item.AcquiredCount = 0
            else
                item.Active = false
            end
        end
    end
    resetCounter("received_star_coins", 0)
    resetCounter("gate_permit_count", 0)
    resetCounter("required_star_coins", 80)
    resetSections()

    setToggle("option_star_coins", slotBool(slotData, "star_coin_checks", true))
    setToggle("option_red_coins", slotBool(slotData, "red_coin_checks", true))
    setToggle("option_secret_exits", slotBool(slotData, "secret_exit_checks", false))
    setToggle("option_toad_houses", slotBool(slotData, "toad_house_checks", true))
    setToggle("option_one_up_blocks", slotBool(slotData, "one_up_block_checks", false))
    setToggle("option_blocksanity", slotBool(slotData, "blocksanity", false))
    setToggle("option_bonus_area", slotBool(slotData, "world_6_2_bonus_area", false))
    setToggle("option_secret_exit_shortcut_logic", slotBool(slotData, "secret_exit_shortcut_logic", false))
    setToggle("option_secret_exit_world_unlock_logic", slotBool(slotData, "secret_exit_world_unlock_logic", false))
    setToggle("option_cannon_route_logic", slotBool(slotData, "cannon_route_logic", false))
    setToggle("keys_disabled", not slotBool(slotData, "tower_castle_keys", true))

    local gateMode = 0
    if slotData and type(slotData["star_coin_gate_mode"]) == "number" then
        gateMode = math.tointeger(slotData["star_coin_gate_mode"]) or 0
    end
    local gateModeItem = Tracker:FindObjectForCode("gate_mode_selector")
    if gateModeItem then gateModeItem.CurrentStage = math.max(0, math.min(2, gateMode)) end

    local levelMode = 0
    if slotData and type(slotData["level_randomization"]) == "number" then
        levelMode = math.tointeger(slotData["level_randomization"]) or 0
    end
    local levelModeItem = Tracker:FindObjectForCode("level_randomization_mode")
    if levelModeItem then levelModeItem.CurrentStage = math.max(0, math.min(2, levelMode)) end
    NSMBDS_SetLevelMapping(levelMode, slotData and slotData["level_mapping"] or nil)

    local tierData = nil
    if slotData then
        if gateMode == 0 then
            tierData = slotData["vanilla_gate_tiers"]
        elseif gateMode == 2 then
            tierData = slotData["individual_gate_tiers"]
        end
    end
    for index, gate in ipairs(NSMBDS_GATE_DATA or {}) do
        local tier = gate.tier
        if tierData then
            local key = gateMode == 0 and gate.name or gate.permit
            tier = math.tointeger(tonumber(tierData[key])) or tier
        end
        NSMBDS_GATE_TIERS[index] = tier
    end

    local licenseOptions = {
        {"license_mini_mushroom", "license_mini_mushroom_disabled", true},
        {"license_blue_shell", "license_blue_shell_disabled", true},
        {"license_mega_mushroom", "license_mega_mushroom_disabled", true},
        {"license_mushroom", "license_mushroom_disabled", false},
        {"license_fire_flower", "license_fire_flower_disabled", true},
        {"license_touchscreen_pocket", "license_touchscreen_pocket_disabled", false},
    }
    for _, option in ipairs(licenseOptions) do
        setToggle(option[2], not slotBool(slotData, option[1], option[3]))
    end

    local goal = Tracker:FindObjectForCode("goal_setting")
    if goal then
        local goalValue = slotData and slotData["goal"] or 0
        goal.CurrentStage = math.max(0, math.min(3, math.tointeger(goalValue) or 0))
    end
    local required = slotData and slotData["required_star_coins"] or 80
    resetCounter("required_star_coins", math.tointeger(required) or 80)

    ensureViewSubscription()
end

local function reset(slotData)
    local previous = Tracker.BulkUpdate
    Tracker.BulkUpdate = true
    local ok, message = pcall(resetState, slotData)
    Tracker.BulkUpdate = previous
    if not ok then error(message) end
end

ensureViewSubscription = function()
    if viewSubscriptionReady then
        return
    end
    local key = getViewStorageKey()
    if key == nil then
        return
    end
    viewStorageKey = key
    local notifyReady = Archipelago:SetNotify({key})
    local getReady = Archipelago:Get({key})
    if notifyReady and getReady then
        viewStorageKey = key
        viewSubscriptionReady = true
        print("NSMBDS auto-view subscribed to " .. key)
    end
end

local function dataStorageRetrieved(key, value)
    if key == viewStorageKey then
        print("NSMBDS auto-view retrieved " .. key .. " = " .. tostring(value))
        observeCurrentView(value)
    end
end

local function dataStorageChanged(key, value, _oldValue)
    if key == viewStorageKey then
        print("NSMBDS auto-view changed " .. key .. " = " .. tostring(value))
        observeCurrentView(value)
    end
end

local function itemReceived(index, itemId, _itemName, _player)
    if index <= currentIndex then
        return
    end
    currentIndex = index

    local mapping = NSMBDS_ITEM_MAP[itemId]
    if mapping == nil then
        return
    end
    local item = Tracker:FindObjectForCode(mapping.code)
    if item then
        if mapping.kind == "consumable" then
            item.AcquiredCount = math.min(item.AcquiredCount + 1, item.MaxCount)
            if mapping.code == "item_progressive_gate_pass" then
                -- Force deferred logic to re-evaluate the Lua gate functions.
                Tracker.BulkUpdate = true
                Tracker.BulkUpdate = false
            end
        else
            item.Active = true
        end
    end
    if mapping.gate then
        local count = Tracker:FindObjectForCode("gate_permit_count")
        if count then
            count.AcquiredCount = math.min(count.AcquiredCount + 1, count.MaxCount)
        end
    end
end

local function locationChecked(locationId, _locationName)
    local mapping = NSMBDS_LOCATION_MAP[locationId]
    if mapping == nil then
        return
    end
    for _, target in ipairs(mapping.targets) do
        local address = "@" .. target.location .. "/" .. target.section
        local section = Tracker:FindObjectForCode(address)
        if section then
            section.AvailableChestCount = 0
        end
    end
end

Archipelago:AddClearHandler("NSMBDS reset", reset)
Archipelago:AddItemHandler("NSMBDS item received", itemReceived)
Archipelago:AddLocationHandler("NSMBDS location checked", locationChecked)
Archipelago:AddRetrievedHandler("NSMBDS current view retrieved", dataStorageRetrieved)
Archipelago:AddSetReplyHandler("NSMBDS current view changed", dataStorageChanged)
ScriptHost:AddWatchForCode("NSMBDS auto view option", "option_auto_world_switch", function(_code)
    activateCurrentView()
end)
ScriptHost:AddOnFrameHandler("NSMBDS current view subscription", function()
    if viewSubscriptionReady then
        return
    end
    viewSubscriptionRetryFrames = viewSubscriptionRetryFrames + 1
    if viewSubscriptionRetryFrames >= 60 then
        viewSubscriptionRetryFrames = 0
        ensureViewSubscription()
    end
end)

-- Give every gate a direct Lua rule. This avoids stale JSON provider caches
-- when Archipelago replays multiple copies of the same progressive item.
for gateIndex = 1, 32 do
    local requiredCount = gateIndex
    _G["progressiveGate" .. requiredCount] = function()
        local item = Tracker:FindObjectForCode("item_progressive_gate_pass")
        if item and item.AcquiredCount >= requiredCount then
            return 1
        end
        return 0
    end
end

-- APWorld assigns each gate a tier. Progressive mode uses its fixed progression
-- index; vanilla and individual modes restore the seed-specific shuffled tier.
NSMBDS_GATE_TIERS = NSMBDS_GATE_TIERS or {}
for gateIndex = 1, 32 do
    local index = gateIndex
    _G["starCoinGateCost" .. index] = function()
        local coins = Tracker:FindObjectForCode("received_star_coins")
        local gate = NSMBDS_GATE_DATA and NSMBDS_GATE_DATA[index]
        local tier = NSMBDS_GATE_TIERS[index] or (gate and gate.tier) or index
        local cost = gate and gate.cost or 5
        if coins and coins.AcquiredCount >= tier * cost then
            return 1
        end
        return 0
    end
end

-- Level Randomization keeps checks attached to course content while route
-- requirements, keys and gates remain attached to the overworld slot. The
-- seed supplies slot -> content; these functions evaluate the inverse lookup
-- on demand, so all checks in one course share a single small Lua rule.
NSMBDS_LEVEL_MAPPING = NSMBDS_LEVEL_MAPPING or {}
NSMBDS_LEVEL_INVERSE = NSMBDS_LEVEL_INVERSE or {}

local function boolAccess(value)
    return value and AccessibilityLevel.Normal or AccessibilityLevel.None
end

local function itemActive(code)
    return Tracker:ProviderCountForCode(code) > 0
end

local function andAccess(left, right)
    return math.min(left, right)
end

local function eventAccess(eventName)
    local suffix = eventName:match(" (Goal)$") or eventName:match(" (Secret Exit)$")
    if suffix == nil then
        return AccessibilityLevel.None
    end
    local slotName = eventName:sub(1, #eventName - #suffix - 1)
    local mappedName = slotName
    if suffix ~= "Secret Exit" or not (NSMBDS_MINI_CASTLE_SECRET_EXIT_SLOTS or {})[slotName] then
        mappedName = (NSMBDS_LEVEL_MAPPING or {})[slotName] or slotName
    end
    local address = (NSMBDS_EVENT_ADDRESSES or {})[mappedName .. " " .. suffix]
    local section = address and Tracker:FindObjectForCode(address) or nil
    return section and section.AccessibilityLevel or AccessibilityLevel.None
end

local gateAccess
local function atomAccess(atom)
    local gateRegion = atom:match("^REGION:(.+)$")
    if gateRegion then
        local gateIndex = (NSMBDS_GATE_REGION_INDEX or {})[gateRegion]
        return gateIndex and gateAccess(gateIndex) or AccessibilityLevel.None
    end
    return eventAccess(atom)
end

local function alternativeAccess(alternative)
    local result = AccessibilityLevel.Normal
    for _, atom in ipairs(alternative) do
        result = andAccess(result, atomAccess(atom))
        if result == AccessibilityLevel.None then return result end
    end
    return result
end

local function requirementAccess(requirement)
    local hasNormalRoute = false
    for _, alternative in ipairs(requirement or {}) do
        local usesOptionalSecret = false
        for _, atom in ipairs(alternative) do
            if (NSMBDS_INTRA_WORLD_SECRET_EXITS or {})[atom] then
                usesOptionalSecret = true
                break
            end
        end
        if not usesOptionalSecret then hasNormalRoute = true end
    end
    local shortcuts = itemActive("option_secret_exit_shortcut_logic")
    local result = AccessibilityLevel.None
    for _, alternative in ipairs(requirement or {}) do
        local usesOptionalSecret = false
        for _, atom in ipairs(alternative) do
            if (NSMBDS_INTRA_WORLD_SECRET_EXITS or {})[atom] then
                usesOptionalSecret = true
                break
            end
        end
        if shortcuts or not (hasNormalRoute and usesOptionalSecret) then
            result = math.max(result, alternativeAccess(alternative))
        end
    end
    return result
end

local function routeAccess(routes, requireOption, secretDependent)
    if requireOption and not itemActive(requireOption) then
        return AccessibilityLevel.None
    end
    local result = AccessibilityLevel.None
    for _, alternative in ipairs(routes or {}) do
        local allowed = true
        if secretDependent and not itemActive("option_secret_exit_shortcut_logic") then
            for _, atom in ipairs(alternative) do
                if atom == "World 2-A Secret Exit" then allowed = false end
            end
        end
        if allowed then result = math.max(result, alternativeAccess(alternative)) end
    end
    return result
end

local function worldAccess(worldNumber)
    if worldNumber == 1 then return AccessibilityLevel.Normal end
    local routes = (NSMBDS_WORLD_ROUTES or {})[worldNumber]
    if routes == nil then return AccessibilityLevel.None end
    local result = boolAccess(itemActive(routes.pass))
    result = math.max(result, routeAccess(routes.normal, nil, true))
    result = math.max(result, routeAccess(routes.alternate, "option_secret_exit_world_unlock_logic", true))
    result = math.max(result, routeAccess(routes.cannon, "option_cannon_route_logic", true))
    return result
end

local function gateAuthorization(gateIndex)
    local gate = (NSMBDS_GATE_DATA or {})[gateIndex]
    if gate == nil then return AccessibilityLevel.None end
    local coins = _G["starCoinGateCost" .. gateIndex]() > 0
    if not coins then return AccessibilityLevel.None end
    if itemActive("gate_mode_vanilla") then return AccessibilityLevel.Normal end
    if itemActive("gate_mode_progressive") then
        return boolAccess(_G["progressiveGate" .. gateIndex]() > 0)
    end
    if itemActive("gate_mode_individual") then
        return boolAccess(itemActive(gate.code))
    end
    return AccessibilityLevel.None
end

gateAccess = function(gateIndex)
    local gate = (NSMBDS_GATE_DATA or {})[gateIndex]
    if gate == nil then return AccessibilityLevel.None end
    local worldNumber = tonumber(gate.name:match("World (%d+)") or "0") or 0
    return andAccess(worldAccess(worldNumber), gateAuthorization(gateIndex))
end

local function randomizedSlotAccess(actualRegion)
    local requirement = (NSMBDS_STAGE_REQUIREMENTS or {})[actualRegion]
    if requirement == nil then
        requirement = (NSMBDS_TOAD_REQUIREMENTS or {})[actualRegion]
    end
    if requirement == nil then return AccessibilityLevel.None end
    local worldNumber = tonumber(actualRegion:match("World (%d+)") or "0") or 0
    local result = andAccess(worldAccess(worldNumber), requirementAccess(requirement))
    local keyCode = (NSMBDS_STAGE_KEYS or {})[actualRegion]
    if keyCode and not itemActive("keys_disabled") then
        result = andAccess(result, boolAccess(itemActive(keyCode)))
    end
    local gateIndex = (NSMBDS_GATE_TARGET_INDEX or {})[actualRegion]
    if gateIndex then result = andAccess(result, gateAuthorization(gateIndex)) end
    return result
end

function NSMBDS_RandomizedRegionAccess(regionName)
    local slotName = (NSMBDS_LEVEL_INVERSE or {})[regionName] or regionName
    if (NSMBDS_STAGE_REQUIREMENTS or {})[regionName] == nil then slotName = regionName end
    return randomizedSlotAccess(slotName)
end

function NSMBDS_RandomizedBossAccess(contentName)
    local goalAddress = (NSMBDS_EVENT_ADDRESSES or {})[contentName .. " Goal"]
    local goal = goalAddress and Tracker:FindObjectForCode(goalAddress) or nil
    local result = goal and goal.AccessibilityLevel or AccessibilityLevel.None
    local slotName = (NSMBDS_LEVEL_INVERSE or {})[contentName] or contentName
    if (NSMBDS_MINI_CASTLE_SECRET_EXIT_SLOTS or {})[slotName] then
        result = math.max(result, eventAccess(slotName .. " Secret Exit"))
    end
    return result
end

function NSMBDS_SetLevelMapping(mode, mapping)
    NSMBDS_LEVEL_MAPPING = {}
    NSMBDS_LEVEL_INVERSE = {}
    for _, name in ipairs(NSMBDS_LEVEL_NAMES or {}) do
        NSMBDS_LEVEL_MAPPING[name] = name
        NSMBDS_LEVEL_INVERSE[name] = name
    end
    if mode ~= 0 and type(mapping) == "table" then
        for slotName, contentName in pairs(mapping) do
            if NSMBDS_LEVEL_MAPPING[slotName] and NSMBDS_LEVEL_INVERSE[contentName] then
                NSMBDS_LEVEL_MAPPING[slotName] = contentName
            end
        end
        for slotName, contentName in pairs(NSMBDS_LEVEL_MAPPING) do
            NSMBDS_LEVEL_INVERSE[contentName] = slotName
        end
    end
end

for index, regionName in ipairs(NSMBDS_RANDOMIZED_REGIONS or {}) do
    local region = regionName
    _G["randomized_access_" .. region:lower():gsub("&", "and"):gsub("'", ""):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")] = function()
        return NSMBDS_RandomizedRegionAccess(region)
    end
    _G["randomized_slot_access_" .. region:lower():gsub("&", "and"):gsub("'", ""):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")] = function()
        return randomizedSlotAccess(region)
    end
end

for _, stageName in ipairs(NSMBDS_BOSS_STAGES or {}) do
    local stage = stageName
    _G["randomized_boss_access_" .. stage:lower():gsub("&", "and"):gsub("'", ""):gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")] = function()
        return NSMBDS_RandomizedBossAccess(stage)
    end
end

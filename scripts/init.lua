-- NSMBDS PopTracker pack entry point.

Tracker.AllowDeferredLogicUpdate = true
Tracker.BulkUpdate = true

Tracker:AddItems("items/items.json")
Tracker:AddMaps("maps/maps.json")
ScriptHost:LoadScript("scripts/generated/data.lua")
ScriptHost:LoadScript("scripts/logic.lua")
NSMBDS_SetLevelMapping(0, nil)
ScriptHost:LoadScript("scripts/generated/locations.lua")
Tracker:AddLayouts("layouts/tracker.json")
-- Overworld sections reference the level checks directly; no duplicate state.

-- Mirror the APWorld defaults for a new offline tracker. A connected seed
-- replaces these values from slot_data.
local default_options = {
    "option_star_coins",
    "option_red_coins",
    "option_toad_houses",
    "option_auto_world_switch",
    "license_mushroom_disabled",
    "license_touchscreen_pocket_disabled",
}
for _, opt in ipairs(default_options) do
    local item = Tracker:FindObjectForCode(opt)
    if item then
        item.Active = true
    end
end

if Archipelago then
    ScriptHost:LoadScript("scripts/archipelago.lua")
end

Tracker.BulkUpdate = false

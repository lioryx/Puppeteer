-- An experimental feature that tracks enemies

local util = PTUtil

if not util.HasGUIDUnits() then
    return
end

util.SetEnvironment(Puppeteer)

local function isUnitRelevant(unit)
    return UnitCanAttack("player", unit) and UnitHealth(unit) > 0 and UnitIsConnected(unit) and UnitExists(unit) 
        and (UnitAffectingCombat(unit) or UnitIsUnit(unit, "target") or UnitIsUnit(unit, "pettarget"))
end

local isUnitNearby = util.CanClientGetPreciseDistance(true) and
function(unit)
    return util.GetDistanceTo(unit) < 60
end
or
function() return true end

local f = CreateFrame("Frame", "PTEnemyUpdater")

f:SetScript("OnEvent", function()
    local unit = arg1
    if event == "NAME_PLATE_UNIT_ADDED" then
        unit = arg1
    elseif event == "PLAYER_TARGET_CHANGED" then
        unit = "target"
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        unit = UnitGUID("mouseover")
    end

    if UnitCanAttack("player", unit) and not UnitIsCharmed("player") and (UnitAffectingCombat(unit) or (unit == "target" and UnitHealth(unit) > 0)) then
        if not CustomUnitsMap["enemy"] then
            return
        end

        local guid = UnitGUID(unit)
        if not guid then return end
        if IsGuidUnitType(guid, "enemy") then -- Already enemy
            return
        end

        local enemyUnits = CustomUnitsMap["enemy"]
        if not enemyUnits then
            return
        end

        if not util.IsReallyInInstance() and (not UnitAffectingCombat("player") or not isUnitNearby(unit)) 
                and (unit ~= "target" or not UnitCanAttack("player", unit)) then
            return
        end

        for _, enemyUnit in ipairs(enemyUnits) do
            if CustomUnitGUIDMap[enemyUnit] then
                if not isUnitRelevant(enemyUnit) then
                    SetCustomUnitGuid(enemyUnit, nil)
                    SetCustomUnitGuid(enemyUnit, guid)
                    return
                end
            end
        end

        SetGuidUnitType(guid, "enemy")
    end
end)

local nextUpdate = GetTime() + 0.25
local EnemyTracker_OnUpdate = function()
    if GetTime() >= nextUpdate then
        nextUpdate = GetTime() + 0.25

        local enemyUnits = CustomUnitsMap["enemy"]
        if not enemyUnits then
            return
        end
        local maxEnemies = table.getn(enemyUnits)
        local lastIndex = 0
        for i, unit in ipairs(enemyUnits) do
            if CustomUnitGUIDMap[unit] then
                if isUnitRelevant(unit) then
                    lastIndex = i
                end
            end
        end

        for i = lastIndex + 1, maxEnemies do
            local enemyUnit = enemyUnits[i]
            if CustomUnitGUIDMap[enemyUnit] then
                SetCustomUnitGuid(enemyUnit, nil)
            end
        end
    end
end

local enemySchedule
function SetEnemyTrackingEnabled(trackEnemies)
    if enemySchedule then enemySchedule:Cancel(); enemySchedule = nil end
    if trackEnemies then
        if PTClientAPI.Enabled and C_EventUtils and C_EventUtils.IsEventValid("NAME_PLATE_UNIT_ADDED") then
            f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        end
        f:RegisterEvent("UNIT_COMBAT")
        f:RegisterEvent("UNIT_FLAGS")
        f:RegisterEvent("PLAYER_TARGET_CHANGED")
        f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
        if PTClientAPI.Capabilities.Timer then
            f:SetScript("OnUpdate", nil)
            enemySchedule = PTClientAPI.NewScheduler(EnemyTracker_OnUpdate, 0.25)
        else f:SetScript("OnUpdate", EnemyTracker_OnUpdate) end
    else
        f:UnregisterAllEvents()
        f:SetScript("OnUpdate", nil)
        for _, unit in ipairs(CustomUnitsMap["enemy"]) do
            SetCustomUnitGuid(unit, nil)
        end
    end
end

RegisterCustomUnits("enemy", 40)

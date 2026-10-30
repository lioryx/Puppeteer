local api = PTClientAPI
if not PTHealPredict then return end
local predict = PTHealPredict
local originalIncoming = predict.GetIncomingHealing
local function guidName(guid) return UnitName(api.QueryUnit(guid)) end
local function uniqueName(guid)
    local name = guidName(guid)
    if not name then return nil end
    for other in pairs(PTGuidRoster.GuidUnitMap) do
        if other ~= guid and guidName(other) == name then return nil end
    end
    return name
end
function predict.GetIncomingHealing(guid)
    if not api.Enabled then return originalIncoming(guid) end
    if not guid then return 0, 0 end
    local total, direct = originalIncoming(guid)
    local cache = PTUnit.Get(guid)
    if cache and cache.NativeAuras then
        total = direct
        for _, aura in pairs(cache.NativeAuras) do
            if aura.sourceGUID and aura.id then
                total = total + predict.GetExpectedHeal(guidName(aura.sourceGUID), aura.id.."-HoT")
            end
        end
    end
    local comm = AceLibrary("HealComm-1.0")
    local targetName = uniqueName(guid)
    local function covered(name)
        for caster, cast in pairs(predict.IncomingHeals[guid] or {}) do
            if cast.heal > 0 and guidName(caster) == name then return true end
        end
    end
    local extra = 0
    local counted = {}
    if comm and targetName then
        for caster, heal in pairs((comm.Heals and comm.Heals[targetName]) or {}) do
            if heal.ctime > GetTime() and not covered(caster) then
                extra = extra + heal.amount; counted[caster] = true
            end
        end
        for caster, heal in pairs(comm.GrpHeals or {}) do
            if heal.ctime > GetTime() and not counted[caster] and not covered(caster) then
                for _, name in ipairs(heal.targets) do
                    if name == targetName then extra = extra + heal.amount; break end
                end
            end
        end
    end
    return total + extra, direct + extra
end
local originalResCount = predict.GetResurrectionCount
function predict.GetResurrectionCount(guid)
    if not api.Enabled then return originalResCount(guid) end
    if not guid then return 0 end
    local count, names = 0, {}
    for caster in pairs(predict.ResurrectionTargets[guid] or {}) do
        count = count + 1
        local name = guidName(caster)
        if name then names[name] = true end
    end
    local comm, target = AceLibrary("HealComm-1.0"), uniqueName(guid)
    for name, expires in pairs((target and comm.pendingResurrections and comm.pendingResurrections[target]) or {}) do
        if expires > GetTime() and not names[name] then count = count + 1 end
    end
    return count
end
function predict.IsBeingResurrected(guid) return predict.GetResurrectionCount(guid) > 0 end
function predict.GetIncomingDirectHealing(guid)
    local _, direct = predict.GetIncomingHealing(guid)
    return direct
end
local f = CreateFrame("Frame", "PTClassicHealingLog")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 ~= "Puppeteer" or not api.Enabled then return end
        PuppeteerLib:RegisterEvent("HealComm_Healupdate", function(name)
            for guid in pairs(PTGuidRoster.GuidUnitMap) do
                if guidName(guid) == name then Puppeteer.QueueRefresh(guid, "heal") end
            end
        end)
        PuppeteerLib:RegisterEvent("HealComm_Ressupdate", function(name)
            for guid in pairs(PTGuidRoster.GuidUnitMap) do
                if guidName(guid) == name then Puppeteer.QueueRefresh(guid, "health") end
            end
        end)
        if CombatLogGetCurrentEventInfo and C_EventUtils and C_EventUtils.IsEventValid("COMBAT_LOG_EVENT_UNFILTERED") then
            f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            PTHealPredictCombatLog:UnregisterAllEvents()
            PTHealPredictPerCombatLog:UnregisterAllEvents()
        end
        return
    end
    local _, kind, _, source, sourceName, _, _, target, _, _, _, spell, _, _, amount, _, _, critical = CombatLogGetCurrentEventInfo()
    if (kind ~= "SPELL_HEAL" and kind ~= "SPELL_PERIODIC_HEAL") or critical or not amount or not sourceName then return end
    local cache = PTUnit.Get(target)
    if not cache or cache == PTUnit or cache.HasHealingModifier then return end
    local key = kind == "SPELL_PERIODIC_HEAL" and spell.."-HoT" or spell
    local generic = predict.HealCache
    generic[key] = generic[key] and generic[key] + (amount-generic[key])*0.05 or amount
    local personal = predict.PlayerHealCache[sourceName]
    if not personal then personal = {}; predict.PlayerHealCache[sourceName] = personal end
    personal[key] = personal[key] and personal[key] + (amount-personal[key])*0.25 or amount
    personal.lastSeen = time()
    Puppeteer.QueueRefresh(target, "heal")
end)

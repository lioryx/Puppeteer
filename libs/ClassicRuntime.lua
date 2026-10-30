local api = PTClientAPI
local plates = {}
function Puppeteer.RefreshEventFilters()
    if not api.Enabled or not PTUtil.HasGUIDUnits() then return end
    local tokens = {}
    for _, token in ipairs(PTUtil.AllRealUnits) do table.insert(tokens, token) end
    for token, guid in pairs(plates) do
        if api.GetGUID(token) == guid then
            table.insert(tokens, token)
            PTGuidRoster.SetUnitGuid(token, guid)
        else plates[token] = nil end
    end
    -- SuperWoW emits GUID arguments; native events use real tokens only.
    if PTUtil.IsSuperWowPresent() then
        for guid in pairs(Puppeteer.GUIDCustomUnitMap) do table.insert(tokens, guid) end
    end
    for _, f in ipairs(Puppeteer.EventHandlerFrames) do
        if f.RegisterUnitEvent then
            for _, e in ipairs(f.PTEvents or {}) do
                if e == "UNIT_AURA" or e == "UNIT_HEALTH" or e == "UNIT_MAXHEALTH" or
                    e == "UNIT_MANA" or e == "UNIT_RAGE" or e == "UNIT_ENERGY" or e == "UNIT_FOCUS" or
                    e == "UNIT_MAXMANA" or e == "UNIT_DISPLAYPOWER" then
                    f:UnregisterEvent(e)
                    f:RegisterUnitEvent(e, unpack(tokens))
                end
            end
        end
    end
end
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
    if not api.Enabled or not PTUtil.HasGUIDUnits() then return end
    if event == "PLAYER_ENTERING_WORLD" then
        if C_EventUtils and C_EventUtils.IsEventValid("NAME_PLATE_UNIT_ADDED") then
            f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
            f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        local guid = api.GetGUID(arg1)
        if guid then plates[arg1] = guid; PTGuidRoster.SetUnitGuid(arg1, guid) end
    else
        plates[arg1] = nil
        PTGuidRoster.SetUnitGuid(arg1, nil)
    end
    Puppeteer.RefreshEventFilters()
end)

-- One shared text updater; the native frame draws the radial sweep itself.
local active = {}
local updater = CreateFrame("Frame")
local function updateText()
    local now = GetTime()
    for cd, update in pairs(active) do
        if cd:IsShown() then update(now) end
    end
end
local unavailable
function api.CreateCooldown(parent)
    if not api.Enabled or unavailable then return nil end
    local ok, cd = pcall(CreateFrame, "Cooldown", nil, parent)
    if not ok or not cd or not cd.SetCooldown or not cd.SetDrawBling or not cd.SetHideCountdownNumbers then unavailable = true; return nil end
    cd.nativeCooldown = true
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    cd:Hide()
    return cd
end
function api.TrackCooldown(cd, callback)
    cd:SetScript("OnShow", function()
        active[cd] = callback
        updater:SetScript("OnUpdate", updateText)
    end)
    cd:SetScript("OnHide", function()
        active[cd] = nil
        if not next(active) then updater:SetScript("OnUpdate", nil) end
    end)
end

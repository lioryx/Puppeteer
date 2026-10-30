local api = PTClientAPI
local pending, spare = {}, {}
local frame = CreateFrame("Frame", "PTRefreshQueue")
local function flush()
    local work = pending
    pending, spare = spare, work
    frame:SetScript("OnUpdate", nil)
    for identity, dirty in pairs(work) do
        work[identity] = nil
        local cache = PTUnit.Get(identity)
        if cache and cache.Unit then
            api.Count("unitRefreshes")
            local ok, err = pcall(function()
            if dirty.aura then cache:UpdateAuras(dirty.delta) end
            if dirty.auraTime and not dirty.aura and cache.RefreshAuraTimes then cache:RefreshAuraTimes() end
            local query = api.QueryUnit(cache.Unit)
            local snapshot = {unit=query, guid=api.GetGUID(query)}
            if dirty.health or dirty.aura or dirty.auraTime or dirty.heal then
                snapshot.UnitHealth, snapshot.UnitHealthMax = UnitHealth(query), UnitHealthMax(query)
            end
            if dirty.power then snapshot.UnitMana, snapshot.UnitManaMax = UnitMana(query), UnitManaMax(query) end
            api.Snapshot = snapshot
            for ui in Puppeteer.UnitFrames(identity) do
                if ui:IsShown() then
                    if dirty.aura or dirty.auraTime then
                        ui:UpdateAuras()
                        local tip = getglobal("PTAuraTooltip")
                        local owner = tip and tip:IsShown() and tip:GetOwner()
                        if owner and owner.unitFrame == ui then
                            if owner.auraData then ui:ApplyAuraTooltip(owner) else tip:Hide() end
                        end
                    end
                    if dirty.health or dirty.aura or dirty.auraTime then ui:UpdateHealth() end
                    if dirty.power then ui:UpdatePower() end
                    if dirty.heal then ui:UpdateIncomingHealing() end
                end
            end
            end)
            api.Snapshot = nil
            if not ok then geterrorhandler()(err) end
        end
    end
end
function Puppeteer.QueueRefresh(token, kind, info)
    local guid = PTUtil.HasGUIDUnits() and api.GetGUID(token)
    local key = guid or token
    if not key then return end
    local dirty = pending[key]
    if not dirty then dirty = {}; pending[key] = dirty end
    dirty[kind] = true
    if kind == "aura" and not info then
        dirty.delta = dirty.delta or {ids={}}
        dirty.delta.full = true
    end
    if info then
        local delta = dirty.delta or { ids = {} }
        dirty.delta = delta
        if info.isFullUpdate then delta.full = true end
        for _, field in ipairs({"addedAuraInstanceIDs", "updatedAuraInstanceIDs", "removedAuraInstanceIDs"}) do
            local list = info[field]
            if list then for _, id in ipairs(list) do delta.ids[id] = true end end
        end
    end
    frame:SetScript("OnUpdate", flush)
end
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 == "Puppeteer" and api.Capabilities.AuraDelta then events:RegisterEvent("UNIT_AURA_DELTA") end
    elseif api.Capabilities.AuraDelta and Puppeteer.IsRelevantUnit(arg1) then
        Puppeteer.QueueRefresh(arg1, "aura", arg2)
    end
end)

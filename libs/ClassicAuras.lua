-- Owned records remain alive while a displayed icon references them. Native
-- records are deliberately not returned to Compost's legacy aura pool.
local api, unit = PTClientAPI, PTUnit
local originalUpdate, originalDispose = unit.UpdateAuras, unit.Dispose
local slots, scratch = {}, {}
local function clear(t) for k in pairs(t) do t[k] = nil end end
local function add(map, key, value)
    if not map[key] then map[key] = {} end
    table.insert(map[key], value)
end
local function record(d, old, filter, index)
    local a = old or {}
    a.name, a.texture, a.stacks = d.name, d.icon, d.applications or 1
    a.id, a.type = d.spellId, d.dispelName or ""
    a.instanceID, a.filter, a.index = d.auraInstanceID, filter, index
    a.classic = true
    a.sourceGUID = d.sourceGUID or (d.sourceUnit and api.GetGUID(d.sourceUnit))
    if (d.duration or 0) > 0 and (d.expirationTime or 0) > GetTime() then
        a.nativeTime = a.nativeTime or {}
        a.time = a.nativeTime
        a.time.startTime, a.time.endTime = d.expirationTime - d.duration, d.expirationTime
        a.time.duration, a.time.owner = d.duration, a.sourceGUID
        a.time.ownerName = d.sourceUnit and UnitName(d.sourceUnit)
    else a.time, a.nativeTime = nil, nil end
    return a
end
local function summarize(self)
    for _, key in ipairs({"Buffs", "Debuffs", "BuffsIDSet", "DebuffsIDSet", "AfflictedDebuffTypes", "TrackedDebuffTypes"}) do
        self[key] = self[key] or {}; clear(self[key])
    end
    for _, key in ipairs({"BuffsMap", "DebuffsMap", "TypedDebuffs"}) do
        self[key] = self[key] or {}
        for _, bucket in pairs(self[key]) do clear(bucket) end
    end
    self.AuraTimesByName = self.AuraTimesByName or {}; clear(self.AuraTimesByName)
    self.HasHealingModifier, self.HasImportantDebuff = false, false
    for _, a in pairs(self.NativeAuras) do
        local harmful = a.filter == "HARMFUL"
        local list = harmful and self.Debuffs or self.Buffs
        table.insert(list, a)
        add(harmful and self.DebuffsMap or self.BuffsMap, a.name, a)
        if a.id then
            local set = harmful and self.DebuffsIDSet or self.BuffsIDSet
            set[a.id] = true
        end
        a.time = a.nativeTime and a.nativeTime.endTime > GetTime() and a.nativeTime or nil
        if not a.time and a.sourceGUID and self.AuraTimes and self.AuraTimes[a.id] then
            local candidate = self.AuraTimes[a.id][a.sourceGUID]
            if candidate and candidate.endTime > GetTime() then a.time = candidate end
        end
        if a.time then self.AuraTimesByName[a.name] = a.time end
        if (harmful and PuppeteerSettings.TrackedHealingDebuffs or PuppeteerSettings.TrackedHealingBuffs)[a.name] then
            self.HasHealingModifier = true
        end
        if harmful then
            if PuppeteerSettings.ImportantDebuffs[a.name] then self.HasImportantDebuff = true end
            if a.type ~= "" then
                self.AfflictedDebuffTypes[a.type] = 1
                add(self.TypedDebuffs, a.type, a)
                if not PuppeteerSettings.IgnoredDispellableDebuffs[a.name] then self.TrackedDebuffTypes[a.type] = 1 end
            end
        end
    end
    for _, key in ipairs({"BuffsMap", "DebuffsMap", "TypedDebuffs"}) do
        for name, bucket in pairs(self[key]) do if not next(bucket) then self[key][name] = nil end end
    end
    local function order(a,b) return (a.instanceID or a.index) < (b.instanceID or b.index) end
    table.sort(self.Buffs, order); table.sort(self.Debuffs, order)
    self.AurasPopulated = true
end
function unit:RefreshAuraTimes()
    if self.NativeAuras then summarize(self) end
end
function unit:UpdateAuras(delta)
    if not api.Capabilities.AuraSlots or not self.Unit then return originalUpdate(self) end
    local query = api.QueryUnit(self.Unit)
    local backend = api.Auras
    if delta and not delta.full and self.NativeAuras and self.NativeIncremental then
        for id in pairs(delta.ids) do
            api.Count("auraInstanceQueries")
            local d = backend.GetAuraDataByAuraInstanceID(query, id, scratch)
            if d then self.NativeAuras[id] = record(d, self.NativeAuras[id], d.isHarmful and "HARMFUL" or "HELPFUL", 1)
            else self.NativeAuras[id] = nil end
        end
    else
        api.Count("auraFullScans")
        local previous = self.NativeAuras or {}
        self.NativeAuras = {}
        self.NativeIncremental = api.Capabilities.AuraDelta and UnitIsVisible(query) and true or false
        for _, filter in ipairs({"HELPFUL", "HARMFUL"}) do
            local _, count = backend.GetAuraSlots(query, filter, nil, nil, slots)
            for i = 1, count do
                local d
                if api.Capabilities.AuraDelta then d = backend.GetAuraDataBySlot(query, slots[i])
                else
                    local name, icon, stacks, kind, duration, expires, source, _, _, spell = backend.UnitAuraBySlot(query, slots[i])
                    if name then
                        clear(scratch)
                        scratch.name, scratch.icon, scratch.applications = name, icon, stacks
                        scratch.dispelName, scratch.duration, scratch.expirationTime = kind, duration, expires
                        scratch.sourceUnit, scratch.spellId = source, spell
                        d = scratch
                    end
                end
                if d then
                    local key = d.auraInstanceID or filter..i
                    if not d.auraInstanceID then self.NativeIncremental = false end
                    self.NativeAuras[key] = record(d, previous[key], filter, i)
                end
            end
        end
    end
    summarize(self)
end
function unit:Dispose()
    if not self.NativeAuras then return originalDispose(self) end
    -- UI references own ordinary Lua records; GC safely retires them after unbind.
    for k in pairs(self) do self[k] = nil end
end
local tooltip = PTUnitFrame.ApplyAuraTooltip
function PTUnitFrame:ApplyAuraTooltip(frame)
    local a = frame.auraData
    if not a or not a.classic then return tooltip(self, frame) end
    local query = api.QueryUnit(self:GetResolvedUnit())
    local _, count = api.Auras.GetAuraSlots(query, a.filter, nil, nil, slots)
    for i = 1, count do
        local match
        if a.instanceID then
            local d = api.Auras.GetAuraDataBySlot(query, slots[i])
            match = d and d.auraInstanceID == a.instanceID
        else
            local name = api.Auras.UnitAuraBySlot(query, slots[i])
            match = i == a.index and name == a.name
        end
        if match then
            local tip = getglobal("PTAuraTooltip") or GameTooltip
            tip:SetOwner(frame, "ANCHOR_BOTTOMLEFT")
            if tip.SetUnitAura then tip:SetUnitAura(query, i, a.filter); tip:Show() end
            return
        end
    end
    (getglobal("PTAuraTooltip") or GameTooltip):Hide()
end

local renderAuras = PTUnitFrame.UpdateAuras
local sizeElements = PTUnitFrame.SizeElements
function PTUnitFrame:SizeElements()
    self.nativeAuraView = nil
    return sizeElements(self)
end
function PTUnitFrame:UpdateAuras()
    local cache = self:GetCache()
    if not cache.NativeAuras or self:IsFake() then api.Count("auraFrameUpdates"); return renderAuras(self) end
    local view = self.nativeAuraView or {}
    local index, changed = 0, self.nativeAuraView == nil
    local function compare(value)
        index = index + 1
        value = value == nil and false or value
        if view[index] ~= value then view[index] = value; changed = true end
    end
    compare(self:GetProfile()); compare(cache.HasImportantDebuff)
    for _, list in ipairs({cache.Buffs, cache.Debuffs}) do
        compare(table.getn(list))
        for _, a in ipairs(list) do
            compare(a.instanceID); compare(a.id); compare(a.name); compare(a.texture)
            compare(a.stacks); compare(a.type); compare(a.sourceGUID)
            compare(a.time and a.time.startTime); compare(a.time and a.time.duration)
        end
    end
    if table.getn(view) ~= index then changed = true end
    for i = table.getn(view), index+1, -1 do view[i] = nil end
    self.nativeAuraView = view
    if changed then api.Count("auraFrameUpdates"); return renderAuras(self) end
end

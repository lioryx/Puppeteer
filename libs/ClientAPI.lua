-- Private optional client backend. Never publish compatibility globals: other
-- addons use those globals to identify SuperWoW and select their own backends.
PTClientAPI = { Enabled = true, Capabilities = {} }
local api = PTClientAPI
local root = getfenv(0)
local mirror = root.ClassicAPI
local installed = mirror ~= nil or root.CLASSIC_API_VERSION ~= nil

local function binding(name)
    if not installed then return nil end
    local value = (mirror and mirror[name]) or root[name]
    if type(value) == "function" then return value end
end

api.UnitGUID = binding("UnitGUID")
api.UnitDistanceSquared = binding("UnitDistanceSquared")
-- The global has a different return convention when SuperWoW replaces it.
api.UnitPosition = mirror and mirror.UnitPosition
api.GetPlayerFacing = binding("GetPlayerFacing")
api.UnitInLineOfSight = binding("UnitInLineOfSight")
api.Auras = installed and ((mirror and mirror.C_UnitAuras) or root.C_UnitAuras)
api.Timer = installed and ((mirror and mirror.C_Timer) or root.C_Timer)
api.Spells = installed and ((mirror and mirror.C_Spell) or root.C_Spell)
api.Items = installed and ((mirror and mirror.C_Item) or root.C_Item)

function api.Configure(enabled, runtime)
    api.Enabled = installed and enabled ~= false
    local c = api.Capabilities
    local a = api.Auras
    local events = installed and ((mirror and mirror.C_EventUtils) or root.C_EventUtils)
    c.GUID = api.Enabled and api.UnitGUID ~= nil
    c.Distance = api.Enabled and api.UnitDistanceSquared ~= nil
    c.Position = api.Enabled and type(api.UnitPosition) == "function"
    c.Sight = api.Enabled and api.UnitInLineOfSight ~= nil
    c.Timer = api.Enabled and api.Timer and type(api.Timer.After) == "function" or false
    c.AuraSlots = api.Enabled and a and type(a.GetAuraSlots) == "function"
        and type(a.UnitAuraBySlot) == "function" or false
    if runtime and c.AuraSlots then
        local probe = {}
        local ok, _, count = pcall(a.GetAuraSlots, "player", "HELPFUL", nil, nil, probe)
        c.AuraSlots = ok and type(count) == "number" and probe.n == count
            and root.GameTooltip and type(root.GameTooltip.SetUnitAura) == "function" or false
    end
    c.AuraDelta = c.AuraSlots and type(a.GetAuraDataBySlot) == "function"
        and type(a.GetAuraDataByAuraInstanceID) == "function"
        and events and type(events.IsEventValid) == "function"
        and events.IsEventValid("UNIT_AURA_DELTA") or false
    c.Casts = c.GUID and api.Spells and type(api.Spells.UnitCastingInfo) == "function"
        and type(api.Spells.GetSpellInfo) == "function" and events and type(events.IsEventValid) == "function"
        and events.IsEventValid("UNIT_SPELLCAST_START") and events.IsEventValid("UNIT_SPELLCAST_SUCCEEDED") or false
end

function api.ResolveUnit(unit)
    local proxy = root.PTUnitProxy
    if proxy and proxy.AllCustomUnitsSet[unit] then
        return proxy.CustomUnitGUIDMap[unit]
    end
    return unit
end

function api.GetGUID(unit)
    unit = api.ResolveUnit(unit)
    if not unit then return nil end
    if string.sub(unit, 1, 2) == "0x" then return unit end
    if api.Capabilities.GUID then return api.UnitGUID(unit) end
    if root.GetUnitGUID then return root.GetUnitGUID(unit) end
    local _, guid = root.UnitExists(unit)
    return guid
end

-- A GUID is an identity, not necessarily a loaded object. Roster tokens can
-- still expose health and auras for members on another map.
function api.QueryUnit(unit)
    unit = api.ResolveUnit(unit)
    if not unit then return nil end
    local roster = root.PTGuidRoster
    local units = roster and roster.GuidUnitMap[unit]
    if units then
        for _, token in ipairs(units) do
            if not (root.PTUnitProxy and root.PTUnitProxy.AllCustomUnitsSet[token])
                and api.GetGUID(token) == unit then return token end
        end
    end
    return unit
end

function api.GetPosition(unit)
    unit = api.ResolveUnit(unit)
    if not unit or not api.Capabilities.Position then return nil end
    local y, x, z, map = api.UnitPosition(unit)
    return x, y, z, map
end

-- Schedule relative to the current time, not the previous deadline. A stalled
-- frame must not produce a burst of catch-up scans. One handle per subsystem.
local scheduledTasks, scheduledFor = {}, nil
local wake
local function schedule(deadline)
    if scheduledFor and scheduledFor <= deadline then return end
    scheduledFor = deadline
    api.Timer.After(math.max(deadline - GetTime(), 0.01), wake)
end
wake = function()
    local now = GetTime()
    if scheduledFor and now + 0.001 < scheduledFor then return end
    scheduledFor = nil
    local nextDeadline
    for handle in pairs(scheduledTasks) do
        if handle.cancelled then scheduledTasks[handle] = nil
        else
            if now >= handle.deadline then
                local ok, nextDelay = pcall(handle.callback)
                if not ok then
                    local report = root.geterrorhandler and root.geterrorhandler()
                    if report then pcall(report, nextDelay) end
                    nextDelay = handle.delay
                end
                handle.deadline = now + math.max(tonumber(nextDelay) or handle.delay, 0.01)
            end
            if not handle.cancelled and (not nextDeadline or handle.deadline < nextDeadline) then nextDeadline = handle.deadline end
        end
    end
    if nextDeadline then schedule(nextDeadline) end
end
function api.NewScheduler(callback, delay)
    local handle = {callback=callback, delay=delay, deadline=GetTime()+delay}
    function handle:Cancel() self.cancelled = true; scheduledTasks[self] = nil end
    scheduledTasks[handle] = true
    schedule(handle.deadline)
    return handle
end

api.Configure(true)

-- Opt-in counters complement client CPU profiling without affecting saved data.
function api.Count(name, amount)
    local metrics = api.Metrics
    if metrics then metrics[name] = (metrics[name] or 0) + (amount or 1) end
end

local metadata = {}
function api.SpellInfo(id)
    if root.SpellInfo then return root.SpellInfo(id) end
    local info = metadata[id]
    if not info and api.Spells and api.Spells.GetSpellInfo then
        info = api.Spells.GetSpellInfo(id)
        if info then metadata[id] = {name=info.name, rank=info.rank, iconID=info.iconID} end
    end
    if info then return info.name, info.rank, info.iconID end
end

function api.HasEventToken(guid)
    local roster = root.PTGuidRoster
    for _, token in ipairs(roster and roster.GuidUnitMap[guid] or {}) do
        if not root.PTUnitProxy.AllCustomUnitsSet[token] and api.GetGUID(token) == guid then return true end
    end
    return false
end

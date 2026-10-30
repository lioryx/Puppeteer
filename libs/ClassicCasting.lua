local api = PTClientAPI
local casts, sent, bridge, registered = {}, {}, nil, {}
local legacyEvents = {"UNIT_CASTEVENT", "SPELLCAST_START", "SPELLCAST_STOP", "SPELLCAST_INTERRUPTED", "SPELLCAST_FAILED", "SPELLCAST_DELAYED"}
local function compatible(lib)
    local contract = lib and lib.PuppeteerClassicContract
    if not contract or not lib.SpellCastInfo or not lib.Spells then return false end
    for _, name in ipairs({"ProcessSpellCast", "SPELLCAST_START", "SPELLCAST_STOP", "SPELLCAST_INTERRUPTED", "SPELLCAST_FAILED", "SPELLCAST_DELAYED"}) do
        if type(contract[name]) ~= "function" or lib[name] ~= contract[name] then return false end
    end
    return true
end
local function checkBridge()
    local lib = AceLibrary("HealComm-1.0")
    if api.Enabled and bridge == lib and compatible(lib) then return end
    api.DirectCastReady = false
    if bridge and bridge.RegisterEvent then
        for name in pairs(registered) do bridge:RegisterEvent(name) end
    end
    bridge, registered = nil, {}
    local events = C_EventUtils and C_EventUtils.IsEventValid
    if not api.Enabled or not api.Capabilities.GUID or not api.Spells or not api.Spells.UnitCastingInfo
        or PTUtil.IsSuperWowPresent() or not compatible(lib) or not events
        or not events("UNIT_SPELLCAST_SENT") or not events("UNIT_SPELLCAST_START")
        or not events("UNIT_SPELLCAST_SUCCEEDED") or not events("UNIT_SPELLCAST_STOP") then return end
    bridge = lib
    for _, name in ipairs(legacyEvents) do
        if lib:IsEventRegistered(name) then registered[name] = true; lib:UnregisterEvent(name) end
    end
    api.DirectCastReady = api.Spells and type(api.Spells.CastAtUnit) == "function" or false
end
local function uniqueTarget(name)
    if not name or name == "" then return nil end
    local result
    for guid in pairs(PTGuidRoster.GuidUnitMap) do
        if UnitName(api.QueryUnit(guid)) == name then
            if result and result ~= guid then return nil end
            result = guid
        end
    end
    return result
end
local function dispatch(c, action)
    if not c.target then return end
    local old1, old2, old3, old4, old5 = arg1, arg2, arg3, arg4, arg5
    arg1, arg2, arg3, arg4, arg5 = c.caster, c.target, action, c.spell, c.duration
    local ok, err = pcall(function()
        PTHealPredictCasts:GetScript("OnEvent")()
        PTCastIcons:GetScript("OnEvent")()
    end)
    arg1, arg2, arg3, arg4, arg5 = old1, old2, old3, old4, old5
    if not ok then geterrorhandler()(err) end
end
local function prepare(c)
    if not bridge or not c.target then return false end
    local name, rank = api.SpellInfo(c.spell)
    if not name then return false end
    for k in pairs(bridge.SpellCastInfo) do bridge.SpellCastInfo[k] = nil end
    bridge.CurrentSpellName = name
    local _, _, number = string.find(rank or "", "(%d+)")
    bridge.CurrentSpellRank = tonumber(number) or 1
    bridge:ProcessSpellCast(api.QueryUnit(c.target))
    return true
end
local events = CreateFrame("Frame", "PTClassicCastEvents")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" or event == "PLAYER_LOGIN" then
        if not api.Enabled or not api.Spells or not api.Spells.UnitCastingInfo then return end
        checkBridge()
        local valid = C_EventUtils and C_EventUtils.IsEventValid
        for _, e in ipairs({"UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_DELAYED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE", "UNIT_SPELLCAST_CHANNEL_STOP"}) do
            if valid and valid(e) then events:RegisterEvent(e) end
        end
        return
    end
    if not api.Enabled or not PTHealPredict or PTUtil.IsSuperWowPresent() then return end
    checkBridge()
    local token, id, spell = arg1, arg2, arg3
    local caster = api.GetGUID(token)
    if not caster then return end
    local player = caster == api.GetGUID("player")
    if event == "UNIT_SPELLCAST_SENT" then
        sent = {}
        if arg2 and arg2 ~= "" then sent[arg3] = api.GetGUID(arg2) or api.PendingClick
        elseif api.PendingClick then sent[arg3] = api.PendingClick end
        return
    end
    local c = casts[caster]
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        if c and c.id == id then return end
        local channel = event == "UNIT_SPELLCAST_CHANNEL_START"
        local getter = channel and api.Spells.UnitChannelInfo or api.Spells.UnitCastingInfo
        if not getter then return end
        local _, _, _, startTime, endTime = getter(token)
        local target = sent[id] or (UnitSpellTargetName and uniqueTarget(UnitSpellTargetName(token)))
        if not startTime or not endTime or endTime <= startTime then return end
        if c and c.spell == spell and c.starting == startTime and c.channel == channel and c.target == target then
            c.id = id -- A real token can start covering a previously polled slot.
            return
        end
        if c then
            dispatch(c, "FAIL")
            if player and c.bridge and c.bridge == bridge and not c.broadcastDone then bridge:SPELLCAST_INTERRUPTED() end
        end
        c = {caster=caster, id=id, spell=spell, target=target, duration=endTime-startTime, starting=startTime, ending=endTime, channel=channel}
        casts[caster] = c
        dispatch(c, "START")
        if PTHealPredict.UpdateCastTiming then PTHealPredict.UpdateCastTiming(caster, startTime, endTime) end
        if player and prepare(c) then
            c.bridge = bridge
            bridge:SPELLCAST_START(api.SpellInfo(spell), c.duration)
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if c and c.id == id then
            if not c.channel then dispatch(c, "CAST"); casts[caster] = nil end
            if player and c.bridge and c.bridge == bridge and not c.broadcastDone then bridge:SPELLCAST_STOP(); c.broadcastDone = true end
        elseif player and sent[id] then
            local instant = {target=sent[id], spell=spell}
            if prepare(instant) then bridge:SPELLCAST_STOP() end
        end
        sent[id] = nil
    elseif c and c.id == id and (event == "UNIT_SPELLCAST_DELAYED" or event == "UNIT_SPELLCAST_CHANNEL_UPDATE") then
        local getter = c.channel and api.Spells.UnitChannelInfo or api.Spells.UnitCastingInfo
        local _, _, _, starting, ending = getter(token)
        if starting and ending and ending > starting then
            if player and c.bridge and c.bridge == bridge and ending > c.ending and not c.broadcastDone then
                local old = arg1; arg1 = ending-c.ending
                local ok, err = pcall(bridge.SPELLCAST_DELAYED, bridge)
                arg1 = old
                if not ok then geterrorhandler()(err) end
            end
            c.starting, c.ending, c.duration = starting, ending, ending-starting
            if PTHealPredict.UpdateCastTiming then PTHealPredict.UpdateCastTiming(caster, starting, ending) end
        end
    elseif c and c.id == id then
        dispatch(c, "FAIL")
        if player and c.bridge and c.bridge == bridge and not c.broadcastDone then bridge:SPELLCAST_INTERRUPTED() end
        casts[caster], sent[id] = nil, nil
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_STOP" then
        sent[id] = nil
    end
end)
-- GUID-only slots do not receive token-filtered native cast events. Poll only
-- those slots, sharing the existing 0.25 second custom-unit maintenance pass.
function api.PollCast(guid)
    if not api.Enabled or PTUtil.IsSuperWowPresent() or not api.Spells or not api.Spells.UnitCastingInfo then return end
    local token = api.QueryUnit(guid)
    local name, _, _, starting, ending, _, id, _, spell = api.Spells.UnitCastingInfo(token)
    local channel = false
    if not name and api.Spells.UnitChannelInfo then
        name, _, _, starting, ending, _, _, spell = api.Spells.UnitChannelInfo(token)
        channel = name ~= nil
        id = nil
    end
    local c = casts[guid]
    if not name or not starting or not ending or not spell then
        if c then dispatch(c, "FAIL"); casts[guid] = nil end
        return
    end
    id = id or (guid..":"..spell..":"..starting)
    local action = channel and "UNIT_SPELLCAST_CHANNEL_START" or "UNIT_SPELLCAST_START"
    if c and c.spell == spell and c.starting == starting then
        id = c.id
        if c.ending == ending then return end
        action = channel and "UNIT_SPELLCAST_CHANNEL_UPDATE" or "UNIT_SPELLCAST_DELAYED"
    end
    local oldEvent, a, b, d = event, arg1, arg2, arg3
    event, arg1, arg2, arg3 = action, token, id, spell
    local ok, err = pcall(events:GetScript("OnEvent"))
    event, arg1, arg2, arg3 = oldEvent, a, b, d
    if not ok then geterrorhandler()(err) end
end
function api.ExpireCasts()
    for caster, c in pairs(casts) do
        if GetTime() * 1000 > c.ending + 500 then
            dispatch(c, "FAIL")
            if c.bridge and c.bridge == bridge and not c.broadcastDone then bridge:SPELLCAST_INTERRUPTED() end
            casts[caster], sent[c.id] = nil, nil
        end
    end
end
function api.CastAtUnit(spell, unit)
    checkBridge()
    if not api.DirectCastReady or not api.Spells or not api.Spells.CastAtUnit then return false end
    api.PendingClick = api.GetGUID(unit)
    local ok, err = pcall(api.Spells.CastAtUnit, spell, api.QueryUnit(unit), false)
    api.PendingClick = nil
    if not ok then geterrorhandler()(err) end
    return true -- handled, including rejection; never retry through another backend
end

function api.CanDirectCast()
    checkBridge()
    return api.DirectCastReady
end

from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]
class BackendTests(unittest.TestCase):
 def lua(self):
  l=LuaRuntime(unpack_returned_tuples=True)
  l.execute('''
  now=10; function GetTime() return now end
  function UnitHealth() return 50 end
  function UnitHealthMax() return 100 end
  function UnitIsVisible() return true end
  function UnitName(u) return u end
  CLASSIC_API_VERSION=11713
  ClassicAPI={UnitGUID=function(u) if u=='party1' or u=='target' then return '0x1' else return u end end}
  C_EventUtils={IsEventValid=function() return true end}
  function CreateFrame(_,name)
   local f={scripts={},events={}}
   function f:SetScript(k,v) self.scripts[k]=v end
   function f:GetScript(k) return self.scripts[k] end
   function f:RegisterEvent(e) self.events[e]=true end
   function f:UnregisterEvent(e) self.events[e]=nil end
   if name then _G[name]=f end
   return f
  end
  function getglobal(k) return _G[k] end
  PTUnitFrame={ApplyAuraTooltip=function() end}
  PTUnit={UpdateAuras=function(self) self.legacy=true end,Dispose=function() end}
  PuppeteerSettings={TrackedHealingBuffs={},TrackedHealingDebuffs={},ImportantDebuffs={},IgnoredDispellableDebuffs={}}
  native={ [10]={name='Renew',icon='a',applications=1,spellId=139,auraInstanceID=10,isHarmful=false,duration=15,expirationTime=25,sourceGUID='0xP'},
           [20]={name='Poison',icon='b',applications=1,spellId=200,auraInstanceID=20,isHarmful=true,dispelName='Poison'}}
  reads=0; scans=0
  C_UnitAuras={
   GetAuraSlots=function(u,filter,m,c,out) scans=scans+1; for k in pairs(out) do out[k]=nil end; local n=0; for id,d in pairs(native) do if (filter=='HARMFUL')==d.isHarmful then n=n+1;out[n]=id end end; return nil,n end,
   GetAuraDataBySlot=function(u,id) return native[id] end,
   UnitAuraBySlot=function() end,
   GetAuraDataByAuraInstanceID=function(u,id,buf) reads=reads+1;local d=native[id];if not d then return nil end; for k in pairs(buf) do buf[k]=nil end;for k,v in pairs(d) do buf[k]=v end;return buf end}
  ''')
  l.execute((ROOT/'libs/ClientAPI.lua').read_text(encoding='utf-8'))
  return l
 def test_incremental_records_and_removal(self):
  l=self.lua();l.execute((ROOT/'libs/ClassicAuras.lua').read_text(encoding='utf-8'))
  l.execute('''c=setmetatable({Unit='party1'},{__index=PTUnit}); c:UpdateAuras(); assert(scans==2)
  original=c.Buffs[1];native[10].applications=3;c:UpdateAuras({ids={[10]=true}})
  assert(scans==2 and reads==1 and c.Buffs[1]==original and original.stacks==3)
  native[20]=nil;c:UpdateAuras({ids={[20]=true}});assert(not c.AfflictedDebuffTypes.Poison and c.DebuffsIDSet[200]==nil and original.name=='Renew')
  ''')
 def test_off_fallback(self):
  l=self.lua();l.execute((ROOT/'libs/ClassicAuras.lua').read_text(encoding='utf-8'))
  l.execute("PTClientAPI.Configure(false);c=setmetatable({Unit='party1'},{__index=PTUnit});c:UpdateAuras();assert(c.legacy and scans==0)")
 def test_delta_payload_is_copied_and_aliases_merged(self):
  l=self.lua();l.execute('''PTUtil={HasGUIDUnits=function() return true end}; updates=0;uiUpdates=0
  cache={Unit='0x1',UpdateAuras=function(self,d) updates=updates+1;assert(d.ids[10] and d.ids[20]) end}
  PTUnit.Get=function() return cache end
  ui={IsShown=function() return true end,UpdateAuras=function() uiUpdates=uiUpdates+1 end,UpdateHealth=function() end}
  Puppeteer={IsRelevantUnit=function() return true end,UnitFrames=function() local done=false;return function() if not done then done=true;return ui end end end}
  ''');l.execute((ROOT/'core/RefreshQueue.lua').read_text(encoding='utf-8'))
  l.execute('''payload={addedAuraInstanceIDs={10}};Puppeteer.QueueRefresh('party1','aura',payload)
  payload.addedAuraInstanceIDs[1]=20;Puppeteer.QueueRefresh('target','aura',payload)
  payload.addedAuraInstanceIDs[1]=999;PTRefreshQueue:GetScript('OnUpdate')()
  assert(updates==1 and uiUpdates==1)
  ''')
 def test_guid_proxy_uses_roster_when_object_is_unloaded(self):
  l=self.lua();l.execute("""
  function AceLibrary() return {} end
  function UnitExists(u) return u=='party1' and 1 or nil end
  function UnitClass() return 'Priest','PRIEST' end
  PTGuidRoster={GuidUnitMap={['0x1']={'focus1','party1'}}}
  """)
  l.execute((ROOT/'libs/UnitProxy.lua').read_text(encoding='utf-8'))
  l.execute("""
  PTUnitProxy.CustomUnitGUIDMap.focus1='0x1'
  local exists,guid=PTUnitProxy.UnitExists('focus1')
  assert(exists==1 and guid=='0x1')
  assert(PTClientAPI.QueryUnit('0x1')=='party1')
  local name,class=PTUnitProxy.UnitClass('focus1')
  assert(name=='Priest' and class=='PRIEST')
  assert(PTUnitProxy.UnitExists('focus2')==nil)
  assert(PTUnitProxy.UnitIsCorpse('focus1')==false)
  """)
 def test_full_update_and_visibility_rebuild(self):
  l=self.lua();l.execute((ROOT/'libs/ClassicAuras.lua').read_text(encoding='utf-8'))
  l.execute("""
  c=setmetatable({Unit='party1'},{__index=PTUnit});c:UpdateAuras()
  native[10]=nil;c:UpdateAuras({full=true,ids={}})
  assert(scans==4 and not c.BuffsMap.Renew and c.DebuffsMap.Poison)
  function UnitIsVisible() return nil end
  native[20].auraInstanceID=nil;c:UpdateAuras()
  assert(not c.NativeIncremental)
  """)
 def test_scheduler_no_catchup_and_error_recovery(self):
  l=self.lua();l.execute("""
  queue={};errors=0;calls=0
  PTClientAPI.Timer={After=function(d,f) table.insert(queue,f) end}
  function geterrorhandler() return function() errors=errors+1 end end
  h=PTClientAPI.NewScheduler(function() calls=calls+1;error('expected') end,.25)
  now=50;table.remove(queue,1)()
  assert(calls==1 and errors==1 and h.deadline==50.25)
  h:Cancel();now=60;table.remove(queue,1)();assert(calls==1 and #queue==0)
  """)
 def cast_lua(self):
  l=self.lua()
  l.execute("""
  PTUtil={IsSuperWowPresent=function() return false end}
  PTGuidRoster={GuidUnitMap={['0x1']={'party1'}}}
  PTHealPredict={}
  counts={start=0,stop=0,cancel=0,predict=0,icons=0}
  lib={SpellCastInfo={},Spells={},events={SPELLCAST_START=true,CHAT_MSG_ADDON=true},PuppeteerClassicContract={}}
  function lib:IsEventRegistered(e) return self.events[e] end
  function lib:RegisterEvent(e) self.events[e]=true end
  function lib:UnregisterEvent(e) self.events[e]=nil end
  function lib:ProcessSpellCast(u) self.target=u end
  function lib:SPELLCAST_START() counts.start=counts.start+1 end
  function lib:SPELLCAST_STOP() counts.stop=counts.stop+1 end
  function lib:SPELLCAST_INTERRUPTED() counts.cancel=counts.cancel+1 end
  function lib:SPELLCAST_FAILED() end
  function lib:SPELLCAST_DELAYED() end
  for _,n in ipairs({'ProcessSpellCast','SPELLCAST_START','SPELLCAST_STOP','SPELLCAST_INTERRUPTED','SPELLCAST_FAILED','SPELLCAST_DELAYED'}) do lib.PuppeteerClassicContract[n]=lib[n] end
  function AceLibrary() return lib end
  function geterrorhandler() return error end
  PTHealPredictCasts=CreateFrame('Frame');PTHealPredictCasts:SetScript('OnEvent',function() counts.predict=counts.predict+1 end)
  PTCastIcons=CreateFrame('Frame');PTCastIcons:SetScript('OnEvent',function() counts.icons=counts.icons+1 end)
  PTClientAPI.Spells={UnitCastingInfo=function() return 'Heal','','',10000,12000 end,
   UnitChannelInfo=function() return 'Channel','','',10000,12000 end,
   CastAtUnit=function() return false end,GetSpellInfo=function() return {name='Heal',rank='Rank 1'} end}
  function fire(e,a,b,c,d) event=e;arg1=a;arg2=b;arg3=c;arg4=d;PTClassicCastEvents:GetScript('OnEvent')() end
  """)
  l.execute((ROOT/'libs/ClassicCasting.lua').read_text(encoding='utf-8'))
  l.execute("fire('PLAYER_LOGIN');assert(PTClientAPI.DirectCastReady);assert(lib.events.CHAT_MSG_ADDON and not lib.events.SPELLCAST_START)")
  return l
 def test_cast_aliases_and_success_once(self):
  l=self.cast_lua();l.execute("""
  fire('UNIT_SPELLCAST_SENT','player','party1','cast1',139)
  fire('UNIT_SPELLCAST_START','player','cast1',139)
  fire('UNIT_SPELLCAST_START','player','cast1',139)
  assert(counts.start==1 and counts.predict==1)
  fire('UNIT_SPELLCAST_SUCCEEDED','player','cast1',139)
  fire('UNIT_SPELLCAST_SUCCEEDED','player','cast1',139)
  fire('UNIT_SPELLCAST_STOP','player','cast1',139)
  assert(counts.stop==1 and counts.cancel==0 and counts.predict==2)
  assert(arg1=='player' and arg2=='cast1' and arg3==139)
  """)
 def test_old_failure_does_not_cancel_new_cast(self):
  l=self.cast_lua();l.execute("""
  fire('UNIT_SPELLCAST_SENT','player','party1','new',139)
  fire('UNIT_SPELLCAST_START','player','new',139)
  fire('UNIT_SPELLCAST_FAILED','player','old',139)
  assert(counts.cancel==0)
  fire('UNIT_SPELLCAST_INTERRUPTED','player','new',139)
  fire('UNIT_SPELLCAST_STOP','player','new',139)
  assert(counts.cancel==1 and counts.stop==0)
  """)
 def test_incompatible_library_disables_direct_cast(self):
  l=self.cast_lua();l.execute("""
  lib.SPELLCAST_START=function() error('must not call unknown implementation') end
  assert(not PTClientAPI.CanDirectCast())
  assert(not PTClientAPI.CastAtUnit('Heal','party1'))
  assert(lib.events.CHAT_MSG_ADDON)
  """)
 def test_rejected_direct_cast_is_handled_not_retried(self):
  l=self.cast_lua();l.execute("assert(PTClientAPI.CastAtUnit('Heal','party1')==true)")
 def test_channel_lives_until_stop(self):
  l=self.cast_lua();l.execute("""
  fire('UNIT_SPELLCAST_SENT','player','party1','channel',139)
  fire('UNIT_SPELLCAST_CHANNEL_START','player','channel',139)
  fire('UNIT_SPELLCAST_SUCCEEDED','player','channel',139)
  assert(counts.predict==1)
  fire('UNIT_SPELLCAST_CHANNEL_STOP','player','channel',139)
  assert(counts.predict==2 and counts.cancel==0)
  """)
 def test_delayed_and_channel_update_keep_absolute_times(self):
  l=self.cast_lua();l.execute("""
  PTHealPredict.UpdateCastTiming=function(c,s,e) counts.ending=e end
  fire('UNIT_SPELLCAST_SENT','player','party1','cast',139)
  fire('UNIT_SPELLCAST_START','player','cast',139)
  PTClientAPI.Spells.UnitCastingInfo=function() return 'Heal','','',10000,14000 end
  fire('UNIT_SPELLCAST_DELAYED','player','cast',139)
  assert(counts.ending==14000 and counts.start==1)
  fire('UNIT_SPELLCAST_SENT','player','party1','channel',139)
  fire('UNIT_SPELLCAST_CHANNEL_START','player','channel',139)
  PTClientAPI.Spells.UnitChannelInfo=function() return 'Channel','','',10000,11000 end
  fire('UNIT_SPELLCAST_CHANNEL_UPDATE','player','channel',139)
  assert(counts.ending==11000)
  """)
 def test_custom_cast_poll_does_not_guess_success(self):
  l=self.cast_lua();l.execute("""
  function UnitSpellTargetName() return 'party1' end
  PTClientAPI.Spells.UnitCastingInfo=function() return 'Heal','','',10000,12000,false,'remote',false,139 end
  PTClientAPI.PollCast('0x2');PTClientAPI.PollCast('0x2')
  assert(counts.predict==1 and counts.start==0)
  PTClientAPI.Spells.UnitCastingInfo=function() end
  PTClientAPI.Spells.UnitChannelInfo=function() end
  PTClientAPI.PollCast('0x2')
  assert(counts.predict==2 and counts.stop==0)
  """)
 def test_full_refresh_wins_over_delta(self):
  l=self.lua();l.execute("""
  PTUtil={HasGUIDUnits=function() return true end}
  function geterrorhandler() return error end
  PTUnit.Get=function() return {Unit='party1',UpdateAuras=function(self,d) assert(d.full);seen=true end} end
  Puppeteer={UnitFrames=function() return function() end end}
  """);l.execute((ROOT/'core/RefreshQueue.lua').read_text(encoding='utf-8'))
  l.execute("""
  Puppeteer.QueueRefresh('party1','aura')
  Puppeteer.QueueRefresh('target','aura',{updatedAuraInstanceIDs={10}})
  PTRefreshQueue:GetScript('OnUpdate')();assert(seen)
  """)
 def test_aura_time_candidate_does_not_scan_or_replace_native_time(self):
  l=self.lua();l.execute((ROOT/'libs/ClassicAuras.lua').read_text(encoding='utf-8'))
  l.execute("""
  c=setmetatable({Unit='party1'},{__index=PTUnit});c:UpdateAuras()
  c.AuraTimes={[139]={['0xP']={startTime=1,endTime=80,duration=79}}}
  c:RefreshAuraTimes();assert(scans==2 and reads==0 and c.Buffs[1].time.endTime==25)
  native[10].duration=0;c:UpdateAuras({ids={[10]=true}})
  assert(c.Buffs[1].time.endTime==80 and scans==2)
  now=90;c:RefreshAuraTimes();assert(c.Buffs[1].time==nil and scans==2)
  """)
 def test_missing_cast_events_leave_legacy_hooks_enabled(self):
  l=self.cast_lua();l.execute("""
  lib.SPELLCAST_START=function() end
  assert(not PTClientAPI.CanDirectCast() and lib.events.SPELLCAST_START)
  lib.PuppeteerClassicContract.SPELLCAST_START=lib.SPELLCAST_START
  C_EventUtils.IsEventValid=function() return false end
  assert(not PTClientAPI.CanDirectCast() and lib.events.SPELLCAST_START)
  """)
 def test_healcomm_contribution_is_counted_once_per_caster(self):
  l=self.lua();l.execute("""
  PTGuidRoster={GuidUnitMap={['0x1']={'party1'}}}
  PTHealPredict={GetIncomingHealing=function() return 100,100 end,GetResurrectionCount=function() return 0 end,
   IncomingHeals={['0x1']={['0xP']={heal=100}}},ResurrectionTargets={},GetExpectedHeal=function() return 0 end}
  PTUnit.Get=function() return {} end
  comm={Heals={party1={['0xP']={ctime=20,amount=100},other={ctime=20,amount=70}}},
   GrpHeals={other={ctime=20,amount=70,targets={'party1'}}}}
  function AceLibrary() return comm end
  """);l.execute((ROOT/'libs/ClassicHealing.lua').read_text(encoding='utf-8'))
  l.execute("local total,direct=PTHealPredict.GetIncomingHealing('0x1');assert(total==170 and direct==170)")
 def test_icon_fields_are_not_rewritten_when_unchanged(self):
  l=self.lua();l.execute("""
  util={HasAuraTimers=function() return false end};selfBorderedBuffs={};debuffTypeBorderColors={}
  PTUnitFrame.IsEnemy=function() return false end
  writes=0
  function widget()
   return setmetatable({}, {__index=function(t,k) return function(self,v) writes=writes+1;if k=='SetText' then self.text=v end end end})
  end
  component={frame=widget(),icon=widget(),button={SetAllPoints=function() writes=writes+1 end},stackText=widget(),border=widget()}
  data={name='Renew',stacks=3,texture='a',type=''}
  """)
  source=(ROOT/'PTUnitFrame.lua').read_text(encoding='utf-8')
  source=source[source.index('function PTUnitFrame:CreateAura('):source.index('function PTUnitFrame:Initialize()')]
  l.execute(source)
  l.execute("""
  PTUnitFrame:CreateAura(component,data,0,0,'Buff',12)
  local before=writes
  PTUnitFrame:CreateAura(component,data,0,0,'Buff',12)
  assert(writes==before)
  data.stacks=1;PTUnitFrame:CreateAura(component,data,0,0,'Buff',12)
  assert(writes==before+1 and component.stackText.text=='')
  """)
 def test_slot_fallback_without_incremental_interface(self):
  l=self.lua();l.execute("""
  C_UnitAuras.GetAuraDataByAuraInstanceID=nil;PTClientAPI.Configure(true)
  C_UnitAuras.UnitAuraBySlot=function(u,id)
   local d=native[id];return d.name,d.icon,d.applications,d.dispelName,d.duration,d.expirationTime,nil,nil,nil,d.spellId
  end
  """);l.execute((ROOT/'libs/ClassicAuras.lua').read_text(encoding='utf-8'))
  l.execute("""
  c=setmetatable({Unit='party1'},{__index=PTUnit});c:UpdateAuras()
  assert(c.BuffsIDSet[139] and c.DebuffsIDSet[200] and not c.NativeIncremental)
  local before=c.Buffs[1];native[10].applications=2;c:UpdateAuras()
  assert(c.Buffs[1]==before and before.stacks==2 and reads==0)
  """)
 def test_no_classicapi_keeps_vanilla_path(self):
  l=self.lua();l.execute("ClassicAPI=nil;CLASSIC_API_VERSION=nil;C_UnitAuras=nil;function UnitExists() return 1 end")
  l.execute((ROOT/'libs/ClientAPI.lua').read_text(encoding='utf-8'))
  l.execute((ROOT/'libs/UnitProxy.lua').read_text(encoding='utf-8'))
  l.execute((ROOT/'libs/ClassicAuras.lua').read_text(encoding='utf-8'))
  l.execute("""
  assert(not PTClientAPI.Enabled and not PTClientAPI.Capabilities.GUID and not PTUnitProxy and not SpellInfo)
  c=setmetatable({Unit='party1'},{__index=PTUnit});c:UpdateAuras();assert(c.legacy and scans==0)
  """)
 def test_expiry_removes_missing_stop_without_success_broadcast(self):
  l=self.cast_lua();l.execute("""
  fire('UNIT_SPELLCAST_SENT','player','party1','lost',139)
  fire('UNIT_SPELLCAST_START','player','lost',139)
  now=30;PTClientAPI.ExpireCasts();PTClientAPI.ExpireCasts()
  assert(counts.predict==2 and counts.cancel==1 and counts.stop==0)
  """)
if __name__=='__main__': unittest.main()


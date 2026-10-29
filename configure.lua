-- Verify the selected factory's bindings and initialize its dedicated ghost database.
-- This does not start machines or move real items/fluids.
local variant=...
assert(variant=='platinum' or variant=='monazite','Choose platinum or monazite')
local component=require('component')
local cfg=assert(loadfile('/oc-factories/'..variant..'/config.lua'))()
local function check(address,label)
 assert(type(address)=='string' and not address:find('_ADDRESS',1,true),'Fill '..label)
 assert(component.type(address),'Component unavailable: '..label..' '..address)
end
check(cfg.me,'me');check(cfg.db,'db')
local needed={me={'getItemInNetwork','getFluidInNetwork','getStoredPower'},
 machine={'getWorkMaxProgress','isWorkAllowed','setWorkAllowed'},
 hub={'requestItems','sendItems','getStackInSlot','dropIntoSlot','requestFluids','sendFluids'}}
local function methods(address,names,label)
 local available=component.methods(address)
 for _,name in ipairs(names)do assert(available[name]~=nil,'Missing '..label..'.'..name)end
end
methods(cfg.me,needed.me,'ME query interface')
for id,m in pairs(cfg.machines)do
 check(m.address,id);check(m.hub,id..'.hub')
 methods(m.address,needed.machine,id);methods(m.hub,needed.hub,id..'.hub')
 if m.circuitAddress then
  check(m.circuitAddress,id..'.circuitAddress')
  methods(m.circuitAddress,{'setCircuitConfiguration'},id..'.circuitAddress')
 end
end
methods(cfg.db,{'get','set'},'database')
for _,entry in ipairs(cfg.entries or {})do
 assert(entry.id,'Missing ghost item descriptor at '..entry.slot)
 assert(component.invoke(cfg.db,'set',entry.slot,entry.id,entry.meta,entry.tag or ''))
end
print('Bindings verified. Ghost descriptors initialized: '..#(cfg.entries or {}))
print('Confirm hatches, IO sides, circuits and native output connections before launch.')

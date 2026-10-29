-- Rare Earth Controller v6. Owned factory only; persistent exact-batch transfers.
local C=component;local I=C.invoke;local disk=assert(factoryDisk,'Use launch.lua');local root=assert(factoryRoot,'Use launch.lua')
local function read(p)local h,e=I(disk,'open',root..p,'r');if not h then return nil,e end;local s='';while true do local b=I(disk,'read',h,8192);if not b then break end;s=s..b end;I(disk,'close',h);return s end
local function encode(v)
 local t=type(v);if t=='string'then return string.format('%q',v)elseif t=='number'or t=='boolean'then return tostring(v)elseif t=='nil'then return'nil'end
 local a={'{'};for k,x in pairs(v)do a[#a+1]='['..encode(k)..']='..encode(x)..','end;a[#a+1]='}';return table.concat(a)
end
local function write(p,s)local h=assert(I(disk,'open',root..p,'w'));assert(I(disk,'write',h,s));I(disk,'close',h)end
local function loadfile(p)local s=read(p);if not s then return nil end;return assert(load(s,'='..p,'t',_G))()end
local cfg=assert(loadfile('config.lua'));local state=loadfile('state.lua')or loadfile('state.new')or loadfile('state.old')or{jobs={},done={},counts={},boost={cerium=false,samarium=false},seq=0,started=computer.uptime()}
local function persist()write('state.new','return '..encode(state));if I(disk,'exists',root..'state.lua')then I(disk,'remove',root..'state.old');I(disk,'rename',root..'state.lua',root..'state.old')end;assert(I(disk,'rename',root..'state.new',root..'state.lua'))end
local function log(kind,v) if I(disk,'exists',root..'events.log')and I(disk,'size',root..'events.log')>262144 then I(disk,'remove',root..'events.previous.log');I(disk,'rename',root..'events.log',root..'events.previous.log')end;local h=assert(I(disk,'open',root..'events.log','a'));I(disk,'write',h,encode({time=computer.uptime(),event=kind,data=v})..'\n');I(disk,'close',h)end
local recipes={};for _,r in ipairs(cfg.recipes)do recipes[r.id]=r end
local function H(m,k,...)
 if k=='count'then local v=I(m.hub,'getStackInInternalSlot',...);return type(v)=='table'and(v.size or 0)or 0 end
 return I(m.hub,k,...)
end
local function G(m,k,...)return I(m.address,k,...)end
local function amount(v)return type(v)=='table'and(v.size or v.amount or 0)or 0 end
local cache={}
local function itemstock(x)
 local key=x.id..':'..x.meta..':'..(x.tag or'');if cache[key]~=nil then return cache[key]end
 if x.id=='gregtech:gt.metaitem.01'and x.meta==2817 then
  -- The subnet's partitioned salt chest is private to this factory. Query the
  -- same network the Hub actually extracts from, including the main storage view.
  local values,e=I(cfg.machines.X1.hub,'getItemsInNetwork',{name=x.id,damage=x.meta})
  assert(not e,'Subnet salt query failed: '..tostring(e));local n=0
  for _,v in ipairs(values or{})do if v.name==x.id and v.damage==x.meta then n=n+amount(v)end end
  cache[key]=n;return n
 end
 local v,e=I(cfg.me,'getItemInNetwork',x.id,x.meta,x.tag);assert(not e,'Main item query failed: '..tostring(e));local n=amount(v);cache[key]=n;return n
end
local function fluidstock(x)local key='f:'..x.name;if cache[key]~=nil then return cache[key]end;local v,e=I(cfg.me,'getFluidInNetwork',x.name);assert(not e,'Main fluid query failed: '..tostring(e));local n=amount(v);cache[key]=n;return n end
local function clearhub(m,full)
 local slots=full and 32 or 9
 for s=1,slots do local n=H(m,'count',s);if n>0 then H(m,'select',s);local a=H(m,'sendItems',n);assert(a==n,'Hub return blocked')end end
 for _,s in ipairs(full and {}or{31,32})do local n=H(m,'count',s);if n>0 then H(m,'select',s);assert(H(m,'sendItems',n)==n,'Hub return blocked')end end
 for t=1,8 do local n=H(m,'tankLevel',t);if n>0 then H(m,'selectTank',t);local a=H(m,'sendFluids',n);assert(a==n,'Hub fluid return blocked')end end
end
local function fluids(m)
 local ret={};local n=H(m,'getTankCount',m.side)or 0
 for t=1,n do local f=H(m,'getFluidInTank',m.side,t);if f and amount(f)>0 then ret[f.name]=(ret[f.name]or 0)+amount(f)end end
 return ret
end
local function hasconsumable(m,r)
 for k,x in ipairs(r.items_in)do if x.count>0 then local v=H(m,'getStackInSlot',m.side,m.input_start+k-1);if amount(v)>0 then return true end end end
 local f=fluids(m);for _,x in ipairs(r.fluids_in)do if(f[x.name]or 0)>0 then return true end end;return false
end
local function collect(m,r)
 if not m.large then
  for s=m.output_start,m.output_start+m.output_count-1 do
   local v=H(m,'getStackInSlot',m.side,s)
   if v and amount(v)>0 then H(m,'select',32);local before=H(m,'count',32);H(m,'suckFromSlot',m.side,s,64);local got=H(m,'count',32)-before;assert(got>0,'Output extraction blocked '..m.id);local sent=H(m,'sendItems',got);assert(sent==got,'Main item storage full')end
  end
  if m.capacity>0 then
   H(m,'selectTank',8);local _,n=H(m,'drainRobot',m.side,256000);if type(n)=='number'and n>0 then assert(H(m,'sendFluids',n)==n,'Main fluid storage full')end
  end
 end
 for k,x in ipairs(r.items_in)do if x.count==0 then
  H(m,'select',32);H(m,'suckFromSlot',m.side,m.input_start+k-1,64);local n=H(m,'count',32);if n>0 then assert(H(m,'sendItems',n)==n,'Catalyst return blocked')end
 end end
end
local limits={digest=18000,return_digest=18000,dissolve=198000,mud_sift=96,sulfate_mix=42000,acid=48,acid_sift=64,neutralize=64,neutral_sift=64,dry=48,nitrate=12000,water_leach=16000,rich_leach=16000,leach_sift=16000,freeze=48,separate=64,separate_2=64,chlorinate=48,salt_mix=48,sm_mix=48,sm_centrifuge=64,sm_sift=1000000,blend=120,zr_chloride=45,zr_solution=9000,zr_reduction=24,hf_chloride=45,hf_solution=9000,hf_reduction=18,hf_seed=45,hf_iodide=45,hf_refine=1000000,hf_cool=1000000,zr_cool=1000000,ce_chloride=64,ce_oxalate=40,ce_roast=64,ce_electro=1000000,th_electro=1000000,th_cake=48,th_thermal=1000000,uranium_bath=48,uranium_sift=1000000,salt_electro=64,co_electro=1000000,ch3cl_electro=1000000,ammonium_nitrate=8000,ammonium_chloride=8000,hcl_recycle=16000,water_can=16,cl_uncan=1000000,acetone_seed=8000}
local fluidPrimary={digest=true,return_digest=true,dissolve=true,sulfate_mix=true,nitrate=true,water_leach=true,rich_leach=true,leach_sift=true,ammonium_nitrate=true,ammonium_chloride=true,hcl_recycle=true,acetic=true}
limits.salt_synthesis=64
local function done(id)return state.done[id]or 0 end
local function credit(id)
 if id=='co_electro'then return done('ce_roast')*9-done(id)end
 if id=='ch3cl_electro'then return math.floor(done('sm_centrifuge')*0.4)-done(id)end
 if id=='cl_uncan'then return done('ch3cl_electro')-done(id)end
end
local function want(r)
 local id=r.id
 if credit(id)and credit(id)<1 then return false end
 -- Recover real chloride regardless of prior batches or the salt buffer level.
 if id=='mg_recycle'then return itemstock(r.items_in[2])>=r.items_in[2].count end
 if id=='water_leach'and state.boost.cerium or id=='rich_leach'and not state.boost.cerium then return false end
 if id=='salt_mix'and state.boost.samarium or id=='sm_mix'and not state.boost.samarium then return false end
 if id=='hf_seed'and fluidstock({name='iodine'})>=4000 then return false end
 if id=='salt_synthesis'and itemstock({id='gregtech:gt.metaitem.01',meta=2377})>=6 and itemstock({id='gregtech:gt.metaitem.01',meta=2017})>=4 then return false end
 local f=fluidPrimary[id]or #r.items_out==0
 local out=f and r.fluids_out[1]or r.items_out[1]
 return out and(f and fluidstock(out)or itemstock(out))<(limits[id]or 64)
end
local function targetbatch(r)
 if r.id=='mg_recycle'then return math.floor(itemstock(r.items_in[2])/r.items_in[2].count)end
 local f=fluidPrimary[r.id]or #r.items_out==0
 local out=f and r.fluids_out[1]or r.items_out[1]
 if not out then return 0 end
 local stock=f and fluidstock(out)or itemstock(out);local each=f and out.amount or out.count
 return math.max(0,math.ceil(((limits[r.id]or 64)-stock)/each))
end
local function enough(r,m,n)
 for _,x in ipairs(r.items_in)do local need=x.count==0 and 1 or x.count*n;local hold=r.id=='hf_chloride'and 6 or 0;if need>64 or itemstock(x)-hold<need then return false end end
 local tanks=0
 for _,x in ipairs(r.fluids_in)do
  if fluidstock(x)<x.amount*n then return false end
  if m.large then tanks=tanks+math.ceil(x.amount*n/m.capacity)elseif x.amount*n>m.capacity then return false end
 end
 if m.large and tanks>(m.tanks or 4)then return false end
 if r.circuit and m.large and not m.circuitAddress then
  local v=H(m,'getStackInSlot',m.side,m.circuit_slot)
  if not(v and v.damage==r.circuit)then
   local entry=cfg.programs[tostring(math.floor(r.circuit))];if not entry then return false end
   local desc=I(cfg.db,'get',entry);local v,e=I(cfg.me,'getItemInNetwork',desc);assert(not e,e);if amount(v)<1 then return false end
  end
 end
 return true
end
local function program(m,r,j)
 if m.circuitAddress then local ok,e=I(m.circuitAddress,'setCircuitConfiguration',r.circuit or -1);assert(ok,e);return true end
 if not r.circuit then return true end
 if not m.large then local ok,e=G(m,'setCircuitConfiguration',r.circuit);assert(ok,e);return true end
 local v=H(m,'getStackInSlot',m.side,m.circuit_slot)
 if v and v.damage==r.circuit then return true end
 if j.program_sent then if H(m,'count',31)>0 then H(m,'select',31);H(m,'dropIntoSlot',m.side,16,1)end;return false end
 H(m,'select',31);local got=H(m,'requestItems',cfg.db,cfg.programs[tostring(math.floor(r.circuit))],1)
 if got~=1 then if got and got>0 then H(m,'sendItems',got)end;return false end
 j.program_sent=true;persist();H(m,'dropIntoSlot',m.side,16,1);return false
end
local function stage(m,r,n)
 clearhub(m);state.seq=state.seq+1;local j={id=r.id,n=n,phase='stage',serial=state.seq};state.jobs[m.id]=j;persist()
 for k,x in ipairs(r.items_in)do H(m,'select',k);local need=x.count==0 and 1 or x.count*n;local got=H(m,'requestItems',cfg.db,x.db,need);if got~=need then clearhub(m);state.jobs[m.id]=nil;if r.id=='rich_leach'then state.boost.cerium=false elseif r.id=='sm_mix'then state.boost.samarium=false end;persist();log('short_withdrawal',{id=r.id,item=x.id,meta=x.meta,db=x.db,seen=itemstock(x),need=need,got=got});cache={};return false end end
 for k,x in ipairs(r.fluids_in)do H(m,'selectTank',k);local need=x.amount*n;local got=H(m,'requestFluids',cfg.db,x.db,need);if got~=need then clearhub(m);state.jobs[m.id]=nil;persist();log('short_fluid',{id=r.id,need=need,got=got});cache={};return false end end
 j.phase='commit';persist();cache={};return true
end
local function hubpending(m)
 for id,j in pairs(state.jobs)do if id~=m.id and cfg.machines[id].hub==m.hub and(j.phase=='stage'or j.phase=='commit')then return true end end
 return false
end
local function commit(m,r,j)
 assert(not G(m,'isWorkAllowed')and G(m,'getWorkMaxProgress')==0,'Commit requires stopped machine '..m.id)
 if not program(m,r,j)then return end
 local f=fluids(m)
 for k,x in ipairs(r.fluids_in)do
  local need=x.amount*j.n;local have=f[x.name]or 0;assert(have<=need,'Excess input fluid '..m.id)
  if have<need then H(m,'selectTank',k);local buffered=H(m,'tankLevel',k);if buffered<need-have then local add=need-have-buffered;local got=H(m,'requestFluids',cfg.db,x.db,add);assert(got==add,'Recovery fluid shortage '..m.id);log('recovered_fluid_buffer',{machine=m.id,name=x.name,amount=got})end;local _,n=H(m,'fillRobot',m.side,need-have);assert(type(n)=='number'and n==need-have,'Fluid delivery blocked '..m.id);log('fluid_delivered',{serial=j.serial,name=x.name,amount=n})end
 end
 if r.id=='dissolve'then local f=fluids(m);assert(f.water==90000*j.n and f['muddy monazite rare earth solution']==9000*j.n,'S1 water:mud ratio mismatch')end
 for k,x in ipairs(r.items_in)do
  local slot=m.input_start+k-1;local v=H(m,'getStackInSlot',m.side,slot);local have=amount(v);local need=x.count==0 and 1 or x.count*j.n
  if v then assert(v.name==x.id and v.damage==x.meta,'Foreign machine input '..m.id)end
  assert(have<=need,'Excess machine input '..m.id)
  if have<need then H(m,'select',k);local buffered=H(m,'count',k);if buffered<need-have then local add=need-have-buffered;local got=H(m,'requestItems',cfg.db,x.db,add);assert(got==add,'Recovery item shortage '..m.id);log('recovered_item_buffer',{machine=m.id,id=x.id,amount=got})end;local before=H(m,'count',k);H(m,'dropIntoSlot',m.side,slot,need-have);local sent=before-H(m,'count',k);assert(sent==need-have,'Item delivery blocked '..m.id);log('item_delivered',{serial=j.serial,id=x.id,amount=sent})end
 end
 j.phase='armed';j.at=computer.uptime();persist();G(m,'setWorkAllowed',true);log('armed',{machine=m.id,id=r.id,n=j.n,serial=j.serial})
end
local function update(m,j)
 local r=assert(recipes[j.id]);local max=G(m,'getWorkMaxProgress')
 if j.phase=='commit'then commit(m,r,j);return end
 if j.phase=='stage'then clearhub(m);state.jobs[m.id]=nil;persist();log('recovered_uncommitted',m.id);return end
 if j.phase=='armed'then
  if max>0 then j.phase='running';j.max=max;persist();log('started',{machine=m.id,id=j.id,max=max,n=j.n})
  elseif not hasconsumable(m,r)then assert(G(m,'isWorkAllowed'),'Machine stopped before batch completion '..m.id);j.phase='complete';persist()
  elseif computer.uptime()-(j.at or 0)>20 then error('Recipe did not start '..m.id..' '..r.id..' '..encode(G(m,'getSensorInformation')))end
 elseif j.phase=='running'and max==0 and not hasconsumable(m,r)then assert(G(m,'isWorkAllowed'),'Machine unexpectedly stopped '..m.id);j.phase='complete';persist()end
 if j.phase=='complete'then G(m,'setWorkAllowed',false);collect(m,r);clearhub(m);state.done[r.id]=(state.done[r.id]or 0)+j.n;state.counts[m.id]=(state.counts[m.id]or 0)+1;state.jobs[m.id]=nil;persist();log('completed',{machine=m.id,id=r.id,n=j.n,max=j.max});cache={}end
end
local gpu=C.list('gpu')();local screen=C.list('screen')()
if gpu and screen then I(gpu,'bind',screen);I(gpu,'setResolution',80,25);I(gpu,'setBackground',0x10202a);I(gpu,'setForeground',0xe0f0f0)end
local display=assert(load(assert(read('dashboard.lua')),'=dashboard','t',_G))()({
 invoke=I,gpu=gpu,computer=computer,recipes=recipes,state=state,
 itemstock=itemstock,fluidstock=fluidstock,persist=persist,log=log,
})
local function body()
 -- Resume interrupted jobs without crediting lost native output.
 if state.error then
  state.interrupted=state.interrupted or{}
  for id,j in pairs(state.jobs)do local m=cfg.machines[id]
   if G(m,'getWorkMaxProgress')==0 and not G(m,'isWorkAllowed')and(j.phase=='armed'or j.phase=='running')then
    state.interrupted[tostring(j.serial)]={machine=id,id=j.id,n=j.n,reason='power interruption; remaining inputs resumed without output credit'}
    if hasconsumable(m,recipes[j.id])then j.n=0;j.phase='armed'else state.jobs[id]=nil end
    persist();log('recover_power_interruption',state.interrupted[tostring(j.serial)])
   end
  end
 end
 state.error=nil
 if state.schema~=2 then
  state.boost.cerium=itemstock({id='bartworks:gt.bwMetaGenerateddust',meta=11029})>=3
  state.schema=2
 end
 state.cursor=state.cursor or {}
 persist()
 log('boot',{version=6});local cleaned={}
 for _,m in pairs(cfg.machines)do local j=state.jobs[m.id];if not j then if not hubpending(m)and not cleaned[m.hub]then clearhub(m,true);cleaned[m.hub]=true end;assert(G(m,'getWorkMaxProgress')==0,'Untracked active machine '..m.id);G(m,'setWorkAllowed',false)elseif j.phase=='armed'or j.phase=='running'then G(m,'setWorkAllowed',true);j.at=computer.uptime()elseif j.phase=='commit'then G(m,'setWorkAllowed',false)end end
 local cycle=0;local order={'V1','M1','M2','T1','B1','L1','K1','C1','E1','F1','R1','X1','S1','D1'}
 while true do
  cache={};assert(I(cfg.me,'getStoredPower')>0,'AE unpowered');local c=itemstock({id='bartworks:gt.bwMetaGenerateddust',meta=11029});local s=itemstock({id='bartworks:gt.bwMetaGenerateddust',meta=11128})
  local oldC,oldS=state.boost.cerium,state.boost.samarium
  if c<3 then state.boost.cerium=false elseif c>=48 then state.boost.cerium=true end
  if s<2 then state.boost.samarium=false elseif s>=32 then state.boost.samarium=true end
  if oldC~=state.boost.cerium then persist();log('enrichment_switch',{route='cerium',enabled=state.boost.cerium,stock=c})end
  if oldS~=state.boost.samarium then persist();log('enrichment_switch',{route='samarium',enabled=state.boost.samarium,stock=s})end
  for _,id in ipairs(order)do local m=cfg.machines[id];local j=state.jobs[id]
   if j then update(m,j)
   elseif not state.paused and not hubpending(m)then
    local offset=(state.cursor[id]or 0)%#cfg.recipes
    for k=1,#cfg.recipes do local index=(k+offset-1)%#cfg.recipes+1;local r=cfg.recipes[index]
     if r.machine==id and want(r)then local n=math.min(r.batch or m.maxbatch,targetbatch(r))
      if credit(r.id)then n=math.min(n,credit(r.id))end
      while n>0 and not enough(r,m,n)do n=n-1 end
      if n>0 then state.cursor[id]=index;if stage(m,r,n)then commit(m,r,state.jobs[id])end;break end
     end
    end
   end
  end
  cycle=cycle+1;display()
  local event,_,_,code=computer.pullSignal(0.25)
  if event=='key_down'then
   if code==57 then state.paused=not state.paused;persist()
   elseif code==19 then state.paused=false;persist()end
  end
 end
end
local ok,e=xpcall(body,debug.traceback)
if not ok then state.error=tostring(e);pcall(persist);pcall(log,'fault',e);for _,m in pairs(cfg.machines)do pcall(G,m,'setWorkAllowed',false)end;display('暂停：'..tostring(e):sub(1,68));while true do local event,_,_,code=computer.pullSignal(5);if event=='key_down'and code==19 then computer.shutdown(true)end end end

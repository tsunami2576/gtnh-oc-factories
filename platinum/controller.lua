-- Platinum Controller v1. Persistent exact batches; full-size dust routes.
local C=component;local I=C.invoke;local disk=assert(factoryDisk,'Use launch.lua');local root=assert(factoryRoot,'Use launch.lua')
local function read(p)local h,e=I(disk,'open',root..p,'r');if not h then return nil,e end;local s='';while true do local b=I(disk,'read',h,8192);if not b then break end;s=s..b end;I(disk,'close',h);return s end
local function encode(v)
 local t=type(v);if t=='string'then return string.format('%q',v)elseif t=='number'or t=='boolean'then return tostring(v)elseif t=='nil'then return'nil'end
 local a={'{'};for k,x in pairs(v)do a[#a+1]='['..encode(k)..']='..encode(x)..','end;a[#a+1]='}';return table.concat(a)
end
local function write(p,s)local h=assert(I(disk,'open',root..p,'w'));assert(I(disk,'write',h,s));I(disk,'close',h)end
local function loadfile(p)local s=read(p);if not s then return nil end;return assert(load(s,'='..p,'t',_G))()end
local cfg=assert(loadfile('config.lua'));local state=loadfile('state.lua')or loadfile('state.new')or loadfile('state.old')or{jobs={},done={},counts={},seq=0,started=computer.uptime()}
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
 local function flushItems()
  H(m,'select',32);local n=H(m,'count',32)
  if n>0 and H(m,'sendItems',n)<n then return false end;return true
 end
 local function flushFluid()
  H(m,'selectTank',8);local n=H(m,'tankLevel',8)
  if n>0 and H(m,'sendFluids',n)<n then return false end;return true
 end
 if not flushItems()or not flushFluid()then return false end
 if not m.large then
  for s=m.output_start,m.output_start+m.output_count-1 do
   local v=H(m,'getStackInSlot',m.side,s)
   if v and amount(v)>0 then H(m,'select',32);H(m,'suckFromSlot',m.side,s,64);assert(H(m,'count',32)>0,'Output extraction blocked '..m.id);if not flushItems()then return false end end
  end
  if m.capacity>0 then H(m,'selectTank',8);H(m,'drainRobot',m.side,256000);if not flushFluid()then return false end end
 end
 for k,x in ipairs(r.items_in)do if x.count==0 then H(m,'select',32);H(m,'suckFromSlot',m.side,m.input_start+k-1,64);if not flushItems()then return false end end end
 return true
end
local function descriptor(x)
 local d=x.descriptor or x
 assert(I(cfg.db,'set',1,d.id,d.meta,d.tag or ''),'Database descriptor rejected')
 return 1
end
local function request(m,kind,x,n)return H(m,kind,cfg.db,descriptor(x),n)end
local function matches(m,r)return r.machine==m.id or r.machine=='chem'and(m.id=='R1'or m.id=='R2')end
-- Inventory goals follow useful downstream material, with bounded recovery buffers.
local function done(id)return state.done[id]or 0 end
local function pending(id)local n=0;for _,j in pairs(state.jobs)do if j.id==id then n=n+j.n end end;return n end
local function outputstock(r)return r.fluidPrimary and fluidstock(r.target)or itemstock(r.target)end
local function needs(id)local r=recipes[id];return outputstock(r)<r.limit end
local function pdMetal()return itemstock(recipes.pd_precipitate.items_in[1])end
local function pdBacklog()
 return pdMetal()>144 or fluidstock(recipes.pd_precipitate.fluids_in[1])>36000 or itemstock(recipes.palladium.items_in[1])>=4
end
local function pdNeeded()return needs('palladium')or pdBacklog()end
local function acidNeed()return fluidstock(recipes.formic_acid.fluids_in[1])<16000 end
local function cycleNeeded()
 return needs('platinum')or needs('rhodium')or needs('ruthenium')or needs('iridium')or needs('osmium')or needs('palladium')and pdMetal()<36
end
local function forcedSift(r)
 return r.id=='pt_sift'and cycleNeeded()or r.id=='pd_sift'and itemstock(recipes.pd_sift.items_in[1])>0
end
local function cleanup(r)
 return r.id=='potassium_grind'and itemstock(r.items_in[1])>0 or r.id=='calcium_recycle'and itemstock(r.items_in[1])>32 or r.id=='zinc_recycle'and itemstock(r.items_in[1])>128
end
local function effectiveLimit(r)
 if cycleNeeded()then if r.id=='pt_digest'then return 144000 elseif r.id=='pt_refine'then return 144 end end
 return r.limit
end
local function want(r)
 if r.id=='pd_seed_salt'then return pdNeeded()and pdMetal()<36 and outputstock(r)<r.limit end
 if r.id=='pd_ammonia'or r.id=='pd_precipitate'then return pdNeeded()and outputstock(r)<effectiveLimit(r)end
 if r.id=='palladium'then return pdNeeded()end
 -- Use reclaimed nitrogen oxides before synthesizing nitric acid from fresh ammonia.
 if r.id=='nitric_ammonia'and(fluidstock(recipes.nitric_recycle.fluids_in[1])>=2000 or fluidstock(recipes.nitric_oxide_recycle.fluids_in[1])>=9000)then return false end
 if r.id=='na_nitrate_hydroxide'and itemstock(recipes.na_nitrate.items_in[1])>=1 then return false end
 -- Avoid accumulating nitric oxide while the one-step, oxygen-assisted route is available.
 if r.id=='nitric_recycle_bulk'or r.id=='nitric_no2' then
  if fluidstock(recipes.nitric_oxide_recycle.fluids_in[1])>=32000 or fluidstock(recipes.nitric_recycle.fluids_in[2])>=1000 then return false end
 end
 if r.id=='zinc_recycle'and acidNeed()then return true end
 return cleanup(r)or forcedSift(r)or outputstock(r)<effectiveLimit(r)
end
local function targetbatch(r)
 if cleanup(r)or forcedSift(r)or r.id=='palladium'and pdBacklog()then return r.batch end
 local each=r.fluidPrimary and r.target.amount or r.target.count
 local n=math.max(0,math.ceil((effectiveLimit(r)-outputstock(r)-pending(r.id)*each)/math.max(each,1)))
 if r.id=='zinc_recycle'and acidNeed()then
  n=math.max(n,math.ceil((16000-fluidstock(recipes.formic_acid.fluids_in[1]))/1000)-pending(r.id))
 end
 return math.max(0,n)
end
local function enough(r,m,n)
 for _,x in ipairs(r.items_in)do
  local need=x.count==0 and 1 or x.count*n
  local hold=(x.id=='bartworks:gt.bwMetaGenerateddust'and(x.meta==47 or x.meta==53))and(r.hold or 0)or 0
  if need>64 or itemstock(x)-hold<need then return false end
 end
 local tanks=0
 for _,x in ipairs(r.fluids_in)do
  if fluidstock(x)<x.amount*n then return false end
  if m.large then tanks=tanks+math.ceil(x.amount*n/m.capacity)elseif x.amount*n>m.capacity then return false end
 end
 if m.large and tanks>(m.tanks or 4)then return false end
 for _,x in ipairs(r.items_out)do if x.count*n>64 then return false end end
 if not m.large then for _,x in ipairs(r.fluids_out)do if x.amount*n>m.capacity then return false end end end
 return true
end
-- R2 drains excess Pd; R1 keeps the other chemistry moving, then helps Pd when free.
local recipeIndex={};for i,r in ipairs(cfg.recipes)do recipeIndex[r.id]=i end
local function ready(m,r)
 if not matches(m,r)or not want(r)then return nil end
 local n=math.min(r.batch or m.maxbatch,targetbatch(r))
 while n>0 and not enough(r,m,n)do n=n-1 end
 if n>0 then return r,n,recipeIndex[r.id]end
end
local function choose(m)
 if m.id=='R2'and pdBacklog()then
  for _,rid in ipairs({'palladium','pd_precipitate','pd_ammonia'})do
   local r,n,index=ready(m,recipes[rid]);if r then return r,n,index end
  end
 end
 local offset=(state.cursor[m.id]or 0)%#cfg.recipes
 if m.id=='R1'and pdBacklog()and cycleNeeded()then
  for k=1,#cfg.recipes do
   local candidate=cfg.recipes[(k+offset-1)%#cfg.recipes+1]
   if candidate.id~='pd_ammonia'and candidate.id~='pd_precipitate'and candidate.id~='palladium'then
    local r,n,index=ready(m,candidate);if r then return r,n,index end
   end
  end
 end
 for k=1,#cfg.recipes do
  local r,n,index=ready(m,cfg.recipes[(k+offset-1)%#cfg.recipes+1]);if r then return r,n,index end
 end
end
local function program(m,r,j)
 if r.configuredTool then
  local ghost=H(m,'getStackInSlot',m.side,m.circuit_slot)
  if ghost and ghost.name==r.configuredTool.id and ghost.damage==r.configuredTool.meta then return true end
  H(m,'select',31)
  if H(m,'count',31)==0 then assert(request(m,'requestItems',r.programItem,1)==1,'Tool program unavailable '..m.id)end
  assert(not H(m,'getStackInSlot',m.side,m.input_start),'Tool programming requires empty item input '..m.id)
  local before=H(m,'count',31);H(m,'dropIntoSlot',m.side,m.input_start,1)
  assert(before-H(m,'count',31)==1,'Tool program delivery blocked '..m.id)
  for k=1,40 do
   if not H(m,'getStackInSlot',m.side,m.input_start)then
    local v=H(m,'getStackInSlot',m.side,m.circuit_slot)
    assert(not v or v.name==r.configuredTool.id and v.damage==r.configuredTool.meta,'Wrong configured tool '..m.id)
    log('configured_tool',{machine=m.id,tool=r.configuredTool.name,paid_programs=1});return true
   end
   computer.pullSignal(0.05)
  end
  error('Native programming cover did not consume program '..m.id)
 end
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
 for k,x in ipairs(r.items_in)do H(m,'select',k);local need=x.count==0 and 1 or x.count*n;local got=request(m,'requestItems',x,need);if got~=need then clearhub(m);state.jobs[m.id]=nil;persist();log('short_withdrawal',{id=r.id,need=need,got=got});cache={};return false end end
 for k,x in ipairs(r.fluids_in)do H(m,'selectTank',k);local need=x.amount*n;local got=request(m,'requestFluids',x,need);if got~=need then clearhub(m);state.jobs[m.id]=nil;persist();log('short_fluid',{id=r.id,need=need,got=got});cache={};return false end end
 j.phase='commit';persist();cache={};return true
end
local function hubpending(m)
 for id,j in pairs(state.jobs)do if id~=m.id and cfg.machines[id].hub==m.hub and(j.phase=='stage'or j.phase=='commit'or j.phase=='complete')then return true end end
 return false
end
local function commit(m,r,j)
 assert(not G(m,'isWorkAllowed')and G(m,'getWorkMaxProgress')==0,'Commit requires stopped machine '..m.id)
 if not program(m,r,j)then return end
 local f=fluids(m)
 for k,x in ipairs(r.fluids_in)do
  local need=x.amount*j.n;local have=f[x.name]or 0;assert(have<=need,'Excess input fluid '..m.id)
  if have<need then H(m,'selectTank',k);local buffered=H(m,'tankLevel',k);if buffered<need-have then local add=need-have-buffered;local got=request(m,'requestFluids',x,add);assert(got==add,'Recovery fluid shortage '..m.id);log('recovered_fluid_buffer',{machine=m.id,name=x.name,amount=got})end;local _,n=H(m,'fillRobot',m.side,need-have);assert(type(n)=='number'and n==need-have,'Fluid delivery blocked '..m.id);log('fluid_delivered',{serial=j.serial,name=x.name,amount=n})end
 end
 for k,x in ipairs(r.items_in)do
  local slot=m.input_start+k-1;local v=H(m,'getStackInSlot',m.side,slot);local have=amount(v);local need=x.count==0 and 1 or x.count*j.n
  if v then assert(v.name==x.id and v.damage==x.meta,'Foreign machine input '..m.id)end
  assert(have<=need,'Excess machine input '..m.id)
  if have<need then H(m,'select',k);local buffered=H(m,'count',k);if buffered<need-have then local add=need-have-buffered;local got=request(m,'requestItems',x,add);assert(got==add,'Recovery item shortage '..m.id);log('recovered_item_buffer',{machine=m.id,id=x.id,amount=got})end;local before=H(m,'count',k);H(m,'dropIntoSlot',m.side,slot,need-have);local sent=before-H(m,'count',k);assert(sent==need-have,'Item delivery blocked '..m.id);log('item_delivered',{serial=j.serial,id=x.id,amount=sent})end
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
  elseif computer.uptime()-(j.at or 0)>30 then error('Recipe did not start '..m.id..' '..r.id..' '..encode(G(m,'getSensorInformation')))end
 elseif j.phase=='running'and max==0 and not hasconsumable(m,r)then assert(G(m,'isWorkAllowed'),'Machine unexpectedly stopped '..m.id);j.phase='complete';persist()end
 if j.phase=='complete'then G(m,'setWorkAllowed',false);if collect(m,r)==false then return end;clearhub(m);state.done[r.id]=(state.done[r.id]or 0)+j.n;state.counts[m.id]=(state.counts[m.id]or 0)+1;state.jobs[m.id]=nil;state.lastCompleted={id=r.id,n=j.n,at=computer.uptime()};persist();log('completed',{machine=m.id,id=r.id,n=j.n,max=j.max});cache={}end
end
local gpu=C.list('gpu')();local screen=C.list('screen')()
if gpu and screen then I(gpu,'bind',screen);I(gpu,'setResolution',80,25);I(gpu,'setBackground',0x10202a);I(gpu,'setForeground',0xe0f0f0)end
local order={'M1','S1','V1','L1','K1','H1','X1','D1','E1','F1','R1','R2'}
local display=assert(load(assert(read('dashboard.lua')),'=dashboard','t',_G))()({
 invoke=I,gpu=gpu,computer=computer,recipes=recipes,state=state,
 itemstock=itemstock,fluidstock=fluidstock,persist=persist,log=log,
})
local function body()
 if state.error then for id,j in pairs(state.jobs)do local m=cfg.machines[id];if(j.phase=='armed'or j.phase=='running')and G(m,'getWorkMaxProgress')==0 and not G(m,'isWorkAllowed')then state.aborted=state.aborted or{};state.aborted[tostring(j.serial)]={machine=id,id=j.id,n=j.n,reason='stopped native batch; outputs uncredited, remaining inputs resumed'};if hasconsumable(m,recipes[j.id])then j.n=0;j.phase='armed';j.recovered=true else state.jobs[id]=nil end;persist();log('recover_stopped',id)end end end
 state.error=nil;state.cursor=state.cursor or{};persist();log('boot',{version=1});local cleaned={}
 for _,id in ipairs(order)do local m=cfg.machines[id];local j=state.jobs[id]
  if not j then
   if not hubpending(m)and not cleaned[m.hub]then clearhub(m,true);cleaned[m.hub]=true end
   assert(G(m,'getWorkMaxProgress')==0,'Untracked active machine '..m.id);G(m,'setWorkAllowed',false)
  elseif j.phase=='armed'or j.phase=='running'then G(m,'setWorkAllowed',true);j.at=computer.uptime()
  elseif j.phase=='commit'then G(m,'setWorkAllowed',false)end
 end
 local cycle=0
 while true do
  cache={};while I(cfg.me,'getStoredPower')<=0 do display('等待 AE 供电恢复；暂停新投料');computer.pullSignal(2)end
  for _,id in ipairs(order)do local m=cfg.machines[id];local j=state.jobs[id]
   if j then update(m,j)
   elseif not state.paused and not hubpending(m)then
    local r,n,index=choose(m)
    if r then state.cursor[id]=index;if stage(m,r,n)then commit(m,r,state.jobs[id])end end
   end
  end
  cycle=cycle+1;state.cycles=cycle
  if cycle%2==0 then display(state.paused and'已暂停新投料；正在收尾在制批次'or'运行中：按目标库存补充，缺料自动等待')end
  local signal,_,key=computer.pullSignal(0.25)
  if signal=='key_down'then if key==32 then state.paused=true;persist();log('pause',true)elseif key==114 or key==82 then state.paused=false;persist();log('resume',true)end end
 end
end
local ok,e=xpcall(body,debug.traceback)
if not ok then state.error=tostring(e);pcall(persist);pcall(log,'fault',e);for _,m in pairs(cfg.machines)do pcall(G,m,'setWorkAllowed',false)end;pcall(display,'暂停：'..tostring(e):sub(1,68));while true do local sig,_,key=computer.pullSignal(5);if sig=='key_down'and(key==114 or key==82)then computer.shutdown(true)end end end

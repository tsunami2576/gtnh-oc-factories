-- This module only draws the screen and accounts for completed recipes.
-- Call the returned constructor with the adapter described in README.md.
return function(env)
local I=assert(env.invoke);local gpu=assert(env.gpu)
local computer=assert(env.computer);local recipes=assert(env.recipes)
local state=assert(env.state);local itemstock=assert(env.itemstock)
local fluidstock=assert(env.fluidstock);local persist=assert(env.persist);local log=assert(env.log)
-- Material dashboard. Rates use this factory's completed native recipes, never global AE stock changes.
local function material(label,recipe,index,kind,low)
 local x=recipes[recipe][kind=='fluid'and'fluids_in'or'items_in'][index]
 return {label=label,x=x,fluid=kind=='fluid',low=low or(x.amount or math.max(1,x.count))}
end
local supplies={
 material('王水','pt_digest',1,'fluid'),material('盐酸','rhodium',1,'fluid'),
 material('硝酸','na_nitrate',1,'fluid'),material('甲酸','palladium',1,'fluid'),
 material('氯化铵','ir_precipitate',1,'fluid'),material('氢气','hcl',1,'fluid'),
 material('氧气','disulfate',1,'fluid'),material('氨气','pd_ammonia',1,'fluid'),
 material('水','rh_cake_solution',1,'fluid'),material('一氧化碳','sodium_formate',1,'fluid'),
 material('硝石粉','rare_residue',2,'item'),material('硫粉','disulfate',2,'item'),
 material('钾粉','disulfate',1,'item'),material('盐','rh_roast',2,'item'),
 material('氢氧化钠','sodium_formate',1,'item'),material('钠粉','na_nitrate',1,'item'),
 material('硫酸','formic_acid',1,'fluid'),
}
local circulating={
 material('精炼铂盐粉','pt_refine',1,'item'),material('铂金属粉','pt_digest',1,'item'),
 material('钯金属粉','pd_precipitate',1,'item'),recipes.potassium_cast and material('熔融钾','potassium_cast',1,'fluid')or material('铂残渣','residue_leach',1,'item'),
 material('钙粉','platinum',2,'item'),material('锌粉','rh_reduce',1,'item'),
}
local products={{'platinum','铂'},{'palladium','钯'},{'rhodium','铑'},{'ruthenium','钌'},{'iridium','铱'},{'osmium','锇'}}
local function copyDone()local a={};for id,n in pairs(state.done)do a[id]=n end;return a end
if not state.telemetry or state.telemetry.schema~=1 then state.telemetry={schema=1,clock=0,points={{t=0,done=copyDone()}}}end
local telemetry=state.telemetry
local telemetryLast=computer.uptime()
local telemetrySaved=telemetry.clock
local function telemetryRates()
 local now=computer.uptime();telemetry.clock=telemetry.clock+math.max(0,now-telemetryLast);telemetryLast=now
 local pts=telemetry.points
 if #pts==0 then pts[1]={t=telemetry.clock,done=copyDone()}end
 if telemetry.clock-pts[#pts].t>=15 then pts[#pts+1]={t=telemetry.clock,done=copyDone()}end
 local cutoff=math.max(0,telemetry.clock-300)
 while #pts>2 and pts[2].t<=cutoff do table.remove(pts,1)end
 local first=pts[1];local start=math.max(cutoff,first.t);local seconds=telemetry.clock-start
 local fraction=0
 if start>first.t and pts[2]then fraction=(start-first.t)/(pts[2].t-first.t)end
 local rates={}
 if seconds>=5 then for id,n in pairs(state.done)do
  local baseline=first.done[id]or 0
  if fraction>0 then baseline=baseline+((pts[2].done[id]or 0)-baseline)*fraction end
  rates[id]=math.max(0,n-baseline)*3600/seconds
 end end
 if telemetry.clock-telemetrySaved>=30 then persist();telemetrySaved=telemetry.clock end
 return rates,seconds
end
local function sameResource(a,b,fluid)
 if fluid then return a.name==b.name end
 return a.id==b.id and a.meta==b.meta and(a.tag or'')==(b.tag or'')
end
local function resourceFlow(m,rates,gross)
 local total=0
 for id,n in pairs(rates)do local r=recipes[id]
  if r then
   for _,x in ipairs(r[m.fluid and'fluids_in'or'items_in'])do
    if sameResource(x,m.x,m.fluid)then total=total+(x.amount or x.count)*n end
   end
   if not gross then for _,x in ipairs(r[m.fluid and'fluids_out'or'items_out'])do
    if sameResource(x,m.x,m.fluid)then total=total-(x.amount or x.count)*n end
   end end
  end
 end
 return total
end
local function stockOf(m)
 local ok,n=pcall(m.fluid and fluidstock or itemstock,m.x)
 if ok then return n end
 return nil
end
local function shortNumber(n)
 local a=math.abs(n)
 if a>=1000000 then return string.format('%.2fM',n/1000000)
 elseif a>=1000 then return string.format('%.2fk',n/1000)
 elseif a>=100 then return string.format('%.0f',n)
 elseif a>=1 then return string.format('%.1f',n)
 elseif a>=0.05 then return string.format('%.2f',n)
 else return '0'end
end
local function stockText(m,n)
 if n==nil then return '--'end
 if m.fluid then return shortNumber(n/1000)..'B'end
 return shortNumber(n)
end
local function rateText(m,n,ready,signed)
 if not ready then return '采样中'end
 if m.fluid then n=n/1000 end
 local sign=signed and n>0.05 and'+'or''
 return sign..shortNumber(n)
end
local function clipped(s,width)
 local out,w={},0
 for ch in tostring(s):gmatch('[%z\1-\127\194-\244][\128-\191]*')do
  local size=#ch>1 and 2 or 1
  if w+size>width then break end
  out[#out+1]=ch;w=w+size
 end
 return table.concat(out),w
end
local dashboardCells={};local dashboardColor;local dashboardReady=false
local function paint(x,y,width,s,color)
 local text,w=clipped(s,width);text=text..string.rep(' ',width-w);color=color or 0xe0f0f0
 local key=x..':'..y;local old=dashboardCells[key]
 if old and old.text==text and old.color==color then return end
 if dashboardColor~=color then I(gpu,'setForeground',color);dashboardColor=color end
 I(gpu,'set',x,y,text);dashboardCells[key]={text=text,color=color}
end
local function renderDashboard(message)
 local rates,seconds=telemetryRates();local ready=seconds>=5
 if not gpu then return end
 if not dashboardReady then I(gpu,'setBackground',0x10202a);I(gpu,'fill',1,1,80,25,' ');dashboardReady=true end
 paint(2,1,45,(env.title or '铂族产线 · 原料库存与平均流量'),0x8bd7ff)
 paint(56,1,23,state.paused and'已暂停新投料'or'按目标库存补料',state.paused and 0xefc56a or 0x55d69e)
 paint(2,2,77,'粉末单位：份；流体单位：B；速率均为每小时',0x92a7b3)
 paint(2,3,38,'补给与药剂：正数消耗，负数回收',0x8bd7ff)
 paint(43,3,35,'铂族成品',0x8bd7ff)
 paint(2,4,12,'物料');paint(15,4,12,'当前库存');paint(28,4,12,'净耗/h')
 paint(43,4,10,'产物');paint(55,4,10,'当前库存');paint(66,4,13,'平均产速/h')
 local low={}
 for k,m in ipairs(supplies)do
  local y=k+4;local n=stockOf(m);local flow=resourceFlow(m,rates,false)
  local scarce=n~=nil and n<m.low
  if scarce then low[#low+1]=m.label end
  paint(2,y,12,m.label);paint(15,y,12,stockText(m,n),scarce and 0xefc56a or 0xe0f0f0)
  paint(28,y,12,rateText(m,flow,ready,true),flow>0.05 and 0xefc56a or flow< -0.05 and 0x55d69e or 0x81939f)
 end
 for k,entry in ipairs(products)do
  local r=recipes[entry[1]];local m={x=r.target,fluid=false};local flow=0
  for _,x in ipairs(r.items_out)do if sameResource(x,r.target,false)then flow=flow+x.count*(rates[r.id]or 0)end end
  paint(43,k+4,10,entry[2]);paint(55,k+4,10,stockText(m,stockOf(m)))
  paint(66,k+4,13,rateText(m,flow,ready,false),flow>0 and 0x55d69e or 0x81939f)
 end
 paint(43,12,36,'循环料：取用量包含反复周转',0x8bd7ff)
 paint(43,13,12,'物料');paint(55,13,10,'当前库存');paint(66,13,13,'取用/h')
 for k,m in ipairs(circulating)do
  paint(43,k+13,12,m.label);paint(55,k+13,10,stockText(m,stockOf(m)))
  paint(66,k+13,13,rateText(m,resourceFlow(m,rates,true),ready,false),0x92a7b3)
 end
 if #low>0 then
  paint(43,21,36,'低库存：'..table.concat(low,'、'),0xefc56a)
  paint(43,22,36,'低于一批用量，可留意补给',0x92a7b3)
 else paint(43,21,36,'所列补给料库存充足',0x55d69e);paint(43,22,36,'')end
 local window=math.floor(math.min(300,seconds))
 paint(2,23,77,'平均窗口：'..math.floor(window/60)..'分'..window%60 ..'秒；净耗已扣本线回收',0x92a7b3)
 paint(2,24,77,'仅统计本线已完成加工；库存为主网可用量',0x92a7b3)
 paint(2,25,77,'空格暂停新投料 / R 继续',0x92a7b3)
 if message and(message:find('暂停：',1,true)or message:find('等待 AE',1,true))then paint(2,23,77,message,0xff7070)end
end
local dashboardNext=0;local dashboardMessage
local function display(message)
 local now=computer.uptime();if now<dashboardNext and message==dashboardMessage then return end
 dashboardNext=now+5;dashboardMessage=message
 local ok,e=pcall(renderDashboard,message)
 if not ok then
  if state.uiError~=tostring(e)then state.uiError=tostring(e);pcall(log,'dashboard_error',e)end
  if gpu then pcall(paint,2,23,77,'统计画面异常：'..tostring(e),0xff7070)end
 else state.uiError=nil end
end

return display
end

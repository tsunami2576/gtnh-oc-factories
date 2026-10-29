-- OpenOS + Internet Card. Only program files are updated; config and journals are retained.
local variant=...
assert(variant=='platinum' or variant=='monazite' or variant=='all',
 'Usage: lua install.lua platinum|monazite|all')
local filesystem=require('filesystem')
local internet=require('internet')
local base='https://raw.githubusercontent.com/tsunami2576/gtnh-oc-factories/main/'
local root='/oc-factories/'
local function download(path)
 local data={}
 for chunk in internet.request(base..path)do data[#data+1]=chunk end
 local source=table.concat(data)
 assert(load(source,'='..path,'t',{}),'Invalid Lua download: '..path)
 filesystem.makeDirectory(filesystem.path(root..path))
 local f=assert(io.open(root..path,'wb'));assert(f:write(source));f:close()
 print('Installed '..path)
end
for _,path in ipairs({'launch.lua','configure.lua'})do download(path)end
for _,name in ipairs({'platinum','monazite'})do
 if variant=='all' or variant==name then
  for _,path in ipairs({'controller.lua','dashboard.lua','config.example.lua'})do
   download(name..'/'..path)
  end
  local config=root..name..'/config.lua'
  if not filesystem.exists(config)then
   assert(filesystem.copy(root..name..'/config.example.lua',config))
   print('Created '..config..'; replace all *_ADDRESS values.')
  end
 end
end
print('Next: edit config.lua, then run configure.lua and launch.lua.')

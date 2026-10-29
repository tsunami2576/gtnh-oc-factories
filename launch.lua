-- OpenOS: lua /oc-factories/launch.lua platinum|monazite
local variant=...
assert(variant=='platinum' or variant=='monazite','Choose platinum or monazite')
local component=require('component')
local computer=require('computer')
local filesystem=require('filesystem')
local directory='/oc-factories/'..variant
local disk,mount=assert(filesystem.get(directory))
local root=directory:sub(#mount+1)..'/'
if root:sub(1,1)~='/' then root='/'..root end
assert(filesystem.exists(directory..'/config.lua'),'Edit config.lua and run configure.lua first')
local env=setmetatable({component=component,computer=computer,
 factoryDisk=disk.address,factoryRoot=root},{__index=_G})
env._G=env
assert(loadfile(directory..'/controller.lua','t',env))()

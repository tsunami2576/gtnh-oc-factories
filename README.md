# GTNH OC 物料看板与产线控制

铂处理、独居石处理两套 Lua 程序。显示原料库存与净耗、循环料取用量、成品平均产速；支持中文 80×25 屏幕、近 5 分钟统计、低库存提示和局部刷新。正数表示消耗，负数表示回收；`≈` 表示概率产物的期望速率。

## 安装

需要 OpenOS、互联网卡，以及能显示 80×25 的 GPU/屏幕。T3 OC 部件可用。

```sh
wget https://raw.githubusercontent.com/tsunami2576/gtnh-oc-factories/main/install.lua /tmp/factories-install.lua
lua /tmp/factories-install.lua all
```

1. 编辑 `/oc-factories/platinum/config.lua` 或 `/oc-factories/monazite/config.lua`，替换所有 `*_ADDRESS`，按实际布局修改枢纽方向、输入输出槽位和液槽容量。共用枢纽保留同一地址。
2. 连接机器、ME 查询接口、IO Hub、独立数据库及原生输出口。用下列命令检查接口并写入数据库的幽灵样本。
3. 首次启动时机器应空闲、输入仓为空；确认供电和物料已接好，再启动。后续保留程序自己生成的 `state.*` 文件，用于恢复在制批次。

```sh
lua /oc-factories/configure.lua platinum
lua /oc-factories/launch.lua platinum
# 独居石线将 platinum 换成 monazite
```

空格暂停新投料，R 继续。退出/重启后用相同命令恢复；重装保留已有配置和运行记录。

## 接线与设备

完整控制需要 Programmable Hatches 的 IO Hub、可写 OC 数据库、GT 机器适配器，以及提供 `getItemInNetwork` / `getFluidInNetwork` 的 ME 查询接口。后者可用适配器连接 ME 流体接口（`ae2fc:fluid_interface`）。`configure.lua` 会检查实际方法是否可用。

- **铂线**：R1/R2 大化反、E1 高炉、D1 蒸馏塔、F1 工业筛选机；M1 研磨机、L1 电解机、K1 装罐机、S1 流体固化机、V1 真空冷冻机、H1 流体加热机、X1 流体提取机。数据库需可写；S1 使用编程覆盖板切换电路/锭模具，相关编程物品需放入 ME。
- **独居石线**：D1 煮解池、S1 溶解槽、R1 大化反、E1 高炉、F1 工业筛选机、C1 工业离心机；V1 真空冷冻机、M1/M2 电磁分离机、T1 热离心机、B1 化学浸洗机、L1 电解机、K1 装罐机、X1 混合机。数据库至少 67 槽，S1 的电路 9 编程物品需放入 ME。丙酮、草酸、硝酸等从 ME 持续供给；碘为铪循环启动料。

参考设备为 IV，高炉/煮解池使用高速钢 G 线圈；每台多方块仍需满足原生电压、电流、维护与结构要求。配置中的方向是相对 IO Hub 的面：0 下、1 上、2 北、3 南、4 西、5 东；槽位从 1 开始。改变仓型号时须同步改配置。

配方与接口基于 GT5U **5.09.54.183**、OpenComputers **1.12.62-GTNH**、Programmable Hatches **0.2.0p26**。不同版本需核对物品 ID、配方及接口；铕在此 IV 配置中输出氧化物。

## 只复用显示前端

直接引用对应目录的 `dashboard.lua`，不必运行控制器，也不要求连接 ME；库存可由自己的查询函数提供。它返回一个构造函数，接收以下数据并返回 `draw(message)`：

```lua
local draw = dofile("/oc-factories/platinum/dashboard.lua")({
  invoke = component.invoke, gpu = gpuAddress, computer = computer,
  recipes = recipesById, state = state,
  itemstock = itemstock, fluidstock = fluidstock,
  persist = persist, log = log,
})
draw() -- 定期调用；内部每 5 秒刷新
```

`recipesById` 由模板的 `recipes` 按 `id` 建索引。`state.done[id]` 是本线已完成的配方次数；`itemstock(x)` / `fluidstock(x)` 返回当前库存，流体单位为 mB。`persist()` 保存状态，`log(kind, message)` 接收画面错误；独居石界面还需 `state.boost={cerium=false,samarium=false}`。修改模块开头的物料/产物列表即可换成自己的产线。

统计依据本线完成配方，净耗会扣除本线回收，不使用共享 ME 库存涨跌推算产速。模块只绘图和更新统计，不调用投料或机器开关。

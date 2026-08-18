# 叶子生成、Streaming显示与清扫

## 目标与边界

负责区域逻辑叶子、全服共享大厅钱币池、服务端收取判定、客户端流式模型、空间网格、当前区域进度和清扫范围反馈。工具属性与装备归工具功能，背包容量归背包功能。

## 玩家流程

当前推进区域生成正式叶子，下一域只显示不可处理预览。大厅独立维护600个共享钱币池位并每0.1秒激活一个空位。玩家装备清洁工具并持续输入后，服务端按工具行为收取或推动合法目标；区域叶子推进区域进度，大厅钱币只进入背包、出售和清理统计。

## 服务端权威

`LeafService`拥有逻辑叶片描述、空间索引、生成缺口、收取去重、区域完成、庭院广播及全服Lobby广播。大厅池不写`YardProgress`或DataStore，客户端模型是否加载、镜头是否可见都不能作为收取依据。

## 客户端表现

`YardLeafController`按服务端描述和8-stud空间格只加载附近模型，区域模型放入各区`GeneratedLeaves`，Lobby模型放入`大厅装扮.GeneratedLeaves`；Streaming后复用对象池。客户端远距收尾描边只选择当前正式Area，不选择Lobby。

## 数据流

区域/庭院状态与全服Lobby池 -> 服务端生成逻辑描述 -> `YardLeafSnapshot/YardLeafDelta` -> 客户端流式模型；输入与瞄准 -> 活动Remote -> 服务端同时查询当前庭院和Lobby -> 背包、统计及必要的区域进度更新 -> 快照/增量刷新。

## 配置

叶子类型、权重、模型和Lobby入口来自`LeafConfig`；客户端加载半径和批量预算来自`LeafVisibilityConfig`；圆形、边界和瞄准计算复用`HarvestGeometry`。

## Remote

`YardLeafSnapshot`和`YardLeafDelta`由服务端同步逻辑描述；`SetLeafPickupActive`、`UpdateHarvestAim`和`LeafPickupBatch`承载输入；`LeafCollected`发送成功反馈。客户端请求不携带可直接相信的奖励结果。

## 快照字段

`AreaClearedValue`、`AreaTotalValue`、`AreaProgress`、`AreaCollectedLeafCount`、`AreaTotalLeafCount`、`LeafValueMultiplier`、`PersonalLeafValueMultiplier`。

## 永久字段与重置

无独占主存档顶层字段；叶子区域进度存放在`YardProgress`内部。Lobby池是服务器会话状态，不保存且不应用Rebirth数量倍率。死亡保留区域进度，Rebirth重建本轮区域但不重建Lobby池。

## Studio契约

精确结构见`Workspace区域结构`、`ReplicatedStorage资源/叶子模板`和`收割范围与描边`。正式叶子由运行时描述驱动，不要求在Studio预摆每一片。

## 依赖功能

依赖`area-progression-rebirth`、`tools-upgrades`和`bags-capacity`；排行榜、失物生成、教程、回收引导和HUD消费收取结果。

## 不变量

- 服务端逻辑描述和区域计数是唯一进度来源；Lobby固定600个稳定池位且同一池位最多成功领取一次。
- 预览叶子不可收取，不计入正式缺口和完成。
- Streaming加载/回收模型不得增减逻辑叶片。
- 失败、重复和已移除目标不能重复发放背包价值或统计。
- Lobby与庭院的移除/移动增量必须隔离；Lobby拾取不推进区域、教程或幸运箱检查点。

## 修改影响

改变叶子生成、索引或收取接口时检查工具命中、背包满、失物触发、区域完成、教程漏斗、排行榜和庭院访客同步。修改模型路径时同步Studio契约。

## 最小回归清单

- [ ] 首批、补叶、预览和区域完成的逻辑总数一致。
- [ ] Tool01～04合法范围内生效，越界或伪造请求被拒绝。
- [ ] Streaming进出、切庭院和死亡后无重复模型或进度变化。
- [ ] Lobby约60秒填满600个池位，拾取后全服同步并按0.1秒逐个补位。

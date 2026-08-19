# 叶子生成、Streaming显示与清扫

## 目标与边界

负责区域逻辑叶子、全服共享大厅钱币池、已清区域会话重置钱币、服务端收取判定、客户端流式模型、空间网格、当前区域进度和清扫范围反馈。工具属性与装备归工具功能，背包容量归背包功能。

## 玩家流程

个人庭院中全部已付费解锁区域都生成正式可处理叶子，只有下一锁定区域显示不可处理预览，因此玩家可同时清理多个已解锁区域。总量超过20000的正式区域和ResetCoin在玩家收取后，以每0.1秒最多100片持续补到`min(20000, 区域实际剩余数)`；补充位置覆盖整个`ground`并优先选择当前密度较低的8-stud网格。大厅独立维护600个共享钱币池位并每0.1秒激活一个空位。ResetCoin仍必须等待全部已解锁区域清完。

## 服务端权威

`LeafService`拥有正式区域、`ResetAreas`与Lobby的逻辑描述、空间索引、生成缺口、收取去重、区域完成、庭院广播及全服Lobby广播。普通补充在后台维护600个位置候选，每次从全区域按表面积采样4个位置并选择“活动叶子+已缓存位置”最少的网格；候选不再依附当前仍有叶子的网格。`AreaCoinResetService`绑定现有Prompt，签发限时且绑定具体重置台的确认资格，并在最终请求时再次校验资格、距离和并发锁。大厅池和重置钱币都不写`YardProgress`或DataStore，客户端模型是否加载、镜头是否可见都不能作为收取依据。

## 客户端表现

`YardLeafController`按服务端描述和8-stud空间格只加载附近模型，区域模型放入各区`GeneratedLeaves`，Lobby模型放入`大厅装扮.GeneratedLeaves`；Streaming后复用对象池。`PerformanceController`按本地FPS提供Low/Medium/High档，庭院、ResetCoin、Lobby、预览和Coop合计最多显示3000/10000/20000个世界叶子模型；最近的Streaming网格和收尾目标优先进入创建队列。降档只取消尚未执行的创建，不因档位变化回收已显示模型；现有模型继续保留，直至正常收取或离开原Streaming隐藏范围。普通大厅按`StateSnapshot.ActiveYardOwnerUserId`切换庭院，合作副本则只以`YardLeafSnapshot/YardLeafDelta`中的`Coop/JobId`作用域维护世界，普通状态快照不得清除合作钱币。客户端远距收尾描边只选择当前正式Area，不选择Lobby。`LeafGainHintController`将成功进入背包的逐片钱币提示放回各自权威世界位置，使用`tishi`模板向上淡出；提示只存在于收集者客户端。`AreaCoinResetController`显示权威资格和真实失败原因，可用/锁定渐变严格二选一；锁定确认只让说明文字放大并短暂变红，不发送重置请求。门金币不足且可重置时，区域门控制器只把现有本地引导Beam转向Reset入口，实际资格仍来自本功能的服务端状态。

## 数据流

区域/庭院状态、会话ResetAreas与全服Lobby池 -> 服务端生成逻辑描述 -> `YardLeafSnapshot/YardLeafDelta` -> 客户端流式模型；重置Prompt -> `AreaCoinResetPrompted` -> 面板确认 -> `RequestAreaCoinReset`再次权威校验 -> 创建单轮ResetAreas；输入与瞄准 -> 活动Remote -> 服务端同时查询当前庭院、重置钱币和Lobby -> 背包、清理统计及仅限正式区域的进度更新 -> `LeafCollected`逐片价值与世界坐标反馈、快照和增量刷新。

## 配置

叶子类型、权重、模型和Lobby入口来自`LeafConfig`；每个正式区域和ResetCoin区域的服务端权威活动上限为20000，补充批量为100/0.1秒，位置缓存目标为600且每Heartbeat最多准备12个候选。客户端加载半径、批量预算、性能采样阈值和3000/10000/20000模型额度来自`LeafVisibilityConfig`；圆形、边界和瞄准计算复用`HarvestGeometry`。

## Remote

`AreaCoinResetPrompted`只向合法触发世界Prompt的玩家发送当前资格，并同时结束门短缺的前往Reset引导；`RequestAreaCoinReset`返回`Status/Message/Eligible/RequirementText`并只接受仍在该重置台附近的单次确认。`YardLeafSnapshot`和`YardLeafDelta`由服务端同步逻辑描述；`SetLeafPickupActive`、`UpdateHarvestAim`和`LeafPickupBatch`承载输入；`LeafCollected`发送成功反馈，其中逐片提示记录包含`LeafType/BagAmount/DisplayValue/WorldPosition`。客户端请求不携带可直接相信的奖励结果。

## 快照字段

`AreaClearedValue`、`AreaTotalValue`、`AreaProgress`、`AreaCollectedLeafCount`、`AreaTotalLeafCount`、`AreaCoinResetEligible`、`AreaCoinResetRequirementText`、`LeafValueMultiplier`、`PersonalLeafValueMultiplier`。

`LeafValueMultiplier`继续由服务端计算为个人历史倍率乘重生倍率；`PersonalLeafValueMultiplier`只兼容老档已拥有的`PlayerAttributeLevels.LeafValue`，新玩家没有购买入口时保持x1。

## 永久字段与重置

无独占主存档顶层字段；叶子区域进度存放在`YardProgress`内部。Lobby池和ResetAreas都是服务器会话状态，不保存；ResetAreas按当前Rebirth叶子数量倍率创建，Lobby不应用该倍率。死亡保留本轮ResetAreas，Rebirth重建玩家庭院并清除它们，但不重建Lobby池。

## Studio契约

精确结构见`Workspace区域结构`、`ReplicatedStorage资源/叶子模板/世界收取提示`、`收割范围与描边`和`StarterGui契约`。正式叶子由运行时描述驱动，不要求在Studio预摆每一片；全部直属`Workspace.Function.Reset.ProximityPrompt`都是同一面板入口。

## 依赖功能

依赖`area-progression-rebirth`、`tools-upgrades`和`bags-capacity`；排行榜、失物生成、教程、回收引导和HUD消费收取结果。

## 不变量

- 服务端逻辑描述和区域计数是唯一进度来源；Lobby固定600个稳定池位且同一池位最多成功领取一次。
- 正式区域与ResetCoin补充必须覆盖整个`ground`并趋向低密度网格，不能只在剩余叶子附近或最后一个地面Part集中。
- 预览叶子不可收取，不计入正式缺口和完成。
- Streaming加载/回收模型不得增减逻辑叶片。
- Low/Medium/High只限制本机可见模型创建；不同档位客户端必须共享相同叶子ID、奖励和进度，降档不得因性能档位主动回收已显示模型。
- 老档`LeafValue`个人倍率必须在Yard、ResetCoin、Lobby与Coop复用同一奖励入口；客户端隐藏升级卡不得清除、重复应用或绕过该倍率。
- 失败、重复和已移除目标不能重复发放背包价值或统计。
- 世界收取提示只消费成功进入背包的服务端逐片反馈；缺失、超额或播放失败不得改变奖励，Quick Sell与即时回收不创建该提示。
- `UpdateHarvestAim`必须在`LeafService`初始化完成后立即绑定，并早于首份玩家状态加载；团队测试的较慢冷启动不得积压或丢弃瞄准事件。
- Lobby与庭院的移除/移动增量必须隔离；Lobby拾取不推进区域、教程或幸运箱检查点。
- Coop客户端活动世界只由当前Coop快照作用域维护；发布环境必须匹配本服`JobId`，Studio因两端JobId占位形式不同而由首个合法Coop Begin锁定作用域，后续包仍必须匹配。普通`StateSnapshot.ActiveYardOwnerUserId`不得清空或改写该作用域。
- Coop仍复用普通工具的同一收取和结算入口，但`Waiting`及完成阶段必须拒绝活动请求；匹配上下文进入`Playing`后才统一开放，不能复制另一套副本拾取算法。
- ResetAreas与正式区域共用显示和工具查询但使用不同ID；重置拾取只增加背包、清理榜，并仅在本轮累计数正好达到200倍数时即时判定幸运箱，不改变门、教程、首次通关、正式区域完成值或Rebirth资格。
- Prompt本身不得创建ResetAreas；最终确认必须重新校验自己庭院、庭院就绪、全部已解锁区域、旧ResetCoin、具体重置台距离和并发锁。
- 门短缺引导只消费权威ResetCoin资格；Beam或常驻提示失败不得创建ResetAreas、改变正式进度或绕过Prompt确认。

## 修改影响

改变叶子生成、索引或收取接口时检查工具命中、背包满、失物触发、区域完成、教程漏斗、排行榜、个人庭院隔离和Coop共享同步。修改模型路径时同步Studio契约。

## 最小回归清单

- [ ] 全部已解锁区域的首批、补叶和完成计数一致，只有下一锁定区域保持不可收取预览。
- [ ] 普通区域每0.1秒最多补100片并只补到`min(20000, 实际剩余数)`；连续清理一侧时补充仍覆盖全部地面且无单点堆叠。
- [ ] Studio分别覆盖Low/Medium/High时，本地新建模型总数不超过3000/10000/20000；降档停止新建且不主动回收现有模型，收取或远距Streaming后自然回到新额度内。
- [ ] Tool01～04合法范围内生效，越界或伪造请求被拒绝。
- [ ] 新档个人倍率保持x1且不显示个人倍率牌；带旧`LeafValue`等级的档案按每级+0.5继续结算并显示倍率牌。
- [ ] 大厅与Coop团队测试冷启动期间`UpdateHarvestAim`已有服务端监听，无队列耗尽或瞄准事件丢弃警告。
- [ ] 每片成功进入背包的钱币只在收集者客户端从实际收取位置显示对应图片和`+价值`，立即开始在1.4秒内上升3 studs；前0.6秒保持可见，后0.8秒继续上升并淡出。排期与活动提示合计最多30个且复用对象池。
- [ ] Streaming进出、状态快照和死亡后无重复模型或进度变化；两名普通玩家的个人庭院描述不串包。
- [ ] Coop冷启动及工具、背包、Coins和区域进度触发多次普通状态快照后，Area01正式钱币和Area02预览仍保留且只接收匹配本服`JobId`的Coop增量。
- [ ] Studio副本匹配状态达到`Expected=1/Arrived=1/Playing`后，Tool01真实收取使Area01计数减少且背包增加；等待状态同一请求不结算。
- [ ] Lobby约60秒填满600个池位，拾取后全服同步并按0.1秒逐个补位。
- [ ] Prompt只打开当前玩家面板；全部已解锁区域清完后确认恢复各区完整一轮钱币且门保持开启，任一区域或上一轮未清完、远距、伪造或并发请求均不生成。

## 合作副本边界

合作局使用唯一`CoopYard`，全员共享Area01–08进度。难度倍率替代Rebirth叶量倍率，Lobby池不启动；20000权威活动上限、均衡补充和100片/0.1秒吞吐保持，每名成员仍按自己的性能档位限制本地模型。叶子包使用`ScopeKind/ScopeId`隔离Yard与Coop；每名玩家另维护当前服务器内的个人分区收取数供幸运箱即时判定。

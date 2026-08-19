# 经济、购买台、回收与商业化

## 目标与边界

统一金币增减、购买台、叶子回收、失物商店、Quick Sell、双倍金币、Game Pass和Developer Product收据。具体商品能力仍由背包、工具或其他功能拥有。

## 玩家流程

玩家回收背包叶子或兑换携带失物获得金币，也可在购买台或Area_02～08区域门消费金币，或打开Robux购买框。普通失物和便便都按玩家最新叶价倍率估值并进入Double Coins可加倍金额；制造便便的50金币费用保持固定。Quick Sell在拥有权限时远程结算同一批内容；双倍金币拥有者获得统一倍率，并在本地隐藏区域购买牌。

## 服务端权威

`EconomyService`是金币修改入口；`AreaDoorService`只在顺序、Area01到目标前一区的正式清理进度和余额校验通过后调用`TrySpend`，并以请求锁保证同一门不会重复扣款；`RecycleService`和`QuickSellService`复用正式估值与来源分账；商品收据和所有权继续保持幂等。

## 客户端表现

正向金币动画由`CoinGainEvent`驱动；区域门成功消费由`CoinSpendEvent`同时驱动`CoinsFrame["+Value"]`负数脉冲和本地世界金币飞向门的表现。每枚抵达复用HUD的`SoundService.Recycle`对象池；表现失败不能回滚或重复执行真实消费。余额不足固定显示`You need <price> Coins.`，只有ResetCoin资格成立时才追加重置引导。

## 数据流

Prompt/门碰撞/UI请求 -> 服务端资格、价格和余额校验 -> 原子扣费/结算 -> 状态与收据保存 -> 快照和金币事件 -> HUD、门及购买台刷新。升级面板Player页三张背包卡的`RequestBagPurchase`只携带支付类型和目标ID，价格、下一等级、扩容资格及权益均由服务端重算。Marketplace回调不能直接相信客户端“购买成功”信号。

## 配置

金币上限来自`PlayerAttributeConfig`，商品ID和类型来自`ProductConfig`及相关功能Config，区域门价格来自`AreaUnlockConfig`，显示统一使用`CoinFormat`。重生次数对金币商品采用独立曲线：工具与普通属性升级为`1.5^次数`，区域门为`2^次数`；普通背包、扩容、Developer Product、Game Pass和SKIP的Robux价格不套用这些倍率。双倍、Quick Sell和世界Game Pass ID继续以源码配置为准。

## Remote

`RequestQuickSell`客户端到服务端请求权威批量结算；Player页背包卡的`RequestBagPurchase`归背包功能，本功能提供其扣费和Marketplace处理；`CoinGainEvent`服务端到客户端播放带来源的正向金币反馈；`CoinSpendEvent`只在服务端确认区域门购买后发送正整数`Amount`、扣款后`TargetCoins`、`Reason="AreaUnlock"`和`TargetAreaId`。门价不足建议事件归区域推进功能，经济功能只保证原短价格提示仍先显示。Robux购买使用Roblox Marketplace接口和服务端收据，不新增自定义购买成功Remote。

## 快照字段

`Coins`、`DoubleCoinsOwned`、`DoubleCoinsOwnershipReady`、`CoinRewardMultiplier`、`QuickSellOwned`、`QuickSellOwnershipReady`。

## 永久字段与重置

本功能拥有主存档`Coins`。Game Pass由Roblox所有权恢复，永久Developer Product由独立权益和收据账本恢复；普通Rebirth重置本轮金币，完整清档遵守清档与Robux恢复策略。

## Studio契约

回收和商店见`大厅与八区域通用回收对象`，世界购买台见`Area_01专用玩法对象`及`Prompt与代码职责`，HUD购买入口见`StarterGui契约`。大厅回收和失物商店使用`Workspace["大厅装扮"]`。

## 依赖功能

依赖`persistence-reset`、`bags-capacity`、`lost-items`和`tools-upgrades`；社区、好友奖励、抛硬币和排行榜也使用经济入口。

## 不变量

- 所有金币修改必须经过服务端sanitize和统一事件。
- 重复Prompt、收据或Remote不能重复扣费或发奖。
- Player页背包金币升级余额不足时只显示原不足提示，不自动打开Robux购买框。
- `CoinSpendEvent`只负责表现，客户端收到事件不能再次扣款或解锁区域。
- Quick Sell与实体回收必须使用同一估值、倍率和来源分账。
- 本地隐藏购买台不能改变其他玩家或服务器共享实例。
- 赚取金币、角色死亡和普通HUD刷新不得清除已登记的门价建议。

## 修改影响

改变倍率、结算或商品类型时检查叶子、失物、背包来源分账、好友奖励、教程漏斗、购买提示和收据迁移。新增世界入口需支持缺失与Streaming。

## 最小回归清单

- [ ] 大厅及Area_01～08回收/商店成功、空内容和并发路径正确。
- [ ] 金币购买、区域门、Game Pass、Developer Product重复触发均保持幂等。
- [ ] 工具/升级与区域门分别按`1.5^RebirthCount`和`2^RebirthCount`显示并扣费，背包与Robux价格保持基础规则。
- [ ] 区域门成功扣款显示准确负数并同步权威余额，同时只播放一次10～30枚世界金币序列；失败时不显示任何扣款动画。
- [ ] 门价不足短提示先显示，结束后常驻建议恢复；成功区域重置、Rebirth或完整测试重置后不再恢复。
- [ ] 双倍金币和Quick Sell拥有/未拥有玩家在同服互不影响视觉与结算。

## 合作副本边界

局内金币商品仍真实扣除主档Coins，但普通工具、背包、扩容和升级只进入合作运行态。回收与Double Coins照常；合作排行只统计叶子背包和即时回收实际到账Coins，不混入幸运物兑换额。

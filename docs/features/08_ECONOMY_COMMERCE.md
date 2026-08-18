# 经济、购买台、回收与商业化

## 目标与边界

统一金币增减、购买台、叶子回收、失物商店、Quick Sell、双倍金币、Game Pass和Developer Product收据。具体商品能力仍由背包、工具或其他功能拥有。

## 玩家流程

玩家回收背包叶子或兑换携带失物获得金币，也可在购买台或Area_02～08区域门消费金币，或打开Robux购买框。Quick Sell在拥有权限时远程结算同一批内容；双倍金币拥有者获得统一倍率，并在本地隐藏区域购买牌。

## 服务端权威

`EconomyService`是金币修改入口；`AreaDoorService`只在顺序和清理条件通过后调用`TrySpend`，并以请求锁保证同一门不会重复扣款；`RecycleService`和`QuickSellService`复用正式估值与来源分账；`ProductService`绑定Area_01～08的包/工具购买台；`DeveloperProductService`和Game Pass服务验证收据或所有权并保持幂等。

## 客户端表现

正向金币动画由`CoinGainEvent`驱动；区域门成功消费由`CoinSpendEvent`驱动`CoinsFrame["+Value"]`负数脉冲。`DoubleCoinsButtonController`让HUD按钮和可选`Area_XX.Sign.Sign.SurfaceGui.TextButton`共用购买锁；拥有者只在自己客户端隐藏整个区域Sign。价格、Prompt和世界台按权威快照更新。

## 数据流

Prompt/门碰撞/UI请求 -> 服务端资格、价格和余额校验 -> 原子扣费/结算 -> 状态与收据保存 -> 快照和金币事件 -> HUD、门及购买台刷新。Marketplace回调不能直接相信客户端“购买成功”信号。

## 配置

金币上限来自`PlayerAttributeConfig`，商品ID和类型来自`ProductConfig`及相关功能Config，区域门价格来自`AreaUnlockConfig`，显示统一使用`CoinFormat`。双倍、Quick Sell和世界Game Pass ID继续以源码配置为准。

## Remote

`RequestQuickSell`客户端到服务端请求权威批量结算；`CoinGainEvent`服务端到客户端播放带来源的正向金币反馈；`CoinSpendEvent`只在服务端确认区域门购买后发送正整数`Amount`、扣款后`TargetCoins`、`Reason="AreaUnlock"`和`TargetAreaId`。Robux购买使用Roblox Marketplace接口和服务端收据，不新增自定义购买成功Remote。

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
- `CoinSpendEvent`只负责表现，客户端收到事件不能再次扣款或解锁区域。
- Quick Sell与实体回收必须使用同一估值、倍率和来源分账。
- 本地隐藏购买台不能改变其他玩家或服务器共享实例。

## 修改影响

改变倍率、结算或商品类型时检查叶子、失物、背包来源分账、好友奖励、教程漏斗、购买提示和收据迁移。新增世界入口需支持缺失与Streaming。

## 最小回归清单

- [ ] 大厅及Area_01～08回收/商店成功、空内容和并发路径正确。
- [ ] 金币购买、区域门、Game Pass、Developer Product重复触发均保持幂等。
- [ ] 区域门成功扣款显示准确负数并同步权威余额，失败时不显示扣款动画。
- [ ] 双倍金币和Quick Sell拥有/未拥有玩家在同服互不影响视觉与结算。

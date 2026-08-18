# 区域推进、门、空气墙与重生

## 目标与边界

负责Area_01～Area_08的顺序推进、门碰触解锁、当前客户端空气墙、本轮完成资格和普通/SKIP Rebirth。Area_09仅保留存档兼容，不参与当前运行。

## 玩家流程

玩家从Area_01开始，清完所有前置区域后由引导到门前并支付金币解锁下一域；Area_02～08都使用金币门价，不再使用最低Rebirth次数。完成基础区域及本轮主动解锁区域，或达到彩虹便便条件后，可普通Rebirth；SKIP购买只跳过资格，不改变重置结果。

## 服务端权威

`AreaDoorService`校验自己庭院、解锁顺序、所有前置区域完成状态和权威余额，通过`EconomyService`扣除当前门价后才写`UnlockedAreas`；同一玩家的门请求串行处理，重复碰撞不能重复扣款。`RebirthService`计算资格并调用`PlayerDataService.ResetForRebirth`。客户端碰撞和面板都不能直接扣款、写`UnlockedAreas`或执行重置。

## 客户端表现

`AreaDoorController`在每个活动门的金币价格牌显示当前轮次真实价格，并显示门状态和引导；`AirWallController`按个人快照递归关闭`AirWall["2"]～["8"]`碰撞并在Rebirth后恢复Studio原值，`RebirthController`显示权威资格和倍率。成功扣款通过`CoinSpendEvent`让HUD显示负数脉冲，失败请求不播放。

## 数据流

叶子完成状态与Rebirth次数 -> 玩家碰门 -> 服务端计算门价并原子扣款/解锁 -> `CoinSpendEvent`与快照 -> 门、空气墙、HUD和引导刷新；请求Rebirth继续使用独立权威资格与重置事务。

## 配置

区域数量、顺序和最终区域来自`RegionConfig`；Area_02～08基础门价来自`AreaUnlockConfig`。当前门价为`BaseUnlockPrice × RebirthConfig.GetLeafCountMultiplier(RebirthCount)`，即每次Rebirth增加基础价的50%；彩虹便便要求和其他倍率仍来自`RebirthConfig`。

## Remote

`RequestAreaUnlock`客户端到服务端请求碰门解锁；`CoinSpendEvent`只在权威门购买成功后发送`Amount/TargetCoins/Reason/TargetAreaId`；`AreaCompletionNotice`服务端发送完成反馈；`RequestRebirth`处理普通入口，SKIP收据最终复用同一重置逻辑。

## 快照字段

`UnlockedAreas`、`AreaId`、`CurrentAreaId`、`RebirthLeafValueMultiplier`、`RebirthCount`、`RebirthEligible`、`RainbowPoopFoundCount`、`RainbowPoopRequiredCount`、`LeafCountMultiplier`。

## 永久字段与重置

`UnlockedAreas`、`ProcessedSkipRebirthReceiptIds`、`RebirthCount`、`RainbowPoopFoundCount`。Rebirth后只恢复Area_01并增加次数；收据幂等历史和文档明确的永久成长继续保留，完整清档按清档策略重置。

## Studio契约

精确结构见`Workspace区域结构`、`区域门`和`StarterGui契约`。核心入口为`Workspace.Area_XX`、`Workspace.AirWall["2"]～["8"]`和`GameHUD.Frame.Rebirth`。

## 依赖功能

依赖`persistence-reset`、`leaves-cleaning`和`poop-lobby`；教程、HUD、购买提醒和庭院访问会消费区域状态。

## 不变量

- 解锁必须连续，不能从客户端提交任意区域跳级。
- Area_02～08必须清完所有前置区域并成功扣除当前轮次门价；重复或失败请求不得扣款。
- 空气墙只改当前客户端并恢复每个Part的Studio原始`CanCollide`。
- 角色死亡不重锁空气墙；只有游戏内Rebirth改变区域进度。
- 普通与SKIP Rebirth除资格来源外使用同一重置事务。
- Lobby共享钱币不属于任何Area，不改变区域清理、开门或Rebirth资格。

## 修改影响

改变区域数量需同步RegionConfig、门、空气墙、叶子、失物、HUD、存档过滤和验收。改变Rebirth保留边界需逐项审计全部36个主存档字段。

## 最小回归清单

- [ ] Area_02～08按顺序付费解锁，价格随Rebirth次数刷新，未满足条件时服务端拒绝且不扣款。
- [ ] Door03/Door04/Door07重复入口显示同价、只收费一次；Streaming重载后价格牌与门状态恢复。
- [ ] 两名不同进度玩家的空气墙互不影响。
- [ ] 死亡不重锁，普通和SKIP Rebirth后墙体及进度正确恢复。

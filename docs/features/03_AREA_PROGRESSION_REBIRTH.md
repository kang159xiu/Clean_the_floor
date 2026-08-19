# 区域推进、门、空气墙与重生

## 目标与边界

负责Area_01～Area_08的顺序推进、门碰触解锁、当前客户端空气墙、本轮完成资格和普通/SKIP Rebirth。Area_09仅保留存档兼容，不参与当前运行。

## 玩家流程

玩家从Area_01开始；解锁Area N前，Area01到Area(N-1)的正式清理进度必须全部达到100%、前一区域已解锁且金币足够。通过后按顺序支付金币解锁下一域，不使用最低Rebirth次数或“重生自动开门”。购买后目标区域立即成为正式可收取区域，下一锁定区域只显示预览。金币不足时提示`You need <price> Coins.`；若全部已解锁区域已清完且权威状态允许重置区域钱币，引导线再转向`Workspace.Function.Reset`。普通Rebirth满足本轮金币要求或彩虹便便要求任一项即可，SKIP购买只跳过资格，不改变重置结果。

## 服务端权威

`AreaDoorService`校验玩家自己的庭院、解锁顺序、Area01到目标前一区的正式`ClearedRatio`和权威余额；只有全部清理条件通过后才调用`EconomyService`扣除当前门价并写`UnlockedAreas`。同一玩家的门请求串行处理，未清完、余额不足和重复碰撞都不能重复扣款。只有服务端确认全部当前已解锁区域清完且余额不足的失败分支才发送Reset建议事件。`RebirthService`按金币与彩虹便便的OR关系计算资格并调用`PlayerDataService.ResetForRebirth`。客户端碰撞、飞行动画和面板都不能直接扣款、写`UnlockedAreas`或执行重置。

## 客户端表现

`AreaDoorController`在每个活动门显示当前轮次真实价格；权威扣款成功后，使用独立对象池从玩家身边向实际碰撞门飞出10～30个`tishi`金币，每个显示完整负门价并以`alpha²`位移逐渐加速。每枚到达时让可见`MB01/MB02`放大到1.08倍并复用回收音效，最后一次脉冲结束后才打开全部同目标门副本。收到合法金币不足事件且可重置时，现有Beam转向`Workspace.Function.Reset`。`RebirthController`显示权威金币/便便条件、金币比例和倍率；HUD仍通过同一`CoinSpendEvent`显示负数扣款脉冲。

## 数据流

正式区域进度、金币与Rebirth次数 -> 玩家碰门 -> 服务端依次校验顺序、累计清理条件并原子扣款/解锁；余额不足时通知真实门价并按需读取ResetCoin状态；成功时`CoinSpendEvent`同时驱动HUD扣款和本地世界飞行动画，快照驱动正式区域、空气墙和门状态。Rebirth请求按`Coins >= RequiredCoins OR RainbowPoopFound >= RequiredPoop`重新校验后进入统一重置事务。

## 配置

区域数量与顺序来自`RegionConfig`；Area_02～08基础门价来自`AreaUnlockConfig`。当前门价为`round(BaseUnlockPrice × 2 ^ RebirthCount)`，每轮都从原始基础价完整计算后四舍五入。门飞行数量按实际门价在10～14500区间使用平方根曲线平滑映射到10～30个，超过上限仍为30个。普通Rebirth金币要求为`round(500 × 2.5 ^ RebirthCount)`，0～4次依次为500/1250/3125/7813/19531；彩虹便便要求为`(RebirthCount + 1) × 5`。面板分别显示`Money RequiredCoins`和`find X/Y`，服务端拒绝提示组合为`Money RequiredCoins or find X/Y`。重生叶价倍率为`RebirthCount + 1`，即0/1/2/3次分别为x1/x2/x3/x4。

## Remote

`RequestAreaUnlock`客户端到服务端请求碰门解锁；`CoinSpendEvent`只在权威门购买成功后发送`Amount/TargetCoins/Reason/TargetAreaId`，客户端不得据此再次扣款；`AreaDoorCoinShortageNotice`只在全部已解锁区域清完且权威余额不足时发送Reset建议状态；`RequestRebirth`处理普通入口，SKIP收据最终复用同一重置逻辑。

## 快照字段

`UnlockedAreas`、`AreaId`、`CurrentAreaId`、`RebirthLeafValueMultiplier`、`RebirthCount`、`RebirthEligible`、`RebirthRequiredCoins`、`RainbowPoopFoundCount`、`RainbowPoopRequiredCount`、`LeafCountMultiplier`。

## 永久字段与重置

`UnlockedAreas`、`ProcessedSkipRebirthReceiptIds`、`RebirthCount`、`RainbowPoopFoundCount`。Rebirth后只恢复Area_01并增加次数；收据幂等历史和文档明确的永久成长继续保留，完整清档按清档策略重置。

## Studio契约

精确结构见`Workspace区域结构`、`区域门`和`StarterGui契约`。核心入口为`Workspace.Area_XX`、`Workspace.AirWall["2"]～["8"]`和`GameHUD.Frame.Rebirth`。

## 依赖功能

依赖`persistence-reset`、`leaves-cleaning`和`poop-lobby`；教程、HUD、购买提醒和庭院访问会消费区域状态。

## 不变量

- 解锁必须连续，不能从客户端提交任意区域跳级。
- 解锁Area N必须让Area01到Area(N-1)的正式`ClearedRatio`全部达到1、前一区域已解锁并成功扣除当前轮次门价；ResetCoin、Lobby与Coop钱币不能满足普通门清理条件，重复或失败请求不得扣款。
- Reset常驻建议与Beam只能由“全部已解锁区域清完且余额不足”的权威事件登记；已有ResetCoin时只提示先收完，不得引导回Reset台。
- 到达Reset Prompt、门成功购买、资格失效、普通/SKIP Rebirth或完整清档后必须清除短缺引导；普通死亡只重建仍有效的Reset Beam。
- 空气墙只改当前客户端并恢复每个Part的Studio原始`CanCollide`。
- 角色死亡不重锁空气墙；只有游戏内Rebirth改变区域进度。
- Rebirth次数分别按门价`2^次数`和金币要求`2.5^次数`生效，不能直接解锁门或跳过金币；两条价格曲线不得复用叶量倍率。
- `RebirthLeafValueMultiplier`必须始终等于`RebirthCount + 1`；重生面板当前值、下一值与服务端奖励结算必须读取同一共享公式。
- 普通Rebirth只检查本轮金币或彩虹便便条件，不读取区域清理状态；金币只作门槛，成功后由统一重置事务归零。
- `CoinSpendEvent`、世界金币动画和门脉冲只作表现；模板缺失、死亡或Streaming中断必须立即回到权威门状态。
- 普通与SKIP Rebirth除资格来源外使用同一重置事务。
- Lobby共享钱币不属于任何Area，不改变区域清理、开门或Rebirth资格。

## 修改影响

改变区域数量需同步RegionConfig、门、空气墙、叶子、失物、HUD、存档过滤和验收。改变Rebirth保留边界需逐项审计全部35个主存档字段。

## 最小回归清单

- [ ] Area_02～08只有在Area01到目标前一区全部正式清完后才可按顺序付费解锁；任一区域未完成都拒绝且不扣款，0/1/2次Rebirth门价为原始基础价的1/2/4倍。
- [ ] 已清完全部已解锁区域且下一门金币不足时，可重置则只显示`Reset cleared areas to earn more Coins.`并将唯一Beam指向`Workspace.Function.Reset`；已有ResetCoin则只提示先收完。
- [ ] 全部已解锁区域清完且门价不足时短提示结束后恢复常驻建议；清理未完成、前区未解锁和重复碰门不登记建议。
- [ ] Door03/Door04/Door07重复入口显示同价、只收费一次；Streaming重载后价格牌与门状态恢复。
- [ ] 两名不同进度玩家的空气墙互不影响。
- [ ] 0/1/2/3/4次Rebirth要求500/1250/3125/7813/19531金币；`monexplain`、`explain`、进度条、组合失败提示和权威资格一致，金币和彩虹便便条件独立按OR生效。
- [ ] 0/1/2/3/4次Rebirth的当前叶价倍率为x1/x2/x3/x4/x5，面板下一倍率始终比当前高x1。
- [ ] 10～30个门金币显示`-总价`和指定金币图片，每枚由慢到快抵达并播放回收音效/门脉冲，最后一次脉冲后才开门；失败请求不生成表现。
- [ ] 死亡不重锁，普通和SKIP Rebirth后墙体及进度正确恢复。

## 合作副本边界

合作局只使用Area01–08：初始Area01，清完当前区域后把下一Area写入所有在线成员的临时`UnlockedAreas`并直接开门，不扣Coins；隐藏门价且不接受门购买、Rebirth或ResetCoin请求。合作Area08完成不提交单人ClearSpeedrun。

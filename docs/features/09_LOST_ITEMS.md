# 失物、幸运箱、图鉴与揭晓

## 目标与边界

管理普通失物计划、五级幸运箱、定时箱、世界投影、权威拾取、揭晓、会话库存、兑换、图鉴和首次获得提示。便便失物的生成事务归大便功能。

## 玩家流程

玩家清扫到计划节点后看到对应等级幸运箱，打开后在箱子原位置播放候选揭晓和最终展示，再飞向玩家并加入快捷栏。首次成功入库的普通失物在飞行结束后显示`NEW!`。携带物可在来源区、大厅或最近有效商店兑换。

## 服务端权威

`LostItemService`拥有计划Seed、箱子等级、最终ID、拾取锁、RevealId、授予时序、会话堆叠、图鉴计数和兑换。客户端不提前知道地面箱最终物品，动画结束也不能自行增加库存。

## 客户端表现

`LocalLostItemController`按共享时序播放候选、价值牌和抛物线飞行；距离胸口目标大于2 studs保持完整尺寸，进入2 studs后只单向缩小。`LostItemGuidanceController`按来源、解锁和距离选择商店，支持大厅与Streaming。

## 数据流

区域清扫进度/定时器 -> 服务端计划和地面描述 -> 客户端箱子投影 -> 拾取Remote -> 权威RevealId与结果 -> `LostItemRevealStarted` -> 本地动画；服务端提交库存后发送`LostItemRevealCompleted`和快照 -> 动画与成功结果会合后显示NEW。

## 配置

概率、等级、模板、价值、Reveal时序、`FlyShrinkDistance`和总时长由`LostItemConfig`提供；概率验证复用`LostItemProbabilityValidation`。

## Remote

`RequestLostItemPickup`客户端请求权威拾取；`LostItemRevealStarted`发送RevealId、结果和原点；`LostItemRevealCompleted`确认入库成功及最终IsNew；`ClaimCodexReward`处理图鉴奖励。

## 快照字段

`AreaLostItemsFound`、`AreaLostItemsTotal`、`AreaFoundLostItems`、`PersonalWorldLostItems`、`CarriedLostItem`、`CollectibleInventoryCounts`、`CollectibleInventoryTotal`、`TimedLuckyBoxNextSpawnAt`、`TimedLuckyBoxWaitingForPickup`、`TimedLuckyBoxRewardKind`、`LostItemCollectedCounts`、`CodexClaimedTiers`。

## 永久字段与重置

`LostItemRunProgress`、`LuckyBoxOnboarding`、`CollectedCounts`、`CodexClaimedTiers`。会话携带库存离服清除，但未完成普通计划和待领取定时箱按字段恢复；Rebirth按既定规则重建本轮计划并保留图鉴与首次奖励状态，完整清档重置。

## Studio契约

模板见`失物模板`，商店见`大厅与八区域通用回收对象`，Beam见`丢失物兑换引导`，图鉴与`GetDiamond`见`StarterGui契约`。大厅入口为`Workspace["大厅装扮"].LostItemShop`。

## 依赖功能

依赖`leaves-cleaning`、`economy-commerce`和`hud-camera`；大便、教程、区域引导、Quick Sell和重生资格消费其结果。

## 不变量

- 最终ID、IsNew、价值和库存提交只由服务端决定。
- 揭晓时序服务端与客户端共用同一Config接口。
- `NEW!`必须同时等待本地结束及`Succeeded=true/IsNew=true`，重复事件只显示一次。
- 观察者只看世界揭晓，不获得开启者库存或首次提示。
- `LeafConfig.Lobby.AreaId`的共享钱币拾取不参与普通幸运箱进度或落点记录。

## 修改影响

修改揭晓时序需同步服务端授予等待、客户端清理、角色失效和验收。修改库存/兑换需检查快捷栏堆叠、图鉴、Quick Sell、商店引导、便便和持久计划。

## 最小回归清单

- [ ] 首次、重复、失败、死亡和离服揭晓路径无重复授予。
- [ ] 超过/进入2 studs时尺寸规则及到达后NEW时序正确。
- [ ] 大厅和已解锁区域商店选择、兑换和Streaming恢复正确。

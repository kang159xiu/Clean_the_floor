# 失物、幸运箱、图鉴与揭晓

## 目标与边界

管理每200片叶子的幸运箱判定、五级箱子、定时箱、世界投影、权威拾取、并行揭晓、会话库存、兑换、图鉴和首次获得提示。便便失物的生成事务归大便功能。

## 玩家流程

每个正式区域和每轮ResetCoin各自每收取200片进行一次独立5%判定，成功时在触发玩家周围生成对应区域等级箱子；Lobby不参与。玩家可连续打开多个箱子，各自在原箱位置并行播放候选揭晓和最终展示，完整尺寸飞向玩家后才加入快捷栏。首次成功入库的普通失物在飞行结束后显示`NEW!`。携带物可在来源区、大厅或最近有效商店兑换。

## 服务端权威

`LostItemService`拥有检查点基线与会话计数、箱子等级、最终ID、单箱拾取锁、RevealId、并行待授予表、授予时序、会话堆叠、图鉴计数和兑换。客户端不提前知道地面箱最终物品，动画结束也不能自行增加库存；合法SpawnId上限统一为128字符。

## 客户端表现

`LocalLostItemController`按RevealId独立播放候选、价值牌和抛物线飞行，飞行全程保持完整尺寸；每个地面箱仅用自己的`PickupPending`防重复请求，不再使用全局等待或`Wait (xN)`提示。`LostItemGuidanceController`按来源、解锁和距离选择商店，支持大厅与Streaming。

## 数据流

区域或ResetCoin收取数跨过200倍数/定时器 -> 服务端独立5%判定和会话地面描述 -> 客户端箱子投影 -> 拾取Remote -> 权威RevealId与结果 -> `LostItemRevealStarted` -> 多组本地动画；各自总时长结束后服务端独立提交库存并发送`LostItemRevealCompleted`和快照 -> 动画与成功结果会合后显示NEW。

## 配置

200片间隔、5%概率、等级、模板、价值、0.5秒最终停留、0.65秒飞行和总时长由`LostItemConfig`提供；概率验证复用`LostItemProbabilityValidation`。定时箱首次180秒、后续300秒且每次新服务器会话重新计时。

## Remote

`RequestLostItemPickup`客户端请求权威拾取；`LostItemRevealStarted`发送RevealId、结果和原点；`LostItemRevealCompleted`确认入库成功及最终IsNew；`ClaimCodexReward`处理图鉴奖励。

## 快照字段

`AreaLostItemsFound`、`AreaLostItemsTotal`、`AreaFoundLostItems`、`PersonalWorldLostItems`、`CarriedLostItem`、`CollectibleInventoryCounts`、`CollectibleInventoryTotal`、`TimedLuckyBoxNextSpawnAt`、`TimedLuckyBoxWaitingForPickup`、`TimedLuckyBoxRewardKind`、`LostItemCollectedCounts`、`CodexClaimedTiers`。

## 永久字段与重置

`LuckyBoxOnboarding`、`CollectedCounts`、`CodexClaimedTiers`。普通/定时未打开箱、检查点、位置、待揭晓和携带库存都只属于服务器会话，离服不恢复；Schema 33忽略旧`LostItemRunProgress`并在下次保存清除。首次定时高等级奖励的历史字段只在物品实际成功入库后标记；Rebirth保留图鉴与首次奖励状态，完整清档重置。

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
- 每个Area的正式进度和每轮ResetCoin使用独立检查点流；加入时以正式区当前`floor(Collected/200)`为基线，不补抽旧档位。
- 未打开箱和未来判定不得写DataStore；同一SpawnId最多授予一次，不同RevealId互不阻塞。

## 修改影响

修改揭晓时序需同步服务端授予等待、客户端清理、角色失效和验收。修改库存/兑换需检查快捷栏堆叠、图鉴、Quick Sell、商店引导、便便和会话清理。

## 最小回归清单

- [ ] 199片不判定，200/400片各判定一次且大样本成功率接近5%；Lobby不计，ResetCoin按轮次独立计。
- [ ] 多箱立即并行揭晓；首次、重复、失败、死亡、Rebirth和离服路径无重复授予或残留待处理记录。
- [ ] 最终物停留0.5秒、完整尺寸飞行0.65秒，到达后快捷栏和NEW时序正确。
- [ ] 大厅和已解锁区域商店选择、兑换和Streaming恢复正确。

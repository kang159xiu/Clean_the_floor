# 市场参考与数据指标

> 数据快照日期：2026-07-15。以下公开数据只保留为立项历史参考，不代表当前实时平台数据。

## 历史参考

| 游戏 | 当时CCU | 平均时长 | 点赞率 |
|---|---:|---:|---:|
| Clean the Squishies | 23,566 | 8.3分钟 | 91.4% |
| Clean the Supermarket | 11,883 | 17.4分钟 | 93.1% |
| Clean The Library | 8,259 | 22.8分钟 | 92.2% |
| Cut Grass for Anime Characters | 815 | 12.9分钟 | 98.0% |
| Grass Incremental Simulator | 718 | 14.3分钟 | 96.3% |
| Cut Grass for Brainrots | 408 | 10.7分钟 | 90.7% |

`Drain the Lake`在当时约5.1万CCU、平均时长约14.26分钟、点赞率约96.33%。项目借鉴的是“收集资源→容器装满→固定位置倾倒→获得代币→升级效率→世界发生变化”的结构，而不是题材或美术。

阶段1已证明基础交互能够运行，验收点A已经通过。阶段2不再以“是否制作多区域”为问题，而是验证现有八区域、三工具和经济系统能否形成完整单人体验。

## 验收B分析事件

`PlaytestMetricsService`已接入服务端确认的测试记录。Studio使用`[CleanTheFloorMetrics]`前缀输出，正式服务器使用`AnalyticsService:LogCustomEvent`上报`ctf_b_*`：

- `run_start/run_exit/run_complete`：会话开始、退出点和Area_08完成。
- `first_leaf/first_bag_full/recycle`：首片、首次袋满和每次回收。
- `purchase`：袋子、工具解锁和属性升级的种类、ID、价格和区域。
- `area_entered/area_progress/area_unlocked`：区域切换、25/50/75/100%里程碑和门解锁。
- `tool_summary`：退出时按工具上报有效使用时长、动作数和影响叶子数。
- `lost_plan/lost_spawned/lost_found/lost_redeemed`：失物数量、出现进度、稀有度、拾取和兑换。

事件只能上报服务端确认的状态，不上传完整DataStore内容或用户输入文本。

`area_unlocked`继续由服务端记录，`UnlockMethod`固定为`AreaCleared`。已移除`key_spawned`、`key_collected`、`key_consumed`及KeyId字段。

## Roblox正式新手漏斗

Schema 20之后自然首次创建存档的玩家同时进入Roblox Onboarding Funnel；老档和完整清档不补发。服务端只在权威成功结果后严格按顺序调用`AnalyticsService:LogOnboardingFunnelStepEvent`：

1. `Enter Game`
2. `Collect First Leaf`
3. `Collect 15 Leaves`
4. `Recycle Leaves for the First Time`
5. `Upgrade Pickup Amount for the First Time`
6. `Upgrade Pickup Speed for the First Time`
7. `Upgrade Bag 1 to Bag 2`
8. `Unlock Area 2`
9. `Unlock Area 3`
10. `Purchase First Broom`

失败的收取、回收、升级、购买或开门请求不打点。永久背包、Developer Product背包及Robux Tool02不计入指定购买步骤。提前完成的后序条件会保留，前序完成后再连续补交，不跳步。Studio只输出`[CleanTheFloorOnboarding]`顺序日志；后台“分析 → 漏斗”的正式数据必须使用发布服务器和新账号验证。漏斗与步骤编号保持不变，新旧事件继续合并统计；已经上报的历史中文步骤标签无法由游戏代码改名，后续事件统一使用上述英文标签。

## 八区清理在线时间排行榜

场景排行榜展示账号历史最快的八区累计在线清理时间Top 20。计时从加入服务器开始，数据加载、教程、购买、菜单和AFK均计入；离服暂停，重进续计。只有庭院主人自己的`Area_08`完成会冻结该主人的本轮成绩，好友协助不会建立独立成绩。初始轮和每次重生均可挑战，主排行榜只通过服务端OrderedDataStore提交更快秒数，客户端不能上传成绩。

最快清扫排行榜与验收B的`run_complete`指标用途不同：排行榜允许跨多个在线会话累计，且展示账号历史最快；既有验收指标仍按其原始会话事件计算。最快清扫和永久在线时长统一显示`00m/1h05m`并舍去秒数，但名次按完整秒数决定。永久清理数量榜独立按服务端成功收取的叶子实体累计，不复用`run_complete`或BagValue指标。

## 验收点B目标

- 80%以上新玩家在90秒内完成首次回收。
- 70%以上新玩家在3分钟内完成第一次有效购买或升级。
- 完成玩家的八区中位通关时间为90～150分钟，并且至少50%有效测试者在单会话到达Area_08。
- 扫把购买中位时间30～45分钟，吹风机70～100分钟；购买者中至少60%有效使用超过30秒。
- 至少80%玩家能正确说明双手、扫把和吹风机的差异；同时拥有三种工具后，没有单一工具占超过75%有效输入时间。
- 至少70%玩家认为失物“有惊喜但不影响主要清理节奏”。

## 调整顺序

1. 首次回收率低：调整初始容量、叶子密度、回收距离和袋满反馈。
2. 购买率低：调整首个正式价格和收益，不用免费价格掩盖问题。
3. 工具使用率低：调整工具解锁时机、功能差异和升级反馈。
4. 单区完成率低：调整区域叶子数量、工具效率或路径距离。
5. 总时长异常：最后调整区域数量、经济跨度和失物节奏。

在分析事件上线并取得真实数据前，不根据历史市场数字宣称当前平衡已经成立。

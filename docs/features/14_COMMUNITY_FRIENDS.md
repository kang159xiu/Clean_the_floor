# 社区与好友奖励

## 目标与边界

负责官方社区会员奖励和好友庭院贡献产生的待领取奖励、贡献者显示及交易幂等。邀请和庭院切换本身归庭院功能，金币写入归经济功能。

## 玩家流程

玩家点击社区入口后使用Roblox加入群组流程，服务端确认会员后发放一次奖励并隐藏个人按钮。好友在庭院产生符合规则的贡献后，主人可查看贡献者并领取待奖励。

## 服务端权威

`CommunityService`调用Roblox会员API验证，不相信客户端加入结果。好友奖励由庭院/玩家数据服务记录唯一交易ID、待发放金额和贡献者，领取时再通过经济入口结算。

## 客户端表现

`CommunityController`处理加入提示、有限重试、领取提示和个人按钮隐藏。好友奖励UI只展示快照中的待领取总额和贡献者，不自行汇总世界行为。

## 数据流

社区按钮 -> Roblox Prompt -> `ClaimCommunityReward` -> 服务端会员检查 -> 持久标记与金币；好友贡献 -> 服务端生成幂等delivery -> 主人快照 -> `ClaimFriendRewards` -> 原子领取并保存处理ID。

## 配置

社区Group ID和奖励来自`CommunityConfig`。好友奖励规则由权威庭院/数据服务定义，显示金额使用统一金币格式。

## Remote

`ClaimCommunityReward`验证并领取社区奖励；`ClaimFriendRewards`领取当前待好友奖励。两者均为客户端到服务端RemoteFunction并返回明确状态。

## 快照字段

`CommunityRewardClaimed`、`PendingFriendRewardTotal`、`PendingFriendRewardContributors`。

## 永久字段与重置

`CommunityRewardClaimed`、`PendingFriendRewards`、`ProcessedFriendRewardIds`、`PendingFriendDeliveries`。死亡、离服和普通Rebirth保留；完整清档按当前策略允许重新领取社区奖励并清除好友待处理数据。

## Studio契约

入口和奖励UI见`StarterGui契约`，社区按钮路径为`GameHUD.HUDRoot.jiaqun`。客户端只隐藏PlayerGui克隆，不修改StarterGui模板。

## 依赖功能

依赖`persistence-reset`、`economy-commerce`和`yards-visiting`。

## 不变量

- 社区奖励必须由服务端会员API确认且每个存档周期最多一次。
- 好友delivery和processed ID必须防止重进、重试和并发重复领取。
- 客户端显示金额不参与实际结算，倍率只能在服务端统一应用一次。

## 修改影响

修改奖励需检查经济倍率、通知、保存和清档；修改好友贡献需检查庭院主人归属、背包来源值、离线delivery和交易ID上限。

## 最小回归清单

- [ ] 未加入、刚加入、已加入和API失败时社区奖励行为正确。
- [ ] 同一好友交易重复提交/领取只结算一次。
- [ ] 离线、重进、Rebirth和完整清档后的保留边界正确。

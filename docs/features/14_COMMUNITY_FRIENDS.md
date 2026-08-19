# 社区与好友奖励

## 目标与边界

负责官方社区会员奖励，以及退休好友庭院系统遗留的待领取奖励、贡献者显示与交易幂等。官方体验邀请归个人庭院功能，金币写入归经济功能。

## 玩家流程

玩家点击社区入口后使用Roblox加入群组流程，服务端确认会员后发放一次奖励并隐藏个人按钮。带有旧待领取好友奖励的玩家仍可查看贡献者并领取一次；普通个人庭院游玩不再产生新的好友贡献。

## 服务端权威

`CommunityService`调用Roblox会员API验证，不相信客户端加入结果。`PlayerDataService`继续兼容既有好友delivery、唯一交易ID、待发放金额和贡献者，领取时再通过经济入口结算；退休系统不会从新的庭院行为创建delivery。

## 客户端表现

`CommunityController`处理加入提示、有限重试、领取提示和个人按钮隐藏。独立`FriendRewardController`只使用`HUDRoot.Friendcollection`展示快照中的旧待领取总额和贡献者，不依赖旧庭院邀请UI或访客模板。

## 数据流

社区按钮 -> Roblox Prompt -> `ClaimCommunityReward` -> 服务端会员检查 -> 持久标记与金币；旧存档delivery恢复/重试 -> 玩家快照 -> `ClaimFriendRewards` -> 原子领取并保存处理ID。新的个人庭院结算只记录玩家自己的来源，不创建好友delivery。

## 配置

社区Group ID和奖励来自`CommunityConfig`。遗留好友奖励显示金额使用统一金币格式。

## Remote

`ClaimCommunityReward`验证并领取社区奖励；`ClaimFriendRewards`领取当前待好友奖励。两者均为客户端到服务端RemoteFunction并返回明确状态。

## 快照字段

`CommunityRewardClaimed`、`PendingFriendRewardTotal`、`PendingFriendRewardContributors`。

## 永久字段与重置

`CommunityRewardClaimed`、`PendingFriendRewards`、`ProcessedFriendRewardIds`、`PendingFriendDeliveries`。死亡、离服和普通Rebirth保留；完整清档按当前策略允许重新领取社区奖励并清除好友待处理数据。

## Studio契约

入口和奖励UI见`StarterGui契约`，社区按钮路径为`GameHUD.HUDRoot.jiaqun`。客户端只隐藏PlayerGui克隆，不修改StarterGui模板。

## 依赖功能

依赖`persistence-reset`和`economy-commerce`；`yards-visiting`保证新的个人庭院行为不会产生跨玩家来源。

## 不变量

- 社区奖励必须由服务端会员API确认且每个存档周期最多一次。
- 好友delivery和processed ID必须防止重进、重试和并发重复领取。
- 普通个人庭院游玩不得新建好友贡献；删除旧邀请UI或`ReplicatedStorage.frend`不得影响历史奖励领取。
- 客户端显示金额不参与实际结算，倍率只能在服务端统一应用一次。

## 修改影响

修改奖励需检查经济倍率、通知、保存和清档；修改好友贡献需检查庭院主人归属、背包来源值、离线delivery和交易ID上限。

## 最小回归清单

- [ ] 未加入、刚加入、已加入和API失败时社区奖励行为正确。
- [ ] 同一好友交易重复提交/领取只结算一次。
- [ ] 离线、重进、Rebirth和完整清档后的保留边界正确。
- [ ] 有旧奖励时`Friendcollection`正常显示和领取；无旧奖励时隐藏，普通游玩不会增加新金额。

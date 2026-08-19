# 个人庭院、官方邀请与返回出生点

## 目标与边界

管理普通模式下玩家自己的庭院上下文、Roblox官方体验邀请入口，以及把当前角色返回出生点。它不再提供好友庭院访问、访客权限或跨庭院共享；Coop共享世界由合作功能独立拥有。

## 玩家流程

大厅玩家点击`GameHUD.Frame.invite`后，客户端先确认当前平台可发送邀请，再打开Roblox官方邀请界面。被邀请好友从体验正常入口加入，始终进入自己的庭院。大厅和合作副本中的玩家点击`fanhui.Lobby`都只把当前角色移动回本Place的出生点，不改变存档、庭院或合作局状态。

## 服务端权威

`YardService`只为已加载玩家返回本人作为活动庭院Owner，`PlayerAreaService`维护玩家所处区域，`ReturnToSpawnService`在停止清扫和工具动作后把角色安全移动到唯一有效出生点。官方邀请属于Roblox原生客户端界面，不授予任何庭院或合作权限。

## 客户端表现

`OfficialInviteController`只在大厅启用`Frame.invite`，使用`CanSendGameInviteAsync()`、请求锁和`GameInvitePromptClosed`管理原生弹窗；Coop中隐藏按钮。`LobbyReturnController`在大厅与Coop都显示`fanhui.Lobby`，并在返回当前Place出生点前停止手动工具输入。旧`GameHUD.invite/accept`及访客模板可留在Studio，但运行时代码不查找它们。

## 数据流

大厅邀请按钮 -> Roblox `SocialService`能力检查 -> 官方邀请界面；好友接受后按平台正常加入流程进入体验。玩家状态Ready -> `YardService`固定Owner为本人 -> 快照、叶子、便便和失物按本人UserId隔离。返回按钮 -> `RequestReturnToSpawn` -> 服务端停止输入并移动角色。

## 配置

庭院本身无独立共享Config；大厅/Coop Place分流读取`CoopMatchConfig`。官方邀请不设置`ExperienceInviteOptions`或LaunchData。

## Remote

`RequestReturnToSpawn`由客户端请求、服务端校验角色与出生点并执行。官方邀请直接使用`SocialService`，不经过自定义Remote。旧`SendYardInvite/RespondYardInvite/YardInviteReceived/EnterYard/LeaveVisitedYard/SetPoopPermission`已退休。

## 快照字段

`HomeYardProgress`、`ActiveYardOwnerUserId`；后者在普通模式始终等于当前玩家UserId。

## 永久字段与重置

`YardProgress`永久保存；Rebirth按区域功能规则重建本轮进度。Schema 34退休`AllowGuestPoop`，旧值加载时忽略并在下次保存清除。不存在持久或会话访客关系。

## Studio契约

区域入口归入`Workspace区域结构`；官方邀请按钮、可选旧UI和返回按钮见`StarterGui契约`。本次不修改Studio实例。

## 依赖功能

依赖`platform-state`和`area-progression-rebirth`；叶子、大便、失物和工具输入读取个人庭院上下文，Coop使用自己的共享作用域。

## 不变量

- 普通模式的活动庭院Owner必须始终为玩家本人，任何好友加入都不能切换Owner或共享区域进度。
- 官方邀请不得携带庭院、队伍或副本LaunchData；Coop必须隐藏入口。
- 原生邀请请求同时最多一个，关闭、异常或超时恢复后可再次点击。
- 返回出生点必须停止当前清扫与工具动作，但不能重建角色、重置庭院或改变存档。

## 修改影响

改变个人庭院上下文会影响叶子描述、大便、失物、回收来源与当前区域HUD。修改邀请入口需同时回归大厅/Coop Place分流和旧UI缺失兼容。

## 最小回归清单

- [ ] 大厅点击`Frame.invite`只打开一次官方邀请界面，关闭后可再次点击；不可用时显示英文提示并恢复按钮。
- [ ] Coop隐藏邀请按钮；保留或删除旧庭院邀请UI/访客模板均不影响Bootstrap。
- [ ] 两名普通玩家各自只看到、收取和结算自己的庭院叶子、便便与失物，`ActiveYardOwnerUserId`始终为本人。
- [ ] 大厅与Coop的`fanhui.Lobby`都停止输入并正确移动到当前Place出生点，不修改庭院/合作进度、金币、背包或库存，也不触发跨Place返回。

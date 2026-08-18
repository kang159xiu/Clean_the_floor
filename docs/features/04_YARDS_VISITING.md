# 庭院访问、邀请与返回

## 目标与边界

管理玩家自己的庭院、好友访问、邀请响应、访客列表、允许制造大便权限，以及返回出生点/大厅时的上下文切换。

## 玩家流程

玩家可邀请在线好友进入自己的庭院；访客接受后切换到主人庭院，看到主人权威进度与共享世界对象，随后可退出访问或返回大厅。主人可以控制访客是否可制造大便。

## 服务端权威

`YardService`拥有当前庭院映射，`YardInviteService`校验邀请、过期、双方状态和奖励，`PlayerAreaService`维护玩家所处区域，`ReturnToSpawnService`负责安全结束当前交互并传送。

## 客户端表现

`YardUIController`管理邀请和访问界面，`VisitorBillboardController`显示访问者信息，`LobbyReturnController`在返回前停止工具、Automatic和局部HUD状态。

## 数据流

邀请Remote -> 服务端建立待邀请 -> 接受后切换庭院上下文 -> `PlayerDataService`快照使用主人区域状态 -> 叶子/大便增量按目标庭院同步 -> 退出时恢复自己庭院。

## 配置

庭院本身无独立共享Config；区域过滤继续读取`RegionConfig`，奖励和权限由相关服务常量与存档字段约束。

## Remote

拥有`SendYardInvite`、`RespondYardInvite`、`YardInviteReceived`、`EnterYard`、`LeaveVisitedYard`、`SetPoopPermission`和`RequestReturnToSpawn`。所有位置和权限变化由服务端确认。

## 快照字段

`AllowGuestPoop`、`HomeYardProgress`、`ActiveYardOwnerUserId`、`ActiveYardOwnerName`、`IsVisitingYard`、`ActiveYardVisitors`。

## 永久字段与重置

`AllowGuestPoop`和`YardProgress`永久保存。访问关系和当前被访问庭院是会话状态；离服、服务器关闭和完整清档会解除，Rebirth重建自己的本轮庭院进度。

## Studio契约

庭院和区域入口归入`Workspace区域结构`，访问与邀请UI归入`StarterGui契约`。`Workspace.Yards`和Lobby出生点的精确现场结构当前标记待Studio核验。

## 依赖功能

依赖`platform-state`和`area-progression-rebirth`；叶子、大便、好友奖励、失物和工具输入都读取当前庭院上下文。

## 不变量

- 访客不能修改自己的区域进度来替代主人进度。
- 任何庭院切换都必须停止旧工具输入和清理旧客户端投影。
- 邀请重复响应、过期或任一方离服必须安全失败。

## 修改影响

改变庭院上下文接口会影响叶子描述、大便共享、失物投影、回收结算、好友奖励和所有当前区域HUD。新增庭院世界对象必须说明主人/访客可见性。

## 最小回归清单

- [ ] 邀请、接受、拒绝、过期和离服路径无重复访问。
- [ ] 访客看到主人叶子、区域和大便状态，自己的存档不被覆盖。
- [ ] 退出访问和返回大厅后工具、相机、投影及HUD恢复。

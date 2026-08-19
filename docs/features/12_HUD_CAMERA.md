# HUD、模态界面、镜头与输入反馈

## 目标与边界

负责GameHUD渲染、通知、快捷栏视图、中央飞入效果、主面板互斥、模糊、开关动画和通用镜头状态。业务资格与数值仍由服务端快照和各功能Config决定。

## 玩家流程

玩家通过HUD查看金币、背包、工具、区域、图鉴和提示，区域门成功扣款时在`CoinsFrame["+Value"]`看到负数并伴随金币框脉冲；金币不足且可重置时常驻显示`Reset cleared areas to earn more Coins.`，到达Reset Prompt后清除。钱币逐片收取反馈改由叶子功能在世界原位置显示，HUD不再随机生成`GetHint`或把它飞向背包。升级/图鉴/Rebirth/区域钱币重置等主面板继续互斥；官方邀请按钮直接打开Roblox原生界面，不打开自定义模态面板。中央奖励提示播放后回收模板；特殊玩法临时控制镜头，结束后恢复正常输入。

## 服务端权威

本功能没有业务裁决。服务端只通过`StateSnapshot`和`Notification`发送权威内容，客户端不能根据按钮外观自行发奖、扣费或解锁。

## 客户端表现

`HUDController`是当前综合HUD门面，并按来源与数字优先级管理常驻通知；临时提示只覆盖显示，不删除各来源状态。个人历史金币倍率牌仅在权威`PersonalLeafValueMultiplier > 1`时显示，新档x1时隐藏整个`TrailMultiplierDisplay`；重生倍率牌继续独立显示。快捷栏由`ToolController`渲染，制造便便教程期间Tool05按钮以模板原缩放为基准持续放大脉冲。`ModalPanelCoordinator/Effects`处理互斥、模糊和动画；`CenterFlyUIEffect`保留为通用飞入效果，但不再负责钱币收取提示；`CameraController`维护常规镜头接口。

## 数据流

业务服务状态/事件 -> StateSnapshotStore、Notification或金币表现事件 -> HUD局部刷新；门消费事件先取消冲突的正向金币动画，再显示权威扣款后余额和短暂负数脉冲；入口按钮 -> Modal协调器 -> 正式打开/关闭回调；功能动画 -> CenterFly模板池 -> 完成回调恢复原始UI状态。

## 配置

时间显示复用`DurationFormat`，货币复用`CoinFormat`。具体图像、名称、倍率和价格来自所属功能Config，不在HUD重复定义。

## Remote

`Notification`由服务端向客户端发送普通权威提示；`CoinSpendEvent`只携带已完成区域门消费的表现数据，HUD不得据此执行扣款或解锁。`HUDController:PlayRecycleFeedbackSound()`只向门动画开放现有本地Recycle声音池，每枚门金币抵达时播放一次，不创建新的声音模板或Remote。

## 快照字段

无独占业务字段。HUD消费多个功能字段，字段所有权和修改影响由manifest查询。

## 永久字段与重置

无专用永久字段。面板、Tween、模糊、通知队列和镜头是客户端会话状态；角色重建或控制器关闭时必须恢复。

## Studio契约

完整层级见`StarterGui契约`与`SoundService契约`。运行时本地Blur使用`Lighting.LocalModalPanelBlur`，不得修改StarterGui模板作为个人状态。

## 依赖功能

直接依赖`platform-state`，并作为工具、背包、失物、教程、抛硬币、社区和区域功能的表现层。

## 不变量

- HUD只展示权威状态，不能成为余额、拥有权或完成资格来源。
- `HUDRoot.GetHint`必须保持隐藏，钱币收取提示不得再随机出现在屏幕或飞向背包。
- 区域门扣款提示必须使用`CoinSpendEvent.TargetCoins`同步余额，连续快照和正向金币动画不能留下错误的`+Value`文字或UIScale。
- 同一时刻最多一个主模态面板可见。
- 常驻提示按来源独立登记；清除教程、门建议或其他来源时不得连带清除其余来源。
- 取消Tween、目标失效和快速开关后必须恢复Studio原始位置、透明度和UIScale。
- 客户端个人显示不得写回StarterGui或影响同服玩家。
- 个人倍率牌显隐只读权威个人倍率，不得根据升级卡存在与否推导或改变旧存档奖励。

## 修改影响

修改HUDController公共方法需查询所有关联功能。修改模态或镜头需检查升级、图鉴、邀请、Rebirth、区域钱币重置和抛硬币；修改中央提示需检查金币、叶子提示与失物NEW。

## 最小回归清单

- [ ] 五个主面板互斥、切换、关闭和Blur恢复正确。
- [ ] 教程常驻提示优先于门建议，临时提示结束后恢复当前最高优先级来源。
- [ ] 快速重复操作、角色死亡和目标UI销毁无Tween/UIScale残留。
- [ ] 放大快捷栏模板后，制造便便教程的Tool05按钮仍有清晰脉冲，教程结束后恢复模板原始大小。
- [ ] HUD数值、通知和中央飞入不改变任何服务端状态。
- [ ] 新档个人倍率x1时隐藏整块`TrailMultiplierDisplay`；旧档个人倍率大于x1时显示正确值，重生倍率牌始终独立刷新。
- [ ] 收取钱币时HUD内没有`LeafGainHint`克隆，`GetDiamond`失物与金币中央提示保持不变。
- [ ] 区域门扣款时显示`-价格`并脉冲，失败请求、角色重建和后续金币收入不会留下负数或缩放残留。

## 合作副本边界

大厅`Team001`只在加入平台后显示，`plain.Value`显示`Auto confirming in %d s`，`esc`退出匹配。副本全程同时显示`fanhui.Lobby`与`fanhui.Return`：`Lobby`只回当前副本Place的出生点；`Return`点击只打开`fanhuidating`，由`Return/no`确认或取消跨Place返回。跨Place返回请求期间相关按钮锁定，失败后恢复。副本完成使用`Team`显示时间和最多四行排行；保存失败保留界面重试，成功返回大厅。

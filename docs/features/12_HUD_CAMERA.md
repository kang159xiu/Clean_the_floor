# HUD、模态界面、镜头与输入反馈

## 目标与边界

负责GameHUD渲染、通知、快捷栏视图、中央飞入效果、主面板互斥、模糊、开关动画和通用镜头状态。业务资格与数值仍由服务端快照和各功能Config决定。

## 玩家流程

玩家通过HUD查看金币、背包、工具、区域、图鉴和提示，区域门成功扣款时在`CoinsFrame["+Value"]`看到负数并伴随金币框脉冲。打开升级/图鉴/邀请/Rebirth等主面板时其他主面板关闭并启用模糊。中央奖励提示播放后回收模板；特殊玩法临时控制镜头，结束后恢复正常输入。

## 服务端权威

本功能没有业务裁决。服务端只通过`StateSnapshot`和`Notification`发送权威内容，客户端不能根据按钮外观自行发奖、扣费或解锁。

## 客户端表现

`HUDController`是当前综合HUD门面；`ModalPanelCoordinator/Effects`处理互斥、模糊和动画；`CenterFlyUIEffect`统一飞入、缩放、淡出与回收；`CameraController`维护常规镜头接口。

## 数据流

业务服务状态/事件 -> StateSnapshotStore、Notification或金币表现事件 -> HUD局部刷新；门消费事件先取消冲突的正向金币动画，再显示权威扣款后余额和短暂负数脉冲；入口按钮 -> Modal协调器 -> 正式打开/关闭回调；功能动画 -> CenterFly模板池 -> 完成回调恢复原始UI状态。

## 配置

时间显示复用`DurationFormat`，货币复用`CoinFormat`。具体图像、名称、倍率和价格来自所属功能Config，不在HUD重复定义。

## Remote

`Notification`由服务端向客户端发送普通权威提示；`CoinSpendEvent`只携带已完成区域门消费的表现数据，HUD不得据此执行扣款或解锁。其他HUD按钮使用所属功能Remote；HUD不得创建通用“执行任意操作”Remote。

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
- 区域门扣款提示必须使用`CoinSpendEvent.TargetCoins`同步余额，连续快照和正向金币动画不能留下错误的`+Value`文字或UIScale。
- 同一时刻最多一个主模态面板可见。
- 取消Tween、目标失效和快速开关后必须恢复Studio原始位置、透明度和UIScale。
- 客户端个人显示不得写回StarterGui或影响同服玩家。

## 修改影响

修改HUDController公共方法需查询所有关联功能。修改模态或镜头需检查升级、图鉴、邀请、Rebirth和抛硬币；修改中央提示需检查金币、叶子提示与失物NEW。

## 最小回归清单

- [ ] 四个主面板互斥、切换、关闭和Blur恢复正确。
- [ ] 快速重复操作、角色死亡和目标UI销毁无Tween/UIScale残留。
- [ ] HUD数值、通知和中央飞入不改变任何服务端状态。
- [ ] 区域门扣款时显示`-价格`并脉冲，失败请求、角色重建和后续金币收入不会留下负数或缩放残留。

# 核心启动与状态同步

## 目标与边界

负责创建运行时Remote、按依赖初始化服务与控制器，并把服务端权威状态可靠送到客户端。它不决定任何具体玩法规则。

## 玩家流程

玩家加入后服务端完成服务装配与数据加载，客户端等待Remote并并行启动无依赖控制器；有依赖的控制器等待前置成功。客户端性能控制器先以Low启动，随后按本地渲染帧率持续判断Low/Medium/High。首份权威快照到达后，各功能渲染当前状态。

## 服务端权威

`init.server.luau`是Remote创建和服务依赖装配的唯一入口。初始化失败必须带步骤名终止或记录，不能让未完成依赖的服务继续对外处理请求。高频活动Remote必须在其权威服务就绪后立即绑定，先于`PlayerDataService`发送首份可操作快照。

## 客户端表现

`init.client.luau`按显式依赖图启动控制器。`StateSnapshotStore`缓存最新快照，新订阅者立即获得当前值，避免各控制器各自等待Remote造成初始化竞态。`PerformanceController`只采样当前客户端`RenderStepped`，窗口失焦时暂停；档位变化通过本地BindableEvent通知表现控制器，不上传服务端。

## 数据流

服务端创建Remote并初始化服务 -> `PlayerDataService`加载玩家 -> 服务提供者组装状态 -> `StateSnapshot`发送 -> `StateSnapshotStore`缓存 -> 功能控制器订阅并局部渲染。

## 配置

Remote文件夹名称来自`src/shared/Constants.luau`；服务与控制器名单和依赖顺序由两个启动脚本显式维护。性能采样预热、窗口、FPS阈值和叶子模型额度来自`LeafVisibilityConfig.Performance`。

## Remote

本功能拥有`StateSnapshot`，方向为服务端到单个客户端。其他Remote分别归属业务功能，但都由服务端启动入口创建、客户端启动入口读取。

## 快照字段

本功能拥有快照传输机制，不拥有业务字段。所有顶层字段必须在`manifest.json`登记到唯一业务功能。

## 永久字段与重置

无专用永久字段。快照缓存只存在当前客户端会话，离服后自然销毁。

## Studio契约

运行时使用`game.ReplicatedStorage.Remotes`。该Folder及Remote由服务端验证或创建，不要求手工预建。

## 依赖功能

所有功能依赖本功能；本功能只依赖Roblox服务、共享常量和Rojo映射。

## 不变量

- 服务端与客户端Remote名称集合必须完全一致。
- 业务控制器不得自行创建Remote或伪造权威快照。
- 控制器依赖失败时不得假装成功继续启动后继项。
- 首份可操作快照不得早于`UpdateHarvestAim`等高频活动Remote的正式服务端监听。
- 客户端性能档位不得成为奖励、进度、资格、快照或存档的数据来源。

## 修改影响

新增Remote、服务、控制器或启动依赖时必须同时更新两端入口、manifest归属和对应功能页。修改快照分发会影响所有订阅控制器。

## 最小回归清单

- [ ] 服务端Bootstrap日志无失败或长期STALLED。
- [ ] 客户端全部控制器完成或给出明确失败依赖。
- [ ] 首份及后续快照只触发一次最新状态渲染。
- [ ] 团队测试冷启动期间装备工具不会出现`UpdateHarvestAim`队列耗尽或事件丢弃。
- [ ] 性能控制器从Low安全启动，失焦不误降档，恢复焦点后重新预热并继续采样。

## 合作副本边界

同一Bootstrap根据`CoopMatchConfig`中的PlaceId分流。大厅启用组队服务和界面；副本先绑定名单入场校验，并在`PlayerDataService`开始加载玩家前初始化合作服务、同步权威名单与难度，再启用合作运行态和结算界面。副本跳过教程、邀请、付费门、Rebirth、ResetCoin、Coin Flip和大厅牛。

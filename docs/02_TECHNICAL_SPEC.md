# 技术规格

## 文档职责

本文只记录跨功能架构。每项玩法的行为、Remote、字段、Studio入口和最小回归见[功能地图](features/README.md)；机器归属见`features/manifest.json`。

## 代码结构

- `src/server/init.server.luau`创建Remote并按显式顺序装配Service。
- `src/client/init.client.luau`读取Remote并按依赖图启动Controller。
- `src/server/Services`承载服务端权威和外部DataStore/Marketplace接口。
- `src/client/Controllers`承载输入、HUD、Streaming模型和个人视觉。
- `src/shared/Config`是两端共享数值、ID和规则接口；共享工具模块只放无玩家状态的纯逻辑。

## 权威原则

- 客户端只提交意图，不提交可直接相信的金币、奖励、拥有权、区域完成或物品结果。
- 服务端先验证玩家状态、对象上下文、距离、余额、冷却和幂等，再执行状态修改。
- 玩家个人表现优先使用本地属性或本地克隆，不Destroy服务器共享实例。
- 任何跨DataStore、共享投影或收据操作必须有唯一ID、锁和失败回滚。

## 状态同步

服务端通过`PlayerDataService.GetSnapshot`组装权威业务状态，客户端由`StateSnapshotStore`缓存并分发。业务字段必须有唯一功能归属；新增或删除顶层字段会被文档校验器检测。

高频世界状态使用专用增量Remote，例如庭院叶子和排行榜，不把全部内容塞入主快照。客户端订阅者必须能处理首次快照、后续刷新、Streaming晚加载和角色重建。

## Remote契约

Remote由服务端启动入口创建、客户端启动入口读取。两端集合和manifest归属必须一致；`scripts\verify-project.cmd`会动态解析并检查。具体方向、语义和失败行为记录在所属功能页。

## 持久化

主存档由`PlayerDataService`统一加载、sanitize、迁移和`UpdateAsync`保存。Schema值从源码提取并与manifest比较；各字段的Rebirth、完整清档和离服边界记录在所属功能页。独立排行榜、永久商品权益和收据账本继续由对应服务负责。

## Studio与Streaming

精确实例结构由[Studio对象契约](05_STUDIO_OBJECT_CONTRACT.md)唯一维护。可选对象必须安全缺失，Streaming后新增实例必须按最新快照立即应用；无法连接目标Place时只标记待核验，不根据旧截图或其他Place猜测。

## 变更流程

开发前运行`scripts\feature-impact.cmd <路径或契约>`，阅读命中的功能页和依赖；开发后更新行为/契约文档并运行`scripts\verify-project.cmd`。详细规则见[文档维护规则](DOCUMENTATION_RULES.md)。

## 已知结构风险

当前高风险集中在大型PlayerData、HUD、Leaf和LostItem模块、主快照扇出以及缺少Luau自动测试。治理与拆分顺序见[代码健康审计](CODE_HEALTH_AUDIT.md)，第一轮不改变游戏行为。

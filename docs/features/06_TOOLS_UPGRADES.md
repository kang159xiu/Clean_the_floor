# 工具、Automatic与升级

## 目标与边界

管理Tool01双手、Tool02扫把、Tool03吹风机、Tool04吸尘器和Tool05制造大便的装备、输入、动作、购买资格及升级。叶子实际收取和大便事务由对应功能裁决。

## 玩家流程

玩家从快捷栏装备工具，按住鼠标或触摸持续工作；Automatic把同一输入状态保持为开启。金币购买或永久权益解锁工具，升级界面提升双手、工具和个人属性。切工具、袋满、死亡、切庭院或特殊玩法会停止旧输入。

## 服务端权威

`CleaningToolService`审计装备，`CleaningToolActionService`维护活动动作，升级服务分别校验属性、等级、价格和扣费，`ToolGamePassService`处理Tool04所有权。客户端只提交意图和属性ID。

## 客户端表现

`ToolController`统一快捷栏、输入和装备反馈；`AutomaticController`复用真实持续状态；购买台控制器按快照显示价格、Owned和个人隐藏。拥有Tool04后购买台Beam只在该玩家客户端恢复或禁用Studio原值。

## 数据流

输入/快捷栏 -> Equip或活动Remote -> 服务端装备与动作状态 -> 叶子服务同时查询当前庭院与全服Lobby池，或由大便服务处理；升级按钮 -> 对应RemoteFunction -> 服务端扣费和状态更新 -> 快照 -> HUD、范围、购买台和角色工具刷新。

## 配置

基础工具和购买类型来自`ToolConfig`，双手升级来自`HandUpgradeConfig`，无限工具升级来自`ToolUpgradeConfig`，个人属性来自`PlayerAttributeConfig`。收集动画时序复用`CleaningToolCollectAnimation`。

## Remote

`EquipTool`、`UpgradeHandAttribute`、`UpgradeToolAttribute`、`UpgradePlayerAttribute`均为客户端到服务端并返回权威结果。持续清扫Remote归叶子功能，Tool05请求归大便功能。

## 快照字段

`PermanentToolOwnershipReady`、`EquippedToolId`、`ToolName`、`PickupCount`、`PickupInterval`、`HarvestRadius`、`HarvestForwardOffset`、`ToolBehavior`、`ToolStats`、`ToolPrice`、`ToolImage`、`ToolModelPath`、`UnlockedTools`、`HandUpgradeLevels`、`ToolUpgradeLevels`、`PlayerAttributeLevels`、`MoveSpeedBonus`、`WalkSpeed`。

## 永久字段与重置

`UnlockedTools`、`HandUpgradeLevels`、`ToolUpgradeLevels`、`PlayerAttributeLevels`、`LastEquippedTool`。永久Developer Product和Game Pass权益由独立所有权来源恢复；普通Rebirth清理本轮工具成长但保留文档定义的永久个人属性，完整清档规则由清档策略决定。

## Studio契约

工具模板见`清洁工具模板`，范围见`收割范围与描边`，快捷栏/升级页见`StarterGui契约`。世界Tool04台位于`Workspace.Function.tool04`同结构入口，具体层级见`Prompt与代码职责`。

## 依赖功能

依赖`leaves-cleaning`、`economy-commerce`和`hud-camera`；教程、背包满、抛硬币和庭院切换会暂停或恢复工具状态。

## 不变量

- 客户端不能决定拥有权、升级结果、命中目标或奖励。
- 同一玩家只能有一个有效清洁工具活动状态。
- Automatic与手动输入共用状态机，不能产生双重收取循环。
- 个人购买台隐藏不能Destroy服务器共享对象。

## 修改影响

修改工具行为或属性需检查LeafService、范围预览、快捷栏、动作声音、Automatic、购买台、教程和存档。增加工具需同时登记Config、模板、购买入口和所有权恢复。

## 最小回归清单

- [ ] Tool01～05装备、卸下、死亡恢复和数字键/触摸选择正确。
- [ ] 升级成功准确扣费，金币不足、满级和重复请求不改变状态。
- [ ] Automatic、切工具、袋满、抛硬币和返回大厅不会留下活动输入。

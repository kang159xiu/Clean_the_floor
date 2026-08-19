# 工具、Automatic与升级

## 目标与边界

管理Tool01双手、Tool02扫把、Tool03吹风机、Tool04吸尘器和Tool05制造大便的装备、输入、动作、购买资格及升级。叶子实际收取和大便事务由对应功能裁决。

## 玩家流程

玩家从快捷栏装备工具，按住鼠标或触摸持续工作；Automatic把同一输入状态保持为开启。金币购买或永久权益解锁工具，升级界面提升双手、工具和Move Speed。切工具、袋满、死亡、返回出生点或特殊玩法会停止旧输入。

## 服务端权威

`CleaningToolService`审计装备，`CleaningToolActionService`维护活动动作，升级服务分别校验属性、等级、价格和扣费，`ToolGamePassService`处理Tool04所有权。`UpgradePlayerAttribute`只接受仍可购买的`MoveSpeed`；退休的`LeafValue`及其他伪造属性ID均在扣费前拒绝。客户端只提交意图和属性ID。

## 客户端表现

`ToolController`统一快捷栏、输入和装备反馈；制造便便教程激活时，Tool05按钮使用独立UIScale以1.25倍持续脉冲，停止引导后恢复模板原缩放，模板本身尺寸变化不影响脉冲基准。`AutomaticController`复用真实持续状态，并使用`HUDRoot.Automatic.off`显示ON/OFF；`OP`只保留Studio标题文字。Automatic功能节点缺失或类型错误时只警告并安全停用该按钮，不能无限等待并阻塞Coin Flip或Coop等依赖控制器。升级面板打开时只通过`ToolController`取消当前手动按住输入，不直接关闭Automatic服务端清扫状态；玩家保持Automatic ON时可继续自动收取。购买台控制器按快照显示价格、Owned和个人隐藏。拥有Tool04后购买台Beam只在该玩家客户端恢复或禁用Studio原值。升级面板固定为Player、Hands、Broom、Blower四页；Player页普通属性只绑定`Pickup Amount → Move Speed`，并清理旧PlayerGui中可能残留的`Pickup Speed`金币倍率卡。Player页额外三张背包卡由背包功能渲染和购买，不进入玩家属性升级逻辑；Hands页的`Pickup Speed`仍是真实双手收取速度升级。

## 数据流

输入/快捷栏 -> Equip或活动Remote -> 服务端装备与动作状态 -> 叶子服务同时查询当前庭院与全服Lobby池，或由大便服务处理；升级按钮 -> 对应RemoteFunction -> 服务端扣费和状态更新 -> 快照 -> HUD、范围、购买台和角色工具刷新。

## 配置

基础工具和购买类型来自`ToolConfig`，双手升级来自`HandUpgradeConfig`，无限工具升级来自`ToolUpgradeConfig`，个人属性来自`PlayerAttributeConfig`。金币工具购买以及Hands、Broom、Blower和Move Speed全部按`round(该档基础价格 × 1.5 ^ RebirthCount)`定价，并始终从原始档位价格完整计算后四舍五入。该个人属性Config显式区分可购买顺序`MoveSpeed`与需持久化兼容的`MoveSpeed/LeafValue`；旧`LeafValue`每级+0.5只参与倍率计算，不再提供价格或升级定义。三类升级Config均提供独立的`MakeDefaultLevels()`表，调用方不得共享或修改Config内部表。收集动画时序复用`CleaningToolCollectAnimation`。

## Remote

`EquipTool`、`UpgradeHandAttribute`、`UpgradeToolAttribute`、`UpgradePlayerAttribute`均为客户端到服务端并返回权威结果。`UpgradePlayerAttribute("LeafValue")`属于无效请求，必须返回失败且不扣Coins、不改等级。持续清扫Remote归叶子功能，Tool05请求归大便功能。

## 快照字段

`PermanentToolOwnershipReady`、`EquippedToolId`、`ToolName`、`PickupCount`、`PickupInterval`、`HarvestRadius`、`HarvestForwardOffset`、`ToolBehavior`、`ToolStats`、`ToolPrice`、`ToolImage`、`ToolModelPath`、`UnlockedTools`、`HandUpgradeLevels`、`ToolUpgradeLevels`、`PlayerAttributeLevels`、`MoveSpeedBonus`、`WalkSpeed`。

## 永久字段与重置

`UnlockedTools`、`HandUpgradeLevels`、`ToolUpgradeLevels`、`PlayerAttributeLevels`、`LastEquippedTool`。`PlayerAttributeLevels.LeafValue`作为老玩家只读兼容等级继续保存、重进和普通Rebirth保留，不退款、不清零；完整清档按清档策略归零。永久Developer Product和Game Pass权益由独立所有权来源恢复。

## Studio契约

工具模板见`清洁工具模板`，范围见`收割范围与描边`，快捷栏/升级页见`StarterGui契约`。世界Tool04台位于`Workspace.Function.tool04`同结构入口，具体层级见`Prompt与代码职责`。

## 依赖功能

依赖`leaves-cleaning`、`economy-commerce`和`hud-camera`；教程、背包满、抛硬币和庭院切换会暂停或恢复工具状态。

## 不变量

- 客户端不能决定拥有权、升级结果、命中目标或奖励。
- 工具和普通属性的显示、可购买提醒与服务端扣费必须读取同一`1.5^RebirthCount`价格；背包、扩容和Robux商品不得套用该倍率。
- 同一玩家只能有一个有效清洁工具活动状态。
- Automatic与手动输入共用状态机，不能产生双重收取循环。
- 升级面板不得绕过`ToolController`直接改持续清扫Remote，避免Automatic本地ON但服务端OFF。
- 退休`LeafValue`只能被存档清洗和奖励计算读取，不能出现在可购买属性顺序、客户端卡片绑定或服务端升级定义中。
- Automatic的Studio功能节点缺失时不得阻塞客户端Bootstrap或依赖控制器初始化。
- 个人购买台隐藏不能Destroy服务器共享对象。

## 修改影响

修改工具行为或属性需检查LeafService、范围预览、快捷栏、动作声音、Automatic、购买台、教程和存档。增加工具需同时登记Config、模板、购买入口和所有权恢复。

## 最小回归清单

- [ ] Tool01～05装备、卸下、死亡恢复和数字键/触摸选择正确。
- [ ] 制造便便教程期间Tool05快捷栏按钮持续明显脉冲，完成、按钮重建或快捷栏隐藏后无UIScale残留。
- [ ] 工具购买、Hands/Broom/Blower和Move Speed在0/1/2次Rebirth时为各档基础价的1/1.5/2.25倍，显示、可购买提醒和服务端扣费一致；金币不足、满级和重复请求不改变状态。
- [ ] Player页只显示Move Speed及三张背包卡；大厅和Coop均没有旧金币倍率卡，伪造`LeafValue`升级请求不扣费。
- [ ] Automatic ON时打开升级面板仍继续自动收取；手动按住清扫打开面板只取消手动输入。
- [ ] Automatic、切工具、袋满、抛硬币和返回大厅不会留下活动输入。
- [ ] `Automatic.off/OP/UIGradient1/UIGradient2`结构正确时可切换ON/OFF；节点缺失时只停用Automatic且Bootstrap继续完成。

## 合作副本边界

合作局默认Tool01和Tool05，保留永久Robux工具；金币工具、Hand/Tool升级和Player的Move Speed从0开始且仅在本局有效，但价格仍按玩家永久`RebirthCount`使用`1.5^次数`曲线。老档只读`LeafValue`等级继续保留并参与本局价值倍率。等待到达和完成结算时服务端关闭叶子/便便入口；权威名单进入`Playing`后Tool01～04与Automatic继续复用普通区域的同一活动状态机和收取入口。客户端在完成时关闭Automatic、取消手动输入并压制结算期间快捷栏。

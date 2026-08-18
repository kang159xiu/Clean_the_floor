# 背包、容量扩展与角色外观

## 目标与边界

管理背包当前装载、普通等级、Lv.8后的容量扩展、永久3K/5K容量包、即时回收包和角色背包外观。金币扣费和商品收据归经济功能。

## 玩家流程

清扫把价值装入当前背包，达到容量后停止普通装袋并提示回收。玩家在任一区域购买台升级普通背包；达到普通Lv.8或拥有容量型永久背包后，同一购买行为改为扩容。永久背包可切换角色外观，instant recycle权益绕过普通装袋上限流程。

## 服务端权威

`BagService`修改装载值，`PermanentBagService`提供验证后的所有权，`BagVisualService`和`CharacterScaleService`维护角色Accessory。容量和下一档扩容全部调用`BagConfig`，客户端显示值不参与结算。

## 客户端表现

HUD显示当前/最大容量；购买台本地克隆下一背包模型并刷新Prompt、价格和可选`介绍`。实际进入扩容且下一档有效时显示`Bag+`加紧凑增量，否则恢复该TextLabel加载时Studio原文。

## 数据流

叶子收取 -> `BagService`按容量及权威`sourceOwnerUserId`写入来源值（Lobby使用拾取者本人）-> 快照更新HUD；购买台Prompt -> ProductService -> 权威升级/扩容 -> 快照 -> 所有已加载区域购买台和角色外观刷新。

## 配置

普通等级、永久包、容量优先级、扩容价格、增量和累计容量都由`BagConfig`提供。显示数字统一使用`CoinFormat.Compact`，不复制扩容公式。

## Remote

本功能拥有服务端到客户端的`BagFullPickupAttempt`反馈。升级购买使用Studio Prompt和经济服务绑定，不新增专用Remote。

## 快照字段

`CurrentBagValue`、`BagCapacity`、`BagCapacityBonus`、`BagFull`、`BagLevel`、`BagExpansionLevel`、`BagName`、`BagImage`、`BagPrice`、`PermanentBagOwnership`、`PermanentBagOwnershipReady`、`ActivePermanentBagId`、`InstantRecycleEnabled`。

## 永久字段与重置

`BagLevel`、`BagExpansionLevel`、`CurrentBagValue`、`BagCycleId`、`BagSourceValues`、`SelectedPermanentBagVisualId`、`BagCapacityBonus`。Schema 32把旧`LegacyAreaBagCapacityBonus`无损归一为正式容量字段；Rebirth清空本轮普通等级、扩容和装载，保留该永久容量及永久权益，完整清档按清档策略重建。

## Studio契约

模板见`袋子模板`，HUD见`StarterGui契约`，购买台见`Prompt与代码职责`。入口为`Area_01～08.BagProduct_01`，可选描述节点为`Part.BillboardGui.介绍 [TextLabel]`。

## 依赖功能

依赖`persistence-reset`、`economy-commerce`和`hud-camera`；叶子、回收、Quick Sell、好友分账和工具输入读取背包状态。

## 不变量

- 服务端容量是普通或有效永久基础容量、历史奖励和扩容奖励的统一结果。
- 购买台显示不得改变价格、购买类型或角色真实外观。
- `BagCycleId/BagSourceValues`必须阻止跨清档或并发回收结算到新背包周期。
- 可选Studio节点缺失或Streaming晚到不能阻断购买台。

## 修改影响

调整容量或扩容时检查ProductService、回收、Quick Sell、HUD、购买台文字、永久包优先级、保存sanitize和Rebirth。修改模型名时同步BagConfig与Studio模板。

## 最小回归清单

- [ ] 普通Lv.1～8升级与扩容价格、容量和模型正确。
- [ ] 3K/5K玩家可提前扩容，失效后恢复普通升级行为。
- [ ] `介绍`在扩容显示下一增量，普通/满级恢复原文且支持Streaming。

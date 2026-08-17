# 技术规格

> 本文描述2026-08-02源码中的实际接口。未来模块和多人接口只写入路线图，不混入当前运行时契约。

## 权威原则

- 客户端只负责输入、镜头、UI、范围和表现；客户端不能决定叶子奖励、金币、购买结果、升级结果或区域完成。
- 服务端验证当前角色、实际装备Tool、瞄准时效、水平距离、袋子容量和玩家状态。
- 购买、升级、回收和失物兑换由服务端结算并防止重复触发。
- 叶子通过服务端活动表和`Collected`属性防止重复处理；移动工具不能直接上报叶子位移或奖励。

## 当前代码结构

```text
src/shared
├─ Config
│  ├─ AreaUnlockConfig.luau
│  ├─ BagConfig.luau
│  ├─ HandUpgradeConfig.luau
│  ├─ LeafConfig.luau
│  ├─ LostItemConfig.luau
│  ├─ PlayerAttributeConfig.luau
│  ├─ ProductConfig.luau
│  ├─ RegionConfig.luau
│  ├─ ToolConfig.luau
│  ├─ ToolUpgradeConfig.luau
│  └─ TutorialConfig.luau
├─ CleaningToolCollectAnimation.luau
├─ Constants.luau
├─ HarvestGeometry.luau
└─ LostItemProbabilityValidation.luau

src/server/Services
├─ AreaDoorService.luau
├─ BagService.luau
├─ BagVisualService.luau
├─ CharacterScaleService.luau
├─ ClearTimeLeaderboardService.luau
├─ CleaningToolActionService.luau
├─ CleaningToolService.luau
├─ CleanupLeaderboardService.luau
├─ EconomyService.luau
├─ HandUpgradeService.luau
├─ LeafService.luau
├─ LostItemService.luau
├─ PlayerAttributeUpgradeService.luau
├─ PlayerDataService.luau
├─ PlayerAreaService.luau
├─ PlaytimeLeaderboardService.luau
├─ PlaytestMetricsService.luau
├─ ProductService.luau
├─ RecycleService.luau
├─ TutorialService.luau
└─ ToolUpgradeService.luau

src/client
├─ Controllers
│  ├─ AreaDoorController.luau
│  ├─ AffordableNotificationController.luau
│  ├─ BagProductDisplayController.luau
│  ├─ CameraController.luau
│  ├─ TimeLeaderboardController.luau
│  ├─ ExitSaveController.luau
│  ├─ HandUpgradeController.luau
│  ├─ HarvestRangeController.luau
│  ├─ HUDController.luau
│  ├─ LeafTargetHighlightController.luau
│  ├─ LocalLostItemController.luau
│  ├─ RecycleGuidanceController.luau
│  ├─ TutorialController.luau
│  └─ ToolController.luau
├─ Effects/CenterFlyUIEffect.luau
└─ init.client.luau
```

当前没有`Types.luau`、`AreaService`、`GameRunService`、`PartyService`或`LobbyController`，文档和代码不得假定它们存在。

`CharacterScaleService`在服务端监听`CharacterAdded`和`CharacterAppearanceLoaded`，等待`Humanoid/HumanoidRootPart`后对R6、R15角色调用绝对`Model:ScaleTo(0.7)`。缩放时临时排除所有Tool及带`CleaningBagLevel`的系统背包，保证手持工具维持模板大小、已缩放背包不重复乘到0.49；`BagVisualService`则在`Humanoid:AddAccessory`前通过临时Model单独把每个新背包克隆缩到0.7。该服务不修改移速、HipHeight、工具属性、Remote、快照或存档。

## 玩家会话状态

`PlayerDataService`在服务器内维护：

```luau
{
    Coins = 0,
    BagLevel = 1,
    CurrentBagValue = 0,
    UnlockedTools = { Tool01 = true, Tool02 = false, Tool03 = false },
    UnlockedAreas = { Area_01 = true },
    CurrentAreaId = "Area_01",
    EquippedTool = "Tool01",
    LastEquippedTool = "Tool01",
    HandUpgradeLevels = { Range = 0, Speed = 0, Amount = 0 },
    ToolUpgradeLevels = {
        Tool02 = { Range = 0, ForwardOffset = 0, SweepStrength = 0 },
        Tool03 = { Range = 0, Power = 0, Accuracy = 0 },
    },
    PlayerAttributeLevels = { MoveSpeed = 0, LeafValue = 0 },
    WalkSpeed = 16,
    PersonalLeafValueMultiplier = 1,
    LeafValueMultiplier = 1,
    CollectedCounts = {},
    CodexClaimedTiers = {},
    ClearSpeedrun = {
        Version = 1,
        Eligible = boolean,
        RunRebirthCount = number,
        Completed = boolean,
        AccumulatedSeconds = number,
        BestSeconds = number?,
        PendingBestSeconds = number?,
        SessionStartedClock = number?, -- 仅运行时
    },
}
```

上述白名单成长字段均从永久存档恢复。重生会重置金币、袋子、工具、工具等级和本轮区域进度，但保留`PlayerAttributeLevels`、旧玩家的`LegacyAreaBagCapacityBonus`、`CollectedCounts`与`CodexClaimedTiers`。区域完成不再发放新的属性或容量奖励。

普通进度保存采用固定10秒合并窗口：窗口内的多次变化只更新运行时Revision，不重复提交`UpdateAsync`。提交前检查`UpdateAsync`预算，预算不足时5秒后重查；失败后按5/15/30/60秒退避并保留Dirty状态。离服、关服和重生使用最新状态强制保存，付费重生仍以成功保存回执检查点作为发货完成条件；所有延迟任务均以状态引用和Token隔离清档、重生及玩家离开后的旧任务。

## 区域与叶子生成

- `RegionConfig`集中登记当前运行时`AreaCount=8`、`DefaultUnlockedAreaCount=1`、`BaseProgressionAreaCount=4`、`FinalAreaId=Area_08`和`Order=Area_01～08`。`PersistentAreaCount=9/PersistentOrder=Area_01～09`只供存档清洗保留休眠Area_09数据；Area_09的`Mansion`显示、叶子和失物配置继续保留，但不参与运行时生成、检测或解锁。
- 每个`Area_XX.ground`必须是Model，所有后代BasePart按`Size.X × Size.Z`参与加权随机落点。
- 每区基础叶子数量为`clamp(round(ground面积 × LeafDensityPerSquareStud), MinimumLeafCount, MaximumLeafCount)`；正式目标数量为`round(基础数量 × (1 + RebirthCount × 0.5))`。Area_01的`MinimumLeafCount/MaximumLeafCount`均为450，因此0次重生基础目标固定450片；未解锁前沿预览固定100片且不乘重生倍率。
- 服务启动时只为当前最早已解锁且未完成区域计算正式目标，每区激活最多2000片，并为其下一地区生成100片预览；更远区域不生成。区域100%完成后预览保持不可处理，直到角色身体碰门且服务端成功解锁；随后用正式活动集替换该预览，并在存在后继区域时生成新的100片预览。重进按存档选择最早已解锁未完成区并恢复比例；当前Area_08没有后继区域。
- 每区独立维护完整`TotalLeafCount/TotalValue`、已清理值、最多2000片活动叶子和确定性待生成序号。待生成部分不进入`LeavesById/LeafGrid`或客户端快照；`GameplayReady=true`才允许工具、失物和描边处理，`PreviewOnly=true`表示当前仅为未解锁预览。
- `LeafConfig.Population`统一配置活动上限2000、工作批量20、批次间隔0.1秒、失败重试0.05秒、每区200个预备位置和每Heartbeat最多4次候选准备。正式未完成区域的目标活动数为`min(2000, TotalLeafCount - CollectedLeafCount)`，缺口为该目标减去当前`Leaves`并受`PendingLeafCount`限制；不再维护`RefillOwedCount`。每个候选通过`areaState.Leaves[randomIndex]`以O(1)取得现存锚点，在锚点8-stud网格内投射到其原ground平面并最多执行一次包围盒障碍检查，不遍历活动集或读取玩家位置；活动叶为0时才允许全区域候选恢复首片。收取后立即排队，首批不等待，后续每0.1秒按确定性下一Leaf类型从队列取最多20片并发送单个`Upsert`；失效位置只消耗候选，不减少`PendingLeafCount`，并按0.05秒重试。区域完成、重生、清档、庭院重建和区域替换都会清空队列并使旧Token失效。
- 普通失物会话只在玩家已解锁、`GameplayReady=true`且`Completed=false`时创建。各启用区在3～6件之间等概率规划，并分配到互不重复的随机累计清理片数；达到节点时在刚移除叶子周围4 studs内生成幸运盒。旧轮已持久化的计划完整保留且不重抽数量；新区域计划和重生后的新轮使用3～6。100片`PreviewOnly`叶子和已完成区域不创建普通计划；重复区域就绪和快照通知由会话状态幂等处理。
- 叶子克隆自`ReplicatedStorage.Model.Leaf1～Leaf16`，属性为`LeafType/BagValue/AreaId/Collected`。克隆使用`ModelStreamingMode=Atomic`、保持锚定、关闭碰撞/触摸/查询，并沿落点ground表面法线加入0.05～0.6 studs随机高度差；初始正式叶、100片预览和实时补叶共用该范围。`LeafVisibilityConfig`为首个`GameplayReady=true、Completed=false`区域的两种Leaf各维护100个客户端预热模型，总池上限200；每0.05秒最多克隆1个并保持`Parent=nil`。静态Part与贴图设置只在克隆时遍历一次，显示时恢复动态属性、缩放和位置；收取动画或流送回收后优先归池，切区以Token取消旧预热并逐个释放过期类型。
- 性能经验：叶子属于高数量重复实例，模板、运行时克隆和场景装饰叶子的所有BasePart都应保持`CanCollide=false`、`CanTouch=false`、`CanQuery=false`、`CastShadow=false`。大量叶子开启碰撞会增加角色移动期间的物理接触与求解开销，开启阴影会增加移动和旋转镜头时的阴影渲染开销，两者都可能表现为走动或转视角卡顿。遇到类似问题时优先检查这些实例属性，再排查逐帧脚本和网络；10Hz的`YardLeafDelta.Kind="Move"`只同步被推动叶子的运动状态，不控制Roblox玩家角色移动。
- 每个候选位置以旋转后的叶子包围盒调用`Workspace:GetPartBoundsInBox`，`OverlapParams.RespectCanCollide=false`，因此所有`CanQuery=true`对象都会参与判断。八区ground和旧`GeneratedLeaves`容器被排除；包围盒各轴内缩0.02 studs且最小保留0.01 studs。每片最多随机尝试12次，失败时使用最后候选；只有受阻兜底达到本次活动叶子1%时才按区域输出汇总警告，正式叶子和100片预览使用同一规则。
- `PlayerAreaService`每0.25秒只检测玩家脚下`Area_01～Area_08.ground`并更新`CurrentAreaId`，不检查该区域是否已经解锁。玩家在道路或休眠Area_09上时保留最后有效区域。
- `areaProgressProvider`和失物进度Provider都使用`CurrentAreaId`；主HUD清洁度、失物数量和本区图片列表随当前区域切换。

叶子数值配置中的Leaf1～18 `BagValue`均为1。当前`LeafConfig.ActiveOrder`只包含Leaf1～16，服务端模板验证、客户端对象池和回收飞叶均不得查找Leaf17/18；运行区域叶子池固定为Area_01使用Leaf1/2、Area_02使用Leaf3/4，以此类推至Area_08使用Leaf15/16。Area_09的Leaf17/18数值配置仅为以后恢复保留，Studio模板可以缺失。

区域必须完成完整逻辑目标才设置`AreaCleaned=true`，不使用95%自动完成。区域剩余超过2000片时持续追平2000活动目标；剩余不足2000片后活动目标等于全部真实剩余叶子，待生成耗尽后不再刷新。没有现存叶子的特殊情况由后台调度器准备全区域ground候选恢复首片；退出重进仍只按保存的清理比例重新生成剩余分布，不保存运行时计数、位置队列或具体位置。

客户端按权威`AreaTotalLeafCount - AreaCollectedLeafCount`启用最后100片收尾描边：当前活动庭院的当前正式区域剩余1～100片时，`YardLeafController`从按区域增量维护的描述ID集合中单次选择水平距离最近的最多5片，并复用`ReplicatedStorage.miaobian.Highlight02`。选择只在进入/离开收尾阶段、当前区域或庭院变化、玩家跨8-stud网格以及目标描述增删移动时刷新；使用Top 5插入选择而不排序全部叶子，不扫描Workspace。选中的最多5个远距模型通过现有16个/帧创建队列加载并暂时豁免距离回收，普通48/64-stud流式半径不扩大；目标更换后旧模型恢复正常回收。该引导在角色存活时不受工具、输入和背包状态限制，并优先于Tool01普通描边。区域仍必须实际收取全部逻辑叶子才完成，进度、开门和奖励判定不变。

普通目标描边只服务Tool01：装备双手时立即刷新一次，之后每0.5秒从8-stud空间网格查询与真实拾取圆相交的附近叶子，再按水平模型边界、`PickupCount`和背包剩余容量筛选。Tool02、Tool03和Tool04无论装备、按下或持续工作都不会读取该索引进行目标搜索、排序或创建普通`Highlight`；这些工具的实际作用范围与收取仍由服务端权威判定。袋满、卸下、死亡或切换到其他工具时清空普通描边。

## 工具输入、装备与动作

- `CleaningToolService`只从`ReplicatedStorage.CleaningTools`克隆已解锁且可用的Tool，设置`CleaningToolId`与`HotbarOrder`，并在重生时重建背包。
- 客户端关闭Roblox默认Backpack栏，并把`HUDRoot.ToolFrame.ImageButton`作为隐藏模板生成自定义快捷栏。栏内按`HotbarOrder`显示已解锁Tool01～05和当前会话失物堆叠；每种失物类型只显示一个代表槽及`number=xN`，非系统Tool不显示。
- 点击未装备按钮会装备该项，重复点击当前按钮会卸下；实际位于Character中的当前装备项使用`#FFFFFF`描边，其他槽位使用`#808080`描边，清洁工具和携带失物使用同一规则。数字键`1～9`按快捷栏当前从左到右的顺序选择项目；键盘可用时第1～9槽的`key`同步显示对应数字，第10槽以后隐藏，纯触屏设备隐藏全部键位提示，外接或断开键盘后立即刷新。Q键继续装备/卸下最近使用的清洁工具，鼠标滚轮在当前快捷栏项目中循环切换。
- 成功兑换携带失物后，服务端在确认角色空手时自动恢复`LastEquippedTool`；主动按Q键或重复点击快捷栏卸下工具不会触发自动恢复。
- 清洁工具按钮名称和图片读取`ToolConfig.Name/Image`；图片为空时隐藏`ImageLabel`但保留名称。失物读取`LostItemId`对应的`LostItemConfig.DisplayName/Image`，正式图片为空时使用统一占位图。
- 玩家按住鼠标左键或触摸时，客户端通过`SetLeafPickupActive`启动工具；松开、切换工具、窗口失焦、死亡或重生时停止。
- Automatic与手动输入在`ToolController`合并成一个持续状态；状态由false变为true时只发送一次`SetLeafPickupActive(true)`并立即执行首批，全部后续批次由服务端Heartbeat驱动。Tool01读取升级后的`PickupInterval`，Tool02读取`ForceInterval`，Tool03/04读取`PickupInterval`；服务端每Heartbeat最多处理一批且不做低帧率追赶。袋满、切工具、切庭院、返回Lobby、角色重建和抛硬币暂停会停止或重新同步该状态；自动吹风机复用真实长按的循环声音和持续动作。旧`AutoPulse`模式及固定0.5秒限流已删除。
- Tool01成功处理一个批次时按当前间隔调整非循环动作动画速度。Tool02/03持续有效时循环动作动画，停止输入后淡出。
- Tool01～03使用`rbxassetid://121404663456576`作为共享清理动作；Tool05单独使用`rbxassetid://132805312644318`，Tool04保留模型持有动作且禁用通用批次动作。
- Tool04单次最多10片的删除ID合并为一条`YardLeafDelta.Kind="Remove"`并携带可选`ToolId`；客户端每包最多动画1片，其余立即回池。`LeafCollected(totalAmount, firstLeafType, toolId, leafHints)`在同一网络包中携带可选逐片列表，每项包含权威`LeafType/BagAmount/DisplayValue`。服务端Tool01～04仍按每片记录；客户端把有效逐片提示放入0.04秒短时节拍队列，每帧最多新建1个。排期与播放中合计最多30个，超额项直接省略、不压缩合并。旧三参数调用直接把总袋值作为一个提示。
- `LastEquippedTool`只记录Tool01～04清叶工具。Tool05可以手动装备，但加入、死亡复活、重生、失物兑换后的默认恢复以及Q键重新装备均回到最近的清叶工具；旧档若曾记录Tool05则安全回退Tool01。
- 数据状态或角色准备完成后的正常工具同步会追加一次0.25秒服务端审计：同时检查Character与Backpack，任意Tool01～04存在时不处理；只有Tool05、失物Tool或完全没有Tool时，使用玩家级锁补发并装备Tool01。该审计只用于进入与角色重建兜底，不会因玩家手动卸下而重复发放，因为清叶工具仍保留在Backpack。

### Tool01 双手

- `Behavior="Collect"`，基础范围1.5、前移6、有效间隔0.55秒、数量1。
- 服务端按叶子水平包围盒距离和名称排序，每批最多处理`PickupCount`片。
- 只显示外圈和下一批叶子Highlight；袋满后停止并播放袋满反馈。
- 当前升级值：

| 等级 | 范围 | 速度间隔 | 数量 |
|---:|---:|---:|---:|
| 0 | 1.5 | 0.60 | 1 |
| 1 | 2.0 | 0.40 | 2 |
| 2 | 2.5 | 0.30 | 3 |
| 3 | 3.0 | 0.20 | 4 |
| 4 | 3.5 | 0.15 | 5 |
| 5 | 4.0 | 0.10 | 6 |

范围、速度、数量价格分别为`100/200/450/750/1500`、`63/188/375/688/1125`和`25/125/438/875/1438`。

### Tool02 扫把

- `Behavior="Broom"`，当前解锁价格825，基础范围3、前移8、每0.15秒按覆盖率选择最近叶子，不设置固定片数上限。
- 实际运行属性来自`ToolUpgradeConfig`：推动速度固定为`BaseImpulseSpeed 18 × SweepImpulseMultiplier 0.4`；基础范围沿用内外距离衰减，溢出圆环使用外沿倍率0.2。叶子向玩家根部移动，在水平3 studs内自动装袋，并以2 studs作为运动停止距离。
- 范围等级0～5为`3/4/5/6/7/8`，价格`1000/1688/2375/3063/3500`。
- 前移等级0～5为`8/9/10/11/12/13`，价格`875/1500/2125/2750/3375`。
- 内部存档ID继续为`SweepStrength`，运行时字段改为`SweepCoverage`；等级0～5为`50%/60%/70%/80%/90%/100%`，价格`1250/1625/2000/2375/2750`，之后每级继续增加10%。基础范围使用第一段最多100%，每个额外100%增加一层1-stud圆环；每层按距离和叶子ID稳定排序并选择`ceil(层内数量 × 本层比例)`。

### Tool03 吹风机

- `Behavior="Blower"`，当前解锁价格12498，基础范围3、前移6、固定每0.2秒直接装袋最多2片。每次新按下会清空该工具上次批次时间并立即执行第一批；按住空地时仍保持连续动作，叶子进入范围后在下一批收取。
- 电脑端以玩家至受`ForwardOffset`限制的瞄准点形成渐宽气流；纯触屏端以玩家脚底为圆心并使用`Range + ForwardOffset/2`半径。两种模式的候选都按与客户端描边相同的距离顺序收取，不创建吹风叶子运动状态。
- Pickup Range等级0～5为`3/4/5/6/7/8`，价格`7000/8750/10000/11500/12500`，5级后沿普通无限分支继续增加。
- 历史存档ID`Power`固定表示Pickup Amount，等级0～9每批为`2/3/4/5/6/7/8/9/10/11`片；升级价格为`3750/5000/6000/6750/7250/10875/16313/24469/36703`，9级显示`MAX`。
- 历史存档ID`Accuracy`固定表示Pickup Distance，其`ValueField`为`ForwardOffset`。等级0～9为`6/7/8/9/10/11/12/13/14/15` studs；升级价格为`300/1500/7500/11250/16875/25313/37970/56955/85433`，9级显示`MAX`。纯触屏每级因此增加0.5 studs玩家中心半径，Pickup Range仍只控制气流宽度。
- `ToolStats`继续提供`Range/ForwardOffset/PickupCount/PickupInterval`，其中`PickupInterval`固定为`0.2`。吹风机没有电量状态、耗电、充电、0电可用性判断、头顶电量牌或低电量提示。
- 客户端初始化时仍克隆并异步预加载一次`SoundService.leafBlower`；操作者装备Tool03、按住且袋未满时从头循环播放该实例，松开、袋满、切换工具或死亡时停止并归零但不销毁，其他玩家不会听到。

扫把会记录最后推动玩家和工具来源；仅由该玩家扫把推动的叶子进入其水平3 studs范围时使用正常装袋流程，并推进区域、教程与失物逻辑。叶子运动停止距离独立保持2 studs，为自动收取留出1 stud容差。吹风机逐片复用同一正常装袋流程，因此飞行动画、音效、教程、区域进度和失物触发保持一致。

### 无限工具升级接口

- `HandUpgradeConfig`与`ToolUpgradeConfig`统一提供`IsCapped`、`IsMaxLevel`、`GetLevelConfig`和`GetNextPrice`。服务端购买、客户端显示、教程和可购买通知不再直接读取静态`Levels[current+1]`或统一判断`level >= 5`。
- `UPattributeicon.1～4`切换`Player/Hands/Broom/Blower`页面。当前页按钮只启用`Stud["Owned/Locked"]`选中渐变，其余按钮只启用`Stud.Cost`未选中渐变；页面显示与按钮状态由同一次`SelectPage`更新。11张卡使用直属`Name/Info/BuyButtons.Buy.Cost`显示英文名、数值变化及价格；玩家页只含`Move Speed/Value Multiplier`。
- 双手`Speed`最高5级，吹风机`Power/Accuracy`最高9级；其余既有无限分支规则保持不变。旧Power/Accuracy等级沿用并钳制到9，旧`ChargeSpeed`不再读取，后续正常保存会自然移除且不退款。
- 11张升级卡统一使用`BuyButtons.Buy`处理点击，`Name`显示权威名称、`Info`显示`当前实际值->下一级实际值`、`Buy.Cost`显示价格。双手及工具的当前/下一级值由配置的`ValueField`和`GetLevelConfig`取得；达到配置上限或价格溢出时显示`当前值->MAX`并禁用按钮。`Hands["Pickup Amount"]`内的`Buy.Decor.Stud.UIGradient002`和`Buy.Highlight.UIStroke002`是不可购买样式模板；客户端给其余卡片按需各克隆一份且不重复创建。金币不足、工具未解锁、MAX或价格不可用时关闭冲突彩色样式并启用两份灰色节点，可购买时关闭灰色并恢复原始彩色节点状态；模板或目标层级缺失仅警告并回退旧渐变，不阻断启动。
- 普通无限分支目标等级大于5时基础价格为`round(5级价格 × 1.5^(目标等级-5))`，实际价格继续乘`2^RebirthCount`。
- 扫把已删除`MaxAffectedLeaves`及范围等级派生数量；覆盖率选择由`HarvestGeometry`在服务端处理与客户端描边间共享。吹风机继续使用`PickupCount`。工具等级保存整数，重生归零。

## 瞄准、范围和叶子运动

- 纯触屏设备不使用镜头射线，以玩家脚底为逻辑圆心，作用半径为`Range + ForwardOffset/2`，但不显示外圈、内圈或扫把方向Beam。非纯触屏设备把`GetMouseLocation()`原始坐标传给`ViewportPointToRay`，再直接与玩家脚底水平面求交，避免Core UI顶栏偏移和高模型命中深度造成圆心错位；交点仍按`ForwardOffset`限制。
- `UpdateHarvestAim(valid, aimOffset, playerCentered)`最多约0.05秒更新一次。纯触屏提交零偏移和`playerCentered=true`；其他设备提交受限水平偏移和`false`。服务端验证布尔模式、Vector3、时效、实际装备和距离，以权威工具属性重新计算手机半径，拒绝手机模式的非零偏移。
- 电脑端玩家存活且实际装备有效清洁工具时，外圈持续显示，Tool02/03内圈按配置持续显示。范围Part的尺寸Tween只作用于内外圈；`MagneticRange.SurfaceGui.Frame`由单独的`LocalHarvestRangeCenter`克隆显示，该克隆始终保持模板Part和Frame的原始尺寸并跟随同一逻辑圆心。外圈、内圈和固定中心点均在原有离地间隙基础上沿脚底平面法线额外抬高`0.2 studs`；外圈与中心点继续保留`GROUND_GAP=0.02`，内圈继续使用额外`0.02-stud`分层。该偏移只作用于本地视觉CFrame，不进入逻辑圆心、服务端瞄准或命中计算。初始化、卸下工具、装备Tool05、死亡、角色根部缺失或有效范围为0时，内外圈、固定中心点及扫把方向辅助Part全部隐藏并停放到`CFrame.new()`，同时发送无效瞄准；纯触屏仅停放视觉，仍持续提交有效的玩家中心瞄准。
- Tool01只显示外圈；Tool02/03显示内外同心圆。切回Tool01时取消内圈尺寸Tween并立即隐藏内圈Decal。
- Tool02装备且范围有效时，客户端克隆`ReplicatedStorage.PointTo`为透明、无碰撞的`LocalBroomDirectionGuide`；电脑端保持范围中心指向玩家脚下的贴地Beam，纯触屏始终隐藏并将该辅助Part停放到原点。范围视觉额外`0.2-stud`偏移不得应用到该Beam，其离地间隙继续独立使用`0.1 studs`。
- 服务端以0.05秒固定步长权威更新被推动叶子，使用阻尼停止，并持续向当前区域ground投影以避免离地；只用200 studs/秒的技术速度保护防止物理崩溃，不对正常升级数值钳制。持续运动通过`YardLeafDelta.Kind="Move"`每0.1秒（10Hz）批量发送精简位置、速度和停止参数，开始与停止状态立即发送；客户端最高30Hz预测视觉位置，并在0.15秒内向新权威样本平滑纠偏。单Part素材缓存包围盒偏移后统一使用`BulkMoveTo`，多Part素材使用缓存后的`PivotTo`回退，移动热路径不再重复计算包围盒。
- 服务端为每个区域维护8-stud叶子空间网格；手机端Tool01/04直接收取圆内最近目标，Tool02推动圆内目标并在3 studs内自动装袋，Tool03按功率和间隔直接批量收取圆内目标。电脑端保留原瞄准圆和吹风机渐宽气流。两种模式都可跨正式区域处理，预览叶子不进入候选，垂直限制保持4 studs。

## 金币个人属性与结算

- `PlayerAttributeConfig`只定义`MoveSpeed/LeafValue`，`PlayerAttributeUpgradeService`是唯一升级入口；旧Luck等级加载后丢弃且不退款。客户端只提交属性ID；服务端串行校验等级、有效上限、阶乘价格和金币余额后通过标准金币消费入口扣款。
- 购买目标等级`n`价格为`BasePrice × n!`。移速与叶价`BasePrice=500`金币；只保存等级。价格超过货币安全上限`1e100`时返回`MAX`。
- 有效移速为`min(40, 16 + MoveSpeed等级)`；有效价值倍率为`(1 + LeafValue等级 × 0.5) × (1 + RebirthCount × 1.5)`。幸运点、幸运金币和幸运额外失物已经移除。
- 回收及好友叶子收益统一使用有效价值倍率。普通失物逐件计算`floor(基础值 × 有效价值倍率)`，其汇总额再应用双倍金币。五级玩家大便单独计算固定额：制造者实例为10，其他玩家实例读取该等级`10/100/300/1000/2000`，大便额不应用价值倍率或双倍金币；混合兑换只翻倍普通失物部分。叶子结算不再追加幸运金币，普通失物数量不再有幸运加成。
- 金币使用大数值安全上限；图鉴次数等普通计数仍限制为10亿。所有货币与价格入口拒绝NaN、负数和无穷值。

## 袋子、商品与回收

- `BagConfig.Levels`保留8级普通背包，当前容量为`15/100/150/200/250/300/350/400`；`PermanentBags`另行登记`bag09/bag010/bag011`和各自`Enabled`开关，不会扩展持久化`BagLevel`。
- 8级运行价格为`0/45/150/400/1000/2500/6000/15000`；1/2级有图片，3～8级图片为空。`bag01～bag08`Accessory通过`BagVisualService`装备到角色；所有普通与永久系统背包克隆会先缩放到0.7，再交给`Humanoid:AddAccessory`，并使用属性防止重复缩放。
- Area_01～08的`BagProduct_01`都由`ProductService`连接；Lv.8前购买当前等级的下一级，Lv.8后购买`BagExpansionLevel`。第`n`次扩容增加`100 + (n - 1) × 50`容量，累计奖励为`25 × n × (n + 3)`；首次价格22500，后续按上次实际整数价格乘1.5并四舍五入，且不使用重生倍率。3K/5K永久背包直接具备扩容资格，最终容量为`当前普通或永久基础容量 + LegacyAreaBagCapacityBonus + GetExpansionCapacityBonus(BagExpansionLevel)`。`BagProductDisplayController`在实际扩容模式下复用`GetNextExpansionCapacityIncrement`，把已加载购买台的可选`Part.BillboardGui.介绍`写为`Bag+紧凑增量`；普通升级或无下一档时恢复节点载入时的原文，缺失及Streaming晚到不阻塞价格、Prompt和模型。
- Area_01～08的`CleaProduct_02/03`分别购买Tool02/03；Area_01额外的`CleaProduct_02_1`映射到同一Tool02商品。当前价格来自`ToolConfig`，分别为825和12498。是否拥有只读取权威`UnlockedTools`：已拥有时服务端直接拒绝重复触发，不扣金币、不克隆也不装备；客户端把所有同类价格牌改为`Owned`并关闭Prompt。Tool01默认解锁，当前Studio没有必须存在的CleaProduct_01契约。
- 游戏内货币、价格和容量统一调用`CoinFormat.Compact`：小于1000显示整数，达到1000后使用小写`k/m/b/t/qa/qi...`，按一位小数向上取整并移除末尾`.0`，跨过`1000k`时继续进位到`1m`。例如`825→825`、`1000→1k`、`1001→1.1k`、`12498→12.5k`、`999999→1m`。该规则只改变文本，不参与价格、容量、资格或扣款计算。
- 双手拾取以`math.min(剩余容量, BagValue)`装袋；容量不足时显示实际加入值并移除该叶子。
- `RecycleService`只连接`Area_01～Area_08.Recycle_01`；任一区域成功触发时立即清空袋子并权威增加金币。每个区域独立保存回收堆动画状态，但同一玩家仍使用全局回收锁防止重复结算。普通回收完成不再发送“区域回收数量/获得金币”的重复HUD文字，金币动画、回收特效、教程回调、统计和快照不变。
- 普通回收按本次实际袋值使用开方曲线生成5～30片0.5倍随机叶子：1～15/100/400/3000/5000片约对应5/8/11/24/30个模型；飞叶创建、金币跳动和`SoundService.Recycle`使用同一动态间隔，并随数量从0.1秒降至最快0.05秒，各片自身仍飞行0.2秒且逐个创建。目标优先为`Recycle_01.PulseVisual.grass.grass`，五组起点和弧线循环复用。每片到达时，服务端以`PulseVisual`的Studio Pivot为中心让全部视觉BasePart短暂放大至1.08倍再恢复；连续到达会重启该区独立脉冲并复位全部尺寸与位置。最后一次脉冲完整结束后才播放草堆固定底部中心的Y轴动画。旧路径`Recycle_01.grass.grass`仍可播放草堆动画，但缺少`PulseVisual`时跳过整体脉冲。
- `CoinGainEvent`的金币分段与可选声音序列相互独立；`SoundKind/SoundCount/SoundFirstDelay/SoundInterval`由服务端权威设置。普通叶子回收的金币分段、`SoundService.Recycle`和飞叶抵达使用相同数量与间隔，低金额的零增量分段仍保留对应声音；低于0.08秒时，仅回收金币脉冲的放大/缩小半程各改为当前间隔的一半，因此0.05秒节拍使用0.025+0.025秒。Quick Sell不创建世界飞叶但保留同一金币和声音节拍。拥有双倍金币通行证时，完整`+基础值`保持0.3秒，再显示`基础值x2`、脉冲并保持0.6秒，最后用0.35秒飞入权威余额。
- 每名玩家本局前三次从未满变为满袋时，客户端克隆`ReplicatedStorage.yindaoxian`并连接玩家根部与`CurrentAreaId.Recycle_01`。两端向上偏移1.5 studs，Beam放在本地`Workspace.LocalRecycleGuidanceEffects`并独立于角色生命周期。满袋期间不依赖输入或工具并持续显示；回收清空后移除，第4次起不再显示。

### 永久背包通行证

- `bag09`和`bag010`的`Enabled=true`，分别提供3000/5000基础容量，Game Pass为`1935075451/1933167762`；旧玩家Schema 24迁移得到的历史区域容量继续叠加，后台基础价为49/59 Robux并展示本地区域价格。
- `bag011`的模型、Game Pass `1930772443`和即时回收分支保留，但`Enabled=false`；运行时不会查询资格、购买、装备、展示区域价格或启用即时回收。恢复时只需重新打开配置开关。
- 服务端所有权缓存是唯一资格来源；快照继续公开三项运行时所有权和查询状态，但关闭项固定为未启用，不会成为当前永久背包。功能容量与HUD继续按`bag010 > bag09 > 普通背包`计算，角色Accessory则优先读取已验证拥有的`SelectedPermanentBagVisualId`。
- `3Kback/5Kback`始终显示；未拥有时Prompt显示“购买”并使用区域价格，已拥有时显示“装备/已拥有”，服务端直接保存外观选择并更换Accessory，不打开购买界面。普通`BagLevel`仍只保存1～8并在重生时重置，永久资格不进入DataStore。
- Tool04和两种已启用背包购买台共用`GPOwned00～GPOwned15`资格组合角色碰撞组，避免多个服务互相覆盖角色CollisionGroup。全部16种玩家组彼此不可碰撞、但继续与`Default`场景碰撞；购买台仍只允许拥有对应权益的玩家组穿过。`Trashback`存在时本地隐藏且Prompt禁用，不再是启动必需对象。

### 永久Developer Product

- `ProductConfig.DeveloperProducts`保留现有数字Product ID，内部Kind为`PermanentTool/PermanentBagLevel/SkipRebirth`。Tool02/03和BagLevel03～08在收据确认后永久授予；`SkipRebirth`使用Product ID `3691791013`，每张新收据只执行一次绕过本轮资格的重生，不形成永久资格。
- 弹出窗口前必须重新读取主玩家状态：Tool02/03以`UnlockedTools`为准，目标背包以`BagLevel`为准。已用金币或Robux获得目标时拒绝弹窗；全局购买锁继续阻止并发窗口。收据由独立幂等记录处理，不能仅因当前已拥有而跳过确认。
- 独立DataStore继续使用`CleanTheFloor_RobuxEntitlements_v1`以原地迁移，记录Schema 3：`PermanentToolGrants`、`PermanentMinimumBagLevel`和最多200个`ProcessedReceiptIds`。工具取并集、背包取最高等级，重生不清除权益。
- Schema 1的`OwnedProductIds`及Schema 2的`ToolGrants/MinimumBagLevel`首次读取时通过`UpdateAsync`永久化并写回Schema 3。加载或迁移失败时权益保持未就绪并禁止再次弹窗；`ProcessReceipt`只有在`UpdateAsync`成功后返回`PurchaseGranted`，玩家离线时也可安全落盘。
- 主玩家DataStore当前为Schema 26；更新加载不再迁移或重写`UnlockedAreas`，会保留存档中当前连续的已解锁区域，未记录为解锁的区域保持关闭。真正完成普通或SKIP重生时仍按现有重置边界仅恢复Area_01。`ProcessedSkipRebirthReceiptIds`继续作为付费重生的第一层收据检查点。

## 已移除的下水道系统

- 八区不再要求或读取`sewer/sewer01`，也没有购买、解锁、吸叶和奖励入口。
- 叶子生成不再避让旧井盖范围，移动叶子停止后继续保留在世界中，只有正常收集流程会移除并推进进度。
- Tool03当前沿渐宽气流直接装袋，不依赖下水道；Tool02在靠近玩家3 studs时自动装袋，运动停止距离为2 studs。

## 双倍金币通行证

- `ProductConfig.GamePasses.DoubleCoins`登记永久Game Pass `1935165459`和倍率2；服务端在玩家状态就绪时用`UserOwnsGamePassAsync`缓存资格，并只信任服务端`PromptGamePassPurchaseFinished`的成功结果。资格不进入DataStore，查询失败安全回退x1并重试。
- 倍率覆盖回收、失物、幸运和好友收益，并在现有区域/永久叶价/重生倍率之后相乘。好友收益按实际收款人的资格处理；离线待领取数据保持基础值，领取时再乘当前永久资格。所有消费与价格保持不变。
- `GameHUD.Commodity`商品轮播已停用，客户端不再读取或等待该对象，也不再为Tool04、3K或5K背包创建HUD价格查询、Tween或购买点击；对应世界购买台保持不变。`DoubleCoinsButtonController`管理`GameHUD.HUDRoot.x2coins`和可选的`Area_01～08.Sign.Sign.SurfaceGui.TextButton`入口，两者共用Game Pass `1935165459`购买锁；区域牌支持Streaming，拥有者本地隐藏整个`Area_XX.Sign`并关闭SurfaceGui，未拥有者保持Studio原值。地区价格只写入直属`x2coins.Rb`，不得修改标题`x2coins.TextLabel`；查询失败时保留Studio手填价格。
- `StateSnapshot.PermanentToolOwnershipReady.Tool04`是非持久化资格查询状态；吸尘器只有在查询完成且未拥有时才进入商品轮播。所有权仍由`UnlockedTools.Tool04`和服务端Marketplace缓存决定。

## Quick Sell通行证

- `ProductConfig.GamePasses.QuickSell`登记Game Pass `1941655401`。服务端查询并缓存所有权，快照只读公开`QuickSellOwned/QuickSellOwnershipReady`；客户端状态不能绕过`RequestQuickSell [RemoteFunction]`中的再次验证。
- `GameHUD.Frame.QuickSell`未拥有时只打开原生Game Pass购买框；购买完成只更新资格并推送快照，不自动结算。拥有后再次点击才请求卖出，空库存不提示。
- Quick Sell叶子分支复用`BagService:TakeAll`、`EconomyService:AwardRecycleCoins`和`RecycleService`成功回调，继续应用有效叶价、双倍金币、幸运及好友分账，但不播放实体回收站的世界叶子/草地动画。失物分支复用`LostItemService`的全库存兑换，继续写`Redeemed`、清理携带Tool、记录指标并触发中央金币动画。
- Quick Sell自身锁与原有回收锁、失物商店锁叠加；两个库存分支独立尝试，一类忙碌不会阻止另一类安全结算。返回状态固定为`Sold/Empty/NotOwned/Busy/Unavailable`。

## Tool04吸尘器通行证

- `ToolConfig.Tools[4]`同时登记固定玩法属性和永久Game Pass：`GamePassId=1932106073`、后台基础价199 Robux、范围4、长度8、间隔0.1秒、每批最多10片；Roblox原生购买框负责展示玩家所在地区的实际价格。
- 服务端在玩家状态就绪时查询并缓存所有权，购买成功后立即解锁和装备。`UnlockedTools.Tool04`只是运行时资格镜像，持久化布尔值不能绕过所有权检查；重生和管理员清档从缓存恢复，不增加DataStore字段。
- `Workspace.Function`下所有直接名为`tool04`且带直接子级`ProximityPrompt`的BasePart都是购买入口。已拥有玩家触发时直接装备；未拥有玩家打开原生Game Pass购买提示。
- 客户端为每名玩家调用`GetProductInfo(GamePass)`取得当前区域价格，并只在本地更新全部`tool04.GuiPart.BillboardGui.cost.TextLabel`；查询失败时回退配置中的基础价199，不改变服务端结算。
- 客户端根据快照中的`UnlockedTools.Tool04`做个人显隐：拥有者本地隐藏购买台全部BasePart、BillboardGui和Prompt，并关闭全部后代Beam；未拥有者按Studio原始Beam状态显示。`Function.ChildAdded`和购买台`DescendantAdded`保证Streaming后状态仍正确，服务器不删除共享购买台。
- Tool04与永久背包共用购买台碰撞协调服务；购买台与符合资格的玩家角色不碰撞，但与未购买玩家保持碰撞。所有权查询、购买完成、角色重生和角色新增BasePart都会重新应用。

## 区域门

- `AreaUnlockConfig`定义Area_02～08、其前置区域和Door02～08，不包含提前解锁条件。
- 门上`ImageButton`只作为门牌且保持`Active/Interactable=false`。只有本地玩家角色身体碰到锁定的`Door01`才请求服务端解锁；服务端要求玩家在自己的庭院、直接前一区域已解锁、全部前置清理度达到100%，并满足目标区域重生门槛。客户端碰撞请求按目标区域冷却2.25秒，工具、Accessory、其他玩家和场景Part不会触发。
- 服务端写入玩家会话`UnlockedAreas`并请求生成下一区域；重复解锁不会重复生成。
- 客户端将所有区域中的同名门同步为灰色`207,207,207`和`CanCollide=false`；门牌、通知和回收提示统一读取`RegionConfig.DisplayName`，不向玩家显示`Area_0x`或“区域N”。区域解锁中央提示读取目标区域`Image`，Area_08全部完成提示读取庄园图片，缺失或空值时回退统一占位图。
- 解锁状态死亡保留、退出重置，不写入永久存档。

## 五级幸运盒子、失物金币与图鉴

- `LostItemConfig`登记五级普通失物：`LostItem01～05/Common/200`、`06～10/Uncommon/500`、`11～15/Rare/1000`、`16～20/Legendary/2500`、`21～25/Mythic/5000`。图鉴、存档白名单和累计次数使用同一顺序；`LostItem095～099`便便配置与结算完全独立且不变。
- `LostItemConfig`保存Area_01～09的五级权重，所有等级在每区概率都大于0，合计严格为100。先按区域权重选`LuckyTier`，再在对应5种失物中等概率选择最终物品。当前运行时只推进Area_01～08，休眠Area_09继续保存`7/13/20/32/28`权重以兼容旧计划和后续恢复。
- `LostItemRunProgress`仍提前保存权威`LostItemId`，但`StateSnapshot.PersonalWorldLostItems`只公开`AreaId/SpawnId/LuckyTier/WorldPivotCFrame`。Schema 27以前的旧轮计划按编号反推箱子等级，不重抽结果。
- 新计划在3～6个互不重复的渐进节点生成相应等级幸运盒子；旧轮已经持久化的计划数量原样保留。服务端在当前清扫点4 studs内生成投影，客户端从`ReplicatedStorage["Lucky Block"].Lucky001～005`克隆到`Workspace.LocalLostItems`，保留`Base.ProximityPrompt`的`OPEN`与0.5秒按住时间；地面不显示真实物品或价值。
- `LostItemConfig.TimedLuckyBox`统一配置首次180秒、循环300秒、失败重试1秒及Lucky004/Lucky005的80/20权重。玩家数据就绪后先扫描当前`LostItemRunProgress`：存在`TimedRewardKind=First/Recurring`且尚未Found的箱子时恢复为等待领取状态，不创建计时Token；否则根据`FirstTimedHighTierBoxSpawned`启动180或300秒会话Token。倒计时结束时读取当时的`CurrentAreaId`和活动庭院，位置依次尝试该区最近清扫点、角色附近合法地面、活动叶位置和区域加权地面。成功创建世界投影后追加`TimedRewardKind`条目，首次箱同时设置永久首次标记；失败保持到期状态并每秒重试。只有揭晓完成、物品成功加入快捷栏并把持久条目标记Found后，才重新启动300秒计时。该直接生成路径不调用低级箱保底消费函数。
- `StateSnapshot`提供`TimedLuckyBoxNextSpawnAt/TimedLuckyBoxWaitingForPickup/TimedLuckyBoxRewardKind`。截止时间使用`Workspace:GetServerTimeNow()`，客户端`HUDController`安全查找`GameHUD.HUDRoot.time.Value`，按`ceil(NextSpawnAt-ServerTimeNow)`每秒显示`XmYs`；首快照前为`--`，箱子待领取、揭晓中及到期生成失败重试时为`0m0s`。该节点缺失或稍后复制只影响倒计时表现，不阻塞HUD与客户端Bootstrap。
- `RequestLostItemPickup`继续由服务端验证活动庭院、SpawnId、角色存活、背包、Prompt距离、兑换状态和玩家级并发锁。成功后立即从全部当前投影移除箱子并建立`pendingReveals[player]`，在完整揭晓时序内不写Found、不增加图鉴、不创建快捷栏Tool；伪造或并发请求直接拒绝。
- 新增`LostItemRevealStarted`广播`RevealId/SpawnId/OpenerUserId/BoxTier/FinalLostItemId/RevealSeed/IsNew/RevealCoinValue`。只发送给开启者及同活动庭院50 studs内的在线玩家；价值按开启者当时的有效叶价值倍率权威计算，不包含双倍金币。客户端在`Workspace.LocalLostItemReveals`按相同Seed从全部25种普通失物中有放回抽取12轮候选，允许重复和最终物品提前出现；每轮使用5%→100%→5%的`Back Out/Quad In`脉冲，并按指数1.5从`0.06/0.04秒`减速至`0.22/0.14秒`。最终模型再用0.25秒从5%放大至100%，完成后才创建从`LostItem01.upgrade.BillboardGui`克隆的价值牌并完整展示2.5秒；此阶段不再提前显示`NEW!`。所有临时Part均锚定、无碰撞、无触碰、无查询、无重量。
- `LostItemRevealStarted`携带箱子被隐藏前的`RevealOriginCFrame`；候选、最终模型和价值牌以视觉Model包围盒中心对齐该世界位置，不读取开启者Head。`LostItemConfig.GetLuckyRevealPulseDurations/GetLuckyRevealPulseDuration/GetLuckyRevealAnimationDuration/GetLuckyRevealTotalDuration`是客户端播放和服务端授予等待共用的唯一时序接口；当前12轮脉冲约2.477秒，加最终放大0.25秒、定格2.5秒及飞入0.45秒，名义总时长约5.677秒。定格后价值牌淡出，模型以`4*p*(1-p)*1.5`的额外Y轴高度沿抛物线实时追踪开启者胸口；模型中心距离实时胸口目标超过`FlyShrinkDistance=2` studs时保持完整尺寸，进入阈值后按剩余距离以Quad In缩小至`FlyEndScale=0.15`，已达到的缩小进度只增不减。角色无效时从当前位置淡出。总时长结束且开启者仍在服时，服务端才把预定物品加入会话库存并以`shouldEquip=false`同步快捷栏；当前清洁工具和持续输入不变。库存提交失败恢复原箱并推送快照；死亡不取消授予，角色有效后补建Tool；离服清除待揭晓且不授予，原持久计划下次按同等级和同结果恢复。
- `LuckyBoxOnboarding`只对Schema 28自然新档或完整清档启用。成功授予Lucky001～003时累计，达到3次设置Pending；下一件尚未触发的计划箱若为1～3级则替换成随机Lucky004，原4/5级则保留，并在写入计划条目`Guaranteed=true`后一次性消费保底。普通重生保留该状态，Schema 27及更早缺失字段时迁移为Completed。
- 每名玩家的八区失物计划写入`LostItemRunProgress`并在同一轮重生内跨服务器保留；计划在自己和好友庭院间共用，叶子移除只推进当前庭院内每名玩家自己的计划。实际找到者获得本轮Found进度、永久图鉴次数和兑换金币，庭院主人不分走失物奖励。客户端世界容器为`Workspace.LocalLostItems`，只投影当前活动庭院的一份世界物；切换庭院时旧投影由新快照清除，同一稳定SpawnId不能同时投影多份。
- `LostItemRevealCompleted`只发给开启者，携带`RevealId/LostItemId/Succeeded/IsNew`。服务端在库存提交、图鉴计数和对应快照处理完成后发送成功结果；库存失败或游戏内重置取消发送失败结果。`LocalLostItemController`按`RevealId`同时等待本地飞行结束和权威成功结果，只有最终`IsNew=true`时才复用`HUDRoot.GetDiamond`显示`NEW!`和物品图片；重复结果、观察者、失败结果和便便失物均不显示，异常待状态在共享总时长加10秒后清理。开启者本地揭晓期间触发任意其他箱子只累计并显示`Wait (xN)`，揭晓完成后清零；观察者可同时播放多名玩家的独立RevealId。
- `Triggered=true/Redeemed=false`的普通失物在重进时于计划来源区域重新选择合法地面恢复；退出时携带的失物按`Found=true/Redeemed=false`恢复为地面物，不保存Tool或世界坐标。`Redeemed=true`永不恢复或重复结算；区域完成后仅恢复此前已触发未兑换物，不触发剩余计划。已找到图片在兑换后仍从持久计划恢复。
- 服务端按失物类型维护会话堆叠，每种类型创建一个代表Tool；`CollectibleInventoryCounts/CollectibleInventoryTotal`驱动快捷栏`xN`和兑换引导。Area_01只要`CarriedLostItem`存在就显示兑换Beam；Area_02～08还要求`CollectibleInventoryTotal > 7`。兑换Beam使用现有`StateSnapshot.UnlockedAreas`过滤当前活动庭院目标：已解锁来源区优先，来源区未解锁或无已加载商店时只在其他已解锁区域选择最近`LostItemShop.upgrade`，没有有效目标时隐藏并等待Streaming或后续快照恢复。区域开门引导的既有更高优先级保持不变。死亡后全部代表Tool恢复到Backpack，但不覆盖默认装备的最近清叶工具；离服、游戏重生和完整清档时清空。普通未兑换SpawnId仍由持久计划在下次会话恢复。
- `PoopService`按庭院维护最多20个`LostItem095～099`投影，并以全服共享注册表维护每次制造对应的唯一逻辑物品和统一`SpawnId`。服务端用相对权重`50/30/20/10/5`只选择一次等级，并把`LostItemId`写入共享条目，所以同一SpawnId在所有庭院等级一致；五种模板分别缓存落地高度与Prompt距离。Tool05有效点击立即播放独立动作并建立唯一待处理请求；读取`ToolConfig.Tools[5]`的`HopDelay=0.2`和`HopVelocity=25`，到时重新校验同一角色、同一Tool实例、同一庭院、存活且落地后，对`HumanoidRootPart`施加`AssemblyMass × HopVelocity`的纯竖直冲量。该冲量不调用`Humanoid.Jump`或跳跃状态并有独立1秒冷却；声音延迟为0.4秒，生成延迟为0.8秒。制造冷却从服务端接受请求时开始，因此Automatic可按1秒节拍连续制造；生成时再次校验脚下地面、50金币及当前活动庭院容量。当前庭院已有20个时整次失败，即使其他庭院有空位也不扣费。成功时先把同一共享条目投影到全部可用目标庭院，再扣一次50金币；创建或扣款失败会回滚全部投影。自己庭院广播、好友庭院定向；任意投影被一名玩家成功拾取后，以统一`SpawnId`从所有庭院原子删除，只向该玩家库存加入一件且保留`LostItemId/CreatorUserId`，并向全部受影响庭院成员推送快照，因此最多兑换一次。库存提交失败则只向仍低于20个的原庭院恢复投影；权限关闭、无人庭院、离服、重生和清档会解除投影，最后一个投影消失时回收共享条目。Automatic请求的失败提示按5秒限频，手动请求仍即时提示。
- `LobbyCowService`使用锚定`Cow`模型、直属`Direction` Part和六个编号路径点。启动时按地面把Cow对齐Part001，随后以5 studs/s和`0.7～1.4x`随机变速平滑巡逻；不创建Weld或修改碰撞、点位与Direction外观。每5秒从Direction反向2 studs向真实地面投射并调用`PoopService`创建大厅共享大便；最多30件，水平间距不足2 studs时跳过，60 studs内玩家收到现有便便声音。结构无效会警告一次并关闭牛功能，不影响Bootstrap。
- 大厅大便使用独立运行时集合和`ActiveLobbyPoops`，不进入`ActiveYardPoops`、庭院权限/容量、玩家消费或制造排行榜。客户端与庭院大便合并投影并复用五级揭晓和`RequestPoopPickup`，但隐藏制造者Billboard；拾取后全服删除，库存CreatorUserId为空，所以所有玩家按实际等级固定价值出售。成功加入库存后，大厅与庭院拾取统一触发权威成功回调。
- `PoopController`收到新SpawnId后隐藏真实模型、制造者牌和Prompt，将另外四种大便模板随机打乱并按普通失物的放大/缩小减速节奏依次轮播，最后放大真实等级。轮播克隆会删除脚本、Prompt、BillboardGui和全部`Highlight`，最终克隆也删除全部`Highlight`；条目删除、切庭院或并发拾取会取消Tween并清除临时模型。动画结束后才显示制造者头像/文字并按既有5秒制造者限制启用Prompt。
- `LostItemShop`按五级普通失物基础`200/500/1000/2500/5000`结算。服务端按每件普通失物应用收款人的有效价值倍率并向下取整，汇总后再应用双倍金币。五级大便按`LostItemId`分别堆叠；`LostItem099.DisplayName=Rainbow Poop`，其余四级为`Poop`。制造者实例固定10，其他玩家实例按`10/100/300/1000/2000`结算，大便部分始终跳过叶价、重生和双倍金币。混合兑换一次合并到账；存在大便固定额时金币事件用真实总额和`x1`表示，避免显示误导性的整批`x2`。普通失物原地揭晓和持有Tool的价值牌显示有效单件/堆叠价值；达到货币上限时以实际到账值为准。
- 教程完成后的首次普通金币背包购买会在`OnboardingFunnel`写入一次性便便引导。制造阶段只有权威金币严格大于100时显示`You can now make poop for all players!`并脉冲Tool05快捷栏；制造成功后以该`SpawnId`进入Pickup阶段。教程便便向本服所有客户端投影，但`TutorialPickupUserId/PickupAllowed`使其仅能由制造者立即拾取；拾取后进入Sell阶段并绕过普通失物8件门槛指向最近的已解锁`LostItemShop.upgrade`。实体兑换和Quick Sell共用权威兑换清单，只有清单包含同一SpawnId时才永久完成。临时阶段和SpawnId不保存；普通或SKIP重生将未完成状态标记为完成且不再重启，只有未重生玩家退出重进时从Make恢复；旧存档缺少引导字段时不补发。
- `LostItem099.Model["1"]`的模板内嵌Script不会随克隆运行，仍按安全规则删除。`PoopController`使用单一Heartbeat和服务器时间相位，以原速度`0.15`统一驱动世界最终模型、生成轮播假模型及所有玩家当前手持的LostItem099；活动部件使用Neon和HSV彩虹色，卸下、销毁或清理时恢复原始颜色与材质并解除引用。
- 失物兑换的`CoinGainEvent`携带`CenterReward=true`，金额仍按整批显示；成功结算后另以权威有效库存件数设置`SoundKind="LostItem"`，让每件失物按0.1秒间隔播放一次`SoundService.demo`。实体兑换和Quick Sell规则一致，空库存、失败或重复条目不产生声音。客户端同时播放右上角`CoinsFrame.+Value`与保留名称的`GetDiamond`中央金币提示；中央显示`+最终实际到账金币`、使用金币图并飞向`CoinsFrame.Value`。同一笔必须等待两套动画都结束，连续兑换及叶子/失物声音由单一队列按事件顺序播放。
- 图鉴为每种普通失物使用`5/10/20/40/80/100`累计节点；存在下一档时Claim按钮始终显示，未达标点击只在客户端提示“找到X个可领取X金币”，达标后才提交领取ID。服务端按`CollectedCounts`和`CodexClaimedTiers`验证下一档，基础金币依次为`50/100/200/400/800/1000`，只叠加双倍金币并逐档领取。
- 教程手机和`LostItem100`已移除；失物服务不再生成、恢复或处理教程专属物品。

## 新手教程

- `TutorialService`按DataStore中的`TutorialProgress`恢复会话，依次验证累计实际装袋或即时回收15个叶子实体、第一次成功卖出、双手拾取数量升级、第二次成功卖出和双手拾取速度升级；每个成功处理的叶子实体只计1片，不按`BagValue`累计。死亡和首次重生前的退出重进均保留；普通或SKIP重生把`Step`固定为`Complete`并关闭所有后续一次性引导，加载任何`RebirthCount > 0`的历史档时也应用同一收口，日期或管理员完整清档才恢复默认教程。旧档若仍停在第1步但已有15～19片，读取时直接进入Area_01回收步骤。
- 原数字步骤4复用为`WaitForSecondRecycle`，保存兼容字段`SecondRecycleSucceeded`且不提升Schema。世界回收、Quick Sell和即时回收只有实际到账大于0时才算成功；数量升级后的下一次成功事件进入速度步骤。速度引导仅在当前金币足够支付下一等级时返回`TargetKind="Upgrade"`，只有成功升级双手`Speed`才完成教程，Tool02/03升级不参与推进。
- `TutorialController`仅在第1步复用`HUDRoot.yin`显示按住拾取，并按服务端`LeafCount/LeafGoal`显示`0/15`至`15/15`、在实际处理第15片后隐藏。数量和速度升级都不自动打开面板；关闭时克隆独立Beam指向Area_01升级台，玩家主动打开后切换到`Hands`页，并通过`UIScale`让对应购买按钮循环放大至原比例的1.12倍。面板关闭、目标失效或正确属性升级成功时取消Tween并恢复原比例。
- 速度升级后`Step`仍进入`Complete`，但符合条件的新玩家保存`BagGuidancePending=true、BagGuidanceReady=false`。教程完成后的每次成功回收都以金币结算后的余额检查下一袋价格；首次满足价格且永久背包资格已确认、没有生效永久背包时保存`BagGuidanceReady=true`。服务端仅在两个标记有效、仍为基础普通背包且当前金币足够时返回`TargetKind="BagUpgrade"`，不再要求袋满；客户端优先连接当前区域`BagProduct_01`，Streaming缺失时每0.25秒从已解锁区域选择最近的已加载购买点。首次普通背包购买成功后在最终快照前清除并保存两个标记。

## 重生资格与流程

- `Frame.Rebirth`是唯一重生入口。`RebirthService`以玩家自己的权威状态判断普通重生资格：Area_01～04全部达到100%且当前主动解锁的所有更后区域也达到100%，或本轮`RainbowPoopFoundCount >= (RebirthCount + 1) × 5`。`LostItem099`只有在大厅或庭院权威拾取成功并进入库存后才增加计数，失败、重复请求和其他便便等级不计；计数封顶、退出重进保留，普通/SKIP重生与完整清档归零。`StateSnapshot`返回`RebirthEligible/RainbowPoopFoundCount/RainbowPoopRequiredCount`，客户端不自行推断。普通重生清空本轮区域进度及Area_02～09解锁，只恢复Area_01。
- 合法玩家在好友庭院中请求时先通过`YardService`返回自己的庭院，再停止工具输入并调用`PlayerDataService:ResetForRebirth`清空本轮养成，清除失物，并把教程会话重建为完成状态，然后重建房主庭院叶子并重新生成角色。服务端互斥锁保证UI、Prompt和重复点击只执行一次。
- 重生保留`PlayerAttributeLevels`、`LegacyAreaBagCapacityBonus`、`CollectedCounts`、`CodexClaimedTiers`、好友奖励防重复ID、待投递给其他玩家的奖励及排行榜历史最好/待提交秒数；未领取好友金币不会保留。重生成功后`ClearSpeedrun`以新`RebirthCount`清零本轮累计并立即从当前`os.clock()`开始下一轮。镜头模式只在本地当前会话存在，不进入重生数据。
- `RebirthCount`永久保存且不设上限。`Header.number`显示其纯数字；`RebirthLeafValueMultiplier=1+RebirthCount×1.5`显示为`数值x Cash`，`LeafCountMultiplier=1+RebirthCount×0.5`显示为`数值X Quantity`，工具及升级价格仍乘`2^RebirthCount`。有资格时启用`RobuxPurchase.Stud.Cost`渐变，无资格时启用`Owned/Locked`渐变。
- `Buttons.SKIP`始终显示并只打开Developer Product `3691791013`购买框。收据由服务端与普通重生共用玩家锁，唯一差异是跳过本轮清区或Rainbow Poop资格；成功后仍执行相同清档、庭院重建、角色重载和快照同步。
- 重生点的位置、距离、视线要求和`HoldDuration`由Studio设置，运行时代码只连接`Triggered`，不覆盖这些属性。

## 永久存档

当前DataStore：

```text
Name: CleanTheFloor_PlayerCollectibles_v1
Key:  Player_<UserId>
SchemaVersion: 25
```

有效Payload：

```luau
{
    SchemaVersion = 25,
    DataResetDateKey = 20260807,
    DataResetNoticeDateKey = 20260807,
    Coins = number,
    BagLevel = number,
    BagExpansionLevel = number,
    CurrentBagValue = number,
    BagCycleId = number,
    BagSourceValues = { [OwnerUserId] = number },
    SelectedPermanentBagVisualId = "bag09" | "bag010" | nil,
    AllowGuestPoop = boolean,
    CommunityRewardClaimed = boolean,
    UnlockedTools = { [ToolId] = boolean },
    HandUpgradeLevels = { [AttributeId] = number },
    ToolUpgradeLevels = { [ToolId] = { [AttributeId] = number } },
    PlayerAttributeLevels = { MoveSpeed = number, LeafValue = number, Luck = number },
    LegacyAreaBagCapacityBonus = number,
    LastEquippedTool = ToolId,
    TutorialCompleted = boolean,
    TutorialProgress = {
        Step = number,
        LeafCount = number,
        TargetAreaId = AreaId?,
        AmountUpgradeSucceeded = boolean,
        SpeedUpgradeSucceeded = boolean,
        SecondRecycleSucceeded = boolean,
        BagGuidancePending = boolean,
        BagGuidanceReady = boolean,
    },
    OnboardingFunnel = {
        Version = 1,
        Eligible = boolean,
        HighestStep = number,
        CollectedLeaves = number,
        HasRecycled = boolean,
        OrdinaryBag2Purchased = boolean,
        BroomPurchasedWithCoins = boolean,
    },
    ClearSpeedrun = {
        Version = 1,
        Eligible = boolean,
        RunRebirthCount = number,
        Completed = boolean,
        AccumulatedSeconds = number,
        BestSeconds = number?,
        PendingBestSeconds = number?,
    },
    YardProgress = {
        UnlockedAreas = { [AreaId] = boolean },
        Areas = { [AreaId] = { ClearedRatio = number } },
    },
    PendingFriendRewards = table,
    ProcessedFriendRewardIds = { string },
    ProcessedSkipRebirthReceiptIds = { string },
    PendingFriendDeliveries = table,
    RebirthCount = number,
    LostItemRunProgress = {
        RebirthCount = number,
        Areas = {
            [AreaId] = {
                BaseSpawnCount = number,
                LuckRoll = number,
                Items = {
                    {
                        LostItemId = string,
                        TriggerProgress = number,
                        Triggered = boolean,
                        Found = boolean,
                        Redeemed = boolean,
                    },
                },
            },
        },
    },
    CollectedCounts = { [LostItemId] = number },
    CodexClaimedTiers = { [LostItemId] = number },
}
```

- 加载与保存最多重试3次；使用`UpdateAsync`覆盖上述白名单字段。离开或关服的最终同步保存会先等待已排队保存结束，再写当前最新状态，避免旧Payload晚到覆盖新进度。
- 购买/升级、区域解锁、区域进度、新收藏、奖励领取、60秒自动保存、离开和关服会请求保存。
- 正式服务器加载失败时移除玩家；Studio未开启API时使用临时收藏数据并警告。
- `CollectedCounts`读取时只接受当前25个ID；旧玩家01～10计数原样保留，11～25缺失时按0处理。
- `CodexClaimedTiers`只接受当前25个ID并限制在0～6档；SchemaVersion 2及更早数据缺少该字段时按未领取处理，已有累计次数可以逐档补领。
- Schema 13及更早数据中的`YardProgress.UnlockedSewers`在加载时忽略，并在完整保存或离线好友奖励更新时删除；旧购买记录不退款。
- SchemaVersion 7及更早数据缺少`RebirthCount`时按0迁移。SchemaVersion 8旧档缺少`PlayerAttributeLevels`时三个等级均按0迁移。SchemaVersion 9旧档缺少`TutorialProgress`时按现有规则恢复；SchemaVersion 10旧档缺少`SelectedPermanentBagVisualId`时默认使用已拥有的最高档外观，并在玩家主动切换后保存。
- Schema 11及更早旧档首次读取时执行`Coins += Diamonds × 10`并删除`Diamonds`，结果受金币安全上限保护；转换不发送`CoinGainEvent`且不应用双倍金币。在线加载和离线好友奖励`UpdateAsync`路径都先执行同一幂等迁移，保存失败重试不会重复转换。
- Schema 15新增`LostItemRunProgress`。Schema 14及更早旧档缺失时按当前重生次数创建空计划，并在玩家首次进入未完成区域时立即抽取和保存；不能从永久`CollectedCounts`反推旧区域进度。稳定SpawnId由玩家ID、重生次数、区域ID和项目索引生成，不直接保存。成功重生和白名单完整清档清除本轮计划；世界坐标、客户端实例和携带Tool仍不进入DataStore。
- Schema 16新增`AllowGuestPoop`，旧档默认`true`；该字段在游戏重生中保留、完整清档恢复默认。世界大便和全部会话堆叠不进入DataStore。
- Schema 17使用`DataResetDateKey`作为每名玩家已应用的清档版本。`DataResetConfig`当前配置`Enabled=true`、版本日期`2026-08-07`；开启时，标记缺失或小于`20260807`的档案清除全部非Robux字段并写入当前版本，相同或更新标记正常加载。配置日期不与现实时间比较；错过日期的玩家以后上线仍补做，配置继续递增后每名玩家再执行一次。关闭开关时旧档及标记保持；全新玩家直接写当前版本，之后开启相同版本不会误清。
- Schema 18的`TutorialProgress`保留`BagGuidancePending`并增加可选`BagGuidanceReady`。`Ready`缺失时默认`false`，现有Pending玩家会等待下一次满足价格的成功回收；Pending缺失或为false的更早完成档不会补做。
- Schema 19新增`CommunityRewardClaimed`。旧档默认`false`，已在社区中的旧玩家由服务端验证后补发一次1000金币；普通重生保留，日期或管理员完整清档清除。奖励标记与金币进入同一白名单Payload，不应用任何金币倍率。
- Schema 20新增正式`OnboardingFunnel`进度。只有本版本上线后自然首次创建的档案设为`Eligible=true`；Schema 19及更早旧档、日期清档和管理员测试清档均不补发漏斗。`HighestStep`只在正式Onboarding API调用成功后推进；`CollectedLeaves`按实际进入普通背包的叶子实体累计至15，`HasRecycled`记录首次成功发币回收。两个仅服务端使用的购买标记区分普通金币背包/扫把与Developer Product授权，保证提前完成的后序条件可跨服等待且不会误算Robux购买。兼容字段`PoopGuidancePending/PoopGuidanceCompleted`保存一次性便便引导，`BroomGuidanceReady/BroomGuidanceCompleted`保存完成便便教学后、叶子结算余额达到825触发的一次性扫把引导；这些字段不改变漏斗版本或10步Analytics定义。普通或SKIP重生保留正式漏斗进度，但把可见的便便及扫把引导标记为完成，避免重生后继续显示新手提示。
- Schema 25曾新增第9区并将`ClearSpeedrun`内部版本升至2；当前暂停Area_09并恢复Area_08为计时终点。Area_08尚未完成的合格计时继续累计；加载时已经完成Area_08的未完成计时因无法还原真实完成时刻而退役且不提交，历史最好仍从原OrderedDataStore恢复。普通重生只重置当前轮并保留已恢复或新提交的历史最好与待提交成绩。
- Schema 26的新档初始只解锁Area_01；当前加载路径不再重写旧档的已解锁连续区域，避免更新时关闭玩家已有区域。兼容字段`RainbowPoopFoundCount`缺失时为0且不提升Schema版本。
- Schema 30将永久字段迁移为`LuckyBoxOnboarding.FirstTimedHighTierBoxSpawned`。Schema 29读取旧`TimedTier4BoxSpawned`并完整保留真假值，Schema 28及更早旧档迁移为`true`且不补发首次奖励；Schema 30自然新档和完整清档默认为`false`，普通重生复制该字段。`LostItemRunProgress.Items`使用可选`TimedRewardKind=First/Recurring`恢复尚未领取的定时箱，旧`TimedOnboardingReward=true`迁移为`First`；指标分别使用`TimedFirstHighTierReward`和`TimedRecurringHighTierReward`，并继续记录实际等级、区域、Guaranteed及IsNew。Schema 28原有低级箱保底三个字段与迁移口径保持不变。
- Schema 24移除区域奖励发放。首次加载旧档时，按旧`AreaRewardClaims`中每个包含Area_06位的庭院固化`+200`到`LegacyAreaBagCapacityBonus`；自己庭院Area_06进度已完成但领取位缺失时兼容补算一次。迁移后删除旧位图，幸运、叶价和移动速度区域奖励立即失效，容量在重进和普通重生时保留；日期或管理员完整清档将其清零且不能重新获得。
- 可选`DataResetNoticeDateKey`记录已经向玩家说明过的清档版本。实际清档时先留空；在线玩家收到说明后写成`DataResetDateKey`并立即排队保存。离线好友奖励首次命中旧版本时先清档并保留当前奖励，后续同版本奖励正常累计；玩家上线保留奖励并补显示一次说明，重进不再提示。普通保存、管理员测试重置和游戏重生均保持两个日期字段。
- 日期清档不复制任何普通字段，因此金币、背包/工具、升级、区域、重生、教程、图鉴、好友奖励、设置、失物计划、外观选择及`AllowGuestPoop`全部恢复默认。Robux永久商品不属于DataStore，由双倍金币、Tool04和永久背包服务重新查询Roblox Game Pass所有权后恢复。
- 旧Schema 11存档中的`KeyCounts`字段不再加载或进入状态，并会在下一次完整保存时自然移除。

### 永久排行榜

- 排行榜继续使用升序OrderedDataStore `CleanTheFloor_ClearTimeLeaderboard_v1`，Key为`Player_<UserId>`，值为四舍五入后的完整正整数秒。当前Area_08成绩继续写入同一榜；`UpdateAsync`只在候选值更小时替换，重生、日期清档、管理员清档和主玩家DataStore删除都不会删除该历史记录。曾建立的空`v2`榜不再读取、迁移或删除。
- `LeafService:_completeArea`在权威进度写为100%后触发区域完成回调，并传递`yard.Owner`；`ClearTimeLeaderboardService`只处理`RegionConfig.FinalAreaId`（当前Area_08），因此好友协助贡献庭院进度但成绩归庭院主人。
- 提交失败时主存档保留最小`PendingBestSeconds`；每次提交最多尝试3次，玩家重进和在线60秒轮询继续补交。提交成功后同步主存档缓存并立即请求刷新Top 20；正常缓存也每60秒刷新。
- 四榜共用`LeaderboardUsernameResolver`解析账号`Username`：在线玩家直接读取`Player.Name`，其余Top候选通过`UserService:GetUserInfosByUserIdsAsync`批量查询并共享成功缓存。查询按立即、1秒后、3秒后最多尝试3次；临时失败时显示由UserId确定性生成且不含数字的`PlayerABC`式代称，后续60秒刷新成功后自动替换为真实用户名。一次成功批量响应中没有返回的账号视为无效并隐藏整行，但不删除OrderedDataStore记录；其余玩家继续保留原始名次，允许出现跳号。最快时间榜另按UserId映射Top条目，避免隐藏行后Self成绩或排名被数组位置错配。
- `PlaytimeLeaderboardService`使用普通DataStore `CleanTheFloor_Playtime_v1`和降序OrderedDataStore `CleanTheFloor_PlaytimeLeaderboard_v1`。每次加入生成GUID Session ID；在线秒数从PlayerAdded的`os.clock()`开始，每60秒及离服时提交。四榜以服务器启动后的`0/5/10/15`秒固定错峰读取旧Top 20，先广播旧榜再串行提交本服新统计；所有读写先检查请求预算，预算不足等待5秒，请求失败按`5/15/30/60`秒退避。普通DataStore保留最近32个`SessionCheckpoints`，`UpdateAsync`只增加同一会话检查点相对上次的差值，重复回调或不确定重试不会重复累计。在线总时长独立于PlayerData Schema，因此普通重生和任何完整清档都不删除。
- `CleanupLeaderboardService`使用普通DataStore `CleanTheFloor_CleanupCount_v1`和降序OrderedDataStore `CleanTheFloor_CleanupLeaderboard_v1`。它在`LostItemService`之后通过`LeafService:AddLeafCollectedHandler`注册，避免被失物服务初始化时的`SetLeafCollectedHandler`清除；每次`_collectLeaf`成功移除权威叶子后给实际收取玩家增加1，不按BagValue、庭院主人或网络批次数计算。普通装袋与即时回收均计入，失败、重复或区域完成时清除的剩余模型不计入；统计没有增加时跳过普通与Ordered写入，普通总数成功后保留待同步总数直到Ordered写入成功，玩家重新加入会自动对账。
- 两个永久累计服务的普通记录与OrderedDataStore每次最多重试3次，成功后请求刷新榜单；Top 20另每60秒缓存刷新。若普通记录已写而Ordered写入失败，下次周期或重进会以累计总值补交。最近32个会话检查点只用于幂等，不进入PlayerData存档且不升级Schema。
- 服务端时间榜按完整秒数排序；共享`DurationFormat.HoursMinutes`向下舍去不足一分钟的秒数，小时为0时显示`00m/05m/59m`，有小时时显示`1h05m/100h00m`。清理和便便数量使用`CoinFormat.Compact`的紧凑整数且不带货币符号。四个榜的Self在Top 20内显示精确`#N`，有历史成绩但榜外显示`#20+`，无成绩显示`#--`以及`00m`或`0`。

## Remote契约

| Remote | 类型 | 方向 | 当前用途 |
|---|---|---|---|
| `EquipTool` | RemoteFunction | 客户端→服务端 | 装备、卸下或切换清洁工具 |
| `UpgradeHandAttribute` | RemoteFunction | 客户端→服务端 | 升级双手`Range/Speed/Amount` |
| `UpgradeToolAttribute` | RemoteFunction | 客户端→服务端 | 升级Tool02/03白名单属性 |
| `UpgradePlayerAttribute` | RemoteFunction | 客户端→服务端 | 权威升级`MoveSpeed/LeafValue`并返回`upgraded, message, latestSnapshot` |
| `ClaimCodexReward` | RemoteFunction | 客户端→服务端 | 请求领取指定失物的下一档图鉴奖励，由服务端验证次数和已领取档位；第三个返回值为实际到账金币 |
| `ClaimCommunityReward` | RemoteFunction | 客户端→服务端 | 请求服务端验证Group ID `220344414`并领取一次性1000金币；返回`Status/IsMember/Claimed/AwardedCoins` |
| `RequestRebirth` | RemoteFunction | 客户端→服务端 | 请求重生；服务端重新校验“清完Area_01～04及全部主动解锁后续区域”或本轮Rainbow Poop数量资格并返回`success, message` |
| `RequestReturnToSpawn` | RemoteFunction | 客户端→服务端 | 将存活角色权威移动到本Place唯一启用的`Workspace.SpawnLocation`，返回`success, message` |
| `RequestProgressSave` | RemoteFunction | 客户端→服务端 | ESC/CoreGui菜单打开后请求保存当前权威进度；服务端按玩家锁和10秒限流返回`Saved/Failed/Unavailable/Busy/Cooldown`，客户端不能提交状态 |
| `EnterYard` | RemoteFunction | 客户端→服务端 | 直接进入指定的本服务器玩家庭院 |
| `SetPoopPermission` | RemoteFunction | 客户端→服务端 | 永久切换是否允许其他玩家向自己的庭院制造大便 |
| `RequestMakeTrash` | RemoteEvent | 客户端→服务端 | Tool05制造请求；可选布尔参数标记Automatic来源，位置、费用、冷却和投递庭院仍由服务端决定 |
| `RequestPoopPickup` | RemoteEvent | 客户端→服务端 | 请求拾取当前庭院的五级共享大便SpawnId；等级由服务端共享条目决定 |
| `StateSnapshot` | RemoteEvent | 服务端→单客户端 | 权威状态与UI快照 |
| `ClearTimeLeaderboardSnapshot` | RemoteEvent | 服务端→单客户端 | 只读Top 20与Self快照；客户端只可发送字符串`Request`请求缓存，不能提交成绩 |
| `PlaytimeLeaderboardSnapshot` | RemoteEvent | 服务端→单客户端 | 只读永久在线时长Top 20与Self快照；客户端只可限流读取缓存，不能提交秒数 |
| `CleanupLeaderboardSnapshot` | RemoteEvent | 服务端→单客户端 | 只读永久清理叶子数量Top 20与Self快照；客户端不能提交数量、用户名或排名 |
| `PoopLeaderboardSnapshot` | RemoteEvent | 服务端→单客户端 | 只读永久制造便便次数Top 20与Self快照；客户端只能限流请求缓存，不能提交次数、用户名或排名 |
| `LeafCollected` | RemoteEvent | 服务端→单客户端 | 批次实际入袋总数、首片类型、工具ID及可选逐片`leafHints`价值列表 |
| `LeafPickupBatch` | RemoteEvent | 服务端→单客户端 | 成功批次的工具、间隔和数量反馈 |
| `BagFullPickupAttempt` | RemoteEvent | 服务端→单客户端 | 袋满时继续使用双手的反馈 |
| `CoinGainEvent` | RemoteEvent | 服务端→单客户端 | 所有正向金币的基础值、倍率、最终值、分段动画及可选`SoundKind/SoundCount/SoundFirstDelay/SoundInterval`；失物兑换可带`CenterReward=true` |
| `RequestLostItemPickup` | RemoteEvent | 客户端→服务端 | 请求拾取指定SpawnId失物 |
| `LostItemRevealStarted` | RemoteEvent | 服务端→附近客户端 | 广播同庭院50 studs内权威幸运盒揭晓结果、随机种子、首次标记和开启者价值 |
| `LostItemRevealCompleted` | RemoteEvent | 服务端→开启者 | 通知指定RevealId是否已成功加入会话库存，并携带最终首次获得标记 |
| `SetLeafPickupActive` | RemoteEvent | 客户端→服务端 | 手动与Automatic合并后的持续清洁输入，只接受布尔按住/松开状态；实际批次间隔由服务端当前工具属性决定 |
| `UpdateHarvestAim` | RemoteEvent | 客户端→服务端 | `valid, aimOffset, playerCentered`；提交受限水平偏移，或纯触屏零偏移玩家中心模式 |
| `RequestAreaUnlock` | RemoteEvent | 客户端→服务端 | 请求解锁Area_02～08 |
| `Notification` | RemoteEvent | 服务端→单客户端 | HUD短提示，可选停留秒数和高优先级标记 |

当前没有多人大厅、跨Place Teleport或`LobbyAction`。`RequestReturnToSpawn`只在当前Place内移动现有角色，不重载角色、不切换庭院、不修改背包、装备、Automatic或玩家进度；移动前停止手动持续清扫和工具动作，并清零角色线速度与角速度。

`StateSnapshot`在原有经济、工具、区域、教程和图鉴状态外，增加`AllowGuestPoop`、`CommunityRewardClaimed`、`ActiveYardPoops`、`ActiveLobbyPoops`、`ActiveYardVisitors`、`CollectibleInventoryCounts`和`CollectibleInventoryTotal`。`ActiveYardVisitors`只包含当前活动庭院内除主人外的在线成员，并以`{UserId, DisplayName}`描述；进入、返回、切换庭院和离服会刷新受影响庭院的全部成员。`CommunityRewardClaimed`用于客户端隐藏社区按钮，并在同局完整清档后重新验证；`ActiveYardPoops`通常描述玩家当前活动庭院的共享世界物，教程便便则额外投影给本服所有玩家，每项包含`SpawnId/LostItemId/CreatorUserId/CreatorName/CreatorPickupUnlockTime/WorldPivotCFrame`及可选`TutorialPickupUserId/PickupAllowed`。`ActiveLobbyPoops`是全服共享NPC大便，只包含运行时`SpawnId/LostItemId/WorldPivotCFrame`及隐藏制造者牌标记；`CarriedLostItem`继续提供一个代表条目给现有兑换引导兼容使用。`TutorialState`额外返回`PoopGuidanceStage/PoopGuidanceSpawnId/PoopGuidanceActive`。

四个排行榜Remote均独立于`StateSnapshot`。时间榜包含`Entries[{UserId, UserName, TimeSeconds, Rank}]`和`Self{UserName, TimeSeconds?, RankText}`，清理榜对应字段为`LeafCount`，便便榜对应字段为`PoopCount`。共享`TimeLeaderboardController`不会`WaitForChild`场景榜；若Streaming尚未载入`WinsBoard/PlaytimeBoard/gold/POOP`，它每秒非阻塞重试，分别保留最后快照并在对象出现后渲染。

## 验收B记录契约

- `PlaytestMetricsService`只记录服务端确认的事件，不新增客户端奖励Remote。
- Studio以`[CleanTheFloorMetrics]`前缀输出JSON字段和退出汇总；正式服务器通过`AnalyticsService:LogCustomEvent`上报`ctf_b_*`事件。
- 已记录首片、首次袋满、回收、购买/升级、区域进入、25/50/75/100%里程碑、失物计划/生成/拾取/兑换、区域解锁、退出点和Area_08完成；区域解锁方式固定为`AreaCleared`。`PlayerAttributeUpgrade`购买记录额外包含属性ID、目标等级和金币消耗，退出时每个工具另上报`tool_summary`的有效时间/动作/影响叶子数。
- 正式新手漏斗与`ctf_b_*`并行。符合资格的新玩家由服务端严格顺序调用`AnalyticsService:LogOnboardingFunnelStepEvent`，步骤名称依次为`Enter Game`、`Collect First Leaf`、`Collect 15 Leaves`、`Recycle Leaves for the First Time`、`Upgrade Pickup Amount for the First Time`、`Upgrade Pickup Speed for the First Time`、`Upgrade Bag 1 to Bag 2`、`Unlock Area 2`、`Unlock Area 3`、`Purchase First Broom`。后序条件可提前完成并保存，但不得跳过未满足的前序调用；Studio仅以`[CleanTheFloorOnboarding] Step X/10`验证顺序，正式报表需发布服务器产生。
- Area_04～09仍使用固定名称`AreaUnlockProgression_04_09_v1`调用`AnalyticsService:LogFunnelStepEvent`，步骤1～6依次为`Unlock Area 4`至`Unlock Area 9`。当前Area_09停用，只会上报前5步；`RecordAreaUnlocked`显式拒绝非活动区域，伪造Area_09请求不会产生漏斗事件。调用不传`funnelSessionId`，由Roblox按玩家终身首次步骤去重；漏斗ID与历史步骤编号不变。
- 原始记录只用于验收与平衡，不改变奖励、存档或玩家状态。

## 客户端UI与镜头

- HUD只显示服务端快照；`CoinsFrame.Value`仅显示经过`CoinFormat.Compact`格式化的金币数值，不添加`Coins:`等说明前缀。货币和容量使用同一紧凑规则；等级、百分比、范围、功率、任务/图鉴/区域进度和普通物品数量继续显示精确值。普通`GameHUD.NotificationFrame.Notification`默认停留2.25秒并用0.25秒淡出。教程前3步可设置常驻底层文字，普通提示临时覆盖后自动恢复。`ExitSaveController`监听`GuiService.MenuOpened/MenuClosed`；菜单打开后仅在`RequestProgressSave`权威成功时常驻显示`Progress saved.`，失败显示`Save failed. Please try again.`，菜单关闭立即撤销并恢复教程底层文字。真正离服继续执行现有`PlayerRemoving`最终同步保存。
- `TrailMultiplierDisplay.TrailMultiplierLabel`显示权威`PersonalLeafValueMultiplier`，与Value Multiplier升级卡的当前个人升级倍率保持一致，格式为`Multiplier x1 (Upgrade)`；`RebirthMultiplierDisplay.RebirthMultiplierLabel`独立显示权威`RebirthLeafValueMultiplier`，格式为`Multiplier x1 (Rebirth)`。两者随每次快照刷新，整数不显示小数，非整数最多显示两位小数。
- `StateSnapshot.AreaCollectedLeafCount/AreaTotalLeafCount`是当前活动庭院、当前区域的叶子实体计数，不进入存档；`AreaProgressFrame.Value`以无空格`已收集/总数`显示。`Icon`读取`LeafConfig.AreaPools[CurrentAreaId][1]`对应类型的图片，缺失时保留Studio默认图片。图形进度条`AreaProgressFrame.BarBackground`已删除，客户端不再等待或更新该节点；服务端`AreaProgress`继续用于区域完成及其他玩法逻辑。客户端也不再读取已删除的`AreaProgressFrame.luck`。
- `CommunityController`连接`HUDRoot.jiaqun`并在客户端调用`GroupService:PromptJoinAsync(220344414)`。权威快照未领取时调用`ClaimCommunityReward`，由服务端`IsInGroupAsync`验证；旧会员自动补发，加入结果为`Joined/AlreadyMember`时按0/1/2/4/8秒有限重试以兼容会员状态同步延迟。领取或已领取后只隐藏PlayerGui克隆，StarterGui模板保持不变；`JoinRequestPending`不隐藏也不发奖。HUD初始化5秒后的自动提示和本局手动防重复规则保持。
- `Lossofprogress.Visible`完全继承Studio模板设置，客户端初始化、区域完成、区域切换和庭院切换都不修改父Frame可见性；收到当前活动庭院快照后仍实时更新本区失物次数与图片。内部`ItemFrame`继续作为隐藏模板，运行时找到的失物克隆仍由客户端显示和清理。
- `NotificationFrame02`是可购买提示模板。金币首次达到候选价格时，客户端只显示金币购买的Tool02/Tool03和下一级普通背包；属性升级、工具升级、背包扩容和Robux商品不进入提示2。同屏最多4条，多余候选排队；每条沿用现有滑入、停留、渐隐和补位动画。升级按钮`tixin`仍独立提示可购买的属性升级。
- 未解锁工具只提示购买，不提示其属性；持续买得起期间同一候选只显示一次，变得买不起后再次攒够可重新提示。回收金币表现结束前暂缓弹出候选。
- `LeafCollected(totalAmount, firstLeafType, toolId, leafHints)`的有效逐片项进入短时节拍队列。队列为空且距离上次生成已达到0.04秒时首个立即生成；其余由单一Heartbeat连接按0.04秒最多取1项，低帧率不会按累计时间追赶并在同一帧创建多个。`OutstandingLeafHintCount`同时计算已排期与正在播放的提示，最大30；每次入队按剩余额度随机保留可接受项，超额项立即省略、不合并金额也不延后补播。提示完成、目标失效和启动异常均只释放一次额度；队列清空即断开Heartbeat。权威入袋、教程、声音和结算保持不变。`DisplayValue`由服务端按`本片BagValue × 区域 × 个人Leaf Value × 重生`计算，不含双倍金币、幸运或好友收益；客户端整数省略`.0`、小数最多一位，1k以上沿用紧凑单位。缺少逐片列表的旧事件按`totalAmount × 当前快照叶价`排入一个提示。
- `GetHint`按HUD尺寸分布：外椭圆直径约为可用区域90%宽、80%高，15%落在中心30%半径的小椭圆，85%落在外环并用平方根半径取样进一步偏向外围。范围按克隆尺寸收缩且四边至少保留24像素；0.1秒放大、停留0.2秒，随后用1秒飞向`BagFrame.BarBackground`实时中心，并同步完全渐隐和缩至原大小20%。克隆显示前按`LeafConfig.Types[leafType].Image`设置`Icon.Image`；未知类型、缺失或空图片回退到Studio模板当前图片。`CenterFlyUIEffect.Play`的可选`FlyEndScale`与移动、渐隐共用飞行Tween参数；可选`OnFinished`在正常完成、目标失效或异常回收时只调用一次，用于释放HUD提示额度。回收前统一取消Tween并恢复透明度、可见性、文字、图片、位置和`UIScale`，避免持续Clone/Destroy或复用尺寸串联。
- `BagFrame.name`显示当前背包配置的英文名称，不显示`Lv.X`；启用中的bag01～bag010依次使用`Trash Pack/Chick Pack/Cow Pack/Rover Pack/Paw Pack/Super Pack/Fruit Pack/Blackwing Pack/Angel Pack/Space Pack`。`BagFrame.Value`的当前装载量和最大容量都通过`CoinFormat.Compact`显示且不留空格，例如`1.2k/5k`；小于1k仍显示整数。普通背包购买台`ObjectText`只显示`Capacity 100`等目标容量，`ActionText`继续显示价格；扩容阶段继续显示`Expand Capacity (目标容量)`，并让可选`介绍`显示下一次增量，如`Bag+100`或`Bag+1k`，购买台不显示背包名称或等级。`AreaProgressFrame.Value`继续显示精确`已收集/总数`，例如`2000/5000`，不使用单位。`HUDRoot.NotificationFrame00`默认隐藏，可显示便便教程当前英文步骤；进入满袋状态后袋满文字常驻并覆盖教程，清空后恢复教程或隐藏，提示自身不参与抖动。只有满袋时玩家按住鼠标或触摸清扫输入，`BagFrame`才持续左右抖动，松开后立即恢复原角度，且不占用全局通知框。每个满袋周期刚满时播放一次声音，继续收集触发`BagFullPickupAttempt`时按0.75秒冷却再次播放；该反馈不受回收引导线显示规则影响。
- 双手属性、工具属性和玩家永久属性升级成功时只刷新权威UI并播放`SoundService.UP`，不再额外发送成功文字；金币不足、满级、无效请求等失败消息仍通过普通通知显示。三个升级Remote继续返回原有`成功状态、消息、快照`。
- `LeafTargetHighlightController`只使用8-stud水平空间网格管理Tool01下一批目标描边；Tool01装备时立即查询并继续每0.5秒查询。Tool02/03/04不运行普通客户端预览查询，输入状态变化也不会触发候选检索。Tool01粗筛跳过不与真实拾取圆相交的网格，网格内仍按水平模型边界精确过滤；`Tool01HighlightQuery`独立标记Profiler。移动模型仍通过`LeafVisualBoundingCFrame/LeafVisualBoundingSize`事件维护索引，不会触发目标检索，也不再因`LeafMoveRevision`重复调用`GetBoundingBox()`。
- Workspace启用Streaming，最小/目标半径为64/160 studs。客户端不再逐片计算叶子的距离、镜头可见性或透明度，所有已加载叶子始终显示。服务端叶子描述和已加载模型分别维护8-stud客户端空间网格：基础48 studs内加载、64 studs外回收，工具范围更大时按`ForwardOffset + Range + 8`扩展加载半径并保留16-stud回收滞后；玩家移动8 studs或描述变化时刷新候选，每帧最多创建/回收各16片。加载只查询附近描述格，回收只精确检查刚离开回收边界的格子，不再周期遍历全部描述或约900个已加载模型。唯一远距例外是当前正式区域最后100片阶段选中的最多5个`Highlight02`目标。
- 客户端仍把“`TouchEnabled`且没有键盘和鼠标”判定为纯触屏，并在运行时重新读取设备能力，避免Studio设备模拟器或输入能力稍晚就绪时缓存错误模式；该标记只控制手机清理方式。所有设备始终使用第三人称，不绑定视角按钮、V键或Ctrl键；不创建视角Remote，`StateSnapshot`和Schema 21存档均不包含`CameraMode`，旧档同名字段直接忽略并在下次保存时自然移除。
- 第三人称固定`CameraMode=Classic`、FOV 70、缩放5～30 studs，进入和角色重建时把镜头放到约10 studs；客户端逐帧恢复CameraMode、CameraType、CameraSubject、FOV和零CameraOffset，但不覆盖Roblox标准鼠标、右键旋转或滚轮缩放。
- `GameHUD.Frame.Upgrade`的`Activated`事件切换面板显隐，第一次点击显示面板并停止清扫，再次点击关闭，不要求靠近升级台。Area_01～08升级台Prompt继续调用打开入口。面板也可由`Banner.Close`或E键关闭；客户端直接监听E键，并在关闭后的0.35秒内忽略升级台Prompt，避免同一次按键重新打开面板。邀请和升级面板不再保存或恢复镜头鼠标状态。
- `YardUIController`使用新版`GameHUD.invite`层级：玩家行的`name`显示`DisplayName`，`Image.Icon2`显示HeadShot，`invite`发送本服庭院邀请，`visit yard`直接进入目标庭院；`GoHome`只在访问别人庭院时显示并返回自己庭院，`nodabian.allowed`按权威`AllowGuestPoop`显示`Allowed/Blocked`。控制器不再读取旧行节点`Title/Icon/ImageButton/jinru`或`nodabian.Title`。
- 抛硬币下注`jian/jia`单击按10金币调整；长按使用真实经过时间累计，按每0.01秒±10等效速率更新。每帧只合并刷新一次下注文字，金额继续钳制到10和当前余额可下注上限之间；展示硬币只在跨越1k/10k/100k外观档位时重建。
- `ModalPanelCoordinator`统一协调图鉴、邀请、升级和重生四个主界面：同一时刻只允许一个可见，打开新界面会调用当前界面的正式关闭入口，再次点击当前入口则关闭。任一主界面打开时，客户端在`Lighting`维护`LocalModalPanelBlur [BlurEffect]`并启用`Size=18`；四个界面全部关闭后禁用，界面切换期间保持启用。邀请确认框、好友奖励和商品面板不属于该互斥集合。
- `ModalPanelEffects`保留各主界面的Studio原始`Position`。打开时从原位置下方90像素开始，0.22秒上移到目标上方12像素，再用0.1秒向下回落到原位置；关闭或切换时取消Tween并立即恢复原位置，防止快速操作造成漂移。鼠标进入四个入口按钮时，本地`UIScale`用0.12秒放大到原尺寸的1.08倍，移开后0.1秒恢复；不修改StarterGui模板。
- `VisitorBillboardController`根据`ActiveYardVisitors`在每个客户端本地克隆`ReplicatedStorage.frend.BillboardGui`到访客Head，显示`Visitor: DisplayName`和HeadShot头像。服务端不把Billboard挂入角色，因此不同庭院客户端不会看到；模板缺失或类型错误只警告一次并停用该视觉，不得阻断客户端启动。
- `UPattribute.Frame.ScrollingFrame.UPpeople.cuifnegji.List`复用Studio现有三个分支：`fanwei/gonglv/kongzhi`分别显示有效移速、仅由Value Multiplier升级产生的个人叶价倍率和有效幸运点。当前及下一叶价倍率均通过权威`PersonalLeafValueMultiplier`计算，不混入区域或重生倍率；`ImageButton.Title`显示金币价格或`MAX`，成功/失败复用`SoundService.UP/UPno`。
- 全部11张升级卡的购买按钮在有可用/不可用渐变节点时按金币、解锁状态和等级切换；渐变缺失时保留Studio默认外观，不阻断客户端启动。
- 双手、扫把、吹风机和玩家属性共11张升级卡使用直属`Name`显示权威名称，并用`Info`显示紧凑的`当前值->下一级值`，`Buy.Cost`显示价格。间隔使用秒、扫把覆盖率使用百分比、价值使用倍率；有效上限显示`当前值->MAX`。
- `AreaDoorController`只按玩家自己庭院的前置清扫进度选择下一扇未解锁门：Area_01～04清完后指向Door05，之后清完紧邻前区依次指向Door06～09；引导不要求最低重生次数已满足，因此可与重生按钮提示同时存在，触门后再由服务端提示缺少条件。访问其他庭院时不显示，门实际解锁后立即移除并等待下一段清扫完成。
- `RebirthController`保持`GameHUD.Frame.Rebirth`常驻并默认隐藏`GameHUD.chongshengqueren`及其入口提醒`tixin`。客户端只读取权威`RebirthEligible`：有资格且面板关闭时显示静态`tixin`，整个入口按钮以1.12倍、0.35秒循环脉冲；脉冲与1.08倍鼠标悬停共用`ModalPanelEffects`维护的同一`UIScale`并组合倍率。直属`explain [TextLabel]`实时显示`Clear Areas 1-4 and every area you unlock, or find X/Y Rainbow Poops.`；手机状态变化不影响该面板。普通或SKIP重生成功后按钮恢复原尺寸，后续重新满足资格时再次提示。按钮打开面板，`closes`关闭，`RobuxPurchase`调用`RequestRebirth`并在等待响应期间防止重复点击。`X1/X2`显示当前/下一次叶子价值倍率，`numX1/numX2`显示当前/下一次叶子数量倍率，整数不带`.0`、半级保留`.5`。
- 客户端`StateSnapshotStore`在Remote加载后立即监听权威快照并提前发起请求；首次未收到时按1/2/4/8秒退避、之后每10秒重试，60秒后停止。所有快照消费者通过Store订阅，晚初始化控制器会版本安全地回放最新快照，不会用旧回放覆盖新事件。
- `init.client.luau`按现有`Init`参数建立一次性控制器依赖任务；无依赖控制器可并行初始化，单个控制器卡住或失败只影响其依赖链。10秒诊断不终止仍在等待复制的任务，且同一控制器不会重复初始化。
- HUD核心只等待金币、背包、区域进度及通用通知；管理员重置、图鉴、失物进度、中央奖励、CoinFlip失败提示、叶子提示和相关音效均使用非阻塞可选绑定，节点稍后复制时只补绑定一次。`AffordableNotificationController`同样缓存快照并等待自己的提示模板，不再阻塞Bootstrap。角色镜头通过`ChildAdded`和角色代次等待`Humanoid/HumanoidRootPart`，不再产生无限等待。

## 当前已知边界

- Area_02～08已有当前区域HUD、失物上下文和回收功能；商品服务仍只连接Area_01，下水道系统已经移除。
- 经济已改为第一轮正式验收价格，仍需用3次完整跑图和真实玩家数据调优；Bag03～08和工具HUD图片不完整。
- Schema 20保留Schema 17的`DataResetDateKey`、可选`DataResetNoticeDateKey`和单次版本清档策略，继续保存社区奖励领取标记，并增加仅自然新档Eligible的正式入门漏斗状态；教程进度继续保存`BagGuidancePending`及可选`BagGuidanceReady`。吹风机没有电量字段；失物世界坐标、会话失物堆叠与世界大便不保存。普通重生保留两个清档日期、外观选择、`AllowGuestPoop`、`CommunityRewardClaimed`、`OnboardingFunnel`及明确列出的永久字段。
- 验收记录和双倍金币通行证已接入；仍没有其他商业化、大厅、Teleport或多人模式。

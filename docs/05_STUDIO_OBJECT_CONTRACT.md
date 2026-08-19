# Studio对象与命名契约

> 本文是精确Studio路径、名称、类型和可选性的唯一当前文档。玩家流程与代码责任请从`docs/features/README.md`进入；未连接目标Place时新增结构必须标记待Studio核验。

> 本文件只描述当前源码实际读取的Studio接口。Studio中存在但尚未被服务连接的对象会明确标为“预放置”。

## Workspace区域结构

```text
Workspace
├─ 大厅装扮 [Folder]
│  ├─ Recycle_01 [BasePart，结构同区域回收点]
│  │  └─ ProximityPrompt
│  ├─ LostItemShop [Model]
│  │  └─ upgrade [BasePart]
│  │     └─ ProximityPrompt
│  ├─ ground [Model]
│  │  └─ 任意数量BasePart
│  ├─ GeneratedLeaves [Folder，客户端运行时按需创建]
│  ├─ Cow [Model，全部BasePart保持Anchored]
│  │  └─ Direction [BasePart，LookVector朝牛头]
│  └─ actionpoop [Folder]
│     └─ Part001..Part006 [BasePart，按编号循环路径]
├─ AirWall [Folder或Model]
│  └─ 2..8 [Folder或Model，对应Area_02..Area_08]
│     └─ 任意层级BasePart
├─ Function [Folder或Model]
│  ├─ Reset [BasePart，可重复；已清区域钱币重置入口]
│  │  └─ ProximityPrompt [运行时显示Reset / Cleared Area Coins]
│  ├─ Leaderboards.WinsBoard.SurfaceGui
│  │  ├─ ScrollingFrame [ScrollingFrame]
│  │  │  └─ RowTemplate
│  │  │     └─ Frame [Frame，隐藏单行模板]
│  │  │        ├─ Amount [TextLabel]
│  │  │        ├─ Rank [TextLabel]
│  │  │        └─ UserName [TextLabel]
│  │  └─ Self.Frame [Frame]
│  │     ├─ Amount [TextLabel]
│  │     ├─ Rank [TextLabel]
│  │     └─ UserName [TextLabel]
│  └─ tool04 [BasePart，可重复；当前4个]
│     ├─ ProximityPrompt
│     ├─ GuiPart.BillboardGui
│     │  └─ cost [Frame]
│     │     └─ TextLabel
│     └─ 底座.Group
│        └─ Beam [当前4个]
└─ Area_01..Area_08 [Folder]
   ├─ ground [Model]
   │  └─ 任意数量BasePart
   ├─ Door [Model]
   │  └─ Door02..Door08 [Model]
   │     ├─ Door01 [BasePart]
   │     │  └─ SurfaceGui
   │     │     ├─ Frame.ImageButton.TextLabel
   │     │     └─ rebirth [Frame，保留历史对象名，运行时作为金币价格牌]
   │     │        └─ ImageLabel [金币图标]
   │     │           └─ x1 [TextLabel，运行时真实门价]
   │     └─ MB01/MB02 [Model，按实际门板数量]
   │        └─ angle [number属性，完全打开后的世界绝对Y角度，单位为度]
   ├─ Recycle_01 [BasePart，功能锚点]
   │  ├─ ProximityPrompt
   │  ├─ PulseVisual [Model]
   │  │  ├─ 静态回收桶视觉BasePart及其Decal/Texture
   │  │  └─ grass [Model]
   │  │     └─ grass [BasePart]
   │  └─ RecycleEffects [运行时Folder]
   ├─ Sign [可选容器]
   │  └─ Sign
   │     └─ SurfaceGui
   │        └─ TextButton
   └─ GeneratedLeaves [Folder，运行时按需创建]
```

- 八个活动Area必须是Workspace直接子级Folder；`ground`必须是Area直接子级Model。`Area_09`当前不属于运行时契约，可以留在Studio或删除，均不得影响启动。`ReplicatedStorage.Model`当前只要求Leaf1～16模板，Leaf17/18可删除且不得触发启动等待或断言。
- `大厅装扮.Cow.Direction`必须是Cow直属或后代BasePart，`LookVector`表示牛头方向；缺失时大厅牛功能关闭。Cow全部BasePart必须保持Anchored，移动通过`Cow:PivotTo()`整体完成，不要求Weld。`actionpoop`必须包含严格命名的六个BasePart；代码只读取位置，不修改点位或Direction的Studio可见性与碰撞配置。
- `Workspace.CoinFlip.Table.jingtou [BasePart]`是抛硬币玩法的镜头起点；下注时镜头位于该Part，抛掷时镜头从该点温和地同步向硬币推进并配合`FieldOfView`缩放，落地后回到该点。镜头始终保持世界Y轴向上并朝向硬币，避免画面滚转。移动该Part即可调整镜头距离和高度，其自身朝向不参与计算。`jingtou`应保持Anchored、透明且关闭碰撞、触摸和查询。
- 同一次进入`CoinFlip.Click`的会话中，本地展示硬币会保留最后落点、正反面和水平朝向；下一局直接从该落点起飞。调整赌金导致Coin001～004模型切换时也必须保持桌面局部X/Z及最终姿态，只按新模型尺寸重新计算贴桌高度。退出区域或角色重建后才恢复桌面中央。
- `StarterGui.GameHUD.coinFlip`显示期间，客户端必须隐藏`HUDRoot.ToolFrame`并封锁快捷栏点击、数字键`1～9`和`Q`装备切换；NO、离开`CoinFlip.Click`、死亡或会话重置时恢复，并按最新库存重绘。Roblox默认Backpack栏仍保持关闭。
- `coinFlip.yes`发出权威请求后最多等待`0.2s`：若服务器仍未返回，则展示硬币从当前落点沿正式抛掷相同速度持续上升并让镜头跟随，长时间等待时只在轨迹最高点短暂停留。预抛不得猜测结果、落点或播放落地音效；成功时继承当前高度、旋转和垂直速度接入正式轨迹，不得停顿后二次起飞；失败时约`0.2s`回到原落点和原面。
- `StarterGui.GameHUD.coinFlip.jian/jia/NO/yes [GuiButton]`运行时各使用独立`CoinFlipPressScale [UIScale]`提供一次性按压回弹；`jian/jia`单击一次调整10金币，长按按每0.01秒±10的真实时间速率连续调整且只在最初按下时播放按钮脉冲。低帧率下同帧到期档位合并为一次文字刷新；`coinFlip.Frame.TextLabel`的`CoinFlipWagerWaveScale [UIScale]`只为单次调整播放追数与回弹，长按不会排队动画。展示硬币只在下注跨越1k/10k/100k档位时重建。
- `StarterGui.GameHUD.HUDRoot.coinsX [GuiObject]`是抛硬币反面时的扣款提示模板；其直属`Notification [TextLabel]`由客户端写为`-赌金`。运行时整个`coinsX`向上漂浮并逐渐淡出，Studio中应保持默认隐藏。
- Workspace必须启用`StreamingEnabled`，并设置`StreamingMinRadius=64`、`StreamingTargetRadius=160`；这些值与`LeafVisibilityConfig`保持一致。
- `Workspace.ClientPerformanceTierOverride [可选string属性]`只用于Studio Play确定性测试，可设为`Low`、`Medium`或`High`并在运行中切换；属性缺失或值非法时使用真实FPS采样，正式发布客户端始终忽略该属性。
- `ReplicatedStorage.miaobian.Highlight02`必须是`Highlight`，作为每个正式区域剩余最后100片时的收尾描边模板。客户端最多克隆5份，只设置名称、`Adornee`、`Enabled`和父级；模板当前橙色填充、白色外框及`AlwaysOnTop`样式由Studio维护。
- `ReplicatedStorage.miaobian.Highlight03`必须是`Highlight`，作为幸运盒原地轮播期间随机模型的只读描边模板。客户端每轮克隆一份，只设置名称、`Adornee`和父级；`Adornee`必须是当前轮播模型内部的视觉`Model`，不能包含隐藏`upgrade`。轮播模型销毁时描边一并销毁，最终真实模型不使用该模板。
- Area和`大厅装扮.ground`的全部后代BasePart都是各自的生成与工具射线表面；服务启动时设置`Anchored=true`、`CanQuery=true`。位于`大厅装扮`下但不在`ground` Model内部的同名Part不参与Lobby生成。
- Lobby使用600个全服共享稳定池位，从Leaf1～16等概率选择外观、基础背包价值固定为1，并按每0.1秒一个空位激活。Lobby描述随当前庭院快照一同下发，客户端模型只放入`大厅装扮.GeneratedLeaves`；拾取计入背包、出售和清理榜，但不写`YardProgress`、不解锁区域且不推进教程或幸运箱。
- 每区运行时写入`AreaCleaned`属性。`GenerationComplete`表示当前生成批次是否结束；只有`GameplayReady=true`的完整区域可以被工具和描边处理，`PreviewOnly=true`的100片预览只负责远景显示。
- 启动只完整生成基础450片的Area_01，并为Area_02生成100片预览。角色身体碰门时，只有Area01到目标前一区的正式清理进度全部达到100%、顺序与金币扣款验证通过，目标区域才补齐正式数量，同时为再下一区域生成100片预览。全部已付费解锁区域都保持正式可收取状态；更远区域不生成，当前Area_08没有后继区域，Area_09不得生成预览或正式叶子。
- 普通失物不再以真实模型写入服务端`Area_XX.GeneratedLostItems`。个人地面箱克隆由客户端放在`Workspace.LocalLostItems`，原地揭晓克隆放在`Workspace.LocalLostItemReveals`；服务器仍保留最终ID、位置、拾取、RevealId和奖励权威。Area_01～08正式进度及每轮ResetCoin各自每收取200片进行一次独立5%判定，成功时在触发玩家周围4 studs内生成对应等级箱子；Lobby不参与。首次120秒及后续300秒定时Lucky004/005每次服务器会话重新计时，未打开箱、位置、检查点和未来计划不写DataStore。`GameHUD.HUDRoot.time.Value`必须是文字GUI对象，客户端只修改其`Text`并在节点缺失时安全关闭倒计时表现。地面快照只公开`LuckyTier`，不公开最终物品或价值。揭晓容器中的候选与最终模型按视觉Model包围盒中心对齐权威`RevealOriginCFrame`；12轮候选不得保留Billboard，最终0.25秒放大完成后挂接价值牌并展示0.5秒，再用0.65秒沿最高额外抬升1.5 studs的抛物线飞向开启者胸口，飞行全程保持完整尺寸。不同RevealId可并行动画和独立发奖；`GetDiamond`的首次获得提示只能在对应飞行结束且服务端确认入库后出现。
- `Workspace.Function.Reset [BasePart]`同时是门金币不足且可重置时的本地Beam目标；对象暂未Streaming到客户端时只隐藏并重试，不得阻断控制器。其直属`ProximityPrompt`只向触发玩家打开`GameHUD.Reset`并结束本轮前往Reset引导，不直接创建钱币或显示旧失败通知。玩家点击面板确认后，服务端再次检查仍在同一重置台附近、自己的庭院已就绪、全部已解锁区域清完且上一轮ResetCoin已收完，才为这些区域创建一轮独立会话钱币；门、`UnlockedAreas`、正式`YardProgress`、教程和首次通关保持不变。
- 重生不再使用`Workspace.Function`中的世界Part或`ProximityPrompt`；玩家统一通过`GameHUD.Frame.Rebirth`打开确认面板。
- `Function.Leaderboards.WinsBoard`、`PlaytimeBoard`、`gold`和`POOP`共用排行榜对象契约。每个`SurfaceGui.ScrollingFrame.RowTemplate.Frame`必须保留直属`Amount/Rank/UserName [TextLabel]`；原始外层`RowTemplate`由客户端保持隐藏，生成行必须克隆完整`RowTemplate`并只在克隆内部Frame写内容，不能把内部Frame直接改挂到ScrollingFrame，否则比例行高会相对整个滚动区域放大。`ScrollingFrame`必须保留直属`UIListLayout`；客户端运行时设置`AutomaticCanvasSize=Y`、清零初始`CanvasSize`并启用纵向滚动，Studio继续负责模板行高、布局间距和滚动条样式。
- 四个榜的`SurfaceGui.Self.Frame`都必须保留同名三个TextLabel，由每个客户端只在本地写自己的数据。`WinsBoard`显示最快清扫时间，`PlaytimeBoard`显示永久在线时长，两者使用`00m/1h05m`格式；`gold`显示永久清理叶子数，`POOP`显示永久成功制造便便次数，两者使用紧凑整数。无成绩显示`#--`以及`00m`或`0`，榜外显示`#20+`。场景对象受Streaming影响时客户端不得阻塞启动，载入后使用各自最后一份只读快照补画。
- `Function`下所有直接名为`tool04`的BasePart都是吸尘器购买入口，必须各有直接子级`ProximityPrompt`和`GuiPart.BillboardGui.cost.TextLabel`。Prompt固定显示“购买/吸尘器”；TextLabel在Studio默认写199，运行时由每名玩家的客户端改成本地区域价格，旁边Robux图片和现有布局保持不变。
- Tool04购买台必须保留在服务器Workspace，不能因单名玩家购买而Destroy。拥有者由客户端本地隐藏全部BasePart/BillboardGui/Prompt，并关闭购买台后代全部Beam；`tool04.底座.Group`下当前4个Beam同样适用。Beam恢复时使用其最初载入的Studio `Enabled`值。服务端运行时碰撞组只允许拥有者穿过，未购买玩家继续看到并碰撞。
- `Function`下直接名为`3Kback/5Kback`的BasePart是当前永久背包购买入口，每个必须包含直接子级`ProximityPrompt`和`GuiPart.BillboardGui.cost.TextLabel`。
- 两类启用Prompt在未拥有时显示“购买/3K背包”和“购买/5K背包”，cost在Studio默认写`49/59`，运行时由客户端替换为玩家本地区域价格；拥有后同一购买台保持可见和可触发，Prompt改为“装备”，cost改为“已拥有”。购买台不得因单个玩家拥有权益而在服务器Destroy或本地隐藏。
- `Trashback`和`ReplicatedStorage.bag.bag011`可以继续保留以便未来恢复；当前`bag011.Enabled=false`，运行时隐藏购买台、禁用Prompt且不验证或装备该Accessory，场景中缺失`Trashback`也不会阻止启动。
- `ReplicatedStorage.bag.bag09/bag010`必须是带`Handle.BodyBackAttachment`的Accessory。功能容量与HUD按5K、3K优先级计算；角色Accessory可由已拥有玩家在两个购买台间切换。服务端碰撞只让玩家穿过自己已拥有的对应购买台，但Prompt仍可触发。

## 区域门

- `DoorNN`表示目标区域N；Area_02～08要求Area01到Area_(N-1)的正式清理进度全部达到100%、前一区域已解锁并按顺序支付金币，不存在Key或最低Rebirth次数替代路径。门价为基础价乘`1 + 0.5 × RebirthCount`并取整；普通或SKIP Rebirth后只保留Area_01，旧门重新锁定并按新的Rebirth次数再次购买，普通死亡与重新加入则保留本轮已购门。
- 固定按钮路径为`DoorNN.Door01.SurfaceGui.Frame.ImageButton`，文字节点为其`TextLabel`；价格路径为`DoorNN.Door01.SurfaceGui.rebirth.ImageLabel.x1`。`rebirth`只是历史对象名，当前只承载金币图标和价格，不表示重生要求。
- `ImageLabel.Image`使用与`HUDRoot.CoinsFrame.ImageLabel`相同的金币图片`rbxassetid://140381046419252`。客户端把`x1.Text`写为`x`加当前玩家真实紧凑门价，例如`x150/x1.8k`；Rebirth、快照或Streaming重载后必须刷新。同名目标门允许存在多个入口副本，当前Door03、Door04和Door07均有重复入口，所有副本必须显示同价且一次解锁后同步打开。
- 每个`Door02～Door08`及其`MB01/MB02`保持`ModelStreamingMode=Atomic`。每个需要旋转的`MB01/MB02`模型必须直接设置number属性`angle`，表示门完全打开后的世界绝对Y角度（度）；运行时保留关闭姿态的位置与X/Z旋转，只将目标Y旋转设为`angle`，缺失属性时临时使用关闭Y角度`+90°`回退。
- 锁定状态的`Door01.CanTouch`必须保持`true`；只有本地玩家身体碰撞会执行解锁请求，工具、Accessory、其他玩家和场景Part不会触发。`SurfaceGui.Frame.ImageButton`必须保留用于现有排版，但运行时始终不可点击。
- 未解锁时显示`Unlock <Area DisplayName>`、当前金币门价，并恢复Studio外观与碰撞。前置正式区域未全部清完时提示`Clear all areas through <Previous Area> to unlock <Target Area>.`；余额不足或前一区域尚未解锁时同样由服务端拒绝且不扣款。
- 当前玩家解锁后，所有区域中的同名DoorNN在该客户端设置`Door01.Transparency=1`、`CanCollide/CanTouch/CanQuery=false`并关闭整个`SurfaceGui`；`MB01/MB02`在0.6秒内打开。首次载入已经解锁的门直接同步最终打开姿态，不重播动画。
- `Workspace.AirWall["N"]`对应`Area_0N`的玩家空气墙；客户端按当前活动庭院的`StateSnapshot.UnlockedAreas`独立控制容器内全部后代BasePart。区域已解锁时本地设置`CanCollide=false`，未解锁时恢复各Part最初载入时的Studio值，不会影响同服其他玩家。
- 老存档进入时立即应用已解锁状态；游戏内Rebirth重置区域进度后恢复碰撞。普通角色死亡复活不重新锁墙。`AirWall`、编号容器或内部Part受Streaming后加载时必须按最后一份快照补应用。

## 大厅与八区域通用回收对象

- `Area_01～Area_08`都必须存在上述`Recycle_01`结构，服务端会逐区连接直接子级`ProximityPrompt`；Area_09回收对象不绑定。
- `大厅装扮.Recycle_01`使用相同结构并记为逻辑来源`Lobby`，复用正常背包结算、金币奖励、统计和世界动画；Lobby来源的拾取与回收不推进教程、区域解锁或通关进度。
- 新结构的草堆动画目标为本区`Recycle_01.PulseVisual.grass.grass`。运行时按本次袋值逐个生成5～30片飞叶，间隔从0.1秒逐渐降至0.05秒；每片到达时让`PulseVisual`全部BasePart围绕Model Pivot从原尺寸短暂放大至1.08倍再恢复。最后一次脉冲结束后，草堆才沿Y轴缩放并补偿CFrame，使世界底部中心固定。`Recycle_01`必须保持固定BasePart并只作功能锚点，`RecycleEffects`必须留在`PulseVisual`外。旧路径`Recycle_01.grass.grass`只兼容草堆动画，不播放整体脉冲。
- 袋满引导在大厅回收点与当前活动庭院已解锁区域的回收点之间选择离玩家最近的`Recycle_01`；本局前三个满袋周期常驻显示，第4次起停止显示。

## 已移除的下水道对象

- `Area_01～Area_08`不再需要`sewer`或`sewer01`，运行时不会查找、创建或连接这些对象。
- Studio若仍有旧下水道残留，可以直接删除；原位置继续属于正常ground叶子生成范围。

## Area_01专用玩法对象

```text
Workspace.Area_01
├─ CleaProduct_02 [BasePart]
├─ CleaProduct_02_1 [BasePart, Area_01新增扫把台]
│  └─ ProximityPrompt
├─ CleaProduct_03 [BasePart]
│  └─ ProximityPrompt
├─ BagProduct_01 [BasePart]
│  ├─ ProximityPrompt
│  ├─ bag01 [BasePart或Model，展示锚点]
│  └─ Part [BasePart]
│     └─ BillboardGui
│        ├─ MoneyText [TextLabel]
│        └─ 介绍 [可选TextLabel]
├─ Recycle_01 [BasePart，功能锚点]
│  ├─ ProximityPrompt
│  ├─ PulseVisual [Model]
│  │  └─ grass.grass [动画BasePart]
│  └─ RecycleEffects [运行时Folder]
├─ LostItemShop [Model]
│  └─ upgrade [BasePart]
│     └─ ProximityPrompt
└─ 其他用户预放置场景对象
```

- Area_01～08的`CleaProduct_02/03`分别连接Tool02/03；Area_01的`CleaProduct_02_1`是Tool02的场景别名。当前价格来自`ToolConfig`，而不是Part属性或Prompt文字；购买台只负责本轮首次购买，不负责装备。
- `CleaProduct_02.saoba.Grip.BillboardGui.MoneyText`、Area_01别名的同层级`MoneyText`和`CleaProduct_03.cost.BillboardGui.MoneyText`为场景价格牌；未拥有时客户端按当前重生倍率持续覆盖为紧凑价格。Studio基础文本分别为`$825`和`$12.5k`；玩家当前已拥有对应工具时，全部同类牌改为`Owned`且Prompt在该客户端关闭。重生后金币购买的工具恢复价格和Prompt，Developer Product永久工具则自动恢复并继续显示`Owned`。
- 当前Tool01默认解锁，不要求Area_01存在`CleaProduct_01`。
- `BagProduct_01`在普通Lv.8前购买当前袋子的下一级；普通购买阶段的Prompt `ObjectText`只显示`Capacity 100`等目标容量，不显示等级或背包名称，`ActionText`继续显示价格。达到Lv.8或玩家拥有3K/5K永久背包后，同一Prompt和价格牌继续出售`+100/+150/+200/+250……`、每次多50的容量扩展，不显示`MAX`。扩容阶段继续展示`bag08`购买台模型并显示动态计算的`Expand Capacity (目标容量)`；存在直属`介绍 [TextLabel]`时同步显示下一次增量`Bag+100/Bag+150……`，四位数起使用紧凑单位。普通升级或无下一档时恢复该节点加载时的Studio文字；节点缺失、类型错误或稍后Streaming载入不得阻断购买台。实际角色普通/永久背包外观不变；价格和下一容量均由客户端按权威快照与`BagConfig`覆盖，无需新增Studio对象。
- `Recycle_01`遵循上方八区域通用回收契约。
- Area_01～08中存在的直接子级`LostItemShop`以及`大厅装扮.LostItemShop`都会连接同一套失物兑换逻辑。

Studio的Area_02～08已经预放置同名商品对象；`ProductService`的商品购买范围保持原逻辑，失物兑换商店按上方规则连接。

## ReplicatedStorage资源

```text
ReplicatedStorage
├─ Model [Folder]
│  ├─ Leaf1..Leaf16 [Model]
│  └─ MagneticRange [Model或Folder]
│     └─ MagneticRange [BasePart]
│        └─ Decal [Decal]
├─ tishi [Part，世界钱币收取提示模板]
│  └─ BillboardGui
│     └─ GetHint [Frame]
│        ├─ Icon [ImageLabel]
│        └─ TextLabel [TextLabel，可包含UIStroke]
├─ PointTo [BasePart]
│  ├─ Beam [Beam]
│  ├─ Attachment0 [Attachment，玩家点位]
│  └─ Attachment1 [Attachment，范围中心]
├─ CleaningTools [Folder]
│  ├─ Tool01 [Tool]
│  ├─ Tool02 [Tool]
│  ├─ Tool03 [Tool]
│  ├─ Tool04 [Tool]
│  └─ Tool05 [Tool]
├─ bag [Folder]
│  └─ bag01..bag010 [Accessory]
├─ LostItem [Folder]
│  ├─ LostItem01..LostItem25 [Model]
│  │  ├─ upgrade [BasePart]
│  │  │  ├─ ProximityPrompt
│  │  │  └─ BillboardGui [LostItem01为公共价值牌模板]
│  │  └─ Model [Model，正式视觉]
│  ├─ LostItem095..LostItem099 [Model]（五级共享大便）
│  │  └─ LostItem099.Model.1 [MeshPart，运行时由PoopController统一驱动Neon彩虹颜色]
│     ├─ upgrade [BasePart]
│     │  └─ ProximityPrompt
│     └─ Model [Model，正式视觉]
├─ Lucky Block [Folder]
│  ├─ Lucky001..Lucky005 [Model]
│  │  └─ Base [BasePart]
│  │     └─ ProximityPrompt [ActionText=OPEN, HoldDuration=0.5, MaxActivationDistance=10]
├─ frend [Folder，可选旧素材，运行时不使用]
│  └─ BillboardGui [BillboardGui，可保留或删除]
│     └─ Power
│        ├─ Value [TextLabel]
│        └─ ImageLabel [ImageLabel]
├─ Key [Folder，保留但运行时不使用]
│  └─ Key02..Key08 [Model，未使用素材]
├─ miaobian [Part]
   └─ Highlight [Highlight]
└─ yindaoxian [Beam]
```

- 普通失物视觉及价值牌只读取`ReplicatedStorage.LostItem`；地面箱只读取`ReplicatedStorage["Lucky Block"]`。`Workspace.LostItem`是独立装饰，可以自由移动、隐藏或删除，代码不得依赖；`Workspace.LocalLostItems`和`Workspace.LocalLostItemReveals`都只允许作为客户端运行时投影容器。
- `frend.BillboardGui`属于退休访客系统的可选旧素材；生产代码不读取、等待或克隆它，保留或删除都不能影响客户端启动。

### 叶子模板

- Leaf1～18必须各自是Model并包含至少一个BasePart或MeshPart，不要求PrimaryPart，不包含正式脚本或Prompt。后续可以将视觉替换为钞票或其他垃圾，但应保持模板名称，或同步修改`LeafConfig`；模型包围盒会直接参与生成、拾取及高亮判定，尺寸应保持在合理范围。
- 运行时代码只克隆模板，不改动原模板。克隆使用Atomic流式模式、锚定并关闭碰撞、触摸与查询。
- 当前Leaf1～18的BagValue均为1，因此每片都占1格背包并提供1点基础金币。Area_01使用Leaf1/2、Area_02使用Leaf3/4，以此类推至Area_09使用Leaf17/18；每区前一种模型权重70，后一种权重30。
- 叶子落点允许与其他叶子重叠，并沿当前ground表面法线随机抬高0.05～0.6 studs以显示叠放层次；但必须避开八区ground之外所有`CanQuery=true`的世界物体。模型的旋转包围盒最多检查12个随机位置，全部失败时才允许使用最后候选以保证数量。
- 拾取后完整Model在0.35秒内沿弧线飞向玩家并缩小销毁。

### 世界收取提示

- `ReplicatedStorage.tishi`必须为透明`BasePart`，包含直属`BillboardGui.GetHint [Frame]`及其直属`Icon [ImageLabel]/TextLabel [TextLabel]`；大厅与Coop Place必须保留相同结构。
- 客户端只在服务端确认钱币进入背包后克隆该模板到该片钱币最后的权威世界位置。克隆固定锚定并关闭碰撞、触碰、查询和阴影，只存在于收集者客户端。
- `Icon`读取该钱币`LeafConfig`图片，缺失配置时保留`tishi`默认图片；`TextLabel`显示应用当前叶价倍率后的`+价值`，不包含兑换阶段的Double Coins。
- 每个提示从出现时就开始漂浮，在总计1.4秒内向上移动3 studs；前0.6秒保持图片、文字和可选UIStroke完全可见，后0.8秒继续上升并同步淡出。逐片提示保持0.04秒节奏，排期与活动合计最多30个，超额直接省略；完成或失败后必须恢复透明度并进入客户端对象池。
- Quick Sell及其他即时回收不克隆`tishi`，继续使用金币到账动画；缺失或无效模板只关闭该表现，不得阻断客户端Bootstrap或真实收取。
- 普通区域门权威扣款成功后可由`AreaDoorController`另建最多30个本地`tishi`克隆；这些克隆强制使用`rbxassetid://99223157190429`并把`TextLabel`写为完整负门价。它们从玩家身边以0.2秒弧线和`alpha²`位移逐渐加速飞向实际碰撞门，仅作表现，不得扣款或写`UnlockedAreas`；Coop不运行该表现。

### 清洁工具模板

- Tool必须能由Roblox Humanoid正常装备，并由服务端添加`CleaningToolId`和`HotbarOrder`。
- Tool01～Tool05都是当前可用模板。Tool04必须包含可装备的`Handle`并保留模板自带持有动画LocalScript；固定玩法属性由`ToolConfig.Tools[4]`提供，不进入升级配置。Tool05必须保留模型自带的`135075227978653`持有动画LocalScript，快捷栏名称由配置固定为`MakeTrash`，只允许手动装备且不会成为加入或复活时的默认恢复工具。
- `ToolConfig.DefaultToolId`对应模板必须始终存在且为可克隆Tool。进入或复活审计只把Tool01～04计为清洁工具；Tool05和失物Tool不阻止缺失时补发、装备Tool01，也不得造成重复Tool01。
- 模型握持方向和动作适配由Studio模板决定，代码不会自动旋转工具视觉。

### 袋子模板

- `bag01～bag08`必须是Accessory，运行时克隆到Character。
- 系统克隆带`CleaningBagLevel`属性；更换等级时删除旧系统袋子，不删除其他Accessory。
- `BagConfig.ModelPath`使用`bag.bagXX`相对ReplicatedStorage路径。

### 失物模板

- `upgrade`是Prompt载体、落地锚点和Tool Handle基准，必须保持直立，底面表示落地点。
- `LostItem01～25`和`LostItem095～099`都必须有与upgrade同级、名称严格为`Model`的正式视觉Model。`LostItem01.upgrade.BillboardGui`是幸运盒最终原地价值牌和普通快捷栏价值牌的公共模板，必须保留`Frame.ImageLabel/TextLabel`。五个大便模板还必须各自保留`upgrade.ProximityPrompt`及根级`BillboardGui.cost.ImageLabel/TextLabel`；运行时分别显示制造者头像和`Poop made by DisplayName`。五个模板层级一致但尺寸可以不同，服务端会分别缓存落地高度和拾取距离。世界最终克隆和轮播克隆都不得保留`Highlight`，轮播克隆还会移除Prompt、BillboardGui和脚本。`LostItem100`已废弃，代码不再等待或克隆它。
- `Lucky001～005`必须各自为Model并包含直属`Base [BasePart]`和`Base.ProximityPrompt`。五个Prompt保持`OPEN`、0.5秒按住及10 studs激活距离；客户端克隆后只覆盖ObjectText为`Lucky Box Lv.N`，并关闭所有Part的碰撞、触碰和查询。模型级别与文件名严格一一对应，不能把最终失物ID、名称或价值写入箱子实例。
- 个人世界克隆的upgrade默认隐藏，但Prompt位置、拾取距离和Tool Handle仍以它为准。
- 视觉范围只用于失物之间的生成避让，不参与叶子覆盖或拾取判断，也不用于自动重新居中或补偿高度。
- 原始模板只读，拾取Tool和世界物均来自克隆。

### 保留的钥匙素材

- `ReplicatedStorage.Key.Key02～Key08`仅作为未使用素材保留，不再属于启动对象契约。
- 服务端和客户端不会读取、克隆、显示或校验这些模型；其结构缺失或变化不会影响游戏启动。

## 收割范围与描边

- 范围模板固定为`ReplicatedStorage.Model.MagneticRange.MagneticRange`，并要求直接子级`Decal [Decal]`与`SurfaceGui [SurfaceGui].Frame [GuiObject]`存在。
- 客户端克隆外圈、内圈和唯一固定中心点到本地Workspace，全部关闭碰撞、触摸、查询和阴影。内外圈克隆必须关闭自身`SurfaceGui`，只允许`LocalHarvestRangeCenter`显示中心Frame。
- 装备有效清洁工具时，纯触屏设备只保留以玩家脚底为圆心、半径为`Range + ForwardOffset/2`的逻辑作用范围，不显示范围Part或Decal；非纯触屏设备使用原始鼠标视口坐标与脚底水平面的射线交点，可达距离内圆心与鼠标重合，高模型不参与定位，超出长度时钳制到`ForwardOffset`。Studio仍复用同一范围模板，不需要增加移动端锚点或新Part。
- 电脑端Tool01只显示外圈；Tool02/03在`InnerRangeRatio>0`时显示同心内外圈。`LocalHarvestRangeCenter`保持模板Part原始尺寸且不参与范围尺寸Tween，其`SurfaceGui.Frame`保持Studio原始尺寸并与内外圈共用同一圆心。运行时外圈、内圈和中心点必须沿当前脚底平面法线在原有间隙上统一额外抬高`0.2 studs`；外圈/中心点原有`0.02-stud`间隙和内圈额外`0.02-stud`分层保持不变。该高度不得写回Studio模板或用于服务端瞄准和命中。纯触屏设备的内外圈和中心点始终隐藏。
- 扫把方向模板固定为`ReplicatedStorage.PointTo`及其直接子级`Beam/Attachment0/Attachment1`。Beam保持`FaceCamera=false`和零曲线，两个Attachment的Studio本地旋转是最终视觉方向，运行时代码不得覆盖。电脑端客户端隐藏克隆Part本体并连接范围圆心与玩家；纯触屏运行时Beam始终隐藏。范围Part的额外`0.2-stud`视觉高度不得改变Beam独立的`0.1-stud`离地高度。
- 本地范围辅助Part创建后立即停放到`CFrame.new()`。纯触屏始终保持停放；电脑端在卸下清洁工具、装备Tool05、角色死亡/根部缺失或有效范围为0时停放。停放必须关闭Beam和中心`SurfaceGui`，同时设置范围Part的`LocalTransparencyModifier=1`和Decal透明度1；重新装备时先设置正确CFrame，再恢复模板可见性。
- `miaobian.Highlight`只用于Tool01下一次会处理的普通目标；Tool02～05均不使用。客户端对象池只把`Adornee`绑定到整个叶子Model并修改`Enabled`，不得覆盖模板颜色、填充、透明度或DepthMode，也不得依赖叶子外观或PrimaryPart。
- 所有升级卡直属`Name`必须与配置`DisplayName`完全一致；客户端按四页固定卡片路径写入权威名称，不再通过旧标题别名匹配。内部存档ID与模板卡名可以不同，例如Broom的`Pickup Range`卡显示`Sweep Coverage`。
- 下一批目标描边使用8-stud空间网格且只服务Tool01：装备时立即刷新，随后每0.5秒刷新。Tool02/03/04装备、按下和持续工作时都不运行普通客户端查询或候选排序。Tool01空间查询只访问与当前实际作用圆相交的网格，最终目标仍按模型边界精确过滤。移动中的叶子由本地`LeafVisualBoundingCFrame/LeafVisualBoundingSize`属性更新目标索引，不得在运动热路径重复调用`GetBoundingBox()`；被动索引维护不得触发任何工具候选检索。
- 已加载叶子始终保持模板可见状态，客户端不得再按玩家距离、镜头视野或渐变带修改`LocalTransparencyModifier`、Decal或Texture透明度。98 studs内创建本地模型，106 studs外进入分帧回收；描述与已加载模型分别维护8-stud空间网格，移动刷新只检查附近加载格和刚离开回收边界的格子，不遍历全部叶子模型。这两个边界只控制本地模型是否加载，不改变服务端碰撞、收取状态或模板透明度。`Leaf1～Leaf16`应优先保持单BasePart，以使用客户端`BulkMoveTo`快速路径。

## 袋满回收引导

- `ReplicatedStorage.yindaoxian`必须是Beam，是袋满引导线的只读视觉模板。
- 模板使用当前叶片纹理，固定为`TextureMode=Wrap`、`TextureLength=2`、`TextureSpeed=1`、完全不透明、`LightEmission=1`、`ZOffset=2`、两端宽度1和`FaceCamera=true`。
- 运行时克隆只设置`Attachment0`、`Attachment1`、`Enabled`和父级；颜色、纹理、透明度和发光等视觉属性全部沿用Studio模板。
- 起点Attachment放在玩家`HumanoidRootPart`，终点Attachment放在当前区域`Recycle_01`，两端局部Y均上移1.5 studs。Beam本体放在客户端`Workspace.LocalRecycleGuidanceEffects`，不作为角色后代并独立管理生命周期。
- 引导显示只依赖满袋周期，不依赖鼠标、触摸或当前工具；回收清空后立即销毁运行时克隆。

## 教程引导

- 教程同样只读克隆`ReplicatedStorage.yindaoxian`，放入客户端`Workspace.LocalTutorialGuidanceEffects`，不得修改模板视觉属性。
- 第1步先连接角色与Area_01最近的正式钱币位置；客户端只创建透明、无碰撞、不可查询的本地锚点，不修改钱币对象。水平距离进入6 studs前显示`Go to the coins`并隐藏`HUDRoot.yin`；进入后销毁该锚点并切换为拾取提示。目标消失、角色复活或Streaming未就绪时隐藏Beam并重新解析，不得选择Lobby钱币或ResetCoin。
- 第2步连接角色与对应区域`Recycle_01`；数量升级和第二次成功卖出后达到升级价格的速度步骤连接角色与`Area_01.UPattribute.up`，但不会自动打开面板。玩家通过升级台或HUD入口主动打开后销毁Beam、切换到`Hands`页，并让对应`Pickup Amount`或`Pickup Speed`的`BuyButtons.Buy`循环放大缩小。
- 教程完成后的首次背包提示在成功回收且结算后金币足够时复用同一教程Beam，优先连接当前区域`BagProduct_01`；目标未加载时只在已解锁区域中选择最近的已加载购买点。该提示不要求袋满，首次普通背包购买后永久结束；门引导激活时仍拥有更高优先级。
- 首次普通背包购买后的便便教程继续只读复用`ReplicatedStorage.yindaoxian`。制造成功后Beam连接玩家与`Workspace.LocalPoops.LocalPoop_<SpawnId>.upgrade`，第一次及下一轮有效拾取后的兑换阶段连接最近已解锁区域的`LostItemShop.upgrade`，账号最多显示两轮兑换Beam；门引导优先于便便教程，便便教程优先于普通失物兑换引导。

## 丢失物兑换引导

- 丢失物兑换引导同样只读克隆`ReplicatedStorage.yindaoxian`，Beam本体放入客户端`Workspace.LocalLostItemGuidanceEffects`；它与`LocalRecycleGuidanceEffects`、`LocalTutorialGuidanceEffects`相互独立，可同时显示。
- 显示条件读取现有快照：Area_01为`CarriedLostItem`存在；Area_02～08还要求`CollectibleInventoryTotal > 7`。不满足时立即销毁Beam和两端Attachment；道路沿用最后一次有效`CurrentAreaId`。
- 玩家端Attachment放在`HumanoidRootPart`上方1.5 studs，目标端Attachment放在兑换处`upgrade`上方1.5 studs。满足显示条件时每0.25秒重新选择目标，以适配角色重生、Streaming流入/流出和场景对象变化。
- 目标选择包含`大厅装扮.LostItemShop`和当前活动庭院`StateSnapshot.UnlockedAreas`中的已解锁区域。来源为`Lobby`时优先大厅商店；来源区域已解锁时优先该区域内离玩家最近的有效`upgrade`；来源处无已加载目标时，在大厅与其他已解锁区域中选择全局最近目标。没有已加载兑换点时隐藏Beam，Streaming载入或后续解锁后自动恢复。
- 2026-08-03 Studio检查时Area_04没有`LostItemShop`，Area_05与Area_07各有两个同名`LostItemShop`；客户端选择规则兼容缺失和任意数量重复结构，代码不得自动创建、移动或删除用户场景对象。

## 合作匹配与副本

- 大厅PlaceId为`95556867008792`，合作副本PlaceId为`131244809352557`；两个Place使用同一`default.project.json`与`src`，场景对象分别保存在各自Place。
- 大厅`Workspace.Function.place001`～`place004`必须都是玩家进入检测用BasePart。每个台的全服状态牌位于`join [BasePart].BillboardGui.Frame`：`04 [TextLabel]`显示`当前人数/目标人数`，空队为`0/4`；`easy [TextLabel]`显示`EASY/HARD/NIGHTMARE/HELL`，空队为`EASY`；`TextLabel [TextLabel]`只在房主确认后的15秒倒计时显示`Starting in %ds`，其他状态隐藏。四台结构必须一致，文字由服务端直接更新。Coop Place不要求复制这些大厅匹配台。
- 每个台只允许运行时代码修改`底座.Group [Model]`内全部后代`Part`的`CanCollide`；当前Place可以有4个或8个Part，不得修改同名装饰`Group [MeshPart]`。服务端未满时保持开放、满员/保存/传送时关闭；已入队成员客户端始终在本地关闭当前台围墙，退出后解除。
- `StarterGui.GameHUD.Team001`是大厅组队面板：人数减/加为`Frame.PLAYER.-/+`、人数值为`Frame.PLAYER.PLAY.4`、难度切换为`Frame.DIFFICULTY.</>`、难度值为`Frame.DIFFICULTY.EASY.EASY`、退出为`esc`、确认为`nodabian`、状态倒计时为`plain.Value`。
- `StarterGui.GameHUD.Team0EXC [Frame]`是大厅队内等待条，直属`esc [ImageButton]`负责退出匹配。任何成员进入组队台并被服务端接纳后显示，离队后隐藏；房主确认后`Team001`隐藏而本条继续显示。退出由服务端将角色放到对应台`CFrame.LookVector`前方、检测范围与退出边距之外并朝向该台。
- `StarterGui.GameHUD.Team`是副本结算面板：时间为`muban.TIME`、排行行为`muban.001`～`004`、保存并返回大厅为`nodabian`。编辑态`Team.Visible=false`；`Team001`虽然模板可见，客户端启动后必须先隐藏。
- 合作副本必须保留`StarterGui.GameHUD.fanhui.Lobby/Return [TextButton]`和`GameHUD.fanhuidating [Frame]`；后者直属`Return/no [TextButton]`分别确认返回和取消。副本同时显示Lobby与Return，并让确认Frame默认隐藏；大厅只需显示Lobby并隐藏这些可选副本确认节点。
- 副本运行时禁用场景中任何可选保留的匹配台`join`状态牌BillboardGui、`Workspace.Function.Reset`下Prompt和所有Area01～08门价`SurfaceGui.rebirth`；匹配台完全缺失也必须安全启动。Area09不参与合作局。

## StarterGui契约

`StarterGui.GameHUD.Enabled`必须为`true`，否则整套HUD及其按钮不会显示或接收输入。各功能面板的初始显隐继续由对应客户端控制器负责。

`ReplicatedStorage.Power`和`Workspace.Power`作为未使用素材保留，玩法代码不得读取、等待、克隆、修改或销毁其中对象。Tool03不再创建头顶电量牌或低电量提示；`StarterGui.GameHUD.HUDRoot.NotificationFrame00.Notification`承载袋满与便便教程提示，袋满始终优先。

除保留自身设计字体的`ReplicatedStorage.tishi`外，所有位于`Workspace`的`BillboardGui/SurfaceGui`以及`ReplicatedStorage`场景模板中同类GUI下的文字对象统一使用`Montserrat Bold Normal`字体；只调整`FontFace`，保留文字、颜色、描边、缩放、对齐、RichText和布局。`StarterGui`屏幕HUD不属于该规则；Roblox原生`ProximityPrompt`没有字体属性，继续使用平台默认样式。

```text
StarterGui.GameHUD
├─ fanhui
│  ├─ Lobby [TextButton，当前Place返回出生点；大厅与Coop均显示]
│  └─ Return [TextButton，合作副本打开返回确认]
├─ fanhuidating [Frame，合作副本返回确认，默认隐藏]
│  ├─ Return [TextButton，确认保存并跨Place返回大厅]
│  └─ no [TextButton，取消并隐藏确认]
├─ TrailMultiplierDisplay
│  └─ TrailMultiplierLabel [文本节点]
├─ RebirthMultiplierDisplay
│  └─ RebirthMultiplierLabel [文本节点]
├─ HUDRoot
│  ├─ CoinsFrame
│  │  ├─ Value
│  │  └─ +Value
│  ├─ BagFrame
│  │  ├─ ImageLabel
│  │  ├─ name
│  │  ├─ Value
│  │  └─ BarBackground.Fill
│  ├─ AreaProgressFrame
│  │  ├─ Value
│  │  └─ Icon [ImageLabel或ImageButton]
│  ├─ comok [电脑端提示，Studio默认隐藏]
│  ├─ NotificationFrame00 [袋满提示，Studio默认隐藏]
│  │  └─ Notification
│  ├─ ToolFrame
│  │  ├─ UIListLayout
│  │  └─ ImageButton [隐藏模板]
│  │     ├─ ImageLabel
│  │     ├─ ToolName
│  │     ├─ key [TextLabel，数字键1～9]
│  │     ├─ number [失物堆叠数量xN]
│  │     ├─ UIStroke
│  │     └─ UICorner
│  ├─ GetHint [Frame，已停用的旧屏幕收取提示，保持隐藏]
│  │  ├─ Icon [ImageLabel]
│  │  └─ TextLabel
│  ├─ yin
│  │  └─ Value
│  ├─ NotificationFrame02
│  │  ├─ Notification
│  │  └─ Icon
│  ├─ Lossofprogress
│  │  ├─ TextLabel
│  │  └─ ScrollingFrame.ItemFrame
│  ├─ Friendcollection [旧好友奖励领取入口]
│  │  ├─ ImageButton [GuiButton]
│  │  │  └─ number [TextLabel]
│  │  └─ friend [TextLabel]
│  └─ GetDiamond
│     ├─ Icon
│     ├─ Light
│     └─ TextLabel
├─ NotificationFrame
│  ├─ UIGradient
│  └─ Notification
├─ Frame
│  ├─ Codex
│  ├─ invite [GuiButton，Roblox官方体验邀请]
│  ├─ Upgrade [GuiButton，直接打开升级面板]
│  ├─ Rebirth [GuiButton，进入游戏后始终显示]
│  │  └─ tixin [ImageLabel，可重生提醒，模板默认隐藏]
│  └─ QuickSell [GuiButton，Quick Sell通行证入口]
├─ chongshengqueren [GuiObject，重生确认界面]
│  ├─ monexplain [TextLabel，客户端写入`Money <金币要求>`]
│  ├─ explain [TextLabel，客户端写入`find X/Y`]
│  ├─ jindu
│  │  ├─ Name [TextLabel，客户端写入`当前金币/金币要求`]
│  │  └─ BarBackground
│  │     └─ Fill [GuiObject，X比例为`clamp(当前金币/金币要求, 0, 1)`]
│  ├─ closes [GuiButton，关闭界面]
│  ├─ Header.number [TextLabel，当前RebirthCount纯数字]
│  ├─ Buttons
│  │  ├─ RobuxPurchase [GuiButton，普通确认]
│  │  │  └─ Stud
│  │  │     ├─ Cost [UIGradient，可重生状态]
│  │  │     └─ Owned/Locked [UIGradient，锁定状态]
│  │  └─ SKIP [GuiButton，Developer Product 3691791013]
│  ├─ X1 [TextLabel，格式`数值x Cash`]
│  ├─ X2 [TextLabel，格式`数值x Cash`]
│  ├─ numX1 [TextLabel，格式`数值X Quantity`]
│  └─ numX2 [TextLabel，格式`数值X Quantity`]
├─ Reset [Frame，区域钱币重置确认界面，Studio默认隐藏]
│  ├─ muban
│  │  └─ explain [TextLabel，客户端写入权威条件或失败原因]
│  ├─ nodabian [ImageButton，确认按钮]
│  │  ├─ allowed [TextLabel，运行时固定显示Reset]
│  │  └─ Stud
│  │     ├─ UIGradient [可重置状态]
│  │     └─ UIGradient2 [不可重置状态]
│  └─ Banner
│     └─ Close [TextButton，关闭界面]
├─ invite [GuiObject，可选退休庭院列表，运行时不使用]
│  ├─ GoHome [GuiButton]
│  ├─ nodabian [GuiButton]
│  │  └─ allowed [TextLabel，Allowed/Blocked]
│  └─ List.muban [隐藏玩家行模板]
│     ├─ name [TextLabel，玩家DisplayName]
│     ├─ Image.Icon2 [ImageLabel，玩家HeadShot头像]
│     ├─ invite [GuiButton，退休对象，运行时不使用]
│     └─ visit yard [GuiButton，退休对象，运行时不使用]
├─ accept [GuiObject，可选退休接受弹窗，运行时不使用]
├─ Codex
│  ├─ Banner.Close
│  └─ ListHolder.AchievementsList.List.Template [隐藏模板]
│     └─ Main
│        ├─ UIGradient1 [Common]
│        ├─ UIGradient2 [Uncommon]
│        ├─ UIGradient3 [Rare]
│        ├─ UIGradient4 [Legendary]
│        ├─ UIGradient5 [Mythic，粉紫渐变]
│        ├─ Name
│        ├─ Difficulty
│        ├─ Description
│        ├─ IconFrame
│        │  ├─ Icon
│        │  ├─ Amount
│        │  └─ cost [文本节点]
│        ├─ Claim [GuiButton]
│        │  └─ Title [文本节点]
│        └─ Claimed [可选GuiObject]
└─ UPattribute
   ├─ Banner.Close
   └─ Frame.ScrollingFrame
      ├─ UPhand.hand.List
      ├─ UPsaoba.saoba.List
      ├─ UPcuifnegji.cuifnegji.List
      └─ UPpeople.cuifnegji.List
```

- `Frame.Rebirth`、`Frame.QuickSell`和`chongshengqueren`的Studio位置与尺寸均由现有布局决定。重生入口和SKIP运行时始终显示；`Frame.Rebirth.tixin`必须为默认隐藏的`ImageLabel`，客户端只按资格与面板状态控制其可见性，不缩放`tixin`本身。资格成立且面板关闭时，客户端在`Frame.Rebirth`直属`UIScale`上组合1.12倍资格脉冲和1.08倍悬停缩放；打开面板、请求重生或成功重生时恢复原尺寸。大厅与合作副本模板都必须保留`monexplain/explain [TextLabel]`，默认文字分别为`Money 500`和`find 0/5`；其余默认文字为`0/500`、空金币进度、`1x Cash/2x Cash/1X Quantity/1.5X Quantity`及`Header.number=0`，默认只启用`Owned/Locked`渐变。客户端按`round(500 × 2.5 ^ RebirthCount)`显示权威金币要求，并按`RebirthCount + 1`显示当前金币倍率；金币足够或本轮彩虹便便数量足够任一项成立即可重生，金币本身不额外消费，成功重生仍由统一重置流程清空本轮金币。
- `GameHUD.Reset`只能由世界重置Prompt打开，并与图鉴、升级和Rebirth面板互斥。`explain`按权威状态显示`Clear Areas 1-N to reset Coins.`、`Collect all reset coins before resetting again.`或真实庭院原因；锁定时点击确认只让该文字放大到1.12倍并短暂变为`RGB(255,80,80)`，随后恢复Studio原色与尺寸。`UIGradient/UIGradient2`必须严格二选一，服务端确认成功后关闭面板。
- `Frame.QuickSell`只连接客户端点击；未拥有Game Pass `1941655401`时打开原生购买框，拥有后调用`RequestQuickSell`。客户端不得直接移除背包或失物，也不得因购买完成自动结算。
- `HUDRoot.Automatic`必须是`GuiButton`并保留直属`off [TextLabel]`、`OP [TextLabel]`和`UIGradient1/UIGradient2 [UIGradient]`。代码只在`off`写`ON/OFF`并在两个渐变间切换，不修改`OP`标题；任一功能节点缺失或类型错误时只警告并安全停用Automatic，不得无限等待或阻塞客户端Bootstrap。按钮状态仅属于当前会话，不进入DataStore。
- `HUDRoot.Diamond`已删除，客户端不得等待或重建钻石余额框。
  - `fanhui.Lobby [TextButton]`在大厅和合作副本都显示，只用于把当前角色移动到本Place唯一启用的`Workspace.SpawnLocation`，不是多人大厅或跨Place Teleport入口。`fanhui.Return`只在合作副本打开`fanhuidating`，确认后复用`RequestCoopReturn`保存并优先返回TeleportData登记的原大厅服务器，失败时回退到任意大厅服务器。任一副本确认节点缺失或类型错误时只警告并隐藏Return，不得阻断Lobby返回出生点或合作控制器其余功能。
  - `HUDRoot.GetDiamond`保留原对象名，作为失物首次获得、失物金币和区域中央提示的只读视觉模板。首次获得普通失物时，客户端只在世界飞行动画结束且收到权威入库成功结果后克隆它并显示`NEW!`与物品图片；提交失物时显示金币图片和`+最终实际到账金币`并飞入`CoinsFrame.Value`。
- 同一模板也用于区域解锁中央提示；图片来自目标区域`RegionConfig.Image`，八区当前共用临时占位图，后续只替换配置资源ID，不新增Studio图片对象。

- `GetHint`、`GetDiamond`、`ToolFrame.ImageButton`、失物`ItemFrame`、图鉴`Template`、`GameHUD.NotificationFrame`、`HUDRoot.NotificationFrame02`和升级面板是隐藏模板或隐藏容器，运行时代码不得销毁原对象。
- `GameHUD.NotificationFrame.Notification`同时承载退出菜单保存结果；ESC/CoreGui菜单保持打开且服务端保存成功时显示`Progress saved.`，失败时显示`Save failed. Please try again.`。该提示不走默认渐隐，`GuiService.MenuClosed`后立即隐藏并恢复当前最高优先级常驻文字；教程来源高于门价建议来源，无需新增Studio UI对象。
- `HUDRoot.GetHint`不再生成任何运行时克隆，也不再随机出现在屏幕或飞向背包；客户端只保证它保持隐藏。正式逐片反馈统一使用`ReplicatedStorage.tishi`世界模板。
- `HUDRoot.CameraButton`与`HUDRoot.comok`必须不存在；客户端不得等待、查找或创建替代对象。所有设备固定第三人称，不提供视角或Ctrl鼠标提示UI。
- 图鉴运行时只克隆`Template`生成LostItem01～25条目；`Amount`显示下一未领取节点，`cost`按当前`StateSnapshot.LeafValueMultiplier`显示该失物倍率后单件兑换价值，`Claim.Title`仍显示不应用价值倍率的本档基础金币奖励。存在下一档时`Claim`始终可见，未达标点击显示目标提示；100档领取后隐藏`Claim`。可选`Claimed [GuiObject]`存在时同步显示，缺失时不等待、不创建替代节点且不影响客户端启动。
- `ToolFrame.ImageButton.Visible=false`。客户端按库存克隆按钮，`ImageLabel`只显示配置图片，`ToolName`只显示名称；键盘可用时`key`按当前槽位显示`1～9`，纯触屏或第10槽以后清空并隐藏；`number`继续独立显示失物堆叠数量`xN`，允许和`key`同时显示。`UIStroke`的粗细、透明度和缩放模式沿用Studio模板，客户端只按实际装备状态将颜色切换为已装备`#FFFFFF`、未装备`#808080`。现有横向`UIListLayout`负责居中和排序，Roblox默认Backpack栏由客户端关闭。
- `GameHUD.Frame.invite [GuiButton]`是官方体验邀请入口。大厅客户端点击后调用`SocialService:CanSendGameInviteAsync()`，可用时打开`PromptGameInvite()`；不配置LaunchData，不打开自定义面板。Coop客户端隐藏该按钮。`GameHUD.invite`、`GameHUD.accept`和`ReplicatedStorage.frend`均为可选退休对象，运行时代码不得读取或等待。
- `HUDRoot.Friendcollection`只兼容旧存档中已有的好友奖励：`ImageButton.number`显示领取金额，`friend`显示贡献者；没有待领奖励时隐藏。它不依赖退休邀请UI或访客模板。
- `HUDRoot.jiaqun [GuiButton]`是官方社区入口；客户端连接其`Activated`事件，不覆盖Studio中的位置、尺寸、图片或文字。目标社区固定为Group ID `220344414`，使用Roblox原生加入界面而不是外部网页。服务端确认会员并发放一次性1000金币后，客户端只把当前玩家`PlayerGui`中的克隆设为隐藏；不得删除或隐藏StarterGui模板，否则未加入玩家将失去入口。
- `CoinsFrame.Value`只显示金币数值，使用小于1k原样、达到1k后一位小数向上取整的小写紧凑格式，不添加`Coins:`等说明文字。`CoinsFrame.+Value`默认隐藏并使用`+0`：正向金币继续使用累计/飞入动画，双倍金币时先显示`+基础值`再显示无前导加号的`基础值x2`；区域门权威扣款成功时复用同一节点显示`-门价`并与整个CoinsFrame各脉冲一次，约1秒后恢复隐藏。扣款表现必须取消冲突的正向动画并采用`CoinSpendEvent.TargetCoins`，失败请求不得显示负数。失物金币会与`GetDiamond`中央提示同时开始，连续提交逐笔排队。
- `TrailMultiplierDisplay.TrailMultiplierLabel`与`RebirthMultiplierDisplay.RebirthMultiplierLabel`是可选的只读倍率标签；存在时前者只显示老档权威`PersonalLeafValueMultiplier`，倍率为x1时隐藏整个`TrailMultiplierDisplay`，大于x1时按`Multiplier x数值 (Upgrade)`显示；后者独立显示重生叶价倍率。两者都不得混入区域倍率，缺失或类型错误只跳过对应显示，不得阻断HUD及其他客户端控制器启动。
- `GameHUD.Commodity`已废弃，客户端不再读取、等待或显示该对象；正确Place可保留隐藏模板，也可直接删除整个层级，不影响Bootstrap或世界购买台。
- `GameHUD.HUDRoot.x2coins [GuiButton]`是独立双倍金币购买入口，不得放入`Commodity`轮换。它必须保留直属`Rb [TextLabel]`作为价格和直属`TextLabel`作为`x2 Cash`标题；客户端只写`Rb`，资格未就绪或拥有后隐藏，未拥有时常驻且点击打开Game Pass `1935165459`购买提示。
- `Area_01～Area_08.Sign.Sign.SurfaceGui.TextButton`是可选的世界双倍金币购买入口；存在时点击复用`x2coins`的同一购买锁和Game Pass提示。缺失或尚未Streaming载入时不得等待、警告或影响客户端启动，运行时载入后自动接入。未拥有玩家保持购买牌Studio原样；`DoubleCoinsOwned=true`后，当前玩家客户端把直属`Area_XX.Sign`内全部BasePart设为本地透明并关闭全部SurfaceGui，原始`LocalTransparencyModifier/Enabled`必须可恢复，且不得影响其他玩家。
- 独立双倍金币按钮成功取得`GetProductInfo(GamePass).PriceInRobux`后使用共享紧凑格式，查询失败时保留Studio价格。Tool04和3K/5K背包的HUD轮播价格与点击逻辑已移除；其Roblox购买提示和拥有后装备继续由世界购买台负责。
- `BagFrame.name [TextLabel]`显示当前`BagConfig.Name`英文名称，不显示`Lv.X`；bag01～bag010依次为`Trash Pack/Chick Pack/Cow Pack/Rover Pack/Paw Pack/Super Pack/Fruit Pack/Blackwing Pack/Angel Pack/Space Pack`。`BagFrame.Value [TextLabel]`的当前装载量和最大容量都使用紧凑单位，例如`1.2k/5k`；小于1k的一端仍显示整数。`AreaProgressFrame.Value`仍显示精确`已收集/总数`且不使用单位。`BagFrame.ImageLabel`读取当前BagConfig图片，空字符串时隐藏。
- `HUDRoot.NotificationFrame00`默认隐藏，`Notification`保留Studio文字与样式；权威`BagFull=true`时常驻显示且自身保持Studio原始Rotation。未满袋时可显示当前便便教程的英文步骤；袋满覆盖教程文字，清空后恢复。只有玩家同时按住清扫输入才持续修改独立的`BagFrame.Rotation`形成左右抖动，松开或清空后恢复。该提示不复用`GameHUD.NotificationFrame`。
- `LostItem099.Model["1"]`必须保留为可着色`BasePart`（当前为MeshPart）。模板内Script不会被运行时克隆保留；世界实例、轮播假模型和角色手持实例的Neon彩虹颜色由客户端`PoopController`统一驱动，卸下后恢复Studio模板的原始颜色与材质。
- `LostItem099`的世界Prompt、制造者牌、快捷栏和携带Tool统一从共享配置读取`Rainbow Poop`；`LostItem095～098`继续显示`Poop`。
- `AreaProgressFrame`显示玩家脚下`Area_XX.ground`对应区域的信息：`Value`固定显示叶子实体`已收集/总数`，`Icon`读取该区`LeafConfig.AreaPools`第一种类型的图片。`BarBackground`图形进度条与`luck`均已删除，不属于对象契约，客户端不得等待、恢复或更新这些节点。`Lossofprogress.Visible`只由Studio模板决定，客户端不得根据初始化、区域完成或区域切换修改父Frame可见性；内部次数与图片仍随`CurrentAreaId`和个人庭院实时更新，道路上保留最后区域。
- `GameHUD.Frame.Codex/Upgrade/Rebirth`分别切换图鉴、升级和重生主界面；`GameHUD.Reset`由世界Prompt打开。四个主界面由客户端统一互斥，打开其中一个会关闭当前面板。`Frame.invite`只打开Roblox原生邀请界面，不参与自定义面板互斥或Blur。任一自定义主界面可见时，客户端在`Lighting`创建或复用`LocalModalPanelBlur [BlurEffect]`，固定`Size=18`并启用；全部关闭后禁用。该模糊对象是纯本地运行时效果，不要求Studio预置。
- 五个主界面打开时从各自Studio原位置下方上移，略微越过后向下回落到原位置；运行时代码只暂时修改`Position`，关闭时恢复。现有HUD入口按钮的`AnchorPoint`和Studio尺寸保持不变，客户端仅在PlayerGui克隆中创建或复用`UIScale`实现鼠标悬停1.08倍放大，移开恢复原大小。
- `GameHUD.Frame.Upgrade [GuiButton]`还可由Area_01～09中实际存在的`UPattribute.up.ProximityPrompt`打开同一面板。HUD按钮不要求玩家靠近升级台；`Banner.Close`或键盘E键也可关闭面板。
- `GameHUD.UPattribute`必须保留`UPattributeicon.1～4 [GuiButton]`及直属`Player/Hands/Broom/Blower [ScrollingFrame]`。每个分页按钮必须包含`Stud.Cost [UIGradient]`和`Stud["Owned/Locked"] [UIGradient]`：当前页仅启用`Owned/Locked`，其余按钮仅启用`Cost`。按钮依次切换四页；每张普通属性卡保留直属`Name/Info/explain [TextLabel]`及`BuyButtons.Buy [GuiButton]`，购买按钮内必须存在`Cost [TextLabel]`。每个Buy还应有`Decor.Stud`和`Highlight`容器；`Hands["Pickup Amount"].BuyButtons.Buy.Decor.Stud.UIGradient002 [UIGradient]`及同一Buy下`Highlight.UIStroke002 [UIStroke]`提供灰色不可购买模板。运行时会把缺少的模板克隆到其余普通属性卡相同层级，不能放置同名但类型不同的对象。`UPattribute.Bag`和`UPattributeicon.5`已删除，不再属于契约。
- 大厅与合作副本的`UPattribute.Player`都必须保留`Pickup0001～0003 [GuiObject]`三张背包卡。每张卡必须包含直属`Name/Info [TextLabel]`、`Image.Icon [ImageLabel]`、`BuyButtons.Buy/Bu2 [GuiButton]`及两个按钮各自的`Cost [TextLabel]`；代码不创建、克隆或移动这些卡。`Pickup0001`显示下一档bag02～08，之后显示扩容图标`rbxassetid://114584597270599`及`当前容量->目标容量`；`Pickup0002/0003`固定显示bag09 3K与bag010 5K。2026-08-19已在大厅Place `95556867008792`和副本Place `131244809352557`核验三张卡及全部数据节点类型正确。
- Player页普通属性只保留`Pickup Amount → Move Speed`；`Pickup Speed → Value Multiplier`已从大厅Place `95556867008792`和副本Place `131244809352557`删除，旧发布模板若残留则客户端只销毁PlayerGui克隆。背包`Pickup0001～0003`不参与普通属性绑定。Hands、Broom、Blower各保留`Pickup Amount/Pickup Range/Pickup Speed`三张模板卡，运行时名称按真实属性覆盖；尤其不得删除Hands页教程使用的`Pickup Speed`。
- 新手进入双手数量或速度升级步骤时，客户端自动打开Hands页，并脉冲对应卡的`BuyButtons.Buy`；同一步骤手动关闭后不因重复快照再次强制打开。
- `HUDRoot.yin`默认由教程客户端隐藏；第1步进入Area_01钱币水平距离6 studs后才在Studio原位置显示`Press to Pick Up`，玩家累计实际装袋或即时回收第15片叶子后隐藏；升级步骤不再移动或显示该对象。
- 图鉴Template必须包含名称、难度、介绍、次数和图标，并应保留`Main.UIGradient1～5`。五个渐变依次对应`Common/Uncommon/Rare/Legendary/Mythic`，完整时每张卡只启用其稀有度对应的一项；`UIGradient5`使用粉紫色。任一渐变缺失或类型错误时客户端只警告一次、保留Studio模板默认外观，不得阻断快捷栏、清扫范围及其他控制器启动。运行时仍按配置生成25项，未收集图标显示黑色剪影。
- `NotificationFrame02`默认隐藏，Studio位置是第一条可购买提示的最终位置。运行时只克隆下一级普通背包、Tool02和Tool03购买提示，最多同时4条，按模板高度加8像素向下排列；`Notification`显示候选文字，图片为空时隐藏`Icon`。
- UI颜色、字体、渐变和最终布局由Studio决定，代码只维护固定数据节点和动画状态。

## SoundService契约

- `Grass_walk_2 [Sound]`：单片装袋音效模板。
- `Recycle [Sound]`：每片回收飞叶或门购买金币抵达时的本地音效模板；门动画逐枚复用同一对象池，不创建新的Studio声音对象。
- `demo [Sound]`：失物成功兑换音效模板，每个有效兑换条目播放一次，固定间隔0.1秒。
- `Background [Sound]`：背景音乐，Studio配置`Looped=true`、`Playing=true`。
- `leafBlower [Sound]`：吹风机本地工作音效模板，Studio保持`Looped=false/Playing=false`。客户端初始化时克隆并异步预加载唯一的本地循环实例；操作者按住时直接`:Play()`，停止工作时`:Stop()`并将`TimePosition`归零但保留实例供下次复用。
- 袋满反馈使用HUD控制器当前绑定的声音模板；缺失模板只能跳过表现，不改变服务端规则。
- 音量、SoundId和PlaybackSpeed默认由Studio模板配置；`Recycle/demo`运行时克隆按实际重叠峰值增长并在结束后进入各自对象池复用。

## Prompt与代码职责

- 商品、回收和失物Prompt的ActionText、ObjectText、距离、按住时间与视线要求通常由Studio设置，服务代码不应覆盖。
- 购买台控制器可以按权威所有权和区域价格更新对应Prompt及价格牌；其他Prompt继续以Studio配置为准。
- Roblox Studio MCP负责对象、属性、Play测试和输出检查；不得使用computer-use控制Studio。正式Luau只在本地`src`修改并通过Rojo同步。
- 禁止运行时代码重建正式GameHUD、购买点、区域门或回收处。

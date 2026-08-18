# 阶段1交接与验收点A

> 历史文档：用户已于2026-07-20确认验收点A通过。本文件保留阶段1当时的参数、测试和增量记录，不再作为当前规格或待办来源；当前状态见`08_STAGE_2_CURRENT_STATUS.md`。

## 当前完成阶段

- 阶段0：完成。
- 阶段1：完成，并已将`Area_01`清理物从草迁移为可重叠落叶，同时加入双手当前局属性升级。
- 当前状态：验收点A已通过，阶段1关闭。
- 未开发：Area_02至Area_08的失物、商品等扩展玩法、多人大厅、Teleport和拾取升级存档；八区落叶生成与完成判定已接入。

## 阶段1早期验收参数（历史）

下表记录阶段1最初交付值，后续工具增量和当前配置已经覆盖其中部分数值。

| 项目 | 当前值 |
|---|---:|
| 生成模型 | `Leaf1`至`Leaf5` |
| 叶子生成数量 | 密度1.5，最少300，最多1000 |
| 双手拾取范围 | 半径1.5 studs |
| 双手范围前移 | 4 studs |
| 基础单次数量 | 1片 |
| 基础拾取间隔 | 0.25秒 |
| 范围5级 | 半径3.73248 studs |
| 速度5级 | 0.100469秒 |
| 数量5级 | 每批6片 |
| Leaf1价值/权重 | 1 / 60 |
| Leaf2价值/权重 | 2 / 30 |
| Leaf3价值/权重 | 3 / 20 |
| Leaf4价值/权重 | 4 / 5 |
| Leaf5价值/权重 | 5 / 1 |
| 初始袋子容量 | 50 |
| 袋子升级后容量 | 85 |
| 袋子升级价格 | 45金币 |
| 回收Prompt距离 | 10 studs |
| 每局失物数量 | 5 |

## 本轮修改

- 新增`LeafConfig.luau`和`LeafService.luau`，删除`GrassConfig.luau`和`GrassService.luau`。
- 运行时容器改为`Area_01.GeneratedLeaves`；实例属性改为`LeafType`、`BagValue`、`AreaId`和`Collected`。
- 叶子独立随机落点、随机水平旋转并允许自然重叠；使用极小高度差减少重叠闪烁。
- `ToolConfig`只保留`Hands`，使用`PickupCount`与`PickupInterval`，删除倍率、兼容草表和`Cleaner1`。
- 服务端按距离排序候选，每0.25秒最多拾取最近1片；未来可直接调整数量和间隔配置。
- Remote改为`LeafCollected(addedAmount, leafType)`；每片仍独立播放获取UI和`SoundService.Grass_walk_2`。
- 删除`grass03`专属音效逻辑；未删除用户Studio中的声音资产。
- 回收动画改为随机克隆5个0.5倍`Leaf1`至`Leaf5`，飞行节奏和目标`Recycle_01.grass.grass`保持不变。
- `LostItemService`改为监听叶子拾取数量和活动叶子；覆盖范围内所有重叠叶子清完后才启用Prompt。
- 删除工具商品配置，运行时禁用`CleaProduct_XX`Prompt；`BagProduct_01`继续正常工作。
- 客户端删除R键工具循环；Q键和ToolFrame仍可装备/卸下双手。
- 状态快照新增`PickupCount`、`PickupInterval`并删除`HarvestMultiplier`；HUD显示每次数量、间隔和范围。
- 回收金币快照新增可选`CoinGainAnimation`；`CoinsFrame.+Value`按5片叶子到达节奏累计奖励、脉冲5次，第5次后停留1秒，再飞入主金币并触发一次框体脉冲。服务器金币与Leaderstats仍立即结算。
- 每段回收金币到达时客户端克隆播放一次`SoundService.Recycle`，共5次并允许重叠，原模板保持不变。
- 未修改`Leaf1`至`Leaf5`、`MagneticRange.MagneticRange`或回收动画Part。
- 通过Studio MCP将`GameHUD.HUDRoot.ToolFrame`加宽至约22%屏幕宽，并启用`ToolName.TextScaled`与取消截断，确保数量、间隔和范围完整可见。
- 通过Studio MCP将`GameHUD.HUDRoot.CoinsFrame.+Value`设置为默认隐藏、文本`+0`；运行时复用原对象，不克隆或销毁。
- 新增`HandUpgradeConfig.luau`，明确保存范围、速度和数量三个分支0至5级的价格及升级后属性。
- 玩家内存状态新增`HandUpgradeLevels`；死亡重生保留，退出服务器后随状态销毁，不加入钻石/图鉴DataStore。
- 新增`UpgradeHandAttribute` RemoteFunction和`HandUpgradeService`，服务端验证属性白名单、等级、价格、金币、请求间隔和玩家锁，成功后扣款并推送有效属性快照。
- `LeafService`改为动态读取玩家有效`Range/PickupInterval/PickupCount`，并用最后成功批次时间与当前间隔比较，使速度升级立即参与下一次判定。
- 新增`HandUpgradeController`，连接`Frame.UPattribute`、关闭按钮和三个升级按钮；价格显示下一等级，满级显示`MAX`，五个等级灯按0/0.5透明度更新。
- 通过Studio MCP将升级面板设为默认隐藏，初始价格设为`$200/$100/$20`，并将15个等级灯统一设为`ImageTransparency=0.5`。
- 通过Studio MCP将`SoundService.Background`设置为自动播放并循环，保留用户配置的SoundId、音量和播放速度。
- 失物世界放置改为以`upgrade`为锚点：将其底面贴到`Area_01.ground`并对整个外层失物应用随机Y轴旋转，正式视觉`Model`保持模板内相对upgrade的位置和旋转。
- 视觉Model包围盒不再参与贴地高度补偿，只继续用于覆盖叶子检测和失物生成避让；无视觉模型时upgrade占位以自身底面贴地。
- 失物模板启动验证新增upgrade直立契约；局部Y轴未保持竖直时服务端用明确断言阻止错误资源进入运行时。
- 成功兑换失物的状态快照新增`DiamondGainAnimation={SequenceId,Amount}`；钻石仍由服务端立即结算并保存，客户端只延迟主HUD数字显示。
- `GetDiamond`改为隐藏动画模板：奖励UI从中下方放大上升、停留1秒，再飞向`DiamondNUM`缩小销毁；连续钻石奖励使用顺序队列。
- 通过Studio MCP将`GetDiamond.Visible=false`、`GetDiamond.TextLabel.Text="+0"`，保留Icon、Light和原旋转LocalScript。
- 新增共享`HarvestGeometry.GetDistanceSquaredToBounds`，服务端实际拾取与客户端下一批提示使用相同的水平包围盒距离和排序规则。
- `LeafTargetHighlightController`只为Tool01按0.5秒间隔选择下一批普通目标并复用`ReplicatedStorage.miaobian.Highlight`克隆池；Tool02/03/04普通客户端扫描保持关闭。当前正式区域剩余最后100片时，`YardLeafController`独立显示最近最多5片`Highlight02`，并暂时抑制Tool01普通描边。
- 叶子生成改为完成Pivot定位后再放入`GeneratedLeaves`；客户端对新复制Model延迟缓存，并在初始化0.5秒后整体刷新一次，避免内部BasePart尚未复制时漏掉目标。
- 新增`AreaUnlockConfig`、`AreaDoorService`与`AreaDoorController`，接入`Area_01`至`Area_08`共56个`Door02`至`Door08`按钮。
- `DoorNN`读取前一区域的团队共享`AreaCleaned`属性；玩家个人`UnlockedAreas`只在当前服务器会话保存并通过状态快照同步。
- 解锁后所有同名门仅在对应玩家客户端变为RGB`207,207,207`、关闭`Door01.CanCollide`并把文字改为`RegionConfig.DisplayName`中的正式场景名；不缩放、不隐藏、不修改透明度、触摸、查询或空气墙。
- `RegionConfig`扩展至Area_01～Area_08；`LeafService`改为维护各区域独立叶子容器、价值、数量、完成状态和`AreaCleaned`属性。
- 启动时Area_01同步生成、Area_02分批生成；Area_03～Area_08只在前一个目标区域首次被玩家解锁时按顺序生成。相同解锁请求不会重复生成。
- 异步生成Folder使用`GenerationComplete`阻止工具和描边处理未完成批次；服务端收取范围、推动工具射线、客户端范围贴地和下一批描边均已改为支持八区ground/GeneratedLeaves。
- Area_02～Area_08叶子不会触发Area_01失物生成或覆盖检查；商品和袋子展示仍保持原Area_01接入范围。

## 已运行测试

- Rojo 7.5.1构建成功，输出到系统临时目录。
- 静态搜索确认`src`中不存在`grass01/02/03`、`GrassService`、`GrassConfig`、`GrassCollected`、`HarvestMultiplier`、`Cleaner1`或`GeneratedGrass`引用。
- 保留的`grass`字符串只有用户固定回收路径`Recycle_01.grass.grass`；保留的`Grass_walk_2`是用户指定音效模板。
- Studio运行成功；按当前`RegionConfig`上限生成1000片叶子和5个失物触发位。
- 运行时叶子实例的`LeafType/BagValue/Collected`属性保持有效，全部BasePart保持锚定并关闭碰撞、触摸和查询；检测到自然重叠叶子。
- 在同一范围布置多个候选时，0.10秒只结算1片，0.32秒结算第2片，未出现同帧清空。
- 单片拾取时客户端生成1个`LeafGainHint`和1个`LeafCollectedSound`，袋子按叶子价值增加。
- 回收表现测试确认随机叶子按0.1秒间隔进入`RecycleEffects`，最后一片到达后才显示并启动原Y轴回收堆动画。
- 50金币回收HUD测试依次记录`+10/+20/+30/+40/+50`；第5次脉冲后最终金额停留约1秒，再飞入主金币。飞入前主金币保持旧值，完成后`+Value`隐藏并恢复原位置，`CoinsFrame`只脉冲一次。
- 53金币测试依次显示`+11/+22/+33/+43/+53`并严格结算到53；1金币测试最终正确显示1且`+Value`仍完成5次脉冲。
- 动画中断测试在显示`+20`时注入新余额17，旧动画立即取消，`+Value`隐藏复位且主金币保持最新17，没有被旧任务覆盖。
- 回收音效测试确认单次五段动画创建正好5个`RecycleStepSound`，声音允许重叠，并在播放结束或10秒容错时间内全部销毁。
- 运行截图确认落叶外观、自然重叠和完整工具参数文字可见。
- 控制台没有本轮脚本错误；仍有既有失物占位警告、Studio DataStore API未开启警告和用户原脚本等待`Workspace.Animations`警告。
- 本轮Rojo 7.5.1再次构建成功，输出到系统临时目录；Studio启动后服务器和客户端升级模块均无脚本错误。
- 初始升级UI验证通过：面板默认隐藏，三个价格为`$200/$100/$20`，15个等级灯均为0.5，三个按钮可用。
- 使用实际UI输入验证外部入口可打开面板、`Banner.Close`可关闭；0金币调用范围升级返回“需要200金币”，金币、等级和范围均保持不变。
- 服务端隔离测试以20000金币购买全部15级：总扣款9920，最终余额10080；三个等级均为5，有效范围3.73248、间隔0.100469、数量6。
- 快速连续升级请求被“操作过快”拒绝；满级后的额外请求不扣金币，并返回“已达到最高等级”。
- 满级快照UI验证通过：三个价格均显示`MAX`、按钮禁用、15个等级灯全部为0；工具HUD显示每次6片、0.10秒、范围3.7，范围显示直径Tween到约7.46496 studs。
- 背景音乐运行验证通过：客户端`SoundService.Background.IsPlaying=true`、`Looped=true`，播放时间正常推进。
- 使用临时运行态克隆将视觉Model放到upgrade上方和侧面，放置后相对位置误差约`0.00000024 studs`、旋转误差0；upgrade底面贴地误差约`0.0000038 studs`。
- 使用5个不同随机种子验证整体Y轴旋转，upgrade底面始终贴地，视觉相对位置最大误差约`0.000016 studs`。
- 无视觉Model的upgrade占位保持可见并正确贴地；正式视觉存在时upgrade继续隐藏，覆盖半径仍来自视觉包围盒。
- Tool测试确认视觉Model相对克隆Handle的位置和旋转误差均为0，没有被重新居中。
- 钻石动画采样确认主数字在飞入前保持旧值；0.45秒时到达中上方并恢复原尺寸，约1.6秒进入飞入阶段，约2.1秒销毁并更新主数字。
- 连续`+5`和`+10`奖励测试确认依次播放：第一段期间主值保持100，第一段完成后显示105并播放第二段，最终显示115且无残留克隆。用户已确认当前实际效果可以。
- 正式控制器在1000片叶子运行配置下自动缓存并显示目标；角色位置改变后描边从`Leaf1_158`切换到`Leaf1_392`，约0.1秒更新链路正常。
- 基础`PickupCount=1`时启用1个描边；注入满级有效数量6时启用6个描边。袋子只剩1容量时截断为1个，袋满时6个池对象全部关闭但继续复用。
- 实际启动拾取后，原目标`Leaf1_392`立即标记`Collected=true`并离开`GeneratedLeaves`，描边自动转移到下一片；卸下双手后启用描边数为0。
- `ReplicatedStorage.miaobian.Highlight`验证为白色纯描边、`FillTransparency=1`、`OutlineTransparency=0`和`AlwaysOnTop`，运行时克隆未覆盖这些属性。
- Studio对象检查确认8个区域各有7个完整门按钮，共56个绑定。隔离客户端测试中解锁`Area_04`后正好8个`Door04`变灰、关闭碰撞并显示“树林”，其他48个门保持未解锁状态。
- 门表现测试确认解锁前后`Door01.Transparency`不变，`CanTouch/CanQuery`保持原值；未执行任何缩放、隐藏或空气墙操作。
- 服务端隔离测试确认`Area_03.AreaCleaned=false`时提示“清理完区域3解锁”且状态不变，设为`true`后写入个人`Area_04`、推送一次快照并提示“已解锁区域4”。
- 临时四区生成测试确认启动阶段Area_01/02各生成300片、Area_03/04为0；调用Area_02解锁联动后Area_03生成300片且Area_04仍未创建。
- 生成完成测试确认Area_01、Area_02和后续Area_03的`GenerationComplete=true`，未到前沿的Area_04没有`GeneratedLeaves`Folder。
- 门与生成联动测试确认解锁Area_03时只调用一次下一地区生成入口，由叶子服务幂等生成Area_04。
- 提示UI从已删除的`HUDRoot.Notification`迁移到`HUDRoot.NotificationFrame.Notification`；Frame保存用户设计的背景、渐变和描边，TextLabel只负责文字。
- 普通提示显示时完整保留Studio中的`NotificationFrame`外观；停留结束后背景、文字、图片和描边同步淡出，隐藏后恢复模板原始透明度供下次显示。

## 当前遗留与非阻塞项

- `Leaf1`至`Leaf5`使用SpecialMesh，视觉尺寸不一定等于Part包围盒；服务端判定和落地使用Model/BasePart包围盒，需在Studio验收视觉边缘。
- 用户原有`grass01/02/03`模型未被代码引用，也未被本轮自动删除。
- 当前双手升级仅为服务器会话内成长；如果以后需要跨服务器保留，必须另行设计存档版本迁移，本轮不写入现有DataStore。
- Studio原有无关脚本和旧GUI仍不属于本轮修改范围。

## 用户验收点A（已通过）

- 叶子是否只生成在`Area_01.ground`并能自然重叠，重叠处是否没有明显闪烁。
- 多片叶子处于范围内时，双手是否每0.25秒只拾取1片。
- 半径1.5 studs、前移4 studs的显示范围和实际判定是否一致。
- 下一批叶子是否始终显示白色描边；数量升级后是否同时提示整批，袋子容量不足、袋满或卸下工具时是否正确减少或隐藏。
- 三个升级入口是否清楚；价格、等级灯和`MAX`反馈是否易懂。
- 范围升到3.73248、速度升到0.100469秒、单批数量升到6片的成长幅度是否合适。
- 金币不足、快速点击、死亡重生和退出重进时的升级行为是否符合预期。
- 五类叶子的1/2/3/4/5价值、生成频率和袋子节奏是否合适。
- 每片叶子的飞向玩家动画、数量UI、袋子脉冲和音效是否保持原有观感。
- 回收时5个随机0.5倍叶子是否按原节奏飞向回收堆，并正确衔接Y轴动画。
- 重叠叶子没有全部清除前，失物Prompt是否保持禁用。
- 后续加入正式失物Model后，upgrade底面是否贴地，视觉Model是否保持用户在模板中设置的相对位置。
- 袋子购买、回收金币、镜头、鼠标、图鉴、钻石和失物携带是否保持正常。
- 区域未清理时门提示是否正确；解锁后所有同名门是否只对当前玩家变灰、关闭碰撞并显示“区域N”，同时保持可见且不影响空气墙。

## 阶段转换

验收点A门槛已经关闭。后续唯一有效路线为`03_IMPLEMENTATION_ROADMAP.md`中的阶段2，并由`08_STAGE_2_CURRENT_STATUS.md`维护当前待办；本文件下方增量记录继续作为历史证据保留。

## 2026-07-19 扫把与吹风机增量交接

- 新增`ToolUpgradeConfig`与`ToolUpgradeService`。Tool02扫把和Tool03吹风机的解锁、属性等级及升级只保留在当前服务器内，不写入现有DataStore。
- `CleaProduct_01/02/03`分别用于免费切回双手、500金币解锁/装备扫把、3000金币解锁/装备吹风机；已解锁后重复触发免费切换。
- 扫把每0.6秒影响圆心最近的最多10片叶子，内圈向玩家最多移动`3 × SweepStrength`，外圈为20%，不会越过玩家。
- 吹风机按住输入时每0.15秒影响圆心最近的最多30片叶子，按`Power × 0.15`向外移动；内圈保持±15度扰动，外圈按Accuracy对应概率产生±45至135度偏航。
- 推动工具只移动锚定叶子，不增加袋子、清洁进度或失物触发数量，也不发送收集批次声音/动画；袋满时仍可使用。
- 客户端对Tool02/03显示同心内外圆，内圆半径为外圆50%；Tool02显示恢复目标及本批推动目标，Tool03按移动端圆形或电脑端渐宽气流显示本批目标。
- 升级面板同时连接双手、扫把和吹风机分支。未解锁分支显示“需要解锁”，点击后由服务器提示“需要解锁扫把/吹风机”，不扣金币。
- 本轮只修改VS Code/Rojo源码与项目文档，没有直接修改Studio对象或脚本。
- 已使用Luau 0.730编译器对`src`全部`.luau`执行语法解析，全部通过；Rojo 7.5.1构建成功，输出为系统临时目录中的`Clean_the_floor_tools_verify.rbxlx`。
- 尚需在Studio Play中验证实际UI节点拼写、`CleaningTools.Tool02/Tool03`类型、三个购买Prompt、叶子贴地滑动观感和1000片叶子下的持续吹风网络表现。

## 2026-07-20 范围圆圈残留修复

- `HarvestRangeController`现在同时控制外圈、内圈Part与其子级Decal；隐藏时Decal透明度设为1，显示时恢复模板透明度。
- Tool02/03切回Tool01时取消内圈尺寸Tween并立即隐藏内圈Decal，不再把旧内圈留在最后位置。
- 每帧先检测玩家脚下属于哪个`Area_XX.ground`；脚下没有区域ground时隐藏全部圆圈并向服务端发送无效瞄准。
- 相机中心射线和边缘补偿射线只命中玩家当前所在区域的ground，避免离开区域后吸附在区域边缘或跨区域显示。
- 玩家脚下检测从根部上方4 studs向下延伸20 studs，普通跳跃仍在区域ground垂直投影范围内时继续显示。
- Studio Play隔离验证确认：模板Decal透明度`0.2`可正确恢复；Tool01和统一隐藏路径都会把内外圈Decal设为`1`；区域ground上方可识别当前ground，远离所有区域时返回无效。
- Rojo 7.5.1构建成功，输出为系统临时目录中的`Clean_the_floor_range_fix_verify.rbxlx`。

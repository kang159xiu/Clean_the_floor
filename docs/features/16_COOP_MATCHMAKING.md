# 四人合作匹配与副本

## 目标与边界

大厅四个组队台各自组成最多四人的本服队伍，并把队伍传送到独立保留服务器。`CoopMatch`使用同一份源码但运行共享Area01–08进度、局内临时成长和合作结算；不做跨服务器补人，不恢复中途断线，不把合作通关写入单人通关榜。

## 玩家流程

玩家进入`place001`～`place004`之一后立即看到`Team0EXC`。首位成员成为房主，并在尚未确认时额外看到`Team001`以选择1～4人和四档难度；非房主不显示配置面板。房主确认后`Team001`隐藏，全队保留`Team0EXC`等待传送；未满目标人数时倒计时15秒并允许其他玩家加入，满员提前开始。`Team0EXC.esc`（以及房主配置阶段保留的`Team001.esc`）退出队伍，服务端立即把角色移到当前组队台前方检测范围之外；房主退出后按加入顺序转交。服务端确认入队后，该成员本地立即关闭当前台围墙，未满目标人数时其他玩家仍可进入，满员后服务端对所有玩家关闭围墙。副本等待名单成员最多10秒，随后以实际到达成员开始。副本全程显示`fanhui.Lobby`和`fanhui.Return`：前者只回当前副本Place的出生点，后者点击后由`fanhuidating.Return/no`确认或取消，确认时保存并优先返回进入副本前的同一大厅服务器，不可用时进入其他大厅服务器。Area08清完显示合作排行，`Team.nodabian`继续直接保存并返回大厅。

## 服务端权威

`PartyMatchmakingService`维护四支队伍、房主、成员顺序、目标人数、难度、倒计时、世界状态牌、围墙状态、保存和TeleportData，并把大厅`game.JobId`作为可选返回实例ID传入副本。每台世界牌由服务器显示`当前人数/目标人数`、当前难度及确认后的15秒`Starting in Ns`；空队恢复`0/4`和`EASY`并隐藏倒计时。入队按`TargetPlayerCount`封顶；未满且未保存/传送时服务端围墙开放，满员、保存或传送时关闭。满员瞬间已经进入检测区但未入队的玩家会被移到围墙包围盒最近一侧之外。`CoopMatchService`验证大厅SourcePlaceId、保留服务器、协议版本、MatchId及成员UserId，并在玩家主档开始加载前把权威名单和难度同步到运行服务；Studio只建立单人EASY合成局。第一名合法且状态Ready的成员到达后才启动10秒等待，全员到齐则提前开始，等待期间离开的成员不再计为已到达。副本开始/结束、完成时间、排行和返回保存均由服务端裁决；返回请求按玩家加锁，原大厅同步或异步传送失败时只回退一次到任意大厅服务器，最终失败才解除锁并允许重试。

## 客户端表现

`PartyController`显示权威队伍快照并发送房主操作：`Team0EXC`跟随是否在队伍内，`Team001`只在房主尚未确认的Waiting状态显示。成员按快照中的`PadId`每0.2秒在本地开启对应围墙Part碰撞，适配服务器状态复制及Streaming，退出后恢复为开放状态。人数减号在目标人数等于当前成员数时禁用，加号在4人时禁用；倒计时使用服务端截止时间本地刷新。`CoopMatchController`隐藏大厅专用面板、`Frame.Rebirth`、重生确认面板和Reset面板，但保留`fanhui.Lobby`并启用`fanhui.Return`及确认面板；官方邀请控制器同时隐藏`Frame.invite`，不能用平台邀请绕过匹配名单。`LobbyReturnController`负责前者回到当前副本出生点，后者保存或最终传送失败时恢复相关按钮。完成时关闭Automatic和工具输入，填充最多四行`#n: Username - npcs - coins`并处理保存重试。副本升级面板与大厅共用Player页三张背包卡，Player普通属性只显示Move Speed；金币工具和普通升级读取合作局临时等级，并按玩家永久`RebirthCount`使用`1.5^次数`价格，扩容仍按背包自身价格，永久Robux背包继续走权益流程。合作叶子客户端只接受`ScopeKind="Coop"`的当前副本作用域；发布环境要求`ScopeId=game.JobId`，Studio由首个合法Coop Begin锁定作用域。普通状态快照只更新工具范围与区域进度，不触发庭院清场。门仍由`AreaDoorController`读取临时`UnlockedAreas`打开，但副本隐藏价格且不发送购买请求。

## 数据流

平台进入/离开或房主操作 -> `RequestPartyAction` -> 队伍状态 -> 世界TextLabel与`PartySnapshot`。确认 -> 全员主存档保存 -> 含大厅服务器实例ID的Reserved Server TeleportData -> 副本入场校验并同步名单/难度 -> 首名状态Ready成员启动10秒窗口 -> `Playing`开放共享Coop叶子域。个人拾取 -> 共享区域进度、个人幸运箱计数和清理榜；回收 -> 主Coins与个人结算金币；副本Return确认或Area08结算按钮 -> 保存 -> `RequestCoopReturn`优先原大厅并按需回退。

## 配置

`CoopMatchConfig`拥有大厅PlaceId `95556867008792`、副本PlaceId `131244809352557`、协议版本、四个平台、15秒确认和10秒到达时间。难度倍率为EASY 1、HARD 2、NIGHTMARE 3、HELL 4，只乘Area01–08基础叶子总量，不乘人数或Rebirth叶子数量倍率。

## Remote

- `RequestPartyAction`：RemoteFunction；动作仅允许`Leave`、`SetTarget`、`SetDifficulty`、`Confirm`。
- `PartySnapshot`：RemoteEvent；大厅向队员发送房主、成员、目标人数、难度、状态及服务端截止时间。
- `CoopMatchSnapshot`：RemoteEvent；副本发送等待/进行/完成状态、到达人数、完成时间和排行；最终返回传送失败时只向对应玩家附加`ReturnStatus="TeleportFailed"`以恢复按钮，客户端可FireServer请求重发。
- `RequestCoopReturn`：RemoteFunction；合法副本成员在任意副本阶段均可请求，保存成功后返回`Teleporting`，保存/传送启动失败返回`SaveFailed/TeleportFailed`。
- `YardLeafSnapshot/YardLeafDelta`新增`ScopeKind`和`ScopeId`包字段，显式隔离`Yard`与`Coop`。

## 快照字段

不增加主`StateSnapshot`永久契约。合作局仍用主快照显示当前局内工具、背包、Coins和临时`UnlockedAreas`；组队与结算字段使用两个独立Snapshot Remote。

## 永久字段与重置

副本读取主档后保存只读基线。Coins、永久权益、RainbowPoop、LuckyBoxOnboarding、CollectedCounts、CodexClaimedTiers及独立累计排行榜可继续保存；金币工具、普通背包/扩容、Hand/Tool升级、Move Speed、合作区域进度和副本背包均只存在本服务器。老档`PlayerAttributeLevels.LeafValue`不属于临时重置项：副本保留其只读等级和个人价值倍率，但不允许继续购买。死亡不清临时成长；离开副本或中途断线时临时数据消失，主档原背包与成长由基线保护。

## Studio契约

大厅必须保留`StarterGui.GameHUD.Team001`、`GameHUD.Team0EXC`、`StarterGui.GameHUD.Team`、`GameHUD.fanhui.Lobby`及`Workspace.Function.place001`～`place004`，并在`GameHUD.UPattribute.Player`保留`Pickup0001～0003`背包卡。大厅与副本的共享重生模板都保留`chongshengqueren.monexplain/explain [TextLabel]`，默认分别为`Money 500`和`find 0/5`；副本运行时仍隐藏整个重生入口与面板。每个平台状态牌位于`join.BillboardGui.Frame`：`04/easy/TextLabel`分别显示人数、难度和倒计时；只允许修改`底座.Group [Model]`内全部后代Part的碰撞，不修改同名MeshPart。副本不要求复制四个大厅匹配台；若场景保留它们，运行时必须禁用状态牌。副本额外要求`GameHUD.fanhui.Return`和`GameHUD.fanhuidating.Return/no`，大厅允许没有这些副本确认节点。准确层级见`docs/05_STUDIO_OBJECT_CONTRACT.md`。

## 依赖功能

依赖`platform-state`、`persistence-reset`、`leaves-cleaning`、`tools-upgrades`、`bags-capacity`、`economy-commerce`、`lost-items`、`poop-lobby`和`leaderboards-analytics`。

## 不变量

- 每个平台只属于一支队伍，每名玩家同一时间只属于一个平台；非房主不能改人数、难度或确认。
- 目标人数不得低于当前成员数；成员本地围墙始终关闭，外部玩家只在未满时可进入，服务端满员围墙和入队人数必须使用同一目标值。
- 只有Waiting状态房主可见`Team001`；所有队员只要仍在队伍中就必须可见`Team0EXC`，退出后两者立即隐藏且角色位于原台前方检测范围外。
- 传送前所有成员都保存成功；每队使用自己的保留服务器和不可复用MatchId。
- 副本Return必须先保存且同一玩家同时最多一个返回事务；原大厅不可用时只能回退到同一大厅Place，不能传到其他Place。
- 发布副本只接受大厅匹配名单成员；非法直入必须返回大厅或踢出。
- 合作副本必须隐藏官方邀请入口，不能通过Roblox体验邀请绕过大厅匹配名单。
- 合作副本必须隐藏`Frame.Rebirth`、`chongshengqueren`和`Reset`，并拒绝付费门、重生和区域钱币重置入口；大厅中的对应入口不受影响。
- 合作副本的`fanhui.Lobby`只能移动角色到当前副本出生点，不得保存、结束合作局或执行跨Place传送；`fanhui.Return`才负责保存并返回匹配大厅。
- 合法名单与难度必须在任何玩家状态Ready处理和Coop庭院生成前同步；不能以空Fallback名单进入长期`Waiting`。
- `Waiting`和完成阶段必须关闭清扫与便便入口，只有`Playing`允许使用；到达等待从第一名合法Ready成员开始，离开成员不能继续占用到达计数。
- Coop叶子、Yard叶子和Lobby共享池不得串快照、增量、移动或移除包。
- 合作叶子快照完成后，任何工具、背包、Coins或区域状态推送都不得以玩家自己的庭院OwnerId清空合作世界。
- 共享区域每片叶子只能由一人结算；幸运箱仍按收取者每区个人精确200倍数即时判定。
- 合作临时成长、合作背包和区域进度绝不覆盖主档成长；合作完成绝不提交单人通关时间榜。
- Coop临时覆盖只能归零可购买的Move Speed，不能归零或放大老档只读`LeafValue`等级。

## 修改影响

改PlaceId、TeleportData、组队UI、合作作用域、临时成长边界或结算字段时必须同步本页、manifest、Studio契约和发布验证。改叶子/便便/回收服务时必须分别回归单人Yard、Lobby和Coop三种作用域。

## 最小回归清单

- [ ] 四台世界牌独立显示权威人数、难度和15秒倒计时；房主Waiting时显示Team001，确认后隐藏，所有成员入队期间显示Team0EXC；房主转移、权限、目标人数不低于成员数、满员提前开始和失败恢复正确。
- [ ] 首名成员入队后不能走出；未满时外部玩家可进入；2/2、3/3、4/4后全服围墙关闭，已闯入的非成员移到外部；退出后本人可以离开且不会立即重入。
- [ ] 发布副本拒绝直接进入，合法四人只进入同一保留服务器且10秒到达窗口正确。
- [ ] Studio单人副本显示`Expected=1/Arrived=1/Playing`；Tool01实际拾取使Area01从450降至449并增加背包，Tool02～04和Automatic同样只在`Playing`生效。
- [ ] 四档总量、20000权威活动上限、100/0.1秒补充、共享进度及Area01–08自动门正确；不同成员按各自Low/Medium/High档最多新建3000/10000/20000个本地模型。
- [ ] 冷启动显示Area01正式钱币和Area02预览；等待并触发多次`StateSnapshot`后仍保留，错误Yard作用域或其他JobId的叶子包被忽略。
- [ ] 个人幸运箱、共享便便、清理/游玩/便便榜和单人通关榜隔离正确。
- [ ] 死亡保留本局成长；完成与中退后主档Coins/永久记录正确，临时成长和背包不泄漏；带旧`LeafValue`等级的玩家在副本中倍率仍生效且无法购买下一等级。
- [ ] 副本Player页三张背包卡与大厅同结构；金币工具和普通升级在0/1/2次永久Rebirth时按基础价1/1.5/2.25显示并扣费，普通升级/扩容只改临时状态，Developer Product和3K/5K权益购买后永久恢复。
- [ ] 完成自动回收、排行排序、保存失败重试和返回大厅正确。
- [ ] 等待、游玩、结算中和完成阶段均可打开Return确认；取消不传送，确认优先回原大厅，原服不可用时进入其他大厅，保存或最终传送失败可重试且无重复请求。
- [ ] 副本`fanhui.Lobby`全程可见并回到本Place出生点，合作状态、共享进度、背包和Coins保持不变，不打开跨Place确认框。

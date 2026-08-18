# 抛硬币

## 目标与边界

管理金币下注、服务端结果、待结算持久化、硬币世界动画、反馈和镜头暂停恢复。它不改变通用金币或工具接口。

## 玩家流程

玩家选择合法下注并确认，服务端锁定请求、校验余额并确定结果；客户端播放硬币动画和胜负反馈，结束后恢复镜头、工具与Automatic。异常离开时服务端持久化待结算状态，重进继续完成。

## 服务端权威

`CoinFlipService`拥有请求锁、下注校验和结算；`PlayerDataService`保存进度与Pending。客户端动画展示的朝向或文字不能决定胜负或金币结果。

## 客户端表现

`CoinFlipController`控制按钮、硬币模型、摄像机、连续操作反馈和清理，并通过正式接口暂停/恢复工具、范围和Automatic。

## 数据流

下注UI -> `RequestCoinFlip` -> 服务端余额与Pending事务 -> 权威结果 -> 客户端动画 -> 快照/返回值更新；中断时Pending写入存档，重进由服务端恢复结果。

## 配置

下注范围、动画与结算参数来自`CoinFlipConfig`。金币修改继续通过经济服务安全边界。

## Remote

`RequestCoinFlip`为客户端到服务端RemoteFunction，返回权威接受/拒绝与动画所需结果。重复请求和已有Pending必须被拒绝或复用，不得生成第二笔结算。

## 快照字段

`CoinFlipPending`。

## 永久字段与重置

`CoinFlipProgress`、`PendingCoinFlip`。离服保留未完成事务，死亡不重抽结果；Rebirth按当前保存策略保留抛硬币进度，完整清档清除。

## Studio契约

界面和声音见`StarterGui契约`与`SoundService契约`。若运行时硬币模型由客户端创建，不应要求Workspace预摆共享模型；目标Place表现待Studio核验。

## 依赖功能

依赖`economy-commerce`、`hud-camera`和`tools-upgrades`。

## 不变量

- 余额扣除、随机结果和奖励只在服务端发生一次。
- Pending创建后结果不可因重试、死亡或重进重新抽取。
- 所有动画退出路径都必须恢复镜头、工具、Automatic和范围显示。

## 修改影响

修改时序需检查服务端锁与客户端清理；修改下注或奖励需检查大数值sanitize、双倍金币是否适用、保存迁移和Pending恢复。

## 最小回归清单

- [ ] 胜、负、余额不足、重复点击和已有Pending路径正确。
- [ ] 动画中死亡、离服、关闭UI和目标销毁不产生二次结算。
- [ ] 结束后镜头、鼠标、工具、Automatic及HUD完全恢复。

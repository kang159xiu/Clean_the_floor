# 排行榜与分析

## 目标与边界

记录完整清理时间、在线时长、清理叶子数、制造便便数及产品漏斗事件，并把排行榜快照发送客户端。它只观察已成功业务事件，不参与业务裁决。

## 玩家流程

玩家正常游玩时统计自动累计；排行榜定时显示Top数据。正式新玩家按权威成功事件进入顺序漏斗，Studio只输出验证日志，发布服务器才写正式分析。

## 服务端权威

各排行榜服务维护普通DataStore与OrderedDataStore的提交、重试和缓存；`PlaytestMetricsService`只在真实服务端成功节点上报。用户名解析与DataStore工具集中处理限频和失败降级。

## 客户端表现

`TimeLeaderboardController`消费四类排行榜Remote并更新已存在的世界/UI列表。缺失模板或名字查询失败应保留安全占位，不影响玩法Bootstrap。

## 数据流

叶子/大便/区域/购买成功事件 -> 统计服务增加本地权威计数 -> 普通DataStore检查点 -> OrderedDataStore -> 周期缓存 -> 专用Snapshot Remote -> 客户端列表。漏斗事件按服务端步骤直接上报AnalyticsService。

## 配置

DataStore名称、刷新周期、Top数量和事件标签由各排行榜/指标服务常量维护。完整跑图阈值见验收手册，不在统计服务重复定义玩法规则。

## Remote

`ClearTimeLeaderboardSnapshot`、`PlaytimeLeaderboardSnapshot`、`CleanupLeaderboardSnapshot`、`PoopLeaderboardSnapshot`均为服务端到客户端只读快照。

## 快照字段

不占用主`StateSnapshot`顶层字段，四类榜单使用独立Remote。

## 永久字段与重置

主存档拥有`ClearSpeedrun`作为资格、累计时长、最好成绩缓存和待提交检查点。其他榜单使用独立普通/Ordered DataStore；普通Rebirth和完整清档不得擅自删除终身榜单历史。

## Studio契约

排行榜世界板和UI入口按`Area_01专用玩法对象`与`StarterGui契约`处理。当前目标Place未连接，具体板名和模板完整性标记待Studio核验。

## 依赖功能

依赖`persistence-reset`、`leaves-cleaning`和`poop-lobby`；区域、工具、商品、失物和教程向PlaytestMetrics提供成功事件。

## 不变量

- 只有权威成功事件计数，失败、重复和客户端动画不计。
- Lobby共享钱币和ResetCoin每次权威拾取计入清理榜一次，但不推进教程漏斗或正式区域进度指标。
- 普通DataStore成功但Ordered失败时必须保留待同步值。
- 排行榜或Analytics失败不能阻断核心玩法。
- 历史运行日志不因当前规则调整而重写。

## 修改影响

修改业务成功点时检查是否需要新增、移动或删除指标回调；修改DataStore需保留旧成绩、重试和名字缓存。新增榜单需独立Remote并登记manifest。

## 最小回归清单

- [ ] 叶子、便便、在线时长和清理时间各只累计一次。
- [ ] DataStore/Ordered/用户名查询失败后可重试且不阻断玩法。
- [ ] Studio不发送正式Analytics，发布服漏斗严格按权威顺序。

## 合作副本边界

合作拾取、在线时长和制造继续进入清理/游玩/便便榜；副本跳过`ClearTimeLeaderboardService`，Area08完成绝不提交单人通关时间。合作结算排行只存在当前Match快照，不新增永久榜。

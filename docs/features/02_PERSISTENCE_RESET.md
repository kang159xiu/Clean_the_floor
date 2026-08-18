# 存档、迁移、保存与清档

## 目标与边界

维护玩家主存档、会话状态、迁移、自动保存、退出保存、日期清档和管理员清档。具体功能字段的含义由各功能页负责。

## 玩家流程

加入时读取并清洗存档，失败时发布服不创建可被覆盖的假状态；游戏中变更进入防抖保存队列，菜单保存和离服保存写入最新状态。完整清档重建新档，Rebirth使用独立保留边界。

## 服务端权威

`PlayerDataService`是主状态和`CleanTheFloor_PlayerCollectibles_v1`的唯一拥有者，当前源码Schema为31。加载、迁移、快照、保存队列和状态修改都通过该服务；`AdminResetService`只调用正式清档入口。

## 客户端表现

`ExitSaveController`在Roblox菜单打开时请求权威保存并显示结果；客户端提示不代表DataStore已成功，必须使用Remote返回值。

## 数据流

DataStore -> 迁移与sanitize -> 会话state -> 各服务权威修改 -> `GetSnapshot` -> 防抖/自动/退出`UpdateAsync`。日期清档先经过`DataResetPolicy`，Rebirth走`ResetForRebirth`。

## 配置

日期清档来自`DataResetConfig`，管理员白名单来自`AdminTestConfig`。Schema常量只在`PlayerDataService`定义，manifest用于检测文档漂移。

## Remote

`RequestProgressSave`为客户端到服务端的有限频率同步保存；`ResetPlayerData`仅允许管理员测试账号调用。两者失败都必须返回明确结果，不得只改本地UI。

## 快照字段

`CanUseAdminReset`。其余快照字段按业务功能归属。

## 永久字段与重置

本功能拥有`SchemaVersion`、`DataResetDateKey`、`DataResetNoticeDateKey`。主存档另有36个顶层字段，全部在manifest按业务归属；完整清档和Rebirth的保留集合不得混用。

## Studio契约

保存提示使用`StarterGui契约`中的GameHUD通知节点；目标Place未连接时具体可见状态标记为待Studio核验。

## 依赖功能

依赖`platform-state`。所有带永久字段的功能反向依赖本功能。

## 不变量

- 加载失败不能以默认值覆盖线上存档。
- 最终保存必须等待旧队列结束并写最新revision。
- NaN、无穷、负货币和越界计数不得进入状态或DataStore。
- Schema提升必须保留明确迁移和回退边界。

## 修改影响

增加永久字段需同时更新新档、sanitize、保存payload、Rebirth保留策略、完整清档策略、manifest和所属功能页。修改快照需检查全部订阅者。

## 最小回归清单

- [ ] 新档、当前Schema旧档和至少一个旧Schema迁移正确。
- [ ] 自动保存、菜单保存和离服保存不会旧值覆盖新值。
- [ ] 普通Rebirth、SKIP Rebirth与完整清档保留字段符合各功能页。

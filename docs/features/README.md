# 功能地图

这里是当前玩法的首要阅读入口。源码负责真实数值和校验，功能页负责说明玩家行为、权威数据流、依赖关系和改动后的回归范围。

## 使用方法

1. 运行`scripts\feature-impact.cmd <源码路径、Remote、字段或Studio路径>`。
2. 阅读命中的主功能页和依赖页。
3. 修改行为或契约时更新功能页及`manifest.json`。
4. 完成后运行`scripts\verify-project.cmd`。

## 当前功能

| ID | 功能 | 状态 |
| --- | --- | --- |
| `platform-state` | [核心启动与状态同步](01_PLATFORM_STATE.md) | Active |
| `persistence-reset` | [存档、迁移、保存与清档](02_PERSISTENCE_RESET.md) | Active |
| `area-progression-rebirth` | [区域推进、门、空气墙与重生](03_AREA_PROGRESSION_REBIRTH.md) | Active |
| `yards-visiting` | [庭院访问、邀请与返回](04_YARDS_VISITING.md) | Active |
| `leaves-cleaning` | [叶子生成、Streaming显示与清扫](05_LEAVES_CLEANING.md) | Active |
| `tools-upgrades` | [工具、Automatic与升级](06_TOOLS_UPGRADES.md) | Active |
| `bags-capacity` | [背包、容量扩展与角色外观](07_BAGS_CAPACITY.md) | Active |
| `economy-commerce` | [经济、购买台、回收与商业化](08_ECONOMY_COMMERCE.md) | Active |
| `lost-items` | [失物、幸运箱、图鉴与揭晓](09_LOST_ITEMS.md) | Active |
| `poop-lobby` | [大便、Tool05与大厅牛](10_POOP_LOBBY.md) | Active |
| `tutorial-guidance` | [教程、引导线与可购买提醒](11_TUTORIAL_GUIDANCE.md) | Active |
| `hud-camera` | [HUD、模态界面、镜头与输入反馈](12_HUD_CAMERA.md) | Active |
| `coin-flip` | [抛硬币](13_COIN_FLIP.md) | Active |
| `community-friends` | [社区与好友奖励](14_COMMUNITY_FRIENDS.md) | Active |
| `leaderboards-analytics` | [排行榜与分析](15_LEADERBOARDS_ANALYTICS.md) | Active |

暂停、移除和只保留兼容数据的系统见[历史功能](archive/README.md)。

## 机器清单

`manifest.json`是工具读取的功能归属契约。它必须覆盖全部Luau文件、Remote、`StateSnapshot`顶层字段和主存档顶层字段。Markdown页面与清单冲突时先核对源码，再修复两者，不允许选择性忽略校验。

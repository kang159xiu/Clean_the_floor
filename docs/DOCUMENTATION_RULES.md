# 文档维护规则

## 事实归属

项目不再使用一份不断增长的总文档承载所有事实。每类事实只有一个当前归属：

| 事实 | 当前权威 |
| --- | --- |
| 数值、ID、算法、校验条件 | `src`中的Config或权威服务 |
| 玩家可见行为、数据流、依赖和修改影响 | 对应`docs/features`功能页 |
| Studio实例路径、名称、类型和可选性 | `docs/05_STUDIO_OBJECT_CONTRACT.md` |
| 跨功能架构和权威原则 | `docs/02_TECHNICAL_SPEC.md` |
| 完整跑图步骤 | `docs/09_CHECKPOINT_B_VALIDATION.md` |
| 已完成测试证据 | `docs/10_CHECKPOINT_B_RUN_LOG.md` |
| 历史实现 | `docs/archive`，不得作为当前依据 |

## 修改流程

1. 使用`scripts\feature-impact.cmd`按源码路径、Remote、快照字段、永久字段或Studio路径查找功能。
2. 阅读命中的功能页、依赖页以及精确Studio契约。
3. 修改前写明功能边界、不变量和最小回归项。
4. 行为或契约改变时同步功能页与`manifest.json`；纯内部重构且接口不变时只更新代码健康审计或测试证据。
5. 新增Luau文件必须登记唯一`primarySources`归属；共享影响写入其他功能的`relatedSources`。
6. 新增Remote、`StateSnapshot`顶层字段或主存档顶层字段时，必须登记唯一功能归属。
7. 运行`scripts\verify-project.cmd`。Studio验证不可用时明确记录待核验项，不得写成已通过。

## 功能页写法

- 描述稳定行为和边界，不复制可由Config直接读取的大段数值表。
- Remote写方向、调用者、权威校验与失败结果；不只列名称。
- 永久字段写清离服、死亡、普通Rebirth和完整清档的保留规则。
- Studio路径只列功能入口；精确后代树链接对象契约。
- 修改影响必须指出容易被连带破坏的功能。
- 最小回归清单应能在一次局部Play中完成；完整跑图仍由验收手册管理。

## 历史与状态

- `docs/08_STAGE_2_CURRENT_STATUS.md`只记录功能状态和当前验证缺口，不重复功能规则。
- `docs/10_CHECKPOINT_B_RUN_LOG.md`只追加，不重写历史结果。
- 暂停或移除功能移动到`docs/features/archive`，并记录替代功能和残留兼容数据。
- Schema版本只在机器清单和存档功能页展示，校验器会与源码常量比较。

# 阶段2当前状态

> 更新日期：2026-08-17。本文只记录状态和验证缺口，不重复功能规则。

## 当前基线

- 15个当前功能域已登记到[功能地图](features/README.md)。
- 当前活动区域为Area_01～Area_08；Area_09暂停，下水道和旧HUD商品轮播已移除。
- 主存档源码Schema、Luau文件、Remote、快照字段和永久字段数量由`scripts\verify-project.cmd`动态核验，不再手工复制到多份文档。
- Studio精确结构继续以[Studio对象契约](05_STUDIO_OBJECT_CONTRACT.md)为准。

## 功能状态

| 功能组 | 状态 | 当前验证重点 |
| --- | --- | --- |
| 核心启动、存档、区域与庭院 | 已实现 | 正确Place重进、双人隔离、Rebirth保留边界 |
| 叶子、工具、背包与经济 | 已实现 | 八区完整跑图、永久权益和Streaming晚加载 |
| 失物、便便与定时幸运箱 | 已实现 | 双客户端共享、揭晓失败恢复和定时器重进 |
| 教程、HUD、抛硬币与社区 | 已实现 | 新档漏斗、异常退出清理、正式Marketplace/API |
| 排行榜与分析 | 已实现，待发布数据证明 | OrderedDataStore补交与正式Analytics报表 |

## 验证状态

- 文档归属校验已覆盖全部源码、Remote、主快照字段和主存档payload字段。
- Rojo构建是每次变更的最低自动门槛。
- 当前仓库没有Luau单元测试框架；纯逻辑特征测试是下一阶段第一项工程工作。
- 目标Place未连接时，Studio对象、Play、双人和真实购买验证必须保持“待核验”，不能以其他Place代替。

## 下一阶段顺序

1. 为Config、格式化、迁移和快照组装增加特征测试。
2. 集中Remote声明，消除两端重复清单。
3. 保持外部行为不变，依次拆分PlayerData、HUD、Leaf和LostItem热点。
4. 按[验收手册](09_CHECKPOINT_B_VALIDATION.md)继续正确Place中的完整跑图，并只向[运行日志](10_CHECKPOINT_B_RUN_LOG.md)追加证据。

## 交接规则

未来任务先使用`scripts\feature-impact.cmd`定位功能，再阅读对应页面；行为、字段、Remote或Studio契约变化必须同步功能页和manifest。历史长文档已移动到`docs/archive/2026-08-17`，仅供追溯。

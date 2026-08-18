# Clean_the_floor - 项目执行入口

本文件是新任务接手项目时的第一入口。不要先通读历史长文档；先定位当前功能，再读取对应契约。

## 开始顺序

1. 阅读根目录`AGENTS.md`和[文档维护规则](docs/DOCUMENTATION_RULES.md)。
2. 打开[功能地图](docs/features/README.md)。
3. 运行`scripts\feature-impact.cmd <源码路径、Remote、字段或Studio路径>`定位影响范围。
4. 阅读命中的功能页、依赖页及相关[Studio对象契约](docs/05_STUDIO_OBJECT_CONTRACT.md)。
5. 修改后运行`scripts\verify-project.cmd`。

## 当前仓库

- Rojo配置：`default.project.json`
- 客户端入口：`src/client/init.client.luau`
- 服务端入口：`src/server/init.server.luau`
- 共享配置：`src/shared/Config`
- 当前状态：[阶段2当前状态](docs/08_STAGE_2_CURRENT_STATUS.md)
- 代码风险与拆分顺序：[代码健康审计](docs/CODE_HEALTH_AUDIT.md)

## 权威边界

- 正式Luau只修改本地`src`并通过Rojo同步，不在Studio脚本编辑器中维护另一份源码。
- 服务端是金币、背包、工具、区域、失物、便便、购买和存档的唯一权威。
- 精确Studio路径只写入`docs/05_STUDIO_OBJECT_CONTRACT.md`；功能页说明对象参与的数据流。
- 无法连接正确Place时只记录“待Studio核验”，不能用其他Place或旧文档代替。
- `docs/archive`只供历史追溯；当前规则以源码、功能页和Studio契约为准。

## 验证入口

- 自动文档与构建：`scripts\verify-project.cmd`
- 局部影响查询：`scripts\feature-impact.cmd <query...>`
- 完整Play步骤：[验收点B验证手册](docs/09_CHECKPOINT_B_VALIDATION.md)
- 已完成证据：[验收点B运行日志](docs/10_CHECKPOINT_B_RUN_LOG.md)

`README.md`保留历史乱码内容，不作为开发或交接依据。

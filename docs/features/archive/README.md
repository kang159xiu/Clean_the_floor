# 暂停与移除功能

本目录只记录历史边界，不描述当前玩法。当前功能以`docs/features/README.md`为准。

## Area_09

- 状态：暂停。
- 当前运行区域为`Area_01～Area_08`，`RegionConfig.PersistentAreaCount=9`只保留旧档兼容空间。
- Area_09不生成、不检测、不进入HUD、通关或重生资格；旧存档数据不得擅自删除。
- 替代：当前最终区域由`RegionConfig.FinalAreaId`定义为`Area_08`。

## 下水道系统

- 状态：已移除。
- 服务端和客户端不得等待或绑定`sewer/sewer01`，也不提供购买、吸叶或奖励入口。
- Studio残留对象不构成运行契约，精确历史说明只用于清理资产。

## HUD商品轮播

- 状态：已移除。
- `GameHUD.Commodity`不再作为Tool04、永久背包或其他Game Pass购买入口。
- 替代：世界购买台、区域双倍金币牌和各功能自己的原生购买流程。

## 区域完成属性奖励

- 状态：已停发。
- 区域完成继续推进开门和中央提示，但不再发放旧移动速度、叶价、幸运或新容量奖励。
- `LegacyAreaBagCapacityBonus`只用于兼容已迁移的历史容量。

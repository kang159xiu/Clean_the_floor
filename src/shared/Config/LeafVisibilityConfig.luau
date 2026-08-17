local LeafVisibilityConfig = {
	StreamingLoadDistance = 48,
	StreamingHideDistance = 64,
	StreamingCellSize = 8,
	CreateBudgetPerFrame = 16,
	RecycleBudgetPerFrame = 16,
	PoolTargetPerActiveType = 100,
	MaximumTotalPooledModels = 200,
	PoolPrewarmBatchSize = 1,
	PoolPrewarmInterval = 0.05,
	StreamingMinRadius = 64,
	StreamingTargetRadius = 160,
}

return table.freeze(LeafVisibilityConfig)

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
	Performance = {
		InitialTier = "Low",
		WarmupSeconds = 3,
		FocusResumeWarmupSeconds = 2,
		SampleWindowSeconds = 5,
		UpgradeWindowCount = 2,
		HighAverageFps = 52,
		HighP95FrameSeconds = 1 / 40,
		MediumAverageFps = 32,
		MediumP95FrameSeconds = 1 / 20,
		LeafModelLimits = {
			Low = 3000,
			Medium = 10000,
			High = 20000,
		},
	},
}

return table.freeze(LeafVisibilityConfig)

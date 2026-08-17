local SHARED_ACTION_ANIMATION_ID = "rbxassetid://121404663456576"
local DEFAULT_ACTION_REFERENCE_INTERVAL = 0.6

local tools = {
	[1] = {
		Index = 1,
		Id = "Tool01",
		Range = 1.5,
		ForwardOffset = 9,
		Price = 0,
		Name = "Hands",
		Behavior = "Collect",
		ModelPath = "CleaningTools.Tool01",
		Image = "rbxassetid://123526567512816",
		PickupCount = 1,
		PickupInterval = 0.6,--收取间隔
		MaxLevel = 1,
		UnlockedByDefault = true,
		AvailableForGameplay = true,
		UsesHandUpgrades = true,
		ActionAnimationId = SHARED_ACTION_ANIMATION_ID,
		ActionAnimationMode = "Batch",
		ActionReferenceInterval = DEFAULT_ACTION_REFERENCE_INTERVAL,
	},
	[2] = {
		Index = 2,
		Id = "Tool02",
		Name = "Broom",
		Price = 825,
		Behavior = "Broom",
		Range = 2,
		ForwardOffset = 6,
		ForceInterval = 0.15,
		InnerRangeRatio = 0.5,
		SweepCoverage = 0.5,
		SweepCoverageRingWidth = 1,
		SweepImpulseMultiplier = 0.4,
		BaseImpulseSpeed = 18,
		AutoCollectDistance = 3,
		RootStopDistance = 2,
		OuterForceMultiplier = 0.2,
		ModelPath = "CleaningTools.Tool02",
		Image = "rbxassetid://107158249191205",
		UnlockedByDefault = false,
		AvailableForGameplay = true,
		UsesHandUpgrades = false,
		ActionAnimationId = SHARED_ACTION_ANIMATION_ID,
		ActionAnimationMode = "WhileActive",
		ActionReferenceInterval = DEFAULT_ACTION_REFERENCE_INTERVAL,
	},
	[3] = {
		Index = 3,
		Id = "Tool03",
		Name = "Leaf Blower",
		Price = 12498,
		Behavior = "Blower",
		Range = 6,
		ForwardOffset = 6,
		InnerRangeRatio = 0.5,
		PickupCount = 2,
		PickupInterval = 0.2,
		ModelPath = "CleaningTools.Tool03",
		Image = "rbxassetid://136545046222882",
		UnlockedByDefault = false,
		AvailableForGameplay = true,
		UsesHandUpgrades = false,
		ActionAnimationId = SHARED_ACTION_ANIMATION_ID,
		ActionAnimationMode = "WhileActive",
		ActionReferenceInterval = DEFAULT_ACTION_REFERENCE_INTERVAL,
	},
	[4] = {
		Index = 4,
		Id = "Tool04",
		Name = "Dust Collector",
		Price = 0,
		PurchaseKind = "GamePass",
		GamePassId = 1932106073,
		BaseRobuxPrice = 199,
		Behavior = "Collect",
		Range = 20,
		ForwardOffset = 15,
		PickupCount = 20,
		PickupInterval = 0.1,
		ModelPath = "CleaningTools.Tool04",
		Image = "rbxassetid://87871569128588",
		UnlockedByDefault = false,
		AvailableForGameplay = true,
		UsesHandUpgrades = false,
		ActionAnimationId = "",
		ActionAnimationMode = "Disabled",
		ActionReferenceInterval = DEFAULT_ACTION_REFERENCE_INTERVAL,
	},
	[5] = {
		Index = 5,
		Id = "Tool05",
		Name = "Poop",
		Price = 0,
		Behavior = "MakeTrash",
		ModelPath = "CleaningTools.Tool05",
		Image = "rbxassetid://80652254893642",
		UnlockedByDefault = true,
		AvailableForGameplay = true,
		UsesHandUpgrades = false,
		ActionAnimationId = "rbxassetid://132805312644318",---dabian action
		ActionAnimationMode = "Single",
		ActionReferenceInterval = DEFAULT_ACTION_REFERENCE_INTERVAL,
		HopDelay = 0.2,
		HopVelocity = 25,
		SpawnDelay = 0.8,
		SpawnSoundDelay = 0.4,
		CreatorPickupDelay = 5,
	},
}

local byId = {}
for _, tool in tools do
	byId[tool.Id] = tool
end

local function isLeafCleaningTool(toolId)
	local tool = type(toolId) == "string" and byId[toolId] or nil
	return tool ~= nil
		and (tool.Behavior == "Collect" or tool.Behavior == "Broom" or tool.Behavior == "Blower")
end

local ToolConfig = {
	DefaultToolId = "Tool01",
	Order = { 1, 2, 3, 4, 5 },
	Tools = tools,
	ById = byId,
	IsLeafCleaningTool = isLeafCleaningTool,
}

return table.freeze(ToolConfig)

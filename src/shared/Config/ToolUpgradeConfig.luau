local RebirthConfig = require(script.Parent.RebirthConfig)

local INITIAL_MAX_LEVEL = 5
local UNLIMITED_PRICE_GROWTH = 1.5
local MAX_SAFE_LEVEL = 1_000_000

local tools = {
	Tool02 = {
		ToolId = "Tool02",
		Behavior = "Broom",
		ForceInterval = 0.15,
		InnerRangeRatio = 0.5,
		BaseImpulseSpeed = 18,
		SweepImpulseMultiplier = 0.4,
		SweepCoverageRingWidth = 1,
		RootStopDistance = 2,
		OuterForceMultiplier = 0.2,
		Order = { "Range", "ForwardOffset", "SweepStrength" },
		Attributes = {
			Range = {
				Id = "Range",
				DisplayName = "Broom Range",
				ValueField = "Range",
				IsCapped = false,
				ValuePerLevelAfterInitial = 1,
				Levels = {
					[0] = { Level = 0, Range = 3 },
					[1] = { Level = 1, Price = 1000, Range = 4 },
					[2] = { Level = 2, Price = 1688, Range = 5 },
					[3] = { Level = 3, Price = 2375, Range = 6 },
					[4] = { Level = 4, Price = 3063, Range = 7 },
					[5] = { Level = 5, Price = 3500, Range = 8 },
				},
			},
			ForwardOffset = {
				Id = "ForwardOffset",
				DisplayName = "Sweep Distance",
				ValueField = "ForwardOffset",
				IsCapped = false,
				ValuePerLevelAfterInitial = 1,
				Levels = {
					[0] = { Level = 0, ForwardOffset = 5 },
					[1] = { Level = 1, Price = 875, ForwardOffset = 6 },
					[2] = { Level = 2, Price = 1500, ForwardOffset = 7 },
					[3] = { Level = 3, Price = 2125, ForwardOffset = 8 },
					[4] = { Level = 4, Price = 2750, ForwardOffset = 9 },
					[5] = { Level = 5, Price = 3375, ForwardOffset = 12 },
				},
			},
			SweepStrength = {
				Id = "SweepStrength",
				DisplayName = "Sweep Coverage",
				ValueField = "SweepCoverage",
				IsCapped = false,
				ValuePerLevelAfterInitial = 0.1,
				Levels = {
					[0] = { Level = 0, SweepCoverage = 0.5 },
					[1] = { Level = 1, Price = 1250, SweepCoverage = 0.6 },
					[2] = { Level = 2, Price = 1625, SweepCoverage = 0.7 },
					[3] = { Level = 3, Price = 2000, SweepCoverage = 0.8 },
					[4] = { Level = 4, Price = 2375, SweepCoverage = 0.9 },
					[5] = { Level = 5, Price = 2750, SweepCoverage = 1.0 },
				},
			},
		},
	},

	Tool03 = {
		ToolId = "Tool03",
		Behavior = "Blower",
		InnerRangeRatio = 0.5,
		ForwardOffset = 6,
		PickupInterval = 0.2,
		Order = { "Range", "Power", "Accuracy" },
		Attributes = {
			Range = {
				Id = "Range",
				DisplayName = "Pickup Range",
				ValueField = "Range",
				IsCapped = false,
				ValuePerLevelAfterInitial = 1,
				Levels = {
					[0] = { Level = 0, Range = 6 },
					[1] = { Level = 1, Price = 7000, Range = 8 },
					[2] = { Level = 2, Price = 8750, Range = 9 },
					[3] = { Level = 3, Price = 10000, Range = 11 },
					[4] = { Level = 4, Price = 11500, Range = 13 },
					[5] = { Level = 5, Price = 12500, Range = 15 },
				},
			},
			Power = {
				Id = "Power",
				DisplayName = "Pickup Amount",
				ValueField = "PickupCount",
				IsCapped = true,
				MaxLevel = 9,
				Levels = {
					[0] = { Level = 0, PickupCount = 6 },
					[1] = { Level = 1, Price = 3750, PickupCount = 7 },
					[2] = { Level = 2, Price = 5000, PickupCount = 8 },
					[3] = { Level = 3, Price = 6000, PickupCount = 9 },
					[4] = { Level = 4, Price = 6750, PickupCount = 10 },
					[5] = { Level = 5, Price = 7250, PickupCount = 11 },
					[6] = { Level = 6, Price = 10875, PickupCount = 12 },
					[7] = { Level = 7, Price = 16313, PickupCount = 13 },
					[8] = { Level = 8, Price = 24469, PickupCount = 14 },
					[9] = { Level = 9, Price = 36703, PickupCount = 15 },
				},
			},
			Accuracy = {
				Id = "Accuracy",
				DisplayName = "Pickup Distance",
				ValueField = "ForwardOffset",
				IsCapped = true,
				MaxLevel = 9,
				Levels = {
					[0] = { Level = 0, ForwardOffset = 6 },
					[1] = { Level = 1, Price = 300, ForwardOffset = 7 },
					[2] = { Level = 2, Price = 1500, ForwardOffset = 8 },
					[3] = { Level = 3, Price = 7500, ForwardOffset = 9 },
					[4] = { Level = 4, Price = 11250, ForwardOffset = 10 },
					[5] = { Level = 5, Price = 16875, ForwardOffset = 11 },
					[6] = { Level = 6, Price = 25313, ForwardOffset = 12 },
					[7] = { Level = 7, Price = 37970, ForwardOffset = 13 },
					[8] = { Level = 8, Price = 56955, ForwardOffset = 14 },
					[9] = { Level = 9, Price = 85433, ForwardOffset = 15 },
				},
			},
		},
	},
}

local function finiteNumber(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function getAttribute(toolId, attributeId)
	local tool = tools[toolId]
	return tool and tool.Attributes[attributeId] or nil
end

local function normalizeLevel(toolId, attributeId, level)
	local numericLevel = tonumber(level)
	if not finiteNumber(numericLevel) then
		numericLevel = 0
	end
	local normalized = math.clamp(math.floor(numericLevel), 0, MAX_SAFE_LEVEL)
	local attribute = getAttribute(toolId, attributeId)
	if attribute and attribute.IsCapped then
		return math.min(normalized, attribute.MaxLevel)
	end
	return normalized
end

local function isCapped(toolId, attributeId)
	local attribute = getAttribute(toolId, attributeId)
	return attribute ~= nil and attribute.IsCapped == true
end

local function isMaxLevel(toolId, attributeId, level)
	local attribute = getAttribute(toolId, attributeId)
	return attribute ~= nil
		and attribute.IsCapped == true
		and normalizeLevel(toolId, attributeId, level) >= attribute.MaxLevel
end

local function getLevelConfig(toolId, attributeId, level)
	local attribute = getAttribute(toolId, attributeId)
	if not attribute then
		return nil
	end
	local normalized = normalizeLevel(toolId, attributeId, level)
	local configured = attribute.Levels[normalized]
	if configured then
		return configured
	end
	if normalized <= INITIAL_MAX_LEVEL then
		return nil
	end
	if attribute.IsCapped and attribute.GenerateAfterInitial ~= true then
		return nil
	end

	local initialConfig = attribute.Levels[INITIAL_MAX_LEVEL]
	local extraLevels = normalized - INITIAL_MAX_LEVEL
	local priceGrowth = tonumber(attribute.PriceGrowthAfterInitial) or UNLIMITED_PRICE_GROWTH
	local rawPrice = initialConfig.Price * (priceGrowth ^ extraLevels)
	local rawValue = initialConfig[attribute.ValueField] + attribute.ValuePerLevelAfterInitial * extraLevels
	if finiteNumber(attribute.MaximumValue) then
		rawValue = math.min(rawValue, attribute.MaximumValue)
	end
	if not finiteNumber(rawValue) then
		return nil
	end
	return {
		Level = normalized,
		Price = if finiteNumber(rawPrice) then math.floor(rawPrice + 0.5) else nil,
		[attribute.ValueField] = rawValue,
	}
end

local function getNextPrice(toolId, attributeId, currentLevel, rebirthCount)
	if isMaxLevel(toolId, attributeId, currentLevel) then
		return nil
	end
	local normalized = normalizeLevel(toolId, attributeId, currentLevel)
	local levelConfig = getLevelConfig(toolId, attributeId, normalized + 1)
	if not levelConfig or not finiteNumber(levelConfig.Price) or levelConfig.Price <= 0 then
		return nil
	end
	local price = RebirthConfig.GetScaledToolAndUpgradePrice(levelConfig.Price, rebirthCount)
	return finiteNumber(price) and price or nil
end

local function makeDefaultLevels()
	local result = {}
	for toolId, tool in tools do
		local levels = {}
		for _, attributeId in tool.Order do
			levels[attributeId] = 0
		end
		result[toolId] = levels
	end
	return result
end

local function getEffectiveAttributes(toolId, rawLevels)
	local tool = tools[toolId]
	if not tool then
		return nil
	end
	local levels = type(rawLevels) == "table" and rawLevels or {}
	local result = {
		InnerRangeRatio = tool.InnerRangeRatio,
		ForwardOffset = tool.ForwardOffset,
		BaseImpulseSpeed = tool.BaseImpulseSpeed,
		SweepImpulseMultiplier = tool.SweepImpulseMultiplier,
		SweepCoverageRingWidth = tool.SweepCoverageRingWidth,
		RootStopDistance = tool.RootStopDistance,
		OuterForceMultiplier = tool.OuterForceMultiplier,
		ForceInterval = tool.ForceInterval,
		PickupInterval = tool.PickupInterval,
		MaximumSpreadAngle = tool.MaximumSpreadAngle,
	}
	for _, attributeId in tool.Order do
		local attribute = tool.Attributes[attributeId]
		local levelConfig = getLevelConfig(toolId, attributeId, levels[attributeId])
		result[attribute.ValueField] = levelConfig[attribute.ValueField]
	end
	return result
end

for _, tool in tools do
	for _, attributeId in tool.Order do
		local attribute = tool.Attributes[attributeId]
		for _, levelConfig in attribute.Levels do
			table.freeze(levelConfig)
		end
		table.freeze(attribute.Levels)
		table.freeze(attribute)
	end
	table.freeze(tool.Order)
	table.freeze(tool.Attributes)
	table.freeze(tool)
end
table.freeze(tools)

local ToolUpgradeConfig = {
	InitialMaxLevel = INITIAL_MAX_LEVEL,
	UnlimitedPriceGrowth = UNLIMITED_PRICE_GROWTH,
	Tools = tools,
	GetAttribute = getAttribute,
	NormalizeLevel = normalizeLevel,
	IsCapped = isCapped,
	IsMaxLevel = isMaxLevel,
	GetLevelConfig = getLevelConfig,
	GetNextPrice = getNextPrice,
	MakeDefaultLevels = makeDefaultLevels,
	GetEffectiveAttributes = getEffectiveAttributes,
}

return table.freeze(ToolUpgradeConfig)

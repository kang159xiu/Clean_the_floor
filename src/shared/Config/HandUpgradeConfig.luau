local RebirthConfig = require(script.Parent.RebirthConfig)

local INITIAL_MAX_LEVEL = 5
local UNLIMITED_PRICE_GROWTH = 1.5
local MAX_SAFE_LEVEL = 1_000_000

local order = { "Range", "Speed", "Amount" }

local attributes = {
	Range = {
		Id = "Range",
		DisplayName = "Pickup Range",
		ValueField = "Range",
		IsCapped = false,
		ValuePerLevelAfterInitial = 0.5,
		Levels = {
			[0] = { Level = 0, Range = 1.5 },
			[1] = { Level = 1, Price = 100, Range = 2 },
			[2] = { Level = 2, Price = 200, Range = 2.5 },
			[3] = { Level = 3, Price = 450, Range = 3 },
			[4] = { Level = 4, Price = 750, Range = 3.5 },
			[5] = { Level = 5, Price = 1500, Range = 4 },
		},
	},
	Speed = {
		Id = "Speed",
		DisplayName = "Pickup Speed",
		ValueField = "PickupInterval",
		IsCapped = true,
		MaxLevel = INITIAL_MAX_LEVEL,
		Levels = {
			[0] = { Level = 0, PickupInterval = 0.5 },
			[1] = { Level = 1, Price = 20, PickupInterval = 0.4 },
			[2] = { Level = 2, Price = 85, PickupInterval = 0.3 },
			[3] = { Level = 3, Price = 448, PickupInterval = 0.2 },
			[4] = { Level = 4, Price = 2350, PickupInterval = 0.15 },
			[5] = { Level = 5, Price = 4500, PickupInterval = 0.1 },
		},
	},
	Amount = {
		Id = "Amount",
		DisplayName = "Pickup Amount",
		ValueField = "PickupCount",
		IsCapped = false,
		ValuePerLevelAfterInitial = 1,
		Levels = {
			[0] = { Level = 0, PickupCount = 1 },
			[1] = { Level = 1, Price = 10, PickupCount = 2 },
			[2] = { Level = 2, Price = 50, PickupCount = 3 },
			[3] = { Level = 3, Price = 875, PickupCount = 4 },
			[4] = { Level = 4, Price = 1438, PickupCount = 5 },
			[5] = { Level = 5, Price = 5680, PickupCount = 6 },
		},
	},
}

local function finiteNumber(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function normalizeLevel(attributeId, level)
	local numericLevel = tonumber(level)
	if not finiteNumber(numericLevel) then
		numericLevel = 0
	end
	local normalized = math.clamp(math.floor(numericLevel), 0, MAX_SAFE_LEVEL)
	local attribute = attributes[attributeId]
	if attribute and attribute.IsCapped then
		return math.min(normalized, attribute.MaxLevel)
	end
	return normalized
end

local function isCapped(attributeId)
	local attribute = attributes[attributeId]
	return attribute ~= nil and attribute.IsCapped == true
end

local function isMaxLevel(attributeId, level)
	local attribute = attributes[attributeId]
	return attribute ~= nil
		and attribute.IsCapped == true
		and normalizeLevel(attributeId, level) >= attribute.MaxLevel
end

local function getLevelConfig(attributeId, level)
	local attribute = attributes[attributeId]
	if not attribute then
		return nil
	end

	local normalized = normalizeLevel(attributeId, level)
	local configured = attribute.Levels[normalized]
	if configured then
		return configured
	end
	if attribute.IsCapped or normalized <= INITIAL_MAX_LEVEL then
		return nil
	end

	local initialConfig = attribute.Levels[INITIAL_MAX_LEVEL]
	local extraLevels = normalized - INITIAL_MAX_LEVEL
	local rawPrice = initialConfig.Price * (UNLIMITED_PRICE_GROWTH ^ extraLevels)
	local rawValue = initialConfig[attribute.ValueField] + attribute.ValuePerLevelAfterInitial * extraLevels
	if not finiteNumber(rawValue) then
		return nil
	end
	return {
		Level = normalized,
		Price = if finiteNumber(rawPrice) then math.floor(rawPrice + 0.5) else nil,
		[attribute.ValueField] = rawValue,
	}
end

local function getNextPrice(attributeId, currentLevel, rebirthCount)
	if isMaxLevel(attributeId, currentLevel) then
		return nil
	end
	local levelConfig = getLevelConfig(attributeId, normalizeLevel(attributeId, currentLevel) + 1)
	if not levelConfig or not finiteNumber(levelConfig.Price) or levelConfig.Price <= 0 then
		return nil
	end
	local price = RebirthConfig.GetScaledPrice(levelConfig.Price, rebirthCount)
	return finiteNumber(price) and price or nil
end

local function getEffectiveAttributes(levels)
	local source = type(levels) == "table" and levels or {}
	return {
		Range = getLevelConfig("Range", source.Range).Range,
		PickupInterval = getLevelConfig("Speed", source.Speed).PickupInterval,
		PickupCount = getLevelConfig("Amount", source.Amount).PickupCount,
	}
end

for _, attributeId in order do
	local attribute = attributes[attributeId]
	for level = 0, INITIAL_MAX_LEVEL do
		table.freeze(attribute.Levels[level])
	end
	table.freeze(attribute.Levels)
	table.freeze(attribute)
end
table.freeze(order)
table.freeze(attributes)

local HandUpgradeConfig = {
	MaxLevel = INITIAL_MAX_LEVEL,
	InitialMaxLevel = INITIAL_MAX_LEVEL,
	UnlimitedPriceGrowth = UNLIMITED_PRICE_GROWTH,
	Order = order,
	Attributes = attributes,
	NormalizeLevel = normalizeLevel,
	IsCapped = isCapped,
	IsMaxLevel = isMaxLevel,
	GetLevelConfig = getLevelConfig,
	GetNextPrice = getNextPrice,
	GetEffectiveAttributes = getEffectiveAttributes,
}

return table.freeze(HandUpgradeConfig)

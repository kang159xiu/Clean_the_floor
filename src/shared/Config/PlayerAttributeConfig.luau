local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)

local MAX_CURRENCY_VALUE = 1e100
local MAX_SAFE_LEVEL = 1_000_000

local order = { "MoveSpeed" }
local persistedOrder = { "MoveSpeed", "LeafValue" }

local attributes = {
	MoveSpeed = {
		Id = "MoveSpeed",
		DisplayName = "Move Speed",
		BasePrice = 500,
		MaxLevel = 24,
		ValuePerLevel = 1,
	},
}

local legacyAttributes = {
	LeafValue = {
		Id = "LeafValue",
		ValuePerLevel = 0.5,
	},
}

local persistedAttributes = {
	MoveSpeed = attributes.MoveSpeed,
	LeafValue = legacyAttributes.LeafValue,
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
	local attribute = persistedAttributes[attributeId]
	if attribute and attribute.MaxLevel then
		normalized = math.min(normalized, attribute.MaxLevel)
	end
	return normalized
end

local function isConfiguredMaxLevel(attributeId, level)
	local attribute = attributes[attributeId]
	return attribute ~= nil
		and attribute.MaxLevel ~= nil
		and normalizeLevel(attributeId, level) >= attribute.MaxLevel
end

local function getUpgradePrice(attributeId, currentLevel, rebirthCount)
	local attribute = attributes[attributeId]
	if not attribute or isConfiguredMaxLevel(attributeId, currentLevel) then
		return nil
	end
	local targetLevel = normalizeLevel(attributeId, currentLevel) + 1
	local price = attribute.BasePrice
	for factor = 2, targetLevel do
		if price > MAX_CURRENCY_VALUE / factor then
			return nil
		end
		price *= factor
	end
	if not finiteNumber(price) or price > MAX_CURRENCY_VALUE then
		return nil
	end
	local scaledPrice = RebirthConfig.GetScaledToolAndUpgradePrice(price, rebirthCount)
	if not finiteNumber(scaledPrice) or scaledPrice > MAX_CURRENCY_VALUE then
		return nil
	end
	return scaledPrice
end

local function makeDefaultLevels()
	return {
		MoveSpeed = 0,
		LeafValue = 0,
	}
end

for _, attributeId in order do
	table.freeze(attributes[attributeId])
end
for _, attributeId in persistedOrder do
	local legacyAttribute = legacyAttributes[attributeId]
	if legacyAttribute then
		table.freeze(legacyAttribute)
	end
end
table.freeze(attributes)
table.freeze(legacyAttributes)
table.freeze(order)
table.freeze(persistedOrder)

local PlayerAttributeConfig = {
	MaximumCurrencyValue = MAX_CURRENCY_VALUE,
	MaximumWalkSpeed = 40,
	Order = order,
	PersistedOrder = persistedOrder,
	Attributes = attributes,
	LegacyAttributes = legacyAttributes,
	NormalizeLevel = normalizeLevel,
	IsConfiguredMaxLevel = isConfiguredMaxLevel,
	GetUpgradePrice = getUpgradePrice,
	MakeDefaultLevels = makeDefaultLevels,
}

return table.freeze(PlayerAttributeConfig)

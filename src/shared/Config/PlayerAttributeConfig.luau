local MAX_CURRENCY_VALUE = 1e100
local MAX_SAFE_LEVEL = 1_000_000

local order = { "MoveSpeed", "LeafValue" }

local attributes = {
	MoveSpeed = {
		Id = "MoveSpeed",
		DisplayName = "Move Speed",
		BasePrice = 500,
		MaxLevel = 24,
		ValuePerLevel = 1,
	},
	LeafValue = {
		Id = "LeafValue",
		DisplayName = "Value Multiplier",
		BasePrice = 500,
		ValuePerLevel = 0.5,
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

local function getUpgradePrice(attributeId, currentLevel)
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
	return math.floor(price + 0.5)
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
table.freeze(attributes)
table.freeze(order)

local PlayerAttributeConfig = {
	MaximumCurrencyValue = MAX_CURRENCY_VALUE,
	MaximumWalkSpeed = 40,
	Order = order,
	Attributes = attributes,
	NormalizeLevel = normalizeLevel,
	IsConfiguredMaxLevel = isConfiguredMaxLevel,
	GetUpgradePrice = getUpgradePrice,
	MakeDefaultLevels = makeDefaultLevels,
}

return table.freeze(PlayerAttributeConfig)

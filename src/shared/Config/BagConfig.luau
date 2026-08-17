local PlayerAttributeConfig = require(script.Parent.PlayerAttributeConfig)

local EXPANSION_BASE_CAPACITY_INCREMENT = 100
local EXPANSION_CAPACITY_INCREMENT_PER_LEVEL = 50
local EXPANSION_PRICE_MULTIPLIER = 1.5

local BagConfig = {
	DefaultLevel = 1,
	MaxLevel = 8,
	Order = { 1, 2, 3, 4, 5, 6, 7, 8 },
	PermanentOrder = { "bag09", "bag010", "bag011" },
	PermanentPriority = { "bag011", "bag010", "bag09" },
	PermanentBags = {
		bag09 = {
			Id = "bag09",
			Enabled = true,
			Name = "Angel Pack",
			Capacity = 3000,
			Behavior = "Capacity",
			PurchaseKind = "GamePass",
			GamePassId = 1935075451,
			BaseRobuxPrice = 49,
			StationName = "3Kback",
			Image = "rbxassetid://129623708227579",
			ModelName = "bag09",
			ModelPath = "bag.bag09",
		},
		bag010 = {
			Id = "bag010",
			Enabled = true,
			Name = "Space Pack",
			Capacity = 5000,
			Behavior = "Capacity",
			PurchaseKind = "GamePass",
			GamePassId = 1933167762,
			BaseRobuxPrice = 59,
			StationName = "5Kback",
			Image = "rbxassetid://86536031811394",
			ModelName = "bag010",
			ModelPath = "bag.bag010",
		},
		bag011 = {
			Id = "bag011",
			Enabled = false,
			Name = "Lv.11",
			Behavior = "InstantRecycle",
			PurchaseKind = "GamePass",
			GamePassId = 1930772443,
			BaseRobuxPrice = 299,
			StationName = "Trashback",
			Image = "rbxassetid://114584597270599",
			ModelName = "bag011",
			ModelPath = "bag.bag011",
		},
	},
	Levels = {
		[1] = {
			Id = 1,
			Capacity = 15,--基础容量
			Price = 0,
			Name = "Trash Pack",
			Image = "rbxassetid://140300050110603",
			ModelName = "bag01",
			ModelPath = "bag.bag01",
		},
		[2] = {
			Id = 2,
			Capacity = 100,
			Price = 45,
			Name = "Chick Pack",
			Image = "rbxassetid://74230370972124",
			ModelName = "bag02",
			ModelPath = "bag.bag02",
		},
		[3] = {
			Id = 3,
			Capacity = 200,
			Price = 150,
			Name = "Cow Pack",
			Image = "rbxassetid://132230328905896",
			ModelName = "bag03",
			ModelPath = "bag.bag03",
		},
		[4] = {
			Id = 4,
			Capacity = 300,
			Price = 400,
			Name = "Rover Pack",
			Image = "rbxassetid://80998520242818",
			ModelName = "bag04",
			ModelPath = "bag.bag04",
		},
		[5] = {
			Id = 5,
			Capacity = 400,
			Price = 1500,
			Name = "Paw Pack",
			Image = "rbxassetid://85327064309891",
			ModelName = "bag05",
			ModelPath = "bag.bag05",
		},
		[6] = {
			Id = 6,
			Capacity = 500,
			Price = 3000,
			Name = "Super Pack",
			Image = "rbxassetid://132810015165866",
			ModelName = "bag06",
			ModelPath = "bag.bag06",
		},
		[7] = {
			Id = 7,
			Capacity = 600,
			Price = 6000,
			Name = "Fruit Pack",
			Image = "rbxassetid://83760676404079",
			ModelName = "bag07",
			ModelPath = "bag.bag07",
		},
		[8] = {
			Id = 8,
			Capacity = 700,
			Price = 15000,
			Name = "Blackwing Pack",
			Image = "rbxassetid://87841535719947",
			ModelName = "bag08",
			ModelPath = "bag.bag08",
		},
	},
}

local expansionPrices = {}
local previousExpansionPrice = BagConfig.Levels[BagConfig.MaxLevel].Price
while previousExpansionPrice <= PlayerAttributeConfig.MaximumCurrencyValue / EXPANSION_PRICE_MULTIPLIER do
	local nextPrice = math.floor(previousExpansionPrice * EXPANSION_PRICE_MULTIPLIER + 0.5)
	if nextPrice <= previousExpansionPrice then
		break
	end
	table.insert(expansionPrices, nextPrice)
	previousExpansionPrice = nextPrice
end
table.freeze(expansionPrices)

BagConfig.Expansion = table.freeze({
	BaseCapacityIncrement = EXPANSION_BASE_CAPACITY_INCREMENT,
	CapacityIncrementPerLevel = EXPANSION_CAPACITY_INCREMENT_PER_LEVEL,
	PriceMultiplier = EXPANSION_PRICE_MULTIPLIER,
	MaxLevel = #expansionPrices,
	Prices = expansionPrices,
})

function BagConfig.NormalizeExpansionLevel(value)
	local numericLevel = tonumber(value)
	if not numericLevel or numericLevel ~= numericLevel then
		return 0
	end
	return math.clamp(math.floor(numericLevel), 0, BagConfig.Expansion.MaxLevel)
end

function BagConfig.GetExpansionCapacityBonus(level)
	local normalizedLevel = BagConfig.NormalizeExpansionLevel(level)
	return math.floor(
		normalizedLevel
			* (
				2 * BagConfig.Expansion.BaseCapacityIncrement
					+ (normalizedLevel - 1) * BagConfig.Expansion.CapacityIncrementPerLevel
			)
			/ 2
		+ 0.5
	)
end

function BagConfig.GetNextExpansionCapacityIncrement(currentLevel)
	local normalizedLevel = BagConfig.NormalizeExpansionLevel(currentLevel)
	if not BagConfig.Expansion.Prices[normalizedLevel + 1] then
		return nil
	end
	return BagConfig.Expansion.BaseCapacityIncrement
		+ normalizedLevel * BagConfig.Expansion.CapacityIncrementPerLevel
end

function BagConfig.GetNextExpansionPrice(currentLevel)
	local normalizedLevel = BagConfig.NormalizeExpansionLevel(currentLevel)
	return BagConfig.Expansion.Prices[normalizedLevel + 1]
end

function BagConfig.IsPermanentBagEnabled(bagId)
	local config = BagConfig.PermanentBags[bagId]
	return config ~= nil and config.Enabled == true
end

function BagConfig.IsCapacityPermanentBag(bagId)
	local config = BagConfig.PermanentBags[bagId]
	return BagConfig.IsPermanentBagEnabled(bagId)
		and config.Behavior == "Capacity"
		and type(config.Capacity) == "number"
end

function BagConfig.CanPurchaseExpansion(bagLevel, permanentBagId)
	local normalizedBagLevel = math.clamp(
		math.floor(tonumber(bagLevel) or BagConfig.DefaultLevel),
		BagConfig.DefaultLevel,
		BagConfig.MaxLevel
	)
	return normalizedBagLevel >= BagConfig.MaxLevel
		or BagConfig.IsCapacityPermanentBag(permanentBagId)
end

return table.freeze(BagConfig)

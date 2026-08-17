local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local PLACEHOLDER_IMAGE = "rbxassetid://94046911309238"
local MAX_REDEEM_COIN_VALUE = 1e100
local LOST_ITEM_IMAGES = table.freeze({
	LostItem01 = "rbxassetid://125717598222878", 
	LostItem02 = "rbxassetid://115241977154084", 
	LostItem03 = "rbxassetid://96805265063080", 
	LostItem04 = "rbxassetid://124401251263190",
	LostItem05 = "rbxassetid://139763856467112",
	LostItem06 = "rbxassetid://106935371802503",
	LostItem07 = "rbxassetid://129292303891274",
	LostItem08 = "rbxassetid://117187143742801",
	LostItem09 = "rbxassetid://123033023570745",
	LostItem10 = "rbxassetid://74254797928068",
	LostItem11 = "rbxassetid://104407338684427",
	LostItem12 = "rbxassetid://99003514894775",
	LostItem13 = "rbxassetid://129382813578298",
	LostItem14 = "rbxassetid://107661092602389",
	LostItem15 = "rbxassetid://100346199569877",
	LostItem16 = "rbxassetid://137292787986870",
	LostItem17 = "rbxassetid://107253059979318",
	LostItem18 = "rbxassetid://118425405634667",
	LostItem19 = "rbxassetid://85420373939907",
	LostItem20 = "rbxassetid://76002541624634",
	LostItem21 = "rbxassetid://129806301575209",
	LostItem22 = "rbxassetid://102132525825621",
	LostItem23 = "rbxassetid://102754867590587",
	LostItem24 = "rbxassetid://130290254583349",
	LostItem25 = "rbxassetid://77619854204421", 
})
local CODEX_COIN_VALUE_MULTIPLIER = 10
local codexMilestones = table.freeze({ 5, 10, 20, 40, 80, 100 })
local revealAnimation = table.freeze({
	-- Existing poop/world reveal timing. PoopController shares this config table,
	-- so these fields must remain independent from the lucky-box timing below.
	DecoyCount = 12,
	StartScale = 0.05,
	FirstDecoyGrowDuration = 0.06,
	LastDecoyGrowDuration = 0.22,
	FirstDecoyShrinkDuration = 0.04,
	LastDecoyShrinkDuration = 0.14,
	SlowdownExponent = 1.5,
	FinalGrowDuration = 0.25,

	-- Lucky-box world reveal timing and presentation.
	FinalHoldDuration = 2.5,
	FlyToPlayerDuration = 0.45,
	FlyArcHeight = 1.5,
	FlyShrinkDistance = 2,
	FlyEndScale = 0.15,
	ValueFadeDuration = 0.15,
	MaximumDisplaySize = 2.5,
	NearbyViewerRadius = 50,
})
local minimumSpawnCount = 3
local maximumSpawnCount = 6
local timedLuckyBox = table.freeze({
	FirstDelaySeconds = 180,
	RecurringDelaySeconds = 300,
	RetryDelaySeconds = 1,
	TierWeights = table.freeze({
		[4] = 80,
		[5] = 20,
	}),
	RewardKinds = table.freeze({
		First = "First",
		Recurring = "Recurring",
	}),
	SpawnSources = table.freeze({
		First = "TimedFirstHighTierReward",
		Recurring = "TimedRecurringHighTierReward",
	}),
})
local spawnModes = table.freeze({
	Immediate = "Immediate",
	Progressive = "Progressive",
})

local rarityDefinitions = {
	Common = {
		Id = "Common",
		DisplayName = "Common",
		Color = Color3.fromRGB(135, 255, 37),
		CoinValue = 200,
		Description = "A common lost item found among the leaves.",
	},
	Uncommon = {
		Id = "Uncommon",
		DisplayName = "Uncommon",
		Color = Color3.fromRGB(80, 180, 255),
		CoinValue = 500,
		Description = "An uncommon lost item hidden in thick leaves.",
	},
	Rare = {
		Id = "Rare",
		DisplayName = "Rare",
		Color = Color3.fromRGB(190, 100, 255),
		CoinValue = 1000,
		Description = "A rare lost item that is hard to find while cleaning.",
	},
	Legendary = {
		Id = "Legendary",
		DisplayName = "Legendary",
		Color = Color3.fromRGB(255, 190, 45),
		CoinValue = 2500,
		Description = "An extremely rare legendary lost item.",
	},
	Mythic = {
		Id = "Mythic",
		DisplayName = "Mythic",
		Color = Color3.fromRGB(255, 70, 180),
		CoinValue = 5000,
		Description = "A mythic lost item found inside the rarest lucky boxes.",
	},
}

local rarityOrder = { "Common", "Uncommon", "Rare", "Legendary", "Mythic" }

local function getRarityId(index)
	return rarityOrder[math.clamp(math.ceil(index / 5), 1, #rarityOrder)]
end

local order = {}
local types = {}
local idsByRarity = {
	Common = {},
	Uncommon = {},
	Rare = {},
	Legendary = {},
	Mythic = {},
}

for index = 1, 25 do
	local lostItemId = string.format("LostItem%02d", index)
	local rarityId = getRarityId(index)
	local rarity = rarityDefinitions[rarityId]
	local config = table.freeze({
		Id = lostItemId,
		DisplayName = string.format("Lost Item %02d", index),
		RarityId = rarityId,
		Difficulty = rarity.DisplayName,
		DifficultyColor = rarity.Color,
		Description = rarity.Description,
		Image = if LOST_ITEM_IMAGES[lostItemId] ~= "" then LOST_ITEM_IMAGES[lostItemId] else PLACEHOLDER_IMAGE,
		CoinValue = rarity.CoinValue,
		LuckyTier = math.ceil(index / 5),
		Grip = CFrame.identity,
	})
	types[lostItemId] = config
	table.insert(order, lostItemId)
	table.insert(idsByRarity[rarityId], lostItemId)
end

local poopImage = "rbxassetid://80652254893642"
local poopTiers = {}
local poopItemIds = {}
local poopTierById = {}
local poopTotalWeight = 0
for level, definition in {
	{ Id = "LostItem095", CoinValue = 10, Weight = 50 },
	{ Id = "LostItem096", CoinValue = 100, Weight = 30 },
	{ Id = "LostItem097", CoinValue = 300, Weight = 20 },
	{ Id = "LostItem098", CoinValue = 1000, Weight = 10 },
	{ Id = "LostItem099", CoinValue = 2000, Weight = 5 },
} do
	local tier = table.freeze({
		Id = definition.Id,
		Level = level,
		CoinValue = definition.CoinValue,
		Weight = definition.Weight,
	})
	table.insert(poopTiers, tier)
	table.insert(poopItemIds, tier.Id)
	poopTierById[tier.Id] = tier
	poopTotalWeight += tier.Weight
	types[tier.Id] = table.freeze({
		Id = tier.Id,
		DisplayName = if tier.Id == "LostItem099" then "Rainbow Poop" else "Poop",
		RarityId = "Special",
		Difficulty = "Special",
		DifficultyColor = Color3.fromRGB(255, 255, 255),
		Description = "Poop left by another player.",
		Image = poopImage,
		CoinValue = tier.CoinValue,
		Grip = CFrame.identity,
		PoopOnly = true,
		PoopLevel = tier.Level,
		SpawnWeight = tier.Weight,
	})
end
poopTiers = table.freeze(poopTiers)
poopItemIds = table.freeze(poopItemIds)
poopTierById = table.freeze(poopTierById)
local templateOrder = table.clone(order)
for _, lostItemId in poopItemIds do
	table.insert(templateOrder, lostItemId)
end

local function getCodexCoinReward(milestone)
	local normalizedMilestone = math.max(0, math.floor(tonumber(milestone) or 0))
	return normalizedMilestone * CODEX_COIN_VALUE_MULTIPLIER
end

local function usesLeafValueMultiplier(lostItemId)
	local config = type(lostItemId) == "string" and types[lostItemId] or nil
	return config ~= nil and config.PoopOnly ~= true
end

local function isPoopItemId(lostItemId)
	return type(lostItemId) == "string" and poopTierById[lostItemId] ~= nil
end

local function getPoopRedeemCoinValue(lostItemId, isCreator)
	local tier = type(lostItemId) == "string" and poopTierById[lostItemId] or nil
	if not tier then
		return 0
	end
	return if isCreator == true then poopTiers[1].CoinValue else tier.CoinValue
end

local function choosePoopItemId(random)
	if typeof(random) ~= "Random" then
		return poopItemIds[1]
	end
	local roll = random:NextInteger(1, poopTotalWeight)
	local cursor = 0
	for _, tier in poopTiers do
		cursor += tier.Weight
		if roll <= cursor then
			return tier.Id
		end
	end
	return poopItemIds[#poopItemIds]
end

local function getRedeemCoinValue(lostItemId, leafValueMultiplier)
	local config = type(lostItemId) == "string" and types[lostItemId] or nil
	if not config then
		return 0
	end
	local baseCoinValue = math.max(0, math.floor(tonumber(config.CoinValue) or 0))
	if not usesLeafValueMultiplier(lostItemId) then
		return baseCoinValue
	end

	local multiplier = tonumber(leafValueMultiplier)
	if
		multiplier == nil
		or multiplier ~= multiplier
		or multiplier == math.huge
		or multiplier == -math.huge
	then
		multiplier = 1
	end
	local scaledValue = baseCoinValue * math.max(0, multiplier)
	if scaledValue == math.huge then
		return MAX_REDEEM_COIN_VALUE
	end
	return math.min(MAX_REDEEM_COIN_VALUE, math.max(0, math.floor(scaledValue)))
end

local rarityProfiles = {
	Area_01 = { Common = 65, Uncommon = 24, Rare = 8, Legendary = 2, Mythic = 1 },
	Area_02 = { Common = 57, Uncommon = 25, Rare = 12, Legendary = 4, Mythic = 2 },
	Area_03 = { Common = 49, Uncommon = 26, Rare = 16, Legendary = 6, Mythic = 3 },
	Area_04 = { Common = 40, Uncommon = 27, Rare = 20, Legendary = 9, Mythic = 4 },
	Area_05 = { Common = 32, Uncommon = 26, Rare = 23, Legendary = 13, Mythic = 6 },
	Area_06 = { Common = 24, Uncommon = 24, Rare = 25, Legendary = 18, Mythic = 9 },
	Area_07 = { Common = 17, Uncommon = 21, Rare = 25, Legendary = 23, Mythic = 14 },
	Area_08 = { Common = 11, Uncommon = 17, Rare = 23, Legendary = 29, Mythic = 20 },
	Area_09 = { Common = 7, Uncommon = 13, Rare = 20, Legendary = 32, Mythic = 28 },
}

local areas = {}
for areaNumber = 1, RegionConfig.PersistentAreaCount do
	local areaId = string.format("Area_%02d", areaNumber)
	local profile = rarityProfiles[areaId]
	local totalProbability = 0
	for _, rarityId in rarityOrder do
		local probability = tonumber(profile[rarityId]) or 0
		assert(probability > 0, areaId .. " must give every rarity a positive probability")
		totalProbability += probability
	end
	assert(totalProbability == 100, areaId .. " rarity probabilities must total 100")
	areas[areaId] = table.freeze({
		SpawnMode = spawnModes.Progressive,
		MinimumSpawnCount = minimumSpawnCount,
		MaximumSpawnCount = maximumSpawnCount,
		RarityProbabilities = table.freeze(profile),
	})
end

for _, rarityId in rarityOrder do
	table.freeze(rarityDefinitions[rarityId])
	table.freeze(idsByRarity[rarityId])
end
table.freeze(rarityDefinitions)
table.freeze(idsByRarity)
table.freeze(rarityOrder)
table.freeze(order)
table.freeze(templateOrder)
table.freeze(types)
table.freeze(areas)

local function chooseBaseSpawnCount(random, areaId)
	local area = areas[areaId]
	assert(area, "Unknown lost item area: " .. tostring(areaId))
	return random:NextInteger(area.MinimumSpawnCount, area.MaximumSpawnCount)
end

local function chooseRarityId(random, areaId)
	local area = areas[areaId]
	assert(area, "Unknown lost item area: " .. tostring(areaId))
	local roll = random:NextNumber(0, 100)
	local cursor = 0
	for _, rarityId in rarityOrder do
		cursor += area.RarityProbabilities[rarityId]
		if roll <= cursor then
			return rarityId
		end
	end
	return rarityOrder[#rarityOrder]
end

local function chooseLostItemId(random, areaId)
	local rarityId = chooseRarityId(random, areaId)
	local candidates = idsByRarity[rarityId]
	local lostItemId = candidates[random:NextInteger(1, #candidates)]
	return lostItemId, rarityId, types[lostItemId].LuckyTier
end

local function normalizeLuckyTier(value)
	return math.clamp(math.floor(tonumber(value) or 1), 1, #rarityOrder)
end

local function getLuckyTier(lostItemId)
	local config = type(lostItemId) == "string" and types[lostItemId] or nil
	return config and config.PoopOnly ~= true and config.LuckyTier or nil
end

local function getLostItemIdsForTier(luckyTier)
	local rarityId = rarityOrder[normalizeLuckyTier(luckyTier)]
	return idsByRarity[rarityId]
end

local function chooseLostItemIdForTier(random, luckyTier)
	assert(typeof(random) == "Random", "Lucky-box selection requires Random")
	local normalizedTier = normalizeLuckyTier(luckyTier)
	local candidates = getLostItemIdsForTier(normalizedTier)
	return candidates[random:NextInteger(1, #candidates)], rarityOrder[normalizedTier]
end

local function getLuckyRevealPulseDurations(index)
	local decoyCount = math.max(1, math.floor(revealAnimation.DecoyCount))
	local normalizedIndex = math.clamp(math.floor(tonumber(index) or 1), 1, decoyCount)
	local progress = if decoyCount > 1 then (normalizedIndex - 1) / (decoyCount - 1) else 1
	local slowdown = progress ^ revealAnimation.SlowdownExponent
	local growDuration = revealAnimation.FirstDecoyGrowDuration
		+ (revealAnimation.LastDecoyGrowDuration - revealAnimation.FirstDecoyGrowDuration)
			* slowdown
	local shrinkDuration = revealAnimation.FirstDecoyShrinkDuration
		+ (revealAnimation.LastDecoyShrinkDuration - revealAnimation.FirstDecoyShrinkDuration)
			* slowdown
	return growDuration, shrinkDuration
end

local function getLuckyRevealPulseDuration()
	local duration = 0
	for index = 1, revealAnimation.DecoyCount do
		local growDuration, shrinkDuration = getLuckyRevealPulseDurations(index)
		duration += growDuration + shrinkDuration
	end
	return duration
end

local function getLuckyRevealAnimationDuration()
	return getLuckyRevealPulseDuration() + revealAnimation.FinalGrowDuration
end

local function getLuckyRevealTotalDuration()
	return getLuckyRevealAnimationDuration()
		+ revealAnimation.FinalHoldDuration
		+ revealAnimation.FlyToPlayerDuration
end

local LostItemConfig = {
	Order = order,
	TemplateOrder = templateOrder,
	CoinImage = "rbxassetid://98838784830744",
	CodexMilestones = codexMilestones,
	CodexCoinValueMultiplier = CODEX_COIN_VALUE_MULTIPLIER,
	GetCodexCoinReward = getCodexCoinReward,
	UsesLeafValueMultiplier = usesLeafValueMultiplier,
	GetRedeemCoinValue = getRedeemCoinValue,
	IsPoopItemId = isPoopItemId,
	GetPoopRedeemCoinValue = getPoopRedeemCoinValue,
	ChoosePoopItemId = choosePoopItemId,
	RevealAnimation = revealAnimation,
	TimedLuckyBox = timedLuckyBox,
	LuckyTierCount = #rarityOrder,
	NormalizeLuckyTier = normalizeLuckyTier,
	GetLuckyTier = getLuckyTier,
	GetLostItemIdsForTier = getLostItemIdsForTier,
	ChooseLostItemIdForTier = chooseLostItemIdForTier,
	GetLuckyRevealPulseDurations = getLuckyRevealPulseDurations,
	GetLuckyRevealPulseDuration = getLuckyRevealPulseDuration,
	GetLuckyRevealAnimationDuration = getLuckyRevealAnimationDuration,
	GetLuckyRevealTotalDuration = getLuckyRevealTotalDuration,
	RarityOrder = rarityOrder,
	Rarities = rarityDefinitions,
	IdsByRarity = idsByRarity,
	Types = types,
	Areas = areas,
	SpawnModes = spawnModes,
	MinimumSpawnCount = minimumSpawnCount,
	MaximumSpawnCount = maximumSpawnCount,
	ProgressiveSpawnRadius = 4,
	ProgressiveSpawnGroundAttempts = 8,
	LeafClearancePadding = 0.25,
	DropForwardOffset = 3,
	PoopItemIds = poopItemIds,
	PoopTiers = poopTiers,
	PoopTierById = poopTierById,
	PoopTotalWeight = poopTotalWeight,
	ChooseBaseSpawnCount = chooseBaseSpawnCount,
	ChooseRarityId = chooseRarityId,
	ChooseLostItemId = chooseLostItemId,
}

return table.freeze(LostItemConfig)

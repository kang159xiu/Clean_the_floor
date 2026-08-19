local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local AreaUnlockConfig = {
	Order = {},
	Areas = {},
	ByDoorModelName = {},
	CoinImage = "rbxassetid://140381046419252",
	PriceMultiplierPerRebirth = 2,
	DoorPurchasePresentation = {
		CoinImage = "rbxassetid://99223157190429",
		MinimumVisualCount = 10,
		MaximumVisualCount = 30,
		CurveMinimumPrice = 10,
		CurveMaximumPrice = 14_500,
		FlightDuration = 0.2,
		MaximumSpawnInterval = 0.1,
		MinimumSpawnInterval = 0.05,
		PulseScale = 1.08,
		PulseGrowDuration = 0.08,
		PulseShrinkDuration = 0.1,
	},
}

local baseUnlockPricesByTargetAreaNumber = {
	[2] = 10,
	[3] = 20,
	[4] = 50,
	[5] = 3_000,
	[6] = 6_650,
	[7] = 8_500,
	[8] = 14_500,
}

for targetAreaNumber = 2, RegionConfig.AreaCount do
	local targetAreaId = string.format("Area_%02d", targetAreaNumber)
	local requiredAreaNumber = targetAreaNumber - 1
	local baseUnlockPrice = assert(
		baseUnlockPricesByTargetAreaNumber[targetAreaNumber],
		string.format("Missing base unlock price for %s", targetAreaId)
	)
	local config = {
		TargetAreaId = targetAreaId,
		TargetAreaNumber = targetAreaNumber,
		RequiredAreaId = string.format("Area_%02d", requiredAreaNumber),
		RequiredAreaNumber = requiredAreaNumber,
		RequiredThroughAreaId = string.format("Area_%02d", requiredAreaNumber),
		RequiredThroughAreaNumber = requiredAreaNumber,
		BaseUnlockPrice = baseUnlockPrice,
		DoorModelName = string.format("Door%02d", targetAreaNumber),
	}
	table.freeze(config)
	AreaUnlockConfig.Areas[targetAreaId] = config
	AreaUnlockConfig.ByDoorModelName[config.DoorModelName] = config
	table.insert(AreaUnlockConfig.Order, targetAreaId)
end

function AreaUnlockConfig.IsClearRequirementMet(config, areas)
	if type(config) ~= "table" then
		return false
	end
	local requiredThroughAreaNumber = math.max(
		0,
		math.floor(tonumber(config.RequiredThroughAreaNumber) or 0)
	)
	local progressByArea = type(areas) == "table" and areas or {}
	for areaNumber = 1, requiredThroughAreaNumber do
		local areaId = string.format("Area_%02d", areaNumber)
		local progress = progressByArea[areaId]
		if (tonumber(type(progress) == "table" and progress.ClearedRatio) or 0) < 1 then
			return false
		end
	end
	return true
end

function AreaUnlockConfig.GetUnlockPrice(config, rebirthCount)
	if type(config) ~= "table" then
		return 0
	end
	local basePrice = math.max(0, math.floor(tonumber(config.BaseUnlockPrice) or 0))
	local scaledPrice = basePrice
		* AreaUnlockConfig.PriceMultiplierPerRebirth ^ RebirthConfig.NormalizeCount(rebirthCount)
	if scaledPrice == math.huge then
		return math.huge
	end
	return math.max(0, math.floor(scaledPrice + 0.5))
end

function AreaUnlockConfig.GetDoorPurchaseVisualCount(unlockPrice)
	local presentation = AreaUnlockConfig.DoorPurchasePresentation
	local normalized = math.clamp(
		((tonumber(unlockPrice) or 0) - presentation.CurveMinimumPrice)
			/ (presentation.CurveMaximumPrice - presentation.CurveMinimumPrice),
		0,
		1
	)
	return math.clamp(
		presentation.MinimumVisualCount
			+ math.floor(
				(presentation.MaximumVisualCount - presentation.MinimumVisualCount)
					* math.sqrt(normalized)
			),
		presentation.MinimumVisualCount,
		presentation.MaximumVisualCount
	)
end

function AreaUnlockConfig.GetDoorPurchaseSpawnInterval(visualCount)
	local presentation = AreaUnlockConfig.DoorPurchasePresentation
	local countProgress = math.clamp(
		((tonumber(visualCount) or presentation.MinimumVisualCount) - presentation.MinimumVisualCount)
			/ (presentation.MaximumVisualCount - presentation.MinimumVisualCount),
		0,
		1
	)
	return presentation.MaximumSpawnInterval
		- countProgress * (presentation.MaximumSpawnInterval - presentation.MinimumSpawnInterval)
end

table.freeze(AreaUnlockConfig.DoorPurchasePresentation)
table.freeze(AreaUnlockConfig.Order)
table.freeze(AreaUnlockConfig.Areas)
table.freeze(AreaUnlockConfig.ByDoorModelName)

return table.freeze(AreaUnlockConfig)

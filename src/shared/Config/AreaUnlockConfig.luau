local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local AreaUnlockConfig = {
	Order = {},
	Areas = {},
	ByDoorModelName = {},
	CoinImage = "rbxassetid://140381046419252",
}

local baseUnlockPricesByTargetAreaNumber = {
	[2] = 150,
	[3] = 800,
	[4] = 1_800,
	[5] = 3_000,
	[6] = 4_650,
	[7] = 6_500,
	[8] = 8_500,
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
	local progressByArea = type(areas) == "table" and areas or {}
	for areaNumber = 1, config.RequiredThroughAreaNumber do
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
	local leafCountMultiplier = RebirthConfig.GetLeafCountMultiplier(rebirthCount)
	return math.max(0, math.floor(basePrice * leafCountMultiplier + 0.5))
end

table.freeze(AreaUnlockConfig.Order)
table.freeze(AreaUnlockConfig.Areas)
table.freeze(AreaUnlockConfig.ByDoorModelName)

return table.freeze(AreaUnlockConfig)

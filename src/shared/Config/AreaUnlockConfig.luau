local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local AreaUnlockConfig = {
	Order = {},
	Areas = {},
	ByDoorModelName = {},
}

local minimumRebirthsByTargetAreaNumber = {
	[5] = 1,
	[6] = 2,
	[7] = 3,
	[8] = 4,
	[9] = 7,
}

for targetAreaNumber = 2, RegionConfig.AreaCount do
	local targetAreaId = string.format("Area_%02d", targetAreaNumber)
	local requiredAreaNumber = targetAreaNumber - 1
	local config = {
		TargetAreaId = targetAreaId,
		TargetAreaNumber = targetAreaNumber,
		RequiredAreaId = string.format("Area_%02d", requiredAreaNumber),
		RequiredAreaNumber = requiredAreaNumber,
		RequiredThroughAreaId = string.format("Area_%02d", requiredAreaNumber),
		RequiredThroughAreaNumber = requiredAreaNumber,
		MinimumRebirths = minimumRebirthsByTargetAreaNumber[targetAreaNumber] or 0,
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

function AreaUnlockConfig.GetRequirementStatus(config, areas, rebirthCount)
	if type(config) ~= "table" then
		return false, false
	end
	local cleared = AreaUnlockConfig.IsClearRequirementMet(config, areas)
	local rebirths = math.max(0, math.floor(tonumber(rebirthCount) or 0))
	return cleared, rebirths >= config.MinimumRebirths
end

table.freeze(AreaUnlockConfig.Order)
table.freeze(AreaUnlockConfig.Areas)
table.freeze(AreaUnlockConfig.ByDoorModelName)

return table.freeze(AreaUnlockConfig)

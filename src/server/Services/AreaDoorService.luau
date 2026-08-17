local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AreaUnlockConfig = require(ReplicatedStorage.Shared.Config.AreaUnlockConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local AreaDoorService = {}

local REQUEST_COOLDOWN = 0.15
local requestTimes = {}

function AreaDoorService:Init(playerDataService, requestRemote, leafService, metricsService)
	self.PlayerDataService = playerDataService
	self.RequestRemote = requestRemote
	self.LeafService = leafService
	self.MetricsService = metricsService

	for _, areaId in RegionConfig.Order do
		local area = Workspace:FindFirstChild(areaId)
		assert(area and area:IsA("Folder"), string.format("Workspace.%s must be a Folder", areaId))
		if area:GetAttribute("AreaCleaned") == nil then
			area:SetAttribute("AreaCleaned", false)
		end
	end

	requestRemote.OnServerEvent:Connect(function(player, targetAreaId)
		self:_requestUnlock(player, targetAreaId)
	end)
	Players.PlayerRemoving:Connect(function(player)
		requestTimes[player] = nil
	end)
end

function AreaDoorService:_requestUnlock(player, targetAreaId)
	if type(targetAreaId) ~= "string" then
		return
	end
	local config = AreaUnlockConfig.Areas[targetAreaId]
	if not config then
		return
	end
	local requiredAreaName = RegionConfig[config.RequiredThroughAreaId].DisplayName
	local targetAreaName = RegionConfig[config.TargetAreaId].DisplayName

	local now = os.clock()
	if now - (requestTimes[player] or -math.huge) < REQUEST_COOLDOWN then
		return
	end
	requestTimes[player] = now

	local state = self.PlayerDataService:GetState(player)
	if not state then
		return
	end
	if state.ActiveYardOwnerUserId ~= player.UserId then
		self.PlayerDataService:Notify(player, "Return to your yard before unlocking an area.")
		return
	end
	if state.UnlockedAreas[targetAreaId] == true then
		return
	end
	if state.UnlockedAreas[config.RequiredAreaId] ~= true then
		self.PlayerDataService:Notify(player, "Unlock the previous area first.")
		return
	end

	local clearRequirementMet, rebirthRequirementMet = AreaUnlockConfig.GetRequirementStatus(
		config,
		state.YardProgress and state.YardProgress.Areas,
		state.RebirthCount
	)
	if not clearRequirementMet or not rebirthRequirementMet then
		local message
		local rebirthWord = if config.MinimumRebirths == 1 then "rebirth" else "rebirths"
		if not clearRequirementMet and not rebirthRequirementMet then
			message = string.format(
				"Clear all areas through %s and reach %d %s to unlock %s.",
				requiredAreaName,
				config.MinimumRebirths,
				rebirthWord,
				targetAreaName
			)
		elseif not clearRequirementMet then
			message = string.format(
				"Clear all areas through %s to unlock %s.",
				requiredAreaName,
				targetAreaName
			)
		else
			message = string.format(
				"Reach %d %s to unlock %s.",
				config.MinimumRebirths,
				rebirthWord,
				targetAreaName
			)
		end
		self.PlayerDataService:Notify(player, message)
		return
	end

	state.UnlockedAreas[targetAreaId] = true
	state.YardProgress.UnlockedAreas[targetAreaId] = true
	self.PlayerDataService:QueuePersistentSave(player)
	if self.MetricsService then
		self.MetricsService:RecordAreaUnlocked(player, targetAreaId)
	end
	self.LeafService:GenerateNextAreaForUnlock(player, targetAreaId)
	self.PlayerDataService:PushSnapshot(player)
	self.PlayerDataService:Notify(player, "Unlocked " .. targetAreaName .. ".")
end

return AreaDoorService

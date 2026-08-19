local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local AreaUnlockConfig = require(ReplicatedStorage.Shared.Config.AreaUnlockConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local AreaDoorService = {}

local REQUEST_COOLDOWN = 0.15
local requestTimes = {}
local requestLocks = {}

function AreaDoorService:Init(
	playerDataService,
	requestRemote,
	leafService,
	metricsService,
	economyService,
	coinSpendRemote,
	coinShortageRemote
)
	self.PlayerDataService = playerDataService
	self.RequestRemote = requestRemote
	self.LeafService = leafService
	self.MetricsService = metricsService
	self.EconomyService = economyService
	self.CoinSpendRemote = coinSpendRemote
	self.CoinShortageRemote = coinShortageRemote
	assert(coinSpendRemote:IsA("RemoteEvent"), "CoinSpendEvent must be a RemoteEvent")
	assert(coinShortageRemote:IsA("RemoteEvent"), "AreaDoorCoinShortageNotice must be a RemoteEvent")

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
		requestLocks[player] = nil
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

	local now = os.clock()
	if now - (requestTimes[player] or -math.huge) < REQUEST_COOLDOWN then
		return
	end
	requestTimes[player] = now
	if requestLocks[player] then
		return
	end
	requestLocks[player] = true
	local succeeded, message = xpcall(function()
		self:_processUnlock(player, config)
	end, debug.traceback)
	requestLocks[player] = nil
	if not succeeded then
		warn(string.format("Area unlock failed for %s: %s", player.Name, tostring(message)))
	end
end

function AreaDoorService:_processUnlock(player, config)
	local targetAreaId = config.TargetAreaId
	local requiredAreaName = RegionConfig[config.RequiredThroughAreaId].DisplayName
	local targetAreaName = RegionConfig[targetAreaId].DisplayName
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
	if not AreaUnlockConfig.IsClearRequirementMet(config, state.YardProgress and state.YardProgress.Areas) then
		self.PlayerDataService:Notify(
			player,
			string.format("Clear all areas through %s to unlock %s.", requiredAreaName, targetAreaName)
		)
		return
	end

	local unlockPrice = AreaUnlockConfig.GetUnlockPrice(config, state.RebirthCount)
	if not self.EconomyService:TrySpend(player, unlockPrice) then
		self.PlayerDataService:Notify(
			player,
			string.format("You need %s Coins.", CoinFormat.Compact(unlockPrice))
		)
		if self.LeafService:AreAllUnlockedAreasCleared(player) then
			local resetStatus = self.LeafService:GetAreaCoinResetStatus(player)
			self.CoinShortageRemote:FireClient(player, {
				TargetAreaId = targetAreaId,
				CurrentCoins = math.max(0, math.floor(tonumber(state.Coins) or 0)),
				RequiredCoins = unlockPrice,
				AreaCoinResetEligible = resetStatus.Eligible == true,
				AreaCoinResetStatus = resetStatus.Status,
				AreaCoinResetRequirementText = resetStatus.RequirementText,
			})
		end
		return
	end

	state.UnlockedAreas[targetAreaId] = true
	state.YardProgress.UnlockedAreas[targetAreaId] = true
	self.PlayerDataService:QueuePersistentSave(player)
	self.CoinSpendRemote:FireClient(player, {
		Amount = unlockPrice,
		TargetCoins = math.max(0, math.floor(tonumber(state.Coins) or 0)),
		Reason = "AreaUnlock",
		TargetAreaId = targetAreaId,
	})
	if self.MetricsService then
		self.MetricsService:RecordAreaUnlocked(player, targetAreaId)
	end
	self.LeafService:GenerateNextAreaForUnlock(player, targetAreaId)
	self.PlayerDataService:PushSnapshot(player)
	self.PlayerDataService:Notify(
		player,
		string.format("Unlocked %s for %s Coins.", targetAreaName, CoinFormat.Compact(unlockPrice))
	)
end

return AreaDoorService

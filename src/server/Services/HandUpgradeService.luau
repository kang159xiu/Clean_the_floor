local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local HandUpgradeConfig = require(ReplicatedStorage.Shared.Config.HandUpgradeConfig)

local HandUpgradeService = {}

local REQUEST_INTERVAL = 0.1
local requestTimes = {}
local playerLocks = {}

function HandUpgradeService:Init(playerDataService, economyService, metricsService)
	self.PlayerDataService = playerDataService
	self.EconomyService = economyService
	self.MetricsService = metricsService

	Players.PlayerRemoving:Connect(function(player)
		requestTimes[player] = nil
		playerLocks[player] = nil
	end)
end

function HandUpgradeService:Upgrade(player, attributeId)
	if type(attributeId) ~= "string" or #attributeId > 16 then
		return false, "Invalid upgrade type.", self.PlayerDataService:GetSnapshot(player)
	end

	local attribute = HandUpgradeConfig.Attributes[attributeId]
	if not attribute then
		return false, "Invalid upgrade type.", self.PlayerDataService:GetSnapshot(player)
	end

	local now = os.clock()
	if now - (requestTimes[player] or 0) < REQUEST_INTERVAL or playerLocks[player] then
		return false, "Too fast.", self.PlayerDataService:GetSnapshot(player)
	end
	requestTimes[player] = now
	playerLocks[player] = true

	local callSucceeded, upgraded, message = pcall(function()
		local state = self.PlayerDataService:GetState(player)
		if not state then
			return false, "Player state is not ready."
		end

		local currentLevel = HandUpgradeConfig.NormalizeLevel(attributeId, state.HandUpgradeLevels[attributeId])
		if HandUpgradeConfig.IsMaxLevel(attributeId, currentLevel) then
			return false, attribute.DisplayName .. " is already max level."
		end

		local nextLevel = currentLevel + 1
		local price = HandUpgradeConfig.GetNextPrice(attributeId, currentLevel, state.RebirthCount)
		if not price or price < 0 then
			return false, "Invalid upgrade configuration."
		end

		if not self.EconomyService:TrySpend(player, price) then
			return false, string.format("Not enough Coins. You need %s.", CoinFormat.Compact(price))
		end

		state.HandUpgradeLevels[attributeId] = nextLevel
		self.PlayerDataService:QueuePersistentSave(player)
		if self.MetricsService then
			self.MetricsService:RecordPurchase(
				player,
				"HandUpgrade",
				attributeId .. tostring(nextLevel),
				price,
				state.CurrentAreaId
			)
		end
		self.PlayerDataService:PushSnapshot(player)
		return true, string.format("%s upgraded to Lv.%d.", attribute.DisplayName, nextLevel)
	end)

	playerLocks[player] = nil
	if not callSucceeded then
		warn(string.format("Hand upgrade failed for %s: %s", player.Name, tostring(upgraded)))
		return false, "Upgrade failed. Try again.", self.PlayerDataService:GetSnapshot(player)
	end

	if not upgraded then
		self.PlayerDataService:Notify(player, message)
	end
	return upgraded, message, self.PlayerDataService:GetSnapshot(player)
end

return HandUpgradeService

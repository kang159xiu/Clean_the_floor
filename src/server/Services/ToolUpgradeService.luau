local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)
local ToolUpgradeConfig = require(ReplicatedStorage.Shared.Config.ToolUpgradeConfig)

local ToolUpgradeService = {}

local REQUEST_INTERVAL = 0.1
local requestTimes = {}
local playerLocks = {}

function ToolUpgradeService:Init(playerDataService, economyService, metricsService)
	self.PlayerDataService = playerDataService
	self.EconomyService = economyService
	self.MetricsService = metricsService

	Players.PlayerRemoving:Connect(function(player)
		requestTimes[player] = nil
		playerLocks[player] = nil
	end)
end

function ToolUpgradeService:Upgrade(player, toolId, attributeId)
	if
		type(toolId) ~= "string"
		or #toolId > 24
		or type(attributeId) ~= "string"
		or #attributeId > 24
	then
		return false, "Invalid tool upgrade request.", self.PlayerDataService:GetSnapshot(player)
	end

	local toolConfig = ToolConfig.ById[toolId]
	local toolUpgrade = ToolUpgradeConfig.Tools[toolId]
	local attribute = ToolUpgradeConfig.GetAttribute(toolId, attributeId)
	if not toolConfig or not toolUpgrade or not attribute then
		return false, "Invalid tool upgrade request.", self.PlayerDataService:GetSnapshot(player)
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
		if state.UnlockedTools[toolId] ~= true then
			return false, "Unlock " .. toolConfig.Name .. " first."
		end

		local toolLevels = state.ToolUpgradeLevels and state.ToolUpgradeLevels[toolId]
		if not toolLevels then
			return false, "Invalid tool upgrade state."
		end
		local currentLevel = ToolUpgradeConfig.NormalizeLevel(toolId, attributeId, toolLevels[attributeId])
		if ToolUpgradeConfig.IsMaxLevel(toolId, attributeId, currentLevel) then
			return false, attribute.DisplayName .. " is already max level."
		end

		local nextLevel = currentLevel + 1
		local price = ToolUpgradeConfig.GetNextPrice(toolId, attributeId, currentLevel, state.RebirthCount)
		if not price or price < 0 then
			return false, "Invalid upgrade configuration."
		end
		if not self.EconomyService:TrySpend(player, price) then
			return false, string.format("Not enough Coins. You need %s.", CoinFormat.Compact(price))
		end

		toolLevels[attributeId] = nextLevel
		self.PlayerDataService:QueuePersistentSave(player)
		if self.MetricsService then
			self.MetricsService:RecordPurchase(
				player,
				"ToolUpgrade",
				toolId .. ":" .. attributeId .. tostring(nextLevel),
				price,
				state.CurrentAreaId
			)
		end
		self.PlayerDataService:PushSnapshot(player)
		return true, string.format("%s upgraded to Lv.%d.", attribute.DisplayName, nextLevel)
	end)

	playerLocks[player] = nil
	if not callSucceeded then
		warn(string.format("Tool upgrade failed for %s: %s", player.Name, tostring(upgraded)))
		return false, "Upgrade failed. Try again.", self.PlayerDataService:GetSnapshot(player)
	end

	if not upgraded then
		self.PlayerDataService:Notify(player, message)
	end
	return upgraded, message, self.PlayerDataService:GetSnapshot(player)
end

return ToolUpgradeService

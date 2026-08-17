local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local PlayerAttributeConfig = require(ReplicatedStorage.Shared.Config.PlayerAttributeConfig)

local PlayerAttributeUpgradeService = {}

local REQUEST_INTERVAL = 0.1
local requestTimes = {}
local playerLocks = {}

function PlayerAttributeUpgradeService:Init(playerDataService, economyService, metricsService)
	self.PlayerDataService = playerDataService
	self.EconomyService = economyService
	self.MetricsService = metricsService

	Players.PlayerRemoving:Connect(function(player)
		requestTimes[player] = nil
		playerLocks[player] = nil
	end)
end

function PlayerAttributeUpgradeService:_isEffectiveMax(state, attributeId)
	if attributeId == "MoveSpeed" then
		return (tonumber(state.WalkSpeed) or 0) >= PlayerAttributeConfig.MaximumWalkSpeed
	end
	return false
end

function PlayerAttributeUpgradeService:Upgrade(player, attributeId)
	if type(attributeId) ~= "string" or #attributeId > 24 then
		return false, "Invalid player attribute upgrade.", self.PlayerDataService:GetSnapshot(player)
	end
	local attribute = PlayerAttributeConfig.Attributes[attributeId]
	if not attribute then
		return false, "Invalid player attribute upgrade.", self.PlayerDataService:GetSnapshot(player)
	end

	local now = os.clock()
	if now - (requestTimes[player] or 0) < REQUEST_INTERVAL or playerLocks[player] then
		return false, "Too fast.", self.PlayerDataService:GetSnapshot(player)
	end
	requestTimes[player] = now
	playerLocks[player] = true

	local rollbackState = nil
	local rollbackCoins = nil
	local rollbackLevel = nil
	local callSucceeded, upgraded, message = pcall(function()
		local state = self.PlayerDataService:GetState(player)
		if not state then
			return false, "Player state is not ready."
		end
		if self:_isEffectiveMax(state, attributeId) then
			return false, attribute.DisplayName .. " is already maxed."
		end

		local levels = state.PlayerAttributeLevels
		if type(levels) ~= "table" then
			return false, "Invalid player attribute state."
		end
		local currentLevel = PlayerAttributeConfig.NormalizeLevel(attributeId, levels[attributeId])
		if PlayerAttributeConfig.IsConfiguredMaxLevel(attributeId, currentLevel) then
			return false, attribute.DisplayName .. " is already maxed."
		end
		local price = PlayerAttributeConfig.GetUpgradePrice(attributeId, currentLevel)
		if not price or price <= 0 or price == math.huge then
			return false, attribute.DisplayName .. " is already maxed."
		end
		local coinsBeforePurchase = tonumber(state.Coins)
		if not self.EconomyService:TrySpend(player, price) then
			return false, string.format("Not enough Coins. You need %s.", CoinFormat.Compact(price))
		end

		local nextLevel = currentLevel + 1
		rollbackState = state
		rollbackCoins = coinsBeforePurchase
		rollbackLevel = currentLevel
		levels[attributeId] = nextLevel
		self.PlayerDataService:RefreshPlayerModifiers(player)
		if self.MetricsService then
			self.MetricsService:RecordPurchase(
				player,
				"PlayerAttributeUpgrade",
				attributeId .. tostring(nextLevel),
				price,
				state.CurrentAreaId,
				{
					AttributeId = attributeId,
					TargetLevel = nextLevel,
					CoinCost = price,
				}
			)
		end
		self.PlayerDataService:QueuePersistentSave(player)
		self.PlayerDataService:PushSnapshot(player)
		return true, string.format("%s upgraded to Lv.%d.", attribute.DisplayName, nextLevel)
	end)

	playerLocks[player] = nil
	if not callSucceeded then
		if rollbackState and self.PlayerDataService:GetState(player) == rollbackState then
			rollbackState.Coins = rollbackCoins
			rollbackState.PlayerAttributeLevels[attributeId] = rollbackLevel
			pcall(function()
				self.PlayerDataService:RefreshPlayerModifiers(player)
			end)
			self.PlayerDataService:UpdateLeaderstats(player)
			self.PlayerDataService:QueuePersistentSave(player)
			self.PlayerDataService:PushSnapshot(player)
		end
		warn(string.format("Player attribute upgrade failed for %s: %s", player.Name, tostring(upgraded)))
		return false, "Upgrade failed. Try again.", self.PlayerDataService:GetSnapshot(player)
	end

	if not upgraded then
		self.PlayerDataService:Notify(player, message)
	end
	return upgraded, message, self.PlayerDataService:GetSnapshot(player)
end

return PlayerAttributeUpgradeService

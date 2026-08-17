local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)

local DoubleCoinsService = {}

local OWNERSHIP_ATTEMPTS = 3
local RETRY_DELAYS = { 1, 3 }

local ownershipByPlayer = {}

local function getConfig()
	local config = ProductConfig.GamePasses and ProductConfig.GamePasses.DoubleCoins
	assert(config, "ProductConfig.GamePasses.DoubleCoins is missing")
	assert(tonumber(config.GamePassId), "DoubleCoins.GamePassId must be numeric")
	assert(tonumber(config.Multiplier), "DoubleCoins.Multiplier must be numeric")
	return config
end

function DoubleCoinsService:_loadOwnership(player)
	local config = getConfig()
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		local success, ownsPass = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, config.GamePassId)
		end)
		if success then
			ownershipByPlayer[player] = ownsPass == true
			return ownershipByPlayer[player]
		end

		warn(string.format(
			"Double-coins ownership lookup failed for %s (attempt %d/%d): %s",
			player.Name,
			attempt,
			OWNERSHIP_ATTEMPTS,
			tostring(ownsPass)
		))
		if attempt < OWNERSHIP_ATTEMPTS and player.Parent == Players then
			task.wait(RETRY_DELAYS[attempt] or RETRY_DELAYS[#RETRY_DELAYS])
		end
	end

	ownershipByPlayer[player] = false
	return false
end

function DoubleCoinsService:OwnsPass(player)
	return ownershipByPlayer[player] == true
end

function DoubleCoinsService:GetMultiplier(player)
	if not self:OwnsPass(player) then
		return 1
	end
	return math.max(1, math.floor(tonumber(getConfig().Multiplier) or 1))
end

function DoubleCoinsService:Init(playerDataService)
	self.PlayerDataService = playerDataService
	local config = getConfig()

	playerDataService:SetCoinRewardMultiplierProvider(function(player)
		return self:GetMultiplier(player), ownershipByPlayer[player] ~= nil
	end)
	playerDataService:AddPlayerStateReadyHandler(function(player)
		self:_loadOwnership(player)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if gamePassId ~= config.GamePassId or wasPurchased ~= true or player.Parent ~= Players then
			return
		end
		ownershipByPlayer[player] = true
		playerDataService:Notify(player, "Double Coins activated.")
		playerDataService:PushSnapshot(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		ownershipByPlayer[player] = nil
	end)
end

return DoubleCoinsService

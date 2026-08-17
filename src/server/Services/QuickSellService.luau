local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)

local QuickSellService = {}

local OWNERSHIP_ATTEMPTS = 3
local RETRY_DELAYS = { 1, 3 }

local ownershipStates = {}
local quickSellLocks = {}

local function getConfig()
	local config = ProductConfig.GamePasses and ProductConfig.GamePasses.QuickSell
	assert(config and config.Id == "QuickSell", "ProductConfig.GamePasses.QuickSell is missing")
	assert(tonumber(config.GamePassId), "QuickSell.GamePassId must be numeric")
	return config
end

local function makeResult(status, recycledBagValue, redeemedLostItemCount)
	return {
		Status = status,
		RecycledBagValue = math.max(0, tonumber(recycledBagValue) or 0),
		RedeemedLostItemCount = math.max(0, math.floor(tonumber(redeemedLostItemCount) or 0)),
	}
end

function QuickSellService:_loadOwnership(player)
	local config = getConfig()
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		local success, ownsPass = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, config.GamePassId)
		end)
		if success then
			ownershipStates[player] = {
				Owned = ownsPass == true,
				Ready = true,
			}
			if self.PlayerDataService:GetState(player) then
				self.PlayerDataService:PushSnapshot(player)
			end
			return
		end

		warn(string.format(
			"Quick Sell ownership lookup failed for %s (attempt %d/%d): %s",
			player.Name,
			attempt,
			OWNERSHIP_ATTEMPTS,
			tostring(ownsPass)
		))
		if attempt < OWNERSHIP_ATTEMPTS and player.Parent == Players then
			task.wait(RETRY_DELAYS[attempt] or RETRY_DELAYS[#RETRY_DELAYS])
		end
	end

	if player.Parent == Players then
		ownershipStates[player] = {
			Owned = false,
			Ready = false,
		}
		if self.PlayerDataService:GetState(player) then
			self.PlayerDataService:PushSnapshot(player)
		end
	end
end

function QuickSellService:GetOwnershipStatus(player)
	local state = ownershipStates[player]
	return state ~= nil and state.Owned == true, state ~= nil and state.Ready == true
end

function QuickSellService:Request(player)
	local playerState = self.PlayerDataService:GetState(player)
	if player.Parent ~= Players or not playerState then
		return makeResult("Unavailable", 0, 0)
	end
	local owned, ready = self:GetOwnershipStatus(player)
	if not ready then
		return makeResult("Unavailable", 0, 0)
	end
	if not owned then
		return makeResult("NotOwned", 0, 0)
	end
	if quickSellLocks[player] then
		return makeResult("Busy", 0, 0)
	end

	quickSellLocks[player] = true
	local recycleStatus = "Unavailable"
	local recycledBagValue = 0
	local recycleSucceeded, recycleError = pcall(function()
		recycleStatus, recycledBagValue = self.RecycleService:TryQuickSell(player)
	end)
	if not recycleSucceeded then
		warn("Quick Sell leaf recycle failed for " .. player.Name .. ": " .. tostring(recycleError))
		recycleStatus = "Unavailable"
	end

	local lostItemStatus = "Unavailable"
	local redeemedLostItemCount = 0
	local lostItemSucceeded, lostItemError = pcall(function()
		lostItemStatus, redeemedLostItemCount = self.LostItemService:TryQuickRedeem(player)
	end)
	if not lostItemSucceeded then
		warn("Quick Sell lost-item redeem failed for " .. player.Name .. ": " .. tostring(lostItemError))
		lostItemStatus = "Unavailable"
	end
	quickSellLocks[player] = nil

	if recycleStatus == "Sold" or lostItemStatus == "Sold" then
		return makeResult("Sold", recycledBagValue, redeemedLostItemCount)
	end
	if recycleStatus == "Empty" and lostItemStatus == "Empty" then
		return makeResult("Empty", 0, 0)
	end
	if recycleStatus == "Busy" or lostItemStatus == "Busy" then
		return makeResult("Busy", 0, 0)
	end
	return makeResult("Unavailable", 0, 0)
end

function QuickSellService:Init(playerDataService, recycleService, lostItemService)
	self.PlayerDataService = playerDataService
	self.RecycleService = recycleService
	self.LostItemService = lostItemService
	local config = getConfig()

	playerDataService:SetQuickSellOwnershipProvider(function(player)
		return self:GetOwnershipStatus(player)
	end)
	playerDataService:AddPlayerStateReadyHandler(function(player)
		task.spawn(function()
			self:_loadOwnership(player)
		end)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if gamePassId ~= config.GamePassId or wasPurchased ~= true or player.Parent ~= Players then
			return
		end
		ownershipStates[player] = {
			Owned = true,
			Ready = true,
		}
		playerDataService:PushSnapshot(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		ownershipStates[player] = nil
		quickSellLocks[player] = nil
	end)
end

return QuickSellService

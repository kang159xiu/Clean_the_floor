local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)

local RebirthService = {}

local rebirthLocks = {}

local function formatMultiplier(value)
	local normalized = math.max(0, tonumber(value) or 0)
	local rounded = math.floor(normalized + 0.5)
	if math.abs(normalized - rounded) < 0.001 then
		return tostring(rounded)
	end
	return string.format("%.1f", normalized)
end

function RebirthService:CanRebirth(player)
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return false, false, false, 0, RebirthConfig.GetRainbowPoopRequiredCount(0), 0, RebirthConfig.GetRequiredCoins(0)
	end
	local requiredCount = RebirthConfig.GetRainbowPoopRequiredCount(state.RebirthCount)
	local foundCount = math.min(
		math.max(0, math.floor(tonumber(state.RainbowPoopFoundCount) or 0)),
		requiredCount
	)
	local rainbowPoopCompleted = foundCount >= requiredCount
	local currentCoins = math.max(0, tonumber(state.Coins) or 0)
	local requiredCoins = RebirthConfig.GetRequiredCoins(state.RebirthCount)
	local moneyCompleted = currentCoins >= requiredCoins
	return moneyCompleted or rainbowPoopCompleted,
		rainbowPoopCompleted,
		moneyCompleted,
		foundCount,
		requiredCount,
		currentCoins,
		requiredCoins
end

function RebirthService:GetRequirementMessage(player)
	local _, _, _, foundCount, requiredCount, _, requiredCoins = self:CanRebirth(player)
	return RebirthConfig.GetRequirementText(
		requiredCoins,
		foundCount,
		requiredCount
	)
end

function RebirthService:_tryRebirth(player, notifyFailure, skipRebirthPurchaseId)
	if rebirthLocks[player] then
		return false, "Rebirth is already in progress."
	end
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return false, "Player data is not ready."
	end
	if self.CoinFlipPendingProvider and self.CoinFlipPendingProvider(player) then
		return false, "Wait for the coin flip to finish before rebirthing."
	end
	local purchasedSkip = skipRebirthPurchaseId ~= nil
	if purchasedSkip then
		if state.PersistentDataAvailable ~= true then
			return false, "Player save data is unavailable."
		end
		if self.PlayerDataService:HasProcessedSkipRebirthReceipt(player, skipRebirthPurchaseId) then
			if self.PlayerDataService:SavePlayerNow(player) then
				return true, "This paid rebirth was already applied."
			end
			return false, "Paid rebirth save retry failed."
		end
	end

	local eligible = purchasedSkip or self:CanRebirth(player)
	if not eligible then
		local message = self:GetRequirementMessage(player)
		if notifyFailure ~= false then
			self.PlayerDataService:Notify(player, message)
		end
		return false, message
	end

	rebirthLocks[player] = true
	local requestSucceeded = false
	local requestMessage = "Rebirth failed. Try again."
	local rebirthCount = nil
	local leafCountMultiplier = nil
	local receiptCheckpointSaved = not purchasedSkip

	local operationSucceeded, operationError = xpcall(function()
		self.ToolActionService:StopPlayer(player)
		self.LeafService:SetPickupActive(player, false)

		local resetSucceeded, result, nextLeafCountMultiplier = self.PlayerDataService:ResetForRebirth(
			player,
			skipRebirthPurchaseId
		)
		if not resetSucceeded then
			requestMessage = result
			return
		end
		rebirthCount = result
		leafCountMultiplier = nextLeafCountMultiplier
		local rebirthSaveSucceeded = self.PlayerDataService:SavePlayerNow(player)
		if purchasedSkip then
			receiptCheckpointSaved = rebirthSaveSucceeded
			if not receiptCheckpointSaved then
				warn(string.format(
					"Paid rebirth checkpoint save failed for %s (PurchaseId=%s)",
					player.Name,
					tostring(skipRebirthPurchaseId)
				))
			end
		elseif not rebirthSaveSucceeded then
			warn(string.format(
				"Rebirth checkpoint save failed for %s; the latest state remains queued for retry",
				player.Name
			))
		end

		self.LostItemService:ResetYard(player)
		self.PoopService:ResetYard(player)
		self.TutorialService:ResetPlayer(player)
		self.LeafService:ResetOwnerYard(player)
		self.PlayerDataService:PushSnapshot(player)

		if player.Parent == Players then
			local loadedCharacter, loadError = pcall(function()
				player:LoadCharacterAsync()
			end)
			if not loadedCharacter then
				warn("Rebirth character reload failed: " .. tostring(loadError))
			end
		end

		local leafValueMultiplier = RebirthConfig.GetLeafValueMultiplier(rebirthCount)
		requestMessage = string.format(
			"Rebirth complete! Rebirth %d, Leaf Value x%s, Leaf Count x%.1f",
			rebirthCount,
			formatMultiplier(leafValueMultiplier),
			leafCountMultiplier or RebirthConfig.GetLeafCountMultiplier(rebirthCount)
		)
		requestSucceeded = receiptCheckpointSaved
		if not receiptCheckpointSaved then
			requestMessage = "Paid rebirth applied, but its save is waiting to retry."
		end
	end, debug.traceback)
	rebirthLocks[player] = nil

	if not operationSucceeded then
		warn("Rebirth failed: " .. tostring(operationError))
		requestMessage = "Rebirth failed. Try again."
	end
	if requestSucceeded then
		if player.Parent == Players then
			self.PlayerDataService:Notify(player, requestMessage)
		end
		return true, requestMessage
	end
	if notifyFailure ~= false and player.Parent == Players then
		self.PlayerDataService:Notify(player, requestMessage)
	end
	return false, requestMessage
end

function RebirthService:SetCoinFlipPendingProvider(provider)
	self.CoinFlipPendingProvider = provider
end

function RebirthService:TryRebirth(player, notifyFailure)
	return self:_tryRebirth(player, notifyFailure, nil)
end

function RebirthService:TryPurchasedRebirth(player, purchaseId)
	if type(purchaseId) ~= "string" or #purchaseId <= 0 or #purchaseId > 128 then
		return false, "Invalid paid rebirth receipt."
	end
	return self:_tryRebirth(player, false, purchaseId)
end

function RebirthService:Init(
	playerDataService,
	leafService,
	lostItemService,
	tutorialService,
	toolActionService,
	poopService
)
	self.PlayerDataService = playerDataService
	self.LeafService = leafService
	self.LostItemService = lostItemService
	self.TutorialService = tutorialService
	self.ToolActionService = toolActionService
	self.PoopService = poopService
	playerDataService:SetRebirthStatusProvider(function(player)
		local eligible, _, _, foundCount, requiredCount = self:CanRebirth(player)
		return eligible, foundCount, requiredCount
	end)
	poopService:AddPoopPickedUpHandler(function(player, _, lostItemId)
		if lostItemId == "LostItem099" then
			playerDataService:IncrementRainbowPoopFound(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		rebirthLocks[player] = nil
	end)
end

return RebirthService

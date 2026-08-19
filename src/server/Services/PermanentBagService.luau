local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)

local PermanentBagService = {}

local OWNERSHIP_ATTEMPTS = 3
local RETRY_DELAYS = { 1, 3 }
local PURCHASE_PROMPT_TIMEOUT = 30

local ownershipByPlayer = {}
local purchasePromptLocks = {}

local function makeOwnershipState()
	local result = {}
	for _, bagId in BagConfig.PermanentOrder do
		local enabled = BagConfig.IsPermanentBagEnabled(bagId)
		result[bagId] = {
			Ready = not enabled,
			Owned = false,
		}
	end
	return result
end

local function getConfigByGamePassId(gamePassId)
	for _, bagId in BagConfig.PermanentOrder do
		local config = BagConfig.PermanentBags[bagId]
		if BagConfig.IsPermanentBagEnabled(bagId) and config.GamePassId == gamePassId then
			return config
		end
	end
	return nil
end

function PermanentBagService:_getOwnershipMaps(player)
	local state = ownershipByPlayer[player]
	local ownership = {}
	local readiness = {}
	for _, bagId in BagConfig.PermanentOrder do
		local entry = state and state[bagId]
		local enabled = BagConfig.IsPermanentBagEnabled(bagId)
		ownership[bagId] = enabled and entry and entry.Owned == true or false
		readiness[bagId] = enabled and entry and entry.Ready == true or false
	end
	return ownership, readiness
end

function PermanentBagService:_hasStationAccess(ownership, bagId)
	return BagConfig.IsPermanentBagEnabled(bagId) and ownership[bagId] == true
end

function PermanentBagService:_applyOwnership(player)
	local playerState = self.PlayerDataService:GetState(player)
	if not playerState then
		return false
	end
	local wasInstantRecycle = self.PlayerDataService:IsInstantRecycleEnabled(playerState)
	local ownership, readiness = self:_getOwnershipMaps(player)
	self.PlayerDataService:SetPermanentBagEntitlements(player, ownership, readiness, false)
	for _, bagId in BagConfig.PermanentOrder do
		if BagConfig.IsPermanentBagEnabled(bagId) then
			self.CollisionService:SetPlayerAccess(
				player,
				bagId,
				self:_hasStationAccess(ownership, bagId)
			)
		end
	end
	self.BagVisualService:SyncPlayer(player)

	local isInstantRecycle = self.PlayerDataService:IsInstantRecycleEnabled(playerState)
	if isInstantRecycle and not wasInstantRecycle then
		local bagValue, awardedCoins, targetCoins = self.BagService:RecycleStoredContents(player, false)
		if bagValue > 0 then
			self.RecycleService:NotifyInstantRecycleCompleted(
				player,
				playerState.CurrentAreaId or "Area_01",
				bagValue,
				awardedCoins,
				targetCoins
			)
		end
	end
	self.PlayerDataService:PushSnapshot(player)
	return true
end

function PermanentBagService:_queryOwnership(player, config)
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		if player.Parent ~= Players then
			return false, false
		end
		local success, ownsPass = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, config.GamePassId)
		end)
		if success then
			return true, ownsPass == true
		end
		warn(string.format(
			"%s ownership lookup failed for %s (attempt %d/%d): %s",
			config.Id,
			player.Name,
			attempt,
			OWNERSHIP_ATTEMPTS,
			tostring(ownsPass)
		))
		if attempt < OWNERSHIP_ATTEMPTS then
			task.wait(RETRY_DELAYS[attempt] or RETRY_DELAYS[#RETRY_DELAYS])
		end
	end
	return false, false
end

function PermanentBagService:_loadAllOwnership(player)
	local state = makeOwnershipState()
	ownershipByPlayer[player] = state
	local remaining = 0
	for _, bagId in BagConfig.PermanentOrder do
		if BagConfig.IsPermanentBagEnabled(bagId) then
			remaining += 1
			task.spawn(function()
				local ready, owned = self:_queryOwnership(player, BagConfig.PermanentBags[bagId])
				if ownershipByPlayer[player] == state then
					state[bagId].Ready = ready
					state[bagId].Owned = ready and owned or false
				end
				remaining -= 1
			end)
		end
	end
	while remaining > 0 and player.Parent == Players do
		task.wait()
	end
	if player.Parent == Players and ownershipByPlayer[player] == state then
		self:_applyOwnership(player)
	end
end

function PermanentBagService:_refreshSingleOwnership(player, config)
	if not BagConfig.IsPermanentBagEnabled(config.Id) then
		return true, false
	end
	local state = ownershipByPlayer[player]
	if not state then
		state = makeOwnershipState()
		ownershipByPlayer[player] = state
	end
	local ready, owned = self:_queryOwnership(player, config)
	if ownershipByPlayer[player] ~= state then
		return false, false
	end
	state[config.Id].Ready = ready
	state[config.Id].Owned = ready and owned or false
	self:_applyOwnership(player)
	return ready, state[config.Id].Owned
end

function PermanentBagService:_promptPurchase(player, config)
	if not BagConfig.IsPermanentBagEnabled(config.Id) then
		return false
	end
	if purchasePromptLocks[player] then
		return false
	end
	local promptToken = {}
	purchasePromptLocks[player] = promptToken
	local success, message = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, config.GamePassId)
	end)
	if not success then
		purchasePromptLocks[player] = nil
		warn(string.format("%s purchase prompt failed for %s: %s", config.Id, player.Name, tostring(message)))
		self.PlayerDataService:Notify(player, config.Name .. " purchase window is unavailable.")
		return false
	end
	task.delay(PURCHASE_PROMPT_TIMEOUT, function()
		if purchasePromptLocks[player] == promptToken then
			purchasePromptLocks[player] = nil
		end
	end)
	return true
end

function PermanentBagService:_equipOwnedBagAppearance(player, config)
	local selected = self.PlayerDataService:SetSelectedPermanentBagVisual(player, config.Id)
	if not selected then
		return false
	end
	self.BagVisualService:SyncPlayer(player)
	return true
end

function PermanentBagService:_equipOwnedBagFromCache(player, config)
	-- A reset can replace the runtime state after this service has cached the
	-- Marketplace result. Reapply the complete cache before selecting the visual.
	if not self:_applyOwnership(player) or not self:_equipOwnedBagAppearance(player, config) then
		self.PlayerDataService:Notify(player, "Backpack ownership could not be applied. Try again shortly.")
		return false
	end
	self.PlayerDataService:Notify(player, config.Name .. " appearance equipped.")
	return true
end

function PermanentBagService:_onStationTriggered(player, config)
	if
		not BagConfig.IsPermanentBagEnabled(config.Id)
		or player.Parent ~= Players
		or not self.PlayerDataService:GetState(player)
	then
		return false
	end
	local state = ownershipByPlayer[player]
	local entry = state and state[config.Id]
	if not entry or not entry.Ready then
		local ready, owned = self:_refreshSingleOwnership(player, config)
		if not ready then
			self.PlayerDataService:Notify(player, "Game Pass ownership could not be confirmed. Try again later.")
			return false
		end
		if owned then
			return self:_equipOwnedBagFromCache(player, config)
		end
	end

	local ownership = self:_getOwnershipMaps(player)
	if ownership[config.Id] == true then
		return self:_equipOwnedBagFromCache(player, config)
	end
	return self:_promptPurchase(player, config)
end

function PermanentBagService:RequestBagPurchase(player, bagId)
	if type(bagId) ~= "string" or #bagId > 32 then
		return false
	end
	local config = BagConfig.PermanentBags[bagId]
	if not config or not BagConfig.IsCapacityPermanentBag(bagId) then
		return false
	end
	return self:_onStationTriggered(player, config)
end

function PermanentBagService:_tryBindStation(station)
	if station.Parent ~= self.FunctionFolder or self.BoundStations[station] then
		return
	end
	local config = nil
	for _, bagId in BagConfig.PermanentOrder do
		local candidate = BagConfig.PermanentBags[bagId]
		if string.lower(station.Name) == string.lower(candidate.StationName) then
			config = candidate
			break
		end
	end
	if not config then
		return
	end
	if not BagConfig.IsPermanentBagEnabled(config.Id) then
		self.BoundStations[station] = true
		local function disableStationInstance(instance)
			if instance:IsA("ProximityPrompt") then
				instance.Enabled = false
			elseif instance:IsA("BasePart") then
				instance.CanCollide = false
				instance.CanTouch = false
				instance.CanQuery = false
			end
		end
		disableStationInstance(station)
		for _, descendant in station:GetDescendants() do
			disableStationInstance(descendant)
		end
		station.DescendantAdded:Connect(disableStationInstance)
		station.Destroying:Connect(function()
			self.BoundStations[station] = nil
		end)
		return
	end
	local prompt = station:FindFirstChild("ProximityPrompt")
	if not station:IsA("BasePart") or not prompt or not prompt:IsA("ProximityPrompt") then
		warn("Invalid permanent bag purchase station: " .. station:GetFullName())
		return
	end
	self.BoundStations[station] = true
	prompt.Enabled = true
	prompt.ActionText = "Buy"
	prompt.ObjectText = config.Name
	self.CollisionService:RegisterStation(config.Id, station)
	prompt.Triggered:Connect(function(player)
		task.spawn(function()
			self:_onStationTriggered(player, config)
		end)
	end)
	station.Destroying:Connect(function()
		self.BoundStations[station] = nil
	end)
end

function PermanentBagService:_bindPurchaseStations()
	self.FunctionFolder = Workspace:WaitForChild("Function")
	self.BoundStations = {}
	for _, station in self.FunctionFolder:GetChildren() do
		self:_tryBindStation(station)
	end
	self.FunctionFolder.ChildAdded:Connect(function(station)
		task.defer(function()
			self:_tryBindStation(station)
		end)
	end)
	for _, bagId in BagConfig.PermanentOrder do
		if BagConfig.IsPermanentBagEnabled(bagId) then
			local stationName = BagConfig.PermanentBags[bagId].StationName
			local found = false
			for _, station in self.FunctionFolder:GetChildren() do
				if string.lower(station.Name) == string.lower(stationName) then
					found = true
					break
				end
			end
			assert(found, "Workspace.Function requires at least one " .. stationName .. ".ProximityPrompt")
		end
	end
end

function PermanentBagService:Init(
	playerDataService,
	bagService,
	bagVisualService,
	recycleService,
	collisionService
)
	self.PlayerDataService = playerDataService
	self.BagService = bagService
	self.BagVisualService = bagVisualService
	self.RecycleService = recycleService
	self.CollisionService = collisionService

	for _, bagId in BagConfig.PermanentOrder do
		local config = BagConfig.PermanentBags[bagId]
		assert(type(config.Enabled) == "boolean", config.Id .. ".Enabled must be boolean")
		if BagConfig.IsPermanentBagEnabled(bagId) then
			assert(config.PurchaseKind == "GamePass", config.Id .. ".PurchaseKind must be GamePass")
			assert(tonumber(config.GamePassId), config.Id .. ".GamePassId must be numeric")
		end
	end

	playerDataService:SetPermanentBagEntitlementProvider(function(player)
		return self:_getOwnershipMaps(player)
	end)
	playerDataService:AddPlayerStateReadyHandler(function(player)
		self:_loadAllOwnership(player)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		local config = getConfigByGamePassId(gamePassId)
		if not config or player.Parent ~= Players then
			return
		end
		purchasePromptLocks[player] = nil
		if wasPurchased ~= true then
			return
		end
		local state = ownershipByPlayer[player] or makeOwnershipState()
		ownershipByPlayer[player] = state
		state[config.Id].Ready = true
		state[config.Id].Owned = true
		self:_applyOwnership(player)
		if self:_equipOwnedBagAppearance(player, config) then
			self.PlayerDataService:Notify(player, config.Name .. " unlocked and equipped.")
		else
			self.PlayerDataService:Notify(player, config.Name .. " unlocked. Use the station to equip it.")
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		ownershipByPlayer[player] = nil
		purchasePromptLocks[player] = nil
	end)

	self:_bindPurchaseStations()
end

return PermanentBagService

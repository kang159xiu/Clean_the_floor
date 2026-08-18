local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)

local BagService = {}

function BagService:Init(playerDataService, bagVisualService, economyService)
	self.PlayerDataService = playerDataService
	self.BagVisualService = bagVisualService
	self.EconomyService = economyService
end

function BagService:IsFull(player)
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return true
	end
	if self.PlayerDataService:IsInstantRecycleEnabled(state) then
		return false
	end
	return state.CurrentBagValue >= self.PlayerDataService:GetBagCapacity(state)
end

function BagService:TryAdd(player, amount, shouldPush, sourceOwnerUserId)
	local state = self.PlayerDataService:GetState(player)
	if not state or type(amount) ~= "number" or amount <= 0 then
		return false, 0
	end
	if self.PlayerDataService:IsInstantRecycleEnabled(state) then
		local ownerUserId = math.floor(tonumber(sourceOwnerUserId) or state.ActiveYardOwnerUserId or player.UserId)
		if ownerUserId <= 0 then
			ownerUserId = player.UserId
		end
		local awardedCoins, targetCoins = self.EconomyService:AwardRecycleCoins(player, amount, {
			ShouldPush = shouldPush ~= false,
			SourceValues = {
				[tostring(ownerUserId)] = amount,
			},
			StepCount = 1,
			FirstStepDelay = 0,
			StepInterval = 0.1,
			HoldDuration = 1,
			FlyDuration = 0.35,
		})
		return true, amount, "InstantRecycle", awardedCoins, targetCoins
	end

	local capacity = self.PlayerDataService:GetBagCapacity(state)
	local remaining = math.max(0, capacity - state.CurrentBagValue)
	if remaining <= 0 then
		return false, 0
	end

	local added = math.min(remaining, amount)
	state.CurrentBagValue += added
	local ownerUserId = math.floor(tonumber(sourceOwnerUserId) or state.ActiveYardOwnerUserId or player.UserId)
	if ownerUserId <= 0 then
		ownerUserId = player.UserId
	end
	local sourceKey = tostring(ownerUserId)
	state.BagSourceValues[sourceKey] = (state.BagSourceValues[sourceKey] or 0) + added
	self.PlayerDataService:MarkPersistentDirty(player)

	if state.CurrentBagValue >= capacity and not state.BagFullNotified then
		state.BagFullNotified = true
	end

	if shouldPush ~= false then
		self.PlayerDataService:PushSnapshot(player)
	end
	return true, added, "Bag", 0, state.Coins
end

function BagService:TakeAll(player, shouldPush)
	local state = self.PlayerDataService:GetState(player)
	if not state or state.CurrentBagValue <= 0 then
		return 0, {}, nil
	end

	local value = state.CurrentBagValue
	local sourceValues = {}
	for ownerUserId, sourceValue in state.BagSourceValues do
		sourceValues[ownerUserId] = sourceValue
	end
	local bagCycleId = state.BagCycleId or 1
	state.CurrentBagValue = 0
	table.clear(state.BagSourceValues)
	state.BagCycleId = bagCycleId + 1
	state.BagFullNotified = false
	self.PlayerDataService:MarkPersistentDirty(player)
	if shouldPush ~= false then
		self.PlayerDataService:PushSnapshot(player)
	end
	return value, sourceValues, bagCycleId
end

function BagService:SetLevel(player, level)
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return false
	end
	state.BagLevel = level
	state.BagFullNotified = state.CurrentBagValue >= self.PlayerDataService:GetBagCapacity(state)
	self.BagVisualService:SyncPlayer(player)
	self.PlayerDataService:QueuePersistentSave(player)
	return true
end

function BagService:SetExpansionLevel(player, level)
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return false
	end
	state.BagExpansionLevel = BagConfig.NormalizeExpansionLevel(level)
	state.BagFullNotified = state.CurrentBagValue >= self.PlayerDataService:GetBagCapacity(state)
	self.PlayerDataService:QueuePersistentSave(player)
	return true
end

function BagService:RecycleStoredContents(player, shouldPush)
	local bagValue, sourceValues = self:TakeAll(player, false)
	if bagValue <= 0 then
		return 0, 0, nil
	end
	local awardedCoins, targetCoins = self.EconomyService:AwardRecycleCoins(player, bagValue, {
		ShouldPush = shouldPush ~= false,
		SourceValues = sourceValues,
		StepCount = 1,
		FirstStepDelay = 0,
		StepInterval = 0.1,
		HoldDuration = 1,
		FlyDuration = 0.35,
	})
	return bagValue, awardedCoins, targetCoins
end

return BagService

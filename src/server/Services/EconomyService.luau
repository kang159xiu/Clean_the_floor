local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerAttributeConfig = require(ReplicatedStorage.Shared.Config.PlayerAttributeConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local EconomyService = {}

local pendingRecycleBatches = {}
local settlementSequences = {}

local function sanitizeCurrency(value)
	local numeric = tonumber(value)
	if not numeric or numeric ~= numeric or numeric == math.huge or numeric == -math.huge then
		return 0
	end
	return math.clamp(math.floor(numeric), 0, PlayerAttributeConfig.MaximumCurrencyValue)
end

local function copyAmounts(source)
	local result = {}
	for ownerUserId, amount in source do
		result[ownerUserId] = amount
	end
	return result
end

function EconomyService:Init(playerDataService)
	self.PlayerDataService = playerDataService
	self.FriendRewardHandler = nil

	Players.PlayerRemoving:Connect(function(player)
		self:FlushRecycleBatch(player)
		pendingRecycleBatches[player] = nil
		settlementSequences[player] = nil
	end)

	game:BindToClose(function()
		for player in pendingRecycleBatches do
			self:FlushRecycleBatch(player)
			self.PlayerDataService:SavePlayerNow(player)
		end
	end)
end

function EconomyService:SetFriendRewardHandler(handler)
	self.FriendRewardHandler = handler
end

function EconomyService:_sendFriendRewards(player, amounts)
	if not self.FriendRewardHandler or not next(amounts) then
		return
	end
	local success, message = pcall(self.FriendRewardHandler, player, copyAmounts(amounts))
	if not success then
		warn("Friend reward handler failed: " .. tostring(message))
	end
end

function EconomyService:_makeFriendAmounts(player, sourceValues, multiplier)
	local result = {}
	if type(sourceValues) ~= "table" then
		return result
	end
	for rawOwnerUserId, rawSourceValue in sourceValues do
		local ownerUserId = math.floor(tonumber(rawOwnerUserId) or 0)
		local sourceValue = math.max(0, math.floor(tonumber(rawSourceValue) or 0))
		local amount = sanitizeCurrency(sourceValue * multiplier)
		if ownerUserId > 0 and ownerUserId ~= player.UserId and amount > 0 then
			result[ownerUserId] = sanitizeCurrency((result[ownerUserId] or 0) + amount)
		end
	end
	return result
end

function EconomyService:_scheduleRecycleSettlement(player, batch)
	batch.Generation += 1
	local generation = batch.Generation
	task.delay(RegionConfig.GameplaySettings.SettlementIdleDuration, function()
		if pendingRecycleBatches[player] == batch and batch.Generation == generation then
			self:FlushRecycleBatch(player)
		end
	end)
end

function EconomyService:_getOrCreateRecycleBatch(player)
	local batch = pendingRecycleBatches[player]
	if batch then
		return batch
	end
	local settlementId = (settlementSequences[player] or 0) + 1
	settlementSequences[player] = settlementId
	batch = {
		Id = settlementId,
		Generation = 0,
		BaseAmount = 0,
	}
	pendingRecycleBatches[player] = batch
	return batch
end

function EconomyService:AwardRecycleCoins(player, bagValue, options)
	local state = self.PlayerDataService:GetState(player)
	if not state or type(bagValue) ~= "number" or bagValue <= 0 then
		return 0, state and state.Coins or 0, nil
	end
	options = type(options) == "table" and options or {
		ShouldPush = options ~= false,
	}

	local multiplier = math.max(0, tonumber(state.LeafValueMultiplier) or tonumber(state.CoinMultiplier) or 1)
	local baseAward = sanitizeCurrency(bagValue * multiplier)
	local _, rewardMultiplier, requestedAward = self.PlayerDataService:CalculateCoinReward(player, baseAward)
	if requestedAward <= 0 then
		return 0, state.Coins, nil
	end

	local friendAmounts = self:_makeFriendAmounts(player, options.SourceValues, multiplier)
	local previousCoins = sanitizeCurrency(state.Coins)
	state.Coins = sanitizeCurrency(previousCoins + requestedAward)
	local awarded = state.Coins - previousCoins
	if awarded ~= requestedAward then
		baseAward = awarded
		rewardMultiplier = 1
	end
	if awarded > 0 then
		self.PlayerDataService:MarkPersistentDirty(player)
		self.PlayerDataService:UpdateLeaderstats(player)
	end
	self:_sendFriendRewards(player, friendAmounts)

	local batch = self:_getOrCreateRecycleBatch(player)
	batch.BaseAmount = sanitizeCurrency(batch.BaseAmount + awarded)
	self:_scheduleRecycleSettlement(player, batch)

	if player.Parent == Players then
		self.PlayerDataService:NotifyCoinGainEvent(player, {
			Phase = "Accumulate",
			SettlementId = batch.Id,
			BaseAmount = baseAward,
			RewardMultiplier = rewardMultiplier,
			Amount = awarded,
			TargetCoins = state.Coins,
			StepCount = options.StepCount,
			FirstStepDelay = options.FirstStepDelay,
			StepInterval = options.StepInterval,
			SoundKind = options.SoundKind,
			SoundCount = options.SoundCount,
			SoundFirstDelay = options.SoundFirstDelay,
			SoundInterval = options.SoundInterval,
			HoldDuration = options.HoldDuration,
			FlyDuration = options.FlyDuration,
		})
		if options.ShouldPush ~= false then
			self.PlayerDataService:PushSnapshot(player)
		end
	end
	return awarded, state.Coins, batch.Id
end

function EconomyService:FlushRecycleBatch(player)
	local batch = pendingRecycleBatches[player]
	if not batch then
		return false, 0
	end
	pendingRecycleBatches[player] = nil

	local state = self.PlayerDataService:GetState(player)
	if not state or batch.BaseAmount <= 0 then
		return false, 0
	end
	if player.Parent == Players then
		self.PlayerDataService:NotifyCoinGainEvent(player, {
			Phase = "Settle",
			SettlementId = batch.Id,
			Amount = 0,
			TargetCoins = state.Coins,
			StepCount = 1,
			FirstStepDelay = 0,
			StepInterval = 0.1,
			HoldDuration = 0,
			FlyDuration = 0.35,
		})
		self.PlayerDataService:PushSnapshot(player)
	end
	return false, 0
end

function EconomyService:TrySpend(player, price)
	local state = self.PlayerDataService:GetState(player)
	if
		not state
		or type(price) ~= "number"
		or price ~= price
		or price == math.huge
		or price == -math.huge
		or price < 0
	then
		return false
	end
	local currentCoins = sanitizeCurrency(state.Coins)
	if currentCoins < price then
		return false
	end

	state.Coins = sanitizeCurrency(currentCoins - price)
	self.PlayerDataService:MarkPersistentDirty(player)
	self.PlayerDataService:UpdateLeaderstats(player)
	return true
end

return EconomyService

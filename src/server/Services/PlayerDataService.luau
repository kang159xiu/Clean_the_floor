local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AdminTestConfig = require(script.Parent.Parent.AdminTestConfig)
local DataResetPolicy = require(script.Parent.Parent.DataResetPolicy)
local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local CoinFlipConfig = require(ReplicatedStorage.Shared.Config.CoinFlipConfig)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local DataResetConfig = require(ReplicatedStorage.Shared.Config.DataResetConfig)
local HandUpgradeConfig = require(ReplicatedStorage.Shared.Config.HandUpgradeConfig)
local LostItemConfig = require(ReplicatedStorage.Shared.Config.LostItemConfig)
local PlayerAttributeConfig = require(ReplicatedStorage.Shared.Config.PlayerAttributeConfig)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)
local ToolUpgradeConfig = require(ReplicatedStorage.Shared.Config.ToolUpgradeConfig)
local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)

local PlayerDataService = {}

local DATASTORE_NAME = "CleanTheFloor_PlayerCollectibles_v1"
local DATA_SCHEMA_VERSION = 31
local ONBOARDING_FUNNEL_VERSION = 1
local ONBOARDING_FUNNEL_MAX_STEP = 10
local CLEAR_SPEEDRUN_VERSION = 2
local MAX_DATASTORE_ATTEMPTS = 3
local AUTOSAVE_INTERVAL = 60
local PERSISTENT_SAVE_DEBOUNCE_SECONDS = 10
local PERSISTENT_SAVE_BUDGET_RETRY_SECONDS = 5
local PERSISTENT_SAVE_RETRY_DELAYS = { 5, 15, 30, 60 }
local MAX_SAVED_COUNT = 1_000_000_000
local MAX_SAVED_CURRENCY = PlayerAttributeConfig.MaximumCurrencyValue
local LEGACY_DIAMOND_TO_COIN_MULTIPLIER = 10
local LEGACY_AREA_REWARD_MASK = 255
local LEGACY_AREA_CAPACITY_BIT = bit32.lshift(1, 6 - 1)
local LEGACY_AREA_CAPACITY_PER_CLAIM = 200

local persistentStore = DataStoreService:GetDataStore(DATASTORE_NAME)
local states = {}
local loadingPlayers = {}
local saveRunning = {}
local saveScheduledStates = {}
local saveTaskTokens = {}
local saveRevisions = {}
local saveRetryAttempts = {}
local coinGainSequences = {}
local playerJoinedClocks = {}
local initialized = false

local areaProgressProvider = function()
	return 0, 0, 0, 0, 0
end

local lostItemProgressProvider = function(_)
	return 0, 0, {}, {}, nil, {}, 0
end

local timedLuckyBoxSnapshotProvider = function(_)
	return nil, false, nil
end

local poopSnapshotProvider = function(_)
	return {}
end

local rebirthStatusProvider = function(_)
	return false, 0, RebirthConfig.GetRainbowPoopRequiredCount(0)
end

local tutorialStateProvider = function(_)
	return nil
end

local coinRewardMultiplierProvider = function(_)
	return 1, true
end

local quickSellOwnershipProvider = function(_)
	return false, false
end

local permanentToolEntitlementProvider = function(_)
	return {}, {}
end

local permanentBagEntitlementProvider = function(_)
	return {}, {}
end

local developerProductEntitlementProvider = function(_)
	return {}, BagConfig.DefaultLevel, false
end

local yardContextProvider = function(player)
	return {
		OwnerUserId = player.UserId,
		OwnerName = player.DisplayName,
		IsVisiting = false,
		Visitors = {},
	}
end

local equippedToolChangedHandler = function() end
local playerStateReadyHandlers = {}

local function makeFreshPersistentData(dataResetDateKey, dataResetNoticeDateKey)
	return DataResetPolicy.MakeFreshPersistentData(
		DATA_SCHEMA_VERSION,
		dataResetDateKey,
		dataResetNoticeDateKey
	)
end

local function preparePersistentDataForCurrentReset(rawData, isNewPlayer)
	local preparedData, resetApplied = DataResetPolicy.PreparePersistentData(
		rawData,
		isNewPlayer,
		DATA_SCHEMA_VERSION,
		DataResetConfig.Enabled,
		DataResetConfig.GetCutoffDateKey()
	)
	if resetApplied and type(rawData) == "table" then
		preparedData.ProcessedSkipRebirthReceiptIds = rawData.ProcessedSkipRebirthReceiptIds
	end
	return preparedData, resetApplied
end

local function getDataKeyFromUserId(userId)
	return string.format("Player_%d", userId)
end

local function getDataKey(player)
	return getDataKeyFromUserId(player.UserId)
end

local function sanitizeWholeNumber(value)
	local numberValue = tonumber(value)
	if not numberValue then
		return 0
	end
	return math.clamp(math.floor(numberValue), 0, MAX_SAVED_COUNT)
end

local function sanitizePositiveSeconds(value)
	local seconds = sanitizeWholeNumber(value)
	return if seconds > 0 then seconds else nil
end

local function sanitizeClearSpeedrun(rawSpeedrun, rebirthCount, startFreshRun)
	local normalizedRebirthCount = RebirthConfig.NormalizeCount(rebirthCount)
	local source = type(rawSpeedrun) == "table" and rawSpeedrun or nil
	local result = {
		Version = CLEAR_SPEEDRUN_VERSION,
		Eligible = false,
		RunRebirthCount = normalizedRebirthCount,
		Completed = false,
		AccumulatedSeconds = 0,
	}
	local sourceVersion = source and math.floor(tonumber(source.Version) or 0) or 0
	local bestSeconds = if sourceVersion == CLEAR_SPEEDRUN_VERSION
		then sanitizePositiveSeconds(source.BestSeconds)
		else nil
	local pendingBestSeconds = if sourceVersion == CLEAR_SPEEDRUN_VERSION
		then sanitizePositiveSeconds(source.PendingBestSeconds)
		else nil
	if bestSeconds then
		result.BestSeconds = bestSeconds
	end
	if pendingBestSeconds then
		result.PendingBestSeconds = pendingBestSeconds
	end
	if startFreshRun == true then
		result.Eligible = true
		return result
	end
	if
		source
		and sourceVersion == 1
		and RebirthConfig.NormalizeCount(source.RunRebirthCount) == normalizedRebirthCount
	then
		-- Preserve eligible legacy Area_08 runs. The OrderedDataStore remains the
		-- authority for historical best times from this version.
		result.Eligible = source.Eligible == true
		result.AccumulatedSeconds = sanitizeWholeNumber(source.AccumulatedSeconds)
		return result
	end
	if
		not source
		or math.floor(tonumber(source.Version) or 0) ~= CLEAR_SPEEDRUN_VERSION
		or RebirthConfig.NormalizeCount(source.RunRebirthCount) ~= normalizedRebirthCount
	then
		-- Existing saves that predate the timer cannot submit a partially completed run.
		return result
	end
	result.Eligible = source.Eligible == true
	result.Completed = result.Eligible and source.Completed == true
	result.AccumulatedSeconds = sanitizeWholeNumber(source.AccumulatedSeconds)
	return result
end

local function retireClearSpeedrunIfFinalAreaWasAlreadyCompleted(speedrun, yardProgress)
	if
		type(speedrun) ~= "table"
		or speedrun.Eligible ~= true
		or speedrun.Completed == true
	then
		return false
	end
	local areas = type(yardProgress) == "table" and yardProgress.Areas or nil
	local finalAreaProgress = type(areas) == "table" and areas[RegionConfig.FinalAreaId] or nil
	local clearedRatio = tonumber(type(finalAreaProgress) == "table" and finalAreaProgress.ClearedRatio) or 0
	if clearedRatio < 1 then
		return false
	end

	-- This run was timed against the temporarily enabled Area_09 target. Once
	-- Area_08 is restored as the finish, its true completion timestamp cannot be
	-- reconstructed, so do not submit the later elapsed time as an Area_08 record.
	speedrun.Eligible = false
	speedrun.Completed = false
	speedrun.SessionStartedClock = nil
	return true
end

local function getClearSpeedrunElapsed(state)
	local speedrun = state and state.ClearSpeedrun
	if type(speedrun) ~= "table" then
		return 0
	end
	local elapsed = math.max(0, tonumber(speedrun.AccumulatedSeconds) or 0)
	local sessionStartedClock = tonumber(speedrun.SessionStartedClock)
	if speedrun.Eligible == true and speedrun.Completed ~= true and sessionStartedClock then
		elapsed += math.max(0, os.clock() - sessionStartedClock)
	end
	return math.clamp(elapsed, 0, MAX_SAVED_COUNT)
end

local function copyClearSpeedrunForSave(state)
	local speedrun = state and state.ClearSpeedrun
	local result = sanitizeClearSpeedrun(speedrun, state and state.RebirthCount, false)
	result.AccumulatedSeconds = sanitizeWholeNumber(math.floor(getClearSpeedrunElapsed(state) + 0.5))
	return result
end

local function startClearSpeedrunSession(state, startedClock)
	local speedrun = state and state.ClearSpeedrun
	if type(speedrun) ~= "table" then
		return
	end
	if speedrun.Eligible == true and speedrun.Completed ~= true then
		speedrun.SessionStartedClock = tonumber(startedClock) or os.clock()
	else
		speedrun.SessionStartedClock = nil
	end
end

local function isClearSpeedrunSessionActive(state)
	local speedrun = state and state.ClearSpeedrun
	return type(speedrun) == "table"
		and speedrun.Eligible == true
		and speedrun.Completed ~= true
		and tonumber(speedrun.SessionStartedClock) ~= nil
end

local function sanitizeCollectedCounts(rawCounts)
	local collectedCounts = {}
	if type(rawCounts) ~= "table" then
		return collectedCounts
	end

	for _, lostItemId in LostItemConfig.Order do
		local count = sanitizeWholeNumber(rawCounts[lostItemId])
		if count > 0 then
			collectedCounts[lostItemId] = count
		end
	end
	return collectedCounts
end

local function copyCollectedCounts(source)
	local copy = {}
	for _, lostItemId in LostItemConfig.Order do
		local count = sanitizeWholeNumber(source[lostItemId])
		if count > 0 then
			copy[lostItemId] = count
		end
	end
	return copy
end

local function sanitizeLuckyBoxOnboarding(rawState, sourceSchemaVersion)
	local normalizedSourceSchemaVersion = math.floor(tonumber(sourceSchemaVersion) or 0)
	if type(rawState) ~= "table" then
		if normalizedSourceSchemaVersion < 29 then
			return {
				LowTierPickupCount = 3,
				HighTierGuaranteePending = false,
				HighTierGuaranteeCompleted = true,
				FirstTimedHighTierBoxSpawned = true,
			}
		end
		return {
			LowTierPickupCount = 0,
			HighTierGuaranteePending = false,
			HighTierGuaranteeCompleted = false,
			FirstTimedHighTierBoxSpawned = false,
		}
	end

	local completed = rawState.HighTierGuaranteeCompleted == true
	local pending = not completed and rawState.HighTierGuaranteePending == true
	local pickupCount = math.clamp(sanitizeWholeNumber(rawState.LowTierPickupCount), 0, 3)
	if completed or pending then
		pickupCount = 3
	end
	return {
		LowTierPickupCount = pickupCount,
		HighTierGuaranteePending = pending,
		HighTierGuaranteeCompleted = completed,
		FirstTimedHighTierBoxSpawned = if normalizedSourceSchemaVersion >= 30
			then rawState.FirstTimedHighTierBoxSpawned == true
			elseif normalizedSourceSchemaVersion >= 29
				then rawState.TimedTier4BoxSpawned == true
				else true,
	}
end

local function copyLuckyBoxOnboarding(source)
	return sanitizeLuckyBoxOnboarding(source, DATA_SCHEMA_VERSION)
end

local function sanitizeLostItemRunProgress(rawProgress, rebirthCount, sourceSchemaVersion, expireUnopened)
	local normalizedRebirthCount = RebirthConfig.NormalizeCount(rebirthCount)
	local normalizedSourceSchemaVersion = math.floor(tonumber(sourceSchemaVersion) or 0)
	local result = {
		RebirthCount = normalizedRebirthCount,
		Areas = {},
	}
	if
		type(rawProgress) ~= "table"
		or RebirthConfig.NormalizeCount(rawProgress.RebirthCount) ~= normalizedRebirthCount
		or type(rawProgress.Areas) ~= "table"
	then
		return result
	end

	for _, areaId in RegionConfig.PersistentOrder do
		local areaConfig = LostItemConfig.Areas[areaId]
		local rawArea = rawProgress.Areas[areaId]
		if areaConfig and type(rawArea) == "table" and type(rawArea.Items) == "table" then
			local items = {}
			for _, rawItem in ipairs(rawArea.Items) do
				local lostItemId = type(rawItem) == "table" and rawItem.LostItemId or nil
				local itemConfig = lostItemId and LostItemConfig.Types[lostItemId] or nil
				local triggerProgress = tonumber(type(rawItem) == "table" and rawItem.TriggerProgress)
				if
					itemConfig
					and itemConfig.PoopOnly ~= true
					and triggerProgress
					and triggerProgress == triggerProgress
					and triggerProgress > -math.huge
					and triggerProgress < math.huge
				then
					local found = rawItem.Found == true
					local redeemed = found and rawItem.Redeemed == true
					local triggered = rawItem.Triggered == true or found or redeemed
					local expired = not found
						and (rawItem.Expired == true
							or (normalizedSourceSchemaVersion < 31 and triggered)
							or (expireUnopened == true and triggered))
					local timedRewardKind = rawItem.TimedRewardKind
					if
						timedRewardKind ~= LostItemConfig.TimedLuckyBox.RewardKinds.First
						and timedRewardKind ~= LostItemConfig.TimedLuckyBox.RewardKinds.Recurring
					then
						timedRewardKind = if rawItem.TimedOnboardingReward == true
							then LostItemConfig.TimedLuckyBox.RewardKinds.First
							else nil
					end
					table.insert(items, {
						LostItemId = lostItemId,
						TriggerProgress = math.clamp(triggerProgress, 0, 1),
						Triggered = triggered or expired,
						Found = found,
						Redeemed = redeemed,
						Expired = expired,
						Guaranteed = rawItem.Guaranteed == true,
						TimedRewardKind = timedRewardKind,
					})
				end
			end
			if #items > 0 then
				local baseSpawnCount = math.clamp(
					sanitizeWholeNumber(rawArea.BaseSpawnCount),
					areaConfig.MinimumSpawnCount,
					areaConfig.MaximumSpawnCount
				)
				result.Areas[areaId] = {
					BaseSpawnCount = baseSpawnCount,
					Items = items,
				}
			end
		end
	end
	return result
end

local function copyLostItemRunProgress(source, rebirthCount)
	return sanitizeLostItemRunProgress(source, rebirthCount, DATA_SCHEMA_VERSION, true)
end

local function sanitizeCodexClaimedTiers(rawTiers)
	local claimedTiers = {}
	if type(rawTiers) ~= "table" then
		return claimedTiers
	end

	local maximumTier = #LostItemConfig.CodexMilestones
	for _, lostItemId in LostItemConfig.Order do
		local tier = math.min(sanitizeWholeNumber(rawTiers[lostItemId]), maximumTier)
		if tier > 0 then
			claimedTiers[lostItemId] = tier
		end
	end
	return claimedTiers
end

local function copyCodexClaimedTiers(source)
	return sanitizeCodexClaimedTiers(source)
end

local function sanitizeCoins(value)
	local numberValue = tonumber(value)
	if
		not numberValue
		or numberValue ~= numberValue
		or numberValue == math.huge
		or numberValue == -math.huge
	then
		return 0
	end
	return math.clamp(math.floor(numberValue), 0, MAX_SAVED_CURRENCY)
end

local function makeDefaultCoinFlipProgress()
	return {
		GuaranteedHeadsRemaining = CoinFlipConfig.InitialGuaranteedHeads,
		MissesSinceHeads = 0,
		PityThreshold = math.random(
			CoinFlipConfig.MinimumPityThreshold,
			CoinFlipConfig.MaximumPityThreshold
		),
	}
end

local function sanitizeCoinFlipProgress(rawProgress, sourceSchemaVersion)
	if type(rawProgress) ~= "table" then
		if math.floor(tonumber(sourceSchemaVersion) or 0) >= DATA_SCHEMA_VERSION then
			return makeDefaultCoinFlipProgress()
		end
		-- Existing players do not receive the new-player-only first two guaranteed wins.
		local progress = makeDefaultCoinFlipProgress()
		progress.GuaranteedHeadsRemaining = 0
		return progress
	end
	return {
		GuaranteedHeadsRemaining = math.clamp(
			sanitizeWholeNumber(rawProgress.GuaranteedHeadsRemaining),
			0,
			CoinFlipConfig.InitialGuaranteedHeads
		),
		MissesSinceHeads = math.clamp(
			sanitizeWholeNumber(rawProgress.MissesSinceHeads),
			0,
			CoinFlipConfig.MaximumPityThreshold
		),
		PityThreshold = math.clamp(
			sanitizeWholeNumber(rawProgress.PityThreshold),
			CoinFlipConfig.MinimumPityThreshold,
			CoinFlipConfig.MaximumPityThreshold
		),
	}
end

local function copyCoinFlipProgress(rawProgress)
	return sanitizeCoinFlipProgress(rawProgress, DATA_SCHEMA_VERSION)
end

local function sanitizePendingCoinFlip(rawPending)
	if type(rawPending) ~= "table" then
		return nil
	end
	local transactionId = rawPending.TransactionId
	local wager = sanitizeCoins(rawPending.Wager)
	local settlementUnixMillis = math.floor(tonumber(rawPending.SettlementUnixMillis) or 0)
	local landingSeed = math.floor(tonumber(rawPending.LandingSeed) or 0)
	if
		type(transactionId) ~= "string"
		or #transactionId <= 0
		or #transactionId > CoinFlipConfig.MaximumTransactionIdLength
		or wager < CoinFlipConfig.MinimumWager
		or wager % CoinFlipConfig.WagerStep ~= 0
		or settlementUnixMillis <= 0
	then
		return nil
	end
	return {
		TransactionId = transactionId,
		Wager = wager,
		CoinId = CoinFlipConfig.GetCoinId(wager),
		IsHeads = rawPending.IsHeads == true,
		SettlementUnixMillis = settlementUnixMillis,
		LandingSeed = landingSeed,
	}
end

local function copyPendingCoinFlip(rawPending)
	return sanitizePendingCoinFlip(rawPending)
end

local function migrateLegacyDiamondCurrency(data)
	if type(data) ~= "table" or data.Diamonds == nil then
		return false
	end
	local legacyDiamonds = sanitizeCoins(data.Diamonds)
	data.Coins = sanitizeCoins(sanitizeCoins(data.Coins) + legacyDiamonds * LEGACY_DIAMOND_TO_COIN_MULTIPLIER)
	data.Diamonds = nil
	return true
end

local function migrateRemovedSewerData(data)
	if type(data) ~= "table" then
		return false
	end
	local yardProgress = data.YardProgress
	if type(yardProgress) ~= "table" or yardProgress.UnlockedSewers == nil then
		return false
	end
	yardProgress.UnlockedSewers = nil
	return true
end

local function sanitizeBagLevel(value)
	local level = sanitizeWholeNumber(value)
	return math.clamp(level, BagConfig.DefaultLevel, #BagConfig.Levels)
end

local function sanitizeBagExpansionLevel(value)
	return BagConfig.NormalizeExpansionLevel(value)
end

local function sanitizeUnlockedTools(rawTools)
	local unlockedTools = {}
	for _, toolIndex in ToolConfig.Order do
		local tool = ToolConfig.Tools[toolIndex]
		local isGamePassTool = tool.PurchaseKind == "GamePass"
		unlockedTools[tool.Id] = tool.UnlockedByDefault == true
			or (
				not isGamePassTool
				and type(rawTools) == "table"
				and rawTools[tool.Id] == true
			)
	end
	return unlockedTools
end

local function copyUnlockedTools(source)
	return sanitizeUnlockedTools(source)
end

local function sanitizePermanentBagMap(source)
	local result = {}
	for _, bagId in BagConfig.PermanentOrder do
		result[bagId] = BagConfig.IsPermanentBagEnabled(bagId)
			and type(source) == "table"
			and source[bagId] == true
	end
	return result
end

local function sanitizeDeveloperProductToolOwnership(source)
	local result = {}
	for _, productConfigId in ProductConfig.DeveloperProductOrder do
		local product = ProductConfig.DeveloperProducts[productConfigId]
		if product.Kind == "PermanentTool" then
			result[product.ToolId] = type(source) == "table" and source[product.ToolId] == true
		end
	end
	return result
end

local function sanitizeDeveloperProductBagLevel(value)
	local level = math.clamp(
		math.floor(tonumber(value) or BagConfig.DefaultLevel),
		BagConfig.DefaultLevel,
		BagConfig.MaxLevel
	)
	if level <= BagConfig.DefaultLevel then
		return BagConfig.DefaultLevel
	end
	for candidateLevel = level, BagConfig.DefaultLevel + 1, -1 do
		if ProductConfig.DeveloperProductsByBagLevel[candidateLevel] then
			return candidateLevel
		end
	end
	return BagConfig.DefaultLevel
end

local function applyDeveloperProductValues(state, toolOwnership, minimumBagLevel, ready)
	if not state then
		return false, false, false
	end
	state.DeveloperProductEntitlementsReady = ready == true
	if ready ~= true then
		return false, false, false
	end

	local normalizedTools = sanitizeDeveloperProductToolOwnership(toolOwnership)
	local normalizedBagLevel = sanitizeDeveloperProductBagLevel(minimumBagLevel)
	local toolChanged = false
	for toolId, owned in normalizedTools do
		if owned and state.UnlockedTools[toolId] ~= true then
			state.UnlockedTools[toolId] = true
			toolChanged = true
		end
	end
	local bagChanged = state.BagLevel < normalizedBagLevel
	if bagChanged then
		state.BagLevel = normalizedBagLevel
	end
	state.DeveloperProductToolOwnership = normalizedTools
	state.DeveloperProductMinimumBagLevel = normalizedBagLevel
	return toolChanged or bagChanged, toolChanged, bagChanged
end

local function applyDeveloperProductEntitlements(player, state)
	local success, toolOwnership, minimumBagLevel, ready = pcall(
		developerProductEntitlementProvider,
		player
	)
	if not success then
		warn(string.format(
			"Developer Product entitlement provider failed for %s: %s",
			player.Name,
			tostring(toolOwnership)
		))
		state.DeveloperProductEntitlementsReady = false
		return false, false, false
	end
	return applyDeveloperProductValues(state, toolOwnership, minimumBagLevel, ready)
end

local function sanitizeSelectedPermanentBagVisualId(value)
	if type(value) ~= "string" then
		return nil
	end
	if value ~= "bag09" and value ~= "bag010" then
		return nil
	end
	return if BagConfig.IsPermanentBagEnabled(value) then value else nil
end

local function getActivePermanentBagId(state)
	local ownership = state and state.PermanentBagOwnership
	for _, bagId in BagConfig.PermanentPriority do
		if BagConfig.IsPermanentBagEnabled(bagId) and ownership and ownership[bagId] == true then
			return bagId
		end
	end
	return nil
end

local function getStorageBagConfig(state)
	local ownership = state and state.PermanentBagOwnership
	for _, bagId in { "bag010", "bag09" } do
		if BagConfig.IsPermanentBagEnabled(bagId) and ownership and ownership[bagId] == true then
			return BagConfig.PermanentBags[bagId]
		end
	end
	local level = state and state.BagLevel or BagConfig.DefaultLevel
	return BagConfig.Levels[level] or BagConfig.Levels[BagConfig.DefaultLevel]
end

local function getMaximumLoadCapacity(legacyAreaBagCapacityBonus, bagExpansionLevel)
	local maximum = BagConfig.Levels[BagConfig.MaxLevel].Capacity
	for _, bagId in BagConfig.PermanentOrder do
		if BagConfig.IsPermanentBagEnabled(bagId) then
			local capacity = tonumber(BagConfig.PermanentBags[bagId].Capacity)
			if capacity then
				maximum = math.max(maximum, capacity)
			end
		end
	end
	return maximum
		+ sanitizeWholeNumber(legacyAreaBagCapacityBonus)
		+ BagConfig.GetExpansionCapacityBonus(bagExpansionLevel)
end

local function getSafePersistentBagCapacity(state)
	local readiness = state and state.PermanentBagOwnershipReady
	if not readiness or readiness.bag09 ~= true or readiness.bag010 ~= true then
		return getMaximumLoadCapacity(
			state and state.LegacyAreaBagCapacityBonus,
			state and state.BagExpansionLevel
		)
	end
	local config = getStorageBagConfig(state)
	return config.Capacity
		+ sanitizeWholeNumber(state.LegacyAreaBagCapacityBonus)
		+ BagConfig.GetExpansionCapacityBonus(state.BagExpansionLevel)
end

local function applyPermanentToolEntitlements(player, state)
	local success, entitlements, readiness = pcall(permanentToolEntitlementProvider, player)
	if not success then
		warn(string.format(
			"Permanent tool entitlement provider failed for %s: %s",
			player.Name,
			tostring(entitlements)
		))
		entitlements = {}
		readiness = {}
	end
	if type(entitlements) ~= "table" then
		entitlements = {}
	end
	if type(readiness) ~= "table" then
		readiness = {}
	end
	state.PermanentToolOwnershipReady = state.PermanentToolOwnershipReady or {}

	for _, toolIndex in ToolConfig.Order do
		local tool = ToolConfig.Tools[toolIndex]
		if tool.PurchaseKind == "GamePass" then
			state.UnlockedTools[tool.Id] = entitlements[tool.Id] == true
			state.PermanentToolOwnershipReady[tool.Id] = readiness[tool.Id] == true
		end
	end
end

local function applyPermanentBagEntitlements(player, state)
	local success, ownership, readiness = pcall(permanentBagEntitlementProvider, player)
	if not success then
		warn(string.format(
			"Permanent bag entitlement provider failed for %s: %s",
			player.Name,
			tostring(ownership)
		))
		ownership = {}
		readiness = {}
	end
	state.PermanentBagOwnership = sanitizePermanentBagMap(ownership)
	state.PermanentBagOwnershipReady = sanitizePermanentBagMap(readiness)
end

local function applyRuntimeEntitlements(player, state)
	applyPermanentToolEntitlements(player, state)
	applyPermanentBagEntitlements(player, state)
	applyDeveloperProductEntitlements(player, state)
end

local function sanitizeUnlockedAreas(rawAreas)
	local unlockedAreas = {}
	for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
		unlockedAreas[string.format("Area_%02d", areaNumber)] = true
	end
	if type(rawAreas) == "table" then
		for areaNumber = RegionConfig.DefaultUnlockedAreaCount + 1, RegionConfig.PersistentAreaCount do
			local areaId = string.format("Area_%02d", areaNumber)
			local previousAreaId = string.format("Area_%02d", areaNumber - 1)
			if rawAreas[areaId] == true and unlockedAreas[previousAreaId] == true then
				unlockedAreas[areaId] = true
			else
				break
			end
		end
	end
	return unlockedAreas
end

local function copyUnlockedAreas(source)
	return sanitizeUnlockedAreas(source)
end

local function copyActiveUnlockedAreas(source)
	local unlockedAreas = {}
	local rawAreas = type(source) == "table" and source or {}
	for _, areaId in RegionConfig.Order do
		if rawAreas[areaId] == true then
			unlockedAreas[areaId] = true
		end
	end
	return unlockedAreas
end

local function sanitizeHandUpgradeLevels(rawLevels)
	local levels = {}
	for _, attributeId in HandUpgradeConfig.Order do
		levels[attributeId] = HandUpgradeConfig.NormalizeLevel(
			attributeId,
			type(rawLevels) == "table" and rawLevels[attributeId] or nil
		)
	end
	return levels
end

local function copyHandUpgradeLevels(source)
	return sanitizeHandUpgradeLevels(source)
end

local function isValidTutorialAreaId(areaId)
	return type(areaId) == "string"
		and string.match(areaId, "^Area_%d%d$") ~= nil
		and RegionConfig[areaId] ~= nil
end

local function sanitizeTutorialProgress(rawProgress, tutorialCompleted, handUpgradeLevels)
	local progress = type(rawProgress) == "table" and rawProgress or {}
	local minimumStep = TutorialConfig.Steps.CleanLeaves
	local maximumStep = TutorialConfig.Steps.Complete
	local step = math.clamp(math.floor(tonumber(progress.Step) or minimumStep), minimumStep, maximumStep)
	if tutorialCompleted == true then
		step = maximumStep
	end

	local leafGoal = math.max(1, math.floor(tonumber(TutorialConfig.LeafGoal) or 1))
	local rawLeafCount = math.max(0, math.floor(tonumber(progress.LeafCount) or 0))
	local leafCount = math.clamp(rawLeafCount, 0, leafGoal)
	-- Older saves can still be on the clean-leaves step with 15-19 leaves
	-- because the previous tutorial goal was 20. Advance them without requiring
	-- another pickup after the goal is lowered.
	if step == TutorialConfig.Steps.CleanLeaves and rawLeafCount >= leafGoal then
		step = TutorialConfig.Steps.RecycleLeaves
	end
	if step > TutorialConfig.Steps.CleanLeaves then
		leafCount = leafGoal
	end

	local targetAreaId = isValidTutorialAreaId(progress.TargetAreaId) and progress.TargetAreaId or nil
	if step == TutorialConfig.Steps.RecycleLeaves and not targetAreaId then
		targetAreaId = TutorialConfig.UpgradeAreaId
	end

	local amountLevel = HandUpgradeConfig.NormalizeLevel(
		TutorialConfig.AmountAttributeId,
		type(handUpgradeLevels) == "table" and handUpgradeLevels[TutorialConfig.AmountAttributeId] or nil
	)
	local speedLevel = HandUpgradeConfig.NormalizeLevel(
		TutorialConfig.SpeedAttributeId,
		type(handUpgradeLevels) == "table" and handUpgradeLevels[TutorialConfig.SpeedAttributeId] or nil
	)
	local amountUpgradeSucceeded = progress.AmountUpgradeSucceeded == true or amountLevel > 0
	local speedUpgradeSucceeded = progress.SpeedUpgradeSucceeded == true or speedLevel > 0
	local secondRecycleSucceeded = progress.SecondRecycleSucceeded == true
	local hasLegacyPhoneProgress = progress.PhonePicked ~= nil
	-- Old step 5 meant the removed phone interlude had elapsed, not that a second
	-- recycle happened. Require one successful sale after migration.
	if hasLegacyPhoneProgress and step >= TutorialConfig.Steps.WaitForSecondRecycle and speedUpgradeSucceeded then
		step = TutorialConfig.Steps.Complete
	elseif step == TutorialConfig.Steps.UpgradeSpeed and not secondRecycleSucceeded and not speedUpgradeSucceeded then
		step = TutorialConfig.Steps.WaitForSecondRecycle
	elseif step == TutorialConfig.Steps.WaitForSecondRecycle and secondRecycleSucceeded then
		step = TutorialConfig.Steps.UpgradeSpeed
	end
	local bagGuidancePending = progress.BagGuidancePending == true

	return {
		Step = step,
		LeafCount = leafCount,
		TargetAreaId = targetAreaId,
		AmountUpgradeSucceeded = amountUpgradeSucceeded,
		SpeedUpgradeSucceeded = speedUpgradeSucceeded,
		SecondRecycleSucceeded = secondRecycleSucceeded,
		BagGuidancePending = bagGuidancePending,
		BagGuidanceReady = bagGuidancePending and progress.BagGuidanceReady == true,
	}
end

local function copyTutorialProgress(source, handUpgradeLevels)
	return sanitizeTutorialProgress(source, false, handUpgradeLevels)
end

local function sanitizeOnboardingFunnel(rawFunnel, naturalNewPlayer)
	local source = type(rawFunnel) == "table" and rawFunnel or nil
	local versionMatches = source
		and math.floor(tonumber(source.Version) or 0) == ONBOARDING_FUNNEL_VERSION
	local eligible = if versionMatches
		then source.Eligible == true
		else naturalNewPlayer == true
	local leafGoal = math.max(1, math.floor(tonumber(TutorialConfig.LeafGoal) or 1))
	local poopGuidanceCompleted = source ~= nil and source.PoopGuidanceCompleted == true
	local broomGuidanceCompleted = source ~= nil and source.BroomGuidanceCompleted == true
	return {
		Version = ONBOARDING_FUNNEL_VERSION,
		Eligible = eligible,
		HighestStep = if eligible
			then math.clamp(
				math.floor(tonumber(source and source.HighestStep) or 0),
				0,
				ONBOARDING_FUNNEL_MAX_STEP
			)
			else 0,
		CollectedLeaves = if eligible
			then math.clamp(
				math.floor(tonumber(source and source.CollectedLeaves) or 0),
				0,
				leafGoal
			)
			else 0,
		HasRecycled = eligible and source ~= nil and source.HasRecycled == true,
		-- BagLevel alone cannot distinguish a Coin purchase from a Developer Product grant.
		-- Persist this authority-only flag so an early Lv.1 -> Lv.2 Coin purchase can wait
		-- for the preceding onboarding steps without being lost across sessions.
		OrdinaryBag2Purchased = eligible
			and source ~= nil
			and source.OrdinaryBag2Purchased == true,
		-- UnlockedTools cannot distinguish a Coin purchase from a Developer Product grant.
		-- Keep the Coin purchase authority across sessions when step 10 was completed early.
		BroomPurchasedWithCoins = eligible
			and source ~= nil
			and source.BroomPurchasedWithCoins == true,
		-- This post-tutorial guidance is opt-in only. Missing fields on old saves remain
		-- false, so deploying the feature never backfills players who already own bags.
		PoopGuidancePending = not poopGuidanceCompleted
			and source ~= nil
			and source.PoopGuidancePending == true,
		PoopGuidanceCompleted = poopGuidanceCompleted,
		BroomGuidanceReady = not broomGuidanceCompleted
			and source ~= nil
			and source.BroomGuidanceReady == true,
		BroomGuidanceCompleted = broomGuidanceCompleted,
	}
end

local function copyOnboardingFunnel(source)
	return sanitizeOnboardingFunnel(source, false)
end

local function completeTutorialAfterRebirth(tutorialProgress, onboardingFunnel)
	tutorialProgress.Step = TutorialConfig.Steps.Complete
	tutorialProgress.LeafCount = TutorialConfig.LeafGoal
	tutorialProgress.TargetAreaId = nil
	tutorialProgress.BagGuidancePending = false
	tutorialProgress.BagGuidanceReady = false
	onboardingFunnel.PoopGuidancePending = false
	onboardingFunnel.PoopGuidanceCompleted = true
	onboardingFunnel.BroomGuidanceReady = false
	onboardingFunnel.BroomGuidanceCompleted = true
end

local function sanitizeToolUpgradeLevels(rawLevels)
	local levels = ToolUpgradeConfig.MakeDefaultLevels()
	for toolId, toolUpgrade in ToolUpgradeConfig.Tools do
		local sourceToolLevels = type(rawLevels) == "table" and rawLevels[toolId] or nil
		for _, attributeId in toolUpgrade.Order do
			levels[toolId][attributeId] = ToolUpgradeConfig.NormalizeLevel(
				toolId,
				attributeId,
				type(sourceToolLevels) == "table" and sourceToolLevels[attributeId] or nil
			)
		end
	end
	return levels
end

local function copyToolUpgradeLevels(source)
	return sanitizeToolUpgradeLevels(source)
end

local function sanitizePlayerAttributeLevels(rawLevels)
	local levels = PlayerAttributeConfig.MakeDefaultLevels()
	for _, attributeId in PlayerAttributeConfig.Order do
		levels[attributeId] = PlayerAttributeConfig.NormalizeLevel(
			attributeId,
			type(rawLevels) == "table" and rawLevels[attributeId] or nil
		)
	end
	return levels
end

local function copyPlayerAttributeLevels(source)
	return sanitizePlayerAttributeLevels(source)
end

local function sanitizeYardProgress(rawProgress, legacyUnlockedAreas)
	local progress = type(rawProgress) == "table" and rawProgress or {}
	local unlockedAreas = sanitizeUnlockedAreas(progress.UnlockedAreas or legacyUnlockedAreas)
	local areas = {}
	for _, areaId in RegionConfig.PersistentOrder do
		local rawArea = type(progress.Areas) == "table" and progress.Areas[areaId] or nil
		local ratio = math.clamp(tonumber(type(rawArea) == "table" and rawArea.ClearedRatio) or 0, 0, 1)
		if ratio > 0 or unlockedAreas[areaId] == true then
			areas[areaId] = { ClearedRatio = ratio }
		end
	end
	for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
		local areaId = string.format("Area_%02d", areaNumber)
		areas[areaId] = areas[areaId] or { ClearedRatio = 0 }
	end
	return {
		UnlockedAreas = unlockedAreas,
		Areas = areas,
	}
end

local function copyYardProgress(source)
	return sanitizeYardProgress(source)
end

local function copyActiveYardProgress(source)
	local progress = type(source) == "table" and source or {}
	local activeUnlockedAreas = copyActiveUnlockedAreas(progress.UnlockedAreas)
	local activeAreas = {}
	local rawAreas = type(progress.Areas) == "table" and progress.Areas or {}
	for _, areaId in RegionConfig.Order do
		local rawArea = rawAreas[areaId]
		local ratio = math.clamp(tonumber(type(rawArea) == "table" and rawArea.ClearedRatio) or 0, 0, 1)
		if ratio > 0 or activeUnlockedAreas[areaId] == true then
			activeAreas[areaId] = { ClearedRatio = ratio }
		end
	end
	for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
		local areaId = string.format("Area_%02d", areaNumber)
		activeAreas[areaId] = activeAreas[areaId] or { ClearedRatio = 0 }
	end
	return {
		UnlockedAreas = activeUnlockedAreas,
		Areas = activeAreas,
	}
end

local function sanitizeLegacyAreaRewardClaims(rawClaims)
	local claims = {}
	if type(rawClaims) ~= "table" then
		return claims
	end
	for rawOwnerUserId, rawMask in rawClaims do
		local ownerUserId = tonumber(rawOwnerUserId)
		local mask = math.clamp(math.floor(tonumber(rawMask) or 0), 0, LEGACY_AREA_REWARD_MASK)
		if ownerUserId and ownerUserId > 0 and mask > 0 then
			claims[tostring(math.floor(ownerUserId))] = mask
		end
	end
	return claims
end

local function addCompletedHomeAreaCapacityClaim(claims, yardProgress, ownerUserId)
	local areaProgress = yardProgress.Areas.Area_06
	if not areaProgress or tonumber(areaProgress.ClearedRatio) < 1 then
		return
	end
	local ownerKey = tostring(ownerUserId)
	local mask = claims[ownerKey] or 0
	claims[ownerKey] = bit32.bor(mask, LEGACY_AREA_CAPACITY_BIT)
end

local function migrateLegacyAreaBagCapacityBonus(data, yardProgress, ownerUserId)
	local hadLegacyClaims = data.AreaRewardClaims ~= nil
	local rawStoredBonus = data.LegacyAreaBagCapacityBonus
	if rawStoredBonus ~= nil then
		local bonus = sanitizeWholeNumber(rawStoredBonus)
		data.LegacyAreaBagCapacityBonus = bonus
		data.AreaRewardClaims = nil
		return bonus, hadLegacyClaims or bonus ~= rawStoredBonus
	end

	local claims = sanitizeLegacyAreaRewardClaims(data.AreaRewardClaims)
	addCompletedHomeAreaCapacityClaim(claims, yardProgress, ownerUserId)
	local claimCount = 0
	for _, mask in claims do
		if bit32.band(mask, LEGACY_AREA_CAPACITY_BIT) ~= 0 then
			claimCount += 1
		end
	end
	local bonus = sanitizeWholeNumber(claimCount * LEGACY_AREA_CAPACITY_PER_CLAIM)
	data.LegacyAreaBagCapacityBonus = bonus
	data.AreaRewardClaims = nil
	return bonus, true
end

local function calculateEffectiveModifiers(rawPlayerAttributeLevels, rebirthCount)
	local levels = sanitizePlayerAttributeLevels(rawPlayerAttributeLevels)
	local personalMoveSpeedBonus = levels.MoveSpeed
	local personalLeafValueMultiplier = 1
		+ levels.LeafValue * PlayerAttributeConfig.Attributes.LeafValue.ValuePerLevel
	local rebirthLeafValueMultiplier = RebirthConfig.GetLeafValueMultiplier(rebirthCount)
	local baseWalkSpeed = RegionConfig.GameplaySettings.BaseWalkSpeed
	local walkSpeed = math.min(
		PlayerAttributeConfig.MaximumWalkSpeed,
		baseWalkSpeed + personalMoveSpeedBonus
	)
	local leafValueMultiplier = personalLeafValueMultiplier
		* rebirthLeafValueMultiplier
	return {
		LeafValueMultiplier = leafValueMultiplier,
		PersonalLeafValueMultiplier = personalLeafValueMultiplier,
		RebirthLeafValueMultiplier = rebirthLeafValueMultiplier,
		MoveSpeedBonus = walkSpeed - baseWalkSpeed,
		PersonalMoveSpeedBonus = personalMoveSpeedBonus,
		WalkSpeed = walkSpeed,
	}
end

local function sanitizeBagSourceValues(rawSources, currentBagValue, fallbackOwnerUserId)
	local normalized = {}
	if type(rawSources) == "table" then
		for rawUserId, rawValue in rawSources do
			local userId = tonumber(rawUserId)
			local value = sanitizeWholeNumber(rawValue)
			if userId and userId > 0 and value > 0 then
				normalized[tostring(math.floor(userId))] = value
			end
		end
	end

	local keys = {}
	for userId in normalized do
		table.insert(keys, userId)
	end
	table.sort(keys)

	local remaining = sanitizeWholeNumber(currentBagValue)
	local result = {}
	for _, userId in keys do
		if remaining <= 0 then
			break
		end
		local kept = math.min(normalized[userId], remaining)
		if kept > 0 then
			result[userId] = kept
			remaining -= kept
		end
	end
	if remaining > 0 and fallbackOwnerUserId and fallbackOwnerUserId > 0 then
		local fallbackKey = tostring(math.floor(fallbackOwnerUserId))
		result[fallbackKey] = (result[fallbackKey] or 0) + remaining
	end
	return result
end

local function copyBagSourceValues(source, currentBagValue, fallbackOwnerUserId)
	return sanitizeBagSourceValues(source, currentBagValue, fallbackOwnerUserId)
end

local function sanitizeFriendRewardContributors(rawContributors)
	local contributors = {}
	if type(rawContributors) ~= "table" then
		return contributors
	end
	local count = 0
	for rawUserId, rawData in rawContributors do
		if count >= 50 then
			break
		end
		local userId = tonumber(rawUserId)
		local amount = type(rawData) == "table" and sanitizeCoins(rawData.Amount) or 0
		if userId and userId > 0 and amount > 0 then
			local name = type(rawData.Name) == "string" and string.sub(rawData.Name, 1, 32) or "Player"
			contributors[tostring(math.floor(userId))] = {
				Amount = amount,
				Name = name,
			}
			count += 1
		end
	end
	return contributors
end

local function sanitizePendingFriendRewards(rawRewards)
	local rewards = type(rawRewards) == "table" and rawRewards or {}
	return {
		TotalAmount = sanitizeCoins(rewards.TotalAmount),
		Contributors = sanitizeFriendRewardContributors(rewards.Contributors),
	}
end

local function copyPendingFriendRewards(source)
	return sanitizePendingFriendRewards(source)
end

local function makeFriendRewardContributorList(source)
	local sanitized = sanitizePendingFriendRewards(source)
	local list = {}
	for rawUserId, contributor in sanitized.Contributors do
		table.insert(list, {
			UserId = tonumber(rawUserId),
			Name = contributor.Name,
			Amount = contributor.Amount,
		})
	end
	table.sort(list, function(left, right)
		if left.Amount == right.Amount then
			return left.UserId < right.UserId
		end
		return left.Amount > right.Amount
	end)
	return sanitized.TotalAmount, list
end

local function sanitizeStringList(rawList, maximumCount)
	local result = {}
	if type(rawList) ~= "table" then
		return result
	end
	for _, value in rawList do
		if #result >= maximumCount then
			break
		end
		if type(value) == "string" and #value > 0 and #value <= 128 then
			table.insert(result, value)
		end
	end
	return result
end

local function sanitizePendingFriendDeliveries(rawDeliveries)
	local result = {}
	if type(rawDeliveries) ~= "table" then
		return result
	end
	for _, rawDelivery in rawDeliveries do
		if #result >= 50 then
			break
		end
		if type(rawDelivery) == "table" then
			local transactionId = rawDelivery.TransactionId
			local ownerUserId = sanitizeWholeNumber(rawDelivery.OwnerUserId)
			local amount = sanitizeCoins(rawDelivery.Amount)
			if type(transactionId) == "string" and #transactionId <= 96 and ownerUserId > 0 and amount > 0 then
				table.insert(result, {
					TransactionId = transactionId,
					OwnerUserId = ownerUserId,
					Amount = amount,
					HelperUserId = sanitizeWholeNumber(rawDelivery.HelperUserId),
					HelperName = type(rawDelivery.HelperName) == "string"
						and string.sub(rawDelivery.HelperName, 1, 32)
						or "Player",
				})
			end
		end
	end
	return result
end

local function hasProcessedReward(processedIds, transactionId)
	for _, processedId in processedIds do
		if processedId == transactionId then
			return true
		end
	end
	return false
end

local function appendProcessedReward(processedIds, transactionId)
	if hasProcessedReward(processedIds, transactionId) then
		return false
	end
	table.insert(processedIds, transactionId)
	while #processedIds > 200 do
		table.remove(processedIds, 1)
	end
	return true
end

local function makeDefaultState(
	persistentData,
	persistentDataAvailable,
	playerUserId,
	naturalNewPlayer,
	startFreshClearSpeedrun
)
	local data = persistentData or {}
	local dataResetDateKey = DataResetConfig.NormalizeStoredDateKey(data.DataResetDateKey)
	local dataResetNoticeDateKey = DataResetConfig.NormalizeStoredDateKey(data.DataResetNoticeDateKey)
	local migratedLegacyDiamonds = migrateLegacyDiamondCurrency(data)
	local removedLegacySewers = migrateRemovedSewerData(data)
	local bagLevel = sanitizeBagLevel(data.BagLevel)
	local bagExpansionLevel = sanitizeBagExpansionLevel(data.BagExpansionLevel)
	local yardProgress = sanitizeYardProgress(data.YardProgress, data.UnlockedAreas)
	local legacyAreaBagCapacityBonus, migratedLegacyAreaRewards = migrateLegacyAreaBagCapacityBonus(
		data,
		yardProgress,
		playerUserId
	)
	local playerAttributeLevels = sanitizePlayerAttributeLevels(data.PlayerAttributeLevels)
	local rebirthCount = RebirthConfig.NormalizeCount(data.RebirthCount)
	local lostItemRunProgress = sanitizeLostItemRunProgress(
		data.LostItemRunProgress,
		rebirthCount,
		data.SchemaVersion,
		false
	)
	local luckyBoxOnboarding = sanitizeLuckyBoxOnboarding(data.LuckyBoxOnboarding, data.SchemaVersion)
	local effectiveModifiers = calculateEffectiveModifiers(
		playerAttributeLevels,
		rebirthCount
	)
	-- Permanent bag ownership is verified after the runtime state exists. Preserve a
	-- legitimately larger saved load until those Marketplace queries finish.
	local bagCapacity = getMaximumLoadCapacity(
		legacyAreaBagCapacityBonus,
		bagExpansionLevel
	)
	local currentBagValue = math.clamp(sanitizeWholeNumber(data.CurrentBagValue), 0, bagCapacity)
	local unlockedTools = sanitizeUnlockedTools(data.UnlockedTools)
	local handUpgradeLevels = sanitizeHandUpgradeLevels(data.HandUpgradeLevels)
	local tutorialProgress = sanitizeTutorialProgress(
		data.TutorialProgress,
		data.TutorialCompleted,
		handUpgradeLevels
	)
	local onboardingFunnel = sanitizeOnboardingFunnel(data.OnboardingFunnel, naturalNewPlayer)
	if rebirthCount > 0 then
		completeTutorialAfterRebirth(tutorialProgress, onboardingFunnel)
	end
	local coinFlipProgress = sanitizeCoinFlipProgress(data.CoinFlipProgress, data.SchemaVersion)
	local pendingCoinFlip = sanitizePendingCoinFlip(data.PendingCoinFlip)
	local clearSpeedrun = sanitizeClearSpeedrun(data.ClearSpeedrun, rebirthCount, startFreshClearSpeedrun)
	local retiredClearSpeedrun = retireClearSpeedrunIfFinalAreaWasAlreadyCompleted(clearSpeedrun, yardProgress)
	local lastEquippedTool = type(data.LastEquippedTool) == "string"
		and data.LastEquippedTool
		or ToolConfig.DefaultToolId
	if
		unlockedTools[lastEquippedTool] ~= true
		or not ToolConfig.IsLeafCleaningTool(lastEquippedTool)
	then
		lastEquippedTool = ToolConfig.DefaultToolId
	end
	return {
		DataResetDateKey = dataResetDateKey,
		DataResetNoticeDateKey = dataResetNoticeDateKey,
		DataResetNoticePending = dataResetDateKey ~= nil
			and (not dataResetNoticeDateKey or dataResetNoticeDateKey < dataResetDateKey),
		Coins = sanitizeCoins(data.Coins),
		BagLevel = bagLevel,
		BagExpansionLevel = bagExpansionLevel,
		CurrentBagValue = currentBagValue,
		BagCycleId = math.max(1, sanitizeWholeNumber(data.BagCycleId)),
		BagSourceValues = sanitizeBagSourceValues(data.BagSourceValues, currentBagValue, playerUserId),
		BagFullNotified = false,
		PermanentBagOwnership = sanitizePermanentBagMap(nil),
		PermanentBagOwnershipReady = sanitizePermanentBagMap(nil),
		PermanentToolOwnershipReady = {},
		DeveloperProductEntitlementsReady = false,
		DeveloperProductToolOwnership = sanitizeDeveloperProductToolOwnership(nil),
		DeveloperProductMinimumBagLevel = BagConfig.DefaultLevel,
		SelectedPermanentBagVisualId = sanitizeSelectedPermanentBagVisualId(data.SelectedPermanentBagVisualId),
		UnlockedTools = unlockedTools,
		UnlockedAreas = yardProgress.UnlockedAreas,
		YardProgress = yardProgress,
		LegacyAreaBagCapacityBonus = legacyAreaBagCapacityBonus,
		ActiveYardOwnerUserId = playerUserId,
		AllowGuestPoop = data.AllowGuestPoop ~= false,
		CommunityRewardClaimed = data.CommunityRewardClaimed == true,
		CurrentAreaId = "Area_01",
		EquippedTool = lastEquippedTool,
		LastEquippedTool = lastEquippedTool,
		TutorialCompleted = tutorialProgress.Step == TutorialConfig.Steps.Complete,
		TutorialProgress = tutorialProgress,
		OnboardingFunnel = onboardingFunnel,
		CoinFlipProgress = coinFlipProgress,
		PendingCoinFlip = pendingCoinFlip,
		ClearSpeedrun = clearSpeedrun,
		CoinMultiplier = effectiveModifiers.LeafValueMultiplier,
		LeafValueMultiplier = effectiveModifiers.LeafValueMultiplier,
		PersonalLeafValueMultiplier = effectiveModifiers.PersonalLeafValueMultiplier,
		RebirthLeafValueMultiplier = effectiveModifiers.RebirthLeafValueMultiplier,
		MoveSpeedBonus = effectiveModifiers.MoveSpeedBonus,
		WalkSpeed = effectiveModifiers.WalkSpeed,
		PlayerAttributeLevels = playerAttributeLevels,
		PurchasedProducts = {},
		HandUpgradeLevels = handUpgradeLevels,
		ToolUpgradeLevels = sanitizeToolUpgradeLevels(data.ToolUpgradeLevels),
		PendingFriendRewards = sanitizePendingFriendRewards(data.PendingFriendRewards),
		ProcessedFriendRewardIds = sanitizeStringList(data.ProcessedFriendRewardIds, 200),
		ProcessedSkipRebirthReceiptIds = sanitizeStringList(
			data.ProcessedSkipRebirthReceiptIds,
			200
		),
		PendingFriendDeliveries = sanitizePendingFriendDeliveries(data.PendingFriendDeliveries),
		RebirthCount = rebirthCount,
		RainbowPoopFoundCount = math.min(
			sanitizeWholeNumber(data.RainbowPoopFoundCount),
			RebirthConfig.GetRainbowPoopRequiredCount(rebirthCount)
		),
		LostItemRunProgress = lostItemRunProgress,
		LuckyBoxOnboarding = luckyBoxOnboarding,
		CollectedCounts = sanitizeCollectedCounts(persistentData and persistentData.CollectedCounts),
		CodexClaimedTiers = sanitizeCodexClaimedTiers(persistentData and persistentData.CodexClaimedTiers),
		PersistentDataAvailable = persistentDataAvailable,
		PersistentDirty = migratedLegacyDiamonds
			or removedLegacySewers
			or migratedLegacyAreaRewards
			or retiredClearSpeedrun
			or tonumber(data.SchemaVersion) ~= DATA_SCHEMA_VERSION
			or type(data.PlayerAttributeLevels) ~= "table"
			or (type(data.PlayerAttributeLevels) == "table" and data.PlayerAttributeLevels.Luck ~= nil)
			or type(data.TutorialProgress) ~= "table"
			or (type(data.TutorialProgress) == "table" and data.TutorialProgress.PhonePicked ~= nil)
			or (
				type(data.TutorialProgress) == "table"
				and data.TutorialProgress.SecondRecycleSucceeded == nil
			)
			or type(data.OnboardingFunnel) ~= "table"
			or type(data.ClearSpeedrun) ~= "table"
			or type(data.LostItemRunProgress) ~= "table"
			or type(data.LuckyBoxOnboarding) ~= "table"
			or (
				type(data.LuckyBoxOnboarding) == "table"
				and type(data.LuckyBoxOnboarding.FirstTimedHighTierBoxSpawned) ~= "boolean"
			)
			or type(data.RainbowPoopFoundCount) ~= "number"
			or type(data.BagExpansionLevel) ~= "number"
			or type(data.CommunityRewardClaimed) ~= "boolean"
			or type(data.ProcessedSkipRebirthReceiptIds) ~= "table"
			or type(data.CoinFlipProgress) ~= "table"
			or (data.PendingCoinFlip ~= nil and pendingCoinFlip == nil),
		PersistentResetRequested = false,
		PersistentResetInProgress = false,
		PersistentResetCompleted = false,
	}
end

local function ensureLeaderstats(player, state)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end

	local coins = leaderstats:FindFirstChild("Coins")
	if coins and not coins:IsA("NumberValue") then
		coins:Destroy()
		coins = nil
	end
	if not coins then
		coins = Instance.new("NumberValue")
		coins.Name = "Coins"
		coins.Parent = leaderstats
	end
	coins.Value = state.Coins
end

local function syncPlayerWalkSpeed(player, state, character)
	character = character or player.Character
	if not state or not character or player.Character ~= character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = math.min(
			PlayerAttributeConfig.MaximumWalkSpeed,
			math.max(0, tonumber(state.WalkSpeed) or RegionConfig.GameplaySettings.BaseWalkSpeed)
		)
	end
end

function PlayerDataService:_loadPersistentData(player)
	local lastError = nil
	for attempt = 1, MAX_DATASTORE_ATTEMPTS do
		local success, result = pcall(function()
			return persistentStore:GetAsync(getDataKey(player))
		end)
		if success then
			if type(result) == "table" then
				return result, true, false
			end
			return makeFreshPersistentData(), true, true
		end

		lastError = result
		if attempt < MAX_DATASTORE_ATTEMPTS then
			task.wait(attempt)
		end
	end

	if RunService:IsStudio() then
		return makeFreshPersistentData(), false, true
	end

	warn(string.format("Persistent data load failed for %s: %s", player.Name, tostring(lastError)))
	return nil, false, false
end

function PlayerDataService:_savePersistentData(player, state, maximumAttempts)
	if not state.PersistentDataAvailable or state.PersistentResetRequested then
		return true
	end
	local attemptLimit = math.clamp(
		math.floor(tonumber(maximumAttempts) or MAX_DATASTORE_ATTEMPTS),
		1,
		MAX_DATASTORE_ATTEMPTS
	)

	local payload = {
		SchemaVersion = DATA_SCHEMA_VERSION,
		DataResetDateKey = DataResetConfig.NormalizeStoredDateKey(state.DataResetDateKey),
		DataResetNoticeDateKey = DataResetConfig.NormalizeStoredDateKey(state.DataResetNoticeDateKey),
		Coins = sanitizeCoins(state.Coins),
		BagLevel = sanitizeBagLevel(state.BagLevel),
		BagExpansionLevel = sanitizeBagExpansionLevel(state.BagExpansionLevel),
		CurrentBagValue = math.clamp(
			sanitizeWholeNumber(state.CurrentBagValue),
			0,
			getSafePersistentBagCapacity(state)
		),
		BagCycleId = math.max(1, sanitizeWholeNumber(state.BagCycleId)),
		BagSourceValues = copyBagSourceValues(
			state.BagSourceValues,
			state.CurrentBagValue,
			player.UserId
		),
		SelectedPermanentBagVisualId = sanitizeSelectedPermanentBagVisualId(state.SelectedPermanentBagVisualId),
		AllowGuestPoop = state.AllowGuestPoop ~= false,
		CommunityRewardClaimed = state.CommunityRewardClaimed == true,
		UnlockedTools = copyUnlockedTools(state.UnlockedTools),
		UnlockedAreas = copyUnlockedAreas(state.UnlockedAreas),
		HandUpgradeLevels = copyHandUpgradeLevels(state.HandUpgradeLevels),
		ToolUpgradeLevels = copyToolUpgradeLevels(state.ToolUpgradeLevels),
		PlayerAttributeLevels = copyPlayerAttributeLevels(state.PlayerAttributeLevels),
		LegacyAreaBagCapacityBonus = sanitizeWholeNumber(state.LegacyAreaBagCapacityBonus),
		LastEquippedTool = state.UnlockedTools[state.LastEquippedTool] == true
			and ToolConfig.IsLeafCleaningTool(state.LastEquippedTool)
			and state.LastEquippedTool
			or ToolConfig.DefaultToolId,
		TutorialCompleted = state.TutorialProgress.Step == TutorialConfig.Steps.Complete,
		TutorialProgress = copyTutorialProgress(state.TutorialProgress, state.HandUpgradeLevels),
		OnboardingFunnel = copyOnboardingFunnel(state.OnboardingFunnel),
		CoinFlipProgress = copyCoinFlipProgress(state.CoinFlipProgress),
		PendingCoinFlip = copyPendingCoinFlip(state.PendingCoinFlip),
		ClearSpeedrun = copyClearSpeedrunForSave(state),
		YardProgress = copyYardProgress({
			UnlockedAreas = state.UnlockedAreas,
			Areas = state.YardProgress and state.YardProgress.Areas or {},
		}),
		PendingFriendRewards = copyPendingFriendRewards(state.PendingFriendRewards),
		ProcessedFriendRewardIds = sanitizeStringList(state.ProcessedFriendRewardIds, 200),
		ProcessedSkipRebirthReceiptIds = sanitizeStringList(
			state.ProcessedSkipRebirthReceiptIds,
			200
		),
		PendingFriendDeliveries = sanitizePendingFriendDeliveries(state.PendingFriendDeliveries),
		RebirthCount = RebirthConfig.NormalizeCount(state.RebirthCount),
		RainbowPoopFoundCount = math.min(
			sanitizeWholeNumber(state.RainbowPoopFoundCount),
			RebirthConfig.GetRainbowPoopRequiredCount(state.RebirthCount)
		),
		LostItemRunProgress = copyLostItemRunProgress(state.LostItemRunProgress, state.RebirthCount),
		LuckyBoxOnboarding = copyLuckyBoxOnboarding(state.LuckyBoxOnboarding),
		CollectedCounts = copyCollectedCounts(state.CollectedCounts),
		CodexClaimedTiers = copyCodexClaimedTiers(state.CodexClaimedTiers),
	}
	local lastError = nil

	for attempt = 1, attemptLimit do
		local success, result = pcall(function()
			return persistentStore:UpdateAsync(getDataKey(player), function()
				return payload
			end)
		end)
		if success then
			return true
		end

		lastError = result
		if attempt < attemptLimit then
			task.wait(attempt)
		end
	end

	warn(string.format("Persistent data save failed for %s: %s", player.Name, tostring(lastError)))
	return false
end

function PlayerDataService:_cancelScheduledPersistentSave(player)
	saveTaskTokens[player] = (saveTaskTokens[player] or 0) + 1
	saveScheduledStates[player] = nil
end

function PlayerDataService:_schedulePersistentSave(player, state, delaySeconds)
	if
		states[player] ~= state
		or not state.PersistentDataAvailable
		or state.PersistentResetRequested
		or not state.PersistentDirty
	then
		return
	end
	if saveRunning[player] == state or saveScheduledStates[player] == state then
		return
	end

	local token = (saveTaskTokens[player] or 0) + 1
	saveTaskTokens[player] = token
	saveScheduledStates[player] = state
	task.delay(math.max(0, tonumber(delaySeconds) or 0), function()
		if
			saveTaskTokens[player] ~= token
			or saveScheduledStates[player] ~= state
			or states[player] ~= state
		then
			return
		end
		saveScheduledStates[player] = nil
		self:_runScheduledPersistentSave(player, state)
	end)
end

function PlayerDataService:_runScheduledPersistentSave(player, state)
	if
		states[player] ~= state
		or not state.PersistentDataAvailable
		or state.PersistentResetRequested
		or not state.PersistentDirty
	then
		return
	end
	if saveRunning[player] then
		self:_schedulePersistentSave(player, state, PERSISTENT_SAVE_DEBOUNCE_SECONDS)
		return
	end
	if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) <= 0 then
		self:_schedulePersistentSave(player, state, PERSISTENT_SAVE_BUDGET_RETRY_SECONDS)
		return
	end

	local revision = saveRevisions[player] or 0
	saveRunning[player] = state
	local success = self:_savePersistentData(player, state, 1)
	saveRunning[player] = nil
	if states[player] ~= state then
		return
	end

	if success then
		saveRetryAttempts[player] = 0
		if (saveRevisions[player] or 0) == revision then
			state.PersistentDirty = false
		else
			state.PersistentDirty = true
			self:_schedulePersistentSave(player, state, PERSISTENT_SAVE_DEBOUNCE_SECONDS)
		end
		return
	end

	state.PersistentDirty = true
	local retryAttempt = (saveRetryAttempts[player] or 0) + 1
	saveRetryAttempts[player] = retryAttempt
	local retryDelay = PERSISTENT_SAVE_RETRY_DELAYS[math.min(retryAttempt, #PERSISTENT_SAVE_RETRY_DELAYS)]
	self:_schedulePersistentSave(player, state, retryDelay)
end

function PlayerDataService:QueuePersistentSave(player)
	local state = states[player]
	if not state or not state.PersistentDataAvailable or state.PersistentResetRequested then
		return
	end

	state.PersistentDirty = true
	saveRevisions[player] = (saveRevisions[player] or 0) + 1
	self:_schedulePersistentSave(player, state, PERSISTENT_SAVE_DEBOUNCE_SECONDS)
end

function PlayerDataService:MarkPersistentDirty(player)
	local state = states[player]
	if state and state.PersistentDataAvailable and not state.PersistentResetRequested then
		state.PersistentDirty = true
		saveRevisions[player] = (saveRevisions[player] or 0) + 1
		self:_schedulePersistentSave(player, state, PERSISTENT_SAVE_DEBOUNCE_SECONDS)
	end
end

function PlayerDataService:SavePlayerNow(player)
	local state = states[player]
	if not state then
		return true
	end
	if state.PersistentResetRequested then
		return true
	end
	self:_cancelScheduledPersistentSave(player)
	-- A queued save may already have captured an older payload. Let it finish
	-- before the final synchronous save so it cannot overwrite newer progress.
	while saveRunning[player] and states[player] == state do
		task.wait()
	end
	if states[player] ~= state then
		return true
	end
	self:_cancelScheduledPersistentSave(player)

	local revision = saveRevisions[player] or 0
	saveRunning[player] = state
	local success = self:_savePersistentData(player, state)
	saveRunning[player] = nil
	if states[player] ~= state then
		return success
	end
	if success then
		saveRetryAttempts[player] = 0
		state.PersistentDirty = (saveRevisions[player] or 0) ~= revision
	else
		state.PersistentDirty = true
	end
	if state.PersistentDirty and player.Parent then
		local delaySeconds = PERSISTENT_SAVE_DEBOUNCE_SECONDS
		if not success then
			local retryAttempt = (saveRetryAttempts[player] or 0) + 1
			saveRetryAttempts[player] = retryAttempt
			delaySeconds = PERSISTENT_SAVE_RETRY_DELAYS[math.min(retryAttempt, #PERSISTENT_SAVE_RETRY_DELAYS)]
		end
		self:_schedulePersistentSave(player, state, delaySeconds)
	end
	return success
end

function PlayerDataService:ResetPersistentData(player)
	local state = states[player]
	if not state then
		return false, "Player data is not ready."
	end
	if state.PersistentResetCompleted then
		return true, "Your save is already cleared. You will start over next time you join."
	end
	if state.PersistentResetInProgress then
		return false, "Your save is being cleared. Please wait."
	end
	if not state.PersistentDataAvailable then
		return false, "DataStore is unavailable. Your save was not cleared."
	end

	state.PersistentResetRequested = true
	state.PersistentResetInProgress = true
	state.PersistentDirty = false
	self:_cancelScheduledPersistentSave(player)
	while saveRunning[player] do
		task.wait()
	end
	self:_cancelScheduledPersistentSave(player)
	state.PersistentDirty = false

	local lastError = nil
	for attempt = 1, MAX_DATASTORE_ATTEMPTS do
		local success, result = pcall(function()
			return persistentStore:RemoveAsync(getDataKey(player))
		end)
		if success then
			state.PersistentResetInProgress = false
			state.PersistentResetCompleted = true
			return true, "Save cleared. You will start over next time you join."
		end

		lastError = result
		if attempt < MAX_DATASTORE_ATTEMPTS then
			task.wait(attempt)
		end
	end

	state.PersistentResetRequested = false
	state.PersistentResetInProgress = false
	state.PersistentDirty = true
	if states[player] == state and player.Parent then
		self:QueuePersistentSave(player)
	end
	warn(string.format("Persistent data reset failed for %s: %s", player.Name, tostring(lastError)))
	return false, "Failed to clear your save. Try again later."
end

function PlayerDataService:ResetForAdminTest(player, initialCoins)
	local state = states[player]
	if not state then
		return false, "Player data is not ready."
	end
	if state.PersistentResetRequested or state.PersistentResetInProgress then
		return false, "Data reset is in progress. Please wait."
	end
	if not state.PersistentDataAvailable and not RunService:IsStudio() then
		return false, "DataStore is unavailable. Data was not reset."
	end

	local freshPersistentData = makeFreshPersistentData(
		state.DataResetDateKey,
		state.DataResetNoticeDateKey
	)
	freshPersistentData.Coins = sanitizeCoins(initialCoins)
	freshPersistentData.ProcessedSkipRebirthReceiptIds = sanitizeStringList(
		state.ProcessedSkipRebirthReceiptIds,
		200
	)
	local freshState = makeDefaultState(
		freshPersistentData,
		state.PersistentDataAvailable,
		player.UserId,
		false,
		true
	)
	startClearSpeedrunSession(freshState, os.clock())
	-- Advance the runtime cycle so an old in-flight recycle cannot settle into the fresh state.
	freshState.BagCycleId = math.max(1, sanitizeWholeNumber(state.BagCycleId) + 1)
	freshState.PersistentDirty = false

	local persisted = state.PersistentDataAvailable == true
	if persisted then
		state.PersistentResetRequested = true
		state.PersistentResetInProgress = true
		state.PersistentDirty = false
		self:_cancelScheduledPersistentSave(player)
		while saveRunning[player] do
			task.wait()
		end
		self:_cancelScheduledPersistentSave(player)

		if not self:_savePersistentData(player, freshState) then
			state.PersistentResetRequested = false
			state.PersistentResetInProgress = false
			state.PersistentDirty = true
			self:QueuePersistentSave(player)
			return false, "Data reset failed. Try again later."
		end
	end

	table.clear(state)
	for key, value in freshState do
		state[key] = value
	end
	saveRetryAttempts[player] = 0
	-- Entitlement providers can finish while the reset is saving. Re-read every
	-- provider only after the final runtime table has replaced the old state so a
	-- late result cannot be written into state that is about to be discarded.
	applyRuntimeEntitlements(player, state)
	coinGainSequences[player] = nil

	ensureLeaderstats(player, state)
	syncPlayerWalkSpeed(player, state)
	equippedToolChangedHandler(player, state.EquippedTool)
	return true, persisted
end

function PlayerDataService:ResetForRebirth(player, skipRebirthPurchaseId)
	local state = states[player]
	if not state then
		return false, "Player data is not ready."
	end
	if state.PersistentResetRequested or state.PersistentResetInProgress then
		return false, "Your save is being cleared. Please wait."
	end

	local nextRebirthCount = RebirthConfig.NormalizeCount(state.RebirthCount) + 1
	local nextBagCycleId = math.max(1, sanitizeWholeNumber(state.BagCycleId) + 1)
	local processedSkipRebirthReceiptIds = sanitizeStringList(
		state.ProcessedSkipRebirthReceiptIds,
		200
	)
	if skipRebirthPurchaseId ~= nil then
		if
			type(skipRebirthPurchaseId) ~= "string"
			or #skipRebirthPurchaseId <= 0
			or #skipRebirthPurchaseId > 128
		then
			return false, "Invalid purchase receipt."
		end
		if not appendProcessedReward(processedSkipRebirthReceiptIds, skipRebirthPurchaseId) then
			return false, "This purchase receipt was already applied."
		end
	end
	local completedTutorialProgress = copyTutorialProgress(
		state.TutorialProgress,
		state.HandUpgradeLevels
	)
	local onboardingFunnel = copyOnboardingFunnel(state.OnboardingFunnel)
	-- Rebirth starts a new progression run, not a second onboarding run. Mark every
	-- optional post-tutorial prompt as finished while preserving analytics progress.
	completeTutorialAfterRebirth(completedTutorialProgress, onboardingFunnel)
	local preservedData = {
		SchemaVersion = DATA_SCHEMA_VERSION,
		DataResetDateKey = DataResetConfig.NormalizeStoredDateKey(state.DataResetDateKey),
		DataResetNoticeDateKey = DataResetConfig.NormalizeStoredDateKey(state.DataResetNoticeDateKey),
		RebirthCount = nextRebirthCount,
		AllowGuestPoop = state.AllowGuestPoop ~= false,
		CommunityRewardClaimed = state.CommunityRewardClaimed == true,
		TutorialCompleted = true,
		TutorialProgress = completedTutorialProgress,
		OnboardingFunnel = onboardingFunnel,
		CoinFlipProgress = copyCoinFlipProgress(state.CoinFlipProgress),
		PendingCoinFlip = copyPendingCoinFlip(state.PendingCoinFlip),
		SelectedPermanentBagVisualId = sanitizeSelectedPermanentBagVisualId(state.SelectedPermanentBagVisualId),
		LegacyAreaBagCapacityBonus = sanitizeWholeNumber(state.LegacyAreaBagCapacityBonus),
		ProcessedFriendRewardIds = sanitizeStringList(state.ProcessedFriendRewardIds, 200),
		ProcessedSkipRebirthReceiptIds = processedSkipRebirthReceiptIds,
		PendingFriendDeliveries = sanitizePendingFriendDeliveries(state.PendingFriendDeliveries),
		PlayerAttributeLevels = copyPlayerAttributeLevels(state.PlayerAttributeLevels),
		LuckyBoxOnboarding = copyLuckyBoxOnboarding(state.LuckyBoxOnboarding),
		CollectedCounts = copyCollectedCounts(state.CollectedCounts),
		CodexClaimedTiers = copyCodexClaimedTiers(state.CodexClaimedTiers),
		ClearSpeedrun = {
			Version = CLEAR_SPEEDRUN_VERSION,
			Eligible = true,
			RunRebirthCount = nextRebirthCount,
			Completed = false,
			AccumulatedSeconds = 0,
			BestSeconds = sanitizePositiveSeconds(state.ClearSpeedrun and state.ClearSpeedrun.BestSeconds),
			PendingBestSeconds = sanitizePositiveSeconds(
				state.ClearSpeedrun and state.ClearSpeedrun.PendingBestSeconds
			),
		},
	}
	local freshState = makeDefaultState(
		preservedData,
		state.PersistentDataAvailable,
		player.UserId,
		false,
		true
	)
	freshState.BagCycleId = nextBagCycleId
	startClearSpeedrunSession(freshState, os.clock())

	self:_cancelScheduledPersistentSave(player)
	table.clear(state)
	for key, value in freshState do
		state[key] = value
	end
	saveRetryAttempts[player] = 0
	applyRuntimeEntitlements(player, state)

	ensureLeaderstats(player, state)
	syncPlayerWalkSpeed(player, state)
	equippedToolChangedHandler(player, state.EquippedTool)
	self:QueuePersistentSave(player)
	return true, nextRebirthCount, RebirthConfig.GetLeafCountMultiplier(nextRebirthCount)
end

function PlayerDataService:HasProcessedSkipRebirthReceipt(player, purchaseId)
	local state = states[player]
	return state ~= nil
		and type(purchaseId) == "string"
		and hasProcessedReward(state.ProcessedSkipRebirthReceiptIds, purchaseId)
end

function PlayerDataService:CreditOnlineFriendReward(owner, delivery)
	local state = states[owner]
	if
		not state
		or type(delivery) ~= "table"
		or type(delivery.TransactionId) ~= "string"
		or sanitizeCoins(delivery.Amount) <= 0
	then
		return false
	end
	if not appendProcessedReward(state.ProcessedFriendRewardIds, delivery.TransactionId) then
		return true
	end

	local baseAmount, rewardMultiplier, amount = self:CalculateCoinReward(owner, delivery.Amount)
	local previousCoins = sanitizeCoins(state.Coins)
	state.Coins = sanitizeCoins(previousCoins + amount)
	local awardedAmount = state.Coins - previousCoins
	if awardedAmount ~= amount then
		baseAmount = awardedAmount
		rewardMultiplier = 1
	end
	if awardedAmount > 0 then
		self:UpdateLeaderstats(owner)
	end
	self:QueuePersistentSave(owner)
	if awardedAmount > 0 then
		self:NotifyCoinGainEvent(owner, {
			BaseAmount = baseAmount,
			RewardMultiplier = rewardMultiplier,
			Amount = awardedAmount,
			TargetCoins = state.Coins,
			StepCount = 1,
			FirstStepDelay = 0,
			StepInterval = 0.1,
			HoldDuration = 1,
			FlyDuration = 0.35,
		})
	end
	self:PushSnapshot(owner)
	return true
end

function PlayerDataService:DeliverOfflineFriendReward(ownerUserId, delivery)
	local numericOwnerUserId = sanitizeWholeNumber(ownerUserId)
	if
		numericOwnerUserId <= 0
		or type(delivery) ~= "table"
		or type(delivery.TransactionId) ~= "string"
		or #delivery.TransactionId > 96
		or sanitizeCoins(delivery.Amount) <= 0
	then
		return false, "invalid delivery"
	end

	local success, result = pcall(function()
		return persistentStore:UpdateAsync(getDataKeyFromUserId(numericOwnerUserId), function(rawData)
			local isNewPlayer = type(rawData) ~= "table"
			local data, dataResetPerformed = preparePersistentDataForCurrentReset(rawData, isNewPlayer)
			local sourceSchemaVersion = data.SchemaVersion
			migrateLegacyDiamondCurrency(data)
			migrateRemovedSewerData(data)
			migrateLegacyAreaBagCapacityBonus(
				data,
				sanitizeYardProgress(data.YardProgress, data.UnlockedAreas),
				numericOwnerUserId
			)
			data.LuckyBoxOnboarding = sanitizeLuckyBoxOnboarding(
				data.LuckyBoxOnboarding,
				sourceSchemaVersion
			)
			data.SchemaVersion = DATA_SCHEMA_VERSION
			if isNewPlayer or dataResetPerformed then
				data.ClearSpeedrun = sanitizeClearSpeedrun(data.ClearSpeedrun, data.RebirthCount, true)
			end
			local processedIds = sanitizeStringList(data.ProcessedFriendRewardIds, 200)
			if hasProcessedReward(processedIds, delivery.TransactionId) then
				return data
			end
			appendProcessedReward(processedIds, delivery.TransactionId)

			local rewards = sanitizePendingFriendRewards(data.PendingFriendRewards)
			local amount = sanitizeCoins(delivery.Amount)
			rewards.TotalAmount = sanitizeCoins(rewards.TotalAmount + amount)
			local helperUserId = sanitizeWholeNumber(delivery.HelperUserId)
			if helperUserId > 0 then
				local helperKey = tostring(helperUserId)
				local contributor = rewards.Contributors[helperKey] or {
					Amount = 0,
					Name = "Player",
				}
				contributor.Amount = sanitizeCoins(contributor.Amount + amount)
				if type(delivery.HelperName) == "string" and #delivery.HelperName > 0 then
					contributor.Name = string.sub(delivery.HelperName, 1, 32)
				end
				rewards.Contributors[helperKey] = contributor
			end

			data.PendingFriendRewards = rewards
			data.ProcessedFriendRewardIds = processedIds
			return data
		end)
	end)
	return success, success and result or tostring(result)
end

function PlayerDataService:QueueFriendRewardDelivery(helper, ownerUserId, amount, transactionId)
	local helperState = states[helper]
	local numericOwnerUserId = sanitizeWholeNumber(ownerUserId)
	local rewardAmount = sanitizeCoins(amount)
	if
		not helperState
		or numericOwnerUserId <= 0
		or numericOwnerUserId == helper.UserId
		or rewardAmount <= 0
		or type(transactionId) ~= "string"
	then
		return false
	end
	local delivery = {
		TransactionId = transactionId,
		OwnerUserId = numericOwnerUserId,
		Amount = rewardAmount,
		HelperUserId = helper.UserId,
		HelperName = helper.DisplayName,
	}
	local owner = Players:GetPlayerByUserId(numericOwnerUserId)
	local delivered = false
	if owner then
		if states[owner] then
			delivered = self:CreditOnlineFriendReward(owner, delivery)
		end
	else
		delivered = select(1, self:DeliverOfflineFriendReward(numericOwnerUserId, delivery))
	end
	if delivered then
		return true
	end
	table.insert(helperState.PendingFriendDeliveries, delivery)
	self:QueuePersistentSave(helper)
	return false
end

function PlayerDataService:ClaimFriendRewards(player)
	local state = states[player]
	if not state then
		return false, "Player data is not ready.", 0, nil
	end
	local rawAmount = sanitizeCoins(state.PendingFriendRewards.TotalAmount)
	if rawAmount <= 0 then
		return false, "No friend collaboration earnings are ready to claim.", 0, self:GetSnapshot(player)
	end
	local baseAmount, rewardMultiplier, amount = self:CalculateCoinReward(player, rawAmount)

	state.PendingFriendRewards = {
		TotalAmount = 0,
		Contributors = {},
	}
	local previousCoins = sanitizeCoins(state.Coins)
	state.Coins = sanitizeCoins(previousCoins + amount)
	local awardedAmount = state.Coins - previousCoins
	if awardedAmount ~= amount then
		baseAmount = awardedAmount
		rewardMultiplier = 1
	end
	if awardedAmount > 0 then
		self:UpdateLeaderstats(player)
	end
	self:QueuePersistentSave(player)
	if awardedAmount > 0 then
		self:NotifyCoinGainEvent(player, {
			BaseAmount = baseAmount,
			RewardMultiplier = rewardMultiplier,
			Amount = awardedAmount,
			TargetCoins = state.Coins,
			StepCount = 1,
			FirstStepDelay = 0,
			StepInterval = 0.1,
			HoldDuration = 1,
			FlyDuration = 0.35,
		})
	end
	self:PushSnapshot(player)
	return true,
		string.format("Claimed %s Coins.", CoinFormat.Compact(awardedAmount)),
		awardedAmount,
		self:GetSnapshot(player)
end

function PlayerDataService:Init(remotes)
	self.Remotes = remotes
	initialized = true

	local function addPlayer(player)
		if states[player] or loadingPlayers[player] then
			return
		end
		loadingPlayers[player] = true

		local persistentData, persistentDataAvailable, isNewPlayer = self:_loadPersistentData(player)
		loadingPlayers[player] = nil
		if not player.Parent then
			return
		end
		if not persistentData then
			player:Kick("Data failed to load. Please rejoin the game.")
			return
		end

		local preparedData, dataResetPerformed = preparePersistentDataForCurrentReset(persistentData, isNewPlayer)
		local state = makeDefaultState(
			preparedData,
			persistentDataAvailable,
			player.UserId,
			isNewPlayer and not dataResetPerformed,
			isNewPlayer or dataResetPerformed
		)
		startClearSpeedrunSession(state, playerJoinedClocks[player] or os.clock())
		state.DataResetNoticePending = dataResetPerformed or state.DataResetNoticePending
		applyRuntimeEntitlements(player, state)
		states[player] = state
		ensureLeaderstats(player, state)
		syncPlayerWalkSpeed(player, state)
		for _, handler in playerStateReadyHandlers do
			local success, message = pcall(handler, player, state)
			if not success then
				warn("Player-state-ready handler failed: " .. tostring(message))
			end
		end
		equippedToolChangedHandler(player, state.EquippedTool)
		if state.PersistentDirty then
			self:QueuePersistentSave(player)
		end

		task.delay(0.25, function()
			if states[player] == state and player.Parent then
				self:PushSnapshot(player)
				if state.DataResetNoticePending then
					self:Notify(player, DataResetConfig.ResetNotice, 6, true)
					state.DataResetNoticeDateKey = state.DataResetDateKey
					state.DataResetNoticePending = false
					self:QueuePersistentSave(player)
				end
				if not persistentDataAvailable then
					self:Notify(player, "Studio DataStore is unavailable. Progress is temporary.")
				end
			end
		end)
	end

	local function bindPlayer(player)
		playerJoinedClocks[player] = playerJoinedClocks[player] or os.clock()
		player.CharacterAdded:Connect(function(character)
			task.spawn(function()
				character:WaitForChild("Humanoid")
				if states[player] then
					self:RefreshPlayerModifiers(player)
				else
					syncPlayerWalkSpeed(player, nil, character)
				end
			end)
		end)
		task.spawn(addPlayer, player)
	end

	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player)
		self:SavePlayerNow(player)
		self:_cancelScheduledPersistentSave(player)
		states[player] = nil
		loadingPlayers[player] = nil
		saveRunning[player] = nil
		saveScheduledStates[player] = nil
		saveTaskTokens[player] = nil
		saveRevisions[player] = nil
		saveRetryAttempts[player] = nil
		coinGainSequences[player] = nil
		playerJoinedClocks[player] = nil
	end)

	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end

	task.spawn(function()
		while initialized do
			task.wait(AUTOSAVE_INTERVAL)
			for player, state in states do
				if (state.PersistentDirty or isClearSpeedrunSessionActive(state)) and player.Parent then
					self:QueuePersistentSave(player)
				end
			end
		end
	end)

	game:BindToClose(function()
		initialized = false
		local remaining = 0
		for player in states do
			remaining += 1
			task.spawn(function()
				self:SavePlayerNow(player)
				remaining -= 1
			end)
		end

		local deadline = os.clock() + 25
		while remaining > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

function PlayerDataService:SetAreaProgressProvider(provider)
	areaProgressProvider = provider
end

function PlayerDataService:SetLostItemProgressProvider(provider)
	lostItemProgressProvider = provider
end

function PlayerDataService:SetTimedLuckyBoxSnapshotProvider(provider)
	timedLuckyBoxSnapshotProvider = provider or function(_)
		return nil, false, nil
	end
end

function PlayerDataService:SetPoopSnapshotProvider(provider)
	poopSnapshotProvider = provider or function()
		return {}
	end
end

function PlayerDataService:SetRebirthStatusProvider(provider)
	rebirthStatusProvider = provider or function(_)
		return false, 0, RebirthConfig.GetRainbowPoopRequiredCount(0)
	end
end

function PlayerDataService:SetTutorialStateProvider(provider)
	tutorialStateProvider = provider or function()
		return nil
	end
end

function PlayerDataService:SetCoinRewardMultiplierProvider(provider)
	coinRewardMultiplierProvider = provider or function()
		return 1, true
	end
end

function PlayerDataService:SetQuickSellOwnershipProvider(provider)
	quickSellOwnershipProvider = provider or function()
		return false, false
	end
end

function PlayerDataService:SetPermanentToolEntitlementProvider(provider)
	permanentToolEntitlementProvider = provider or function()
		return {}, {}
	end
end

function PlayerDataService:SetPermanentBagEntitlementProvider(provider)
	permanentBagEntitlementProvider = provider or function()
		return {}, {}
	end
end

function PlayerDataService:SetDeveloperProductEntitlementProvider(provider)
	developerProductEntitlementProvider = provider or function()
		return {}, BagConfig.DefaultLevel, false
	end
end

function PlayerDataService:ApplyDeveloperProductEntitlements(player, shouldPush)
	local state = states[player]
	if not state then
		return false, false, false
	end
	local changed, toolChanged, bagChanged = applyDeveloperProductEntitlements(player, state)
	if changed then
		state.BagFullNotified = state.CurrentBagValue >= self:GetBagCapacity(state)
		if toolChanged then
			equippedToolChangedHandler(player, state.EquippedTool)
		end
		self:QueuePersistentSave(player)
	end
	if shouldPush ~= false then
		self:PushSnapshot(player)
	end
	return state.DeveloperProductEntitlementsReady == true, toolChanged, bagChanged
end

function PlayerDataService:SetYardContextProvider(provider)
	yardContextProvider = provider or yardContextProvider
end

function PlayerDataService:SetEquippedToolChangedHandler(handler)
	equippedToolChangedHandler = handler or function() end
end

function PlayerDataService:SetPlayerStateReadyHandler(handler)
	table.clear(playerStateReadyHandlers)
	if handler then
		table.insert(playerStateReadyHandlers, handler)
	end
end

function PlayerDataService:AddPlayerStateReadyHandler(handler)
	if handler then
		table.insert(playerStateReadyHandlers, handler)
	end
end

function PlayerDataService:GetState(player)
	return states[player]
end

function PlayerDataService:CanPersistCriticalTransaction(player)
	local state = states[player]
	return state ~= nil
		and (state.PersistentDataAvailable == true or RunService:IsStudio())
		and state.PersistentResetRequested ~= true
		and state.PersistentResetInProgress ~= true
end

function PlayerDataService:ApplyCoinFlipStart(player, wager, pendingTransaction, progress)
	local state = states[player]
	local normalizedWager = sanitizeCoins(wager)
	local normalizedPending = sanitizePendingCoinFlip(pendingTransaction)
	if not self:CanPersistCriticalTransaction(player) then
		return false, "Player save data is unavailable."
	end
	if state.PendingCoinFlip ~= nil then
		return false, "A coin flip is already in progress."
	end
	if
		normalizedWager < CoinFlipConfig.MinimumWager
		or normalizedWager % CoinFlipConfig.WagerStep ~= 0
		or not normalizedPending
	then
		return false, "Invalid bet."
	end
	if sanitizeCoins(state.Coins) < normalizedWager then
		return false, "Not enough Coins."
	end

	local previousCoins = state.Coins
	local previousProgress = state.CoinFlipProgress
	state.Coins = sanitizeCoins(state.Coins - normalizedWager)
	state.CoinFlipProgress = copyCoinFlipProgress(progress)
	state.PendingCoinFlip = normalizedPending
	self:UpdateLeaderstats(player)
	self:MarkPersistentDirty(player)
	if not self:SavePlayerNow(player) then
		state.Coins = previousCoins
		state.CoinFlipProgress = previousProgress
		state.PendingCoinFlip = nil
		self:UpdateLeaderstats(player)
		self:MarkPersistentDirty(player)
		return false, "Bet could not be saved. Try again."
	end
	self:PushSnapshot(player)
	return true, normalizedPending
end

function PlayerDataService:CompleteCoinFlip(player, transactionId)
	local state = states[player]
	local pending = state and sanitizePendingCoinFlip(state.PendingCoinFlip) or nil
	if
		not pending
		or type(transactionId) ~= "string"
		or pending.TransactionId ~= transactionId
	then
		return false, 0, state and sanitizeCoins(state.Coins) or 0
	end

	local previousCoins = state.Coins
	local previousPending = state.PendingCoinFlip
	local awarded = 0
	if pending.IsHeads then
		local normalizedPreviousCoins = sanitizeCoins(state.Coins)
		state.Coins = sanitizeCoins(normalizedPreviousCoins + sanitizeCoins(pending.Wager * 2))
		awarded = state.Coins - normalizedPreviousCoins
	end
	state.PendingCoinFlip = nil
	self:UpdateLeaderstats(player)
	self:MarkPersistentDirty(player)
	if not self:SavePlayerNow(player) then
		state.Coins = previousCoins
		state.PendingCoinFlip = previousPending
		self:UpdateLeaderstats(player)
		self:MarkPersistentDirty(player)
		return false, 0, state.Coins
	end
	if player.Parent == Players then
		if awarded > 0 then
			self:NotifyCoinGainEvent(player, {
				Amount = awarded,
				BaseAmount = awarded,
				RewardMultiplier = 1,
				TargetCoins = state.Coins,
				StepCount = 1,
				FirstStepDelay = 0,
				StepInterval = 0.1,
				SoundKind = "CoinFlip",
				SoundCount = 1,
				SoundFirstDelay = 0,
				SoundInterval = 0.1,
				CenterReward = true,
			})
		end
		self:PushSnapshot(player)
	end
	return true, awarded, state.Coins
end

function PlayerDataService:IncrementRainbowPoopFound(player)
	local state = states[player]
	if not state then
		return false, 0, RebirthConfig.GetRainbowPoopRequiredCount(0)
	end
	local requiredCount = RebirthConfig.GetRainbowPoopRequiredCount(state.RebirthCount)
	local previousCount = math.min(sanitizeWholeNumber(state.RainbowPoopFoundCount), requiredCount)
	local foundCount = math.min(previousCount + 1, requiredCount)
	state.RainbowPoopFoundCount = foundCount
	if foundCount ~= previousCount then
		self:QueuePersistentSave(player)
		self:PushSnapshot(player)
	end
	return foundCount ~= previousCount, foundCount, requiredCount
end

function PlayerDataService:GetClearSpeedrunElapsed(player)
	return getClearSpeedrunElapsed(states[player])
end

function PlayerDataService:CompleteClearSpeedrun(player)
	local state = states[player]
	local speedrun = state and state.ClearSpeedrun
	if
		type(speedrun) ~= "table"
		or speedrun.Eligible ~= true
		or speedrun.Completed == true
		or RebirthConfig.NormalizeCount(speedrun.RunRebirthCount)
			~= RebirthConfig.NormalizeCount(state.RebirthCount)
	then
		return false, nil
	end
	local elapsedSeconds = math.max(1, sanitizeWholeNumber(math.floor(getClearSpeedrunElapsed(state) + 0.5)))
	speedrun.AccumulatedSeconds = elapsedSeconds
	speedrun.Completed = true
	speedrun.SessionStartedClock = nil
	local bestSeconds = sanitizePositiveSeconds(speedrun.BestSeconds)
	if not bestSeconds or elapsedSeconds < bestSeconds then
		local pendingBestSeconds = sanitizePositiveSeconds(speedrun.PendingBestSeconds)
		speedrun.PendingBestSeconds = if pendingBestSeconds
			then math.min(pendingBestSeconds, elapsedSeconds)
			else elapsedSeconds
	end
	self:QueuePersistentSave(player)
	return true, elapsedSeconds
end

function PlayerDataService:SetCommittedClearSpeedrunBest(player, bestSeconds)
	local state = states[player]
	local speedrun = state and state.ClearSpeedrun
	local normalizedBest = sanitizePositiveSeconds(bestSeconds)
	if type(speedrun) ~= "table" or not normalizedBest then
		return false
	end
	local previousBest = sanitizePositiveSeconds(speedrun.BestSeconds)
	local nextBest = if previousBest then math.min(previousBest, normalizedBest) else normalizedBest
	local changed = nextBest ~= previousBest
	speedrun.BestSeconds = nextBest
	local pendingBest = sanitizePositiveSeconds(speedrun.PendingBestSeconds)
	if pendingBest and nextBest <= pendingBest then
		speedrun.PendingBestSeconds = nil
		changed = true
	end
	if changed then
		self:QueuePersistentSave(player)
	end
	return changed
end

function PlayerDataService:GetClearSpeedrunLeaderboardState(player)
	local state = states[player]
	local speedrun = state and state.ClearSpeedrun
	if type(speedrun) ~= "table" then
		return nil
	end
	return {
		BestSeconds = sanitizePositiveSeconds(speedrun.BestSeconds),
		PendingBestSeconds = sanitizePositiveSeconds(speedrun.PendingBestSeconds),
		Eligible = speedrun.Eligible == true,
		Completed = speedrun.Completed == true,
		AccumulatedSeconds = sanitizeWholeNumber(math.floor(getClearSpeedrunElapsed(state) + 0.5)),
	}
end

function PlayerDataService:SetAllowGuestPoop(player, allowed, shouldPush)
	local state = states[player]
	if not state or type(allowed) ~= "boolean" then
		return false
	end
	if state.AllowGuestPoop == allowed then
		return true
	end
	state.AllowGuestPoop = allowed
	self:MarkPersistentDirty(player)
	if shouldPush ~= false then
		self:PushSnapshot(player)
	end
	return true
end

function PlayerDataService:GetCoinRewardStatus(player)
	local success, value, ready = pcall(coinRewardMultiplierProvider, player)
	if not success then
		warn("Coin reward multiplier provider failed: " .. tostring(value))
		return 1, false
	end
	return math.max(1, math.floor(tonumber(value) or 1)), ready ~= false
end

function PlayerDataService:GetCoinRewardMultiplier(player)
	return self:GetCoinRewardStatus(player)
end

function PlayerDataService:GetQuickSellOwnershipStatus(player)
	local success, owned, ready = pcall(quickSellOwnershipProvider, player)
	if not success then
		warn("Quick Sell ownership provider failed: " .. tostring(owned))
		return false, false
	end
	return owned == true, ready == true
end

function PlayerDataService:CalculateCoinReward(player, baseAmount)
	local sanitizedBaseAmount = sanitizeCoins(baseAmount)
	local rewardMultiplier = self:GetCoinRewardMultiplier(player)
	return sanitizedBaseAmount, rewardMultiplier, sanitizeCoins(sanitizedBaseAmount * rewardMultiplier)
end

function PlayerDataService:RefreshPlayerModifiers(player)
	local state = states[player]
	if not state then
		return nil
	end
	local modifiers = calculateEffectiveModifiers(
		state.PlayerAttributeLevels,
		state.RebirthCount
	)
	state.LeafValueMultiplier = modifiers.LeafValueMultiplier
	state.CoinMultiplier = modifiers.LeafValueMultiplier
	state.PersonalLeafValueMultiplier = modifiers.PersonalLeafValueMultiplier
	state.RebirthLeafValueMultiplier = modifiers.RebirthLeafValueMultiplier
	state.MoveSpeedBonus = modifiers.MoveSpeedBonus
	state.WalkSpeed = modifiers.WalkSpeed
	state.BagFullNotified = state.CurrentBagValue >= self:GetBagCapacity(state)
	syncPlayerWalkSpeed(player, state)
	return modifiers
end

function PlayerDataService:GetBagCapacity(state)
	local bagConfig = getStorageBagConfig(state)
	local baseCapacity = bagConfig.Capacity
	return baseCapacity
		+ sanitizeWholeNumber(state.LegacyAreaBagCapacityBonus)
		+ BagConfig.GetExpansionCapacityBonus(state.BagExpansionLevel)
end

function PlayerDataService:GetActivePermanentBagId(playerOrState)
	local state = playerOrState
	if typeof(playerOrState) == "Instance" and playerOrState:IsA("Player") then
		state = states[playerOrState]
	end
	return getActivePermanentBagId(state)
end

function PlayerDataService:GetSelectedPermanentBagVisualId(playerOrState)
	local state = playerOrState
	if typeof(playerOrState) == "Instance" and playerOrState:IsA("Player") then
		state = states[playerOrState]
	end
	local selectedBagId = sanitizeSelectedPermanentBagVisualId(
		state and state.SelectedPermanentBagVisualId
	)
	local ownership = state and state.PermanentBagOwnership
	if selectedBagId and ownership and ownership[selectedBagId] == true then
		return selectedBagId
	end
	return getActivePermanentBagId(state)
end

function PlayerDataService:IsInstantRecycleEnabled(playerOrState)
	return self:GetActivePermanentBagId(playerOrState) == "bag011"
end

function PlayerDataService:GetEffectiveBagConfig(playerOrState)
	local state = playerOrState
	if typeof(playerOrState) == "Instance" and playerOrState:IsA("Player") then
		state = states[playerOrState]
	end
	local activeBagId = getActivePermanentBagId(state)
	if activeBagId then
		return BagConfig.PermanentBags[activeBagId]
	end
	local level = state and state.BagLevel or BagConfig.DefaultLevel
	return BagConfig.Levels[level] or BagConfig.Levels[BagConfig.DefaultLevel]
end

function PlayerDataService:GetBagVisualConfig(playerOrState)
	local state = playerOrState
	if typeof(playerOrState) == "Instance" and playerOrState:IsA("Player") then
		state = states[playerOrState]
	end
	local selectedBagId = self:GetSelectedPermanentBagVisualId(state)
	if selectedBagId then
		return BagConfig.PermanentBags[selectedBagId]
	end
	local level = state and state.BagLevel or BagConfig.DefaultLevel
	return BagConfig.Levels[level] or BagConfig.Levels[BagConfig.DefaultLevel]
end

function PlayerDataService:GetEffectiveHandAttributes(playerOrState)
	local state = playerOrState
	if typeof(playerOrState) == "Instance" and playerOrState:IsA("Player") then
		state = states[playerOrState]
	end
	return HandUpgradeConfig.GetEffectiveAttributes(state and state.HandUpgradeLevels)
end

function PlayerDataService:GetEffectiveToolAttributes(playerOrState)
	local state = playerOrState
	if typeof(playerOrState) == "Instance" and playerOrState:IsA("Player") then
		state = states[playerOrState]
	end
	local toolConfig = state and state.EquippedTool and ToolConfig.ById[state.EquippedTool]
	if not toolConfig or toolConfig.AvailableForGameplay ~= true then
		return nil
	end
	if toolConfig.UsesHandUpgrades == true then
		return self:GetEffectiveHandAttributes(state)
	end
	local configuredAttributes = ToolUpgradeConfig.GetEffectiveAttributes(
		toolConfig.Id,
		state.ToolUpgradeLevels and state.ToolUpgradeLevels[toolConfig.Id]
	)
	if configuredAttributes then
		return configuredAttributes
	end
	return {
		Range = math.max(0, tonumber(toolConfig.Range) or 0),
		PickupInterval = math.max(0, tonumber(toolConfig.PickupInterval) or 0),
		PickupCount = math.max(0, math.floor(tonumber(toolConfig.PickupCount) or 0)),
	}
end

function PlayerDataService:GetSnapshot(player)
	local state = states[player]
	if not state then
		return nil
	end

	local currentAreaId = state.CurrentAreaId or "Area_01"
	local yardContext = yardContextProvider(player) or {}
	local activeOwner = yardContext.Owner
	local activeOwnerState = activeOwner and states[activeOwner] or nil
	local clearedValue, totalValue, progress, collectedLeafCount, totalLeafCount = areaProgressProvider(
		player,
		currentAreaId
	)
	collectedLeafCount = math.max(0, math.floor(tonumber(collectedLeafCount) or 0))
	totalLeafCount = math.max(0, math.floor(tonumber(totalLeafCount) or 0))
	collectedLeafCount = math.min(collectedLeafCount, totalLeafCount)
	local lostItemsFound, lostItemsTotal, foundLostItems, personalWorldLostItems, carriedLostItem, collectibleInventoryCounts, collectibleInventoryTotal = lostItemProgressProvider(
		player,
		currentAreaId
	)
	local timedLuckyBoxNextSpawnAt, timedLuckyBoxWaitingForPickup, timedLuckyBoxRewardKind = timedLuckyBoxSnapshotProvider(
		player
	)
	if
		type(timedLuckyBoxNextSpawnAt) ~= "number"
		or timedLuckyBoxNextSpawnAt ~= timedLuckyBoxNextSpawnAt
		or timedLuckyBoxNextSpawnAt == math.huge
		or timedLuckyBoxNextSpawnAt == -math.huge
	then
		timedLuckyBoxNextSpawnAt = nil
	end
	if type(timedLuckyBoxRewardKind) ~= "string" then
		timedLuckyBoxRewardKind = nil
	end
	local activeYardPoops, activeLobbyPoops = poopSnapshotProvider(player)
	activeYardPoops = type(activeYardPoops) == "table" and activeYardPoops or {}
	activeLobbyPoops = type(activeLobbyPoops) == "table" and activeLobbyPoops or {}
	local tutorialState = tutorialStateProvider(player)
	local equippedConfig = state.EquippedTool and ToolConfig.ById[state.EquippedTool]
	local effectiveToolAttributes = self:GetEffectiveToolAttributes(state)
	local bagConfig = self:GetEffectiveBagConfig(state)
	local activePermanentBagId = getActivePermanentBagId(state)
	local instantRecycleEnabled = activePermanentBagId == "bag011"
	local permanentBagOwnership = sanitizePermanentBagMap(state.PermanentBagOwnership)
	local permanentBagOwnershipReady = sanitizePermanentBagMap(state.PermanentBagOwnershipReady)
	local permanentToolOwnershipReady = {}
	for _, toolIndex in ToolConfig.Order do
		local tool = ToolConfig.Tools[toolIndex]
		if tool.PurchaseKind == "GamePass" then
			permanentToolOwnershipReady[tool.Id] = state.PermanentToolOwnershipReady ~= nil
				and state.PermanentToolOwnershipReady[tool.Id] == true
				or false
		end
	end
	local unlockedTools = {}
	for toolId, unlocked in state.UnlockedTools do
		unlockedTools[toolId] = unlocked
	end
	local unlockedAreas = {}
	local activeUnlockedAreas = activeOwnerState and activeOwnerState.UnlockedAreas or state.UnlockedAreas
	for _, areaId in RegionConfig.Order do
		if activeUnlockedAreas[areaId] == true then
			unlockedAreas[areaId] = true
		end
	end
	local handUpgradeLevels = {}
	for _, attributeId in HandUpgradeConfig.Order do
		handUpgradeLevels[attributeId] = HandUpgradeConfig.NormalizeLevel(
			attributeId,
			state.HandUpgradeLevels[attributeId]
		)
	end
	local toolUpgradeLevels = {}
	for toolId, toolUpgrade in ToolUpgradeConfig.Tools do
		local levels = {}
		local sourceLevels = state.ToolUpgradeLevels and state.ToolUpgradeLevels[toolId] or {}
		for _, attributeId in toolUpgrade.Order do
			levels[attributeId] = ToolUpgradeConfig.NormalizeLevel(toolId, attributeId, sourceLevels[attributeId])
		end
		toolUpgradeLevels[toolId] = levels
	end
	local playerAttributeLevels = copyPlayerAttributeLevels(state.PlayerAttributeLevels)

	local toolStats = {}
	if effectiveToolAttributes then
		for key, value in effectiveToolAttributes do
			toolStats[key] = value
		end
	end
	local toolBehavior = equippedConfig and equippedConfig.Behavior or nil
	local usesDirectPickupStats = toolBehavior == "Collect" or toolBehavior == "Blower"
	local coinRewardMultiplier, coinRewardOwnershipReady = self:GetCoinRewardStatus(player)
	local quickSellOwned, quickSellOwnershipReady = self:GetQuickSellOwnershipStatus(player)
	local pendingFriendRewardTotal, pendingFriendRewardContributors = makeFriendRewardContributorList(
		state.PendingFriendRewards
	)
	if coinRewardMultiplier > 1 then
		pendingFriendRewardTotal = sanitizeCoins(pendingFriendRewardTotal * coinRewardMultiplier)
		for _, contributor in pendingFriendRewardContributors do
			contributor.Amount = sanitizeCoins(contributor.Amount * coinRewardMultiplier)
		end
	end
	local rebirthEligible, rainbowPoopFoundCount, rainbowPoopRequiredCount = rebirthStatusProvider(player)
	rainbowPoopRequiredCount = math.max(
		1,
		sanitizeWholeNumber(rainbowPoopRequiredCount)
	)
	rainbowPoopFoundCount = math.min(
		sanitizeWholeNumber(rainbowPoopFoundCount),
		rainbowPoopRequiredCount
	)

	return {
		CanUseAdminReset = AdminTestConfig.IsAllowed(player.Name),
		Coins = state.Coins,
		DoubleCoinsOwned = coinRewardMultiplier > 1,
		DoubleCoinsOwnershipReady = coinRewardOwnershipReady,
		CoinRewardMultiplier = coinRewardMultiplier,
		QuickSellOwned = quickSellOwned,
		QuickSellOwnershipReady = quickSellOwnershipReady,
		CurrentBagValue = state.CurrentBagValue,
		BagCapacity = self:GetBagCapacity(state),
		BagCapacityBonus = sanitizeWholeNumber(state.LegacyAreaBagCapacityBonus),
		BagFull = not instantRecycleEnabled and state.CurrentBagValue >= self:GetBagCapacity(state),
		BagLevel = state.BagLevel,
		BagExpansionLevel = sanitizeBagExpansionLevel(state.BagExpansionLevel),
		BagName = bagConfig.Name,
		BagImage = bagConfig.Image,
		BagPrice = tonumber(bagConfig.Price) or 0,
		PermanentBagOwnership = permanentBagOwnership,
		PermanentBagOwnershipReady = permanentBagOwnershipReady,
		PermanentToolOwnershipReady = permanentToolOwnershipReady,
		ActivePermanentBagId = activePermanentBagId,
		InstantRecycleEnabled = instantRecycleEnabled,
		EquippedToolId = state.EquippedTool,
		ToolName = equippedConfig and equippedConfig.Name or "Unequipped",
		PickupCount = usesDirectPickupStats and effectiveToolAttributes and effectiveToolAttributes.PickupCount or 0,
		PickupInterval = usesDirectPickupStats and effectiveToolAttributes and effectiveToolAttributes.PickupInterval or 0,
		HarvestRadius = effectiveToolAttributes and effectiveToolAttributes.Range or 0,
		HarvestForwardOffset = effectiveToolAttributes and effectiveToolAttributes.ForwardOffset
			or equippedConfig and equippedConfig.ForwardOffset
			or 0,
		ToolBehavior = toolBehavior,
		ToolStats = toolStats,
		ToolPrice = equippedConfig
			and RebirthConfig.GetScaledPrice(equippedConfig.Price, state.RebirthCount)
			or 0,
		ToolImage = equippedConfig and equippedConfig.Image or "",
		ToolModelPath = equippedConfig and equippedConfig.ModelPath or "",
		UnlockedTools = unlockedTools,
		UnlockedAreas = unlockedAreas,
		HandUpgradeLevels = handUpgradeLevels,
		ToolUpgradeLevels = toolUpgradeLevels,
		PlayerAttributeLevels = playerAttributeLevels,
		AreaId = currentAreaId,
		CurrentAreaId = currentAreaId,
		AreaClearedValue = clearedValue,
		AreaTotalValue = totalValue,
		AreaProgress = progress,
		AreaCollectedLeafCount = collectedLeafCount,
		AreaTotalLeafCount = totalLeafCount,
		LeafValueMultiplier = state.LeafValueMultiplier,
		PersonalLeafValueMultiplier = state.PersonalLeafValueMultiplier,
		RebirthLeafValueMultiplier = state.RebirthLeafValueMultiplier,
		MoveSpeedBonus = state.MoveSpeedBonus,
		WalkSpeed = state.WalkSpeed,
		RebirthCount = RebirthConfig.NormalizeCount(state.RebirthCount),
		CoinFlipPending = state.PendingCoinFlip ~= nil,
		RebirthEligible = rebirthEligible == true,
		RainbowPoopFoundCount = rainbowPoopFoundCount,
		RainbowPoopRequiredCount = rainbowPoopRequiredCount,
		LeafCountMultiplier = RebirthConfig.GetLeafCountMultiplier(state.RebirthCount),
		AreaLostItemsFound = lostItemsFound,
		AreaLostItemsTotal = lostItemsTotal,
		AreaFoundLostItems = foundLostItems,
		PersonalWorldLostItems = personalWorldLostItems,
		CarriedLostItem = carriedLostItem,
		CollectibleInventoryCounts = collectibleInventoryCounts or {},
		CollectibleInventoryTotal = math.max(0, math.floor(tonumber(collectibleInventoryTotal) or 0)),
		TimedLuckyBoxNextSpawnAt = timedLuckyBoxNextSpawnAt,
		TimedLuckyBoxWaitingForPickup = timedLuckyBoxWaitingForPickup == true,
		TimedLuckyBoxRewardKind = timedLuckyBoxRewardKind,
		ActiveYardPoops = activeYardPoops,
		ActiveLobbyPoops = activeLobbyPoops,
		AllowGuestPoop = state.AllowGuestPoop ~= false,
		CommunityRewardClaimed = state.CommunityRewardClaimed == true,
		LostItemCollectedCounts = copyCollectedCounts(state.CollectedCounts),
		CodexClaimedTiers = copyCodexClaimedTiers(state.CodexClaimedTiers),
		TutorialState = tutorialState,
		HomeYardProgress = copyActiveYardProgress({
			UnlockedAreas = state.UnlockedAreas,
			Areas = state.YardProgress and state.YardProgress.Areas or {},
		}),
		PendingFriendRewardTotal = pendingFriendRewardTotal,
		PendingFriendRewardContributors = pendingFriendRewardContributors,
		ActiveYardOwnerUserId = tonumber(yardContext.OwnerUserId) or player.UserId,
		ActiveYardOwnerName = type(yardContext.OwnerName) == "string"
			and yardContext.OwnerName
			or player.DisplayName,
		IsVisitingYard = yardContext.IsVisiting == true,
		ActiveYardVisitors = type(yardContext.Visitors) == "table" and yardContext.Visitors or {},
	}
end

function PlayerDataService:PushSnapshot(player)
	local snapshot = self:GetSnapshot(player)
	if snapshot and self.Remotes then
		self.Remotes.StateSnapshot:FireClient(player, snapshot)
	end
end

function PlayerDataService:_createCoinGainPayload(player, options)
	if type(options) ~= "table" then
		return nil
	end
	local phase = options.Phase
	if phase ~= "Accumulate" and phase ~= "Settle" then
		phase = "Normal"
	end
	local amount = sanitizeCoins(options.Amount)
	local baseAmount = sanitizeCoins(options.BaseAmount)
	local rewardMultiplier = math.max(1, math.floor(tonumber(options.RewardMultiplier) or 1))
	if baseAmount <= 0 then
		baseAmount = amount
	end
	if rewardMultiplier > 1 and baseAmount * rewardMultiplier ~= amount then
		baseAmount = amount
		rewardMultiplier = 1
	end
	local targetCoins = sanitizeCoins(options.TargetCoins)
	local soundKind = options.SoundKind
	if soundKind ~= "Recycle" and soundKind ~= "LostItem" and soundKind ~= "CoinFlip" then
		soundKind = nil
	end
	local soundCount = if soundKind
		then math.max(0, math.floor(tonumber(options.SoundCount) or 0))
		else nil
	local soundFirstDelay = if soundKind
		then math.max(0, tonumber(options.SoundFirstDelay) or 0)
		else nil
	local soundInterval = if soundKind
		then math.max(0.05, tonumber(options.SoundInterval) or 0.1)
		else nil
	local soundOnly = amount <= 0
		and phase ~= "Settle"
		and soundKind ~= nil
		and soundCount ~= nil
		and soundCount > 0
	if amount <= 0 and phase ~= "Settle" and not soundOnly then
		return nil
	end

	local sequenceId = (coinGainSequences[player] or 0) + 1
	coinGainSequences[player] = sequenceId
	return {
		SequenceId = sequenceId,
		Phase = phase,
		SettlementId = math.max(0, math.floor(tonumber(options.SettlementId) or 0)),
		BaseAmount = baseAmount,
		RewardMultiplier = rewardMultiplier,
		Amount = amount,
		TargetCoins = targetCoins,
		StepCount = math.max(1, math.floor(tonumber(options.StepCount) or 1)),
		FirstStepDelay = math.max(0, tonumber(options.FirstStepDelay) or 0),
		StepInterval = math.max(0.05, tonumber(options.StepInterval) or 0.1),
		SoundKind = soundKind,
		SoundCount = soundCount,
		SoundFirstDelay = soundFirstDelay,
		SoundInterval = soundInterval,
		SoundOnly = soundOnly,
		HoldDuration = math.max(0, tonumber(options.HoldDuration) or 1),
		FlyDuration = math.max(0.05, tonumber(options.FlyDuration) or 0.35),
		CenterReward = options.CenterReward == true,
	}
end

function PlayerDataService:NotifyCoinGainEvent(player, options)
	if not self.Remotes or player.Parent ~= Players then
		return 0
	end
	local payload = self:_createCoinGainPayload(player, options)
	if not payload then
		return 0
	end
	self.Remotes.CoinGainEvent:FireClient(player, payload)
	return payload.SequenceId
end

function PlayerDataService:PushAllSnapshots()
	for _, player in Players:GetPlayers() do
		self:PushSnapshot(player)
	end
end

function PlayerDataService:Notify(player, message, holdDuration, priority)
	if self.Remotes and player.Parent then
		self.Remotes.Notification:FireClient(player, message, holdDuration, priority)
	end
end

function PlayerDataService:NotifyLeafCollected(player, addedAmount, leafType, toolId, leafHints)
	if self.Remotes and player.Parent and type(addedAmount) == "number" and addedAmount > 0 then
		self.Remotes.LeafCollected:FireClient(player, addedAmount, leafType, toolId, leafHints)
	end
end

function PlayerDataService:NotifyLeafPickupBatch(player, toolId, pickupInterval, collectedCount)
	if
		self.Remotes
		and player.Parent
		and type(toolId) == "string"
		and type(pickupInterval) == "number"
		and type(collectedCount) == "number"
		and collectedCount > 0
	then
		self.Remotes.LeafPickupBatch:FireClient(player, toolId, pickupInterval, collectedCount)
	end
end

function PlayerDataService:NotifyBagFullPickupAttempt(player)
	if self.Remotes and player.Parent then
		self.Remotes.BagFullPickupAttempt:FireClient(player)
	end
end

function PlayerDataService:NotifyAll(message)
	for _, player in Players:GetPlayers() do
		self:Notify(player, message)
	end
end

function PlayerDataService:IncrementLostItemCollected(player, lostItemId)
	local state = states[player]
	local config = LostItemConfig.Types[lostItemId]
	if not state or not config or config.PoopOnly == true then
		return 0
	end

	local newCount = sanitizeWholeNumber(state.CollectedCounts[lostItemId]) + 1
	state.CollectedCounts[lostItemId] = math.min(newCount, MAX_SAVED_COUNT)
	self:QueuePersistentSave(player)
	return state.CollectedCounts[lostItemId]
end

function PlayerDataService:TryClaimCommunityReward(player, coinAmount)
	local state = states[player]
	if not state then
		return false, 0, 0, false
	end
	if state.CommunityRewardClaimed == true then
		return false, 0, sanitizeCoins(state.Coins), true
	end

	local rewardAmount = sanitizeCoins(coinAmount)
	if rewardAmount <= 0 then
		return false, 0, sanitizeCoins(state.Coins), false
	end

	local previousCoins = sanitizeCoins(state.Coins)
	state.CommunityRewardClaimed = true
	state.Coins = sanitizeCoins(previousCoins + rewardAmount)
	local awardedCoins = state.Coins - previousCoins
	self:UpdateLeaderstats(player)
	self:QueuePersistentSave(player)
	return true, awardedCoins, state.Coins, true
end

function PlayerDataService:ClaimCodexReward(player, lostItemId)
	local state = states[player]
	local config = type(lostItemId) == "string" and LostItemConfig.Types[lostItemId] or nil
	if not state then
		return false, "Player state is not ready.", 0
	end
	if not config or config.PoopOnly == true then
		return false, "Invalid Codex item.", 0
	end

	local milestones = LostItemConfig.CodexMilestones
	local claimedTier = math.min(
		sanitizeWholeNumber(state.CodexClaimedTiers[lostItemId]),
		#milestones
	)
	local nextTier = claimedTier + 1
	local targetCount = milestones[nextTier]
	if not targetCount then
		return false, "All rewards for this Codex item have been claimed.", 0
	end

	local collectedCount = sanitizeWholeNumber(state.CollectedCounts[lostItemId])
	local baseCoinReward = LostItemConfig.GetCodexCoinReward(targetCount)
	if collectedCount < targetCount then
		return false, string.format(
			"Collect %d to claim %s Coins",
			targetCount,
			CoinFormat.Compact(baseCoinReward)
		), 0
	end

	local baseAmount, rewardMultiplier, requestedCoins = self:CalculateCoinReward(player, baseCoinReward)
	local previousCoins = sanitizeCoins(state.Coins)
	state.Coins = sanitizeCoins(previousCoins + requestedCoins)
	state.CodexClaimedTiers[lostItemId] = nextTier
	local awardedCoins = state.Coins - previousCoins
	if awardedCoins ~= requestedCoins then
		baseAmount = awardedCoins
		rewardMultiplier = 1
	end
	self:UpdateLeaderstats(player)
	self:QueuePersistentSave(player)

	if awardedCoins > 0 then
		self:NotifyCoinGainEvent(player, {
			Phase = "Normal",
			BaseAmount = baseAmount,
			RewardMultiplier = rewardMultiplier,
			Amount = awardedCoins,
			TargetCoins = state.Coins,
			StepCount = 1,
			FirstStepDelay = 0,
			StepInterval = 0.1,
			HoldDuration = 1,
			FlyDuration = 0.35,
		})
	end
	self:PushSnapshot(player)
	return true, string.format("Claimed %s Coins.", CoinFormat.Compact(awardedCoins)), awardedCoins
end

function PlayerDataService:AwardLostItemCoins(player, coinAmount, options)
	options = type(options) == "table" and options or {}
	local soundCount = math.max(0, math.floor(tonumber(options.SoundCount) or 0))
	local fixedCoinAmount = sanitizeCoins(options.FixedCoinAmount)
	local state = states[player]
	local baseCoinAmount, coinRewardMultiplier, multipliedCoins = self:CalculateCoinReward(player, coinAmount)
	local requestedCoins = sanitizeCoins(multipliedCoins + fixedCoinAmount)
	if not state or requestedCoins <= 0 then
		return false, 0
	end

	local previousCoins = sanitizeCoins(state.Coins)
	state.Coins = sanitizeCoins(previousCoins + requestedCoins)
	local awardedCoins = state.Coins - previousCoins
	if awardedCoins ~= requestedCoins then
		baseCoinAmount = awardedCoins
		coinRewardMultiplier = 1
	elseif fixedCoinAmount > 0 then
		-- A fixed-value poop amount and a multiplied normal lost-item amount cannot be
		-- represented by one honest multiplier. Show the exact combined payout.
		baseCoinAmount = awardedCoins
		coinRewardMultiplier = 1
	end

	self:UpdateLeaderstats(player)
	self:QueuePersistentSave(player)

	if awardedCoins > 0 or soundCount > 0 then
		self:NotifyCoinGainEvent(player, {
			Phase = "Normal",
			BaseAmount = baseCoinAmount,
			RewardMultiplier = coinRewardMultiplier,
			Amount = awardedCoins,
			TargetCoins = state.Coins,
			StepCount = 1,
			FirstStepDelay = 0,
			StepInterval = 0.1,
			SoundKind = "LostItem",
			SoundCount = soundCount,
			SoundFirstDelay = 0,
			SoundInterval = 0.1,
			HoldDuration = 1,
			FlyDuration = 0.35,
			CenterReward = true,
		})
	end
	self:PushSnapshot(player)

	return true, awardedCoins
end

function PlayerDataService:UnlockTool(player, toolId)
	local state = states[player]
	local toolConfig = ToolConfig.ById[toolId]
	if
		not state
		or not toolConfig
		or toolConfig.AvailableForGameplay ~= true
		or toolConfig.PurchaseKind == "GamePass"
	then
		return false
	end
	state.UnlockedTools[toolId] = true
	self:QueuePersistentSave(player)
	return true
end

function PlayerDataService:SetPermanentToolEntitlement(player, toolId, owned, equipNow, ownershipReady)
	local state = states[player]
	local toolConfig = ToolConfig.ById[toolId]
	if
		not state
		or not toolConfig
		or toolConfig.AvailableForGameplay ~= true
		or toolConfig.PurchaseKind ~= "GamePass"
	then
		return false
	end

	local shouldOwn = owned == true
	state.PermanentToolOwnershipReady = state.PermanentToolOwnershipReady or {}
	local shouldBeReady = ownershipReady == true
	local ownershipChanged = state.UnlockedTools[toolId] ~= shouldOwn
	local readinessChanged = state.PermanentToolOwnershipReady[toolId] ~= shouldBeReady
	local stateChanged = ownershipChanged or readinessChanged
	local shouldSyncTools = ownershipChanged
	state.UnlockedTools[toolId] = shouldOwn
	state.PermanentToolOwnershipReady[toolId] = shouldBeReady

	if not shouldOwn then
		if state.EquippedTool == toolId then
			state.EquippedTool = ToolConfig.DefaultToolId
			stateChanged = true
			shouldSyncTools = true
		end
		if state.LastEquippedTool == toolId then
			state.LastEquippedTool = ToolConfig.DefaultToolId
			stateChanged = true
			shouldSyncTools = true
		end
	elseif equipNow == true then
		local rememberAsCleaningTool = ToolConfig.IsLeafCleaningTool(toolId)
		if
			state.EquippedTool ~= toolId
			or (rememberAsCleaningTool and state.LastEquippedTool ~= toolId)
		then
			stateChanged = true
			shouldSyncTools = true
		end
		state.EquippedTool = toolId
		if rememberAsCleaningTool then
			state.LastEquippedTool = toolId
		end
	end

	if stateChanged then
		if shouldSyncTools then
			equippedToolChangedHandler(player, state.EquippedTool)
		end
		self:PushSnapshot(player)
	end
	return true
end

function PlayerDataService:SetSelectedPermanentBagVisual(player, bagId)
	local state = states[player]
	local normalizedBagId = sanitizeSelectedPermanentBagVisualId(bagId)
	if
		not state
		or not normalizedBagId
		or state.PermanentBagOwnership[normalizedBagId] ~= true
	then
		return false, false
	end
	if state.SelectedPermanentBagVisualId == normalizedBagId then
		return true, false
	end
	state.SelectedPermanentBagVisualId = normalizedBagId
	self:MarkPersistentDirty(player)
	self:QueuePersistentSave(player)
	return true, true
end

function PlayerDataService:SetPermanentBagEntitlements(player, ownership, readiness, shouldPush)
	local state = states[player]
	if not state then
		return false, false, nil, nil
	end

	local previousActiveBagId = getActivePermanentBagId(state)
	local normalizedOwnership = sanitizePermanentBagMap(ownership)
	local normalizedReadiness = sanitizePermanentBagMap(readiness)
	local changed = false
	for _, bagId in BagConfig.PermanentOrder do
		if
			state.PermanentBagOwnership[bagId] ~= normalizedOwnership[bagId]
			or state.PermanentBagOwnershipReady[bagId] ~= normalizedReadiness[bagId]
		then
			changed = true
		end
		state.PermanentBagOwnership[bagId] = normalizedOwnership[bagId]
		state.PermanentBagOwnershipReady[bagId] = normalizedReadiness[bagId]
	end

	local capacityOwnershipReady = normalizedReadiness.bag09 and normalizedReadiness.bag010
	if capacityOwnershipReady and not self:IsInstantRecycleEnabled(state) then
		local capacity = self:GetBagCapacity(state)
		if state.CurrentBagValue > capacity then
			state.CurrentBagValue = capacity
			state.BagSourceValues = sanitizeBagSourceValues(
				state.BagSourceValues,
				state.CurrentBagValue,
				player.UserId
			)
			changed = true
		end
	end
	state.BagFullNotified = not self:IsInstantRecycleEnabled(state)
		and state.CurrentBagValue >= self:GetBagCapacity(state)

	local activeBagId = getActivePermanentBagId(state)
	if shouldPush ~= false and changed then
		self:PushSnapshot(player)
	end
	return true, changed, previousActiveBagId, activeBagId
end

function PlayerDataService:SetEquippedTool(player, toolId)
	local state = states[player]
	if not state then
		return false, "Player state is not ready."
	end

	if toolId == nil then
		state.EquippedTool = nil
		equippedToolChangedHandler(player, nil)
		self:PushSnapshot(player)
		return true, "Cleaning tool unequipped."
	end

	local toolConfig = ToolConfig.ById[toolId]
	if not toolConfig or not state.UnlockedTools[toolId] or toolConfig.AvailableForGameplay ~= true then
		return false, "This tool is not unlocked."
	end

	state.EquippedTool = toolId
	if ToolConfig.IsLeafCleaningTool(toolId) then
		state.LastEquippedTool = toolId
		self:MarkPersistentDirty(player)
	end
	equippedToolChangedHandler(player, toolId)
	self:PushSnapshot(player)
	local effectiveToolAttributes = self:GetEffectiveToolAttributes(state)
	if toolConfig.Behavior == "Broom" then
		return true, string.format(
			"Broom equipped (Range %.1f, Length %.1f, Coverage %d%%).",
			effectiveToolAttributes and effectiveToolAttributes.Range or 0,
			effectiveToolAttributes and effectiveToolAttributes.ForwardOffset or 0,
			math.floor((effectiveToolAttributes and effectiveToolAttributes.SweepCoverage or 0) * 100 + 0.5)
		)
	elseif toolConfig.Behavior == "Blower" then
		return true, string.format(
			"Leaf Blower equipped (Range %.1f, Distance %.1f, %d per use, %.1fs interval).",
			effectiveToolAttributes and effectiveToolAttributes.Range or 0,
			effectiveToolAttributes and effectiveToolAttributes.ForwardOffset or 0,
			math.floor(effectiveToolAttributes and effectiveToolAttributes.PickupCount or 0),
			effectiveToolAttributes and effectiveToolAttributes.PickupInterval or 0
		)
	elseif toolConfig.Behavior == "MakeTrash" then
		return true, "MakeTrash equipped."
	end
	return true, string.format(
		"%s equipped (%d per use, %.2fs interval, Range %.1f).",
		toolConfig.Name,
		effectiveToolAttributes and effectiveToolAttributes.PickupCount or 0,
		effectiveToolAttributes and effectiveToolAttributes.PickupInterval or 0,
		effectiveToolAttributes and effectiveToolAttributes.Range or 0
	)
end

function PlayerDataService:SetEquippedToolFromInventory(player, toolId)
	local state = states[player]
	if not state then
		return false
	end

	if toolId ~= nil then
		local toolConfig = ToolConfig.ById[toolId]
		if
			type(toolId) ~= "string"
			or not toolConfig
			or toolConfig.AvailableForGameplay ~= true
			or state.UnlockedTools[toolId] ~= true
		then
			return false
		end
		if ToolConfig.IsLeafCleaningTool(toolId) then
			state.LastEquippedTool = toolId
			self:MarkPersistentDirty(player)
		end
	end

	if state.EquippedTool == toolId then
		return true
	end
	state.EquippedTool = toolId
	self:PushSnapshot(player)
	return true
end

function PlayerDataService:UpdateLeaderstats(player)
	local state = states[player]
	if state then
		ensureLeaderstats(player, state)
	end
end

return PlayerDataService

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)
local LostItemConfig = require(ReplicatedStorage.Shared.Config.LostItemConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local LostItemService = {}

local PICKUP_DISTANCE_PADDING = 3
local UPGRADE_UPRIGHT_ALIGNMENT = 0.999
local LOST_ITEM_HOTBAR_ORDER = 1_000
local REVEAL_TOTAL_DURATION = LostItemConfig.GetLuckyRevealTotalDuration()
local NEARBY_REVEAL_RADIUS = LostItemConfig.RevealAnimation.NearbyViewerRadius
local TIMED_LUCKY_BOX = LostItemConfig.TimedLuckyBox
local PROGRESSIVE_SPAWN_MODE = LostItemConfig.SpawnModes
	and LostItemConfig.SpawnModes.Progressive
	or "Progressive"
local TIMED_REWARD_KIND_FIRST = TIMED_LUCKY_BOX.RewardKinds.First
local TIMED_REWARD_KIND_RECURRING = TIMED_LUCKY_BOX.RewardKinds.Recurring

local playerSessions = {}
local pickupLocks = {}
local pendingReveals = {}
local shopLocks = {}

local function getSpawnSource(timedRewardKind)
	if timedRewardKind == TIMED_REWARD_KIND_FIRST then
		return TIMED_LUCKY_BOX.SpawnSources.First
	elseif timedRewardKind == TIMED_REWARD_KIND_RECURRING then
		return TIMED_LUCKY_BOX.SpawnSources.Recurring
	end
	return nil
end

local function getVisualModel(model)
	local visualModel = model:FindFirstChild("Model")
	if visualModel and visualModel:IsA("Model") and visualModel:FindFirstChildWhichIsA("BasePart", true) then
		return visualModel
	end
	return nil
end

local function getDisplayBounds(model, upgrade)
	local visualModel = getVisualModel(model)
	if visualModel then
		return visualModel:GetBoundingBox()
	end
	return upgrade.CFrame, upgrade.Size
end

local function removeInteractiveDescendants(instance)
	for _, descendant in instance:GetDescendants() do
		if
			descendant:IsA("ProximityPrompt")
			or descendant:IsA("LuaSourceContainer")
			or descendant:IsA("BillboardGui")
		then
			descendant:Destroy()
		end
	end
end

local function chooseProgressiveTriggerCounts(
	random,
	collectedLeafCount,
	totalLeafCount,
	requestedCount,
	excludedTriggerCounts
)
	local firstTrigger = math.max(1, math.floor(tonumber(collectedLeafCount) or 0) + 1)
	local lastTrigger = math.max(0, math.floor(tonumber(totalLeafCount) or 0))
	local candidates = {}
	for triggerLeafCount = firstTrigger, lastTrigger do
		if not excludedTriggerCounts or excludedTriggerCounts[triggerLeafCount] ~= true then
			table.insert(candidates, triggerLeafCount)
		end
	end
	local triggerCount = math.min(
		#candidates,
		math.max(0, math.floor(tonumber(requestedCount) or 0))
	)
	if triggerCount <= 0 then
		return {}
	end

	local triggers = {}
	for index = 1, triggerCount do
		local selectedIndex = random:NextInteger(index, #candidates)
		candidates[index], candidates[selectedIndex] = candidates[selectedIndex], candidates[index]
		table.insert(triggers, candidates[index])
	end
	table.sort(triggers)
	return triggers
end

local function chooseBaseSpawnCount(random, areaId)
	local configuredChooser = LostItemConfig.ChooseBaseSpawnCount
	if type(configuredChooser) == "function" then
		return configuredChooser(random, areaId)
	end

	local areaConfig = LostItemConfig.Areas and LostItemConfig.Areas[areaId]
	assert(areaConfig, "Unknown lost item area: " .. tostring(areaId))
	local minimum = math.max(
		0,
		math.floor(tonumber(areaConfig.MinimumSpawnCount) or tonumber(LostItemConfig.MinimumSpawnCount) or 3)
	)
	local maximum = math.max(
		minimum,
		math.floor(tonumber(areaConfig.MaximumSpawnCount) or tonumber(LostItemConfig.MaximumSpawnCount) or 6)
	)
	return random:NextInteger(minimum, maximum)
end

local function getTriggerLeafCount(triggerProgress, totalLeafCount)
	local total = math.max(0, math.floor(tonumber(totalLeafCount) or 0))
	if total <= 0 then
		return math.huge
	end
	local progress = math.clamp(tonumber(triggerProgress) or 1, 0, 1)
	return math.clamp(math.ceil(progress * total), 1, total)
end

local function makePersistentSpawnId(player, rebirthCount, areaId, itemIndex)
	return string.format(
		"Run_%d_%d_%s_%04d",
		player.UserId,
		math.max(0, math.floor(tonumber(rebirthCount) or 0)),
		areaId,
		itemIndex
	)
end

function LostItemService:_ensurePlayerSession(player)
	local session = playerSessions[player]
	if session then
		return session
	end
	session = {
		Yards = {},
		Inventory = {},
		LastInventoryLostItemId = nil,
		LastCollectedPositions = {},
		TimedLuckyBoxToken = nil,
		TimedLuckyBoxNextSpawnAt = nil,
		TimedLuckyBoxRewardKind = nil,
		TimedLuckyBoxWaitingForPickup = false,
	}
	playerSessions[player] = session
	return session
end

function LostItemService:_getInventoryStack(playerSession, lostItemId, create)
	local stack = playerSession.Inventory[lostItemId]
	if not stack and create == true then
		stack = {}
		playerSession.Inventory[lostItemId] = stack
	end
	return stack
end

function LostItemService:_getInventorySpawnIds(playerSession)
	local result = {}
	for _, stack in playerSession.Inventory do
		for _, item in stack do
			if type(item.SpawnId) == "string" then
				result[item.SpawnId] = true
			end
		end
	end
	return result
end

function LostItemService:_getInventorySnapshot(playerSession)
	local counts = {}
	local total = 0
	for lostItemId, stack in playerSession.Inventory do
		local count = #stack
		if count > 0 then
			counts[lostItemId] = count
			total += count
		end
	end
	return counts, total
end

function LostItemService:_getPersistentRun(player)
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return nil, nil
	end
	local rebirthCount = math.max(0, math.floor(tonumber(state.RebirthCount) or 0))
	local runProgress = state.LostItemRunProgress
	if
		type(runProgress) ~= "table"
		or math.max(0, math.floor(tonumber(runProgress.RebirthCount) or 0)) ~= rebirthCount
		or type(runProgress.Areas) ~= "table"
	then
		runProgress = {
			RebirthCount = rebirthCount,
			Areas = {},
		}
		state.LostItemRunProgress = runProgress
		self.PlayerDataService:QueuePersistentSave(player)
	end
	return runProgress, state
end

function LostItemService:_getPersistentItem(player, areaId, itemIndex)
	local runProgress = self:_getPersistentRun(player)
	local persistentArea = runProgress and runProgress.Areas[areaId]
	if not persistentArea then
		return nil
	end
	local normalizedIndex = math.floor(tonumber(itemIndex) or 0)
	return persistentArea.Items[normalizedIndex]
end

function LostItemService:_rebuildRuntimeAreaSession(player, areaSession, persistentArea, totalLeafCount)
	areaSession.PersistentArea = persistentArea
	areaSession.BaseSpawnCount = persistentArea.BaseSpawnCount
	areaSession.TotalLeafCount = math.max(0, math.floor(tonumber(totalLeafCount) or 0))
	areaSession.SpawnCount = #persistentArea.Items
	areaSession.PlannedItems = {}
	areaSession.FoundItems = {}
	areaSession.CountedSpawnIds = {}
	areaSession.NextPlannedIndex = 1
	areaSession.NextSpawnSerial = #persistentArea.Items + 1

	local state = self.PlayerDataService:GetState(player)
	local rebirthCount = math.max(0, math.floor(tonumber(state and state.RebirthCount) or 0))
	local validSpawnIds = {}
	for itemIndex, persistentItem in ipairs(persistentArea.Items) do
		local config = LostItemConfig.Types[persistentItem.LostItemId]
		if config and config.PoopOnly ~= true then
			local spawnId = makePersistentSpawnId(player, rebirthCount, areaSession.AreaId, itemIndex)
			validSpawnIds[spawnId] = persistentItem
			table.insert(areaSession.PlannedItems, {
				AreaId = areaSession.AreaId,
				SpawnId = spawnId,
				LostItemId = persistentItem.LostItemId,
				RarityId = config.RarityId,
				LuckyTier = config.LuckyTier,
				Guaranteed = persistentItem.Guaranteed == true,
				TimedRewardKind = persistentItem.TimedRewardKind,
				TriggerProgress = persistentItem.TriggerProgress,
				TriggerLeafCount = getTriggerLeafCount(
					persistentItem.TriggerProgress,
					areaSession.TotalLeafCount
				),
				ItemIndex = itemIndex,
				PersistentItem = persistentItem,
			})
			if persistentItem.Found == true then
				areaSession.CountedSpawnIds[spawnId] = true
				table.insert(areaSession.FoundItems, {
					SpawnId = spawnId,
					LostItemId = persistentItem.LostItemId,
				})
			end
		end
	end
	table.sort(areaSession.PlannedItems, function(left, right)
		local leftProgress = tonumber(left.TriggerProgress) or 1
		local rightProgress = tonumber(right.TriggerProgress) or 1
		if leftProgress == rightProgress then
			return left.ItemIndex < right.ItemIndex
		end
		return leftProgress < rightProgress
	end)

	for spawnId, itemData in areaSession.WorldItems do
		if itemData.PersistentItem then
			local persistentItem = validSpawnIds[spawnId]
			if not persistentItem then
				persistentItem = self:_getPersistentItem(
					player,
					itemData.PlanAreaId,
					itemData.ItemIndex
				)
			end
			if
				not persistentItem
				or persistentItem.Redeemed == true
				or persistentItem.Expired == true
				or persistentItem.Found == true
			then
				areaSession.WorldItems[spawnId] = nil
			else
				itemData.PersistentItem = persistentItem
				itemData.Found = persistentItem.Found == true
				itemData.Guaranteed = persistentItem.Guaranteed == true
				itemData.TimedRewardKind = persistentItem.TimedRewardKind
			end
		end
	end
end

function LostItemService:_getActiveYardKey(player)
	local state = self.PlayerDataService:GetState(player)
	return tostring(state and state.ActiveYardOwnerUserId or player.UserId)
end

function LostItemService:_ensureYardSession(player)
	local playerSession = self:_ensurePlayerSession(player)
	local yardKey = self:_getActiveYardKey(player)
	local yardSession = playerSession.Yards[yardKey]
	if not yardSession then
		yardSession = { OwnerUserId = tonumber(yardKey), Areas = {} }
		playerSession.Yards[yardKey] = yardSession
	end
	return yardSession, yardKey
end

function LostItemService:_ensureAreaSession(player, areaId, allowCompleted)
	local yardSession, yardKey = self:_ensureYardSession(player)
	local existing = yardSession.Areas[areaId]
	local areaCompleted = self.LeafService:IsAreaCompleted(player, areaId)
	local areaConfig = LostItemConfig.Areas[areaId]
	if not areaConfig then
		return nil, false, false
	end
	local runProgress, state = self:_getPersistentRun(player)
	if not state then
		return nil, false, false
	end
	if not self.LeafService:IsAreaGameplayReady(player, areaId) then
		return nil, false, false
	end
	local persistentArea = runProgress.Areas[areaId]
	if existing then
		if persistentArea then
			local _, totalLeafCount = self.LeafService:GetLeafCounts(player, areaId)
			self:_rebuildRuntimeAreaSession(player, existing, persistentArea, totalLeafCount)
			local restored = self:_restorePersistentWorldItems(player, yardKey, existing)
			return existing, false, restored
		end
		return existing, false, false
	end
	if areaCompleted and allowCompleted ~= true and not persistentArea then
		return nil, false, false
	end

	local collectedLeafCount = 0
	local totalLeafCount = 0
	if persistentArea or not areaCompleted then
		collectedLeafCount, totalLeafCount = self.LeafService:GetLeafCounts(player, areaId)
	end
	local createdPersistentPlan = false
	if not persistentArea and not areaCompleted then
		local remainingLeafCount = math.max(0, totalLeafCount - collectedLeafCount)
		if totalLeafCount <= 0 or remainingLeafCount <= 0 then
			return nil, false, false
		end
		local baseSpawnCount = chooseBaseSpawnCount(self.Random, areaId)
		local requestedCount = math.min(baseSpawnCount, remainingLeafCount)
		local triggerLeafCounts = chooseProgressiveTriggerCounts(
			self.Random,
			collectedLeafCount,
			totalLeafCount,
			requestedCount
		)
		local items = {}
		for index, triggerLeafCount in ipairs(triggerLeafCounts) do
			local lostItemId = LostItemConfig.ChooseLostItemId(self.Random, areaId)
			items[index] = {
				LostItemId = lostItemId,
				TriggerProgress = math.clamp(triggerLeafCount / totalLeafCount, 0, 1),
				Triggered = false,
				Found = false,
				Redeemed = false,
				Expired = false,
				Guaranteed = false,
			}
		end
		persistentArea = {
			BaseSpawnCount = baseSpawnCount,
			Items = items,
		}
		runProgress.Areas[areaId] = persistentArea
		createdPersistentPlan = true
		self.PlayerDataService:QueuePersistentSave(player)
	end

	local areaSession = {
		AreaId = areaId,
		SpawnMode = areaConfig.SpawnMode,
		BaseSpawnCount = persistentArea and persistentArea.BaseSpawnCount or 0,
		SpawnCount = persistentArea and #persistentArea.Items or 0,
		TotalLeafCount = totalLeafCount,
		PlannedItems = {},
		NextPlannedIndex = 1,
		WorldItems = {},
		FoundItems = {},
		CountedSpawnIds = {},
		NextSpawnSerial = persistentArea and #persistentArea.Items + 1 or 1,
		PersistentArea = persistentArea,
	}
	yardSession.Areas[areaId] = areaSession
	if persistentArea then
		self:_rebuildRuntimeAreaSession(player, areaSession, persistentArea, totalLeafCount)
	end
	local restored = persistentArea and self:_restorePersistentWorldItems(player, yardKey, areaSession) or false
	if self.MetricsService and createdPersistentPlan and #persistentArea.Items > 0 then
		self.MetricsService:RecordLostItemPlan(player, areaId, #persistentArea.Items)
	end
	return areaSession, true, restored
end

function LostItemService:_isCandidateOccupied(areaSession, position)
	for _, itemData in areaSession.WorldItems do
		if (itemData.Center - position).Magnitude <= itemData.Radius * 2 then
			return true
		end
	end
	return false
end

function LostItemService:_chooseLeafPosition(player, areaSession)
	local entries = self.LeafService:GetActiveLeafEntries(player, areaSession.AreaId)
	local candidates = {}
	for _, entry in entries do
		local position = entry.BoundingCFrame.Position
		if not self:_isCandidateOccupied(areaSession, position) then
			table.insert(candidates, position)
		end
	end
	if #candidates == 0 then
		for _, entry in entries do
			table.insert(candidates, entry.BoundingCFrame.Position)
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[self.Random:NextInteger(1, #candidates)]
end

function LostItemService:_makeWorldItem(areaId, lostItemId, spawnId, targetPosition, found)
	local luckyTier = LostItemConfig.GetLuckyTier(lostItemId)
	local templateData = luckyTier and self.LuckyBoxTemplateData[luckyTier] or nil
	local raycastParams = self.AreaRaycastParams[areaId]
	if not templateData or not raycastParams or typeof(targetPosition) ~= "Vector3" then
		return nil
	end

	local rayResult = Workspace:Raycast(
		targetPosition + Vector3.new(0, 25, 0),
		Vector3.new(0, -60, 0),
		raycastParams
	)
	local groundPosition = rayResult and rayResult.Position or targetPosition
	local yaw = self.Random:NextNumber(0, math.pi * 2)
	local targetBaseCFrame = CFrame.new(groundPosition + Vector3.new(0, templateData.Base.Size.Y / 2, 0))
		* CFrame.Angles(0, yaw, 0)
	local worldTransform = targetBaseCFrame * templateData.Base.CFrame:Inverse()
	local worldPivotCFrame = worldTransform * templateData.Template:GetPivot()
	return {
		AreaId = areaId,
		PlanAreaId = areaId,
		LostItemId = lostItemId,
		LuckyTier = luckyTier,
		SpawnId = spawnId,
		WorldPivotCFrame = worldPivotCFrame,
		Found = found == true,
		Buried = false,
		Center = targetBaseCFrame.Position,
		Radius = templateData.Radius,
	}
end

function LostItemService:_chooseProgressiveSpawnPosition(areaId, collectedPosition)
	local raycastParams = self.AreaRaycastParams[areaId]
	if not raycastParams or typeof(collectedPosition) ~= "Vector3" then
		return collectedPosition
	end
	for _ = 1, LostItemConfig.ProgressiveSpawnGroundAttempts do
		local angle = self.Random:NextNumber(0, math.pi * 2)
		local radius = math.sqrt(self.Random:NextNumber()) * LostItemConfig.ProgressiveSpawnRadius
		local candidate = collectedPosition
			+ Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local rayResult = Workspace:Raycast(
			candidate + Vector3.new(0, 25, 0),
			Vector3.new(0, -60, 0),
			raycastParams
		)
		if rayResult then
			return rayResult.Position
		end
	end
	return collectedPosition
end

function LostItemService:_chooseAreaGroundPosition(areaId)
	local samples = self.AreaGroundSamples and self.AreaGroundSamples[areaId]
	if not samples or samples.TotalWeight <= 0 then
		return nil
	end
	local roll = self.Random:NextNumber(0, samples.TotalWeight)
	local selected = samples.Entries[#samples.Entries]
	for _, entry in samples.Entries do
		if roll <= entry.CumulativeWeight then
			selected = entry
			break
		end
	end
	if not selected then
		return nil
	end
	local part = selected.Part
	local localPoint = Vector3.new(
		self.Random:NextNumber(-part.Size.X / 2, part.Size.X / 2),
		part.Size.Y / 2,
		self.Random:NextNumber(-part.Size.Z / 2, part.Size.Z / 2)
	)
	local candidate = part.CFrame:PointToWorldSpace(localPoint)
	local rayResult = Workspace:Raycast(
		candidate + Vector3.new(0, 25, 0),
		Vector3.new(0, -60, 0),
		self.AreaRaycastParams[areaId]
	)
	return rayResult and rayResult.Position or candidate
end

function LostItemService:_removePersistentWorldProjections(playerSession, keepYardKey, keepAreaId, spawnId)
	for yardKey, yardSession in playerSession.Yards do
		for areaId, areaSession in yardSession.Areas do
			if yardKey ~= keepYardKey or (keepAreaId ~= nil and areaId ~= keepAreaId) then
				local itemData = areaSession.WorldItems[spawnId]
				if itemData and itemData.PersistentItem then
					areaSession.WorldItems[spawnId] = nil
				end
			end
		end
	end
end

function LostItemService:_findPersistentWorldProjection(playerSession, yardKey, spawnId)
	local yardSession = playerSession.Yards[yardKey]
	local foundAreaSession = nil
	local foundItemData = nil
	local removedDuplicate = false
	for _, areaSession in yardSession and yardSession.Areas or {} do
		local itemData = areaSession.WorldItems[spawnId]
		if itemData and itemData.PersistentItem then
			if not foundItemData then
				foundAreaSession = areaSession
				foundItemData = itemData
			else
				areaSession.WorldItems[spawnId] = nil
				removedDuplicate = true
			end
		end
	end
	return foundAreaSession, foundItemData, removedDuplicate
end

function LostItemService:_restorePersistentWorldItems(player, yardKey, areaSession)
	if not areaSession.PersistentArea then
		return false
	end
	local playerSession = self:_ensurePlayerSession(player)
	local inventorySpawnIds = self:_getInventorySpawnIds(playerSession)
	local changed = false
	for _, plannedItem in areaSession.PlannedItems do
		local persistentItem = plannedItem.PersistentItem
		local spawnId = plannedItem.SpawnId
		local pendingReveal = pendingReveals[player]
		local revealPendingForSpawn = pendingReveal
			and pendingReveal.ItemData
			and pendingReveal.ItemData.SpawnId == spawnId
		if revealPendingForSpawn then
			if areaSession.WorldItems[spawnId] then
				areaSession.WorldItems[spawnId] = nil
				changed = true
			end
		elseif
			persistentItem.Redeemed == true
			or persistentItem.Expired == true
			or persistentItem.Found == true
			or inventorySpawnIds[spawnId] == true
		then
			if areaSession.WorldItems[spawnId] then
				areaSession.WorldItems[spawnId] = nil
				changed = true
			end
			self:_removePersistentWorldProjections(playerSession, nil, nil, spawnId)
		elseif persistentItem.Triggered == true then
			self:_removePersistentWorldProjections(playerSession, yardKey, nil, spawnId)
			local _, projectedItem, removedDuplicate = self:_findPersistentWorldProjection(
				playerSession,
				yardKey,
				spawnId
			)
			if removedDuplicate then
				changed = true
			end
			if projectedItem then
				projectedItem.PersistentItem = persistentItem
				projectedItem.ItemIndex = plannedItem.ItemIndex
				projectedItem.PlanAreaId = areaSession.AreaId
				projectedItem.Found = persistentItem.Found == true
				projectedItem.Guaranteed = persistentItem.Guaranteed == true
			end
		end
	end
	return changed
end

function LostItemService:_applyPendingLuckyBoxGuarantee(player, plannedItem)
	local state = self.PlayerDataService:GetState(player)
	local onboarding = state and state.LuckyBoxOnboarding
	local persistentItem = plannedItem and plannedItem.PersistentItem
	if
		type(onboarding) ~= "table"
		or onboarding.HighTierGuaranteePending ~= true
		or onboarding.HighTierGuaranteeCompleted == true
		or type(persistentItem) ~= "table"
	then
		return plannedItem and plannedItem.Guaranteed == true
	end

	local luckyTier = LostItemConfig.GetLuckyTier(plannedItem.LostItemId)
	if not luckyTier then
		return false
	end
	if luckyTier < 4 then
		local guaranteedLostItemId, guaranteedRarityId = LostItemConfig.ChooseLostItemIdForTier(
			self.Random,
			4
		)
		persistentItem.LostItemId = guaranteedLostItemId
		plannedItem.LostItemId = guaranteedLostItemId
		plannedItem.RarityId = guaranteedRarityId
		plannedItem.LuckyTier = 4
	else
		plannedItem.LuckyTier = luckyTier
	end
	persistentItem.Guaranteed = true
	plannedItem.Guaranteed = true
	onboarding.LowTierPickupCount = 3
	onboarding.HighTierGuaranteePending = false
	onboarding.HighTierGuaranteeCompleted = true
	self.PlayerDataService:QueuePersistentSave(player)
	return true
end

function LostItemService:_findOutstandingTimedLuckyBox(player)
	local runProgress, state = self:_getPersistentRun(player)
	if not runProgress or not state then
		return nil
	end

	for _, areaId in RegionConfig.PersistentOrder do
		local persistentArea = runProgress.Areas[areaId]
		for itemIndex, persistentItem in ipairs(persistentArea and persistentArea.Items or {}) do
			local timedRewardKind = persistentItem.TimedRewardKind
			if
				(timedRewardKind == TIMED_REWARD_KIND_FIRST
					or timedRewardKind == TIMED_REWARD_KIND_RECURRING)
				and persistentItem.Found ~= true
				and persistentItem.Redeemed ~= true
				and persistentItem.Expired ~= true
			then
				return {
					AreaId = areaId,
					ItemIndex = itemIndex,
					PersistentItem = persistentItem,
					RewardKind = timedRewardKind,
				}
			end
		end
	end
	return nil
end

function LostItemService:_chooseTimedLuckyTier()
	local totalWeight = 0
	for luckyTier = 4, 5 do
		totalWeight += math.max(0, tonumber(TIMED_LUCKY_BOX.TierWeights[luckyTier]) or 0)
	end
	if totalWeight <= 0 then
		return 4
	end

	local roll = self.Random:NextNumber(0, totalWeight)
	local cumulativeWeight = 0
	for luckyTier = 4, 5 do
		cumulativeWeight += math.max(0, tonumber(TIMED_LUCKY_BOX.TierWeights[luckyTier]) or 0)
		if roll <= cumulativeWeight then
			return luckyTier
		end
	end
	return 5
end

function LostItemService:_chooseTimedLuckyBoxSpawnPosition(player, areaSession)
	local areaId = areaSession.AreaId
	local playerSession = self:_ensurePlayerSession(player)
	local candidatePositions = {}
	local lastCollectedPosition = playerSession.LastCollectedPositions[areaId]
	if typeof(lastCollectedPosition) == "Vector3" then
		table.insert(candidatePositions, lastCollectedPosition)
	end
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		table.insert(candidatePositions, rootPart.Position)
	end
	local leafPosition = self:_chooseLeafPosition(player, areaSession)
	if leafPosition then
		table.insert(candidatePositions, leafPosition)
	end

	local raycastParams = self.AreaRaycastParams[areaId]
	for _, candidatePosition in candidatePositions do
		local projectedPosition = self:_chooseProgressiveSpawnPosition(areaId, candidatePosition)
		local rayResult = raycastParams and Workspace:Raycast(
			projectedPosition + Vector3.new(0, 25, 0),
			Vector3.new(0, -60, 0),
			raycastParams
		)
		if rayResult then
			return rayResult.Position
		end
	end
	return self:_chooseAreaGroundPosition(areaId)
end

function LostItemService:_spawnTimedLuckyBox(player, rewardKind)
	if rewardKind ~= TIMED_REWARD_KIND_FIRST and rewardKind ~= TIMED_REWARD_KIND_RECURRING then
		return false
	end
	local state = self.PlayerDataService:GetState(player)
	local onboarding = state and state.LuckyBoxOnboarding
	if type(onboarding) ~= "table" then
		return false
	end
	local outstanding = self:_findOutstandingTimedLuckyBox(player)
	if outstanding then
		local playerSession = self:_ensurePlayerSession(player)
		playerSession.TimedLuckyBoxNextSpawnAt = nil
		playerSession.TimedLuckyBoxRewardKind = outstanding.RewardKind
		playerSession.TimedLuckyBoxWaitingForPickup = true
		if
			outstanding.RewardKind == TIMED_REWARD_KIND_FIRST
			and onboarding.FirstTimedHighTierBoxSpawned ~= true
		then
			onboarding.FirstTimedHighTierBoxSpawned = true
			self.PlayerDataService:QueuePersistentSave(player)
		end
		self.PlayerDataService:PushSnapshot(player)
		return true
	end
	local areaId = type(state.CurrentAreaId) == "string" and state.CurrentAreaId or "Area_01"
	if not LostItemConfig.Areas[areaId] then
		areaId = "Area_01"
	end
	if not self.LeafService:IsAreaGameplayReady(player, areaId) then
		return false
	end
	local areaSession = self:_ensureAreaSession(player, areaId, true)
	if not areaSession then
		return false
	end
	local runProgress = self:_getPersistentRun(player)
	if not runProgress then
		return false
	end
	local persistentArea = runProgress.Areas[areaId]
	local createdPersistentArea = false
	if not persistentArea then
		persistentArea = {
			BaseSpawnCount = chooseBaseSpawnCount(self.Random, areaId),
			Items = {},
		}
		runProgress.Areas[areaId] = persistentArea
		createdPersistentArea = true
	end

	local luckyTier = self:_chooseTimedLuckyTier()
	local lostItemId, rarityId = LostItemConfig.ChooseLostItemIdForTier(self.Random, luckyTier)
	local itemIndex = #persistentArea.Items + 1
	local persistentItem = {
		LostItemId = lostItemId,
		TriggerProgress = 0,
		Triggered = true,
		Found = false,
		Redeemed = false,
		Expired = false,
		Guaranteed = false,
		TimedRewardKind = rewardKind,
	}
	table.insert(persistentArea.Items, persistentItem)

	local _, totalLeafCount = self.LeafService:GetLeafCounts(player, areaId)
	self:_rebuildRuntimeAreaSession(player, areaSession, persistentArea, totalLeafCount)
	local spawnPosition = self:_chooseTimedLuckyBoxSpawnPosition(player, areaSession)
	local spawnId = makePersistentSpawnId(player, state.RebirthCount, areaId, itemIndex)
	local worldItem = spawnPosition
		and self:_makeWorldItem(areaId, lostItemId, spawnId, spawnPosition, false)
		or nil
	if not worldItem then
		table.remove(persistentArea.Items, itemIndex)
		if createdPersistentArea and #persistentArea.Items == 0 then
			runProgress.Areas[areaId] = nil
		end
		self:_rebuildRuntimeAreaSession(player, areaSession, persistentArea, totalLeafCount)
		return false
	end

	worldItem.PersistentItem = persistentItem
	worldItem.ItemIndex = itemIndex
	worldItem.Guaranteed = false
	worldItem.TimedRewardKind = rewardKind
	areaSession.WorldItems[spawnId] = worldItem
	if rewardKind == TIMED_REWARD_KIND_FIRST then
		onboarding.FirstTimedHighTierBoxSpawned = true
	end
	local playerSession = self:_ensurePlayerSession(player)
	playerSession.TimedLuckyBoxNextSpawnAt = nil
	playerSession.TimedLuckyBoxRewardKind = rewardKind
	playerSession.TimedLuckyBoxWaitingForPickup = true
	self.PlayerDataService:QueuePersistentSave(player)
	if self.MetricsService then
		local spawnSource = getSpawnSource(rewardKind)
		self.MetricsService:RecordLostItemPlan(player, areaId, 1, spawnSource)
		self.MetricsService:RecordLostItemSpawned(
			player,
			areaId,
			lostItemId,
			rarityId,
			0,
			luckyTier,
			false,
			spawnSource
		)
	end
	self.PlayerDataService:PushSnapshot(player)
	return true
end

function LostItemService:_scheduleTimedLuckyBox(player, forceRestart)
	local state = self.PlayerDataService:GetState(player)
	local onboarding = state and state.LuckyBoxOnboarding
	if type(onboarding) ~= "table" then
		return
	end
	local playerSession = self:_ensurePlayerSession(player)
	if playerSession.TimedLuckyBoxToken ~= nil and forceRestart ~= true then
		return
	end

	local outstanding = self:_findOutstandingTimedLuckyBox(player)
	if outstanding then
		playerSession.TimedLuckyBoxToken = nil
		playerSession.TimedLuckyBoxNextSpawnAt = nil
		playerSession.TimedLuckyBoxRewardKind = outstanding.RewardKind
		playerSession.TimedLuckyBoxWaitingForPickup = true
		if
			outstanding.RewardKind == TIMED_REWARD_KIND_FIRST
			and onboarding.FirstTimedHighTierBoxSpawned ~= true
		then
			onboarding.FirstTimedHighTierBoxSpawned = true
			self.PlayerDataService:QueuePersistentSave(player)
		end
		self.PlayerDataService:PushSnapshot(player)
		return
	end

	local rewardKind = if onboarding.FirstTimedHighTierBoxSpawned == true
		then TIMED_REWARD_KIND_RECURRING
		else TIMED_REWARD_KIND_FIRST
	local delaySeconds = if rewardKind == TIMED_REWARD_KIND_FIRST
		then TIMED_LUCKY_BOX.FirstDelaySeconds
		else TIMED_LUCKY_BOX.RecurringDelaySeconds
	local token = {}
	playerSession.TimedLuckyBoxToken = token
	playerSession.TimedLuckyBoxNextSpawnAt = Workspace:GetServerTimeNow() + delaySeconds
	playerSession.TimedLuckyBoxRewardKind = rewardKind
	playerSession.TimedLuckyBoxWaitingForPickup = false
	self.PlayerDataService:PushSnapshot(player)

	task.delay(delaySeconds, function()
		local attemptSpawn
		attemptSpawn = function()
			if
				player.Parent ~= Players
				or playerSessions[player] ~= playerSession
				or playerSession.TimedLuckyBoxToken ~= token
			then
				return
			end

			local succeeded, spawned = pcall(function()
				return self:_spawnTimedLuckyBox(player, rewardKind)
			end)
			if succeeded and spawned then
				playerSession.TimedLuckyBoxToken = nil
				return
			end
			if not succeeded and playerSession.TimedLuckyBoxWarningShown ~= true then
				playerSession.TimedLuckyBoxWarningShown = true
				warn(
					string.format(
						"Timed lucky-box spawn failed for player %d: %s",
						player.UserId,
						tostring(spawned)
					)
				)
			end
			task.delay(TIMED_LUCKY_BOX.RetryDelaySeconds, attemptSpawn)
		end
		attemptSpawn()
	end)
end

function LostItemService:_spawnProgressiveItemsAtPosition(
	player,
	areaSession,
	collectedLeafCount,
	collectedPosition
)
	if
		areaSession.SpawnMode ~= PROGRESSIVE_SPAWN_MODE
		or typeof(collectedPosition) ~= "Vector3"
		or self.LeafService:IsAreaCompleted(player, areaSession.AreaId)
	then
		return false
	end
	local normalizedCollectedCount = math.max(0, math.floor(tonumber(collectedLeafCount) or 0))
	local totalLeafCount = math.max(0, math.floor(tonumber(areaSession.TotalLeafCount) or 0))
	local triggerProgress = if totalLeafCount > 0
		then math.clamp(normalizedCollectedCount / totalLeafCount, 0, 1)
		else 0
	local spawnedAny = false
	while areaSession.NextPlannedIndex <= #areaSession.PlannedItems do
		local plannedItem = areaSession.PlannedItems[areaSession.NextPlannedIndex]
		local persistentItem = plannedItem.PersistentItem
		if persistentItem and persistentItem.Triggered == true then
			areaSession.NextPlannedIndex += 1
			continue
		end
		if (tonumber(plannedItem.TriggerLeafCount) or math.huge) > normalizedCollectedCount then
			break
		end
		local guaranteed = self:_applyPendingLuckyBoxGuarantee(player, plannedItem)
		local spawnPosition = self:_chooseProgressiveSpawnPosition(
			areaSession.AreaId,
			collectedPosition
		)
		local worldItem = self:_makeWorldItem(
			areaSession.AreaId,
			plannedItem.LostItemId,
			plannedItem.SpawnId,
			spawnPosition,
			false
		)
		if not worldItem then
			break
		end
		worldItem.PersistentItem = persistentItem
		worldItem.ItemIndex = plannedItem.ItemIndex
		worldItem.Guaranteed = guaranteed == true
		worldItem.TimedRewardKind = persistentItem and persistentItem.TimedRewardKind or nil
		areaSession.WorldItems[plannedItem.SpawnId] = worldItem
		if persistentItem then
			persistentItem.Triggered = true
		end
		areaSession.NextPlannedIndex += 1
		spawnedAny = true
		if self.MetricsService then
			self.MetricsService:RecordLostItemSpawned(
				player,
				areaSession.AreaId,
				plannedItem.LostItemId,
				plannedItem.RarityId,
				tonumber(plannedItem.TriggerProgress) or triggerProgress,
				plannedItem.LuckyTier,
				guaranteed == true,
				getSpawnSource(worldItem.TimedRewardKind)
			)
		end
	end
	if spawnedAny then
		self.PlayerDataService:QueuePersistentSave(player)
	end
	return spawnedAny
end

function LostItemService:OnTeamLeafRemoved(
	influencingPlayer,
	areaId,
	collectedPosition,
	collectedLeafCount,
	_,
	yardOwnerUserId
)
	if areaId == LeafConfig.Lobby.AreaId then
		return
	end
	if influencingPlayer and typeof(collectedPosition) == "Vector3" then
		local playerSession = self:_ensurePlayerSession(influencingPlayer)
		playerSession.LastCollectedPositions[areaId] = collectedPosition
	end
	local areaConfig = LostItemConfig.Areas[areaId]
	if
		areaConfig
		and areaConfig.SpawnMode == PROGRESSIVE_SPAWN_MODE
		and typeof(collectedPosition) == "Vector3"
	then
		local resolvedOwnerUserId = math.floor(tonumber(yardOwnerUserId) or 0)
		if resolvedOwnerUserId <= 0 and influencingPlayer then
			local influencingState = self.PlayerDataService:GetState(influencingPlayer)
			resolvedOwnerUserId = math.floor(
				tonumber(influencingState and influencingState.ActiveYardOwnerUserId) or influencingPlayer.UserId
			)
		end
		if resolvedOwnerUserId > 0 then
			local ownerKey = tostring(resolvedOwnerUserId)
			for _, player in Players:GetPlayers() do
				local state = self.PlayerDataService:GetState(player)
				local activeOwnerUserId = state
					and math.floor(tonumber(state.ActiveYardOwnerUserId) or player.UserId)
				local isActiveYard = activeOwnerUserId == resolvedOwnerUserId
				local playerSession = playerSessions[player]
				if isActiveYard and not playerSession then
					playerSession = self:_ensurePlayerSession(player)
				end
				local yardSession = playerSession and playerSession.Yards[ownerKey]
				local areaSession = yardSession and yardSession.Areas[areaId]
				local created = false
				if
					isActiveYard
					and not areaSession
					and self.LeafService:IsAreaGameplayReady(player, areaId)
				then
					areaSession, created = self:_ensureAreaSession(player, areaId)
				end
				local spawned = areaSession
					and self:_spawnProgressiveItemsAtPosition(
						player,
						areaSession,
						collectedLeafCount,
						collectedPosition
					)
				if
					isActiveYard
					and (created or spawned)
					and self.PlayerDataService:GetState(player)
				then
					self.PlayerDataService:PushSnapshot(player)
				end
			end
		end
	end
end

function LostItemService:_ensureUnlockedAreaSessions(player)
	if not self.PlayerDataService:GetState(player) then
		return
	end
	for _, areaId in RegionConfig.Order do
		if self.LeafService:IsAreaGameplayReady(player, areaId) then
			self:_ensureAreaSession(player, areaId)
		end
	end
end

function LostItemService:_onAreaGameplayReady(areaId)
	for _, player in Players:GetPlayers() do
		if self.PlayerDataService:GetState(player) and self.LeafService:IsAreaGameplayReady(player, areaId) then
			local _, created, spawned = self:_ensureAreaSession(player, areaId)
			if (created or spawned) and self.PlayerDataService:GetState(player) then
				self.PlayerDataService:PushSnapshot(player)
			end
		end
	end
end

function LostItemService:_getInventoryStackRedeemCoinValue(player, lostItemId, stack)
	if LostItemConfig.IsPoopItemId(lostItemId) then
		local total = 0
		for _, itemData in stack or {} do
			total += LostItemConfig.GetPoopRedeemCoinValue(
				lostItemId,
				tonumber(itemData.CreatorUserId) == player.UserId
			)
		end
		return total
	end
	local playerState = self.PlayerDataService:GetState(player)
	local leafValueMultiplier = tonumber(playerState and playerState.LeafValueMultiplier)
		or tonumber(playerState and playerState.CoinMultiplier)
		or 1
	return LostItemConfig.GetRedeemCoinValue(lostItemId, leafValueMultiplier)
end

function LostItemService:_updateCarryToolRedeemValue(player, tool, lostItemId, stack)
	local redeemCoinValue = self:_getInventoryStackRedeemCoinValue(player, lostItemId, stack)
	tool:SetAttribute("StackRedeemCoinValue", redeemCoinValue)
	local handle = tool:FindFirstChild("Handle")
	local billboard = handle and handle:FindFirstChild("BillboardGui")
	local frame = billboard and billboard:FindFirstChild("Frame")
	local textLabel = frame and frame:FindFirstChild("TextLabel")
	if textLabel and textLabel:IsA("TextLabel") then
		textLabel.Text = CoinFormat.Compact(redeemCoinValue)
	end
end

function LostItemService:_createCarryTool(player, lostItemId, stack)
	local templateData = self.TemplateData[lostItemId]
	local config = LostItemConfig.Types[lostItemId]
	if not templateData or not config then
		return nil
	end

	local tool = Instance.new("Tool")
	tool.Name = config.DisplayName
	tool.ToolTip = config.DisplayName
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.Enabled = false
	tool.ManualActivationOnly = true
	tool.Grip = config.Grip
	if type(config.Image) == "string" then
		tool.TextureId = config.Image
	end
	tool:SetAttribute("LostItemCarry", true)
	tool:SetAttribute("LostItemId", lostItemId)
	tool:SetAttribute("SpawnId", "Inventory_" .. lostItemId)
	tool:SetAttribute("StackedCollectible", true)
	tool:SetAttribute("StackCount", 1)
	tool:SetAttribute("HotbarOrder", LOST_ITEM_HOTBAR_ORDER)

	local handle = templateData.Upgrade:Clone()
	removeInteractiveDescendants(handle)
	handle.Name = "Handle"
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanTouch = false
	handle.CanQuery = false
	handle.Massless = true
	handle.Parent = tool
	local valueBillboard = self.ValueBillboardTemplate:Clone()
	valueBillboard.Name = "BillboardGui"
	valueBillboard.Frame.TextLabel.Text = CoinFormat.Compact(
		self:_getInventoryStackRedeemCoinValue(player, lostItemId, stack)
	)
	valueBillboard.Frame.ImageLabel.Image = LostItemConfig.CoinImage
	valueBillboard.Enabled = true
	valueBillboard.Parent = handle

	local sourceVisual = getVisualModel(templateData.Template)
	if sourceVisual then
		handle.Transparency = 1
		handle.CastShadow = false
		local visualClone = sourceVisual:Clone()
		removeInteractiveDescendants(visualClone)
		visualClone.Parent = tool
		for _, descendant in visualClone:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = false
				descendant.CanCollide = false
				descendant.CanTouch = false
				descendant.CanQuery = false
				descendant.Massless = true
				local weld = Instance.new("WeldConstraint")
				weld.Name = "LostItemWeld"
				weld.Part0 = handle
				weld.Part1 = descendant
				weld.Parent = handle
			end
		end
	end
	return tool
end

function LostItemService:_findCarryTool(player, lostItemId)
	for _, container in { player.Character, player:FindFirstChildOfClass("Backpack") } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool")
					and child:GetAttribute("LostItemCarry") == true
					and (not lostItemId or child:GetAttribute("LostItemId") == lostItemId)
				then
					return child
				end
			end
		end
	end
	return nil
end

function LostItemService:_syncInventoryTool(player, lostItemId, shouldEquip)
	local playerSession = self:_ensurePlayerSession(player)
	local stack = self:_getInventoryStack(playerSession, lostItemId, false)
	local count = stack and #stack or 0
	local tool = self:_findCarryTool(player, lostItemId)
	if count <= 0 then
		if tool then
			tool:Destroy()
		end
		return nil
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not backpack or not humanoid or humanoid.Health <= 0 then
		return tool
	end
	if not tool then
		tool = self:_createCarryTool(player, lostItemId, stack)
		if not tool then
			return nil
		end
		tool.Equipped:Connect(function()
			local currentSession = playerSessions[player]
			if currentSession then
				currentSession.LastInventoryLostItemId = lostItemId
			end
		end)
		tool.Parent = backpack
	end
	tool:SetAttribute("StackCount", count)
	self:_updateCarryToolRedeemValue(player, tool, lostItemId, stack)
	if shouldEquip == true then
		playerSession.LastInventoryLostItemId = lostItemId
		humanoid:EquipTool(tool)
	end
	return tool
end

function LostItemService:_findWorldItem(player, playerSession, spawnId)
	local yardSession = playerSession.Yards[self:_getActiveYardKey(player)]
	for _, areaSession in yardSession and yardSession.Areas or {} do
		local itemData = areaSession.WorldItems[spawnId]
		if itemData then
			return areaSession, itemData
		end
	end
	return nil, nil
end

function LostItemService:_addInventoryItem(player, itemData, shouldEquip, allowDeferredTool)
	local config = itemData and LostItemConfig.Types[itemData.LostItemId]
	if not config then
		return false
	end
	local playerSession = self:_ensurePlayerSession(player)
	local stack = self:_getInventoryStack(playerSession, itemData.LostItemId, true)
	table.insert(stack, itemData)
	local syncSucceeded, tool = pcall(function()
		return self:_syncInventoryTool(player, itemData.LostItemId, shouldEquip)
	end)
	if syncSucceeded and (tool or allowDeferredTool == true) then
		return true
	end
	table.remove(stack, #stack)
	if #stack <= 0 then
		playerSession.Inventory[itemData.LostItemId] = nil
	end
	if not syncSucceeded then
		warn("Lost item inventory tool sync failed: " .. tostring(tool))
	end
	return false
end

function LostItemService:AddSpecialCollectible(player, lostItemId, metadata)
	local config = LostItemConfig.Types[lostItemId]
	if not config or config.PoopOnly ~= true then
		return false
	end
	metadata = type(metadata) == "table" and metadata or {}
	local itemData = {
		SourceYardOwnerUserId = tonumber(metadata.SourceYardOwnerUserId),
		SourceAreaId = metadata.SourceAreaId,
		LostItemId = lostItemId,
		SpawnId = tostring(metadata.SpawnId or ("Special_" .. game:GetService("HttpService"):GenerateGUID(false))),
		CreatorUserId = tonumber(metadata.CreatorUserId),
		SpecialOnly = true,
	}
	local added = self:_addInventoryItem(player, itemData, false)
	if added then
		local followUpSucceeded, followUpError = pcall(function()
			self:_syncInventoryTool(player, lostItemId, true)
			self.PlayerDataService:PushSnapshot(player)
		end)
		if not followUpSucceeded then
			warn("Special collectible follow-up sync failed: " .. tostring(followUpError))
		end
	end
	return added
end

function LostItemService:_broadcastReveal(player, payload)
	local openerState = self.PlayerDataService:GetState(player)
	local openerYardOwnerUserId = openerState
		and math.floor(tonumber(openerState.ActiveYardOwnerUserId) or player.UserId)
		or player.UserId
	local openerCharacter = player.Character
	local openerRoot = openerCharacter and openerCharacter:FindFirstChild("HumanoidRootPart")
	for _, recipient in Players:GetPlayers() do
		local shouldSend = recipient == player
		if not shouldSend and openerRoot and openerRoot:IsA("BasePart") then
			local recipientState = self.PlayerDataService:GetState(recipient)
			local recipientYardOwnerUserId = recipientState
				and math.floor(tonumber(recipientState.ActiveYardOwnerUserId) or recipient.UserId)
			local recipientCharacter = recipient.Character
			local recipientRoot = recipientCharacter and recipientCharacter:FindFirstChild("HumanoidRootPart")
			shouldSend = recipientYardOwnerUserId == openerYardOwnerUserId
				and recipientRoot ~= nil
				and recipientRoot:IsA("BasePart")
				and (recipientRoot.Position - openerRoot.Position).Magnitude <= NEARBY_REVEAL_RADIUS
		end
		if shouldSend then
			self.RevealRemote:FireClient(recipient, payload)
		end
	end
end

function LostItemService:_recordLuckyBoxPickup(player, luckyTier)
	if type(luckyTier) ~= "number" or luckyTier > 3 then
		return
	end
	local state = self.PlayerDataService:GetState(player)
	local onboarding = state and state.LuckyBoxOnboarding
	if
		type(onboarding) ~= "table"
		or onboarding.HighTierGuaranteeCompleted == true
		or onboarding.HighTierGuaranteePending == true
	then
		return
	end
	onboarding.LowTierPickupCount = math.clamp(
		math.floor(tonumber(onboarding.LowTierPickupCount) or 0) + 1,
		0,
		3
	)
	if onboarding.LowTierPickupCount >= 3 then
		onboarding.HighTierGuaranteePending = true
	end
	self.PlayerDataService:QueuePersistentSave(player)
end

function LostItemService:_sendRevealCompleted(player, pending, succeeded, isNew)
	local inventoryItem = pending and pending.InventoryItem
	if
		player.Parent ~= Players
		or not pending
		or type(pending.RevealId) ~= "string"
		or not inventoryItem
		or type(inventoryItem.LostItemId) ~= "string"
	then
		return
	end
	self.RevealCompletedRemote:FireClient(player, {
		RevealId = pending.RevealId,
		LostItemId = inventoryItem.LostItemId,
		Succeeded = succeeded == true,
		IsNew = succeeded == true and isNew == true,
	})
end

function LostItemService:_finalizePendingReveal(player, revealId)
	local pending = pendingReveals[player]
	if not pending or pending.RevealId ~= revealId then
		return
	end
	pendingReveals[player] = nil
	if player.Parent ~= Players then
		return
	end
	local state = self.PlayerDataService:GetState(player)
	if not state then
		self:_sendRevealCompleted(player, pending, false, false)
		return
	end

	if not self:_addInventoryItem(player, pending.InventoryItem, false, true) then
		if pending.AreaSession and pending.ItemData then
			pending.AreaSession.WorldItems[pending.ItemData.SpawnId] = pending.ItemData
		end
		self.PlayerDataService:PushSnapshot(player)
		self:_sendRevealCompleted(player, pending, false, false)
		return
	end

	local itemData = pending.ItemData
	local areaSession = pending.AreaSession
	local persistentItem = itemData.PersistentItem
	local firstPickup = if persistentItem then persistentItem.Found ~= true else itemData.Found ~= true
	if firstPickup then
		itemData.Found = true
		if persistentItem then
			persistentItem.Triggered = true
			persistentItem.Found = true
			persistentItem.Expired = false
		end
	end

	local isNew = false
	if firstPickup and not areaSession.CountedSpawnIds[itemData.SpawnId] then
		areaSession.CountedSpawnIds[itemData.SpawnId] = true
		table.insert(areaSession.FoundItems, {
			SpawnId = itemData.SpawnId,
			LostItemId = itemData.LostItemId,
		})
		local collectedCount = self.PlayerDataService:IncrementLostItemCollected(player, itemData.LostItemId)
		isNew = collectedCount == 1
		self:_recordLuckyBoxPickup(player, itemData.LuckyTier)
		if self.MetricsService then
			local config = LostItemConfig.Types[itemData.LostItemId]
			self.MetricsService:RecordLostItemFound(
				player,
				itemData.PlanAreaId or areaSession.AreaId,
				itemData.LostItemId,
				config.RarityId,
				itemData.LuckyTier,
				itemData.Guaranteed == true,
				isNew,
				getSpawnSource(itemData.TimedRewardKind)
			)
		end
	end
	if persistentItem then
		self:_removePersistentWorldProjections(
			self:_ensurePlayerSession(player),
			nil,
			nil,
			itemData.SpawnId
		)
		self.PlayerDataService:QueuePersistentSave(player)
	end
	local config = LostItemConfig.Types[itemData.LostItemId]
	self.PlayerDataService:Notify(player, "Found " .. config.DisplayName .. ".")
	if itemData.TimedRewardKind ~= nil then
		local playerSession = self:_ensurePlayerSession(player)
		playerSession.TimedLuckyBoxNextSpawnAt = nil
		playerSession.TimedLuckyBoxRewardKind = nil
		playerSession.TimedLuckyBoxWaitingForPickup = false
		self:_scheduleTimedLuckyBox(player, true)
	else
		self.PlayerDataService:PushSnapshot(player)
	end
	self:_sendRevealCompleted(player, pending, true, isNew)
end

function LostItemService:RequestPickup(player, spawnId)
	if pickupLocks[player] or pendingReveals[player] then
		return
	end
	pickupLocks[player] = true
	local playerSession = self:_ensurePlayerSession(player)
	local areaSession, itemData = self:_findWorldItem(player, playerSession, spawnId)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local backpack = player:FindFirstChildOfClass("Backpack")
	local luckyTier = itemData and LostItemConfig.GetLuckyTier(itemData.LostItemId) or nil
	local templateData = luckyTier and self.LuckyBoxTemplateData[luckyTier] or nil
	local config = itemData and LostItemConfig.Types[itemData.LostItemId] or nil
	if
		not areaSession
		or not itemData
		or not templateData
		or not config
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
		or not backpack
		or (itemData.PersistentItem and (
			itemData.PersistentItem.Redeemed == true
			or itemData.PersistentItem.Expired == true
		))
	then
		pickupLocks[player] = nil
		return
	end

	local maximumDistance = templateData.PromptDistance + PICKUP_DISTANCE_PADDING
	if (rootPart.Position - itemData.Center).Magnitude > maximumDistance then
		pickupLocks[player] = nil
		return
	end

	local state = self.PlayerDataService:GetState(player)
	if not state then
		pickupLocks[player] = nil
		return
	end
	local revealId = HttpService:GenerateGUID(false)
	local inventoryItem = {
		SourceYardOwnerUserId = tonumber(self:_getActiveYardKey(player)),
		SourceAreaId = itemData.PlanAreaId or areaSession.AreaId,
		LostItemId = itemData.LostItemId,
		SpawnId = itemData.SpawnId,
		ItemIndex = itemData.ItemIndex,
		LuckyTier = luckyTier,
		Guaranteed = itemData.Guaranteed == true,
		TimedRewardKind = itemData.TimedRewardKind,
	}
	local persistentItem = itemData.PersistentItem
	local isNew = (not persistentItem or persistentItem.Found ~= true)
		and math.max(0, math.floor(tonumber(state.CollectedCounts[itemData.LostItemId]) or 0)) == 0
	local revealCoinValue = LostItemConfig.GetRedeemCoinValue(
		itemData.LostItemId,
		math.max(0, tonumber(state.LeafValueMultiplier) or tonumber(state.CoinMultiplier) or 1)
	)
	areaSession.WorldItems[itemData.SpawnId] = nil
	if persistentItem then
		self:_removePersistentWorldProjections(playerSession, nil, nil, itemData.SpawnId)
	end
	pendingReveals[player] = {
		RevealId = revealId,
		AreaSession = areaSession,
		ItemData = itemData,
		InventoryItem = inventoryItem,
	}
	local payload = {
		RevealId = revealId,
		SpawnId = itemData.SpawnId,
		OpenerUserId = player.UserId,
		BoxTier = luckyTier,
		FinalLostItemId = itemData.LostItemId,
		RevealSeed = self.Random:NextInteger(1, 2_147_483_646),
		IsNew = isNew,
		RevealCoinValue = revealCoinValue,
		RevealOriginCFrame = itemData.WorldPivotCFrame,
	}
	self:_broadcastReveal(player, payload)
	self.PlayerDataService:PushSnapshot(player)
	pickupLocks[player] = nil
	task.delay(REVEAL_TOTAL_DURATION, function()
		self:_finalizePendingReveal(player, revealId)
	end)
end

function LostItemService:_restoreInventoryTools(player, character)
	local playerSession = playerSessions[player]
	if not playerSession or not next(playerSession.Inventory) or not player.Parent or player.Character ~= character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	if not humanoid or humanoid.Health <= 0 or not backpack then
		return
	end
	for lostItemId, stack in playerSession.Inventory do
		if #stack > 0 then
			self:_syncInventoryTool(player, lostItemId, false)
		end
	end
end

function LostItemService:_restorePersistentInventory(player)
	local runProgress, state = self:_getPersistentRun(player)
	if not runProgress or not state then
		return false
	end
	local playerSession = self:_ensurePlayerSession(player)
	local inventorySpawnIds = self:_getInventorySpawnIds(playerSession)
	local rebirthCount = math.max(0, math.floor(tonumber(state.RebirthCount) or 0))
	local restoredAny = false

	for _, areaId in RegionConfig.PersistentOrder do
		local persistentArea = runProgress.Areas[areaId]
		for itemIndex, persistentItem in ipairs(persistentArea and persistentArea.Items or {}) do
			local lostItemId = persistentItem.LostItemId
			local config = LostItemConfig.Types[lostItemId]
			local spawnId = makePersistentSpawnId(player, rebirthCount, areaId, itemIndex)
			if
				config
				and config.PoopOnly ~= true
				and persistentItem.Found == true
				and persistentItem.Redeemed ~= true
				and persistentItem.Expired ~= true
				and inventorySpawnIds[spawnId] ~= true
			then
				local added = self:_addInventoryItem(player, {
					SourceYardOwnerUserId = player.UserId,
					SourceAreaId = areaId,
					LostItemId = lostItemId,
					SpawnId = spawnId,
					ItemIndex = itemIndex,
					LuckyTier = config.LuckyTier,
					Guaranteed = persistentItem.Guaranteed == true,
					TimedRewardKind = persistentItem.TimedRewardKind,
				}, false, true)
				if added then
					inventorySpawnIds[spawnId] = true
					restoredAny = true
				end
			end
		end
	end

	if restoredAny then
		local character = player.Character
		if character then
			task.defer(function()
				self:_restoreInventoryTools(player, character)
			end)
		end
		self.PlayerDataService:PushSnapshot(player)
	end
	return restoredAny
end

function LostItemService:_restoreLastCleaningTool(player)
	task.defer(function()
		if player.Parent ~= Players then
			return
		end

		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not humanoid or humanoid.Health <= 0 then
			return
		end
		for _, child in character:GetChildren() do
			if child:IsA("Tool") then
				return
			end
		end

		local state = self.PlayerDataService:GetState(player)
		if not state then
			return
		end
		local toolId = state.LastEquippedTool
		if type(toolId) ~= "string" or state.UnlockedTools[toolId] ~= true then
			toolId = ToolConfig.DefaultToolId
		end
		if state.UnlockedTools[toolId] == true then
			self.PlayerDataService:SetEquippedTool(player, toolId)
		end
	end)
end

function LostItemService:_redeemInventory(player, options)
	options = type(options) == "table" and options or {}
	if shopLocks[player] then
		return "Busy", 0
	end
	shopLocks[player] = true
	local playerSession = self:_ensurePlayerSession(player)
	local _, inventoryTotal = self:_getInventorySnapshot(playerSession)
	if inventoryTotal <= 0 then
		if options.SilentEmpty ~= true then
			self.PlayerDataService:Notify(player, "You have no Lost Items to redeem.")
		end
		shopLocks[player] = nil
		return "Empty", 0
	end

	local validItems = {}
	local multiplierEligibleCoinValue = 0
	local fixedCoinValue = 0
	local playerState = self.PlayerDataService:GetState(player)
	local leafValueMultiplier = math.max(
		0,
		tonumber(playerState and playerState.LeafValueMultiplier)
			or tonumber(playerState and playerState.CoinMultiplier)
			or 1
	)
	for lostItemId, stack in playerSession.Inventory do
		local config = LostItemConfig.Types[lostItemId]
		if config then
			for _, itemData in stack do
				local persistentItem = nil
				local valid = true
				if itemData.ItemIndex ~= nil then
					persistentItem = self:_getPersistentItem(player, itemData.SourceAreaId, itemData.ItemIndex)
					valid = persistentItem ~= nil
						and persistentItem.Redeemed ~= true
						and persistentItem.Expired ~= true
				end
				if valid then
					local redeemCoinValue
					if config.PoopOnly == true then
						redeemCoinValue = LostItemConfig.GetPoopRedeemCoinValue(
							itemData.LostItemId,
							tonumber(itemData.CreatorUserId) == player.UserId
						)
						fixedCoinValue += redeemCoinValue
					else
						redeemCoinValue = LostItemConfig.GetRedeemCoinValue(
							itemData.LostItemId,
							leafValueMultiplier
						)
						multiplierEligibleCoinValue += redeemCoinValue
					end
					table.insert(validItems, {
						Data = itemData,
						Config = config,
						PersistentItem = persistentItem,
						RedeemCoinValue = redeemCoinValue,
					})
				end
			end
		end
	end
	if multiplierEligibleCoinValue + fixedCoinValue <= 0 or #validItems <= 0 then
		if options.SilentEmpty ~= true then
			self.PlayerDataService:Notify(player, "You have no Lost Items to redeem.")
		end
		shopLocks[player] = nil
		return "Empty", 0
	end

	local rewarded, awardedCoins = self.PlayerDataService:AwardLostItemCoins(player, multiplierEligibleCoinValue, {
		FixedCoinAmount = fixedCoinValue,
		SoundCount = #validItems,
	})
	if not rewarded then
		shopLocks[player] = nil
		return "Unavailable", 0
	end

	local persistentChanged = false
	for _, item in validItems do
		local itemData = item.Data
		local persistentItem = item.PersistentItem
		if persistentItem then
			persistentItem.Triggered = true
			persistentItem.Found = true
			persistentItem.Redeemed = true
			self:_removePersistentWorldProjections(playerSession, nil, nil, itemData.SpawnId)
			persistentChanged = true
		end
		if self.MetricsService and item.Config.PoopOnly ~= true then
			self.MetricsService:RecordLostItemRedeemed(
				player,
				itemData.SourceAreaId,
				itemData.LostItemId,
				item.Config.RarityId,
				item.RedeemCoinValue,
				itemData.LuckyTier or item.Config.LuckyTier,
				itemData.Guaranteed == true,
				getSpawnSource(itemData.TimedRewardKind)
			)
		end
	end
	if persistentChanged then
		self.PlayerDataService:QueuePersistentSave(player)
	end

	for _, container in { player.Character, player:FindFirstChildOfClass("Backpack") } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") and child:GetAttribute("LostItemCarry") == true then
					child:Destroy()
				end
			end
		end
	end
	table.clear(playerSession.Inventory)
	playerSession.LastInventoryLostItemId = nil
	local redeemedItems = {}
	for _, item in validItems do
		table.insert(redeemedItems, {
			SpawnId = item.Data.SpawnId,
			LostItemId = item.Data.LostItemId,
			CreatorUserId = item.Data.CreatorUserId,
			RedeemCoinValue = item.RedeemCoinValue,
		})
	end
	for _, handler in self.RedeemedHandlers do
		local succeeded, handlerError = pcall(handler, player, redeemedItems)
		if not succeeded then
			warn(string.format("Lost-item redeemed handler failed for player %d: %s", player.UserId, tostring(handlerError)))
		end
	end
	self.PlayerDataService:PushSnapshot(player)
	self:_restoreLastCleaningTool(player)
	if options.SilentSuccess ~= true then
		self.PlayerDataService:Notify(
			player,
			string.format("Redeemed %d items for %s Coins.", #validItems, CoinFormat.Compact(awardedCoins))
		)
	end
	shopLocks[player] = nil
	return "Sold", #validItems
end

function LostItemService:TryQuickRedeem(player)
	if not self.PlayerDataService:GetState(player) then
		return "Unavailable", 0
	end
	return self:_redeemInventory(player, {
		SilentEmpty = true,
		SilentSuccess = true,
	})
end

function LostItemService:ResetYard(owner)
	local ownerUserId = owner.UserId
	local ownerKey = tostring(ownerUserId)
	local changedPlayers = {}
	for player, pending in pendingReveals do
		if
			player == owner
			or tonumber(pending.InventoryItem and pending.InventoryItem.SourceYardOwnerUserId) == ownerUserId
		then
			pendingReveals[player] = nil
			self:_sendRevealCompleted(player, pending, false, false)
		end
	end
	for player, playerSession in playerSessions do
		if player == owner then
			if next(playerSession.Inventory) then
				changedPlayers[player] = true
			end
			for _, container in { player.Character, player:FindFirstChildOfClass("Backpack") } do
				if container then
					for _, child in container:GetChildren() do
						if child:IsA("Tool") and child:GetAttribute("LostItemCarry") == true then
							child:Destroy()
						end
					end
				end
			end
			table.clear(playerSession.Inventory)
			playerSession.LastInventoryLostItemId = nil
		end
		if player == owner then
			table.clear(playerSession.Yards)
		else
			playerSession.Yards[ownerKey] = nil
		end
	end
	for player in changedPlayers do
		if player.Parent == Players and self.PlayerDataService:GetState(player) then
			task.defer(function()
				self:_restoreLastCleaningTool(player)
			end)
			self.PlayerDataService:PushSnapshot(player)
		end
	end
	local ownerSession = playerSessions[owner]
	if ownerSession then
		table.clear(ownerSession.LastCollectedPositions)
	end
	task.defer(function()
		if owner.Parent == Players and self.PlayerDataService:GetState(owner) then
			self:_scheduleTimedLuckyBox(owner, true)
		end
	end)
end

function LostItemService:GetTimedLuckyBoxSnapshot(player)
	local playerSession = playerSessions[player]
	if not playerSession then
		return nil, false, nil
	end
	return playerSession.TimedLuckyBoxNextSpawnAt,
		playerSession.TimedLuckyBoxWaitingForPickup == true,
		playerSession.TimedLuckyBoxRewardKind
end

function LostItemService:GetProgress(player, areaId)
	areaId = areaId or "Area_01"
	local playerSession = self:_ensurePlayerSession(player)
	self:_ensureUnlockedAreaSessions(player)
	local yardSession = playerSession.Yards[self:_getActiveYardKey(player)]
	local areaSession = yardSession and yardSession.Areas[areaId]
	local foundItems = {}
	if areaSession then
		for _, item in areaSession.FoundItems do
			table.insert(foundItems, {
				SpawnId = item.SpawnId,
				LostItemId = item.LostItemId,
			})
		end
	end

	local worldItems = {}
	for _, sessionForArea in yardSession and yardSession.Areas or {} do
		for _, itemData in sessionForArea.WorldItems do
			table.insert(worldItems, {
				AreaId = itemData.AreaId,
				SpawnId = itemData.SpawnId,
				LuckyTier = itemData.LuckyTier or LostItemConfig.GetLuckyTier(itemData.LostItemId),
				WorldPivotCFrame = itemData.WorldPivotCFrame,
			})
		end
	end
	local inventoryCounts, inventoryTotal = self:_getInventorySnapshot(playerSession)
	local carriedItem = nil
	local preferredLostItemId = playerSession.LastInventoryLostItemId
	local preferredStack = preferredLostItemId and playerSession.Inventory[preferredLostItemId] or nil
	if preferredStack and #preferredStack > 0 then
		carriedItem = preferredStack[1]
	else
		for _, stack in playerSession.Inventory do
			if #stack > 0 then
				carriedItem = stack[1]
				break
			end
		end
	end
	local carriedItemSnapshot = nil
	if carriedItem then
		carriedItemSnapshot = {
			SourceYardOwnerUserId = carriedItem.SourceYardOwnerUserId,
			SourceAreaId = carriedItem.SourceAreaId,
			LostItemId = carriedItem.LostItemId,
			SpawnId = carriedItem.SpawnId,
		}
	end
	return #foundItems,
		areaSession and areaSession.SpawnCount or 0,
		foundItems,
		worldItems,
		carriedItemSnapshot,
		inventoryCounts,
		inventoryTotal
end

function LostItemService:_bindShop(container)
	local shop = container:FindFirstChild("LostItemShop")
	if not shop then
		return
	end
	assert(shop:IsA("Model"), shop:GetFullName() .. " must be a Model")
	local shopUpgrade = shop:FindFirstChild("upgrade")
	assert(
		shopUpgrade and shopUpgrade:IsA("BasePart"),
		shop:GetFullName() .. ".upgrade must be a BasePart"
	)
	local shopPrompt = shopUpgrade:FindFirstChild("ProximityPrompt")
	assert(
		shopPrompt and shopPrompt:IsA("ProximityPrompt"),
		shopUpgrade:GetFullName() .. ".ProximityPrompt is missing"
	)
	shopPrompt.Enabled = true
	shopPrompt.Triggered:Connect(function(player)
		self:_redeemInventory(player)
	end)
end

function LostItemService:Init(playerDataService, leafService, metricsService, revealRemote, revealCompletedRemote)
	self.PlayerDataService = playerDataService
	self.LeafService = leafService
	self.MetricsService = metricsService
	self.RevealRemote = revealRemote
	self.RevealCompletedRemote = revealCompletedRemote
	assert(revealRemote and revealRemote:IsA("RemoteEvent"), "LostItemRevealStarted must be a RemoteEvent")
	assert(
		revealCompletedRemote and revealCompletedRemote:IsA("RemoteEvent"),
		"LostItemRevealCompleted must be a RemoteEvent"
	)
	self.Random = Random.new()
	self.AreaRaycastParams = {}
	self.AreaGroundSamples = {}
	self.RedeemedHandlers = {}

	for _, areaId in RegionConfig.Order do
		local area = Workspace:FindFirstChild(areaId)
		assert(area and area:IsA("Folder"), "Workspace." .. areaId .. " must be a Folder")
		local oldGeneratedFolder = area:FindFirstChild("GeneratedLostItems")
		if oldGeneratedFolder then
			oldGeneratedFolder:Destroy()
		end
		local ground = area:FindFirstChild("ground")
		assert(ground and ground:IsA("Model"), areaId .. ".ground must be a Model")
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { ground }
		params.IgnoreWater = true
		self.AreaRaycastParams[areaId] = params
		local groundEntries = {}
		local totalGroundWeight = 0
		for _, descendant in ground:GetDescendants() do
			if descendant:IsA("BasePart") then
				totalGroundWeight += math.max(0.001, descendant.Size.X * descendant.Size.Z)
				table.insert(groundEntries, {
					Part = descendant,
					CumulativeWeight = totalGroundWeight,
				})
			end
		end
		self.AreaGroundSamples[areaId] = {
			Entries = groundEntries,
			TotalWeight = totalGroundWeight,
		}

		local areaConfig = LostItemConfig.Areas[areaId]
		assert(areaConfig, "Missing lost item area config: " .. areaId)
	end

	local templateFolder = ReplicatedStorage:FindFirstChild("LostItem")
	assert(templateFolder and templateFolder:IsA("Folder"), "ReplicatedStorage.LostItem must be a Folder")
	local valueTemplateModel = templateFolder:FindFirstChild("LostItem01")
	assert(valueTemplateModel and valueTemplateModel:IsA("Model"), "ReplicatedStorage.LostItem.LostItem01 must be a Model")
	local valueTemplateUpgrade = valueTemplateModel:FindFirstChild("upgrade")
	assert(
		valueTemplateUpgrade and valueTemplateUpgrade:IsA("BasePart"),
		"ReplicatedStorage.LostItem.LostItem01.upgrade must be a BasePart"
	)
	self.ValueBillboardTemplate = valueTemplateUpgrade:FindFirstChild("BillboardGui")
	assert(
		self.ValueBillboardTemplate and self.ValueBillboardTemplate:IsA("BillboardGui"),
		"ReplicatedStorage.LostItem.LostItem01.upgrade.BillboardGui must be a BillboardGui"
	)
	self.TemplateData = {}
	for _, lostItemId in LostItemConfig.TemplateOrder do
		local template = templateFolder:FindFirstChild(lostItemId)
		assert(template and template:IsA("Model"), "Missing lost item model: " .. lostItemId)
		local upgrade = template:FindFirstChild("upgrade")
		assert(upgrade and upgrade:IsA("BasePart"), lostItemId .. ".upgrade must be a BasePart")
		assert(
			math.abs(upgrade.CFrame.UpVector:Dot(Vector3.yAxis)) >= UPGRADE_UPRIGHT_ALIGNMENT,
			lostItemId .. ".upgrade must be upright"
		)
		local prompt = upgrade:FindFirstChild("ProximityPrompt")
		assert(prompt and prompt:IsA("ProximityPrompt"), lostItemId .. ".upgrade.ProximityPrompt is missing")
		local displayCFrame, displaySize = getDisplayBounds(template, upgrade)
		self.TemplateData[lostItemId] = {
			Template = template,
			Upgrade = upgrade,
			DisplayOffset = template:GetPivot():ToObjectSpace(displayCFrame),
			Radius = math.max(displaySize.X, displaySize.Z) / 2 + LostItemConfig.LeafClearancePadding,
			PromptDistance = prompt.MaxActivationDistance,
		}
	end

	local luckyBoxFolder = ReplicatedStorage:FindFirstChild("Lucky Block")
	assert(luckyBoxFolder and luckyBoxFolder:IsA("Folder"), "ReplicatedStorage.Lucky Block must be a Folder")
	self.LuckyBoxTemplateData = {}
	for luckyTier = 1, LostItemConfig.LuckyTierCount do
		local templateName = string.format("Lucky%03d", luckyTier)
		local template = luckyBoxFolder:FindFirstChild(templateName)
		assert(template and template:IsA("Model"), "Missing lucky-box model: " .. templateName)
		local base = template:FindFirstChild("Base")
		assert(base and base:IsA("BasePart"), templateName .. ".Base must be a BasePart")
		local prompt = base:FindFirstChild("ProximityPrompt")
		assert(prompt and prompt:IsA("ProximityPrompt"), templateName .. ".Base.ProximityPrompt is missing")
		local _, displaySize = template:GetBoundingBox()
		self.LuckyBoxTemplateData[luckyTier] = {
			Template = template,
			Base = base,
			Radius = math.max(displaySize.X, displaySize.Z) / 2 + LostItemConfig.LeafClearancePadding,
			PromptDistance = prompt.MaxActivationDistance,
		}
	end

	for _, areaId in RegionConfig.Order do
		local area = Workspace:FindFirstChild(areaId)
		assert(area, "Workspace." .. areaId .. " is missing")
		self:_bindShop(area)
	end
	local lobby = Workspace:FindFirstChild(LeafConfig.Lobby.ContainerName)
	assert(
		lobby and lobby:IsA("Folder"),
		"Workspace." .. LeafConfig.Lobby.ContainerName .. " must be a Folder"
	)
	self:_bindShop(lobby)

	table.clear(playerSessions)
	table.clear(pickupLocks)
	table.clear(pendingReveals)
	table.clear(shopLocks)
	leafService:SetLeafCollectedHandler(function(player, areaId, position, collectedCount, collectionMode, ownerUserId)
		self:OnTeamLeafRemoved(player, areaId, position, collectedCount, collectionMode, ownerUserId)
	end)
	leafService:AddAreaGameplayReadyHandler(function(areaId)
		self:_onAreaGameplayReady(areaId)
	end)
	playerDataService:AddPlayerStateReadyHandler(function(player)
		self:_restorePersistentInventory(player)
		self:_scheduleTimedLuckyBox(player)
	end)

	local function trackPlayer(player)
		player.CharacterAdded:Connect(function(character)
			task.delay(0.35, function()
				self:_restoreInventoryTools(player, character)
			end)
		end)
	end
	Players.PlayerAdded:Connect(trackPlayer)
	Players.PlayerRemoving:Connect(function(player)
		playerSessions[player] = nil
		pickupLocks[player] = nil
		pendingReveals[player] = nil
		shopLocks[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end
end

function LostItemService:AddRedeemedHandler(handler)
	assert(type(handler) == "function", "Lost-item redeemed handler must be a function")
	table.insert(self.RedeemedHandlers, handler)
end

return LostItemService

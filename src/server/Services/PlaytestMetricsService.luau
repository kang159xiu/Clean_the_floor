local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)
local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)

local PlaytestMetricsService = {}

local EVENT_PREFIX = "ctf_b_"
local AREA_MILESTONES = { 25, 50, 75, 100 }
local PRINT_STUDIO_METRICS = false
local ONBOARDING_FUNNEL_VERSION = 1
local ONBOARDING_FUNNEL_MAX_STEP = 10
local ONBOARDING_BROOM_TOOL_ID = "Tool02"
local ONBOARDING_ORDINARY_BAG_2_ID = BagConfig.Levels[2].ModelName
local AREA_UNLOCK_FUNNEL_NAME = "AreaUnlockProgression_04_09_v1"
local AREA_UNLOCK_FUNNEL_MAX_STEP = 6
local AREA_UNLOCK_FUNNEL_STEPS = table.freeze({
	Area_04 = table.freeze({ Step = 1, Name = "Unlock Area 4" }),
	Area_05 = table.freeze({ Step = 2, Name = "Unlock Area 5" }),
	Area_06 = table.freeze({ Step = 3, Name = "Unlock Area 6" }),
	Area_07 = table.freeze({ Step = 4, Name = "Unlock Area 7" }),
	Area_08 = table.freeze({ Step = 5, Name = "Unlock Area 8" }),
	Area_09 = table.freeze({ Step = 6, Name = "Unlock Area 9" }),
})
local ONBOARDING_STEP_NAMES = table.freeze({
	[1] = "Enter Game",
	[2] = "Collect First Leaf",
	[3] = "Collect 15 Leaves",
	[4] = "Recycle Leaves for the First Time",
	[5] = "Upgrade Pickup Amount for the First Time",
	[6] = "Upgrade Pickup Speed for the First Time",
	[7] = "Upgrade Bag 1 to Bag 2",
	[8] = "Unlock Area 2",
	[9] = "Unlock Area 3",
	[10] = "Purchase First Broom",
})

local sessions = {}

assert(TutorialConfig.LeafGoal == 15, "Onboarding funnel step 3 must match the 15-leaf tutorial goal")

local function areaNumber(areaId)
	return tonumber(string.match(tostring(areaId), "^Area_(%d%d)$")) or 0
end

function PlaytestMetricsService:Init(playerDataService)
	self.PlayerDataService = playerDataService
	self.OnboardingAdvanceRunning = {}
	self.OnboardingAdvanceQueued = {}
	table.clear(sessions)
	playerDataService:AddPlayerStateReadyHandler(function(player, state)
		self:_advanceOnboardingFunnel(player, state)
	end)
	Players.PlayerAdded:Connect(function(player)
		self:_getSession(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:RecordRunExit(player)
		sessions[player] = nil
		self.OnboardingAdvanceRunning[player] = nil
		self.OnboardingAdvanceQueued[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		self:_getSession(player)
	end
end

function PlaytestMetricsService:_elapsed(session)
	return math.max(0, os.clock() - session.StartClock)
end

function PlaytestMetricsService:_emit(player, eventName, value, fields)
	local fullName = EVENT_PREFIX .. eventName
	local numericValue = math.max(0, tonumber(value) or 0)
	local customFields = fields or {}
	if RunService:IsStudio() then
		if PRINT_STUDIO_METRICS then
			print(string.format(
				"[CleanTheFloorMetrics] %s %s",
				fullName,
				HttpService:JSONEncode({ Value = numericValue, Fields = customFields })
			))
		end
		return
	end
	local success, message = pcall(function()
		AnalyticsService:LogCustomEvent(player, fullName, numericValue, customFields)
	end)
	if not success then
		warn(string.format("Metric %s failed for %s: %s", fullName, player.Name, tostring(message)))
	end
end

function PlaytestMetricsService:_emitOnboardingStep(player, step)
	local stepName = ONBOARDING_STEP_NAMES[step]
	if not stepName then
		return false
	end
	if RunService:IsStudio() then
		print(string.format(
			"[CleanTheFloorOnboarding] Step %d/%d | %s | UserId=%d",
			step,
			ONBOARDING_FUNNEL_MAX_STEP,
			stepName,
			player.UserId
		))
		return true
	end
	local success, message = pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)
	if not success then
		warn(string.format(
			"Onboarding funnel step %d failed for %s: %s",
			step,
			player.Name,
			tostring(message)
		))
	end
	return success
end

function PlaytestMetricsService:_emitAreaUnlockFunnelStep(player, areaId)
	local funnelStep = AREA_UNLOCK_FUNNEL_STEPS[areaId]
	if not funnelStep then
		return false
	end
	if RunService:IsStudio() then
		print(string.format(
			"[CleanTheFloorAreaUnlockFunnel] Step %d/%d | %s | UserId=%d",
			funnelStep.Step,
			AREA_UNLOCK_FUNNEL_MAX_STEP,
			funnelStep.Name,
			player.UserId
		))
		return true
	end
	local success, message = pcall(function()
		AnalyticsService:LogFunnelStepEvent(
			player,
			AREA_UNLOCK_FUNNEL_NAME,
			nil,
			funnelStep.Step,
			funnelStep.Name
		)
	end)
	if not success then
		warn(string.format(
			"Area unlock funnel step %d failed for %s: %s",
			funnelStep.Step,
			player.Name,
			tostring(message)
		))
	end
	return success
end

function PlaytestMetricsService:_isOnboardingStepSatisfied(state, funnel, step)
	if step == 1 then
		return true
	elseif step == 2 then
		return funnel.CollectedLeaves >= 1
	elseif step == 3 then
		return funnel.CollectedLeaves >= TutorialConfig.LeafGoal
	elseif step == 4 then
		return funnel.HasRecycled == true
	elseif step == 5 then
		return (state.HandUpgradeLevels[TutorialConfig.AmountAttributeId] or 0) > 0
	elseif step == 6 then
		return (state.HandUpgradeLevels[TutorialConfig.SpeedAttributeId] or 0) > 0
	elseif step == 7 then
		return funnel.OrdinaryBag2Purchased == true
	elseif step == 8 then
		return state.UnlockedAreas.Area_02 == true
	elseif step == 9 then
		return state.UnlockedAreas.Area_03 == true
	elseif step == 10 then
		return funnel.BroomPurchasedWithCoins == true
	end
	return false
end

function PlaytestMetricsService:_advanceOnboardingFunnel(player, suppliedState)
	if not player or not player:IsA("Player") or player.Parent ~= Players then
		return
	end
	if self.OnboardingAdvanceRunning[player] then
		self.OnboardingAdvanceQueued[player] = true
		return
	end

	self.OnboardingAdvanceRunning[player] = true
	repeat
		self.OnboardingAdvanceQueued[player] = false
		local state = self.PlayerDataService:GetState(player) or suppliedState
		local funnel = state and state.OnboardingFunnel
		if
			not state
			or type(funnel) ~= "table"
			or funnel.Version ~= ONBOARDING_FUNNEL_VERSION
			or funnel.Eligible ~= true
		then
			break
		end

		local advanced = false
		while funnel.HighestStep < ONBOARDING_FUNNEL_MAX_STEP do
			local nextStep = funnel.HighestStep + 1
			if not self:_isOnboardingStepSatisfied(state, funnel, nextStep) then
				break
			end
			if not self:_emitOnboardingStep(player, nextStep) then
				break
			end
			funnel.HighestStep = nextStep
			advanced = true
		end
		if advanced then
			self.PlayerDataService:QueuePersistentSave(player)
		end
	until self.OnboardingAdvanceQueued[player] ~= true
	self.OnboardingAdvanceRunning[player] = nil
	self.OnboardingAdvanceQueued[player] = nil
end

function PlaytestMetricsService:_getEligibleOnboardingFunnel(player)
	local state = self.PlayerDataService:GetState(player)
	local funnel = state and state.OnboardingFunnel
	if
		type(funnel) ~= "table"
		or funnel.Version ~= ONBOARDING_FUNNEL_VERSION
		or funnel.Eligible ~= true
	then
		return nil, state
	end
	return funnel, state
end

function PlaytestMetricsService:_getSession(player)
	local session = sessions[player]
	if session then
		return session
	end
	session = {
		StartClock = os.clock(),
		StartedAt = os.time(),
		CurrentAreaId = "Area_01",
		FarthestArea = 1,
		AreaEnteredAt = { Area_01 = 0 },
		AreaMilestones = {},
		FirstLeafAt = nil,
		FirstRecycleAt = nil,
		FirstPurchaseAt = nil,
		RecycleCount = 0,
		PurchaseCount = 0,
		LostPlanned = 0,
		LostSpawned = 0,
		LostFound = 0,
		LostRedeemed = 0,
		ToolStats = {},
		Completed = false,
	}
	sessions[player] = session
	self:_emit(player, "run_start", 0, { ConfigVersion = 1 })
	return session
end

function PlaytestMetricsService:RecordAreaEntered(player, areaId, previousAreaId)
	local session = self:_getSession(player)
	local elapsed = self:_elapsed(session)
	session.CurrentAreaId = areaId
	session.FarthestArea = math.max(session.FarthestArea, areaNumber(areaId))
	if session.AreaEnteredAt[areaId] == nil then
		session.AreaEnteredAt[areaId] = elapsed
	end
	self:_emit(player, "area_entered", elapsed, {
		AreaId = areaId,
		PreviousAreaId = previousAreaId or "",
	})
end

function PlaytestMetricsService:RecordLeafCollected(
	player,
	areaId,
	addedAmount,
	progress,
	bagFull,
	collectionMode
)
	if not player or not player:IsA("Player") then
		return
	end
	local session = self:_getSession(player)
	local elapsed = self:_elapsed(session)
	if not session.FirstLeafAt then
		session.FirstLeafAt = elapsed
		self:_emit(player, "first_leaf", elapsed, { AreaId = areaId, AddedAmount = addedAmount })
	end
	self:RecordAreaProgress(player, areaId, progress)
	if bagFull and not session.FirstBagFullAt then
		session.FirstBagFullAt = elapsed
		self:_emit(player, "first_bag_full", elapsed, { AreaId = areaId })
	end

	if collectionMode == "Bag" then
		local funnel = self:_getEligibleOnboardingFunnel(player)
		if funnel and funnel.CollectedLeaves < TutorialConfig.LeafGoal then
			-- Record successful leaves, not BagValue: every call represents one leaf entering the bag.
			funnel.CollectedLeaves += 1
			self.PlayerDataService:QueuePersistentSave(player)
		end
		if funnel then
			self:_advanceOnboardingFunnel(player)
		end
	end
end

function PlaytestMetricsService:RecordAreaProgress(player, areaId, progress)
	if not player or not player:IsA("Player") then
		return
	end
	local session = self:_getSession(player)
	local areaMilestones = session.AreaMilestones[areaId]
	if not areaMilestones then
		areaMilestones = {}
		session.AreaMilestones[areaId] = areaMilestones
	end
	local percent = math.clamp((tonumber(progress) or 0) * 100, 0, 100)
	for _, milestone in AREA_MILESTONES do
		if percent >= milestone and not areaMilestones[milestone] then
			local elapsed = self:_elapsed(session)
			areaMilestones[milestone] = elapsed
			local areaStartedAt = session.AreaEnteredAt[areaId] or 0
			self:_emit(player, "area_progress", milestone, {
				AreaId = areaId,
				RunSeconds = math.floor(elapsed + 0.5),
				AreaSeconds = math.floor(elapsed - areaStartedAt + 0.5),
			})
			if areaId == RegionConfig.FinalAreaId and milestone == 100 and not session.Completed then
				session.Completed = true
				self:_emit(player, "run_complete", elapsed, { FarthestArea = RegionConfig.AreaCount })
			end
		end
	end
end

function PlaytestMetricsService:RecordToolAction(player, toolId, activeSeconds, affectedLeaves)
	local session = self:_getSession(player)
	local stats = session.ToolStats[toolId]
	if not stats then
		stats = { ActiveSeconds = 0, Actions = 0, AffectedLeaves = 0 }
		session.ToolStats[toolId] = stats
	end
	stats.ActiveSeconds += math.max(0, tonumber(activeSeconds) or 0)
	stats.Actions += 1
	stats.AffectedLeaves += math.max(0, math.floor(tonumber(affectedLeaves) or 0))
end

function PlaytestMetricsService:RecordRecycle(player, areaId, bagValue, awardedCoins, targetCoins)
	local session = self:_getSession(player)
	local elapsed = self:_elapsed(session)
	session.RecycleCount += 1
	if not session.FirstRecycleAt then
		session.FirstRecycleAt = elapsed
	end
	self:_emit(player, "recycle", elapsed, {
		AreaId = areaId,
		BagValue = bagValue,
		AwardedCoins = awardedCoins,
		TargetCoins = targetCoins,
	})

	if (tonumber(bagValue) or 0) > 0 and (tonumber(awardedCoins) or 0) > 0 then
		local funnel = self:_getEligibleOnboardingFunnel(player)
		if funnel then
			if funnel.HasRecycled ~= true then
				funnel.HasRecycled = true
				self.PlayerDataService:QueuePersistentSave(player)
			end
			self:_advanceOnboardingFunnel(player)
		end
	end
end

function PlaytestMetricsService:RecordPurchase(player, purchaseKind, purchaseId, price, areaId, details)
	local session = self:_getSession(player)
	local elapsed = self:_elapsed(session)
	session.PurchaseCount += 1
	if not session.FirstPurchaseAt then
		session.FirstPurchaseAt = elapsed
	end
	local fields = {
		Kind = purchaseKind,
		PurchaseId = purchaseId,
		Price = price,
		AreaId = areaId or session.CurrentAreaId,
	}
	if type(details) == "table" then
		for key, value in details do
			fields[key] = value
		end
	end
	self:_emit(player, "purchase", elapsed, fields)

	local funnel = self:_getEligibleOnboardingFunnel(player)
	if funnel then
		local funnelStateChanged = false
		if
			purchaseKind == "BagUpgrade"
			and purchaseId == ONBOARDING_ORDINARY_BAG_2_ID
			and funnel.OrdinaryBag2Purchased ~= true
		then
			funnel.OrdinaryBag2Purchased = true
			funnelStateChanged = true
		elseif
			purchaseKind == "ToolUnlock"
			and purchaseId == ONBOARDING_BROOM_TOOL_ID
			and funnel.BroomPurchasedWithCoins ~= true
		then
			funnel.BroomPurchasedWithCoins = true
			funnelStateChanged = true
		end
		if funnelStateChanged then
			self.PlayerDataService:QueuePersistentSave(player)
		end
		self:_advanceOnboardingFunnel(player)
	end
end

function PlaytestMetricsService:RecordAreaUnlocked(player, areaId)
	if not RegionConfig.IsActiveAreaId(areaId) then
		return
	end
	local session = self:_getSession(player)
	session.FarthestArea = math.max(session.FarthestArea, areaNumber(areaId))
	self:_emit(player, "area_unlocked", self:_elapsed(session), {
		AreaId = areaId,
		UnlockMethod = "AreaCleared",
	})
	self:_emitAreaUnlockFunnelStep(player, areaId)
	self:_advanceOnboardingFunnel(player)
end

function PlaytestMetricsService:RecordLostItemPlan(player, areaId, count, spawnSource)
	local session = self:_getSession(player)
	session.LostPlanned += count
	self:_emit(player, "lost_plan", count, {
		AreaId = areaId,
		SpawnSource = spawnSource,
	})
end

function PlaytestMetricsService:RecordLostItemSpawned(
	player,
	areaId,
	lostItemId,
	rarityId,
	trigger,
	boxTier,
	guaranteed,
	spawnSource
)
	local session = self:_getSession(player)
	session.LostSpawned += 1
	self:_emit(player, "lost_spawned", trigger, {
		AreaId = areaId,
		LostItemId = lostItemId,
		RarityId = rarityId,
		BoxTier = boxTier,
		Guaranteed = guaranteed == true,
		SpawnSource = spawnSource,
	})
end

function PlaytestMetricsService:RecordLostItemFound(
	player,
	areaId,
	lostItemId,
	rarityId,
	boxTier,
	guaranteed,
	isNew,
	spawnSource
)
	local session = self:_getSession(player)
	session.LostFound += 1
	self:_emit(player, "lost_found", self:_elapsed(session), {
		AreaId = areaId,
		LostItemId = lostItemId,
		RarityId = rarityId,
		BoxTier = boxTier,
		Guaranteed = guaranteed == true,
		IsNew = isNew == true,
		SpawnSource = spawnSource,
	})
end

function PlaytestMetricsService:RecordLostItemRedeemed(
	player,
	areaId,
	lostItemId,
	rarityId,
	coins,
	boxTier,
	guaranteed,
	spawnSource
)
	local session = self:_getSession(player)
	session.LostRedeemed += 1
	self:_emit(player, "lost_redeemed", coins, {
		AreaId = areaId,
		LostItemId = lostItemId,
		RarityId = rarityId,
		Coins = coins,
		BoxTier = boxTier,
		Guaranteed = guaranteed == true,
		SpawnSource = spawnSource,
	})
end

function PlaytestMetricsService:RecordRunExit(player)
	local session = sessions[player]
	if not session then
		return
	end
	local elapsed = self:_elapsed(session)
	for toolId, stats in session.ToolStats do
		self:_emit(player, "tool_summary", stats.ActiveSeconds, {
			ToolId = toolId,
			Actions = stats.Actions,
			AffectedLeaves = stats.AffectedLeaves,
		})
	end
	self:_emit(player, "run_exit", elapsed, {
		FarthestArea = session.FarthestArea,
		CurrentAreaId = session.CurrentAreaId,
		Completed = session.Completed and 1 or 0,
		PurchaseCount = session.PurchaseCount,
		LostFound = session.LostFound,
	})
	if RunService:IsStudio() and PRINT_STUDIO_METRICS then
		local milestones = {}
		for areaId, areaMilestones in session.AreaMilestones do
			local areaCopy = {}
			for milestone, milestoneElapsed in areaMilestones do
				areaCopy[tostring(milestone)] = milestoneElapsed
			end
			milestones[areaId] = areaCopy
		end
		local summary = {
			StartedAt = session.StartedAt,
			ElapsedSeconds = elapsed,
			FarthestArea = session.FarthestArea,
			Completed = session.Completed,
			FirstLeafAt = session.FirstLeafAt,
			FirstBagFullAt = session.FirstBagFullAt,
			FirstRecycleAt = session.FirstRecycleAt,
			FirstPurchaseAt = session.FirstPurchaseAt,
			RecycleCount = session.RecycleCount,
			PurchaseCount = session.PurchaseCount,
			LostPlanned = session.LostPlanned,
			LostSpawned = session.LostSpawned,
			LostFound = session.LostFound,
			LostRedeemed = session.LostRedeemed,
			ToolStats = session.ToolStats,
			AreaMilestones = milestones,
		}
		print("[CleanTheFloorMetricsSummary] " .. HttpService:JSONEncode(summary))
	end
end

function PlaytestMetricsService:GetDebugSnapshot(player)
	return sessions[player]
end

return PlaytestMetricsService

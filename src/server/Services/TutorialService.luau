local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local HandUpgradeConfig = require(ReplicatedStorage.Shared.Config.HandUpgradeConfig)
local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)
local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)

local TutorialService = {}

local sessions = {}

local function makeSession(progress, onboardingFunnel)
	local source = type(progress) == "table" and progress or {}
	local funnel = type(onboardingFunnel) == "table" and onboardingFunnel or {}
	local bagGuidancePending = source.BagGuidancePending == true
	local poopGuidanceCompleted = funnel.PoopGuidanceCompleted == true
	local poopGuidancePending = not poopGuidanceCompleted and funnel.PoopGuidancePending == true
	local broomGuidanceCompleted = funnel.BroomGuidanceCompleted == true
	local broomGuidanceReady = not broomGuidanceCompleted and funnel.BroomGuidanceReady == true
	local step = math.clamp(
		math.floor(tonumber(source.Step) or TutorialConfig.Steps.CleanLeaves),
		TutorialConfig.Steps.CleanLeaves,
		TutorialConfig.Steps.Complete
	)
	local secondRecycleSucceeded = source.SecondRecycleSucceeded == true
	-- Step 5 saves from the removed phone tutorial have no second-recycle marker.
	-- Return those players to step 4 so their next successful sale unlocks speed guidance.
	if
		step == TutorialConfig.Steps.UpgradeSpeed
		and not secondRecycleSucceeded
		and source.SpeedUpgradeSucceeded ~= true
	then
		step = TutorialConfig.Steps.WaitForSecondRecycle
	elseif step == TutorialConfig.Steps.WaitForSecondRecycle and secondRecycleSucceeded then
		step = TutorialConfig.Steps.UpgradeSpeed
	end
	return {
		Step = step,
		LeafCount = math.clamp(
			math.floor(tonumber(source.LeafCount) or 0),
			0,
			TutorialConfig.LeafGoal
		),
		TargetAreaId = type(source.TargetAreaId) == "string" and source.TargetAreaId or nil,
		SequenceId = 1,
		AmountUpgradeSucceeded = source.AmountUpgradeSucceeded == true,
		SpeedUpgradeSucceeded = source.SpeedUpgradeSucceeded == true,
		SecondRecycleSucceeded = secondRecycleSucceeded,
		BagGuidancePending = bagGuidancePending,
		BagGuidanceReady = bagGuidancePending and source.BagGuidanceReady == true,
		PoopGuidancePending = poopGuidancePending,
		PoopGuidanceCompleted = poopGuidanceCompleted,
		PoopGuidanceStage = poopGuidancePending and "Make" or nil,
		PoopGuidanceSpawnId = nil,
		BroomGuidanceReady = broomGuidanceReady,
		BroomGuidanceCompleted = broomGuidanceCompleted,
	}
end

function TutorialService:_ensureSession(player)
	local session = sessions[player]
	if not session then
		local state = self.PlayerDataService and self.PlayerDataService:GetState(player)
		session = makeSession(state and state.TutorialProgress, state and state.OnboardingFunnel)
		sessions[player] = session
	end
	return session
end

function TutorialService:_canAffordSpeedUpgrade(player)
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return false
	end
	local currentLevel = HandUpgradeConfig.NormalizeLevel(
		TutorialConfig.SpeedAttributeId,
		state.HandUpgradeLevels[TutorialConfig.SpeedAttributeId]
	)
	if currentLevel > 0 then
		return true
	end
	local price = HandUpgradeConfig.GetNextPrice(
		TutorialConfig.SpeedAttributeId,
		currentLevel,
		state.RebirthCount
	)
	return price ~= nil and price >= 0 and state.Coins >= price
end

function TutorialService:_isBasicOrdinaryBagState(state)
	return state
		and state.BagLevel == BagConfig.DefaultLevel
		and self.PlayerDataService:GetActivePermanentBagId(state) == nil
end

function TutorialService:_arePermanentBagEntitlementsReady(state)
	if not state or type(state.PermanentBagOwnershipReady) ~= "table" then
		return false
	end
	for _, bagId in BagConfig.PermanentOrder do
		if
			BagConfig.IsPermanentBagEnabled(bagId)
			and state.PermanentBagOwnershipReady[bagId] ~= true
		then
			return false
		end
	end
	return true
end

function TutorialService:_canGuideBagUpgrade(player, session)
	local state = self.PlayerDataService:GetState(player)
	if
		not session.BagGuidancePending
		or not session.BagGuidanceReady
		or not self:_isBasicOrdinaryBagState(state)
		or not self:_arePermanentBagEntitlementsReady(state)
	then
		return false, nil
	end

	local nextBag = BagConfig.Levels[state.BagLevel + 1]
	if not nextBag or state.Coins < nextBag.Price then
		return false, nil
	end
	return true, session.TargetAreaId or state.CurrentAreaId or "Area_01"
end

function TutorialService:GetSnapshotState(player)
	local session = self:_ensureSession(player)
	local state = self.PlayerDataService:GetState(player)
	local step = session.Step
	local targetKind = nil
	local targetAreaId = nil
	local targetAttributeId = nil
	local targetReady = false
	if step == TutorialConfig.Steps.RecycleLeaves then
		targetKind = "Recycle"
		targetAreaId = session.TargetAreaId
		targetReady = true
	elseif step == TutorialConfig.Steps.UpgradeAmount then
		targetKind = "Upgrade"
		targetAreaId = TutorialConfig.UpgradeAreaId
		targetAttributeId = TutorialConfig.AmountAttributeId
		targetReady = true
	elseif step == TutorialConfig.Steps.UpgradeSpeed then
		targetAttributeId = TutorialConfig.SpeedAttributeId
		targetReady = self:_canAffordSpeedUpgrade(player)
		if targetReady then
			targetKind = "Upgrade"
			targetAreaId = TutorialConfig.UpgradeAreaId
		end
	elseif step == TutorialConfig.Steps.Complete then
		local canGuideBag, bagTargetAreaId = self:_canGuideBagUpgrade(player, session)
		if canGuideBag then
			targetKind = "BagUpgrade"
			targetAreaId = bagTargetAreaId
			targetReady = true
		elseif session.BroomGuidanceReady and not session.BroomGuidanceCompleted then
			targetKind = "BroomPurchase"
			targetAreaId = state and state.CurrentAreaId or "Area_01"
			targetReady = true
		end
	end
	return {
		Active = step < TutorialConfig.Steps.Complete,
		Step = step,
		LeafCount = session.LeafCount,
		LeafGoal = TutorialConfig.LeafGoal,
		TargetKind = targetKind,
		TargetAreaId = targetAreaId,
		TargetAttributeId = targetAttributeId,
		TargetReady = targetReady,
		SequenceId = session.SequenceId,
		PoopGuidanceStage = session.PoopGuidanceStage,
		PoopGuidanceSpawnId = session.PoopGuidanceSpawnId,
		PoopGuidanceActive = session.PoopGuidanceStage ~= nil
			and (session.PoopGuidanceStage ~= "Make" or (tonumber(state and state.Coins) or 0) > 100),
	}
end

function TutorialService:_persistProgress(player, session)
	local state = self.PlayerDataService:GetState(player)
	if not state or sessions[player] ~= session then
		return
	end
	state.TutorialProgress = {
		Step = session.Step,
		LeafCount = session.LeafCount,
		TargetAreaId = session.TargetAreaId,
		AmountUpgradeSucceeded = session.AmountUpgradeSucceeded,
		SpeedUpgradeSucceeded = session.SpeedUpgradeSucceeded,
		SecondRecycleSucceeded = session.SecondRecycleSucceeded,
		BagGuidancePending = session.BagGuidancePending,
		BagGuidanceReady = session.BagGuidanceReady,
	}
	state.TutorialCompleted = session.Step == TutorialConfig.Steps.Complete
	local funnel = state.OnboardingFunnel
	if type(funnel) == "table" then
		funnel.PoopGuidancePending = session.PoopGuidancePending == true
		funnel.PoopGuidanceCompleted = session.PoopGuidanceCompleted == true
		funnel.BroomGuidanceReady = session.BroomGuidanceReady == true
		funnel.BroomGuidanceCompleted = session.BroomGuidanceCompleted == true
	end
	self.PlayerDataService:QueuePersistentSave(player)
end

function TutorialService:_push(player)
	if self.PlayerDataService:GetState(player) then
		self.PlayerDataService:PushSnapshot(player)
	end
end

function TutorialService:_setStep(player, session, step, shouldPush)
	session.Step = step
	session.SequenceId += 1
	self:_persistProgress(player, session)
	if shouldPush ~= false then
		self:_push(player)
	end
end

function TutorialService:_completeTutorial(player, session)
	local state = self.PlayerDataService:GetState(player)
	session.BagGuidancePending = self:_isBasicOrdinaryBagState(state) == true
	session.BagGuidanceReady = false
	self:_setStep(player, session, TutorialConfig.Steps.Complete)
end

function TutorialService:_resumeLoadedSession(player, session)
	if sessions[player] ~= session or not self.PlayerDataService:GetState(player) then
		return
	end
	if session.PoopGuidancePending and not session.PoopGuidanceCompleted then
		session.PoopGuidanceStage = "Make"
		session.PoopGuidanceSpawnId = nil
	end
	local state = self.PlayerDataService:GetState(player)
	if state.UnlockedTools[TutorialConfig.BroomToolId] == true and not session.BroomGuidanceCompleted then
		session.BroomGuidanceReady = false
		session.BroomGuidanceCompleted = true
		session.SequenceId += 1
		self:_persistProgress(player, session)
		self:_push(player)
	end

	if session.Step == TutorialConfig.Steps.UpgradeAmount and session.AmountUpgradeSucceeded then
		self:_setStep(player, session, TutorialConfig.Steps.WaitForSecondRecycle)
		return
	end
	if session.Step == TutorialConfig.Steps.UpgradeSpeed and session.SpeedUpgradeSucceeded then
		self:_completeTutorial(player, session)
	end

	if
		session.Step == TutorialConfig.Steps.Complete
		and session.BagGuidancePending
		and not self:_isBasicOrdinaryBagState(self.PlayerDataService:GetState(player))
	then
		session.BagGuidancePending = false
		session.BagGuidanceReady = false
		session.SequenceId += 1
		self:_persistProgress(player, session)
		self:_push(player)
		return
	end

end

function TutorialService:OnLeafRemoved(player, areaId, position, collectionMode)
	if
		areaId == LeafConfig.Lobby.AreaId
		or not player
		or (collectionMode ~= "Bag" and collectionMode ~= "InstantRecycle")
	then
		return
	end
	local session = self:_ensureSession(player)
	if session.Step ~= TutorialConfig.Steps.CleanLeaves then
		return
	end
	session.LeafCount = math.min(TutorialConfig.LeafGoal, session.LeafCount + 1)
	if session.LeafCount >= TutorialConfig.LeafGoal then
		session.TargetAreaId = areaId
		self:_setStep(player, session, TutorialConfig.Steps.RecycleLeaves)
	else
		session.SequenceId += 1
		self:_persistProgress(player, session)
		self:_push(player)
	end
end

function TutorialService:OnRecycleSucceeded(player, areaId, awardedCoins)
	if areaId == LeafConfig.Lobby.AreaId or math.max(0, tonumber(awardedCoins) or 0) <= 0 then
		return
	end
	local session = self:_ensureSession(player)
	if session.Step == TutorialConfig.Steps.RecycleLeaves then
		if areaId ~= session.TargetAreaId then
			return
		end
		if session.AmountUpgradeSucceeded then
			self:_setStep(player, session, TutorialConfig.Steps.WaitForSecondRecycle)
		else
			self:_setStep(player, session, TutorialConfig.Steps.UpgradeAmount)
		end
		return
	end
	if session.Step == TutorialConfig.Steps.WaitForSecondRecycle then
		session.SecondRecycleSucceeded = true
		if session.SpeedUpgradeSucceeded then
			self:_completeTutorial(player, session)
		else
			self:_setStep(player, session, TutorialConfig.Steps.UpgradeSpeed)
		end
		return
	end
	if session.Step ~= TutorialConfig.Steps.Complete then
		return
	end

	local state = self.PlayerDataService:GetState(player)
	if
		state
		and session.PoopGuidanceCompleted
		and not session.BroomGuidanceReady
		and not session.BroomGuidanceCompleted
		and state.UnlockedTools[TutorialConfig.BroomToolId] ~= true
		and state.Coins >= TutorialConfig.BroomGuidanceCoinThreshold
	then
		session.BroomGuidanceReady = true
		session.TargetAreaId = areaId
		session.SequenceId += 1
		self:_persistProgress(player, session)
		self:_push(player)
		return
	end
	if not session.BagGuidancePending or session.BagGuidanceReady then
		return
	end
	if
		not self:_isBasicOrdinaryBagState(state)
		or not self:_arePermanentBagEntitlementsReady(state)
	then
		return
	end
	local nextBag = BagConfig.Levels[state.BagLevel + 1]
	if not nextBag or state.Coins < nextBag.Price then
		return
	end

	session.BagGuidanceReady = true
	session.TargetAreaId = areaId
	session.SequenceId += 1
	self:_persistProgress(player, session)
	self:_push(player)
end

function TutorialService:OnToolAcquired(player, toolId)
	if toolId ~= TutorialConfig.BroomToolId then
		return
	end
	local session = self:_ensureSession(player)
	if session.BroomGuidanceCompleted then
		return
	end
	session.BroomGuidanceReady = false
	session.BroomGuidanceCompleted = true
	session.SequenceId += 1
	self:_persistProgress(player, session)
	self:_push(player)
end

function TutorialService:OnUpgradeSucceeded(player, toolId, attributeId)
	if toolId ~= "Tool01" then
		return
	end
	local session = self:_ensureSession(player)
	if attributeId == TutorialConfig.AmountAttributeId then
		session.AmountUpgradeSucceeded = true
		if session.Step == TutorialConfig.Steps.UpgradeAmount then
			self:_setStep(player, session, TutorialConfig.Steps.WaitForSecondRecycle)
		else
			self:_persistProgress(player, session)
		end
	elseif attributeId == TutorialConfig.SpeedAttributeId then
		session.SpeedUpgradeSucceeded = true
		if session.Step == TutorialConfig.Steps.UpgradeSpeed then
			self:_completeTutorial(player, session)
		else
			self:_persistProgress(player, session)
		end
	end
end

function TutorialService:OnBagUpgradePurchased(player, purchaseKind)
	local session = self:_ensureSession(player)
	if not session.BagGuidancePending then
		return
	end
	session.BagGuidancePending = false
	session.BagGuidanceReady = false
	if purchaseKind == "Coins" and not session.PoopGuidanceCompleted then
		session.PoopGuidancePending = true
		session.PoopGuidanceStage = "Make"
		session.PoopGuidanceSpawnId = nil
	end
	session.SequenceId += 1
	self:_persistProgress(player, session)
end

function TutorialService:OnPoopCreated(player, spawnId)
	local session = self:_ensureSession(player)
	if
		not session.PoopGuidancePending
		or session.PoopGuidanceCompleted
		or session.PoopGuidanceStage ~= "Make"
		or type(spawnId) ~= "string"
	then
		return false
	end
	session.PoopGuidanceStage = "Pickup"
	session.PoopGuidanceSpawnId = spawnId
	session.SequenceId += 1
	self:_persistProgress(player, session)
	return true
end

function TutorialService:OnPoopPickedUp(player, spawnId)
	local session = self:_ensureSession(player)
	if
		not session.PoopGuidancePending
		or session.PoopGuidanceCompleted
		or session.PoopGuidanceStage ~= "Pickup"
		or spawnId ~= session.PoopGuidanceSpawnId
	then
		return
	end
	session.PoopGuidanceStage = "Sell"
	session.SequenceId += 1
	self:_persistProgress(player, session)
	self:_push(player)
end

function TutorialService:OnLostItemsRedeemed(player, redeemedItems)
	local session = self:_ensureSession(player)
	if
		not session.PoopGuidancePending
		or session.PoopGuidanceCompleted
		or session.PoopGuidanceStage ~= "Sell"
		or type(redeemedItems) ~= "table"
	then
		return
	end
	local targetSpawnId = session.PoopGuidanceSpawnId
	for _, item in redeemedItems do
		if type(item) == "table" and item.SpawnId == targetSpawnId then
			session.PoopGuidancePending = false
			session.PoopGuidanceCompleted = true
			session.PoopGuidanceStage = nil
			session.PoopGuidanceSpawnId = nil
			session.SequenceId += 1
			self:_persistProgress(player, session)
			return
		end
	end
end

function TutorialService:ResetPlayer(player)
	local state = self.PlayerDataService:GetState(player)
	local session = makeSession(state and state.TutorialProgress, state and state.OnboardingFunnel)
	sessions[player] = session
	self:_persistProgress(player, session)
end

function TutorialService:Init(playerDataService, leafService, lostItemService, recycleService, poopService)
	self.PlayerDataService = playerDataService
	self.PoopService = poopService
	table.clear(sessions)

	playerDataService:SetTutorialStateProvider(function(player)
		return self:GetSnapshotState(player)
	end)
	leafService:AddLeafCollectedHandler(function(player, areaId, position, _, collectionMode, _, collectionContext)
		if type(collectionContext) == "table" and collectionContext.Kind == "ResetCoin" then
			return
		end
		self:OnLeafRemoved(player, areaId, position, collectionMode)
	end)
	recycleService:AddRecycleCompletedHandler(function(player, areaId, _, awardedCoins)
		self:OnRecycleSucceeded(player, areaId, awardedCoins)
	end)
	poopService:AddPoopCreatedHandler(function(player, spawnId)
		return self:OnPoopCreated(player, spawnId)
	end)
	poopService:AddPoopPickedUpHandler(function(player, spawnId)
		self:OnPoopPickedUp(player, spawnId)
	end)
	lostItemService:AddRedeemedHandler(function(player, redeemedItems)
		self:OnLostItemsRedeemed(player, redeemedItems)
	end)

	playerDataService:AddPlayerStateReadyHandler(function(player, state)
		local session = makeSession(state.TutorialProgress, state.OnboardingFunnel)
		sessions[player] = session
		task.defer(function()
			self:_resumeLoadedSession(player, session)
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		sessions[player] = nil
	end)
end

return TutorialService

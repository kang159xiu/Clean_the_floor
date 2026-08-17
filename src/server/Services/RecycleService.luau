local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local RecycleService = {}

local recycleLocks = {}
local recycleAnimationSequences = {}
local deliveryLocks = {}
local MINIMUM_FLYING_LEAF_COUNT = 5
local MAXIMUM_FLYING_LEAF_COUNT = 30
local FLYING_LEAF_CURVE_MINIMUM_VALUE = 15
local FLYING_LEAF_CURVE_MAXIMUM_VALUE = 5000
local FLYING_LEAF_SCALE = 0.5
local FLYING_LEAF_DURATION = 0.2
local MAXIMUM_FLYING_LEAF_INTERVAL = 0.1
local MINIMUM_FLYING_LEAF_INTERVAL = 0.05
local RECYCLE_LOCK_TIMEOUT_PADDING = 1
local FLYING_LEAF_TARGET_HEIGHT = 0.2
local FLYING_LEAF_OFFSETS = {
	Vector3.new(-0.55, 0.05, 0),
	Vector3.new(0.55, 0.05, 0),
	Vector3.new(0, 0.4, 0),
	Vector3.new(-0.28, -0.25, 0),
	Vector3.new(0.28, -0.25, 0),
}
local FLYING_LEAF_ARC_HEIGHTS = { 0.55, 0.75, 0.95, 0.65, 0.85 }
local COIN_GAIN_HOLD_DURATION = 1
local COIN_GAIN_FLY_DURATION = 0.35
local RECYCLE_PULSE_SCALE = 1.08
local RECYCLE_PULSE_GROW_DURATION = 0.08
local RECYCLE_PULSE_SHRINK_DURATION = 0.1

local function withY(size, y)
	return Vector3.new(size.X, y, size.Z)
end

local function cframeForY(bottomCFrame, y)
	return bottomCFrame * CFrame.new(0, y / 2, 0)
end

local function getRecyclePresentation(bagValue)
	local normalized = math.clamp(
		((tonumber(bagValue) or 0) - FLYING_LEAF_CURVE_MINIMUM_VALUE)
			/ (FLYING_LEAF_CURVE_MAXIMUM_VALUE - FLYING_LEAF_CURVE_MINIMUM_VALUE),
		0,
		1
	)
	local leafCount = math.clamp(
		MINIMUM_FLYING_LEAF_COUNT
			+ math.floor(
				(MAXIMUM_FLYING_LEAF_COUNT - MINIMUM_FLYING_LEAF_COUNT) * math.sqrt(normalized)
			),
		MINIMUM_FLYING_LEAF_COUNT,
		MAXIMUM_FLYING_LEAF_COUNT
	)
	local countProgress = (leafCount - MINIMUM_FLYING_LEAF_COUNT)
		/ (MAXIMUM_FLYING_LEAF_COUNT - MINIMUM_FLYING_LEAF_COUNT)
	local leafInterval = MAXIMUM_FLYING_LEAF_INTERVAL
		- countProgress * (MAXIMUM_FLYING_LEAF_INTERVAL - MINIMUM_FLYING_LEAF_INTERVAL)
	return leafCount, leafInterval
end

function RecycleService:_createStation(areaId, container)
	assert(container, "Recycle station container is missing for " .. areaId)
	local containerPath = container:GetFullName()
	local recycle = container:FindFirstChild("Recycle_01")
	assert(recycle and recycle:IsA("BasePart"), containerPath .. ".Recycle_01 must be a BasePart")
	local prompt = recycle:FindFirstChild("ProximityPrompt")
	assert(
		prompt and prompt:IsA("ProximityPrompt"),
		containerPath .. ".Recycle_01.ProximityPrompt is missing"
	)
	local pulseVisual = recycle:FindFirstChild("PulseVisual")
	local pulseVisualWarningIssued = false
	if pulseVisual and not pulseVisual:IsA("Model") then
		warn(containerPath .. ".Recycle_01.PulseVisual must be a Model; recycle pulse disabled")
		pulseVisualWarningIssued = true
		pulseVisual = nil
	end
	local preferredGrassContainer = pulseVisual and pulseVisual:FindFirstChild("grass")
	local preferredAnimationPart = preferredGrassContainer
		and preferredGrassContainer:FindFirstChild("grass")
	local legacyGrassContainer = recycle:FindFirstChild("grass")
	local legacyAnimationPart = legacyGrassContainer and legacyGrassContainer:FindFirstChild("grass")
	local animationPart = if preferredAnimationPart and preferredAnimationPart:IsA("BasePart")
		then preferredAnimationPart
		else legacyAnimationPart
	assert(
		animationPart and animationPart:IsA("BasePart"),
		containerPath .. ".Recycle_01.PulseVisual.grass.grass or Recycle_01.grass.grass must be a BasePart"
	)

	local effectsFolder = recycle:FindFirstChild("RecycleEffects")
	if effectsFolder then
		assert(
			effectsFolder:IsA("Folder"),
			containerPath .. ".Recycle_01.RecycleEffects must be a Folder"
		)
		effectsFolder:ClearAllChildren()
	else
		effectsFolder = Instance.new("Folder")
		effectsFolder.Name = "RecycleEffects"
		effectsFolder.Parent = recycle
	end

	local originalSize = animationPart.Size
	local originalCFrame = animationPart.CFrame
	local pulsePivot = pulseVisual and pulseVisual:GetPivot() or nil
	local pulseParts = {}
	if pulseVisual and pulsePivot then
		for _, descendant in pulseVisual:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(pulseParts, {
					Part = descendant,
					OriginalSize = descendant.Size,
					RelativeCFrame = pulsePivot:ToObjectSpace(descendant.CFrame),
				})
			end
		end
		if #pulseParts == 0 then
			warn(containerPath .. ".Recycle_01.PulseVisual has no BasePart; recycle pulse disabled")
			pulseVisual = nil
			pulsePivot = nil
		end
	elseif not pulseVisualWarningIssued then
		warn(containerPath .. ".Recycle_01.PulseVisual is missing; recycle pulse disabled")
	end
	local station = {
		AreaId = areaId,
		RecyclePart = recycle,
		Prompt = prompt,
		AnimationPart = animationPart,
		EffectsFolder = effectsFolder,
		PulseVisual = pulseVisual,
		PulsePivot = pulsePivot,
		PulseParts = pulseParts,
		OriginalSize = originalSize,
		OriginalCFrame = originalCFrame,
		BottomCFrame = originalCFrame * CFrame.new(0, -originalSize.Y / 2, 0),
		OriginalTransparency = if animationPart.Transparency < 1 then animationPart.Transparency else 0,
		AnimationSerial = 0,
		GrowTween = nil,
		ShrinkTween = nil,
		PulseSerial = 0,
		PulseCompletedSerial = 0,
		PendingGrassPulseSerial = nil,
		PulseScaleValue = nil,
		PulseScaleConnection = nil,
		PulseGrowTween = nil,
		PulseShrinkTween = nil,
	}
	if pulseVisual then
		local pulseScaleValue = Instance.new("NumberValue")
		pulseScaleValue.Value = 1
		station.PulseScaleValue = pulseScaleValue
		station.PulseScaleConnection = pulseScaleValue:GetPropertyChangedSignal("Value"):Connect(function()
			self:_applyRecyclePulseScale(station, pulseScaleValue.Value)
		end)
	end
	animationPart.Transparency = 1
	animationPart.Size = originalSize
	animationPart.CFrame = originalCFrame

	prompt.Triggered:Connect(function(player)
		self:_recycle(player, station)
	end)
	return station
end

function RecycleService:Init(playerDataService, bagService, economyService, metricsService, leafService)
	self.PlayerDataService = playerDataService
	self.BagService = bagService
	self.EconomyService = economyService
	self.MetricsService = metricsService
	self.LeafService = leafService
	self.Stations = {}
	self.RecycleCompletedHandlers = {}
	leafService:AddInstantRecycleCompletedHandler(function(player, areaId, leafValue, awardedCoins, targetCoins)
		self:NotifyInstantRecycleCompleted(player, areaId, leafValue, awardedCoins, targetCoins)
	end)
	economyService:SetFriendRewardHandler(function(helper, rewardAmounts)
		self:_queueFriendRewards(helper, rewardAmounts)
	end)

	local modelFolder = ReplicatedStorage:FindFirstChild("Model")
	assert(modelFolder and modelFolder:IsA("Folder"), "ReplicatedStorage.Model must be a Folder")
	local flyingLeafTemplates = {}
	for _, leafType in LeafConfig.ActiveOrder do
		local template = modelFolder:FindFirstChild(leafType)
		assert(template and template:IsA("Model"), "ReplicatedStorage.Model." .. leafType .. " must be a Model")
		assert(template:FindFirstChildWhichIsA("BasePart", true), leafType .. " needs a BasePart")
		table.insert(flyingLeafTemplates, template)
	end
	self.FlyingLeafTemplates = flyingLeafTemplates
	self.Random = Random.new()

	for _, areaId in RegionConfig.Order do
		local area = Workspace:FindFirstChild(areaId)
		assert(area and area:IsA("Folder"), "Workspace." .. areaId .. " must be a Folder")
		self.Stations[areaId] = self:_createStation(areaId, area)
	end
	local lobbyConfig = LeafConfig.Lobby
	local lobby = Workspace:FindFirstChild(lobbyConfig.ContainerName)
	assert(
		lobby and lobby:IsA("Folder"),
		"Workspace." .. lobbyConfig.ContainerName .. " must be a Folder"
	)
	self.Stations[lobbyConfig.AreaId] = self:_createStation(lobbyConfig.AreaId, lobby)

	Players.PlayerRemoving:Connect(function(player)
		recycleLocks[player] = nil
		recycleAnimationSequences[player] = nil
		deliveryLocks[player] = nil
	end)
	playerDataService:AddPlayerStateReadyHandler(function(player)
		task.defer(function()
			self:_processPendingFriendDeliveries(player)
		end)
	end)
	task.spawn(function()
		while true do
			task.wait(30)
			for _, player in Players:GetPlayers() do
				self:_processPendingFriendDeliveries(player)
			end
		end
	end)
end

function RecycleService:_deliverFriendReward(helper, delivery)
	local owner = Players:GetPlayerByUserId(delivery.OwnerUserId)
	if owner then
		if self.PlayerDataService:GetState(owner) then
			return self.PlayerDataService:CreditOnlineFriendReward(owner, delivery)
		end
		return false
	end
	local delivered = self.PlayerDataService:DeliverOfflineFriendReward(
		delivery.OwnerUserId,
		delivery
	)
	return delivered == true
end

function RecycleService:_processPendingFriendDeliveries(helper)
	if deliveryLocks[helper] then
		return
	end
	local state = self.PlayerDataService:GetState(helper)
	if not state or #state.PendingFriendDeliveries == 0 then
		return
	end
	deliveryLocks[helper] = true
	local pending = state.PendingFriendDeliveries
	state.PendingFriendDeliveries = {}
	local remaining = {}
	for _, delivery in pending do
		if helper.Parent ~= Players or not self:_deliverFriendReward(helper, delivery) then
			table.insert(remaining, delivery)
		end
	end
	for _, delivery in remaining do
		table.insert(state.PendingFriendDeliveries, delivery)
	end
	deliveryLocks[helper] = nil
	self.PlayerDataService:QueuePersistentSave(helper)
end

function RecycleService:_queueFriendRewards(helper, rewardAmounts)
	local state = self.PlayerDataService:GetState(helper)
	if not state then
		return
	end
	for rawOwnerUserId, rawAmount in rewardAmounts do
		local ownerUserId = math.floor(tonumber(rawOwnerUserId) or 0)
		local amount = math.max(0, math.floor(tonumber(rawAmount) or 0))
		if ownerUserId > 0 and ownerUserId ~= helper.UserId and amount > 0 then
			table.insert(state.PendingFriendDeliveries, {
				TransactionId = HttpService:GenerateGUID(false),
				OwnerUserId = ownerUserId,
				Amount = amount,
				HelperUserId = helper.UserId,
				HelperName = helper.DisplayName,
			})
		end
	end
	if #state.PendingFriendDeliveries > 0 then
		self.PlayerDataService:QueuePersistentSave(helper)
		task.spawn(function()
			self:_processPendingFriendDeliveries(helper)
		end)
	end
end

function RecycleService:_runRecycle(player, station, options)
	options = type(options) == "table" and options or {}
	if recycleLocks[player] then
		return "Busy", 0
	end
	recycleLocks[player] = true

	local bagValue, sourceValues = self.BagService:TakeAll(player, false)
	if bagValue <= 0 then
		if options.SilentEmpty ~= true then
			self.PlayerDataService:Notify(player, "Your backpack is empty.")
		end
		recycleLocks[player] = nil
		return "Empty", 0
	end
	local flyingLeafCount, flyingLeafInterval = getRecyclePresentation(bagValue)

	local awardedCoins, targetCoins = self.EconomyService:AwardRecycleCoins(player, bagValue, {
		ShouldPush = false,
		SourceValues = sourceValues,
		StepCount = flyingLeafCount,
		FirstStepDelay = FLYING_LEAF_DURATION,
		StepInterval = flyingLeafInterval,
		SoundKind = "Recycle",
		SoundCount = flyingLeafCount,
		SoundFirstDelay = FLYING_LEAF_DURATION,
		SoundInterval = flyingLeafInterval,
		HoldDuration = COIN_GAIN_HOLD_DURATION,
		FlyDuration = COIN_GAIN_FLY_DURATION,
	})
	if awardedCoins > 0 then
		local state = self.PlayerDataService:GetState(player)
		local areaId = station and station.AreaId
			or state and state.CurrentAreaId
			or "Area_01"
		self:_notifyRecycleCompleted(player, areaId, bagValue, awardedCoins)
		if self.MetricsService then
			self.MetricsService:RecordRecycle(player, areaId, bagValue, awardedCoins, targetCoins)
		end
	end

	self.PlayerDataService:PushSnapshot(player)
	if options.PlayWorldAnimation == false or not station then
		recycleLocks[player] = nil
	else
		local sequenceId = (recycleAnimationSequences[player] or 0) + 1
		recycleAnimationSequences[player] = sequenceId
		local function releaseRecycleLock()
			if recycleAnimationSequences[player] == sequenceId then
				recycleLocks[player] = nil
			end
		end
		self:_playDepositAnimation(
			player,
			station,
			flyingLeafCount,
			flyingLeafInterval,
			releaseRecycleLock
		)
		local lockTimeout = (flyingLeafCount - 1) * flyingLeafInterval
			+ FLYING_LEAF_DURATION
			+ RECYCLE_LOCK_TIMEOUT_PADDING
		task.delay(lockTimeout, releaseRecycleLock)
	end
	return "Sold", bagValue
end

function RecycleService:_recycle(player, station)
	self:_runRecycle(player, station, {
		PlayWorldAnimation = true,
		SilentEmpty = false,
	})
end

function RecycleService:TryQuickSell(player)
	if not self.PlayerDataService:GetState(player) then
		return "Unavailable", 0
	end
	return self:_runRecycle(player, nil, {
		PlayWorldAnimation = false,
		SilentEmpty = true,
	})
end

function RecycleService:_notifyRecycleCompleted(player, areaId, bagValue, awardedCoins)
	for _, handler in self.RecycleCompletedHandlers do
		local success, message = pcall(handler, player, areaId, bagValue, awardedCoins)
		if not success then
			warn("Recycle-completed handler failed: " .. tostring(message))
		end
	end
end

function RecycleService:AddRecycleCompletedHandler(handler)
	table.insert(self.RecycleCompletedHandlers, handler)
end

function RecycleService:NotifyInstantRecycleCompleted(player, areaId, leafValue, awardedCoins, targetCoins)
	local sanitizedLeafValue = math.max(0, tonumber(leafValue) or 0)
	if sanitizedLeafValue <= 0 then
		return
	end
	local sanitizedAward = math.max(0, tonumber(awardedCoins) or 0)
	self:_notifyRecycleCompleted(player, areaId, sanitizedLeafValue, sanitizedAward)
	if self.MetricsService then
		self.MetricsService:RecordRecycle(
			player,
			areaId,
			sanitizedLeafValue,
			sanitizedAward,
			math.max(0, tonumber(targetCoins) or 0)
		)
	end
end

function RecycleService:_createFlyingLeaf(station, startPosition, index)
	local template = self.FlyingLeafTemplates[self.Random:NextInteger(1, #self.FlyingLeafTemplates)]
	local clone = template:Clone()
	clone.Name = string.format("RecycleLeaf_%02d", index)
	clone:ScaleTo(clone:GetScale() * FLYING_LEAF_SCALE)

	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.CastShadow = false
		end
	end

	local boundingCFrame = clone:GetBoundingBox()
	local pivotOffset = boundingCFrame:ToObjectSpace(clone:GetPivot())
	local boundingRotation = boundingCFrame.Rotation
	clone:PivotTo(CFrame.new(startPosition) * boundingRotation * pivotOffset)
	clone.Parent = station.EffectsFolder

	local patternIndex = ((index - 1) % #FLYING_LEAF_ARC_HEIGHTS) + 1
	return {
		Model = clone,
		StartPosition = startPosition,
		BoundingRotation = boundingRotation,
		PivotOffset = pivotOffset,
		ArcHeight = FLYING_LEAF_ARC_HEIGHTS[patternIndex],
	}
end

function RecycleService:_applyRecyclePulseScale(station, scale)
	if not station.PulseVisual or not station.PulseVisual.Parent or not station.PulsePivot then
		return
	end
	local safeScale = math.max(0.001, tonumber(scale) or 1)
	for _, partData in station.PulseParts do
		local part = partData.Part
		if part.Parent and part:IsDescendantOf(station.PulseVisual) then
			local relativeCFrame = partData.RelativeCFrame
			part.Size = partData.OriginalSize * safeScale
			part.CFrame = station.PulsePivot
				* CFrame.new(relativeCFrame.Position * safeScale)
				* relativeCFrame.Rotation
		end
	end
end

function RecycleService:_cancelRecyclePulseTweens(station)
	if station.PulseGrowTween then
		station.PulseGrowTween:Cancel()
	end
	if station.PulseShrinkTween then
		station.PulseShrinkTween:Cancel()
	end
	station.PulseGrowTween = nil
	station.PulseShrinkTween = nil
	if station.PulseScaleValue then
		station.PulseScaleValue.Value = 1
		self:_applyRecyclePulseScale(station, 1)
	end
end

function RecycleService:_cancelGrassAnimationForPulse(station)
	station.AnimationSerial += 1
	self:_cancelTweens(station)
	local part = station.AnimationPart
	if part.Parent then
		part.Transparency = 1
		part.Size = station.OriginalSize
		part.CFrame = station.OriginalCFrame
	end
end

function RecycleService:_playRecyclePulse(station)
	if
		not station.PulseVisual
		or not station.PulseVisual.Parent
		or not station.PulseScaleValue
	then
		return nil
	end

	station.PulseSerial += 1
	local serial = station.PulseSerial
	station.PendingGrassPulseSerial = nil
	self:_cancelGrassAnimationForPulse(station)
	self:_cancelRecyclePulseTweens(station)

	local growTween = TweenService:Create(
		station.PulseScaleValue,
		TweenInfo.new(RECYCLE_PULSE_GROW_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Value = RECYCLE_PULSE_SCALE }
	)
	station.PulseGrowTween = growTween
	growTween:Play()

	task.spawn(function()
		growTween.Completed:Wait()
		if serial ~= station.PulseSerial or not station.PulseVisual.Parent then
			return
		end
		station.PulseGrowTween = nil

		local shrinkTween = TweenService:Create(
			station.PulseScaleValue,
			TweenInfo.new(RECYCLE_PULSE_SHRINK_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
			{ Value = 1 }
		)
		station.PulseShrinkTween = shrinkTween
		shrinkTween:Play()
		shrinkTween.Completed:Wait()
		if serial ~= station.PulseSerial or not station.PulseVisual.Parent then
			return
		end
		station.PulseShrinkTween = nil
		self:_applyRecyclePulseScale(station, 1)
		station.PulseCompletedSerial = serial
		if station.PendingGrassPulseSerial == serial then
			station.PendingGrassPulseSerial = nil
			self:_playAnimation(station)
		end
	end)
	return serial
end

function RecycleService:_playGrassAfterPulse(station, pulseSerial)
	if pulseSerial == nil then
		self:_playAnimation(station)
		return
	end
	if pulseSerial ~= station.PulseSerial then
		return
	end
	if station.PulseCompletedSerial == pulseSerial then
		self:_playAnimation(station)
	else
		station.PendingGrassPulseSerial = pulseSerial
	end
end

function RecycleService:_playDepositAnimation(player, station, flyingLeafCount, flyingLeafInterval, onCompleted)
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		self:_playGrassAfterPulse(
			station,
			if station.PulseScaleValue then station.PulseSerial else nil
		)
		if onCompleted then
			onCompleted()
		end
		return
	end

	local targetPosition = station.OriginalCFrame.Position
	task.spawn(function()
		local completedCount = 0
		local latestPulseSerial = nil
		local lastRootCFrame = rootPart.CFrame
		for index = 1, flyingLeafCount do
			if index > 1 then
				task.wait(flyingLeafInterval)
			end
			if rootPart:IsDescendantOf(Workspace) then
				lastRootCFrame = rootPart.CFrame
			end

			local patternIndex = ((index - 1) % #FLYING_LEAF_OFFSETS) + 1
			local localOffset = FLYING_LEAF_OFFSETS[patternIndex]
				+ Vector3.new(0, FLYING_LEAF_TARGET_HEIGHT, 0)
			local startPosition = lastRootCFrame:PointToWorldSpace(localOffset)
			local flyingData = self:_createFlyingLeaf(station, startPosition, index)

			task.spawn(function()
				local startTime = os.clock()
				while flyingData.Model.Parent do
					local alpha = math.clamp((os.clock() - startTime) / FLYING_LEAF_DURATION, 0, 1)
					local easedAlpha = alpha * alpha
					local basePosition = flyingData.StartPosition:Lerp(targetPosition, easedAlpha)
					local arcHeight = 4 * alpha * (1 - alpha) * flyingData.ArcHeight
					local flightPosition = basePosition + Vector3.new(0, arcHeight, 0)
					flyingData.Model:PivotTo(
						CFrame.new(flightPosition)
							* flyingData.BoundingRotation
							* flyingData.PivotOffset
					)

					if alpha >= 1 then
						break
					end
					RunService.Heartbeat:Wait()
				end

				if flyingData.Model.Parent then
					flyingData.Model:Destroy()
				end
				local pulseSerial = self:_playRecyclePulse(station)
				if pulseSerial and (not latestPulseSerial or pulseSerial > latestPulseSerial) then
					latestPulseSerial = pulseSerial
				end
				completedCount += 1
			end)
		end

		while completedCount < flyingLeafCount do
			RunService.Heartbeat:Wait()
		end
		self:_playGrassAfterPulse(station, latestPulseSerial)
		if onCompleted then
			onCompleted()
		end
	end)
end

function RecycleService:_cancelTweens(station)
	if station.GrowTween then
		station.GrowTween:Cancel()
	end
	if station.ShrinkTween then
		station.ShrinkTween:Cancel()
	end
	station.GrowTween = nil
	station.ShrinkTween = nil
end

function RecycleService:_playAnimation(station)
	station.AnimationSerial += 1
	local serial = station.AnimationSerial
	self:_cancelTweens(station)

	local part = station.AnimationPart
	local originalSize = station.OriginalSize
	local startY = if part.Transparency >= 1
		then originalSize.Y * 0.05
		else math.max(originalSize.Y * 0.05, part.Size.Y)
	part.Size = withY(originalSize, startY)
	part.CFrame = cframeForY(station.BottomCFrame, startY)
	part.Transparency = station.OriginalTransparency

	local growTween = TweenService:Create(
		part,
		TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{
			Size = originalSize,
			CFrame = station.OriginalCFrame,
		}
	)
	station.GrowTween = growTween
	growTween:Play()

	task.spawn(function()
		growTween.Completed:Wait()
		if serial ~= station.AnimationSerial then
			return
		end
		task.wait(0.35)
		if serial ~= station.AnimationSerial then
			return
		end

		local targetY = originalSize.Y * 0.05
		local shrinkTween = TweenService:Create(
			part,
			TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{
				Size = withY(originalSize, targetY),
				CFrame = cframeForY(station.BottomCFrame, targetY),
			}
		)
		station.ShrinkTween = shrinkTween
		shrinkTween:Play()
		shrinkTween.Completed:Wait()
		if serial ~= station.AnimationSerial then
			return
		end
		station.ShrinkTween = nil
		part.Transparency = 1
		part.Size = originalSize
		part.CFrame = station.OriginalCFrame
	end)
end

return RecycleService

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)
local LeafVisibilityConfig = require(ReplicatedStorage.Shared.Config.LeafVisibilityConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local YardLeafController = {}
local leafMotionConfig = LeafConfig.Motion or {}

local CREATE_BUDGET_PER_FRAME = math.max(
	1,
	math.floor(tonumber(LeafVisibilityConfig.CreateBudgetPerFrame) or 16)
)
local RECYCLE_BUDGET_PER_FRAME = math.max(
	1,
	math.floor(tonumber(LeafVisibilityConfig.RecycleBudgetPerFrame) or 16)
)
local BASE_STREAMING_LOAD_DISTANCE = math.max(
	0,
	tonumber(LeafVisibilityConfig.StreamingLoadDistance) or 48
)
local BASE_STREAMING_HIDE_DISTANCE = math.max(
	BASE_STREAMING_LOAD_DISTANCE,
	tonumber(LeafVisibilityConfig.StreamingHideDistance) or 64
)
local STREAMING_CELL_SIZE = math.max(1, tonumber(LeafVisibilityConfig.StreamingCellSize) or 8)
local TOOL_STREAMING_MARGIN = STREAMING_CELL_SIZE
local POOL_TARGET_PER_ACTIVE_TYPE = math.max(
	0,
	math.floor(tonumber(LeafVisibilityConfig.PoolTargetPerActiveType) or 100)
)
local MAXIMUM_TOTAL_POOLED_MODELS = math.max(
	0,
	math.floor(tonumber(LeafVisibilityConfig.MaximumTotalPooledModels) or 200)
)
local POOL_PREWARM_BATCH_SIZE = math.clamp(
	math.floor(tonumber(LeafVisibilityConfig.PoolPrewarmBatchSize) or 1),
	1,
	1
)
local POOL_PREWARM_INTERVAL = math.max(
	0.05,
	tonumber(LeafVisibilityConfig.PoolPrewarmInterval) or 0.05
)
local REMOVAL_FINAL_SCALE = 0.1
local REMOVAL_ARC_HEIGHT = 0.4
local DUST_COLLECTOR_TOOL_ID = "Tool04"
local DUST_COLLECTOR_ANIMATED_LEAVES_PER_BATCH = 1
local FINAL_GUIDANCE_REMAINING_LEAVES = 100
local FINAL_GUIDANCE_MAX_TARGETS = 5
local VISUAL_BOUNDS_CFRAME_ATTRIBUTE = "LeafVisualBoundingCFrame"
local VISUAL_BOUNDS_SIZE_ATTRIBUTE = "LeafVisualBoundingSize"
local BASE_TRANSPARENCY_ATTRIBUTE = "LeafBaseTransparency"
local CLIENT_VISUAL_STEP = math.max(1 / 60, tonumber(leafMotionConfig.ClientVisualStep) or 1 / 30)
local CORRECTION_DURATION = math.max(0, tonumber(leafMotionConfig.CorrectionDuration) or 0.15)
local MAXIMUM_PREDICTION_SECONDS = math.max(
	CLIENT_VISUAL_STEP,
	tonumber(leafMotionConfig.MaximumPredictionSeconds) or 0.55
)
local SPATIAL_BOUNDS_UPDATE_INTERVAL = math.max(
	CLIENT_VISUAL_STEP,
	tonumber(leafMotionConfig.SpatialBoundsUpdateInterval) or 0.1
)
local MOTION_DAMPING = math.max(0, tonumber(leafMotionConfig.Damping) or 6)

local function streamingCellCoordinates(position)
	return math.floor(position.X / STREAMING_CELL_SIZE), math.floor(position.Z / STREAMING_CELL_SIZE)
end

local function streamingCellKey(cellX, cellZ)
	return tostring(cellX) .. ":" .. tostring(cellZ)
end

local function buildStreamingCellSet(origin, radius)
	local cells = {}
	local radiusSquared = radius * radius
	local minimumCellX = math.floor((origin.X - radius) / STREAMING_CELL_SIZE)
	local maximumCellX = math.floor((origin.X + radius) / STREAMING_CELL_SIZE)
	local minimumCellZ = math.floor((origin.Z - radius) / STREAMING_CELL_SIZE)
	local maximumCellZ = math.floor((origin.Z + radius) / STREAMING_CELL_SIZE)
	for cellX = minimumCellX, maximumCellX do
		local minimumX = cellX * STREAMING_CELL_SIZE
		local maximumX = minimumX + STREAMING_CELL_SIZE
		local closestX = math.clamp(origin.X, minimumX, maximumX)
		for cellZ = minimumCellZ, maximumCellZ do
			local minimumZ = cellZ * STREAMING_CELL_SIZE
			local maximumZ = minimumZ + STREAMING_CELL_SIZE
			local closestZ = math.clamp(origin.Z, minimumZ, maximumZ)
			local offsetX = closestX - origin.X
			local offsetZ = closestZ - origin.Z
			if offsetX * offsetX + offsetZ * offsetZ <= radiusSquared then
				cells[streamingCellKey(cellX, cellZ)] = true
			end
		end
	end
	return cells
end

local function isFiniteVector3(value)
	return typeof(value) == "Vector3"
		and value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and math.abs(value.X) < 1_000_000
		and math.abs(value.Y) < 1_000_000
		and math.abs(value.Z) < 1_000_000
end

local function getPredictionDisplacement(velocity, poweredSeconds, elapsed)
	local poweredElapsed = math.min(elapsed, math.max(0, poweredSeconds))
	local displacement = velocity * poweredElapsed
	local dampingElapsed = math.max(0, elapsed - poweredElapsed)
	if dampingElapsed > 0 then
		local dampingDistance
		if MOTION_DAMPING > 0 then
			dampingDistance = (1 - math.exp(-MOTION_DAMPING * dampingElapsed)) / MOTION_DAMPING
		else
			dampingDistance = dampingElapsed
		end
		displacement += velocity * dampingDistance
	end
	return displacement
end

local function clampPredictionToStopPoint(samplePosition, displacement, stopPoint, stopRadius)
	if not isFiniteVector3(stopPoint) then
		return displacement
	end
	local stopDelta = Vector3.new(stopPoint.X - samplePosition.X, 0, stopPoint.Z - samplePosition.Z)
	if stopDelta.Magnitude <= stopRadius or stopDelta.Magnitude <= 0.0001 then
		return Vector3.zero
	end
	local stopDirection = stopDelta.Unit
	local remainingDistance = math.max(0, stopDelta.Magnitude - stopRadius)
	local projectedDistance = Vector3.new(displacement.X, 0, displacement.Z):Dot(stopDirection)
	if projectedDistance >= remainingDistance then
		return stopDirection * remainingDistance
	end
	return displacement
end

function YardLeafController:Init(remotes)
	self.Remotes = remotes
	self.Player = Players.LocalPlayer
	self.ModelFolder = ReplicatedStorage:WaitForChild("Model")
	local highlightContainer = ReplicatedStorage:WaitForChild("miaobian")
	self.FinalGuidanceHighlightTemplate = highlightContainer:WaitForChild("Highlight02")
	assert(self.FinalGuidanceHighlightTemplate:IsA("Highlight"), "ReplicatedStorage.miaobian.Highlight02 must be a Highlight")
	self.ActiveOwnerUserId = nil
	self.SnapshotSerial = nil
	self.SnapshotLoading = false
	self.Descriptors = {}
	self.DescriptorBuckets = {}
	self.DescriptorCellKeys = {}
	self.DescriptorIdsByArea = {}
	self.Models = {}
	self.LoadedModelBuckets = {}
	self.LoadedModelCellKeys = {}
	self.Folders = {}
	self.AreaStates = {}
	self.ModelPools = {}
	self.PooledModelCount = 0
	self.ActivePoolLeafTypes = {}
	self.ActivePoolLeafTypeSet = {}
	self.PoolMaintenanceToken = 0
	self.PoolMaintenanceRunning = false
	self.PoolPrewarmNextTypeIndex = 1
	self.TemplateVisualData = {}
	self.ModelVisualData = {}
	self.MotionStates = {}
	self.CreateQueue = {}
	self.CreateQueueHead = 1
	self.QueuedIds = {}
	self.RecycleQueue = {}
	self.RecycleQueueHead = 1
	self.RecycleQueuedIds = {}
	self.PendingDeltas = {}
	self.AnimatingModels = {}
	self.StreamingDirty = true
	self.StreamingLoadDistance = BASE_STREAMING_LOAD_DISTANCE
	self.StreamingHideDistance = BASE_STREAMING_HIDE_DISTANCE
	self.ActiveStreamingLoadCells = {}
	self.ActiveStreamingHideCells = {}
	self.LastStreamingPlayerCellX = nil
	self.LastStreamingPlayerCellZ = nil
	self.VisualMotionElapsed = 0
	self.SpatialBoundsElapsed = 0
	self.VisualBoundsRevision = 0
	self.CurrentAreaId = nil
	self.CurrentAreaCollectedLeafCount = 0
	self.CurrentAreaTotalLeafCount = 0
	self.FinalGuidanceActive = false
	self.FinalGuidanceAreaId = nil
	self.FinalGuidanceDirty = false
	self.FinalGuidanceTargets = {}
	self.FinalGuidanceTargetSet = {}
	self.FinalGuidanceHighlights = {}
	self.FinalGuidanceChangedHandlers = {}
	self.CharacterDiedConnection = nil

	for _, leafType in LeafConfig.ActiveOrder do
		local template = self.ModelFolder:WaitForChild(leafType)
		assert(template:IsA("Model"), "ReplicatedStorage.Model." .. leafType .. " must be a Model")
		local boundingCFrame, boundingSize = template:GetBoundingBox()
		local baseParts = {}
		for _, descendant in template:GetDescendants() do
			if descendant:IsA("BasePart") then
				table.insert(baseParts, descendant)
			end
		end
		assert(#baseParts > 0, "ReplicatedStorage.Model." .. leafType .. " needs a BasePart")
		self.TemplateVisualData[leafType] = {
			Scale = template:GetScale(),
			BoundingSize = boundingSize,
			BoundsToPivot = boundingCFrame:ToObjectSpace(template:GetPivot()),
			SinglePart = #baseParts == 1,
			BoundsToPart = if #baseParts == 1
				then boundingCFrame:ToObjectSpace(baseParts[1].CFrame)
				else nil,
		}
		self.ModelPools[leafType] = {}
	end

	remotes.YardLeafSnapshot.OnClientEvent:Connect(function(packet)
		self:_handleSnapshotPacket(packet)
	end)
	remotes.YardLeafDelta.OnClientEvent:Connect(function(packet)
		self:_handleDeltaPacket(packet)
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		local harvestRadius = math.max(0, tonumber(snapshot.HarvestRadius) or 0)
		local harvestForwardOffset = math.max(0, tonumber(snapshot.HarvestForwardOffset) or 0)
		local nextLoadDistance = math.max(
			BASE_STREAMING_LOAD_DISTANCE,
			harvestForwardOffset + harvestRadius + TOOL_STREAMING_MARGIN
		)
		local nextHideDistance = math.max(
			BASE_STREAMING_HIDE_DISTANCE,
			nextLoadDistance + 2 * STREAMING_CELL_SIZE
		)
		if
			nextLoadDistance ~= self.StreamingLoadDistance
			or nextHideDistance ~= self.StreamingHideDistance
		then
			self.StreamingLoadDistance = nextLoadDistance
			self.StreamingHideDistance = nextHideDistance
			self.StreamingDirty = true
		end
		local ownerUserId = tonumber(snapshot.ActiveYardOwnerUserId)
		if ownerUserId and ownerUserId ~= self.ActiveOwnerUserId then
			self.ActiveOwnerUserId = ownerUserId
			self.SnapshotLoading = false
			self.SnapshotSerial = nil
			self:_clearWorld()
			remotes.YardLeafSnapshot:FireServer("Request")
		end
		self.CurrentAreaId = type(snapshot.CurrentAreaId) == "string"
			and snapshot.CurrentAreaId
			or type(snapshot.AreaId) == "string" and snapshot.AreaId
			or nil
		self.CurrentAreaCollectedLeafCount = math.max(
			0,
			math.floor(tonumber(snapshot.AreaCollectedLeafCount) or 0)
		)
		self.CurrentAreaTotalLeafCount = math.max(
			0,
			math.floor(tonumber(snapshot.AreaTotalLeafCount) or 0)
		)
		self.CurrentAreaCollectedLeafCount = math.min(
			self.CurrentAreaCollectedLeafCount,
			self.CurrentAreaTotalLeafCount
		)
		self:_updateFinalGuidanceState()
	end)

	RunService.Heartbeat:Connect(function(deltaTime)
		self:_updateMovingVisuals(deltaTime)
		self:_updateRemovalAnimations()
		if self:_shouldRefreshStreaming() then
			self:_refreshStreaming()
		end
		if self.FinalGuidanceDirty then
			self:_refreshFinalGuidanceTargets()
		end
		self:_processCreateQueue()
		self:_processRecycleQueue()
	end)
	local function handleCharacterAdded(character)
		self.StreamingDirty = true
		self.FinalGuidanceDirty = self.FinalGuidanceActive
		if self.CharacterDiedConnection then
			self.CharacterDiedConnection:Disconnect()
			self.CharacterDiedConnection = nil
		end
		task.defer(function()
			local humanoid = character:FindFirstChildOfClass("Humanoid")
				or character:WaitForChild("Humanoid", 5)
			if character ~= self.Player.Character or not humanoid or not humanoid:IsA("Humanoid") then
				return
			end
			self.CharacterDiedConnection = humanoid.Died:Connect(function()
				self:_setFinalGuidanceTargets({})
				self.FinalGuidanceDirty = self.FinalGuidanceActive
			end)
		end)
	end
	self.Player.CharacterAdded:Connect(handleCharacterAdded)
	self.Player.CharacterRemoving:Connect(function()
		if self.CharacterDiedConnection then
			self.CharacterDiedConnection:Disconnect()
			self.CharacterDiedConnection = nil
		end
		self:_setFinalGuidanceTargets({})
		self.FinalGuidanceDirty = self.FinalGuidanceActive
	end)
	if self.Player.Character then
		handleCharacterAdded(self.Player.Character)
	end

	task.delay(0.5, function()
		remotes.YardLeafSnapshot:FireServer("Request")
	end)
end

function YardLeafController:IsFinalGuidanceActive()
	return self.FinalGuidanceActive == true
end

function YardLeafController:AddFinalGuidanceChangedHandler(handler)
	assert(type(handler) == "function", "Final-guidance handler must be a function")
	table.insert(self.FinalGuidanceChangedHandlers, handler)
	local success, message = pcall(handler, self.FinalGuidanceActive == true)
	if not success then
		warn("Final-guidance handler failed: " .. tostring(message))
	end
end

function YardLeafController:_notifyFinalGuidanceChanged()
	for _, handler in self.FinalGuidanceChangedHandlers do
		local success, message = pcall(handler, self.FinalGuidanceActive == true)
		if not success then
			warn("Final-guidance handler failed: " .. tostring(message))
		end
	end
end

function YardLeafController:_getFinalGuidanceHighlight(index)
	local highlight = self.FinalGuidanceHighlights[index]
	if highlight then
		return highlight
	end
	highlight = self.FinalGuidanceHighlightTemplate:Clone()
	highlight.Name = string.format("LocalFinalLeafHighlight_%02d", index)
	highlight.Adornee = nil
	highlight.Enabled = false
	highlight.Parent = Workspace
	self.FinalGuidanceHighlights[index] = highlight
	return highlight
end

function YardLeafController:_applyFinalGuidanceHighlights()
	for index = 1, FINAL_GUIDANCE_MAX_TARGETS do
		local leafId = self.FinalGuidanceTargets[index]
		local model = leafId and self.Models[leafId] or nil
		local highlight = self.FinalGuidanceHighlights[index]
		if leafId and model and model.Parent and self.Descriptors[leafId] then
			highlight = highlight or self:_getFinalGuidanceHighlight(index)
			highlight.Adornee = model
			highlight.Enabled = true
		elseif highlight then
			highlight.Enabled = false
			highlight.Adornee = nil
		end
	end
end

function YardLeafController:_finalGuidanceTargetsMatch(nextTargets)
	if #self.FinalGuidanceTargets ~= #nextTargets then
		return false
	end
	for index, leafId in nextTargets do
		if self.FinalGuidanceTargets[index] ~= leafId then
			return false
		end
	end
	return true
end

function YardLeafController:_setFinalGuidanceTargets(nextTargets)
	if self:_finalGuidanceTargetsMatch(nextTargets) then
		self:_applyFinalGuidanceHighlights()
		return
	end
	local previousTargets = table.clone(self.FinalGuidanceTargets)
	table.clear(self.FinalGuidanceTargets)
	table.clear(self.FinalGuidanceTargetSet)
	for _, leafId in nextTargets do
		if type(leafId) == "string" and self.Descriptors[leafId] and not self.FinalGuidanceTargetSet[leafId] then
			self.FinalGuidanceTargetSet[leafId] = true
			table.insert(self.FinalGuidanceTargets, leafId)
		end
	end
	for _, leafId in previousTargets do
		if not self.FinalGuidanceTargetSet[leafId] then
			local descriptor = self.Descriptors[leafId]
			local model = self.Models[leafId]
			if descriptor and model and not self:_shouldKeepDescriptorLoaded(descriptor) then
				self:_queueRecycle(leafId, model)
			end
		end
	end
	for _, leafId in self.FinalGuidanceTargets do
		self:_queueCreate(leafId)
	end
	self:_applyFinalGuidanceHighlights()
end

function YardLeafController:_setFinalGuidanceActive(active, areaId)
	local nextActive = active == true
	local nextAreaId = if nextActive then areaId else nil
	local activeChanged = self.FinalGuidanceActive ~= nextActive
	local areaChanged = self.FinalGuidanceAreaId ~= nextAreaId
	if not activeChanged and not areaChanged then
		return
	end
	self.FinalGuidanceActive = nextActive
	self.FinalGuidanceAreaId = nextAreaId
	self:_setFinalGuidanceTargets({})
	self.FinalGuidanceDirty = nextActive
	if activeChanged then
		self:_notifyFinalGuidanceChanged()
	end
end

function YardLeafController:_updateFinalGuidanceState()
	local areaId = self.CurrentAreaId
	local areaState = areaId and self.AreaStates[areaId] or nil
	local remainingLeaves = math.max(
		0,
		self.CurrentAreaTotalLeafCount - self.CurrentAreaCollectedLeafCount
	)
	local active = not self.SnapshotLoading
		and type(areaId) == "string"
		and areaState ~= nil
		and areaState.GameplayReady == true
		and areaState.PreviewOnly ~= true
		and areaState.Completed ~= true
		and remainingLeaves >= 1
		and remainingLeaves <= FINAL_GUIDANCE_REMAINING_LEAVES
	self:_setFinalGuidanceActive(active, areaId)
end

local function isBetterFinalGuidanceCandidate(left, right)
	return left.DistanceSquared < right.DistanceSquared
		or left.DistanceSquared == right.DistanceSquared and left.LeafId < right.LeafId
end

function YardLeafController:_refreshFinalGuidanceTargets()
	self.FinalGuidanceDirty = false
	if not self.FinalGuidanceActive or self.SnapshotLoading then
		self:_setFinalGuidanceTargets({})
		return
	end
	local rootPosition = self:_getPlayerRootPosition()
	local areaLeafIds = self.DescriptorIdsByArea[self.FinalGuidanceAreaId]
	if not rootPosition or not areaLeafIds then
		self:_setFinalGuidanceTargets({})
		return
	end

	debug.profilebegin("FinalLeafGuidanceSelection")
	local best = {}
	for leafId in areaLeafIds do
		local descriptor = self.Descriptors[leafId]
		if descriptor and descriptor.AreaId == self.FinalGuidanceAreaId then
			local position = descriptor.BoundingCFrame.Position
			local offsetX = position.X - rootPosition.X
			local offsetZ = position.Z - rootPosition.Z
			local candidate = {
				LeafId = leafId,
				DistanceSquared = offsetX * offsetX + offsetZ * offsetZ,
			}
			local insertionIndex = #best + 1
			for index, current in best do
				if isBetterFinalGuidanceCandidate(candidate, current) then
					insertionIndex = index
					break
				end
			end
			table.insert(best, insertionIndex, candidate)
			if #best > FINAL_GUIDANCE_MAX_TARGETS then
				table.remove(best)
			end
		end
	end
	debug.profileend()

	local nextTargets = {}
	for _, candidate in best do
		table.insert(nextTargets, candidate.LeafId)
	end
	self:_setFinalGuidanceTargets(nextTargets)
end

function YardLeafController:_ensureFolder(areaId)
	local folder = self.Folders[areaId]
	if folder and folder.Parent then
		return folder
	end
	local area = Workspace:WaitForChild(areaId)
	folder = area:FindFirstChild("GeneratedLeaves")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "GeneratedLeaves"
		folder.Parent = area
	end
	self.Folders[areaId] = folder
	return folder
end

function YardLeafController:_predictDescriptorBounds(descriptor, serverNow)
	local sampleBounds = descriptor.BoundingCFrame
	if descriptor.IsMoving ~= true or typeof(sampleBounds) ~= "CFrame" then
		return sampleBounds
	end
	local velocity = descriptor.MotionVelocity
	if not isFiniteVector3(velocity) then
		return sampleBounds
	end
	local sampleServerTime = tonumber(descriptor.MotionSampleServerTime) or serverNow
	local elapsed = math.clamp(serverNow - sampleServerTime, 0, MAXIMUM_PREDICTION_SECONDS)
	local poweredSeconds = math.max(0, tonumber(descriptor.MotionPoweredSecondsRemaining) or 0)
	local displacement = getPredictionDisplacement(velocity, poweredSeconds, elapsed)
	displacement = clampPredictionToStopPoint(
		sampleBounds.Position,
		displacement,
		descriptor.MotionStopPoint,
		math.max(0, tonumber(descriptor.MotionStopRadius) or 0)
	)
	local angularVelocity = tonumber(descriptor.MotionAngularVelocity) or 0
	local angularDisplacement = getPredictionDisplacement(
		Vector3.new(angularVelocity, 0, 0),
		poweredSeconds,
		elapsed
	).X
	return CFrame.new(sampleBounds.Position + displacement)
		* CFrame.Angles(0, math.rad(angularDisplacement), 0)
		* sampleBounds.Rotation
end

function YardLeafController:_scheduleMotion(descriptor, model, immediate)
	local leafId = descriptor.Id
	if type(leafId) ~= "string" or not model or (not model.Parent and immediate ~= true) then
		return
	end
	local previousState = self.MotionStates[leafId]
	local currentVisualBounds = previousState and previousState.LastVisualBounds
	if typeof(currentVisualBounds) ~= "CFrame" then
		currentVisualBounds = model:GetAttribute(VISUAL_BOUNDS_CFRAME_ATTRIBUTE)
	end
	local serverNow = Workspace:GetServerTimeNow()
	local predictedBounds = self:_predictDescriptorBounds(descriptor, serverNow)
	if typeof(currentVisualBounds) ~= "CFrame" then
		currentVisualBounds = predictedBounds
	end
	self.MotionStates[leafId] = {
		Descriptor = descriptor,
		Model = model,
		CorrectionFrom = if immediate then predictedBounds else currentVisualBounds,
		CorrectionStartedAt = if immediate then os.clock() - CORRECTION_DURATION else os.clock(),
		LastVisualBounds = currentVisualBounds,
	}
	self:_setInfluenceAttributes(model, descriptor)
end

function YardLeafController:_updateMovingVisuals(deltaTime)
	self.VisualMotionElapsed += math.max(0, deltaTime)
	self.SpatialBoundsElapsed += math.max(0, deltaTime)
	if self.VisualMotionElapsed < CLIENT_VISUAL_STEP then
		return
	end
	self.VisualMotionElapsed %= CLIENT_VISUAL_STEP

	local publishSpatialBounds = self.SpatialBoundsElapsed >= SPATIAL_BOUNDS_UPDATE_INTERVAL
	if publishSpatialBounds then
		self.SpatialBoundsElapsed %= SPATIAL_BOUNDS_UPDATE_INTERVAL
	end
	local serverNow = Workspace:GetServerTimeNow()
	local clientNow = os.clock()
	local bulkParts = {}
	local bulkCFrames = {}
	local publishedStates = {}
	local completedLeafIds = {}

	for leafId, state in self.MotionStates do
		local model = state.Model
		local descriptor = state.Descriptor
		local visualData = model and self.ModelVisualData[model]
		if
			not model
			or not model.Parent
			or self.Models[leafId] ~= model
			or not descriptor
		then
			table.insert(completedLeafIds, leafId)
			continue
		end

		local predictedBounds = self:_predictDescriptorBounds(descriptor, serverNow)
		local correctionAlpha = if CORRECTION_DURATION <= 0
			then 1
			else math.clamp((clientNow - state.CorrectionStartedAt) / CORRECTION_DURATION, 0, 1)
		local easedCorrectionAlpha = 1 - (1 - correctionAlpha) * (1 - correctionAlpha)
		local visualBounds = state.CorrectionFrom:Lerp(predictedBounds, easedCorrectionAlpha)
		state.LastVisualBounds = visualBounds

		local singlePart = visualData and visualData.SinglePart
		local templateData = visualData and visualData.Template
		if singlePart and singlePart.Parent and templateData and typeof(templateData.BoundsToPart) == "CFrame" then
			table.insert(bulkParts, singlePart)
			table.insert(bulkCFrames, visualBounds * templateData.BoundsToPart)
		elseif templateData and typeof(templateData.BoundsToPivot) == "CFrame" then
			model:PivotTo(visualBounds * templateData.BoundsToPivot)
		else
			self:_positionModel(model, descriptor, visualBounds)
		end

		local completed = descriptor.IsMoving ~= true and correctionAlpha >= 1
		if publishSpatialBounds or completed then
			table.insert(publishedStates, {
				Model = model,
				Descriptor = descriptor,
				BoundingCFrame = visualBounds,
			})
		end
		if completed then
			table.insert(completedLeafIds, leafId)
		end
	end

	if #bulkParts > 0 then
		Workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	for _, entry in publishedStates do
		self:_publishVisualBounds(entry.Model, entry.Descriptor, entry.BoundingCFrame)
	end
	for _, leafId in completedLeafIds do
		self.MotionStates[leafId] = nil
	end
end

function YardLeafController:_restorePreparedModelVisuals(model, visualData)
	local templateData = visualData and visualData.Template
	local targetScale = templateData and templateData.Scale
	if targetScale and math.abs(model:GetScale() - targetScale) > 0.0001 then
		model:ScaleTo(targetScale)
	end
	for _, basePart in visualData and visualData.BaseParts or {} do
		if basePart.Parent then
			basePart.LocalTransparencyModifier = 0
		end
	end
	for _, surfaceVisual in visualData and visualData.SurfaceVisuals or {} do
		local instance = surfaceVisual.Instance
		if instance.Parent then
			instance.Transparency = surfaceVisual.BaseTransparency
		end
	end
end

function YardLeafController:_prepareModel(model, leafType)
	local templateData = self.TemplateVisualData[leafType]
	model.Parent = nil
	model.Name = leafType
	model:ScaleTo(templateData and templateData.Scale or self.ModelFolder[leafType]:GetScale())
	local baseParts = {}
	local surfaceVisuals = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.CastShadow = false
			descendant.LocalTransparencyModifier = 0
			table.insert(baseParts, descendant)
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			local baseTransparency = tonumber(descendant:GetAttribute(BASE_TRANSPARENCY_ATTRIBUTE))
			if not baseTransparency then
				baseTransparency = descendant.Transparency
				descendant:SetAttribute(BASE_TRANSPARENCY_ATTRIBUTE, baseTransparency)
			end
			baseTransparency = math.clamp(baseTransparency, 0, 1)
			descendant.Transparency = baseTransparency
			table.insert(surfaceVisuals, {
				Instance = descendant,
				BaseTransparency = baseTransparency,
			})
		end
	end
	local singlePart = templateData and templateData.SinglePart == true and #baseParts == 1
	if singlePart then
		model.PrimaryPart = baseParts[1]
	end
	self.ModelVisualData[model] = {
		LeafType = leafType,
		Template = templateData,
		SinglePart = if singlePart then baseParts[1] else nil,
		BaseParts = baseParts,
		SurfaceVisuals = surfaceVisuals,
	}
	model:SetAttribute("LeafType", leafType)
	return model
end

function YardLeafController:_activateModel(model, descriptor)
	local visualData = self.ModelVisualData[model]
	if not visualData or visualData.LeafType ~= descriptor.LeafType then
		self:_prepareModel(model, descriptor.LeafType)
		visualData = self.ModelVisualData[model]
	end
	self:_restorePreparedModelVisuals(model, visualData)
	model.Name = descriptor.Id
	model:SetAttribute("LeafId", descriptor.Id)
	model:SetAttribute("LeafType", descriptor.LeafType)
	model:SetAttribute("BagValue", descriptor.BagValue)
	model:SetAttribute("AreaId", descriptor.AreaId)
	model:SetAttribute("Collected", false)
end

function YardLeafController:_resetModelForPool(model, visualData)
	self:_restorePreparedModelVisuals(model, visualData)
	model.Parent = nil
	model.Name = visualData.LeafType
	model:SetAttribute("LeafId", nil)
	model:SetAttribute("LeafType", visualData.LeafType)
	model:SetAttribute("BagValue", nil)
	model:SetAttribute("AreaId", nil)
	model:SetAttribute("Collected", nil)
	model:SetAttribute(VISUAL_BOUNDS_CFRAME_ATTRIBUTE, nil)
	model:SetAttribute(VISUAL_BOUNDS_SIZE_ATTRIBUTE, nil)
	model:SetAttribute("LeafMoveRevision", nil)
	model:SetAttribute("LastInfluencedUserId", nil)
	model:SetAttribute("LastInfluencedToolId", nil)
end

function YardLeafController:_destroyPreparedModel(model)
	self.ModelVisualData[model] = nil
	model:Destroy()
end

function YardLeafController:_createPreparedModel(leafType)
	local template = self.ModelFolder:FindFirstChild(leafType)
	if not template or not template:IsA("Model") then
		return nil
	end
	return self:_prepareModel(template:Clone(), leafType)
end

function YardLeafController:_poolNeedsMaintenance()
	for _, leafType in LeafConfig.ActiveOrder do
		local pool = self.ModelPools[leafType]
		if pool and #pool > 0 and not self.ActivePoolLeafTypeSet[leafType] then
			return true
		end
	end
	if self.PooledModelCount >= MAXIMUM_TOTAL_POOLED_MODELS then
		return false
	end
	for _, leafType in self.ActivePoolLeafTypes do
		local pool = self.ModelPools[leafType]
		if pool and #pool < POOL_TARGET_PER_ACTIVE_TYPE then
			return true
		end
	end
	return false
end

function YardLeafController:_performPoolMaintenanceStep()
	for _, leafType in LeafConfig.ActiveOrder do
		local pool = self.ModelPools[leafType]
		if pool and #pool > 0 and not self.ActivePoolLeafTypeSet[leafType] then
			local model = table.remove(pool)
			self.PooledModelCount = math.max(0, self.PooledModelCount - 1)
			self:_destroyPreparedModel(model)
			return true
		end
	end

	local activeTypeCount = #self.ActivePoolLeafTypes
	if activeTypeCount <= 0 or self.PooledModelCount >= MAXIMUM_TOTAL_POOLED_MODELS then
		return false
	end
	for offset = 0, activeTypeCount - 1 do
		local index = ((self.PoolPrewarmNextTypeIndex + offset - 1) % activeTypeCount) + 1
		local leafType = self.ActivePoolLeafTypes[index]
		local pool = self.ModelPools[leafType]
		if pool and #pool < POOL_TARGET_PER_ACTIVE_TYPE then
			local model = self:_createPreparedModel(leafType)
			self.PoolPrewarmNextTypeIndex = (index % activeTypeCount) + 1
			if model then
				table.insert(pool, model)
				self.PooledModelCount += 1
				return true
			end
			return false
		end
	end
	return false
end

function YardLeafController:_startPoolMaintenance()
	if self.PoolMaintenanceRunning or not self:_poolNeedsMaintenance() then
		return
	end
	self.PoolMaintenanceRunning = true
	local maintenanceToken = self.PoolMaintenanceToken
	task.spawn(function()
		while maintenanceToken == self.PoolMaintenanceToken and self:_poolNeedsMaintenance() do
			task.wait(POOL_PREWARM_INTERVAL)
			if maintenanceToken ~= self.PoolMaintenanceToken then
				break
			end
			debug.profilebegin("LeafModelPrewarm")
			for _ = 1, POOL_PREWARM_BATCH_SIZE do
				if not self:_performPoolMaintenanceStep() then
					break
				end
			end
			debug.profileend()
		end
		if maintenanceToken ~= self.PoolMaintenanceToken then
			return
		end
		self.PoolMaintenanceRunning = false
		if self:_poolNeedsMaintenance() then
			self:_startPoolMaintenance()
		end
	end)
end

function YardLeafController:_setActivePoolLeafTypes(nextLeafTypes)
	local unchanged = #nextLeafTypes == #self.ActivePoolLeafTypes
	if unchanged then
		for index, leafType in nextLeafTypes do
			if self.ActivePoolLeafTypes[index] ~= leafType then
				unchanged = false
				break
			end
		end
	end
	if unchanged then
		self:_startPoolMaintenance()
		return
	end

	self.PoolMaintenanceToken += 1
	self.PoolMaintenanceRunning = false
	self.PoolPrewarmNextTypeIndex = 1
	self.ActivePoolLeafTypes = table.clone(nextLeafTypes)
	table.clear(self.ActivePoolLeafTypeSet)
	for _, leafType in self.ActivePoolLeafTypes do
		self.ActivePoolLeafTypeSet[leafType] = true
	end
	self:_startPoolMaintenance()
end

function YardLeafController:_refreshPoolTargetsFromAreaStates()
	local nextLeafTypes = {}
	for _, areaId in RegionConfig.Order do
		local areaState = self.AreaStates[areaId]
		if areaState and areaState.GameplayReady == true and areaState.Completed ~= true then
			local seenLeafTypes = {}
			for _, poolEntry in LeafConfig.AreaPools[areaId] or {} do
				local leafType = poolEntry.LeafType
				if self.ModelPools[leafType] and not seenLeafTypes[leafType] then
					seenLeafTypes[leafType] = true
					table.insert(nextLeafTypes, leafType)
				end
			end
			break
		end
	end
	self:_setActivePoolLeafTypes(nextLeafTypes)
end

function YardLeafController:_publishVisualBounds(model, descriptor, boundingCFrame)
	model:SetAttribute(VISUAL_BOUNDS_CFRAME_ATTRIBUTE, boundingCFrame)
	model:SetAttribute(VISUAL_BOUNDS_SIZE_ATTRIBUTE, descriptor.BoundingSize)
	self.VisualBoundsRevision += 1
	model:SetAttribute("LeafMoveRevision", self.VisualBoundsRevision)
	model:SetAttribute("LastInfluencedUserId", tonumber(descriptor.LastInfluencedUserId))
	model:SetAttribute(
		"LastInfluencedToolId",
		type(descriptor.LastInfluencedToolId) == "string" and descriptor.LastInfluencedToolId or nil
	)
end

function YardLeafController:_setInfluenceAttributes(model, descriptor)
	model:SetAttribute("LastInfluencedUserId", tonumber(descriptor.LastInfluencedUserId))
	model:SetAttribute(
		"LastInfluencedToolId",
		type(descriptor.LastInfluencedToolId) == "string" and descriptor.LastInfluencedToolId or nil
	)
end

function YardLeafController:_positionModel(model, descriptor, boundingCFrame)
	local targetBounds = boundingCFrame or descriptor.BoundingCFrame
	local visualData = self.ModelVisualData[model]
	local templateData = visualData and visualData.Template
	local singlePart = visualData and visualData.SinglePart
	if singlePart and singlePart.Parent and templateData and typeof(templateData.BoundsToPart) == "CFrame" then
		singlePart.CFrame = targetBounds * templateData.BoundsToPart
	elseif templateData and typeof(templateData.BoundsToPivot) == "CFrame" then
		model:PivotTo(targetBounds * templateData.BoundsToPivot)
	else
		local currentBounds = model:GetBoundingBox()
		model:PivotTo(targetBounds * currentBounds:Inverse() * model:GetPivot())
	end
	self:_publishVisualBounds(model, descriptor, targetBounds)
end

function YardLeafController:_takeModel(descriptor)
	local pool = self.ModelPools[descriptor.LeafType]
	local model = table.remove(pool)
	if model then
		self.PooledModelCount = math.max(0, self.PooledModelCount - 1)
	else
		model = self:_createPreparedModel(descriptor.LeafType)
	end
	assert(model, "Missing prepared leaf model for " .. tostring(descriptor.LeafType))
	self:_activateModel(model, descriptor)
	local initialBounds = self:_predictDescriptorBounds(descriptor, Workspace:GetServerTimeNow())
	self:_positionModel(model, descriptor, initialBounds)
	model.Parent = self:_ensureFolder(descriptor.AreaId)
	if descriptor.IsMoving == true then
		self:_scheduleMotion(descriptor, model, true)
	end
	self:_startPoolMaintenance()
	return model
end

function YardLeafController:_recycleModel(model)
	if self.AnimatingModels[model] then
		return
	end
	local leafId = model:GetAttribute("LeafId")
	if type(leafId) == "string" then
		self.MotionStates[leafId] = nil
		self:_removeLoadedModelFromGrid(leafId)
	end
	local visualData = self.ModelVisualData[model]
	local leafType = visualData and visualData.LeafType or model:GetAttribute("LeafType")
	if type(leafType) ~= "string" or not self.ModelPools[leafType] or not visualData then
		self:_destroyPreparedModel(model)
		return
	end
	self:_resetModelForPool(model, visualData)
	local pool = self.ModelPools[leafType]
	if
		not self.ActivePoolLeafTypeSet[leafType]
		or #pool >= POOL_TARGET_PER_ACTIVE_TYPE
		or self.PooledModelCount >= MAXIMUM_TOTAL_POOLED_MODELS
	then
		self:_destroyPreparedModel(model)
	else
		table.insert(pool, model)
		self.PooledModelCount += 1
	end
	self:_startPoolMaintenance()
end

function YardLeafController:_clearWorld()
	self:_setFinalGuidanceActive(false)
	local animatingModels = {}
	for model in self.AnimatingModels do
		table.insert(animatingModels, model)
	end
	for _, model in animatingModels do
		self.AnimatingModels[model] = nil
		if model.Parent then
			self:_recycleModel(model)
		end
	end
	table.clear(self.MotionStates)
	table.clear(self.Descriptors)
	table.clear(self.DescriptorBuckets)
	table.clear(self.DescriptorCellKeys)
	table.clear(self.DescriptorIdsByArea)
	table.clear(self.AreaStates)
	table.clear(self.CreateQueue)
	self.CreateQueueHead = 1
	table.clear(self.QueuedIds)
	table.clear(self.RecycleQueue)
	self.RecycleQueueHead = 1
	table.clear(self.RecycleQueuedIds)
	table.clear(self.PendingDeltas)
	for leafId, model in self.Models do
		self.Models[leafId] = nil
		self:_recycleModel(model)
	end
	self:_setActivePoolLeafTypes({})
	table.clear(self.LoadedModelBuckets)
	table.clear(self.LoadedModelCellKeys)
	for _, folder in self.Folders do
		if folder.Parent then
			folder:SetAttribute("GenerationComplete", false)
			folder:SetAttribute("GameplayReady", false)
		end
	end
	self.StreamingDirty = true
	table.clear(self.ActiveStreamingLoadCells)
	table.clear(self.ActiveStreamingHideCells)
	self.LastStreamingPlayerCellX = nil
	self.LastStreamingPlayerCellZ = nil
end

function YardLeafController:_getPlayerRootPosition()
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
	then
		return nil
	end
	return rootPart.Position
end

function YardLeafController:_isDescriptorInStreamingCells(descriptor, cells)
	local key = self.DescriptorCellKeys[descriptor.Id]
	return key ~= nil and cells[key] == true
end

function YardLeafController:_shouldLoadDescriptor(descriptor)
	return self.FinalGuidanceTargetSet[descriptor.Id] == true
		or self:_isDescriptorInStreamingCells(descriptor, self.ActiveStreamingLoadCells)
end

function YardLeafController:_shouldKeepDescriptorLoaded(descriptor)
	return self.FinalGuidanceTargetSet[descriptor.Id] == true
		or self:_isDescriptorInStreamingCells(descriptor, self.ActiveStreamingHideCells)
end

function YardLeafController:_removeDescriptorFromArea(leafId, descriptor)
	local areaId = descriptor and descriptor.AreaId
	local areaLeafIds = areaId and self.DescriptorIdsByArea[areaId] or nil
	if not areaLeafIds then
		return
	end
	areaLeafIds[leafId] = nil
	if next(areaLeafIds) == nil then
		self.DescriptorIdsByArea[areaId] = nil
	end
end

function YardLeafController:_indexDescriptorInArea(descriptor)
	local areaLeafIds = self.DescriptorIdsByArea[descriptor.AreaId]
	if not areaLeafIds then
		areaLeafIds = {}
		self.DescriptorIdsByArea[descriptor.AreaId] = areaLeafIds
	end
	areaLeafIds[descriptor.Id] = true
end

function YardLeafController:_removeDescriptorFromGrid(leafId)
	local key = self.DescriptorCellKeys[leafId]
	if not key then
		return
	end
	local bucket = self.DescriptorBuckets[key]
	if bucket then
		bucket[leafId] = nil
		if next(bucket) == nil then
			self.DescriptorBuckets[key] = nil
		end
	end
	self.DescriptorCellKeys[leafId] = nil
end

function YardLeafController:_indexDescriptor(descriptor)
	self:_removeDescriptorFromGrid(descriptor.Id)
	local cellX, cellZ = streamingCellCoordinates(descriptor.BoundingCFrame.Position)
	local key = streamingCellKey(cellX, cellZ)
	local bucket = self.DescriptorBuckets[key]
	if not bucket then
		bucket = {}
		self.DescriptorBuckets[key] = bucket
	end
	bucket[descriptor.Id] = true
	self.DescriptorCellKeys[descriptor.Id] = key
end

function YardLeafController:_removeLoadedModelFromGrid(leafId)
	local key = self.LoadedModelCellKeys[leafId]
	if not key then
		return
	end
	local bucket = self.LoadedModelBuckets[key]
	if bucket then
		bucket[leafId] = nil
		if next(bucket) == nil then
			self.LoadedModelBuckets[key] = nil
		end
	end
	self.LoadedModelCellKeys[leafId] = nil
end

function YardLeafController:_indexLoadedModel(leafId, descriptor)
	if not self.Models[leafId] or not descriptor or typeof(descriptor.BoundingCFrame) ~= "CFrame" then
		self:_removeLoadedModelFromGrid(leafId)
		return
	end
	local cellX, cellZ = streamingCellCoordinates(descriptor.BoundingCFrame.Position)
	local key = streamingCellKey(cellX, cellZ)
	if self.LoadedModelCellKeys[leafId] == key then
		return
	end
	self:_removeLoadedModelFromGrid(leafId)
	local bucket = self.LoadedModelBuckets[key]
	if not bucket then
		bucket = {}
		self.LoadedModelBuckets[key] = bucket
	end
	bucket[leafId] = true
	self.LoadedModelCellKeys[leafId] = key
end

function YardLeafController:_queueCreate(leafId)
	if self.Models[leafId] or self.QueuedIds[leafId] or not self.Descriptors[leafId] then
		return
	end
	self.QueuedIds[leafId] = true
	table.insert(self.CreateQueue, leafId)
end

function YardLeafController:_processCreateQueue()
	if self.CreateQueueHead > #self.CreateQueue then
		return
	end
	if not self:_getPlayerRootPosition() then
		return
	end
	debug.profilebegin("LeafModelCreate")
	local processed = 0
	while processed < CREATE_BUDGET_PER_FRAME and self.CreateQueueHead <= #self.CreateQueue do
		local leafId = self.CreateQueue[self.CreateQueueHead]
		self.CreateQueueHead += 1
		self.QueuedIds[leafId] = nil
		local descriptor = self.Descriptors[leafId]
		if
			descriptor
			and not self.Models[leafId]
			and self:_shouldLoadDescriptor(descriptor)
		then
			local model = self:_takeModel(descriptor)
			self.Models[leafId] = model
			self:_indexLoadedModel(leafId, descriptor)
			self:_applyFinalGuidanceHighlights()
		end
		processed += 1
	end
	if self.CreateQueueHead > #self.CreateQueue then
		table.clear(self.CreateQueue)
		self.CreateQueueHead = 1
	end
	debug.profileend()
end

function YardLeafController:_queueRecycle(leafId, model)
	if
		not model
		or self.AnimatingModels[model]
		or self.RecycleQueuedIds[leafId] == model
	then
		return
	end
	self.RecycleQueuedIds[leafId] = model
	table.insert(self.RecycleQueue, {
		LeafId = leafId,
		Model = model,
	})
end

function YardLeafController:_processRecycleQueue()
	if self.RecycleQueueHead > #self.RecycleQueue then
		return
	end
	debug.profilebegin("LeafModelRecycle")
	local processed = 0
	while processed < RECYCLE_BUDGET_PER_FRAME and self.RecycleQueueHead <= #self.RecycleQueue do
		local entry = self.RecycleQueue[self.RecycleQueueHead]
		self.RecycleQueueHead += 1
		local leafId = entry.LeafId
		local model = entry.Model
		if self.RecycleQueuedIds[leafId] == model then
			self.RecycleQueuedIds[leafId] = nil
		end
		if self.Models[leafId] == model and not self.AnimatingModels[model] then
			local descriptor = self.Descriptors[leafId]
			local keepLoaded = descriptor and self:_shouldKeepDescriptorLoaded(descriptor)
			if not keepLoaded then
				self.Models[leafId] = nil
				self:_recycleModel(model)
			end
		end
		processed += 1
	end
	if self.RecycleQueueHead > #self.RecycleQueue then
		table.clear(self.RecycleQueue)
		self.RecycleQueueHead = 1
	end
	debug.profileend()
end

function YardLeafController:_shouldRefreshStreaming()
	local rootPosition = self:_getPlayerRootPosition()
	if not rootPosition then
		return false
	end
	if self.StreamingDirty or self.LastStreamingPlayerCellX == nil then
		return true
	end
	local cellX, cellZ = streamingCellCoordinates(rootPosition)
	return cellX ~= self.LastStreamingPlayerCellX or cellZ ~= self.LastStreamingPlayerCellZ
end

function YardLeafController:_refreshStreaming()
	local rootPosition = self:_getPlayerRootPosition()
	if not rootPosition then
		return
	end
	debug.profilebegin("LeafStreamingCellDiff")
	local nextLoadCells = buildStreamingCellSet(rootPosition, self.StreamingLoadDistance)
	local nextHideCells = buildStreamingCellSet(rootPosition, self.StreamingHideDistance)
	for key in nextLoadCells do
		if not self.ActiveStreamingLoadCells[key] then
			local bucket = self.DescriptorBuckets[key]
			if bucket then
				for leafId in bucket do
					self:_queueCreate(leafId)
				end
			end
		end
	end
	for key in self.ActiveStreamingHideCells do
		if not nextHideCells[key] then
			local bucket = self.LoadedModelBuckets[key]
			if bucket then
				for leafId in bucket do
					local model = self.Models[leafId]
					if model then
						self:_queueRecycle(leafId, model)
					end
				end
			end
		end
	end
	self.ActiveStreamingLoadCells = nextLoadCells
	self.ActiveStreamingHideCells = nextHideCells
	self.StreamingDirty = false
	self.LastStreamingPlayerCellX, self.LastStreamingPlayerCellZ = streamingCellCoordinates(rootPosition)
	if self.FinalGuidanceActive then
		self.FinalGuidanceDirty = true
	end
	debug.profileend()
end

function YardLeafController:_storeDescriptor(descriptor)
	if type(descriptor) ~= "table"
		or type(descriptor.Id) ~= "string"
		or type(descriptor.AreaId) ~= "string"
		or type(descriptor.LeafType) ~= "string"
		or typeof(descriptor.BoundingCFrame) ~= "CFrame"
		or typeof(descriptor.BoundingSize) ~= "Vector3"
	then
		return
	end
	local previousDescriptor = self.Descriptors[descriptor.Id]
	local previousRevision = previousDescriptor and tonumber(previousDescriptor.Revision)
	local nextRevision = tonumber(descriptor.Revision)
	if previousRevision and nextRevision and nextRevision < previousRevision then
		return
	end
	if previousDescriptor and previousDescriptor.AreaId ~= descriptor.AreaId then
		self:_removeDescriptorFromArea(descriptor.Id, previousDescriptor)
	end
	self.Descriptors[descriptor.Id] = descriptor
	self:_indexDescriptorInArea(descriptor)
	self:_indexDescriptor(descriptor)
	if self.FinalGuidanceActive and descriptor.AreaId == self.FinalGuidanceAreaId then
		self.FinalGuidanceDirty = true
	end
	local model = self.Models[descriptor.Id]
	if model then
		self:_indexLoadedModel(descriptor.Id, descriptor)
		if descriptor.IsMoving == true then
			self:_scheduleMotion(descriptor, model, false)
		else
			self.MotionStates[descriptor.Id] = nil
			self:_positionModel(model, descriptor)
		end
		if not self:_shouldKeepDescriptorLoaded(descriptor) then
			self:_queueRecycle(descriptor.Id, model)
		end
	elseif self:_shouldLoadDescriptor(descriptor) then
		self:_queueCreate(descriptor.Id)
	end
end

function YardLeafController:_applyMovePacket(packet)
	local sampleServerTime = tonumber(packet.SampleServerTime) or Workspace:GetServerTimeNow()
	local finalGuidanceChanged = false
	for _, move in packet.Leaves or {} do
		local leafId = type(move) == "table" and move.Id or nil
		local descriptor = type(leafId) == "string" and self.Descriptors[leafId] or nil
		if descriptor and typeof(move.BoundingCFrame) == "CFrame" then
			local currentRevision = tonumber(descriptor.Revision) or 0
			local moveRevision = tonumber(move.Revision) or currentRevision
			if moveRevision >= currentRevision then
				descriptor.BoundingCFrame = move.BoundingCFrame
				descriptor.Revision = moveRevision
				descriptor.LastInfluencedUserId = tonumber(move.LastInfluencedUserId)
				descriptor.LastInfluencedToolId = type(move.LastInfluencedToolId) == "string"
					and move.LastInfluencedToolId
					or nil
				descriptor.IsMoving = move.IsMoving == true
				descriptor.MotionSampleServerTime = tonumber(move.MotionSampleServerTime) or sampleServerTime
				descriptor.MotionVelocity = if isFiniteVector3(move.MotionVelocity)
					then move.MotionVelocity
					else Vector3.zero
				descriptor.MotionAngularVelocity = tonumber(move.MotionAngularVelocity) or 0
				descriptor.MotionPoweredSecondsRemaining = math.max(
					0,
					tonumber(move.MotionPoweredSecondsRemaining) or 0
				)
				descriptor.MotionStopPoint = if isFiniteVector3(move.MotionStopPoint)
					then move.MotionStopPoint
					else nil
				descriptor.MotionStopRadius = math.max(0, tonumber(move.MotionStopRadius) or 0)
				self:_indexDescriptor(descriptor)
				if self.FinalGuidanceActive and descriptor.AreaId == self.FinalGuidanceAreaId then
					finalGuidanceChanged = true
				end

				local model = self.Models[leafId]
				if model then
					self:_indexLoadedModel(leafId, descriptor)
					self:_scheduleMotion(descriptor, model, false)
					if not self:_shouldKeepDescriptorLoaded(descriptor) then
						self:_queueRecycle(leafId, model)
					end
				elseif self:_shouldLoadDescriptor(descriptor) then
					self:_queueCreate(leafId)
				end
			end
		end
	end
	if finalGuidanceChanged then
		self.FinalGuidanceDirty = true
	end
end

function YardLeafController:_applyAreaStates()
	for _, areaId in RegionConfig.Order do
		local folder = self:_ensureFolder(areaId)
		local areaState = self.AreaStates[areaId]
		folder:SetAttribute("GenerationComplete", areaState ~= nil)
		folder:SetAttribute("GameplayReady", areaState and areaState.GameplayReady == true or false)
		folder:SetAttribute("PreviewOnly", areaState and areaState.PreviewOnly == true or false)
	end
	self:_refreshPoolTargetsFromAreaStates()
	self:_updateFinalGuidanceState()
end

function YardLeafController:_handleSnapshotPacket(packet)
	if type(packet) ~= "table" or type(packet.Kind) ~= "string" then
		return
	end
	local ownerUserId = tonumber(packet.YardOwnerUserId)
	local serial = tonumber(packet.Serial)
	if not ownerUserId or not serial then
		return
	end
	if packet.Kind == "Begin" then
		if self.ActiveOwnerUserId and ownerUserId ~= self.ActiveOwnerUserId then
			return
		end
		self.ActiveOwnerUserId = ownerUserId
		self.SnapshotSerial = serial
		self.SnapshotLoading = true
		self:_clearWorld()
		for _, areaState in packet.Areas or {} do
			if type(areaState) == "table" and type(areaState.AreaId) == "string" then
				self.AreaStates[areaState.AreaId] = areaState
			end
		end
		self:_refreshPoolTargetsFromAreaStates()
		return
	end
	if ownerUserId ~= self.ActiveOwnerUserId or serial ~= self.SnapshotSerial then
		return
	end
	if packet.Kind == "Chunk" and self.SnapshotLoading then
		for _, descriptor in packet.Leaves or {} do
			self:_storeDescriptor(descriptor)
		end
	elseif packet.Kind == "End" and self.SnapshotLoading then
		self.SnapshotLoading = false
		self:_applyAreaStates()
		local pending = self.PendingDeltas
		self.PendingDeltas = {}
		for _, delta in pending do
			self:_applyDelta(delta)
		end
	end
end

function YardLeafController:_animateRemoval(model, packet)
	model:SetAttribute("Collected", true)
	local startPivot = model:GetPivot()
	local startPosition = startPivot.Position
	local startRotation = startPivot.Rotation
	local originalScale = model:GetScale()
	local duration = math.max(0.05, tonumber(packet.Duration) or 0.35)
	local lastTarget = typeof(packet.TargetPosition) == "Vector3" and packet.TargetPosition or startPosition
	local targetPlayer = tonumber(packet.TargetUserId) and Players:GetPlayerByUserId(packet.TargetUserId) or nil
	self.AnimatingModels[model] = {
		StartTime = os.clock(),
		Duration = duration,
		StartPosition = startPosition,
		StartRotation = startRotation,
		OriginalScale = originalScale,
		LastTarget = lastTarget,
		TargetPlayer = targetPlayer,
	}
end

function YardLeafController:_updateRemovalAnimations()
	if next(self.AnimatingModels) == nil then
		return
	end
	debug.profilebegin("LeafBatchRemovalAnimation")
	local now = os.clock()
	local completedModels = {}
	for model, animation in self.AnimatingModels do
		if not model.Parent then
			table.insert(completedModels, model)
			continue
		end
		local alpha = math.clamp((now - animation.StartTime) / animation.Duration, 0, 1)
		local eased = alpha * alpha
		local character = animation.TargetPlayer and animation.TargetPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			animation.LastTarget = rootPart.Position + Vector3.new(0, 0.2, 0)
		end
		local position = animation.StartPosition:Lerp(animation.LastTarget, eased)
			+ Vector3.new(0, 4 * alpha * (1 - alpha) * REMOVAL_ARC_HEIGHT, 0)
		model:ScaleTo(math.max(
			0.001,
			animation.OriginalScale * (1 + (REMOVAL_FINAL_SCALE - 1) * eased)
		))
		model:PivotTo(CFrame.new(position) * animation.StartRotation)
		if alpha >= 1 then
			table.insert(completedModels, model)
		end
	end
	for _, model in completedModels do
		self.AnimatingModels[model] = nil
		if model.Parent then
			self:_recycleModel(model)
		end
	end
	debug.profileend()
end

function YardLeafController:_applyDelta(packet)
	if packet.Kind == "Move" then
		self:_applyMovePacket(packet)
	elseif packet.Kind == "Upsert" then
		for _, descriptor in packet.Leaves or {} do
			self:_storeDescriptor(descriptor)
		end
	elseif packet.Kind == "Remove" then
		local maximumAnimatedLeaves = if packet.ToolId == DUST_COLLECTOR_TOOL_ID
			then DUST_COLLECTOR_ANIMATED_LEAVES_PER_BATCH
			else math.huge
		local animatedLeafCount = 0
		local finalGuidanceChanged = false
		for _, leafId in packet.LeafIds or {} do
			local descriptor = self.Descriptors[leafId]
			if descriptor and self.FinalGuidanceActive and descriptor.AreaId == self.FinalGuidanceAreaId then
				finalGuidanceChanged = true
			end
			self:_removeDescriptorFromArea(leafId, descriptor)
			self.Descriptors[leafId] = nil
			self:_removeDescriptorFromGrid(leafId)
			self.QueuedIds[leafId] = nil
			self.MotionStates[leafId] = nil
			local model = self.Models[leafId]
			if model then
				if packet.Effect == "Collect" then
					self.Models[leafId] = nil
					self:_removeLoadedModelFromGrid(leafId)
					self.RecycleQueuedIds[leafId] = nil
					if animatedLeafCount < maximumAnimatedLeaves then
						animatedLeafCount += 1
						self:_animateRemoval(model, packet)
					else
						self:_recycleModel(model)
					end
				else
					self:_queueRecycle(leafId, model)
				end
			end
		end
		if finalGuidanceChanged then
			self.FinalGuidanceDirty = true
			self:_refreshFinalGuidanceTargets()
		end
	end
end

function YardLeafController:_handleDeltaPacket(packet)
	if type(packet) ~= "table" or tonumber(packet.YardOwnerUserId) ~= self.ActiveOwnerUserId then
		return
	end
	if self.SnapshotLoading then
		table.insert(self.PendingDeltas, packet)
	else
		self:_applyDelta(packet)
	end
end

return YardLeafController

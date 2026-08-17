local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local HarvestGeometry = require(ReplicatedStorage.Shared.HarvestGeometry)
local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local LeafService = {}
local leafMotionConfig = LeafConfig.Motion or {}
local leafPopulationConfig = LeafConfig.Population or {}

local MAX_VERTICAL_PICKUP_DISTANCE = 4
local MIN_PICKUP_INTERVAL = 0.05
local BAG_FULL_FEEDBACK_COOLDOWN = 0.75
local HARVEST_AIM_MAX_AGE = 0.35
local HARVEST_AIM_MIN_UPDATE_INTERVAL = 0.03
local HARVEST_AIM_DISTANCE_TOLERANCE = 0.5
local PLAYER_CENTERED_AIM_OFFSET_TOLERANCE = 0.01
local PROGRESS_SNAPSHOT_INTERVAL = 0.2
local LEAF_MOTION_STEP = math.max(0.01, tonumber(leafMotionConfig.ServerSimulationStep) or 0.05)
local LEAF_MOTION_MAX_ACCUMULATOR = 0.25
local LEAF_MOTION_DAMPING = math.max(0, tonumber(leafMotionConfig.Damping) or 6)
local LEAF_MOVE_REPLICATION_INTERVAL = math.max(
	LEAF_MOTION_STEP,
	tonumber(leafMotionConfig.ReplicationInterval) or 0.1
)
local LEAF_MOVE_REPLICATION_CLOCK_TOLERANCE = LEAF_MOTION_STEP * 0.5
local LEAF_MOTION_STOP_SPEED = 0.05
local LEAF_MOTION_STOP_ANGULAR_SPEED = 2
local LEAF_MOTION_MAX_SPEED = 200
local SERVER_LEAF_GRID_CELL_SIZE = 8
local HAND_PICKUP_GRID_CELL_SIZE = 2
local HAND_MAX_SCANNED_LEAVES_PER_QUERY = 30
local MAX_DIRECT_GRID_QUERY_CELLS = 4096
local LEAF_PUSH_GROUND_GAP = 0.02
local LEAF_PUSH_RAY_HEIGHT = 8
local LEAF_PUSH_RAY_DISTANCE = 20
local LEAF_PUSH_DISTANCE_FRACTIONS = { 1, 0.75, 0.5, 0.25 }
local SNAPSHOT_CHUNK_SIZE = 100
local GENERATION_BATCH_SIZE = 100
local POPULATION_CALCULATION_BATCH_SIZE = 1000
local BLOCKED_PLACEMENT_WARNING_RATIO = 0.01
local HAND_TOOL_ID = "Tool01"
local BROOM_TOOL_ID = "Tool02"
local BLOWER_TOOL_ID = "Tool03"
local DUST_COLLECTOR_TOOL_ID = "Tool04"
local RANDOM_SEED_MODULUS = 2_147_483_647
local MAXIMUM_ACTIVE_LEAVES = math.max(
	1,
	math.floor(tonumber(leafPopulationConfig.MaximumActiveLeaves) or 2000)
)
local REFILL_WORK_BATCH_SIZE = math.clamp(
	math.floor(tonumber(leafPopulationConfig.RefillWorkBatchSize) or 20),
	1,
	20
)
local REFILL_BATCH_INTERVAL = math.max(
	0.1,
	tonumber(leafPopulationConfig.RefillBatchInterval) or 0.1
)
local REFILL_RETRY_INTERVAL = math.max(0.05, tonumber(leafPopulationConfig.RefillRetryInterval) or 0.05)
local REFILL_PREPARED_POSITION_TARGET = math.max(
	1,
	math.floor(tonumber(leafPopulationConfig.RefillPreparedPositionTarget) or 200)
)
local REFILL_PREPARATION_ATTEMPTS_PER_HEARTBEAT = math.max(
	1,
	math.floor(tonumber(leafPopulationConfig.RefillPreparationAttemptsPerHeartbeat) or 4)
)
local REFILL_ANCHOR_POSITION_ATTEMPTS = 4

local activePickupPlayers = {}
local activeMovingLeaves = {}
local lastPickupAttemptTimes = {}
local lastBagFullFeedbackTimes = {}
local harvestAimEntries = {}
local lastHarvestAimUpdateTimes = {}

local function isFiniteVector3(value)
	return typeof(value) == "Vector3"
		and value.X == value.X
		and value.Y == value.Y
		and value.Z == value.Z
		and math.abs(value.X) < 1_000_000
		and math.abs(value.Y) < 1_000_000
		and math.abs(value.Z) < 1_000_000
end

local function isFiniteNumber(value)
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
end

local function getHorizontalVelocity(leafData)
	local velocity = leafData and leafData.Velocity
	if not isFiniteVector3(velocity) then
		return Vector3.zero
	end
	return Vector3.new(velocity.X, 0, velocity.Z)
end

local function getBoundsSupportRadius(boundingRotation, boundingSize, surfaceNormal)
	local normal = surfaceNormal.Magnitude > 0 and surfaceNormal.Unit or Vector3.new(0, 1, 0)
	local halfSize = boundingSize / 2
	return math.abs(boundingRotation.RightVector:Dot(normal)) * halfSize.X
		+ math.abs(boundingRotation.UpVector:Dot(normal)) * halfSize.Y
		+ math.abs(boundingRotation.LookVector:Dot(normal)) * halfSize.Z
end

local function getRangeWeight(distance, radius, innerRangeRatio, outerMultiplier)
	local innerRadius = radius * math.clamp(tonumber(innerRangeRatio) or 0, 0, 1)
	if distance <= innerRadius or radius <= innerRadius + 0.0001 then
		return 1
	end
	local outerAlpha = math.clamp((distance - innerRadius) / (radius - innerRadius), 0, 1)
	return 1 + (math.max(0, outerMultiplier) - 1) * outerAlpha
end

local function trimCandidates(candidates, maximumCount)
	table.sort(candidates, function(left, right)
		if left.DistanceSquared == right.DistanceSquared then
			return left.Leaf.Id < right.Leaf.Id
		end
		return left.DistanceSquared < right.DistanceSquared
	end)
	while #candidates > maximumCount do
		table.remove(candidates)
	end
	return candidates
end

local function candidateComesBefore(left, right)
	if left.DistanceSquared == right.DistanceSquared then
		return left.Leaf.Id < right.Leaf.Id
	end
	return left.DistanceSquared < right.DistanceSquared
end

local function insertBoundedCandidate(candidates, candidate, maximumCount)
	local insertIndex = #candidates + 1
	for index, existing in candidates do
		if candidateComesBefore(candidate, existing) then
			insertIndex = index
			break
		end
	end
	table.insert(candidates, insertIndex, candidate)
	if #candidates > maximumCount then
		table.remove(candidates)
	end
end

local function leafGridCoordinates(position)
	return math.floor(position.X / SERVER_LEAF_GRID_CELL_SIZE), math.floor(position.Z / SERVER_LEAF_GRID_CELL_SIZE)
end

local function leafGridKey(cellX, cellZ)
	return tostring(cellX) .. ":" .. tostring(cellZ)
end

local function handPickupGridCoordinates(position)
	return math.floor(position.X / HAND_PICKUP_GRID_CELL_SIZE), math.floor(position.Z / HAND_PICKUP_GRID_CELL_SIZE)
end

local function handPickupGridKey(cellX, cellZ)
	return tostring(cellX) .. ":" .. tostring(cellZ)
end

local function cellIntersectsHorizontalCircle(cellX, cellZ, center, radiusSquared, cellSize)
	local minimumX = cellX * cellSize
	local maximumX = minimumX + cellSize
	local minimumZ = cellZ * cellSize
	local maximumZ = minimumZ + cellSize
	local closestX = math.clamp(center.X, minimumX, maximumX)
	local closestZ = math.clamp(center.Z, minimumZ, maximumZ)
	local deltaX = center.X - closestX
	local deltaZ = center.Z - closestZ
	return deltaX * deltaX + deltaZ * deltaZ <= radiusSquared
end

local function getHorizontalBoundsExtents(boundingCFrame, boundingSize)
	local halfSize = boundingSize / 2
	local extentX = math.abs(boundingCFrame.RightVector.X) * halfSize.X
		+ math.abs(boundingCFrame.UpVector.X) * halfSize.Y
		+ math.abs(boundingCFrame.LookVector.X) * halfSize.Z
	local extentZ = math.abs(boundingCFrame.RightVector.Z) * halfSize.X
		+ math.abs(boundingCFrame.UpVector.Z) * halfSize.Y
		+ math.abs(boundingCFrame.LookVector.Z) * halfSize.Z
	return extentX, extentZ
end

local function normalizeRandomSeed(value)
	local normalized = math.floor(math.abs(tonumber(value) or 0)) % RANDOM_SEED_MODULUS
	return if normalized == 0 then 1 else normalized
end

local function getHorizontalDistanceSquared(left, right)
	local deltaX = left.X - right.X
	local deltaZ = left.Z - right.Z
	return deltaX * deltaX + deltaZ * deltaZ
end

function LeafService:Init(playerDataService, bagService, toolActionService, metricsService, yardService, remotes)
	self.PlayerDataService = playerDataService
	self.BagService = bagService
	self.ToolActionService = toolActionService
	self.MetricsService = metricsService
	self.YardService = yardService
	self.Remotes = remotes
	self.ToolRandom = Random.new()
	self.LeafCollectedHandlers = {}
	self.InstantRecycleCompletedHandlers = {}
	self.LeafStateChangedHandlers = {}
	self.AreaGameplayReadyHandlers = {}
	self.AreaCompletedHandlers = {}
	self.Yards = {}
	self.AreaDefinitions = {}
	self.AreaLeafPools = {}
	self.TemplateBounds = {}
	self.SnapshotSerials = {}
	self.LastSnapshotRequestTimes = {}
	self.RefillPreparationAreaStates = {}
	self.RefillPreparationCursor = 1

	local orderedLeafTypes = {}
	for _, leafType in LeafConfig.ActiveOrder do
		assert(type(leafType) == "string" and leafType ~= "", "LeafConfig.ActiveOrder contains an invalid leaf type")
		assert(not orderedLeafTypes[leafType], "LeafConfig.ActiveOrder contains duplicate leaf type: " .. leafType)
		local leafTypeConfig = LeafConfig.Types[leafType]
		assert(type(leafTypeConfig) == "table", "Missing LeafConfig type: " .. leafType)
		assert(
			isFiniteNumber(leafTypeConfig.BagValue) and leafTypeConfig.BagValue > 0,
			"Invalid BagValue for leaf type: " .. leafType
		)
		orderedLeafTypes[leafType] = true
	end

	local pooledLeafTypes = {}
	local leafPlacementExclusions = {}
	for _, areaId in RegionConfig.Order do
		local region = RegionConfig[areaId]
		assert(region, "Missing RegionConfig entry: " .. areaId)
		local configuredPool = LeafConfig.AreaPools[areaId]
		assert(type(configuredPool) == "table" and #configuredPool > 0, "Missing LeafConfig area pool: " .. areaId)
		local poolTypes = {}
		local normalizedPool = table.create(#configuredPool)
		local totalPoolWeight = 0
		for _, entry in configuredPool do
			local leafType = entry.LeafType
			local spawnWeight = tonumber(entry.SpawnWeight)
			assert(
				type(leafType) == "string" and orderedLeafTypes[leafType],
				string.format("Invalid leaf type in %s pool", areaId)
			)
			assert(not poolTypes[leafType], string.format("Duplicate leaf type %s in %s pool", leafType, areaId))
			assert(not pooledLeafTypes[leafType], string.format("Leaf type %s is assigned to multiple areas", leafType))
			assert(
				isFiniteNumber(spawnWeight) and spawnWeight > 0,
				string.format("Invalid spawn weight for %s in %s", leafType, areaId)
			)
			poolTypes[leafType] = true
			pooledLeafTypes[leafType] = true
			table.insert(normalizedPool, {
				LeafType = leafType,
				SpawnWeight = spawnWeight,
			})
			totalPoolWeight += spawnWeight
		end
		self.AreaLeafPools[areaId] = {
			Entries = normalizedPool,
			TotalWeight = totalPoolWeight,
		}
		local area = Workspace:FindFirstChild(areaId)
		assert(area and area:IsA("Folder"), "Workspace." .. areaId .. " must be a Folder")
		local ground = area:FindFirstChild("ground")
		assert(ground and ground:IsA("Model"), areaId .. ".ground must be a Model")
		table.insert(leafPlacementExclusions, ground)
		local generatedFolder = area:FindFirstChild("GeneratedLeaves")
		if generatedFolder then
			assert(generatedFolder:IsA("Folder"), areaId .. ".GeneratedLeaves must be a Folder")
			generatedFolder:ClearAllChildren()
			table.insert(leafPlacementExclusions, generatedFolder)
		end

		local surfaces = {}
		local totalSurfaceArea = 0
		for _, descendant in ground:GetDescendants() do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanQuery = true
				local surfaceArea = descendant.Size.X * descendant.Size.Z
				totalSurfaceArea += surfaceArea
				table.insert(surfaces, {
					Part = descendant,
					CumulativeArea = totalSurfaceArea,
				})
			end
		end
		assert(#surfaces > 0, areaId .. ".ground has no BasePart surfaces")

		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Include
		raycastParams.FilterDescendantsInstances = { ground }
		raycastParams.IgnoreWater = true
		self.AreaDefinitions[areaId] = {
			AreaId = areaId,
			Area = area,
			Ground = ground,
			Surfaces = surfaces,
			SurfaceArea = totalSurfaceArea,
			RaycastParams = raycastParams,
			FullTargetLeafCount = math.clamp(
				math.floor(totalSurfaceArea * region.LeafDensityPerSquareStud + 0.5),
				region.MinimumLeafCount,
				region.MaximumLeafCount
			),
		}
	end
	for leafType in orderedLeafTypes do
		assert(pooledLeafTypes[leafType], "Leaf type is not assigned to an area pool: " .. leafType)
	end
	local placementOverlapParams = OverlapParams.new()
	placementOverlapParams.FilterType = Enum.RaycastFilterType.Exclude
	placementOverlapParams.FilterDescendantsInstances = leafPlacementExclusions
	placementOverlapParams.MaxParts = 1
	placementOverlapParams.RespectCanCollide = false
	self.LeafPlacementOverlapParams = placementOverlapParams

	local modelFolder = ReplicatedStorage:FindFirstChild("Model")
	assert(modelFolder and modelFolder:IsA("Folder"), "ReplicatedStorage.Model must be a Folder")
	for _, leafType in LeafConfig.ActiveOrder do
		local template = modelFolder:FindFirstChild(leafType)
		assert(template and template:IsA("Model"), "Missing leaf model: " .. leafType)
		assert(template:FindFirstChildWhichIsA("BasePart", true), leafType .. " needs a BasePart")
		local boundingCFrame, boundingSize = template:GetBoundingBox()
		self.TemplateBounds[leafType] = {
			CFrame = boundingCFrame,
			Size = boundingSize,
		}
	end

	table.clear(activePickupPlayers)
	table.clear(activeMovingLeaves)
	table.clear(lastPickupAttemptTimes)
	table.clear(lastBagFullFeedbackTimes)
	table.clear(harvestAimEntries)
	table.clear(lastHarvestAimUpdateTimes)

	playerDataService:AddPlayerStateReadyHandler(function(player)
		task.spawn(function()
			self:_prepareOwnerYard(player)
		end)
	end)
	yardService:AddYardChangedHandler(function(player)
		self:SetPickupActive(player, false)
		self:ClearHarvestAim(player)
		self:SendSnapshot(player)
		self:_notifyLeafStateChanged(player)
	end)
	remotes.YardLeafSnapshot.OnServerEvent:Connect(function(player)
		local now = os.clock()
		if now - (self.LastSnapshotRequestTimes[player] or -math.huge) >= 1 then
			self.LastSnapshotRequestTimes[player] = now
			self:SendSnapshot(player)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		activePickupPlayers[player] = nil
		lastPickupAttemptTimes[player] = nil
		lastBagFullFeedbackTimes[player] = nil
		harvestAimEntries[player] = nil
		lastHarvestAimUpdateTimes[player] = nil
		self.SnapshotSerials[player] = nil
		self.LastSnapshotRequestTimes[player] = nil
		for leaf in activeMovingLeaves do
			if leaf.LastInfluencedPlayer == player then
				leaf.LastInfluencedPlayer = nil
				leaf.LastInfluencedToolId = nil
			end
		end
		local leavingYard = self.Yards[player]
		if leavingYard then
			for _, areaState in leavingYard.Areas do
				self:_invalidateRefillPreparation(areaState)
			end
		end
		task.delay(3, function()
			local yard = self.Yards[player]
			if yard then
				for leaf in yard.LeavesById do
					activeMovingLeaves[leaf] = nil
				end
				self.Yards[player] = nil
			end
		end)
	end)

	local function bindCharacterLifecycle(player, character)
		task.spawn(function()
			local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
			if not humanoid or not humanoid:IsA("Humanoid") then
				return
			end
			humanoid.Died:Connect(function()
				activePickupPlayers[player] = nil
				self:ClearHarvestAim(player)
				if self.ToolActionService then
					self.ToolActionService:StopPlayer(player)
				end
			end)
		end)
	end
	local function bindPlayerLifecycle(player)
		player.CharacterAdded:Connect(function(character)
			bindCharacterLifecycle(player, character)
		end)
		if player.Character then
			bindCharacterLifecycle(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(bindPlayerLifecycle)
	for _, player in Players:GetPlayers() do
		bindPlayerLifecycle(player)
	end

	self.MotionAccumulator = 0
	self.PickupConnection = RunService.Heartbeat:Connect(function(deltaTime)
		self:_pickupForActivePlayers()
		for _ = 1, REFILL_PREPARATION_ATTEMPTS_PER_HEARTBEAT do
			self:_prepareNextRefillPosition()
		end
		self.MotionAccumulator = math.min(
			self.MotionAccumulator + math.max(0, deltaTime),
			LEAF_MOTION_MAX_ACCUMULATOR
		)
		while self.MotionAccumulator >= LEAF_MOTION_STEP do
			self.MotionAccumulator -= LEAF_MOTION_STEP
			self:_updateMovingLeaves(LEAF_MOTION_STEP)
		end
	end)
end

function LeafService:_chooseLeafType(random, areaId)
	local pool = self.AreaLeafPools[areaId]
	local roll = random:NextNumber(0, pool.TotalWeight)
	local cursor = 0
	for _, entry in pool.Entries do
		cursor += entry.SpawnWeight
		if roll <= cursor then
			return entry.LeafType
		end
	end
	return pool.Entries[#pool.Entries].LeafType
end

function LeafService:_getLeafTypeForIndex(areaState, leafIndex)
	local seed = normalizeRandomSeed(
		areaState.SequenceSeed
			+ leafIndex * 48_271
			+ 17_389
	)
	return self:_chooseLeafType(Random.new(seed), areaState.AreaId)
end

function LeafService:_getPlacementRandom(areaState, leafIndex, placementSerial)
	return Random.new(normalizeRandomSeed(
		areaState.SequenceSeed
			+ leafIndex * 69_621
			+ (placementSerial or 0) * 130_363
			+ 97_409
	))
end

function LeafService:_makeYard(owner)
	local yard = {
		Owner = owner,
		OwnerUserId = owner.UserId,
		Areas = {},
		LeavesById = {},
		Revision = 0,
		Preparing = true,
		Ready = false,
		ProgressSnapshotQueued = false,
		ProgressionReconcileRunning = false,
		ProgressionReconcilePending = false,
		PendingMoveLeaves = {},
		NextMoveReplicationAt = 0,
		ForceMoveReplication = false,
	}
	self.Yards[owner] = yard
	return yard
end

function LeafService:_discardAreaState(yard, areaId)
	local areaState = yard.Areas[areaId]
	if not areaState then
		return
	end
	areaState.Cancelled = true
	areaState.RefillToken = (areaState.RefillToken or 0) + 1
	self:_invalidateRefillPreparation(areaState)
	for _, leaf in areaState.Leaves do
		yard.LeavesById[leaf.Id] = nil
		self:_removeLeafFromGrid(leaf)
		self:_removeLeafFromHandPickupGrid(leaf)
		activeMovingLeaves[leaf] = nil
		yard.PendingMoveLeaves[leaf.Id] = nil
	end
	yard.Areas[areaId] = nil
end

function LeafService:_reconcileAreaGeneration(yard)
	if self.Yards[yard.Owner] ~= yard then
		return false
	end
	local state = self.PlayerDataService:GetState(yard.Owner)
	if not state then
		return false
	end
	local savedAreas = state.YardProgress and state.YardProgress.Areas or {}
	local highestUnlockedAreaNumber = 0
	local currentAreaNumber = nil
	for areaNumber, areaId in RegionConfig.Order do
		if state.UnlockedAreas[areaId] == true then
			highestUnlockedAreaNumber = math.max(highestUnlockedAreaNumber, areaNumber)
			local savedArea = savedAreas[areaId]
			local clearedRatio = math.clamp(
				tonumber(type(savedArea) == "table" and savedArea.ClearedRatio) or 0,
				0,
				1
			)
			if currentAreaNumber == nil and clearedRatio < 1 then
				currentAreaNumber = areaNumber
			end
		end
	end

	local formalThroughAreaNumber = currentAreaNumber or highestUnlockedAreaNumber
	local previewAreaNumber = formalThroughAreaNumber > 0
		and formalThroughAreaNumber < RegionConfig.AreaCount
		and formalThroughAreaNumber + 1
		or nil
	local desiredModes = {}
	for areaNumber = 1, formalThroughAreaNumber do
		local areaId = string.format("Area_%02d", areaNumber)
		if state.UnlockedAreas[areaId] == true then
			desiredModes[areaId] = true
		end
	end
	if previewAreaNumber then
		desiredModes[string.format("Area_%02d", previewAreaNumber)] = false
	end

	for _, areaId in RegionConfig.Order do
		if yard.Areas[areaId] and desiredModes[areaId] == nil then
			self:_discardAreaState(yard, areaId)
		end
	end
	for _, areaId in RegionConfig.Order do
		local gameplayReady = desiredModes[areaId]
		if gameplayReady ~= nil then
			self:_generateArea(yard, areaId, gameplayReady)
			if self.Yards[yard.Owner] ~= yard then
				return false
			end
		end
	end
	return true
end

function LeafService:_queueProgressionReconcile(yard)
	if self.Yards[yard.Owner] ~= yard then
		return false
	end
	if yard.ProgressionReconcileRunning then
		yard.ProgressionReconcilePending = true
		return true
	end
	yard.ProgressionReconcileRunning = true
	task.spawn(function()
		repeat
			yard.ProgressionReconcilePending = false
			self:_reconcileAreaGeneration(yard)
		until self.Yards[yard.Owner] ~= yard or yard.ProgressionReconcilePending ~= true
		yard.ProgressionReconcileRunning = false
		if self.Yards[yard.Owner] == yard then
			self:SendSnapshotToMembers(yard)
			self:_queueProgressSnapshot(yard, true)
		end
	end)
	return true
end

function LeafService:_insertLeafInGrid(leaf)
	local areaState = leaf.AreaState
	if not areaState or not areaState.LeafGrid then
		return
	end
	local cellX, cellZ = leafGridCoordinates(leaf.BoundingCFrame.Position)
	local key = leafGridKey(cellX, cellZ)
	local cell = areaState.LeafGrid[key]
	if not cell then
		cell = {}
		areaState.LeafGrid[key] = cell
	end
	cell[leaf] = true
	leaf.ServerGridKey = key
end

function LeafService:_removeLeafFromGrid(leaf)
	local areaState = leaf.AreaState
	local key = leaf.ServerGridKey
	local cell = areaState and areaState.LeafGrid and key and areaState.LeafGrid[key] or nil
	if cell then
		cell[leaf] = nil
		if next(cell) == nil then
			areaState.LeafGrid[key] = nil
		end
	end
	leaf.ServerGridKey = nil
end

function LeafService:_getHandPickupGridKeys(leaf)
	local boundingCFrame = leaf.BoundingCFrame
	local boundingSize = leaf.BoundingSize
	local extentX, extentZ = getHorizontalBoundsExtents(boundingCFrame, boundingSize)
	local position = boundingCFrame.Position
	local minimumCellX = math.floor((position.X - extentX) / HAND_PICKUP_GRID_CELL_SIZE)
	local maximumCellX = math.floor((position.X + extentX) / HAND_PICKUP_GRID_CELL_SIZE)
	local minimumCellZ = math.floor((position.Z - extentZ) / HAND_PICKUP_GRID_CELL_SIZE)
	local maximumCellZ = math.floor((position.Z + extentZ) / HAND_PICKUP_GRID_CELL_SIZE)
	local keys = {}
	for cellX = minimumCellX, maximumCellX do
		for cellZ = minimumCellZ, maximumCellZ do
			table.insert(keys, handPickupGridKey(cellX, cellZ))
		end
	end
	return keys
end

function LeafService:_removeLeafFromHandPickupGrid(leaf)
	local areaState = leaf.AreaState
	local pickupGrid = areaState and areaState.HandPickupGrid
	for _, key in leaf.ServerHandPickupGridKeys or {} do
		local cell = pickupGrid and pickupGrid[key]
		if cell then
			cell[leaf] = nil
			if next(cell) == nil then
				pickupGrid[key] = nil
			end
		end
	end
	leaf.ServerHandPickupGridKeys = nil
end

function LeafService:_insertLeafInHandPickupGrid(leaf, keys)
	local areaState = leaf.AreaState
	local pickupGrid = areaState and areaState.HandPickupGrid
	if not pickupGrid then
		return
	end
	local occupiedKeys = keys or self:_getHandPickupGridKeys(leaf)
	for _, key in occupiedKeys do
		local cell = pickupGrid[key]
		if not cell then
			cell = {}
			pickupGrid[key] = cell
		end
		cell[leaf] = true
	end
	leaf.ServerHandPickupGridKeys = occupiedKeys
end

function LeafService:_updateLeafHandPickupGrid(leaf)
	local nextKeys = self:_getHandPickupGridKeys(leaf)
	local currentKeys = leaf.ServerHandPickupGridKeys
	if currentKeys and #currentKeys == #nextKeys then
		local matches = true
		for index, key in nextKeys do
			if currentKeys[index] ~= key then
				matches = false
				break
			end
		end
		if matches then
			return
		end
	end
	self:_removeLeafFromHandPickupGrid(leaf)
	self:_insertLeafInHandPickupGrid(leaf, nextKeys)
end

function LeafService:_updateLeafGrid(leaf)
	local cellX, cellZ = leafGridCoordinates(leaf.BoundingCFrame.Position)
	local nextKey = leafGridKey(cellX, cellZ)
	if leaf.ServerGridKey ~= nextKey then
		self:_removeLeafFromGrid(leaf)
		self:_insertLeafInGrid(leaf)
	end
	self:_updateLeafHandPickupGrid(leaf)
end

function LeafService:_queryHandPickupLeaves(yard, center, radius)
	local leaves = {}
	if not yard or not yard.Areas or not isFiniteVector3(center) or not isFiniteNumber(radius) or radius < 0 then
		return leaves
	end
	local seen = {}
	local radiusSquared = radius * radius
	local minimumCellX, minimumCellZ = handPickupGridCoordinates(center - Vector3.new(radius, 0, radius))
	local maximumCellX, maximumCellZ = handPickupGridCoordinates(center + Vector3.new(radius, 0, radius))
	for _, areaState in yard.Areas do
		if areaState.Generated and areaState.HandPickupGrid then
			for cellX = minimumCellX, maximumCellX do
				for cellZ = minimumCellZ, maximumCellZ do
					if cellIntersectsHorizontalCircle(
						cellX,
						cellZ,
						center,
						radiusSquared,
						HAND_PICKUP_GRID_CELL_SIZE
					) then
						local cell = areaState.HandPickupGrid[handPickupGridKey(cellX, cellZ)]
						if cell then
							for leaf in cell do
								if not seen[leaf] and leaf.Yard.LeavesById[leaf.Id] == leaf then
									seen[leaf] = true
									table.insert(leaves, leaf)
									if #leaves >= HAND_MAX_SCANNED_LEAVES_PER_QUERY then
										return leaves
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return leaves
end

function LeafService:_queryAreaLeaves(areaState, center, radius)
	local leaves = {}
	if
		not areaState
		or not areaState.LeafGrid
		or not isFiniteVector3(center)
		or not isFiniteNumber(radius)
		or radius < 0
	then
		return leaves
	end
	local minX, minZ = leafGridCoordinates(center - Vector3.new(radius, 0, radius))
	local maxX, maxZ = leafGridCoordinates(center + Vector3.new(radius, 0, radius))
	local queryCellCount = (maxX - minX + 1) * (maxZ - minZ + 1)
	if queryCellCount > MAX_DIRECT_GRID_QUERY_CELLS then
		for _, cell in areaState.LeafGrid do
			for leaf in cell do
				if leaf.Yard.LeavesById[leaf.Id] == leaf then
					table.insert(leaves, leaf)
				end
			end
		end
		return leaves
	end
	for cellX = minX, maxX do
		for cellZ = minZ, maxZ do
			local cell = areaState.LeafGrid[leafGridKey(cellX, cellZ)]
			if cell then
				for leaf in cell do
					if leaf.Yard.LeavesById[leaf.Id] == leaf then
						table.insert(leaves, leaf)
					end
				end
			end
		end
	end
	return leaves
end

function LeafService:_queryYardLeaves(yard, center, radius)
	local leaves = {}
	if not yard or not yard.Areas then
		return leaves
	end
	for _, areaState in yard.Areas do
		if areaState.Generated then
			for _, leaf in self:_queryAreaLeaves(areaState, center, radius) do
				table.insert(leaves, leaf)
			end
		end
	end
	return leaves
end

function LeafService:_selectSurface(random, definition)
	local roll = random:NextNumber(0, definition.SurfaceArea)
	for _, surfaceInfo in definition.Surfaces do
		if roll <= surfaceInfo.CumulativeArea then
			return surfaceInfo.Part
		end
	end
	return definition.Surfaces[#definition.Surfaces].Part
end

function LeafService:_isLeafPlacementBlocked(boundingCFrame, boundingSize)
	local placementConfig = LeafConfig.Placement
	local inset = math.max(0, tonumber(placementConfig.BoundsInset) or 0)
	local minimumSize = math.max(0.001, tonumber(placementConfig.MinimumQuerySize) or 0.01)
	local querySize = Vector3.new(
		math.max(minimumSize, boundingSize.X - inset),
		math.max(minimumSize, boundingSize.Y - inset),
		math.max(minimumSize, boundingSize.Z - inset)
	)
	return #Workspace:GetPartBoundsInBox(boundingCFrame, querySize, self.LeafPlacementOverlapParams) > 0
end

function LeafService:_makeLeafBoundingCFrameOnSurface(random, surface, region, boundingSize, surfacePosition)
	local placementConfig = LeafConfig.Placement
	local maximumPitch = math.rad(math.max(0, tonumber(placementConfig.MaximumPitchDegrees) or 0))
	local maximumRoll = math.rad(math.max(0, tonumber(placementConfig.MaximumRollDegrees) or 0))
	local heightJitter = random:NextNumber(region.LeafHeightJitterMin, region.LeafHeightJitterMax)
	local yaw = random:NextNumber(0, math.pi * 2)
	local pitch = random:NextNumber(-maximumPitch, maximumPitch)
	local roll = random:NextNumber(-maximumRoll, maximumRoll)
	local boundingRotation = surface.CFrame.Rotation
		* CFrame.Angles(0, yaw, 0)
		* CFrame.Angles(pitch, 0, roll)
	local supportRadius = getBoundsSupportRadius(boundingRotation, boundingSize, surface.CFrame.UpVector)
	local boundingPosition = surfacePosition
		+ surface.CFrame.UpVector * (supportRadius + heightJitter)
	return CFrame.new(boundingPosition) * boundingRotation
end

function LeafService:_makeLeafPlacementCandidate(random, definition, region, boundingSize)
	local surface = self:_selectSurface(random, definition)
	local paddingX = math.min(region.EdgePadding, surface.Size.X * 0.2)
	local paddingZ = math.min(region.EdgePadding, surface.Size.Z * 0.2)
	local localX = random:NextNumber(-surface.Size.X / 2 + paddingX, surface.Size.X / 2 - paddingX)
	local localZ = random:NextNumber(-surface.Size.Z / 2 + paddingZ, surface.Size.Z / 2 - paddingZ)
	local surfacePosition = surface.CFrame:PointToWorldSpace(
		Vector3.new(localX, surface.Size.Y / 2, localZ)
	)
	return self:_makeLeafBoundingCFrameOnSurface(random, surface, region, boundingSize, surfacePosition), surface
end

function LeafService:_getSurfacePositionAtWorldXZ(surface, region, worldX, worldZ)
	if not surface or not surface:IsA("BasePart") then
		return nil
	end
	local surfaceNormal = surface.CFrame.UpVector
	if math.abs(surfaceNormal.Y) < 0.001 then
		return nil
	end
	local surfaceOrigin = surface.CFrame:PointToWorldSpace(Vector3.new(0, surface.Size.Y / 2, 0))
	local worldY = surfaceOrigin.Y
		- (
			surfaceNormal.X * (worldX - surfaceOrigin.X)
				+ surfaceNormal.Z * (worldZ - surfaceOrigin.Z)
		) / surfaceNormal.Y
	local projectedPosition = Vector3.new(worldX, worldY, worldZ)
	local localPosition = surface.CFrame:PointToObjectSpace(projectedPosition)
	local paddingX = math.min(region.EdgePadding, surface.Size.X * 0.2)
	local paddingZ = math.min(region.EdgePadding, surface.Size.Z * 0.2)
	if
		localPosition.X < -surface.Size.X / 2 + paddingX
		or localPosition.X > surface.Size.X / 2 - paddingX
		or localPosition.Z < -surface.Size.Z / 2 + paddingZ
		or localPosition.Z > surface.Size.Z / 2 - paddingZ
	then
		return nil
	end
	return surface.CFrame:PointToWorldSpace(
		Vector3.new(localPosition.X, surface.Size.Y / 2, localPosition.Z)
	)
end

function LeafService:_makeAnchoredRefillPlacement(random, areaState, boundingSize)
	local areaLeaves = areaState.Leaves
	if #areaLeaves <= 0 then
		return self:_makeLeafPlacementCandidate(random, areaState.Definition, areaState.Region, boundingSize)
	end

	local anchor = areaLeaves[random:NextInteger(1, #areaLeaves)]
	local surface = anchor and anchor.PlacementSurface
	if not surface or not surface:IsA("BasePart") then
		return nil, nil
	end
	local cellX, cellZ = leafGridCoordinates(anchor.BoundingCFrame.Position)
	local cellInset = 0.001
	local minimumX = cellX * SERVER_LEAF_GRID_CELL_SIZE + cellInset
	local maximumX = (cellX + 1) * SERVER_LEAF_GRID_CELL_SIZE - cellInset
	local minimumZ = cellZ * SERVER_LEAF_GRID_CELL_SIZE + cellInset
	local maximumZ = (cellZ + 1) * SERVER_LEAF_GRID_CELL_SIZE - cellInset
	for _ = 1, REFILL_ANCHOR_POSITION_ATTEMPTS do
		local worldX = random:NextNumber(minimumX, maximumX)
		local worldZ = random:NextNumber(minimumZ, maximumZ)
		local surfacePosition = self:_getSurfacePositionAtWorldXZ(
			surface,
			areaState.Region,
			worldX,
			worldZ
		)
		if surfacePosition then
			return self:_makeLeafBoundingCFrameOnSurface(
				random,
				surface,
				areaState.Region,
				boundingSize,
				surfacePosition
			), surface
		end
	end
	return nil, nil
end

function LeafService:_chooseLeafPlacement(random, definition, region, boundingSize)
	local placementConfig = LeafConfig.Placement
	local maximumAttempts = math.max(1, math.floor(tonumber(placementConfig.MaxAttempts) or 1))
	local lastBoundingCFrame
	local lastSurface
	for _ = 1, maximumAttempts do
		local boundingCFrame, surface = self:_makeLeafPlacementCandidate(random, definition, region, boundingSize)
		lastBoundingCFrame = boundingCFrame
		lastSurface = surface
		if not self:_isLeafPlacementBlocked(boundingCFrame, boundingSize) then
			return boundingCFrame, false, surface
		end
	end
	return lastBoundingCFrame, true, lastSurface
end

function LeafService:_createRefillPreparationCollections(areaId)
	local pool = self.AreaLeafPools[areaId]
	local positionsByLeafType = {}
	local targetsByLeafType = {}
	local remainders = table.create(#pool.Entries)
	local assignedCount = 0
	for order, entry in pool.Entries do
		local exactTarget = REFILL_PREPARED_POSITION_TARGET * entry.SpawnWeight / pool.TotalWeight
		local baseTarget = math.floor(exactTarget)
		positionsByLeafType[entry.LeafType] = {}
		targetsByLeafType[entry.LeafType] = baseTarget
		assignedCount += baseTarget
		remainders[#remainders + 1] = {
			LeafType = entry.LeafType,
			Remainder = exactTarget - baseTarget,
			Order = order,
		}
	end
	table.sort(remainders, function(left, right)
		if left.Remainder == right.Remainder then
			return left.Order < right.Order
		end
		return left.Remainder > right.Remainder
	end)
	for index = 1, REFILL_PREPARED_POSITION_TARGET - assignedCount do
		local remainder = remainders[((index - 1) % #remainders) + 1]
		targetsByLeafType[remainder.LeafType] += 1
	end
	return positionsByLeafType, targetsByLeafType
end

function LeafService:_invalidateRefillPreparation(areaState)
	if not areaState then
		return
	end
	areaState.RefillPreparationToken = (areaState.RefillPreparationToken or 0) + 1
	areaState.RefillPreparationRegistered = false
	areaState.RefillPreparedPositionCount = 0
	local positionsByLeafType = areaState.RefillPreparedPositionsByLeafType or {}
	for _, queue in positionsByLeafType do
		table.clear(queue)
	end
end

function LeafService:_canPrepareRefillPositions(areaState)
	return self:_isCurrentAreaState(areaState)
		and areaState.RefillPreparationRegistered == true
		and areaState.Generated
		and not areaState.Completed
		and areaState.PendingLeafCount > 0
end

function LeafService:_registerRefillPreparation(areaState)
	if not self:_isCurrentAreaState(areaState)
		or not areaState.Generated
		or areaState.Completed
		or areaState.PendingLeafCount <= 0
		or areaState.RefillPreparationRegistered
	then
		return
	end
	areaState.RefillPreparationRegistered = true
	table.insert(self.RefillPreparationAreaStates, areaState)
end

function LeafService:_chooseRefillPreparationLeafType(areaState)
	if areaState.RefillPreparedPositionCount >= REFILL_PREPARED_POSITION_TARGET then
		return nil
	end
	local positionsByLeafType = areaState.RefillPreparedPositionsByLeafType
	local targetsByLeafType = areaState.RefillPreparedTargetsByLeafType
	local nextLeafType = self:_getLeafTypeForIndex(areaState, areaState.NextLeafIndex)
	local nextQueue = positionsByLeafType[nextLeafType]
	if nextQueue and #nextQueue < (targetsByLeafType[nextLeafType] or 0) then
		return nextLeafType
	end

	local selectedLeafType
	local selectedDeficit = 0
	for _, entry in self.AreaLeafPools[areaState.AreaId].Entries do
		local leafType = entry.LeafType
		local deficit = (targetsByLeafType[leafType] or 0) - #(positionsByLeafType[leafType] or {})
		if deficit > selectedDeficit then
			selectedLeafType = leafType
			selectedDeficit = deficit
		end
	end
	return selectedLeafType
end

function LeafService:_prepareRefillPositionForArea(areaState)
	if not self:_canPrepareRefillPositions(areaState) then
		return false
	end
	local leafType = self:_chooseRefillPreparationLeafType(areaState)
	if not leafType then
		return false
	end

	areaState.RefillPreparationSerial += 1
	local preparationToken = areaState.RefillPreparationToken
	local random = self:_getPlacementRandom(
		areaState,
		areaState.NextLeafIndex,
		areaState.RefillPreparationSerial
	)
	local boundingSize = self.TemplateBounds[leafType].Size
	local boundingCFrame, placementSurface = self:_makeAnchoredRefillPlacement(random, areaState, boundingSize)
	if not boundingCFrame then
		return true
	end
	local cellX, cellZ = leafGridCoordinates(boundingCFrame.Position)
	local gridKey = leafGridKey(cellX, cellZ)
	local allowEmptyArea = #areaState.Leaves == 0
	if not allowEmptyArea then
		local cell = areaState.LeafGrid[gridKey]
		if not cell or next(cell) == nil then
			return true
		end
	end
	if self:_isLeafPlacementBlocked(boundingCFrame, boundingSize) then
		return true
	end
	if not self:_canPrepareRefillPositions(areaState)
		or areaState.RefillPreparationToken ~= preparationToken
	then
		return true
	end

	local queue = areaState.RefillPreparedPositionsByLeafType[leafType]
	queue[#queue + 1] = {
		LeafType = leafType,
		BoundingCFrame = boundingCFrame,
		PlacementSurface = placementSurface,
		GridKey = gridKey,
		PreparationToken = preparationToken,
		AllowEmptyArea = allowEmptyArea,
	}
	areaState.RefillPreparedPositionCount += 1
	return true
end

function LeafService:_prepareNextRefillPosition()
	local areaStates = self.RefillPreparationAreaStates
	local checkedCount = 0
	local maximumChecks = #areaStates
	while #areaStates > 0 and checkedCount < maximumChecks do
		if self.RefillPreparationCursor > #areaStates then
			self.RefillPreparationCursor = 1
		end
		local cursor = self.RefillPreparationCursor
		local areaState = areaStates[cursor]
		if not self:_canPrepareRefillPositions(areaState) then
			self:_invalidateRefillPreparation(areaState)
			table.remove(areaStates, cursor)
			maximumChecks -= 1
		else
			self.RefillPreparationCursor = cursor % #areaStates + 1
			checkedCount += 1
			if self:_prepareRefillPositionForArea(areaState) then
				return
			end
		end
	end
end

function LeafService:_takePreparedRefillPlacement(areaState, leafType)
	local queue = areaState.RefillPreparedPositionsByLeafType[leafType]
	local candidate = queue and table.remove(queue) or nil
	if not candidate then
		return nil, nil
	end
	areaState.RefillPreparedPositionCount = math.max(0, areaState.RefillPreparedPositionCount - 1)
	if not self:_isCurrentAreaState(areaState)
		or candidate.LeafType ~= leafType
		or candidate.PreparationToken ~= areaState.RefillPreparationToken
	then
		return nil, nil
	end

	if #areaState.Leaves > 0 then
		local cell = areaState.LeafGrid[candidate.GridKey]
		if not cell or next(cell) == nil then
			return nil, nil
		end
	elseif not candidate.AllowEmptyArea then
		return nil, nil
	end
	return candidate.BoundingCFrame, candidate.PlacementSurface
end

function LeafService:_insertActiveLeaf(areaState, leaf)
	local yard = areaState.Yard
	local areaLeaves = areaState.Leaves
	areaLeaves[#areaLeaves + 1] = leaf
	leaf.AreaListIndex = #areaLeaves
	yard.LeavesById[leaf.Id] = leaf
	self:_insertLeafInGrid(leaf)
	self:_insertLeafInHandPickupGrid(leaf)
end

function LeafService:_activateNextPendingLeaf(areaState, isRefill)
	if areaState.PendingLeafCount <= 0 or areaState.NextLeafIndex > areaState.GeneratedLeafCount then
		return nil, false
	end
	local leafIndex = areaState.NextLeafIndex
	local leafType = self:_getLeafTypeForIndex(areaState, leafIndex)
	local leafTypeConfig = LeafConfig.Types[leafType]
	local boundingSize = self.TemplateBounds[leafType].Size
	local boundingCFrame
	local placementSurface
	local usedBlockedFallback = false
	if isRefill then
		boundingCFrame, placementSurface = self:_takePreparedRefillPlacement(areaState, leafType)
		if not boundingCFrame then
			return nil, false
		end
	else
		local random = self:_getPlacementRandom(areaState, leafIndex, 0)
		boundingCFrame, usedBlockedFallback, placementSurface = self:_chooseLeafPlacement(
			random,
			areaState.Definition,
			areaState.Region,
			boundingSize
		)
	end
	if not boundingCFrame then
		return nil, usedBlockedFallback
	end

	local leaf = {
		Id = string.format("%s_%05d", areaState.AreaId, leafIndex),
		Yard = areaState.Yard,
		AreaId = areaState.AreaId,
		AreaState = areaState,
		LeafType = leafType,
		BagValue = leafTypeConfig.BagValue,
		BoundingCFrame = boundingCFrame,
		PlacementSurface = placementSurface,
		BoundingSize = boundingSize,
		Velocity = Vector3.zero,
		AngularVelocity = 0,
		PoweredUntil = 0,
		LastInfluencedAt = 0,
		LastInfluencedPlayer = nil,
		LastInfluencedToolId = nil,
		StopPoint = nil,
		StopRadius = 0,
		MotionDirty = false,
		Revision = 0,
	}
	areaState.NextLeafIndex += 1
	areaState.PendingLeafCount -= 1
	self:_insertActiveLeaf(areaState, leaf)
	return leaf, usedBlockedFallback
end

function LeafService:_isCurrentAreaState(areaState)
	local yard = areaState and areaState.Yard
	return yard ~= nil
		and self.Yards[yard.Owner] == yard
		and yard.Areas[areaState.AreaId] == areaState
		and areaState.Cancelled ~= true
end

function LeafService:_getDesiredActiveLeafCount(areaState)
	if not areaState or areaState.Completed then
		return 0
	end
	local remainingLeafCount = math.max(
		0,
		math.floor((tonumber(areaState.TotalLeafCount) or 0) - (tonumber(areaState.CollectedLeafCount) or 0))
	)
	return math.min(MAXIMUM_ACTIVE_LEAVES, remainingLeafCount)
end

function LeafService:_getAreaRefillDeficit(areaState)
	if not areaState or areaState.PendingLeafCount <= 0 then
		return 0
	end
	local activeDeficit = math.max(0, self:_getDesiredActiveLeafCount(areaState) - #areaState.Leaves)
	return math.min(areaState.PendingLeafCount, activeDeficit)
end

function LeafService:_canContinueAreaRefill(areaState, refillToken)
	return self:_isCurrentAreaState(areaState)
		and areaState.RefillToken == refillToken
		and areaState.Generated
		and not areaState.Completed
		and areaState.PendingLeafCount > 0
		and self:_getAreaRefillDeficit(areaState) > 0
end

function LeafService:_queueAreaRefill(areaState)
	if not self:_isCurrentAreaState(areaState)
		or not areaState.Generated
		or areaState.Completed
		or areaState.PendingLeafCount <= 0
		or self:_getAreaRefillDeficit(areaState) <= 0
		or areaState.RefillQueued
	then
		return
	end

	areaState.RefillQueued = true
	areaState.RefillToken += 1
	local refillToken = areaState.RefillToken
	-- Defer only to the next scheduler resumption so all removals from the current
	-- collection batch share one refill packet; there is no initial refill delay.
	task.defer(function()
		local nextBatchDelay = 0
		while self:_canContinueAreaRefill(areaState, refillToken) do
			if nextBatchDelay > 0 then
				task.wait(nextBatchDelay)
			end
			if not self:_canContinueAreaRefill(areaState, refillToken) then
				break
			end

			local refillDeficit = self:_getAreaRefillDeficit(areaState)
			local maximumThisBatch = math.min(
				REFILL_WORK_BATCH_SIZE,
				refillDeficit,
				areaState.PendingLeafCount
			)
			local descriptors = table.create(maximumThisBatch)
			for _ = 1, maximumThisBatch do
				local leaf = self:_activateNextPendingLeaf(areaState, true)
				if not leaf then
					break
				end
				descriptors[#descriptors + 1] = self:_serializeLeaf(leaf)
			end

			if #descriptors > 0 then
				if areaState.Yard.Ready then
					self:_sendDelta(areaState.Yard, {
						Kind = "Upsert",
						Leaves = descriptors,
					})
				end
				nextBatchDelay = REFILL_BATCH_INTERVAL
			else
				nextBatchDelay = REFILL_RETRY_INTERVAL
			end
		end
		if self:_isCurrentAreaState(areaState) and areaState.RefillToken == refillToken then
			areaState.RefillQueued = false
			if
				areaState.Generated
				and not areaState.Completed
				and areaState.PendingLeafCount > 0
				and self:_getAreaRefillDeficit(areaState) > 0
			then
				self:_queueAreaRefill(areaState)
			end
		end
	end)
end

function LeafService:_generateArea(yard, areaId, gameplayReady)
	local definition = self.AreaDefinitions[areaId]
	local region = RegionConfig[areaId]
	local targetCount
	if gameplayReady then
		local ownerState = self.PlayerDataService:GetState(yard.Owner)
		local multiplier = RebirthConfig.GetLeafCountMultiplier(ownerState and ownerState.RebirthCount)
		targetCount = math.max(1, math.floor(definition.FullTargetLeafCount * multiplier + 0.5))
	else
		targetCount = math.min(RegionConfig.LockedPreviewLeafCount, definition.FullTargetLeafCount)
	end

	local previous = yard.Areas[areaId]
	if previous and previous.Generated == gameplayReady and previous.GeneratedLeafCount == targetCount then
		return previous
	end
	if previous then
		previous.Cancelled = true
		previous.RefillToken = (previous.RefillToken or 0) + 1
		self:_invalidateRefillPreparation(previous)
		for _, leaf in previous.Leaves do
			yard.LeavesById[leaf.Id] = nil
			self:_removeLeafFromGrid(leaf)
			self:_removeLeafFromHandPickupGrid(leaf)
			activeMovingLeaves[leaf] = nil
			yard.PendingMoveLeaves[leaf.Id] = nil
		end
	end

	local refillPreparedPositionsByLeafType, refillPreparedTargetsByLeafType =
		self:_createRefillPreparationCollections(areaId)
	local areaState = {
		AreaId = areaId,
		Definition = definition,
		Region = region,
		Yard = yard,
		Generated = gameplayReady,
		PreviewOnly = not gameplayReady,
		GeneratedLeafCount = targetCount,
		TotalLeafCount = targetCount,
		CollectedLeafCount = 0,
		TotalValue = 0,
		CollectedValue = 0,
		Completed = false,
		Leaves = {},
		LeafGrid = {},
		HandPickupGrid = {},
		SequenceSeed = normalizeRandomSeed(region.Seed + (yard.OwnerUserId % 100_000) * 7_919),
		NextLeafIndex = 1,
		PendingLeafCount = targetCount,
		RefillQueued = false,
		RefillToken = 0,
		RefillPreparedPositionsByLeafType = refillPreparedPositionsByLeafType,
		RefillPreparedPositionCount = 0,
		RefillPreparedTargetsByLeafType = refillPreparedTargetsByLeafType,
		RefillPreparationSerial = 0,
		RefillPreparationToken = 1,
		RefillPreparationRegistered = false,
		Cancelled = false,
	}
	yard.Areas[areaId] = areaState

	for index = 1, targetCount do
		local leafType = self:_getLeafTypeForIndex(areaState, index)
		areaState.TotalValue += LeafConfig.Types[leafType].BagValue
		if index % POPULATION_CALCULATION_BATCH_SIZE == 0 then
			task.wait()
		end
	end

	local restoredRatio = 0
	if gameplayReady then
		local ownerState = self.PlayerDataService:GetState(yard.Owner)
		local savedArea = ownerState
			and ownerState.YardProgress
			and ownerState.YardProgress.Areas
			and ownerState.YardProgress.Areas[areaId]
		restoredRatio = math.clamp(tonumber(savedArea and savedArea.ClearedRatio) or 0, 0, 1)
	end
	local restoredValue = math.floor(areaState.TotalValue * restoredRatio + 0.5)
	local skippedValue = 0
	if gameplayReady and restoredValue > 0 then
		for index = 1, targetCount do
			local leafType = self:_getLeafTypeForIndex(areaState, index)
			local bagValue = LeafConfig.Types[leafType].BagValue
			if skippedValue + bagValue > restoredValue then
				break
			end
			skippedValue += bagValue
			areaState.CollectedLeafCount += 1
			if index % POPULATION_CALCULATION_BATCH_SIZE == 0 then
				task.wait()
			end
		end
	end
	areaState.NextLeafIndex = areaState.CollectedLeafCount + 1
	areaState.PendingLeafCount = targetCount - areaState.CollectedLeafCount
	areaState.CollectedValue = math.min(restoredValue, areaState.TotalValue)
	areaState.Completed = gameplayReady
		and (restoredRatio >= 1 or areaState.CollectedValue >= areaState.TotalValue)
	if areaState.Completed then
		areaState.CollectedLeafCount = areaState.TotalLeafCount
		areaState.CollectedValue = areaState.TotalValue
		areaState.NextLeafIndex = targetCount + 1
		areaState.PendingLeafCount = 0
	else
		local initialActiveCount = math.min(
			areaState.PendingLeafCount,
			if gameplayReady then MAXIMUM_ACTIVE_LEAVES else targetCount
		)
		local blockedFallbackCount = 0
		for index = 1, initialActiveCount do
			local leaf, usedBlockedFallback = self:_activateNextPendingLeaf(areaState, false)
			if not leaf then
				break
			end
			if usedBlockedFallback then
				blockedFallbackCount += 1
			end
			if index % GENERATION_BATCH_SIZE == 0 then
				task.wait()
			end
		end
		local activeLeafCount = #areaState.Leaves
		if
			blockedFallbackCount > 0
			and blockedFallbackCount / math.max(1, activeLeafCount) >= BLOCKED_PLACEMENT_WARNING_RATIO
		then
			warn(string.format(
				"[LeafService] %s used the final blocked placement for %d/%d active leaves after %d attempts",
				areaId,
				blockedFallbackCount,
				activeLeafCount,
				LeafConfig.Placement.MaxAttempts
			))
		end
	end
	if gameplayReady then
		self:_registerRefillPreparation(areaState)
		self:_notifyAreaGameplayReady(areaId, yard.Owner)
	end
	return areaState
end

function LeafService:_prepareOwnerYard(owner)
	if owner.Parent ~= Players or not self.PlayerDataService:GetState(owner) then
		return
	end
	local existing = self.Yards[owner]
	if existing and (existing.Preparing or existing.Ready) then
		return
	end
	local yard = self:_makeYard(owner)
	yard.ProgressionReconcileRunning = true
	repeat
		yard.ProgressionReconcilePending = false
		self:_reconcileAreaGeneration(yard)
	until self.Yards[owner] ~= yard or yard.ProgressionReconcilePending ~= true
	yard.ProgressionReconcileRunning = false
	if self.Yards[owner] ~= yard then
		return
	end
	yard.Preparing = false
	yard.Ready = true
	self:SendSnapshotToMembers(yard)
	self:_queueProgressSnapshot(yard, true)
end

function LeafService:ResetOwnerYard(owner)
	local oldYard = self.Yards[owner]
	if oldYard then
		oldYard.Ready = false
		for _, areaState in oldYard.Areas do
			self:_invalidateRefillPreparation(areaState)
		end
		for leaf in oldYard.LeavesById do
			activeMovingLeaves[leaf] = nil
		end
		table.clear(oldYard.PendingMoveLeaves)
		self.Yards[owner] = nil
	end

	for _, member in self.YardService:GetMembers(owner) do
		self:SetPickupActive(member, false)
		self:ClearHarvestAim(member)
		self.ToolActionService:StopPlayer(member)
	end

	self:_prepareOwnerYard(owner)
	return self.Yards[owner]
end

function LeafService:_getYardForPlayer(player)
	local owner = self.YardService:GetActiveOwner(player)
	return owner and self.Yards[owner] or nil
end

local function getLastInfluencedUserId(leaf)
	local lastInfluencedPlayer = leaf.LastInfluencedPlayer
	return if typeof(lastInfluencedPlayer) == "Instance"
		and lastInfluencedPlayer:IsA("Player")
		then lastInfluencedPlayer.UserId
		else nil
end

function LeafService:_serializeLeafMotion(leaf, sampleServerTime)
	local moving = activeMovingLeaves[leaf] == true
	return {
		Id = leaf.Id,
		BoundingCFrame = leaf.BoundingCFrame,
		Revision = leaf.Revision,
		LastInfluencedUserId = getLastInfluencedUserId(leaf),
		LastInfluencedToolId = leaf.LastInfluencedToolId,
		IsMoving = moving,
		MotionSampleServerTime = sampleServerTime,
		MotionVelocity = if moving then getHorizontalVelocity(leaf) else nil,
		MotionAngularVelocity = if moving then tonumber(leaf.AngularVelocity) or 0 else nil,
		MotionPoweredSecondsRemaining = if moving
			then math.max(0, (tonumber(leaf.PoweredUntil) or 0) - os.clock())
			else nil,
		MotionStopPoint = if moving and isFiniteVector3(leaf.StopPoint) then leaf.StopPoint else nil,
		MotionStopRadius = if moving then math.max(0, tonumber(leaf.StopRadius) or 0) else nil,
	}
end

function LeafService:_serializeLeaf(leaf, sampleServerTime)
	local descriptor = {
		Id = leaf.Id,
		AreaId = leaf.AreaId,
		LeafType = leaf.LeafType,
		BagValue = leaf.BagValue,
		BoundingCFrame = leaf.BoundingCFrame,
		BoundingSize = leaf.BoundingSize,
		Revision = leaf.Revision,
		LastInfluencedUserId = getLastInfluencedUserId(leaf),
		LastInfluencedToolId = leaf.LastInfluencedToolId,
	}
	if activeMovingLeaves[leaf] == true then
		local motion = self:_serializeLeafMotion(leaf, sampleServerTime or Workspace:GetServerTimeNow())
		descriptor.IsMoving = true
		descriptor.MotionSampleServerTime = motion.MotionSampleServerTime
		descriptor.MotionVelocity = motion.MotionVelocity
		descriptor.MotionAngularVelocity = motion.MotionAngularVelocity
		descriptor.MotionPoweredSecondsRemaining = motion.MotionPoweredSecondsRemaining
		descriptor.MotionStopPoint = motion.MotionStopPoint
		descriptor.MotionStopRadius = motion.MotionStopRadius
	end
	return descriptor
end

function LeafService:SendSnapshot(player)
	local yard = self:_getYardForPlayer(player)
	if not yard or not yard.Ready then
		return false
	end
	local serial = (self.SnapshotSerials[player] or 0) + 1
	self.SnapshotSerials[player] = serial
	local ownerUserId = yard.OwnerUserId
	local areas = {}
	local leaves = {}
	local snapshotMotionSampleTime = Workspace:GetServerTimeNow()
	for _, areaId in RegionConfig.Order do
		local areaState = yard.Areas[areaId]
		if areaState then
			table.insert(areas, {
				AreaId = areaId,
				GameplayReady = areaState.Generated,
				PreviewOnly = areaState.PreviewOnly,
				Completed = areaState.Completed,
			})
			for _, leaf in areaState.Leaves do
				table.insert(leaves, self:_serializeLeaf(leaf, snapshotMotionSampleTime))
			end
		end
	end

	task.spawn(function()
		if player.Parent ~= Players or self.SnapshotSerials[player] ~= serial then
			return
		end
		self.Remotes.YardLeafSnapshot:FireClient(player, {
			Kind = "Begin",
			YardOwnerUserId = ownerUserId,
			Serial = serial,
			Areas = areas,
			LeafCount = #leaves,
		})
		for firstIndex = 1, #leaves, SNAPSHOT_CHUNK_SIZE do
			if player.Parent ~= Players or self.SnapshotSerials[player] ~= serial then
				return
			end
			local chunk = {}
			for index = firstIndex, math.min(firstIndex + SNAPSHOT_CHUNK_SIZE - 1, #leaves) do
				table.insert(chunk, leaves[index])
			end
			self.Remotes.YardLeafSnapshot:FireClient(player, {
				Kind = "Chunk",
				YardOwnerUserId = ownerUserId,
				Serial = serial,
				Leaves = chunk,
			})
			task.wait()
		end
		if player.Parent == Players and self.SnapshotSerials[player] == serial then
			self.Remotes.YardLeafSnapshot:FireClient(player, {
				Kind = "End",
				YardOwnerUserId = ownerUserId,
				Serial = serial,
			})
		end
	end)
	return true
end

function LeafService:SendSnapshotToMembers(yard)
	for _, member in self.YardService:GetMembers(yard.Owner) do
		self:SendSnapshot(member)
	end
end

function LeafService:_sendDelta(yard, packet)
	yard.Revision += 1
	packet.YardOwnerUserId = yard.OwnerUserId
	packet.Revision = yard.Revision
	for _, member in self.YardService:GetMembers(yard.Owner) do
		if member.Parent == Players then
			self.Remotes.YardLeafDelta:FireClient(member, packet)
		end
	end
end

function LeafService:_queueLeafUpsert(leaf)
	leaf.Yard.PendingMoveLeaves[leaf.Id] = leaf
end

function LeafService:_flushMoveDeltas()
	local now = os.clock()
	for _, yard in self.Yards do
		local hasPendingLeaves = next(yard.PendingMoveLeaves) ~= nil
		local shouldFlush = yard.ForceMoveReplication == true
			or now + LEAF_MOVE_REPLICATION_CLOCK_TOLERANCE
				>= (tonumber(yard.NextMoveReplicationAt) or 0)
		if hasPendingLeaves and shouldFlush then
			local leaves = {}
			local sampleServerTime = Workspace:GetServerTimeNow()
			for leafId, leaf in yard.PendingMoveLeaves do
				yard.PendingMoveLeaves[leafId] = nil
				if yard.LeavesById[leafId] == leaf then
					table.insert(leaves, self:_serializeLeafMotion(leaf, sampleServerTime))
				end
			end
			if #leaves > 0 then
				self:_sendDelta(yard, {
					Kind = "Move",
					SampleServerTime = sampleServerTime,
					Leaves = leaves,
				})
			end
			yard.NextMoveReplicationAt = now + LEAF_MOVE_REPLICATION_INTERVAL
			yard.ForceMoveReplication = false
		elseif not hasPendingLeaves then
			yard.ForceMoveReplication = false
		end
	end
end

function LeafService:ClearHarvestAim(player)
	harvestAimEntries[player] = nil
end

function LeafService:AddLeafStateChangedHandler(handler)
	table.insert(self.LeafStateChangedHandlers, handler)
end

function LeafService:AddAreaGameplayReadyHandler(handler)
	table.insert(self.AreaGameplayReadyHandlers, handler)
end

function LeafService:AddAreaCompletedHandler(handler)
	if handler then
		table.insert(self.AreaCompletedHandlers, handler)
	end
end

function LeafService:_notifyAreaGameplayReady(areaId, owner)
	for _, handler in self.AreaGameplayReadyHandlers do
		local success, message = pcall(handler, areaId, owner)
		if not success then
			warn("Area gameplay-ready handler failed: " .. tostring(message))
		end
	end
end

function LeafService:_notifyLeafStateChanged(player)
	for _, handler in self.LeafStateChangedHandlers do
		local success, message = pcall(handler, player)
		if not success then
			warn("Leaf state changed handler failed: " .. tostring(message))
		end
	end
end

function LeafService:_queueProgressSnapshot(yard, immediate)
	if immediate then
		for _, member in self.YardService:GetMembers(yard.Owner) do
			self.PlayerDataService:PushSnapshot(member)
		end
		return
	end
	if yard.ProgressSnapshotQueued then
		return
	end
	yard.ProgressSnapshotQueued = true
	task.delay(PROGRESS_SNAPSHOT_INTERVAL, function()
		yard.ProgressSnapshotQueued = false
		if self.Yards[yard.Owner] ~= yard then
			return
		end
		for _, member in self.YardService:GetMembers(yard.Owner) do
			self.PlayerDataService:PushSnapshot(member)
		end
	end)
end

function LeafService:_resolveHarvestAimPosition(humanoid, rootPart, horizontalPosition)
	local feetOffset = math.max(0, humanoid.HipHeight + rootPart.Size.Y / 2)
	return Vector3.new(
		horizontalPosition.X,
		rootPart.Position.Y - feetOffset,
		horizontalPosition.Z
	)
end

function LeafService:UpdateHarvestAim(player, valid, aimOffset, playerCentered)
	if valid ~= true then
		self:ClearHarvestAim(player)
		return
	end
	local now = os.clock()
	if now - (lastHarvestAimUpdateTimes[player] or -math.huge) < HARVEST_AIM_MIN_UPDATE_INTERVAL then
		return
	end
	lastHarvestAimUpdateTimes[player] = now
	local function rejectAim()
		harvestAimEntries[player] = nil
	end
	if player.Parent ~= Players or not isFiniteVector3(aimOffset) or type(playerCentered) ~= "boolean" then
		rejectAim()
		return
	end
	local state = self.PlayerDataService:GetState(player)
	local toolConfig = state and state.EquippedTool and ToolConfig.ById[state.EquippedTool]
	local effectiveAttributes = state and self.PlayerDataService:GetEffectiveToolAttributes(state)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local equippedTool = character and character:FindFirstChildOfClass("Tool")
	if not state or not toolConfig or not effectiveAttributes or toolConfig.AvailableForGameplay ~= true
		or not humanoid or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart")
		or not equippedTool or equippedTool:GetAttribute("CleaningToolId") ~= toolConfig.Id
	then
		rejectAim()
		return
	end
	local maxDistance = math.max(0, tonumber(effectiveAttributes.ForwardOffset) or tonumber(toolConfig.ForwardOffset) or 0)
	local allowedDistance = maxDistance + HARVEST_AIM_DISTANCE_TOLERANCE
	local horizontalOffsetSquared = aimOffset.X * aimOffset.X + aimOffset.Z * aimOffset.Z
	local invalidOffset = math.abs(aimOffset.Y) > 0.01
		or (if playerCentered
			then horizontalOffsetSquared > PLAYER_CENTERED_AIM_OFFSET_TOLERANCE * PLAYER_CENTERED_AIM_OFFSET_TOLERANCE
			else horizontalOffsetSquared > allowedDistance * allowedDistance)
	if maxDistance <= 0 or invalidOffset then
		rejectAim()
		return
	end
	local targetPosition = if playerCentered then rootPart.Position else rootPart.Position + aimOffset
	harvestAimEntries[player] = {
		Position = self:_resolveHarvestAimPosition(humanoid, rootPart, targetPosition),
		RootPositionAtUpdate = rootPart.Position,
		ToolId = toolConfig.Id,
		PlayerCentered = playerCentered,
		UpdatedAt = now,
	}
end

function LeafService:_getValidatedHarvestAim(player, humanoid, rootPart, toolConfig, effectiveAttributes)
	local entry = harvestAimEntries[player]
	if not entry or entry.ToolId ~= toolConfig.Id or os.clock() - entry.UpdatedAt > HARVEST_AIM_MAX_AGE then
		harvestAimEntries[player] = nil
		return nil
	end
	if entry.PlayerCentered == true then
		entry.Position = self:_resolveHarvestAimPosition(humanoid, rootPart, rootPart.Position)
		entry.RootPositionAtUpdate = rootPart.Position
		return entry.Position, true
	end
	local maxDistance = math.max(0, tonumber(effectiveAttributes.ForwardOffset) or tonumber(toolConfig.ForwardOffset) or 0)
	local allowedDistance = maxDistance + HARVEST_AIM_DISTANCE_TOLERANCE
	if maxDistance <= 0 or HarvestGeometry.GetHorizontalDistanceSquared(entry.RootPositionAtUpdate, entry.Position) > allowedDistance * allowedDistance then
		harvestAimEntries[player] = nil
		return nil
	end
	local rootDisplacement = HarvestGeometry.GetHorizontalDelta(entry.RootPositionAtUpdate, rootPart.Position)
	local translatedPosition = entry.Position + rootDisplacement
	local clampedPosition = HarvestGeometry.ClampHorizontalPosition(rootPart.Position, translatedPosition, maxDistance)
	entry.Position = self:_resolveHarvestAimPosition(humanoid, rootPart, clampedPosition)
	entry.RootPositionAtUpdate = rootPart.Position
	return entry.Position, false
end

function LeafService:_findLeafPushTranslation(leaf, displacement, nextRotation)
	for _, fraction in LEAF_PUSH_DISTANCE_FRACTIONS do
		local desiredPosition = leaf.BoundingCFrame.Position + displacement * fraction
		local result = Workspace:Raycast(
			desiredPosition + Vector3.new(0, LEAF_PUSH_RAY_HEIGHT, 0),
			Vector3.new(0, -LEAF_PUSH_RAY_DISTANCE, 0),
			leaf.AreaState.Definition.RaycastParams
		)
		if result then
			local supportRadius = getBoundsSupportRadius(nextRotation, leaf.BoundingSize, result.Normal)
			local targetBoundsPosition = result.Position + result.Normal * (supportRadius + LEAF_PUSH_GROUND_GAP)
			return targetBoundsPosition - leaf.BoundingCFrame.Position, fraction
		end
	end
	return nil
end

function LeafService:_finishLeafMotion(leaf)
	local wasMoving = activeMovingLeaves[leaf] == true
	activeMovingLeaves[leaf] = nil
	leaf.Velocity = Vector3.zero
	leaf.AngularVelocity = 0
	leaf.PoweredUntil = 0
	leaf.StopPoint = nil
	leaf.StopRadius = 0
	if wasMoving and leaf.Yard.LeavesById[leaf.Id] == leaf then
		leaf.Revision += 1
		self:_queueLeafUpsert(leaf)
		leaf.Yard.ForceMoveReplication = true
	end
	if leaf.MotionDirty and leaf.Yard.LeavesById[leaf.Id] == leaf then
		leaf.MotionDirty = false
		self:_notifyLeafStateChanged(leaf.LastInfluencedPlayer)
	end
end

function LeafService:_setLeafInfluence(leaf, influencingPlayer, influencingToolId)
	if typeof(influencingPlayer) == "Instance" and influencingPlayer:IsA("Player") then
		leaf.LastInfluencedAt = os.clock()
		leaf.LastInfluencedPlayer = influencingPlayer
		leaf.LastInfluencedToolId = type(influencingToolId) == "string" and influencingToolId or nil
	else
		leaf.LastInfluencedPlayer = nil
		leaf.LastInfluencedToolId = nil
	end
end

function LeafService:_notifyBagFullPickupAttempt(player)
	local now = os.clock()
	if now - (lastBagFullFeedbackTimes[player] or -math.huge) < BAG_FULL_FEEDBACK_COOLDOWN then
		return
	end
	lastBagFullFeedbackTimes[player] = now
	self.PlayerDataService:NotifyBagFullPickupAttempt(player)
end

function LeafService:_tryAutoCollectBroomLeaf(leaf, deferSnapshot)
	if
		leaf.Yard.LeavesById[leaf.Id] ~= leaf
		or leaf.LastInfluencedToolId ~= BROOM_TOOL_ID
	then
		return "None", nil
	end
	local player = leaf.LastInfluencedPlayer
	if
		typeof(player) ~= "Instance"
		or not player:IsA("Player")
		or player.Parent ~= Players
		or not self.PlayerDataService:GetState(player)
		or self:_getYardForPlayer(player) ~= leaf.Yard
	then
		return "None", nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
	then
		return "None", nil
	end
	local autoCollectDistance = math.max(
		0,
		tonumber(ToolConfig.ById[BROOM_TOOL_ID].AutoCollectDistance) or 0
	)
	local leafPosition = leaf.BoundingCFrame.Position
	if
		autoCollectDistance <= 0
		or HarvestGeometry.GetHorizontalDistanceSquared(rootPart.Position, leafPosition)
			> autoCollectDistance * autoCollectDistance
		or math.abs(rootPart.Position.Y - leafPosition.Y) > MAX_VERTICAL_PICKUP_DISTANCE
	then
		return "None", player
	end
	if self:_collectLeaf(player, leaf, deferSnapshot) then
		lastBagFullFeedbackTimes[player] = nil
		return "Collected", player
	end
	if self.BagService:IsFull(player) then
		self:_notifyBagFullPickupAttempt(player)
	end
	return "Blocked", player
end

function LeafService:_setLeafMotion(
	leaf,
	velocity,
	poweredDuration,
	stopPoint,
	stopRadius,
	influencingPlayer,
	influencingToolId
)
	if leaf.Yard.LeavesById[leaf.Id] ~= leaf or not isFiniteVector3(velocity) then
		return
	end
	local horizontalVelocity = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = horizontalVelocity.Magnitude
	if speed <= 0.0001 then
		return
	end
	if speed > LEAF_MOTION_MAX_SPEED then
		horizontalVelocity = horizontalVelocity.Unit * LEAF_MOTION_MAX_SPEED
		speed = LEAF_MOTION_MAX_SPEED
	end
	local wasMoving = activeMovingLeaves[leaf] == true
	local now = os.clock()
	leaf.Velocity = horizontalVelocity
	leaf.AngularVelocity = math.clamp(
		(tonumber(leaf.AngularVelocity) or 0) * 0.4
			+ self.ToolRandom:NextNumber(-90, 90) * math.clamp(speed / 7, 0.35, 2),
		-240,
		240
	)
	self:_setLeafInfluence(leaf, influencingPlayer, influencingToolId)
	leaf.PoweredUntil = math.max(tonumber(leaf.PoweredUntil) or 0, now + math.max(0, poweredDuration or 0))
	leaf.StopPoint = isFiniteVector3(stopPoint) and stopPoint or nil
	leaf.StopRadius = leaf.StopPoint and math.max(0, tonumber(stopRadius) or 0) or 0
	leaf.MotionDirty = true
	activeMovingLeaves[leaf] = true
	if not wasMoving then
		leaf.Revision += 1
		self:_queueLeafUpsert(leaf)
		leaf.Yard.ForceMoveReplication = true
	end
end

function LeafService:_updateMovingLeaves(deltaTime)
	local now = os.clock()
	local broomCollectedCounts = {}
	for leaf in activeMovingLeaves do
		if leaf.Yard.LeavesById[leaf.Id] ~= leaf then
			activeMovingLeaves[leaf] = nil
			continue
		end
		local autoCollectState, collector = self:_tryAutoCollectBroomLeaf(leaf, true)
		if autoCollectState == "Collected" then
			broomCollectedCounts[collector] = (broomCollectedCounts[collector] or 0) + 1
			continue
		elseif autoCollectState == "Blocked" then
			self:_finishLeafMotion(leaf)
			continue
		end
		local velocity = getHorizontalVelocity(leaf)
		local angularVelocity = tonumber(leaf.AngularVelocity) or 0
		local stopPoint = isFiniteVector3(leaf.StopPoint) and leaf.StopPoint or nil
		local stopRadius = math.max(0, tonumber(leaf.StopRadius) or 0)
		local stopDelta = stopPoint and HarvestGeometry.GetHorizontalDelta(leaf.BoundingCFrame.Position, stopPoint) or nil
		if stopDelta and stopDelta.Magnitude <= stopRadius then
			self:_finishLeafMotion(leaf)
			continue
		end
		if now > (tonumber(leaf.PoweredUntil) or 0) then
			local damping = math.exp(-LEAF_MOTION_DAMPING * deltaTime)
			velocity *= damping
			angularVelocity *= damping
		end
		if velocity.Magnitude < LEAF_MOTION_STOP_SPEED and math.abs(angularVelocity) < LEAF_MOTION_STOP_ANGULAR_SPEED then
			self:_finishLeafMotion(leaf)
			continue
		end
		local displacement = velocity * deltaTime
		local shouldStopAfterMove = false
		if stopDelta and stopDelta.Magnitude > stopRadius then
			local stopDirection = stopDelta.Unit
			local remainingDistance = stopDelta.Magnitude - stopRadius
			if velocity:Dot(stopDirection) > 0 and displacement:Dot(stopDirection) >= remainingDistance then
				displacement = stopDirection * remainingDistance
				shouldStopAfterMove = true
			end
		end
		local startBounds = leaf.BoundingCFrame
		local nextRotation = CFrame.Angles(0, math.rad(angularVelocity * deltaTime), 0)
			* startBounds.Rotation
		local translation, distanceFraction = self:_findLeafPushTranslation(leaf, displacement, nextRotation)
		if not translation or translation.Magnitude <= 0.0001 then
			self:_finishLeafMotion(leaf)
			continue
		end
		leaf.BoundingCFrame = CFrame.new(startBounds.Position + translation) * nextRotation
		self:_updateLeafGrid(leaf)
		leaf.Revision += 1
		autoCollectState, collector = self:_tryAutoCollectBroomLeaf(leaf, true)
		if autoCollectState == "Collected" then
			broomCollectedCounts[collector] = (broomCollectedCounts[collector] or 0) + 1
			continue
		elseif autoCollectState == "Blocked" then
			self:_queueLeafUpsert(leaf)
			self:_finishLeafMotion(leaf)
			continue
		end
		self:_queueLeafUpsert(leaf)
		if shouldStopAfterMove and (not distanceFraction or distanceFraction >= 0.999) then
			self:_finishLeafMotion(leaf)
			continue
		end
		if distanceFraction and distanceFraction < 0.999 then
			velocity *= distanceFraction * 0.5
		end
		leaf.Velocity = velocity
		leaf.AngularVelocity = angularVelocity
	end
	for player, collectedCount in broomCollectedCounts do
		self.PlayerDataService:NotifyLeafPickupBatch(player, BROOM_TOOL_ID, LEAF_MOTION_STEP, collectedCount)
	end
	self:_flushMoveDeltas()
end

function LeafService:_getBroomCandidates(yard, origin, attributes, excludedLeaves, radiusOverride)
	local baseRadius = tonumber(radiusOverride) or tonumber(attributes.Range)
	local coverage = tonumber(attributes.SweepCoverage)
	local ringWidth = math.max(0.001, tonumber(attributes.SweepCoverageRingWidth) or 1)
	if
		not isFiniteNumber(baseRadius)
		or baseRadius <= 0
		or not isFiniteNumber(coverage)
		or coverage <= 0
	then
		return {}
	end
	local maximumRadius = HarvestGeometry.GetBroomCoverageMaximumRadius(baseRadius, coverage, ringWidth)
	local candidates = {}
	for _, leaf in self:_queryYardLeaves(yard, origin, maximumRadius) do
		if leaf.AreaState.Generated and not (excludedLeaves and excludedLeaves[leaf]) then
			local leafPosition = leaf.BoundingCFrame.Position
			local distanceSquared = HarvestGeometry.GetHorizontalDistanceSquared(origin, leafPosition)
			local distance = math.sqrt(distanceSquared)
			if distance <= maximumRadius and math.abs(leafPosition.Y - origin.Y) <= MAX_VERTICAL_PICKUP_DISTANCE then
				local ringIndex = HarvestGeometry.GetBroomCoverageRingIndex(distance, baseRadius, ringWidth)
				table.insert(candidates, {
					Leaf = leaf,
					DistanceSquared = distanceSquared,
					StableId = leaf.Id,
					RingIndex = ringIndex,
					Weight = if ringIndex == 0
						then getRangeWeight(
							distance,
							baseRadius,
							attributes.InnerRangeRatio,
							attributes.OuterForceMultiplier or 0
						)
						else math.max(0, tonumber(attributes.OuterForceMultiplier) or 0),
				})
			end
		end
	end
	return HarvestGeometry.SelectBroomCoverageCandidates(candidates, coverage)
end

function LeafService:_getBroomRecoveryCandidates(yard, player, rootPart, radius)
	local candidates = {}
	local radiusSquared = radius * radius
	for _, leaf in self:_queryYardLeaves(yard, rootPart.Position, radius) do
		if
			leaf.AreaState.Generated
			and leaf.LastInfluencedPlayer == player
			and leaf.LastInfluencedToolId == BROOM_TOOL_ID
		then
			local leafPosition = leaf.BoundingCFrame.Position
			local distanceSquared = HarvestGeometry.GetHorizontalDistanceSquared(rootPart.Position, leafPosition)
			if
				distanceSquared <= radiusSquared
				and math.abs(rootPart.Position.Y - leafPosition.Y) <= MAX_VERTICAL_PICKUP_DISTANCE
			then
				table.insert(candidates, {
					Leaf = leaf,
					DistanceSquared = distanceSquared,
				})
			end
		end
	end
	return trimCandidates(candidates, #candidates)
end

function LeafService:_useBroom(player, yard, rootPart, origin, attributes, actionRadius)
	local coverage = tonumber(attributes.SweepCoverage)
	if not isFiniteNumber(coverage) or coverage <= 0 then
		return
	end
	local baseImpulseSpeed = math.max(0, tonumber(attributes.BaseImpulseSpeed) or 18)
	local impulseMultiplier = math.max(0, tonumber(attributes.SweepImpulseMultiplier) or 0.4)
	local forceInterval = math.max(MIN_PICKUP_INTERVAL, tonumber(attributes.ForceInterval) or 0.15)
	local autoCollectDistance = math.max(
		0,
		tonumber(ToolConfig.ById[BROOM_TOOL_ID].AutoCollectDistance) or 0
	)
	local stopDistance = math.max(
		0,
		tonumber(attributes.RootStopDistance)
			or tonumber(ToolConfig.ById[BROOM_TOOL_ID].RootStopDistance)
			or 0
	)
	if baseImpulseSpeed <= 0 or impulseMultiplier <= 0 then
		return
	end
	local affectedCount = 0
	local collectedCount = 0
	local handledLeaves = {}
	for _, candidate in self:_getBroomRecoveryCandidates(
		yard,
		player,
		rootPart,
		autoCollectDistance
	) do
		local leaf = candidate.Leaf
		handledLeaves[leaf] = true
		local autoCollectState = self:_tryAutoCollectBroomLeaf(leaf, true)
		if autoCollectState == "Collected" then
			affectedCount += 1
			collectedCount += 1
		end
	end
	for _, candidate in self:_getBroomCandidates(
		yard,
		origin,
		attributes,
		handledLeaves,
		actionRadius
	) do
		local leaf = candidate.Leaf
		local towardPlayer = HarvestGeometry.GetHorizontalDelta(leaf.BoundingCFrame.Position, rootPart.Position)
		self:_setLeafInfluence(leaf, player, BROOM_TOOL_ID)
		if towardPlayer.Magnitude <= autoCollectDistance then
			local autoCollectState = self:_tryAutoCollectBroomLeaf(leaf, true)
			if autoCollectState == "Collected" then
				affectedCount += 1
				collectedCount += 1
			end
		else
			local stopPoint = Vector3.new(rootPart.Position.X, leaf.BoundingCFrame.Position.Y, rootPart.Position.Z)
			self:_setLeafMotion(
				leaf,
				towardPlayer.Unit * baseImpulseSpeed * impulseMultiplier * candidate.Weight,
				forceInterval,
				stopPoint,
				stopDistance,
				player,
				BROOM_TOOL_ID
			)
			affectedCount += 1
		end
	end
	if collectedCount > 0 then
		self.PlayerDataService:NotifyLeafPickupBatch(player, BROOM_TOOL_ID, forceInterval, collectedCount)
	end
	if affectedCount > 0 and self.MetricsService then
		self.MetricsService:RecordToolAction(player, BROOM_TOOL_ID, forceInterval, affectedCount)
	end
end

function LeafService:_useBlower(player, yard, rootPart, origin, attributes, playerCentered, actionRadius)
	local radius = tonumber(attributes.Range)
	local effectiveRadius = tonumber(actionRadius) or radius
	local pickupInterval = math.max(MIN_PICKUP_INTERVAL, tonumber(attributes.PickupInterval) or 0.2)
	local pickupCount = math.max(0, math.floor(tonumber(attributes.PickupCount) or 0))
	if
		not isFiniteNumber(radius)
		or radius <= 0
		or not isFiniteNumber(effectiveRadius)
		or effectiveRadius <= 0
		or pickupCount <= 0
	then
		return
	end
	local candidates = {}
	if playerCentered then
		local radiusSquared = effectiveRadius * effectiveRadius
		for _, leaf in self:_queryYardLeaves(yard, origin, effectiveRadius) do
			if leaf.AreaState.Generated and leaf.BagValue > 0 then
				local horizontalDistanceSquared, verticalDistance = HarvestGeometry.GetDistanceSquaredToBounds(
					origin,
					leaf.BoundingCFrame,
					leaf.BoundingSize
				)
				if horizontalDistanceSquared <= radiusSquared and verticalDistance <= MAX_VERTICAL_PICKUP_DISTANCE then
					table.insert(candidates, {
						Leaf = leaf,
						DistanceSquared = horizontalDistanceSquared,
					})
				end
			end
		end
	else
		local airflowEnd = Vector3.new(origin.X, rootPart.Position.Y, origin.Z)
		local nozzleRadius = math.max(0.35, radius * 0.15)
		local queryCenter = (rootPart.Position + airflowEnd) / 2
		local queryRadius = HarvestGeometry.GetHorizontalDelta(rootPart.Position, airflowEnd).Magnitude / 2 + radius
		for _, leaf in self:_queryYardLeaves(yard, queryCenter, queryRadius) do
			if leaf.AreaState.Generated and leaf.BagValue > 0 then
				local leafPosition = leaf.BoundingCFrame.Position
				local _, segmentAlpha, distance = HarvestGeometry.GetHorizontalSegmentInfo(
					leafPosition,
					rootPart.Position,
					airflowEnd
				)
				local allowedRadius = nozzleRadius + (radius - nozzleRadius) * segmentAlpha
				if distance <= allowedRadius and math.abs(leafPosition.Y - origin.Y) <= MAX_VERTICAL_PICKUP_DISTANCE then
					table.insert(candidates, {
						Leaf = leaf,
						DistanceSquared = HarvestGeometry.GetHorizontalDistanceSquared(rootPart.Position, leafPosition),
					})
				end
			end
		end
	end
	trimCandidates(candidates, #candidates)
	local collectedCount = 0
	for _, candidate in candidates do
		if collectedCount >= pickupCount or self.BagService:IsFull(player) then
			break
		end
		if self:_collectLeaf(player, candidate.Leaf, true) then
			collectedCount += 1
		end
	end
	if collectedCount > 0 then
		self.PlayerDataService:NotifyLeafPickupBatch(player, BLOWER_TOOL_ID, pickupInterval, collectedCount)
		if self.MetricsService then
			self.MetricsService:RecordToolAction(player, BLOWER_TOOL_ID, pickupInterval, collectedCount)
		end
		self:_queueProgressSnapshot(yard, false)
	end
end

function LeafService:_getPlayerAttemptTimes(player)
	local attempts = lastPickupAttemptTimes[player]
	if not attempts then
		attempts = {}
		lastPickupAttemptTimes[player] = attempts
	end
	return attempts
end

function LeafService:_pickupForPlayer(player, character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		activePickupPlayers[player] = nil
		if self.ToolActionService then self.ToolActionService:StopPlayer(player) end
		return
	end
	local state = self.PlayerDataService:GetState(player)
	local toolConfig = state and state.EquippedTool and ToolConfig.ById[state.EquippedTool]
	local attributes = state and self.PlayerDataService:GetEffectiveToolAttributes(state)
	local radius = toolConfig and attributes and tonumber(attributes.Range) or 0
	if not state or not toolConfig or toolConfig.AvailableForGameplay ~= true or not attributes or radius <= 0 then
		activePickupPlayers[player] = nil
		if self.ToolActionService then self.ToolActionService:StopPlayer(player) end
		return
	end
	local equippedTool = character:FindFirstChildOfClass("Tool")
	if not equippedTool or equippedTool:GetAttribute("CleaningToolId") ~= toolConfig.Id
		or activePickupPlayers[player] ~= toolConfig.Id
	then
		activePickupPlayers[player] = nil
		if self.ToolActionService then self.ToolActionService:StopPlayer(player) end
		return
	end
	local behavior = toolConfig.Behavior or "Collect"
	if behavior ~= "Collect" and behavior ~= "Broom" and behavior ~= "Blower" then
		activePickupPlayers[player] = nil
		return
	end
	if (behavior == "Collect" or behavior == "Blower") and self.BagService:IsFull(player) then
		activePickupPlayers[player] = nil
		if behavior == "Blower" and self.ToolActionService then
			self.ToolActionService:SetContinuousActive(player, BLOWER_TOOL_ID, false)
		end
		return
	end
	local configuredInterval = (behavior == "Collect" or behavior == "Blower")
		and math.max(MIN_PICKUP_INTERVAL, tonumber(attributes.PickupInterval) or 0.6)
		or math.max(MIN_PICKUP_INTERVAL, tonumber(attributes.ForceInterval) or 0.1)
	local interval = configuredInterval
	local now = os.clock()
	local attempts = self:_getPlayerAttemptTimes(player)
	if now - (attempts[toolConfig.Id] or -math.huge) < interval then
		return
	end
	local origin, playerCentered = self:_getValidatedHarvestAim(player, humanoid, rootPart, toolConfig, attributes)
	if not origin then
		if self.ToolActionService then self.ToolActionService:SetContinuousActive(player, toolConfig.Id, false) end
		return
	end
	local actionRadius = if playerCentered
		then HarvestGeometry.GetPlayerCenteredRadius(radius, attributes.ForwardOffset or toolConfig.ForwardOffset)
		else radius
	local yard = self:_getYardForPlayer(player)
	if not yard or not yard.Ready then
		if self.ToolActionService then
			self.ToolActionService:SetContinuousActive(player, toolConfig.Id, false)
		end
		return
	end
	attempts[toolConfig.Id] = now
	if (behavior == "Broom" or behavior == "Blower") and self.ToolActionService then
		self.ToolActionService:SetContinuousActive(player, toolConfig.Id, true)
	end
	if behavior == "Broom" then
		self:_useBroom(player, yard, rootPart, origin, attributes, actionRadius)
		return
	elseif behavior == "Blower" then
		self:_useBlower(player, yard, rootPart, origin, attributes, playerCentered, actionRadius)
		return
	end

	local pickupCount = math.max(1, math.floor(tonumber(attributes.PickupCount) or 1))
	local radiusSquared = actionRadius * actionRadius
	local candidates = {}
	local isHandTool = toolConfig.Id == HAND_TOOL_ID
	if isHandTool then
		debug.profilebegin("Tool01ServerPickupQuery")
	end
	local queriedLeaves = if isHandTool
		then self:_queryHandPickupLeaves(yard, origin, actionRadius)
		else self:_queryYardLeaves(yard, origin, actionRadius)
	for _, leaf in queriedLeaves do
		if leaf.AreaState.Generated and leaf.BagValue > 0 then
			local horizontalDistanceSquared, verticalDistance = HarvestGeometry.GetDistanceSquaredToBounds(
				origin,
				leaf.BoundingCFrame,
				leaf.BoundingSize
			)
			if horizontalDistanceSquared <= radiusSquared and verticalDistance <= MAX_VERTICAL_PICKUP_DISTANCE then
				local candidate = { Leaf = leaf, DistanceSquared = horizontalDistanceSquared }
				if isHandTool then
					insertBoundedCandidate(candidates, candidate, pickupCount)
				else
					table.insert(candidates, candidate)
				end
			end
		end
	end
	if isHandTool then
		debug.profileend()
	else
		trimCandidates(candidates, #candidates)
	end
	local collectedThisBatch = 0
	local collectionBatch = if isHandTool or toolConfig.Id == DUST_COLLECTOR_TOOL_ID
		then self:_createCollectionBatch(player, toolConfig.Id)
		else nil
	for _, candidate in candidates do
		if collectedThisBatch >= pickupCount or self.BagService:IsFull(player) then break end
		if self:_collectLeaf(player, candidate.Leaf, true, collectionBatch) then
			collectedThisBatch += 1
		end
	end
	if collectionBatch then
		self:_finishCollectionBatch(collectionBatch)
	end
	if collectedThisBatch > 0 then
		if self.ToolActionService then self.ToolActionService:PlayBatch(player, toolConfig.Id, interval) end
		self.PlayerDataService:NotifyLeafPickupBatch(player, toolConfig.Id, interval, collectedThisBatch)
		if self.MetricsService then self.MetricsService:RecordToolAction(player, toolConfig.Id, interval, collectedThisBatch) end
		self:_queueProgressSnapshot(yard, false)
		if self.BagService:IsFull(player) then activePickupPlayers[player] = nil end
	end
end

function LeafService:_pickupForActivePlayers()
	for player in activePickupPlayers do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if player.Parent ~= Players or not humanoid or humanoid.Health <= 0 then
			activePickupPlayers[player] = nil
			self:ClearHarvestAim(player)
			if self.ToolActionService then self.ToolActionService:StopPlayer(player) end
		elseif character then
			self:_pickupForPlayer(player, character)
		end
	end
end

function LeafService:SetPickupActive(player, active)
	if active ~= true then
		activePickupPlayers[player] = nil
		if self.ToolActionService then self.ToolActionService:SetContinuousActive(player, nil, false) end
		return
	end
	if player.Parent ~= Players then return end
	local state = self.PlayerDataService:GetState(player)
	local toolConfig = state and state.EquippedTool and ToolConfig.ById[state.EquippedTool]
	if not state or not toolConfig or toolConfig.AvailableForGameplay ~= true then return end
	if activePickupPlayers[player] and activePickupPlayers[player] ~= toolConfig.Id then
		activePickupPlayers[player] = nil
		if self.ToolActionService then self.ToolActionService:StopPlayer(player) end
	end
	if activePickupPlayers[player] then return end
	if toolConfig.Behavior == "Blower" then
		-- Every new press starts with an immediate blower collection batch.
		self:_getPlayerAttemptTimes(player)[toolConfig.Id] = nil
	end
	if (toolConfig.Behavior == "Collect" or toolConfig.Behavior == "Blower") and self.BagService:IsFull(player) then
		self:_notifyBagFullPickupAttempt(player)
		return
	end
	if toolConfig.Behavior == "Collect" or toolConfig.Behavior == "Blower" then
		lastBagFullFeedbackTimes[player] = nil
	end
	activePickupPlayers[player] = toolConfig.Id
	if player.Character then self:_pickupForPlayer(player, player.Character) end
end

function LeafService:_recordAreaRemoval(leaf, collectionMode, influencingPlayer)
	local areaState = leaf.AreaState
	areaState.CollectedValue = math.min(areaState.TotalValue, areaState.CollectedValue + leaf.BagValue)
	areaState.CollectedLeafCount = math.min(areaState.TotalLeafCount, areaState.CollectedLeafCount + 1)
	local ownerState = self.PlayerDataService:GetState(leaf.Yard.Owner)
	if ownerState then
		ownerState.YardProgress.Areas[leaf.AreaId] = ownerState.YardProgress.Areas[leaf.AreaId] or {}
		ownerState.YardProgress.Areas[leaf.AreaId].ClearedRatio = areaState.TotalValue > 0
			and math.clamp(areaState.CollectedValue / areaState.TotalValue, 0, 1)
			or 0
		self.PlayerDataService:MarkPersistentDirty(leaf.Yard.Owner)
	end
	self:_notifyLeafCollectedHandlers(
		influencingPlayer,
		leaf.AreaId,
		leaf.BoundingCFrame.Position,
		areaState.CollectedLeafCount,
		collectionMode,
		leaf.Yard.OwnerUserId
	)
	if areaState.TotalValue > 0 and areaState.CollectedValue >= areaState.TotalValue then
		self:_completeArea(leaf.Yard, areaState)
	else
		self:_queueProgressSnapshot(leaf.Yard, false)
		self:_queueAreaRefill(areaState)
	end
end

function LeafService:_createCollectionBatch(player, toolId)
	return {
		Player = player,
		ToolId = toolId,
		LeafIds = {},
		LeafHints = {},
		AddedAmount = 0,
		LeafType = nil,
		StateChanged = false,
		Yard = nil,
	}
end

function LeafService:_finishCollectionBatch(batch)
	if not batch or #batch.LeafIds <= 0 then
		return
	end
	local profilingHandBatch = batch.ToolId == HAND_TOOL_ID
	if profilingHandBatch then
		debug.profilebegin("Tool01BatchRemoval")
	end
	local player = batch.Player
	local yard = batch.Yard
	if yard then
		self:_sendDelta(yard, {
			Kind = "Remove",
			LeafIds = batch.LeafIds,
			Effect = "Collect",
			TargetUserId = player.UserId,
			Duration = 0.35,
			ToolId = batch.ToolId,
		})
	end
	if batch.AddedAmount > 0 then
		self.PlayerDataService:NotifyLeafCollected(
			player,
			batch.AddedAmount,
			batch.LeafType,
			batch.ToolId,
			batch.LeafHints
		)
	end
	if batch.StateChanged then
		self:_notifyLeafStateChanged(player)
	end
	if profilingHandBatch then
		debug.profileend()
	end
end

function LeafService:_removeLeaf(leaf, effect, targetUserId, targetPosition, removalBatch)
	local yard = leaf.Yard
	if yard.LeavesById[leaf.Id] ~= leaf then return false end
	yard.LeavesById[leaf.Id] = nil
	self:_removeLeafFromGrid(leaf)
	self:_removeLeafFromHandPickupGrid(leaf)
	activeMovingLeaves[leaf] = nil
	yard.PendingMoveLeaves[leaf.Id] = nil
	local areaLeaves = leaf.AreaState.Leaves
	local index = leaf.AreaListIndex
	if index and areaLeaves[index] == leaf then
		local lastLeaf = areaLeaves[#areaLeaves]
		areaLeaves[index] = lastLeaf
		areaLeaves[#areaLeaves] = nil
		if lastLeaf and lastLeaf ~= leaf then
			lastLeaf.AreaListIndex = index
		end
		leaf.AreaListIndex = nil
	end
	if removalBatch then
		removalBatch.Yard = removalBatch.Yard or yard
		removalBatch.LeafIds[#removalBatch.LeafIds + 1] = leaf.Id
	else
		self:_sendDelta(yard, {
			Kind = "Remove",
			LeafIds = { leaf.Id },
			Effect = effect,
			TargetUserId = targetUserId,
			TargetPosition = targetPosition,
			Duration = 0.35,
		})
	end
	return true
end

function LeafService:_collectLeaf(player, leaf, deferSnapshot, collectionBatch)
	if leaf.Yard.LeavesById[leaf.Id] ~= leaf then return false end
	local addedSuccessfully, addedAmount, storageMode, awardedCoins, targetCoins = self.BagService:TryAdd(
		player,
		leaf.BagValue,
		false,
		leaf.Yard.OwnerUserId
	)
	if not addedSuccessfully then return false end
	if not self:_removeLeaf(leaf, "Collect", player.UserId, nil, collectionBatch) then return false end
	if storageMode ~= "InstantRecycle" then
		local playerState = self.PlayerDataService:GetState(player)
		local leafValueMultiplier = math.max(
			0,
			tonumber(playerState and playerState.LeafValueMultiplier)
				or tonumber(playerState and playerState.CoinMultiplier)
				or 1
		)
		local leafHint = {
			LeafType = leaf.LeafType,
			BagAmount = addedAmount,
			DisplayValue = leaf.BagValue * leafValueMultiplier,
		}
		if collectionBatch then
			collectionBatch.AddedAmount += addedAmount
			collectionBatch.LeafType = collectionBatch.LeafType or leaf.LeafType
			collectionBatch.LeafHints[#collectionBatch.LeafHints + 1] = leafHint
		else
			self.PlayerDataService:NotifyLeafCollected(
				player,
				addedAmount,
				leaf.LeafType,
				nil,
				{ leafHint }
			)
		end
	end
	local collectionMode = if storageMode == "InstantRecycle" then "InstantRecycle" else "Bag"
	self:_recordAreaRemoval(leaf, collectionMode, player)
	if storageMode == "InstantRecycle" then
		self:_notifyInstantRecycleCompleted(
			player,
			leaf.AreaId,
			addedAmount,
			awardedCoins,
			targetCoins
		)
	end
	if collectionBatch then
		collectionBatch.StateChanged = true
	else
		self:_notifyLeafStateChanged(player)
	end
	if self.MetricsService then
		self.MetricsService:RecordLeafCollected(
			player,
			leaf.AreaId,
			addedAmount,
			leaf.AreaState.TotalValue > 0 and leaf.AreaState.CollectedValue / leaf.AreaState.TotalValue or 0,
			self.BagService:IsFull(player),
			collectionMode
		)
	end
	if not deferSnapshot then self:_queueProgressSnapshot(leaf.Yard, false) end
	return true
end

function LeafService:_completeArea(yard, areaState)
	if areaState.Completed then return end
	areaState.Completed = true
	areaState.RefillToken += 1
	areaState.RefillQueued = false
	self:_invalidateRefillPreparation(areaState)
	areaState.PendingLeafCount = 0
	areaState.NextLeafIndex = areaState.GeneratedLeafCount + 1
	areaState.CollectedValue = areaState.TotalValue
	areaState.CollectedLeafCount = areaState.TotalLeafCount
	local remainingLeafIds = {}
	for _, leaf in areaState.Leaves do
		if yard.LeavesById[leaf.Id] == leaf then
			yard.LeavesById[leaf.Id] = nil
			self:_removeLeafFromGrid(leaf)
			self:_removeLeafFromHandPickupGrid(leaf)
			activeMovingLeaves[leaf] = nil
			yard.PendingMoveLeaves[leaf.Id] = nil
			table.insert(remainingLeafIds, leaf.Id)
		end
	end
	table.clear(areaState.Leaves)
	table.clear(areaState.LeafGrid)
	table.clear(areaState.HandPickupGrid)
	if #remainingLeafIds > 0 then
		self:_sendDelta(yard, { Kind = "Remove", LeafIds = remainingLeafIds })
	end
	local ownerState = self.PlayerDataService:GetState(yard.Owner)
	if ownerState then
		ownerState.YardProgress.Areas[areaState.AreaId] = { ClearedRatio = 1 }
		self.PlayerDataService:QueuePersistentSave(yard.Owner)
	end
	for _, handler in self.AreaCompletedHandlers do
		local success, message = pcall(handler, yard.Owner, areaState.AreaId)
		if not success then
			warn("Area-completed handler failed: " .. tostring(message))
		end
	end
	for _, member in self.YardService:GetMembers(yard.Owner) do
		self.Remotes.AreaCompletionNotice:FireClient(member, areaState.AreaId, nil)
	end
	-- Area completion and a near-simultaneous door touch must share the same
	-- reconciliation queue. This keeps preview promotion/removal idempotent and
	-- prevents two yielding generation passes from rebuilding the same area.
	self:_queueProgressionReconcile(yard)
end

function LeafService:GenerateNextAreaForUnlock(playerOrAreaId, maybeAreaId)
	local player = typeof(playerOrAreaId) == "Instance" and playerOrAreaId or nil
	local areaId = player and maybeAreaId or playerOrAreaId
	local owner = player and self.YardService:GetActiveOwner(player) or nil
	local yard = owner and self.Yards[owner] or nil
	if not yard or type(areaId) ~= "string" then return false end
	local ownerState = self.PlayerDataService:GetState(owner)
	if not ownerState or ownerState.UnlockedAreas[areaId] ~= true then
		return false
	end
	return self:_queueProgressionReconcile(yard)
end

function LeafService:GetProgress(playerOrAreaId, maybeAreaId)
	local player = typeof(playerOrAreaId) == "Instance" and playerOrAreaId or nil
	local areaId = player and maybeAreaId or playerOrAreaId
	local yard = player and self:_getYardForPlayer(player) or nil
	if not yard and not player then
		for _, candidate in self.Yards do
			yard = candidate
			break
		end
	end
	local areaState = yard and yard.Areas[areaId or "Area_01"] or nil
	if not areaState or areaState.TotalValue <= 0 then return 0, 0, 0 end
	return areaState.CollectedValue, areaState.TotalValue, math.clamp(areaState.CollectedValue / areaState.TotalValue, 0, 1)
end

function LeafService:IsAreaGameplayReady(playerOrAreaId, maybeAreaId)
	local player = typeof(playerOrAreaId) == "Instance" and playerOrAreaId or nil
	local areaId = player and maybeAreaId or playerOrAreaId
	local yard = player and self:_getYardForPlayer(player) or nil
	if not yard and not player then
		for _, candidate in self.Yards do
			yard = candidate
			break
		end
	end
	local areaState = yard and yard.Areas[areaId or "Area_01"] or nil
	return areaState ~= nil and areaState.Generated == true
end

function LeafService:IsAreaCompleted(playerOrAreaId, maybeAreaId)
	local player = typeof(playerOrAreaId) == "Instance" and playerOrAreaId or nil
	local areaId = player and maybeAreaId or playerOrAreaId
	local yard = player and self:_getYardForPlayer(player) or nil
	if not yard and not player then
		for _, candidate in self.Yards do
			yard = candidate
			break
		end
	end
	local areaState = yard and yard.Areas[areaId or "Area_01"] or nil
	return areaState ~= nil and areaState.Completed == true
end

function LeafService:GetLeafCounts(playerOrAreaId, maybeAreaId)
	local player = typeof(playerOrAreaId) == "Instance" and playerOrAreaId or nil
	local areaId = player and maybeAreaId or playerOrAreaId
	local yard = player and self:_getYardForPlayer(player) or nil
	if not yard and not player then
		for _, candidate in self.Yards do
			yard = candidate
			break
		end
	end
	local areaState = yard and yard.Areas[areaId or "Area_01"] or nil
	if not areaState then return 0, 0 end
	return areaState.CollectedLeafCount, areaState.TotalLeafCount
end

function LeafService:GetActiveLeafEntries(playerOrAreaId, maybeAreaId)
	local player = typeof(playerOrAreaId) == "Instance" and playerOrAreaId or nil
	local areaId = player and maybeAreaId or playerOrAreaId
	local yard = player and self:_getYardForPlayer(player) or nil
	if not yard and not player then
		for _, candidate in self.Yards do
			yard = candidate
			break
		end
	end
	local entries = {}
	if not yard then return entries end
	for _, leaf in yard.LeavesById do
		if leaf.AreaState.Generated and (not areaId or leaf.AreaId == areaId) then
			table.insert(entries, leaf)
		end
	end
	return entries
end

function LeafService:_notifyLeafCollectedHandlers(
	player,
	areaId,
	position,
	collectedLeafCount,
	collectionMode,
	yardOwnerUserId
)
	for _, handler in self.LeafCollectedHandlers do
		local success, message = pcall(
			handler,
			player,
			areaId,
			position,
			collectedLeafCount,
			collectionMode,
			yardOwnerUserId
		)
		if not success then warn("Leaf-collected handler failed: " .. tostring(message)) end
	end
end

function LeafService:SetLeafCollectedHandler(handler)
	table.clear(self.LeafCollectedHandlers)
	if handler then table.insert(self.LeafCollectedHandlers, handler) end
end

function LeafService:AddLeafCollectedHandler(handler)
	table.insert(self.LeafCollectedHandlers, handler)
end

function LeafService:_notifyInstantRecycleCompleted(player, areaId, leafValue, awardedCoins, targetCoins)
	for _, handler in self.InstantRecycleCompletedHandlers do
		local success, message = pcall(handler, player, areaId, leafValue, awardedCoins, targetCoins)
		if not success then
			warn("Instant-recycle handler failed: " .. tostring(message))
		end
	end
end

function LeafService:AddInstantRecycleCompletedHandler(handler)
	if handler then
		table.insert(self.InstantRecycleCompletedHandlers, handler)
	end
end

return LeafService

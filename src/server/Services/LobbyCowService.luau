local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LobbyCowService = {}

local LOBBY_FOLDER_NAME = "大厅装扮"
local COW_NAME = "Cow"
local DIRECTION_NAME = "Direction"
local WAYPOINT_FOLDER_NAME = "actionpoop"
local WAYPOINT_COUNT = 6
local BASE_MOVE_SPEED = 5
local MINIMUM_SPEED_MULTIPLIER = 0.7
local MAXIMUM_SPEED_MULTIPLIER = 1.4
local MINIMUM_SPEED_CHANGE_INTERVAL = 3
local MAXIMUM_SPEED_CHANGE_INTERVAL = 12
local TURN_SPEED_RADIANS = math.rad(180)
local POOP_ATTEMPT_INTERVAL = 5
local POOP_BEHIND_DISTANCE = 2
local GROUND_RAY_HEIGHT = 20
local GROUND_RAY_DISTANCE = 80
local MAXIMUM_MOVEMENT_STEPS_PER_HEARTBEAT = 8

local function horizontalUnit(vector)
	local horizontal = Vector3.new(vector.X, 0, vector.Z)
	if horizontal.Magnitude < 0.001 then
		return nil
	end
	return horizontal.Unit
end

local function getYaw(vector)
	return math.atan2(-vector.X, -vector.Z)
end

local function moveYawTowards(currentYaw, targetYaw, maximumDelta)
	local delta = (targetYaw - currentYaw + math.pi) % (2 * math.pi) - math.pi
	if math.abs(delta) <= maximumDelta then
		return targetYaw
	end
	return currentYaw + math.sign(delta) * maximumDelta
end

function LobbyCowService:_warnAndDisable(message)
	if not self.WarningEmitted then
		self.WarningEmitted = true
		warn("Lobby cow is disabled: " .. message)
	end
	self.Enabled = false
end

function LobbyCowService:_getGroundHit(position)
	local excluded = { self.Cow, self.WaypointFolder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(excluded, player.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excluded
	params.IgnoreWater = false
	return Workspace:Raycast(
		position + Vector3.new(0, GROUND_RAY_HEIGHT, 0),
		Vector3.new(0, -GROUND_RAY_DISTANCE, 0),
		params
	)
end

function LobbyCowService:_makeTargetPosition(waypoint)
	local hit = self:_getGroundHit(waypoint.Position)
	if not hit or not hit.Instance or not hit.Instance:IsA("BasePart") then
		return nil
	end
	return Vector3.new(waypoint.Position.X, hit.Position.Y + self.CowPivotHeight, waypoint.Position.Z)
end

function LobbyCowService:_setCowPivot(position)
	local pivotRotation = CFrame.Angles(0, self.CurrentYaw, 0)
		* self.DirectionLocalRotation:Inverse()
	self.Cow:PivotTo(CFrame.new(position) * pivotRotation)
end

function LobbyCowService:_chooseNextSpeed(now)
	self.SpeedMultiplier = self.Random:NextNumber(
		MINIMUM_SPEED_MULTIPLIER,
		MAXIMUM_SPEED_MULTIPLIER
	)
	self.NextSpeedChangeAt = now + self.Random:NextNumber(
		MINIMUM_SPEED_CHANGE_INTERVAL,
		MAXIMUM_SPEED_CHANGE_INTERVAL
	)
end

function LobbyCowService:_moveCow(deltaTime, now)
	if now >= self.NextSpeedChangeAt then
		self:_chooseNextSpeed(now)
	end

	local remainingMovement = BASE_MOVE_SPEED * self.SpeedMultiplier * deltaTime
	local movementSteps = 0
	while remainingMovement > 0 and movementSteps < MAXIMUM_MOVEMENT_STEPS_PER_HEARTBEAT do
		movementSteps += 1
		local destination = self.TargetPositions[self.DestinationIndex]
		local offset = destination - self.CurrentPosition
		local distance = offset.Magnitude
		if distance <= 0.001 then
			self.CurrentPosition = destination
			self.DestinationIndex = self.DestinationIndex % #self.TargetPositions + 1
		else
			local direction = offset.Unit
			local travel = math.min(distance, remainingMovement)
			self.CurrentPosition += direction * travel
			remainingMovement -= travel
			local horizontalDirection = horizontalUnit(direction)
			if horizontalDirection then
				self.CurrentYaw = moveYawTowards(
					self.CurrentYaw,
					getYaw(horizontalDirection),
					TURN_SPEED_RADIANS * deltaTime
				)
			end
			if travel >= distance - 0.001 then
				self.CurrentPosition = destination
				self.DestinationIndex = self.DestinationIndex % #self.TargetPositions + 1
			end
		end
	end
	self:_setCowPivot(self.CurrentPosition)
end

function LobbyCowService:_tryCreatePoop()
	local cowPivot = self.Cow:GetPivot()
	local forward = horizontalUnit(self.Direction.CFrame.LookVector)
	if not forward then
		self:_warnAndDisable("Cow.Direction must have a valid horizontal LookVector")
		return
	end
	local rayPosition = cowPivot.Position - forward * POOP_BEHIND_DISTANCE
	local hit = self:_getGroundHit(rayPosition)
	if not hit or not hit.Instance or not hit.Instance:IsA("BasePart") then
		return
	end
	self.PoopService:TryCreateLobbyPoop(hit.Position, forward)
end

function LobbyCowService:Init(poopService)
	self.PoopService = poopService
	self.Random = Random.new()
	self.Enabled = false
	self.WarningEmitted = false

	local lobbyFolder = Workspace:FindFirstChild(LOBBY_FOLDER_NAME)
	local cow = lobbyFolder and lobbyFolder:FindFirstChild(COW_NAME)
	local direction = cow and cow:FindFirstChild(DIRECTION_NAME)
	local waypointFolder = lobbyFolder and lobbyFolder:FindFirstChild(WAYPOINT_FOLDER_NAME)
	if not lobbyFolder or not lobbyFolder:IsA("Folder") then
		self:_warnAndDisable("Workspace.大厅装扮 must be a Folder")
		return
	end
	if not cow or not cow:IsA("Model") then
		self:_warnAndDisable("Workspace.大厅装扮.Cow must be a Model")
		return
	end
	if not direction or not direction:IsA("BasePart") then
		self:_warnAndDisable("Workspace.大厅装扮.Cow.Direction must be a BasePart")
		return
	end
	if not waypointFolder or not waypointFolder:IsA("Folder") then
		self:_warnAndDisable("Workspace.大厅装扮.actionpoop must be a Folder")
		return
	end
	for _, descendant in cow:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant.Anchored then
			self:_warnAndDisable(descendant:GetFullName() .. " must remain anchored")
			return
		end
	end

	local waypoints = {}
	for index = 1, WAYPOINT_COUNT do
		local name = string.format("Part%03d", index)
		local waypoint = waypointFolder:FindFirstChild(name)
		if not waypoint or not waypoint:IsA("BasePart") then
			self:_warnAndDisable(waypointFolder:GetFullName() .. "." .. name .. " must be a BasePart")
			return
		end
		table.insert(waypoints, waypoint)
	end

	self.LobbyFolder = lobbyFolder
	self.Cow = cow
	self.Direction = direction
	self.WaypointFolder = waypointFolder
	self.Waypoints = waypoints
	local cowBoundingCFrame, cowBoundingSize = cow:GetBoundingBox()
	self.CowPivotHeight = math.max(
		0,
		cow:GetPivot().Position.Y - (cowBoundingCFrame.Position.Y - cowBoundingSize.Y / 2)
	)
	self.DirectionLocalRotation = cow:GetPivot():ToObjectSpace(direction.CFrame).Rotation
	self.TargetPositions = {}
	for _, waypoint in waypoints do
		local targetPosition = self:_makeTargetPosition(waypoint)
		if not targetPosition then
			self:_warnAndDisable("no ground was found below " .. waypoint:GetFullName())
			return
		end
		table.insert(self.TargetPositions, targetPosition)
	end

	local firstDirection = horizontalUnit(self.TargetPositions[2] - self.TargetPositions[1])
	if not firstDirection then
		self:_warnAndDisable("Part001 and Part002 must not share the same horizontal position")
		return
	end
	self.CurrentPosition = self.TargetPositions[1]
	self.DestinationIndex = 2
	self.CurrentYaw = getYaw(firstDirection)
	self:_setCowPivot(self.CurrentPosition)
	local now = os.clock()
	self:_chooseNextSpeed(now)
	self.NextPoopAttemptAt = now + POOP_ATTEMPT_INTERVAL
	self.Enabled = true

	RunService.Heartbeat:Connect(function(deltaTime)
		if not self.Enabled or not self.Cow.Parent or not self.Direction.Parent then
			return
		end
		local heartbeatNow = os.clock()
		self:_moveCow(math.min(math.max(deltaTime, 0), 0.25), heartbeatNow)
		if heartbeatNow >= self.NextPoopAttemptAt then
			self.NextPoopAttemptAt = heartbeatNow + POOP_ATTEMPT_INTERVAL
			self:_tryCreatePoop()
		end
	end)
end

return LobbyCowService

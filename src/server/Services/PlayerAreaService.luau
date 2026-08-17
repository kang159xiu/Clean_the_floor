local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local PlayerAreaService = {}

local UPDATE_INTERVAL = 0.25
local GROUND_RAY_HEIGHT = 4
local GROUND_RAY_DISTANCE = 20

function PlayerAreaService:Init(playerDataService, metricsService)
	self.PlayerDataService = playerDataService
	self.MetricsService = metricsService
	self.Grounds = {}
	self.RaycastParams = RaycastParams.new()
	self.RaycastParams.FilterType = Enum.RaycastFilterType.Include
	self.RaycastParams.IgnoreWater = true

	local filters = {}
	for _, areaId in RegionConfig.Order do
		local area = Workspace:FindFirstChild(areaId)
		assert(area and area:IsA("Folder"), "Workspace." .. areaId .. " must be a Folder")
		local ground = area:FindFirstChild("ground")
		assert(ground and ground:IsA("Model"), areaId .. ".ground must be a Model")
		self.Grounds[ground] = areaId
		table.insert(filters, ground)
	end
	self.RaycastParams.FilterDescendantsInstances = filters

	local accumulator = 0
	self.Connection = RunService.Heartbeat:Connect(function(deltaTime)
		accumulator += deltaTime
		if accumulator < UPDATE_INTERVAL then
			return
		end
		accumulator %= UPDATE_INTERVAL
		for _, player in Players:GetPlayers() do
			self:_updatePlayer(player)
		end
	end)
end

function PlayerAreaService:_getAreaIdAtRoot(rootPart)
	local result = Workspace:Raycast(
		rootPart.Position + Vector3.new(0, GROUND_RAY_HEIGHT, 0),
		Vector3.new(0, -GROUND_RAY_DISTANCE, 0),
		self.RaycastParams
	)
	if not result then
		return nil
	end

	local current = result.Instance
	while current do
		local areaId = self.Grounds[current]
		if areaId then
			return areaId
		end
		current = current.Parent
	end
	return nil
end

function PlayerAreaService:_updatePlayer(player)
	local state = self.PlayerDataService:GetState(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		not state
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
	then
		return
	end

	local areaId = self:_getAreaIdAtRoot(rootPart)
	if not areaId or state.CurrentAreaId == areaId then
		return
	end

	local previousAreaId = state.CurrentAreaId
	state.CurrentAreaId = areaId
	if self.MetricsService then
		self.MetricsService:RecordAreaEntered(player, areaId, previousAreaId)
	end
	self.PlayerDataService:PushSnapshot(player)
end

return PlayerAreaService

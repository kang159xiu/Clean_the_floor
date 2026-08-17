local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ReturnToSpawnService = {}

local REQUEST_COOLDOWN = 1
local SPAWN_CLEARANCE = 0.1

local requestTimes = {}

local function clearCharacterVelocity(character)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.AssemblyLinearVelocity = Vector3.zero
			descendant.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local function isBodyPart(character, part)
	local current = part.Parent
	while current and current ~= character do
		if current:IsA("Accessory") or current:IsA("Tool") then
			return false
		end
		current = current.Parent
	end
	return current == character
end

local function getStandingRootHeight(character, rootPart)
	local rootUp = rootPart.CFrame.UpVector
	local lowestOffset = -rootPart.Size.Y / 2
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") and isBodyPart(character, descendant) then
			local centerOffset = rootPart.CFrame:PointToObjectSpace(descendant.Position).Y
			local halfExtent = (
				math.abs(descendant.CFrame.RightVector:Dot(rootUp)) * descendant.Size.X
				+ math.abs(descendant.CFrame.UpVector:Dot(rootUp)) * descendant.Size.Y
				+ math.abs(descendant.CFrame.LookVector:Dot(rootUp)) * descendant.Size.Z
			) / 2
			lowestOffset = math.min(lowestOffset, centerOffset - halfExtent)
		end
	end
	return -lowestOffset
end

function ReturnToSpawnService:_getSpawnLocation()
	local spawnLocation = Workspace:FindFirstChild("SpawnLocation")
	if
		not spawnLocation
		or not spawnLocation:IsA("SpawnLocation")
		or spawnLocation.Enabled ~= true
	then
		return nil
	end
	return spawnLocation
end

function ReturnToSpawnService:_request(player)
	local now = os.clock()
	if now - (requestTimes[player] or -math.huge) < REQUEST_COOLDOWN then
		return false, "Please wait before returning again."
	end
	requestTimes[player] = now

	if not self.PlayerDataService:GetState(player) then
		return false, "Player data is not ready."
	end
	local spawnLocation = self:_getSpawnLocation()
	if not spawnLocation then
		return false, "The spawn point is unavailable."
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		not character
		or character.Parent == nil
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
	then
		return false, "Your character is not ready."
	end

	self.LeafService:SetPickupActive(player, false)
	self.LeafService:ClearHarvestAim(player)
	self.ToolActionService:StopPlayer(player)

	local rootHeight = spawnLocation.Size.Y / 2
		+ getStandingRootHeight(character, rootPart)
		+ SPAWN_CLEARANCE
	local targetRootCFrame = spawnLocation.CFrame * CFrame.new(0, rootHeight, 0)
	local targetCharacterPivot = targetRootCFrame * rootPart.CFrame:Inverse() * character:GetPivot()
	clearCharacterVelocity(character)
	character:PivotTo(targetCharacterPivot)
	clearCharacterVelocity(character)
	return true, "Returned to spawn."
end

function ReturnToSpawnService:Init(playerDataService, leafService, toolActionService, requestRemote)
	self.PlayerDataService = playerDataService
	self.LeafService = leafService
	self.ToolActionService = toolActionService

	requestRemote.OnServerInvoke = function(player)
		return self:_request(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		requestTimes[player] = nil
	end)
end

return ReturnToSpawnService

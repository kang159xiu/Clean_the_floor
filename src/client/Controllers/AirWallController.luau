local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local AreaUnlockConfig = require(ReplicatedStorage.Shared.Config.AreaUnlockConfig)

local AirWallController = {}

local AIR_WALL_ROOT_NAME = "AirWall"

function AirWallController:Init(remotes)
	self.UnlockedAreas = {}
	self.AreaIdByWallName = {}
	self.OriginalCanCollide = {}
	self.RootConnections = {}
	self.Root = nil

	for _, targetAreaId in AreaUnlockConfig.Order do
		local config = AreaUnlockConfig.Areas[targetAreaId]
		self.AreaIdByWallName[tostring(config.TargetAreaNumber)] = targetAreaId
	end

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self.UnlockedAreas = type(snapshot.UnlockedAreas) == "table"
			and snapshot.UnlockedAreas
			or {}
		self:_refreshAllParts()
	end)

	Workspace.ChildAdded:Connect(function(child)
		if child.Name == AIR_WALL_ROOT_NAME and not self.Root then
			self:_bindRoot(child)
		end
	end)
	Workspace.ChildRemoved:Connect(function(child)
		if child == self.Root then
			self:_unbindRoot()
		end
	end)

	local root = Workspace:FindFirstChild(AIR_WALL_ROOT_NAME)
	if root then
		self:_bindRoot(root)
	end
end

function AirWallController:_getAreaIdForPart(part)
	local root = self.Root
	if not root then
		return nil
	end

	local wallContainer = part
	while wallContainer.Parent and wallContainer.Parent ~= root do
		wallContainer = wallContainer.Parent
	end
	if wallContainer.Parent ~= root then
		return nil
	end
	return self.AreaIdByWallName[wallContainer.Name]
end

function AirWallController:_applyPart(part)
	local areaId = self:_getAreaIdForPart(part)
	if not areaId then
		return
	end
	if self.OriginalCanCollide[part] == nil then
		self.OriginalCanCollide[part] = part.CanCollide
	end

	if self.UnlockedAreas[areaId] == true then
		part.CanCollide = false
	else
		part.CanCollide = self.OriginalCanCollide[part]
	end
end

function AirWallController:_restorePart(part)
	local originalCanCollide = self.OriginalCanCollide[part]
	if originalCanCollide == nil then
		return
	end
	self.OriginalCanCollide[part] = nil
	if part.Parent then
		part.CanCollide = originalCanCollide
	end
end

function AirWallController:_refreshAllParts()
	local root = self.Root
	if not root then
		return
	end
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("BasePart") then
			self:_applyPart(descendant)
		end
	end
end

function AirWallController:_bindRoot(root)
	if self.Root == root then
		return
	end
	if self.Root then
		self:_unbindRoot()
	end

	self.Root = root
	table.insert(self.RootConnections, root.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			self:_applyPart(descendant)
		end
	end))
	table.insert(self.RootConnections, root.DescendantRemoving:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			self:_restorePart(descendant)
		end
	end))
	self:_refreshAllParts()
end

function AirWallController:_unbindRoot()
	for _, connection in self.RootConnections do
		connection:Disconnect()
	end
	table.clear(self.RootConnections)

	local trackedParts = {}
	for part in self.OriginalCanCollide do
		table.insert(trackedParts, part)
	end
	for _, part in trackedParts do
		self:_restorePart(part)
	end
	self.Root = nil
end

return AirWallController

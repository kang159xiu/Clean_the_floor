local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local LostItemGuidanceController = {}

local AREA_COUNT = RegionConfig.AreaCount
local ATTACHMENT_HEIGHT = 1.5
local TARGET_REFRESH_INTERVAL = 0.25

local function copyUnlockedAreas(rawUnlockedAreas)
	local unlockedAreas = {}
	for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
		unlockedAreas[string.format("Area_%02d", areaNumber)] = true
	end
	if type(rawUnlockedAreas) ~= "table" then
		return unlockedAreas
	end
	for areaNumber = 1, AREA_COUNT do
		local areaId = string.format("Area_%02d", areaNumber)
		if rawUnlockedAreas[areaId] == true then
			unlockedAreas[areaId] = true
		end
	end
	return unlockedAreas
end

local function collectAreaTargets(area, targets)
	if not area then
		return
	end
	for _, child in area:GetChildren() do
		if child.Name == "LostItemShop" and child:IsA("Model") then
			local upgrade = child:FindFirstChild("upgrade")
			if upgrade and upgrade:IsA("BasePart") then
				table.insert(targets, upgrade)
			end
		end
	end
end

local function chooseNearestTarget(rootPart, targets)
	local nearestTarget = nil
	local nearestDistance = math.huge
	for _, target in targets do
		local distance = (target.Position - rootPart.Position).Magnitude
		if distance < nearestDistance then
			nearestTarget = target
			nearestDistance = distance
		end
	end
	return nearestTarget
end

function LostItemGuidanceController:Init(remotes, areaDoorController, poopController)
	self.Player = Players.LocalPlayer
	self.AreaDoorController = areaDoorController
	self.PoopController = poopController
	self.BeamTemplate = ReplicatedStorage:WaitForChild("yindaoxian")
	assert(self.BeamTemplate:IsA("Beam"), "ReplicatedStorage.yindaoxian must be a Beam")

	local oldEffectsFolder = Workspace:FindFirstChild("LocalLostItemGuidanceEffects")
	if oldEffectsFolder then
		oldEffectsFolder:Destroy()
	end
	local effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "LocalLostItemGuidanceEffects"
	effectsFolder.Parent = Workspace
	self.EffectsFolder = effectsFolder

	self.CarriedLostItem = nil
	self.CurrentAreaId = "Area_01"
	self.CollectibleInventoryTotal = 0
	self.UnlockedAreas = copyUnlockedAreas(nil)
	self.TargetRefreshElapsed = 0
	self.TutorialPoopStage = nil
	self.TutorialPoopSpawnId = nil
	self.BroomGuidanceActive = false
	self.ActiveRootPart = nil
	self.ActiveTargetPart = nil
	self.SourceAttachment = nil
	self.TargetAttachment = nil
	self.Beam = nil
	if self.AreaDoorController then
		self.AreaDoorController:ConnectGuidanceActiveChanged(function()
			self:_refresh()
		end)
	end

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self.UnlockedAreas = copyUnlockedAreas(snapshot.UnlockedAreas)
		if type(snapshot.CurrentAreaId) == "string" then
			self.CurrentAreaId = snapshot.CurrentAreaId
		end
		self.CollectibleInventoryTotal = math.max(
			0,
			math.floor(tonumber(snapshot.CollectibleInventoryTotal) or 0)
		)
		self.CarriedLostItem = type(snapshot.CarriedLostItem) == "table"
			and snapshot.CarriedLostItem
			or nil
		local tutorialState = type(snapshot.TutorialState) == "table" and snapshot.TutorialState or nil
		local tutorialStage = tutorialState and tutorialState.PoopGuidanceStage or nil
		self.TutorialPoopStage = if tutorialStage == "Pickup" or tutorialStage == "Sell"
			then tutorialStage
			else nil
		self.TutorialPoopSpawnId = tutorialState and tutorialState.PoopGuidanceSpawnId or nil
		self.BroomGuidanceActive = tutorialState ~= nil
			and tutorialState.TargetKind == "BroomPurchase"
			and tutorialState.TargetReady == true
		self.TargetRefreshElapsed = 0
		self:_refresh()
	end)

	RunService.Heartbeat:Connect(function(deltaTime)
		if not self.CarriedLostItem and self.TutorialPoopStage == nil then
			self.TargetRefreshElapsed = 0
			return
		end
		self.TargetRefreshElapsed += deltaTime
		if self.TargetRefreshElapsed < TARGET_REFRESH_INTERVAL then
			return
		end
		self.TargetRefreshElapsed %= TARGET_REFRESH_INTERVAL
		self:_refresh()
	end)

	self.Player.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
	self.Player.CharacterRemoving:Connect(function()
		self:_destroyBeam()
	end)
	if self.Player.Character then
		self:_bindCharacter(self.Player.Character)
	end
end

function LostItemGuidanceController:_shouldShowGuidance()
	if self.BroomGuidanceActive then
		return false
	end
	if self.TutorialPoopStage == "Pickup" then
		return type(self.TutorialPoopSpawnId) == "string"
	elseif self.TutorialPoopStage == "Sell" then
		return self.CarriedLostItem ~= nil
	end
	if not self.CarriedLostItem then
		return false
	end
	if self.CarriedLostItem.SourceAreaId == LeafConfig.Lobby.AreaId then
		return true
	end
	if self.CurrentAreaId == "Area_01" then
		return true
	end
	local areaNumber = tonumber(string.match(self.CurrentAreaId or "", "^Area_(%d%d)$"))
	return areaNumber ~= nil
		and areaNumber >= 2
		and areaNumber <= AREA_COUNT
		and self.CollectibleInventoryTotal > 7
end

function LostItemGuidanceController:_bindCharacter(character)
	self:_destroyBeam()
	if self.HumanoidDiedConnection then
		self.HumanoidDiedConnection:Disconnect()
		self.HumanoidDiedConnection = nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		self.HumanoidDiedConnection = humanoid.Died:Connect(function()
			self:_destroyBeam()
		end)
	end
	character:WaitForChild("HumanoidRootPart", 5)
	self:_refresh()
end

function LostItemGuidanceController:_getRootPart()
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

function LostItemGuidanceController:_getTargetPart(rootPart)
	if self.TutorialPoopStage == "Pickup" then
		return self.PoopController and self.PoopController:GetGuidanceTarget(self.TutorialPoopSpawnId) or nil
	elseif self.TutorialPoopStage == "Sell" then
		local tutorialTargets = {}
		collectAreaTargets(
			Workspace:FindFirstChild(LeafConfig.Lobby.ContainerName),
			tutorialTargets
		)
		for areaNumber = 1, AREA_COUNT do
			local areaId = string.format("Area_%02d", areaNumber)
			if self.UnlockedAreas[areaId] == true then
				collectAreaTargets(Workspace:FindFirstChild(areaId), tutorialTargets)
			end
		end
		return chooseNearestTarget(rootPart, tutorialTargets)
	end
	local carriedLostItem = self.CarriedLostItem
	if not carriedLostItem then
		return nil
	end

	local sourceTargets = {}
	local sourceAreaId = carriedLostItem.SourceAreaId
	if sourceAreaId == LeafConfig.Lobby.AreaId then
		collectAreaTargets(Workspace:FindFirstChild(LeafConfig.Lobby.ContainerName), sourceTargets)
	elseif type(sourceAreaId) == "string" and self.UnlockedAreas[sourceAreaId] == true then
		collectAreaTargets(Workspace:FindFirstChild(sourceAreaId), sourceTargets)
	end
	local sourceTarget = chooseNearestTarget(rootPart, sourceTargets)
	if sourceTarget then
		return sourceTarget
	end

	local fallbackTargets = {}
	collectAreaTargets(Workspace:FindFirstChild(LeafConfig.Lobby.ContainerName), fallbackTargets)
	for areaNumber = 1, AREA_COUNT do
		local areaId = string.format("Area_%02d", areaNumber)
		if self.UnlockedAreas[areaId] == true then
			collectAreaTargets(Workspace:FindFirstChild(areaId), fallbackTargets)
		end
	end
	return chooseNearestTarget(rootPart, fallbackTargets)
end

function LostItemGuidanceController:_destroyBeam()
	if self.Beam then
		self.Beam:Destroy()
	end
	if self.SourceAttachment then
		self.SourceAttachment:Destroy()
	end
	if self.TargetAttachment then
		self.TargetAttachment:Destroy()
	end
	self.Beam = nil
	self.SourceAttachment = nil
	self.TargetAttachment = nil
	self.ActiveRootPart = nil
	self.ActiveTargetPart = nil
end

function LostItemGuidanceController:_showBeam(rootPart, targetPart)
	if
		self.Beam
		and self.Beam.Parent
		and self.ActiveRootPart == rootPart
		and self.ActiveTargetPart == targetPart
	then
		self.Beam.Enabled = true
		return
	end

	self:_destroyBeam()
	local sourceAttachment = Instance.new("Attachment")
	sourceAttachment.Name = "LocalLostItemGuidanceSource"
	sourceAttachment.Position = Vector3.new(0, ATTACHMENT_HEIGHT, 0)
	sourceAttachment.Parent = rootPart

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "LocalLostItemGuidanceTarget"
	targetAttachment.Position = Vector3.new(0, ATTACHMENT_HEIGHT, 0)
	targetAttachment.Parent = targetPart

	local beam = self.BeamTemplate:Clone()
	beam.Name = "LocalLostItemGuidanceBeam"
	beam.Attachment0 = sourceAttachment
	beam.Attachment1 = targetAttachment
	beam.Enabled = true
	beam.Parent = self.EffectsFolder

	self.ActiveRootPart = rootPart
	self.ActiveTargetPart = targetPart
	self.SourceAttachment = sourceAttachment
	self.TargetAttachment = targetAttachment
	self.Beam = beam
end

function LostItemGuidanceController:_refresh()
	if self.AreaDoorController and self.AreaDoorController:IsGuidanceActive() then
		self:_destroyBeam()
		return
	end
	if not self:_shouldShowGuidance() then
		self:_destroyBeam()
		return
	end
	local rootPart = self:_getRootPart()
	local targetPart = rootPart and self:_getTargetPart(rootPart) or nil
	if not rootPart or not targetPart then
		self:_destroyBeam()
		return
	end
	self:_showBeam(rootPart, targetPart)
end

return LostItemGuidanceController

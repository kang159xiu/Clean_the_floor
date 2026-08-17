local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local RecycleGuidanceController = {}
local ATTACHMENT_HEIGHT = 1.5
local AREA_COUNT = RegionConfig.AreaCount
local TARGET_REFRESH_INTERVAL = 0.25

function RecycleGuidanceController:Init(remotes, toolController, hudController, areaDoorController)
	self.Player = Players.LocalPlayer
	self.ToolController = toolController
	self.HUDController = hudController
	self.AreaDoorController = areaDoorController
	self.BeamTemplate = ReplicatedStorage:WaitForChild("yindaoxian")
	assert(self.BeamTemplate:IsA("Beam"), "ReplicatedStorage.yindaoxian must be a Beam")
	local effectsFolder = Workspace:FindFirstChild("LocalRecycleGuidanceEffects")
	if not effectsFolder then
		effectsFolder = Instance.new("Folder")
		effectsFolder.Name = "LocalRecycleGuidanceEffects"
		effectsFolder.Parent = Workspace
	end
	assert(effectsFolder:IsA("Folder"), "Workspace.LocalRecycleGuidanceEffects must be a Folder")
	self.EffectsFolder = effectsFolder
	self.BagFull = false
	self.PurchaseGuidanceActive = false
	self.PickupInputActive = toolController:IsPickupInputActive()
	self.UnlockedAreas = {}
	for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
		self.UnlockedAreas[string.format("Area_%02d", areaNumber)] = true
	end
	self.TargetRefreshElapsed = 0
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

	toolController:ConnectPickupInputChanged(function(active)
		self.PickupInputActive = active == true
		self:_refreshHoldFeedback()
	end)

	remotes.StateSnapshotStore:Connect(function(snapshot)
		local bagFull = snapshot.BagFull == true
		self.BagFull = bagFull
		local tutorialState = snapshot.TutorialState
		self.PurchaseGuidanceActive = type(tutorialState) == "table"
			and (tutorialState.TargetKind == "BagUpgrade" or tutorialState.TargetKind == "BroomPurchase")
			and tutorialState.TargetReady == true
		self.UnlockedAreas = snapshot.UnlockedAreas
		self.TargetRefreshElapsed = 0
		self:_refresh()
		self:_refreshHoldFeedback()
	end)
	RunService.Heartbeat:Connect(function(deltaTime)
		if not self.BagFull then
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
		self.HUDController:SetBagFullHoldFeedbackActive(false)
	end)
	Workspace.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "Recycle_01" then
			self:_refresh()
		end
	end)
	if self.Player.Character then
		self:_bindCharacter(self.Player.Character)
	end
end

function RecycleGuidanceController:_bindCharacter(character)
	self:_destroyBeam()
	if self.HumanoidDiedConnection then
		self.HumanoidDiedConnection:Disconnect()
		self.HumanoidDiedConnection = nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		self.HumanoidDiedConnection = humanoid.Died:Connect(function()
			self:_destroyBeam()
			self.HUDController:SetBagFullHoldFeedbackActive(false)
		end)
	end
	character:WaitForChild("HumanoidRootPart", 5)
	self:_refresh()
	self:_refreshHoldFeedback()
end

function RecycleGuidanceController:_refreshHoldFeedback()
	self.HUDController:SetBagFullHoldFeedbackActive(
		self.BagFull
			and self.PickupInputActive
			and self:_getRootPart() ~= nil
	)
end

function RecycleGuidanceController:_getTargetPart(rootPart)
	local nearestPart = nil
	local nearestDistance = math.huge
	local function considerContainer(container)
		local recycle = container and container:FindFirstChild("Recycle_01")
		if recycle and recycle:IsA("BasePart") then
			local distance = (recycle.Position - rootPart.Position).Magnitude
			if distance < nearestDistance then
				nearestPart = recycle
				nearestDistance = distance
			end
		end
	end

	considerContainer(Workspace:FindFirstChild(LeafConfig.Lobby.ContainerName))
	for areaNumber = 1, AREA_COUNT do
		local areaId = string.format("Area_%02d", areaNumber)
		if self.UnlockedAreas[areaId] == true then
			considerContainer(Workspace:FindFirstChild(areaId))
		end
	end
	return nearestPart
end

function RecycleGuidanceController:_getRootPart()
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		humanoid
		and humanoid.Health > 0
		and rootPart
		and rootPart:IsA("BasePart")
	then
		return rootPart
	end
	return nil
end

function RecycleGuidanceController:_destroyBeam()
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

function RecycleGuidanceController:_showBeam(rootPart, targetPart)
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
	sourceAttachment.Name = "LocalRecycleGuidanceSource"
	sourceAttachment.Position = Vector3.new(0, ATTACHMENT_HEIGHT, 0)
	sourceAttachment.Parent = rootPart

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "LocalRecycleGuidanceTarget"
	targetAttachment.Position = Vector3.new(0, ATTACHMENT_HEIGHT, 0)
	targetAttachment.Parent = targetPart

	local beam = self.BeamTemplate:Clone()
	beam.Name = "LocalRecycleGuidanceBeam"
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

function RecycleGuidanceController:_refresh()
	if self.AreaDoorController and self.AreaDoorController:IsGuidanceActive() then
		self:_destroyBeam()
		return
	end
	local rootPart = self:_getRootPart()
	local targetPart = rootPart and self:_getTargetPart(rootPart) or nil
	local shouldShow = self.BagFull
		and not self.PurchaseGuidanceActive
		and rootPart ~= nil
		and targetPart ~= nil

	if not shouldShow then
		self:_destroyBeam()
		return
	end

	self:_showBeam(rootPart, targetPart)
end

return RecycleGuidanceController

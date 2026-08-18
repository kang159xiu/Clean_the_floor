local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local AreaUnlockConfig = require(ReplicatedStorage.Shared.Config.AreaUnlockConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local AreaDoorController = {}

local TOUCH_REQUEST_COOLDOWN = 2.25
local DEFAULT_DOOR_OPEN_ROTATION_DEGREES = 90
local DOOR_OPEN_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GUIDANCE_SOURCE_HEIGHT = 1.5
local GUIDANCE_REFRESH_INTERVAL = 0.25

local function getOpenPivot(closedPivot, configuredAngle)
	local rotationX, rotationY, rotationZ = closedPivot:ToOrientation()
	local openRotationY = rotationY + math.rad(DEFAULT_DOOR_OPEN_ROTATION_DEGREES)
	if
		type(configuredAngle) == "number"
		and configuredAngle == configuredAngle
		and math.abs(configuredAngle) < math.huge
	then
		openRotationY = math.rad(configuredAngle)
	end
	return CFrame.new(closedPivot.Position)
		* CFrame.fromOrientation(rotationX, openRotationY, rotationZ)
end

function AreaDoorController:Init(remotes)
	self.Remotes = remotes
	self.Player = Players.LocalPlayer
	self.BeamTemplate = ReplicatedStorage:WaitForChild("yindaoxian")
	assert(self.BeamTemplate:IsA("Beam"), "ReplicatedStorage.yindaoxian must be a Beam")
	local oldEffectsFolder = Workspace:FindFirstChild("LocalAreaDoorGuidanceEffects")
	if oldEffectsFolder then
		oldEffectsFolder:Destroy()
	end
	local effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "LocalAreaDoorGuidanceEffects"
	effectsFolder.Parent = Workspace
	self.EffectsFolder = effectsFolder
	self.UnlockedAreas = {}
	for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
		self.UnlockedAreas[string.format("Area_%02d", areaNumber)] = true
	end
	self.HomeYardProgress = nil
	self.IsVisitingYard = false
	self.RebirthCount = 0
	self.EligibleTargetAreaId = nil
	self.Bindings = {}
	self.BoundDoorRoots = {}
	self.MissingPriceUIWarnings = {}
	self.TouchRequestTimes = {}
	self.HasReceivedSnapshot = false
	self.GuidanceRefreshElapsed = 0
	self.ActiveGuidanceRootPart = nil
	self.ActiveGuidanceTargetPart = nil
	self.GuidanceSourceAttachment = nil
	self.GuidanceTargetAttachment = nil
	self.GuidanceBeam = nil
	self.GuidanceActive = false
	self.GuidanceActiveChanged = Instance.new("BindableEvent")

	remotes.StateSnapshotStore:Connect(function(snapshot)
		if type(snapshot) ~= "table" or type(snapshot.UnlockedAreas) ~= "table" then
			return
		end
		self.UnlockedAreas = snapshot.UnlockedAreas
		self.HomeYardProgress = type(snapshot.HomeYardProgress) == "table"
			and snapshot.HomeYardProgress
			or nil
		self.IsVisitingYard = snapshot.IsVisitingYard == true
		self.RebirthCount = math.max(0, math.floor(tonumber(snapshot.RebirthCount) or 0))
		self:_refreshAllDoors(self.HasReceivedSnapshot)
		self:_refreshEligibleTargetAreaId()
		self.GuidanceRefreshElapsed = 0
		self:_refreshGuidance()
		self.HasReceivedSnapshot = true
	end)

	RunService.Heartbeat:Connect(function(deltaTime)
		if not self.EligibleTargetAreaId then
			self.GuidanceRefreshElapsed = 0
			return
		end
		self.GuidanceRefreshElapsed += deltaTime
		if self.GuidanceRefreshElapsed < GUIDANCE_REFRESH_INTERVAL then
			return
		end
		self.GuidanceRefreshElapsed %= GUIDANCE_REFRESH_INTERVAL
		self:_refreshGuidance()
	end)
	self.Player.CharacterAdded:Connect(function(character)
		self:_bindGuidanceCharacter(character)
	end)
	self.Player.CharacterRemoving:Connect(function()
		self:_destroyGuidance()
	end)

	for _, areaId in RegionConfig.Order do
		local area = Workspace:FindFirstChild(areaId)
		if area then
			self:_bindArea(area)
		end
	end
	Workspace.ChildAdded:Connect(function(child)
		if child:IsA("Folder") and RegionConfig.IsActiveAreaId(child.Name) then
			self:_bindArea(child)
		end
	end)
	if self.Player.Character then
		self:_bindGuidanceCharacter(self.Player.Character)
	end
end

function AreaDoorController:IsGuidanceActive()
	return self.GuidanceActive == true
end

function AreaDoorController:ConnectGuidanceActiveChanged(callback)
	return self.GuidanceActiveChanged.Event:Connect(callback)
end

function AreaDoorController:_setGuidanceActive(active)
	active = active == true
	if self.GuidanceActive == active then
		return
	end
	self.GuidanceActive = active
	self.GuidanceActiveChanged:Fire(active)
end

function AreaDoorController:_clearGuidanceInstances()
	if self.GuidanceBeam then
		self.GuidanceBeam:Destroy()
	end
	if self.GuidanceSourceAttachment then
		self.GuidanceSourceAttachment:Destroy()
	end
	if self.GuidanceTargetAttachment then
		self.GuidanceTargetAttachment:Destroy()
	end
	self.GuidanceBeam = nil
	self.GuidanceSourceAttachment = nil
	self.GuidanceTargetAttachment = nil
	self.ActiveGuidanceRootPart = nil
	self.ActiveGuidanceTargetPart = nil
end

function AreaDoorController:_destroyGuidance()
	self:_clearGuidanceInstances()
	self:_setGuidanceActive(false)
end

function AreaDoorController:_getGuidanceRootPart()
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

function AreaDoorController:_bindGuidanceCharacter(character)
	self:_destroyGuidance()
	if self.GuidanceHumanoidDiedConnection then
		self.GuidanceHumanoidDiedConnection:Disconnect()
		self.GuidanceHumanoidDiedConnection = nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		self.GuidanceHumanoidDiedConnection = humanoid.Died:Connect(function()
			self:_destroyGuidance()
		end)
	end
	character:WaitForChild("HumanoidRootPart", 5)
	self:_refreshGuidance()
end

function AreaDoorController:_getEligibleTargetAreaId()
	if self.IsVisitingYard or type(self.HomeYardProgress) ~= "table" then
		return nil
	end
	local areas = type(self.HomeYardProgress.Areas) == "table"
		and self.HomeYardProgress.Areas
		or {}
	for _, targetAreaId in AreaUnlockConfig.Order do
		if self.UnlockedAreas[targetAreaId] ~= true then
			local config = AreaUnlockConfig.Areas[targetAreaId]
			if AreaUnlockConfig.IsClearRequirementMet(config, areas) then
				return targetAreaId
			end
		end
	end
	return nil
end

function AreaDoorController:_refreshEligibleTargetAreaId()
	local targetAreaId = self:_getEligibleTargetAreaId()
	if self.EligibleTargetAreaId ~= targetAreaId then
		self.EligibleTargetAreaId = targetAreaId
		self.GuidanceRefreshElapsed = 0
	end
end

function AreaDoorController:_getNearestGuidanceTarget(rootPart)
	local nearestPart = nil
	local nearestDistance = math.huge
	for model, binding in self.Bindings do
		if
			model.Parent
			and binding.Config.TargetAreaId == self.EligibleTargetAreaId
			and binding.IsUnlocked ~= true
			and binding.Part.Parent
		then
			local distance = (binding.Part.Position - rootPart.Position).Magnitude
			if distance < nearestDistance then
				nearestPart = binding.Part
				nearestDistance = distance
			end
		end
	end
	return nearestPart
end

function AreaDoorController:_showGuidance(rootPart, targetPart)
	if
		self.GuidanceBeam
		and self.GuidanceBeam.Parent
		and self.ActiveGuidanceRootPart == rootPart
		and self.ActiveGuidanceTargetPart == targetPart
	then
		self.GuidanceBeam.Enabled = true
		self:_setGuidanceActive(true)
		return
	end

	self:_clearGuidanceInstances()
	local sourceAttachment = Instance.new("Attachment")
	sourceAttachment.Name = "LocalAreaDoorGuidanceSource"
	sourceAttachment.Position = Vector3.new(0, GUIDANCE_SOURCE_HEIGHT, 0)
	sourceAttachment.Parent = rootPart

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "LocalAreaDoorGuidanceTarget"
	targetAttachment.Parent = targetPart

	local beam = self.BeamTemplate:Clone()
	beam.Name = "LocalAreaDoorGuidanceBeam"
	beam.Attachment0 = sourceAttachment
	beam.Attachment1 = targetAttachment
	beam.Enabled = true
	beam.Parent = self.EffectsFolder

	self.ActiveGuidanceRootPart = rootPart
	self.ActiveGuidanceTargetPart = targetPart
	self.GuidanceSourceAttachment = sourceAttachment
	self.GuidanceTargetAttachment = targetAttachment
	self.GuidanceBeam = beam
	self:_setGuidanceActive(true)
end

function AreaDoorController:_refreshGuidance()
	local rootPart = self:_getGuidanceRootPart()
	local targetPart = rootPart and self:_getNearestGuidanceTarget(rootPart) or nil
	if not self.EligibleTargetAreaId or not rootPart or not targetPart then
		self:_destroyGuidance()
		return
	end
	self:_showGuidance(rootPart, targetPart)
end

function AreaDoorController:_bindArea(area)
	local doorRoot = area:FindFirstChild("Door")
	if doorRoot then
		self:_bindDoorRoot(doorRoot)
	end
	area.ChildAdded:Connect(function(child)
		if child.Name == "Door" then
			self:_bindDoorRoot(child)
		end
	end)
end

function AreaDoorController:_bindDoorRoot(doorRoot)
	if self.BoundDoorRoots[doorRoot] then
		return
	end
	self.BoundDoorRoots[doorRoot] = true

	for _, child in doorRoot:GetChildren() do
		if child:IsA("Model") then
			self:_bindDoorModel(child, doorRoot)
		end
	end
	doorRoot.ChildAdded:Connect(function(child)
		if child:IsA("Model") then
			self:_bindDoorModel(child, doorRoot)
		end
	end)
end

function AreaDoorController:_bindDoorModel(doorModel, doorRoot)
	if self.Bindings[doorModel] or doorModel.Parent ~= doorRoot then
		return
	end
	local config = AreaUnlockConfig.ByDoorModelName[doorModel.Name]
	if not config then
		return
	end

	local doorPart = doorModel:FindFirstChild("Door01")
	local surfaceGui = doorPart and doorPart:FindFirstChild("SurfaceGui")
	local frame = surfaceGui and surfaceGui:FindFirstChild("Frame")
	local button = frame and frame:FindFirstChild("ImageButton")
	local textLabel = button and button:FindFirstChild("TextLabel")
	local priceFrame = surfaceGui and surfaceGui:FindFirstChild("rebirth")
	local priceImage = priceFrame and priceFrame:FindFirstChild("ImageLabel")
	local priceLabel = priceImage and priceImage:FindFirstChild("x1")
	if
		not doorPart
		or not doorPart:IsA("BasePart")
		or not surfaceGui
		or not surfaceGui:IsA("SurfaceGui")
		or not button
		or not button:IsA("ImageButton")
		or not textLabel
		or not textLabel:IsA("TextLabel")
	then
		return
	end
	if
		not priceFrame
		or not priceFrame:IsA("GuiObject")
		or not priceImage
		or not priceImage:IsA("ImageLabel")
		or not priceLabel
		or not priceLabel:IsA("TextLabel")
	then
		local warningKey = doorModel:GetFullName()
		if not self.MissingPriceUIWarnings[warningKey] then
			self.MissingPriceUIWarnings[warningKey] = true
			warn(warningKey .. ".Door01.SurfaceGui.rebirth.ImageLabel.x1 is missing or invalid")
		end
		priceFrame = nil
		priceImage = nil
		priceLabel = nil
	end

	local binding = {
		Model = doorModel,
		Part = doorPart,
		SurfaceGui = surfaceGui,
		Button = button,
		TextLabel = textLabel,
		PriceFrame = priceFrame,
		PriceImage = priceImage,
		PriceLabel = priceLabel,
		Config = config,
		ExpectedParent = doorRoot,
		Panels = {},
		OpenAlpha = 0,
		IsUnlocked = nil,
		OriginalColor = doorPart.Color,
		OriginalTransparency = doorPart.Transparency,
		OriginalCanCollide = doorPart.CanCollide,
		OriginalCanTouch = doorPart.CanTouch,
		OriginalCanQuery = doorPart.CanQuery,
		OriginalSurfaceGuiEnabled = surfaceGui.Enabled,
	}
	for _, panelName in { "MB01", "MB02" } do
		local panel = doorModel:FindFirstChild(panelName)
		if panel and panel:IsA("Model") then
			local closedPivot = panel:GetPivot()
			table.insert(binding.Panels, {
				Model = panel,
				ClosedPivot = closedPivot,
				OpenPivot = getOpenPivot(closedPivot, panel:GetAttribute("angle")),
			})
		end
	end
	self.Bindings[doorModel] = binding
	binding.DoorTouchedConnection = doorPart.Touched:Connect(function(hit)
		self:_handleDoorTouched(binding, hit)
	end)
	binding.AncestryChangedConnection = doorModel.AncestryChanged:Connect(function()
		if doorModel.Parent ~= binding.ExpectedParent then
			self:_cleanupDoorBinding(doorModel, binding)
		end
	end)
	binding.DestroyingConnection = doorModel.Destroying:Connect(function()
		self:_cleanupDoorBinding(doorModel, binding)
	end)

	self:_applyDoorState(binding, false)
	self:_refreshGuidance()
end

function AreaDoorController:_cleanupDoorBinding(doorModel, binding)
	if self.Bindings[doorModel] ~= binding then
		return
	end
	self.Bindings[doorModel] = nil
	self:_cancelDoorAnimation(binding)

	for _, connectionName in {
		"DoorTouchedConnection",
		"AncestryChangedConnection",
		"DestroyingConnection",
	} do
		local connection = binding[connectionName]
		binding[connectionName] = nil
		if connection then
			connection:Disconnect()
		end
	end

	task.defer(function()
		self:_refreshGuidance()
	end)
end

function AreaDoorController:_applyDoorOpenAlpha(binding, alpha)
	binding.OpenAlpha = math.clamp(alpha, 0, 1)
	for _, panelBinding in binding.Panels do
		if panelBinding.Model.Parent then
			panelBinding.Model:PivotTo(
				panelBinding.ClosedPivot:Lerp(panelBinding.OpenPivot, binding.OpenAlpha)
			)
		end
	end
end

function AreaDoorController:_cancelDoorAnimation(binding)
	local tween = binding.ActiveTween
	local changedConnection = binding.TweenChangedConnection
	local completedConnection = binding.TweenCompletedConnection
	local driver = binding.TweenDriver
	binding.ActiveTween = nil
	binding.TweenChangedConnection = nil
	binding.TweenCompletedConnection = nil
	binding.TweenDriver = nil
	if changedConnection then
		changedConnection:Disconnect()
	end
	if completedConnection then
		completedConnection:Disconnect()
	end
	if tween then
		tween:Cancel()
	end
	if driver then
		driver:Destroy()
	end
end

function AreaDoorController:_setDoorOpenAlpha(binding, alpha)
	self:_cancelDoorAnimation(binding)
	self:_applyDoorOpenAlpha(binding, alpha)
end

function AreaDoorController:_animateDoorOpen(binding)
	self:_cancelDoorAnimation(binding)
	if #binding.Panels == 0 then
		self:_applyDoorOpenAlpha(binding, 1)
		return
	end

	local driver = Instance.new("NumberValue")
	driver.Value = binding.OpenAlpha
	local tween = TweenService:Create(driver, DOOR_OPEN_TWEEN_INFO, { Value = 1 })
	binding.TweenDriver = driver
	binding.ActiveTween = tween
	binding.TweenChangedConnection = driver:GetPropertyChangedSignal("Value"):Connect(function()
		self:_applyDoorOpenAlpha(binding, driver.Value)
	end)
	binding.TweenCompletedConnection = tween.Completed:Connect(function()
		if binding.ActiveTween ~= tween then
			return
		end
		self:_cancelDoorAnimation(binding)
		self:_applyDoorOpenAlpha(binding, 1)
	end)
	tween:Play()
end

function AreaDoorController:_requestUnlock(config)
	if self.UnlockedAreas[config.TargetAreaId] ~= true then
		self.Remotes.RequestAreaUnlock:FireServer(config.TargetAreaId)
	end
end

function AreaDoorController:_handleDoorTouched(binding, hit)
	if self.UnlockedAreas[binding.Config.TargetAreaId] == true or not hit:IsA("BasePart") then
		return
	end

	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if
		not character
		or not humanoid
		or humanoid.Health <= 0
		or not hit:IsDescendantOf(character)
		or hit:FindFirstAncestorWhichIsA("Tool")
		or hit:FindFirstAncestorWhichIsA("Accessory")
	then
		return
	end

	local targetAreaId = binding.Config.TargetAreaId
	local now = os.clock()
	if now - (self.TouchRequestTimes[targetAreaId] or -math.huge) < TOUCH_REQUEST_COOLDOWN then
		return
	end
	self.TouchRequestTimes[targetAreaId] = now
	self:_requestUnlock(binding.Config)
end

function AreaDoorController:_applyDoorState(binding, allowAnimation)
	local unlocked = self.UnlockedAreas[binding.Config.TargetAreaId] == true
	local targetAreaName = RegionConfig[binding.Config.TargetAreaId].DisplayName
	local unlockPrice = AreaUnlockConfig.GetUnlockPrice(binding.Config, self.RebirthCount)
	if binding.PriceFrame and binding.PriceFrame.Parent then
		binding.PriceFrame.Visible = not unlocked
		binding.PriceImage.Image = AreaUnlockConfig.CoinImage
		binding.PriceLabel.Text = "x" .. CoinFormat.Compact(unlockPrice)
	end
	local stateChanged = binding.IsUnlocked ~= unlocked
	local shouldAnimate = allowAnimation
		and stateChanged
		and binding.IsUnlocked == false
		and unlocked
	binding.IsUnlocked = unlocked
	if unlocked then
		binding.Part.Transparency = 1
		binding.Part.CanCollide = false
		binding.Part.CanTouch = false
		binding.Part.CanQuery = false
		binding.SurfaceGui.Enabled = false
		binding.TextLabel.Text = targetAreaName
		binding.Button.Active = false
		binding.Button.Interactable = false
		if stateChanged then
			if shouldAnimate then
				self:_animateDoorOpen(binding)
			else
				self:_setDoorOpenAlpha(binding, 1)
			end
		end
	else
		binding.Part.Color = binding.OriginalColor
		binding.Part.Transparency = binding.OriginalTransparency
		binding.Part.CanCollide = binding.OriginalCanCollide
		binding.Part.CanTouch = binding.OriginalCanTouch
		binding.Part.CanQuery = binding.OriginalCanQuery
		binding.SurfaceGui.Enabled = binding.OriginalSurfaceGuiEnabled
		binding.TextLabel.Text = "Unlock " .. targetAreaName
		binding.Button.Active = false
		binding.Button.Interactable = false
		if stateChanged then
			self:_setDoorOpenAlpha(binding, 0)
		end
	end
end

function AreaDoorController:_refreshAllDoors(allowAnimation)
	for model, binding in self.Bindings do
		if model.Parent then
			self:_applyDoorState(binding, allowAnimation)
		else
			self:_cancelDoorAnimation(binding)
			self.Bindings[model] = nil
		end
	end
end

return AreaDoorController

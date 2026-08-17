local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local HarvestGeometry = require(ReplicatedStorage.Shared.HarvestGeometry)

local HarvestRangeController = {}

local CLEANING_TOOL_ATTRIBUTE = "CleaningToolId"
local HARVEST_RANGE_RENDER_BINDING = "CleanFloorHarvestRange"
local COLLECT_AIM_UPDATE_INTERVAL = 0.02
local PUSH_TOOL_AIM_UPDATE_INTERVAL = 0.05
local GROUND_GAP = 0.02
local RANGE_VISUAL_HEIGHT_OFFSET = 0
local DIRECTION_GUIDE_GROUND_GAP = 0.1
local DIRECTION_GUIDE_MIN_DISTANCE = 0.05
local PARKED_CFRAME = CFrame.new()

local function getPerpendicularUp(direction, preferredUp)
	local projectedUp = preferredUp - direction * preferredUp:Dot(direction)
	if projectedUp.Magnitude < 0.001 then
		local fallbackUp = if math.abs(direction:Dot(Vector3.yAxis)) < 0.999
			then Vector3.yAxis
			else Vector3.zAxis
		projectedUp = fallbackUp - direction * fallbackUp:Dot(direction)
	end
	return projectedUp.Unit
end

local function getVerticalAxis(rotation)
	local xAlignment = math.abs(rotation.RightVector.Y)
	local yAlignment = math.abs(rotation.UpVector.Y)
	local zAlignment = math.abs(rotation.LookVector.Y)
	if xAlignment >= yAlignment and xAlignment >= zAlignment then
		return "X"
	elseif yAlignment >= zAlignment then
		return "Y"
	end
	return "Z"
end

local function getPlaneDiameter(size, verticalAxis)
	if verticalAxis == "X" then
		return math.max(size.Y, size.Z)
	elseif verticalAxis == "Y" then
		return math.max(size.X, size.Z)
	end
	return math.max(size.X, size.Y)
end

local function sizeForRadius(originalSize, verticalAxis, baseDiameter, radius)
	local scale = radius * 2 / baseDiameter
	if verticalAxis == "X" then
		return Vector3.new(originalSize.X, originalSize.Y * scale, originalSize.Z * scale)
	elseif verticalAxis == "Y" then
		return Vector3.new(originalSize.X * scale, originalSize.Y, originalSize.Z * scale)
	end
	return Vector3.new(originalSize.X * scale, originalSize.Y * scale, originalSize.Z)
end

local function getThickness(size, verticalAxis)
	if verticalAxis == "X" then
		return size.X
	elseif verticalAxis == "Y" then
		return size.Y
	end
	return size.Z
end

function HarvestRangeController:Init(remotes, cameraController, toolController)
	self.Remotes = remotes
	self.CameraController = cameraController
	self.ToolController = toolController
	self.Player = Players.LocalPlayer
	self.PlayerCentered = cameraController:IsTouchPrimary()
	self.HarvestRadius = 0
	self.EffectiveHarvestRadius = 0
	self.ForwardOffset = 0
	self.EquippedToolId = nil
	self.ToolBehavior = nil
	self.InnerRangeRatio = 0
	self.CurrentAimPosition = nil
	self.LastAimUpdateTime = 0
	self.AimValidSent = false

	local template = ReplicatedStorage.Model.MagneticRange.MagneticRange
	assert(template:IsA("BasePart"), "Model.MagneticRange.MagneticRange must be a BasePart")
	local templateDecal = template:FindFirstChild("Decal")
	assert(templateDecal and templateDecal:IsA("Decal"), "MagneticRange.MagneticRange.Decal must be a Decal")
	local templateSurfaceGui = template:FindFirstChild("SurfaceGui")
	assert(
		templateSurfaceGui and templateSurfaceGui:IsA("SurfaceGui"),
		"MagneticRange.MagneticRange.SurfaceGui must be a SurfaceGui"
	)
	local templateCenterFrame = templateSurfaceGui:FindFirstChild("Frame")
	assert(
		templateCenterFrame and templateCenterFrame:IsA("GuiObject"),
		"MagneticRange.MagneticRange.SurfaceGui.Frame must be a GuiObject"
	)

	self.OriginalSize = template.Size
	self.OriginalRotation = template.CFrame.Rotation
	self.OriginalDecalTransparency = templateDecal.Transparency
	self.OriginalCenterSurfaceGuiEnabled = templateSurfaceGui.Enabled
	self.OriginalCenterFrameSize = templateCenterFrame.Size
	self.VerticalAxis = getVerticalAxis(self.OriginalRotation)
	self.BaseDiameter = getPlaneDiameter(template.Size, self.VerticalAxis)

	local visual = template:Clone()
	visual.Name = "LocalHarvestRange"
	visual.Anchored = true
	visual.CanCollide = false
	visual.CanTouch = false
	visual.CanQuery = false
	visual.CastShadow = false
	visual.LocalTransparencyModifier = 1
	local visualDecal = visual:FindFirstChild("Decal")
	visualDecal.Transparency = 1
	local visualSurfaceGui = visual:FindFirstChild("SurfaceGui")
	assert(visualSurfaceGui and visualSurfaceGui:IsA("SurfaceGui"), "LocalHarvestRange.SurfaceGui must be a SurfaceGui")
	visualSurfaceGui.Enabled = false
	visual.Parent = Workspace
	self.Visual = visual
	self.VisualDecal = visualDecal
	local innerVisual = template:Clone()
	innerVisual.Name = "LocalHarvestInnerRange"
	innerVisual.Anchored = true
	innerVisual.CanCollide = false
	innerVisual.CanTouch = false
	innerVisual.CanQuery = false
	innerVisual.CastShadow = false
	innerVisual.LocalTransparencyModifier = 1
	local innerVisualDecal = innerVisual:FindFirstChild("Decal")
	innerVisualDecal.Transparency = 1
	local innerVisualSurfaceGui = innerVisual:FindFirstChild("SurfaceGui")
	assert(
		innerVisualSurfaceGui and innerVisualSurfaceGui:IsA("SurfaceGui"),
		"LocalHarvestInnerRange.SurfaceGui must be a SurfaceGui"
	)
	innerVisualSurfaceGui.Enabled = false
	innerVisual.Parent = Workspace
	self.InnerVisual = innerVisual
	self.InnerVisualDecal = innerVisualDecal

	local centerVisual = template:Clone()
	centerVisual.Name = "LocalHarvestRangeCenter"
	centerVisual.Size = self.OriginalSize
	centerVisual.Anchored = true
	centerVisual.CanCollide = false
	centerVisual.CanTouch = false
	centerVisual.CanQuery = false
	centerVisual.CastShadow = false
	centerVisual.LocalTransparencyModifier = 1
	local centerVisualDecal = centerVisual:FindFirstChild("Decal")
	assert(centerVisualDecal and centerVisualDecal:IsA("Decal"), "LocalHarvestRangeCenter.Decal must be a Decal")
	centerVisualDecal.Transparency = 1
	local centerSurfaceGui = centerVisual:FindFirstChild("SurfaceGui")
	assert(
		centerSurfaceGui and centerSurfaceGui:IsA("SurfaceGui"),
		"LocalHarvestRangeCenter.SurfaceGui must be a SurfaceGui"
	)
	local centerFrame = centerSurfaceGui:FindFirstChild("Frame")
	assert(
		centerFrame and centerFrame:IsA("GuiObject"),
		"LocalHarvestRangeCenter.SurfaceGui.Frame must be a GuiObject"
	)
	centerFrame.Size = self.OriginalCenterFrameSize
	centerSurfaceGui.Enabled = false
	centerVisual.Parent = Workspace
	self.CenterVisual = centerVisual
	self.CenterSurfaceGui = centerSurfaceGui
	self.CenterFrame = centerFrame

	local directionGuideTemplate = ReplicatedStorage:WaitForChild("PointTo")
	assert(directionGuideTemplate:IsA("BasePart"), "ReplicatedStorage.PointTo must be a BasePart")
	local templateBeam = directionGuideTemplate:FindFirstChild("Beam")
	local templateAttachment0 = directionGuideTemplate:FindFirstChild("Attachment0")
	local templateAttachment1 = directionGuideTemplate:FindFirstChild("Attachment1")
	assert(templateBeam and templateBeam:IsA("Beam"), "ReplicatedStorage.PointTo.Beam must be a Beam")
	assert(
		templateAttachment0 and templateAttachment0:IsA("Attachment"),
		"ReplicatedStorage.PointTo.Attachment0 must be an Attachment"
	)
	assert(
		templateAttachment1 and templateAttachment1:IsA("Attachment"),
		"ReplicatedStorage.PointTo.Attachment1 must be an Attachment"
	)
	local templateDirection = templateAttachment1.Position - templateAttachment0.Position
	assert(templateDirection.Magnitude > 0.001, "PointTo attachments must not share the same position")
	self.DirectionGuideTemplateDirection = templateDirection.Unit
	local templateUp = getPerpendicularUp(self.DirectionGuideTemplateDirection, Vector3.yAxis)
	self.DirectionGuideTemplateReferenceInverse = CFrame.lookAt(
		Vector3.zero,
		self.DirectionGuideTemplateDirection,
		templateUp
	).Rotation:Inverse()
	self.DirectionGuideGroundOffset = DIRECTION_GUIDE_GROUND_GAP
	self.DirectionGuideAttachment0Rotation = templateAttachment0.CFrame.Rotation
	self.DirectionGuideAttachment1Rotation = templateAttachment1.CFrame.Rotation

	local directionGuide = directionGuideTemplate:Clone()
	directionGuide.Name = "LocalBroomDirectionGuide"
	directionGuide.Anchored = true
	directionGuide.CanCollide = false
	directionGuide.CanTouch = false
	directionGuide.CanQuery = false
	directionGuide.CastShadow = false
	directionGuide.Transparency = 1
	directionGuide.LocalTransparencyModifier = 1
	local directionGuideBeam = directionGuide:FindFirstChild("Beam")
	local directionGuideAttachment0 = directionGuide:FindFirstChild("Attachment0")
	local directionGuideAttachment1 = directionGuide:FindFirstChild("Attachment1")
	directionGuideBeam.Attachment0 = directionGuideAttachment0
	directionGuideBeam.Attachment1 = directionGuideAttachment1
	directionGuideBeam.Enabled = false
	directionGuide.Parent = Workspace
	self.DirectionGuide = directionGuide
	self.DirectionGuideBeam = directionGuideBeam
	self.DirectionGuideAttachment0 = directionGuideAttachment0
	self.DirectionGuideAttachment1 = directionGuideAttachment1
	self:_parkVisuals()

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self.EquippedToolId = snapshot.EquippedToolId
		self:_setToolRange(
			snapshot.HarvestRadius,
			snapshot.HarvestForwardOffset,
			snapshot.ToolBehavior,
			snapshot.ToolStats.InnerRangeRatio or 0
		)
	end)
	self.Player.CharacterRemoving:Connect(function()
		self:_hideVisual()
	end)

	RunService:UnbindFromRenderStep(HARVEST_RANGE_RENDER_BINDING)
	RunService:BindToRenderStep(
		HARVEST_RANGE_RENDER_BINDING,
		Enum.RenderPriority.Camera.Value + 2,
		function()
			self:_updateVisual()
		end
	)
end

function HarvestRangeController:_setToolRange(radius, forwardOffset, toolBehavior, innerRangeRatio)
	if self.ToolBehavior ~= toolBehavior then
		self.LastAimUpdateTime = 0
	end
	self.HarvestRadius = math.max(0, radius)
	self.ForwardOffset = math.max(0, forwardOffset)
	self.EffectiveHarvestRadius = if self.PlayerCentered
		then HarvestGeometry.GetPlayerCenteredRadius(self.HarvestRadius, self.ForwardOffset)
		else self.HarvestRadius
	self.ToolBehavior = toolBehavior
	self.InnerRangeRatio = math.clamp(tonumber(innerRangeRatio) or 0, 0, 1)
	if not self.Visual or self.BaseDiameter <= 0 or self.EffectiveHarvestRadius <= 0 then
		self:_hideVisual()
		return
	end

	if self.SizeTween then
		self.SizeTween:Cancel()
	end
	local targetSize = sizeForRadius(
		self.OriginalSize,
		self.VerticalAxis,
		self.BaseDiameter,
		self.EffectiveHarvestRadius
	)
	self.SizeTween = TweenService:Create(
		self.Visual,
		TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ Size = targetSize }
	)
	self.SizeTween:Play()
	if self.InnerSizeTween then
		self.InnerSizeTween:Cancel()
		self.InnerSizeTween = nil
	end
	if self.InnerVisual and self:_shouldShowInnerRange() then
		local innerTargetSize = sizeForRadius(
			self.OriginalSize,
			self.VerticalAxis,
			self.BaseDiameter,
			self.EffectiveHarvestRadius * self.InnerRangeRatio
		)
		self.InnerSizeTween = TweenService:Create(
			self.InnerVisual,
			TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ Size = innerTargetSize }
		)
		self.InnerSizeTween:Play()
	else
		self:_setRangeVisualVisible(self.InnerVisual, self.InnerVisualDecal, false)
	end
end

function HarvestRangeController:_shouldShowInnerRange()
	return (self.EquippedToolId == "Tool02" or self.EquippedToolId == "Tool03")
		and self.InnerRangeRatio > 0
end

function HarvestRangeController:_refreshPlayerCenteredMode()
	local playerCentered = self.CameraController:IsTouchPrimary()
	if self.PlayerCentered == playerCentered then
		return
	end
	self.PlayerCentered = playerCentered
	self.LastAimUpdateTime = 0
	self:_setToolRange(
		self.HarvestRadius,
		self.ForwardOffset,
		self.ToolBehavior,
		self.InnerRangeRatio
	)
end

function HarvestRangeController:_setRangeVisualVisible(visual, decal, visible)
	if visual then
		visual.LocalTransparencyModifier = if visible then 0 else 1
	end
	if decal then
		decal.Transparency = if visible then self.OriginalDecalTransparency else 1
	end
end

function HarvestRangeController:_setCenterVisualVisible(visible)
	if self.CenterSurfaceGui then
		self.CenterSurfaceGui.Enabled = visible and self.OriginalCenterSurfaceGuiEnabled
	end
end

function HarvestRangeController:_setAimPosition(position, rootPosition)
	self.CurrentAimPosition = position
	if position then
		local now = os.clock()
		local updateInterval = if self.ToolBehavior == "Collect"
			then COLLECT_AIM_UPDATE_INTERVAL
			else PUSH_TOOL_AIM_UPDATE_INTERVAL
		if now - self.LastAimUpdateTime >= updateInterval then
			self.LastAimUpdateTime = now
			self.AimValidSent = true
			local aimOffset = if self.PlayerCentered
				then Vector3.zero
				else HarvestGeometry.GetHorizontalDelta(rootPosition, position)
			self.Remotes.UpdateHarvestAim:FireServer(true, aimOffset, self.PlayerCentered)
		end
	elseif self.AimValidSent then
		self.AimValidSent = false
		self.LastAimUpdateTime = 0
		self.Remotes.UpdateHarvestAim:FireServer(false)
	end
end

function HarvestRangeController:_parkVisuals()
	self:_setRangeVisualVisible(self.Visual, self.VisualDecal, false)
	self:_setRangeVisualVisible(self.InnerVisual, self.InnerVisualDecal, false)
	self:_setCenterVisualVisible(false)
	if self.Visual then
		self.Visual.CFrame = PARKED_CFRAME
	end
	if self.InnerVisual then
		self.InnerVisual.CFrame = PARKED_CFRAME
	end
	if self.CenterVisual then
		self.CenterVisual.CFrame = PARKED_CFRAME
	end
	self:_hideDirectionGuide()
	if self.DirectionGuide then
		self.DirectionGuide.CFrame = PARKED_CFRAME
	end
end

function HarvestRangeController:_hideVisual()
	self:_parkVisuals()
	self:_setAimPosition(nil)
end

function HarvestRangeController:_hideDirectionGuide()
	if self.DirectionGuideBeam then
		self.DirectionGuideBeam.Enabled = false
	end
end

function HarvestRangeController:_updateDirectionGuide(
	playerGroundPosition,
	playerGroundNormal,
	rangePosition,
	rangeGroundNormal
)
	if
		self.EquippedToolId ~= "Tool02"
		or not self.DirectionGuide
		or not self.DirectionGuideBeam
		or not self.DirectionGuideAttachment0
		or not self.DirectionGuideAttachment1
	then
		self:_hideDirectionGuide()
		return
	end

	local offset = self.DirectionGuideGroundOffset
	local playerPoint = playerGroundPosition + playerGroundNormal * offset
	local rangePoint = rangePosition + rangeGroundNormal * offset
	local worldDelta = rangePoint - playerPoint
	local distance = worldDelta.Magnitude
	if distance < DIRECTION_GUIDE_MIN_DISTANCE then
		self:_hideDirectionGuide()
		return
	end

	local worldDirection = worldDelta / distance
	local averageNormal = playerGroundNormal + rangeGroundNormal
	if averageNormal.Magnitude < 0.001 then
		averageNormal = playerGroundNormal
	end
	local worldUp = getPerpendicularUp(worldDirection, averageNormal.Unit)
	local worldReference = CFrame.lookAt(Vector3.zero, worldDirection, worldUp).Rotation
	local guideRotation = worldReference * self.DirectionGuideTemplateReferenceInverse
	local guideCFrame = CFrame.new(playerPoint) * guideRotation
	self.DirectionGuide.CFrame = guideCFrame
	self.DirectionGuideAttachment0.Position = Vector3.zero
	self.DirectionGuideAttachment1.Position = self.DirectionGuideTemplateDirection * distance
	self.DirectionGuideBeam.Enabled = true
end

function HarvestRangeController:_getPlayerFeetPlane(rootPart, humanoid)
	local feetOffset = math.max(0, humanoid.HipHeight + rootPart.Size.Y / 2)
	return rootPart.Position - Vector3.new(0, feetOffset, 0), Vector3.yAxis
end

function HarvestRangeController:_projectAimToFeetPlane(rootPart, targetPosition, playerFeetPosition)
	local clampedPosition = HarvestGeometry.ClampHorizontalPosition(
		rootPart.Position,
		targetPosition,
		self.ForwardOffset
	)
	return Vector3.new(clampedPosition.X, playerFeetPosition.Y, clampedPosition.Z), Vector3.yAxis
end

function HarvestRangeController:_getCameraFeetPlaneAim(rootPart, playerFeetPosition)
	local camera = Workspace.CurrentCamera
	local fallbackDirection = HarvestGeometry.GetHorizontalForward(rootPart.CFrame)
	local targetPosition = rootPart.Position + fallbackDirection * self.ForwardOffset
	if camera then
		local viewportSize = camera.ViewportSize
		if viewportSize.X > 0 and viewportSize.Y > 0 then
			local cameraRay
			if not self.CameraController:IsTouchPrimary() then
				local screenPosition = self.ToolController:GetAimScreenPosition(viewportSize)
				cameraRay = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)
			else
				cameraRay = camera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
			end

			local planeDistance = nil
			if math.abs(cameraRay.Direction.Y) > 0.0001 then
				planeDistance = (playerFeetPosition.Y - cameraRay.Origin.Y) / cameraRay.Direction.Y
			end
			if planeDistance and planeDistance > 0 then
				targetPosition = cameraRay.Origin + cameraRay.Direction * planeDistance
			else
				local horizontalDirection = Vector3.new(cameraRay.Direction.X, 0, cameraRay.Direction.Z)
				if horizontalDirection.Magnitude > 0.0001 then
					targetPosition = rootPart.Position + horizontalDirection.Unit * self.ForwardOffset
				end
			end
		end
	end
	return self:_projectAimToFeetPlane(rootPart, targetPosition, playerFeetPosition)
end

function HarvestRangeController:GetCurrentAimPosition()
	return self.CurrentAimPosition
end

function HarvestRangeController:GetCurrentEffectiveRadius()
	return self.EffectiveHarvestRadius
end

function HarvestRangeController:IsPlayerCentered()
	return self.PlayerCentered == true
end

function HarvestRangeController:_hasEquippedCleaningTool(character)
	if not character or not self.EquippedToolId then
		return false
	end
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute(CLEANING_TOOL_ATTRIBUTE) == self.EquippedToolId then
			return true
		end
	end
	return false
end

function HarvestRangeController:_updateVisual()
	self:_refreshPlayerCenteredMode()
	if self.Suppressed then
		self:_parkVisuals()
		return
	end
	local visual = self.Visual
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		not visual
		or self.EffectiveHarvestRadius <= 0
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
		or not self:_hasEquippedCleaningTool(character)
	then
		self:_hideVisual()
		return
	end

	local playerGroundPosition, playerGroundNormal = self:_getPlayerFeetPlane(rootPart, humanoid)
	local aimPosition, groundNormal
	if self.PlayerCentered then
		aimPosition = playerGroundPosition
		groundNormal = playerGroundNormal
	else
		aimPosition, groundNormal = self:_getCameraFeetPlaneAim(rootPart, playerGroundPosition)
	end
	if self.PlayerCentered then
		self:_parkVisuals()
		self:_setAimPosition(aimPosition, rootPart.Position)
		return
	end

	local groundOffset = getThickness(visual.Size, self.VerticalAxis) / 2
		+ GROUND_GAP
		+ RANGE_VISUAL_HEIGHT_OFFSET
	visual.CFrame = CFrame.new(aimPosition + groundNormal * groundOffset) * self.OriginalRotation
	self:_setRangeVisualVisible(visual, self.VisualDecal, true)
	if self.CenterVisual then
		local centerGroundOffset = getThickness(self.OriginalSize, self.VerticalAxis) / 2
			+ GROUND_GAP
			+ RANGE_VISUAL_HEIGHT_OFFSET
		self.CenterVisual.CFrame = CFrame.new(aimPosition + groundNormal * centerGroundOffset) * self.OriginalRotation
		self:_setCenterVisualVisible(true)
	end
	if self.InnerVisual and self:_shouldShowInnerRange() then
		local innerGroundOffset = getThickness(self.InnerVisual.Size, self.VerticalAxis) / 2
			+ GROUND_GAP * 2
			+ RANGE_VISUAL_HEIGHT_OFFSET
		self.InnerVisual.CFrame = CFrame.new(aimPosition + groundNormal * innerGroundOffset) * self.OriginalRotation
		self:_setRangeVisualVisible(self.InnerVisual, self.InnerVisualDecal, true)
	elseif self.InnerVisual then
		self:_setRangeVisualVisible(self.InnerVisual, self.InnerVisualDecal, false)
	end
	self:_updateDirectionGuide(
		playerGroundPosition,
		playerGroundNormal,
		aimPosition,
		groundNormal
	)
	self:_setAimPosition(aimPosition, rootPart.Position)
end

function HarvestRangeController:SetSuppressed(suppressed)
	self.Suppressed = suppressed == true
	if self.Suppressed then
		self:_parkVisuals()
	end
end

return HarvestRangeController

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local AreaUnlockConfig = require(ReplicatedStorage.Shared.Config.AreaUnlockConfig)
local CoopMatchConfig = require(ReplicatedStorage.Shared.Config.CoopMatchConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local AreaDoorController = {}

local TOUCH_REQUEST_COOLDOWN = 2.25
local DEFAULT_DOOR_OPEN_ROTATION_DEGREES = 90
local DOOR_OPEN_TWEEN_INFO = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local GUIDANCE_SOURCE_HEIGHT = 1.5
local GUIDANCE_REFRESH_INTERVAL = 0.25
local PURCHASE_EFFECTS_FOLDER_NAME = "LocalAreaDoorPurchaseEffects"
local PURCHASE_COIN_CLONE_NAME = "DoorPurchaseCoin"
local PURCHASE_COIN_TARGET_HEIGHT = 0.2
local PURCHASE_COIN_OFFSETS = {
	Vector3.new(-0.55, 0.05, 0),
	Vector3.new(0.55, 0.05, 0),
	Vector3.new(0, 0.4, 0),
	Vector3.new(-0.28, -0.25, 0),
	Vector3.new(0.28, -0.25, 0),
}
local PURCHASE_COIN_ARC_HEIGHTS = { 0.55, 0.75, 0.95, 0.65, 0.85 }

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

function AreaDoorController:Init(remotes, hudController)
	self.Remotes = remotes
	self.HUDController = hudController
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
	local oldPurchaseEffectsFolder = Workspace:FindFirstChild(PURCHASE_EFFECTS_FOLDER_NAME)
	if oldPurchaseEffectsFolder then
		oldPurchaseEffectsFolder:Destroy()
	end
	local purchaseEffectsFolder = Instance.new("Folder")
	purchaseEffectsFolder.Name = PURCHASE_EFFECTS_FOLDER_NAME
	purchaseEffectsFolder.Parent = Workspace
	self.PurchaseEffectsFolder = purchaseEffectsFolder
	self.DoorCoinTemplate = nil
	self.DoorCoinTemplateRotation = CFrame.identity
	self.DoorCoinTemplateWarningIssued = false
	self.AvailableDoorCoins = {}
	self.CreatedDoorCoinCount = 0
	self.DoorPurchaseAnimations = {}
	self.LastTouchedBindings = {}
	self.DoorPurchaseAnimationSerial = 0
	self:_bindDoorCoinTemplate()
	self.UnlockedAreas = {}
	for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
		self.UnlockedAreas[string.format("Area_%02d", areaNumber)] = true
	end
	self.Coins = 0
	self.AreaCoinResetEligible = false
	self.HomeYardProgress = nil
	self.RebirthCount = 0
	self.EligibleTargetAreaId = nil
	self.CoinShortageTargetAreaId = nil
	self.ResetGuidanceTargetAreaId = nil
	self.SuppressedDoorGuidanceTargetAreaId = nil
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
		local previousRebirthCount = self.RebirthCount
		self.UnlockedAreas = snapshot.UnlockedAreas
		self.Coins = math.max(0, math.floor(tonumber(snapshot.Coins) or 0))
		self.AreaCoinResetEligible = snapshot.AreaCoinResetEligible == true
		self.HomeYardProgress = type(snapshot.HomeYardProgress) == "table"
			and snapshot.HomeYardProgress
			or nil
		self.RebirthCount = math.max(0, math.floor(tonumber(snapshot.RebirthCount) or 0))
		if self.RebirthCount > previousRebirthCount then
			self:_cancelAllDoorPurchaseAnimations(false)
		end
		self:_refreshAllDoors(self.HasReceivedSnapshot)
		self:_refreshEligibleTargetAreaId()
		if self.RebirthCount > previousRebirthCount then
			self:_clearCoinShortageState(false)
		else
			self:_reconcileCoinShortageState()
		end
		self.GuidanceRefreshElapsed = 0
		self:_refreshGuidance()
		self.HasReceivedSnapshot = true
	end)
	remotes.AreaDoorCoinShortageNotice.OnClientEvent:Connect(function(payload)
		self:_handleCoinShortageNotice(payload)
	end)
	remotes.CoinSpendEvent.OnClientEvent:Connect(function(payload)
		self:_handleDoorSpendEvent(payload)
	end)
	remotes.AreaCoinResetPrompted.OnClientEvent:Connect(function()
		self:_clearCoinShortageState(true)
		self:_refreshGuidance()
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
		self:_cancelAllDoorPurchaseAnimations(true)
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

function AreaDoorController:_getDoorCoinTemplateNodes(template)
	if not template or not template:IsA("BasePart") then
		return nil
	end
	local billboard = template:FindFirstChild("BillboardGui")
	local frame = billboard and billboard:FindFirstChild("GetHint")
	local icon = frame and frame:FindFirstChild("Icon")
	local textLabel = frame and frame:FindFirstChild("TextLabel")
	if
		not billboard
		or not billboard:IsA("BillboardGui")
		or not frame
		or not frame:IsA("GuiObject")
		or not icon
		or not icon:IsA("ImageLabel")
		or not textLabel
		or not textLabel:IsA("TextLabel")
	then
		return nil
	end
	return {
		Billboard = billboard,
		Icon = icon,
		TextLabel = textLabel,
	}
end

function AreaDoorController:_warnDoorCoinTemplate(message)
	if self.DoorCoinTemplateWarningIssued then
		return
	end
	self.DoorCoinTemplateWarningIssued = true
	warn("Door-purchase coin animation is disabled: " .. message)
end

function AreaDoorController:_bindDoorCoinTemplate()
	if self.DoorCoinTemplate and self.DoorCoinTemplate.Parent then
		return true
	end
	local template = ReplicatedStorage:FindFirstChild("tishi")
	local nodes = self:_getDoorCoinTemplateNodes(template)
	if not nodes then
		self.DoorCoinTemplate = nil
		self:_warnDoorCoinTemplate(
			"ReplicatedStorage.tishi.BillboardGui.GetHint.Icon/TextLabel is missing or invalid"
		)
		return false
	end
	self.DoorCoinTemplate = template
	self.DoorCoinTemplateRotation = template.CFrame.Rotation
	return true
end

function AreaDoorController:_createDoorCoin()
	local maximumVisualCount = AreaUnlockConfig.DoorPurchasePresentation.MaximumVisualCount
	if self.CreatedDoorCoinCount >= maximumVisualCount or not self:_bindDoorCoinTemplate() then
		return nil
	end
	local part = self.DoorCoinTemplate:Clone()
	local nodes = self:_getDoorCoinTemplateNodes(part)
	if not nodes then
		part:Destroy()
		return nil
	end
	part.Name = PURCHASE_COIN_CLONE_NAME
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	nodes.Billboard.Enabled = false
	part.Parent = nil
	self.CreatedDoorCoinCount += 1
	return {
		Part = part,
		Billboard = nodes.Billboard,
		Icon = nodes.Icon,
		TextLabel = nodes.TextLabel,
		InUse = false,
	}
end

function AreaDoorController:_takeDoorCoin()
	local coin = table.remove(self.AvailableDoorCoins) or self:_createDoorCoin()
	if coin then
		coin.InUse = true
		coin.Icon.Image = AreaUnlockConfig.DoorPurchasePresentation.CoinImage
		coin.Billboard.Enabled = true
	end
	return coin
end

function AreaDoorController:_releaseDoorCoin(coin)
	if not coin or not coin.InUse then
		return
	end
	coin.InUse = false
	coin.Billboard.Enabled = false
	coin.Part.Parent = nil
	table.insert(self.AvailableDoorCoins, coin)
end

function AreaDoorController:_getDoorPurchaseRootPart()
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

function AreaDoorController:_isPurchaseBindingValid(binding, targetAreaId)
	return type(binding) == "table"
		and binding.Config.TargetAreaId == targetAreaId
		and binding.Model.Parent ~= nil
		and binding.Part.Parent ~= nil
		and self.Bindings[binding.Model] == binding
end

function AreaDoorController:_findDoorPurchaseBinding(targetAreaId, rootPart)
	local touchedBinding = self.LastTouchedBindings[targetAreaId]
	if self:_isPurchaseBindingValid(touchedBinding, targetAreaId) then
		return touchedBinding
	end
	local nearestBinding = nil
	local nearestDistance = math.huge
	for _, binding in self.Bindings do
		if self:_isPurchaseBindingValid(binding, targetAreaId) then
			local distance = (binding.Part.Position - rootPart.Position).Magnitude
			if distance < nearestDistance then
				nearestBinding = binding
				nearestDistance = distance
			end
		end
	end
	return nearestBinding
end

function AreaDoorController:_cancelDoorPurchaseAnimation(targetAreaId, refreshDoors)
	local animation = self.DoorPurchaseAnimations[targetAreaId]
	if not animation then
		return
	end
	self.DoorPurchaseAnimations[targetAreaId] = nil
	animation.Cancelled = true
	for coin in animation.ActiveCoins do
		self:_releaseDoorCoin(coin)
	end
	table.clear(animation.ActiveCoins)
	self:_cancelDoorPurchasePulse(animation.Binding)
	if refreshDoors then
		self:_refreshAllDoors(true)
	end
end

function AreaDoorController:_cancelAllDoorPurchaseAnimations(refreshDoors)
	local targetAreaIds = {}
	for targetAreaId in self.DoorPurchaseAnimations do
		table.insert(targetAreaIds, targetAreaId)
	end
	for _, targetAreaId in targetAreaIds do
		self:_cancelDoorPurchaseAnimation(targetAreaId, false)
	end
	if refreshDoors and #targetAreaIds > 0 then
		self:_refreshAllDoors(true)
	end
end

function AreaDoorController:_playDoorPurchaseAnimation(animation, rootPart, amount)
	local targetAreaId = animation.TargetAreaId
	local binding = animation.Binding
	local presentation = AreaUnlockConfig.DoorPurchasePresentation
	local visualCount = AreaUnlockConfig.GetDoorPurchaseVisualCount(amount)
	local spawnInterval = AreaUnlockConfig.GetDoorPurchaseSpawnInterval(visualCount)
	local targetPosition = binding.Part.Position
	local displayPrice = "-" .. CoinFormat.Compact(amount)

	task.spawn(function()
		local succeeded, message = xpcall(function()
			local completedCount = 0
			local spawnedCount = 0
			local lastRootCFrame = rootPart.CFrame
			for index = 1, visualCount do
				if self.DoorPurchaseAnimations[targetAreaId] ~= animation then
					return
				end
				if index > 1 then
					task.wait(spawnInterval)
				end
				if rootPart:IsDescendantOf(Workspace) then
					lastRootCFrame = rootPart.CFrame
				end
				local patternIndex = ((index - 1) % #PURCHASE_COIN_OFFSETS) + 1
				local startPosition = lastRootCFrame:PointToWorldSpace(
					PURCHASE_COIN_OFFSETS[patternIndex]
						+ Vector3.new(0, PURCHASE_COIN_TARGET_HEIGHT, 0)
				)
				local coin = self:_takeDoorCoin()
				if not coin then
					error("Door-purchase coin pool is unavailable")
				end
				coin.TextLabel.Text = displayPrice
				coin.Part.CFrame = CFrame.new(startPosition) * self.DoorCoinTemplateRotation
				coin.Part.Parent = self.PurchaseEffectsFolder
				animation.ActiveCoins[coin] = true
				spawnedCount += 1
				local arcHeight = PURCHASE_COIN_ARC_HEIGHTS[patternIndex]

				task.spawn(function()
					local startTime = os.clock()
					while
						self.DoorPurchaseAnimations[targetAreaId] == animation
						and coin.InUse
						and coin.Part.Parent == self.PurchaseEffectsFolder
					do
						local alpha = math.clamp(
							(os.clock() - startTime) / presentation.FlightDuration,
							0,
							1
						)
						local easedAlpha = alpha * alpha
						local basePosition = startPosition:Lerp(targetPosition, easedAlpha)
						local currentArcHeight = 4 * alpha * (1 - alpha) * arcHeight
						coin.Part.CFrame = CFrame.new(
							basePosition + Vector3.new(0, currentArcHeight, 0)
						) * self.DoorCoinTemplateRotation
						if alpha >= 1 then
							break
						end
						RunService.Heartbeat:Wait()
					end

					local reachedDoor = self.DoorPurchaseAnimations[targetAreaId] == animation
						and coin.InUse
					animation.ActiveCoins[coin] = nil
					self:_releaseDoorCoin(coin)
					if reachedDoor then
						self:_playDoorPurchasePulse(binding, animation)
						if self.HUDController then
							self.HUDController:PlayRecycleFeedbackSound()
						end
					end
					completedCount += 1
				end)
			end

			while
				completedCount < spawnedCount
				and self.DoorPurchaseAnimations[targetAreaId] == animation
			do
				RunService.Heartbeat:Wait()
			end
			local pulseDeadline = os.clock()
				+ presentation.PulseGrowDuration
				+ presentation.PulseShrinkDuration
				+ 0.25
			while
				animation.LatestPulseSerial ~= nil
				and binding.PulseCompletedSerial ~= animation.LatestPulseSerial
				and self.DoorPurchaseAnimations[targetAreaId] == animation
				and os.clock() < pulseDeadline
			do
				RunService.Heartbeat:Wait()
			end
		end, debug.traceback)

		if self.DoorPurchaseAnimations[targetAreaId] ~= animation then
			return
		end
		self.DoorPurchaseAnimations[targetAreaId] = nil
		self:_cancelDoorPurchasePulse(binding)
		if not succeeded then
			warn("Door-purchase coin animation failed: " .. tostring(message))
		end
		self:_refreshAllDoors(true)
	end)
end

function AreaDoorController:_handleDoorSpendEvent(payload)
	if CoopMatchConfig.IsCoop() or type(payload) ~= "table" or payload.Reason ~= "AreaUnlock" then
		return
	end
	local targetAreaId = payload.TargetAreaId
	local amount = math.max(0, math.floor(tonumber(payload.Amount) or 0))
	if type(targetAreaId) ~= "string" or not AreaUnlockConfig.Areas[targetAreaId] or amount <= 0 then
		return
	end
	local rootPart = self:_getDoorPurchaseRootPart()
	local binding = rootPart and self:_findDoorPurchaseBinding(targetAreaId, rootPart) or nil
	self.LastTouchedBindings[targetAreaId] = nil
	self:_cancelDoorPurchaseAnimation(targetAreaId, false)
	if not rootPart or not binding or not self:_bindDoorCoinTemplate() then
		return
	end

	self.DoorPurchaseAnimationSerial += 1
	local animation = {
		Serial = self.DoorPurchaseAnimationSerial,
		TargetAreaId = targetAreaId,
		Binding = binding,
		ActiveCoins = {},
		LatestPulseSerial = nil,
		Cancelled = false,
	}
	self.DoorPurchaseAnimations[targetAreaId] = animation
	self:_playDoorPurchaseAnimation(animation, rootPart, amount)
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
	if type(self.HomeYardProgress) ~= "table" then
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

function AreaDoorController:_getTargetUnlockPrice(targetAreaId)
	local config = type(targetAreaId) == "string" and AreaUnlockConfig.Areas[targetAreaId] or nil
	if not config then
		return nil
	end
	return AreaUnlockConfig.GetUnlockPrice(config, self.RebirthCount)
end

function AreaDoorController:_isCoinShortageTargetValid(targetAreaId)
	if
		CoopMatchConfig.IsCoop()
		or type(targetAreaId) ~= "string"
		or targetAreaId ~= self.EligibleTargetAreaId
		or self.UnlockedAreas[targetAreaId] == true
	then
		return false
	end
	local unlockPrice = self:_getTargetUnlockPrice(targetAreaId)
	return unlockPrice ~= nil and self.Coins < unlockPrice
end

function AreaDoorController:_clearCoinShortageState(suppressDoorGuidance)
	local targetAreaId = self.CoinShortageTargetAreaId or self.ResetGuidanceTargetAreaId
	self.CoinShortageTargetAreaId = nil
	self.ResetGuidanceTargetAreaId = nil
	if suppressDoorGuidance == true and type(targetAreaId) == "string" then
		self.SuppressedDoorGuidanceTargetAreaId = targetAreaId
	elseif suppressDoorGuidance ~= true then
		self.SuppressedDoorGuidanceTargetAreaId = nil
	end
	self.GuidanceRefreshElapsed = 0
end

function AreaDoorController:_reconcileCoinShortageState()
	local shortageTargetAreaId = self.CoinShortageTargetAreaId
	if shortageTargetAreaId and not self:_isCoinShortageTargetValid(shortageTargetAreaId) then
		self:_clearCoinShortageState(false)
		shortageTargetAreaId = nil
	end
	if shortageTargetAreaId then
		self.ResetGuidanceTargetAreaId = if self.AreaCoinResetEligible
			then shortageTargetAreaId
			else nil
	end

	local suppressedTargetAreaId = self.SuppressedDoorGuidanceTargetAreaId
	if suppressedTargetAreaId and not self:_isCoinShortageTargetValid(suppressedTargetAreaId) then
		self.SuppressedDoorGuidanceTargetAreaId = nil
	end
end

function AreaDoorController:_handleCoinShortageNotice(payload)
	if CoopMatchConfig.IsCoop() or type(payload) ~= "table" then
		return
	end
	local targetAreaId = payload.TargetAreaId
	if type(targetAreaId) ~= "string" or targetAreaId ~= self.EligibleTargetAreaId then
		return
	end
	self.Coins = math.max(0, math.floor(tonumber(payload.CurrentCoins) or self.Coins))
	self.AreaCoinResetEligible = payload.AreaCoinResetEligible == true
	self.CoinShortageTargetAreaId = targetAreaId
	self.ResetGuidanceTargetAreaId = if self.AreaCoinResetEligible then targetAreaId else nil
	self.SuppressedDoorGuidanceTargetAreaId = nil
	self.GuidanceRefreshElapsed = 0
	self:_reconcileCoinShortageState()
	self:_refreshGuidance()
end

function AreaDoorController:_getResetGuidanceTarget()
	local functionRoot = Workspace:FindFirstChild("Function")
	local resetPart = functionRoot and functionRoot:FindFirstChild("Reset")
	if resetPart and resetPart:IsA("BasePart") then
		return resetPart
	end
	return nil
end

function AreaDoorController:_getNearestGuidanceTarget(rootPart)
	if self.CoinShortageTargetAreaId == self.EligibleTargetAreaId then
		if self.ResetGuidanceTargetAreaId == self.EligibleTargetAreaId then
			return self:_getResetGuidanceTarget()
		end
		return nil
	end
	if self.SuppressedDoorGuidanceTargetAreaId == self.EligibleTargetAreaId then
		return nil
	end
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
	self:_reconcileCoinShortageState()
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
		PulsePivot = doorModel:GetPivot(),
		PulseParts = {},
		PulseScaleValue = nil,
		PulseScaleConnection = nil,
		PulseGrowTween = nil,
		PulseShrinkTween = nil,
		PulseSerial = 0,
		PulseCompletedSerial = 0,
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
			for _, descendant in panel:GetDescendants() do
				if descendant:IsA("BasePart") then
					table.insert(binding.PulseParts, {
						Part = descendant,
						OriginalSize = descendant.Size,
						RelativeCFrame = binding.PulsePivot:ToObjectSpace(descendant.CFrame),
					})
				end
			end
		end
	end
	if #binding.PulseParts > 0 then
		local pulseScaleValue = Instance.new("NumberValue")
		pulseScaleValue.Value = 1
		binding.PulseScaleValue = pulseScaleValue
		binding.PulseScaleConnection = pulseScaleValue:GetPropertyChangedSignal("Value"):Connect(function()
			self:_applyDoorPurchasePulseScale(binding, pulseScaleValue.Value)
		end)
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
	for targetAreaId, animation in self.DoorPurchaseAnimations do
		if animation.Binding == binding then
			self:_cancelDoorPurchaseAnimation(targetAreaId, false)
		end
	end
	for targetAreaId, touchedBinding in self.LastTouchedBindings do
		if touchedBinding == binding then
			self.LastTouchedBindings[targetAreaId] = nil
		end
	end
	self.Bindings[doorModel] = nil
	self:_cancelDoorAnimation(binding)
	self:_cancelDoorPurchasePulse(binding)
	if binding.PulseScaleConnection then
		binding.PulseScaleConnection:Disconnect()
		binding.PulseScaleConnection = nil
	end
	if binding.PulseScaleValue then
		binding.PulseScaleValue:Destroy()
		binding.PulseScaleValue = nil
	end

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

function AreaDoorController:_applyDoorPurchasePulseScale(binding, scale)
	if not binding or not binding.Model.Parent then
		return
	end
	local safeScale = math.max(0.001, tonumber(scale) or 1)
	for _, partData in binding.PulseParts do
		local part = partData.Part
		if part.Parent and part:IsDescendantOf(binding.Model) then
			local relativeCFrame = partData.RelativeCFrame
			part.Size = partData.OriginalSize * safeScale
			part.CFrame = binding.PulsePivot
				* CFrame.new(relativeCFrame.Position * safeScale)
				* relativeCFrame.Rotation
		end
	end
end

function AreaDoorController:_cancelDoorPurchasePulse(binding)
	if not binding then
		return
	end
	if binding.PulseGrowTween then
		binding.PulseGrowTween:Cancel()
	end
	if binding.PulseShrinkTween then
		binding.PulseShrinkTween:Cancel()
	end
	binding.PulseGrowTween = nil
	binding.PulseShrinkTween = nil
	if binding.PulseScaleValue then
		binding.PulseScaleValue.Value = 1
		self:_applyDoorPurchasePulseScale(binding, 1)
	end
	binding.PulseCompletedSerial = binding.PulseSerial
end

function AreaDoorController:_playDoorPurchasePulse(binding, animation)
	if
		not binding
		or not binding.Model.Parent
		or not binding.PulseScaleValue
		or #binding.PulseParts == 0
	then
		return
	end
	local presentation = AreaUnlockConfig.DoorPurchasePresentation
	self:_cancelDoorPurchasePulse(binding)
	binding.PulseSerial += 1
	local serial = binding.PulseSerial
	animation.LatestPulseSerial = serial

	local growTween = TweenService:Create(
		binding.PulseScaleValue,
		TweenInfo.new(
			presentation.PulseGrowDuration,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.Out
		),
		{ Value = presentation.PulseScale }
	)
	binding.PulseGrowTween = growTween
	growTween:Play()
	task.spawn(function()
		growTween.Completed:Wait()
		if serial ~= binding.PulseSerial or not binding.Model.Parent then
			return
		end
		binding.PulseGrowTween = nil
		local shrinkTween = TweenService:Create(
			binding.PulseScaleValue,
			TweenInfo.new(
				presentation.PulseShrinkDuration,
				Enum.EasingStyle.Sine,
				Enum.EasingDirection.In
			),
			{ Value = 1 }
		)
		binding.PulseShrinkTween = shrinkTween
		shrinkTween:Play()
		shrinkTween.Completed:Wait()
		if serial ~= binding.PulseSerial or not binding.Model.Parent then
			return
		end
		binding.PulseShrinkTween = nil
		self:_applyDoorPurchasePulseScale(binding, 1)
		binding.PulseCompletedSerial = serial
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
	if CoopMatchConfig.IsCoop() then
		return
	end
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
	if self.SuppressedDoorGuidanceTargetAreaId == targetAreaId then
		self.SuppressedDoorGuidanceTargetAreaId = nil
	end
	self.TouchRequestTimes[targetAreaId] = now
	self.LastTouchedBindings[targetAreaId] = binding
	self:_requestUnlock(binding.Config)
end

function AreaDoorController:_applyDoorState(binding, allowAnimation)
	local targetAreaId = binding.Config.TargetAreaId
	local authoritativeUnlocked = self.UnlockedAreas[targetAreaId] == true
	local unlocked = authoritativeUnlocked and self.DoorPurchaseAnimations[targetAreaId] == nil
	local targetAreaName = RegionConfig[binding.Config.TargetAreaId].DisplayName
	local unlockPrice = AreaUnlockConfig.GetUnlockPrice(binding.Config, self.RebirthCount)
	if binding.PriceFrame and binding.PriceFrame.Parent then
		binding.PriceFrame.Visible = not CoopMatchConfig.IsCoop() and not unlocked
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

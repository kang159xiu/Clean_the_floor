local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local TutorialConfig = require(ReplicatedStorage.Shared.Config.TutorialConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local TutorialController = {}
local ATTACHMENT_HEIGHT = 1.5
local UPGRADE_PULSE_SCALE = 1.12
local UPGRADE_PULSE_DURATION = 0.35
local AREA_COUNT = RegionConfig.AreaCount
local PRODUCT_TARGET_REFRESH_INTERVAL = 0.25
local CLEAN_TARGET_REFRESH_INTERVAL = 0.1

function TutorialController:Init(
	remotes,
	hudController,
	toolController,
	areaDoorController,
	handUpgradeController,
	yardLeafController
)
	self.Player = Players.LocalPlayer
	self.HUDController = hudController
	self.ToolController = toolController
	self.AreaDoorController = areaDoorController
	self.HandUpgradeController = handUpgradeController
	self.YardLeafController = yardLeafController
	self.BeamTemplate = ReplicatedStorage:WaitForChild("yindaoxian")
	assert(self.BeamTemplate:IsA("Beam"), "ReplicatedStorage.yindaoxian must be a Beam")

	local playerGui = self.Player:WaitForChild("PlayerGui")
	local gameHUD = playerGui:WaitForChild("GameHUD")
	local root = gameHUD:WaitForChild("HUDRoot")
	self.Yin = root:WaitForChild("yin")
	assert(self.Yin:IsA("GuiObject"), "HUDRoot.yin must be a GuiObject")
	self.YinValue = self.Yin:WaitForChild("Value")
	assert(self.YinValue:IsA("TextLabel"), "HUDRoot.yin.Value must be a TextLabel")
	self.YinDefaultPosition = self.Yin.Position
	self.Yin.Visible = false

	self.UpgradePanel = gameHUD:WaitForChild("UPattribute")
	assert(self.UpgradePanel:IsA("GuiObject"), "GameHUD.UPattribute must be a GuiObject")
	local handsPage = self.UpgradePanel:WaitForChild("Hands")
	self.UpgradePulseTargets = {
		[TutorialConfig.AmountAttributeId] = handsPage
			:WaitForChild("Pickup Amount")
			:WaitForChild("BuyButtons")
			:WaitForChild("Buy"),
		[TutorialConfig.SpeedAttributeId] = handsPage
			:WaitForChild("Pickup Speed")
			:WaitForChild("BuyButtons")
			:WaitForChild("Buy"),
	}
	self.UpgradePulseScales = {}
	for attributeId, target in self.UpgradePulseTargets do
		assert(target:IsA("GuiObject"), attributeId .. " tutorial pulse target must be a GuiObject")
		local uiScale = target:FindFirstChildOfClass("UIScale")
		if not uiScale then
			uiScale = Instance.new("UIScale")
			uiScale.Name = "TutorialPulseScale"
			uiScale.Parent = target
		end
		self.UpgradePulseScales[attributeId] = {
			Instance = uiScale,
			OriginalScale = uiScale.Scale,
		}
	end

	local effectsFolder = Workspace:FindFirstChild("LocalTutorialGuidanceEffects")
	if not effectsFolder then
		effectsFolder = Instance.new("Folder")
		effectsFolder.Name = "LocalTutorialGuidanceEffects"
		effectsFolder.Parent = Workspace
	end
	assert(effectsFolder:IsA("Folder"), "Workspace.LocalTutorialGuidanceEffects must be a Folder")
	effectsFolder:ClearAllChildren()
	self.EffectsFolder = effectsFolder
	self.CurrentStep = TutorialConfig.Steps.Complete
	self.TargetKind = nil
	self.TargetAreaId = nil
	self.TargetAttributeId = nil
	self.TargetReady = false
	self.UnlockedAreas = {}
	for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
		self.UnlockedAreas[string.format("Area_%02d", areaNumber)] = true
	end
	self.ProductTargetRefreshElapsed = 0
	self.CleanTargetRefreshElapsed = 0
	self.CleanApproachCompleted = false
	self.CleanTargetAnchor = nil
	self.SessionResetCharacterPending = nil
	self.SessionResetSerial = 0
	self.CleanLeafCount = 0
	self.CleanLeafGoal = math.max(1, math.floor(tonumber(TutorialConfig.LeafGoal) or 3))
	self.PoopGuidanceStage = nil
	self.PoopGuidanceActive = false
	if self.AreaDoorController then
		self.AreaDoorController:ConnectGuidanceActiveChanged(function()
			self:_refreshBeam()
		end)
	end

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot.TutorialState, snapshot.UnlockedAreas)
	end)
	hudController:ConnectSessionResetSucceeded(function(characterBeforeReset)
		self:_resetCleanApproachForSession(characterBeforeReset)
	end)
	RunService.Heartbeat:Connect(function(deltaTime)
		if self:_isCleanApproachActive() then
			self.CleanTargetRefreshElapsed += deltaTime
			if self.CleanTargetRefreshElapsed >= CLEAN_TARGET_REFRESH_INTERVAL then
				self.CleanTargetRefreshElapsed %= CLEAN_TARGET_REFRESH_INTERVAL
				self:_updateCleanApproach()
				self:_refreshBeam()
			end
		else
			self.CleanTargetRefreshElapsed = 0
		end
		if
			(self.TargetKind ~= "BagUpgrade" and self.TargetKind ~= "BroomPurchase")
			or not self.TargetReady
		then
			self.ProductTargetRefreshElapsed = 0
			return
		end
		self.ProductTargetRefreshElapsed += deltaTime
		if self.ProductTargetRefreshElapsed < PRODUCT_TARGET_REFRESH_INTERVAL then
			return
		end
		self.ProductTargetRefreshElapsed %= PRODUCT_TARGET_REFRESH_INTERVAL
		self:_refreshBeam()
	end)
	Workspace.DescendantAdded:Connect(function(descendant)
		local isExpectedProduct = self.TargetKind == "BagUpgrade" and descendant.Name == "BagProduct_01"
			or self.TargetKind == "BroomPurchase"
				and (descendant.Name == "CleaProduct_02" or descendant.Name == "CleaProduct_02_1")
		if isExpectedProduct then
			self.ProductTargetRefreshElapsed = 0
			self:_refreshBeam()
		end
	end)
	self.UpgradePanel:GetPropertyChangedSignal("Visible"):Connect(function()
		if
			self.UpgradePanel.Visible
			and self.TargetKind == "Upgrade"
			and self.TargetReady
			and self.HandUpgradeController
		then
			self.HandUpgradeController:SelectPage("Hands")
		end
		self:_refreshBeam()
		self:_refreshYin()
		self:_refreshUpgradePulse()
	end)
	self.Player.CharacterAdded:Connect(function(character)
		self:_bindCharacter(character)
	end)
	self.Player.CharacterRemoving:Connect(function()
		self:_destroyBeam()
		self:_stopUpgradePulse()
	end)
	if self.Player.Character then
		self:_bindCharacter(self.Player.Character)
	end
end

function TutorialController:_resetCleanApproachForSession(characterBeforeReset)
	self.SessionResetSerial += 1
	local resetSerial = self.SessionResetSerial
	self.CleanApproachCompleted = false
	self.CleanTargetRefreshElapsed = 0
	self.SessionResetCharacterPending = if characterBeforeReset
		and self.Player.Character == characterBeforeReset
		then characterBeforeReset
		else nil
	self:_destroyCleanTargetAnchor()
	self:_destroyBeam()
	self:_refreshTutorialNotification()
	self:_refreshYin()
	if self.SessionResetCharacterPending then
		task.delay(5, function()
			if
				self.SessionResetSerial ~= resetSerial
				or self.SessionResetCharacterPending ~= characterBeforeReset
			then
				return
			end
			self.SessionResetCharacterPending = nil
			self.CleanApproachCompleted = false
			self.CleanTargetRefreshElapsed = 0
			self:_refreshTutorialNotification()
			self:_refreshYin()
			self:_updateCleanApproach()
			self:_refreshBeam()
		end)
		return
	end
	self:_updateCleanApproach()
	self:_refreshBeam()
end

function TutorialController:_bindCharacter(character)
	self:_destroyBeam()
	self:_stopUpgradePulse()
	if self.SessionResetCharacterPending and character ~= self.SessionResetCharacterPending then
		self.SessionResetCharacterPending = nil
		self.CleanApproachCompleted = false
		self.CleanTargetRefreshElapsed = 0
	end
	if self.HumanoidDiedConnection then
		self.HumanoidDiedConnection:Disconnect()
		self.HumanoidDiedConnection = nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		self.HumanoidDiedConnection = humanoid.Died:Connect(function()
			self:_destroyBeam()
			self:_stopUpgradePulse()
		end)
	end
	character:WaitForChild("HumanoidRootPart", 5)
	self:_updateCleanApproach()
	self:_refreshBeam()
	self:_refreshUpgradePulse()
end

function TutorialController:_isCleanApproachActive()
	return self.CurrentStep == TutorialConfig.Steps.CleanLeaves
		and self.CleanLeafCount <= 0
		and not self.CleanApproachCompleted
		and self.SessionResetCharacterPending == nil
end

function TutorialController:_destroyCleanTargetAnchor()
	local anchor = self.CleanTargetAnchor
	if not anchor then
		return
	end
	if self.ActiveTargetPart == anchor then
		self:_destroyBeam()
	end
	anchor:Destroy()
	self.CleanTargetAnchor = nil
end

function TutorialController:_getCleanTargetAnchor()
	local anchor = self.CleanTargetAnchor
	if anchor and anchor.Parent then
		return anchor
	end
	anchor = Instance.new("Part")
	anchor.Name = "LocalTutorialCoinTarget"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Parent = self.EffectsFolder
	self.CleanTargetAnchor = anchor
	return anchor
end

function TutorialController:_updateCleanApproach()
	if not self:_isCleanApproachActive() then
		self:_destroyCleanTargetAnchor()
		return
	end
	local rootPart = self:_getRootPart()
	local targetPosition = rootPart
		and self.YardLeafController
		and self.YardLeafController:GetNearestGuidancePosition(
			TutorialConfig.CleanAreaId,
			rootPart.Position
		)
		or nil
	if not rootPart or not targetPosition then
		self:_destroyCleanTargetAnchor()
		return
	end
	local offsetX = targetPosition.X - rootPart.Position.X
	local offsetZ = targetPosition.Z - rootPart.Position.Z
	local distance = math.sqrt(offsetX * offsetX + offsetZ * offsetZ)
	if distance <= TutorialConfig.CleanApproachDistance then
		self.CleanApproachCompleted = true
		self:_destroyCleanTargetAnchor()
		self:_refreshTutorialNotification()
		self:_refreshYin()
		return
	end
	local anchor = self:_getCleanTargetAnchor()
	anchor.Position = targetPosition
end

function TutorialController:_getRootPart()
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart
	end
	return nil
end

function TutorialController:_getTargetPart(rootPart)
	if self:_isCleanApproachActive() then
		return self.CleanTargetAnchor
	elseif self.TargetKind == "Recycle" and type(self.TargetAreaId) == "string" then
		local area = Workspace:FindFirstChild(self.TargetAreaId)
		local recycle = area and area:FindFirstChild("Recycle_01")
		if recycle and recycle:IsA("BasePart") then
			return recycle
		end
	elseif self.TargetKind == "Upgrade" then
		local area = Workspace:FindFirstChild(TutorialConfig.UpgradeAreaId)
		local upgrade = area and area:FindFirstChild("UPattribute")
		local target = upgrade and upgrade:FindFirstChild("up")
		if target and target:IsA("BasePart") then
			return target
		end
	elseif self.TargetKind == "BagUpgrade" then
		if
			type(self.TargetAreaId) == "string"
			and self.UnlockedAreas[self.TargetAreaId] == true
		then
			local area = Workspace:FindFirstChild(self.TargetAreaId)
			local product = area and area:FindFirstChild("BagProduct_01")
			if product and product:IsA("BasePart") then
				return product
			end
		end

		local nearestProduct = nil
		local nearestDistance = math.huge
		for areaNumber = 1, AREA_COUNT do
			local areaId = string.format("Area_%02d", areaNumber)
			if self.UnlockedAreas[areaId] == true then
				local area = Workspace:FindFirstChild(areaId)
				local product = area and area:FindFirstChild("BagProduct_01")
				if product and product:IsA("BasePart") then
					local distance = rootPart and (product.Position - rootPart.Position).Magnitude or math.huge
					if distance < nearestDistance then
						nearestProduct = product
						nearestDistance = distance
					end
				end
			end
		end
		return nearestProduct
	elseif self.TargetKind == "BroomPurchase" then
		if type(self.TargetAreaId) == "string" and self.UnlockedAreas[self.TargetAreaId] == true then
			local targetArea = Workspace:FindFirstChild(self.TargetAreaId)
			local preferredName = if self.TargetAreaId == "Area_01"
				then "CleaProduct_02_1"
				else "CleaProduct_02"
			local preferredProduct = targetArea and targetArea:FindFirstChild(preferredName)
			if preferredProduct and preferredProduct:IsA("BasePart") then
				return preferredProduct
			end
			local fallbackProduct = targetArea and targetArea:FindFirstChild("CleaProduct_02")
			if fallbackProduct and fallbackProduct:IsA("BasePart") then
				return fallbackProduct
			end
		end

		local nearestProduct = nil
		local nearestDistance = math.huge
		for areaNumber = 1, AREA_COUNT do
			local areaId = string.format("Area_%02d", areaNumber)
			if self.UnlockedAreas[areaId] == true then
				local area = Workspace:FindFirstChild(areaId)
				local productNames = if areaId == "Area_01"
					then { "CleaProduct_02_1", "CleaProduct_02" }
					else { "CleaProduct_02" }
				for _, productName in productNames do
					local product = area and area:FindFirstChild(productName)
					if product and product:IsA("BasePart") then
						local distance = rootPart and (product.Position - rootPart.Position).Magnitude or math.huge
						if distance < nearestDistance then
							nearestProduct = product
							nearestDistance = distance
						end
					end
				end
			end
		end
		return nearestProduct
	end
	return nil
end

function TutorialController:_destroyBeam()
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

function TutorialController:_showBeam(rootPart, targetPart)
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
	sourceAttachment.Name = "LocalTutorialGuidanceSource"
	sourceAttachment.Position = Vector3.new(0, ATTACHMENT_HEIGHT, 0)
	sourceAttachment.Parent = rootPart

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "LocalTutorialGuidanceTarget"
	targetAttachment.Position = Vector3.new(0, ATTACHMENT_HEIGHT, 0)
	targetAttachment.Parent = targetPart

	local beam = self.BeamTemplate:Clone()
	beam.Name = "LocalTutorialGuidanceBeam"
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

function TutorialController:_refreshBeam()
	if self.AreaDoorController and self.AreaDoorController:IsGuidanceActive() then
		self:_destroyBeam()
		return
	end
	if self.TargetKind == "Upgrade" and self.UpgradePanel.Visible then
		self:_destroyBeam()
		return
	end
	local rootPart = self:_getRootPart()
	local targetPart = self:_getTargetPart(rootPart)
	if not rootPart or not targetPart then
		self:_destroyBeam()
		return
	end
	self:_showBeam(rootPart, targetPart)
end

function TutorialController:_refreshYin()
	if self.CurrentStep == TutorialConfig.Steps.CleanLeaves then
		if not self.CleanApproachCompleted or self.CleanLeafCount >= self.CleanLeafGoal then
			self.Yin.Visible = false
			return
		end
		self.Yin.Position = self.YinDefaultPosition
		self.YinValue.Text = "Press to Pick Up"
		self.Yin.Visible = true
		return
	end

	self.Yin.Visible = false
end

function TutorialController:_refreshTutorialNotification()
	local step = self.CurrentStep
	if step == TutorialConfig.Steps.CleanLeaves then
		if not self.CleanApproachCompleted and self.CleanLeafCount <= 0 then
			self.HUDController:SetPersistentNotification(TutorialConfig.Messages.GoToCoins)
		else
			self.HUDController:SetPersistentNotification(
				string.format("Hold to Clean %d/%d", self.CleanLeafCount, self.CleanLeafGoal)
			)
		end
	elseif step == TutorialConfig.Steps.RecycleLeaves then
		self.HUDController:SetPersistentNotification(TutorialConfig.Messages.RecycleLeaves)
	elseif step == TutorialConfig.Steps.UpgradeAmount then
		self.HUDController:SetPersistentNotification(TutorialConfig.Messages.UpgradeAmount)
	elseif step == TutorialConfig.Steps.UpgradeSpeed then
		if self.TargetReady then
			self.HUDController:SetPersistentNotification(TutorialConfig.Messages.UpgradeSpeed)
		else
			self.HUDController:SetPersistentNotification(nil)
		end
	elseif self.TargetKind == "BagUpgrade" and self.TargetReady then
		self.HUDController:SetPersistentNotification(TutorialConfig.Messages.UpgradeBag)
	elseif self.TargetKind == "BroomPurchase" and self.TargetReady then
		self.HUDController:SetPersistentNotification(TutorialConfig.Messages.BuyBroom)
	else
		self.HUDController:SetPersistentNotification(nil)
	end
end

function TutorialController:_stopUpgradePulse()
	if self.UpgradePulseTween then
		self.UpgradePulseTween:Cancel()
		self.UpgradePulseTween = nil
	end
	local pulseData = self.ActiveUpgradePulseAttributeId
		and self.UpgradePulseScales[self.ActiveUpgradePulseAttributeId]
	if pulseData and pulseData.Instance.Parent then
		pulseData.Instance.Scale = pulseData.OriginalScale
	end
	self.ActiveUpgradePulseAttributeId = nil
end

function TutorialController:_refreshUpgradePulse()
	local attributeId = nil
	if self.TargetKind == "Upgrade" and self.TargetReady and self.UpgradePanel.Visible then
		attributeId = self.TargetAttributeId
	end

	local pulseData = attributeId and self.UpgradePulseScales[attributeId]
	if not pulseData or not pulseData.Instance.Parent then
		self:_stopUpgradePulse()
		return
	end
	if self.ActiveUpgradePulseAttributeId == attributeId and self.UpgradePulseTween then
		return
	end

	self:_stopUpgradePulse()
	pulseData.Instance.Scale = pulseData.OriginalScale
	local tween = TweenService:Create(
		pulseData.Instance,
		TweenInfo.new(
			UPGRADE_PULSE_DURATION,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut,
			-1,
			true
		),
		{ Scale = pulseData.OriginalScale * UPGRADE_PULSE_SCALE }
	)
	self.ActiveUpgradePulseAttributeId = attributeId
	self.UpgradePulseTween = tween
	tween:Play()
end

function TutorialController:ApplySnapshot(tutorialState, unlockedAreas)
	if type(unlockedAreas) == "table" then
		self.UnlockedAreas = unlockedAreas
	else
		self.UnlockedAreas = {}
		for areaNumber = 1, RegionConfig.DefaultUnlockedAreaCount do
			self.UnlockedAreas[string.format("Area_%02d", areaNumber)] = true
		end
	end
	self.ProductTargetRefreshElapsed = 0
	if type(tutorialState) ~= "table" then
		self.CurrentStep = TutorialConfig.Steps.Complete
		self.TargetKind = nil
		self.TargetAreaId = nil
		self.TargetAttributeId = nil
		self.TargetReady = false
		self.CleanLeafCount = 0
		self.CleanLeafGoal = math.max(1, math.floor(tonumber(TutorialConfig.LeafGoal) or 3))
		self.CleanApproachCompleted = false
		self:_destroyCleanTargetAnchor()
		self.HUDController:SetPersistentNotification(nil)
		self.HUDController:SetPoopGuidanceNotification(nil)
		self.ToolController:SetPoopGuidanceActive(false)
		self:_destroyBeam()
		self:_refreshYin()
		self:_refreshUpgradePulse()
		return
	end

	local step = math.floor(tonumber(tutorialState.Step) or TutorialConfig.Steps.Complete)
	local previousStep = self.CurrentStep
	self.CurrentStep = step
	self.TargetKind = tutorialState.TargetKind
	self.TargetAreaId = tutorialState.TargetAreaId
	self.TargetAttributeId = tutorialState.TargetAttributeId
	self.TargetReady = tutorialState.TargetReady == true
	if
		self.TargetKind == "Upgrade"
		and self.TargetReady
		and self.UpgradePanel.Visible
		and self.HandUpgradeController
	then
		self.HandUpgradeController:SelectPage("Hands")
	end
	local goal = math.max(1, math.floor(tonumber(tutorialState.LeafGoal) or TutorialConfig.LeafGoal))
	local count = math.clamp(math.floor(tonumber(tutorialState.LeafCount) or 0), 0, goal)
	self.CleanLeafGoal = goal
	self.CleanLeafCount = count
	if step == TutorialConfig.Steps.CleanLeaves then
		if count > 0 then
			self.CleanApproachCompleted = true
		elseif previousStep ~= TutorialConfig.Steps.CleanLeaves then
			self.CleanApproachCompleted = false
		end
	else
		self.CleanApproachCompleted = false
		self:_destroyCleanTargetAnchor()
	end
	local poopGuidanceStage = tutorialState.PoopGuidanceStage
	if poopGuidanceStage ~= "Make" and poopGuidanceStage ~= "Pickup" and poopGuidanceStage ~= "Sell" then
		poopGuidanceStage = nil
	end
	self.PoopGuidanceStage = poopGuidanceStage
	self.PoopGuidanceActive = tutorialState.PoopGuidanceActive == true
	self:_refreshTutorialNotification()

	local poopMessage = nil
	if self.PoopGuidanceActive then
		if self.PoopGuidanceStage == "Make" then
			poopMessage = TutorialConfig.Messages.MakePoop
		elseif self.PoopGuidanceStage == "Pickup" then
			poopMessage = TutorialConfig.Messages.PickupPoop
		elseif self.PoopGuidanceStage == "Sell" then
			poopMessage = TutorialConfig.Messages.SellPoop
		end
	end
	self.HUDController:SetPoopGuidanceNotification(poopMessage)
	self.ToolController:SetPoopGuidanceActive(
		self.PoopGuidanceActive and self.PoopGuidanceStage == "Make"
	)

	self:_updateCleanApproach()
	self:_refreshBeam()
	self:_refreshYin()
	self:_refreshUpgradePulse()
end

return TutorialController

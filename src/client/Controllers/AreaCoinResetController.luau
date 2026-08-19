local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ModalPanelCoordinator = require(script.Parent.Parent.Effects.ModalPanelCoordinator)
local ModalPanelEffects = require(script.Parent.Parent.Effects.ModalPanelEffects)
local AreaUnlockConfig = require(ReplicatedStorage.Shared.Config.AreaUnlockConfig)

local AreaCoinResetController = {}

local MODAL_PANEL_ID = "AreaCoinReset"
local DOOR_NOTICE_SOURCE = "AreaDoorCoinShortage"
local DOOR_NOTICE_PRIORITY = 10
local DOOR_RESET_NOTICE_MESSAGE = "Reset cleared areas to earn more Coins."
local LOCKED_TEXT_COLOR = Color3.fromRGB(255, 80, 80)
local LOCKED_PULSE_SCALE = 1.12
local LOCKED_PULSE_OUT_DURATION = 0.12
local LOCKED_PULSE_RETURN_DURATION = 0.22

function AreaCoinResetController:_setDoorNoticeVisible(visible, message)
	self.HUDController:SetPersistentNotificationSource(
		DOOR_NOTICE_SOURCE,
		if visible then message or DOOR_RESET_NOTICE_MESSAGE else nil,
		DOOR_NOTICE_PRIORITY
	)
end

function AreaCoinResetController:_clearDoorShortageNotice()
	self.DoorShortageTargetAreaId = nil
	self.DoorShortageActive = false
	self:_setDoorNoticeVisible(false)
end

function AreaCoinResetController:_isDoorShortageStillValid()
	local targetAreaId = self.DoorShortageTargetAreaId
	local config = type(targetAreaId) == "string" and AreaUnlockConfig.Areas[targetAreaId] or nil
	if
		not self.DoorShortageActive
		or not config
		or self.UnlockedAreas[targetAreaId] == true
	then
		return false
	end
	local unlockPrice = AreaUnlockConfig.GetUnlockPrice(config, self.RebirthCount)
	return self.Coins < unlockPrice
end

function AreaCoinResetController:_refreshDoorShortageNotice()
	if not self:_isDoorShortageStillValid() then
		self:_clearDoorShortageNotice()
		return
	end
	local message = if self.Eligible
		then DOOR_RESET_NOTICE_MESSAGE
		else self.RequirementText
	self:_setDoorNoticeVisible(true, message)
end

function AreaCoinResetController:_cancelLockedFeedback()
	self.LockedFeedbackSerial += 1
	if self.ExplainScaleTween then
		self.ExplainScaleTween:Cancel()
		self.ExplainScaleTween = nil
	end
	if self.ExplainColorTween then
		self.ExplainColorTween:Cancel()
		self.ExplainColorTween = nil
	end
	self.ExplainScale.Scale = self.ExplainOriginalScale
	self.ExplainText.TextColor3 = self.ExplainOriginalColor
end

function AreaCoinResetController:_playLockedFeedback()
	self:_cancelLockedFeedback()
	local serial = self.LockedFeedbackSerial
	local scaleOut = TweenService:Create(
		self.ExplainScale,
		TweenInfo.new(LOCKED_PULSE_OUT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = self.ExplainOriginalScale * LOCKED_PULSE_SCALE }
	)
	local colorOut = TweenService:Create(
		self.ExplainText,
		TweenInfo.new(LOCKED_PULSE_OUT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ TextColor3 = LOCKED_TEXT_COLOR }
	)
	self.ExplainScaleTween = scaleOut
	self.ExplainColorTween = colorOut
	scaleOut:Play()
	colorOut:Play()

	task.spawn(function()
		local playbackState = scaleOut.Completed:Wait()
		if playbackState ~= Enum.PlaybackState.Completed or serial ~= self.LockedFeedbackSerial then
			return
		end
		local scaleReturn = TweenService:Create(
			self.ExplainScale,
			TweenInfo.new(LOCKED_PULSE_RETURN_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = self.ExplainOriginalScale }
		)
		local colorReturn = TweenService:Create(
			self.ExplainText,
			TweenInfo.new(LOCKED_PULSE_RETURN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextColor3 = self.ExplainOriginalColor }
		)
		self.ExplainScaleTween = scaleReturn
		self.ExplainColorTween = colorReturn
		scaleReturn:Play()
		colorReturn:Play()
		local returnState = scaleReturn.Completed:Wait()
		if returnState == Enum.PlaybackState.Completed and serial == self.LockedFeedbackSerial then
			self.ExplainScaleTween = nil
			self.ExplainColorTween = nil
			self.ExplainScale.Scale = self.ExplainOriginalScale
			self.ExplainText.TextColor3 = self.ExplainOriginalColor
		end
	end)
end

function AreaCoinResetController:_refreshButtonState()
	local interactable = not self.RequestRunning
	self.ConfirmButton.Active = interactable
	self.ConfirmButton.Interactable = interactable
	self.EligibleGradient.Enabled = self.Eligible
	self.LockedGradient.Enabled = not self.Eligible
end

function AreaCoinResetController:_applyStatus(payload, preferMessage)
	if type(payload) ~= "table" then
		return
	end
	self.Eligible = payload.Eligible == true
	local requirementText = payload.RequirementText
	if preferMessage == true and type(payload.Message) == "string" and payload.Message ~= "" then
		requirementText = payload.Message
	end
	if type(requirementText) == "string" and requirementText ~= "" then
		self.RequirementText = requirementText
		self.ExplainText.Text = requirementText
	end
	self:_refreshButtonState()
end

function AreaCoinResetController:_setPanelVisible(visible)
	local shouldBeVisible = visible == true and not self.RequestRunning
	local wasVisible = self.Panel.Visible
	if shouldBeVisible then
		ModalPanelCoordinator.Open(MODAL_PANEL_ID)
	else
		ModalPanelCoordinator.Close(MODAL_PANEL_ID)
	end
	if shouldBeVisible and not wasVisible then
		ModalPanelEffects.PlayOpen(self.Panel)
	elseif not shouldBeVisible then
		self:_cancelLockedFeedback()
		ModalPanelEffects.StopOpen(self.Panel)
		self.Panel.Visible = false
	end
end

function AreaCoinResetController:_requestReset()
	if self.RequestRunning then
		return
	end
	if not self.Eligible then
		self:_playLockedFeedback()
		return
	end

	self.RequestRunning = true
	self:_refreshButtonState()
	local invokeSucceeded, result = pcall(function()
		return self.Remotes.RequestAreaCoinReset:InvokeServer()
	end)
	if not invokeSucceeded or type(result) ~= "table" then
		result = {
			Status = "Failed",
			Message = "Area coin reset request failed. Try again.",
			Eligible = false,
			RequirementText = "Area coin reset request failed. Try again.",
		}
	end

	self.RequestRunning = false
	self:_applyStatus(result, result.Status ~= "Succeeded")
	if result.Status == "Succeeded" then
		self:_clearDoorShortageNotice()
		self:_setPanelVisible(false)
	else
		self:_playLockedFeedback()
	end
	self:_refreshButtonState()
end

function AreaCoinResetController:ApplySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	self:_applyStatus({
		Eligible = snapshot.AreaCoinResetEligible,
		RequirementText = snapshot.AreaCoinResetRequirementText,
	})
	self.Coins = math.max(0, math.floor(tonumber(snapshot.Coins) or 0))
	self.UnlockedAreas = type(snapshot.UnlockedAreas) == "table" and snapshot.UnlockedAreas or {}
	local rebirthCount = math.max(0, math.floor(tonumber(snapshot.RebirthCount) or 0))
	if self.LastRebirthCount ~= nil and rebirthCount > self.LastRebirthCount then
		self:_clearDoorShortageNotice()
		self:_setPanelVisible(false)
	end
	self.LastRebirthCount = rebirthCount
	self.RebirthCount = rebirthCount
	self:_refreshDoorShortageNotice()
end

function AreaCoinResetController:Init(remotes, hudController)
	self.Remotes = remotes
	self.HUDController = hudController
	self.Eligible = false
	self.RequestRunning = false
	self.RequirementText = "Your yard is not ready."
	self.LastRebirthCount = nil
	self.RebirthCount = 0
	self.Coins = 0
	self.UnlockedAreas = {}
	self.DoorShortageTargetAreaId = nil
	self.DoorShortageActive = false
	self.LockedFeedbackSerial = 0
	self.ExplainScaleTween = nil
	self.ExplainColorTween = nil

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gameHUD = playerGui:WaitForChild("GameHUD")
	self.Panel = gameHUD:WaitForChild("Reset")
	assert(self.Panel:IsA("GuiObject"), "GameHUD.Reset must be a GuiObject")
	local template = self.Panel:WaitForChild("muban")
	self.ExplainText = template:WaitForChild("explain")
	assert(self.ExplainText:IsA("TextLabel"), "GameHUD.Reset.muban.explain must be a TextLabel")
	self.ExplainOriginalColor = self.ExplainText.TextColor3
	self.ExplainScale = self.ExplainText:FindFirstChild("AreaCoinResetExplainPulseScale")
	if not self.ExplainScale then
		self.ExplainScale = Instance.new("UIScale")
		self.ExplainScale.Name = "AreaCoinResetExplainPulseScale"
		self.ExplainScale.Scale = 1
		self.ExplainScale.Parent = self.ExplainText
	end
	assert(self.ExplainScale:IsA("UIScale"), "AreaCoinResetExplainPulseScale must be a UIScale")
	self.ExplainOriginalScale = self.ExplainScale.Scale

	self.ConfirmButton = self.Panel:WaitForChild("nodabian")
	assert(self.ConfirmButton:IsA("GuiButton"), "GameHUD.Reset.nodabian must be a GuiButton")
	local allowedText = self.ConfirmButton:WaitForChild("allowed")
	assert(allowedText:IsA("TextLabel"), "GameHUD.Reset.nodabian.allowed must be a TextLabel")
	allowedText.Text = "Reset"
	local stud = self.ConfirmButton:WaitForChild("Stud")
	self.EligibleGradient = stud:WaitForChild("UIGradient")
	self.LockedGradient = stud:WaitForChild("UIGradient2")
	assert(self.EligibleGradient:IsA("UIGradient"), "Reset.nodabian.Stud.UIGradient must be a UIGradient")
	assert(self.LockedGradient:IsA("UIGradient"), "Reset.nodabian.Stud.UIGradient2 must be a UIGradient")
	local banner = self.Panel:WaitForChild("Banner")
	self.CloseButton = banner:WaitForChild("Close")
	assert(self.CloseButton:IsA("GuiButton"), "GameHUD.Reset.Banner.Close must be a GuiButton")

	self.ExplainText.Text = self.RequirementText
	self.Panel.Visible = false
	ModalPanelEffects.StopOpen(self.Panel)
	ModalPanelCoordinator.Register(MODAL_PANEL_ID, function()
		self:_setPanelVisible(false)
	end)
	self:_refreshButtonState()

	self.ConfirmButton.Activated:Connect(function()
		self:_requestReset()
	end)
	self.CloseButton.Activated:Connect(function()
		self:_setPanelVisible(false)
	end)
	remotes.AreaCoinResetPrompted.OnClientEvent:Connect(function(payload)
		self:_clearDoorShortageNotice()
		self:_applyStatus(payload)
		self:_setPanelVisible(true)
	end)
	remotes.AreaDoorCoinShortageNotice.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.TargetAreaId) ~= "string" then
			return
		end
		self.DoorShortageTargetAreaId = payload.TargetAreaId
		self.DoorShortageActive = true
		self.Coins = math.max(0, math.floor(tonumber(payload.CurrentCoins) or self.Coins))
		self.Eligible = payload.AreaCoinResetEligible == true
		local requirementText = payload.AreaCoinResetRequirementText
		if type(requirementText) == "string" and requirementText ~= "" then
			self.RequirementText = requirementText
		end
		self:_refreshDoorShortageNotice()
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
	hudController:ConnectSessionResetSucceeded(function()
		self:_clearDoorShortageNotice()
		self:_setPanelVisible(false)
	end)
end

return AreaCoinResetController

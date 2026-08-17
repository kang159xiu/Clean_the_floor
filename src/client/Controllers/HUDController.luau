local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local effectsFolder = script.Parent.Parent:WaitForChild("Effects")
local CenterFlyUIEffect = require(effectsFolder:WaitForChild("CenterFlyUIEffect"))
local ModalPanelCoordinator = require(effectsFolder:WaitForChild("ModalPanelCoordinator"))
local ModalPanelEffects = require(effectsFolder:WaitForChild("ModalPanelEffects"))
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)
local LostItemConfig = require(ReplicatedStorage.Shared.Config.LostItemConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local HUDController = {}
local CODEX_MODAL_PANEL_ID = "Codex"
local CODEX_RARITY_GRADIENT_NAMES = {
	"UIGradient1",
	"UIGradient2",
	"UIGradient3",
	"UIGradient4",
	"UIGradient5",
}
local LEAF_SOUND_CLEANUP_TIMEOUT = 10
local BAG_FULL_SOUND_CLEANUP_TIMEOUT = 10
local BAG_FULL_SOUND_COOLDOWN = 0.75
local BAG_FULL_SHAKE_STEP_DURATION = 0.06
local BAG_FULL_SHAKE_ANGLES = { -7, 7, -5, 5 }
local RECYCLE_SOUND_CLEANUP_TIMEOUT = 10
local PURCHASE_SOUND_CLEANUP_TIMEOUT = 10
local AREA_COMPLETION_FALLBACK_IMAGE = "rbxassetid://87612010732805"
local LEAF_HINT_FALLBACK_IMAGE = "rbxassetid://106760602256692"
local AREA_COMPLETION_HOLD_DURATION = 3
local COIN_GAIN_PULSE_SCALE = 1.15
local COIN_GAIN_PULSE_HALF_DURATION = 0.04
local DOUBLE_COIN_BASE_HOLD_DURATION = 0.3
local DOUBLE_COIN_REVEAL_DURATION = 0.6
local CENTER_REWARD_START_POSITION = UDim2.fromScale(0.5, 0.68)
local CENTER_REWARD_RISE_POSITION = UDim2.fromScale(0.5, 0.32)
local CENTER_REWARD_START_SCALE = 0.35
local CENTER_REWARD_FINAL_SCALE = 0.1
local CENTER_REWARD_RISE_DURATION = 0.45
local CENTER_REWARD_HOLD_DURATION = 1
local COIN_FLIP_LOSS_RISE_DURATION = 1
local COIN_FLIP_LOSS_FADE_DELAY = 0.2
local COIN_FLIP_LOSS_RISE_OFFSET = UDim2.fromScale(0, -0.14)
local MAXIMUM_OUTSTANDING_LEAF_HINTS = 30
local LEAF_HINT_SPAWN_INTERVAL = 0.04

local function getPrimaryAreaLeafImage(areaId)
	local areaPool = LeafConfig.AreaPools[areaId]
	local firstEntry = type(areaPool) == "table" and areaPool[1] or nil
	local leafType = type(firstEntry) == "table" and firstEntry.LeafType or nil
	local leafTypeConfig = type(leafType) == "string" and LeafConfig.Types[leafType] or nil
	local image = type(leafTypeConfig) == "table" and leafTypeConfig.Image or nil
	return type(image) == "string" and image ~= "" and image or nil
end

local function isPositiveFiniteNumber(value)
	return type(value) == "number"
		and value == value
		and value > 0
		and value < math.huge
end

local function formatLeafHintValue(value)
	local numericValue = math.max(0, tonumber(value) or 0)
	if numericValue >= 1000 then
		return "+" .. CoinFormat.Compact(numericValue)
	end
	local roundedValue = math.floor(numericValue * 10 + 0.5) / 10
	local integerValue = math.floor(roundedValue + 0.5)
	if math.abs(roundedValue - integerValue) < 1e-9 then
		return "+" .. tostring(integerValue)
	end
	return "+" .. string.format("%.1f", roundedValue)
end

local function formatMultiplier(value)
	local numericValue = tonumber(value)
	if
		numericValue == nil
		or numericValue ~= numericValue
		or numericValue == math.huge
		or numericValue == -math.huge
	then
		numericValue = 1
	end
	local formatted = string.format("%.2f", math.max(0, numericValue))
	formatted = string.gsub(formatted, "0+$", "")
	formatted = string.gsub(formatted, "%.$", "")
	return formatted
end

local function findOptionalTextLabel(parent, displayName, labelName)
	local display = parent:FindFirstChild(displayName)
	local label = display and display:FindFirstChild(labelName)
	if label == nil then
		warn(string.format("GameHUD.%s.%s is missing; multiplier display will be skipped.", displayName, labelName))
		return nil
	end
	if not (label:IsA("TextLabel") or label:IsA("TextButton") or label:IsA("TextBox")) then
		warn(string.format("GameHUD.%s.%s must be a text GUI object; multiplier display will be skipped.", displayName, labelName))
		return nil
	end
	return label
end
local CENTER_REWARD_FLY_DURATION = 0.5
local CENTER_REWARD_Z_INDEX_OFFSET = 30
local NOTIFICATION_FADE_DURATION = 0.25
local PURCHASE_TOOL_IDS = {
	"Tool02",
	"Tool03",
}

local function targetCenterInParent(parent, target)
	local targetCenter = target.AbsolutePosition + target.AbsoluteSize / 2
	return UDim2.fromOffset(
		targetCenter.X - parent.AbsolutePosition.X,
		targetCenter.Y - parent.AbsolutePosition.Y
	)
end

local function setFill(fill, ratio)
	TweenService:Create(
		fill,
		TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1) }
	):Play()
end

local function getNotificationFadeProperties(instance)
	local original = {}
	local goals = {}
	if instance:IsA("GuiObject") then
		original.BackgroundTransparency = instance.BackgroundTransparency
		goals.BackgroundTransparency = 1
	end
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		original.TextTransparency = instance.TextTransparency
		original.TextStrokeTransparency = instance.TextStrokeTransparency
		goals.TextTransparency = 1
		goals.TextStrokeTransparency = 1
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") or instance:IsA("ViewportFrame") then
		original.ImageTransparency = instance.ImageTransparency
		goals.ImageTransparency = 1
	end
	if instance:IsA("UIStroke") then
		original.Transparency = instance.Transparency
		goals.Transparency = 1
	end
	return original, goals
end

local function waitForDirectChild(parent, childName)
	local child = parent:FindFirstChild(childName)
	while not child do
		local addedChild = parent.ChildAdded:Wait()
		if addedChild.Name == childName then
			child = addedChild
		end
	end
	return child
end

local function findPath(root, path)
	local current = root
	for _, childName in path do
		current = current and current:FindFirstChild(childName)
		if not current then
			return nil
		end
	end
	return current
end

function HUDController:Init(remotes)
	self.Remotes = remotes
	self.SessionResetSucceeded = Instance.new("BindableEvent")
	local playerGui = waitForDirectChild(Players.LocalPlayer, "PlayerGui")
	local gameHUD = waitForDirectChild(playerGui, "GameHUD")
	local root = waitForDirectChild(gameHUD, "HUDRoot")
	self.GameHUD = gameHUD
	self.HUDRoot = root
	self.TimedLuckyBoxValue = nil
	self.TimedLuckyBoxNextSpawnAt = nil
	self.TimedLuckyBoxWaitingForPickup = false
	self.TimedLuckyBoxRewardKind = nil
	self.TimedLuckyBoxSnapshotReceived = false
	self.TimedLuckyBoxLastDisplayedText = nil
	self.TimedLuckyBoxRefreshElapsed = 0
	self.UpgradeMultiplierLabel = findOptionalTextLabel(
		gameHUD,
		"TrailMultiplierDisplay",
		"TrailMultiplierLabel"
	)
	self.RebirthMultiplierLabel = findOptionalTextLabel(
		gameHUD,
		"RebirthMultiplierDisplay",
		"RebirthMultiplierLabel"
	)
	self.CurrentPersonalLeafValueMultiplier = 1
	self.CurrentRebirthLeafValueMultiplier = 1
	self:_updateValueMultiplierLabels()
	self.ResetDataButton = nil
	self.ResetDataLabel = nil
	self.ResetDataDefaultText = nil
	self.CanUseAdminReset = false
	self.ResetDataRequestRunning = false
	self.CenterNoticeTemplate = nil
	self.CenterCoinRewardQueue = {}
	self.CenterCoinRewardRunning = false
	self.CenterCoinRewardSerial = 0
	self.CenterRewardTransactionQueue = {}
	self.CenterRewardTransactionRunning = false
	self.ActiveCenterCoinRewardClone = nil
	self.CenterCoinRewardRiseTween = nil
	self.CenterCoinRewardScaleTween = nil
	self.CenterCoinRewardFlyTween = nil
	self.CenterNoticeSerial = 0
	self.CoinFlipLossFrame = nil
	self.CoinFlipLossLabel = nil
	self.CoinFlipLossOriginalPosition = nil
	self.CoinFlipLossVisualEntries = {}
	self.CoinFlipLossTweens = {}
	self.CoinFlipLossSerial = 0
	self.ActiveCenterNotice = nil
	self.CompletedAreaNoticeKeys = {}
	self.AreaProgressByNoticeKey = {}
	self.AreaNoticeYardSnapshotSerials = {}
	self.AreaNoticeReadyYardOwners = {}
	self.LastRebirthCount = nil
	self.ActiveYardOwnerUserId = Players.LocalPlayer.UserId
	remotes.AreaCompletionNotice.OnClientEvent:Connect(function(completedAreaId, nextAreaId)
		self:_showAreaCompletionNotice(completedAreaId, nextAreaId, self.ActiveYardOwnerUserId)
	end)
	remotes.YardLeafSnapshot.OnClientEvent:Connect(function(packet)
		local ownerUserId = tonumber(packet.YardOwnerUserId)
		local serial = tonumber(packet.Serial)
		if packet.Kind == "Begin" then
			self.AreaNoticeYardSnapshotSerials[ownerUserId] = serial
			self.AreaNoticeReadyYardOwners[ownerUserId] = false
			for _, areaState in packet.Areas or {} do
				if areaState.Completed == true then
					local noticeKey = tostring(ownerUserId) .. ":" .. areaState.AreaId
					self.CompletedAreaNoticeKeys[noticeKey] = true
				end
			end
		elseif
			packet.Kind == "End"
			and self.AreaNoticeYardSnapshotSerials[ownerUserId] == serial
		then
			self.AreaNoticeReadyYardOwners[ownerUserId] = true
		end
	end)

	self.LossProgressFrame = nil
	self.LossProgressText = nil
	self.LossItemsList = nil
	self.LossItemTemplate = nil
	self.AreaLostItemEntries = {}

	self.CodexOpenButton = nil
	self.CodexFrame = nil
	self.CodexCloseButton = nil
	self.CodexList = nil
	self.CodexTemplate = nil
	self.CodexEntries = {}
	self.CodexUnknownRarityWarnings = {}
	self.CodexInvalidClaimedWarningShown = false
	self.CodexRarityGradientsReady = false
	self.CodexBound = false

	self.CoinsFrame = waitForDirectChild(root, "CoinsFrame")
	self.CoinsValue = waitForDirectChild(self.CoinsFrame, "Value")
	self.CoinGainValue = waitForDirectChild(self.CoinsFrame, "+Value")
	self.CoinGainGradient = waitForDirectChild(self.CoinGainValue, "UIGradient")
	self.CoinGainGradientOriginalEnabled = self.CoinGainGradient.Enabled
	self.CoinGainScale = self.CoinGainValue:FindFirstChildOfClass("UIScale")
	if not self.CoinGainScale then
		self.CoinGainScale = Instance.new("UIScale")
		self.CoinGainScale.Name = "CoinGainPulseScale"
		self.CoinGainScale.Parent = self.CoinGainValue
	end
	self.CoinGainBaseScale = self.CoinGainScale.Scale
	self.CoinGainOriginalPosition = self.CoinGainValue.Position
	self.CoinGainSerial = 0
	self.CoinGainIdleSerial = 0
	self.CoinGainPulseSerial = 0
	self.LastCoinGainSequenceId = 0
	self.PendingCoinTarget = nil
	self.PendingCoinAmount = 0
	self.PendingCoinBaseAmount = 0
	self.PendingCoinRewardMultiplier = 1
	self.DoubleCoinRevealSerial = 0
	self.DoubleCoinRevealRunning = false
	self.DoubleCoinRevealComplete = true
	self.PendingCoinHoldDuration = 1
	self.PendingCoinFlyDuration = 0.35
	self.CoinGainLastScheduledAt = nil
	self.CoinGainStepQueue = {}
	self.CoinGainStepQueueHead = 1
	self.CoinGainStepQueueTail = 0
	self.CoinGainStepWorker = nil
	self.PendingLeafSettlementId = nil
	self.PendingLeafSettlementResult = nil
	self.CoinGainValue.Text = "+0"
	self.CoinGainValue.Visible = false
	self.CoinsScale = self.CoinsFrame:FindFirstChildOfClass("UIScale")
	if not self.CoinsScale then
		self.CoinsScale = Instance.new("UIScale")
		self.CoinsScale.Name = "CoinsPulseScale"
		self.CoinsScale.Parent = self.CoinsFrame
	end
	self.CoinsBaseScale = self.CoinsScale.Scale
	self.CoinsPulseSerial = 0
	self.LastCoins = nil
	self.DisplayedCoins = nil
	self.CoinPresentationBusy = false
	self.CoinPresentationSerial = 0
	self.CoinPresentationSettled = Instance.new("BindableEvent")
	self.CoinPresentationSettled.Event:Connect(function()
		if self.CenterRewardTransactionRunning then
			self.CenterRewardTransactionRunning = false
		end
		self:_startNextCenterRewardTransaction()
	end)
	self.BagFrame = waitForDirectChild(root, "BagFrame")
	self.BagName = waitForDirectChild(self.BagFrame, "name")
	assert(self.BagName:IsA("TextLabel"), "HUDRoot.BagFrame.name must be a TextLabel")
	self.BagValue = waitForDirectChild(self.BagFrame, "Value")
	assert(self.BagValue:IsA("TextLabel"), "HUDRoot.BagFrame.Value must be a TextLabel")
	self.BagTarget = waitForDirectChild(self.BagFrame, "BarBackground")
	self.BagFill = waitForDirectChild(self.BagTarget, "Fill")
	self.BagImage = waitForDirectChild(self.BagFrame, "ImageLabel")
	self.BagFullNotificationFrame = waitForDirectChild(root, "NotificationFrame00")
	assert(self.BagFullNotificationFrame:IsA("GuiObject"), "HUDRoot.NotificationFrame00 must be a GuiObject")
	self.BagFullNotification = waitForDirectChild(self.BagFullNotificationFrame, "Notification")
	assert(self.BagFullNotification:IsA("TextLabel"), "HUDRoot.NotificationFrame00.Notification must be a TextLabel")
	self.BagFullNotificationDefaultText = self.BagFullNotification.Text
	self.BagFull = false
	self.PoopGuidanceNotificationMessage = nil
	self.BagFullNotificationFrame.Visible = false
	self.BagBaseRotation = self.BagFrame.Rotation
	self.BagFullShakeSerial = 0
	self.BagFullShakeTween = nil
	self.BagFullShakeActive = false
	self.LastBagFull = nil
	self.LastBagFullSoundAt = -math.huge
	self.AreaProgressFrame = waitForDirectChild(root, "AreaProgressFrame")
	self.AreaValue = waitForDirectChild(self.AreaProgressFrame, "Value")
	assert(self.AreaValue:IsA("TextLabel"), "HUDRoot.AreaProgressFrame.Value must be a TextLabel")
	self.AreaIcon = waitForDirectChild(self.AreaProgressFrame, "Icon")
	assert(
		self.AreaIcon:IsA("ImageLabel") or self.AreaIcon:IsA("ImageButton"),
		"HUDRoot.AreaProgressFrame.Icon must be an ImageLabel or ImageButton"
	)
	self.AreaIconDefaultImage = self.AreaIcon.Image
	self.NotificationFrame = waitForDirectChild(gameHUD, "NotificationFrame")
	assert(self.NotificationFrame:IsA("GuiObject"), "GameHUD.NotificationFrame must be a GuiObject")
	self.Notification = waitForDirectChild(self.NotificationFrame, "Notification")
	assert(self.Notification:IsA("TextLabel"), "NotificationFrame.Notification must be a TextLabel")
	self.NotificationFadeTweens = nil
	self.NotificationFadeEntries = nil
	self.NotificationSerial = 0
	self.NotificationPersistentMessage = nil
	self.NotificationTransientActive = false
	self.NotificationPriorityActive = false
	self.ExitSaveNotificationSerial = nil
	self.NotificationFrame.Visible = false
	self.HUDRoot.ClipsDescendants = false
	self.LeafHintTemplate = nil
	self.LeafHintDefaultImage = LEAF_HINT_FALLBACK_IMAGE

	self.LeafSoundTemplates = {}
	self.NextLeafSoundIndex = 1
	self.BagFullSoundTemplate = nil
	self.RecycleSoundTemplate = nil
	self.LostItemRedeemSoundTemplate = nil
	self.CoinFlipRewardSoundTemplate = nil
	self.CoinFeedbackSoundTemplates = {}
	self.CoinFeedbackSoundPools = {
		Recycle = {},
		LostItem = {},
		CoinFlip = {},
	}
	self.ActiveCoinFeedbackSounds = {}
	self.CoinFeedbackSoundPlaybackSerial = 0
	self.CoinFeedbackSoundQueue = {}
	self.CoinFeedbackSoundQueueHead = 1
	self.CoinFeedbackSoundQueueTail = 0
	self.CoinFeedbackSoundWorker = nil
	self.CoinFeedbackSoundLastScheduledAt = nil
	self.PurchaseSuccessSoundTemplate = nil
	self.LastPurchaseBagLevel = nil
	self.LastPurchaseBagExpansionLevel = nil
	self.LastPurchaseUnlockedTools = nil
	self.CurrentLeafValueMultiplier = 1
	self.OutstandingLeafHintCount = 0
	self.LeafHintRandom = Random.new()
	self.ScheduledLeafHints = {}
	self.ScheduledLeafHintHead = 1
	self.ScheduledLeafHintTail = 0
	self.LeafHintPacingConnection = nil
	self.LastLeafHintSpawnAt = -math.huge
	self.LatestSnapshot = nil
	self.OptionalPresentationWarnings = {}
	self:_tryBindOptionalPresentation()
	self.TimedLuckyBoxTimerConnection = RunService.Heartbeat:Connect(function(deltaTime)
		self.TimedLuckyBoxRefreshElapsed += deltaTime
		if self.TimedLuckyBoxRefreshElapsed >= 0.25 then
			self.TimedLuckyBoxRefreshElapsed = 0
			self:_updateTimedLuckyBoxCountdown()
		end
	end)
	gameHUD.DescendantAdded:Connect(function(descendant)
		local current = descendant
		while current.Parent and current.Parent ~= gameHUD and current.Parent ~= root do
			current = current.Parent
		end
		local relevantRootChild = current.Parent == root
			and (
				current.Name == "00"
				or current.Name == "GetDiamond"
				or current.Name == "coinsX"
				or current.Name == "Lossofprogress"
				or current.Name == "GetHint"
				or current.Name == "time"
			)
		local relevantHUDChild = current.Parent == gameHUD
			and (current.Name == "Codex" or current.Name == "Frame")
		if not relevantRootChild and not relevantHUDChild then
			return
		end
		task.defer(function()
			self:_tryBindOptionalPresentation()
		end)
	end)
	SoundService.ChildAdded:Connect(function(child)
		if
			child.Name ~= "Grass_walk_1"
			and child.Name ~= "Grass_walk_2"
			and child.Name ~= "Grass_walk_3"
			and child.Name ~= "full"
			and child.Name ~= "Recycle"
			and child.Name ~= "demo"
			and child.Name ~= "x2coin"
			and child.Name ~= "BUYyes"
		then
			return
		end
		task.defer(function()
			self:_tryBindOptionalPresentation()
		end)
	end)

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
	remotes.Notification.OnClientEvent:Connect(function(message, holdDuration, priority)
		self:ShowNotification(message, holdDuration, priority)
	end)
	remotes.LeafCollected.OnClientEvent:Connect(function(addedAmount, leafType, _, leafHints)
		self:_showLeafCollectedHints(addedAmount, leafType, leafHints)
	end)
	remotes.LeafPickupBatch.OnClientEvent:Connect(function(_, _, collectedCount)
		self:_playLeafPickupSound(collectedCount)
	end)
	remotes.BagFullPickupAttempt.OnClientEvent:Connect(function()
		self.BagFull = true
		self:_refreshStatusNotification()
		self:_playBagFullSound()
	end)
	remotes.CoinGainEvent.OnClientEvent:Connect(function(event)
		self:_receiveCoinGainEvent(event)
	end)
end

function HUDController:_bindAdminResetIfAvailable()
	if self.ResetDataButton then
		return
	end
	local button = self.HUDRoot:FindFirstChild("00")
	local label = button and button:FindFirstChild("Label")
	if not button or not button:IsA("GuiButton") or not label or not label:IsA("TextLabel") then
		return
	end

	self.ResetDataButton = button
	self.ResetDataLabel = label
	self.ResetDataDefaultText = label.Text
	button.Visible = false
	button.Active = false
	button.Interactable = false
	button.Activated:Connect(function()
		if self.ResetDataRequestRunning or not self.CanUseAdminReset then
			return
		end
		self.ResetDataRequestRunning = true
		button.Active = false
		button.Interactable = false
		local invokeSucceeded, success, message = pcall(function()
			return self.Remotes.ResetPlayerData:InvokeServer()
		end)
		if not invokeSucceeded then
			success = false
			message = "Reset request failed. Try again."
		end
		if success then
			self.SessionResetSucceeded:Fire()
			label.Text = "Reset"
			table.clear(self.CompletedAreaNoticeKeys)
			table.clear(self.AreaProgressByNoticeKey)
		end
		self:ShowNotification(message, 3, true)
		self.ResetDataRequestRunning = false
		button.Active = self.CanUseAdminReset
		button.Interactable = self.CanUseAdminReset
		if success then
			task.delay(2, function()
				if
					self.ResetDataButton == button
					and self.CanUseAdminReset
					and not self.ResetDataRequestRunning
				then
					label.Text = self.ResetDataDefaultText
				end
			end)
		end
	end)
end

function HUDController:_bindCenterNoticeIfAvailable()
	if self.CenterNoticeTemplate then
		return
	end
	local template = self.HUDRoot:FindFirstChild("GetDiamond")
	local textLabel = template and template:FindFirstChild("TextLabel")
	local icon = template and template:FindFirstChild("Icon")
	if
		not template
		or not template:IsA("GuiObject")
		or not textLabel
		or not textLabel:IsA("TextLabel")
		or not icon
		or not icon:IsA("ImageLabel")
	then
		return
	end
	template.Visible = false
	textLabel.Text = "+0"
	icon.Image = LostItemConfig.CoinImage
	self.CenterNoticeTemplate = template
end

function HUDController:_bindCoinFlipLossIfAvailable()
	if self.CoinFlipLossFrame then
		return
	end
	local frame = self.HUDRoot:FindFirstChild("coinsX")
	local label = frame and frame:FindFirstChild("Notification")
	if not frame or not frame:IsA("GuiObject") or not label or not label:IsA("TextLabel") then
		return
	end

	self.CoinFlipLossFrame = frame
	self.CoinFlipLossLabel = label
	self.CoinFlipLossOriginalPosition = frame.Position
	table.clear(self.CoinFlipLossVisualEntries)
	for _, instance in { frame, table.unpack(frame:GetDescendants()) } do
		local original, goals = getNotificationFadeProperties(instance)
		if next(original) ~= nil then
			table.insert(self.CoinFlipLossVisualEntries, {
				Instance = instance,
				Original = original,
				Goals = goals,
			})
		end
	end
	frame.Visible = false
end

function HUDController:_bindLostItemProgressIfAvailable()
	if self.LossProgressFrame then
		return
	end
	local frame = self.HUDRoot:FindFirstChild("Lossofprogress")
	local textLabel = frame and frame:FindFirstChild("TextLabel")
	local list = frame and frame:FindFirstChild("ScrollingFrame")
	local template = list and list:FindFirstChild("ItemFrame")
	local icon = template and template:FindFirstChild("ImageLabel")
	if
		not frame
		or not frame:IsA("GuiObject")
		or not textLabel
		or not textLabel:IsA("TextLabel")
		or not list
		or not list:IsA("GuiObject")
		or not template
		or not template:IsA("GuiObject")
		or not icon
		or not icon:IsA("ImageLabel")
	then
		return
	end

	self.LossProgressFrame = frame
	self.LossProgressText = textLabel
	self.LossItemsList = list
	self.LossItemTemplate = template
	template.Visible = false
end

function HUDController:_bindCodexIfAvailable()
	if self.CodexBound then
		return
	end
	local openButton = findPath(self.GameHUD, { "Frame", "Codex" })
	local frame = self.GameHUD:FindFirstChild("Codex")
	local closeButton = frame and findPath(frame, { "Banner", "Close" })
	local list = frame and findPath(frame, { "ListHolder", "AchievementsList", "List" })
	local template = list and list:FindFirstChild("Template")
	local main = template and template:FindFirstChild("Main")
	local requiredTemplateObjects = {
		{ Path = { "Name" }, ClassName = "TextLabel" },
		{ Path = { "Difficulty" }, ClassName = "TextLabel" },
		{ Path = { "Description" }, ClassName = "TextLabel" },
		{ Path = { "IconFrame", "Icon" }, ClassName = "ImageLabel" },
		{ Path = { "IconFrame", "Amount" }, ClassName = "TextLabel" },
		{ Path = { "IconFrame", "cost" }, IsText = true },
		{ Path = { "Claim" }, ClassName = "GuiButton" },
		{ Path = { "Claim", "Title" }, IsText = true },
	}
	if
		not openButton
		or not openButton:IsA("GuiButton")
		or not frame
		or not frame:IsA("GuiObject")
		or not closeButton
		or not closeButton:IsA("GuiButton")
		or not list
		or not list:IsA("GuiObject")
		or not template
		or not template:IsA("GuiObject")
		or not main
	then
		return
	end
	for _, requirement in requiredTemplateObjects do
		local instance = findPath(main, requirement.Path)
		local validText = instance
			and requirement.IsText == true
			and (instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox"))
		local validClass = instance
			and requirement.ClassName ~= nil
			and instance:IsA(requirement.ClassName)
		if not validText and not validClass then
			return
		end
	end

	self.CodexOpenButton = openButton
	self.CodexFrame = frame
	self.CodexCloseButton = closeButton
	self.CodexList = list
	self.CodexTemplate = template
	template.Visible = false
	frame.Visible = false
	ModalPanelEffects.BindOpenButton(openButton)
	self.CodexRarityGradientsReady = self:_validateCodexRarityGradientTemplate()
	self:_buildCodexEntries()
	self.CodexBound = true
	self:_applyCodexCounts({}, {})
	ModalPanelCoordinator.Register(CODEX_MODAL_PANEL_ID, function()
		self:_setCodexVisible(false)
	end)
	openButton.Activated:Connect(function()
		self:_setCodexVisible(not frame.Visible)
	end)
	closeButton.Activated:Connect(function()
		self:_setCodexVisible(false)
	end)
end

function HUDController:_bindLeafHintIfAvailable()
	if self.LeafHintTemplate then
		return
	end
	local template = self.HUDRoot:FindFirstChild("GetHint")
	local textLabel = template and template:FindFirstChild("TextLabel")
	local icon = template and template:FindFirstChild("Icon")
	if
		not template
		or not template:IsA("GuiObject")
		or not textLabel
		or not textLabel:IsA("TextLabel")
		or not icon
		or not icon:IsA("ImageLabel")
	then
		return
	end
	self.LeafHintTemplate = template
	self.LeafHintDefaultImage = if icon.Image ~= "" then icon.Image else LEAF_HINT_FALLBACK_IMAGE
	template.Visible = false
end

function HUDController:_updateTimedLuckyBoxCountdown()
	local label = self.TimedLuckyBoxValue
	if not label or not label.Parent then
		self.TimedLuckyBoxValue = nil
		return
	end

	local displayText = "--"
	if self.TimedLuckyBoxSnapshotReceived == true then
		local nextSpawnAt = self.TimedLuckyBoxNextSpawnAt
		if self.TimedLuckyBoxWaitingForPickup == true then
			displayText = "0m0s"
		elseif type(nextSpawnAt) == "number" then
			local remainingSeconds = math.max(
				0,
				math.ceil(nextSpawnAt - Workspace:GetServerTimeNow())
			)
			displayText = string.format(
				"%dm%ds",
				math.floor(remainingSeconds / 60),
				remainingSeconds % 60
			)
		elseif self.TimedLuckyBoxRewardKind ~= nil then
			displayText = "0m0s"
		end
	end

	if self.TimedLuckyBoxLastDisplayedText ~= displayText or label.Text ~= displayText then
		self.TimedLuckyBoxLastDisplayedText = displayText
		label.Text = displayText
	end
end

function HUDController:_bindTimedLuckyBoxCountdownIfAvailable()
	if self.TimedLuckyBoxValue and self.TimedLuckyBoxValue.Parent then
		return
	end
	local timerFrame = self.HUDRoot:FindFirstChild("time")
	local value = timerFrame and timerFrame:FindFirstChild("Value")
	if
		not timerFrame
		or not timerFrame:IsA("GuiObject")
		or not value
		or not (value:IsA("TextLabel") or value:IsA("TextButton") or value:IsA("TextBox"))
	then
		return
	end
	self.TimedLuckyBoxValue = value
	self.TimedLuckyBoxLastDisplayedText = nil
	self:_updateTimedLuckyBoxCountdown()
end

function HUDController:_bindOptionalSounds()
	table.clear(self.LeafSoundTemplates)
	for _, soundName in { "Grass_walk_1", "Grass_walk_2", "Grass_walk_3" } do
		local sound = SoundService:FindFirstChild(soundName)
		if sound and sound:IsA("Sound") then
			table.insert(self.LeafSoundTemplates, sound)
		end
	end
	self.NextLeafSoundIndex = math.clamp(self.NextLeafSoundIndex, 1, math.max(1, #self.LeafSoundTemplates))

	local bagFullSound = SoundService:FindFirstChild("full")
	self.BagFullSoundTemplate = if bagFullSound and bagFullSound:IsA("Sound") then bagFullSound else nil
	local recycleSound = SoundService:FindFirstChild("Recycle")
	local lostItemSound = SoundService:FindFirstChild("demo")
	local coinFlipSound = SoundService:FindFirstChild("x2coin")
	self.RecycleSoundTemplate = if recycleSound and recycleSound:IsA("Sound") then recycleSound else nil
	self.LostItemRedeemSoundTemplate = if lostItemSound and lostItemSound:IsA("Sound") then lostItemSound else nil
	self.CoinFlipRewardSoundTemplate = if coinFlipSound and coinFlipSound:IsA("Sound") then coinFlipSound else nil
	self.CoinFeedbackSoundTemplates.Recycle = self.RecycleSoundTemplate
	self.CoinFeedbackSoundTemplates.LostItem = self.LostItemRedeemSoundTemplate
	self.CoinFeedbackSoundTemplates.CoinFlip = self.CoinFlipRewardSoundTemplate
	local purchaseSound = SoundService:FindFirstChild("BUYyes")
	self.PurchaseSuccessSoundTemplate = if purchaseSound and purchaseSound:IsA("Sound") then purchaseSound else nil
end

function HUDController:_applyOptionalSnapshot(snapshot)
	if self.ResetDataButton then
		self.ResetDataButton.Visible = self.CanUseAdminReset
		self.ResetDataButton.Active = self.CanUseAdminReset and not self.ResetDataRequestRunning
		self.ResetDataButton.Interactable = self.CanUseAdminReset and not self.ResetDataRequestRunning
	end
	if self.LossProgressText then
		local found = math.max(0, math.floor(tonumber(snapshot.AreaLostItemsFound) or 0))
		local total = math.max(0, math.floor(tonumber(snapshot.AreaLostItemsTotal) or 0))
		self.LossProgressText.Text = string.format("Lost Items Found: %d/%d", found, total)
		self:_applyAreaLostItems(snapshot.AreaFoundLostItems or {})
	end
	if self.CodexBound then
		self:_applyCodexCounts(snapshot.LostItemCollectedCounts, snapshot.CodexClaimedTiers)
	end
	self:_updateTimedLuckyBoxCountdown()
end

function HUDController:_tryBindOptionalPresentation()
	local bindings = {
		{ Name = "AdminReset", Callback = function() self:_bindAdminResetIfAvailable() end },
		{ Name = "CenterNotice", Callback = function() self:_bindCenterNoticeIfAvailable() end },
		{ Name = "CoinFlipLoss", Callback = function() self:_bindCoinFlipLossIfAvailable() end },
		{ Name = "LostItemProgress", Callback = function() self:_bindLostItemProgressIfAvailable() end },
		{ Name = "Codex", Callback = function() self:_bindCodexIfAvailable() end },
		{ Name = "LeafHint", Callback = function() self:_bindLeafHintIfAvailable() end },
		{ Name = "TimedLuckyBoxCountdown", Callback = function() self:_bindTimedLuckyBoxCountdownIfAvailable() end },
		{ Name = "Sounds", Callback = function() self:_bindOptionalSounds() end },
	}
	for _, binding in bindings do
		local succeeded, message = xpcall(binding.Callback, debug.traceback)
		if not succeeded and not self.OptionalPresentationWarnings[binding.Name] then
			self.OptionalPresentationWarnings[binding.Name] = true
			warn(string.format("HUD optional presentation %s is disabled: %s", binding.Name, tostring(message)))
		end
	end
	if self.LatestSnapshot then
		self:_applyOptionalSnapshot(self.LatestSnapshot)
	end
end

function HUDController:ConnectSessionResetSucceeded(callback)
	return self.SessionResetSucceeded.Event:Connect(callback)
end

function HUDController:_updateValueMultiplierLabels()
	if self.UpgradeMultiplierLabel then
		self.UpgradeMultiplierLabel.Text = string.format(
			"Multiplier x%s (Upgrade)",
			formatMultiplier(self.CurrentPersonalLeafValueMultiplier)
		)
	end
	if self.RebirthMultiplierLabel then
		self.RebirthMultiplierLabel.Text = string.format(
			"Multiplier x%s (Rebirth)",
			formatMultiplier(self.CurrentRebirthLeafValueMultiplier)
		)
	end
end

function HUDController:_setCoinPresentationBusy(busy)
	local shouldBeBusy = busy == true
	if
		not shouldBeBusy
		and (
			self.CenterCoinRewardRunning
			or #self.CenterCoinRewardQueue > 0
			or self.PendingCoinTarget ~= nil
			or self.CoinGainStepWorker ~= nil
		)
	then
		return
	end
	if self.CoinPresentationBusy == shouldBeBusy then
		return
	end
	self.CoinPresentationBusy = shouldBeBusy
	self.CoinPresentationSerial += 1
	if not shouldBeBusy then
		local serial = self.CoinPresentationSerial
		task.defer(function()
			if serial == self.CoinPresentationSerial and not self.CoinPresentationBusy then
				self.CoinPresentationSettled:Fire(self.DisplayedCoins)
			end
		end)
	end
end

function HUDController:IsCoinPresentationBusy()
	return self.CoinPresentationBusy == true
end

function HUDController:ConnectCoinPresentationSettled(callback)
	return self.CoinPresentationSettled.Event:Connect(callback)
end

function HUDController:_setCodexVisible(visible)
	if not self.CodexBound or not self.CodexFrame then
		return
	end
	local shouldBeVisible = visible == true
	local wasVisible = self.CodexFrame.Visible
	if shouldBeVisible then
		ModalPanelCoordinator.Open(CODEX_MODAL_PANEL_ID)
	else
		ModalPanelCoordinator.Close(CODEX_MODAL_PANEL_ID)
	end
	if shouldBeVisible and not wasVisible then
		ModalPanelEffects.PlayOpen(self.CodexFrame)
	elseif not shouldBeVisible then
		ModalPanelEffects.StopOpen(self.CodexFrame)
		self.CodexFrame.Visible = false
	end
end

function HUDController:_validateCodexRarityGradientTemplate()
	local main = self.CodexTemplate:FindFirstChild("Main")
	local issues = {}
	if not main then
		table.insert(issues, "GameHUD.Codex.ListHolder.AchievementsList.List.Template.Main is missing")
	elseif #LostItemConfig.RarityOrder ~= #CODEX_RARITY_GRADIENT_NAMES then
		table.insert(issues, "LostItemConfig.RarityOrder must match the five Codex gradients")
	else
		for _, gradientName in CODEX_RARITY_GRADIENT_NAMES do
			local gradient = main:FindFirstChild(gradientName)
			local path = "GameHUD.Codex.ListHolder.AchievementsList.List.Template.Main." .. gradientName
			if not gradient then
				table.insert(issues, path .. " is missing")
			elseif not gradient:IsA("UIGradient") then
				table.insert(issues, path .. " must be a UIGradient (found " .. gradient.ClassName .. ")")
			end
		end
	end
	if #issues > 0 then
		warn("Codex rarity gradients disabled: " .. table.concat(issues, "; "))
		return false
	end
	return true
end

function HUDController:_applyCodexRarityGradient(main, rarityId)
	local rarityIndex = table.find(LostItemConfig.RarityOrder, rarityId)
	if type(rarityIndex) ~= "number" or CODEX_RARITY_GRADIENT_NAMES[rarityIndex] == nil then
		local warningKey = tostring(rarityId)
		if not self.CodexUnknownRarityWarnings[warningKey] then
			self.CodexUnknownRarityWarnings[warningKey] = true
			warn("Codex rarity gradient skipped for unknown rarity: " .. warningKey)
		end
		return
	end
	if not self.CodexRarityGradientsReady then
		return
	end
	for gradientIndex, gradientName in CODEX_RARITY_GRADIENT_NAMES do
		local gradient = main:FindFirstChild(gradientName)
		if gradient and gradient:IsA("UIGradient") then
			gradient.Enabled = gradientIndex == rarityIndex
		end
	end
end

function HUDController:_buildCodexEntries()
	for index, lostItemId in LostItemConfig.Order do
		local config = LostItemConfig.Types[lostItemId]
		local clone = self.CodexTemplate:Clone()
		clone.Name = "LostItemEntry_" .. lostItemId
		clone.LayoutOrder = index
		clone.Visible = true

		local main = clone:WaitForChild("Main")
		local nameLabel = main:WaitForChild("Name")
		local difficultyLabel = main:WaitForChild("Difficulty")
		local descriptionLabel = main:WaitForChild("Description")
		local iconFrame = main:WaitForChild("IconFrame")
		local icon = iconFrame:WaitForChild("Icon")
		local amount = iconFrame:WaitForChild("Amount")
		local cost = iconFrame:WaitForChild("cost")
		local claim = main:WaitForChild("Claim")
		local claimTitle = claim:WaitForChild("Title")
		local claimed = main:FindFirstChild("Claimed")
		if claimed and not claimed:IsA("GuiObject") then
			if not self.CodexInvalidClaimedWarningShown then
				self.CodexInvalidClaimedWarningShown = true
				warn(
					"Codex Template.Main.Claimed must be a GuiObject when present; "
						.. "the optional completion indicator will be ignored"
				)
			end
			claimed = nil
		end
		self:_applyCodexRarityGradient(main, config.RarityId)
		assert(
			cost:IsA("TextLabel") or cost:IsA("TextButton") or cost:IsA("TextBox"),
			"Codex Template.Main.IconFrame.cost must be a text GuiObject"
		)
		assert(claim:IsA("GuiButton"), "Codex Template.Main.Claim must be a GuiButton")
		assert(
			claimTitle:IsA("TextLabel") or claimTitle:IsA("TextButton") or claimTitle:IsA("TextBox"),
			"Codex Template.Main.Claim.Title must be a text GuiObject"
		)
		nameLabel.Text = config.DisplayName
		difficultyLabel.Text = config.Difficulty
		difficultyLabel.TextColor3 = config.DifficultyColor
		descriptionLabel.Text = config.Description
		icon.Image = config.Image
		amount.Text = "0/5"
		cost.Text = "$" .. CoinFormat.Compact(config.CoinValue)

		claim.Visible = true
		if claimed then
			claimed.Visible = false
		end

		clone.Parent = self.CodexList
		self.CodexEntries[lostItemId] = {
			Container = clone,
			Icon = icon,
			Amount = amount,
			Cost = cost,
			Claim = claim,
			ClaimTitle = claimTitle,
			Claimed = claimed,
			ClaimBusy = false,
			CollectedCount = 0,
			TargetCount = LostItemConfig.CodexMilestones[1],
		}
		claim.Activated:Connect(function()
			self:_claimCodexReward(lostItemId)
		end)
	end
end

function HUDController:_applyCodexCounts(collectedCounts, claimedTiers)
	if not self.CodexBound then
		return
	end
	collectedCounts = collectedCounts or {}
	claimedTiers = claimedTiers or {}
	local milestones = LostItemConfig.CodexMilestones
	for _, lostItemId in LostItemConfig.Order do
		local entry = self.CodexEntries[lostItemId]
		if entry then
			entry.Cost.Text = "$" .. CoinFormat.Compact(LostItemConfig.GetRedeemCoinValue(
				lostItemId,
				self.CurrentLeafValueMultiplier
			))
			local count = math.max(0, math.floor(tonumber(collectedCounts[lostItemId]) or 0))
			local claimedTier = math.clamp(
				math.floor(tonumber(claimedTiers[lostItemId]) or 0),
				0,
				#milestones
			)
			local targetCount = milestones[claimedTier + 1]
			if targetCount then
				entry.CollectedCount = count
				entry.TargetCount = targetCount
				entry.Amount.Text = string.format("%d/%d", math.min(count, targetCount), targetCount)
				entry.ClaimTitle.Text = "Claim " .. CoinFormat.Compact(
					LostItemConfig.GetCodexCoinReward(targetCount)
				)
				entry.Claim.Visible = true
				entry.Claim.Active = not entry.ClaimBusy
				if entry.Claimed then
					entry.Claimed.Visible = false
				end
			else
				local finalTarget = milestones[#milestones]
				entry.CollectedCount = count
				entry.TargetCount = nil
				entry.Amount.Text = string.format("%d/%d", finalTarget, finalTarget)
				entry.Claim.Visible = false
				entry.Claim.Active = false
				if entry.Claimed then
					entry.Claimed.Visible = true
				end
			end
			entry.Icon.Image = LostItemConfig.Types[lostItemId].Image
			entry.Icon.ImageColor3 = if count > 0 then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
		end
	end
end

function HUDController:_claimCodexReward(lostItemId)
	local entry = self.CodexEntries[lostItemId]
	if not entry or entry.ClaimBusy or not entry.Claim.Visible then
		return
	end
	if not entry.TargetCount then
		return
	end
	if entry.CollectedCount < entry.TargetCount then
		self:ShowNotification(string.format(
			"Collect %d to claim %s Coins",
			entry.TargetCount,
			CoinFormat.Compact(LostItemConfig.GetCodexCoinReward(entry.TargetCount))
		))
		return
	end

	entry.ClaimBusy = true
	entry.Claim.Active = false
	task.spawn(function()
		local invoked, claimed, message = pcall(function()
			return self.Remotes.ClaimCodexReward:InvokeServer(lostItemId)
		end)
		entry.ClaimBusy = false
		entry.Claim.Active = entry.Claim.Visible
		if not invoked then
			self:ShowNotification("Codex reward claim failed. Try again.")
		elseif not claimed and type(message) == "string" and message ~= "" then
			self:ShowNotification(message)
		end
	end)
end

function HUDController:_applyAreaLostItems(foundItems)
	if not self.LossItemTemplate or not self.LossItemsList then
		return
	end
	foundItems = type(foundItems) == "table" and foundItems or {}
	local desiredEntries = {}
	for index, foundItem in foundItems do
		local spawnId = foundItem.SpawnId
		local config = LostItemConfig.Types[foundItem.LostItemId]
		desiredEntries[spawnId] = true
		local entry = self.AreaLostItemEntries[spawnId]
		if not entry then
			entry = self.LossItemTemplate:Clone()
			entry.Name = "FoundLostItem_" .. spawnId
			entry.Visible = true
			entry.Parent = self.LossItemsList
			self.AreaLostItemEntries[spawnId] = entry
		end

		entry.LayoutOrder = index
		entry.ImageLabel.Image = config.Image
		entry.ImageLabel.ImageColor3 = Color3.new(1, 1, 1)
	end

	for spawnId, entry in self.AreaLostItemEntries do
		if not desiredEntries[spawnId] then
			entry:Destroy()
			self.AreaLostItemEntries[spawnId] = nil
		end
	end
end

function HUDController:_playLeafPickupSound(collectedCount)
	local templateCount = #self.LeafSoundTemplates
	if templateCount <= 0 then
		return
	end
	local soundIndex = self.NextLeafSoundIndex
	local template = self.LeafSoundTemplates[soundIndex]
	self.NextLeafSoundIndex = soundIndex % templateCount + 1

	local sound = template:Clone()
	sound.Name = "LeafPickupSound"
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.TimePosition = 0
	sound.Parent = SoundService

	sound.Ended:Once(function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
	Debris:AddItem(sound, LEAF_SOUND_CLEANUP_TIMEOUT)
	SoundService:PlayLocalSound(sound)
end

function HUDController:_playBagFullSound()
	if not self.BagFullSoundTemplate then
		return
	end
	local now = os.clock()
	if now - self.LastBagFullSoundAt < BAG_FULL_SOUND_COOLDOWN then
		return
	end
	self.LastBagFullSoundAt = now
	local template = self.BagFullSoundTemplate
	local sound = template:Clone()
	sound.Name = "BagFullAttemptSound"
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.TimePosition = 0
	sound.Parent = SoundService

	sound.Ended:Once(function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
	Debris:AddItem(sound, BAG_FULL_SOUND_CLEANUP_TIMEOUT)
	SoundService:PlayLocalSound(sound)
end

function HUDController:_refreshStatusNotification()
	if self.BagFull then
		self.BagFullNotification.Text = self.BagFullNotificationDefaultText
		self.BagFullNotificationFrame.Visible = true
	elseif self.PoopGuidanceNotificationMessage then
		self.BagFullNotification.Text = self.PoopGuidanceNotificationMessage
		self.BagFullNotificationFrame.Visible = true
	else
		self.BagFullNotification.Text = self.BagFullNotificationDefaultText
		self.BagFullNotificationFrame.Visible = false
	end
end

function HUDController:SetPoopGuidanceNotification(message)
	self.PoopGuidanceNotificationMessage = if type(message) == "string" and message ~= "" then message else nil
	self:_refreshStatusNotification()
end

function HUDController:_cancelBagFullShake()
	self.BagFullShakeSerial += 1
	if self.BagFullShakeTween then
		self.BagFullShakeTween:Cancel()
		self.BagFullShakeTween = nil
	end
	self.BagFrame.Rotation = self.BagBaseRotation
end

function HUDController:_startBagFullShake()
	self:_cancelBagFullShake()
	local serial = self.BagFullShakeSerial
	task.spawn(function()
		while self.BagFullShakeActive and serial == self.BagFullShakeSerial do
			for _, angleOffset in BAG_FULL_SHAKE_ANGLES do
				if not self.BagFullShakeActive or serial ~= self.BagFullShakeSerial then
					return
				end
				local tween = TweenService:Create(
					self.BagFrame,
					TweenInfo.new(BAG_FULL_SHAKE_STEP_DURATION, Enum.EasingStyle.Linear),
					{ Rotation = self.BagBaseRotation + angleOffset }
				)
				self.BagFullShakeTween = tween
				tween:Play()
				tween.Completed:Wait()
			end
		end
	end)
end

function HUDController:SetBagFullHoldFeedbackActive(active)
	local shouldBeActive = active == true
	if self.BagFullShakeActive == shouldBeActive then
		return
	end
	self.BagFullShakeActive = shouldBeActive
	if shouldBeActive then
		self:_startBagFullShake()
	else
		self:_cancelBagFullShake()
	end
end

function HUDController:_releaseCoinFeedbackSound(sound, soundKind, playbackSerial)
	if self.ActiveCoinFeedbackSounds[sound] ~= playbackSerial then
		return
	end
	self.ActiveCoinFeedbackSounds[sound] = nil
	sound:Stop()
	sound.TimePosition = 0
	if sound.Parent and self.CoinFeedbackSoundPools[soundKind] then
		table.insert(self.CoinFeedbackSoundPools[soundKind], sound)
	end
end

function HUDController:_createCoinFeedbackSound(soundKind)
	local template = self.CoinFeedbackSoundTemplates[soundKind]
	if not template then
		return nil
	end
	local sound = template:Clone()
	sound.Name = soundKind .. "FeedbackSound"
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.TimePosition = 0
	sound.Parent = SoundService
	sound.Ended:Connect(function()
		local playbackSerial = self.ActiveCoinFeedbackSounds[sound]
		if playbackSerial then
			self:_releaseCoinFeedbackSound(sound, soundKind, playbackSerial)
		end
	end)
	return sound
end

function HUDController:_playCoinFeedbackSound(soundKind)
	local pool = self.CoinFeedbackSoundPools[soundKind]
	if not pool then
		return
	end
	local sound = table.remove(pool) or self:_createCoinFeedbackSound(soundKind)
	if not sound then
		return
	end
	self.CoinFeedbackSoundPlaybackSerial += 1
	local playbackSerial = self.CoinFeedbackSoundPlaybackSerial
	self.ActiveCoinFeedbackSounds[sound] = playbackSerial
	sound.TimePosition = 0
	SoundService:PlayLocalSound(sound)
	task.delay(RECYCLE_SOUND_CLEANUP_TIMEOUT, function()
		self:_releaseCoinFeedbackSound(sound, soundKind, playbackSerial)
	end)
end

function HUDController:_startCoinFeedbackSoundWorker()
	if self.CoinFeedbackSoundWorker then
		return
	end

	local workerThread
	workerThread = task.defer(function()
		while self.CoinFeedbackSoundQueueHead <= self.CoinFeedbackSoundQueueTail do
			local entry = self.CoinFeedbackSoundQueue[self.CoinFeedbackSoundQueueHead]
			self.CoinFeedbackSoundQueue[self.CoinFeedbackSoundQueueHead] = nil
			self.CoinFeedbackSoundQueueHead += 1
			if entry then
				local waitDuration = entry.ScheduledAt - os.clock()
				if waitDuration > 0 then
					task.wait(waitDuration)
				end
				self:_playCoinFeedbackSound(entry.SoundKind)
			end
		end

		self.CoinFeedbackSoundQueue = {}
		self.CoinFeedbackSoundQueueHead = 1
		self.CoinFeedbackSoundQueueTail = 0
		self.CoinFeedbackSoundLastScheduledAt = nil
		if self.CoinFeedbackSoundWorker == workerThread then
			self.CoinFeedbackSoundWorker = nil
		end
	end)
	self.CoinFeedbackSoundWorker = workerThread
end

function HUDController:_queueCoinFeedbackSounds(event)
	if event.Phase == "Settle" then
		return
	end
	local hasExplicitSound = event.SoundKind == "Recycle"
		or event.SoundKind == "LostItem"
		or event.SoundKind == "CoinFlip"
	local soundKind = if hasExplicitSound then event.SoundKind else "Recycle"
	local rawSoundCount = if hasExplicitSound then event.SoundCount else event.StepCount
	local soundCount = math.max(
		0,
		math.floor(tonumber(rawSoundCount) or 0)
	)
	if soundCount <= 0 then
		return
	end
	local rawFirstDelay = if hasExplicitSound then event.SoundFirstDelay else event.FirstStepDelay
	local rawSoundInterval = if hasExplicitSound then event.SoundInterval else event.StepInterval
	local firstDelay = math.max(0, tonumber(rawFirstDelay) or 0)
	local soundInterval = math.max(0.05, tonumber(rawSoundInterval) or 0.1)
	local scheduleNow = os.clock()
	local lastScheduledAt = self.CoinFeedbackSoundLastScheduledAt
	for soundIndex = 1, soundCount do
		local requestedAt = scheduleNow + firstDelay + (soundIndex - 1) * soundInterval
		local scheduledAt = if lastScheduledAt
			then math.max(requestedAt, lastScheduledAt + soundInterval)
			else requestedAt
		lastScheduledAt = scheduledAt
		self.CoinFeedbackSoundQueueTail += 1
		self.CoinFeedbackSoundQueue[self.CoinFeedbackSoundQueueTail] = {
			SoundKind = soundKind,
			ScheduledAt = scheduledAt,
		}
	end
	self.CoinFeedbackSoundLastScheduledAt = lastScheduledAt
	self:_startCoinFeedbackSoundWorker()
end

function HUDController:_playPurchaseSuccessSound()
	if not self.PurchaseSuccessSoundTemplate then
		return
	end
	local sound = self.PurchaseSuccessSoundTemplate:Clone()
	sound.Name = "PurchaseSuccessSound"
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.TimePosition = 0
	sound.Parent = SoundService

	sound.Ended:Once(function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
	Debris:AddItem(sound, PURCHASE_SOUND_CLEANUP_TIMEOUT)
	SoundService:PlayLocalSound(sound)
end

function HUDController:_applyPurchaseSoundSnapshot(snapshot)
	local bagLevel = math.max(0, math.floor(tonumber(snapshot.BagLevel) or 0))
	local bagExpansionLevel = math.max(0, math.floor(tonumber(snapshot.BagExpansionLevel) or 0))
	local unlockedTools = type(snapshot.UnlockedTools) == "table" and snapshot.UnlockedTools or {}
	if self.LastPurchaseBagLevel == nil then
		self.LastPurchaseBagLevel = bagLevel
		self.LastPurchaseBagExpansionLevel = bagExpansionLevel
		self.LastPurchaseUnlockedTools = {}
		for _, toolId in PURCHASE_TOOL_IDS do
			self.LastPurchaseUnlockedTools[toolId] = unlockedTools[toolId] == true
		end
		return
	end

	local purchased = bagLevel > self.LastPurchaseBagLevel
		or bagExpansionLevel > self.LastPurchaseBagExpansionLevel
	self.LastPurchaseBagLevel = bagLevel
	self.LastPurchaseBagExpansionLevel = bagExpansionLevel
	for _, toolId in PURCHASE_TOOL_IDS do
		local unlocked = unlockedTools[toolId] == true
		if unlocked and self.LastPurchaseUnlockedTools[toolId] ~= true then
			purchased = true
		end
		self.LastPurchaseUnlockedTools[toolId] = unlocked
	end
	if purchased then
		self:_playPurchaseSuccessSound()
	end
end

function HUDController:_showAreaCompletionNotice(completedAreaId, nextAreaId, yardOwnerUserId)
	local noticeKey = tostring(yardOwnerUserId) .. ":" .. completedAreaId
	if self.CompletedAreaNoticeKeys[noticeKey] then
		return
	end
	self.CompletedAreaNoticeKeys[noticeKey] = true

	local completedAreaConfig = RegionConfig[completedAreaId]
	local noticeAreaConfig = completedAreaConfig
	local message = if completedAreaId == RegionConfig.FinalAreaId
		then "All Areas Cleared"
		else "Area Cleared"
	if nextAreaId and RegionConfig[nextAreaId] then
		noticeAreaConfig = RegionConfig[nextAreaId]
		message = "Unlocked " .. noticeAreaConfig.DisplayName
	end
	local noticeImage = noticeAreaConfig and noticeAreaConfig.Image
	if type(noticeImage) ~= "string" or noticeImage == "" then
		noticeImage = AREA_COMPLETION_FALLBACK_IMAGE
	end
	self:ShowCenterNotice(
		message,
		noticeImage,
		AREA_COMPLETION_HOLD_DURATION,
		"AreaCompletionNotice"
	)
end

function HUDController:ApplySnapshot(snapshot)
	self.LatestSnapshot = snapshot
	self.TimedLuckyBoxSnapshotReceived = true
	self.TimedLuckyBoxNextSpawnAt = tonumber(snapshot.TimedLuckyBoxNextSpawnAt)
	self.TimedLuckyBoxWaitingForPickup = snapshot.TimedLuckyBoxWaitingForPickup == true
	self.TimedLuckyBoxRewardKind = type(snapshot.TimedLuckyBoxRewardKind) == "string"
		and snapshot.TimedLuckyBoxRewardKind
		or nil
	self.CurrentLeafValueMultiplier = math.max(
		0,
		tonumber(snapshot.LeafValueMultiplier) or tonumber(snapshot.CoinMultiplier) or 1
	)
	self.CurrentPersonalLeafValueMultiplier = math.max(
		0,
		tonumber(snapshot.PersonalLeafValueMultiplier) or 1
	)
	self.CurrentRebirthLeafValueMultiplier = math.max(
		0,
		tonumber(snapshot.RebirthLeafValueMultiplier) or 1
	)
	self:_updateValueMultiplierLabels()
	self.CanUseAdminReset = snapshot.CanUseAdminReset == true
	self:_applyOptionalSnapshot(snapshot)
	self:_applyPurchaseSoundSnapshot(snapshot)
	local rebirthCount = math.max(0, math.floor(tonumber(snapshot.RebirthCount) or 0))
	if self.LastRebirthCount ~= nil and rebirthCount > self.LastRebirthCount then
		local homeYardPrefix = tostring(Players.LocalPlayer.UserId) .. ":"
		for noticeKey in self.CompletedAreaNoticeKeys do
			if string.sub(noticeKey, 1, #homeYardPrefix) == homeYardPrefix then
				self.CompletedAreaNoticeKeys[noticeKey] = nil
			end
		end
		for noticeKey in self.AreaProgressByNoticeKey do
			if string.sub(noticeKey, 1, #homeYardPrefix) == homeYardPrefix then
				self.AreaProgressByNoticeKey[noticeKey] = nil
			end
		end
	end
	self.LastRebirthCount = rebirthCount
	local coins = snapshot.Coins
	local bagValue = snapshot.CurrentBagValue
	local bagCapacity = snapshot.BagCapacity
	local areaProgress = snapshot.AreaProgress
	local previousCoins = self.LastCoins
	local centerRewardTransactionsActive = self.CenterRewardTransactionRunning
		or #self.CenterRewardTransactionQueue > 0
	if centerRewardTransactionsActive then
		if self.PendingCoinTarget ~= nil and coins < self.PendingCoinTarget then
			self:_cancelCoinGainAnimation(coins)
			self.LastCoins = coins
		elseif previousCoins ~= nil and coins < previousCoins then
			self:_cancelCoinGainAnimation(coins)
			self.LastCoins = coins
		else
			-- A later lost-item redemption may already be authoritative while its
			-- presentation waits in the queue. Keep the displayed balance on the
			-- current transaction so each reward can land separately.
			self.LastCoins = coins
		end
	elseif self.PendingCoinTarget ~= nil then
		self.LastCoins = coins
		if coins < self.PendingCoinTarget then
			self:_cancelCoinGainAnimation(coins)
		elseif coins > self.PendingCoinTarget then
			self.PendingCoinTarget = coins
		end
	elseif previousCoins == nil then
		self:_setCoinsValue(coins)
		self.LastCoins = coins
	elseif coins > previousCoins then
		self:_playCoinsIncrease(coins)
		self.LastCoins = coins
	elseif coins < previousCoins then
		self:_cancelCoinsPulse()
		self:_setCoinsValue(coins)
		self.LastCoins = coins
		self:_setCoinPresentationBusy(false)
	else
		self.LastCoins = coins
	end
	self.BagName.Text = snapshot.BagName
	local bagFull = snapshot.BagFull == true
	self.BagFull = bagFull
	self:_refreshStatusNotification()
	if not bagFull then
		self:SetBagFullHoldFeedbackActive(false)
	end
	if bagFull and self.LastBagFull ~= true then
		self:_playBagFullSound()
	end
	self.LastBagFull = bagFull
	if snapshot.InstantRecycleEnabled == true then
		self.BagValue.Text = "Auto Recycle"
		self.BagValue.TextColor3 = Color3.fromRGB(244, 250, 244)
	else
		self.BagValue.Text = string.format(
			"%s/%s",
			CoinFormat.Compact(bagValue),
			CoinFormat.Compact(bagCapacity)
		)
		self.BagValue.TextColor3 = bagFull
			and Color3.fromRGB(255, 155, 120)
			or Color3.fromRGB(244, 250, 244)
	end
	local bagImage = snapshot.BagImage
	self.BagImage.Image = bagImage
	self.BagImage.Visible = bagImage ~= ""
	local currentAreaId = snapshot.CurrentAreaId or snapshot.AreaId or "Area_01"
	self.AreaIcon.Image = getPrimaryAreaLeafImage(currentAreaId) or self.AreaIconDefaultImage
	self.ActiveYardOwnerUserId = snapshot.ActiveYardOwnerUserId or Players.LocalPlayer.UserId
	local areaNoticeKey = tostring(self.ActiveYardOwnerUserId) .. ":" .. currentAreaId
	local previousAreaProgress = self.AreaProgressByNoticeKey[areaNoticeKey]
	self.AreaProgressByNoticeKey[areaNoticeKey] = areaProgress
	local areaTotalLeafCount = math.max(
		0,
		math.floor(tonumber(snapshot.AreaTotalLeafCount) or tonumber(snapshot.AreaTotalValue) or 0)
	)
	local areaCollectedLeafCount = math.max(
		0,
		math.floor(tonumber(snapshot.AreaCollectedLeafCount) or tonumber(snapshot.AreaClearedValue) or 0)
	)
	areaCollectedLeafCount = math.min(areaCollectedLeafCount, areaTotalLeafCount)
	self.AreaValue.Text = string.format("%d/%d", areaCollectedLeafCount, areaTotalLeafCount)
	setFill(self.BagFill, if snapshot.InstantRecycleEnabled == true then 0 else bagValue / bagCapacity)
	if
		previousAreaProgress ~= nil
		and previousAreaProgress < 1
		and self.AreaNoticeReadyYardOwners[self.ActiveYardOwnerUserId] == true
		and snapshot.AreaTotalValue > 0
		and areaProgress >= 1
	then
		self:_showAreaCompletionNotice(currentAreaId, nil, self.ActiveYardOwnerUserId)
	end
end

function HUDController:HideCenterNotice()
	if
		not self.ActiveCenterNotice
		and not self.CenterNoticeRiseTween
		and not self.CenterNoticeScaleTween
	then
		return
	end

	self.CenterNoticeSerial += 1
	if self.CenterNoticeRiseTween then
		self.CenterNoticeRiseTween:Cancel()
		self.CenterNoticeRiseTween = nil
	end
	if self.CenterNoticeScaleTween then
		self.CenterNoticeScaleTween:Cancel()
		self.CenterNoticeScaleTween = nil
	end
	if self.ActiveCenterNotice then
		self.ActiveCenterNotice:Destroy()
		self.ActiveCenterNotice = nil
	end
end

function HUDController:ShowCenterNotice(message, image, holdDuration, cloneName)
	if not self.CenterNoticeTemplate or not self.HUDRoot then
		return
	end
	self:HideCenterNotice()
	self.CenterNoticeSerial += 1
	local serial = self.CenterNoticeSerial

	local clone = self.CenterNoticeTemplate:Clone()
	clone.Name = cloneName or "CenterNotice"
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.Position = CENTER_REWARD_START_POSITION
	clone.Visible = true
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex += CENTER_REWARD_Z_INDEX_OFFSET
		end
	end
	clone.ZIndex += CENTER_REWARD_Z_INDEX_OFFSET
	clone.Parent = self.HUDRoot
	self.ActiveCenterNotice = clone

	local textLabel = clone:WaitForChild("TextLabel")
	textLabel.Text = message
	textLabel.Visible = true
	local icon = clone:WaitForChild("Icon")
	icon.Image = image
	icon.Visible = true

	local uiScale = clone:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Name = "CenterNoticeScale"
		uiScale.Parent = clone
	end
	local baseScale = uiScale.Scale
	uiScale.Scale = baseScale * CENTER_REWARD_START_SCALE

	local riseTween = TweenService:Create(
		clone,
		TweenInfo.new(CENTER_REWARD_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = CENTER_REWARD_RISE_POSITION }
	)
	local growTween = TweenService:Create(
		uiScale,
		TweenInfo.new(CENTER_REWARD_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = baseScale }
	)
	self.CenterNoticeRiseTween = riseTween
	self.CenterNoticeScaleTween = growTween
	riseTween:Play()
	growTween:Play()

	task.spawn(function()
		riseTween.Completed:Wait()
		if serial ~= self.CenterNoticeSerial or not clone.Parent then
			return
		end
		self.CenterNoticeRiseTween = nil
		self.CenterNoticeScaleTween = nil

		task.wait(math.max(0, tonumber(holdDuration) or 0))
		if serial ~= self.CenterNoticeSerial or not clone.Parent then
			return
		end

		local shrinkTween = TweenService:Create(
			uiScale,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = baseScale * CENTER_REWARD_START_SCALE }
		)
		self.CenterNoticeScaleTween = shrinkTween
		shrinkTween:Play()
		shrinkTween.Completed:Wait()
		if serial ~= self.CenterNoticeSerial then
			return
		end

		self.CenterNoticeScaleTween = nil
		self.ActiveCenterNotice = nil
		clone:Destroy()
	end)
end

function HUDController:_cancelCoinFlipLoss()
	self.CoinFlipLossSerial += 1
	for _, tween in self.CoinFlipLossTweens do
		tween:Cancel()
	end
	table.clear(self.CoinFlipLossTweens)
	for _, entry in self.CoinFlipLossVisualEntries do
		if entry.Instance.Parent then
			for property, value in entry.Original do
				entry.Instance[property] = value
			end
		end
	end
	if self.CoinFlipLossFrame and self.CoinFlipLossOriginalPosition then
		self.CoinFlipLossFrame.Position = self.CoinFlipLossOriginalPosition
		self.CoinFlipLossFrame.Visible = false
	end
end

function HUDController:ShowCoinFlipLoss(amount)
	if not self.CoinFlipLossFrame or not self.CoinFlipLossLabel then
		return
	end
	local displayAmount = math.max(0, math.floor(tonumber(amount) or 0))
	if displayAmount <= 0 then
		return
	end
	self:_cancelCoinFlipLoss()
	local serial = self.CoinFlipLossSerial
	self.CoinFlipLossLabel.Text = "-" .. CoinFormat.Compact(displayAmount)
	self.CoinFlipLossFrame.Visible = true

	local riseTween = TweenService:Create(
		self.CoinFlipLossFrame,
		TweenInfo.new(COIN_FLIP_LOSS_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = self.CoinFlipLossOriginalPosition + COIN_FLIP_LOSS_RISE_OFFSET }
	)
	table.insert(self.CoinFlipLossTweens, riseTween)
	riseTween:Play()

	task.spawn(function()
		task.wait(COIN_FLIP_LOSS_FADE_DELAY)
		if serial ~= self.CoinFlipLossSerial then
			return
		end
		local fadeDuration = COIN_FLIP_LOSS_RISE_DURATION - COIN_FLIP_LOSS_FADE_DELAY
		for _, entry in self.CoinFlipLossVisualEntries do
			if entry.Instance.Parent and next(entry.Goals) ~= nil then
				local tween = TweenService:Create(
					entry.Instance,
					TweenInfo.new(fadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					entry.Goals
				)
				table.insert(self.CoinFlipLossTweens, tween)
				tween:Play()
			end
		end
		task.wait(fadeDuration)
		if serial == self.CoinFlipLossSerial then
			self:_cancelCoinFlipLoss()
		end
	end)
end

function HUDController:_acceptCoinGainSequence(event)
	local sequenceId = event and tonumber(event.SequenceId)
	if not sequenceId or sequenceId <= self.LastCoinGainSequenceId then
		return nil
	end
	self.LastCoinGainSequenceId = sequenceId
	return sequenceId
end

function HUDController:_receiveCoinGainEvent(event)
	if type(event) == "table" and event.SoundOnly == true then
		if not self:_acceptCoinGainSequence(event) then
			return
		end
		self:_queueCoinFeedbackSounds(event)
		return
	end
	if type(event) == "table" and event.CenterReward == true then
		if not self:_acceptCoinGainSequence(event) then
			return
		end
		table.insert(self.CenterRewardTransactionQueue, event)
		self:_startNextCenterRewardTransaction()
		return
	end
	self:_queueCoinGainEvent(event)
end

function HUDController:_startNextCenterRewardTransaction()
	if
		self.CenterRewardTransactionRunning
		or self.CoinPresentationBusy
		or #self.CenterRewardTransactionQueue == 0
	then
		return
	end

	local event = table.remove(self.CenterRewardTransactionQueue, 1)
	self.CenterRewardTransactionRunning = true
	if not self:_queueCoinGainEvent(event, true) then
		self.CenterRewardTransactionRunning = false
		self:_startNextCenterRewardTransaction()
	end
end

function HUDController:_cancelCenterRewardTransactions()
	table.clear(self.CenterRewardTransactionQueue)
	self.CenterRewardTransactionRunning = false
end

function HUDController:_cancelCenterCoinRewards()
	self.CenterCoinRewardSerial += 1
	table.clear(self.CenterCoinRewardQueue)
	self.CenterCoinRewardRunning = false
	if self.CenterCoinRewardRiseTween then
		self.CenterCoinRewardRiseTween:Cancel()
		self.CenterCoinRewardRiseTween = nil
	end
	if self.CenterCoinRewardScaleTween then
		self.CenterCoinRewardScaleTween:Cancel()
		self.CenterCoinRewardScaleTween = nil
	end
	if self.CenterCoinRewardFlyTween then
		self.CenterCoinRewardFlyTween:Cancel()
		self.CenterCoinRewardFlyTween = nil
	end
	if self.ActiveCenterCoinRewardClone then
		self.ActiveCenterCoinRewardClone:Destroy()
		self.ActiveCenterCoinRewardClone = nil
	end
end

function HUDController:_queueCenterCoinReward(amount)
	if not self.CenterNoticeTemplate then
		return
	end
	local displayAmount = math.max(0, math.floor(tonumber(amount) or 0))
	if displayAmount <= 0 then
		return
	end
	table.insert(self.CenterCoinRewardQueue, displayAmount)
	self:_startNextCenterCoinReward()
end

function HUDController:_startNextCenterCoinReward()
	if self.CenterCoinRewardRunning or #self.CenterCoinRewardQueue == 0 then
		return
	end

	local amount = table.remove(self.CenterCoinRewardQueue, 1)
	self.CenterCoinRewardRunning = true
	local serial = self.CenterCoinRewardSerial
	task.spawn(function()
		local succeeded, completed = xpcall(function()
			return self:_playCenterCoinReward(amount, serial)
		end, debug.traceback)
		if not succeeded then
			warn("Center coin reward animation failed: " .. tostring(completed))
		end
		if serial ~= self.CenterCoinRewardSerial then
			return
		end
		self.CenterCoinRewardRunning = false
		if not succeeded or completed ~= true then
			self:_cancelCenterCoinRewards()
			self:_setCoinPresentationBusy(false)
			return
		end
		self:_startNextCenterCoinReward()
		self:_setCoinPresentationBusy(false)
	end)
end

function HUDController:_playCenterCoinReward(amount, serial)
	if not self.CenterNoticeTemplate then
		return false
	end
	local clone = self.CenterNoticeTemplate:Clone()
	clone.Name = "LostItemCoinReward"
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.Position = CENTER_REWARD_START_POSITION
	clone.Visible = true
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex += CENTER_REWARD_Z_INDEX_OFFSET
		end
	end
	clone.ZIndex += CENTER_REWARD_Z_INDEX_OFFSET
	clone.Parent = self.HUDRoot
	self.ActiveCenterCoinRewardClone = clone

	local textLabel = clone:WaitForChild("TextLabel")
	textLabel.Text = "+" .. CoinFormat.Compact(amount)
	textLabel.Visible = true
	local icon = clone:WaitForChild("Icon")
	icon.Image = LostItemConfig.CoinImage
	icon.Visible = true

	local uiScale = clone:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Name = "CenterCoinRewardScale"
		uiScale.Parent = clone
	end
	local baseScale = uiScale.Scale
	uiScale.Scale = baseScale * CENTER_REWARD_START_SCALE

	local riseTween = TweenService:Create(
		clone,
		TweenInfo.new(CENTER_REWARD_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = CENTER_REWARD_RISE_POSITION }
	)
	local growTween = TweenService:Create(
		uiScale,
		TweenInfo.new(CENTER_REWARD_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = baseScale }
	)
	self.CenterCoinRewardRiseTween = riseTween
	self.CenterCoinRewardScaleTween = growTween
	riseTween:Play()
	growTween:Play()
	riseTween.Completed:Wait()
	if serial ~= self.CenterCoinRewardSerial or not clone.Parent then
		return false
	end
	self.CenterCoinRewardRiseTween = nil
	self.CenterCoinRewardScaleTween = nil

	task.wait(CENTER_REWARD_HOLD_DURATION)
	if serial ~= self.CenterCoinRewardSerial or not clone.Parent or not self.CoinsValue.Parent then
		return false
	end

	local flyTween = TweenService:Create(
		clone,
		TweenInfo.new(CENTER_REWARD_FLY_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = targetCenterInParent(self.HUDRoot, self.CoinsValue) }
	)
	local shrinkTween = TweenService:Create(
		uiScale,
		TweenInfo.new(CENTER_REWARD_FLY_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Scale = baseScale * CENTER_REWARD_FINAL_SCALE }
	)
	self.CenterCoinRewardFlyTween = flyTween
	self.CenterCoinRewardScaleTween = shrinkTween
	flyTween:Play()
	shrinkTween:Play()
	flyTween.Completed:Wait()
	if serial ~= self.CenterCoinRewardSerial then
		return false
	end

	self.CenterCoinRewardFlyTween = nil
	self.CenterCoinRewardScaleTween = nil
	self.ActiveCenterCoinRewardClone = nil
	clone:Destroy()
	self:_playCoinsFramePulseOnce()
	return true
end

function HUDController:_setCoinsValue(coins)
	self.DisplayedCoins = coins
	self.CoinsValue.Text = CoinFormat.Compact(coins)
end

function HUDController:_cancelCoinsPulse()
	self.CoinsPulseSerial += 1
	if self.CoinsPulseTween then
		self.CoinsPulseTween:Cancel()
		self.CoinsPulseTween = nil
	end
	self.CoinsScale.Scale = self.CoinsBaseScale
end

function HUDController:_resetCoinGainVisual()
	self.DoubleCoinRevealSerial += 1
	self.DoubleCoinRevealRunning = false
	self.DoubleCoinRevealComplete = true
	if self.CoinGainTween then
		self.CoinGainTween:Cancel()
		self.CoinGainTween = nil
	end
	if self.CoinGainFlyTween then
		self.CoinGainFlyTween:Cancel()
		self.CoinGainFlyTween = nil
	end
	self.CoinGainScale.Scale = self.CoinGainBaseScale
	self.CoinGainValue.Position = self.CoinGainOriginalPosition
	self.CoinGainValue.Text = "+0"
	self.CoinGainValue.Visible = false
	self.CoinGainGradient.Enabled = self.CoinGainGradientOriginalEnabled
	self.PendingLeafSettlementId = nil
	self.PendingLeafSettlementResult = nil
end

function HUDController:_clearCoinGainStepQueue()
	if self.CoinGainStepWorker then
		task.cancel(self.CoinGainStepWorker)
		self.CoinGainStepWorker = nil
	end
	self.CoinGainStepQueue = {}
	self.CoinGainStepQueueHead = 1
	self.CoinGainStepQueueTail = 0
end

function HUDController:_cancelCoinGainAnimation(latestCoins, keepPresentationBusy)
	self.CoinGainSerial += 1
	self.CoinGainIdleSerial += 1
	self.CoinGainPulseSerial += 1
	self.PendingCoinTarget = nil
	self.PendingCoinAmount = 0
	self.PendingCoinBaseAmount = 0
	self.PendingCoinRewardMultiplier = 1
	self.CoinGainLastScheduledAt = nil
	self:_clearCoinGainStepQueue()
	self:_resetCoinGainVisual()
	self:_cancelCoinsPulse()
	self:_cancelCenterCoinRewards()
	self:_cancelCenterRewardTransactions()
	if type(latestCoins) == "number" then
		self:_setCoinsValue(latestCoins)
	end
	if keepPresentationBusy ~= true then
		self:_setCoinPresentationBusy(false)
	end
end

function HUDController:_playCoinGainPulseOnce(pulseHalfDuration)
	pulseHalfDuration = math.max(
		0.001,
		tonumber(pulseHalfDuration) or COIN_GAIN_PULSE_HALF_DURATION
	)
	self.CoinGainPulseSerial += 1
	local pulseSerial = self.CoinGainPulseSerial
	if self.CoinGainTween then
		self.CoinGainTween:Cancel()
		self.CoinGainTween = nil
	end
	self.CoinGainScale.Scale = self.CoinGainBaseScale

	local growTween = TweenService:Create(
		self.CoinGainScale,
		TweenInfo.new(pulseHalfDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = self.CoinGainBaseScale * COIN_GAIN_PULSE_SCALE }
	)
	self.CoinGainTween = growTween
	growTween:Play()
	task.spawn(function()
		growTween.Completed:Wait()
		if pulseSerial ~= self.CoinGainPulseSerial then
			return
		end
		local shrinkTween = TweenService:Create(
			self.CoinGainScale,
			TweenInfo.new(pulseHalfDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = self.CoinGainBaseScale }
		)
		self.CoinGainTween = shrinkTween
		shrinkTween:Play()
		shrinkTween.Completed:Wait()
		if pulseSerial == self.CoinGainPulseSerial then
			self.CoinGainTween = nil
			self.CoinGainScale.Scale = self.CoinGainBaseScale
		end
	end)
end

function HUDController:_playCoinsFramePulseOnce()
	self:_cancelCoinsPulse()
	local serial = self.CoinsPulseSerial

	task.spawn(function()
		local growTween = TweenService:Create(
			self.CoinsScale,
			TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = self.CoinsBaseScale * 1.15 }
		)
		self.CoinsPulseTween = growTween
		growTween:Play()
		growTween.Completed:Wait()
		if serial ~= self.CoinsPulseSerial then
			return
		end

		local shrinkTween = TweenService:Create(
			self.CoinsScale,
			TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Scale = self.CoinsBaseScale }
		)
		self.CoinsPulseTween = shrinkTween
		shrinkTween:Play()
		shrinkTween.Completed:Wait()
		if serial == self.CoinsPulseSerial then
			self.CoinsPulseTween = nil
			self.CoinsScale.Scale = self.CoinsBaseScale
		end
	end)
end

function HUDController:_cancelDoubleCoinReveal()
	self.DoubleCoinRevealSerial += 1
	self.DoubleCoinRevealRunning = false
	self.DoubleCoinRevealComplete = self.PendingCoinRewardMultiplier <= 1
end

function HUDController:_startDoubleCoinReveal(generation)
	if
		generation ~= self.CoinGainSerial
		or not self.PendingCoinTarget
		or self.PendingCoinRewardMultiplier <= 1
		or self.PendingCoinBaseAmount <= 0
		or self.DoubleCoinRevealRunning
		or self.DoubleCoinRevealComplete
	then
		return
	end

	self.DoubleCoinRevealSerial += 1
	local revealSerial = self.DoubleCoinRevealSerial
	self.DoubleCoinRevealRunning = true
	self.CoinGainValue.Position = self.CoinGainOriginalPosition
	self.CoinGainValue.Text = CoinFormat.Compact(self.PendingCoinBaseAmount)
		.. "x"
		.. tostring(self.PendingCoinRewardMultiplier)
	self.CoinGainValue.Visible = true
	self:_playCoinGainPulseOnce()

	task.delay(DOUBLE_COIN_REVEAL_DURATION, function()
		if
			generation ~= self.CoinGainSerial
			or revealSerial ~= self.DoubleCoinRevealSerial
			or not self.PendingCoinTarget
		then
			return
		end
		self.DoubleCoinRevealRunning = false
		self.DoubleCoinRevealComplete = true
		if self.PendingLeafSettlementId then
			self:_tryRevealLeafSettlement()
		else
			self:_flyPendingCoinGain(generation)
		end
	end)
end

function HUDController:_flyPendingCoinGain(generation)
	if generation ~= self.CoinGainSerial or not self.PendingCoinTarget or self.PendingCoinAmount <= 0 then
		return
	end
	local targetCoins = self.PendingCoinTarget
	local flyTween = TweenService:Create(
		self.CoinGainValue,
		TweenInfo.new(self.PendingCoinFlyDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
		{ Position = self.CoinsValue.Position }
	)
	self.CoinGainFlyTween = flyTween
	flyTween:Play()
	task.spawn(function()
		flyTween.Completed:Wait()
		if generation ~= self.CoinGainSerial or self.CoinGainFlyTween ~= flyTween then
			return
		end
		self.CoinGainFlyTween = nil
		self.PendingCoinTarget = nil
		self.PendingCoinAmount = 0
		self.PendingCoinBaseAmount = 0
		self.PendingCoinRewardMultiplier = 1
		self.CoinGainLastScheduledAt = nil
		self:_setCoinsValue(targetCoins)
		self:_resetCoinGainVisual()
		self:_playCoinsFramePulseOnce()
		self:_setCoinPresentationBusy(false)
	end)
end

function HUDController:_tryRevealLeafSettlement()
	local result = self.PendingLeafSettlementResult
	if not result or self.CoinGainStepWorker then
		return
	end
	if self.CoinGainStepQueueHead <= self.CoinGainStepQueueTail then
		return
	end
	if self.PendingCoinRewardMultiplier > 1 and not self.DoubleCoinRevealComplete then
		return
	end

	self.PendingLeafSettlementResult = nil
	self.PendingLeafSettlementId = nil
	self.PendingCoinTarget = result.TargetCoins
	self.LastCoins = result.TargetCoins
	local generation = self.CoinGainSerial
	self.CoinGainGradient.Enabled = self.CoinGainGradientOriginalEnabled
	self:_flyPendingCoinGain(generation)
end

function HUDController:_receiveLeafSettlement(event)
	if self.PendingLeafSettlementId ~= event.SettlementId then
		self.CoinGainIdleSerial += 1
		self:_cancelCoinGainAnimation(event.TargetCoins)
		return
	end

	self.PendingLeafSettlementResult = event
	self.PendingCoinTarget = event.TargetCoins
	self.LastCoins = event.TargetCoins
	self:_tryRevealLeafSettlement()
end

function HUDController:_applyCoinGainStep(
	generation,
	baseStepAmount,
	awardedStepAmount,
	pulseHalfDuration
)
	if
		generation ~= self.CoinGainSerial
		or not self.PendingCoinTarget
		or (baseStepAmount <= 0 and awardedStepAmount <= 0)
	then
		return
	end
	if self.CoinGainFlyTween then
		self.CoinGainFlyTween:Cancel()
		self.CoinGainFlyTween = nil
	end
	self:_cancelDoubleCoinReveal()
	self.PendingCoinBaseAmount += baseStepAmount
	self.PendingCoinAmount += awardedStepAmount
	self.CoinGainValue.Position = self.CoinGainOriginalPosition
	local visibleAmount = if self.PendingCoinRewardMultiplier > 1
		then self.PendingCoinBaseAmount
		else self.PendingCoinAmount
	self.CoinGainValue.Text = "+" .. CoinFormat.Compact(visibleAmount)
	self.CoinGainValue.Visible = true
	self:_playCoinGainPulseOnce(pulseHalfDuration)

	self.CoinGainIdleSerial += 1
	local idleSerial = self.CoinGainIdleSerial
	task.delay(self.PendingCoinHoldDuration, function()
		if idleSerial ~= self.CoinGainIdleSerial then
			return
		end
		if self.PendingCoinRewardMultiplier > 1 then
			self:_startDoubleCoinReveal(generation)
		elseif not self.PendingLeafSettlementId then
			self:_flyPendingCoinGain(generation)
		end
	end)
end

function HUDController:_startCoinGainStepWorker()
	if self.CoinGainStepWorker then
		return
	end

	local workerThread
	workerThread = task.defer(function()
		local lastPlayedAt = -math.huge
		while self.CoinGainStepQueueHead <= self.CoinGainStepQueueTail do
			local entry = self.CoinGainStepQueue[self.CoinGainStepQueueHead]
			self.CoinGainStepQueue[self.CoinGainStepQueueHead] = nil
			self.CoinGainStepQueueHead += 1
			if entry then
				local playAt = math.max(
					entry.ScheduledAt,
					lastPlayedAt + entry.MinimumInterval
				)
				local waitDuration = playAt - os.clock()
				if waitDuration > 0 then
					task.wait(waitDuration)
				end
				self:_applyCoinGainStep(
					entry.Generation,
					entry.BaseAmount,
					entry.Amount,
					entry.PulseHalfDuration
				)
				lastPlayedAt = os.clock()
			end
		end

		self.CoinGainStepQueue = {}
		self.CoinGainStepQueueHead = 1
		self.CoinGainStepQueueTail = 0
		if self.CoinGainStepWorker == workerThread then
			self.CoinGainStepWorker = nil
		end
		task.defer(function()
			self:_tryRevealLeafSettlement()
		end)
	end)
	self.CoinGainStepWorker = workerThread
end

function HUDController:_queueCoinGainEvent(event, sequenceAlreadyAccepted)
	local sequenceId = tonumber(event and event.SequenceId)
	if not sequenceId then
		return false
	end
	if sequenceAlreadyAccepted ~= true then
		sequenceId = self:_acceptCoinGainSequence(event)
		if not sequenceId then
			return false
		end
	end
	local eventAmount = math.max(0, math.floor(tonumber(event.Amount) or 0))
	local eventBaseAmount = math.max(0, math.floor(tonumber(event.BaseAmount) or eventAmount))
	local eventRewardMultiplier = math.max(1, math.floor(tonumber(event.RewardMultiplier) or 1))
	if eventBaseAmount <= 0 then
		eventBaseAmount = eventAmount
	end
	if eventRewardMultiplier > 1 and eventBaseAmount * eventRewardMultiplier ~= eventAmount then
		eventBaseAmount = eventAmount
		eventRewardMultiplier = 1
	end
	event.Amount = eventAmount
	event.BaseAmount = eventBaseAmount
	event.RewardMultiplier = eventRewardMultiplier
	event.CenterReward = event.CenterReward == true
	self:_setCoinPresentationBusy(true)
	if event.Phase == "Settle" then
		self:_receiveLeafSettlement(event)
		return true
	end
	self:_queueCoinFeedbackSounds(event)
	if event.Phase == "Accumulate" then
		if self.PendingLeafSettlementId ~= event.SettlementId then
			self.CoinGainGradient.Enabled = self.CoinGainGradientOriginalEnabled
		end
		self.PendingLeafSettlementId = event.SettlementId
		self.PendingLeafSettlementResult = nil
	end
	-- An accepted income event means another visible step is on the way. Invalidate
	-- the previous idle timer immediately so it cannot finish the accumulator before
	-- this event's FirstStepDelay has elapsed.
	self.CoinGainIdleSerial += 1

	local eventStartCoins = math.max(0, event.TargetCoins - event.Amount)
	if self.PendingCoinTarget ~= nil and eventStartCoins < self.PendingCoinTarget then
		-- The authoritative balance fell between two income events, so a purchase or
		-- another spend happened before this gain. Finish the old visual immediately
		-- and begin a fresh accumulator from the post-spend balance.
		self.LastCoins = eventStartCoins
		self:_cancelCoinGainAnimation(eventStartCoins, true)
	end
	if
		self.PendingCoinTarget ~= nil
		and event.RewardMultiplier ~= self.PendingCoinRewardMultiplier
	then
		self.LastCoins = eventStartCoins
		self:_cancelCoinGainAnimation(eventStartCoins, true)
		self:_playCoinsFramePulseOnce()
	end
	if event.Phase == "Accumulate" then
		self.PendingLeafSettlementId = event.SettlementId
		self.PendingLeafSettlementResult = nil
	end

	if self.PendingCoinTarget == nil then
		self.CoinGainSerial += 1
		self.PendingCoinAmount = 0
		self.PendingCoinBaseAmount = 0
		self.PendingCoinRewardMultiplier = event.RewardMultiplier
		self.DoubleCoinRevealRunning = false
		self.DoubleCoinRevealComplete = event.RewardMultiplier <= 1
		self.PendingCoinTarget = event.TargetCoins
		self:_cancelCoinsPulse()
		self:_setCoinsValue(eventStartCoins)
	else
		self:_cancelDoubleCoinReveal()
		self.PendingCoinTarget = math.max(self.PendingCoinTarget, event.TargetCoins)
		if self.CoinGainFlyTween then
			self.CoinGainFlyTween:Cancel()
			self.CoinGainFlyTween = nil
			self.CoinGainValue.Position = self.CoinGainOriginalPosition
			self.CoinGainValue.Visible = self.PendingCoinBaseAmount > 0
		end
	end
	self.LastCoins = math.max(tonumber(self.LastCoins) or 0, event.TargetCoins)
	self.PendingCoinHoldDuration = if event.RewardMultiplier > 1
		then DOUBLE_COIN_BASE_HOLD_DURATION
		else event.HoldDuration
	self.PendingCoinFlyDuration = event.FlyDuration
	if event.CenterReward then
		self:_queueCenterCoinReward(eventAmount)
	end

	local generation = self.CoinGainSerial
	local baseStep = math.floor(event.BaseAmount / event.StepCount)
	local baseRemainder = event.BaseAmount % event.StepCount
	local awardedStep = math.floor(event.Amount / event.StepCount)
	local awardedRemainder = event.Amount % event.StepCount
	local scheduleNow = os.clock()
	local lastScheduledAt = self.CoinGainLastScheduledAt
	local pulseHalfDuration = COIN_GAIN_PULSE_HALF_DURATION
	if event.SoundKind == "Recycle" and event.StepInterval < COIN_GAIN_PULSE_HALF_DURATION * 2 then
		pulseHalfDuration = event.StepInterval / 2
	end
	local minimumStepInterval = math.max(event.StepInterval, pulseHalfDuration * 2)
	for stepIndex = 1, event.StepCount do
		local stepBaseAmount = baseStep + (if stepIndex <= baseRemainder then 1 else 0)
		local stepAwardedAmount = awardedStep + (if stepIndex <= awardedRemainder then 1 else 0)
		local requestedAt = scheduleNow + event.FirstStepDelay + (stepIndex - 1) * event.StepInterval
		local scheduledAt = if lastScheduledAt
			then math.max(requestedAt, lastScheduledAt + minimumStepInterval)
			else requestedAt
		lastScheduledAt = scheduledAt
		self.CoinGainStepQueueTail += 1
		self.CoinGainStepQueue[self.CoinGainStepQueueTail] = {
			Generation = generation,
			BaseAmount = stepBaseAmount,
			Amount = stepAwardedAmount,
			ScheduledAt = scheduledAt,
			MinimumInterval = minimumStepInterval,
			PulseHalfDuration = pulseHalfDuration,
		}
	end
	self.CoinGainLastScheduledAt = lastScheduledAt
	self:_startCoinGainStepWorker()
	return true
end

function HUDController:_playCoinsIncrease(targetCoins)
	local startCoins = self.DisplayedCoins or self.LastCoins or targetCoins
	if targetCoins <= startCoins then
		self:_setCoinsValue(targetCoins)
		self:_setCoinPresentationBusy(false)
		return
	end

	self:_cancelCoinsPulse()
	self:_setCoinPresentationBusy(true)
	local serial = self.CoinsPulseSerial
	local firstStep = startCoins + math.ceil((targetCoins - startCoins) / 2)
	local stepValues = { firstStep, targetCoins }

	task.spawn(function()
		for _, stepValue in stepValues do
			if serial ~= self.CoinsPulseSerial then
				return
			end
			self:_setCoinsValue(stepValue)

			local growTween = TweenService:Create(
				self.CoinsScale,
				TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Scale = self.CoinsBaseScale * 1.15 }
			)
			self.CoinsPulseTween = growTween
			growTween:Play()
			growTween.Completed:Wait()
			if serial ~= self.CoinsPulseSerial then
				return
			end

			local shrinkTween = TweenService:Create(
				self.CoinsScale,
				TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Scale = self.CoinsBaseScale }
			)
			self.CoinsPulseTween = shrinkTween
			shrinkTween:Play()
			shrinkTween.Completed:Wait()
		end

		if serial == self.CoinsPulseSerial then
			self.CoinsPulseTween = nil
			self.CoinsScale.Scale = self.CoinsBaseScale
			self:_setCoinsValue(targetCoins)
			self:_setCoinPresentationBusy(false)
		end
	end)
end

function HUDController:ShowLeafCollected(displayValue, leafType)
	local slotReleased = false
	local function releaseSlot()
		if slotReleased then
			return
		end
		slotReleased = true
		self.OutstandingLeafHintCount = math.max(0, self.OutstandingLeafHintCount - 1)
	end
	if not isPositiveFiniteNumber(displayValue) then
		releaseSlot()
		return false
	end
	if not self.LeafHintTemplate or not self.HUDRoot or not self.BagTarget then
		releaseSlot()
		return false
	end
	local leafTypeConfig = if type(leafType) == "string" then LeafConfig.Types[leafType] else nil
	local configuredImage = leafTypeConfig and leafTypeConfig.Image
	local leafImage = if type(configuredImage) == "string" and configuredImage ~= ""
		then configuredImage
		else self.LeafHintDefaultImage

	local started, startError = pcall(function()
		CenterFlyUIEffect.Play({
			Template = self.LeafHintTemplate,
			Parent = self.HUDRoot,
			Target = self.BagTarget,
			TextObjectName = "TextLabel",
			Text = formatLeafHintValue(displayValue),
			ImageObjectName = "Icon",
			Image = leafImage,
			CloneName = "LeafGainHint",
			UsePool = true,
			PositionDistribution = "OuterWeightedEllipse",
			OuterAreaScale = Vector2.new(0.9, 0.8),
			CenterChance = 0.15,
			InnerRadiusRatio = 0.3,
			EdgePadding = 24,
			AppearTime = 0.1,
			StartScale = 0.6,
			AppearEasingStyle = Enum.EasingStyle.Quad,
			AppearEasingDirection = Enum.EasingDirection.Out,
			HoldTime = 0.2,
			FlyTime = 1,
			FlyEndScale = 0.2,
			EasingStyle = Enum.EasingStyle.Quad,
			EasingDirection = Enum.EasingDirection.In,
			MinimumZIndex = 20,
			OnFinished = releaseSlot,
		})
	end)
	if not started then
		releaseSlot()
		error(startError)
	end
	return true
end

function HUDController:_normalizeLeafHint(leafType, bagAmount, displayValue)
	if not isPositiveFiniteNumber(bagAmount) then
		return nil
	end
	if not isPositiveFiniteNumber(displayValue) then
		displayValue = bagAmount * self.CurrentLeafValueMultiplier
	end
	if not isPositiveFiniteNumber(displayValue) then
		return nil
	end
	return {
		LeafType = leafType,
		DisplayValue = displayValue,
	}
end

function HUDController:_popScheduledLeafHint()
	if self.ScheduledLeafHintHead > self.ScheduledLeafHintTail then
		return nil
	end
	local leafHint = self.ScheduledLeafHints[self.ScheduledLeafHintHead]
	self.ScheduledLeafHints[self.ScheduledLeafHintHead] = nil
	self.ScheduledLeafHintHead += 1
	if self.ScheduledLeafHintHead > self.ScheduledLeafHintTail then
		table.clear(self.ScheduledLeafHints)
		self.ScheduledLeafHintHead = 1
		self.ScheduledLeafHintTail = 0
	end
	return leafHint
end

function HUDController:_hasScheduledLeafHints()
	return self.ScheduledLeafHintHead <= self.ScheduledLeafHintTail
end

function HUDController:_playNextScheduledLeafHint()
	local leafHint = self:_popScheduledLeafHint()
	if not leafHint then
		return false
	end
	local succeeded, message = pcall(function()
		self:ShowLeafCollected(leafHint.DisplayValue, leafHint.LeafType)
	end)
	if not succeeded then
		warn("Leaf hint playback failed: " .. tostring(message))
	end
	self.LastLeafHintSpawnAt = os.clock()
	return true
end

function HUDController:_stopLeafHintPacing()
	if self.LeafHintPacingConnection then
		self.LeafHintPacingConnection:Disconnect()
		self.LeafHintPacingConnection = nil
	end
end

function HUDController:_startLeafHintPacing()
	if self.LeafHintPacingConnection or not self:_hasScheduledLeafHints() then
		return
	end

	local now = os.clock()
	if now - self.LastLeafHintSpawnAt >= LEAF_HINT_SPAWN_INTERVAL then
		self:_playNextScheduledLeafHint()
		if not self:_hasScheduledLeafHints() then
			return
		end
	end

	self.LeafHintPacingConnection = RunService.Heartbeat:Connect(function()
		if not self:_hasScheduledLeafHints() then
			self:_stopLeafHintPacing()
			return
		end
		local heartbeatNow = os.clock()
		if heartbeatNow - self.LastLeafHintSpawnAt < LEAF_HINT_SPAWN_INTERVAL then
			return
		end
		-- Deliberately play at most one hint per Heartbeat. Low frame rates must not
		-- catch up by creating several hints together and recreate the old wave effect.
		self:_playNextScheduledLeafHint()
		if not self:_hasScheduledLeafHints() then
			self:_stopLeafHintPacing()
		end
	end)
end

function HUDController:_scheduleLeafHints(leafHints)
	local leafHintCount = #leafHints
	local availableSlots = math.max(0, MAXIMUM_OUTSTANDING_LEAF_HINTS - self.OutstandingLeafHintCount)
	local acceptedCount = math.min(leafHintCount, availableSlots)
	if acceptedCount <= 0 then
		return false
	end

	-- Randomly sample visual hints when the authoritative collection contains more
	-- leaves than the remaining visual slots. Excess hints are discarded, not merged
	-- or replayed later; gameplay rewards and bag state have already been awarded.
	for index = 1, acceptedCount do
		local selectedIndex = self.LeafHintRandom:NextInteger(index, leafHintCount)
		leafHints[index], leafHints[selectedIndex] = leafHints[selectedIndex], leafHints[index]
		self.ScheduledLeafHintTail += 1
		self.ScheduledLeafHints[self.ScheduledLeafHintTail] = leafHints[index]
	end
	self.OutstandingLeafHintCount += acceptedCount
	self:_startLeafHintPacing()
	return true
end

function HUDController:_showLeafCollectedHints(addedAmount, leafType, leafHints)
	local validLeafHints = {}
	if type(leafHints) == "table" then
		for _, leafHint in leafHints do
			if type(leafHint) == "table" then
				local normalizedLeafHint = self:_normalizeLeafHint(
					leafHint.LeafType,
					leafHint.BagAmount,
					leafHint.DisplayValue
				)
				if normalizedLeafHint then
					table.insert(validLeafHints, normalizedLeafHint)
				end
			end
		end
	end
	if #validLeafHints > 0 then
		self:_scheduleLeafHints(validLeafHints)
		return
	end

	local legacyAmount = tonumber(addedAmount)
	if isPositiveFiniteNumber(legacyAmount) then
		local normalizedLeafHint = self:_normalizeLeafHint(
			leafType,
			legacyAmount,
			legacyAmount * self.CurrentLeafValueMultiplier
		)
		if normalizedLeafHint then
			self:_scheduleLeafHints({ normalizedLeafHint })
		end
	end
end

function HUDController:_cancelNotificationFade()
	if self.NotificationFadeTweens then
		for _, tween in self.NotificationFadeTweens do
			tween:Cancel()
		end
		self.NotificationFadeTweens = nil
	end
	if self.NotificationFadeEntries then
		for _, entry in self.NotificationFadeEntries do
			for propertyName, value in entry.Original do
				entry.Instance[propertyName] = value
			end
		end
		self.NotificationFadeEntries = nil
	end
end

function HUDController:_showNotificationVisual(message)
	self:_cancelNotificationFade()
	self.Notification.Text = message
	self.NotificationFrame.Visible = true
end

function HUDController:_hideNotificationVisual()
	self.NotificationFrame.Visible = false
end

function HUDController:SetPersistentNotification(message)
	local normalizedMessage = if type(message) == "string" and message ~= "" then message else nil
	self.NotificationPersistentMessage = normalizedMessage
	if self.NotificationTransientActive then
		return
	end

	self.NotificationSerial += 1
	self:_cancelNotificationFade()
	if normalizedMessage then
		self:_showNotificationVisual(normalizedMessage)
	else
		self:_hideNotificationVisual()
	end
end

function HUDController:ShowExitSaveNotification(message)
	if type(message) ~= "string" or message == "" then
		return
	end
	self.NotificationSerial += 1
	local serial = self.NotificationSerial
	self.ExitSaveNotificationSerial = serial
	self.NotificationTransientActive = true
	self.NotificationPriorityActive = true
	self:_showNotificationVisual(message)
end

function HUDController:HideExitSaveNotification()
	local exitSerial = self.ExitSaveNotificationSerial
	self.ExitSaveNotificationSerial = nil
	if not exitSerial or exitSerial ~= self.NotificationSerial then
		return
	end

	self.NotificationSerial += 1
	self:_cancelNotificationFade()
	self.NotificationTransientActive = false
	self.NotificationPriorityActive = false
	if self.NotificationPersistentMessage then
		self:_showNotificationVisual(self.NotificationPersistentMessage)
	else
		self:_hideNotificationVisual()
	end
end

function HUDController:ShowNotification(message, holdDuration, priority)
	if type(message) ~= "string" or message == "" then
		return
	end
	local isPriority = priority == true
	if self.NotificationPriorityActive and not isPriority then
		return
	end

	self.NotificationSerial += 1
	local serial = self.NotificationSerial
	self.ExitSaveNotificationSerial = nil
	self.NotificationTransientActive = true
	self.NotificationPriorityActive = isPriority
	self:_showNotificationVisual(message)
	local duration = math.max(0, tonumber(holdDuration) or 2.25)

	task.delay(duration, function()
		if serial ~= self.NotificationSerial then
			return
		end

		local instances = { self.NotificationFrame }
		for _, descendant in self.NotificationFrame:GetDescendants() do
			table.insert(instances, descendant)
		end
		local fadeEntries = {}
		local fadeTweens = {}
		for _, instance in instances do
			local original, goals = getNotificationFadeProperties(instance)
			if next(goals) then
				table.insert(fadeEntries, {
					Instance = instance,
					Original = original,
				})
				table.insert(fadeTweens, TweenService:Create(
					instance,
					TweenInfo.new(NOTIFICATION_FADE_DURATION),
					goals
				))
			end
		end
		self.NotificationFadeEntries = fadeEntries
		self.NotificationFadeTweens = fadeTweens
		for _, tween in fadeTweens do
			tween:Play()
		end
		if fadeTweens[1] then
			fadeTweens[1].Completed:Wait()
		end
		if serial ~= self.NotificationSerial then
			return
		end

		self.NotificationFrame.Visible = false
		self:_cancelNotificationFade()
		self.NotificationTransientActive = false
		self.NotificationPriorityActive = false
		if self.NotificationPersistentMessage then
			self:_showNotificationVisual(self.NotificationPersistentMessage)
		else
			self:_hideNotificationVisual()
		end
	end)
end

return HUDController

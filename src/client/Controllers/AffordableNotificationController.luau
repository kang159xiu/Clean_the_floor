local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local HandUpgradeConfig = require(ReplicatedStorage.Shared.Config.HandUpgradeConfig)
local PlayerAttributeConfig = require(ReplicatedStorage.Shared.Config.PlayerAttributeConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)
local ToolUpgradeConfig = require(ReplicatedStorage.Shared.Config.ToolUpgradeConfig)

local AffordableNotificationController = {}

local MAX_VISIBLE = 4
local STACK_SPACING = 8
local SLIDE_DURATION = 0.3
local HOLD_DURATION = 8  ----可购买停留时间
local FADE_DURATION = 0.25
local REFLOW_DURATION = 0.2
local OFFSCREEN_PADDING = 32
local UPGRADE_INDICATOR_PULSE_SCALE = 1.12
local UPGRADE_INDICATOR_PULSE_DURATION = 0.35
local PANEL_TOOL_IDS = { "Tool02", "Tool03" }

local function normalizedImage(image)
	return if type(image) == "string" then image else ""
end

local function appendCandidate(list, byKey, key, textValue, image)
	local candidate = {
		Key = key,
		Text = textValue,
		Image = normalizedImage(image),
	}
	table.insert(list, candidate)
	byKey[key] = candidate
end

local function fadeProperties(instance)
	local properties = {}
	if instance:IsA("GuiObject") then
		properties.BackgroundTransparency = 1
	end
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		properties.TextTransparency = 1
		properties.TextStrokeTransparency = 1
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
		properties.ImageTransparency = 1
	end
	if instance:IsA("UIStroke") then
		properties.Transparency = 1
	end
	if instance:IsA("CanvasGroup") then
		properties.GroupTransparency = 1
	end
	return properties
end

function AffordableNotificationController:Init(remotes, hudController)
	self.HUDController = hudController
	self.Remotes = remotes
	self.Active = {}
	self.ActiveByKey = {}
	self.Pending = {}
	self.PendingKeys = {}
	self.CurrentCandidates = {}
	self.PreviousAffordable = {}
	self.LastSnapshotCoins = nil
	self.HasAffordablePanelUpgrade = false
	self.UpgradeIndicatorSuppressed = false
	self.CoinGainWhilePanelOpen = false
	self.UpgradeIndicatorPulseTween = nil
	self.UIBound = false
	self.LatestSnapshot = nil
	self.UIConnection = nil

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self.LatestSnapshot = snapshot
		if self.UIBound then
			self:ApplySnapshot(snapshot)
		end
	end)
	hudController:ConnectCoinPresentationSettled(function()
		if self.UIBound then
			self:_pump()
		end
	end)

	local gameHUD = hudController.GameHUD
	if not gameHUD then
		return
	end
	self.GameHUD = gameHUD
	self:_tryBindUI()
	if not self.UIBound then
		self.UIConnection = gameHUD.DescendantAdded:Connect(function()
			task.defer(function()
				self:_tryBindUI()
			end)
		end)
	end
end

function AffordableNotificationController:_tryBindUI()
	if self.UIBound or not self.GameHUD then
		return
	end
	local root = self.GameHUD:FindFirstChild("HUDRoot")
	local template = root and root:FindFirstChild("NotificationFrame02")
	local notification = template and template:FindFirstChild("Notification")
	local icon = template and template:FindFirstChild("Icon")
	local upgradePanel = self.GameHUD:FindFirstChild("UPattribute")
	local frame = self.GameHUD:FindFirstChild("Frame")
	local upgradeButton = frame and frame:FindFirstChild("Upgrade")
	local upgradeIndicator = upgradeButton and upgradeButton:FindFirstChild("tixin")
	if
		not root
		or not template
		or not template:IsA("GuiObject")
		or not notification
		or not notification:IsA("TextLabel")
		or not icon
		or (not icon:IsA("ImageLabel") and not icon:IsA("ImageButton"))
		or not upgradePanel
		or not upgradePanel:IsA("GuiObject")
		or not upgradeButton
		or not upgradeButton:IsA("GuiButton")
		or not upgradeIndicator
		or not upgradeIndicator:IsA("ImageLabel")
	then
		return
	end

	self.Root = root
	self.Template = template
	self.BasePosition = template.Position
	template.Visible = false
	self.UpgradePanel = upgradePanel
	self.UpgradeIndicator = upgradeIndicator
	self.UpgradeIndicatorScale = upgradeIndicator:FindFirstChildOfClass("UIScale")
	if not self.UpgradeIndicatorScale then
		self.UpgradeIndicatorScale = Instance.new("UIScale")
		self.UpgradeIndicatorScale.Name = "AffordableUpgradePulseScale"
		self.UpgradeIndicatorScale.Parent = upgradeIndicator
	end
	self.UpgradeIndicatorBaseScale = self.UpgradeIndicatorScale.Scale
	upgradeIndicator.Visible = false
	self.UpgradeIndicatorSuppressed = upgradePanel.Visible
	upgradePanel:GetPropertyChangedSignal("Visible"):Connect(function()
		self:_handleUpgradePanelVisibilityChanged()
	end)
	self.UIBound = true
	if self.UIConnection then
		self.UIConnection:Disconnect()
		self.UIConnection = nil
	end
	if self.LatestSnapshot then
		self:ApplySnapshot(self.LatestSnapshot)
	end
end

function AffordableNotificationController:_setUpgradeIndicatorVisible(visible)
	if not self.UIBound or not self.UpgradeIndicator then
		return
	end
	local shouldBeVisible = visible == true
	if
		self.UpgradeIndicator.Visible == shouldBeVisible
		and (not shouldBeVisible or self.UpgradeIndicatorPulseTween ~= nil)
	then
		return
	end
	if self.UpgradeIndicatorPulseTween then
		self.UpgradeIndicatorPulseTween:Cancel()
		self.UpgradeIndicatorPulseTween = nil
	end
	self.UpgradeIndicatorScale.Scale = self.UpgradeIndicatorBaseScale
	self.UpgradeIndicator.Visible = shouldBeVisible
	if not shouldBeVisible then
		return
	end
	local tween = TweenService:Create(
		self.UpgradeIndicatorScale,
		TweenInfo.new(
			UPGRADE_INDICATOR_PULSE_DURATION,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut,
			-1,
			true
		),
		{ Scale = self.UpgradeIndicatorBaseScale * UPGRADE_INDICATOR_PULSE_SCALE }
	)
	self.UpgradeIndicatorPulseTween = tween
	tween:Play()
end

function AffordableNotificationController:_refreshUpgradeIndicator()
	self:_setUpgradeIndicatorVisible(
		self.HasAffordablePanelUpgrade
			and not self.UpgradeIndicatorSuppressed
			and not self.UpgradePanel.Visible
	)
end

function AffordableNotificationController:_handleUpgradePanelVisibilityChanged()
	if self.UpgradePanel.Visible then
		self.UpgradeIndicatorSuppressed = true
		self.CoinGainWhilePanelOpen = false
		self:_setUpgradeIndicatorVisible(false)
		return
	end
	if self.CoinGainWhilePanelOpen then
		self.CoinGainWhilePanelOpen = false
		self.UpgradeIndicatorSuppressed = false
	end
	self:_refreshUpgradeIndicator()
end

function AffordableNotificationController:_hasAffordablePanelUpgrade(snapshot)
	local coins = math.max(0, math.floor(tonumber(snapshot.Coins) or 0))
	local rebirthCount = RebirthConfig.NormalizeCount(snapshot.RebirthCount)
	local handLevels = type(snapshot.HandUpgradeLevels) == "table" and snapshot.HandUpgradeLevels or {}
	for _, attributeId in HandUpgradeConfig.Order do
		local level = HandUpgradeConfig.NormalizeLevel(attributeId, handLevels[attributeId])
		if not HandUpgradeConfig.IsMaxLevel(attributeId, level) then
			local price = HandUpgradeConfig.GetNextPrice(attributeId, level, rebirthCount)
			if price and coins >= price then
				return true
			end
		end
	end

	local unlockedTools = type(snapshot.UnlockedTools) == "table" and snapshot.UnlockedTools or {}
	local toolLevels = type(snapshot.ToolUpgradeLevels) == "table" and snapshot.ToolUpgradeLevels or {}
	for _, toolId in PANEL_TOOL_IDS do
		local toolUpgrade = ToolUpgradeConfig.Tools[toolId]
		if toolUpgrade and unlockedTools[toolId] == true then
			local levels = type(toolLevels[toolId]) == "table" and toolLevels[toolId] or {}
			for _, attributeId in toolUpgrade.Order do
				local level = ToolUpgradeConfig.NormalizeLevel(toolId, attributeId, levels[attributeId])
				if not ToolUpgradeConfig.IsMaxLevel(toolId, attributeId, level) then
					local price = ToolUpgradeConfig.GetNextPrice(toolId, attributeId, level, rebirthCount)
					if price and coins >= price then
						return true
					end
				end
			end
		end
	end

	local playerAttributeLevels = type(snapshot.PlayerAttributeLevels) == "table"
		and snapshot.PlayerAttributeLevels
		or {}
	local walkSpeed = tonumber(snapshot.WalkSpeed) or 0
	for _, attributeId in PlayerAttributeConfig.Order do
		local level = PlayerAttributeConfig.NormalizeLevel(attributeId, playerAttributeLevels[attributeId])
		local effectiveMax = (attributeId == "MoveSpeed" and walkSpeed >= PlayerAttributeConfig.MaximumWalkSpeed)
			or PlayerAttributeConfig.IsConfiguredMaxLevel(attributeId, level)
		if not effectiveMax then
			local price = PlayerAttributeConfig.GetUpgradePrice(attributeId, level)
			if price and coins >= price then
				return true
			end
		end
	end
	return false
end

function AffordableNotificationController:_applyUpgradeIndicatorSnapshot(snapshot)
	local coins = math.max(0, math.floor(tonumber(snapshot.Coins) or 0))
	local previousCoins = self.LastSnapshotCoins
	local gainedCoins = previousCoins ~= nil and coins > previousCoins
	self.LastSnapshotCoins = coins
	self.HasAffordablePanelUpgrade = self:_hasAffordablePanelUpgrade(snapshot)
	if gainedCoins then
		if self.UpgradePanel.Visible then
			self.CoinGainWhilePanelOpen = true
		else
			self.UpgradeIndicatorSuppressed = false
		end
	end
	self:_refreshUpgradeIndicator()
end

function AffordableNotificationController:_buildCandidates(snapshot)
	local coins = math.max(0, math.floor(tonumber(snapshot.Coins) or 0))
	local rebirthCount = RebirthConfig.NormalizeCount(snapshot.RebirthCount)
	local unlockedTools = type(snapshot.UnlockedTools) == "table" and snapshot.UnlockedTools or {}
	local candidates = {}
	local byKey = {}

	for _, toolId in PANEL_TOOL_IDS do
		local tool = ToolConfig.ById[toolId]
		local price = RebirthConfig.GetScaledPrice(tool.Price, rebirthCount)
		if
			tool.AvailableForGameplay == true
			and tool.UnlockedByDefault ~= true
			and unlockedTools[tool.Id] ~= true
			and price > 0
			and coins >= price
		then
			appendCandidate(
				candidates,
				byKey,
				"ToolUnlock:" .. tool.Id,
				string.format("Buy: %s ($%s)", tool.Name, CoinFormat.Compact(price)),
				tool.Image
			)
		end
	end

	local currentBagLevel = math.clamp(
		math.floor(tonumber(snapshot.BagLevel) or BagConfig.DefaultLevel),
		BagConfig.DefaultLevel,
		BagConfig.MaxLevel
	)
	local nextBag = BagConfig.Levels[currentBagLevel + 1]
	if snapshot.ActivePermanentBagId == nil and nextBag and coins >= nextBag.Price then
		appendCandidate(
			candidates,
			byKey,
			string.format("BagUpgrade:%d", nextBag.Id),
			string.format("Buy: %s ($%s)", nextBag.Name, CoinFormat.Compact(nextBag.Price)),
			nextBag.Image
		)
	end

	return candidates, byKey
end

function AffordableNotificationController:ApplySnapshot(snapshot)
	self.LatestSnapshot = snapshot
	if not self.UIBound then
		return
	end
	self:_applyUpgradeIndicatorSnapshot(snapshot)
	local candidates, currentCandidates = self:_buildCandidates(snapshot)
	self.CurrentCandidates = currentCandidates

	local currentAffordable = {}
	for _, candidate in candidates do
		currentAffordable[candidate.Key] = true
	end

	local invalidEntries = {}
	for _, entry in self.Active do
		if not currentAffordable[entry.Key] then
			table.insert(invalidEntries, entry)
		end
	end
	for _, entry in invalidEntries do
		self:_dismiss(entry)
	end

	for _, candidate in candidates do
		if not self.PreviousAffordable[candidate.Key] then
			self:_enqueue(candidate.Key)
		end
	end
	self.PreviousAffordable = currentAffordable
	self:_pump()
end

function AffordableNotificationController:_enqueue(key)
	if self.PendingKeys[key] then
		return
	end
	local active = self.ActiveByKey[key]
	if active then
		active.Requeue = true
		return
	end
	self.PendingKeys[key] = true
	table.insert(self.Pending, key)
end

function AffordableNotificationController:_positionForIndex(index)
	local height = self.Template.AbsoluteSize.Y
	if height <= 0 then
		height = math.max(1, self.Template.Size.Y.Offset)
	end
	return self.BasePosition + UDim2.fromOffset(0, (index - 1) * (height + STACK_SPACING))
end

function AffordableNotificationController:_show(candidate)
	local clone = self.Template:Clone()
	clone.Name = "AffordableNotification_" .. string.gsub(candidate.Key, "[^%w_]", "_")
	local notification = clone:WaitForChild("Notification")
	local icon = clone:WaitForChild("Icon")
	notification.Text = candidate.Text
	icon.Image = candidate.Image
	icon.Visible = candidate.Image ~= ""
	clone.Visible = true
	clone.Parent = self.Root

	local finalPosition = self:_positionForIndex(#self.Active + 1)
	clone.Position = UDim2.new(
		1,
		math.max(OFFSCREEN_PADDING, clone.AbsoluteSize.X + OFFSCREEN_PADDING),
		finalPosition.Y.Scale,
		finalPosition.Y.Offset
	)
	local entry = {
		Key = candidate.Key,
		Clone = clone,
		Dismissing = false,
		Requeue = false,
		PositionTween = nil,
	}
	table.insert(self.Active, entry)
	self.ActiveByKey[candidate.Key] = entry

	local slideTween = TweenService:Create(
		clone,
		TweenInfo.new(SLIDE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = finalPosition }
	)
	entry.PositionTween = slideTween
	slideTween:Play()
	task.delay(SLIDE_DURATION + HOLD_DURATION, function()
		if self.ActiveByKey[entry.Key] == entry then
			self:_dismiss(entry)
		end
	end)
end

function AffordableNotificationController:_dismiss(entry)
	if not entry or entry.Dismissing or self.ActiveByKey[entry.Key] ~= entry then
		return
	end
	entry.Dismissing = true
	if entry.PositionTween then
		entry.PositionTween:Cancel()
		entry.PositionTween = nil
	end

	local fadeTweens = {}
	local instances = { entry.Clone }
	for _, descendant in entry.Clone:GetDescendants() do
		table.insert(instances, descendant)
	end
	for _, instance in instances do
		local properties = fadeProperties(instance)
		if next(properties) ~= nil then
			local tween = TweenService:Create(
				instance,
				TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				properties
			)
			table.insert(fadeTweens, tween)
			tween:Play()
		end
	end

	task.delay(FADE_DURATION, function()
		if self.ActiveByKey[entry.Key] == entry then
			self:_remove(entry)
		end
	end)
end

function AffordableNotificationController:_remove(entry)
	self.ActiveByKey[entry.Key] = nil
	for index, activeEntry in self.Active do
		if activeEntry == entry then
			table.remove(self.Active, index)
			break
		end
	end
	if entry.Clone then
		entry.Clone:Destroy()
	end
	if entry.Requeue and self.CurrentCandidates[entry.Key] then
		self:_enqueue(entry.Key)
	end
	self:_reflow()
	self:_pump()
end

function AffordableNotificationController:_reflow()
	for index, entry in self.Active do
		if not entry.Dismissing and entry.Clone.Parent then
			if entry.PositionTween then
				entry.PositionTween:Cancel()
			end
			local tween = TweenService:Create(
				entry.Clone,
				TweenInfo.new(REFLOW_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Position = self:_positionForIndex(index) }
			)
			entry.PositionTween = tween
			tween:Play()
		end
	end
end

function AffordableNotificationController:_pump()
	if self.HUDController:IsCoinPresentationBusy() then
		return
	end
	while #self.Active < MAX_VISIBLE and #self.Pending > 0 do
		local key = table.remove(self.Pending, 1)
		self.PendingKeys[key] = nil
		local candidate = self.CurrentCandidates[key]
		if candidate and not self.ActiveByKey[key] then
			self:_show(candidate)
		end
	end
end

return AffordableNotificationController

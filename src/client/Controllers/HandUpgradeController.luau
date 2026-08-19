local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ModalPanelCoordinator = require(script.Parent.Parent.Effects.ModalPanelCoordinator)
local ModalPanelEffects = require(script.Parent.Parent.Effects.ModalPanelEffects)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local HandUpgradeConfig = require(ReplicatedStorage.Shared.Config.HandUpgradeConfig)
local PlayerAttributeConfig = require(ReplicatedStorage.Shared.Config.PlayerAttributeConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)
local ToolUpgradeConfig = require(ReplicatedStorage.Shared.Config.ToolUpgradeConfig)

local HandUpgradeController = {}

local MODAL_PANEL_ID = "Upgrade"
local PROMPT_REOPEN_SUPPRESSION_SECONDS = 0.35
local AREA_COUNT = RegionConfig.AreaCount
local UPGRADE_SOUND_CLEANUP_TIMEOUT = 10
local DEFAULT_PAGE_NAME = "Player"
local DISABLED_GRADIENT_NAME = "UIGradient002"
local DISABLED_STROKE_NAME = "UIStroke002"
local PAGE_SELECTED_GRADIENT_NAME = "Owned/Locked"
local PAGE_UNSELECTED_GRADIENT_NAME = "Cost"

local PAGE_ORDER = { "Player", "Hands", "Broom", "Blower" }
local PAGE_BUTTON_NAMES = {
	Player = "1",
	Hands = "2",
	Broom = "3",
	Blower = "4",
}

local CARD_CONFIGS = {
	Player = {
		{ CardName = "Pickup Amount", Kind = "Player", AttributeId = "MoveSpeed" },
	},
	Hands = {
		{ CardName = "Pickup Amount", Kind = "Hand", AttributeId = "Amount" },
		{ CardName = "Pickup Range", Kind = "Hand", AttributeId = "Range" },
		{ CardName = "Pickup Speed", Kind = "Hand", AttributeId = "Speed" },
	},
	Broom = {
		{ CardName = "Pickup Amount", Kind = "Tool", ToolId = "Tool02", AttributeId = "ForwardOffset" },
		{ CardName = "Pickup Range", Kind = "Tool", ToolId = "Tool02", AttributeId = "SweepStrength" },
		{ CardName = "Pickup Speed", Kind = "Tool", ToolId = "Tool02", AttributeId = "Range" },
	},
	Blower = {
		{ CardName = "Pickup Amount", Kind = "Tool", ToolId = "Tool03", AttributeId = "Power" },
		{ CardName = "Pickup Range", Kind = "Tool", ToolId = "Tool03", AttributeId = "Range" },
		{ CardName = "Pickup Speed", Kind = "Tool", ToolId = "Tool03", AttributeId = "Accuracy" },
	},
}

local disabledStyleWarnings = {}

local function warnDisabledStyleOnce(message)
	if disabledStyleWarnings[message] then
		return
	end
	disabledStyleWarnings[message] = true
	warn("[HandUpgradeController] " .. message)
end

local function formatNumber(value)
	local numeric = tonumber(value) or 0
	if math.abs(numeric) < 0.005 then
		numeric = 0
	end
	return string.format("%.2f", numeric):gsub("0+$", ""):gsub("%.$", "")
end

local function formatAttributeValue(valueField, value)
	if valueField == "PickupInterval" then
		return formatNumber(value) .. "s"
	elseif valueField == "SweepCoverage" then
		return formatNumber((tonumber(value) or 0) * 100) .. "%"
	end
	return formatNumber(value)
end

local function formatTransition(currentValue, nextValue)
	return currentValue .. "->" .. (nextValue or "MAX")
end

local function findUpgradeButtonGradients(button)
	local availableGradient = button:FindFirstChild("UIGradient1")
	local unavailableGradient = button:FindFirstChild("UIGradient3")
	if
		availableGradient
		and availableGradient:IsA("UIGradient")
		and unavailableGradient
		and unavailableGradient:IsA("UIGradient")
	then
		return {
			Available = availableGradient,
			Unavailable = unavailableGradient,
		}
	end
	return nil
end

local function findChildPath(root, names)
	local current = root
	for _, name in names do
		current = current and current:FindFirstChild(name) or nil
		if not current then
			return nil
		end
	end
	return current
end

local function ensureDisabledVisual(parent, name, className, template)
	if not parent then
		return nil
	end
	local visual = parent:FindFirstChild(name)
	if visual then
		if visual:IsA(className) then
			return visual
		end
		warnDisabledStyleOnce(visual:GetFullName() .. " must be a " .. className)
		return nil
	end
	if not template then
		return nil
	end
	visual = template:Clone()
	visual.Name = name
	visual.Parent = parent
	return visual
end

local function captureAlternativeVisuals(parent, className, disabledVisual)
	local alternatives = {}
	if not parent then
		return alternatives
	end
	for _, child in parent:GetChildren() do
		if child ~= disabledVisual and child:IsA(className) then
			table.insert(alternatives, {
				Instance = child,
				Enabled = child.Enabled,
			})
		end
	end
	return alternatives
end

local function makeDisabledStyle(button, gradientTemplate, strokeTemplate)
	local stud = findChildPath(button, { "Decor", "Stud" })
	local highlight = button:FindFirstChild("Highlight")
	if not stud or not highlight then
		warnDisabledStyleOnce(button:GetFullName() .. " is missing Decor.Stud or Highlight")
		return nil
	end

	local disabledGradient = ensureDisabledVisual(
		stud,
		DISABLED_GRADIENT_NAME,
		"UIGradient",
		gradientTemplate
	)
	local disabledStroke = ensureDisabledVisual(
		highlight,
		DISABLED_STROKE_NAME,
		"UIStroke",
		strokeTemplate
	)
	if not disabledGradient or not disabledStroke then
		warnDisabledStyleOnce(button:GetFullName() .. " could not bind the complete disabled style")
		return nil
	end

	return {
		Gradient = disabledGradient,
		Stroke = disabledStroke,
		GradientAlternatives = captureAlternativeVisuals(stud, "UIGradient", disabledGradient),
		StrokeAlternatives = captureAlternativeVisuals(highlight, "UIStroke", disabledStroke),
	}
end

local function setAlternativeVisuals(alternatives, restore)
	for _, alternative in alternatives do
		if alternative.Instance.Parent then
			alternative.Instance.Enabled = restore == true and alternative.Enabled or false
		end
	end
end

local function setUpgradeButtonAvailable(branch, available)
	local gradients = branch.Gradients
	local disabledStyle = branch.DisabledStyle
	if gradients and disabledStyle then
		gradients.Available.Enabled = available == true
		gradients.Unavailable.Enabled = false
	elseif gradients then
		gradients.Available.Enabled = available == true
		gradients.Unavailable.Enabled = available ~= true
	end
	if disabledStyle then
		setAlternativeVisuals(disabledStyle.GradientAlternatives, available)
		setAlternativeVisuals(disabledStyle.StrokeAlternatives, available)
		disabledStyle.Gradient.Enabled = available ~= true
		disabledStyle.Stroke.Enabled = available ~= true
	end
end

local function setButtonEnabled(button, enabled)
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.Selectable = enabled
end

function HandUpgradeController:_getDisplayName(cardConfig)
	if cardConfig.Kind == "Hand" then
		return HandUpgradeConfig.Attributes[cardConfig.AttributeId].DisplayName
	elseif cardConfig.Kind == "Tool" then
		return ToolUpgradeConfig.GetAttribute(cardConfig.ToolId, cardConfig.AttributeId).DisplayName
	end
	return PlayerAttributeConfig.Attributes[cardConfig.AttributeId].DisplayName
end

function HandUpgradeController:_bindCard(page, cardConfig)
	local card = page:WaitForChild(cardConfig.CardName)
	local nameLabel = card:WaitForChild("Name")
	local infoLabel = card:WaitForChild("Info")
	local button = card:WaitForChild("BuyButtons"):WaitForChild("Buy")
	local costLabel = button:WaitForChild("Cost")
	assert(card:IsA("GuiObject"), card:GetFullName() .. " must be a GuiObject")
	assert(nameLabel:IsA("TextLabel"), nameLabel:GetFullName() .. " must be a TextLabel")
	assert(infoLabel:IsA("TextLabel"), infoLabel:GetFullName() .. " must be a TextLabel")
	assert(button:IsA("GuiButton"), button:GetFullName() .. " must be a GuiButton")
	assert(costLabel:IsA("TextLabel"), costLabel:GetFullName() .. " must be a TextLabel")

	nameLabel.Text = self:_getDisplayName(cardConfig)
	local branch = {
		Button = button,
		Info = infoLabel,
		Cost = costLabel,
		Gradients = findUpgradeButtonGradients(button),
		DisabledStyle = makeDisabledStyle(
			button,
			self.DisabledGradientTemplate,
			self.DisabledStrokeTemplate
		),
	}
	if cardConfig.Kind == "Hand" then
		self.Branches[cardConfig.AttributeId] = branch
	elseif cardConfig.Kind == "Tool" then
		self.ToolBranches[cardConfig.ToolId] = self.ToolBranches[cardConfig.ToolId] or {}
		self.ToolBranches[cardConfig.ToolId][cardConfig.AttributeId] = branch
	else
		self.PlayerAttributeBranches[cardConfig.AttributeId] = branch
	end

	button.Activated:Connect(function()
		if cardConfig.Kind == "Hand" then
			self:_requestUpgrade(cardConfig.AttributeId)
		elseif cardConfig.Kind == "Tool" then
			self:_requestToolUpgrade(cardConfig.ToolId, cardConfig.AttributeId)
		else
			self:_requestPlayerAttributeUpgrade(cardConfig.AttributeId)
		end
	end)
end

function HandUpgradeController:SelectPage(pageName)
	if not self.Pages[pageName] then
		return false
	end
	self.SelectedPageName = pageName
	for _, candidateName in self.PageOrder do
		local selected = candidateName == pageName
		self.Pages[candidateName].Visible = selected
		local visuals = self.PageButtonVisuals[candidateName]
		visuals.Selected.Enabled = selected
		visuals.Unselected.Enabled = not selected
	end
	return true
end

function HandUpgradeController:OpenPage(pageName)
	if not self:SelectPage(pageName) then
		return false
	end
	self:_setPanelVisible(true)
	return true
end

function HandUpgradeController:Init(remotes, toolController)
	self.Remotes = remotes
	self.ToolController = toolController
	assert(type(toolController) == "table", "HandUpgradeController requires ToolController")
	self.Player = Players.LocalPlayer
	self.Levels = {
		Range = 0,
		Speed = 0,
		Amount = 0,
	}
	self.RequestBusy = {}
	self.Branches = {}
	self.ToolBranches = {}
	self.PlayerAttributeBranches = {}
	self.ToolLevels = ToolUpgradeConfig.MakeDefaultLevels()
	self.PlayerAttributeLevels = PlayerAttributeConfig.MakeDefaultLevels()
	self.Coins = 0
	self.WalkSpeed = 16
	self.UnlockedTools = { Tool01 = true }
	self.RebirthCount = 0
	self.BoundWorldAreas = {}
	self.BoundWorldPrompts = {}
	self.SelectedPageName = DEFAULT_PAGE_NAME
	self.UpgradeSoundTemplate = SoundService:WaitForChild("UP")
	assert(self.UpgradeSoundTemplate:IsA("Sound"), "SoundService.UP must be a Sound")
	self.UpgradeFailureSoundTemplate = SoundService:WaitForChild("UPno")
	assert(self.UpgradeFailureSoundTemplate:IsA("Sound"), "SoundService.UPno must be a Sound")

	local playerGui = self.Player:WaitForChild("PlayerGui")
	local gameHUD = playerGui:WaitForChild("GameHUD")
	self.HUDUpgradeButton = gameHUD:WaitForChild("Frame"):WaitForChild("Upgrade")
	assert(self.HUDUpgradeButton:IsA("GuiButton"), "GameHUD.Frame.Upgrade must be a GuiButton")
	self.Panel = gameHUD:WaitForChild("UPattribute")
	assert(self.Panel:IsA("GuiObject"), "GameHUD.UPattribute must be a GuiObject")
	self.Panel.Active = true
	local playerPage = self.Panel:WaitForChild("Player")
	local retiredLeafValueCard = playerPage:FindFirstChild("Pickup Speed")
	if retiredLeafValueCard then
		retiredLeafValueCard:Destroy()
	end
	local disabledStyleSource = findChildPath(self.Panel, {
		"Hands",
		"Pickup Amount",
		"BuyButtons",
		"Buy",
	})
	local disabledGradientTemplate = disabledStyleSource
		and findChildPath(disabledStyleSource, { "Decor", "Stud", DISABLED_GRADIENT_NAME })
	local disabledStrokeTemplate = disabledStyleSource
		and findChildPath(disabledStyleSource, { "Highlight", DISABLED_STROKE_NAME })
	if disabledGradientTemplate and disabledGradientTemplate:IsA("UIGradient") then
		self.DisabledGradientTemplate = disabledGradientTemplate
	else
		warnDisabledStyleOnce(
			"Hands.Pickup Amount is missing Buy.Decor.Stud." .. DISABLED_GRADIENT_NAME
		)
	end
	if disabledStrokeTemplate and disabledStrokeTemplate:IsA("UIStroke") then
		self.DisabledStrokeTemplate = disabledStrokeTemplate
	else
		warnDisabledStyleOnce(
			"Hands.Pickup Amount is missing Buy.Highlight." .. DISABLED_STROKE_NAME
		)
	end
	self.CloseButton = self.Panel:WaitForChild("Banner"):WaitForChild("Close")
	assert(self.CloseButton:IsA("GuiButton"), "GameHUD.UPattribute.Banner.Close must be a GuiButton")

	self.Pages = {}
	self.PageButtons = {}
	self.PageButtonVisuals = {}
	local iconFrame = self.Panel:WaitForChild("UPattributeicon")
	self.PageOrder = table.clone(PAGE_ORDER)
	for _, pageName in self.PageOrder do
		local page = self.Panel:WaitForChild(pageName)
		local pageButton = iconFrame:WaitForChild(PAGE_BUTTON_NAMES[pageName])
		assert(page:IsA("ScrollingFrame"), page:GetFullName() .. " must be a ScrollingFrame")
		assert(pageButton:IsA("GuiButton"), pageButton:GetFullName() .. " must be a GuiButton")
		local stud = pageButton:WaitForChild("Stud")
		local selectedGradient = stud:WaitForChild(PAGE_SELECTED_GRADIENT_NAME)
		local unselectedGradient = stud:WaitForChild(PAGE_UNSELECTED_GRADIENT_NAME)
		assert(stud:IsA("GuiObject"), stud:GetFullName() .. " must be a GuiObject")
		assert(
			selectedGradient:IsA("UIGradient"),
			selectedGradient:GetFullName() .. " must be a UIGradient"
		)
		assert(
			unselectedGradient:IsA("UIGradient"),
			unselectedGradient:GetFullName() .. " must be a UIGradient"
		)
		self.Pages[pageName] = page
		self.PageButtons[pageName] = pageButton
		self.PageButtonVisuals[pageName] = {
			Selected = selectedGradient,
			Unselected = unselectedGradient,
		}
		for _, cardConfig in CARD_CONFIGS[pageName] or {} do
			self:_bindCard(page, cardConfig)
		end
		pageButton.Activated:Connect(function()
			self:SelectPage(pageName)
		end)
	end
	self:SelectPage(DEFAULT_PAGE_NAME)

	self.Panel.Visible = false
	ModalPanelEffects.StopOpen(self.Panel)
	ModalPanelEffects.BindOpenButton(self.HUDUpgradeButton)
	self.SuppressWorldPromptUntil = 0
	ModalPanelCoordinator.Register(MODAL_PANEL_ID, function()
		self:_setPanelVisible(false)
	end)
	self.HUDUpgradeButton.Activated:Connect(function()
		self:_setPanelVisible(not self.Panel.Visible)
	end)
	self.CloseButton.Activated:Connect(function()
		self:_setPanelVisible(false)
	end)
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.E and self.Panel.Visible then
			self.SuppressWorldPromptUntil = os.clock() + PROMPT_REOPEN_SUPPRESSION_SECONDS
			self:_setPanelVisible(false)
		end
	end)
	for areaNumber = 1, AREA_COUNT do
		local area = Workspace:FindFirstChild(string.format("Area_%02d", areaNumber))
		if area then
			self:_bindWorldArea(area)
		end
	end
	Workspace.ChildAdded:Connect(function(child)
		self:_bindWorldArea(child)
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
	self:_renderAll()
end

function HandUpgradeController:_playUpgradeResultSound(upgraded)
	local template = if upgraded then self.UpgradeSoundTemplate else self.UpgradeFailureSoundTemplate
	local sound = template:Clone()
	sound.Name = if upgraded then "UpgradeSuccessSound" else "UpgradeFailureSound"
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.TimePosition = 0
	sound.Parent = SoundService
	sound.Ended:Once(function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
	Debris:AddItem(sound, UPGRADE_SOUND_CLEANUP_TIMEOUT)
	SoundService:PlayLocalSound(sound)
end

function HandUpgradeController:_bindWorldPrompt(prompt)
	if self.BoundWorldPrompts[prompt] or not prompt:IsA("ProximityPrompt") then
		return
	end
	local promptPart = prompt.Parent
	local worldUpgrade = promptPart and promptPart.Parent
	local area = worldUpgrade and worldUpgrade.Parent
	local areaNumber = area and tonumber(area.Name:match("^Area_(%d%d)$"))
	if
		not promptPart
		or not promptPart:IsA("BasePart")
		or promptPart.Name ~= "up"
		or not worldUpgrade
		or worldUpgrade.Name ~= "UPattribute"
		or not area
		or area.Parent ~= Workspace
		or not areaNumber
		or areaNumber < 1
		or areaNumber > AREA_COUNT
	then
		return
	end

	self.BoundWorldPrompts[prompt] = true
	prompt.Triggered:Connect(function(triggeringPlayer)
		if triggeringPlayer ~= nil and triggeringPlayer ~= self.Player then
			return
		end
		if os.clock() >= self.SuppressWorldPromptUntil then
			self:_setPanelVisible(true)
		end
	end)
	prompt.Destroying:Connect(function()
		self.BoundWorldPrompts[prompt] = nil
	end)
end

function HandUpgradeController:_tryBindUpgradeArea(area)
	local worldUpgrade = area:FindFirstChild("UPattribute")
	local promptPart = worldUpgrade and worldUpgrade:FindFirstChild("up")
	local prompt = promptPart and promptPart:FindFirstChild("ProximityPrompt")
	if prompt then
		self:_bindWorldPrompt(prompt)
	end
end

function HandUpgradeController:_bindWorldArea(area)
	local areaNumber = tonumber(area.Name:match("^Area_(%d%d)$"))
	if
		area.Parent ~= Workspace
		or not areaNumber
		or areaNumber < 1
		or areaNumber > AREA_COUNT
		or self.BoundWorldAreas[area]
	then
		return
	end
	self.BoundWorldAreas[area] = true
	self:_tryBindUpgradeArea(area)
	area.DescendantAdded:Connect(function()
		task.defer(function()
			self:_tryBindUpgradeArea(area)
		end)
	end)
	area.Destroying:Connect(function()
		self.BoundWorldAreas[area] = nil
	end)
end

function HandUpgradeController:_setPanelVisible(visible)
	local shouldBeVisible = visible == true
	if shouldBeVisible then
		ModalPanelCoordinator.Open(MODAL_PANEL_ID)
	else
		ModalPanelCoordinator.Close(MODAL_PANEL_ID)
	end
	if shouldBeVisible == self.Panel.Visible then
		return
	end
	if shouldBeVisible then
		self:SelectPage(self.SelectedPageName)
		ModalPanelEffects.PlayOpen(self.Panel)
		self.ToolController:CancelManualPickupInput()
	else
		ModalPanelEffects.StopOpen(self.Panel)
		self.Panel.Visible = false
	end
end

function HandUpgradeController:ApplySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	self.Coins = math.max(0, tonumber(snapshot.Coins) or self.Coins)
	self.RebirthCount = RebirthConfig.NormalizeCount(snapshot.RebirthCount)
	local handLevels = type(snapshot.HandUpgradeLevels) == "table" and snapshot.HandUpgradeLevels or {}
	for _, attributeId in HandUpgradeConfig.Order do
		self.Levels[attributeId] = HandUpgradeConfig.NormalizeLevel(attributeId, handLevels[attributeId])
	end
	self.UnlockedTools = type(snapshot.UnlockedTools) == "table" and snapshot.UnlockedTools or self.UnlockedTools
	local snapshotToolLevels = type(snapshot.ToolUpgradeLevels) == "table" and snapshot.ToolUpgradeLevels or {}
	for toolId, toolUpgrade in ToolUpgradeConfig.Tools do
		local sourceLevels = type(snapshotToolLevels[toolId]) == "table" and snapshotToolLevels[toolId] or {}
		for _, attributeId in toolUpgrade.Order do
			self.ToolLevels[toolId][attributeId] = ToolUpgradeConfig.NormalizeLevel(
				toolId,
				attributeId,
				sourceLevels[attributeId]
			)
		end
	end
	local playerAttributeLevels = type(snapshot.PlayerAttributeLevels) == "table"
		and snapshot.PlayerAttributeLevels
		or {}
	for _, attributeId in PlayerAttributeConfig.Order do
		self.PlayerAttributeLevels[attributeId] = PlayerAttributeConfig.NormalizeLevel(
			attributeId,
			playerAttributeLevels[attributeId]
		)
	end
	self.WalkSpeed = tonumber(snapshot.WalkSpeed) or self.WalkSpeed
	self:_renderAll()
end

function HandUpgradeController:_renderAll()
	for _, attributeId in HandUpgradeConfig.Order do
		self:_renderBranch(attributeId)
	end
	for toolId, toolUpgrade in ToolUpgradeConfig.Tools do
		for _, attributeId in toolUpgrade.Order do
			self:_renderToolBranch(toolId, attributeId)
		end
	end
	for _, attributeId in PlayerAttributeConfig.Order do
		self:_renderPlayerAttributeBranch(attributeId)
	end
end

function HandUpgradeController:_renderPlayerAttributeBranch(attributeId)
	local branch = self.PlayerAttributeBranches[attributeId]
	local attribute = PlayerAttributeConfig.Attributes[attributeId]
	if not branch or not attribute then
		return
	end
	local level = PlayerAttributeConfig.NormalizeLevel(attributeId, self.PlayerAttributeLevels[attributeId])
	local effectiveMax = (attributeId == "MoveSpeed" and self.WalkSpeed >= PlayerAttributeConfig.MaximumWalkSpeed)
		or PlayerAttributeConfig.IsConfiguredMaxLevel(attributeId, level)
	local price = if effectiveMax
		then nil
		else PlayerAttributeConfig.GetUpgradePrice(attributeId, level, self.RebirthCount)
	local currentValue = formatNumber(self.WalkSpeed)
	local nextValue = formatNumber(math.min(
		PlayerAttributeConfig.MaximumWalkSpeed,
		self.WalkSpeed + attribute.ValuePerLevel
	))
	branch.Info.Text = formatTransition(currentValue, if price then nextValue else nil)
	branch.Cost.Text = if price then "$" .. CoinFormat.Compact(price) else "MAX"
	setUpgradeButtonAvailable(branch, price ~= nil and self.Coins >= price)
	setButtonEnabled(branch.Button, price ~= nil)
end

function HandUpgradeController:_renderToolBranch(toolId, attributeId)
	local branch = self.ToolBranches[toolId] and self.ToolBranches[toolId][attributeId]
	local attribute = ToolUpgradeConfig.GetAttribute(toolId, attributeId)
	if not branch or not attribute then
		return
	end
	local level = ToolUpgradeConfig.NormalizeLevel(toolId, attributeId, self.ToolLevels[toolId][attributeId])
	local unlocked = self.UnlockedTools[toolId] == true
	local isMaxLevel = ToolUpgradeConfig.IsMaxLevel(toolId, attributeId, level)
	local currentConfig = ToolUpgradeConfig.GetLevelConfig(toolId, attributeId, level)
	local nextConfig = if isMaxLevel then nil else ToolUpgradeConfig.GetLevelConfig(toolId, attributeId, level + 1)
	local price = if isMaxLevel then nil else ToolUpgradeConfig.GetNextPrice(toolId, attributeId, level, self.RebirthCount)
	local canUpgrade = nextConfig ~= nil and price ~= nil
	local currentValue = formatAttributeValue(attribute.ValueField, currentConfig[attribute.ValueField])
	local nextValue = if canUpgrade then formatAttributeValue(attribute.ValueField, nextConfig[attribute.ValueField]) else nil
	branch.Info.Text = formatTransition(currentValue, nextValue)
	if not unlocked then
		branch.Cost.Text = "Unlock Required"
	elseif canUpgrade then
		branch.Cost.Text = "$" .. CoinFormat.Compact(price)
	else
		branch.Cost.Text = "MAX"
	end
	setUpgradeButtonAvailable(branch, unlocked and canUpgrade and self.Coins >= price)
	setButtonEnabled(branch.Button, if unlocked then canUpgrade else true)
end

function HandUpgradeController:_renderBranch(attributeId)
	local branch = self.Branches[attributeId]
	if not branch then
		return
	end
	local level = HandUpgradeConfig.NormalizeLevel(attributeId, self.Levels[attributeId])
	local attribute = HandUpgradeConfig.Attributes[attributeId]
	local isMaxLevel = HandUpgradeConfig.IsMaxLevel(attributeId, level)
	local currentConfig = HandUpgradeConfig.GetLevelConfig(attributeId, level)
	local nextConfig = if isMaxLevel then nil else HandUpgradeConfig.GetLevelConfig(attributeId, level + 1)
	local price = if isMaxLevel then nil else HandUpgradeConfig.GetNextPrice(attributeId, level, self.RebirthCount)
	local canUpgrade = nextConfig ~= nil and price ~= nil
	local currentValue = formatAttributeValue(attribute.ValueField, currentConfig[attribute.ValueField])
	local nextValue = if canUpgrade then formatAttributeValue(attribute.ValueField, nextConfig[attribute.ValueField]) else nil
	branch.Info.Text = formatTransition(currentValue, nextValue)
	branch.Cost.Text = if canUpgrade then "$" .. CoinFormat.Compact(price) else "MAX"
	setUpgradeButtonAvailable(branch, canUpgrade and self.Coins >= price)
	setButtonEnabled(branch.Button, canUpgrade)
end

function HandUpgradeController:_invokeUpgrade(requestKey, callback)
	if self.RequestBusy[requestKey] then
		return
	end
	self.RequestBusy[requestKey] = true
	local callSucceeded, upgraded, _, snapshot = pcall(callback)
	self.RequestBusy[requestKey] = nil
	if callSucceeded and type(snapshot) == "table" then
		self:ApplySnapshot(snapshot)
	end
	self:_playUpgradeResultSound(callSucceeded and upgraded == true)
end

function HandUpgradeController:_requestUpgrade(attributeId)
	if HandUpgradeConfig.IsMaxLevel(attributeId, self.Levels[attributeId]) then
		return
	end
	self:_invokeUpgrade("Hand:" .. attributeId, function()
		return self.Remotes.UpgradeHandAttribute:InvokeServer(attributeId)
	end)
end

function HandUpgradeController:_requestToolUpgrade(toolId, attributeId)
	local currentLevel = ToolUpgradeConfig.NormalizeLevel(toolId, attributeId, self.ToolLevels[toolId][attributeId])
	if self.UnlockedTools[toolId] == true and ToolUpgradeConfig.IsMaxLevel(toolId, attributeId, currentLevel) then
		return
	end
	self:_invokeUpgrade(toolId .. ":" .. attributeId, function()
		return self.Remotes.UpgradeToolAttribute:InvokeServer(toolId, attributeId)
	end)
end

function HandUpgradeController:_requestPlayerAttributeUpgrade(attributeId)
	local branch = self.PlayerAttributeBranches[attributeId]
	if not branch or branch.Cost.Text == "MAX" then
		return
	end
	self:_invokeUpgrade("PlayerAttribute:" .. attributeId, function()
		return self.Remotes.UpgradePlayerAttribute:InvokeServer(attributeId)
	end)
end

return HandUpgradeController

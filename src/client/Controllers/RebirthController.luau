local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModalPanelCoordinator = require(script.Parent.Parent.Effects.ModalPanelCoordinator)
local ModalPanelEffects = require(script.Parent.Parent.Effects.ModalPanelEffects)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)

local RebirthController = {}

local REQUEST_FAILED_MESSAGE = "Rebirth request failed. Try again."
local MODAL_PANEL_ID = "Rebirth"
local REMINDER_PULSE_SCALE = 1.12
local REMINDER_PULSE_DURATION = 0.35

local function formatMultiplier(value)
	local normalized = math.max(0, tonumber(value) or 0)
	local rounded = math.floor(normalized + 0.5)
	if math.abs(normalized - rounded) < 0.001 then
		return tostring(rounded)
	end
	return string.format("%.1f", normalized)
end

function RebirthController:_setReminderVisible(visible)
	local shouldBeVisible = visible == true
	self.Reminder.Visible = shouldBeVisible
	ModalPanelEffects.SetOpenButtonPulse(
		self.OpenButton,
		shouldBeVisible,
		REMINDER_PULSE_SCALE,
		REMINDER_PULSE_DURATION
	)
end

function RebirthController:_refreshReminder()
	self:_setReminderVisible(
		self.Eligible
			and not self.Panel.Visible
			and not self.RequestRunning
	)
end

function RebirthController:_refreshButtonState()
	local interactable = not self.RequestRunning
	self.OpenButton.Visible = true
	self.OpenButton.Active = interactable
	self.OpenButton.Interactable = interactable
	self.ConfirmButton.Active = interactable
	self.ConfirmButton.Interactable = interactable
	self.SkipButton.Visible = true
	self.SkipButton.Active = interactable and not self.SkipPromptRunning
	self.SkipButton.Interactable = interactable and not self.SkipPromptRunning
	self.EligibleGradient.Enabled = self.Eligible
	self.LockedGradient.Enabled = not self.Eligible
	self:_refreshReminder()
end

function RebirthController:_setPanelVisible(visible)
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
		ModalPanelEffects.StopOpen(self.Panel)
		self.Panel.Visible = false
	end
	self:_refreshReminder()
end

function RebirthController:_applyMultiplierText(rebirthCount)
	local currentCount = RebirthConfig.NormalizeCount(rebirthCount)
	local nextCount = currentCount + 1
	self.CurrentValueText.Text = formatMultiplier(RebirthConfig.GetLeafValueMultiplier(currentCount)) .. "x Cash"
	self.NextValueText.Text = formatMultiplier(RebirthConfig.GetLeafValueMultiplier(nextCount)) .. "x Cash"
	self.CurrentCountText.Text = formatMultiplier(RebirthConfig.GetLeafCountMultiplier(currentCount)) .. "X Quantity"
	self.NextCountText.Text = formatMultiplier(RebirthConfig.GetLeafCountMultiplier(nextCount)) .. "X Quantity"
	self.RebirthCountText.Text = tostring(currentCount)
end

function RebirthController:_applyMoneyProgress(currentCoins, requiredCoins)
	local normalizedRequiredCoins = math.max(1, tonumber(requiredCoins) or RebirthConfig.GetRequiredCoins(0))
	local normalizedCurrentCoins = math.clamp(
		math.floor(tonumber(currentCoins) or 0),
		0,
		normalizedRequiredCoins
	)
	self.MoneyProgressText.Text = string.format(
		"%s/%s",
		tostring(normalizedCurrentCoins),
		tostring(normalizedRequiredCoins)
	)
	local ratio = math.clamp(normalizedCurrentCoins / normalizedRequiredCoins, 0, 1)
	self.MoneyProgressFill.Size = UDim2.new(
		ratio,
		0,
		self.MoneyProgressFillHeight.Scale,
		self.MoneyProgressFillHeight.Offset
	)
end

function RebirthController:ApplySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	self.Eligible = snapshot.RebirthEligible == true
	local rebirthCount = RebirthConfig.NormalizeCount(snapshot.RebirthCount)
	local requiredCoins = math.max(
		1,
		tonumber(snapshot.RebirthRequiredCoins) or RebirthConfig.GetRequiredCoins(rebirthCount)
	)
	self.RequirementText = RebirthConfig.GetRequirementText(
		requiredCoins,
		snapshot.RainbowPoopFoundCount,
		snapshot.RainbowPoopRequiredCount
	)
	self.MoneyExplainText.Text = RebirthConfig.GetMoneyRequirementText(requiredCoins)
	self.ExplainText.Text = RebirthConfig.GetRainbowPoopRequirementText(
		snapshot.RainbowPoopFoundCount,
		snapshot.RainbowPoopRequiredCount
	)
	self:_applyMoneyProgress(snapshot.Coins, requiredCoins)
	local previousRebirthCount = self.LastRebirthCount
	self.LastRebirthCount = rebirthCount
	self:_applyMultiplierText(rebirthCount)
	self:_refreshButtonState()
	if previousRebirthCount ~= nil and rebirthCount > previousRebirthCount then
		self:_setPanelVisible(false)
	end
end

function RebirthController:_requestRebirth()
	if self.RequestRunning then
		return
	end
	if not self.Eligible then
		self.HUDController:ShowNotification(
			self.RequirementText,
			3,
			true
		)
		return
	end
	self.RequestRunning = true
	self:_refreshButtonState()

	local invokeSucceeded, rebirthSucceeded, message = pcall(function()
		return self.Remotes.RequestRebirth:InvokeServer()
	end)
	if not invokeSucceeded then
		rebirthSucceeded = false
		message = REQUEST_FAILED_MESSAGE
	end
	if rebirthSucceeded then
		self.Eligible = false
		self:_setPanelVisible(false)
	elseif type(message) == "string" and message ~= "" then
		self.HUDController:ShowNotification(message, 3, true)
	end

	self.RequestRunning = false
	self:_refreshButtonState()
end

function RebirthController:_promptSkipRebirth()
	if self.RequestRunning or self.SkipPromptRunning then
		return
	end
	self.SkipPromptRunning = true
	self:_refreshButtonState()
	local succeeded, message = pcall(function()
		MarketplaceService:PromptProductPurchase(self.Player, self.SkipProduct.ProductId)
	end)
	if not succeeded then
		warn("Skip Rebirth purchase prompt failed: " .. tostring(message))
		self.SkipPromptRunning = false
		self:_refreshButtonState()
		self.HUDController:ShowNotification("The Skip purchase window is unavailable.", 3, true)
	end
end

function RebirthController:Init(remotes, hudController)
	self.Remotes = remotes
	self.HUDController = hudController
	self.Eligible = false
	self.RequestRunning = false
	self.SkipPromptRunning = false
	self.LastRebirthCount = nil
	local initialRequiredCoins = RebirthConfig.GetRequiredCoins(0)
	self.RequirementText = RebirthConfig.GetRequirementText(
		initialRequiredCoins,
		0,
		RebirthConfig.GetRainbowPoopRequiredCount(0)
	)
	self.Player = Players.LocalPlayer
	self.SkipProduct = ProductConfig.DeveloperProducts.SkipRebirth
	assert(
		self.SkipProduct and tonumber(self.SkipProduct.ProductId),
		"Skip Rebirth Developer Product config is missing"
	)

	local playerGui = self.Player:WaitForChild("PlayerGui")
	local gameHUD = playerGui:WaitForChild("GameHUD")
	self.Panel = gameHUD:WaitForChild("chongshengqueren")
	self.MoneyExplainText = self.Panel:WaitForChild("monexplain")
	assert(
		self.MoneyExplainText:IsA("TextLabel"),
		"GameHUD.chongshengqueren.monexplain must be a TextLabel"
	)
	self.ExplainText = self.Panel:WaitForChild("explain")
	assert(self.ExplainText:IsA("TextLabel"), "GameHUD.chongshengqueren.explain must be a TextLabel")
	self.MoneyExplainText.Text = RebirthConfig.GetMoneyRequirementText(initialRequiredCoins)
	self.ExplainText.Text = RebirthConfig.GetRainbowPoopRequirementText(
		0,
		RebirthConfig.GetRainbowPoopRequiredCount(0)
	)
	local moneyProgress = self.Panel:WaitForChild("jindu")
	assert(moneyProgress:IsA("GuiObject"), "GameHUD.chongshengqueren.jindu must be a GuiObject")
	self.MoneyProgressText = moneyProgress:FindFirstChild("Name")
	assert(
		self.MoneyProgressText and self.MoneyProgressText:IsA("TextLabel"),
		"GameHUD.chongshengqueren.jindu.Name must be a TextLabel"
	)
	local moneyProgressBackground = moneyProgress:WaitForChild("BarBackground")
	assert(
		moneyProgressBackground:IsA("GuiObject"),
		"GameHUD.chongshengqueren.jindu.BarBackground must be a GuiObject"
	)
	self.MoneyProgressFill = moneyProgressBackground:WaitForChild("Fill")
	assert(
		self.MoneyProgressFill:IsA("GuiObject"),
		"GameHUD.chongshengqueren.jindu.BarBackground.Fill must be a GuiObject"
	)
	self.MoneyProgressFillHeight = self.MoneyProgressFill.Size.Y
	self.OpenButton = gameHUD:WaitForChild("Frame"):WaitForChild("Rebirth")
	self.Reminder = self.OpenButton:WaitForChild("tixin")
	assert(self.Reminder:IsA("ImageLabel"), "GameHUD.Frame.Rebirth.tixin must be an ImageLabel")
	self.Reminder.Visible = false
	local responsiveButtons = self.Panel:FindFirstChild("Buttons")
	local responsiveHeader = self.Panel:FindFirstChild("Header")
	local responsiveHeaderButtons = responsiveHeader and responsiveHeader:FindFirstChild("Buttons")
	self.ConfirmButton = responsiveButtons and responsiveButtons:FindFirstChild("RobuxPurchase")
		or self.Panel:FindFirstChild("ImageButton")
	self.SkipButton = responsiveButtons and responsiveButtons:FindFirstChild("SKIP")
	self.CloseButton = self.Panel:FindFirstChild("closes")
		or responsiveHeaderButtons and responsiveHeaderButtons:FindFirstChild("Close")
	assert(self.ConfirmButton and self.ConfirmButton:IsA("GuiButton"), "Rebirth confirm button is missing")
	assert(self.SkipButton and self.SkipButton:IsA("GuiButton"), "Rebirth SKIP button is missing")
	assert(self.CloseButton and self.CloseButton:IsA("GuiButton"), "Rebirth close button is missing")
	self.CurrentValueText = self.Panel:WaitForChild("X1")
	self.NextValueText = self.Panel:WaitForChild("X2")
	self.CurrentCountText = self.Panel:WaitForChild("numX1")
	self.NextCountText = self.Panel:WaitForChild("numX2")
	self.RebirthCountText = assert(
		responsiveHeader and responsiveHeader:FindFirstChild("number"),
		"Rebirth Header.number is missing"
	)
	assert(self.RebirthCountText:IsA("TextLabel"), "Rebirth Header.number must be a TextLabel")
	local stud = self.ConfirmButton:WaitForChild("Stud")
	self.EligibleGradient = stud:WaitForChild("Cost")
	self.LockedGradient = stud:WaitForChild("Owned/Locked")
	assert(self.EligibleGradient:IsA("UIGradient"), "Rebirth Cost must be a UIGradient")
	assert(self.LockedGradient:IsA("UIGradient"), "Rebirth Owned/Locked must be a UIGradient")

	self.Panel.Visible = false
	ModalPanelEffects.StopOpen(self.Panel)
	self.OpenButton.Visible = true
	ModalPanelEffects.BindOpenButton(self.OpenButton)
	ModalPanelCoordinator.Register(MODAL_PANEL_ID, function()
		self:_setPanelVisible(false)
	end)
	self:_applyMultiplierText(0)
	self:_applyMoneyProgress(0, initialRequiredCoins)
	self:_refreshButtonState()

	self.OpenButton.Activated:Connect(function()
		if not self.RequestRunning then
			self:_setPanelVisible(not self.Panel.Visible)
		end
	end)
	self.CloseButton.Activated:Connect(function()
		self:_setPanelVisible(false)
	end)
	self.ConfirmButton.Activated:Connect(function()
		self:_requestRebirth()
	end)
	self.SkipButton.Activated:Connect(function()
		self:_promptSkipRebirth()
	end)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId)
		if userId == self.Player.UserId and productId == self.SkipProduct.ProductId then
			self.SkipPromptRunning = false
			self:_refreshButtonState()
		end
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
end

return RebirthController

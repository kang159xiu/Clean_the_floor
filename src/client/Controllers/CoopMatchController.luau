local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)

local CoopMatchController = {}

local function setRowText(row, text)
	if row:IsA("TextLabel") or row:IsA("TextButton") then
		row.Text = text
		return true
	end
	local label = row:FindFirstChildWhichIsA("TextLabel", true)
	if label then
		label.Text = text
		return true
	end
	return false
end

local function formatTime(seconds)
	local rounded = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
	return string.format("%02d:%02d", math.floor(rounded / 60), rounded % 60)
end

function CoopMatchController:_hideLobbyPanels()
	for _, name in { "Team001", "chongshengqueren", "chongsheng", "dianzhan", "Reset" } do
		local gui = self.GameHUD:FindFirstChild(name)
		if gui and gui:IsA("GuiObject") then
			gui.Visible = false
		end
	end
	local navigationFrame = self.GameHUD:FindFirstChild("Frame")
	local rebirthButton = navigationFrame and navigationFrame:FindFirstChild("Rebirth")
	if rebirthButton and rebirthButton:IsA("GuiObject") then
		rebirthButton.Visible = false
	end
end

function CoopMatchController:_refreshReturnControls()
	local interactable = not self.ReturnPending
	for _, button in {
		self.OpenReturnButton,
		self.ConfirmReturnButton,
		self.CancelReturnButton,
		self.CompletionReturnButton,
	} do
		if button then
			button.Active = interactable
			button.Interactable = interactable
		end
	end
end

function CoopMatchController:_setReturnConfirmationVisible(visible)
	if self.ReturnConfirmationPanel then
		self.ReturnConfirmationPanel.Visible = visible == true and not self.ReturnPending
	end
end

function CoopMatchController:_restorePendingButtonText()
	if
		self.PendingButton
		and self.PendingButton.Parent
		and self.PendingButton:IsA("TextButton")
		and type(self.PendingButtonOriginalText) == "string"
	then
		self.PendingButton.Text = self.PendingButtonOriginalText
	end
	self.PendingButton = nil
	self.PendingButtonOriginalText = nil
end

function CoopMatchController:_handleReturnFailure(message)
	if not self.ReturnPending then
		return
	end
	self.ReturnPending = false
	self:_restorePendingButtonText()
	self:_refreshReturnControls()
	self.HUDController:ShowNotification(message, 4, true)
end

function CoopMatchController:_applySnapshot(snapshot)
	if type(snapshot) ~= "table" or type(snapshot.State) ~= "string" then
		return
	end
	self.Snapshot = snapshot
	if snapshot.ReturnStatus == "TeleportFailed" then
		self:_handleReturnFailure("Could not return to the lobby. Please try again.")
	end
	self:_hideLobbyPanels()
	local completed = snapshot.State == "Completed"
	self.Panel.Visible = completed
	if not completed then
		return
	end
	if not self.CompletionApplied then
		self.CompletionApplied = true
		self.AutomaticController:SetEnabled(false)
		self.ToolController:SetAutomaticPickupActive(false, true)
		self.ToolController:CancelManualPickupInput()
		self.ToolController:SetHotbarSuppressed(true)
	end
	self.TimeLabel.Text = formatTime(snapshot.CompletionSeconds)
	local ranking = type(snapshot.Ranking) == "table" and snapshot.Ranking or {}
	for index, row in self.Rows do
		local entry = ranking[index]
		row.Visible = entry ~= nil
		if entry then
			setRowText(row, string.format(
				"#%d: %s - %dpcs - %s",
				index,
				type(entry.UserName) == "string" and entry.UserName or "Player",
				math.max(0, math.floor(tonumber(entry.Pieces) or 0)),
				CoinFormat.Compact(entry.Coins)
			))
		end
	end
end

function CoopMatchController:_requestReturn(sourceButton)
	if self.ReturnPending then
		return
	end
	self.ReturnPending = true
	self.PendingButton = sourceButton
	self.PendingButtonOriginalText = if sourceButton and sourceButton:IsA("TextButton")
		then sourceButton.Text
		else nil
	if self.PendingButtonOriginalText then
		sourceButton.Text = "Saving..."
	end
	self:_setReturnConfirmationVisible(false)
	self:_refreshReturnControls()
	task.spawn(function()
		local succeeded, result = pcall(function()
			return self.RequestCoopReturn:InvokeServer()
		end)
		if not succeeded or type(result) ~= "table" or result.Status ~= "Teleporting" then
			local status = type(result) == "table" and result.Status or "Failed"
			self:_handleReturnFailure(
				if status == "SaveFailed"
					then "Save failed. Please try returning again."
					else "Could not return to the lobby. Please try again."
			)
		end
	end)
end

function CoopMatchController:_bindReturnConfirmation()
	local returnFrame = self.GameHUD:FindFirstChild("fanhui")
	local openButton = returnFrame and returnFrame:FindFirstChild("Return")
	local lobbyButton = returnFrame and returnFrame:FindFirstChild("Lobby")
	local confirmationPanel = self.GameHUD:FindFirstChild("fanhuidating")
	local confirmButton = confirmationPanel and confirmationPanel:FindFirstChild("Return")
	local cancelButton = confirmationPanel and confirmationPanel:FindFirstChild("no")

	if returnFrame and returnFrame:IsA("GuiObject") then
		returnFrame.Visible = true
	end
	if lobbyButton and lobbyButton:IsA("GuiObject") then
		lobbyButton.Visible = true
	end
	if confirmationPanel and confirmationPanel:IsA("GuiObject") then
		confirmationPanel.Visible = false
	end
	if
		not returnFrame
		or not returnFrame:IsA("GuiObject")
		or not openButton
		or not openButton:IsA("GuiButton")
		or not confirmationPanel
		or not confirmationPanel:IsA("GuiObject")
		or not confirmButton
		or not confirmButton:IsA("GuiButton")
		or not cancelButton
		or not cancelButton:IsA("GuiButton")
	then
		if openButton and openButton:IsA("GuiObject") then
			openButton.Visible = false
		end
		warn(
			"GameHUD.fanhui.Return and GameHUD.fanhuidating.Return/no must exist; "
				.. "the in-match return button is disabled"
		)
		return
	end

	self.OpenReturnButton = openButton
	self.ReturnConfirmationPanel = confirmationPanel
	self.ConfirmReturnButton = confirmButton
	self.CancelReturnButton = cancelButton
	self.OpenReturnButton.Visible = true
	self:_setReturnConfirmationVisible(false)
	self.OpenReturnButton.Activated:Connect(function()
		self:_setReturnConfirmationVisible(true)
	end)
	self.CancelReturnButton.Activated:Connect(function()
		self:_setReturnConfirmationVisible(false)
	end)
	self.ConfirmReturnButton.Activated:Connect(function()
		self:_requestReturn(self.ConfirmReturnButton)
	end)
end

function CoopMatchController:Init(remotes, hudController, toolController, automaticController)
	self.HUDController = hudController
	self.ToolController = toolController
	self.AutomaticController = automaticController
	self.CoopMatchSnapshot = remotes.CoopMatchSnapshot
	self.RequestCoopReturn = remotes.RequestCoopReturn
	assert(self.CoopMatchSnapshot:IsA("RemoteEvent"), "CoopMatchSnapshot must be a RemoteEvent")
	assert(self.RequestCoopReturn:IsA("RemoteFunction"), "RequestCoopReturn must be a RemoteFunction")
	self.GameHUD = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("GameHUD")
	self.Panel = self.GameHUD:WaitForChild("Team")
	local template = self.Panel:WaitForChild("muban")
	self.TimeLabel = template:WaitForChild("TIME")
	assert(self.TimeLabel:IsA("TextLabel"), "GameHUD.Team.muban.TIME must be a TextLabel")
	self.Rows = {}
	for index = 1, 4 do
		local row = template:WaitForChild(string.format("%03d", index))
		assert(row:IsA("GuiObject"), "Coop ranking row must be a GuiObject")
		self.Rows[index] = row
		row.Visible = false
	end
	self.CompletionReturnButton = self.Panel:WaitForChild("nodabian")
	assert(self.CompletionReturnButton:IsA("GuiButton"), "GameHUD.Team.nodabian must be a GuiButton")
	self.Panel.Visible = false
	self:_hideLobbyPanels()
	self:_bindReturnConfirmation()
	self:_refreshReturnControls()
	self.CompletionReturnButton.Activated:Connect(function()
		self:_requestReturn(self.CompletionReturnButton)
	end)
	self.CoopMatchSnapshot.OnClientEvent:Connect(function(snapshot)
		self:_applySnapshot(snapshot)
	end)
	self.CoopMatchSnapshot:FireServer()
end

return CoopMatchController

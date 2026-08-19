local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CoopMatchConfig = require(ReplicatedStorage.Shared.Config.CoopMatchConfig)

local PartyController = {}

local function bindActivated(button, callback)
	assert(button:IsA("GuiButton"), button:GetFullName() .. " must be a GuiButton")
	button.Activated:Connect(callback)
end

local function setButtonEnabled(button, enabled)
	button.Active = enabled
	button.AutoButtonColor = enabled
	button:SetAttribute("PartyEnabled", enabled)
end

local function findGateModel(padId)
	local functionFolder = Workspace:FindFirstChild("Function")
	local pad = functionFolder and functionFolder:FindFirstChild(padId)
	local base = pad and pad:FindFirstChild("底座")
	if not base then
		return nil
	end
	for _, child in base:GetChildren() do
		if child.Name == "Group" and child:IsA("Model") then
			return child
		end
	end
	return nil
end

local function setGateCollision(gateModel, enabled)
	if not gateModel then
		return
	end
	for _, descendant in gateModel:GetDescendants() do
		if descendant:IsA("Part") then
			descendant.CanCollide = enabled
		end
	end
end

function PartyController:_setActivePad(padId)
	if self.ActivePadId and self.ActivePadId ~= padId then
		setGateCollision(findGateModel(self.ActivePadId), false)
	end
	self.ActivePadId = padId
	if padId then
		setGateCollision(findGateModel(padId), true)
	end
end

function PartyController:_refreshMemberGateCollision()
	if self.ActivePadId then
		setGateCollision(findGateModel(self.ActivePadId), true)
	end
end

function PartyController:_invoke(action, value)
	if self.RequestPending then
		return
	end
	self.RequestPending = true
	task.spawn(function()
		local succeeded, accepted, message = pcall(function()
			return self.RequestPartyAction:InvokeServer(action, value)
		end)
		self.RequestPending = false
		if not succeeded then
			warn("Party action failed: " .. tostring(accepted))
		elseif accepted ~= true and type(message) == "string" and message ~= "" then
			warn("Party action rejected: " .. message)
		end
	end)
end

function PartyController:_refreshStatusText()
	local snapshot = self.Snapshot
	if not snapshot or snapshot.Visible ~= true then
		return
	end
	if snapshot.State == "Countdown" then
		local deadline = tonumber(snapshot.DeadlineServerTime) or Workspace:GetServerTimeNow()
		local seconds = math.max(0, math.ceil(deadline - Workspace:GetServerTimeNow()))
		self.StatusLabel.Text = string.format("Auto confirming in %d s", seconds)
	elseif snapshot.State == "Saving" or snapshot.State == "Teleporting" then
		self.StatusLabel.Text = "Starting..."
	elseif snapshot.IsHost == true then
		self.StatusLabel.Text = "Ready to confirm"
	else
		self.StatusLabel.Text = "Waiting for host..."
	end
end

function PartyController:_applySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	self.Snapshot = snapshot
	local visible = snapshot.Visible == true
	self.WaitingPanel.Visible = visible
	self.Panel.Visible = visible and snapshot.IsHost == true and snapshot.State == "Waiting"
	if not visible then
		self:_setActivePad(nil)
		return
	end
	local padId = if type(snapshot.PadId) == "string" then snapshot.PadId else nil
	self:_setActivePad(padId)
	local target = math.clamp(math.floor(tonumber(snapshot.TargetPlayerCount) or 4), 1, 4)
	local currentPlayerCount = math.clamp(
		math.floor(tonumber(snapshot.CurrentPlayerCount) or 1),
		1,
		CoopMatchConfig.MaximumPartySize
	)
	local difficulty = CoopMatchConfig.NormalizeDifficulty(snapshot.Difficulty)
	self.PlayerValue.Text = tostring(target)
	self.DifficultyValue.Text = difficulty
	local canConfigure = snapshot.IsHost == true and snapshot.State == "Waiting"
	setButtonEnabled(self.PlayerMinus, canConfigure and target > currentPlayerCount)
	setButtonEnabled(self.PlayerPlus, canConfigure and target < CoopMatchConfig.MaximumPartySize)
	setButtonEnabled(self.DifficultyPrevious, canConfigure)
	setButtonEnabled(self.DifficultyNext, canConfigure)
	setButtonEnabled(self.ConfirmButton, canConfigure)
	local canLeave = snapshot.State ~= "Saving" and snapshot.State ~= "Teleporting"
	setButtonEnabled(self.ExitButton, canLeave)
	setButtonEnabled(self.WaitingExitButton, canLeave)
	self:_refreshStatusText()
end

function PartyController:_changeTarget(delta)
	local snapshot = self.Snapshot
	if not snapshot or snapshot.IsHost ~= true or snapshot.State ~= "Waiting" then
		return
	end
	local current = math.clamp(math.floor(tonumber(snapshot.TargetPlayerCount) or 4), 1, 4)
	local currentPlayerCount = math.clamp(
		math.floor(tonumber(snapshot.CurrentPlayerCount) or 1),
		1,
		CoopMatchConfig.MaximumPartySize
	)
	local target = math.clamp(current + delta, currentPlayerCount, CoopMatchConfig.MaximumPartySize)
	if target ~= current then
		self:_invoke("SetTarget", target)
	end
end

function PartyController:_changeDifficulty(delta)
	local snapshot = self.Snapshot
	if not snapshot or snapshot.IsHost ~= true or snapshot.State ~= "Waiting" then
		return
	end
	local current = CoopMatchConfig.NormalizeDifficulty(snapshot.Difficulty)
	local index = table.find(CoopMatchConfig.DifficultyOrder, current) or 1
	index = (index - 1 + delta) % #CoopMatchConfig.DifficultyOrder + 1
	self:_invoke("SetDifficulty", CoopMatchConfig.DifficultyOrder[index])
end

function PartyController:Init(remotes)
	self.Player = Players.LocalPlayer
	self.RequestPartyAction = remotes.RequestPartyAction
	self.PartySnapshot = remotes.PartySnapshot
	assert(self.RequestPartyAction:IsA("RemoteFunction"), "RequestPartyAction must be a RemoteFunction")
	assert(self.PartySnapshot:IsA("RemoteEvent"), "PartySnapshot must be a RemoteEvent")

	local gameHud = self.Player:WaitForChild("PlayerGui"):WaitForChild("GameHUD")
	self.Panel = gameHud:WaitForChild("Team001")
	local frame = self.Panel:WaitForChild("Frame")
	local playerFrame = frame:WaitForChild("PLAYER")
	local difficultyFrame = frame:WaitForChild("DIFFICULTY")
	self.PlayerMinus = playerFrame:WaitForChild("-")
	self.PlayerPlus = playerFrame:WaitForChild("+")
	self.PlayerValue = playerFrame:WaitForChild("PLAY"):WaitForChild("4")
	self.DifficultyPrevious = difficultyFrame:WaitForChild("<")
	self.DifficultyNext = difficultyFrame:WaitForChild(">")
	self.DifficultyValue = difficultyFrame:WaitForChild("EASY"):WaitForChild("EASY")
	self.ExitButton = self.Panel:WaitForChild("esc")
	self.ConfirmButton = self.Panel:WaitForChild("nodabian")
	self.StatusLabel = self.Panel:WaitForChild("plain"):WaitForChild("Value")
	self.WaitingPanel = gameHud:WaitForChild("Team0EXC")
	self.WaitingExitButton = self.WaitingPanel:WaitForChild("esc")
	assert(self.PlayerValue:IsA("TextLabel"), "Team001 player value must be a TextLabel")
	assert(self.DifficultyValue:IsA("TextLabel"), "Team001 difficulty value must be a TextLabel")
	assert(self.StatusLabel:IsA("TextLabel"), "Team001.plain.Value must be a TextLabel")
	assert(self.WaitingPanel:IsA("GuiObject"), "GameHUD.Team0EXC must be a GuiObject")
	assert(self.WaitingExitButton:IsA("GuiButton"), "GameHUD.Team0EXC.esc must be a GuiButton")
	self.Panel.Visible = false
	self.WaitingPanel.Visible = false

	bindActivated(self.PlayerMinus, function()
		self:_changeTarget(-1)
	end)
	bindActivated(self.PlayerPlus, function()
		self:_changeTarget(1)
	end)
	bindActivated(self.DifficultyPrevious, function()
		self:_changeDifficulty(-1)
	end)
	bindActivated(self.DifficultyNext, function()
		self:_changeDifficulty(1)
	end)
	bindActivated(self.ConfirmButton, function()
		self:_invoke("Confirm")
	end)
	bindActivated(self.ExitButton, function()
		self:_invoke("Leave")
	end)
	bindActivated(self.WaitingExitButton, function()
		self:_invoke("Leave")
	end)
	self.PartySnapshot.OnClientEvent:Connect(function(snapshot)
		self:_applySnapshot(snapshot)
	end)
	task.spawn(function()
		while true do
			task.wait(0.2)
			self:_refreshMemberGateCollision()
			self:_refreshStatusText()
		end
	end)
end

return PartyController

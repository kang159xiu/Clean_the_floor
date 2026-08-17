local Players = game:GetService("Players")

local LobbyReturnController = {}

local REQUEST_FAILED_MESSAGE = "Unable to return to spawn. Try again."

function LobbyReturnController:_refreshButton()
	local interactable = not self.RequestRunning
	self.Button.Active = interactable
	self.Button.Interactable = interactable
end

function LobbyReturnController:_requestReturn()
	if self.RequestRunning then
		return
	end
	self.RequestRunning = true
	self:_refreshButton()
	self.ToolController:CancelManualPickupInput()

	local callSucceeded, success, message = pcall(function()
		return self.Remotes.RequestReturnToSpawn:InvokeServer()
	end)
	self.RequestRunning = false
	self:_refreshButton()
	if callSucceeded and success == true then
		self.ToolController:RefreshAutomaticPickupActive()
		return
	end
	self.HUDController:ShowNotification(
		if callSucceeded and type(message) == "string" and message ~= ""
			then message
			else REQUEST_FAILED_MESSAGE,
		3,
		true
	)
end

function LobbyReturnController:Init(remotes, toolController, hudController)
	assert(type(toolController) == "table", "LobbyReturnController requires ToolController")
	assert(type(hudController) == "table", "LobbyReturnController requires HUDController")
	assert(
		remotes.RequestReturnToSpawn and remotes.RequestReturnToSpawn:IsA("RemoteFunction"),
		"RequestReturnToSpawn must be a RemoteFunction"
	)
	self.Remotes = remotes
	self.ToolController = toolController
	self.HUDController = hudController
	self.RequestRunning = false

	local gameHUD = Players.LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("GameHUD")
	local returnFrame = gameHUD:FindFirstChild("fanhui")
	local button = returnFrame and returnFrame:FindFirstChild("Lobby")
	if not returnFrame or not returnFrame:IsA("GuiObject") or not button or not button:IsA("TextButton") then
		warn("GameHUD.fanhui.Lobby must be a TextButton; return-to-spawn button is disabled")
		return
	end
	self.Button = button
	self:_refreshButton()
	self.Button.Activated:Connect(function()
		self:_requestReturn()
	end)
end

return LobbyReturnController

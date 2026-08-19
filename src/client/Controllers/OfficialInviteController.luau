local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local ModalPanelEffects = require(script.Parent.Parent.Effects.ModalPanelEffects)
local CoopMatchConfig = require(ReplicatedStorage.Shared.Config.CoopMatchConfig)

local OfficialInviteController = {}

local PROMPT_RECOVERY_SECONDS = 30
local UNAVAILABLE_MESSAGE = "Invites are not available right now."

function OfficialInviteController:_setRequestRunning(running)
	running = running == true
	self.RequestRunning = running
	self.OpenButton.Active = not running
	self.OpenButton.Interactable = not running
end

function OfficialInviteController:_finishRequest(requestSerial)
	if requestSerial ~= nil and requestSerial ~= self.RequestSerial then
		return
	end
	self:_setRequestRunning(false)
end

function OfficialInviteController:_showUnavailable()
	self.HUDController:ShowNotification(UNAVAILABLE_MESSAGE)
end

function OfficialInviteController:_requestInvite()
	if self.RequestRunning or not CoopMatchConfig.IsLobby() then
		return
	end
	self.RequestSerial += 1
	local requestSerial = self.RequestSerial
	self:_setRequestRunning(true)

	local checked, canInvite = pcall(function()
		return SocialService:CanSendGameInviteAsync(self.Player)
	end)
	if requestSerial ~= self.RequestSerial then
		return
	end
	if not checked or canInvite ~= true then
		self:_finishRequest(requestSerial)
		self:_showUnavailable()
		return
	end

	local prompted = pcall(function()
		SocialService:PromptGameInvite(self.Player)
	end)
	if not prompted then
		self:_finishRequest(requestSerial)
		self:_showUnavailable()
		return
	end

	task.delay(PROMPT_RECOVERY_SECONDS, function()
		self:_finishRequest(requestSerial)
	end)
end

function OfficialInviteController:Init(_, hudController)
	self.Player = Players.LocalPlayer
	self.HUDController = hudController
	self.RequestRunning = false
	self.RequestSerial = 0

	local playerGui = self.Player:WaitForChild("PlayerGui")
	local gameHUD = playerGui:WaitForChild("GameHUD")
	self.OpenButton = gameHUD:WaitForChild("Frame"):WaitForChild("invite")
	assert(self.OpenButton:IsA("GuiButton"), "GameHUD.Frame.invite must be a GuiButton")
	ModalPanelEffects.BindOpenButton(self.OpenButton)

	if not CoopMatchConfig.IsLobby() then
		self.OpenButton.Visible = false
		self.OpenButton.Active = false
		self.OpenButton.Interactable = false
		return
	end

	self.OpenButton.Visible = true
	self:_setRequestRunning(false)
	self.OpenButton.Activated:Connect(function()
		task.spawn(function()
			self:_requestInvite()
		end)
	end)
	SocialService.GameInvitePromptClosed:Connect(function(player)
		if player == self.Player then
			self:_finishRequest()
		end
	end)
end

return OfficialInviteController

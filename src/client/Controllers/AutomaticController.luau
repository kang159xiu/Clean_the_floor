local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local AutomaticController = {}

local AUTO_POOP_INTERVAL = 1
local LOOP_POLL_INTERVAL = 0.05
local POOP_TOOL_ID = "Tool05"
local POOP_COST = 50
local MAXIMUM_YARD_POOPS = 20

local function getAutomaticMode(toolId)
	if ToolConfig.IsLeafCleaningTool(toolId) then
		return "Clean", nil
	end
	if toolId == POOP_TOOL_ID then
		return "Poop", AUTO_POOP_INTERVAL
	end
	return nil, nil
end

function AutomaticController:_applyVisualState()
	self.OnGradient.Enabled = self.Enabled
	self.OffGradient.Enabled = not self.Enabled
	self.Label.Text = if self.Enabled then "ON" else "OFF"
end

function AutomaticController:_refreshMode(now, forceCleaningRefresh)
	local mode, interval = getAutomaticMode(self.ToolController:GetEquippedToolId())
	local modeChanged = mode ~= self.LastMode
	self.LastMode = mode
	if modeChanged then
		self.NextActionAt = if mode == "Poop" and interval
			then (now or os.clock()) + interval
			else math.huge
	end
	local shouldHoldCleaning = self.Enabled and not self.Paused and mode == "Clean"
	self.ToolController:SetAutomaticPickupActive(
		shouldHoldCleaning,
		forceCleaningRefresh == true and shouldHoldCleaning
	)
	return mode, interval, modeChanged
end

function AutomaticController:_canRequestPoop()
	if self.Coins < POOP_COST then
		return false
	end
	return self.ActiveYardPoopCount < MAXIMUM_YARD_POOPS
end

function AutomaticController:_step()
	if self.Paused then
		return
	end
	local now = os.clock()
	local mode, interval, modeChanged = self:_refreshMode(now, false)
	if modeChanged or mode == "Clean" then
		return
	end
	if not mode or not interval then
		return
	end

	if now < self.NextActionAt then
		return
	end
	self.NextActionAt = now + interval

	if self:_canRequestPoop() then
		self.PoopController:RequestMakeIfEquipped(true)
	end
end

function AutomaticController:SetPaused(paused)
	local shouldPause = paused == true
	if self.Paused == shouldPause then
		return
	end
	self.Paused = shouldPause
	local now = os.clock()
	self.NextActionAt = math.huge
	local mode, interval = self:_refreshMode(now, false)
	if not self.Paused and mode == "Poop" and interval then
		self.NextActionAt = now + interval
	end
end

function AutomaticController:_startLoop()
	self.LoopSerial += 1
	local serial = self.LoopSerial
	self:_refreshMode(os.clock(), false)
	task.spawn(function()
		while self.Enabled and serial == self.LoopSerial do
			task.wait(LOOP_POLL_INTERVAL)
			if not self.Enabled or serial ~= self.LoopSerial then
				return
			end
			self:_step()
		end
	end)
end

function AutomaticController:SetEnabled(enabled)
	local shouldEnable = enabled == true
	if self.Enabled == shouldEnable then
		self:_applyVisualState()
		return
	end

	self.Enabled = shouldEnable
	self.LoopSerial += 1
	self:_applyVisualState()
	if shouldEnable then
		self:_startLoop()
	else
		self.LastMode = nil
		self.NextActionAt = math.huge
		self.ToolController:SetAutomaticPickupActive(false)
	end
end

function AutomaticController:_applySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	self.Coins = math.max(0, tonumber(snapshot.Coins) or 0)
	self.ActiveYardPoopCount = if type(snapshot.ActiveYardPoops) == "table"
		then #snapshot.ActiveYardPoops
		else 0
	local activeYardOwnerUserId = tonumber(snapshot.ActiveYardOwnerUserId)
	local yardChanged = self.ActiveYardOwnerUserId ~= nil
		and activeYardOwnerUserId ~= self.ActiveYardOwnerUserId
	self.ActiveYardOwnerUserId = activeYardOwnerUserId

	local rebirthCount = math.max(0, math.floor(tonumber(snapshot.RebirthCount) or 0))
	if self.LastRebirthCount ~= nil and rebirthCount > self.LastRebirthCount then
		self:SetEnabled(false)
	end
	self.LastRebirthCount = rebirthCount
	if self.Enabled then
		self:_refreshMode(os.clock(), yardChanged)
	end
end

function AutomaticController:Init(remotes, toolController, poopController, hudController)
	assert(type(toolController) == "table", "AutomaticController requires ToolController")
	assert(type(poopController) == "table", "AutomaticController requires PoopController")
	assert(type(hudController) == "table", "AutomaticController requires HUDController")
	self.Remotes = remotes
	self.ToolController = toolController
	self.PoopController = poopController
	self.HUDController = hudController
	self.Enabled = false
	self.Paused = false
	self.LoopSerial = 0
	self.LastMode = nil
	self.NextActionAt = math.huge
	self.LastRebirthCount = nil
	self.Coins = 0
	self.ActiveYardPoopCount = 0
	self.ActiveYardOwnerUserId = nil

	local player = Players.LocalPlayer
	local root = player:WaitForChild("PlayerGui"):WaitForChild("GameHUD"):WaitForChild("HUDRoot")
	self.Button = root:WaitForChild("Automatic")
	self.Label = self.Button:WaitForChild("TextLabel")
	self.OnGradient = self.Button:WaitForChild("UIGradient1")
	self.OffGradient = self.Button:WaitForChild("UIGradient2")
	assert(self.Button:IsA("GuiButton"), "GameHUD.HUDRoot.Automatic must be a GuiButton")
	assert(self.Label:IsA("TextLabel"), "Automatic.TextLabel must be a TextLabel")
	assert(self.OnGradient:IsA("UIGradient"), "Automatic.UIGradient1 must be a UIGradient")
	assert(self.OffGradient:IsA("UIGradient"), "Automatic.UIGradient2 must be a UIGradient")

	self:_applyVisualState()
	self.Button.Activated:Connect(function()
		self:SetEnabled(not self.Enabled)
	end)
	hudController:ConnectSessionResetSucceeded(function()
		self:SetEnabled(false)
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:_applySnapshot(snapshot)
	end)
end

return AutomaticController

local GuiService = game:GetService("GuiService")

local ExitSaveController = {}

local SUCCESS_MESSAGE = "Progress saved."
local FAILURE_MESSAGE = "Save failed. Please try again."
local BUSY_RETRY_DELAY = 0.25
local MAXIMUM_RETRY_WINDOW = 12

function ExitSaveController:_isCurrentRequest(serial)
	return self.MenuOpen and serial == self.RequestSerial
end

function ExitSaveController:_showFailure(serial)
	if self:_isCurrentRequest(serial) then
		self.HUDController:ShowExitSaveNotification(FAILURE_MESSAGE)
	end
end

function ExitSaveController:_requestSave(serial)
	local retryDeadline = os.clock() + MAXIMUM_RETRY_WINDOW
	while self:_isCurrentRequest(serial) do
		local invoked, response = pcall(function()
			return self.RequestRemote:InvokeServer()
		end)
		if not self:_isCurrentRequest(serial) then
			return
		end
		if not invoked or type(response) ~= "table" then
			self:_showFailure(serial)
			return
		end

		local status = response.Status
		if status == "Saved" then
			self.HUDController:ShowExitSaveNotification(SUCCESS_MESSAGE)
			return
		end
		if status == "Failed" or status == "Unavailable" then
			self:_showFailure(serial)
			return
		end

		local retryDelay
		if status == "Busy" then
			retryDelay = BUSY_RETRY_DELAY
		elseif status == "Cooldown" then
			retryDelay = math.clamp(tonumber(response.RetryAfter) or BUSY_RETRY_DELAY, 0.05, 10)
		else
			self:_showFailure(serial)
			return
		end
		if os.clock() + retryDelay > retryDeadline then
			self:_showFailure(serial)
			return
		end
		task.wait(retryDelay)
	end
end

function ExitSaveController:_onMenuOpened()
	self.MenuOpen = true
	self.RequestSerial += 1
	local serial = self.RequestSerial
	self.HUDController:HideExitSaveNotification()
	task.spawn(function()
		self:_requestSave(serial)
	end)
end

function ExitSaveController:_onMenuClosed()
	self.MenuOpen = false
	self.RequestSerial += 1
	self.HUDController:HideExitSaveNotification()
end

function ExitSaveController:Init(remotes, hudController)
	assert(remotes.RequestProgressSave:IsA("RemoteFunction"), "RequestProgressSave must be a RemoteFunction")
	assert(hudController, "ExitSaveController requires HUDController")
	self.RequestRemote = remotes.RequestProgressSave
	self.HUDController = hudController
	self.MenuOpen = false
	self.RequestSerial = 0

	GuiService.MenuOpened:Connect(function()
		self:_onMenuOpened()
	end)
	GuiService.MenuClosed:Connect(function()
		self:_onMenuClosed()
	end)
end

return ExitSaveController

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local AreaCoinResetService = {}

local requestLocks = {}

function AreaCoinResetService:_resetPlayerCoins(player)
	if requestLocks[player] then
		return
	end
	requestLocks[player] = true
	local succeeded, message = xpcall(function()
		self.LeafService:SetPickupActive(player, false)
		self.ToolActionService:StopPlayer(player)
		local resetSucceeded, resetMessage = self.LeafService:ResetCompletedAreaCoins(player)
		self.PlayerDataService:Notify(player, resetMessage)
		return resetSucceeded
	end, debug.traceback)
	requestLocks[player] = nil
	if not succeeded then
		warn(string.format("Area coin reset failed for %s: %s", player.Name, tostring(message)))
		if player.Parent == Players then
			self.PlayerDataService:Notify(player, "Unable to reset area coins right now.")
		end
	end
end

function AreaCoinResetService:Init(playerDataService, leafService, toolActionService)
	self.PlayerDataService = playerDataService
	self.LeafService = leafService
	self.ToolActionService = toolActionService

	local functionFolder = Workspace:FindFirstChild("Function")
	assert(functionFolder and functionFolder:IsA("Folder"), "Workspace.Function must be a Folder")
	local boundPromptCount = 0
	for _, resetPart in functionFolder:GetChildren() do
		if resetPart.Name == "Reset" and resetPart:IsA("BasePart") then
			local prompt = resetPart:FindFirstChild("ProximityPrompt")
			assert(
				prompt and prompt:IsA("ProximityPrompt"),
				"Workspace.Function.Reset.ProximityPrompt must be a ProximityPrompt"
			)
			prompt.ActionText = "Reset"
			prompt.ObjectText = "Cleared Area Coins"
			prompt.Enabled = true
			prompt.Triggered:Connect(function(player)
				self:_resetPlayerCoins(player)
			end)
			boundPromptCount += 1
		end
	end
	assert(boundPromptCount > 0, "Workspace.Function must contain at least one Reset BasePart")

	Players.PlayerRemoving:Connect(function(player)
		requestLocks[player] = nil
	end)
end

return AreaCoinResetService

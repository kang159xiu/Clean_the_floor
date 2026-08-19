local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local AreaCoinResetService = {}

local PROMPT_AUTHORIZATION_SECONDS = 30
local PROMPT_DISTANCE_MARGIN = 4

local requestLocks = {}
local promptAuthorizations = {}

local function makePayload(status, statusName, message)
	local eligible = status.Eligible == true
	if statusName == "Busy" or statusName == "Unauthorized" or statusName == "Failed" then
		eligible = false
	end
	return {
		Status = statusName or status.Status,
		Message = message or status.RequirementText,
		Eligible = eligible,
		RequirementText = status.RequirementText,
	}
end

function AreaCoinResetService:_getStatus(player)
	return self.LeafService:GetAreaCoinResetStatus(player)
end

function AreaCoinResetService:_isAuthorizationValid(player, authorization)
	if not authorization or os.clock() > authorization.ExpiresAt then
		return false, "Use the reset station before confirming."
	end
	local resetPart = authorization.ResetPart
	local prompt = authorization.Prompt
	if
		not resetPart
		or not resetPart.Parent
		or not prompt
		or prompt.Parent ~= resetPart
		or prompt.Enabled ~= true
	then
		return false, "The reset station is unavailable."
	end
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return false, "Move closer to the reset station."
	end
	local maximumDistance = math.max(0, tonumber(prompt.MaxActivationDistance) or 0)
		+ PROMPT_DISTANCE_MARGIN
	if (rootPart.Position - resetPart.Position).Magnitude > maximumDistance then
		return false, "Move closer to the reset station."
	end
	return true
end

function AreaCoinResetService:_requestReset(player)
	local status = self:_getStatus(player)
	if requestLocks[player] then
		return makePayload(status, "Busy", "Area coin reset is already in progress.")
	end

	local authorization = promptAuthorizations[player]
	local authorized, authorizationMessage = self:_isAuthorizationValid(player, authorization)
	if not authorized then
		promptAuthorizations[player] = nil
		return makePayload(status, "Unauthorized", authorizationMessage)
	end
	promptAuthorizations[player] = nil

	status = self:_getStatus(player)
	if status.Eligible ~= true then
		return makePayload(status)
	end

	requestLocks[player] = true
	local operationSucceeded, resetSucceeded, resetMessage = xpcall(function()
		self.LeafService:SetPickupActive(player, false)
		self.ToolActionService:StopPlayer(player)
		return self.LeafService:ResetCompletedAreaCoins(player)
	end, debug.traceback)
	requestLocks[player] = nil

	if not operationSucceeded then
		warn(string.format("Area coin reset failed for %s: %s", player.Name, tostring(resetSucceeded)))
		local latestStatus = self:_getStatus(player)
		return makePayload(latestStatus, "Failed", "Unable to reset area coins right now.")
	end
	if resetSucceeded ~= true then
		local latestStatus = self:_getStatus(player)
		return makePayload(latestStatus, latestStatus.Status, resetMessage)
	end

	local latestStatus = self:_getStatus(player)
	if player.Parent == Players then
		self.PlayerDataService:Notify(player, resetMessage)
	end
	return makePayload(latestStatus, "Succeeded", resetMessage)
end

function AreaCoinResetService:Init(
	playerDataService,
	leafService,
	toolActionService,
	promptedRemote,
	requestRemote
)
	self.PlayerDataService = playerDataService
	self.LeafService = leafService
	self.ToolActionService = toolActionService
	assert(promptedRemote:IsA("RemoteEvent"), "AreaCoinResetPrompted must be a RemoteEvent")
	assert(requestRemote:IsA("RemoteFunction"), "RequestAreaCoinReset must be a RemoteFunction")

	local functionFolder = Workspace:FindFirstChild("Function")
	assert(functionFolder, "Workspace.Function is missing")
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
				if player.Parent ~= Players then
					return
				end
				promptAuthorizations[player] = {
					Prompt = prompt,
					ResetPart = resetPart,
					ExpiresAt = os.clock() + PROMPT_AUTHORIZATION_SECONDS,
				}
				promptedRemote:FireClient(player, makePayload(self:_getStatus(player)))
			end)
			boundPromptCount += 1
		end
	end
	assert(boundPromptCount > 0, "Workspace.Function must contain at least one Reset BasePart")

	requestRemote.OnServerInvoke = function(player)
		return self:_requestReset(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		requestLocks[player] = nil
		promptAuthorizations[player] = nil
	end)
end

return AreaCoinResetService

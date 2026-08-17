local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local ToolGamePassService = {}

local TOOL_ID = "Tool04"
local OWNERSHIP_ATTEMPTS = 3
local RETRY_DELAYS = { 1, 3 }
local PURCHASE_PROMPT_TIMEOUT = 30

local ownershipByPlayer = {}
local purchasePromptLocks = {}

local function getConfig()
	local config = ToolConfig.ById[TOOL_ID]
	assert(config, "ToolConfig.ById.Tool04 is missing")
	assert(config.PurchaseKind == "GamePass", "Tool04.PurchaseKind must be GamePass")
	assert(tonumber(config.GamePassId), "Tool04.GamePassId must be numeric")
	return config
end

function ToolGamePassService:OwnsPass(player)
	local ownership = ownershipByPlayer[player]
	return ownership ~= nil and ownership.Ready == true and ownership.Owned == true
end

function ToolGamePassService:_applyOwnership(player, ownsPass, equipNow)
	ownershipByPlayer[player] = {
		Ready = true,
		Owned = ownsPass == true,
	}
	local applied = self.PlayerDataService:SetPermanentToolEntitlement(
		player,
		TOOL_ID,
		ownsPass == true,
		equipNow == true,
		true
	)
	self.CollisionService:SetPlayerAccess(player, TOOL_ID, ownsPass == true)
	return applied
end

function ToolGamePassService:_loadOwnership(player)
	local config = getConfig()
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		if player.Parent ~= Players then
			return false, false
		end

		local success, ownsPass = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, config.GamePassId)
		end)
		if success then
			self:_applyOwnership(player, ownsPass == true, false)
			return true, ownsPass == true
		end

		warn(string.format(
			"Tool04 ownership lookup failed for %s (attempt %d/%d): %s",
			player.Name,
			attempt,
			OWNERSHIP_ATTEMPTS,
			tostring(ownsPass)
		))
		if attempt < OWNERSHIP_ATTEMPTS then
			task.wait(RETRY_DELAYS[attempt] or RETRY_DELAYS[#RETRY_DELAYS])
		end
	end

	ownershipByPlayer[player] = {
		Ready = false,
		Owned = false,
	}
	self.PlayerDataService:SetPermanentToolEntitlement(player, TOOL_ID, false, false, false)
	self.CollisionService:SetPlayerAccess(player, TOOL_ID, false)
	return false, false
end

function ToolGamePassService:_equipOwnedTool(player)
	self.PlayerDataService:SetPermanentToolEntitlement(player, TOOL_ID, true, false, true)
	local equipped, message = self.PlayerDataService:SetEquippedTool(player, TOOL_ID)
	if equipped then
		self.PlayerDataService:Notify(player, "Dust Collector equipped.")
	elseif message then
		self.PlayerDataService:Notify(player, message)
	end
end

function ToolGamePassService:_promptPurchase(player)
	if purchasePromptLocks[player] then
		return
	end
	local config = getConfig()
	local promptToken = {}
	purchasePromptLocks[player] = promptToken

	local success, message = pcall(function()
		MarketplaceService:PromptGamePassPurchase(player, config.GamePassId)
	end)
	if not success then
		purchasePromptLocks[player] = nil
		warn(string.format("Tool04 purchase prompt failed for %s: %s", player.Name, tostring(message)))
		self.PlayerDataService:Notify(player, "The Dust Collector purchase window is unavailable.")
		return
	end

	task.delay(PURCHASE_PROMPT_TIMEOUT, function()
		if purchasePromptLocks[player] == promptToken then
			purchasePromptLocks[player] = nil
		end
	end)
end

function ToolGamePassService:_onStationTriggered(player)
	if player.Parent ~= Players or not self.PlayerDataService:GetState(player) then
		return
	end

	local ownership = ownershipByPlayer[player]
	if not ownership or ownership.Ready ~= true then
		local _, ownsPass = self:_loadOwnership(player)
		if ownsPass then
			self:_equipOwnedTool(player)
			return
		end
	elseif ownership.Owned == true then
		self:_equipOwnedTool(player)
		return
	end

	self:_promptPurchase(player)
end

function ToolGamePassService:_bindPurchaseStations()
	local functionFolder = Workspace:WaitForChild("Function")
	local boundCount = 0
	for _, station in functionFolder:GetChildren() do
		if string.lower(station.Name) == string.lower(TOOL_ID) then
			self.CollisionService:RegisterStation(TOOL_ID, station)
			local prompt = station:FindFirstChild("ProximityPrompt")
			if station:IsA("BasePart") and prompt and prompt:IsA("ProximityPrompt") then
				boundCount += 1
				prompt.Triggered:Connect(function(player)
					task.spawn(function()
						self:_onStationTriggered(player)
					end)
				end)
			else
				warn(string.format("Invalid Tool04 purchase station: %s", station:GetFullName()))
			end
		end
	end
	assert(boundCount > 0, "Workspace.Function requires at least one tool04.ProximityPrompt")
end

function ToolGamePassService:Init(playerDataService, collisionService)
	self.PlayerDataService = playerDataService
	self.CollisionService = collisionService
	local config = getConfig()

	playerDataService:SetPermanentToolEntitlementProvider(function(player)
		local ownership = ownershipByPlayer[player]
		return {
			[TOOL_ID] = self:OwnsPass(player),
		}, {
			[TOOL_ID] = ownership ~= nil and ownership.Ready == true,
		}
	end)
	playerDataService:AddPlayerStateReadyHandler(function(player)
		self:_loadOwnership(player)
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if gamePassId ~= config.GamePassId or player.Parent ~= Players then
			return
		end
		purchasePromptLocks[player] = nil
		if wasPurchased ~= true then
			return
		end

		self:_applyOwnership(player, true, true)
		self.PlayerDataService:Notify(player, "Dust Collector unlocked and equipped.")
	end)

	Players.PlayerRemoving:Connect(function(player)
		ownershipByPlayer[player] = nil
		purchasePromptLocks[player] = nil
	end)

	self:_bindPurchaseStations()
end

return ToolGamePassService

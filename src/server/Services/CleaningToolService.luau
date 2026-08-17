local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local CleaningToolService = {}

local CLEANING_TOOL_ATTRIBUTE = "CleaningToolId"
local HOTBAR_ORDER_ATTRIBUTE = "HotbarOrder"

local function resolveReplicatedStoragePath(path)
	local current = ReplicatedStorage
	for segment in string.gmatch(path, "[^%.]+") do
		current = current and current:FindFirstChild(segment)
		if not current then
			return nil
		end
	end
	return current
end

local function getCleaningToolId(instance)
	if not instance or not instance:IsA("Tool") then
		return nil
	end
	local attributeId = instance:GetAttribute(CLEANING_TOOL_ATTRIBUTE)
	if type(attributeId) == "string" and ToolConfig.ById[attributeId] then
		return attributeId
	end
	if ToolConfig.ById[instance.Name] then
		return instance.Name
	end
	return nil
end

local function getToolHotbarOrder(toolId)
	for order, toolIndex in ToolConfig.Order do
		local config = ToolConfig.Tools[toolIndex]
		if config and config.Id == toolId then
			return order
		end
	end
	return 1
end

local function isCleaningTool(instance)
	return instance
		and instance:IsA("Tool")
		and (
			instance:GetAttribute(CLEANING_TOOL_ATTRIBUTE) ~= nil
			or ToolConfig.ById[instance.Name] ~= nil
		)
end

local function sanitizeCleaningToolDescendant(descendant)
	if not descendant:IsA("BasePart") then
		return
	end
	descendant.CanCollide = false
	descendant.CanTouch = false
	descendant.CanQuery = false
	descendant.Massless = true
end

local function sanitizeCleaningTool(tool)
	for _, descendant in tool:GetDescendants() do
		sanitizeCleaningToolDescendant(descendant)
	end
end

function CleaningToolService:_getPlayerContainers(player)
	return {
		player.Character,
		player:FindFirstChildOfClass("Backpack"),
	}
end

function CleaningToolService:_disconnectTool(tool)
	local connections = self.ToolConnections[tool]
	if not connections then
		return
	end
	self.ToolConnections[tool] = nil
	for _, connection in connections do
		if connection.Connected then
			connection:Disconnect()
		end
	end
end

function CleaningToolService:_findCleaningTool(player, toolId)
	for _, container in self:_getPlayerContainers(player) do
		if container then
			for _, child in container:GetChildren() do
				if getCleaningToolId(child) == toolId then
					return child
				end
			end
		end
	end
	return nil
end

function CleaningToolService:_hasLeafCleaningTool(player)
	for _, container in self:_getPlayerContainers(player) do
		if container then
			for _, child in container:GetChildren() do
				local toolId = getCleaningToolId(child)
				if toolId and ToolConfig.IsLeafCleaningTool(toolId) then
					return true
				end
			end
		end
	end
	return false
end

function CleaningToolService:_ensureDefaultCleaningTool(player, character)
	if self.DefaultToolAuditLocks[player] then
		return
	end
	self.DefaultToolAuditLocks[player] = true

	local success, message = pcall(function()
		if player.Parent ~= Players or player.Character ~= character then
			return
		end
		local state = self.PlayerDataService:GetState(player)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
		if
			not state
			or not humanoid
			or humanoid.Health <= 0
			or not backpack
			or player.Character ~= character
			or self:_hasLeafCleaningTool(player)
		then
			return
		end

		local defaultToolId = ToolConfig.DefaultToolId
		local defaultConfig = ToolConfig.ById[defaultToolId]
		if
			not defaultConfig
			or defaultConfig.AvailableForGameplay ~= true
			or not ToolConfig.IsLeafCleaningTool(defaultToolId)
			or state.UnlockedTools[defaultToolId] ~= true
		then
			warn("Default cleaning tool is unavailable for " .. player.Name)
			return
		end

		-- Recheck immediately before cloning so overlapping state/character callbacks
		-- cannot create a duplicate default tool.
		if self:_hasLeafCleaningTool(player) then
			return
		end
		local tool = self:_cloneCleaningTool(
			player,
			backpack,
			defaultToolId,
			getToolHotbarOrder(defaultToolId)
		)
		if not tool or player.Character ~= character or humanoid.Health <= 0 then
			return
		end
		humanoid:EquipTool(tool)
		self:_queueActiveToolRefresh(player, character)
	end)

	self.DefaultToolAuditLocks[player] = nil
	if not success then
		warn(string.format("Default cleaning tool audit failed for %s: %s", player.Name, tostring(message)))
	end
end

function CleaningToolService:_scheduleDefaultToolAudit(player, character)
	self.DefaultToolAuditVersions[player] = (self.DefaultToolAuditVersions[player] or 0) + 1
	local auditVersion = self.DefaultToolAuditVersions[player]
	task.delay(0.25, function()
		if self.DefaultToolAuditVersions[player] ~= auditVersion then
			return
		end
		self:_ensureDefaultCleaningTool(player, character)
	end)
end

function CleaningToolService:_getActiveCleaningTool(player, character)
	if not character or player.Character ~= character then
		return nil
	end
	for _, child in character:GetChildren() do
		if isCleaningTool(child) then
			return child
		end
	end
	return nil
end

function CleaningToolService:_stopPlayerToolUse(player)
	if self.ToolActionService then
		self.ToolActionService:StopPlayer(player)
	end
	if self.LeafService then
		self.LeafService:SetPickupActive(player, false)
		self.LeafService:ClearHarvestAim(player)
	end
end

function CleaningToolService:_refreshActiveTool(player, character)
	if player.Parent ~= Players or player.Character ~= character then
		return
	end
	local activeTool = self:_getActiveCleaningTool(player, character)
	local toolId = activeTool and getCleaningToolId(activeTool) or nil
	self.PlayerDataService:SetEquippedToolFromInventory(player, toolId)
end

function CleaningToolService:_queueActiveToolRefresh(player, character)
	task.defer(function()
		self:_refreshActiveTool(player, character)
	end)
end

function CleaningToolService:_bindTool(player, tool)
	if not isCleaningTool(tool) then
		return
	end
	sanitizeCleaningTool(tool)
	if self.ToolConnections[tool] then
		return
	end

	local connections = {}
	self.ToolConnections[tool] = connections
	connections.DescendantAdded = tool.DescendantAdded:Connect(sanitizeCleaningToolDescendant)
	connections.Equipped = tool.Equipped:Connect(function()
		sanitizeCleaningTool(tool)
		task.defer(function()
			if tool.Parent then
				sanitizeCleaningTool(tool)
			end
		end)
		local toolId = getCleaningToolId(tool)
		local state = self.PlayerDataService:GetState(player)
		local config = toolId and ToolConfig.ById[toolId]
		if
			not state
			or not config
			or config.AvailableForGameplay ~= true
			or state.UnlockedTools[toolId] ~= true
		then
			tool:Destroy()
			return
		end
		self:_stopPlayerToolUse(player)
		self.PlayerDataService:SetEquippedToolFromInventory(player, toolId)
	end)
	connections.Unequipped = tool.Unequipped:Connect(function()
		task.defer(function()
			if tool.Parent then
				sanitizeCleaningTool(tool)
			end
		end)
		self:_stopPlayerToolUse(player)
		local character = player.Character
		if character then
			self:_queueActiveToolRefresh(player, character)
		end
	end)
	connections.Destroying = tool.Destroying:Connect(function()
		self:_disconnectTool(tool)
	end)
end

function CleaningToolService:_getExpectedToolIds(state)
	local expectedIds = {}
	for order, toolIndex in ToolConfig.Order do
		local config = ToolConfig.Tools[toolIndex]
		if
			config
			and config.AvailableForGameplay == true
			and state.UnlockedTools[config.Id] == true
		then
			table.insert(expectedIds, {
				Id = config.Id,
				Order = order,
			})
		end
	end
	return expectedIds
end

function CleaningToolService:_inventoryNeedsRebuild(player, state)
	local counts = {}
	for _, container in self:_getPlayerContainers(player) do
		if container then
			for _, child in container:GetChildren() do
				if isCleaningTool(child) then
					local toolId = getCleaningToolId(child)
					if not toolId then
						return true
					elseif child:GetAttribute(CLEANING_TOOL_ATTRIBUTE) ~= toolId then
						return true
					else
						local config = ToolConfig.ById[toolId]
						if
							not config
							or config.AvailableForGameplay ~= true
							or state.UnlockedTools[toolId] ~= true
						then
							return true
						end
						counts[toolId] = (counts[toolId] or 0) + 1
					end
				end
			end
		end
	end

	for _, expected in self:_getExpectedToolIds(state) do
		if counts[expected.Id] ~= 1 then
			return true
		end
		counts[expected.Id] = nil
	end
	return next(counts) ~= nil
end

function CleaningToolService:_destroyCleaningTools(player)
	local toolsToDestroy = {}
	for _, container in self:_getPlayerContainers(player) do
		if container then
			for _, child in container:GetChildren() do
				if isCleaningTool(child) then
					table.insert(toolsToDestroy, child)
				end
			end
		end
	end
	for _, tool in toolsToDestroy do
		self:_disconnectTool(tool)
		tool:Destroy()
	end
end

function CleaningToolService:_cloneCleaningTool(player, backpack, toolId, hotbarOrder)
	local config = ToolConfig.ById[toolId]
	local template = config and resolveReplicatedStoragePath(config.ModelPath)
	if not config or not template or not template:IsA("Tool") then
		warn(string.format("Cleaning tool template missing or invalid: %s", tostring(config and config.ModelPath)))
		return nil
	end

	local clone = template:Clone()
	clone.Name = config.Id
	clone.ToolTip = config.Name
	if type(config.Image) == "string" then
		clone.TextureId = config.Image
	end
	clone.CanBeDropped = false
	clone:SetAttribute(CLEANING_TOOL_ATTRIBUTE, config.Id)
	clone:SetAttribute(HOTBAR_ORDER_ATTRIBUTE, hotbarOrder)
	sanitizeCleaningTool(clone)
	clone.Parent = backpack
	self:_bindTool(player, clone)
	return clone
end

function CleaningToolService:_rebuildInventory(player, state, backpack)
	self:_destroyCleaningTools(player)
	for _, expected in self:_getExpectedToolIds(state) do
		self:_cloneCleaningTool(player, backpack, expected.Id, expected.Order)
	end
end

function CleaningToolService:_bindExistingTools(player)
	for _, container in self:_getPlayerContainers(player) do
		if container then
			for _, child in container:GetChildren() do
				if isCleaningTool(child) then
					self:_bindTool(player, child)
				end
			end
		end
	end
end

function CleaningToolService:SyncPlayer(player, toolId, forceRebuild)
	self.SyncVersions[player] = (self.SyncVersions[player] or 0) + 1
	local syncVersion = self.SyncVersions[player]
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
	if self.SyncVersions[player] ~= syncVersion or not backpack then
		return
	end

	local state = self.PlayerDataService:GetState(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not state or not character or not humanoid or humanoid.Health <= 0 then
		return
	end

	if forceRebuild == true or self:_inventoryNeedsRebuild(player, state) then
		self:_rebuildInventory(player, state, backpack)
	else
		self:_bindExistingTools(player)
	end
	if self.SyncVersions[player] ~= syncVersion then
		return
	end
	self:_scheduleDefaultToolAudit(player, character)

	if toolId == nil then
		humanoid:UnequipTools()
		self:_queueActiveToolRefresh(player, character)
		return
	end

	local config = ToolConfig.ById[toolId]
	if
		not config
		or config.AvailableForGameplay ~= true
		or state.UnlockedTools[toolId] ~= true
	then
		return
	end
	local tool = self:_findCleaningTool(player, toolId)
	if not tool then
		self.PlayerDataService:SetEquippedToolFromInventory(player, nil)
		return
	end
	humanoid:EquipTool(tool)
	self:_queueActiveToolRefresh(player, character)
end

function CleaningToolService:_disconnectCharacter(player)
	local connections = self.CharacterConnections[player]
	if not connections then
		return
	end
	self.CharacterConnections[player] = nil
	for _, connection in connections do
		if connection.Connected then
			connection:Disconnect()
		end
	end
end

function CleaningToolService:_bindCharacter(player, character, skipInitialSync)
	if self.ResettingPlayers[player] then
		return
	end
	self:_disconnectCharacter(player)
	local connections = {}
	self.CharacterConnections[player] = connections
	connections.ChildAdded = character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			if isCleaningTool(child) then
				self:_bindTool(player, child)
			end
			self:_queueActiveToolRefresh(player, character)
		end
	end)
	connections.ChildRemoved = character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			self:_queueActiveToolRefresh(player, character)
		end
	end)
	self:_scheduleDefaultToolAudit(player, character)

	task.spawn(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
		if not humanoid or player.Character ~= character then
			return
		end
		connections.Died = humanoid.Died:Connect(function()
			self:_stopPlayerToolUse(player)
			self.PlayerDataService:SetEquippedToolFromInventory(player, nil)
		end)
		local state = self.PlayerDataService:GetState(player)
		if state and skipInitialSync ~= true then
			local preferredToolId = state.LastEquippedTool or ToolConfig.DefaultToolId
			self:SyncPlayer(player, preferredToolId, true)
		end
	end)
end

function CleaningToolService:BeginPlayerReset(player)
	if not player or player.Parent ~= Players then
		return false
	end
	self.ResettingPlayers[player] = true
	self.SyncVersions[player] = (self.SyncVersions[player] or 0) + 1
	self.DefaultToolAuditVersions[player] = (self.DefaultToolAuditVersions[player] or 0) + 1
	self.DefaultToolAuditLocks[player] = nil
	self:_stopPlayerToolUse(player)
	self:_disconnectCharacter(player)
	self:_destroyCleaningTools(player)
	return true
end

function CleaningToolService:CompletePlayerReset(player, preferredToolId)
	if not player or player.Parent ~= Players then
		self.ResettingPlayers[player] = nil
		return false
	end
	self.ResettingPlayers[player] = nil
	local character = player.Character
	if not character then
		return false
	end
	self:_bindCharacter(player, character, true)
	local state = self.PlayerDataService:GetState(player)
	local toolId = preferredToolId
	if type(toolId) ~= "string" then
		toolId = state and state.LastEquippedTool or ToolConfig.DefaultToolId
	end
	return self:SyncPlayer(player, toolId, true)
end

function CleaningToolService:_bindPlayer(player)
	local oldConnection = self.PlayerConnections[player]
	if oldConnection then
		oldConnection:Disconnect()
	end
	self.PlayerConnections[player] = player.CharacterAdded:Connect(function(character)
		self:_bindCharacter(player, character)
	end)
	if player.Character then
		self:_bindCharacter(player, player.Character)
	end
end

function CleaningToolService:Init(playerDataService, toolActionService, leafService)
	self.PlayerDataService = playerDataService
	self.ToolActionService = toolActionService
	self.LeafService = leafService
	self.PlayerConnections = {}
	self.CharacterConnections = {}
	self.ToolConnections = {}
	self.SyncVersions = {}
	self.DefaultToolAuditVersions = {}
	self.DefaultToolAuditLocks = {}
	self.ResettingPlayers = {}

	playerDataService:AddPlayerStateReadyHandler(function(player)
		local character = player.Character
		if character then
			self:_scheduleDefaultToolAudit(player, character)
		end
	end)

	playerDataService:SetEquippedToolChangedHandler(function(player, toolId)
		self:_stopPlayerToolUse(player)
		task.spawn(function()
			self:SyncPlayer(player, toolId, false)
		end)
	end)

	Players.PlayerAdded:Connect(function(player)
		self:_bindPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_stopPlayerToolUse(player)
		self:_disconnectCharacter(player)
		local playerConnection = self.PlayerConnections[player]
		if playerConnection then
			playerConnection:Disconnect()
		end
		self.PlayerConnections[player] = nil
		self.SyncVersions[player] = nil
		self.DefaultToolAuditVersions[player] = nil
		self.DefaultToolAuditLocks[player] = nil
		self.ResettingPlayers[player] = nil
	end)

	for _, player in Players:GetPlayers() do
		self:_bindPlayer(player)
	end
end

return CleaningToolService

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LostItemConfig = require(ReplicatedStorage.Shared.Config.LostItemConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local PoopService = {}

local TOOL_ID = "Tool05"
local MAKE_COST = 50
local MAKE_COOLDOWN = 1
local AUTOMATIC_FAILURE_NOTIFICATION_COOLDOWN = 5
local MAXIMUM_YARD_ITEMS = 20
local MAXIMUM_LOBBY_ITEMS = 30
local LOBBY_ITEM_SPACING = 2
local LOBBY_SOUND_DISTANCE = 5
local MAKE_HOP_DELAY = math.max(0, tonumber(ToolConfig.ById[TOOL_ID].HopDelay) or 0.2)
local MAKE_HOP_VELOCITY = math.max(0, tonumber(ToolConfig.ById[TOOL_ID].HopVelocity) or 25)
local MAKE_HOP_COOLDOWN = 1
local MAKE_SPAWN_DELAY = math.max(0, tonumber(ToolConfig.ById[TOOL_ID].SpawnDelay) or 0.8)
local MAKE_SOUND_DELAY = math.max(0, tonumber(ToolConfig.ById[TOOL_ID].SpawnSoundDelay) or 0.4)
local CREATOR_PICKUP_DELAY = math.max(0, tonumber(ToolConfig.ById[TOOL_ID].CreatorPickupDelay) or 5)
local GROUND_RAY_HEIGHT = 3
local GROUND_RAY_DISTANCE = 18
local PICKUP_DISTANCE_PADDING = 3
local MAKE_FAILURE_MESSAGE = "Poop could not be created. No Coins were charged."
local MAKE_INSUFFICIENT_COINS_MESSAGE = "Not enough Coins to make poop. No Coins were charged."
local MAKE_YARD_FULL_MESSAGE = "The current yard already has 20 poops. No Coins were charged."
local MAKE_COOLDOWN_MESSAGE = "Please wait before making another poop. No Coins were charged."
local MAKE_SUCCESS_MESSAGE = "Poop: -50 Coins"

local yardsByOwner = {}
local sharedItemsBySpawnId = {}
local lobbyItemsBySpawnId = {}
local lastAcceptedMakeTimes = {}
local lastAutomaticFailureNotificationTimes = {}
local lastHopTimes = {}
local pendingMakeRequests = {}
local permissionRequestTimes = {}
local pickupLocks = {}

local function withNoCharge(message)
	local text = type(message) == "string" and message or "Poop could not be created."
	if string.sub(text, -1) ~= "." then
		text ..= "."
	end
	return text .. " No Coins were charged."
end

local function getYard(owner, create)
	local yard = yardsByOwner[owner]
	if not yard and create == true then
		yard = {
			Owner = owner,
			Items = {},
		}
		yardsByOwner[owner] = yard
	end
	return yard
end

local function getItemCount(yard)
	local count = 0
	for _ in yard.Items do
		count += 1
	end
	return count
end

local function getDictionaryCount(dictionary)
	local count = 0
	for _ in dictionary do
		count += 1
	end
	return count
end

local function detachProjection(owner, yard, item)
	if yard and yard.Items[item.SpawnId] == item then
		yard.Items[item.SpawnId] = nil
	end
	if item.ProjectionYards[owner] == yard then
		item.ProjectionYards[owner] = nil
	end
end

local function discardUnprojectedItem(item)
	if
		item.TutorialPickupUserId == nil
		and next(item.ProjectionYards) == nil
		and sharedItemsBySpawnId[item.SpawnId] == item
	then
		sharedItemsBySpawnId[item.SpawnId] = nil
	end
end

local function destroySharedItem(item)
	if not item then
		return {}
	end
	local affectedOwners = {}
	for owner, yard in item.ProjectionYards do
		table.insert(affectedOwners, {
			Owner = owner,
			Yard = yard,
		})
	end
	for _, projection in affectedOwners do
		detachProjection(projection.Owner, projection.Yard, item)
	end
	sharedItemsBySpawnId[item.SpawnId] = nil
	local owners = {}
	for _, projection in affectedOwners do
		table.insert(owners, projection.Owner)
	end
	return owners
end

local function rollbackCreatedItems(item, createdItems)
	local createdYards = {}
	for index = #createdItems, 1, -1 do
		local created = createdItems[index]
		detachProjection(created.Owner, created.Yard, item)
		if created.CreatedYard then
			createdYards[created.Owner] = created.Yard
		end
	end
	for owner, yard in createdYards do
		if yardsByOwner[owner] == yard and getItemCount(yard) == 0 then
			yardsByOwner[owner] = nil
		end
	end
	discardUnprojectedItem(item)
end

function PoopService:_pushYard(owner)
	for _, member in self.YardService:GetMembers(owner) do
		if self.PlayerDataService:GetState(member) then
			self.PlayerDataService:PushSnapshot(member)
		end
	end
end

function PoopService:_clearEmptyYard(owner)
	if owner and #self.YardService:GetMembers(owner) == 0 then
		self:_detachYard(owner)
	end
end

function PoopService:_detachYard(owner)
	local yard = owner and getYard(owner, false) or nil
	if not yard then
		return false
	end

	local items = {}
	for _, item in yard.Items do
		table.insert(items, item)
	end
	for _, item in items do
		detachProjection(owner, yard, item)
		discardUnprojectedItem(item)
	end
	yardsByOwner[owner] = nil
	return true
end

function PoopService:GetSnapshot(player)
	local owner = self.YardService:GetActiveOwner(player)
	local yard = owner and getYard(owner, false) or nil
	local result = {}
	for _, item in yard and yard.Items or {} do
		table.insert(result, {
			SpawnId = item.SpawnId,
			LostItemId = item.LostItemId,
			OwnerUserId = owner.UserId,
			CreatorUserId = item.CreatorUserId,
			CreatorName = item.CreatorName,
			CreatorPickupUnlockTime = item.CreatorPickupUnlockTime,
			TutorialPickupUserId = item.TutorialPickupUserId,
			PickupAllowed = item.TutorialPickupUserId == nil or item.TutorialPickupUserId == player.UserId,
			WorldPivotCFrame = item.WorldPivotCFrame,
		})
	end
	for spawnId, item in sharedItemsBySpawnId do
		if item.TutorialPickupUserId ~= nil and (not yard or yard.Items[spawnId] ~= item) then
			table.insert(result, {
				SpawnId = item.SpawnId,
				LostItemId = item.LostItemId,
				OwnerUserId = item.SourceYardOwnerUserId,
				CreatorUserId = item.CreatorUserId,
				CreatorName = item.CreatorName,
				CreatorPickupUnlockTime = item.CreatorPickupUnlockTime,
				TutorialPickupUserId = item.TutorialPickupUserId,
				PickupAllowed = item.TutorialPickupUserId == player.UserId,
				WorldPivotCFrame = item.WorldPivotCFrame,
			})
		end
	end
	table.sort(result, function(left, right)
		return left.SpawnId < right.SpawnId
	end)
	local lobbyResult = {}
	for _, item in lobbyItemsBySpawnId do
		table.insert(lobbyResult, {
			SpawnId = item.SpawnId,
			LostItemId = item.LostItemId,
			CreatorPickupUnlockTime = 0,
			PickupAllowed = true,
			HideCreatorBillboard = true,
			IsLobbyPoop = true,
			WorldPivotCFrame = item.WorldPivotCFrame,
		})
	end
	table.sort(lobbyResult, function(left, right)
		return left.SpawnId < right.SpawnId
	end)
	return result, lobbyResult
end

function PoopService:_pushAllPlayers()
	for _, player in Players:GetPlayers() do
		if self.PlayerDataService:GetState(player) then
			self.PlayerDataService:PushSnapshot(player)
		end
	end
end

function PoopService:_playLobbyPoopSound(position)
	local eventId = HttpService:GenerateGUID(false)
	for _, player in Players:GetPlayers() do
		local rootPart = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") and self.PlayerDataService:GetState(player) then
			if (rootPart.Position - position).Magnitude <= LOBBY_SOUND_DISTANCE then
				self.Remotes.PoopSoundTriggered:FireClient(player, eventId, position)
			end
		end
	end
end

function PoopService:TryCreateLobbyPoop(groundPosition, forwardDirection)
	if typeof(groundPosition) ~= "Vector3" or typeof(forwardDirection) ~= "Vector3" then
		return false
	end
	if getDictionaryCount(lobbyItemsBySpawnId) >= MAXIMUM_LOBBY_ITEMS then
		return false
	end
	local horizontalForward = Vector3.new(forwardDirection.X, 0, forwardDirection.Z)
	if horizontalForward.Magnitude < 0.001 then
		return false
	end
	horizontalForward = horizontalForward.Unit
	local lostItemId = LostItemConfig.ChoosePoopItemId(self.Random)
	local templatePivotHeight = self.TemplatePivotHeights[lostItemId]
	if not templatePivotHeight then
		return false
	end
	local position = groundPosition + Vector3.new(0, templatePivotHeight, 0)
	for _, existingItem in lobbyItemsBySpawnId do
		local offset = existingItem.WorldPivotCFrame.Position - position
		if Vector2.new(offset.X, offset.Z).Magnitude < LOBBY_ITEM_SPACING then
			return false
		end
	end
	local spawnId = "LobbyCowPoop_" .. HttpService:GenerateGUID(false)
	lobbyItemsBySpawnId[spawnId] = {
		SpawnId = spawnId,
		LostItemId = lostItemId,
		SourceAreaId = "Lobby",
		WorldPivotCFrame = CFrame.lookAt(position, position + horizontalForward),
	}
	self:_playLobbyPoopSound(position)
	self:_pushAllPlayers()
	return true
end

function PoopService:_getPlacementCFrame(player, lostItemId)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not rootPart or not rootPart:IsA("BasePart") then
		return nil
	end
	local equippedTool = character:FindFirstChildOfClass("Tool")
	if not equippedTool or equippedTool:GetAttribute("CleaningToolId") ~= TOOL_ID then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excludedInstances = { character }
	for _, otherPlayer in Players:GetPlayers() do
		local otherCharacter = otherPlayer.Character
		if otherCharacter and otherCharacter ~= character then
			table.insert(excludedInstances, otherCharacter)
		end
	end
	params.FilterDescendantsInstances = excludedInstances
	params.IgnoreWater = false
	local origin = rootPart.Position + Vector3.new(0, GROUND_RAY_HEIGHT, 0)
	local result = Workspace:Raycast(origin, Vector3.new(0, -GROUND_RAY_DISTANCE, 0), params)
	if not result or not result.Instance or not result.Instance:IsA("BasePart") then
		return nil
	end
	local horizontalLook = Vector3.new(rootPart.CFrame.LookVector.X, 0, rootPart.CFrame.LookVector.Z)
	if horizontalLook.Magnitude < 0.001 then
		horizontalLook = Vector3.new(0, 0, -1)
	else
		horizontalLook = horizontalLook.Unit
	end
	local templatePivotHeight = self.TemplatePivotHeights[lostItemId]
	if not templatePivotHeight then
		return nil
	end
	local position = result.Position + Vector3.new(0, templatePivotHeight, 0)
	return CFrame.lookAt(position, position + horizontalLook), equippedTool
end

function PoopService:_getDeliveryTargets(player)
	local activeOwner = self.YardService:GetActiveOwner(player)
	if not activeOwner then
		return {}, "Yard is not ready."
	end
	if activeOwner ~= player then
		local ownerState = self.PlayerDataService:GetState(activeOwner)
		if not ownerState or ownerState.AllowGuestPoop == false then
			return {}, "This yard does not allow guest poop."
		end
		return { activeOwner }
	end

	local targets = {}
	for _, owner in Players:GetPlayers() do
		local ownerState = self.PlayerDataService:GetState(owner)
		if
			ownerState
			and (owner == player or ownerState.AllowGuestPoop ~= false)
			and #self.YardService:GetMembers(owner) > 0
		then
			table.insert(targets, owner)
		end
	end
	return targets
end

function PoopService:_cancelPendingMake(player, expectedRequest)
	local request = pendingMakeRequests[player]
	if not request or (expectedRequest and request ~= expectedRequest) then
		return false
	end
	pendingMakeRequests[player] = nil
	request.Cancelled = true
	for _, connection in request.Connections do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(request.Connections)
	return true
end

function PoopService:_notifyMakeFailure(player, message, isAutomatic)
	if isAutomatic == true then
		local now = os.clock()
		if
			now - (lastAutomaticFailureNotificationTimes[player] or -math.huge)
			< AUTOMATIC_FAILURE_NOTIFICATION_COOLDOWN
		then
			return
		end
		lastAutomaticFailureNotificationTimes[player] = now
	end
	self.PlayerDataService:Notify(player, message)
end

function PoopService:_playPendingMakeSound(player, request)
	if pendingMakeRequests[player] ~= request or request.Cancelled then
		return
	end
	if player.Parent ~= Players or self.YardService:GetActiveOwner(player) ~= request.ActiveOwner then
		return
	end

	local placementCFrame, equippedTool = self:_getPlacementCFrame(player, request.LostItemId)
	if
		not placementCFrame
		or equippedTool ~= request.Tool
		or player.Character ~= request.Character
	then
		return
	end
	local activeYard = getYard(request.ActiveOwner, false)
	if activeYard and getItemCount(activeYard) >= MAXIMUM_YARD_ITEMS then
		return
	end

	local possibleTargets = self:_getDeliveryTargets(player)
	local eventId = HttpService:GenerateGUID(false)
	local notifiedMembers = {}
	for _, owner in possibleTargets do
		local yard = getYard(owner, false)
		if not yard or getItemCount(yard) < MAXIMUM_YARD_ITEMS then
			for _, member in self.YardService:GetMembers(owner) do
				if not notifiedMembers[member] and self.PlayerDataService:GetState(member) then
					notifiedMembers[member] = true
					self.Remotes.PoopSoundTriggered:FireClient(member, eventId, placementCFrame.Position)
				end
			end
		end
	end
end

function PoopService:_applyPendingMakeHop(player, request)
	if pendingMakeRequests[player] ~= request or request.Cancelled then
		return
	end
	if player.Parent ~= Players or self.YardService:GetActiveOwner(player) ~= request.ActiveOwner then
		return
	end

	local _, equippedTool = self:_getPlacementCFrame(player, request.LostItemId)
	if equippedTool ~= request.Tool or player.Character ~= request.Character then
		return
	end

	local character = request.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		not humanoid
		or humanoid.Health <= 0
		or humanoid.FloorMaterial == Enum.Material.Air
		or not rootPart
		or not rootPart:IsA("BasePart")
		or rootPart.Anchored
	then
		return
	end

	local now = os.clock()
	if now - (lastHopTimes[player] or -math.huge) < MAKE_HOP_COOLDOWN then
		return
	end
	local assemblyMass = rootPart.AssemblyMass
	local impulseMagnitude = assemblyMass * MAKE_HOP_VELOCITY
	if
		assemblyMass <= 0
		or assemblyMass ~= assemblyMass
		or assemblyMass == math.huge
		or impulseMagnitude <= 0
		or impulseMagnitude ~= impulseMagnitude
		or impulseMagnitude == math.huge
	then
		return
	end

	lastHopTimes[player] = now
	rootPart:ApplyImpulse(Vector3.new(0, impulseMagnitude, 0))
end

function PoopService:_completePendingMake(player, request)
	if pendingMakeRequests[player] ~= request or request.Cancelled then
		return
	end
	self:_cancelPendingMake(player, request)
	if player.Parent ~= Players or self.YardService:GetActiveOwner(player) ~= request.ActiveOwner then
		return
	end

	local state = self.PlayerDataService:GetState(player)
	if not state or player.Character ~= request.Character then
		return
	end
	local character = request.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local equippedTool = character and character:FindFirstChildOfClass("Tool")
	if not humanoid or humanoid.Health <= 0 or equippedTool ~= request.Tool then
		return
	end
	local lostItemId = request.LostItemId
	local placementCFrame, placementTool = self:_getPlacementCFrame(player, lostItemId)
	if not placementCFrame or placementTool ~= request.Tool then
		self:_notifyMakeFailure(player, MAKE_FAILURE_MESSAGE, request.IsAutomatic)
		return
	end
	if (tonumber(state.Coins) or 0) < MAKE_COST then
		self:_notifyMakeFailure(player, MAKE_INSUFFICIENT_COINS_MESSAGE, request.IsAutomatic)
		return
	end

	local possibleTargets, targetError = self:_getDeliveryTargets(player)
	if #possibleTargets <= 0 then
		self:_notifyMakeFailure(
			player,
			targetError and withNoCharge(targetError) or MAKE_FAILURE_MESSAGE,
			request.IsAutomatic
		)
		return
	end
	local activeYard = getYard(request.ActiveOwner, false)
	if activeYard and getItemCount(activeYard) >= MAXIMUM_YARD_ITEMS then
		self:_notifyMakeFailure(player, MAKE_YARD_FULL_MESSAGE, request.IsAutomatic)
		return
	end
	local targets = {}
	for _, owner in possibleTargets do
		local yard = getYard(owner, false)
		if not yard or getItemCount(yard) < MAXIMUM_YARD_ITEMS then
			table.insert(targets, owner)
		end
	end
	if #targets <= 0 then
		if targetError then
			self:_notifyMakeFailure(player, withNoCharge(targetError), request.IsAutomatic)
		else
			self:_notifyMakeFailure(player, MAKE_YARD_FULL_MESSAGE, request.IsAutomatic)
		end
		return
	end

	local creatorPickupUnlockTime = Workspace:GetServerTimeNow() + CREATOR_PICKUP_DELAY
	local spawnId = string.format(
		"Poop_%d_%s",
		player.UserId,
		HttpService:GenerateGUID(false)
	)
	local item = {
		SpawnId = spawnId,
		LostItemId = lostItemId,
		CreatorUserId = player.UserId,
		CreatorName = player.DisplayName,
		CreatorPickupUnlockTime = creatorPickupUnlockTime,
		SourceYardOwnerUserId = request.ActiveOwner.UserId,
		SourceAreaId = type(state.CurrentAreaId) == "string" and state.CurrentAreaId or "Area_01",
		WorldPivotCFrame = placementCFrame,
		ProjectionYards = {},
	}
	local createdItems = {}
	local creationSucceeded, creationError = pcall(function()
		sharedItemsBySpawnId[spawnId] = item
		for _, owner in targets do
			local existingYard = getYard(owner, false)
			local yard = existingYard or getYard(owner, true)
			table.insert(createdItems, {
				Owner = owner,
				Yard = yard,
				CreatedYard = existingYard == nil,
			})
			yard.Items[spawnId] = item
			item.ProjectionYards[owner] = yard
		end
	end)
	if not creationSucceeded or #createdItems <= 0 then
		rollbackCreatedItems(item, createdItems)
		if not creationSucceeded then
			warn(string.format("Poop creation failed for player %d: %s", player.UserId, tostring(creationError)))
		end
		self:_notifyMakeFailure(player, MAKE_FAILURE_MESSAGE, request.IsAutomatic)
		return
	end

	local coinsBeforeSpend = tonumber(state.Coins) or 0
	local spendCallSucceeded, spendResult = pcall(function()
		return self.EconomyService:TrySpend(player, MAKE_COST)
	end)
	local stateAfterSpend = self.PlayerDataService:GetState(player)
	local coinsAfterSpend = tonumber(stateAfterSpend and stateAfterSpend.Coins)
	local chargeApplied = coinsAfterSpend ~= nil and coinsAfterSpend <= coinsBeforeSpend - MAKE_COST
	if not chargeApplied then
		rollbackCreatedItems(item, createdItems)
		if not spendCallSucceeded then
			warn(string.format("Poop charge failed for player %d: %s", player.UserId, tostring(spendResult)))
		end
		self:_notifyMakeFailure(
			player,
			spendCallSucceeded and spendResult == false and MAKE_INSUFFICIENT_COINS_MESSAGE
				or MAKE_FAILURE_MESSAGE,
			request.IsAutomatic
		)
		return
	end
	if not spendCallSucceeded then
		warn(string.format(
			"Poop charge completed with a follow-up error for player %d: %s",
			player.UserId,
			tostring(spendResult)
		))
		local repairSucceeded, repairError = pcall(function()
			self.PlayerDataService:MarkPersistentDirty(player)
			self.PlayerDataService:UpdateLeaderstats(player)
		end)
		if not repairSucceeded then
			warn(string.format("Poop charge repair failed for player %d: %s", player.UserId, tostring(repairError)))
		end
	elseif spendResult ~= true then
		warn(string.format("Poop charge returned an invalid result after deducting player %d", player.UserId))
	end

	lastAutomaticFailureNotificationTimes[player] = nil
	local tutorialPickupOnly = false
	for _, handler in self.PoopCreatedHandlers do
		local succeeded, handlerResult = pcall(handler, player, spawnId)
		if not succeeded then
			warn(string.format("Poop created handler failed for player %d: %s", player.UserId, tostring(handlerResult)))
		elseif handlerResult == true then
			tutorialPickupOnly = true
		end
	end
	if tutorialPickupOnly then
		item.TutorialPickupUserId = player.UserId
		item.CreatorPickupUnlockTime = 0
	end
	local pushSucceeded, pushError = pcall(function()
		self.PlayerDataService:PushSnapshot(player)
		for _, owner in targets do
			self:_pushYard(owner)
		end
		if tutorialPickupOnly then
			for _, otherPlayer in Players:GetPlayers() do
				if self.PlayerDataService:GetState(otherPlayer) then
					self.PlayerDataService:PushSnapshot(otherPlayer)
				end
			end
		end
	end)
	if not pushSucceeded then
		warn(string.format("Poop snapshot push failed for player %d: %s", player.UserId, tostring(pushError)))
		task.delay(0.1, function()
			local retrySucceeded, retryError = pcall(function()
				self.PlayerDataService:PushSnapshot(player)
				for _, owner in targets do
					self:_pushYard(owner)
				end
				if tutorialPickupOnly then
					for _, otherPlayer in Players:GetPlayers() do
						if self.PlayerDataService:GetState(otherPlayer) then
							self.PlayerDataService:PushSnapshot(otherPlayer)
						end
					end
				end
			end)
			if not retrySucceeded then
				warn(string.format("Poop snapshot retry failed for player %d: %s", player.UserId, tostring(retryError)))
			end
		end)
	end
	self.PlayerDataService:Notify(player, MAKE_SUCCESS_MESSAGE)
end

function PoopService:RequestMake(player, isAutomatic)
	local automaticRequest = isAutomatic == true
	if pendingMakeRequests[player] then
		return
	end
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return
	end
	local lostItemId = LostItemConfig.ChoosePoopItemId(self.Random)
	local placementCFrame, equippedTool = self:_getPlacementCFrame(player, lostItemId)
	if not placementCFrame or not equippedTool then
		local character = player.Character
		local activeTool = character and character:FindFirstChildOfClass("Tool")
		if activeTool and activeTool:GetAttribute("CleaningToolId") == TOOL_ID then
			self:_notifyMakeFailure(player, MAKE_FAILURE_MESSAGE, automaticRequest)
		end
		return
	end

	local now = os.clock()
	if now - (lastAcceptedMakeTimes[player] or -math.huge) < MAKE_COOLDOWN then
		self:_notifyMakeFailure(player, MAKE_COOLDOWN_MESSAGE, automaticRequest)
		return
	end
	if (tonumber(state.Coins) or 0) < MAKE_COST then
		self:_notifyMakeFailure(player, MAKE_INSUFFICIENT_COINS_MESSAGE, automaticRequest)
		return
	end

	local activeOwner = self.YardService:GetActiveOwner(player)
	if not activeOwner then
		self:_notifyMakeFailure(player, MAKE_FAILURE_MESSAGE, automaticRequest)
		return
	end
	local possibleTargets, targetError = self:_getDeliveryTargets(player)
	if #possibleTargets <= 0 then
		if targetError then
			self:_notifyMakeFailure(player, withNoCharge(targetError), automaticRequest)
		else
			self:_notifyMakeFailure(player, MAKE_FAILURE_MESSAGE, automaticRequest)
		end
		return
	end
	local activeYard = getYard(activeOwner, false)
	if activeYard and getItemCount(activeYard) >= MAXIMUM_YARD_ITEMS then
		self:_notifyMakeFailure(player, MAKE_YARD_FULL_MESSAGE, automaticRequest)
		return
	end
	local hasAvailableTarget = false
	for _, owner in possibleTargets do
		local yard = getYard(owner, false)
		if not yard or getItemCount(yard) < MAXIMUM_YARD_ITEMS then
			hasAvailableTarget = true
			break
		end
	end
	if not hasAvailableTarget then
		self:_notifyMakeFailure(player, MAKE_YARD_FULL_MESSAGE, automaticRequest)
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local request = {
		ActiveOwner = activeOwner,
		Cancelled = false,
		Character = character,
		Connections = {},
		IsAutomatic = automaticRequest,
		LostItemId = lostItemId,
		Tool = equippedTool,
	}
	pendingMakeRequests[player] = request
	lastAcceptedMakeTimes[player] = now
	table.insert(request.Connections, equippedTool.Unequipped:Connect(function()
		self:_cancelPendingMake(player, request)
	end))
	if humanoid then
		table.insert(request.Connections, humanoid.Died:Connect(function()
			self:_cancelPendingMake(player, request)
		end))
	end

	self.ToolActionService:PlaySingle(player, TOOL_ID)
	task.delay(MAKE_HOP_DELAY, function()
		self:_applyPendingMakeHop(player, request)
	end)
	task.delay(MAKE_SOUND_DELAY, function()
		self:_playPendingMakeSound(player, request)
	end)
	task.delay(MAKE_SPAWN_DELAY, function()
		self:_completePendingMake(player, request)
	end)
end

function PoopService:_notifyPoopPickedUp(player, spawnId, lostItemId)
	for _, handler in self.PoopPickedUpHandlers do
		local succeeded, handlerError = pcall(handler, player, spawnId, lostItemId)
		if not succeeded then
			warn(string.format("Poop picked-up handler failed for player %d: %s", player.UserId, tostring(handlerError)))
		end
	end
end

function PoopService:RequestPickup(player, spawnId)
	if type(spawnId) ~= "string" or #spawnId > 128 or pickupLocks[spawnId] then
		return
	end
	pickupLocks[spawnId] = true
	local lobbyItem = lobbyItemsBySpawnId[spawnId]
	if lobbyItem then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if
			not humanoid
			or humanoid.Health <= 0
			or not rootPart
			or not rootPart:IsA("BasePart")
			or (rootPart.Position - lobbyItem.WorldPivotCFrame.Position).Magnitude
				> (self.PromptDistances[lobbyItem.LostItemId] or 0) + PICKUP_DISTANCE_PADDING
		then
			pickupLocks[spawnId] = nil
			return
		end
		local addSucceeded, added = pcall(function()
			return self.LostItemService:AddSpecialCollectible(player, lobbyItem.LostItemId, {
				SourceAreaId = lobbyItem.SourceAreaId,
				SpawnId = spawnId,
			})
		end)
		if not addSucceeded or not added then
			if not addSucceeded then
				warn("Lobby poop inventory pickup failed: " .. tostring(added))
			end
			pickupLocks[spawnId] = nil
			return
		end
		lobbyItemsBySpawnId[spawnId] = nil
		self:_notifyPoopPickedUp(player, spawnId, lobbyItem.LostItemId)
		self:_pushAllPlayers()
		pickupLocks[spawnId] = nil
		return
	end
	local owner = self.YardService:GetActiveOwner(player)
	local yard = owner and getYard(owner, false) or nil
	local item = yard and yard.Items[spawnId] or nil
	local sharedItem = sharedItemsBySpawnId[spawnId]
	if sharedItem and sharedItem.TutorialPickupUserId == player.UserId then
		item = sharedItem
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		not item
		or sharedItem ~= item
		or (item.TutorialPickupUserId ~= nil and item.TutorialPickupUserId ~= player.UserId)
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
		or (
			item.CreatorUserId == player.UserId
			and Workspace:GetServerTimeNow() < (tonumber(item.CreatorPickupUnlockTime) or 0)
		)
		or (rootPart.Position - item.WorldPivotCFrame.Position).Magnitude
			> (self.PromptDistances[item.LostItemId] or 0) + PICKUP_DISTANCE_PADDING
	then
		pickupLocks[spawnId] = nil
		return
	end

	local removedProjections = {}
	for projectionOwner, projectionYard in item.ProjectionYards do
		table.insert(removedProjections, {
			Owner = projectionOwner,
			Yard = projectionYard,
		})
	end
	for _, projection in removedProjections do
		detachProjection(projection.Owner, projection.Yard, item)
	end
	local addSucceeded, added = pcall(function()
		return self.LostItemService:AddSpecialCollectible(player, item.LostItemId, {
			SourceYardOwnerUserId = item.SourceYardOwnerUserId or (owner and owner.UserId),
			SourceAreaId = item.SourceAreaId,
			SpawnId = spawnId,
			CreatorUserId = item.CreatorUserId,
		})
	end)
	if not addSucceeded or not added then
		if not addSucceeded then
			warn("Poop inventory pickup failed: " .. tostring(added))
		end
		for _, projection in removedProjections do
			local projectionOwner = projection.Owner
			local projectionYard = projection.Yard
			if
				yardsByOwner[projectionOwner] == projectionYard
				and projectionYard.Items[spawnId] == nil
				and getItemCount(projectionYard) < MAXIMUM_YARD_ITEMS
			then
				projectionYard.Items[spawnId] = item
				item.ProjectionYards[projectionOwner] = projectionYard
			end
		end
		for _, projection in removedProjections do
			self:_pushYard(projection.Owner)
		end
		discardUnprojectedItem(item)
		pickupLocks[spawnId] = nil
		return
	end
	sharedItemsBySpawnId[spawnId] = nil
	for _, projection in removedProjections do
		self:_pushYard(projection.Owner)
	end
	self:_notifyPoopPickedUp(player, spawnId, item.LostItemId)
	if item.TutorialPickupUserId ~= nil then
		for _, otherPlayer in Players:GetPlayers() do
			if otherPlayer ~= player and self.PlayerDataService:GetState(otherPlayer) then
				self.PlayerDataService:PushSnapshot(otherPlayer)
			end
		end
	end
	pickupLocks[spawnId] = nil
end

function PoopService:SetPermission(player, allowed)
	if type(allowed) ~= "boolean" then
		return false, "Invalid setting.", self.PlayerDataService:GetSnapshot(player)
	end
	local now = os.clock()
	if now - (permissionRequestTimes[player] or -math.huge) < 0.25 then
		return false, "Too fast.", self.PlayerDataService:GetSnapshot(player)
	end
	permissionRequestTimes[player] = now
	if not self.PlayerDataService:SetAllowGuestPoop(player, allowed, false) then
		return false, "Player data is not ready.", self.PlayerDataService:GetSnapshot(player)
	end

	if not allowed then
		local yard = getYard(player, false)
		if yard then
			local itemsToRemove = {}
			for _, item in yard.Items do
				if item.CreatorUserId ~= player.UserId then
					table.insert(itemsToRemove, item)
				end
			end
			for _, item in itemsToRemove do
				detachProjection(player, yard, item)
				discardUnprojectedItem(item)
			end
			self:_pushYard(player)
		end
	end
	self.PlayerDataService:PushSnapshot(player)
	return true, allowed and "Guest poop is now allowed." or "Guest poop is now blocked.", self.PlayerDataService:GetSnapshot(player)
end

function PoopService:ResetYard(owner)
	local playersToCancel = {}
	for player, request in pendingMakeRequests do
		if player == owner or request.ActiveOwner == owner then
			table.insert(playersToCancel, player)
		end
	end
	for _, player in playersToCancel do
		self:_cancelPendingMake(player)
	end
	local tutorialItems = {}
	for _, item in sharedItemsBySpawnId do
		if item.TutorialPickupUserId == owner.UserId then
			table.insert(tutorialItems, item)
		end
	end
	for _, item in tutorialItems do
		local affectedOwners = destroySharedItem(item)
		for _, affectedOwner in affectedOwners do
			self:_pushYard(affectedOwner)
		end
	end
	if self:_detachYard(owner) then
		self:_pushYard(owner)
	end
	if #tutorialItems > 0 then
		for _, player in Players:GetPlayers() do
			if self.PlayerDataService:GetState(player) then
				self.PlayerDataService:PushSnapshot(player)
			end
		end
	end
end

function PoopService:Init(playerDataService, economyService, lostItemService, yardService, toolActionService, remotes)
	self.PlayerDataService = playerDataService
	self.EconomyService = economyService
	self.LostItemService = lostItemService
	self.YardService = yardService
	self.ToolActionService = toolActionService
	self.Remotes = remotes
	self.PoopCreatedHandlers = {}
	self.PoopPickedUpHandlers = {}

	self.Random = Random.new()
	self.TemplatePivotHeights = {}
	self.PromptDistances = {}
	local templateFolder = ReplicatedStorage:WaitForChild("LostItem")
	for _, lostItemId in LostItemConfig.PoopItemIds do
		local template = templateFolder:WaitForChild(lostItemId)
		assert(template:IsA("Model"), "ReplicatedStorage.LostItem." .. lostItemId .. " must be a Model")
		local upgrade = template:WaitForChild("upgrade")
		local prompt = upgrade:WaitForChild("ProximityPrompt")
		assert(upgrade:IsA("BasePart"), lostItemId .. ".upgrade must be a BasePart")
		assert(prompt:IsA("ProximityPrompt"), lostItemId .. ".upgrade.ProximityPrompt is missing")
		local boundingCFrame, boundingSize = template:GetBoundingBox()
		self.TemplatePivotHeights[lostItemId] = math.max(
			0,
			template:GetPivot().Position.Y - (boundingCFrame.Position.Y - boundingSize.Y / 2)
		)
		self.PromptDistances[lostItemId] = prompt.MaxActivationDistance
	end

	playerDataService:SetPoopSnapshotProvider(function(player)
		return self:GetSnapshot(player)
	end)
	remotes.RequestMakeTrash.OnServerEvent:Connect(function(player, isAutomatic)
		if isAutomatic ~= nil and type(isAutomatic) ~= "boolean" then
			return
		end
		self:RequestMake(player, isAutomatic == true)
	end)
	remotes.RequestPoopPickup.OnServerEvent:Connect(function(player, spawnId)
		self:RequestPickup(player, spawnId)
	end)
	remotes.SetPoopPermission.OnServerInvoke = function(player, allowed)
		return self:SetPermission(player, allowed)
	end

	yardService:AddYardChangedHandler(function(player, _, previousOwner)
		self:_cancelPendingMake(player)
		self:_clearEmptyYard(previousOwner)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_cancelPendingMake(player)
		lastAcceptedMakeTimes[player] = nil
		lastAutomaticFailureNotificationTimes[player] = nil
		lastHopTimes[player] = nil
		permissionRequestTimes[player] = nil
		local tutorialItems = {}
		for _, item in sharedItemsBySpawnId do
			if item.TutorialPickupUserId == player.UserId then
				table.insert(tutorialItems, item)
			end
		end
		local tutorialItemRemoved = #tutorialItems > 0
		for _, item in tutorialItems do
			destroySharedItem(item)
		end
		self:_detachYard(player)
		task.defer(function()
			for owner in yardsByOwner do
				self:_clearEmptyYard(owner)
			end
			if tutorialItemRemoved then
				for _, otherPlayer in Players:GetPlayers() do
					if self.PlayerDataService:GetState(otherPlayer) then
						self.PlayerDataService:PushSnapshot(otherPlayer)
					end
				end
			end
		end)
	end)
end

function PoopService:AddPoopCreatedHandler(handler)
	assert(type(handler) == "function", "Poop created handler must be a function")
	table.insert(self.PoopCreatedHandlers, handler)
end

function PoopService:AddPoopPickedUpHandler(handler)
	assert(type(handler) == "function", "Poop picked-up handler must be a function")
	table.insert(self.PoopPickedUpHandlers, handler)
end

return PoopService

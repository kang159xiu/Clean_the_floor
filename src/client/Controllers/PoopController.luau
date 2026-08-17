local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LostItemConfig = require(ReplicatedStorage.Shared.Config.LostItemConfig)

local PoopController = {}

local TOOL_ID = "Tool05"
local CLEANING_TOOL_ATTRIBUTE = "CleaningToolId"
local RAINBOW_LOST_ITEM_ID = "LostItem099"
local RAINBOW_PART_NAME = "1"
local RAINBOW_SPEED = 0.15
local REVEAL_ANIMATION = LostItemConfig.RevealAnimation

local function findRainbowPart(container)
	if not container then
		return nil
	end
	local visualModel = if container.Name == "Model" and container:IsA("Model")
		then container
		else container:FindFirstChild("Model")
	local part = visualModel and visualModel:FindFirstChild(RAINBOW_PART_NAME)
	return if part and part:IsA("BasePart") then part else nil
end

local function preparePoopModel(model, previewOnly)
	local toDestroy = {}
	for _, descendant in model:GetDescendants() do
		if
			descendant:IsA("LuaSourceContainer")
			or descendant:IsA("Highlight")
			or (previewOnly and (
				descendant:IsA("ProximityPrompt")
				or descendant:IsA("BillboardGui")
			))
		then
			table.insert(toDestroy, descendant)
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
	for _, descendant in toDestroy do
		descendant:Destroy()
	end
end

local function setVisualHidden(entry, hidden)
	for part, originalModifier in entry.FinalLocalTransparencyModifiers do
		if part.Parent then
			part.LocalTransparencyModifier = if hidden then 1 else originalModifier
		end
	end
end

function PoopController:_getRainbowColor()
	local hue = (Workspace:GetServerTimeNow() * RAINBOW_SPEED) % 1
	return Color3.fromHSV(hue, 1, 1)
end

function PoopController:_registerRainbowPart(part)
	if not part or not part:IsA("BasePart") or self.RainbowParts[part] then
		return
	end
	self.RainbowParts[part] = {
		Color = part.Color,
		Material = part.Material,
	}
	part.Material = Enum.Material.Neon
	part.Color = self:_getRainbowColor()
end

function PoopController:_unregisterRainbowPart(part)
	local original = part and self.RainbowParts[part] or nil
	if not original then
		return
	end
	self.RainbowParts[part] = nil
	if part.Parent then
		part.Color = original.Color
		part.Material = original.Material
	end
end

function PoopController:_updateRainbowParts()
	local color = self:_getRainbowColor()
	for part in self.RainbowParts do
		if part.Parent then
			part.Material = Enum.Material.Neon
			part.Color = color
		else
			self.RainbowParts[part] = nil
		end
	end
end

function PoopController:_playPoopSound(eventId, worldPosition)
	if
		type(eventId) ~= "string"
		or eventId == ""
		or typeof(worldPosition) ~= "Vector3"
		or self.PlayedSoundEventIds[eventId]
	then
		return
	end
	self.PlayedSoundEventIds[eventId] = true

	local emitter = Instance.new("Part")
	emitter.Name = "PoopSoundEmitter_" .. eventId
	emitter.Size = Vector3.new(0.1, 0.1, 0.1)
	emitter.CFrame = CFrame.new(worldPosition)
	emitter.Transparency = 1
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanTouch = false
	emitter.CanQuery = false
	emitter.CastShadow = false
	emitter.Parent = self.SoundEffectsContainer

	local sound = self.SoundTemplate:Clone()
	sound.Parent = emitter
	sound.Ended:Once(function()
		emitter:Destroy()
	end)
	sound:Play()
	task.delay(30, function()
		if emitter.Parent then
			emitter:Destroy()
		end
	end)
end

function PoopController:_isRevealActive(entry, generation)
	return entry.Destroyed ~= true
		and entry.RevealGeneration == generation
		and self.Entries[entry.SpawnId] == entry
end

function PoopController:_clearScaleDriver(entry, tween, connection, scaleValue)
	if entry.RevealTween == tween then
		entry.RevealTween = nil
	end
	if entry.RevealScaleConnection == connection then
		connection:Disconnect()
		entry.RevealScaleConnection = nil
	end
	if entry.RevealScaleValue == scaleValue then
		scaleValue:Destroy()
		entry.RevealScaleValue = nil
	end
end

function PoopController:_tweenVisualScale(
	entry,
	generation,
	visualModel,
	originalScale,
	startScale,
	endScale,
	duration,
	easingStyle,
	easingDirection
)
	if not self:_isRevealActive(entry, generation) or not visualModel.Parent then
		return false
	end
	visualModel:ScaleTo(math.max(0.001, originalScale * startScale))
	local scaleValue = Instance.new("NumberValue")
	scaleValue.Value = startScale
	local connection = scaleValue.Changed:Connect(function(value)
		if self:_isRevealActive(entry, generation) and visualModel.Parent then
			visualModel:ScaleTo(math.max(0.001, originalScale * value))
		end
	end)
	local tween = TweenService:Create(
		scaleValue,
		TweenInfo.new(duration, easingStyle, easingDirection),
		{ Value = endScale }
	)
	entry.RevealScaleValue = scaleValue
	entry.RevealScaleConnection = connection
	entry.RevealTween = tween
	tween:Play()
	local playbackState = tween.Completed:Wait()
	self:_clearScaleDriver(entry, tween, connection, scaleValue)
	return playbackState == Enum.PlaybackState.Completed
		and self:_isRevealActive(entry, generation)
		and visualModel.Parent ~= nil
end

function PoopController:_chooseDecoyIds(finalLostItemId)
	local candidates = {}
	for _, lostItemId in LostItemConfig.PoopItemIds do
		if lostItemId ~= finalLostItemId then
			table.insert(candidates, lostItemId)
		end
	end
	for index = 1, #candidates do
		local selectedIndex = self.Random:NextInteger(index, #candidates)
		candidates[index], candidates[selectedIndex] = candidates[selectedIndex], candidates[index]
	end
	return candidates
end

function PoopController:_createDecoy(entry, lostItemId)
	local template = self.Templates[lostItemId]
	if not template then
		return nil, nil, nil
	end
	local clone = template:Clone()
	clone.Name = string.format("PoopReveal_%s_%s", lostItemId, entry.SpawnId)
	local upgrade = clone:FindFirstChild("upgrade")
	local visualModel = clone:FindFirstChild("Model")
	if
		not upgrade
		or not upgrade:IsA("BasePart")
		or not visualModel
		or not visualModel:IsA("Model")
	then
		clone:Destroy()
		return nil, nil, nil
	end
	local targetPivot = entry.Upgrade.CFrame * upgrade.CFrame:Inverse() * clone:GetPivot()
	preparePoopModel(clone, true)
	upgrade.Transparency = 1
	upgrade.CastShadow = false
	clone:PivotTo(targetPivot)
	clone.Parent = self.Container
	if lostItemId == RAINBOW_LOST_ITEM_ID then
		self:_registerRainbowPart(findRainbowPart(visualModel))
	end
	return clone, visualModel, visualModel:GetScale()
end

function PoopController:_destroyDecoy(entry, decoyModel)
	if entry.DecoyModel == decoyModel then
		entry.DecoyModel = nil
	end
	if decoyModel then
		self:_unregisterRainbowPart(findRainbowPart(decoyModel))
		decoyModel:Destroy()
	end
end

function PoopController:_updatePrompt(entry)
	local creatorLocked = entry.CreatorUserId == self.Player.UserId
		and Workspace:GetServerTimeNow() < entry.CreatorPickupUnlockTime
	entry.Prompt.Enabled = entry.Destroyed ~= true
		and entry.Revealing ~= true
		and entry.PickupPending ~= true
		and entry.PickupAllowed ~= false
		and not creatorLocked
end

function PoopController:_finishReveal(entry, generation)
	if not self:_isRevealActive(entry, generation) then
		return
	end
	if entry.FinalVisualModel and entry.FinalVisualModel.Parent then
		entry.FinalVisualModel:ScaleTo(entry.FinalOriginalScale)
	end
	setVisualHidden(entry, false)
	entry.Revealing = false
	entry.Billboard.Enabled = entry.HideCreatorBillboard ~= true
	self:_updatePrompt(entry)
end

function PoopController:_playSpawnAnimation(entry)
	entry.RevealGeneration += 1
	local generation = entry.RevealGeneration
	local decoyIds = self:_chooseDecoyIds(entry.LostItemId)
	task.spawn(function()
		for index, lostItemId in decoyIds do
			if not self:_isRevealActive(entry, generation) then
				return
			end
			local progress = if #decoyIds > 1 then (index - 1) / (#decoyIds - 1) else 1
			local slowdown = progress ^ REVEAL_ANIMATION.SlowdownExponent
			local growDuration = REVEAL_ANIMATION.FirstDecoyGrowDuration
				+ (REVEAL_ANIMATION.LastDecoyGrowDuration - REVEAL_ANIMATION.FirstDecoyGrowDuration)
					* slowdown
			local shrinkDuration = REVEAL_ANIMATION.FirstDecoyShrinkDuration
				+ (REVEAL_ANIMATION.LastDecoyShrinkDuration - REVEAL_ANIMATION.FirstDecoyShrinkDuration)
					* slowdown
			local decoyModel, visualModel, originalScale = self:_createDecoy(entry, lostItemId)
			if decoyModel and visualModel and originalScale then
				entry.DecoyModel = decoyModel
				local grew = self:_tweenVisualScale(
					entry,
					generation,
					visualModel,
					originalScale,
					REVEAL_ANIMATION.StartScale,
					1,
					growDuration,
					Enum.EasingStyle.Back,
					Enum.EasingDirection.Out
				)
				local shrank = grew and self:_tweenVisualScale(
					entry,
					generation,
					visualModel,
					originalScale,
					1,
					REVEAL_ANIMATION.StartScale,
					shrinkDuration,
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.In
				)
				self:_destroyDecoy(entry, decoyModel)
				if not shrank then
					return
				end
			end
		end

		if not self:_isRevealActive(entry, generation) then
			return
		end
		local finalVisualModel = entry.FinalVisualModel
		if finalVisualModel and finalVisualModel.Parent then
			finalVisualModel:ScaleTo(
				math.max(0.001, entry.FinalOriginalScale * REVEAL_ANIMATION.StartScale)
			)
			setVisualHidden(entry, false)
			local revealed = self:_tweenVisualScale(
				entry,
				generation,
				finalVisualModel,
				entry.FinalOriginalScale,
				REVEAL_ANIMATION.StartScale,
				1,
				REVEAL_ANIMATION.FinalGrowDuration,
				Enum.EasingStyle.Back,
				Enum.EasingDirection.Out
			)
			if not revealed then
				return
			end
		end
		self:_finishReveal(entry, generation)
	end)
end

function PoopController:_destroyEntry(spawnId)
	local entry = self.Entries[spawnId]
	if not entry then
		return
	end
	entry.Destroyed = true
	entry.RevealGeneration += 1
	if entry.RevealTween then
		entry.RevealTween:Cancel()
		entry.RevealTween = nil
	end
	if entry.RevealScaleConnection then
		entry.RevealScaleConnection:Disconnect()
		entry.RevealScaleConnection = nil
	end
	if entry.RevealScaleValue then
		entry.RevealScaleValue:Destroy()
		entry.RevealScaleValue = nil
	end
	if entry.DecoyModel then
		self:_unregisterRainbowPart(findRainbowPart(entry.DecoyModel))
		entry.DecoyModel:Destroy()
		entry.DecoyModel = nil
	end
	if entry.PromptConnection then
		entry.PromptConnection:Disconnect()
	end
	if entry.Model then
		self:_unregisterRainbowPart(entry.RainbowPart)
		entry.Model:Destroy()
	end
	self.Entries[spawnId] = nil
end

function PoopController:_createEntry(itemData)
	local template = self.Templates[itemData.LostItemId]
	if not template then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "LocalPoop_" .. itemData.SpawnId
	clone:SetAttribute("LostItemId", itemData.LostItemId)
	clone:SetAttribute("SpawnId", itemData.SpawnId)
	clone:SetAttribute("CreatorUserId", itemData.CreatorUserId)
	preparePoopModel(clone, false)

	local upgrade = clone:FindFirstChild("upgrade")
	local prompt = upgrade and upgrade:FindFirstChild("ProximityPrompt")
	assert(upgrade and upgrade:IsA("BasePart"), itemData.LostItemId .. ".upgrade must be a BasePart")
	assert(
		prompt and prompt:IsA("ProximityPrompt"),
		itemData.LostItemId .. ".upgrade.ProximityPrompt is missing"
	)
	upgrade.Transparency = 1
	upgrade.CastShadow = false
	local lostItemConfig = LostItemConfig.Types[itemData.LostItemId]
	local displayName = lostItemConfig and lostItemConfig.DisplayName or "Poop"
	prompt.ActionText = "Pick Up"
	prompt.ObjectText = displayName
	local creatorPickupUnlockTime = tonumber(itemData.CreatorPickupUnlockTime) or 0
	prompt.Enabled = false

	local billboard = clone:FindFirstChild("BillboardGui")
	local cost = billboard and billboard:FindFirstChild("cost")
	local avatar = cost and cost:FindFirstChild("ImageLabel")
	local title = cost and cost:FindFirstChild("TextLabel")
	assert(
		billboard and billboard:IsA("BillboardGui"),
		itemData.LostItemId .. ".BillboardGui is missing"
	)
	assert(
		avatar and avatar:IsA("ImageLabel"),
		itemData.LostItemId .. ".BillboardGui.cost.ImageLabel is missing"
	)
	assert(
		title and title:IsA("TextLabel"),
		itemData.LostItemId .. ".BillboardGui.cost.TextLabel is missing"
	)
	billboard.Enabled = false
	local creatorName = type(itemData.CreatorName) == "string" and itemData.CreatorName or "Player"
	title.Text = displayName .. " made by " .. creatorName

	clone:PivotTo(itemData.WorldPivotCFrame)
	clone.Parent = self.Container
	local finalVisualModel = clone:FindFirstChild("Model")
	assert(finalVisualModel and finalVisualModel:IsA("Model"), itemData.LostItemId .. ".Model is missing")
	local finalLocalTransparencyModifiers = {}
	for _, descendant in finalVisualModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			finalLocalTransparencyModifiers[descendant] = descendant.LocalTransparencyModifier
		end
	end
	local entry = {
		Billboard = billboard,
		CreatorPickupUnlockTime = creatorPickupUnlockTime,
		CreatorUserId = itemData.CreatorUserId,
		DecoyModel = nil,
		Destroyed = false,
		FinalLocalTransparencyModifiers = finalLocalTransparencyModifiers,
		FinalOriginalScale = finalVisualModel:GetScale(),
		FinalVisualModel = finalVisualModel,
		HideCreatorBillboard = itemData.HideCreatorBillboard == true,
		LostItemId = itemData.LostItemId,
		Model = clone,
		Prompt = prompt,
		PickupPending = false,
		PickupAllowed = itemData.PickupAllowed ~= false,
		RainbowPart = if itemData.LostItemId == RAINBOW_LOST_ITEM_ID
			then findRainbowPart(finalVisualModel)
			else nil,
		TutorialPickupUserId = itemData.TutorialPickupUserId,
		RevealGeneration = 0,
		Revealing = true,
		SpawnId = itemData.SpawnId,
		Upgrade = upgrade,
	}
	self:_registerRainbowPart(entry.RainbowPart)
	setVisualHidden(entry, true)
	entry.PromptConnection = prompt.Triggered:Connect(function()
		if entry.PickupPending then
			return
		end
		entry.PickupPending = true
		self:_updatePrompt(entry)
		self.Remotes.RequestPoopPickup:FireServer(itemData.SpawnId)
		task.delay(0.6, function()
			if self.Entries[itemData.SpawnId] == entry and entry.Model.Parent then
				entry.PickupPending = false
				self:_updatePrompt(entry)
			end
		end)
	end)
	self.Entries[itemData.SpawnId] = entry
	if
		entry.CreatorUserId == self.Player.UserId
		and Workspace:GetServerTimeNow() < creatorPickupUnlockTime
	then
		task.delay(math.max(0, creatorPickupUnlockTime - Workspace:GetServerTimeNow()), function()
			if self.Entries[itemData.SpawnId] == entry and entry.Model.Parent then
				self:_updatePrompt(entry)
			end
		end)
	end
	task.spawn(function()
		local userId = math.floor(tonumber(itemData.CreatorUserId) or 0)
		if userId <= 0 then
			return
		end
		local success, image = pcall(function()
			return Players:GetUserThumbnailAsync(
				userId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size180x180
			)
		end)
		if success and self.Entries[itemData.SpawnId] == entry and avatar.Parent then
			avatar.Image = image
		end
	end)
	self:_playSpawnAnimation(entry)
	return entry
end

function PoopController:_applySnapshot(snapshot)
	local seen = {}
	local visibleItems = {}
	for _, itemData in type(snapshot.ActiveYardPoops) == "table" and snapshot.ActiveYardPoops or {} do
		table.insert(visibleItems, itemData)
	end
	for _, itemData in type(snapshot.ActiveLobbyPoops) == "table" and snapshot.ActiveLobbyPoops or {} do
		table.insert(visibleItems, itemData)
	end
	for _, itemData in visibleItems do
		if
			type(itemData) == "table"
			and type(itemData.SpawnId) == "string"
			and LostItemConfig.IsPoopItemId(itemData.LostItemId)
			and typeof(itemData.WorldPivotCFrame) == "CFrame"
		then
			seen[itemData.SpawnId] = true
			local entry = self.Entries[itemData.SpawnId]
			if entry and entry.LostItemId ~= itemData.LostItemId then
				self:_destroyEntry(itemData.SpawnId)
				entry = nil
			end
			entry = entry or self:_createEntry(itemData)
			if entry and entry.Model and entry.Model.Parent then
				entry.PickupAllowed = itemData.PickupAllowed ~= false
				entry.HideCreatorBillboard = itemData.HideCreatorBillboard == true
				entry.TutorialPickupUserId = itemData.TutorialPickupUserId
				entry.CreatorPickupUnlockTime = tonumber(itemData.CreatorPickupUnlockTime) or 0
				entry.Billboard.Enabled = entry.Revealing ~= true
					and entry.HideCreatorBillboard ~= true
				entry.Model:PivotTo(itemData.WorldPivotCFrame)
				self:_updatePrompt(entry)
			end
		end
	end
	local stale = {}
	for spawnId in self.Entries do
		if not seen[spawnId] then
			table.insert(stale, spawnId)
		end
	end
	for _, spawnId in stale do
		self:_destroyEntry(spawnId)
	end
end

function PoopController:GetGuidanceTarget(spawnId)
	local entry = type(spawnId) == "string" and self.Entries[spawnId] or nil
	if not entry or entry.Destroyed or not entry.Model or not entry.Model.Parent then
		return nil
	end
	return entry.Upgrade and entry.Upgrade.Parent and entry.Upgrade or nil
end

function PoopController:_refreshHeldRainbowTool(tool, tracker)
	if self.HeldRainbowTools[tool] ~= tracker then
		return
	end
	local shouldAnimate = tool.Parent == tracker.Character
		and tool:GetAttribute("LostItemCarry") == true
		and tool:GetAttribute("LostItemId") == RAINBOW_LOST_ITEM_ID
	local nextPart = if shouldAnimate then findRainbowPart(tool) else nil
	if tracker.Part ~= nextPart then
		self:_unregisterRainbowPart(tracker.Part)
		tracker.Part = nextPart
		self:_registerRainbowPart(nextPart)
	end
end

function PoopController:_untrackHeldRainbowTool(tool)
	local tracker = self.HeldRainbowTools[tool]
	if not tracker then
		return
	end
	self.HeldRainbowTools[tool] = nil
	self:_unregisterRainbowPart(tracker.Part)
	for _, connection in tracker.Connections do
		if connection.Connected then
			connection:Disconnect()
		end
	end
end

function PoopController:_trackHeldRainbowTool(tool, character)
	if not tool:IsA("Tool") or self.HeldRainbowTools[tool] then
		return
	end
	local tracker = {
		Character = character,
		Connections = {},
		Part = nil,
	}
	self.HeldRainbowTools[tool] = tracker
	local function refresh()
		self:_refreshHeldRainbowTool(tool, tracker)
	end
	table.insert(tracker.Connections, tool.DescendantAdded:Connect(refresh))
	table.insert(tracker.Connections, tool:GetAttributeChangedSignal("LostItemCarry"):Connect(refresh))
	table.insert(tracker.Connections, tool:GetAttributeChangedSignal("LostItemId"):Connect(refresh))
	table.insert(tracker.Connections, tool.Destroying:Connect(function()
		self:_untrackHeldRainbowTool(tool)
	end))
	refresh()
end

function PoopController:_unbindRainbowCharacter(player)
	local tracker = self.RainbowCharacterTrackers[player]
	if not tracker then
		return
	end
	self.RainbowCharacterTrackers[player] = nil
	for _, connection in tracker.Connections do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	for tool in tracker.Tools do
		self:_untrackHeldRainbowTool(tool)
	end
end

function PoopController:_bindRainbowCharacter(player, character)
	self:_unbindRainbowCharacter(player)
	local tracker = {
		Character = character,
		Connections = {},
		Tools = {},
	}
	self.RainbowCharacterTrackers[player] = tracker
	local function trackChild(child)
		if child:IsA("Tool") then
			tracker.Tools[child] = true
			self:_trackHeldRainbowTool(child, character)
		end
	end
	local function untrackChild(child)
		if tracker.Tools[child] then
			tracker.Tools[child] = nil
			self:_untrackHeldRainbowTool(child)
		end
	end
	for _, child in character:GetChildren() do
		trackChild(child)
	end
	table.insert(tracker.Connections, character.ChildAdded:Connect(trackChild))
	table.insert(tracker.Connections, character.ChildRemoved:Connect(untrackChild))
end

function PoopController:_trackRainbowPlayer(player)
	if self.RainbowPlayerConnections[player] then
		return
	end
	local connections = {}
	self.RainbowPlayerConnections[player] = connections
	table.insert(connections, player.CharacterAdded:Connect(function(character)
		self:_bindRainbowCharacter(player, character)
	end))
	table.insert(connections, player.CharacterRemoving:Connect(function(character)
		local tracker = self.RainbowCharacterTrackers[player]
		if tracker and tracker.Character == character then
			self:_unbindRainbowCharacter(player)
		end
	end))
	if player.Character then
		self:_bindRainbowCharacter(player, player.Character)
	end
end

function PoopController:_untrackRainbowPlayer(player)
	self:_unbindRainbowCharacter(player)
	local connections = self.RainbowPlayerConnections[player]
	if connections then
		self.RainbowPlayerConnections[player] = nil
		for _, connection in connections do
			if connection.Connected then
				connection:Disconnect()
			end
		end
	end
end

function PoopController:_bindTool(tool)
	if
		self.ToolConnections[tool]
		or not tool:IsA("Tool")
		or tool:GetAttribute(CLEANING_TOOL_ATTRIBUTE) ~= TOOL_ID
	then
		return
	end
	local activated = tool.Activated:Connect(function()
		self.Remotes.RequestMakeTrash:FireServer(false)
	end)
	local destroying
	destroying = tool.Destroying:Connect(function()
		activated:Disconnect()
		destroying:Disconnect()
		self.ToolConnections[tool] = nil
	end)
	self.ToolConnections[tool] = true
end

function PoopController:RequestMakeIfEquipped(isAutomatic)
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local tool = character and character:FindFirstChildOfClass("Tool")
	if
		not humanoid
		or humanoid.Health <= 0
		or not tool
		or tool:GetAttribute(CLEANING_TOOL_ATTRIBUTE) ~= TOOL_ID
	then
		return false
	end
	self.Remotes.RequestMakeTrash:FireServer(isAutomatic == true)
	return true
end

function PoopController:_bindContainer(container)
	if not container then
		return
	end
	for _, child in container:GetChildren() do
		self:_bindTool(child)
	end
	container.ChildAdded:Connect(function(child)
		self:_bindTool(child)
	end)
end

function PoopController:Init(remotes)
	self.Remotes = remotes
	self.Player = Players.LocalPlayer
	self.Entries = {}
	self.HeldRainbowTools = {}
	self.RainbowCharacterTrackers = {}
	self.RainbowParts = {}
	self.RainbowPlayerConnections = {}
	self.ToolConnections = {}
	self.PlayedSoundEventIds = {}
	self.SoundTemplate = SoundService:WaitForChild("dabian")
	assert(self.SoundTemplate:IsA("Sound"), "SoundService.dabian must be a Sound")
	self.Random = Random.new()
	self.Templates = {}
	local templateFolder = ReplicatedStorage:WaitForChild("LostItem")
	assert(templateFolder:IsA("Folder"), "ReplicatedStorage.LostItem must be a Folder")
	for _, lostItemId in LostItemConfig.PoopItemIds do
		local template = templateFolder:WaitForChild(lostItemId)
		assert(template:IsA("Model"), "ReplicatedStorage.LostItem." .. lostItemId .. " must be a Model")
		local upgrade = template:FindFirstChild("upgrade")
		local prompt = upgrade and upgrade:FindFirstChild("ProximityPrompt")
		local visualModel = template:FindFirstChild("Model")
		local billboard = template:FindFirstChild("BillboardGui")
		local cost = billboard and billboard:FindFirstChild("cost")
		assert(upgrade and upgrade:IsA("BasePart"), lostItemId .. ".upgrade must be a BasePart")
		assert(
			prompt and prompt:IsA("ProximityPrompt"),
			lostItemId .. ".upgrade.ProximityPrompt is missing"
		)
		assert(visualModel and visualModel:IsA("Model"), lostItemId .. ".Model is missing")
		assert(billboard and billboard:IsA("BillboardGui"), lostItemId .. ".BillboardGui is missing")
		assert(
			cost and cost:FindFirstChild("ImageLabel") and cost.ImageLabel:IsA("ImageLabel"),
			lostItemId .. ".BillboardGui.cost.ImageLabel is missing"
		)
		assert(
			cost and cost:FindFirstChild("TextLabel") and cost.TextLabel:IsA("TextLabel"),
			lostItemId .. ".BillboardGui.cost.TextLabel is missing"
		)
		self.Templates[lostItemId] = template
	end

	local existing = Workspace:FindFirstChild("LocalPoops")
	if existing then
		existing:Destroy()
	end
	self.Container = Instance.new("Folder")
	self.Container.Name = "LocalPoops"
	self.Container.Parent = Workspace
	local existingSoundEffects = Workspace:FindFirstChild("LocalPoopSoundEffects")
	if existingSoundEffects then
		existingSoundEffects:Destroy()
	end
	self.SoundEffectsContainer = Instance.new("Folder")
	self.SoundEffectsContainer.Name = "LocalPoopSoundEffects"
	self.SoundEffectsContainer.Parent = Workspace

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:_applySnapshot(snapshot)
	end)
	remotes.PoopSoundTriggered.OnClientEvent:Connect(function(eventId, worldPosition)
		self:_playPoopSound(eventId, worldPosition)
	end)
	RunService.Heartbeat:Connect(function()
		self:_updateRainbowParts()
	end)
	Players.PlayerAdded:Connect(function(player)
		self:_trackRainbowPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_untrackRainbowPlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_trackRainbowPlayer(player)
	end
	self:_bindContainer(self.Player:FindFirstChildOfClass("Backpack"))
	self:_bindContainer(self.Player.Character)
	self.Player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			self:_bindContainer(child)
		end
	end)
	self.Player.CharacterAdded:Connect(function(character)
		self:_bindContainer(character)
	end)
end

return PoopController

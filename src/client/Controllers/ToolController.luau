local ContextActionService = game:GetService("ContextActionService")
local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LostItemConfig = require(ReplicatedStorage.Shared.Config.LostItemConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local ToolController = {}
local CLEANING_TOOL_ATTRIBUTE = "CleaningToolId"
local HOTBAR_ORDER_ATTRIBUTE = "HotbarOrder"
local BLOWER_TOOL_ID = "Tool03"
local LOST_ITEM_PLACEHOLDER_IMAGE = "rbxassetid://94046911309238"
local EQUIPPED_STROKE_COLOR = Color3.fromRGB(255, 255, 255)
local UNEQUIPPED_STROKE_COLOR = Color3.fromRGB(128, 128, 128)
local POOP_TOOL_HOTBAR_KEY = "Cleaning_Tool05"
local POOP_GUIDANCE_PULSE_SCALE = 1.12
local POOP_GUIDANCE_PULSE_DURATION = 0.35
local HOTBAR_NUMBER_KEY_TO_INDEX = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
}

function ToolController:Init(remotes, hudController)
	self.Remotes = remotes
	self.HUDController = hudController
	assert(type(hudController) == "table", "ToolController requires HUDController")
	self.Player = Players.LocalPlayer
	self.PlayerGui = self.Player:WaitForChild("PlayerGui")
	self.EquippedToolId = ToolConfig.DefaultToolId
	self.LastEquippedToolId = ToolConfig.DefaultToolId
	self.MousePickupHeld = false
	self.ActivePickupTouches = {}
	self.PrimaryAimTouch = nil
	self.AimTouchSequence = 0
	self.LastTouchAimScreenPosition = nil
	self.LastMouseAimScreenPosition = nil
	self.PickupInputActive = false
	self.AutomaticPickupActive = false
	self.ServerPickupActive = false
	self.PickupStateRefreshScheduled = false
	self.PickupStateRefreshForced = false
	self.PickupInputChanged = Instance.new("BindableEvent")
	self.BagFull = false
	self.BlowerSound = nil
	self.HotbarButtons = {}
	self.HotbarEntries = {}
	self.InventoryConnections = {}
	self.HotbarRefreshScheduled = false
	self.HotbarSuppressed = false
	self.PoopGuidanceActive = false
	self.PoopGuidancePulseTween = nil
	self.PoopGuidancePulseButton = nil
	self.PoopGuidancePulseScale = nil
	self.PoopGuidancePulseScaleCreated = false
	self.BlowerSoundTemplate = SoundService:WaitForChild("leafBlower")
	assert(self.BlowerSoundTemplate:IsA("Sound"), "SoundService.leafBlower must be a Sound")
	self:_initializeBlowerSound()
	self:_disableDefaultBackpack()

	local toolFrame = self.PlayerGui:WaitForChild("GameHUD"):WaitForChild("HUDRoot"):WaitForChild("ToolFrame")
	self.ToolFrame = toolFrame
	self.ToolButtonTemplate = toolFrame:WaitForChild("ImageButton")
	assert(self.ToolButtonTemplate:IsA("ImageButton"), "ToolFrame.ImageButton must be an ImageButton")
	assert(
		self.ToolButtonTemplate:FindFirstChild("ImageLabel")
			and self.ToolButtonTemplate.ImageLabel:IsA("ImageLabel"),
		"ToolFrame.ImageButton.ImageLabel must be an ImageLabel"
	)
	assert(
		self.ToolButtonTemplate:FindFirstChild("ToolName")
			and self.ToolButtonTemplate.ToolName:IsA("TextLabel"),
		"ToolFrame.ImageButton.ToolName must be a TextLabel"
	)
	assert(
		self.ToolButtonTemplate:FindFirstChild("UIStroke")
			and self.ToolButtonTemplate.UIStroke:IsA("UIStroke"),
		"ToolFrame.ImageButton.UIStroke must be a UIStroke"
	)
	assert(
		self.ToolButtonTemplate:FindFirstChild("number")
			and self.ToolButtonTemplate.number:IsA("TextLabel"),
		"ToolFrame.ImageButton.number must be a TextLabel"
	)
	assert(
		self.ToolButtonTemplate:FindFirstChild("key")
			and self.ToolButtonTemplate.key:IsA("TextLabel"),
		"ToolFrame.ImageButton.key must be a TextLabel"
	)
	self.CollectibleInventoryCounts = {}
	self.ToolButtonTemplate.Visible = false

	remotes.StateSnapshotStore:Connect(function(snapshot)
		local previousToolId = self.EquippedToolId
		local previousBagFull = self.BagFull
		self.EquippedToolId = snapshot.EquippedToolId
		if ToolConfig.IsLeafCleaningTool(self.EquippedToolId) then
			self.LastEquippedToolId = self.EquippedToolId
		end
		if previousToolId ~= self.EquippedToolId then
			self:_cancelPickupInput()
			self:_schedulePickupStateRefresh(true)
		end
		self.CollectibleInventoryCounts = type(snapshot.CollectibleInventoryCounts) == "table"
			and snapshot.CollectibleInventoryCounts
			or {}
		self.BagFull = snapshot.BagFull == true
		if previousBagFull ~= self.BagFull then
			self:_schedulePickupStateRefresh(true)
		end
		self:_refreshBlowerSound()
		self:_scheduleHotbarRefresh()
	end)
	self.Player.CharacterAdded:Connect(function()
		self:_cancelPickupInput()
		task.defer(function()
			self:_bindInventoryContainers()
			self:_schedulePickupStateRefresh(true)
		end)
	end)
	self.Player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			task.defer(function()
				self:_bindInventoryContainers()
			end)
		end
	end)
	UserInputService:GetPropertyChangedSignal("KeyboardEnabled"):Connect(function()
		self:_scheduleHotbarRefresh()
	end)

	UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
		local hotbarIndex = HOTBAR_NUMBER_KEY_TO_INDEX[input.KeyCode]
		if hotbarIndex then
			if
				not self.HotbarSuppressed
				and not gameProcessedEvent
				and not UserInputService:GetFocusedTextBox()
			then
				self:_activateHotbarIndex(hotbarIndex)
			end
			return
		end

		if self.HotbarSuppressed or gameProcessedEvent or self:_isInputOverActiveGui(input) then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self.MousePickupHeld = true
			self:_refreshPickupInput()
		elseif input.UserInputType == Enum.UserInputType.Touch then
			self.AimTouchSequence += 1
			self.ActivePickupTouches[input] = self.AimTouchSequence
			self.PrimaryAimTouch = input
			self.LastTouchAimScreenPosition = Vector2.new(input.Position.X, input.Position.Y)
			self:_refreshPickupInput()
		end
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and self.ActivePickupTouches[input] then
			if input == self.PrimaryAimTouch then
				self.LastTouchAimScreenPosition = Vector2.new(input.Position.X, input.Position.Y)
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self.MousePickupHeld = false
			self:_refreshPickupInput()
		elseif input.UserInputType == Enum.UserInputType.Touch and self.ActivePickupTouches[input] then
			self.LastTouchAimScreenPosition = Vector2.new(input.Position.X, input.Position.Y)
			self.ActivePickupTouches[input] = nil
			if input == self.PrimaryAimTouch then
				self.PrimaryAimTouch = nil
				local latestSequence = -math.huge
				for activeTouch, sequence in self.ActivePickupTouches do
					if sequence > latestSequence then
						latestSequence = sequence
						self.PrimaryAimTouch = activeTouch
					end
				end
			end
			self:_refreshPickupInput()
		end
	end)

	UserInputService.WindowFocusReleased:Connect(function()
		self:_cancelPickupInput()
	end)

	ContextActionService:BindAction("ToggleCleaningTool", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			self:ToggleEquipped()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q)

	self:_bindInventoryContainers()
end

function ToolController:_initializeBlowerSound()
	local sound = self.BlowerSoundTemplate:Clone()
	sound.Name = "LocalBlowerWorkingSound"
	sound.Looped = true
	sound.Parent = SoundService
	self.BlowerSound = sound
	task.spawn(function()
		local success, message = pcall(function()
			ContentProvider:PreloadAsync({ sound })
		end)
		if not success then
			warn("Failed to preload blower sound: " .. tostring(message))
		end
	end)
end

function ToolController:_stopBlowerSound()
	local sound = self.BlowerSound
	if sound then
		sound:Stop()
		sound.TimePosition = 0
	end
end

function ToolController:_refreshBlowerSound()
	local shouldPlay = self.EquippedToolId == BLOWER_TOOL_ID
		and self:_getDesiredServerPickupActive()
		and not self.BagFull
	if not shouldPlay then
		self:_stopBlowerSound()
		return
	end
	local sound = self.BlowerSound
	if not sound or sound.Playing then
		return
	end
	sound.TimePosition = 0
	sound:Play()
end

function ToolController:_disableDefaultBackpack()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end

function ToolController:_getOrderedHotbarTools()
	local tools = {}
	local character = self.Player.Character
	local backpack = self.Player:FindFirstChildOfClass("Backpack")
	for _, container in { character, backpack } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") then
					local cleaningToolId = child:GetAttribute(CLEANING_TOOL_ATTRIBUTE)
					local config = type(cleaningToolId) == "string" and ToolConfig.ById[cleaningToolId] or nil
					if config and config.AvailableForGameplay == true then
						table.insert(tools, {
							Tool = child,
							Key = "Cleaning_" .. config.Id,
							Kind = "Cleaning",
							ToolId = config.Id,
							DisplayName = config.Name,
							Image = config.Image,
							Order = tonumber(child:GetAttribute(HOTBAR_ORDER_ATTRIBUTE)) or config.Index or 0,
							TieBreaker = config.Id,
						})
					elseif child:GetAttribute("LostItemCarry") == true then
						local lostItemId = child:GetAttribute("LostItemId")
						local lostItemConfig = type(lostItemId) == "string"
							and LostItemConfig.Types[lostItemId]
							or nil
						local spawnId = tostring(child:GetAttribute("SpawnId") or child.Name)
						local image = lostItemConfig and lostItemConfig.Image or child.TextureId
						if type(image) ~= "string" or image == "" then
							image = LOST_ITEM_PLACEHOLDER_IMAGE
						end
						local displayName = child.Name
						if lostItemConfig then
							displayName = lostItemConfig.DisplayName
						elseif child.ToolTip ~= "" then
							displayName = child.ToolTip
						end
						table.insert(tools, {
							Tool = child,
							Key = "LostItem_" .. spawnId,
							Kind = "LostItem",
							LostItemId = lostItemId,
							DisplayName = displayName,
							Image = image,
							Order = tonumber(child:GetAttribute(HOTBAR_ORDER_ATTRIBUTE)) or 1_000,
							TieBreaker = spawnId,
						})
					end
				end
			end
		end
	end
	table.sort(tools, function(left, right)
		if left.Order == right.Order then
			return left.TieBreaker < right.TieBreaker
		end
		return left.Order < right.Order
	end)
	return tools
end

function ToolController:_disconnectInventoryConnections()
	for _, connection in self.InventoryConnections do
		connection:Disconnect()
	end
	table.clear(self.InventoryConnections)
end

function ToolController:_bindInventoryContainers()
	self:_disconnectInventoryConnections()
	for _, container in { self.Player.Character, self.Player:FindFirstChildOfClass("Backpack") } do
		if container then
			table.insert(self.InventoryConnections, container.ChildAdded:Connect(function(child)
				if child:IsA("Tool") then
					self:_scheduleHotbarRefresh()
					if child:GetAttribute(CLEANING_TOOL_ATTRIBUTE) or container == self.Player.Character then
						self:_schedulePickupStateRefresh(true)
					end
				end
			end))
			table.insert(self.InventoryConnections, container.ChildRemoved:Connect(function(child)
				if child:IsA("Tool") then
					self:_scheduleHotbarRefresh()
					if child:GetAttribute(CLEANING_TOOL_ATTRIBUTE) or container == self.Player.Character then
						self:_schedulePickupStateRefresh(true)
					end
				end
			end))
		end
	end
	self:_scheduleHotbarRefresh()
	self:_schedulePickupStateRefresh(true)
end

function ToolController:_scheduleHotbarRefresh()
	if self.HotbarRefreshScheduled then
		return
	end
	self.HotbarRefreshScheduled = true
	task.defer(function()
		self.HotbarRefreshScheduled = false
		self:_renderHotbar()
	end)
end

function ToolController:_createHotbarButton(entry)
	local button = self.ToolButtonTemplate:Clone()
	button.Name = "Hotbar_" .. entry.Key
	button.Visible = true
	button.Parent = self.ToolFrame
	local buttonData = {
		Button = button,
		Connection = button.Activated:Connect(function()
			self:_activateHotbarEntry(entry.Key)
		end),
	}
	self.HotbarButtons[entry.Key] = buttonData
	return buttonData
end

function ToolController:_destroyHotbarButton(key)
	local buttonData = self.HotbarButtons[key]
	if not buttonData then
		return
	end
	if key == POOP_TOOL_HOTBAR_KEY and self.PoopGuidancePulseButton == buttonData.Button then
		self:_stopPoopGuidancePulse()
	end
	buttonData.Connection:Disconnect()
	buttonData.Button:Destroy()
	self.HotbarButtons[key] = nil
end

function ToolController:_renderHotbar()
	local orderedEntries = self:_getOrderedHotbarTools()
	local character = self.Player.Character
	local desiredKeys = {}
	table.clear(self.HotbarEntries)

	for hotbarIndex, entry in orderedEntries do
		desiredKeys[entry.Key] = true
		self.HotbarEntries[entry.Key] = entry
		local buttonData = self.HotbarButtons[entry.Key] or self:_createHotbarButton(entry)
		local button = buttonData.Button
		local imageLabel = button.ImageLabel
		local toolName = button.ToolName
		local stroke = button.UIStroke
		local keyLabel = button.key
		local numberLabel = button.number
		button.LayoutOrder = entry.Order
		toolName.Text = entry.DisplayName
		local keyVisible = UserInputService.KeyboardEnabled and hotbarIndex <= 9
		keyLabel.Text = if keyVisible then tostring(hotbarIndex) else ""
		keyLabel.Visible = keyVisible
		local image = if type(entry.Image) == "string" then entry.Image else ""
		imageLabel.Image = image
		imageLabel.Visible = image ~= ""
		if entry.Kind == "LostItem" then
			local count = math.max(1, math.floor(tonumber(self.CollectibleInventoryCounts[entry.LostItemId]) or 1))
			numberLabel.Text = "x" .. tostring(count)
			numberLabel.Visible = true
		else
			numberLabel.Visible = false
		end
		stroke.Enabled = true
		stroke.Color = if character and entry.Tool.Parent == character
			then EQUIPPED_STROKE_COLOR
			else UNEQUIPPED_STROKE_COLOR
	end

	local staleKeys = {}
	for key in self.HotbarButtons do
		if not desiredKeys[key] then
			table.insert(staleKeys, key)
		end
	end
	for _, key in staleKeys do
		self:_destroyHotbarButton(key)
	end
	self:_refreshPoopGuidancePulse()
end

function ToolController:_stopPoopGuidancePulse()
	if self.PoopGuidancePulseTween then
		self.PoopGuidancePulseTween:Cancel()
		self.PoopGuidancePulseTween = nil
	end
	local uiScale = self.PoopGuidancePulseScale
	if uiScale then
		uiScale.Scale = tonumber(uiScale:GetAttribute("OriginalScale")) or 1
		if self.PoopGuidancePulseScaleCreated then
			uiScale:Destroy()
		end
	end
	self.PoopGuidancePulseButton = nil
	self.PoopGuidancePulseScale = nil
	self.PoopGuidancePulseScaleCreated = false
end

function ToolController:_refreshPoopGuidancePulse()
	local buttonData = not self.HotbarSuppressed
		and self.PoopGuidanceActive
		and self.HotbarButtons[POOP_TOOL_HOTBAR_KEY]
		or nil
	local button = buttonData and buttonData.Button or nil
	if not button or not button.Parent then
		self:_stopPoopGuidancePulse()
		return
	end
	if self.PoopGuidancePulseButton == button and self.PoopGuidancePulseTween then
		return
	end
	self:_stopPoopGuidancePulse()
	local uiScale = button:FindFirstChild("PoopGuidancePulseScale")
	local createdScale = false
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Name = "PoopGuidancePulseScale"
		uiScale.Parent = button
		createdScale = true
	end
	assert(uiScale:IsA("UIScale"), "PoopGuidancePulseScale must be a UIScale")
	local originalScale = uiScale.Scale
	uiScale:SetAttribute("OriginalScale", originalScale)
	local tween = TweenService:Create(
		uiScale,
		TweenInfo.new(
			POOP_GUIDANCE_PULSE_DURATION,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut,
			-1,
			true
		),
		{ Scale = originalScale * POOP_GUIDANCE_PULSE_SCALE }
	)
	self.PoopGuidancePulseButton = button
	self.PoopGuidancePulseScale = uiScale
	self.PoopGuidancePulseScaleCreated = createdScale
	self.PoopGuidancePulseTween = tween
	tween:Play()
end

function ToolController:SetPoopGuidanceActive(active)
	self.PoopGuidanceActive = active == true
	self:_refreshPoopGuidancePulse()
end

function ToolController:_activateHotbarEntry(key)
	local entry = self.HotbarEntries[key]
	self:_activateHotbarEntryData(entry)
end

function ToolController:_activateHotbarIndex(index)
	local entries = self:_getOrderedHotbarTools()
	self:_activateHotbarEntryData(entries[index])
end

function ToolController:_activateHotbarEntryData(entry)
	if self.HotbarSuppressed then
		return
	end
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not entry or not character or not humanoid or humanoid.Health <= 0 then
		return
	end

	self:_cancelPickupInput()
	local isEquipped = entry.Tool.Parent == character
	if entry.Kind == "Cleaning" then
		self:_requestEquip(if isEquipped then "None" else entry.ToolId)
	elseif entry.Kind == "LostItem" then
		if isEquipped then
			humanoid:UnequipTools()
		elseif entry.Tool.Parent == self.Player:FindFirstChildOfClass("Backpack") then
			humanoid:EquipTool(entry.Tool)
		end
	end
	self:_scheduleHotbarRefresh()
end

function ToolController:_isPositionOverActiveGui(position)
	for _, guiObject in self.PlayerGui:GetGuiObjectsAtPosition(position.X, position.Y) do
		local current = guiObject
		while current and current ~= self.PlayerGui do
			if
				current:IsA("GuiButton")
				or current:IsA("TextBox")
				or (current:IsA("GuiObject") and current.Active)
			then
				return true
			end
			current = current.Parent
		end
	end
	return false
end

function ToolController:_isInputOverActiveGui(input)
	return self:_isPositionOverActiveGui(input.Position)
end

function ToolController:GetAimScreenPosition(viewportSize)
	local activeTouch = self.PrimaryAimTouch
	if activeTouch and self.ActivePickupTouches[activeTouch] then
		self.LastTouchAimScreenPosition = Vector2.new(activeTouch.Position.X, activeTouch.Position.Y)
		return self.LastTouchAimScreenPosition
	end
	if self.LastTouchAimScreenPosition and UserInputService:GetLastInputType() == Enum.UserInputType.Touch then
		return self.LastTouchAimScreenPosition
	end
	if UserInputService.MouseEnabled then
		local mousePosition = UserInputService:GetMouseLocation()
		if
			not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			and not self:_isPositionOverActiveGui(mousePosition)
		then
			self.LastMouseAimScreenPosition = mousePosition
		end
		if self.LastMouseAimScreenPosition then
			return self.LastMouseAimScreenPosition
		end
	end
	if self.LastTouchAimScreenPosition then
		return self.LastTouchAimScreenPosition
	end
	return Vector2.new(viewportSize.X / 2, viewportSize.Y / 2)
end

function ToolController:_setPickupActive(active)
	local equippedConfig = self.EquippedToolId and ToolConfig.ById[self.EquippedToolId]
	local behavior = equippedConfig and equippedConfig.Behavior
	local canCleanLeaves = behavior == "Collect" or behavior == "Broom" or behavior == "Blower"
	local shouldBeActive = active == true and canCleanLeaves
	if self.PickupInputActive == shouldBeActive then
		return
	end

	self.PickupInputActive = shouldBeActive
	self:_refreshPickupServerState()
	self.PickupInputChanged:Fire(shouldBeActive)
	self:_refreshBlowerSound()
end

function ToolController:_getDesiredServerPickupActive()
	if self.HotbarSuppressed then
		return false
	end
	local equippedConfig = self.EquippedToolId and ToolConfig.ById[self.EquippedToolId]
	local behavior = equippedConfig and equippedConfig.Behavior
	if behavior ~= "Collect" and behavior ~= "Broom" and behavior ~= "Blower" then
		return false
	end
	local character = self.Player.Character
	local equippedTool = character and character:FindFirstChildOfClass("Tool")
	if
		not equippedTool
		or equippedTool:GetAttribute(CLEANING_TOOL_ATTRIBUTE) ~= self.EquippedToolId
	then
		return false
	end
	return self.PickupInputActive or (self.AutomaticPickupActive and not self.BagFull)
end

function ToolController:_refreshPickupServerState(force)
	local desiredActive = self:_getDesiredServerPickupActive()
	if force ~= true and self.ServerPickupActive == desiredActive then
		return
	end
	self.ServerPickupActive = desiredActive
	self.Remotes.SetLeafPickupActive:FireServer(desiredActive)
	self:_refreshBlowerSound()
end

function ToolController:_schedulePickupStateRefresh(force)
	self.PickupStateRefreshForced = self.PickupStateRefreshForced or force == true
	if self.PickupStateRefreshScheduled then
		return
	end
	self.PickupStateRefreshScheduled = true
	task.defer(function()
		self.PickupStateRefreshScheduled = false
		local shouldForce = self.PickupStateRefreshForced
		self.PickupStateRefreshForced = false
		self:_refreshPickupServerState(shouldForce)
	end)
end

function ToolController:_refreshPickupInput()
	self:_setPickupActive(
		not self.HotbarSuppressed
			and (self.MousePickupHeld or next(self.ActivePickupTouches) ~= nil)
	)
end

function ToolController:_cancelPickupInput()
	self.MousePickupHeld = false
	table.clear(self.ActivePickupTouches)
	self.PrimaryAimTouch = nil
	self:_setPickupActive(false)
end

function ToolController:_requestEquip(toolId)
	local accepted, _, snapshot = self.Remotes.EquipTool:InvokeServer(toolId)
	if accepted then
		self.EquippedToolId = snapshot.EquippedToolId
		if ToolConfig.IsLeafCleaningTool(self.EquippedToolId) then
			self.LastEquippedToolId = self.EquippedToolId
		end
		self:_schedulePickupStateRefresh(true)
		self:_refreshBlowerSound()
	end
end

function ToolController:ToggleEquipped()
	if self.HotbarSuppressed then
		return
	end
	if self.EquippedToolId then
		self:_requestEquip("None")
	else
		self:_requestEquip(self.LastEquippedToolId or ToolConfig.DefaultToolId)
	end
end

function ToolController:GetEquippedToolId()
	return self.EquippedToolId
end

function ToolController:SetAutomaticPickupActive(active, force)
	local shouldBeActive = active == true
	if self.AutomaticPickupActive == shouldBeActive and force ~= true then
		return
	end
	self.AutomaticPickupActive = shouldBeActive
	self:_refreshPickupServerState(force)
end

function ToolController:RefreshAutomaticPickupActive()
	if self.AutomaticPickupActive then
		self:_refreshPickupServerState(true)
	end
end

function ToolController:CancelManualPickupInput()
	self:_cancelPickupInput()
end

function ToolController:SetHotbarSuppressed(suppressed)
	local shouldSuppress = suppressed == true
	local changed = self.HotbarSuppressed ~= shouldSuppress
	self.HotbarSuppressed = shouldSuppress
	if self.ToolFrame then
		self.ToolFrame.Visible = not shouldSuppress
	end
	if shouldSuppress then
		self:_cancelPickupInput()
		self:_stopPoopGuidancePulse()
	elseif changed then
		self:_scheduleHotbarRefresh()
		self:_refreshPoopGuidancePulse()
	end
	if changed then
		self:_schedulePickupStateRefresh(false)
	end
end

function ToolController:IsPickupInputActive()
	return self.PickupInputActive == true
end

function ToolController:ConnectPickupInputChanged(callback)
	return self.PickupInputChanged.Event:Connect(callback)
end

return ToolController

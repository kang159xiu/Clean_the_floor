local Players = game:GetService("Players")

local CharacterScaleService = {
	CharacterScale = 0.8,--人物缩放大小
}

local SYSTEM_BAG_ATTRIBUTE = "CleaningBagLevel"
local APPLIED_SCALE_ATTRIBUTE = "CleanTheFloorCharacterScale"
local ACCESSORY_SCALE_ATTRIBUTE = "CleanTheFloorAccessoryScale"
local SCALE_EPSILON = 0.0001

local function isTargetScale(value, targetScale)
	return type(value) == "number" and math.abs(value - targetScale) <= SCALE_EPSILON
end

local function detachUnscaledCharacterItems(character)
	local detached = {}
	for _, child in character:GetChildren() do
		if child:IsA("Tool")
			or (child:IsA("Accessory") and child:GetAttribute(SYSTEM_BAG_ATTRIBUTE) ~= nil)
		then
			table.insert(detached, child)
			child.Parent = nil
		end
	end
	return detached
end

local function restoreDetachedItems(character, detached)
	for _, instance in detached do
		if instance.Parent == nil then
			if character.Parent ~= nil then
				instance.Parent = character
			else
				instance:Destroy()
			end
		end
	end
end

function CharacterScaleService:ApplyCharacter(character)
	if not character or not character:IsA("Model") or character.Parent == nil then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
		or character:WaitForChild("Humanoid", 10)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
		or character:WaitForChild("HumanoidRootPart", 10)
	if
		not humanoid
		or not humanoid:IsA("Humanoid")
		or not rootPart
		or not rootPart:IsA("BasePart")
		or character.Parent == nil
	then
		return false
	end

	if self.ApplyingCharacters[character] then
		return isTargetScale(character:GetAttribute(APPLIED_SCALE_ATTRIBUTE), self.CharacterScale)
	end
	self.ApplyingCharacters[character] = true

	-- Cleaning tools intentionally retain their template size. System bags are
	-- already scaled independently before Humanoid:AddAccessory and must not be
	-- multiplied by the character scale a second time.
	local detached = detachUnscaledCharacterItems(character)
	local succeeded, scaleError = pcall(function()
		character:ScaleTo(self.CharacterScale)
		character:SetAttribute(APPLIED_SCALE_ATTRIBUTE, self.CharacterScale)
	end)
	restoreDetachedItems(character, detached)
	self.ApplyingCharacters[character] = nil

	if not succeeded then
		warn(string.format("Failed to scale character %s: %s", character:GetFullName(), tostring(scaleError)))
		return false
	end
	return true
end

function CharacterScaleService:ScaleAccessory(accessory)
	if not accessory or not accessory:IsA("Accessory") then
		return false
	end
	if isTargetScale(accessory:GetAttribute(ACCESSORY_SCALE_ATTRIBUTE), self.CharacterScale) then
		return true
	end

	local originalParent = accessory.Parent
	local scaleContainer = Instance.new("Model")
	scaleContainer.Name = "AccessoryScaleContainer"
	accessory.Parent = scaleContainer
	local succeeded, scaleError = pcall(function()
		scaleContainer:ScaleTo(self.CharacterScale)
	end)
	accessory.Parent = originalParent
	scaleContainer:Destroy()

	if not succeeded then
		warn(string.format("Failed to scale accessory %s: %s", accessory.Name, tostring(scaleError)))
		return false
	end
	accessory:SetAttribute(ACCESSORY_SCALE_ATTRIBUTE, self.CharacterScale)
	return true
end

function CharacterScaleService:_bindPlayer(player)
	local previousConnections = self.PlayerConnections[player]
	if previousConnections then
		for _, connection in previousConnections do
			connection:Disconnect()
		end
	end

	local connections = {}
	self.PlayerConnections[player] = connections
	table.insert(connections, player.CharacterAdded:Connect(function(character)
		task.spawn(function()
			if player.Character == character then
				self:ApplyCharacter(character)
			end
		end)
	end))
	table.insert(connections, player.CharacterAppearanceLoaded:Connect(function(character)
		task.spawn(function()
			if player.Character == character then
				self:ApplyCharacter(character)
			end
		end)
	end))

	if player.Character then
		local character = player.Character
		task.spawn(function()
			if player.Character == character then
				self:ApplyCharacter(character)
			end
		end)
	end
end

function CharacterScaleService:Init()
	self.PlayerConnections = {}
	self.ApplyingCharacters = setmetatable({}, { __mode = "k" })

	Players.PlayerAdded:Connect(function(player)
		self:_bindPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		local connections = self.PlayerConnections[player]
		if connections then
			for _, connection in connections do
				connection:Disconnect()
			end
		end
		self.PlayerConnections[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		self:_bindPlayer(player)
	end
end

return CharacterScaleService

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)

local BagVisualService = {}

local BAG_ID_ATTRIBUTE = "CleaningBagLevel"

function BagVisualService:_removeSystemBags(character)
	for _, child in character:GetChildren() do
		if child:IsA("Accessory") and child:GetAttribute(BAG_ID_ATTRIBUTE) ~= nil then
			child:Destroy()
		end
	end
end

function BagVisualService:_syncCharacter(player, character)
	local state = self.PlayerDataService:GetState(player)
	if not state or player.Character ~= character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if not self.CharacterScaleService:ApplyCharacter(character) or player.Character ~= character then
		return
	end
	local bagConfig = self.PlayerDataService:GetBagVisualConfig(state)
	local template = self.TemplateFolder[bagConfig.ModelName]

	self:_removeSystemBags(character)
	local accessory = template:Clone()
	accessory.Name = "CleaningBag_" .. bagConfig.ModelName
	accessory:SetAttribute(BAG_ID_ATTRIBUTE, bagConfig.Id)
	for _, descendant in accessory:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		end
	end
	if not self.CharacterScaleService:ScaleAccessory(accessory) then
		accessory:Destroy()
		return
	end
	humanoid:AddAccessory(accessory)
end

function BagVisualService:SyncPlayer(player)
	local character = player.Character
	if character then
		self:_syncCharacter(player, character)
	end
end

function BagVisualService:_bindPlayer(player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(function()
			character:WaitForChild("Humanoid")
			if player.Character == character then
				self:_syncCharacter(player, character)
			end
		end)
	end)
	player.CharacterAppearanceLoaded:Connect(function(character)
		if player.Character == character then
			self:_syncCharacter(player, character)
		end
	end)
end

function BagVisualService:Init(playerDataService, characterScaleService)
	self.PlayerDataService = playerDataService
	self.CharacterScaleService = characterScaleService
	assert(
		self.CharacterScaleService
			and type(self.CharacterScaleService.ApplyCharacter) == "function"
			and type(self.CharacterScaleService.ScaleAccessory) == "function",
		"BagVisualService requires CharacterScaleService"
	)
	self.TemplateFolder = ReplicatedStorage:FindFirstChild("bag")
	assert(self.TemplateFolder and self.TemplateFolder:IsA("Folder"), "ReplicatedStorage.bag must be a Folder")
	local configs = {}
	for _, level in BagConfig.Order do
		table.insert(configs, BagConfig.Levels[level])
	end
	for _, bagId in BagConfig.PermanentOrder do
		if BagConfig.IsPermanentBagEnabled(bagId) then
			table.insert(configs, BagConfig.PermanentBags[bagId])
		end
	end
	for _, bagConfig in configs do
		local template = self.TemplateFolder:FindFirstChild(bagConfig.ModelName)
		assert(
			template and template:IsA("Accessory"),
			"ReplicatedStorage." .. bagConfig.ModelPath .. " must be an Accessory"
		)
		local handle = template:FindFirstChild("Handle")
		assert(handle and handle:IsA("BasePart"), bagConfig.ModelName .. ".Handle must be a BasePart")
		local attachment = handle:FindFirstChild("BodyBackAttachment")
		assert(
			attachment and attachment:IsA("Attachment"),
			bagConfig.ModelName .. ".Handle.BodyBackAttachment is missing"
		)
	end

	playerDataService:AddPlayerStateReadyHandler(function(player)
		self:SyncPlayer(player)
	end)
	Players.PlayerAdded:Connect(function(player)
		self:_bindPlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_bindPlayer(player)
	end
end

return BagVisualService

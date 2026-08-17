local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VisitorBillboardController = {}

local LOCAL_BILLBOARD_NAME = "LocalVisitorBillboard"
local THUMBNAIL_TYPE = Enum.ThumbnailType.HeadShot
local THUMBNAIL_SIZE = Enum.ThumbnailSize.Size180x180

local function disconnect(connection)
	if connection then
		connection:Disconnect()
	end
end

function VisitorBillboardController:_resolveTemplate()
	local friendFolder = ReplicatedStorage:FindFirstChild("frend")
	local template = friendFolder and friendFolder:FindFirstChild("BillboardGui")
	local power = template and template:FindFirstChild("Power")
	local value = power and power:FindFirstChild("Value")
	local image = power and power:FindFirstChild("ImageLabel")
	if
		not (template and template:IsA("BillboardGui"))
		or not (value and value:IsA("TextLabel"))
		or not (image and image:IsA("ImageLabel"))
	then
		warn(
			"ReplicatedStorage.frend.BillboardGui.Power.Value/ImageLabel is invalid; visitor billboards are disabled."
		)
		return nil
	end
	return template
end

function VisitorBillboardController:_destroyBillboard(entry)
	if entry.Billboard then
		entry.Billboard:Destroy()
		entry.Billboard = nil
	end
end

function VisitorBillboardController:_disconnectCharacter(entry)
	disconnect(entry.HeadAddedConnection)
	entry.HeadAddedConnection = nil
	entry.Character = nil
	self:_destroyBillboard(entry)
end

function VisitorBillboardController:_applyThumbnail(entry, billboard)
	local power = billboard:FindFirstChild("Power")
	local imageLabel = power and power:FindFirstChild("ImageLabel")
	if not (imageLabel and imageLabel:IsA("ImageLabel")) then
		return
	end
	local cachedImage = self.ThumbnailCache[entry.Player.UserId]
	if cachedImage then
		imageLabel.Image = cachedImage
		return
	end

	task.spawn(function()
		local success, image = pcall(function()
			return Players:GetUserThumbnailAsync(entry.Player.UserId, THUMBNAIL_TYPE, THUMBNAIL_SIZE)
		end)
		if not success or type(image) ~= "string" or image == "" then
			return
		end
		self.ThumbnailCache[entry.Player.UserId] = image
		if self.Entries[entry.Player.UserId] == entry and entry.Billboard == billboard and billboard.Parent then
			imageLabel.Image = image
		end
	end)
end

function VisitorBillboardController:_attachToHead(entry, head)
	if
		not self.Template
		or self.DesiredVisitors[entry.Player.UserId] == nil
		or not (head and head:IsA("BasePart"))
	then
		return
	end
	self:_destroyBillboard(entry)
	local stale = head:FindFirstChild(LOCAL_BILLBOARD_NAME)
	if stale and stale:GetAttribute("LocalVisitorBillboard") == true then
		stale:Destroy()
	end

	local billboard = self.Template:Clone()
	billboard.Name = LOCAL_BILLBOARD_NAME
	billboard:SetAttribute("LocalVisitorBillboard", true)
	billboard.Adornee = head
	billboard.Enabled = true
	local power = billboard:FindFirstChild("Power")
	local value = power and power:FindFirstChild("Value")
	value.Text = "Visitor: " .. entry.DisplayName
	billboard.Parent = head
	entry.Billboard = billboard
	self:_applyThumbnail(entry, billboard)
end

function VisitorBillboardController:_attachToCharacter(entry, character)
	self:_disconnectCharacter(entry)
	entry.Character = character
	if self.DesiredVisitors[entry.Player.UserId] == nil or not character then
		return
	end
	entry.HeadAddedConnection = character.ChildAdded:Connect(function(child)
		if entry.Character == character and child.Name == "Head" and child:IsA("BasePart") then
			self:_attachToHead(entry, child)
		end
	end)
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		self:_attachToHead(entry, head)
	end
end

function VisitorBillboardController:_removeVisitor(userId)
	local entry = self.Entries[userId]
	if not entry then
		return
	end
	self.Entries[userId] = nil
	self:_disconnectCharacter(entry)
	disconnect(entry.CharacterAddedConnection)
	disconnect(entry.CharacterRemovingConnection)
end

function VisitorBillboardController:_ensureVisitor(player, displayName)
	local entry = self.Entries[player.UserId]
	if entry then
		entry.DisplayName = displayName
		if entry.Billboard then
			local power = entry.Billboard:FindFirstChild("Power")
			local value = power and power:FindFirstChild("Value")
			if value and value:IsA("TextLabel") then
				value.Text = "Visitor: " .. displayName
			end
		end
		return
	end

	entry = {
		Player = player,
		DisplayName = displayName,
	}
	self.Entries[player.UserId] = entry
	entry.CharacterAddedConnection = player.CharacterAdded:Connect(function(character)
		self:_attachToCharacter(entry, character)
	end)
	entry.CharacterRemovingConnection = player.CharacterRemoving:Connect(function(character)
		if entry.Character == character then
			self:_disconnectCharacter(entry)
		end
	end)
	self:_attachToCharacter(entry, player.Character)
end

function VisitorBillboardController:_applySnapshot(snapshot)
	local desiredVisitors = {}
	for _, visitor in type(snapshot.ActiveYardVisitors) == "table" and snapshot.ActiveYardVisitors or {} do
		local userId = type(visitor) == "table" and tonumber(visitor.UserId) or nil
		local displayName = type(visitor) == "table" and visitor.DisplayName or nil
		if userId and userId > 0 and type(displayName) == "string" and displayName ~= "" then
			desiredVisitors[math.floor(userId)] = displayName
		end
	end
	self.DesiredVisitors = desiredVisitors

	local staleUserIds = {}
	for userId in self.Entries do
		if desiredVisitors[userId] == nil then
			table.insert(staleUserIds, userId)
		end
	end
	for _, userId in staleUserIds do
		self:_removeVisitor(userId)
	end
	if not self.Template then
		return
	end
	for userId, displayName in desiredVisitors do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			self:_ensureVisitor(player, displayName)
		end
	end
end

function VisitorBillboardController:Init(remotes)
	self.Template = self:_resolveTemplate()
	self.DesiredVisitors = {}
	self.Entries = {}
	self.ThumbnailCache = {}

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:_applySnapshot(snapshot)
	end)
	Players.PlayerAdded:Connect(function(player)
		local displayName = self.DesiredVisitors[player.UserId]
		if self.Template and displayName then
			self:_ensureVisitor(player, displayName)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_removeVisitor(player.UserId)
	end)
end

return VisitorBillboardController

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local GamePassStationCollisionService = {}

local DEFAULT_COLLISION_GROUP = "Default"
local ENTITLEMENT_ORDER = { "Tool04", "bag09", "bag010", "bag011" }
local ENTITLEMENT_BITS = {
	Tool04 = 1,
	bag09 = 2,
	bag010 = 4,
	bag011 = 8,
}
local STATION_GROUPS = {
	Tool04 = "GPStationTool04",
	bag09 = "GPStationBag09",
	bag010 = "GPStationBag010",
	bag011 = "GPStationBag011",
}

local function playerGroupName(mask)
	return string.format("GPOwned%02d", mask)
end

function GamePassStationCollisionService:_setupCollisionGroups()
	for _, groupName in STATION_GROUPS do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(groupName)
		end)
	end
	for mask = 0, 15 do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(playerGroupName(mask))
		end)
	end

	for _, stationGroup in STATION_GROUPS do
		PhysicsService:CollisionGroupSetCollidable(stationGroup, DEFAULT_COLLISION_GROUP, true)
		for mask = 0, 15 do
			local canPass = false
			for entitlementId, bit in ENTITLEMENT_BITS do
				if STATION_GROUPS[entitlementId] == stationGroup and bit32.band(mask, bit) ~= 0 then
					canPass = true
					break
				end
			end
			PhysicsService:CollisionGroupSetCollidable(stationGroup, playerGroupName(mask), not canPass)
		end
	end

	for leftMask = 0, 15 do
		local leftGroup = playerGroupName(leftMask)
		PhysicsService:CollisionGroupSetCollidable(leftGroup, DEFAULT_COLLISION_GROUP, true)
		for rightMask = 0, 15 do
			PhysicsService:CollisionGroupSetCollidable(leftGroup, playerGroupName(rightMask), false)
		end
	end
end

function GamePassStationCollisionService:_getPlayerMask(player)
	local access = self.PlayerAccess[player]
	local mask = 0
	for _, entitlementId in ENTITLEMENT_ORDER do
		if access and access[entitlementId] == true then
			mask = bit32.bor(mask, ENTITLEMENT_BITS[entitlementId])
		end
	end
	return mask
end

function GamePassStationCollisionService:_applyCharacter(player, character)
	if not character or player.Character ~= character then
		return
	end
	local mask = self:_getPlayerMask(player)
	local groupName = playerGroupName(mask)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end
end

function GamePassStationCollisionService:_bindCharacter(player, character)
	local oldConnection = self.CharacterDescendantConnections[player]
	if oldConnection then
		oldConnection:Disconnect()
	end
	self:_applyCharacter(player, character)
	self.CharacterDescendantConnections[player] = character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") and player.Character == character then
			local mask = self:_getPlayerMask(player)
			descendant.CollisionGroup = playerGroupName(mask)
		end
	end)
end

function GamePassStationCollisionService:_bindPlayer(player)
	player.CharacterAdded:Connect(function(character)
		self:_bindCharacter(player, character)
	end)
	if player.Character then
		self:_bindCharacter(player, player.Character)
	end
end

function GamePassStationCollisionService:SetPlayerAccess(player, entitlementId, canPass)
	assert(ENTITLEMENT_BITS[entitlementId], "Unknown purchase-station entitlement: " .. tostring(entitlementId))
	local access = self.PlayerAccess[player]
	if not access then
		access = {}
		self.PlayerAccess[player] = access
	end
	access[entitlementId] = canPass == true
	if player.Character then
		self:_applyCharacter(player, player.Character)
	end
end

function GamePassStationCollisionService:RegisterStation(entitlementId, station)
	local stationGroup = STATION_GROUPS[entitlementId]
	assert(stationGroup, "Unknown purchase-station entitlement: " .. tostring(entitlementId))
	if self.StationConnections[station] then
		return
	end

	local function apply(instance)
		if instance:IsA("BasePart") then
			instance.CollisionGroup = stationGroup
		end
	end
	apply(station)
	for _, descendant in station:GetDescendants() do
		apply(descendant)
	end
	self.StationConnections[station] = station.DescendantAdded:Connect(apply)
	station.Destroying:Connect(function()
		local connection = self.StationConnections[station]
		if connection then
			connection:Disconnect()
		end
		self.StationConnections[station] = nil
	end)
end

function GamePassStationCollisionService:Init()
	self.PlayerAccess = {}
	self.CharacterDescendantConnections = {}
	self.StationConnections = {}
	self:_setupCollisionGroups()

	Players.PlayerAdded:Connect(function(player)
		self:_bindPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self.PlayerAccess[player] = nil
		local connection = self.CharacterDescendantConnections[player]
		if connection then
			connection:Disconnect()
		end
		self.CharacterDescendantConnections[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		self:_bindPlayer(player)
	end
end

return GamePassStationCollisionService

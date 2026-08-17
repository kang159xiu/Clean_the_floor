local Players = game:GetService("Players")

local YardService = {}

local activeOwners = {}
local membersByOwner = {}
local yardChangedHandlers = {}

local function ensureMembers(owner)
	local members = membersByOwner[owner]
	if not members then
		members = {}
		membersByOwner[owner] = members
	end
	return members
end

function YardService:Init(playerDataService)
	self.PlayerDataService = playerDataService

	playerDataService:AddPlayerStateReadyHandler(function(player, state)
		activeOwners[player] = player
		ensureMembers(player)[player] = true
		state.ActiveYardOwnerUserId = player.UserId
	end)

	playerDataService:SetYardContextProvider(function(player)
		local owner = activeOwners[player]
		if not owner or owner.Parent ~= Players then
			owner = player
		end
		return {
			Owner = owner,
			OwnerUserId = owner.UserId,
			OwnerName = owner.DisplayName,
			IsVisiting = owner ~= player,
			Visitors = self:GetVisitors(owner),
		}
	end)

	Players.PlayerRemoving:Connect(function(player)
		local owner = activeOwners[player]
		if owner then
			local members = membersByOwner[owner]
			if members then
				members[player] = nil
			end
		end

		local ownedMembers = membersByOwner[player]
		membersByOwner[player] = nil
		activeOwners[player] = nil
		if owner and owner ~= player and owner.Parent == Players then
			task.defer(function()
				if owner.Parent == Players then
					self:_pushMemberSnapshots(owner)
				end
			end)
		end
		if ownedMembers then
			for member in ownedMembers do
				if member ~= player and member.Parent == Players then
					activeOwners[member] = nil
					self.PlayerDataService:Notify(
						member,
						string.format("%s left the server. Returning to your yard.", player.DisplayName)
					)
					task.delay(2, function()
						if member.Parent == Players and self.PlayerDataService:GetState(member) then
							self:EnterYard(member, member)
						end
					end)
				end
			end
		end
	end)
end

function YardService:AddYardChangedHandler(handler)
	table.insert(yardChangedHandlers, handler)
end

function YardService:_notifyYardChanged(player, owner, previousOwner)
	for _, handler in yardChangedHandlers do
		local success, message = pcall(handler, player, owner, previousOwner)
		if not success then
			warn("Yard-changed handler failed: " .. tostring(message))
		end
	end
end

function YardService:GetActiveOwner(player)
	local owner = activeOwners[player]
	if owner and owner.Parent == Players and self.PlayerDataService:GetState(owner) then
		return owner
	end
	local state = self.PlayerDataService:GetState(player)
	if
		player.Parent == Players
		and state
		and (state.ActiveYardOwnerUserId == nil or state.ActiveYardOwnerUserId == player.UserId)
	then
		return player
	end
	return nil
end

function YardService:GetMembers(owner)
	local result = {}
	local members = membersByOwner[owner]
	if members then
		for member in members do
			if member.Parent == Players then
				table.insert(result, member)
			end
		end
	end
	return result
end

function YardService:GetVisitors(owner)
	local result = {}
	for _, member in self:GetMembers(owner) do
		if member ~= owner and self.PlayerDataService:GetState(member) then
			table.insert(result, {
				UserId = member.UserId,
				DisplayName = member.DisplayName,
			})
		end
	end
	table.sort(result, function(left, right)
		return left.UserId < right.UserId
	end)
	return result
end

function YardService:_pushMemberSnapshots(owner)
	if not owner then
		return
	end
	for _, member in self:GetMembers(owner) do
		self.PlayerDataService:PushSnapshot(member)
	end
end

function YardService:IsOwner(player)
	return self:GetActiveOwner(player) == player
end

function YardService:EnterYard(player, owner)
	if
		player.Parent ~= Players
		or owner.Parent ~= Players
		or not self.PlayerDataService:GetState(player)
		or not self.PlayerDataService:GetState(owner)
	then
		return false, "Yard is temporarily unavailable."
	end

	local previousOwner = activeOwners[player]
	if previousOwner == owner then
		return true, owner == player and "Already in your yard." or "Already in this yard."
	end
	if previousOwner then
		local previousMembers = membersByOwner[previousOwner]
		if previousMembers then
			previousMembers[player] = nil
		end
	end

	activeOwners[player] = owner
	ensureMembers(owner)[player] = true
	local state = self.PlayerDataService:GetState(player)
	state.ActiveYardOwnerUserId = owner.UserId
	self:_notifyYardChanged(player, owner, previousOwner)
	self:_pushMemberSnapshots(previousOwner)
	self:_pushMemberSnapshots(owner)
	if owner ~= player then
		self.PlayerDataService:Notify(
			owner,
			string.format("%s is visiting your yard.", player.DisplayName)
		)
	end
	return true, owner == player and "Returned to your yard." or ("Entered " .. owner.DisplayName .. "'s yard.")
end

function YardService:ReturnHome(player)
	return self:EnterYard(player, player)
end

return YardService

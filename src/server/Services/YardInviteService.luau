local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local YardInviteService = {}

local INVITE_DURATION = 30
local INVITE_COOLDOWN = 3
local ENTER_COOLDOWN = 0.5

local pendingByTarget = {}
local requestTimes = {}
local enterRequestTimes = {}

local function clearInvite(target, invite)
	if pendingByTarget[target] == invite then
		pendingByTarget[target] = nil
	end
end

function YardInviteService:Init(playerDataService, yardService, remotes)
	self.PlayerDataService = playerDataService
	self.YardService = yardService
	self.Remotes = remotes

	remotes.SendYardInvite.OnServerInvoke = function(player, targetUserId)
		return self:SendInvite(player, targetUserId)
	end
	remotes.RespondYardInvite.OnServerInvoke = function(player, inviteId, accepted)
		return self:Respond(player, inviteId, accepted)
	end
	remotes.LeaveVisitedYard.OnServerInvoke = function(player)
		local success, message = yardService:ReturnHome(player)
		if success then
			playerDataService:Notify(player, message)
		end
		return success, message, playerDataService:GetSnapshot(player)
	end
	remotes.EnterYard.OnServerInvoke = function(player, ownerUserId)
		return self:EnterYard(player, ownerUserId)
	end

	Players.PlayerRemoving:Connect(function(player)
		requestTimes[player] = nil
		enterRequestTimes[player] = nil
		local ownInvite = pendingByTarget[player]
		if ownInvite then
			clearInvite(player, ownInvite)
		end
		for target, invite in pendingByTarget do
			if invite.Inviter == player then
				clearInvite(target, invite)
				if target.Parent == Players then
					remotes.YardInviteReceived:FireClient(target, {
						Kind = "Cancel",
						InviteId = invite.Id,
					})
				end
			end
		end
	end)
end

function YardInviteService:EnterYard(player, ownerUserId)
	local now = os.clock()
	if now - (enterRequestTimes[player] or -math.huge) < ENTER_COOLDOWN then
		return false, "Too fast.", self.PlayerDataService:GetSnapshot(player)
	end
	enterRequestTimes[player] = now
	local numericUserId = tonumber(ownerUserId)
	local owner = numericUserId and Players:GetPlayerByUserId(math.floor(numericUserId)) or nil
	if not owner or owner == player or not self.PlayerDataService:GetState(owner) then
		return false, "This player's yard is temporarily unavailable.", self.PlayerDataService:GetSnapshot(player)
	end
	local success, message = self.YardService:EnterYard(player, owner)
	if success then
		self.PlayerDataService:Notify(player, message)
	end
	return success, message, self.PlayerDataService:GetSnapshot(player)
end

function YardInviteService:SendInvite(inviter, targetUserId)
	local now = os.clock()
	if now - (requestTimes[inviter] or -math.huge) < INVITE_COOLDOWN then
		return false, "Invites are being sent too quickly."
	end
	requestTimes[inviter] = now

	if not self.YardService:IsOwner(inviter) then
		return false, "Return to your yard before inviting friends."
	end
	local numericUserId = tonumber(targetUserId)
	local target = numericUserId and Players:GetPlayerByUserId(math.floor(numericUserId)) or nil
	if not target or target == inviter or not self.PlayerDataService:GetState(target) then
		return false, "This player cannot accept invites right now."
	end

	local existing = pendingByTarget[target]
	if existing and existing.ExpiresAt > now then
		return false, "This player is handling another invite."
	end
	if existing then
		clearInvite(target, existing)
	end

	local invite = {
		Id = HttpService:GenerateGUID(false),
		Inviter = inviter,
		Target = target,
		ExpiresAt = now + INVITE_DURATION,
	}
	pendingByTarget[target] = invite
	self.Remotes.YardInviteReceived:FireClient(target, {
		Kind = "Invite",
		InviteId = invite.Id,
		InviterUserId = inviter.UserId,
		InviterName = inviter.DisplayName,
		ExpiresIn = INVITE_DURATION,
	})

	task.delay(INVITE_DURATION, function()
		if pendingByTarget[target] == invite then
			clearInvite(target, invite)
			if target.Parent == Players then
				self.Remotes.YardInviteReceived:FireClient(target, {
					Kind = "Cancel",
					InviteId = invite.Id,
				})
			end
			if inviter.Parent == Players then
				self.PlayerDataService:Notify(
					inviter,
					string.format("%s did not accept your invite.", target.DisplayName)
				)
			end
		end
	end)
	return true, "Yard invite sent to " .. target.DisplayName .. "."
end

function YardInviteService:Respond(target, inviteId, accepted)
	if type(inviteId) ~= "string" or type(accepted) ~= "boolean" then
		return false, "Invalid invite response."
	end
	local invite = pendingByTarget[target]
	if not invite or invite.Id ~= inviteId or invite.ExpiresAt <= os.clock() then
		if invite then
			clearInvite(target, invite)
		end
		return false, "This invite has expired."
	end
	clearInvite(target, invite)

	local inviter = invite.Inviter
	if not inviter or inviter.Parent ~= Players or not self.PlayerDataService:GetState(inviter) then
		return false, "The inviter has left the server."
	end
	if not accepted then
		self.PlayerDataService:Notify(
			inviter,
			string.format("%s declined your invite.", target.DisplayName)
		)
		return true, "Invite declined."
	end

	if not self.YardService:IsOwner(inviter) then
		return false, "The inviter is no longer in their own yard."
	end
	local targetMembers = self.YardService:GetMembers(target)
	if #targetMembers > 1 then
		return false, "Guests are still in your yard. You cannot visit another yard yet."
	end

	local success, message = self.YardService:EnterYard(target, inviter)
	if success then
		self.PlayerDataService:Notify(target, message)
	end
	return success, message, self.PlayerDataService:GetSnapshot(target)
end

return YardInviteService

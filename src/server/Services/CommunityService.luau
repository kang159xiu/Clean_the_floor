local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local CommunityConfig = require(ReplicatedStorage.Shared.Config.CommunityConfig)

local CommunityService = {}

local REQUEST_COOLDOWN = 0.75
local requestLocks = {}
local requestTimes = {}

local function makeResult(status, isMember, claimed, awardedCoins)
	return {
		Status = status,
		IsMember = isMember == true,
		Claimed = claimed == true,
		AwardedCoins = math.max(0, math.floor(tonumber(awardedCoins) or 0)),
	}
end

function CommunityService:_claim(player)
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return makeResult("Unavailable", false, false, 0)
	end
	if state.CommunityRewardClaimed == true then
		return makeResult("AlreadyClaimed", true, true, 0)
	end
	if requestLocks[player] then
		return makeResult("Unavailable", false, false, 0)
	end

	local now = os.clock()
	if now - (requestTimes[player] or -math.huge) < REQUEST_COOLDOWN then
		return makeResult("Unavailable", false, false, 0)
	end
	requestTimes[player] = now
	requestLocks[player] = true

	local operationSucceeded, result = xpcall(function()
		local membershipSucceeded, isMember = pcall(function()
			return player:IsInGroupAsync(CommunityConfig.GroupId)
		end)
		if not membershipSucceeded then
			return makeResult("Unavailable", false, false, 0)
		end
		if player.Parent ~= Players or not self.PlayerDataService:GetState(player) then
			return makeResult("Unavailable", false, false, 0)
		end
		if isMember ~= true then
			return makeResult("NotMember", false, false, 0)
		end

		local newlyClaimed, awardedCoins, targetCoins, claimed =
			self.PlayerDataService:TryClaimCommunityReward(player, CommunityConfig.RewardCoins)
		if not claimed then
			return makeResult("Unavailable", true, false, 0)
		end
		if not newlyClaimed then
			return makeResult("AlreadyClaimed", true, true, 0)
		end

		if awardedCoins > 0 then
			self.PlayerDataService:NotifyCoinGainEvent(player, {
				Phase = "Normal",
				BaseAmount = awardedCoins,
				RewardMultiplier = 1,
				Amount = awardedCoins,
				TargetCoins = targetCoins,
				StepCount = 1,
				FirstStepDelay = 0,
				StepInterval = 0.1,
				HoldDuration = 1,
				FlyDuration = 0.35,
			})
		end
		self.PlayerDataService:Notify(
			player,
			string.format("Community Reward: +%s Coins", CoinFormat.Compact(awardedCoins))
		)
		self.PlayerDataService:PushSnapshot(player)
		return makeResult("Awarded", true, true, awardedCoins)
	end, debug.traceback)

	requestLocks[player] = nil
	if not operationSucceeded then
		warn(string.format("Community reward claim failed for %s: %s", player.Name, tostring(result)))
		return makeResult("Unavailable", false, false, 0)
	end
	return result
end

function CommunityService:Init(playerDataService, claimRemote)
	self.PlayerDataService = playerDataService
	assert(claimRemote:IsA("RemoteFunction"), "ClaimCommunityReward must be a RemoteFunction")

	claimRemote.OnServerInvoke = function(player)
		return self:_claim(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		requestLocks[player] = nil
		requestTimes[player] = nil
	end)
end

return CommunityService

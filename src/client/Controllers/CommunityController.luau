local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CommunityConfig = require(ReplicatedStorage.Shared.Config.CommunityConfig)

local CommunityController = {}

local VERIFICATION_RETRY_DELAYS = { 0, 1, 2, 4, 8 }

local function unavailableResult()
	return {
		Status = "Unavailable",
		IsMember = false,
		Claimed = false,
		AwardedCoins = 0,
	}
end

function CommunityController:Init(remotes, hudController)
	self.Player = Players.LocalPlayer
	self.HUDController = hudController
	self.ClaimRemote = remotes.ClaimCommunityReward
	self.PromptInFlight = false
	self.ManualPromptRequested = false
	self.AutoPromptConsumed = false
	self.LastSnapshotClaimed = nil
	self.VerificationGeneration = 0
	assert(self.ClaimRemote:IsA("RemoteFunction"), "ClaimCommunityReward must be a RemoteFunction")

	local playerGui = self.Player:WaitForChild("PlayerGui")
	local button = playerGui
		:WaitForChild("GameHUD")
		:WaitForChild("HUDRoot")
		:WaitForChild("jiaqun")
	assert(button:IsA("GuiButton"), "GameHUD.HUDRoot.jiaqun must be a GuiButton")
	self.Button = button

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:_onSnapshot(snapshot)
	end)

	button.Activated:Connect(function()
		self.ManualPromptRequested = true
		self.AutoPromptConsumed = true
		self:_requestPrompt(true)
	end)

	task.delay(CommunityConfig.AutoPromptDelay, function()
		if
			self.ManualPromptRequested
			or self.AutoPromptConsumed
			or not self.Button.Parent
			or not self.Button.Visible
		then
			return
		end
		self.AutoPromptConsumed = true
		self:_requestPrompt(false)
	end)
end

function CommunityController:_notify(message)
	self.HUDController:ShowNotification(message)
end

function CommunityController:_setClaimed()
	self.LastSnapshotClaimed = true
	self.AutoPromptConsumed = true
	self.VerificationGeneration += 1
	if self.Button and self.Button.Parent then
		self.Button.Visible = false
	end
end

function CommunityController:_applyClaimResult(result, notifyAlreadyMember)
	if type(result) ~= "table" then
		return false
	end
	local status = result.Status
	if result.Claimed == true or status == "Awarded" or status == "AlreadyClaimed" then
		self:_setClaimed()
		if notifyAlreadyMember and status == "AlreadyClaimed" then
			self:_notify("You have already joined the official community.")
		end
		return true
	end
	return false
end

function CommunityController:_invokeClaim()
	local succeeded, result = pcall(function()
		return self.ClaimRemote:InvokeServer()
	end)
	if not succeeded or type(result) ~= "table" then
		return unavailableResult()
	end
	return result
end

function CommunityController:_verifyMembership(generation, retryNotMember)
	for _, delaySeconds in VERIFICATION_RETRY_DELAYS do
		if delaySeconds > 0 then
			task.wait(delaySeconds)
		end
		if generation ~= self.VerificationGeneration or not self.Button.Parent then
			return false
		end

		local result = self:_invokeClaim()
		if self:_applyClaimResult(result, false) then
			return true
		end
		if result.Status == "NotMember" and not retryNotMember then
			return false
		end
	end
	return false
end

function CommunityController:_beginSnapshotVerification()
	self.VerificationGeneration += 1
	local generation = self.VerificationGeneration
	task.spawn(function()
		self:_verifyMembership(generation, false)
	end)
end

function CommunityController:_onSnapshot(snapshot)
	if type(snapshot) ~= "table" or type(snapshot.CommunityRewardClaimed) ~= "boolean" then
		return
	end

	local claimed = snapshot.CommunityRewardClaimed == true
	if claimed then
		self:_setClaimed()
		return
	end

	local previousClaimed = self.LastSnapshotClaimed
	self.LastSnapshotClaimed = false
	if self.Button and self.Button.Parent then
		self.Button.Visible = true
	end
	if previousClaimed == nil or previousClaimed == true then
		self:_beginSnapshotVerification()
	end
end

function CommunityController:_requestPrompt(isManual)
	if self.PromptInFlight or not self.Button.Parent or not self.Button.Visible then
		return
	end
	self.PromptInFlight = true

	task.spawn(function()
		local existingClaim = self:_invokeClaim()
		if self:_applyClaimResult(existingClaim, isManual) then
			self.PromptInFlight = false
			return
		end

		local promptSucceeded, result = pcall(function()
			return GroupService:PromptJoinAsync(CommunityConfig.GroupId)
		end)
		if not promptSucceeded then
			self.PromptInFlight = false
			self:_notify("The community page is unavailable. Try again later.")
			return
		end

		if result == Enum.GroupMembershipStatus.Joined or result == Enum.GroupMembershipStatus.AlreadyMember then
			self.VerificationGeneration += 1
			local generation = self.VerificationGeneration
			local verified = self:_verifyMembership(generation, true)
			if not verified and self.Button.Parent and self.Button.Visible then
				self:_notify("Community membership is still syncing. Your reward will be checked again next time.")
			end
		elseif result == Enum.GroupMembershipStatus.JoinRequestPending then
			self:_notify("Your join request was submitted.")
		end
		self.PromptInFlight = false
	end)
end

return CommunityController

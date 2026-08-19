local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)

local FriendRewardController = {}

function FriendRewardController:_applySnapshot(snapshot)
	local total = math.max(0, math.floor(tonumber(snapshot.PendingFriendRewardTotal) or 0))
	self.Frame.Visible = total > 0
	if total <= 0 then
		self.ClaimNumber.Text = "Claim $0"
		self.ContributorList.Text = ""
		return
	end

	self.ClaimNumber.Text = "Claim $" .. CoinFormat.Compact(total)
	local lines = {}
	for _, contributor in snapshot.PendingFriendRewardContributors or {} do
		table.insert(lines, string.format("%s +%s", contributor.Name, CoinFormat.Compact(contributor.Amount)))
	end
	self.ContributorList.Text = table.concat(lines, "\n")
end

function FriendRewardController:_claim()
	if self.ClaimRunning then
		return
	end
	self.ClaimRunning = true
	self.ClaimButton.Active = false
	self.ClaimButton.Interactable = false
	pcall(function()
		self.Remotes.ClaimFriendRewards:InvokeServer()
	end)
	self.ClaimButton.Active = true
	self.ClaimButton.Interactable = true
	self.ClaimRunning = false
end

function FriendRewardController:Init(remotes)
	self.Remotes = remotes
	self.ClaimRunning = false

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gameHUD = playerGui:WaitForChild("GameHUD")
	self.Frame = gameHUD:WaitForChild("HUDRoot"):WaitForChild("Friendcollection")
	self.ClaimButton = self.Frame:WaitForChild("ImageButton")
	self.ClaimNumber = self.ClaimButton:WaitForChild("number")
	self.ContributorList = self.Frame:WaitForChild("friend")
	assert(self.Frame:IsA("GuiObject"), "GameHUD.HUDRoot.Friendcollection must be a GuiObject")
	assert(self.ClaimButton:IsA("GuiButton"), "Friendcollection.ImageButton must be a GuiButton")
	assert(self.ClaimNumber:IsA("TextLabel"), "Friendcollection.ImageButton.number must be a TextLabel")
	assert(self.ContributorList:IsA("TextLabel"), "Friendcollection.friend must be a TextLabel")
	self.Frame.Visible = false

	self.ClaimButton.Activated:Connect(function()
		self:_claim()
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:_applySnapshot(snapshot)
	end)
end

return FriendRewardController

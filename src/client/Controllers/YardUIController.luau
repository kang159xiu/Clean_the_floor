local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModalPanelCoordinator = require(script.Parent.Parent.Effects.ModalPanelCoordinator)
local ModalPanelEffects = require(script.Parent.Parent.Effects.ModalPanelEffects)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)

local YardUIController = {}

local MODAL_PANEL_ID = "Invite"
local AVATAR_THUMBNAIL_TYPE = Enum.ThumbnailType.HeadShot
local AVATAR_THUMBNAIL_SIZE = Enum.ThumbnailSize.Size180x180

function YardUIController:Init(remotes)
	self.Remotes = remotes
	self.Player = Players.LocalPlayer
	self.PlayerRows = {}
	self.CurrentInvite = nil
	self.IsVisitingYard = false

	local playerGui = self.Player:WaitForChild("PlayerGui")
	local gameHUD = playerGui:WaitForChild("GameHUD")
	self.OpenButton = gameHUD:WaitForChild("Frame"):WaitForChild("invite")
	self.InvitePanel = gameHUD:WaitForChild("invite")
	self.CloseButton = self.InvitePanel:WaitForChild("Banner"):WaitForChild("Close")
	self.List = self.InvitePanel:WaitForChild("List")
	self.Template = self.List:WaitForChild("muban")
	self.Template.Visible = false
	self.GoHomeButton = self.InvitePanel:WaitForChild("GoHome")
	self.PoopPermissionButton = self.InvitePanel:WaitForChild("nodabian")
	self.PoopPermissionTitle = self.PoopPermissionButton:WaitForChild("allowed")
	assert(self.GoHomeButton:IsA("GuiButton"), "GameHUD.invite.GoHome must be a GuiButton")
	assert(self.PoopPermissionButton:IsA("GuiButton"), "GameHUD.invite.nodabian must be a GuiButton")
	assert(self.PoopPermissionTitle:IsA("TextLabel"), "GameHUD.invite.nodabian.allowed must be a TextLabel")
	self.AllowGuestPoop = true
	self.PoopPermissionBusy = false

	self.AcceptPanel = gameHUD:WaitForChild("accept")
	self.AcceptButton = self.AcceptPanel:WaitForChild("yes")
	self.RejectButton = self.AcceptPanel:WaitForChild("NO")
	self.AcceptTitle = self.AcceptPanel:WaitForChild("Title")
	self.AcceptIcon = self.AcceptPanel:WaitForChild("Icon")

	local friendCollection = gameHUD:WaitForChild("HUDRoot"):WaitForChild("Friendcollection")
	self.FriendCollection = friendCollection
	self.FriendClaimButton = friendCollection:WaitForChild("ImageButton")
	self.FriendClaimNumber = self.FriendClaimButton:WaitForChild("number")
	self.FriendList = friendCollection:WaitForChild("friend")
	self.FriendClaimBusy = false

	self.InvitePanel.Visible = false
	ModalPanelEffects.StopOpen(self.InvitePanel)
	ModalPanelEffects.BindOpenButton(self.OpenButton)
	self.AcceptPanel.Visible = false
	self.FriendCollection.Visible = false
	ModalPanelCoordinator.Register(MODAL_PANEL_ID, function()
		self:_setInvitePanelVisible(false)
	end)

	self.OpenButton.Activated:Connect(function()
		self:_setInvitePanelVisible(not self.InvitePanel.Visible)
	end)
	self.CloseButton.Activated:Connect(function()
		self:_setInvitePanelVisible(false)
	end)
	self.AcceptButton.Activated:Connect(function()
		self:_respondToCurrentInvite(true)
	end)
	self.RejectButton.Activated:Connect(function()
		self:_respondToCurrentInvite(false)
	end)
	self.FriendClaimButton.Activated:Connect(function()
		self:_claimFriendRewards()
	end)
	self.GoHomeButton.Activated:Connect(function()
		self:_returnHome()
	end)
	self.PoopPermissionButton.Activated:Connect(function()
		self:_togglePoopPermission()
	end)

	Players.PlayerAdded:Connect(function()
		self:_refreshPlayerRows()
	end)
	Players.PlayerRemoving:Connect(function(player)
		if self.CurrentInvite and self.CurrentInvite.InviterUserId == player.UserId then
			self:_hideAcceptPanel()
		end
		self:_refreshPlayerRows()
	end)

	remotes.YardInviteReceived.OnClientEvent:Connect(function(packet)
		self:_handleInvitePacket(packet)
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self.IsVisitingYard = snapshot.IsVisitingYard == true
		self.AllowGuestPoop = snapshot.AllowGuestPoop ~= false
		self:_renderYardControls()
		self:_applyFriendRewards(snapshot)
	end)

	self:_renderYardControls()
	self:_refreshPlayerRows()
end

function YardUIController:_renderYardControls()
	self.PoopPermissionTitle.Text = self.AllowGuestPoop and "Allowed" or "Blocked"
	self.GoHomeButton.Visible = self.IsVisitingYard == true
end

function YardUIController:_updateInputState()
	if self.InvitePanel.Visible or self.AcceptPanel.Visible then
		self.Remotes.SetLeafPickupActive:FireServer(false)
	end
end

function YardUIController:_setInvitePanelVisible(visible)
	local shouldBeVisible = visible == true
	local wasVisible = self.InvitePanel.Visible
	if shouldBeVisible then
		ModalPanelCoordinator.Open(MODAL_PANEL_ID)
	else
		ModalPanelCoordinator.Close(MODAL_PANEL_ID)
	end
	if shouldBeVisible and not wasVisible then
		ModalPanelEffects.PlayOpen(self.InvitePanel)
	elseif not shouldBeVisible then
		ModalPanelEffects.StopOpen(self.InvitePanel)
		self.InvitePanel.Visible = false
	end
	if self.InvitePanel.Visible then
		self:_refreshPlayerRows()
	end
	self:_updateInputState()
end

function YardUIController:_clearPlayerRows()
	for player, row in self.PlayerRows do
		self.PlayerRows[player] = nil
		row:Destroy()
	end
end

function YardUIController:_refreshPlayerRows()
	self:_clearPlayerRows()
	local candidates = {}
	for _, player in Players:GetPlayers() do
		if player ~= self.Player then
			table.insert(candidates, player)
		end
	end
	table.sort(candidates, function(left, right)
		local leftName = string.lower(left.DisplayName)
		local rightName = string.lower(right.DisplayName)
		if leftName == rightName then
			return left.UserId < right.UserId
		end
		return leftName < rightName
	end)

	for layoutOrder, player in candidates do
		local row = self.Template:Clone()
		row.Name = "Player_" .. player.UserId
		row.LayoutOrder = layoutOrder
		row.Visible = true
		local playerName = row:WaitForChild("name")
		local imageFrame = row:WaitForChild("Image")
		local icon = imageFrame:WaitForChild("Icon2")
		local inviteButton = row:WaitForChild("invite")
		local enterButton = row:WaitForChild("visit yard")
		assert(playerName:IsA("TextLabel"), "GameHUD.invite.List.muban.name must be a TextLabel")
		assert(imageFrame:IsA("GuiObject"), "GameHUD.invite.List.muban.Image must be a GuiObject")
		assert(icon:IsA("ImageLabel"), "GameHUD.invite.List.muban.Image.Icon2 must be an ImageLabel")
		assert(inviteButton:IsA("GuiButton"), "GameHUD.invite.List.muban.invite must be a GuiButton")
		assert(enterButton:IsA("GuiButton"), "GameHUD.invite.List.muban.visit yard must be a GuiButton")
		playerName.Text = player.DisplayName
		inviteButton.Activated:Connect(function()
			local success = self.Remotes.SendYardInvite:InvokeServer(player.UserId)
			if success then
				inviteButton.Active = false
				task.delay(3, function()
					if inviteButton.Parent then
						inviteButton.Active = true
					end
				end)
			end
		end)
		enterButton.Activated:Connect(function()
			enterButton.Active = false
			local success = self.Remotes.EnterYard:InvokeServer(player.UserId)
			enterButton.Active = true
			if success then
				self:_setInvitePanelVisible(false)
			end
		end)
		self.PlayerRows[player] = row
		row.Parent = self.List

		task.spawn(function()
			local image = Players:GetUserThumbnailAsync(
				player.UserId,
				AVATAR_THUMBNAIL_TYPE,
				AVATAR_THUMBNAIL_SIZE
			)
			if icon.Parent and self.PlayerRows[player] == row then
				icon.Image = image
			end
		end)
	end
end

function YardUIController:_returnHome()
	if not self.IsVisitingYard then
		return
	end
	self.GoHomeButton.Active = false
	local success = self.Remotes.LeaveVisitedYard:InvokeServer()
	self.GoHomeButton.Active = true
	if success then
		self:_setInvitePanelVisible(false)
	end
end

function YardUIController:_togglePoopPermission()
	if self.PoopPermissionBusy then
		return
	end
	self.PoopPermissionBusy = true
	self.PoopPermissionButton.Active = false
	local success, _, snapshot = self.Remotes.SetPoopPermission:InvokeServer(not self.AllowGuestPoop)
	if success and type(snapshot) == "table" then
		self.AllowGuestPoop = snapshot.AllowGuestPoop ~= false
	end
	self.PoopPermissionButton.Active = true
	self.PoopPermissionBusy = false
	self:_renderYardControls()
end

function YardUIController:_handleInvitePacket(packet)
	if type(packet) ~= "table" then
		return
	end
	if packet.Kind == "Cancel" then
		if self.CurrentInvite and self.CurrentInvite.InviteId == packet.InviteId then
			self:_hideAcceptPanel()
		end
		return
	end
	if
		packet.Kind ~= "Invite"
		or type(packet.InviteId) ~= "string"
		or type(packet.InviterUserId) ~= "number"
		or type(packet.InviterName) ~= "string"
	then
		return
	end

	self.CurrentInvite = packet
	self.AcceptTitle.Text = string.format(
		"%s invited you to clean %s's yard",
		packet.InviterName,
		packet.InviterName
	)
	self.AcceptPanel.Visible = true
	self:_updateInputState()
	task.spawn(function()
		local image = Players:GetUserThumbnailAsync(
			packet.InviterUserId,
			AVATAR_THUMBNAIL_TYPE,
			AVATAR_THUMBNAIL_SIZE
		)
		if self.CurrentInvite == packet and self.AcceptIcon.Parent then
			self.AcceptIcon.Image = image
		end
	end)
end

function YardUIController:_hideAcceptPanel()
	self.CurrentInvite = nil
	self.AcceptPanel.Visible = false
	self:_updateInputState()
end

function YardUIController:_respondToCurrentInvite(accepted)
	local invite = self.CurrentInvite
	if not invite then
		self:_hideAcceptPanel()
		return
	end
	self.AcceptButton.Active = false
	self.RejectButton.Active = false
	local success = self.Remotes.RespondYardInvite:InvokeServer(invite.InviteId, accepted == true)
	self.AcceptButton.Active = true
	self.RejectButton.Active = true
	self:_hideAcceptPanel()
	if success and accepted then
		self:_setInvitePanelVisible(false)
	end
end

function YardUIController:_applyFriendRewards(snapshot)
	local total = math.max(0, math.floor(tonumber(snapshot.PendingFriendRewardTotal) or 0))
	self.FriendCollection.Visible = total > 0
	if total <= 0 then
		self.FriendClaimNumber.Text = "Claim $0"
		self.FriendList.Text = ""
		return
	end

	self.FriendClaimNumber.Text = "Claim $" .. CoinFormat.Compact(total)
	local lines = {}
	for _, contributor in snapshot.PendingFriendRewardContributors or {} do
		table.insert(lines, string.format("%s +%s", contributor.Name, CoinFormat.Compact(contributor.Amount)))
	end
	self.FriendList.Text = table.concat(lines, "\n")
end

function YardUIController:_claimFriendRewards()
	if self.FriendClaimBusy then
		return
	end
	self.FriendClaimBusy = true
	self.FriendClaimButton.Active = false
	self.Remotes.ClaimFriendRewards:InvokeServer()
	self.FriendClaimButton.Active = true
	self.FriendClaimBusy = false
end

return YardUIController

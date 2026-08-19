local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local CoopMatchConfig = require(ReplicatedStorage.Shared.Config.CoopMatchConfig)

local PartyMatchmakingService = {}

local PAD_SCAN_INTERVAL = 0.2
local PAD_EXIT_PADDING = 4
local GATE_EJECT_DISTANCE = 3
local ACTION_COOLDOWN = 0.12

local function isAlivePlayer(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return humanoid ~= nil and humanoid.Health > 0 and root ~= nil and root:IsA("BasePart")
end

local function getRoot(player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function isPositionInsidePad(position, pad)
	local localPosition = pad.CFrame:PointToObjectSpace(position)
	local half = pad.Size * 0.5
	return math.abs(localPosition.X) <= half.X + PAD_EXIT_PADDING
		and math.abs(localPosition.Y) <= half.Y + 8
		and math.abs(localPosition.Z) <= half.Z + PAD_EXIT_PADDING
end

local function isInsidePad(player, pad)
	local root = getRoot(player)
	return root ~= nil and isPositionInsidePad(root.Position, pad)
end

local function memberUserIds(party)
	local result = table.create(#party.Members)
	for _, member in party.Members do
		result[#result + 1] = member.UserId
	end
	return result
end

function PartyMatchmakingService:_setGateCollision(party, enabled)
	for _, part in party.GateParts do
		if part.Parent then
			part.CanCollide = enabled
		end
	end
end

function PartyMatchmakingService:_ejectPlayerFromGate(player, party)
	local root = getRoot(player)
	if not root or not party.GateModel.Parent then
		return
	end
	local gateCFrame, gateSize = party.GateModel:GetBoundingBox()
	local localPosition = gateCFrame:PointToObjectSpace(root.Position)
	local half = gateSize * 0.5
	local x = localPosition.X
	local z = localPosition.Z
	local exitDirection = Vector3.xAxis
	local nearestDistance = math.abs(half.X - x)
	local side = "PositiveX"
	local candidates = {
		{ Distance = math.abs(-half.X - x), Side = "NegativeX" },
		{ Distance = math.abs(half.Z - z), Side = "PositiveZ" },
		{ Distance = math.abs(-half.Z - z), Side = "NegativeZ" },
	}
	for _, candidate in candidates do
		if candidate.Distance < nearestDistance then
			nearestDistance = candidate.Distance
			side = candidate.Side
		end
	end
	if side == "PositiveX" then
		x = half.X + GATE_EJECT_DISTANCE
	elseif side == "NegativeX" then
		x = -half.X - GATE_EJECT_DISTANCE
		exitDirection = -Vector3.xAxis
	elseif side == "PositiveZ" then
		z = half.Z + GATE_EJECT_DISTANCE
		exitDirection = Vector3.zAxis
	else
		z = -half.Z - GATE_EJECT_DISTANCE
		exitDirection = -Vector3.zAxis
	end
	local worldPosition = gateCFrame:PointToWorldSpace(Vector3.new(x, localPosition.Y, z))
	local worldExitDirection = gateCFrame:VectorToWorldSpace(exitDirection)
	for _ = 1, 32 do
		if not isPositionInsidePad(worldPosition, party.Pad) then
			break
		end
		worldPosition += worldExitDirection
	end
	root.CFrame = CFrame.new(worldPosition) * root.CFrame.Rotation
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

function PartyMatchmakingService:_movePlayerToPadFront(player, party)
	local root = getRoot(player)
	if not root or not party.Pad.Parent then
		return
	end
	local pad = party.Pad
	local forwardDistance = pad.Size.Z / 2 + PAD_EXIT_PADDING + GATE_EJECT_DISTANCE
	local rootHeight = math.max(3, root.Size.Y / 2 + 1)
	local localPosition = Vector3.new(0, pad.Size.Y / 2 + rootHeight, -forwardDistance)
	local worldPosition = pad.CFrame:PointToWorldSpace(localPosition)
	local lookTarget = Vector3.new(pad.Position.X, worldPosition.Y, pad.Position.Z)
	root.CFrame = CFrame.lookAt(worldPosition, lookTarget)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

function PartyMatchmakingService:_ejectOutsiders(party)
	for _, player in Players:GetPlayers() do
		if self.PartyByPlayer[player] ~= party and isInsidePad(player, party.Pad) then
			self:_ejectPlayerFromGate(player, party)
		end
	end
end

function PartyMatchmakingService:_refreshGateCollision(party)
	local shouldCollide = party.State == "Saving"
		or party.State == "Teleporting"
		or #party.Members >= party.TargetPlayerCount
	self:_setGateCollision(party, shouldCollide)
	if shouldCollide and party.GateClosed ~= true then
		self:_ejectOutsiders(party)
	end
	party.GateClosed = shouldCollide
end

function PartyMatchmakingService:_updateWorldDisplay(party)
	local cache = party.WorldDisplayCache
	local function setText(key, label, value)
		if label.Parent and cache[key] ~= value then
			cache[key] = value
			label.Text = value
		end
	end
	local function setVisible(key, label, visible)
		if label.Parent and cache[key] ~= visible then
			cache[key] = visible
			label.Visible = visible
		end
	end

	local denominator = if #party.Members > 0
		then party.TargetPlayerCount
		else CoopMatchConfig.DefaultTargetPlayerCount
	setText("PlayerCountText", party.WorldPlayerCountLabel, string.format("%d/%d", #party.Members, denominator))
	setText("DifficultyText", party.WorldDifficultyLabel, party.Difficulty)

	local countdownVisible = party.State == "Countdown"
	local countdownText = ""
	if countdownVisible then
		local deadline = tonumber(party.DeadlineServerTime) or Workspace:GetServerTimeNow()
		local seconds = math.max(0, math.ceil(deadline - Workspace:GetServerTimeNow()))
		countdownText = string.format("Starting in %ds", seconds)
	end
	setText("CountdownText", party.WorldCountdownLabel, countdownText)
	setVisible("CountdownVisible", party.WorldCountdownLabel, countdownVisible)
end

function PartyMatchmakingService:_makeSnapshot(party, recipient)
	local members = {}
	for index, member in party.Members do
		members[index] = {
			UserId = member.UserId,
			UserName = member.Name,
			DisplayName = member.DisplayName,
		}
	end
	return {
		Visible = true,
		PadId = party.PadId,
		PadNumber = party.PadNumber,
		HostUserId = party.Host and party.Host.UserId or 0,
		IsHost = party.Host == recipient,
		Members = members,
		CurrentPlayerCount = #party.Members,
		TargetPlayerCount = party.TargetPlayerCount,
		Difficulty = party.Difficulty,
		State = party.State,
		DeadlineServerTime = party.DeadlineServerTime,
	}
end

function PartyMatchmakingService:_pushParty(party)
	self:_refreshGateCollision(party)
	self:_updateWorldDisplay(party)
	for _, member in party.Members do
		if member.Parent == Players then
			self.PartySnapshot:FireClient(member, self:_makeSnapshot(party, member))
		end
	end
end

function PartyMatchmakingService:_removeMember(player, notifyClient)
	local party = self.PartyByPlayer[player]
	if not party then
		if notifyClient and player.Parent == Players then
			self.PartySnapshot:FireClient(player, { Visible = false })
		end
		return
	end
	self.PartyByPlayer[player] = nil
	for index, member in party.Members do
		if member == player then
			table.remove(party.Members, index)
			break
		end
	end
	if notifyClient and player.Parent == Players then
		self.PartySnapshot:FireClient(player, { Visible = false })
	end
	if party.Host == player then
		party.Host = party.Members[1]
	end
	if #party.Members == 0 then
		party.Host = nil
		party.TargetPlayerCount = CoopMatchConfig.DefaultTargetPlayerCount
		party.Difficulty = "EASY"
		party.State = "Waiting"
		party.DeadlineServerTime = nil
		party.ConfirmToken += 1
	else
		if party.State == "Saving" or party.State == "Teleporting" then
			party.State = "Waiting"
			party.DeadlineServerTime = nil
			party.ConfirmToken += 1
		end
	end
	self:_pushParty(party)
end

function PartyMatchmakingService:_addMember(player, party)
	if self.ExitSuppressedParty[player] == party
		or self.PartyByPlayer[player]
	then
		return false
	end
	if (party.State ~= "Waiting" and party.State ~= "Countdown")
		or #party.Members >= party.TargetPlayerCount
	then
		self:_ejectPlayerFromGate(player, party)
		return false
	end
	self.PartyByPlayer[player] = party
	party.Members[#party.Members + 1] = player
	party.Host = party.Host or player
	self:_pushParty(party)
	if party.State == "Countdown" and #party.Members >= party.TargetPlayerCount then
		self:_teleportParty(party, party.ConfirmToken)
	end
	return true
end

function PartyMatchmakingService:_cancelConfirm(party)
	party.ConfirmToken += 1
	party.State = "Waiting"
	party.DeadlineServerTime = nil
	self:_pushParty(party)
end

function PartyMatchmakingService:_restoreAfterTeleportFailure(party, message)
	party.State = "Waiting"
	party.DeadlineServerTime = nil
	party.ConfirmToken += 1
	for _, member in party.Members do
		if member.Parent == Players then
			self.PlayerDataService:Notify(member, message or "Match teleport failed. Please try again.")
		end
	end
	self:_pushParty(party)
end

function PartyMatchmakingService:_teleportParty(party, token)
	if party.ConfirmToken ~= token or party.State == "Teleporting" or #party.Members <= 0 then
		return
	end
	local members = {}
	for _, member in party.Members do
		if member.Parent == Players and self.PartyByPlayer[member] == party then
			members[#members + 1] = member
		end
	end
	if #members <= 0 then
		self:_cancelConfirm(party)
		return
	end

	party.State = "Saving"
	party.DeadlineServerTime = nil
	self:_pushParty(party)
	for _, member in members do
		local callSucceeded, saveSucceeded = pcall(function()
			return self.PlayerDataService:SavePlayerNow(member)
		end)
		if not callSucceeded or saveSucceeded ~= true then
			self:_restoreAfterTeleportFailure(party, "Could not save every player. Match cancelled; please try again.")
			return
		end
	end
	if party.ConfirmToken ~= token then
		return
	end

	local matchId = HttpService:GenerateGUID(false)
	local teleportData = {
		Version = CoopMatchConfig.ProtocolVersion,
		MatchId = matchId,
		LobbyServerInstanceId = game.JobId,
		Difficulty = party.Difficulty,
		MemberUserIds = memberUserIds(party),
		TargetPlayerCount = party.TargetPlayerCount,
		PadId = party.PadId,
		PadNumber = party.PadNumber,
	}
	local options = Instance.new("TeleportOptions")
	options.ShouldReserveServer = true
	options:SetTeleportData(teleportData)
	party.State = "Teleporting"
	party.MatchId = matchId
	self:_pushParty(party)
	local succeeded, teleportError = pcall(function()
		TeleportService:TeleportAsync(CoopMatchConfig.CoopPlaceId, members, options)
	end)
	if not succeeded then
		warn(string.format("[PartyMatchmaking] %s teleport failed: %s", party.PadId, tostring(teleportError)))
		self:_restoreAfterTeleportFailure(party, "Match teleport failed. Please try again.")
	end
end

function PartyMatchmakingService:_confirm(party)
	party.ConfirmToken += 1
	local token = party.ConfirmToken
	if #party.Members >= party.TargetPlayerCount then
		self:_teleportParty(party, token)
		return
	end
	party.State = "Countdown"
	party.DeadlineServerTime = Workspace:GetServerTimeNow() + CoopMatchConfig.ConfirmCountdownSeconds
	self:_pushParty(party)
	task.delay(CoopMatchConfig.ConfirmCountdownSeconds, function()
		if party.ConfirmToken == token and party.State == "Countdown" then
			party.DeadlineServerTime = Workspace:GetServerTimeNow()
			self:_updateWorldDisplay(party)
			task.delay(PAD_SCAN_INTERVAL, function()
				if party.ConfirmToken == token and party.State == "Countdown" then
					self:_teleportParty(party, token)
				end
			end)
		end
	end)
end

function PartyMatchmakingService:_handleAction(player, action, value)
	local now = os.clock()
	if now - (self.LastActionAt[player] or -math.huge) < ACTION_COOLDOWN then
		return false, "Too fast."
	end
	self.LastActionAt[player] = now
	if action == "Leave" then
		local party = self.PartyByPlayer[player]
		self.ExitSuppressedParty[player] = party
		self:_removeMember(player, true)
		if party then
			self:_movePlayerToPadFront(player, party)
		end
		return true
	end
	local party = self.PartyByPlayer[player]
	if not party then
		return false, "You are not in a party."
	end
	if party.Host ~= player then
		return false, "Only the host can change match settings."
	end
	if party.State ~= "Waiting" then
		return false, "The match is already starting."
	end
	if action == "SetTarget" then
		local minimumTarget = math.max(1, #party.Members)
		local target = math.clamp(
			math.floor(tonumber(value) or 0),
			minimumTarget,
			CoopMatchConfig.MaximumPartySize
		)
		party.TargetPlayerCount = target
		self:_pushParty(party)
		return true
	elseif action == "SetDifficulty" then
		if type(value) ~= "string" or not CoopMatchConfig.DifficultyMultipliers[value] then
			return false, "Invalid difficulty."
		end
		party.Difficulty = value
		self:_pushParty(party)
		return true
	elseif action == "Confirm" then
		self:_confirm(party)
		return true
	end
	return false, "Invalid party action."
end

function PartyMatchmakingService:_scanMembership()
	for player, party in self.PartyByPlayer do
		if party.State ~= "Saving"
			and party.State ~= "Teleporting"
			and (player.Parent ~= Players or not isInsidePad(player, party.Pad))
		then
			self:_removeMember(player, player.Parent == Players)
		end
	end
	for _, player in Players:GetPlayers() do
		local suppressedParty = self.ExitSuppressedParty[player]
		if suppressedParty and not isInsidePad(player, suppressedParty.Pad) then
			self.ExitSuppressedParty[player] = nil
			suppressedParty = nil
		end
		if not suppressedParty and not self.PartyByPlayer[player] and isAlivePlayer(player) and self.PlayerDataService:GetState(player) then
			for _, padId in CoopMatchConfig.PadIds do
				local party = self.Parties[padId]
				if isInsidePad(player, party.Pad) then
					self:_addMember(player, party)
					break
				end
			end
		end
	end
end

function PartyMatchmakingService:Init(playerDataService, remotes)
	self.PlayerDataService = playerDataService
	self.RequestPartyAction = remotes.RequestPartyAction
	self.PartySnapshot = remotes.PartySnapshot
	self.Parties = {}
	self.PartyByPlayer = {}
	self.LastActionAt = {}
	self.ExitSuppressedParty = {}

	local functionFolder = Workspace:WaitForChild("Function")
	for padNumber, padId in CoopMatchConfig.PadIds do
		local pad = functionFolder:WaitForChild(padId)
		assert(pad:IsA("BasePart"), pad:GetFullName() .. " must be a BasePart")
		local joinPart = pad:WaitForChild("join")
		assert(joinPart:IsA("BasePart"), padId .. ".join must be a BasePart")
		local worldBillboard = joinPart:WaitForChild("BillboardGui")
		assert(worldBillboard:IsA("BillboardGui"), padId .. ".join.BillboardGui is missing")
		local worldFrame = worldBillboard:WaitForChild("Frame")
		assert(worldFrame:IsA("Frame"), padId .. " world status Frame is missing")
		local playerCountLabel = worldFrame:WaitForChild("04")
		local difficultyLabel = worldFrame:WaitForChild("easy")
		local countdownLabel = worldFrame:WaitForChild("TextLabel")
		assert(playerCountLabel:IsA("TextLabel"), padId .. " world player count label is missing")
		assert(difficultyLabel:IsA("TextLabel"), padId .. " world difficulty label is missing")
		assert(countdownLabel:IsA("TextLabel"), padId .. " world countdown label is missing")
		local base = pad:WaitForChild("底座")
		local gateModel = nil
		for _, child in base:GetChildren() do
			if child.Name == "Group" and child:IsA("Model") then
				gateModel = child
				break
			end
		end
		assert(gateModel and gateModel:IsA("Model"), padId .. " gate Group [Model] is missing")
		local gateParts = {}
		for _, descendant in gateModel:GetDescendants() do
			if descendant:IsA("Part") then
				gateParts[#gateParts + 1] = descendant
			end
		end
		local party = {
			Pad = pad,
			PadId = padId,
			PadNumber = padNumber,
			WorldPlayerCountLabel = playerCountLabel,
			WorldDifficultyLabel = difficultyLabel,
			WorldCountdownLabel = countdownLabel,
			WorldDisplayCache = {},
			GateModel = gateModel,
			GateParts = gateParts,
			GateClosed = false,
			Members = {},
			Host = nil,
			TargetPlayerCount = CoopMatchConfig.DefaultTargetPlayerCount,
			Difficulty = "EASY",
			State = "Waiting",
			DeadlineServerTime = nil,
			ConfirmToken = 0,
		}
		self.Parties[padId] = party
		self:_refreshGateCollision(party)
		self:_updateWorldDisplay(party)
		pad.Touched:Connect(function(hit)
			local character = hit and hit:FindFirstAncestorOfClass("Model")
			local player = character and Players:GetPlayerFromCharacter(character)
			if player and isAlivePlayer(player) and self.PlayerDataService:GetState(player) then
				self:_addMember(player, party)
			end
		end)
	end

	self.RequestPartyAction.OnServerInvoke = function(player, action, value)
		if type(action) ~= "string" or #action > 24 then
			return false, "Invalid party action."
		end
		return self:_handleAction(player, action, value)
	end
	TeleportService.TeleportInitFailed:Connect(function(player, _, errorMessage, placeId, teleportOptions)
		if placeId ~= CoopMatchConfig.CoopPlaceId then
			return
		end
		local party = self.PartyByPlayer[player]
		if party and party.State == "Teleporting" then
			warn(string.format("[PartyMatchmaking] teleport init failed for %s: %s", player.Name, tostring(errorMessage)))
			self:_restoreAfterTeleportFailure(party, "Match teleport failed. Please try again.")
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		self.LastActionAt[player] = nil
		self.ExitSuppressedParty[player] = nil
		self:_removeMember(player, false)
	end)
	task.spawn(function()
		while true do
			task.wait(PAD_SCAN_INTERVAL)
			self:_scanMembership()
			for _, padId in CoopMatchConfig.PadIds do
				self:_updateWorldDisplay(self.Parties[padId])
			end
		end
	end)
end

return PartyMatchmakingService

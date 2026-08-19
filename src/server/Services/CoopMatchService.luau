local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local CoopMatchConfig = require(ReplicatedStorage.Shared.Config.CoopMatchConfig)

local CoopMatchService = {}

local context = nil
local admissionBound = false
local admittedPlayers = {}
local activeService = nil

local function containsUserId(list, userId)
	if type(list) ~= "table" then
		return false
	end
	for _, value in list do
		if math.floor(tonumber(value) or 0) == userId then
			return true
		end
	end
	return false
end

local function sanitizeMemberUserIds(raw)
	local result = {}
	local seen = {}
	if type(raw) ~= "table" then
		return result
	end
	for _, value in raw do
		local userId = math.floor(tonumber(value) or 0)
		local validUserId = userId > 0 or RunService:IsStudio() and userId ~= 0
		if validUserId and not seen[userId] and #result < CoopMatchConfig.MaximumPartySize then
			seen[userId] = true
			result[#result + 1] = userId
		end
	end
	return result
end

local function sanitizeServerInstanceId(value)
	if type(value) ~= "string" or #value < 1 or #value > 128 then
		return nil
	end
	if not string.match(value, "^[%w%-]+$") then
		return nil
	end
	return value
end

local function returnIllegalPlayer(player)
	task.spawn(function()
		local succeeded, teleportError = pcall(function()
			TeleportService:TeleportAsync(CoopMatchConfig.LobbyPlaceId, { player })
		end)
		if not succeeded and player.Parent == Players then
			warn(string.format("[CoopMatch] could not return illegal direct join %s: %s", player.Name, tostring(teleportError)))
			player:Kick("This match can only be entered through the lobby.")
		end
	end)
end

local function admitPlayer(player)
	if not CoopMatchConfig.IsCoop() then
		return false
	end
	if RunService:IsStudio() then
		if not context then
			context = {
				Version = CoopMatchConfig.ProtocolVersion,
				MatchId = "Studio-" .. game.JobId,
				Difficulty = "EASY",
				MemberUserIds = { player.UserId },
				TargetPlayerCount = 1,
				PadId = "place001",
				PadNumber = 1,
				LobbyServerInstanceId = nil,
				StudioSynthetic = true,
			}
		elseif not containsUserId(context.MemberUserIds, player.UserId) then
			context.MemberUserIds[#context.MemberUserIds + 1] = player.UserId
		end
		admittedPlayers[player] = true
		if activeService then
			activeService:_synchronizeContext(context)
		end
		return true
	end

	local joinData = player:GetJoinData()
	local teleportData = joinData and joinData.TeleportData or nil
	local memberIds = sanitizeMemberUserIds(type(teleportData) == "table" and teleportData.MemberUserIds or nil)
	local matchId = type(teleportData) == "table" and teleportData.MatchId or nil
	local valid = joinData.SourcePlaceId == CoopMatchConfig.LobbyPlaceId
		and game.PrivateServerId ~= ""
		and game.PrivateServerOwnerId == 0
		and type(teleportData) == "table"
		and math.floor(tonumber(teleportData.Version) or 0) == CoopMatchConfig.ProtocolVersion
		and type(matchId) == "string"
		and #matchId >= 8
		and #matchId <= 96
		and containsUserId(memberIds, player.UserId)
	if context then
		valid = valid
			and context.MatchId == matchId
			and containsUserId(context.MemberUserIds, player.UserId)
	end
	if not valid then
		returnIllegalPlayer(player)
		return false
	end
	if not context then
		context = {
			Version = CoopMatchConfig.ProtocolVersion,
			MatchId = matchId,
			Difficulty = CoopMatchConfig.NormalizeDifficulty(teleportData.Difficulty),
			MemberUserIds = memberIds,
			TargetPlayerCount = math.clamp(
				math.floor(tonumber(teleportData.TargetPlayerCount) or #memberIds),
				1,
				CoopMatchConfig.MaximumPartySize
			),
			PadId = type(teleportData.PadId) == "string" and string.sub(teleportData.PadId, 1, 24) or "place001",
			PadNumber = math.clamp(math.floor(tonumber(teleportData.PadNumber) or 1), 1, 4),
			LobbyServerInstanceId = sanitizeServerInstanceId(teleportData.LobbyServerInstanceId),
		}
	end
	admittedPlayers[player] = true
	if activeService then
		activeService:_synchronizeContext(context)
	end
	return true
end

function CoopMatchService.PrepareAdmission()
	if admissionBound or not CoopMatchConfig.IsCoop() then
		return
	end
	admissionBound = true
	Players.PlayerAdded:Connect(admitPlayer)
	Players.PlayerRemoving:Connect(function(player)
		admittedPlayers[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		admitPlayer(player)
	end
end

function CoopMatchService:GetContext()
	return context
end

function CoopMatchService:IsAdmitted(player)
	return admittedPlayers[player] == true
end

function CoopMatchService:_synchronizeContext(authoritativeContext)
	if type(authoritativeContext) ~= "table" then
		return false
	end
	local memberUserIds = sanitizeMemberUserIds(authoritativeContext.MemberUserIds)
	if #memberUserIds <= 0 then
		return false
	end

	local synchronizedContext = table.clone(authoritativeContext)
	synchronizedContext.Difficulty = CoopMatchConfig.NormalizeDifficulty(authoritativeContext.Difficulty)
	synchronizedContext.MemberUserIds = memberUserIds
	self.Context = synchronizedContext
	table.clear(self.ExpectedUserIds)
	for _, userId in memberUserIds do
		self.ExpectedUserIds[userId] = true
	end

	if self.LeafService then
		local difficultyApplied = self.LeafService:SetCoopDifficulty(synchronizedContext.Difficulty)
		if
			not difficultyApplied
			and self.LeafService.CoopDifficulty ~= synchronizedContext.Difficulty
		then
			warn(string.format(
				"[CoopMatch] could not apply difficulty %s before the shared yard was created",
				synchronizedContext.Difficulty
			))
		end
	end
	return true
end

function CoopMatchService:_hideLobbyWorldFeatures()
	local functionFolder = Workspace:FindFirstChild("Function")
	if functionFolder then
		for _, padId in CoopMatchConfig.PadIds do
			local pad = functionFolder:FindFirstChild(padId)
			local billboard = pad and pad:FindFirstChild("BillboardGui", true)
			if billboard and billboard:IsA("BillboardGui") then
				billboard.Enabled = false
			end
		end
		local reset = functionFolder:FindFirstChild("Reset")
		if reset then
			for _, descendant in reset:GetDescendants() do
				if descendant:IsA("ProximityPrompt") then
					descendant.Enabled = false
				end
			end
		end
	end
	for areaNumber = 1, 8 do
		local area = Workspace:FindFirstChild(string.format("Area_%02d", areaNumber))
		if area then
			for _, descendant in area:GetDescendants() do
				if descendant:IsA("SurfaceGui") and descendant.Name == "rebirth" then
					descendant.Enabled = false
				end
			end
		end
	end
end

function CoopMatchService:_getArrivedCount()
	local count = 0
	for userId in self.ArrivedUserIds do
		if self.ExpectedUserIds[userId] then
			count += 1
		end
	end
	return count
end

function CoopMatchService:_ensureArrivalGraceTimer()
	if self.State ~= "Waiting" or self.ArrivalGraceToken ~= nil or self:_getArrivedCount() <= 0 then
		return
	end
	local token = {}
	self.ArrivalGraceToken = token
	task.delay(CoopMatchConfig.ArrivalGraceSeconds, function()
		if self.ArrivalGraceToken ~= token then
			return
		end
		self.ArrivalGraceToken = nil
		self:_startMatch()
	end)
end

function CoopMatchService:_makeRanking()
	local ranking = {}
	for userId in self.ArrivedUserIds do
		local score = self.Scores[userId] or {}
		ranking[#ranking + 1] = {
			UserId = userId,
			UserName = score.UserName or "Player",
			Pieces = math.max(0, math.floor(tonumber(score.Pieces) or 0)),
			Coins = math.max(0, math.floor(tonumber(score.Coins) or 0)),
		}
	end
	table.sort(ranking, function(left, right)
		if left.Coins ~= right.Coins then
			return left.Coins > right.Coins
		end
		if left.Pieces ~= right.Pieces then
			return left.Pieces > right.Pieces
		end
		return left.UserId < right.UserId
	end)
	return ranking
end

function CoopMatchService:_makeSnapshot(returnStatus)
	return {
		Version = CoopMatchConfig.ProtocolVersion,
		MatchId = self.Context.MatchId,
		Difficulty = self.Context.Difficulty,
		State = self.State,
		ExpectedPlayerCount = #self.Context.MemberUserIds,
		ArrivedPlayerCount = self:_getArrivedCount(),
		StartServerTime = self.StartServerTime,
		CompletionSeconds = self.CompletionSeconds,
		Ranking = if self.State == "Completed" then self:_makeRanking() else nil,
		ReturnStatus = returnStatus,
	}
end

function CoopMatchService:_pushSnapshot(player, returnStatus)
	if player.Parent == Players and self:IsAdmitted(player) then
		self.CoopMatchSnapshot:FireClient(player, self:_makeSnapshot(returnStatus))
	end
end

function CoopMatchService:_pushAll()
	for _, player in Players:GetPlayers() do
		self:_pushSnapshot(player)
	end
end

function CoopMatchService:_startMatch()
	if self.State ~= "Waiting" or self:_getArrivedCount() <= 0 then
		return
	end
	self.ArrivalGraceToken = nil
	self.State = "Playing"
	self.StartServerTime = Workspace:GetServerTimeNow()
	self.LeafService:SetCoopGameplayEnabled(true)
	self.PoopService:SetCoopGameplayEnabled(true)
	self:_pushAll()
end

function CoopMatchService:_finishMatch()
	if self.State ~= "Playing" then
		return
	end
	self.State = "Completing"
	self.LeafService:SetCoopGameplayEnabled(false)
	self.PoopService:SetCoopGameplayEnabled(false)
	for _, player in Players:GetPlayers() do
		if self:IsAdmitted(player) then
			self.CleaningToolActionService:StopPlayer(player)
			local succeeded, recycleError = pcall(function()
				self.RecycleService:TryQuickSell(player)
			end)
			if not succeeded then
				warn(string.format("[CoopMatch] completion recycle failed for %s: %s", player.Name, tostring(recycleError)))
			end
		end
	end
	self.CompletionSeconds = math.max(0, Workspace:GetServerTimeNow() - (self.StartServerTime or Workspace:GetServerTimeNow()))
	self.State = "Completed"
	self:_pushAll()
end

function CoopMatchService:_onPlayerStateReady(player)
	self:_synchronizeContext(context)
	if not self:IsAdmitted(player) then
		return
	end
	if not self.ExpectedUserIds[player.UserId] then
		return
	end
	self.ArrivedUserIds[player.UserId] = true
	self.Scores[player.UserId] = self.Scores[player.UserId] or {
		UserName = player.Name,
		Pieces = 0,
		Coins = 0,
	}
	self:_pushAll()
	if self.State == "Waiting" then
		if self:_getArrivedCount() >= #self.Context.MemberUserIds then
			self:_startMatch()
		else
			self:_ensureArrivalGraceTimer()
		end
	end
end

function CoopMatchService:_finishReturnFailure(player, record, message)
	if self.ReturnLocks[player] ~= record then
		return
	end
	self.ReturnLocks[player] = nil
	warn(string.format("[CoopMatch] return teleport failed for %s: %s", player.Name, tostring(message)))
	self:_pushSnapshot(player, "TeleportFailed")
end

function CoopMatchService:_startLobbyTeleport(player, record, preferOriginalServer)
	if self.ReturnLocks[player] ~= record or player.Parent ~= Players then
		return false
	end

	local originalServerInstanceId = record.OriginalServerInstanceId
	local useOriginalServer = preferOriginalServer == true
		and type(originalServerInstanceId) == "string"
		and originalServerInstanceId ~= ""
	local teleportOptions = Instance.new("TeleportOptions")
	if useOriginalServer then
		teleportOptions.ServerInstanceId = originalServerInstanceId
	end
	record.Phase = if useOriginalServer then "OriginalServer" else "FallbackServer"
	record.TeleportOptions = teleportOptions

	local teleportSucceeded, teleportError = pcall(function()
		TeleportService:TeleportAsync(CoopMatchConfig.LobbyPlaceId, { player }, teleportOptions)
	end)
	if teleportSucceeded then
		return true
	end
	if self.ReturnLocks[player] ~= record then
		return false
	end
	if useOriginalServer then
		warn(string.format(
			"[CoopMatch] original lobby return failed for %s; using fallback: %s",
			player.Name,
			tostring(teleportError)
		))
		return self:_startLobbyTeleport(player, record, false)
	end
	self:_finishReturnFailure(player, record, teleportError)
	return false
end

function CoopMatchService:_onReturnTeleportInitFailed(player, placeId, teleportOptions, errorMessage)
	if placeId ~= CoopMatchConfig.LobbyPlaceId then
		return
	end
	local record = self.ReturnLocks[player]
	if not record or (teleportOptions and record.TeleportOptions ~= teleportOptions) then
		return
	end
	if record.Phase == "OriginalServer" then
		task.defer(function()
			if self.ReturnLocks[player] == record and player.Parent == Players then
				self:_startLobbyTeleport(player, record, false)
			end
		end)
		return
	end
	if record.Phase == "FallbackServer" then
		self:_finishReturnFailure(player, record, errorMessage)
	end
end

function CoopMatchService:_requestReturn(player)
	if not self:IsAdmitted(player) or player.Parent ~= Players then
		return { Status = "Unavailable" }
	end
	if self.ReturnLocks[player] then
		return { Status = "Busy" }
	end
	local returnRecord = {
		Phase = "Saving",
		OriginalServerInstanceId = self.Context.LobbyServerInstanceId,
		TeleportOptions = nil,
	}
	self.ReturnLocks[player] = returnRecord
	local saveSucceeded = false
	local callSucceeded, result = pcall(function()
		return self.PlayerDataService:SavePlayerNow(player)
	end)
	if callSucceeded then
		saveSucceeded = result == true
	end
	if not saveSucceeded then
		if self.ReturnLocks[player] == returnRecord then
			self.ReturnLocks[player] = nil
		end
		return { Status = "SaveFailed" }
	end
	if not self:_startLobbyTeleport(player, returnRecord, true) then
		return { Status = "TeleportFailed" }
	end
	return { Status = "Teleporting" }
end

function CoopMatchService:Init(playerDataService, leafService, recycleService, cleaningToolActionService, poopService, remotes)
	assert(CoopMatchConfig.IsCoop(), "CoopMatchService can only initialize in CoopMatch")
	self.Context = context or {
		Version = CoopMatchConfig.ProtocolVersion,
		MatchId = "Fallback-" .. game.JobId,
		Difficulty = "EASY",
		MemberUserIds = {},
		TargetPlayerCount = 1,
		PadId = "place001",
		PadNumber = 1,
		LobbyServerInstanceId = nil,
	}
	self.PlayerDataService = playerDataService
	self.LeafService = leafService
	self.RecycleService = recycleService
	self.CleaningToolActionService = cleaningToolActionService
	self.PoopService = poopService
	self.CoopMatchSnapshot = remotes.CoopMatchSnapshot
	self.RequestCoopReturn = remotes.RequestCoopReturn
	self.State = "Waiting"
	self.ExpectedUserIds = {}
	self.ArrivedUserIds = {}
	self.Scores = {}
	self.ReturnLocks = {}
	self.ArrivalGraceToken = nil
	activeService = self
	self:_synchronizeContext(context)
	self:_hideLobbyWorldFeatures()
	leafService:SetCoopDifficulty(self.Context.Difficulty)
	leafService:SetCoopGameplayEnabled(false)
	poopService:SetCoopGameplayEnabled(false)
	leafService:AddLeafCollectedHandler(function(player, areaId)
		if self.State ~= "Playing" or not self:IsAdmitted(player) or areaId == "Lobby" then
			return
		end
		local score = self.Scores[player.UserId]
		if score then
			score.Pieces += 1
		end
	end)
	leafService:AddAreaCompletedHandler(function(_, areaId)
		if areaId == "Area_08" then
			task.spawn(function()
				self:_finishMatch()
			end)
		end
	end)
	recycleService:AddRecycleCompletedHandler(function(player, _, _, awardedCoins)
		if not self:IsAdmitted(player) then
			return
		end
		local score = self.Scores[player.UserId]
		if score then
			score.Coins += math.max(0, math.floor(tonumber(awardedCoins) or 0))
		end
	end)
	playerDataService:AddPlayerStateReadyHandler(function(player)
		self:_onPlayerStateReady(player)
	end)
	self.RequestCoopReturn.OnServerInvoke = function(player)
		return self:_requestReturn(player)
	end
	TeleportService.TeleportInitFailed:Connect(function(player, _, errorMessage, placeId, teleportOptions)
		self:_onReturnTeleportInitFailed(player, placeId, teleportOptions, errorMessage)
	end)
	self.CoopMatchSnapshot.OnServerEvent:Connect(function(player)
		self:_pushSnapshot(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self.ReturnLocks[player] = nil
		if self.ArrivedUserIds[player.UserId] then
			self.ArrivedUserIds[player.UserId] = nil
			if self.State == "Waiting" then
				task.defer(function()
					self:_pushAll()
				end)
			end
		end
	end)
	for _, player in Players:GetPlayers() do
		if playerDataService:GetState(player) then
			self:_onPlayerStateReady(player)
		end
	end
end

return CoopMatchService

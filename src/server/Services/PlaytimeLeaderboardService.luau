local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local LeaderboardDataStoreUtil = require(script.Parent.LeaderboardDataStoreUtil)
local LeaderboardUsernameResolver = require(script.Parent.LeaderboardUsernameResolver)

local PlaytimeLeaderboardService = {}

local PLAYTIME_STORE_NAME = "CleanTheFloor_Playtime_v1"
local ORDERED_STORE_NAME = "CleanTheFloor_PlaytimeLeaderboard_v1"
local ENTRY_KEY_PREFIX = "Player_"
local PLAYTIME_VERSION = 1
local TOP_ENTRY_LIMIT = 20
local REFRESH_INTERVAL = 60
local REFRESH_PHASE = 5
local SNAPSHOT_REQUEST_INTERVAL = 1
local MAX_SESSION_CHECKPOINTS = 32
local MAX_TIME_SECONDS = 1_000_000_000

local playtimeStore = DataStoreService:GetDataStore(PLAYTIME_STORE_NAME)
local orderedStore = DataStoreService:GetOrderedDataStore(ORDERED_STORE_NAME)

local function normalizeWholeSeconds(value)
	local numeric = tonumber(value)
	if not numeric or numeric ~= numeric or numeric < 0 or numeric == math.huge then
		return 0
	end
	return math.clamp(math.floor(numeric + 0.5), 0, MAX_TIME_SECONDS)
end

local function normalizePositiveSeconds(value)
	local seconds = normalizeWholeSeconds(value)
	return if seconds > 0 then seconds else nil
end

local function normalizeTimestamp(value)
	local numeric = tonumber(value)
	if not numeric or numeric ~= numeric or numeric < 0 or numeric == math.huge then
		return 0
	end
	return math.floor(numeric)
end

local function getEntryKey(userId)
	return ENTRY_KEY_PREFIX .. tostring(math.max(1, math.floor(tonumber(userId) or 0)))
end

local function getUserIdFromEntryKey(entryKey)
	if type(entryKey) ~= "string" then
		return nil
	end
	local userId = tonumber(string.match(entryKey, "^" .. ENTRY_KEY_PREFIX .. "(%d+)$"))
	return if userId and userId > 0 then math.floor(userId) else nil
end

local function normalizePlaytimeRecord(rawRecord)
	local source = type(rawRecord) == "table" and rawRecord or {}
	local checkpoints = {}
	local checkpointById = {}
	if type(source.SessionCheckpoints) == "table" then
		for _, rawCheckpoint in ipairs(source.SessionCheckpoints) do
			local sessionId = type(rawCheckpoint) == "table" and rawCheckpoint.Id or nil
			if type(sessionId) == "string" and sessionId ~= "" and #sessionId <= 128 then
				local checkpoint = {
					Id = sessionId,
					Seconds = normalizeWholeSeconds(rawCheckpoint.Seconds),
					UpdatedAt = normalizeTimestamp(rawCheckpoint.UpdatedAt),
				}
				local previous = checkpointById[sessionId]
				if
					not previous
					or checkpoint.Seconds > previous.Seconds
					or checkpoint.UpdatedAt > previous.UpdatedAt
				then
					checkpointById[sessionId] = checkpoint
				end
			end
		end
	end
	for _, checkpoint in checkpointById do
		table.insert(checkpoints, checkpoint)
	end
	table.sort(checkpoints, function(left, right)
		if left.UpdatedAt == right.UpdatedAt then
			return left.Id < right.Id
		end
		return left.UpdatedAt > right.UpdatedAt
	end)
	while #checkpoints > MAX_SESSION_CHECKPOINTS do
		table.remove(checkpoints)
	end
	return {
		Version = PLAYTIME_VERSION,
		TotalSeconds = normalizeWholeSeconds(source.TotalSeconds),
		SessionCheckpoints = checkpoints,
	}
end

local function getCheckpointSeconds(record, sessionId)
	for _, checkpoint in record.SessionCheckpoints do
		if checkpoint.Id == sessionId then
			return checkpoint.Seconds
		end
	end
	return 0
end

local function setCheckpoint(record, sessionId, elapsedSeconds)
	local otherCheckpoints = {}
	for _, checkpoint in record.SessionCheckpoints do
		if checkpoint.Id ~= sessionId then
			table.insert(otherCheckpoints, checkpoint)
		end
	end
	table.sort(otherCheckpoints, function(left, right)
		if left.UpdatedAt == right.UpdatedAt then
			return left.Id < right.Id
		end
		return left.UpdatedAt > right.UpdatedAt
	end)
	local checkpoints = {
		{
			Id = sessionId,
			Seconds = elapsedSeconds,
			UpdatedAt = os.time(),
		},
	}
	for index = 1, math.min(#otherCheckpoints, MAX_SESSION_CHECKPOINTS - 1) do
		table.insert(checkpoints, otherCheckpoints[index])
	end
	record.SessionCheckpoints = checkpoints
end

function PlaytimeLeaderboardService:_copyEntries()
	local entries = table.create(#self.TopEntries)
	for index, entry in self.TopEntries do
		entries[index] = {
			UserId = entry.UserId,
			UserName = entry.UserName,
			TimeSeconds = entry.TimeSeconds,
			Rank = entry.Rank,
		}
	end
	return entries
end

function PlaytimeLeaderboardService:_getSessionElapsed(session)
	return normalizeWholeSeconds(math.floor(math.max(0, os.clock() - session.StartedClock)))
end

function PlaytimeLeaderboardService:_getLiveTotal(session)
	local elapsedSeconds = self:_getSessionElapsed(session)
	local uncommittedSeconds = math.max(0, elapsedSeconds - session.CommittedSessionSeconds)
	return normalizeWholeSeconds(session.TotalSeconds + uncommittedSeconds)
end

function PlaytimeLeaderboardService:_buildSnapshot(player)
	local session = self.Sessions[player]
	local totalSeconds = session and normalizePositiveSeconds(self:_getLiveTotal(session)) or nil
	local topRank = self.TopRankByUserId[player.UserId]
	return {
		Entries = self:_copyEntries(),
		Self = {
			UserName = player.Name,
			TimeSeconds = totalSeconds,
			RankText = if topRank then "#" .. tostring(topRank) elseif totalSeconds then "#20+" else "#--",
		},
	}
end

function PlaytimeLeaderboardService:_sendToPlayer(player)
	if player.Parent == Players then
		self.SnapshotRemote:FireClient(player, self:_buildSnapshot(player))
	end
end

function PlaytimeLeaderboardService:_broadcast()
	for _, player in Players:GetPlayers() do
		self:_sendToPlayer(player)
	end
end

function PlaytimeLeaderboardService:_refreshTopEntries()
	local success, pageOrError, failureKind = LeaderboardDataStoreUtil.TryRequest(
		Enum.DataStoreRequestType.GetSortedAsync,
		function()
			local pages = orderedStore:GetSortedAsync(false, TOP_ENTRY_LIMIT)
			return pages:GetCurrentPage()
		end
	)
	if failureKind == "Budget" then
		LeaderboardDataStoreUtil.WarnBudgetThrottled(
			self.BudgetWarningTimes,
			"Refresh",
			"Playtime leaderboard refresh is waiting for GetSortedAsync budget."
		)
		return false, "Budget"
	end
	if not success then
		warn("Playtime leaderboard refresh failed: " .. tostring(pageOrError))
		return false, "Request"
	end

	local candidates = {}
	local userIds = {}
	for _, rawEntry in pageOrError do
		local userId = getUserIdFromEntryKey(rawEntry.key)
		local timeSeconds = normalizePositiveSeconds(rawEntry.value)
		if userId and timeSeconds then
			local rank = #candidates + 1
			table.insert(candidates, {
				UserId = userId,
				TimeSeconds = timeSeconds,
				Rank = rank,
			})
			table.insert(userIds, userId)
		end
	end
	local resolutions = LeaderboardUsernameResolver.ResolveMany(userIds)
	local entries = {}
	for _, candidate in candidates do
		local resolution = resolutions[candidate.UserId]
		if resolution and not resolution.IsInvalid and resolution.UserName then
			candidate.UserName = resolution.UserName
			table.insert(entries, candidate)
		end
	end

	self.TopEntries = entries
	table.clear(self.TopRankByUserId)
	for _, entry in entries do
		self.TopRankByUserId[entry.UserId] = entry.Rank
	end
	self:_broadcast()
	return true
end

function PlaytimeLeaderboardService:_requestRefresh(commitAfterRefresh)
	if commitAfterRefresh then
		self.CommitAfterRefresh = true
	end
	if self.RefreshRunning then
		return
	end
	self.RefreshRunning = true
	task.spawn(function()
		local retryAttempt = 0
		while self.Running do
			local success, failureKind = self:_refreshTopEntries()
			if success then
				self.InitialTopLoaded = true
				break
			end
			if failureKind == "Request" then
				retryAttempt += 1
			end
			local retryDelay = if failureKind == "Budget"
				then LeaderboardDataStoreUtil.GetBudgetRetryDelay()
				else LeaderboardDataStoreUtil.GetFailureRetryDelay(retryAttempt)
			task.wait(retryDelay)
		end
		self.RefreshRunning = false
		if self.Running and self.CommitAfterRefresh and self.InitialTopLoaded then
			self.CommitAfterRefresh = false
			self:_requestCommitPass()
		end
	end)
end

function PlaytimeLeaderboardService:_submitOrderedTotal(player, totalSeconds)
	local candidate = normalizePositiveSeconds(totalSeconds)
	if not candidate then
		return true
	end
	local success, result, failureKind = LeaderboardDataStoreUtil.TryRequest(
		Enum.DataStoreRequestType.UpdateAsync,
		function()
			return orderedStore:UpdateAsync(getEntryKey(player.UserId), function(previousValue)
				return math.max(normalizeWholeSeconds(previousValue), candidate)
			end)
		end
	)
	if failureKind == "Budget" then
		LeaderboardDataStoreUtil.WarnBudgetThrottled(
			self.BudgetWarningTimes,
			"OrderedUpdate",
			"Playtime leaderboard submission is waiting for UpdateAsync budget."
		)
		return false, "Budget"
	end
	if success then
		return true, normalizePositiveSeconds(result) or candidate
	end
	warn(string.format("Playtime leaderboard submission failed for %s: %s", player.Name, tostring(result)))
	return false, "Request"
end

function PlaytimeLeaderboardService:_commitPlayerNow(player, session)
	local elapsedSeconds = self:_getSessionElapsed(session)
	if elapsedSeconds > session.CommittedSessionSeconds then
		local success, result, failureKind = LeaderboardDataStoreUtil.TryRequest(
			Enum.DataStoreRequestType.UpdateAsync,
			function()
				return playtimeStore:UpdateAsync(getEntryKey(player.UserId), function(previousValue)
					local record = normalizePlaytimeRecord(previousValue)
					local previousSessionSeconds = getCheckpointSeconds(record, session.Id)
					local addedSeconds = math.max(0, elapsedSeconds - previousSessionSeconds)
					record.TotalSeconds = normalizeWholeSeconds(record.TotalSeconds + addedSeconds)
					setCheckpoint(record, session.Id, math.max(previousSessionSeconds, elapsedSeconds))
					return record
				end)
			end
		)
		if failureKind == "Budget" then
			LeaderboardDataStoreUtil.WarnBudgetThrottled(
				self.BudgetWarningTimes,
				"PrimaryUpdate",
				"Playtime save is waiting for UpdateAsync budget."
			)
			return false, "Budget"
		end
		if not success then
			warn(string.format("Playtime save failed for %s: %s", player.Name, tostring(result)))
			return false, "Request"
		end

		local committedRecord = normalizePlaytimeRecord(result)
		session.TotalSeconds = committedRecord.TotalSeconds
		session.CommittedSessionSeconds = getCheckpointSeconds(committedRecord, session.Id)
		session.Loaded = true
		session.PendingOrderedTotal = math.max(session.PendingOrderedTotal or 0, committedRecord.TotalSeconds)
	end

	local pendingOrderedTotal = normalizePositiveSeconds(session.PendingOrderedTotal)
	if pendingOrderedTotal then
		local orderedSucceeded, resultOrFailure = self:_submitOrderedTotal(player, pendingOrderedTotal)
		if not orderedSucceeded then
			return false, resultOrFailure
		end
		if normalizeWholeSeconds(session.PendingOrderedTotal) <= pendingOrderedTotal then
			session.PendingOrderedTotal = nil
		end
	end
	self:_sendToPlayer(player)
	return true
end

function PlaytimeLeaderboardService:_popCommitQueue()
	local selectedIndex = nil
	for index, item in self.CommitQueue do
		if item.Session.CommitPriority then
			selectedIndex = index
			break
		end
	end
	return table.remove(self.CommitQueue, selectedIndex or 1)
end

function PlaytimeLeaderboardService:_runCommitQueue()
	if self.CommitWorkerRunning then
		return
	end
	self.CommitWorkerRunning = true
	task.spawn(function()
		while #self.CommitQueue > 0 do
			local item = self:_popCommitQueue()
			local player = item.Player
			local session = item.Session
			session.CommitQueued = false
			local priority = session.CommitPriority == true
			session.CommitPriority = false
			if self.Sessions[player] == session then
				session.CommitRunning = true
				local success, failureKind = self:_commitPlayerNow(player, session)
				session.CommitRunning = false
				if success then
					session.CommitRetryAttempt = 0
					if session.CommitAgain then
						session.CommitAgain = false
						self:_requestPlayerCommit(player, session, priority or session.Finalizing)
					elseif session.Finalizing then
						session.FinalCommitComplete = true
					end
				else
					if failureKind == "Request" then
						session.CommitRetryAttempt += 1
					end
					local retryDelay = if failureKind == "Budget"
						then LeaderboardDataStoreUtil.GetBudgetRetryDelay()
						else LeaderboardDataStoreUtil.GetFailureRetryDelay(session.CommitRetryAttempt)
					session.CommitAgain = false
					session.CommitRetryToken += 1
					local retryToken = session.CommitRetryToken
					task.delay(retryDelay, function()
						if self.Sessions[player] == session and session.CommitRetryToken == retryToken then
							self:_requestPlayerCommit(player, session, priority or session.Finalizing)
						end
					end)
				end
			end
		end
		self.CommitWorkerRunning = false
	end)
end

function PlaytimeLeaderboardService:_requestPlayerCommit(player, session, priority)
	if self.Sessions[player] ~= session or (session.Removing and not priority) then
		return
	end
	if session.CommitRunning then
		session.CommitAgain = true
		session.CommitPriority = session.CommitPriority or priority == true
		return
	end
	if session.CommitQueued then
		session.CommitPriority = session.CommitPriority or priority == true
		return
	end
	session.CommitRetryToken += 1
	session.CommitQueued = true
	session.CommitPriority = priority == true
	table.insert(self.CommitQueue, { Player = player, Session = session })
	self:_runCommitQueue()
end

function PlaytimeLeaderboardService:_requestCommitPass()
	for player, session in self.Sessions do
		if session.Loaded and not session.Removing then
			self:_requestPlayerCommit(player, session, false)
		end
	end
end

function PlaytimeLeaderboardService:_hydratePlayer(player, session)
	local retryAttempt = 0
	while self.Sessions[player] == session and not session.Removing and not self.InitialTopLoaded do
		task.wait()
	end
	while self.Sessions[player] == session and not session.Removing do
		local success, result, failureKind = LeaderboardDataStoreUtil.TryRequest(
			Enum.DataStoreRequestType.GetAsync,
			function()
				return playtimeStore:GetAsync(getEntryKey(player.UserId))
			end
		)
		if failureKind == "Budget" then
			LeaderboardDataStoreUtil.WarnBudgetThrottled(
				self.BudgetWarningTimes,
				"PrimaryGet",
				"Playtime load is waiting for GetAsync budget."
			)
			task.wait(LeaderboardDataStoreUtil.GetBudgetRetryDelay())
			continue
		end
		if success then
			if self.Sessions[player] ~= session or session.Removing then
				return
			end
			local loadedRecord = normalizePlaytimeRecord(result)
			session.TotalSeconds = loadedRecord.TotalSeconds
			session.CommittedSessionSeconds = getCheckpointSeconds(loadedRecord, session.Id)
			session.Loaded = true
			session.PendingOrderedTotal = normalizePositiveSeconds(loadedRecord.TotalSeconds)
			self:_sendToPlayer(player)
			if self.InitialTopLoaded then
				self:_requestPlayerCommit(player, session, false)
			end
			break
		end
		retryAttempt += 1
		warn(string.format("Playtime load failed for %s: %s", player.Name, tostring(result)))
		task.wait(LeaderboardDataStoreUtil.GetFailureRetryDelay(retryAttempt))
	end
end

function PlaytimeLeaderboardService:_bindPlayer(player)
	if self.Sessions[player] then
		return
	end
	local session = {
		Id = HttpService:GenerateGUID(false),
		StartedClock = os.clock(),
		CommittedSessionSeconds = 0,
		TotalSeconds = 0,
		Loaded = false,
		CommitRunning = false,
		CommitQueued = false,
		CommitAgain = false,
		CommitPriority = false,
		CommitRetryAttempt = 0,
		CommitRetryToken = 0,
		PendingOrderedTotal = nil,
		Removing = false,
		Finalizing = false,
		FinalCommitComplete = false,
	}
	self.Sessions[player] = session
	task.spawn(function()
		self:_hydratePlayer(player, session)
	end)
end

function PlaytimeLeaderboardService:_finalizePlayer(player)
	local session = self.Sessions[player]
	if not session or session.Finalizing then
		return
	end
	session.Finalizing = true
	session.Removing = true
	session.FinalCommitComplete = false
	self:_requestPlayerCommit(player, session, true)
	local deadline = os.clock() + 24
	while self.Sessions[player] == session and not session.FinalCommitComplete and os.clock() < deadline do
		task.wait()
	end
	if not session.FinalCommitComplete then
		warn(string.format("Playtime final save timed out for %s; Roblox may retry older queued work.", player.Name))
	end
	if self.Sessions[player] == session then
		self.Sessions[player] = nil
	end
	self.SnapshotRequestTimes[player] = nil
end

function PlaytimeLeaderboardService:Init(snapshotRemote)
	self.SnapshotRemote = snapshotRemote
	self.Sessions = {}
	self.TopEntries = {}
	self.TopRankByUserId = {}
	self.SnapshotRequestTimes = {}
	self.RefreshRunning = false
	self.RefreshQueued = false
	self.InitialTopLoaded = false
	self.CommitAfterRefresh = false
	self.CommitQueue = {}
	self.CommitWorkerRunning = false
	self.BudgetWarningTimes = {}
	self.Running = true

	snapshotRemote.OnServerEvent:Connect(function(player, requestKind)
		if requestKind ~= "Request" then
			return
		end
		local now = os.clock()
		if now - (self.SnapshotRequestTimes[player] or -math.huge) < SNAPSHOT_REQUEST_INTERVAL then
			return
		end
		self.SnapshotRequestTimes[player] = now
		self:_sendToPlayer(player)
	end)

	Players.PlayerAdded:Connect(function(player)
		self:_bindPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_finalizePlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_bindPlayer(player)
	end

	LeaderboardDataStoreUtil.StartFixedPhaseLoop(REFRESH_PHASE, REFRESH_INTERVAL, function()
		return self.Running
	end, function()
		self:_requestRefresh(true)
	end)

	game:BindToClose(function()
		self.Running = false
		local players = {}
		for player in self.Sessions do
			table.insert(players, player)
		end
		for _, player in players do
			task.spawn(function()
				self:_finalizePlayer(player)
			end)
		end
		local deadline = os.clock() + 25
		while next(self.Sessions) ~= nil and os.clock() < deadline do
			task.wait()
		end
	end)
end

return PlaytimeLeaderboardService

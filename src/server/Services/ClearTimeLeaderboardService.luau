local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)
local LeaderboardDataStoreUtil = require(script.Parent.LeaderboardDataStoreUtil)
local LeaderboardUsernameResolver = require(script.Parent.LeaderboardUsernameResolver)

local ClearTimeLeaderboardService = {}

local ORDERED_STORE_NAME = "CleanTheFloor_ClearTimeLeaderboard_v1"
local ENTRY_KEY_PREFIX = "Player_"
local TARGET_AREA_ID = RegionConfig.FinalAreaId
local TOP_ENTRY_LIMIT = 20
local REFRESH_INTERVAL = 60
local REFRESH_PHASE = 0
local SNAPSHOT_REQUEST_INTERVAL = 1
local MAX_TIME_SECONDS = 1_000_000_000

local orderedStore = DataStoreService:GetOrderedDataStore(ORDERED_STORE_NAME)

local function normalizeSeconds(value)
	local numeric = tonumber(value)
	if not numeric or numeric ~= numeric or numeric <= 0 or numeric == math.huge then
		return nil
	end
	return math.clamp(math.floor(numeric + 0.5), 1, MAX_TIME_SECONDS)
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

function ClearTimeLeaderboardService:_copyEntries()
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

function ClearTimeLeaderboardService:_getCachedBest(player)
	local cached = normalizeSeconds(self.PlayerBestSeconds[player])
	if cached then
		return cached
	end
	local leaderboardState = self.PlayerDataService:GetClearSpeedrunLeaderboardState(player)
	local stateBest = leaderboardState and normalizeSeconds(leaderboardState.BestSeconds) or nil
	if stateBest then
		self.PlayerBestSeconds[player] = stateBest
	end
	return stateBest
end

function ClearTimeLeaderboardService:_buildSnapshot(player)
	local bestSeconds = self:_getCachedBest(player)
	local topEntry = self.TopEntryByUserId[player.UserId]
	local topRank = topEntry and topEntry.Rank or nil
	if topEntry then
		bestSeconds = topEntry.TimeSeconds
		self.PlayerBestSeconds[player] = bestSeconds
	end
	return {
		Entries = self:_copyEntries(),
		Self = {
			UserName = player.Name,
			TimeSeconds = bestSeconds,
			RankText = if topRank then "#" .. tostring(topRank) elseif bestSeconds then "#20+" else "#--",
		},
	}
end

function ClearTimeLeaderboardService:_sendToPlayer(player)
	if player.Parent == Players then
		self.SnapshotRemote:FireClient(player, self:_buildSnapshot(player))
	end
end

function ClearTimeLeaderboardService:_broadcast()
	for _, player in Players:GetPlayers() do
		self:_sendToPlayer(player)
	end
end

function ClearTimeLeaderboardService:_refreshTopEntries()
	local success, pageOrError, failureKind = LeaderboardDataStoreUtil.TryRequest(
		Enum.DataStoreRequestType.GetSortedAsync,
		function()
			local pages = orderedStore:GetSortedAsync(true, TOP_ENTRY_LIMIT)
			return pages:GetCurrentPage()
		end
	)
	if failureKind == "Budget" then
		LeaderboardDataStoreUtil.WarnBudgetThrottled(
			self.BudgetWarningTimes,
			"Refresh",
			"Clear-time leaderboard refresh is waiting for GetSortedAsync budget."
		)
		return false, "Budget"
	end
	if not success then
		warn("Clear-time leaderboard refresh failed: " .. tostring(pageOrError))
		return false, "Request"
	end

	local candidates = {}
	local userIds = {}
	for _, rawEntry in pageOrError do
		local userId = getUserIdFromEntryKey(rawEntry.key)
		local timeSeconds = normalizeSeconds(rawEntry.value)
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
	table.clear(self.TopEntryByUserId)
	for _, entry in entries do
		self.TopRankByUserId[entry.UserId] = entry.Rank
		self.TopEntryByUserId[entry.UserId] = entry
		local onlinePlayer = Players:GetPlayerByUserId(entry.UserId)
		if onlinePlayer then
			self.PlayerBestSeconds[onlinePlayer] = entry.TimeSeconds
			self.PlayerDataService:SetCommittedClearSpeedrunBest(onlinePlayer, entry.TimeSeconds)
		end
	end
	self:_broadcast()
	return true
end

function ClearTimeLeaderboardService:_requestRefresh(submitAfterRefresh)
	if submitAfterRefresh then
		self.SubmitAfterRefresh = true
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
		if self.Running and self.SubmitAfterRefresh and self.InitialTopLoaded then
			self.SubmitAfterRefresh = false
			self:_submitAllPending()
		end
	end)
end

function ClearTimeLeaderboardService:_submitPendingBest(player, candidateSeconds)
	local candidate = normalizeSeconds(candidateSeconds)
	if not candidate then
		return
	end
	local queuedCandidate = normalizeSeconds(self.PendingSubmissions[player])
	self.PendingSubmissions[player] = if queuedCandidate then math.min(queuedCandidate, candidate) else candidate
	if not self.InitialTopLoaded or self.SubmissionRunning[player] then
		return
	end
	self.SubmissionRunning[player] = true
	task.spawn(function()
		local retryAttempt = 0
		while self.Running do
			local currentCandidate = normalizeSeconds(self.PendingSubmissions[player])
			if not currentCandidate then
				break
			end
			local success, result, failureKind = LeaderboardDataStoreUtil.TryRequest(
				Enum.DataStoreRequestType.UpdateAsync,
				function()
					return orderedStore:UpdateAsync(getEntryKey(player.UserId), function(previousValue)
						local previousBest = normalizeSeconds(previousValue)
						if previousBest and previousBest <= currentCandidate then
							return previousBest
						end
						return currentCandidate
					end)
				end
			)
			if failureKind == "Budget" then
				LeaderboardDataStoreUtil.WarnBudgetThrottled(
					self.BudgetWarningTimes,
					"OrderedUpdate",
					"Clear-time leaderboard submission is waiting for UpdateAsync budget."
				)
				task.wait(LeaderboardDataStoreUtil.GetBudgetRetryDelay())
				continue
			end
			if success then
				retryAttempt = 0
				local committedBest = normalizeSeconds(result) or currentCandidate
				local latestCandidate = normalizeSeconds(self.PendingSubmissions[player])
				if latestCandidate and latestCandidate >= committedBest then
					self.PendingSubmissions[player] = nil
				end
				if self.PlayerDataService:GetState(player) then
					self.PlayerBestSeconds[player] = committedBest
					self.PlayerDataService:SetCommittedClearSpeedrunBest(player, committedBest)
					self:_sendToPlayer(player)
				end
			else
				retryAttempt += 1
				warn(string.format(
					"Clear-time leaderboard submission failed for %s: %s",
					player.Name,
					tostring(result)
				))
				task.wait(LeaderboardDataStoreUtil.GetFailureRetryDelay(retryAttempt))
			end
		end
		self.SubmissionRunning[player] = nil
		if self.Running and self.InitialTopLoaded and self.PendingSubmissions[player] then
			self:_submitPendingBest(player, self.PendingSubmissions[player])
		end
	end)
end

function ClearTimeLeaderboardService:_submitAllPending()
	for _, player in Players:GetPlayers() do
		local state = self.PlayerDataService:GetClearSpeedrunLeaderboardState(player)
		local pendingBest = state and normalizeSeconds(state.PendingBestSeconds) or nil
		if pendingBest then
			self:_submitPendingBest(player, pendingBest)
		end
	end
end

function ClearTimeLeaderboardService:_hydratePlayer(player)
	while player.Parent == Players and self.Running and not self.InitialTopLoaded do
		task.wait()
	end
	if player.Parent ~= Players or not self.Running then
		return
	end
	local leaderboardState = self.PlayerDataService:GetClearSpeedrunLeaderboardState(player)
	if not leaderboardState then
		return
	end
	local stateBest = normalizeSeconds(leaderboardState.BestSeconds)
	if stateBest then
		self.PlayerBestSeconds[player] = stateBest
	end
	local retryAttempt = 0
	while player.Parent == Players and self.Running do
		local success, storedValue, failureKind = LeaderboardDataStoreUtil.TryRequest(
			Enum.DataStoreRequestType.GetAsync,
			function()
				return orderedStore:GetAsync(getEntryKey(player.UserId))
			end
		)
		if failureKind == "Budget" then
			LeaderboardDataStoreUtil.WarnBudgetThrottled(
				self.BudgetWarningTimes,
				"SelfGet",
				"Clear-time self record is waiting for GetAsync budget."
			)
			task.wait(LeaderboardDataStoreUtil.GetBudgetRetryDelay())
			continue
		end
		if success then
			local storedBest = normalizeSeconds(storedValue)
			if storedBest then
				self.PlayerBestSeconds[player] = storedBest
				self.PlayerDataService:SetCommittedClearSpeedrunBest(player, storedBest)
			end
			break
		end
		retryAttempt += 1
		warn(string.format(
			"Clear-time leaderboard self record failed for %s: %s",
			player.Name,
			tostring(storedValue)
		))
		task.wait(LeaderboardDataStoreUtil.GetFailureRetryDelay(retryAttempt))
	end
	if player.Parent ~= Players then
		return
	end
	self:_sendToPlayer(player)

	local refreshedState = self.PlayerDataService:GetClearSpeedrunLeaderboardState(player)
	local pendingBest = refreshedState and normalizeSeconds(refreshedState.PendingBestSeconds) or nil
	if pendingBest then
		self:_submitPendingBest(player, pendingBest)
	end
end

function ClearTimeLeaderboardService:Init(playerDataService, leafService, snapshotRemote)
	self.PlayerDataService = playerDataService
	self.LeafService = leafService
	self.SnapshotRemote = snapshotRemote
	self.TopEntries = {}
	self.TopRankByUserId = {}
	self.TopEntryByUserId = {}
	self.PlayerBestSeconds = {}
	self.SubmissionRunning = {}
	self.PendingSubmissions = {}
	self.SnapshotRequestTimes = {}
	self.RefreshRunning = false
	self.RefreshQueued = false
	self.InitialTopLoaded = false
	self.SubmitAfterRefresh = false
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

	leafService:AddAreaCompletedHandler(function(owner, areaId)
		if areaId ~= TARGET_AREA_ID or owner.Parent ~= Players then
			return
		end
		local completed, elapsedSeconds = playerDataService:CompleteClearSpeedrun(owner)
		if completed and elapsedSeconds then
			self:_submitPendingBest(owner, elapsedSeconds)
		end
	end)

	playerDataService:AddPlayerStateReadyHandler(function(player)
		task.spawn(function()
			self:_hydratePlayer(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self.PlayerBestSeconds[player] = nil
		self.SnapshotRequestTimes[player] = nil
	end)

	LeaderboardDataStoreUtil.StartFixedPhaseLoop(REFRESH_PHASE, REFRESH_INTERVAL, function()
		return self.Running
	end, function()
		self:_requestRefresh(true)
	end)
end

return ClearTimeLeaderboardService

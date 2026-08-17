local Players = game:GetService("Players")
local UserService = game:GetService("UserService")

local LeaderboardUsernameResolver = {}

local RETRY_DELAYS = { 0, 1, 3 }
local TEMPORARY_NAME_PREFIX = "Player"
local TEMPORARY_LETTER_COUNT = 3
local TEMPORARY_NAME_COMBINATIONS = 26 ^ TEMPORARY_LETTER_COUNT
local WARNING_INTERVAL = 60

local resolvedNames = {}
local invalidUserIds = {}
local lastWarningAt = -math.huge

local function normalizeUserId(value)
	local userId = tonumber(value)
	if not userId or userId ~= userId or userId == math.huge or userId == -math.huge then
		return nil
	end
	userId = math.floor(userId)
	return if userId > 0 then userId else nil
end

local function makeTemporaryName(userId)
	local code = (userId * 37 + 17) % TEMPORARY_NAME_COMBINATIONS
	local letters = table.create(TEMPORARY_LETTER_COUNT)
	for index = TEMPORARY_LETTER_COUNT, 1, -1 do
		letters[index] = string.char(string.byte("A") + code % 26)
		code = math.floor(code / 26)
	end
	return TEMPORARY_NAME_PREFIX .. table.concat(letters)
end

local function warnTemporaryFailure(message)
	local now = os.clock()
	if now - lastWarningAt < WARNING_INTERVAL then
		return
	end
	lastWarningAt = now
	warn("Leaderboard username lookup is temporarily unavailable: " .. tostring(message))
end

function LeaderboardUsernameResolver.ResolveMany(rawUserIds)
	local userIds = {}
	local includedUserIds = {}
	local results = {}
	local unresolved = {}

	for _, rawUserId in type(rawUserIds) == "table" and rawUserIds or {} do
		local userId = normalizeUserId(rawUserId)
		if userId and not includedUserIds[userId] then
			includedUserIds[userId] = true
			table.insert(userIds, userId)
		end
	end

	for _, userId in userIds do
		local onlinePlayer = Players:GetPlayerByUserId(userId)
		if onlinePlayer then
			resolvedNames[userId] = onlinePlayer.Name
			invalidUserIds[userId] = nil
			results[userId] = { UserName = onlinePlayer.Name }
		elseif resolvedNames[userId] then
			results[userId] = { UserName = resolvedNames[userId] }
		elseif invalidUserIds[userId] then
			results[userId] = { IsInvalid = true }
		else
			table.insert(unresolved, userId)
		end
	end

	if #unresolved > 0 then
		local requestSucceeded = false
		local response
		local lastError
		for attempt, retryDelay in RETRY_DELAYS do
			if retryDelay > 0 then
				task.wait(retryDelay)
			end
			local success, value = pcall(function()
				return UserService:GetUserInfosByUserIdsAsync(unresolved)
			end)
			if success and type(value) == "table" then
				requestSucceeded = true
				response = value
				break
			end
			lastError = value
			if attempt == #RETRY_DELAYS then
				warnTemporaryFailure(lastError)
			end
		end

		if requestSucceeded then
			local returnedUserIds = {}
			for _, userInfo in response do
				local userId = type(userInfo) == "table" and normalizeUserId(userInfo.Id) or nil
				local username = type(userInfo) == "table" and userInfo.Username or nil
				if userId and includedUserIds[userId] then
					returnedUserIds[userId] = true
					if type(username) == "string" and username ~= "" then
						resolvedNames[userId] = username
						invalidUserIds[userId] = nil
						results[userId] = { UserName = username }
					else
						results[userId] = { UserName = makeTemporaryName(userId), IsTemporary = true }
					end
				end
			end
			for _, userId in unresolved do
				if not returnedUserIds[userId] then
					invalidUserIds[userId] = true
					results[userId] = { IsInvalid = true }
				end
			end
		else
			for _, userId in unresolved do
				results[userId] = { UserName = makeTemporaryName(userId), IsTemporary = true }
			end
		end
	end

	return results
end

return LeaderboardUsernameResolver

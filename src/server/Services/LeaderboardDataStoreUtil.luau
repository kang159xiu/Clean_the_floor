local DataStoreService = game:GetService("DataStoreService")

local LeaderboardDataStoreUtil = {}

local BUDGET_RETRY_DELAY = 5
local FAILURE_RETRY_DELAYS = { 5, 15, 30, 60 }
local BUDGET_WARNING_INTERVAL = 60
local SCHEDULER_ORIGIN = os.clock()
local requestRunning = false

function LeaderboardDataStoreUtil.HasBudget(requestType)
	local success, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(requestType)
	end)
	return success and type(budget) == "number" and budget > 0
end

function LeaderboardDataStoreUtil.TryRequest(requestType, callback)
	while requestRunning do
		task.wait()
	end
	requestRunning = true
	if not LeaderboardDataStoreUtil.HasBudget(requestType) then
		requestRunning = false
		return false, nil, "Budget"
	end
	local success, result = pcall(callback)
	requestRunning = false
	return success, result, if success then nil else "Request"
end

function LeaderboardDataStoreUtil.GetBudgetRetryDelay()
	return BUDGET_RETRY_DELAY
end

function LeaderboardDataStoreUtil.GetFailureRetryDelay(attempt)
	local normalizedAttempt = math.max(1, math.floor(tonumber(attempt) or 1))
	return FAILURE_RETRY_DELAYS[math.min(normalizedAttempt, #FAILURE_RETRY_DELAYS)]
end

function LeaderboardDataStoreUtil.WarnBudgetThrottled(warningTimes, key, message)
	local now = os.clock()
	if now - (warningTimes[key] or -math.huge) < BUDGET_WARNING_INTERVAL then
		return
	end
	warningTimes[key] = now
	warn(message)
end

function LeaderboardDataStoreUtil.StartFixedPhaseLoop(phaseSeconds, intervalSeconds, shouldContinue, callback)
	task.spawn(function()
		local nextRun = SCHEDULER_ORIGIN + math.max(0, tonumber(phaseSeconds) or 0)
		while shouldContinue() do
			local remaining = nextRun - os.clock()
			if remaining > 0 then
				task.wait(remaining)
			end
			if not shouldContinue() then
				break
			end
			callback()
			repeat
				nextRun += intervalSeconds
			until nextRun > os.clock()
		end
	end)
end

return LeaderboardDataStoreUtil

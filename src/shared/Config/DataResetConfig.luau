local DataResetConfig = {
	-- This date is a reset version, not the current calendar date. Each player is
	-- reset once when their saved version is older; increasing it runs another reset.
	Enabled = true,
	CutoffDate = {
		Year = 2026,
		Month = 8,
		Day = 7,
	},
	-- Add Roblox usernames here to clear those players once when they join on
	-- this date in China Standard Time (UTC+8). An empty list disables it.
	TargetedReset = {
		Date = {
			Year = 2026,
			Month = 8,
			Day = 18,
		},
		UserNames = {
			-- "PlayerName",
			"Firefly",
			"zaku198902",
			"glaugh90",
			"xiaoyouqifele",
		},
	},
	ResetNotice = "Your progress was reset for an update. Permanent Robux purchases will be restored automatically.",
}

local CHINA_TIME_OFFSET_SECONDS = 8 * 60 * 60

local function isLeapYear(year)
	return year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0)
end

local function isValidDate(year, month, day)
	if
		not year
		or year % 1 ~= 0
		or year < 2000
		or year > 9999
		or not month
		or month % 1 ~= 0
		or month < 1
		or month > 12
	then
		return false
	end
	local daysPerMonth = { 31, isLeapYear(year) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	return day ~= nil and day % 1 == 0 and day >= 1 and day <= daysPerMonth[month]
end

function DataResetConfig.GetCutoffDateKey()
	local date = DataResetConfig.CutoffDate
	local year = tonumber(date and date.Year)
	local month = tonumber(date and date.Month)
	local day = tonumber(date and date.Day)
	assert(isValidDate(year, month, day), "DataResetConfig.CutoffDate is invalid")
	return year * 10000 + month * 100 + day
end

function DataResetConfig.GetTargetedResetDateKey(userName, unixTimestamp)
	if type(userName) ~= "string" or userName == "" then
		return nil
	end

	local targetedReset = DataResetConfig.TargetedReset
	local userNames = targetedReset and targetedReset.UserNames
	if type(userNames) ~= "table" or #userNames == 0 then
		return nil
	end

	local date = targetedReset.Date
	local year = tonumber(date and date.Year)
	local month = tonumber(date and date.Month)
	local day = tonumber(date and date.Day)
	assert(isValidDate(year, month, day), "DataResetConfig.TargetedReset.Date is invalid")
	local targetedDateKey = year * 10000 + month * 100 + day

	local timestamp = tonumber(unixTimestamp)
	if not timestamp or timestamp ~= timestamp or timestamp == math.huge or timestamp == -math.huge then
		timestamp = DateTime.now().UnixTimestamp
	end
	local chinaDate = os.date("!*t", math.floor(timestamp) + CHINA_TIME_OFFSET_SECONDS)
	local currentDateKey = chinaDate.year * 10000 + chinaDate.month * 100 + chinaDate.day
	if currentDateKey ~= targetedDateKey then
		return nil
	end

	local normalizedUserName = string.lower(userName)
	for _, configuredUserName in userNames do
		if
			type(configuredUserName) == "string"
			and string.lower(configuredUserName) == normalizedUserName
		then
			return targetedDateKey
		end
	end
	return nil
end

function DataResetConfig.NormalizeStoredDateKey(value)
	local dateKey = tonumber(value)
	if not dateKey or dateKey % 1 ~= 0 then
		return nil
	end
	local year = math.floor(dateKey / 10000)
	local month = math.floor(dateKey / 100) % 100
	local day = dateKey % 100
	if not isValidDate(year, month, day) then
		return nil
	end
	return dateKey
end

return table.freeze(DataResetConfig)

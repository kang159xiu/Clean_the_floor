local CoinFormat = {}

local DIRECT_SUFFIXES = {
	[1] = "K",
	[2] = "M",
	[3] = "B",
	[4] = "T",
	[5] = "Qa",
	[6] = "Qi",
	[7] = "Sx",
	[8] = "Sp",
	[9] = "Oc",
	[10] = "No",
	[11] = "Dc",
}

local ONES_PREFIXES = {
	[1] = "U",
	[2] = "D",
	[3] = "T",
	[4] = "Qa",
	[5] = "Qi",
	[6] = "Sx",
	[7] = "Sp",
	[8] = "Oc",
	[9] = "No",
}

local TENS_SUFFIXES = {
	[1] = { Exact = "Dc", Tail = "d" },
	[2] = { Exact = "Vg", Tail = "vg" },
	[3] = { Exact = "Tg", Tail = "tg" },
	[4] = { Exact = "Qag", Tail = "qag" },
	[5] = { Exact = "Qig", Tail = "qig" },
	[6] = { Exact = "Sxg", Tail = "sxg" },
	[7] = { Exact = "Spg", Tail = "spg" },
	[8] = { Exact = "Ocg", Tail = "ocg" },
	[9] = { Exact = "Nog", Tail = "nog" },
}

local MAX_UNIT_INDEX = 102

local function suffixForUnit(unitIndex)
	local direct = DIRECT_SUFFIXES[unitIndex]
	if direct then
		return direct
	end

	local illionIndex = unitIndex - 1
	if illionIndex == 100 then
		return "Ce"
	elseif illionIndex > 100 then
		return (ONES_PREFIXES[illionIndex - 100] or "") .. "Ce"
	end

	local tens = math.floor(illionIndex / 10)
	local ones = illionIndex % 10
	local family = TENS_SUFFIXES[tens]
	if not family then
		return "e" .. tostring(unitIndex * 3)
	elseif ones == 0 then
		return family.Exact
	end
	return ONES_PREFIXES[ones] .. family.Tail
end

function CoinFormat.Compact(value)
	local numericValue = tonumber(value) or 0
	if numericValue ~= numericValue then
		return "0"
	elseif numericValue == math.huge then
		return "∞"
	elseif numericValue == -math.huge then
		return "-∞"
	end

	local sign = if numericValue < 0 then "-" else ""
	local scaled = math.abs(numericValue)
	local unitIndex = 0
	while scaled >= 1000 and unitIndex < MAX_UNIT_INDEX do
		scaled /= 1000
		unitIndex += 1
	end

	if unitIndex == 0 then
		return sign .. string.format("%.0f", scaled)
	end

	scaled = math.ceil(scaled * 10 - 1e-9) / 10
	if scaled >= 1000 and unitIndex < MAX_UNIT_INDEX then
		scaled /= 1000
		unitIndex += 1
		scaled = math.ceil(scaled * 10 - 1e-9) / 10
	end

	local roundedInteger = math.floor(scaled + 0.5)
	local numberText = if math.abs(scaled - roundedInteger) < 1e-9
		then tostring(roundedInteger)
		else string.format("%.1f", scaled)
	return sign .. numberText .. string.lower(suffixForUnit(unitIndex))
end

return table.freeze(CoinFormat)

local DurationFormat = {}

function DurationFormat.HoursMinutes(seconds)
	local numericSeconds = tonumber(seconds)
	if
		not numericSeconds
		or numericSeconds ~= numericSeconds
		or numericSeconds < 0
		or numericSeconds == math.huge
	then
		numericSeconds = 0
	end
	local totalMinutes = math.floor(numericSeconds / 60)
	local hours = math.floor(totalMinutes / 60)
	local minutes = totalMinutes % 60
	if hours > 0 then
		return string.format("%dh%02dm", hours, minutes)
	end
	return string.format("%02dm", minutes)
end

return table.freeze(DurationFormat)

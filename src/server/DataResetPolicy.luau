local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataResetConfig = require(ReplicatedStorage.Shared.Config.DataResetConfig)

local DataResetPolicy = {}

function DataResetPolicy.MakeFreshPersistentData(schemaVersion, dataResetDateKey, dataResetNoticeDateKey)
	local normalizedSchemaVersion = math.max(1, math.floor(tonumber(schemaVersion) or 0))
	local normalizedDataResetDateKey = DataResetConfig.NormalizeStoredDateKey(dataResetDateKey)
	local normalizedDataResetNoticeDateKey = DataResetConfig.NormalizeStoredDateKey(dataResetNoticeDateKey)
	if dataResetDateKey ~= nil then
		assert(normalizedDataResetDateKey, "DataResetPolicy reset date is invalid")
	end
	if dataResetNoticeDateKey ~= nil then
		assert(normalizedDataResetNoticeDateKey, "DataResetPolicy notice date is invalid")
	end
	local data = {
		SchemaVersion = normalizedSchemaVersion,
	}
	if normalizedDataResetDateKey then
		data.DataResetDateKey = normalizedDataResetDateKey
	end
	if normalizedDataResetNoticeDateKey then
		data.DataResetNoticeDateKey = normalizedDataResetNoticeDateKey
	end
	return data
end

function DataResetPolicy.PreparePersistentData(
	rawData,
	isNewPlayer,
	schemaVersion,
	resetEnabled,
	resetDateKey
)
	local normalizedResetDateKey = DataResetConfig.NormalizeStoredDateKey(resetDateKey)
	assert(normalizedResetDateKey, "DataResetPolicy reset date is invalid")
	if isNewPlayer then
		return DataResetPolicy.MakeFreshPersistentData(
			schemaVersion,
			normalizedResetDateKey,
			normalizedResetDateKey
		), false
	end

	local data = type(rawData) == "table" and rawData or {}
	local storedDateKey = DataResetConfig.NormalizeStoredDateKey(data.DataResetDateKey)
	if resetEnabled == true and (not storedDateKey or storedDateKey < normalizedResetDateKey) then
		return DataResetPolicy.MakeFreshPersistentData(schemaVersion, normalizedResetDateKey, nil), true
	end

	data.DataResetDateKey = storedDateKey
	data.DataResetNoticeDateKey = DataResetConfig.NormalizeStoredDateKey(data.DataResetNoticeDateKey)
	return data, false
end

return table.freeze(DataResetPolicy)

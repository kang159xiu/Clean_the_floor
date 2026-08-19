local RunService = game:GetService("RunService")

local CoopMatchConfig = {}

CoopMatchConfig.LobbyPlaceId = 95556867008792
CoopMatchConfig.CoopPlaceId = 131244809352557
CoopMatchConfig.ProtocolVersion = 1
CoopMatchConfig.MaximumPartySize = 4
CoopMatchConfig.DefaultTargetPlayerCount = 4
CoopMatchConfig.ConfirmCountdownSeconds = 15
CoopMatchConfig.ArrivalGraceSeconds = 10
CoopMatchConfig.PadIds = { "place001", "place002", "place003", "place004" }
CoopMatchConfig.DifficultyOrder = { "EASY", "HARD", "NIGHTMARE", "HELL" }
CoopMatchConfig.DifficultyMultipliers = {
	EASY = 1,
	HARD = 2,
	NIGHTMARE = 3,
	HELL = 4,
}

function CoopMatchConfig.IsLobby()
	return game.PlaceId == CoopMatchConfig.LobbyPlaceId
end

function CoopMatchConfig.IsCoop()
	return game.PlaceId == CoopMatchConfig.CoopPlaceId
end

function CoopMatchConfig.IsStudioCoop()
	return RunService:IsStudio() and CoopMatchConfig.IsCoop()
end

function CoopMatchConfig.NormalizeDifficulty(value)
	if type(value) == "string" and CoopMatchConfig.DifficultyMultipliers[value] then
		return value
	end
	return "EASY"
end

function CoopMatchConfig.GetDifficultyMultiplier(value)
	return CoopMatchConfig.DifficultyMultipliers[CoopMatchConfig.NormalizeDifficulty(value)]
end

return table.freeze(CoopMatchConfig)

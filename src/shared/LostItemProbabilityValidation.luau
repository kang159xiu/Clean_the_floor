local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LostItemConfig = require(ReplicatedStorage.Shared.Config.LostItemConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local LostItemProbabilityValidation = {}

function LostItemProbabilityValidation.Run(drawsPerArea, seed)
	local draws = math.max(1, math.floor(tonumber(drawsPerArea) or 100_000))
	local random = Random.new(math.floor(tonumber(seed) or 20260720))
	local report = {}
	local previousHighProbability = -math.huge

	for areaNumber = 1, RegionConfig.PersistentAreaCount do
		local areaId = string.format("Area_%02d", areaNumber)
		local areaConfig = LostItemConfig.Areas[areaId]
		local rarityCounts = {}
		local typeCounts = {}
		local spawnCounts = {}
		for spawnCount = areaConfig.MinimumSpawnCount, areaConfig.MaximumSpawnCount do
			spawnCounts[spawnCount] = 0
		end
		for _, rarityId in LostItemConfig.RarityOrder do
			rarityCounts[rarityId] = 0
		end

		for _ = 1, draws do
			local lostItemId, rarityId = LostItemConfig.ChooseLostItemId(random, areaId)
			rarityCounts[rarityId] += 1
			typeCounts[lostItemId] = (typeCounts[lostItemId] or 0) + 1
			local spawnCount = LostItemConfig.ChooseBaseSpawnCount(random, areaId)
			assert(spawnCounts[spawnCount] ~= nil, "Unexpected spawn count: " .. tostring(spawnCount))
			spawnCounts[spawnCount] += 1
		end

		local observed = {}
		for _, rarityId in LostItemConfig.RarityOrder do
			observed[rarityId] = rarityCounts[rarityId] / draws * 100
			assert(rarityCounts[rarityId] > 0, areaId .. " did not roll " .. rarityId)
			assert(
				math.abs(observed[rarityId] - areaConfig.RarityProbabilities[rarityId]) <= 0.75,
				string.format("%s %s probability drifted to %.3f%%", areaId, rarityId, observed[rarityId])
			)
		end

		local highProbability = observed.Legendary + observed.Mythic
		assert(highProbability >= previousHighProbability, areaId .. " high rarity probability must not decrease")
		previousHighProbability = highProbability
		for _, lostItemId in LostItemConfig.Order do
			local rarityId = LostItemConfig.Types[lostItemId].RarityId
			local expectedTypeProbability = areaConfig.RarityProbabilities[rarityId]
				/ #LostItemConfig.IdsByRarity[rarityId]
			local observedTypeProbability = (typeCounts[lostItemId] or 0) / draws * 100
			assert(typeCounts[lostItemId] and typeCounts[lostItemId] > 0, areaId .. " did not roll " .. lostItemId)
			assert(
				math.abs(observedTypeProbability - expectedTypeProbability) <= 0.3,
				string.format("%s %s probability drifted to %.3f%%", areaId, lostItemId, observedTypeProbability)
			)
		end

		local spawnCountOptionTotal = areaConfig.MaximumSpawnCount - areaConfig.MinimumSpawnCount + 1
		for spawnCount, count in spawnCounts do
			local observedProbability = count / draws * 100
			assert(
				math.abs(observedProbability - 100 / spawnCountOptionTotal) <= 0.75,
				string.format("%s spawn count %d drifted to %.3f%%", areaId, spawnCount, observedProbability)
			)
		end

		report[areaId] = {
			Draws = draws,
			RarityPercentages = observed,
			SpawnCounts = spawnCounts,
			TypeCounts = typeCounts,
		}
	end

	return report
end

return LostItemProbabilityValidation

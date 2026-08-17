local CoinFlipConfig = {
	MinimumWager = 10,
	WagerStep = 10,
	AnimationDuration = 4,
	RewardDelay = 0.1,
	BaseHeadsChance = 0.4,
	InitialGuaranteedHeads = 2,
	MinimumPityThreshold = 5,
	MaximumPityThreshold = 10,
	MaximumTransactionIdLength = 64,
	CoinTiers = {
		{ MinimumWager = 100_000, CoinId = "Coin004" },
		{ MinimumWager = 10_000, CoinId = "Coin003" },
		{ MinimumWager = 1_000, CoinId = "Coin002" },
		{ MinimumWager = 0, CoinId = "Coin001" },
	},
}

function CoinFlipConfig.GetCoinId(wager)
	local normalizedWager = math.max(0, tonumber(wager) or 0)
	for _, tier in CoinFlipConfig.CoinTiers do
		if normalizedWager >= tier.MinimumWager then
			return tier.CoinId
		end
	end
	return "Coin001"
end

function CoinFlipConfig.IsCoinId(coinId)
	for _, tier in CoinFlipConfig.CoinTiers do
		if coinId == tier.CoinId then
			return true
		end
	end
	return false
end

return table.freeze(CoinFlipConfig)

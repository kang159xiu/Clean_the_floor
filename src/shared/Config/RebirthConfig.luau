local RebirthConfig = {
	BaseLeafCountMultiplier = 1,
	LeafCountMultiplierPerRebirth = 0.5,
	BaseLeafValueMultiplier = 1,
	LeafValueMultiplierPerRebirth = 1.5,
	PriceMultiplierPerRebirth = 2,
	RainbowPoopPerRebirth = 5,
}

function RebirthConfig.NormalizeCount(value)
	return math.max(0, math.floor(tonumber(value) or 0))
end

function RebirthConfig.GetLeafCountMultiplier(rebirthCount)
	return RebirthConfig.BaseLeafCountMultiplier
		+ RebirthConfig.NormalizeCount(rebirthCount) * RebirthConfig.LeafCountMultiplierPerRebirth
end

function RebirthConfig.GetLeafValueMultiplier(rebirthCount)
	return RebirthConfig.BaseLeafValueMultiplier
		+ RebirthConfig.NormalizeCount(rebirthCount) * RebirthConfig.LeafValueMultiplierPerRebirth
end

function RebirthConfig.GetRainbowPoopRequiredCount(rebirthCount)
	return (RebirthConfig.NormalizeCount(rebirthCount) + 1) * RebirthConfig.RainbowPoopPerRebirth
end

function RebirthConfig.GetPriceMultiplier(rebirthCount)
	return RebirthConfig.PriceMultiplierPerRebirth ^ RebirthConfig.NormalizeCount(rebirthCount)
end

function RebirthConfig.GetScaledPrice(basePrice, rebirthCount)
	local price = tonumber(basePrice)
	if not price or price <= 0 then
		return 0
	end
	local scaledPrice = price * RebirthConfig.GetPriceMultiplier(rebirthCount)
	if scaledPrice == math.huge then
		return math.huge
	end
	return math.max(0, math.floor(scaledPrice + 0.5))
end

return table.freeze(RebirthConfig)

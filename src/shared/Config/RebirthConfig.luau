local RebirthConfig = {
	BaseLeafCountMultiplier = 1,
	LeafCountMultiplierPerRebirth = 0.5,
	ToolAndUpgradePriceMultiplierPerRebirth = 1.5,
	RainbowPoopPerRebirth = 5,
	BaseRequiredCoins = 500,
	RequiredCoinsMultiplierPerRebirth = 2.5,
	MaximumRequiredCoins = 1e100,
}

function RebirthConfig.NormalizeCount(value)
	return math.max(0, math.floor(tonumber(value) or 0))
end

function RebirthConfig.GetLeafCountMultiplier(rebirthCount)
	return RebirthConfig.BaseLeafCountMultiplier
		+ RebirthConfig.NormalizeCount(rebirthCount) * RebirthConfig.LeafCountMultiplierPerRebirth
end

function RebirthConfig.GetLeafValueMultiplier(rebirthCount)
	return RebirthConfig.NormalizeCount(rebirthCount) + 1
end

function RebirthConfig.GetRainbowPoopRequiredCount(rebirthCount)
	return (RebirthConfig.NormalizeCount(rebirthCount) + 1) * RebirthConfig.RainbowPoopPerRebirth
end

function RebirthConfig.GetRequiredCoins(rebirthCount)
	local requiredCoins = RebirthConfig.BaseRequiredCoins
		* RebirthConfig.RequiredCoinsMultiplierPerRebirth ^ RebirthConfig.NormalizeCount(rebirthCount)
	if requiredCoins ~= requiredCoins or requiredCoins == math.huge then
		return RebirthConfig.MaximumRequiredCoins
	end
	return math.min(
		RebirthConfig.MaximumRequiredCoins,
		math.max(0, math.floor(requiredCoins + 0.5))
	)
end

function RebirthConfig.GetMoneyRequirementText(requiredCoins)
	local normalizedRequiredCoins = math.max(
		0,
		tonumber(requiredCoins) or RebirthConfig.GetRequiredCoins(0)
	)
	return string.format("Money %s", tostring(normalizedRequiredCoins))
end

function RebirthConfig.GetRainbowPoopRequirementText(rainbowPoopFoundCount, rainbowPoopRequiredCount)
	local requiredPoopCount = math.max(
		1,
		math.floor(tonumber(rainbowPoopRequiredCount) or RebirthConfig.RainbowPoopPerRebirth)
	)
	local foundPoopCount = math.clamp(
		math.floor(tonumber(rainbowPoopFoundCount) or 0),
		0,
		requiredPoopCount
	)
	return string.format("find %d/%d", foundPoopCount, requiredPoopCount)
end

function RebirthConfig.GetRequirementText(requiredCoins, rainbowPoopFoundCount, rainbowPoopRequiredCount)
	return string.format(
		"%s or %s",
		RebirthConfig.GetMoneyRequirementText(requiredCoins),
		RebirthConfig.GetRainbowPoopRequirementText(
			rainbowPoopFoundCount,
			rainbowPoopRequiredCount
		)
	)
end

function RebirthConfig.GetToolAndUpgradePriceMultiplier(rebirthCount)
	return RebirthConfig.ToolAndUpgradePriceMultiplierPerRebirth
		^ RebirthConfig.NormalizeCount(rebirthCount)
end

function RebirthConfig.GetScaledToolAndUpgradePrice(basePrice, rebirthCount)
	local price = tonumber(basePrice)
	if not price or price <= 0 then
		return 0
	end
	local scaledPrice = price * RebirthConfig.GetToolAndUpgradePriceMultiplier(rebirthCount)
	if scaledPrice == math.huge then
		return math.huge
	end
	return math.max(0, math.floor(scaledPrice + 0.5))
end

return table.freeze(RebirthConfig)

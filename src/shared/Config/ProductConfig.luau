local developerProducts = {
	Tool02Permanent = {
		Id = "Tool02Permanent",
		Kind = "PermanentTool",
		ProductId = 3612984663,
		ToolId = "Tool02",
	},
	Tool03Permanent = {
		Id = "Tool03Permanent",
		Kind = "PermanentTool",
		ProductId = 3639016284,
		ToolId = "Tool03",
	},
	BagLevel03 = {
		Id = "BagLevel03",
		Kind = "PermanentBagLevel",
		ProductId = 3639038093,
		BaseRobuxPrice = 9,
		BagLevel = 3,
	},
	BagLevel04 = {
		Id = "BagLevel04",
		Kind = "PermanentBagLevel",
		ProductId = 3639046761,
		BaseRobuxPrice = 19,
		BagLevel = 4,
	},
	BagLevel05 = {
		Id = "BagLevel05",
		Kind = "PermanentBagLevel",
		ProductId = 3639048588,
		BaseRobuxPrice = 29,
		BagLevel = 5,
	},
	BagLevel06 = {
		Id = "BagLevel06",
		Kind = "PermanentBagLevel",
		ProductId = 3639050454,
		BaseRobuxPrice = 39,
		BagLevel = 6,
	},
	BagLevel07 = {
		Id = "BagLevel07",
		Kind = "PermanentBagLevel",
		ProductId = 3639052459,
		BaseRobuxPrice = 49,
		BagLevel = 7,
	},
	BagLevel08 = {
		Id = "BagLevel08",
		Kind = "PermanentBagLevel",
		ProductId = 3639056485,
		BaseRobuxPrice = 59,
		BagLevel = 8,
	},
	SkipRebirth = {
		Id = "SkipRebirth",
		Kind = "SkipRebirth",
		ProductId = 3691791013,
	},
}

local developerProductOrder = {
	"Tool02Permanent",
	"Tool03Permanent",
	"BagLevel03",
	"BagLevel04",
	"BagLevel05",
	"BagLevel06",
	"BagLevel07",
	"BagLevel08",
	"SkipRebirth",
}

local developerProductsByProductId = {}
local developerProductsByToolId = {}
local developerProductsByBagLevel = {}
for _, productConfigId in developerProductOrder do
	local product = developerProducts[productConfigId]
	developerProductsByProductId[product.ProductId] = product
	if product.Kind == "PermanentTool" then
		developerProductsByToolId[product.ToolId] = product
	elseif product.Kind == "PermanentBagLevel" then
		developerProductsByBagLevel[product.BagLevel] = product
	end
	table.freeze(product)
end
table.freeze(developerProducts)
table.freeze(developerProductOrder)
table.freeze(developerProductsByProductId)
table.freeze(developerProductsByToolId)
table.freeze(developerProductsByBagLevel)

local ProductConfig = {
	GamePasses = {
		DoubleCoins = {
			Id = "DoubleCoins",
			GamePassId = 1935165459,
			Multiplier = 2,
		},
		QuickSell = {
			Id = "QuickSell",
			GamePassId = 1941655401,
		},
	},
	Products = {
		CleaProduct_01 = {
			Id = "CleaProduct_01",
			Kind = "ToolUnlock",
			ToolId = "Tool01",
		},
		CleaProduct_02 = {
			Id = "CleaProduct_02",
			Kind = "ToolUnlock",
			ToolId = "Tool02",
		},
		CleaProduct_03 = {
			Id = "CleaProduct_03",
			Kind = "ToolUnlock",
			ToolId = "Tool03",
		},
		BagProduct_01 = {
			Id = "BagProduct_01",
			Kind = "BagUpgrade",
		},
	},
	DeveloperProducts = developerProducts,
	DeveloperProductOrder = developerProductOrder,
	DeveloperProductsByProductId = developerProductsByProductId,
	DeveloperProductsByToolId = developerProductsByToolId,
	DeveloperProductsByBagLevel = developerProductsByBagLevel,
}

return table.freeze(ProductConfig)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local ProductService = {}

local AREA_COUNT = RegionConfig.AreaCount
local TOOL_PRODUCT_STATIONS = {
	{ InstanceName = "CleaProduct_02", ProductId = "CleaProduct_02" },
	{ InstanceName = "CleaProduct_02_1", ProductId = "CleaProduct_02", AreaId = "Area_01" },
	{ InstanceName = "CleaProduct_03", ProductId = "CleaProduct_03" },
}

local purchaseLocks = {}

local function getDirectPrompt(productPart)
	local prompt = productPart:FindFirstChild("ProximityPrompt")
	assert(
		prompt and prompt:IsA("ProximityPrompt"),
		productPart:GetFullName() .. " needs a direct ProximityPrompt"
	)
	return prompt
end

function ProductService:_registerToolProduct(area, stationConfig)
	local productPart = area:FindFirstChild(stationConfig.InstanceName)
	if not productPart then
		return
	end
	assert(productPart:IsA("BasePart"), productPart:GetFullName() .. " must be a BasePart")

	local product = ProductConfig.Products[stationConfig.ProductId]
	assert(
		product and product.Kind == "ToolUnlock",
		"Missing tool product config: " .. stationConfig.ProductId
	)
	local prompt = getDirectPrompt(productPart)
	prompt.Enabled = true
	prompt.Triggered:Connect(function(player)
		self:_purchaseTool(player, product)
	end)
end

function ProductService:_registerBagProduct(area, product)
	local productPart = area:FindFirstChild(product.Id)
	if not productPart then
		return
	end
	assert(productPart:IsA("BasePart"), productPart:GetFullName() .. " must be a BasePart")

	local prompt = getDirectPrompt(productPart)
	prompt.Enabled = true
	prompt.Triggered:Connect(function(player)
		self:_purchaseBagUpgrade(player, product)
	end)
end

function ProductService:Init(
	playerDataService,
	bagService,
	economyService,
	metricsService,
	developerProductService
)
	self.PlayerDataService = playerDataService
	self.BagService = bagService
	self.EconomyService = economyService
	self.MetricsService = metricsService
	self.DeveloperProductService = developerProductService
	self.BagUpgradePurchasedHandlers = {}
	self.ToolPurchasedHandlers = {}
	assert(
		self.DeveloperProductService
			and type(self.DeveloperProductService.PromptToolPurchase) == "function"
			and type(self.DeveloperProductService.PromptBagLevelPurchase) == "function",
		"ProductService requires DeveloperProductService"
	)
	self.DeveloperProductService:AddBagGrantedHandler(function(player, nextLevel, itemConfig)
		self:_notifyBagUpgradePurchased(player, nextLevel, itemConfig, "DeveloperProduct")
	end)

	local bagProduct = ProductConfig.Products.BagProduct_01
	assert(bagProduct and bagProduct.Kind == "BagUpgrade", "BagProduct_01 config must be a BagUpgrade")
	for areaNumber = 1, AREA_COUNT do
		local areaId = string.format("Area_%02d", areaNumber)
		local area = Workspace:FindFirstChild(areaId)
		assert(area, "Workspace." .. areaId .. " is missing")
		for _, stationConfig in TOOL_PRODUCT_STATIONS do
			if stationConfig.AreaId == nil or stationConfig.AreaId == areaId then
				self:_registerToolProduct(area, stationConfig)
			end
		end
		self:_registerBagProduct(area, bagProduct)
	end
end

function ProductService:AddBagUpgradePurchasedHandler(handler)
	table.insert(self.BagUpgradePurchasedHandlers, handler)
end

function ProductService:AddToolPurchasedHandler(handler)
	if handler then
		table.insert(self.ToolPurchasedHandlers, handler)
	end
end

function ProductService:_notifyToolPurchased(player, toolId)
	for _, handler in self.ToolPurchasedHandlers do
		local success, message = pcall(handler, player, toolId)
		if not success then
			warn("Tool-purchased handler failed: " .. tostring(message))
		end
	end
end

function ProductService:_notifyBagUpgradePurchased(player, nextLevel, itemConfig, purchaseKind)
	for _, handler in self.BagUpgradePurchasedHandlers do
		local success, message = pcall(handler, player, nextLevel, itemConfig, purchaseKind)
		if not success then
			warn("Bag-upgrade-purchased handler failed: " .. tostring(message))
		end
	end
end

function ProductService:_purchaseTool(player, product)
	if purchaseLocks[player] then
		return
	end
	purchaseLocks[player] = true

	local state = self.PlayerDataService:GetState(player)
	local toolConfig = product.Kind == "ToolUnlock" and ToolConfig.ById[product.ToolId] or nil
	if not state or not toolConfig or toolConfig.AvailableForGameplay ~= true then
		purchaseLocks[player] = nil
		return
	end

	if state.UnlockedTools[toolConfig.Id] == true then
		purchaseLocks[player] = nil
		return
	end

	local price = RebirthConfig.GetScaledPrice(toolConfig.Price, state.RebirthCount)
	if not self.EconomyService:TrySpend(player, price) then
		self.PlayerDataService:Notify(
			player,
			string.format("Not enough Coins. You need %s.", CoinFormat.Compact(price))
		)
		self.DeveloperProductService:PromptToolPurchase(player, toolConfig.Id)
		purchaseLocks[player] = nil
		return
	end
	if not self.PlayerDataService:UnlockTool(player, toolConfig.Id) then
		purchaseLocks[player] = nil
		return
	end
	state.PurchasedProducts[product.Id] = true
	self.PlayerDataService:QueuePersistentSave(player)
	if self.MetricsService then
		self.MetricsService:RecordPurchase(
			player,
			"ToolUnlock",
			toolConfig.Id,
			price,
			state.CurrentAreaId
		)
	end
	self:_notifyToolPurchased(player, toolConfig.Id)
	local equipped = self.PlayerDataService:SetEquippedTool(player, toolConfig.Id)
	if equipped then
		self.PlayerDataService:Notify(player, string.format("%s unlocked and equipped.", toolConfig.Name))
	end

	purchaseLocks[player] = nil
end

function ProductService:_purchaseBagExpansion(player, state)
	local currentExpansionLevel = BagConfig.NormalizeExpansionLevel(state.BagExpansionLevel)
	local price = BagConfig.GetNextExpansionPrice(currentExpansionLevel)
	if not price then
		self.PlayerDataService:Notify(player, "Backpack expansion is unavailable.")
		return
	end

	if not self.EconomyService:TrySpend(player, price) then
		self.PlayerDataService:Notify(
			player,
			string.format("Not enough Coins. You need %s.", CoinFormat.Compact(price))
		)
		return
	end

	local nextExpansionLevel = currentExpansionLevel + 1
	self.BagService:SetExpansionLevel(player, nextExpansionLevel)
	local capacity = self.PlayerDataService:GetBagCapacity(state)
	if self.MetricsService then
		self.MetricsService:RecordPurchase(
			player,
			"BagExpansion",
			"BagExpansion",
			price,
			state.CurrentAreaId,
			{
				ExpansionLevel = nextExpansionLevel,
				Capacity = capacity,
			}
		)
	end
	self.PlayerDataService:Notify(
		player,
		string.format("Expanded backpack capacity to %s.", CoinFormat.Compact(capacity))
	)
	self.PlayerDataService:PushSnapshot(player)
end

function ProductService:_purchaseBagUpgrade(player, product)
	if purchaseLocks[player] then
		return
	end
	purchaseLocks[player] = true

	local state = self.PlayerDataService:GetState(player)
	if not state then
		purchaseLocks[player] = nil
		return
	end

	if product.Kind ~= "BagUpgrade" then
		warn("Unsupported product kind: " .. tostring(product.Kind))
		purchaseLocks[player] = nil
		return
	end
	for _, bagId in BagConfig.PermanentOrder do
		if
			BagConfig.IsPermanentBagEnabled(bagId)
			and state.PermanentBagOwnershipReady[bagId] ~= true
		then
			self.PlayerDataService:Notify(player, "Checking permanent backpack ownership. Please wait.")
			purchaseLocks[player] = nil
			return
		end
	end

	local activePermanentBagId = self.PlayerDataService:GetActivePermanentBagId(state)
	if BagConfig.CanPurchaseExpansion(state.BagLevel, activePermanentBagId) then
		self:_purchaseBagExpansion(player, state)
		purchaseLocks[player] = nil
		return
	end

	if activePermanentBagId ~= nil then
		self.PlayerDataService:Notify(player, "Your permanent backpack is active. No standard upgrade is needed.")
		purchaseLocks[player] = nil
		return
	end

	local nextLevel = state.BagLevel + 1
	local itemConfig = BagConfig.Levels[nextLevel]
	if not itemConfig then
		self.PlayerDataService:Notify(player, "Your backpack is already max level.")
		purchaseLocks[player] = nil
		return
	end

	if not self.EconomyService:TrySpend(player, itemConfig.Price) then
		self.PlayerDataService:Notify(
			player,
			string.format("Not enough Coins. You need %s.", CoinFormat.Compact(itemConfig.Price))
		)
		self.DeveloperProductService:PromptBagLevelPurchase(player, nextLevel)
		purchaseLocks[player] = nil
		return
	end

	state.PurchasedProducts[itemConfig.ModelName] = true
	self.BagService:SetLevel(player, nextLevel)
	self.PlayerDataService:QueuePersistentSave(player)
	if self.MetricsService then
		self.MetricsService:RecordPurchase(
			player,
			"BagUpgrade",
			itemConfig.ModelName,
			itemConfig.Price,
			state.CurrentAreaId
		)
	end
	self:_notifyBagUpgradePurchased(player, nextLevel, itemConfig, "Coins")
	self.PlayerDataService:Notify(
		player,
		string.format(
			"Purchased %s (Capacity %s).",
			itemConfig.Name,
			CoinFormat.Compact(itemConfig.Capacity)
		)
	)
	self.PlayerDataService:PushSnapshot(player)
	purchaseLocks[player] = nil
end

return ProductService

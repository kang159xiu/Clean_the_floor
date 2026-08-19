local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local BagProductDisplayController = {}

local AREA_COUNT = RegionConfig.AreaCount
local EXPANSION_ICON = "rbxassetid://114584597270599"

local function setButtonState(button, costLabel, visible, enabled, text)
	button.Visible = visible == true
	button.Active = visible == true and enabled == true
	button.AutoButtonColor = visible == true and enabled == true
	button.Selectable = visible == true and enabled == true
	costLabel.Text = text or ""
end

local function bindCardNodes(card)
	if not card or not card:IsA("GuiObject") then
		return nil
	end
	local nameLabel = card:FindFirstChild("Name")
	local infoLabel = card:FindFirstChild("Info")
	local imageFrame = card:FindFirstChild("Image")
	local icon = imageFrame and imageFrame:FindFirstChild("Icon")
	local buyButtons = card:FindFirstChild("BuyButtons")
	local coinButton = buyButtons and buyButtons:FindFirstChild("Buy")
	local robuxButton = buyButtons and buyButtons:FindFirstChild("Bu2")
	local coinCost = coinButton and coinButton:FindFirstChild("Cost")
	local robuxCost = robuxButton and robuxButton:FindFirstChild("Cost")
	if
		not nameLabel
		or not nameLabel:IsA("TextLabel")
		or not infoLabel
		or not infoLabel:IsA("TextLabel")
		or not icon
		or not icon:IsA("ImageLabel")
		or not coinButton
		or not coinButton:IsA("GuiButton")
		or not robuxButton
		or not robuxButton:IsA("GuiButton")
		or not coinCost
		or not coinCost:IsA("TextLabel")
		or not robuxCost
		or not robuxCost:IsA("TextLabel")
	then
		return nil
	end
	return {
		Card = card,
		Name = nameLabel,
		Info = infoLabel,
		Icon = icon,
		CoinButton = coinButton,
		CoinCost = coinCost,
		RobuxButton = robuxButton,
		RobuxCost = robuxCost,
	}
end

local function isConfiguredArea(instance)
	if instance.Parent ~= Workspace then
		return false
	end
	local areaNumber = tonumber(instance.Name:match("^Area_(%d%d)$"))
	return areaNumber ~= nil and areaNumber >= 1 and areaNumber <= AREA_COUNT
end

local function hideVisual(instance)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = 1
	elseif instance:IsA("Decal") or instance:IsA("Texture") then
		instance.Transparency = 1
	end
end

local function hidePlaceholder(placeholder)
	hideVisual(placeholder)
	for _, descendant in placeholder:GetDescendants() do
		hideVisual(descendant)
	end
end

function BagProductDisplayController:_requestUpgradePurchase(paymentKind, targetId)
	if self.UpgradeRequestBusy or not self.Remotes.RequestBagPurchase then
		return
	end
	self.UpgradeRequestBusy = true
	task.spawn(function()
		local succeeded, result = pcall(function()
			return self.Remotes.RequestBagPurchase:InvokeServer({
				PaymentKind = paymentKind,
				TargetId = targetId,
			})
		end)
		self.UpgradeRequestBusy = false
		if not succeeded then
			warn("Backpack upgrade purchase request failed: " .. tostring(result))
		end
	end)
end

function BagProductDisplayController:_connectUpgradeCard(nodes, targetIdSource)
	local function getTargetId()
		if type(targetIdSource) == "function" then
			return targetIdSource()
		end
		return targetIdSource
	end
	nodes.CoinButton.Activated:Connect(function()
		local targetId = getTargetId()
		if nodes.CoinButton.Active and type(targetId) == "string" then
			self:_requestUpgradePurchase("Coins", targetId)
		end
	end)
	nodes.RobuxButton.Activated:Connect(function()
		local targetId = getTargetId()
		if nodes.RobuxButton.Active and type(targetId) == "string" then
			self:_requestUpgradePurchase("Robux", targetId)
		end
	end)
end

function BagProductDisplayController:_tryBindUpgradeCards()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local gameHUD = playerGui:WaitForChild("GameHUD")
	local panel = gameHUD:WaitForChild("UPattribute")
	local playerPage = panel:FindFirstChild("Player")
	if not playerPage or not playerPage:IsA("ScrollingFrame") then
		warn("[BagProductDisplayController] GameHUD.UPattribute.Player [ScrollingFrame] is missing")
		return
	end

	local standardCard = bindCardNodes(playerPage:FindFirstChild("Pickup0001"))
	if standardCard then
		standardCard.Card.Visible = true
		self.StandardUpgradeCard = standardCard
		self:_connectUpgradeCard(standardCard, function()
			return self.StandardUpgradeTargetId
		end)
	else
		warn("[BagProductDisplayController] Player.Pickup0001 has an invalid card structure")
	end

	for cardName, bagId in {
		Pickup0002 = "bag09",
		Pickup0003 = "bag010",
	} do
		local nodes = bindCardNodes(playerPage:FindFirstChild(cardName))
		if nodes then
			nodes.Card.Visible = true
			self.PermanentUpgradeCards[bagId] = nodes
			self:_connectUpgradeCard(nodes, bagId)
		else
			warn(string.format(
				"[BagProductDisplayController] Player.%s has an invalid card structure",
				cardName
			))
		end
	end
	self:_renderUpgradeCards()
end

function BagProductDisplayController:_loadRegionalPrice(itemId, assetId, infoType, basePrice)
	self.RegionalRobuxPrices[itemId] = math.max(0, math.floor(tonumber(basePrice) or 0))
	task.spawn(function()
		local success, productInfo = pcall(function()
			return MarketplaceService:GetProductInfo(assetId, infoType)
		end)
		if success and type(productInfo) == "table" and tonumber(productInfo.PriceInRobux) then
			self.RegionalRobuxPrices[itemId] = math.max(
				0,
				math.floor(tonumber(productInfo.PriceInRobux) or 0)
			)
		else
			warn("Regional backpack price lookup failed for " .. itemId .. "; using configured base price")
		end
		self:_renderUpgradeCards()
	end)
end

function BagProductDisplayController:_renderUpgradeCards()
	local currentLevel = math.clamp(
		math.floor(tonumber(self.CurrentBagLevel) or BagConfig.DefaultLevel),
		BagConfig.DefaultLevel,
		BagConfig.MaxLevel
	)
	local expansionMode = BagConfig.CanPurchaseExpansion(currentLevel, self.CurrentPermanentBagId)
	local standardCard = self.StandardUpgradeCard
	if standardCard then
		if expansionMode then
			local price = BagConfig.GetNextExpansionPrice(self.CurrentBagExpansionLevel)
			local increment = BagConfig.GetNextExpansionCapacityIncrement(self.CurrentBagExpansionLevel)
			self.StandardUpgradeTargetId = "Expansion"
			standardCard.Icon.Image = EXPANSION_ICON
			setButtonState(standardCard.RobuxButton, standardCard.RobuxCost, false, false, "")
			if price and increment then
				standardCard.Name.Text = "Bag+" .. CoinFormat.Compact(increment)
				standardCard.Info.Text = string.format(
					"%s->%s",
					CoinFormat.Compact(self.CurrentBagCapacity),
					CoinFormat.Compact(self.CurrentBagCapacity + increment)
				)
				setButtonState(
					standardCard.CoinButton,
					standardCard.CoinCost,
					true,
					true,
					"$" .. CoinFormat.Compact(price)
				)
			else
				standardCard.Name.Text = "Bag Expansion"
				standardCard.Info.Text = "MAX"
				setButtonState(standardCard.CoinButton, standardCard.CoinCost, true, false, "MAX")
			end
		else
			local nextLevel = currentLevel + 1
			local config = BagConfig.Levels[nextLevel]
			self.StandardUpgradeTargetId = config and config.ModelName or nil
			if config then
				standardCard.Name.Text = config.Name
				standardCard.Info.Text = CoinFormat.Compact(config.Capacity)
				standardCard.Icon.Image = config.Image
				setButtonState(
					standardCard.CoinButton,
					standardCard.CoinCost,
					true,
					true,
					"$" .. CoinFormat.Compact(config.Price)
				)
				local product = ProductConfig.DeveloperProductsByBagLevel[nextLevel]
				local robuxPrice = product and self.RegionalRobuxPrices[config.ModelName] or nil
				setButtonState(
					standardCard.RobuxButton,
					standardCard.RobuxCost,
					product ~= nil,
					product ~= nil,
					if robuxPrice then "R" .. tostring(robuxPrice) else "R--"
				)
			end
		end
	end

	for _, bagId in { "bag09", "bag010" } do
		local config = BagConfig.PermanentBags[bagId]
		local nodes = self.PermanentUpgradeCards[bagId]
		if nodes then
			nodes.Name.Text = config.Name
			nodes.Info.Text = CoinFormat.Compact(config.Capacity)
			nodes.Icon.Image = config.Image
			setButtonState(nodes.CoinButton, nodes.CoinCost, false, false, "")
			local owned = self.PermanentBagOwnership[bagId] == true
			local price = self.RegionalRobuxPrices[bagId]
			setButtonState(
				nodes.RobuxButton,
				nodes.RobuxCost,
				true,
				true,
				if owned then "Equip" else if price then "R" .. tostring(price) else "R--"
			)
		end
	end
end

function BagProductDisplayController:_createDisplay(station, level)
	local bagConfig = BagConfig.Levels[level]
	local accessory = self.TemplateFolder[bagConfig.ModelName]:Clone()
	accessory.Name = bagConfig.ModelName

	local displayModel = Instance.new("Model")
	displayModel.Name = string.format("LocalBagDisplay_%s_%s", station.AreaId, bagConfig.ModelName)
	accessory.Parent = displayModel
	for _, descendant in displayModel:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
	displayModel.Parent = self.DisplayFolder
	displayModel:PivotTo(station.AnchorPivot)
	return displayModel
end

function BagProductDisplayController:_tryBindDescriptionText(station)
	if station.DescriptionText and station.DescriptionText.Parent then
		return false
	end
	station.DescriptionText = nil
	station.OriginalDescriptionText = nil

	local pricePart = station.ProductPart:FindFirstChild("Part")
	local billboard = pricePart and pricePart:FindFirstChild("BillboardGui")
	local descriptionText = billboard and billboard:FindFirstChild("介绍")
	if not descriptionText or not descriptionText:IsA("TextLabel") then
		return false
	end
	station.DescriptionText = descriptionText
	station.OriginalDescriptionText = descriptionText.Text
	return true
end

function BagProductDisplayController:_renderStation(
	station,
	bagLevel,
	bagExpansionLevel,
	capacityBonus,
	permanentBagId,
	currentBagCapacity
)
	local normalizedBagLevel = math.clamp(
		math.floor(tonumber(bagLevel) or BagConfig.DefaultLevel),
		BagConfig.DefaultLevel,
		BagConfig.MaxLevel
	)
	local normalizedExpansionLevel = BagConfig.NormalizeExpansionLevel(bagExpansionLevel)
	local isExpansion = BagConfig.CanPurchaseExpansion(normalizedBagLevel, permanentBagId)
	local displayLevel = if isExpansion then BagConfig.MaxLevel else normalizedBagLevel + 1
	local bagConfig = BagConfig.Levels[displayLevel]
	local price
	local nextCapacityIncrement

	if isExpansion then
		price = BagConfig.GetNextExpansionPrice(normalizedExpansionLevel)
		nextCapacityIncrement = BagConfig.GetNextExpansionCapacityIncrement(normalizedExpansionLevel)
		local effectiveCapacity = math.max(0, math.floor(tonumber(currentBagCapacity) or 0))
		if effectiveCapacity <= 0 then
			local storageConfig = if BagConfig.IsCapacityPermanentBag(permanentBagId)
				then BagConfig.PermanentBags[permanentBagId]
				else BagConfig.Levels[normalizedBagLevel]
			effectiveCapacity = storageConfig.Capacity
				+ capacityBonus
				+ BagConfig.GetExpansionCapacityBonus(normalizedExpansionLevel)
		end
		if price and nextCapacityIncrement then
			station.Prompt.ObjectText = string.format(
				"Expand Capacity (%s)",
				CoinFormat.Compact(effectiveCapacity + nextCapacityIncrement)
			)
		else
			station.Prompt.ObjectText = string.format(
				"Capacity %s",
				CoinFormat.Compact(effectiveCapacity)
			)
		end
	else
		price = bagConfig.Price
		station.Prompt.ObjectText = string.format(
			"Capacity %s",
			CoinFormat.Compact(
				bagConfig.Capacity
					+ capacityBonus
					+ BagConfig.GetExpansionCapacityBonus(normalizedExpansionLevel)
			)
		)
	end

	station.Prompt.ActionText = if price then "Buy $" .. CoinFormat.Compact(price) else ""
	station.Prompt.Enabled = price ~= nil
	station.MoneyText.Text = if price then "$" .. CoinFormat.Compact(price) else ""
	self:_tryBindDescriptionText(station)
	if station.DescriptionText and station.DescriptionText.Parent then
		station.DescriptionText.Text = if isExpansion and price and nextCapacityIncrement
			then "Bag+" .. CoinFormat.Compact(nextCapacityIncrement)
			else station.OriginalDescriptionText
	end

	if station.DisplayLevel == displayLevel and station.Display and station.Display.Parent then
		return
	end
	if station.Display then
		station.Display:Destroy()
	end
	station.Display = self:_createDisplay(station, displayLevel)
	station.DisplayLevel = displayLevel
end

function BagProductDisplayController:ApplyBagState(
	bagLevel,
	bagExpansionLevel,
	capacityBonus,
	permanentBagId,
	bagCapacity,
	permanentBagOwnership
)
	self.CurrentBagLevel = bagLevel
	self.CurrentBagExpansionLevel = BagConfig.NormalizeExpansionLevel(bagExpansionLevel)
	self.CurrentCapacityBonus = math.max(0, math.floor(tonumber(capacityBonus) or 0))
	self.CurrentPermanentBagId = type(permanentBagId) == "string" and permanentBagId or nil
	self.CurrentBagCapacity = math.max(0, math.floor(tonumber(bagCapacity) or 0))
	self.PermanentBagOwnership = {}
	for _, bagId in BagConfig.PermanentOrder do
		self.PermanentBagOwnership[bagId] = type(permanentBagOwnership) == "table"
			and permanentBagOwnership[bagId] == true
			or false
	end
	for productPart, station in self.Stations do
		if productPart:IsDescendantOf(Workspace) then
			self:_renderStation(
				station,
				bagLevel,
				self.CurrentBagExpansionLevel,
				self.CurrentCapacityBonus,
				self.CurrentPermanentBagId,
				self.CurrentBagCapacity
			)
		else
			if station.Display then
				station.Display:Destroy()
			end
			self.Stations[productPart] = nil
		end
	end
	self:_renderUpgradeCards()
end

function BagProductDisplayController:_tryBindStation(area)
	local productPart = area:FindFirstChild("BagProduct_01")
	if not productPart then
		return
	end
	local existingStation = self.Stations[productPart]
	if existingStation then
		if self:_tryBindDescriptionText(existingStation) then
			self:_renderStation(
				existingStation,
				self.CurrentBagLevel,
				self.CurrentBagExpansionLevel,
				self.CurrentCapacityBonus,
				self.CurrentPermanentBagId,
				self.CurrentBagCapacity
			)
		end
		return
	end

	local prompt = productPart:FindFirstChild("ProximityPrompt")
	local placeholder = productPart:FindFirstChild("bag01")
	local pricePart = productPart:FindFirstChild("Part")
	local billboard = pricePart and pricePart:FindFirstChild("BillboardGui")
	local moneyText = billboard and billboard:FindFirstChild("MoneyText")
	if not prompt or not placeholder or not pricePart or not billboard or not moneyText then
		return
	end

	assert(productPart:IsA("BasePart"), productPart:GetFullName() .. " must be a BasePart")
	assert(prompt:IsA("ProximityPrompt"), prompt:GetFullName() .. " must be a ProximityPrompt")
	assert(
		placeholder:IsA("BasePart") or placeholder:IsA("Model"),
		placeholder:GetFullName() .. " must be a BasePart or Model"
	)
	assert(pricePart:IsA("BasePart"), pricePart:GetFullName() .. " must be a BasePart")
	assert(billboard:IsA("BillboardGui"), billboard:GetFullName() .. " must be a BillboardGui")
	assert(moneyText:IsA("TextLabel"), moneyText:GetFullName() .. " must be a TextLabel")

	hidePlaceholder(placeholder)
	local station = {
		AreaId = area.Name,
		ProductPart = productPart,
		Prompt = prompt,
		MoneyText = moneyText,
		DescriptionText = nil,
		OriginalDescriptionText = nil,
		AnchorPivot = placeholder:GetPivot(),
		Display = nil,
		DisplayLevel = nil,
	}
	self.Stations[productPart] = station
	productPart.AncestryChanged:Connect(function()
		if productPart:IsDescendantOf(Workspace) then
			return
		end
		if station.Display then
			station.Display:Destroy()
		end
		self.Stations[productPart] = nil
	end)
	self:_renderStation(
		station,
		self.CurrentBagLevel,
		self.CurrentBagExpansionLevel,
		self.CurrentCapacityBonus,
		self.CurrentPermanentBagId,
		self.CurrentBagCapacity
	)
end

function BagProductDisplayController:_bindArea(area)
	if not isConfiguredArea(area) or self.BoundAreas[area] then
		return
	end
	self.BoundAreas[area] = true
	self:_tryBindStation(area)
	area.DescendantAdded:Connect(function()
		task.defer(function()
			self:_tryBindStation(area)
		end)
	end)
	area.Destroying:Connect(function()
		self.BoundAreas[area] = nil
	end)
end

function BagProductDisplayController:Init(remotes)
	self.Remotes = remotes
	self.TemplateFolder = ReplicatedStorage:WaitForChild("bag")
	self.Stations = {}
	self.BoundAreas = {}
	self.StandardUpgradeCard = nil
	self.StandardUpgradeTargetId = nil
	self.PermanentUpgradeCards = {}
	self.UpgradeRequestBusy = false
	self.RegionalRobuxPrices = {}
	self.PermanentBagOwnership = {}
	self.CurrentBagLevel = BagConfig.DefaultLevel
	self.CurrentBagExpansionLevel = 0
	self.CurrentCapacityBonus = 0
	self.CurrentPermanentBagId = nil
	self.CurrentBagCapacity = BagConfig.Levels[BagConfig.DefaultLevel].Capacity

	local oldDisplayFolder = Workspace:FindFirstChild("LocalBagProductDisplays")
	if oldDisplayFolder then
		oldDisplayFolder:Destroy()
	end
	local displayFolder = Instance.new("Folder")
	displayFolder.Name = "LocalBagProductDisplays"
	displayFolder.Parent = Workspace
	self.DisplayFolder = displayFolder

	for areaNumber = 1, AREA_COUNT do
		local area = Workspace:FindFirstChild(string.format("Area_%02d", areaNumber))
		if area then
			self:_bindArea(area)
		end
	end
	Workspace.ChildAdded:Connect(function(child)
		self:_bindArea(child)
	end)
	self:_tryBindUpgradeCards()

	for level = BagConfig.DefaultLevel + 2, BagConfig.MaxLevel do
		local bag = BagConfig.Levels[level]
		local product = ProductConfig.DeveloperProductsByBagLevel[level]
		if bag and product then
			self:_loadRegionalPrice(
				bag.ModelName,
				product.ProductId,
				Enum.InfoType.Product,
				product.BaseRobuxPrice
			)
		end
	end
	for _, bagId in { "bag09", "bag010" } do
		local config = BagConfig.PermanentBags[bagId]
		if BagConfig.IsCapacityPermanentBag(bagId) then
			self:_loadRegionalPrice(
				bagId,
				config.GamePassId,
				Enum.InfoType.GamePass,
				config.BaseRobuxPrice
			)
		end
	end

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplyBagState(
			snapshot.BagLevel,
			snapshot.BagExpansionLevel,
			snapshot.BagCapacityBonus,
			snapshot.ActivePermanentBagId,
			snapshot.BagCapacity,
			snapshot.PermanentBagOwnership
		)
	end)
	self:ApplyBagState(
		self.CurrentBagLevel,
		self.CurrentBagExpansionLevel,
		self.CurrentCapacityBonus,
		self.CurrentPermanentBagId,
		self.CurrentBagCapacity,
		self.PermanentBagOwnership
	)
end

return BagProductDisplayController

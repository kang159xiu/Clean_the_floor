local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local BagProductDisplayController = {}

local AREA_COUNT = RegionConfig.AreaCount

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
	bagCapacity
)
	self.CurrentBagLevel = bagLevel
	self.CurrentBagExpansionLevel = BagConfig.NormalizeExpansionLevel(bagExpansionLevel)
	self.CurrentCapacityBonus = math.max(0, math.floor(tonumber(capacityBonus) or 0))
	self.CurrentPermanentBagId = type(permanentBagId) == "string" and permanentBagId or nil
	self.CurrentBagCapacity = math.max(0, math.floor(tonumber(bagCapacity) or 0))
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
	self.TemplateFolder = ReplicatedStorage:WaitForChild("bag")
	self.Stations = {}
	self.BoundAreas = {}
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

	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplyBagState(
			snapshot.BagLevel,
			snapshot.BagExpansionLevel,
			snapshot.BagCapacityBonus,
			snapshot.ActivePermanentBagId,
			snapshot.BagCapacity
		)
	end)
	self:ApplyBagState(
		self.CurrentBagLevel,
		self.CurrentBagExpansionLevel,
		self.CurrentCapacityBonus,
		self.CurrentPermanentBagId,
		self.CurrentBagCapacity
	)
end

return BagProductDisplayController

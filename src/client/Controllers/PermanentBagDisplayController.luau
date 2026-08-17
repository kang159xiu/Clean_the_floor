local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)

local PermanentBagDisplayController = {}

function PermanentBagDisplayController:_getConfigForStation(station)
	for _, bagId in BagConfig.PermanentOrder do
		local config = BagConfig.PermanentBags[bagId]
		if string.lower(station.Name) == string.lower(config.StationName) then
			return config
		end
	end
	return nil
end

function PermanentBagDisplayController:_shouldHide(bagId)
	return not BagConfig.IsPermanentBagEnabled(bagId)
end

function PermanentBagDisplayController:_findPriceLabel(station)
	local guiPart = station:FindFirstChild("GuiPart")
	local billboard = guiPart and guiPart:FindFirstChild("BillboardGui")
	local cost = billboard and billboard:FindFirstChild("cost")
	local priceLabel = cost and cost:FindFirstChild("TextLabel")
	return if priceLabel and priceLabel:IsA("TextLabel") then priceLabel else nil
end

function PermanentBagDisplayController:_findCapacityLabel(station)
	local guiPart = station:FindFirstChild("GuiPart")
	local billboard = guiPart and guiPart:FindFirstChild("BillboardGui")
	local frame = billboard and billboard:FindFirstChild("Frame")
	local capacityLabel = frame and frame:FindFirstChild("TextLabel")
	return if capacityLabel and capacityLabel:IsA("TextLabel") then capacityLabel else nil
end

function PermanentBagDisplayController:_applyVisibility(instance, hidden)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = if hidden then 1 else 0
	elseif instance:IsA("BillboardGui") then
		instance.Enabled = not hidden
	elseif instance:IsA("ProximityPrompt") then
		instance.Enabled = not hidden
	end
end

function PermanentBagDisplayController:_renderStation(station, stationState)
	if not station:IsDescendantOf(Workspace) then
		self.Stations[station] = nil
		return
	end
	local hidden = self:_shouldHide(stationState.Config.Id)
	local owned = self.Ownership[stationState.Config.Id] == true
	self:_applyVisibility(station, hidden)
	for _, descendant in station:GetDescendants() do
		self:_applyVisibility(descendant, hidden)
	end
	local prompt = station:FindFirstChild("ProximityPrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = not hidden
		prompt.ActionText = if owned then "Equip" else "Buy"
		prompt.ObjectText = stationState.Config.Name
	end

	local priceLabel = self:_findPriceLabel(station)
	stationState.PriceLabel = priceLabel
	if priceLabel then
		priceLabel.Text = if owned
			then "Owned"
			else CoinFormat.Compact(self.DisplayedPrices[stationState.Config.Id])
	end
	local capacityLabel = self:_findCapacityLabel(station)
	stationState.CapacityLabel = capacityLabel
	if capacityLabel and stationState.Config.Behavior == "Capacity" then
		capacityLabel.Text = "Capacity: " .. CoinFormat.Compact(stationState.Config.Capacity)
	end
end

function PermanentBagDisplayController:_renderAllStations()
	for station, stationState in self.Stations do
		self:_renderStation(station, stationState)
	end
end

function PermanentBagDisplayController:ApplySnapshot(snapshot)
	local ownership = type(snapshot.PermanentBagOwnership) == "table"
		and snapshot.PermanentBagOwnership
		or {}
	for _, bagId in BagConfig.PermanentOrder do
		self.Ownership[bagId] = BagConfig.IsPermanentBagEnabled(bagId) and ownership[bagId] == true
	end
	self:_renderAllStations()
end

function PermanentBagDisplayController:_tryBindStation(station)
	if station.Parent ~= self.FunctionFolder or self.Stations[station] then
		return
	end
	local config = self:_getConfigForStation(station)
	if not config then
		return
	end
	local stationState = {
		Config = config,
		PriceLabel = self:_findPriceLabel(station),
		CapacityLabel = self:_findCapacityLabel(station),
	}
	self.Stations[station] = stationState
	if BagConfig.IsPermanentBagEnabled(config.Id) and not stationState.PriceLabel then
		warn("Permanent bag regional price label is missing: " .. station:GetFullName())
	end
	self:_renderStation(station, stationState)
	station.DescendantAdded:Connect(function(descendant)
		self:_applyVisibility(descendant, self:_shouldHide(config.Id))
		task.defer(function()
			if self.Stations[station] == stationState then
				self:_renderStation(station, stationState)
			end
		end)
	end)
	station.Destroying:Connect(function()
		self.Stations[station] = nil
	end)
end

function PermanentBagDisplayController:_loadRegionalPrice(config)
	if not BagConfig.IsPermanentBagEnabled(config.Id) then
		return
	end
	local success, productInfo = pcall(function()
		return MarketplaceService:GetProductInfo(config.GamePassId, Enum.InfoType.GamePass)
	end)
	if success and type(productInfo) == "table" and tonumber(productInfo.PriceInRobux) then
		self.DisplayedPrices[config.Id] = math.max(0, math.floor(tonumber(productInfo.PriceInRobux) or 0))
	else
		warn(config.Id .. " regional price lookup failed; using configured base price")
		self.DisplayedPrices[config.Id] = math.max(0, math.floor(tonumber(config.BaseRobuxPrice) or 0))
	end
	self:_renderAllStations()
end

function PermanentBagDisplayController:Init(remotes)
	self.FunctionFolder = Workspace:WaitForChild("Function")
	self.Stations = {}
	self.Ownership = {}
	self.DisplayedPrices = {}
	for _, bagId in BagConfig.PermanentOrder do
		local config = BagConfig.PermanentBags[bagId]
		self.Ownership[bagId] = false
		self.DisplayedPrices[bagId] = math.max(0, math.floor(tonumber(config.BaseRobuxPrice) or 0))
	end

	for _, station in self.FunctionFolder:GetChildren() do
		self:_tryBindStation(station)
	end
	self.FunctionFolder.ChildAdded:Connect(function(station)
		task.defer(function()
			self:_tryBindStation(station)
		end)
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
	for _, bagId in BagConfig.PermanentOrder do
		if BagConfig.IsPermanentBagEnabled(bagId) then
			task.spawn(function()
				self:_loadRegionalPrice(BagConfig.PermanentBags[bagId])
			end)
		end
	end
end

return PermanentBagDisplayController

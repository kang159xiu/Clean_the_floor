local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local ToolGamePassDisplayController = {}

local TOOL_ID = "Tool04"

local function getConfig()
	local config = ToolConfig.ById[TOOL_ID]
	assert(config and config.PurchaseKind == "GamePass", "Tool04 Game Pass config is missing")
	return config
end

function ToolGamePassDisplayController:_setDisplayedPrice(price)
	local normalizedPrice = math.max(0, math.floor(tonumber(price) or 0))
	for station, stationState in self.Stations do
		local priceLabel = stationState.PriceLabel
		if station:IsDescendantOf(Workspace) then
			if priceLabel and priceLabel:IsDescendantOf(station) then
				priceLabel.Text = CoinFormat.Compact(normalizedPrice)
			end
		else
			self.Stations[station] = nil
		end
	end
end

function ToolGamePassDisplayController:_findPriceLabel(station)
	local guiPart = station:FindFirstChild("GuiPart")
	local billboard = guiPart and guiPart:FindFirstChild("BillboardGui")
	local cost = billboard and billboard:FindFirstChild("cost")
	local priceLabel = cost and cost:FindFirstChild("TextLabel")
	return if priceLabel and priceLabel:IsA("TextLabel") then priceLabel else nil
end

function ToolGamePassDisplayController:_applyVisibility(instance)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = if self.Owned then 1 else 0
	elseif instance:IsA("Beam") then
		local originalEnabled = self.OriginalBeamEnabled[instance]
		if originalEnabled == nil then
			originalEnabled = instance.Enabled
			self.OriginalBeamEnabled[instance] = originalEnabled
		end
		instance.Enabled = if self.Owned then false else originalEnabled
	elseif instance:IsA("BillboardGui") then
		instance.Enabled = not self.Owned
	elseif instance:IsA("ProximityPrompt") then
		instance.Enabled = not self.Owned
	end
end

function ToolGamePassDisplayController:_renderStation(station, stationState)
	if not station:IsDescendantOf(Workspace) then
		self.Stations[station] = nil
		return
	end

	self:_applyVisibility(station)
	for _, descendant in station:GetDescendants() do
		self:_applyVisibility(descendant)
	end

	local priceLabel = self:_findPriceLabel(station)
	if priceLabel then
		stationState.PriceLabel = priceLabel
		priceLabel.Text = CoinFormat.Compact(self.DisplayedPrice)
	else
		stationState.PriceLabel = nil
	end
end

function ToolGamePassDisplayController:_renderAllStations()
	for station, stationState in self.Stations do
		self:_renderStation(station, stationState)
	end
end

function ToolGamePassDisplayController:ApplySnapshot(snapshot)
	local unlockedTools = type(snapshot.UnlockedTools) == "table" and snapshot.UnlockedTools or {}
	self.Owned = unlockedTools[TOOL_ID] == true
	self:_renderAllStations()
end

function ToolGamePassDisplayController:_tryBindStation(station)
	if
		station.Parent ~= self.FunctionFolder
		or string.lower(station.Name) ~= string.lower(TOOL_ID)
		or self.Stations[station]
	then
		return
	end

	local stationState = {
		PriceLabel = self:_findPriceLabel(station),
	}
	self.Stations[station] = stationState
	if not stationState.PriceLabel then
		warn(string.format("Tool04 regional price label is missing: %s", station:GetFullName()))
	end

	self:_renderStation(station, stationState)
	station.DescendantAdded:Connect(function(descendant)
		self:_applyVisibility(descendant)
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

function ToolGamePassDisplayController:_bindAllStations()
	for _, child in self.FunctionFolder:GetChildren() do
		self:_tryBindStation(child)
	end
end

function ToolGamePassDisplayController:_loadRegionalPrice()
	local config = getConfig()
	local success, productInfo = pcall(function()
		return MarketplaceService:GetProductInfo(config.GamePassId, Enum.InfoType.GamePass)
	end)
	if success and type(productInfo) == "table" and tonumber(productInfo.PriceInRobux) then
		self.DisplayedPrice = math.max(0, math.floor(tonumber(productInfo.PriceInRobux) or 0))
	else
		warn("Tool04 regional price lookup failed; using configured base price")
		self.DisplayedPrice = math.max(0, math.floor(tonumber(config.BaseRobuxPrice) or 0))
	end
	self:_setDisplayedPrice(self.DisplayedPrice)
end

function ToolGamePassDisplayController:Init(remotes)
	local config = getConfig()
	self.FunctionFolder = Workspace:WaitForChild("Function")
	self.Stations = {}
	self.OriginalBeamEnabled = setmetatable({}, { __mode = "k" })
	self.Owned = false
	self.DisplayedPrice = math.max(0, math.floor(tonumber(config.BaseRobuxPrice) or 0))

	self:_bindAllStations()
	self.FunctionFolder.ChildAdded:Connect(function(child)
		task.defer(function()
			self:_tryBindStation(child)
		end)
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
	task.spawn(function()
		self:_loadRegionalPrice()
	end)
end

return ToolGamePassDisplayController

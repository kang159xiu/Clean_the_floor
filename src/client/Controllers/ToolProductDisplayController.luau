local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local RebirthConfig = require(ReplicatedStorage.Shared.Config.RebirthConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local ToolProductDisplayController = {}

local AREA_COUNT = RegionConfig.AreaCount
local PRODUCT_STATIONS = {
	{ InstanceName = "CleaProduct_02", ProductId = "CleaProduct_02" },
	{ InstanceName = "CleaProduct_02_1", ProductId = "CleaProduct_02", AreaId = "Area_01" },
	{ InstanceName = "CleaProduct_03", ProductId = "CleaProduct_03" },
}
local PRICE_LABEL_PATHS = {
	CleaProduct_02 = { "saoba", "Grip", "BillboardGui", "MoneyText" },
	CleaProduct_03 = { "cost", "BillboardGui", "MoneyText" },
}

local function findNested(instance, path)
	local current = instance
	for _, childName in path do
		current = current and current:FindFirstChild(childName)
	end
	return current
end

function ToolProductDisplayController:_renderStation(station)
	local tool = ToolConfig.ById[station.ToolId]
	local price = RebirthConfig.GetScaledPrice(tool.Price, self.RebirthCount)
	local priceText = "$" .. CoinFormat.Compact(price)
	local priceLabel = findNested(station.Part, PRICE_LABEL_PATHS[station.ProductId])
	local isOwned = self.UnlockedTools[station.ToolId] == true
	if priceLabel and priceLabel:IsA("TextLabel") then
		priceLabel.Text = if isOwned then "Owned" else priceText
	end
	station.Prompt.ObjectText = tool.Name
	station.Prompt.Enabled = not isOwned
	if not isOwned then
		station.Prompt.ActionText = "Buy " .. priceText
	end
end

function ToolProductDisplayController:_renderAll()
	for part, station in self.Stations do
		if part:IsDescendantOf(Workspace) then
			self:_renderStation(station)
		else
			self.Stations[part] = nil
		end
	end
end

function ToolProductDisplayController:_tryBindProduct(area, stationConfig)
	local part = area:FindFirstChild(stationConfig.InstanceName)
	if not part or self.Stations[part] then
		return
	end
	local product = ProductConfig.Products[stationConfig.ProductId]
	local prompt = part:FindFirstChild("ProximityPrompt")
	assert(part:IsA("BasePart"), part:GetFullName() .. " must be a BasePart")
	assert(
		product and product.Kind == "ToolUnlock",
		"Missing tool product config: " .. stationConfig.ProductId
	)
	assert(prompt and prompt:IsA("ProximityPrompt"), part:GetFullName() .. ".ProximityPrompt is missing")

	local station = {
		Part = part,
		ProductId = stationConfig.ProductId,
		ToolId = product.ToolId,
		Prompt = prompt,
	}
	self.Stations[part] = station
	part.Destroying:Connect(function()
		self.Stations[part] = nil
	end)
	part.DescendantAdded:Connect(function()
		task.defer(function()
			if self.Stations[part] == station then
				self:_renderStation(station)
			end
		end)
	end)
	self:_renderStation(station)
end

function ToolProductDisplayController:_bindArea(area)
	local areaNumber = tonumber(area.Name:match("^Area_(%d%d)$"))
	if
		area.Parent ~= Workspace
		or not areaNumber
		or areaNumber < 1
		or areaNumber > AREA_COUNT
		or self.BoundAreas[area]
	then
		return
	end

	self.BoundAreas[area] = true
	for _, stationConfig in PRODUCT_STATIONS do
		if stationConfig.AreaId == nil or stationConfig.AreaId == area.Name then
			self:_tryBindProduct(area, stationConfig)
		end
	end
	area.ChildAdded:Connect(function()
		for _, stationConfig in PRODUCT_STATIONS do
			if stationConfig.AreaId == nil or stationConfig.AreaId == area.Name then
				self:_tryBindProduct(area, stationConfig)
			end
		end
	end)
	area.Destroying:Connect(function()
		self.BoundAreas[area] = nil
	end)
end

function ToolProductDisplayController:Init(remotes)
	self.Stations = {}
	self.BoundAreas = {}
	self.RebirthCount = 0
	self.UnlockedTools = { Tool01 = true }

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
		self.RebirthCount = RebirthConfig.NormalizeCount(snapshot.RebirthCount)
		self.UnlockedTools = snapshot.UnlockedTools
		self:_renderAll()
	end)
end

return ToolProductDisplayController

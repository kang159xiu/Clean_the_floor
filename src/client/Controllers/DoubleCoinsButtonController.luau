local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local RegionConfig = require(ReplicatedStorage.Shared.Config.RegionConfig)

local DoubleCoinsButtonController = {}

function DoubleCoinsButtonController:_refresh()
	local visible = self.OwnershipReady and not self.Owned
	self.Button.Visible = visible
	self.Button.Active = visible and not self.PromptRunning
	self.Button.Interactable = visible and not self.PromptRunning
	self:_renderAllAreaSigns()
end

function DoubleCoinsButtonController:_promptPurchase()
	if self.PromptRunning or not self.OwnershipReady or self.Owned then
		return
	end
	self.PromptRunning = true
	self:_refresh()

	local success, message = pcall(function()
		MarketplaceService:PromptGamePassPurchase(self.Player, self.GamePassId)
	end)
	if not success then
		warn("Unable to open Double Coins purchase prompt: " .. tostring(message))
		self.PromptRunning = false
		self:_refresh()
	end
end

function DoubleCoinsButtonController:_loadRegionalPrice()
	local success, productInfo = pcall(function()
		return MarketplaceService:GetProductInfo(self.GamePassId, Enum.InfoType.GamePass)
	end)
	local regionalPrice = success and type(productInfo) == "table" and tonumber(productInfo.PriceInRobux) or nil
	if regionalPrice then
		self.PriceLabel.Text = CoinFormat.Compact(math.max(0, math.floor(regionalPrice)))
	else
		warn("Double Coins regional price lookup failed; keeping Studio price text")
	end
end

function DoubleCoinsButtonController:_isAreaSign(sign)
	local area = sign and sign.Parent
	return sign ~= nil
		and sign.Name == "Sign"
		and area ~= nil
		and area.Parent == Workspace
		and RegionConfig.IsActiveAreaId(area.Name)
end

function DoubleCoinsButtonController:_applyAreaSignVisibility(instance)
	if instance:IsA("BasePart") then
		local originalModifier = self.OriginalSignPartTransparency[instance]
		if originalModifier == nil then
			originalModifier = instance.LocalTransparencyModifier
			self.OriginalSignPartTransparency[instance] = originalModifier
		end
		instance.LocalTransparencyModifier = if self.Owned then 1 else originalModifier
	elseif instance:IsA("SurfaceGui") then
		local originalEnabled = self.OriginalSignSurfaceGuiEnabled[instance]
		if originalEnabled == nil then
			originalEnabled = instance.Enabled
			self.OriginalSignSurfaceGuiEnabled[instance] = originalEnabled
		end
		instance.Enabled = if self.Owned then false else originalEnabled
	end
end

function DoubleCoinsButtonController:_renderAreaSign(sign)
	if not self:_isAreaSign(sign) then
		self.AreaSigns[sign] = nil
		return
	end
	self:_applyAreaSignVisibility(sign)
	for _, descendant in sign:GetDescendants() do
		self:_applyAreaSignVisibility(descendant)
	end
end

function DoubleCoinsButtonController:_renderAllAreaSigns()
	for sign in self.AreaSigns do
		self:_renderAreaSign(sign)
	end
end

function DoubleCoinsButtonController:_tryBindAreaSign(sign)
	if not self:_isAreaSign(sign) or self.AreaSigns[sign] then
		return
	end
	self.AreaSigns[sign] = true
	self:_renderAreaSign(sign)
	sign.DescendantAdded:Connect(function(descendant)
		if self.AreaSigns[sign] then
			self:_applyAreaSignVisibility(descendant)
			if descendant:IsA("TextButton") then
				self:_tryBindAreaSignButton(descendant)
			end
		end
	end)
	sign.Destroying:Connect(function()
		self.AreaSigns[sign] = nil
	end)
end

function DoubleCoinsButtonController:_isAreaSignButton(button)
	if not button:IsA("TextButton") or button.Name ~= "TextButton" then
		return false
	end
	local surfaceGui = button.Parent
	local innerSign = surfaceGui and surfaceGui.Parent
	local outerSign = innerSign and innerSign.Parent
	local area = outerSign and outerSign.Parent
	return surfaceGui ~= nil
		and surfaceGui:IsA("SurfaceGui")
		and surfaceGui.Name == "SurfaceGui"
		and innerSign ~= nil
		and innerSign.Name == "Sign"
		and outerSign ~= nil
		and outerSign.Name == "Sign"
		and area ~= nil
		and area.Parent == Workspace
		and RegionConfig.IsActiveAreaId(area.Name)
end

function DoubleCoinsButtonController:_tryBindAreaSignButton(button)
	if self.SignButtons[button] or not self:_isAreaSignButton(button) then
		return
	end
	local surfaceGui = button.Parent
	local innerSign = surfaceGui and surfaceGui.Parent
	local outerSign = innerSign and innerSign.Parent
	self:_tryBindAreaSign(outerSign)
	self.SignButtons[button] = true
	button.Activated:Connect(function()
		if self:_isAreaSignButton(button) then
			self:_promptPurchase()
		end
	end)
end

function DoubleCoinsButtonController:_bindLoadedAreaSigns()
	for _, areaId in RegionConfig.Order do
		local area = Workspace:FindFirstChild(areaId)
		local outerSign = area and area:FindFirstChild("Sign")
		if outerSign then
			self:_tryBindAreaSign(outerSign)
		end
		local innerSign = outerSign and outerSign:FindFirstChild("Sign")
		local surfaceGui = innerSign and innerSign:FindFirstChild("SurfaceGui")
		local button = surfaceGui and surfaceGui:FindFirstChild("TextButton")
		if button then
			self:_tryBindAreaSignButton(button)
		end
	end
end

function DoubleCoinsButtonController:ApplySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	self.OwnershipReady = snapshot.DoubleCoinsOwnershipReady == true
	self.Owned = snapshot.DoubleCoinsOwned == true
	self:_refresh()
end

function DoubleCoinsButtonController:Init(remotes)
	local config = ProductConfig.GamePasses and ProductConfig.GamePasses.DoubleCoins
	assert(config and tonumber(config.GamePassId), "DoubleCoins game pass config is missing")

	self.Player = Players.LocalPlayer
	self.GamePassId = config.GamePassId
	self.OwnershipReady = false
	self.Owned = false
	self.PromptRunning = false
	self.AreaSigns = setmetatable({}, { __mode = "k" })
	self.SignButtons = setmetatable({}, { __mode = "k" })
	self.OriginalSignPartTransparency = setmetatable({}, { __mode = "k" })
	self.OriginalSignSurfaceGuiEnabled = setmetatable({}, { __mode = "k" })

	local gameHUD = self.Player:WaitForChild("PlayerGui"):WaitForChild("GameHUD")
	local hudRoot = gameHUD:WaitForChild("HUDRoot")
	assert(hudRoot:IsA("GuiObject"), "GameHUD.HUDRoot must be a GuiObject")
	self.Button = hudRoot:WaitForChild("x2coins")
	assert(self.Button:IsA("GuiButton"), "GameHUD.HUDRoot.x2coins must be a GuiButton")
	self.PriceLabel = self.Button:FindFirstChild("Rb")
	assert(
		self.PriceLabel and self.PriceLabel:IsA("TextLabel"),
		"GameHUD.HUDRoot.x2coins.Rb must be a TextLabel"
	)

	self.Button.Visible = false
	self.Button.Active = false
	self.Button.Interactable = false
	self.Button.Activated:Connect(function()
		self:_promptPurchase()
	end)
	self:_bindLoadedAreaSigns()
	Workspace.DescendantAdded:Connect(function(descendant)
		if descendant.Name == "Sign" then
			self:_tryBindAreaSign(descendant)
		end
		if descendant:IsA("TextButton") then
			self:_tryBindAreaSignButton(descendant)
		end
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId)
		if player ~= self.Player or gamePassId ~= self.GamePassId then
			return
		end
		self.PromptRunning = false
		self:_refresh()
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
	task.spawn(function()
		self:_loadRegionalPrice()
	end)
end

return DoubleCoinsButtonController

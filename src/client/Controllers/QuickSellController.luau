local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)

local QuickSellController = {}

local function getConfig()
	local config = ProductConfig.GamePasses and ProductConfig.GamePasses.QuickSell
	assert(config and tonumber(config.GamePassId), "Quick Sell game pass config is missing")
	return config
end

function QuickSellController:_refreshButton()
	local interactable = not self.RequestRunning and not self.PromptRunning
	self.Button.Visible = true
	self.Button.Active = interactable
	self.Button.Interactable = interactable
end

function QuickSellController:_promptPurchase()
	if self.PromptRunning or self.RequestRunning then
		return
	end
	self.PromptRunning = true
	self:_refreshButton()
	local success, message = pcall(function()
		MarketplaceService:PromptGamePassPurchase(self.Player, self.Config.GamePassId)
	end)
	if not success then
		warn("Quick Sell purchase prompt failed: " .. tostring(message))
		self.PromptRunning = false
		self:_refreshButton()
		self.HUDController:ShowNotification("The Quick Sell purchase window is unavailable.", 3, true)
	end
end

function QuickSellController:_requestQuickSell()
	if self.RequestRunning or self.PromptRunning then
		return
	end
	if not self.OwnershipReady then
		self.HUDController:ShowNotification("Checking Quick Sell ownership. Try again shortly.", 3, true)
		return
	end
	if not self.Owned then
		self:_promptPurchase()
		return
	end

	self.RequestRunning = true
	self:_refreshButton()
	local succeeded, result = pcall(function()
		return self.Remotes.RequestQuickSell:InvokeServer()
	end)
	self.RequestRunning = false
	self:_refreshButton()

	if not succeeded or type(result) ~= "table" then
		self.HUDController:ShowNotification("Quick Sell is unavailable. Try again.", 3, true)
		return
	end
	if result.Status == "NotOwned" then
		self.Owned = false
		self.OwnershipReady = true
		self:_promptPurchase()
	elseif result.Status == "Busy" then
		self.HUDController:ShowNotification("Quick Sell is already processing.", 2, true)
	elseif result.Status == "Unavailable" then
		self.HUDController:ShowNotification("Quick Sell is unavailable. Try again.", 3, true)
	end
	-- Sold uses the existing authoritative coin animations. Empty is intentionally silent.
end

function QuickSellController:ApplySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	if type(snapshot.QuickSellOwned) == "boolean" then
		self.Owned = snapshot.QuickSellOwned
	end
	if type(snapshot.QuickSellOwnershipReady) == "boolean" then
		self.OwnershipReady = snapshot.QuickSellOwnershipReady
	end
	self:_refreshButton()
end

function QuickSellController:Init(remotes, hudController)
	self.Player = Players.LocalPlayer
	self.Remotes = remotes
	self.HUDController = hudController
	self.Config = getConfig()
	self.Owned = false
	self.OwnershipReady = false
	self.RequestRunning = false
	self.PromptRunning = false

	local gameHUD = self.Player:WaitForChild("PlayerGui"):WaitForChild("GameHUD")
	self.Button = gameHUD:WaitForChild("Frame"):WaitForChild("QuickSell")
	assert(self.Button:IsA("GuiButton"), "GameHUD.Frame.QuickSell must be a GuiButton")
	assert(remotes.RequestQuickSell:IsA("RemoteFunction"), "RequestQuickSell must be a RemoteFunction")
	self:_refreshButton()

	self.Button.Activated:Connect(function()
		self:_requestQuickSell()
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId)
		if player == self.Player and gamePassId == self.Config.GamePassId then
			self.PromptRunning = false
			self:_refreshButton()
		end
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
end

return QuickSellController

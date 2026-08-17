local Players = game:GetService("Players")

local AdminTestConfig = require(script.Parent.Parent.AdminTestConfig)

local AdminResetService = {}

local REQUEST_COOLDOWN = 2
local requestLocks = {}
local requestTimes = {}

function AdminResetService:_tryReset(player)
	if not AdminTestConfig.IsAllowed(player.Name) then
		return false, "You do not have test reset permission."
	end
	if requestLocks[player] then
		return false, "Data reset is in progress. Please wait."
	end

	local state = self.PlayerDataService:GetState(player)
	if not state then
		return false, "Player data is not ready."
	end

	requestLocks[player] = true
	self.YardService:ReturnHome(player)
	self.ToolActionService:StopPlayer(player)
	self.LeafService:SetPickupActive(player, false)
	local toolResetBegan = self.CleaningToolService:BeginPlayerReset(player)

	local resetSucceeded, persisted = self.PlayerDataService:ResetForAdminTest(player, AdminTestConfig.InitialCoins)
	if not resetSucceeded then
		if toolResetBegan then
			self.CleaningToolService:CompletePlayerReset(player)
		end
		requestLocks[player] = nil
		return false, persisted
	end

	self.LostItemService:ResetYard(player)
	self.PoopService:ResetYard(player)
	self.TutorialService:ResetPlayer(player)
	self.LeafService:ResetOwnerYard(player)
	self.PlayerDataService:PushSnapshot(player)

	if player.Parent == Players then
		local loadedCharacter, loadError = pcall(function()
			player:LoadCharacterAsync()
		end)
		if not loadedCharacter then
			warn("Admin reset character reload failed: " .. tostring(loadError))
		end
	end
	if toolResetBegan then
		self.CleaningToolService:CompletePlayerReset(player)
	end

	requestLocks[player] = nil
	if persisted then
		return true, "Data reset complete."
	end
	return true, "Data was reset temporarily. Studio cannot save to DataStore right now."
end

function AdminResetService:Init(
	playerDataService,
	yardService,
	leafService,
	lostItemService,
	tutorialService,
	toolActionService,
	poopService,
	cleaningToolService,
	resetRemote
)
	self.PlayerDataService = playerDataService
	self.YardService = yardService
	self.LeafService = leafService
	self.LostItemService = lostItemService
	self.TutorialService = tutorialService
	self.ToolActionService = toolActionService
	self.PoopService = poopService
	self.CleaningToolService = cleaningToolService

	resetRemote.OnServerInvoke = function(player)
		if not AdminTestConfig.IsAllowed(player.Name) then
			return false, "You do not have test reset permission."
		end
		local now = os.clock()
		if now - (requestTimes[player] or -math.huge) < REQUEST_COOLDOWN then
			return false, "Too fast."
		end
		requestTimes[player] = now
		return self:_tryReset(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		requestLocks[player] = nil
		requestTimes[player] = nil
	end)
end

return AdminResetService

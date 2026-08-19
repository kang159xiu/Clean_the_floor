local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BOOTSTRAP_DIAGNOSTICS_ENABLED = true
local BOOTSTRAP_STALL_WARNING_SECONDS = 10
local BOOTSTRAP_LOG_PREFIX = "[CTF ServerBootstrap]"
local PROGRESS_SAVE_REQUEST_INTERVAL = 10
local bootstrapStartedAt = os.clock()

local function logBootstrap(status, stepName, detail)
	if not BOOTSTRAP_DIAGNOSTICS_ENABLED then
		return
	end
	local suffix = if type(detail) == "string" and detail ~= "" then " | " .. detail else ""
	print(string.format("%s %s %s%s", BOOTSTRAP_LOG_PREFIX, status, stepName, suffix))
end

local function runBootstrapStep(stepName, callback)
	if not BOOTSTRAP_DIAGNOSTICS_ENABLED then
		return callback()
	end
	local startedAt = os.clock()
	local completed = false
	logBootstrap("START", stepName)
	task.delay(BOOTSTRAP_STALL_WARNING_SECONDS, function()
		if not completed then
			warn(string.format(
				"%s STALLED %s | running for at least %.1fs",
				BOOTSTRAP_LOG_PREFIX,
				stepName,
				BOOTSTRAP_STALL_WARNING_SECONDS
			))
		end
	end)
	local results = table.pack(xpcall(callback, debug.traceback))
	completed = true
	local elapsedMilliseconds = math.floor((os.clock() - startedAt) * 1000 + 0.5)
	if not results[1] then
		warn(string.format(
			"%s FAILED %s | %dms\n%s",
			BOOTSTRAP_LOG_PREFIX,
			stepName,
			elapsedMilliseconds,
			tostring(results[2])
		))
		error(results[2], 0)
	end
	logBootstrap("OK", stepName, string.format("%dms", elapsedMilliseconds))
	return table.unpack(results, 2, results.n)
end

logBootstrap("START", "Bootstrap")

local Constants = runBootstrapStep("Module:Constants", function()
	return require(ReplicatedStorage.Shared.Constants)
end)
local LostItemConfig = runBootstrapStep("Module:LostItemConfig", function()
	return require(ReplicatedStorage.Shared.Config.LostItemConfig)
end)
local CoopMatchConfig = runBootstrapStep("Module:CoopMatchConfig", function()
	return require(ReplicatedStorage.Shared.Config.CoopMatchConfig)
end)
local IS_COOP = CoopMatchConfig.IsCoop()
local IS_LOBBY = CoopMatchConfig.IsLobby()

local servicesFolder = runBootstrapStep("ServicesFolder", function()
	return script:WaitForChild("Services")
end)
local function loadServiceModule(name)
	return runBootstrapStep("Module:" .. name, function()
		return require(servicesFolder:WaitForChild(name))
	end)
end

local PlayerDataService = loadServiceModule("PlayerDataService")
local BagService = loadServiceModule("BagService")
local CharacterScaleService = loadServiceModule("CharacterScaleService")
local BagVisualService = loadServiceModule("BagVisualService")
local EconomyService = loadServiceModule("EconomyService")
local HandUpgradeService = loadServiceModule("HandUpgradeService")
local ToolUpgradeService = loadServiceModule("ToolUpgradeService")
local PlayerAttributeUpgradeService = loadServiceModule("PlayerAttributeUpgradeService")
local PlaytestMetricsService = loadServiceModule("PlaytestMetricsService")
local ClearTimeLeaderboardService = loadServiceModule("ClearTimeLeaderboardService")
local PlaytimeLeaderboardService = loadServiceModule("PlaytimeLeaderboardService")
local CleanupLeaderboardService = loadServiceModule("CleanupLeaderboardService")
local PoopLeaderboardService = loadServiceModule("PoopLeaderboardService")
local PlayerAreaService = loadServiceModule("PlayerAreaService")
local LeafService = loadServiceModule("LeafService")
local AreaCoinResetService = loadServiceModule("AreaCoinResetService")
local LostItemService = loadServiceModule("LostItemService")
local CleaningToolService = loadServiceModule("CleaningToolService")
local CleaningToolActionService = loadServiceModule("CleaningToolActionService")
local RecycleService = loadServiceModule("RecycleService")
local QuickSellService = loadServiceModule("QuickSellService")
local ReturnToSpawnService = loadServiceModule("ReturnToSpawnService")
local RebirthService = loadServiceModule("RebirthService")
local AdminResetService = loadServiceModule("AdminResetService")
local TutorialService = loadServiceModule("TutorialService")
local DeveloperProductService = loadServiceModule("DeveloperProductService")
local ProductService = loadServiceModule("ProductService")
local DoubleCoinsService = loadServiceModule("DoubleCoinsService")
local GamePassStationCollisionService = loadServiceModule("GamePassStationCollisionService")
local PermanentBagService = loadServiceModule("PermanentBagService")
local ToolGamePassService = loadServiceModule("ToolGamePassService")
local AreaDoorService = loadServiceModule("AreaDoorService")
local YardService = loadServiceModule("YardService")
local PoopService = loadServiceModule("PoopService")
local LobbyCowService = loadServiceModule("LobbyCowService")
local CommunityService = loadServiceModule("CommunityService")
local CoinFlipService = loadServiceModule("CoinFlipService")
local PartyMatchmakingService = loadServiceModule("PartyMatchmakingService")
local CoopMatchService = loadServiceModule("CoopMatchService")

if IS_COOP then
	runBootstrapStep("CoopAdmission", function()
		CoopMatchService.PrepareAdmission()
	end)
end

local function getOrCreate(parent, className, name)
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing.ClassName == className, existing:GetFullName() .. " has the wrong Instance type")
		return existing
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

local remotesFolder = runBootstrapStep("RemoteFolder:ReplicatedStorage.Remotes", function()
	local folder = ReplicatedStorage:FindFirstChild(Constants.REMOTE_FOLDER_NAME)
	if folder then
		assert(folder:IsA("Folder"), "ReplicatedStorage.Remotes must be a Folder")
	else
		folder = Instance.new("Folder")
		folder.Name = Constants.REMOTE_FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	return folder
end)

local remotes = runBootstrapStep("Remotes:CreateOrValidate", function()
	return {
		EquipTool = getOrCreate(remotesFolder, "RemoteFunction", "EquipTool"),
		UpgradeHandAttribute = getOrCreate(remotesFolder, "RemoteFunction", "UpgradeHandAttribute"),
		UpgradeToolAttribute = getOrCreate(remotesFolder, "RemoteFunction", "UpgradeToolAttribute"),
		UpgradePlayerAttribute = getOrCreate(remotesFolder, "RemoteFunction", "UpgradePlayerAttribute"),
		ClaimCodexReward = getOrCreate(remotesFolder, "RemoteFunction", "ClaimCodexReward"),
		ClaimCommunityReward = getOrCreate(remotesFolder, "RemoteFunction", "ClaimCommunityReward"),
		ClaimFriendRewards = getOrCreate(remotesFolder, "RemoteFunction", "ClaimFriendRewards"),
		ResetPlayerData = getOrCreate(remotesFolder, "RemoteFunction", "ResetPlayerData"),
		RequestRebirth = getOrCreate(remotesFolder, "RemoteFunction", "RequestRebirth"),
		RequestAreaCoinReset = getOrCreate(remotesFolder, "RemoteFunction", "RequestAreaCoinReset"),
		RequestBagPurchase = getOrCreate(remotesFolder, "RemoteFunction", "RequestBagPurchase"),
		RequestQuickSell = getOrCreate(remotesFolder, "RemoteFunction", "RequestQuickSell"),
		RequestReturnToSpawn = getOrCreate(remotesFolder, "RemoteFunction", "RequestReturnToSpawn"),
		RequestProgressSave = getOrCreate(remotesFolder, "RemoteFunction", "RequestProgressSave"),
		RequestCoinFlip = getOrCreate(remotesFolder, "RemoteFunction", "RequestCoinFlip"),
		RequestPartyAction = getOrCreate(remotesFolder, "RemoteFunction", "RequestPartyAction"),
		RequestCoopReturn = getOrCreate(remotesFolder, "RemoteFunction", "RequestCoopReturn"),
		StateSnapshot = getOrCreate(remotesFolder, "RemoteEvent", "StateSnapshot"),
		LeafCollected = getOrCreate(remotesFolder, "RemoteEvent", "LeafCollected"),
		LeafPickupBatch = getOrCreate(remotesFolder, "RemoteEvent", "LeafPickupBatch"),
		BagFullPickupAttempt = getOrCreate(remotesFolder, "RemoteEvent", "BagFullPickupAttempt"),
		CoinGainEvent = getOrCreate(remotesFolder, "RemoteEvent", "CoinGainEvent"),
		CoinSpendEvent = getOrCreate(remotesFolder, "RemoteEvent", "CoinSpendEvent"),
		RequestLostItemPickup = getOrCreate(remotesFolder, "RemoteEvent", "RequestLostItemPickup"),
		LostItemRevealStarted = getOrCreate(remotesFolder, "RemoteEvent", "LostItemRevealStarted"),
		LostItemRevealCompleted = getOrCreate(remotesFolder, "RemoteEvent", "LostItemRevealCompleted"),
		RequestMakeTrash = getOrCreate(remotesFolder, "RemoteEvent", "RequestMakeTrash"),
		RequestPoopPickup = getOrCreate(remotesFolder, "RemoteEvent", "RequestPoopPickup"),
		PoopSoundTriggered = getOrCreate(remotesFolder, "RemoteEvent", "PoopSoundTriggered"),
		SetLeafPickupActive = getOrCreate(remotesFolder, "RemoteEvent", "SetLeafPickupActive"),
		UpdateHarvestAim = getOrCreate(remotesFolder, "RemoteEvent", "UpdateHarvestAim"),
		RequestAreaUnlock = getOrCreate(remotesFolder, "RemoteEvent", "RequestAreaUnlock"),
		AreaCompletionNotice = getOrCreate(remotesFolder, "RemoteEvent", "AreaCompletionNotice"),
		AreaCoinResetPrompted = getOrCreate(remotesFolder, "RemoteEvent", "AreaCoinResetPrompted"),
		AreaDoorCoinShortageNotice = getOrCreate(
			remotesFolder,
			"RemoteEvent",
			"AreaDoorCoinShortageNotice"
		),
		Notification = getOrCreate(remotesFolder, "RemoteEvent", "Notification"),
		YardLeafSnapshot = getOrCreate(remotesFolder, "RemoteEvent", "YardLeafSnapshot"),
		YardLeafDelta = getOrCreate(remotesFolder, "RemoteEvent", "YardLeafDelta"),
		ClearTimeLeaderboardSnapshot = getOrCreate(
			remotesFolder,
			"RemoteEvent",
			"ClearTimeLeaderboardSnapshot"
		),
		PlaytimeLeaderboardSnapshot = getOrCreate(
			remotesFolder,
			"RemoteEvent",
			"PlaytimeLeaderboardSnapshot"
		),
		CleanupLeaderboardSnapshot = getOrCreate(
			remotesFolder,
			"RemoteEvent",
			"CleanupLeaderboardSnapshot"
		),
		PoopLeaderboardSnapshot = getOrCreate(
			remotesFolder,
			"RemoteEvent",
			"PoopLeaderboardSnapshot"
		),
		PartySnapshot = getOrCreate(remotesFolder, "RemoteEvent", "PartySnapshot"),
		CoopMatchSnapshot = getOrCreate(remotesFolder, "RemoteEvent", "CoopMatchSnapshot"),
	}
end)

local function initializeService(name, callback)
	runBootstrapStep("Service:" .. name, callback)
end

initializeService("YardService", function()
	YardService:Init(PlayerDataService)
end)
initializeService("PlaytestMetricsService", function()
	PlaytestMetricsService:Init(PlayerDataService)
end)
initializeService("CharacterScaleService", function()
	CharacterScaleService:Init()
end)
initializeService("BagVisualService", function()
	BagVisualService:Init(PlayerDataService, CharacterScaleService)
end)
initializeService("EconomyService", function()
	EconomyService:Init(PlayerDataService)
end)
initializeService("BagService", function()
	BagService:Init(PlayerDataService, BagVisualService, EconomyService)
end)
initializeService("DeveloperProductService", function()
	DeveloperProductService:Init(PlayerDataService, BagVisualService, PlaytestMetricsService)
end)
initializeService("HandUpgradeService", function()
	HandUpgradeService:Init(PlayerDataService, EconomyService, PlaytestMetricsService)
end)
initializeService("ToolUpgradeService", function()
	ToolUpgradeService:Init(PlayerDataService, EconomyService, PlaytestMetricsService)
end)
initializeService("PlayerAttributeUpgradeService", function()
	PlayerAttributeUpgradeService:Init(PlayerDataService, EconomyService, PlaytestMetricsService)
end)
initializeService("CleaningToolActionService", function()
	CleaningToolActionService:Init()
end)
initializeService("LeafService", function()
	LeafService:Init(
		PlayerDataService,
		BagService,
		CleaningToolActionService,
		PlaytestMetricsService,
		YardService,
		remotes
	)
end)
remotes.UpdateHarvestAim.OnServerEvent:Connect(function(player, valid, aimOffset, playerCentered)
	if type(valid) ~= "boolean" then
		return
	end
	if valid and type(playerCentered) ~= "boolean" then
		return
	end
	LeafService:UpdateHarvestAim(player, valid, aimOffset, playerCentered)
end)
if not IS_COOP then
	initializeService("ClearTimeLeaderboardService", function()
		ClearTimeLeaderboardService:Init(
			PlayerDataService,
			LeafService,
			remotes.ClearTimeLeaderboardSnapshot
		)
	end)
end
initializeService("PlaytimeLeaderboardService", function()
	PlaytimeLeaderboardService:Init(remotes.PlaytimeLeaderboardSnapshot)
end)
initializeService("LostItemService", function()
	LostItemService:Init(
		PlayerDataService,
		LeafService,
		PlaytestMetricsService,
		remotes.LostItemRevealStarted,
		remotes.LostItemRevealCompleted
	)
end)
initializeService("CleanupLeaderboardService", function()
	CleanupLeaderboardService:Init(LeafService, remotes.CleanupLeaderboardSnapshot)
end)
initializeService("PoopService", function()
	PoopService:Init(
		PlayerDataService,
		EconomyService,
		LostItemService,
		YardService,
		CleaningToolActionService,
		remotes
	)
end)
initializeService("PoopLeaderboardService", function()
	PoopLeaderboardService:Init(PoopService, remotes.PoopLeaderboardSnapshot)
end)
initializeService("CleaningToolService", function()
	CleaningToolService:Init(PlayerDataService, CleaningToolActionService, LeafService)
end)
initializeService("RecycleService", function()
	RecycleService:Init(PlayerDataService, BagService, EconomyService, PlaytestMetricsService, LeafService)
end)
initializeService("QuickSellService", function()
	QuickSellService:Init(PlayerDataService, RecycleService, LostItemService)
end)
initializeService("ReturnToSpawnService", function()
	ReturnToSpawnService:Init(
		PlayerDataService,
		LeafService,
		CleaningToolActionService,
		remotes.RequestReturnToSpawn
	)
end)
if not IS_COOP then
	initializeService("TutorialService", function()
		TutorialService:Init(PlayerDataService, LeafService, LostItemService, RecycleService, PoopService)
	end)
end
initializeService("ProductService", function()
	ProductService:Init(
		PlayerDataService,
		BagService,
		EconomyService,
		PlaytestMetricsService,
		DeveloperProductService
	)
	if not IS_COOP then
		ProductService:AddBagUpgradePurchasedHandler(function(player, _, _, purchaseKind)
			TutorialService:OnBagUpgradePurchased(player, purchaseKind)
		end)
		ProductService:AddToolPurchasedHandler(function(player, toolId)
			TutorialService:OnToolAcquired(player, toolId)
		end)
		DeveloperProductService:AddToolGrantedHandler(function(player, toolId)
			TutorialService:OnToolAcquired(player, toolId)
		end)
	end
end)
initializeService("DoubleCoinsService", function()
	DoubleCoinsService:Init(PlayerDataService)
end)
initializeService("GamePassStationCollisionService", function()
	GamePassStationCollisionService:Init()
end)
initializeService("PermanentBagService", function()
	PermanentBagService:Init(
		PlayerDataService,
		BagService,
		BagVisualService,
		RecycleService,
		GamePassStationCollisionService
	)
end)
initializeService("ToolGamePassService", function()
	ToolGamePassService:Init(PlayerDataService, GamePassStationCollisionService)
end)
if not IS_COOP then
	initializeService("AreaDoorService", function()
		AreaDoorService:Init(
			PlayerDataService,
			remotes.RequestAreaUnlock,
			LeafService,
			PlaytestMetricsService,
			EconomyService,
			remotes.CoinSpendEvent,
			remotes.AreaDoorCoinShortageNotice
		)
	end)
end
initializeService("PlayerAreaService", function()
	PlayerAreaService:Init(PlayerDataService, PlaytestMetricsService)
end)
initializeService("PlayerDataService.Providers", function()
	PlayerDataService:SetAreaProgressProvider(function(player, areaId)
		local clearedValue, totalValue, progress = LeafService:GetProgress(player, areaId)
		local collectedLeafCount, totalLeafCount = LeafService:GetLeafCounts(player, areaId)
		return clearedValue, totalValue, progress, collectedLeafCount, totalLeafCount
	end)
	PlayerDataService:SetLostItemProgressProvider(function(player, areaId)
		return LostItemService:GetProgress(player, areaId)
	end)
	PlayerDataService:SetTimedLuckyBoxSnapshotProvider(function(player)
		return LostItemService:GetTimedLuckyBoxSnapshot(player)
	end)
	if not IS_COOP then
		PlayerDataService:SetAreaCoinResetStatusProvider(function(player)
			local status = LeafService:GetAreaCoinResetStatus(player)
			return status.Eligible, status.RequirementText
		end)
	end
end)
if IS_COOP then
	initializeService("CoopMatchService", function()
		CoopMatchService:Init(
			PlayerDataService,
			LeafService,
			RecycleService,
			CleaningToolActionService,
			PoopService,
			remotes
		)
	end)
end
initializeService("PlayerDataService", function()
	PlayerDataService:Init(remotes)
end)
if not IS_COOP then
	initializeService("AreaCoinResetService", function()
		AreaCoinResetService:Init(
			PlayerDataService,
			LeafService,
			CleaningToolActionService,
			remotes.AreaCoinResetPrompted,
			remotes.RequestAreaCoinReset
		)
	end)
	initializeService("CoinFlipService", function()
		CoinFlipService:Init(PlayerDataService, remotes.RequestCoinFlip)
	end)
	initializeService("LobbyCowService", function()
		LobbyCowService:Init(PoopService)
	end)
end
initializeService("CommunityService", function()
	CommunityService:Init(PlayerDataService, remotes.ClaimCommunityReward)
end)
if not IS_COOP then
initializeService("RebirthService", function()
	RebirthService:Init(
		PlayerDataService,
		LeafService,
		LostItemService,
		TutorialService,
		CleaningToolActionService,
		PoopService
	)
	DeveloperProductService:SetRebirthService(RebirthService)
	RebirthService:SetCoinFlipPendingProvider(function(player)
		return CoinFlipService:IsPending(player)
	end)
end)
initializeService("AdminResetService", function()
	AdminResetService:Init(
		PlayerDataService,
		LeafService,
		LostItemService,
		TutorialService,
		CleaningToolActionService,
		PoopService,
		CleaningToolService,
		remotes.ResetPlayerData
	)
end)
end

if IS_LOBBY then
	initializeService("PartyMatchmakingService", function()
		PartyMatchmakingService:Init(PlayerDataService, remotes)
	end)
end

remotes.RequestRebirth.OnServerInvoke = function(player)
	if IS_COOP then
		return false, "Rebirth is unavailable in a co-op match.", PlayerDataService:GetSnapshot(player)
	end
	return RebirthService:TryRebirth(player, false)
end

remotes.RequestQuickSell.OnServerInvoke = function(player)
	return QuickSellService:Request(player)
end

remotes.RequestBagPurchase.OnServerInvoke = function(player, request)
	if type(request) == "table"
		and request.PaymentKind == "Robux"
		and (request.TargetId == "bag09" or request.TargetId == "bag010")
	then
		return PermanentBagService:RequestBagPurchase(player, request.TargetId)
	end
	return ProductService:RequestBagPurchase(player, request)
end

local progressSaveRequestTimes = {}
local progressSaveRequestLocks = {}
remotes.RequestProgressSave.OnServerInvoke = function(player)
	local state = PlayerDataService:GetState(player)
	if
		not state
		or state.PersistentDataAvailable ~= true
		or state.PersistentResetRequested == true
	then
		return { Status = "Unavailable" }
	end
	if progressSaveRequestLocks[player] then
		return { Status = "Busy" }
	end

	local now = os.clock()
	local elapsed = now - (progressSaveRequestTimes[player] or -math.huge)
	if elapsed < PROGRESS_SAVE_REQUEST_INTERVAL then
		return {
			Status = "Cooldown",
			RetryAfter = PROGRESS_SAVE_REQUEST_INTERVAL - elapsed,
		}
	end

	progressSaveRequestTimes[player] = now
	progressSaveRequestLocks[player] = true
	local callSucceeded, saveSucceeded = pcall(function()
		return PlayerDataService:SavePlayerNow(player)
	end)
	progressSaveRequestLocks[player] = nil
	if callSucceeded and saveSucceeded == true then
		return { Status = "Saved" }
	end
	if not callSucceeded then
		warn(string.format("Progress-save request failed for %s: %s", player.Name, tostring(saveSucceeded)))
	end
	return { Status = "Failed" }
end

local snapshotRequestTimes = {}
remotes.StateSnapshot.OnServerEvent:Connect(function(player)
	local now = os.clock()
	if now - (snapshotRequestTimes[player] or -math.huge) < 0.5 then
		return
	end
	snapshotRequestTimes[player] = now
	PlayerDataService:PushSnapshot(player)
end)

local equipRequestTimes = {}
remotes.EquipTool.OnServerInvoke = function(player, requestedToolId)
	if type(requestedToolId) ~= "string" or #requestedToolId > 24 then
		return false, "Invalid tool request."
	end

	local now = os.clock()
	if now - (equipRequestTimes[player] or 0) < 0.15 then
		return false, "Too fast."
	end
	equipRequestTimes[player] = now

	local toolId = requestedToolId
	if requestedToolId == Constants.NO_TOOL_ID then
		toolId = nil
	end
	local success, message = PlayerDataService:SetEquippedTool(player, toolId)
	if success then
		LeafService:SetPickupActive(player, false)
		LeafService:ClearHarvestAim(player)
		PlayerDataService:Notify(player, message)
	end
	return success, message, PlayerDataService:GetSnapshot(player)
end

remotes.UpgradeHandAttribute.OnServerInvoke = function(player, attributeId)
	local upgraded, message, snapshot = HandUpgradeService:Upgrade(player, attributeId)
	if upgraded then
		TutorialService:OnUpgradeSucceeded(player, "Tool01", attributeId)
		snapshot = PlayerDataService:GetSnapshot(player)
	end
	return upgraded, message, snapshot
end

remotes.UpgradeToolAttribute.OnServerInvoke = function(player, toolId, attributeId)
	local upgraded, message, snapshot = ToolUpgradeService:Upgrade(player, toolId, attributeId)
	if upgraded then
		TutorialService:OnUpgradeSucceeded(player, toolId, attributeId)
		snapshot = PlayerDataService:GetSnapshot(player)
	end
	return upgraded, message, snapshot
end

remotes.UpgradePlayerAttribute.OnServerInvoke = function(player, attributeId)
	return PlayerAttributeUpgradeService:Upgrade(player, attributeId)
end

remotes.ClaimCodexReward.OnServerInvoke = function(player, lostItemId)
	if type(lostItemId) ~= "string" or #lostItemId > 24 then
		return false, "Invalid Codex item.", 0
	end
	return PlayerDataService:ClaimCodexReward(player, lostItemId)
end

remotes.ClaimFriendRewards.OnServerInvoke = function(player)
	return PlayerDataService:ClaimFriendRewards(player)
end

remotes.SetLeafPickupActive.OnServerEvent:Connect(function(player, active)
	if type(active) ~= "boolean" then
		return
	end
	LeafService:SetPickupActive(player, active)
end)

remotes.RequestLostItemPickup.OnServerEvent:Connect(function(player, spawnId)
	if type(spawnId) == "string" and #spawnId <= LostItemConfig.MaximumSpawnIdLength then
		LostItemService:RequestPickup(player, spawnId)
	end
end)

game:GetService("Players").PlayerRemoving:Connect(function(player)
	snapshotRequestTimes[player] = nil
	progressSaveRequestTimes[player] = nil
	progressSaveRequestLocks[player] = nil
end)

logBootstrap("COMPLETE", "Bootstrap", string.format("%dms", math.floor((os.clock() - bootstrapStartedAt) * 1000 + 0.5)))

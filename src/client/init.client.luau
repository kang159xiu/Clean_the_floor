local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local BOOTSTRAP_DIAGNOSTICS_ENABLED = true
local BOOTSTRAP_STALL_WARNING_SECONDS = 10
local BOOTSTRAP_LOG_PREFIX = "[CTF ClientBootstrap]"
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

local remotesFolder = runBootstrapStep("RemoteFolder:ReplicatedStorage.Remotes", function()
	return ReplicatedStorage:WaitForChild("Remotes")
end)

local function getRemote(name)
	return runBootstrapStep("Remote:" .. name, function()
		return remotesFolder:WaitForChild(name)
	end)
end

local remotes = {
	EquipTool = getRemote("EquipTool"),
	UpgradeHandAttribute = getRemote("UpgradeHandAttribute"),
	UpgradeToolAttribute = getRemote("UpgradeToolAttribute"),
	UpgradePlayerAttribute = getRemote("UpgradePlayerAttribute"),
	ClaimCodexReward = getRemote("ClaimCodexReward"),
	ClaimCommunityReward = getRemote("ClaimCommunityReward"),
	SendYardInvite = getRemote("SendYardInvite"),
	RespondYardInvite = getRemote("RespondYardInvite"),
	LeaveVisitedYard = getRemote("LeaveVisitedYard"),
	EnterYard = getRemote("EnterYard"),
	SetPoopPermission = getRemote("SetPoopPermission"),
	ClaimFriendRewards = getRemote("ClaimFriendRewards"),
	ResetPlayerData = getRemote("ResetPlayerData"),
	RequestRebirth = getRemote("RequestRebirth"),
	RequestQuickSell = getRemote("RequestQuickSell"),
	RequestReturnToSpawn = getRemote("RequestReturnToSpawn"),
	RequestProgressSave = getRemote("RequestProgressSave"),
	RequestCoinFlip = getRemote("RequestCoinFlip"),
	StateSnapshot = getRemote("StateSnapshot"),
	LeafCollected = getRemote("LeafCollected"),
	LeafPickupBatch = getRemote("LeafPickupBatch"),
	BagFullPickupAttempt = getRemote("BagFullPickupAttempt"),
	CoinGainEvent = getRemote("CoinGainEvent"),
	CoinSpendEvent = getRemote("CoinSpendEvent"),
	RequestLostItemPickup = getRemote("RequestLostItemPickup"),
	LostItemRevealStarted = getRemote("LostItemRevealStarted"),
	LostItemRevealCompleted = getRemote("LostItemRevealCompleted"),
	RequestMakeTrash = getRemote("RequestMakeTrash"),
	RequestPoopPickup = getRemote("RequestPoopPickup"),
	PoopSoundTriggered = getRemote("PoopSoundTriggered"),
	SetLeafPickupActive = getRemote("SetLeafPickupActive"),
	UpdateHarvestAim = getRemote("UpdateHarvestAim"),
	RequestAreaUnlock = getRemote("RequestAreaUnlock"),
	AreaCompletionNotice = getRemote("AreaCompletionNotice"),
	Notification = getRemote("Notification"),
	YardInviteReceived = getRemote("YardInviteReceived"),
	YardLeafSnapshot = getRemote("YardLeafSnapshot"),
	YardLeafDelta = getRemote("YardLeafDelta"),
	ClearTimeLeaderboardSnapshot = getRemote("ClearTimeLeaderboardSnapshot"),
	PlaytimeLeaderboardSnapshot = getRemote("PlaytimeLeaderboardSnapshot"),
	CleanupLeaderboardSnapshot = getRemote("CleanupLeaderboardSnapshot"),
	PoopLeaderboardSnapshot = getRemote("PoopLeaderboardSnapshot"),
}

local StateSnapshotStore = runBootstrapStep("Module:StateSnapshotStore", function()
	return require(script:WaitForChild("StateSnapshotStore"))
end)
remotes.StateSnapshotStore = StateSnapshotStore.new(remotes.StateSnapshot)
remotes.StateSnapshotStore:StartRequesting()

local controllersFolder = runBootstrapStep("ControllerFolder", function()
	return script:WaitForChild("Controllers")
end)
local controllerModuleNames = {
	"HUDController",
	"ExitSaveController",
	"ToolController",
	"CameraController",
	"HarvestRangeController",
	"HandUpgradeController",
	"LocalLostItemController",
	"LostItemGuidanceController",
	"BagProductDisplayController",
	"ToolProductDisplayController",
	"AreaDoorController",
	"AirWallController",
	"RecycleGuidanceController",
	"AffordableNotificationController",
	"TutorialController",
	"RebirthController",
	"QuickSellController",
	"LobbyReturnController",
	"DoubleCoinsButtonController",
	"ToolGamePassDisplayController",
	"PermanentBagDisplayController",
	"YardUIController",
	"VisitorBillboardController",
	"YardLeafController",
	"PoopController",
	"AutomaticController",
	"CoinFlipController",
	"CommunityController",
	"TimeLeaderboardController",
}
local controllers = {}
for _, moduleName in controllerModuleNames do
	controllers[moduleName] = runBootstrapStep("Module:" .. moduleName, function()
		return require(controllersFolder:WaitForChild(moduleName))
	end)
end

local controllerJobDefinitions = {
	{
		Name = "HUDController",
		Dependencies = {},
		Run = function()
			controllers.HUDController:Init(remotes)
		end,
	},
	{
		Name = "ExitSaveController",
		Dependencies = { "HUDController" },
		Run = function()
			controllers.ExitSaveController:Init(remotes, controllers.HUDController)
		end,
	},
	{
		Name = "CommunityController",
		Dependencies = { "HUDController" },
		Run = function()
			controllers.CommunityController:Init(remotes, controllers.HUDController)
		end,
	},
	{
		Name = "TimeLeaderboardController",
		Dependencies = {},
		Run = function()
			controllers.TimeLeaderboardController:Init(remotes)
		end,
	},
	{
		Name = "DoubleCoinsButtonController",
		Dependencies = {},
		Run = function()
			controllers.DoubleCoinsButtonController:Init(remotes)
		end,
	},
	{
		Name = "ToolGamePassDisplayController",
		Dependencies = {},
		Run = function()
			controllers.ToolGamePassDisplayController:Init(remotes)
		end,
	},
	{
		Name = "PermanentBagDisplayController",
		Dependencies = {},
		Run = function()
			controllers.PermanentBagDisplayController:Init(remotes)
		end,
	},
	{
		Name = "ToolController",
		Dependencies = { "HUDController" },
		Run = function()
			controllers.ToolController:Init(remotes, controllers.HUDController)
			if BOOTSTRAP_DIAGNOSTICS_ENABLED then
				local checked, backpackEnabled = pcall(function()
					return StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack)
				end)
				if checked then
					logBootstrap("CHECK", "DefaultBackpack", "enabled=" .. tostring(backpackEnabled))
				else
					warn(BOOTSTRAP_LOG_PREFIX .. " CHECK DefaultBackpack failed: " .. tostring(backpackEnabled))
				end
			end
		end,
	},
	{
		Name = "AreaDoorController",
		Dependencies = {},
		Run = function()
			controllers.AreaDoorController:Init(remotes)
		end,
	},
	{
		Name = "AirWallController",
		Dependencies = {},
		Run = function()
			controllers.AirWallController:Init(remotes)
		end,
	},
	{
		Name = "HandUpgradeController",
		Dependencies = {},
		Run = function()
			controllers.HandUpgradeController:Init(remotes)
		end,
	},
	{
		Name = "TutorialController",
		Dependencies = { "HUDController", "ToolController", "AreaDoorController", "HandUpgradeController" },
		Run = function()
			controllers.TutorialController:Init(
				remotes,
				controllers.HUDController,
				controllers.ToolController,
				controllers.AreaDoorController,
				controllers.HandUpgradeController
			)
		end,
	},
	{
		Name = "RebirthController",
		Dependencies = { "HUDController" },
		Run = function()
			controllers.RebirthController:Init(remotes, controllers.HUDController)
		end,
	},
	{
		Name = "QuickSellController",
		Dependencies = { "HUDController" },
		Run = function()
			controllers.QuickSellController:Init(remotes, controllers.HUDController)
		end,
	},
	{
		Name = "LobbyReturnController",
		Dependencies = { "ToolController", "HUDController" },
		Run = function()
			controllers.LobbyReturnController:Init(remotes, controllers.ToolController, controllers.HUDController)
		end,
	},
	{
		Name = "CameraController",
		Dependencies = {},
		Run = function()
			controllers.CameraController:Init()
		end,
	},
	{
		Name = "HarvestRangeController",
		Dependencies = { "CameraController", "ToolController" },
		Run = function()
			controllers.HarvestRangeController:Init(remotes, controllers.CameraController, controllers.ToolController)
			logBootstrap("CHECK", "HarvestRange", "initialized=true")
		end,
	},
	{
		Name = "YardLeafController",
		Dependencies = {},
		Run = function()
			controllers.YardLeafController:Init(remotes)
		end,
	},
	{
		Name = "LocalLostItemController",
		Dependencies = { "HUDController" },
		Run = function()
			controllers.LocalLostItemController:Init(remotes, controllers.HUDController)
		end,
	},
	{
		Name = "PoopController",
		Dependencies = {},
		Run = function()
			controllers.PoopController:Init(remotes)
		end,
	},
	{
		Name = "AutomaticController",
		Dependencies = { "ToolController", "PoopController", "HUDController" },
		Run = function()
			controllers.AutomaticController:Init(
				remotes,
				controllers.ToolController,
				controllers.PoopController,
				controllers.HUDController
			)
		end,
	},
	{
		Name = "CoinFlipController",
		Dependencies = {
			"CameraController",
			"ToolController",
			"AutomaticController",
			"HUDController",
			"HarvestRangeController",
		},
		Run = function()
			controllers.CoinFlipController:Init(
				remotes,
				controllers.CameraController,
				controllers.ToolController,
				controllers.AutomaticController,
				controllers.HUDController,
				controllers.HarvestRangeController
			)
		end,
	},
	{
		Name = "LostItemGuidanceController",
		Dependencies = { "AreaDoorController", "PoopController" },
		Run = function()
			controllers.LostItemGuidanceController:Init(
				remotes,
				controllers.AreaDoorController,
				controllers.PoopController
			)
		end,
	},
	{
		Name = "BagProductDisplayController",
		Dependencies = {},
		Run = function()
			controllers.BagProductDisplayController:Init(remotes)
		end,
	},
	{
		Name = "ToolProductDisplayController",
		Dependencies = {},
		Run = function()
			controllers.ToolProductDisplayController:Init(remotes)
		end,
	},
	{
		Name = "RecycleGuidanceController",
		Dependencies = { "ToolController", "HUDController", "AreaDoorController" },
		Run = function()
			controllers.RecycleGuidanceController:Init(
				remotes,
				controllers.ToolController,
				controllers.HUDController,
				controllers.AreaDoorController
			)
		end,
	},
	{
		Name = "AffordableNotificationController",
		Dependencies = { "HUDController" },
		Run = function()
			controllers.AffordableNotificationController:Init(remotes, controllers.HUDController)
		end,
	},
	{
		Name = "YardUIController",
		Dependencies = {},
		Run = function()
			controllers.YardUIController:Init(remotes)
		end,
	},
	{
		Name = "VisitorBillboardController",
		Dependencies = {},
		Run = function()
			controllers.VisitorBillboardController:Init(remotes)
		end,
	},
}

local controllerJobs = {}
for _, definition in controllerJobDefinitions do
	controllerJobs[definition.Name] = {
		Definition = definition,
		Status = "Pending",
		Completion = Instance.new("BindableEvent"),
	}
end

local function completeControllerJob(job, status)
	job.Status = status
	job.Completion:Fire(status)
end

for _, definition in controllerJobDefinitions do
	local job = controllerJobs[definition.Name]
	task.spawn(function()
		for _, dependencyName in definition.Dependencies do
			local dependency = controllerJobs[dependencyName]
			if dependency.Status == "Pending" or dependency.Status == "Running" then
				dependency.Completion.Event:Wait()
			end
			if dependency.Status ~= "Succeeded" then
				warn(string.format(
					"%s SKIPPED Controller:%s | dependency %s ended as %s",
					BOOTSTRAP_LOG_PREFIX,
					definition.Name,
					dependencyName,
					dependency.Status
				))
				completeControllerJob(job, "Skipped")
				return
			end
		end

		job.Status = "Running"
		local succeeded = pcall(function()
			runBootstrapStep("Controller:" .. definition.Name, definition.Run)
		end)
		completeControllerJob(job, if succeeded then "Succeeded" else "Failed")
	end)
end

task.spawn(function()
	local succeededCount = 0
	local failedCount = 0
	local skippedCount = 0
	for _, definition in controllerJobDefinitions do
		local job = controllerJobs[definition.Name]
		if job.Status == "Pending" or job.Status == "Running" then
			job.Completion.Event:Wait()
		end
		if job.Status == "Succeeded" then
			succeededCount += 1
		elseif job.Status == "Failed" then
			failedCount += 1
		else
			skippedCount += 1
		end
	end
	logBootstrap(
		"COMPLETE",
		"Bootstrap",
		string.format(
			"%dms | succeeded=%d failed=%d skipped=%d",
			math.floor((os.clock() - bootstrapStartedAt) * 1000 + 0.5),
			succeededCount,
			failedCount,
			skippedCount
		)
	)
end)

logBootstrap(
	"DISPATCHED",
	"Bootstrap",
	string.format("%dms", math.floor((os.clock() - bootstrapStartedAt) * 1000 + 0.5))
)

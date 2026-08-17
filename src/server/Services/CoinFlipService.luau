local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CoinFlipConfig = require(ReplicatedStorage.Shared.Config.CoinFlipConfig)

local CoinFlipService = {}

local scheduledTransactions = {}

local function nowUnixMillis()
	return DateTime.now().UnixTimestampMillis
end

local function isInsidePart(part, worldPosition)
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	local halfSize = part.Size * 0.5
	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Y) <= halfSize.Y + 3
		and math.abs(localPosition.Z) <= halfSize.Z
end

local function nextProgress(progress, isHeads)
	local result = {
		GuaranteedHeadsRemaining = math.max(0, math.floor(tonumber(progress.GuaranteedHeadsRemaining) or 0)),
		MissesSinceHeads = math.max(0, math.floor(tonumber(progress.MissesSinceHeads) or 0)),
		PityThreshold = math.clamp(
			math.floor(tonumber(progress.PityThreshold) or CoinFlipConfig.MinimumPityThreshold),
			CoinFlipConfig.MinimumPityThreshold,
			CoinFlipConfig.MaximumPityThreshold
		),
	}
	if result.GuaranteedHeadsRemaining > 0 then
		result.GuaranteedHeadsRemaining -= 1
	end
	if isHeads then
		result.MissesSinceHeads = 0
		result.PityThreshold = math.random(
			CoinFlipConfig.MinimumPityThreshold,
			CoinFlipConfig.MaximumPityThreshold
		)
	else
		result.MissesSinceHeads += 1
	end
	return result
end

function CoinFlipService:_chooseResult(progress)
	local guaranteedRemaining = math.max(
		0,
		math.floor(tonumber(progress.GuaranteedHeadsRemaining) or 0)
	)
	local misses = math.max(0, math.floor(tonumber(progress.MissesSinceHeads) or 0))
	local threshold = math.clamp(
		math.floor(tonumber(progress.PityThreshold) or CoinFlipConfig.MinimumPityThreshold),
		CoinFlipConfig.MinimumPityThreshold,
		CoinFlipConfig.MaximumPityThreshold
	)
	if guaranteedRemaining > 0 or misses + 1 >= threshold then
		return true
	end
	return math.random() < CoinFlipConfig.BaseHeadsChance
end

function CoinFlipService:_isPlayerInZone(player)
	local clickPart = self.ClickPart
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	return clickPart ~= nil
		and clickPart.Parent ~= nil
		and humanoid ~= nil
		and humanoid.Health > 0
		and rootPart ~= nil
		and rootPart:IsA("BasePart")
		and isInsidePart(clickPart, rootPart.Position)
end

function CoinFlipService:_scheduleSettlement(player, transactionId, delaySeconds)
	scheduledTransactions[player] = transactionId
	task.delay(math.max(0, tonumber(delaySeconds) or 0), function()
		if scheduledTransactions[player] ~= transactionId then
			return
		end
		scheduledTransactions[player] = nil
		local completed = self.PlayerDataService:CompleteCoinFlip(player, transactionId)
		if not completed and player.Parent == Players then
			self:_scheduleSettlement(player, transactionId, 5)
		end
	end)
end

function CoinFlipService:_resumePending(player, state)
	local pending = state and state.PendingCoinFlip
	if type(pending) ~= "table" or type(pending.TransactionId) ~= "string" then
		return
	end
	local remainingSeconds = math.max(
		0,
		((tonumber(pending.SettlementUnixMillis) or 0) - nowUnixMillis()) / 1000
	)
	self:_scheduleSettlement(player, pending.TransactionId, remainingSeconds)
end

function CoinFlipService:Request(player, wager)
	local state = self.PlayerDataService:GetState(player)
	if not state then
		return { Success = false, Message = "Player data is not ready." }
	end
	if not self:_isPlayerInZone(player) then
		return { Success = false, Message = "Stand in the coin flip area first." }
	end
	if state.PendingCoinFlip ~= nil then
		return { Success = false, Message = "A coin flip is already in progress." }
	end
	if not self.PlayerDataService:CanPersistCriticalTransaction(player) then
		return { Success = false, Message = "Player save data is unavailable." }
	end

	local normalizedWager = tonumber(wager)
	if
		not normalizedWager
		or normalizedWager ~= normalizedWager
		or normalizedWager == math.huge
		or normalizedWager == -math.huge
		or normalizedWager % 1 ~= 0
		or normalizedWager < CoinFlipConfig.MinimumWager
		or normalizedWager % CoinFlipConfig.WagerStep ~= 0
	then
		return { Success = false, Message = "Bet must be a multiple of 10." }
	end
	if normalizedWager > state.Coins then
		return { Success = false, Message = "Not enough Coins." }
	end

	local progress = state.CoinFlipProgress or {}
	local isHeads = self:_chooseResult(progress)
	local transactionId = HttpService:GenerateGUID(false)
	local landingSeed = math.random(1, 2_000_000_000)
	local pending = {
		TransactionId = transactionId,
		Wager = normalizedWager,
		CoinId = CoinFlipConfig.GetCoinId(normalizedWager),
		IsHeads = isHeads,
		SettlementUnixMillis = nowUnixMillis()
			+ math.floor((CoinFlipConfig.AnimationDuration + CoinFlipConfig.RewardDelay) * 1000),
		LandingSeed = landingSeed,
	}
	local started, result = self.PlayerDataService:ApplyCoinFlipStart(
		player,
		normalizedWager,
		pending,
		nextProgress(progress, isHeads)
	)
	if not started then
		return { Success = false, Message = result }
	end

	self:_scheduleSettlement(
		player,
		transactionId,
		CoinFlipConfig.AnimationDuration + CoinFlipConfig.RewardDelay
	)
	return {
		Success = true,
		TransactionId = transactionId,
		Wager = normalizedWager,
		CoinId = pending.CoinId,
		IsHeads = isHeads,
		AnimationDuration = CoinFlipConfig.AnimationDuration,
		LandingSeed = landingSeed,
	}
end

function CoinFlipService:IsPending(player)
	local state = self.PlayerDataService:GetState(player)
	return state ~= nil and state.PendingCoinFlip ~= nil
end

function CoinFlipService:Init(playerDataService, requestRemote)
	self.PlayerDataService = playerDataService
	assert(requestRemote:IsA("RemoteFunction"), "RequestCoinFlip must be a RemoteFunction")

	local coinFlipFolder = Workspace:FindFirstChild("CoinFlip")
	local clickPart = coinFlipFolder and coinFlipFolder:FindFirstChild("Click")
	if clickPart and clickPart:IsA("BasePart") then
		self.ClickPart = clickPart
	else
		warn("Workspace.CoinFlip.Click is missing; coin flip requests are disabled.")
	end

	requestRemote.OnServerInvoke = function(player, wager)
		return self:Request(player, wager)
	end
	playerDataService:AddPlayerStateReadyHandler(function(player, state)
		self:_resumePending(player, state)
	end)
	Players.PlayerRemoving:Connect(function(player)
		scheduledTransactions[player] = nil
	end)
end

return CoinFlipService

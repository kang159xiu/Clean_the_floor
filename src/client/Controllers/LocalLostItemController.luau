local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local LostItemConfig = require(ReplicatedStorage.Shared.Config.LostItemConfig)

local LocalLostItemController = {}

local REVEAL_ANIMATION = LostItemConfig.RevealAnimation
local DECOY_COUNT = REVEAL_ANIMATION.DecoyCount
local START_SCALE = REVEAL_ANIMATION.StartScale
local FINAL_GROW_DURATION = REVEAL_ANIMATION.FinalGrowDuration
local FINAL_HOLD_DURATION = REVEAL_ANIMATION.FinalHoldDuration
local FLY_TO_PLAYER_DURATION = REVEAL_ANIMATION.FlyToPlayerDuration
local FLY_ARC_HEIGHT = REVEAL_ANIMATION.FlyArcHeight
local VALUE_FADE_DURATION = REVEAL_ANIMATION.ValueFadeDuration
local MAXIMUM_DISPLAY_SIZE = REVEAL_ANIMATION.MaximumDisplaySize
local PICKUP_RESPONSE_TIMEOUT = 1.5
local NEW_ITEM_NOTICE_TIMEOUT = math.max(15, LostItemConfig.GetLuckyRevealTotalDuration() + 10)

local function prepareWorldBox(model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("LuaSourceContainer") or descendant:IsA("BillboardGui") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		end
	end
end

local function prepareRevealModel(model)
	for _, descendant in model:GetDescendants() do
		if
			descendant:IsA("LuaSourceContainer")
			or descendant:IsA("ProximityPrompt")
			or descendant:IsA("BillboardGui")
		then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		end
	end
end

function LocalLostItemController:_updateCarryToolValues()
	local player = Players.LocalPlayer
	for _, container in { player.Character, player:FindFirstChildOfClass("Backpack") } do
		if container then
			for _, child in container:GetChildren() do
				if child:IsA("Tool") and child:GetAttribute("LostItemCarry") == true then
					local lostItemId = child:GetAttribute("LostItemId")
					local handle = child:FindFirstChild("Handle")
					local billboard = handle and handle:FindFirstChild("BillboardGui")
					local frame = billboard and billboard:FindFirstChild("Frame")
					local textLabel = frame and frame:FindFirstChild("TextLabel")
					if textLabel and textLabel:IsA("TextLabel") then
						local redeemCoinValue = if LostItemConfig.IsPoopItemId(lostItemId)
							then tonumber(child:GetAttribute("StackRedeemCoinValue")) or 0
							else LostItemConfig.GetRedeemCoinValue(
								lostItemId,
								self.CurrentLeafValueMultiplier
							)
						textLabel.Text = CoinFormat.Compact(redeemCoinValue)
					end
				end
			end
		end
	end
end

function LocalLostItemController:_updatePrompt(entry)
	entry.Prompt.Enabled = entry.Destroyed ~= true and entry.PickupPending ~= true
end

function LocalLostItemController:_destroyEntry(spawnId)
	local entry = self.Entries[spawnId]
	if not entry then
		return
	end
	entry.Destroyed = true
	if entry.Connection then
		entry.Connection:Disconnect()
	end
	if entry.Model then
		entry.Model:Destroy()
	end
	self.Entries[spawnId] = nil
end

function LocalLostItemController:_createEntry(itemData)
	local luckyTier = LostItemConfig.NormalizeLuckyTier(itemData.LuckyTier)
	local templateName = string.format("Lucky%03d", luckyTier)
	local template = self.LuckyBoxFolder:FindFirstChild(templateName)
	if not template or not template:IsA("Model") then
		return nil
	end
	local clone = template:Clone()
	clone.Name = string.format("Local_%s_%s", templateName, itemData.SpawnId)
	clone:SetAttribute("LuckyTier", luckyTier)
	clone:SetAttribute("SpawnId", itemData.SpawnId)
	prepareWorldBox(clone)
	local base = clone:FindFirstChild("Base")
	local prompt = base and base:FindFirstChild("ProximityPrompt")
	if not base or not base:IsA("BasePart") or not prompt or not prompt:IsA("ProximityPrompt") then
		clone:Destroy()
		return nil
	end
	prompt.ActionText = "OPEN"
	prompt.ObjectText = string.format("Lucky Box Lv.%d", luckyTier)
	clone:PivotTo(itemData.WorldPivotCFrame)
	clone.Parent = self.Container

	local entry = {
		Model = clone,
		Prompt = prompt,
		SpawnId = itemData.SpawnId,
		LuckyTier = luckyTier,
		PickupPending = false,
		Destroyed = false,
	}
	entry.Connection = prompt.Triggered:Connect(function()
		if entry.PickupPending then
			return
		end
		entry.PickupPending = true
		self:_updatePrompt(entry)
		self.Remotes.RequestLostItemPickup:FireServer(entry.SpawnId)
		task.delay(PICKUP_RESPONSE_TIMEOUT, function()
			if self.Entries[entry.SpawnId] == entry then
				entry.PickupPending = false
				self:_updatePrompt(entry)
			end
		end)
	end)
	self.Entries[entry.SpawnId] = entry
	self:_updatePrompt(entry)
	return entry
end

function LocalLostItemController:_createRevealVisual(lostItemId, highlighted)
	local template = self.LostItemFolder:FindFirstChild(lostItemId)
	if not template or not template:IsA("Model") then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "LuckyBoxReveal_" .. lostItemId
	prepareRevealModel(clone)
	local upgrade = clone:FindFirstChild("upgrade")
	if upgrade and upgrade:IsA("BasePart") then
		upgrade.Transparency = 1
		upgrade.CastShadow = false
	end
	local displayModel = clone:FindFirstChild("Model")
	if not displayModel or not displayModel:IsA("Model") then
		clone:Destroy()
		return nil
	end
	local _, displaySize = displayModel:GetBoundingBox()
	local maximumDimension = math.max(displaySize.X, displaySize.Y, displaySize.Z)
	if maximumDimension > 0 then
		local scaleFactor = math.min(1.5, MAXIMUM_DISPLAY_SIZE / maximumDimension)
		clone:ScaleTo(math.max(0.05, clone:GetScale() * scaleFactor))
	end
	local displayCFrame = displayModel:GetBoundingBox()
	local displayOffset = clone:GetPivot():ToObjectSpace(displayCFrame)
	local transparencyValues = {}
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") or descendant:IsA("Texture") then
			transparencyValues[descendant] = descendant.Transparency
		end
	end
	clone.Parent = self.RevealContainer

	if highlighted and self.RevealHighlightTemplate then
		local highlight = self.RevealHighlightTemplate:Clone()
		highlight.Name = "LuckyBoxRevealHighlight"
		highlight.Adornee = displayModel
		highlight.Parent = clone
	end
	return {
		Model = clone,
		BaseScale = clone:GetScale(),
		DisplayOffset = displayOffset,
		TransparencyValues = transparencyValues,
	}
end

function LocalLostItemController:_destroyRevealVisual(active)
	if active.Visual then
		active.Visual.Model:Destroy()
		active.Visual = nil
	end
end

function LocalLostItemController:_createValueAnchor(revealCoinValue)
	local anchor = Instance.new("Part")
	anchor.Name = "LuckyBoxRevealValueAnchor"
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.Parent = self.RevealContainer
	local billboard = self.ValueBillboardTemplate:Clone()
	billboard.Name = "BillboardGui"
	billboard.Enabled = true
	billboard.Frame.TextLabel.Text = CoinFormat.Compact(
		math.max(0, math.floor(tonumber(revealCoinValue) or 0))
	)
	billboard.Frame.ImageLabel.Image = LostItemConfig.CoinImage
	billboard.Parent = anchor
	return anchor
end

function LocalLostItemController:_setRevealFade(visual, fade)
	local normalizedFade = math.clamp(tonumber(fade) or 0, 0, 1)
	for instance, originalTransparency in visual.TransparencyValues do
		if instance.Parent then
			instance.Transparency = originalTransparency + (1 - originalTransparency) * normalizedFade
		end
	end
end

function LocalLostItemController:_positionRevealAt(active, targetCFrame, scale, positionValueAnchor)
	local visual = active.Visual
	if visual and visual.Model.Parent then
		local normalizedScale = math.max(0.001, tonumber(scale) or 1)
		visual.Model:ScaleTo(math.max(0.001, visual.BaseScale * normalizedScale))
		local displayOffset = CFrame.new(visual.DisplayOffset.Position * normalizedScale)
			* visual.DisplayOffset.Rotation
		visual.Model:PivotTo(targetCFrame * displayOffset:Inverse())
		active.LastDisplayCFrame = targetCFrame
	end
	if positionValueAnchor ~= false and active.ValueAnchor and active.ValueAnchor.Parent then
		active.ValueAnchor.CFrame = CFrame.new(targetCFrame.Position)
	end
end

function LocalLostItemController:_positionRevealAtOrigin(active, scale)
	local targetCFrame = active.RevealOriginCFrame * CFrame.Angles(0, os.clock() * 1.5, 0)
	self:_positionRevealAt(active, targetCFrame, scale, true)
end

function LocalLostItemController:_fadeValueAnchor(active)
	local anchor = active.ValueAnchor
	if not anchor or not anchor.Parent then
		return
	end
	local tweenInfo = TweenInfo.new(VALUE_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, descendant in anchor:GetDescendants() do
		local goals = {}
		if descendant:IsA("GuiObject") then
			goals.BackgroundTransparency = 1
		end
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			goals.TextTransparency = 1
			goals.TextStrokeTransparency = 1
		end
		if descendant:IsA("ImageLabel") or descendant:IsA("ImageButton") then
			goals.ImageTransparency = 1
		end
		if descendant:IsA("UIStroke") then
			goals.Transparency = 1
		end
		if next(goals) then
			TweenService:Create(descendant, tweenInfo, goals):Play()
		end
	end
end

function LocalLostItemController:_getFlyTargetPosition(opener)
	if not opener or opener.Parent ~= Players then
		return nil
	end
	local character = opener.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if
		not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart:IsA("BasePart")
	then
		return nil
	end
	return rootPart.Position + Vector3.new(0, 0.75, 0)
end

function LocalLostItemController:_flyRevealToOpener(active, opener, phaseStartTime, phaseEndTime)
	local duration = math.max(0, phaseEndTime - phaseStartTime)
	local startCFrame = active.LastDisplayCFrame or active.RevealOriginCFrame
	local currentCFrame = startCFrame
	local targetLostAtProgress = nil
	self:_fadeValueAnchor(active)

	while self.ActiveReveals[active.RevealId] == active do
		local now = os.clock()
		local progress = if duration > 0 then math.clamp((now - phaseStartTime) / duration, 0, 1) else 1
		local easedProgress = TweenService:GetValue(progress, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		if targetLostAtProgress == nil then
			local targetPosition = self:_getFlyTargetPosition(opener)
			if targetPosition then
				local basePosition = startCFrame.Position:Lerp(targetPosition, easedProgress)
				local arcHeight = 4 * progress * (1 - progress) * FLY_ARC_HEIGHT
				local position = basePosition + Vector3.new(0, arcHeight, 0)
				currentCFrame = CFrame.new(position) * startCFrame.Rotation
			else
				targetLostAtProgress = progress
			end
		end
		self:_positionRevealAt(active, currentCFrame, 1, false)
		if active.Visual and targetLostAtProgress ~= nil then
			local fadeDuration = math.max(0.001, 1 - targetLostAtProgress)
			self:_setRevealFade(active.Visual, (progress - targetLostAtProgress) / fadeDuration)
		end
		if now >= phaseEndTime then
			return true
		end
		RunService.RenderStepped:Wait()
	end
	return false
end

function LocalLostItemController:_animateRevealScale(
	active,
	phaseStartTime,
	phaseEndTime,
	startScale,
	endScale,
	easingStyle,
	easingDirection
)
	local duration = math.max(0, phaseEndTime - phaseStartTime)
	while self.ActiveReveals[active.RevealId] == active do
		local now = os.clock()
		local progress = if duration > 0 then math.clamp((now - phaseStartTime) / duration, 0, 1) else 1
		local easedProgress = TweenService:GetValue(progress, easingStyle, easingDirection)
		self:_positionRevealAtOrigin(active, startScale + (endScale - startScale) * easedProgress)
		if now >= phaseEndTime then
			return true
		end
		RunService.RenderStepped:Wait()
	end
	return false
end

function LocalLostItemController:_displayRevealUntil(active, endTime)
	while self.ActiveReveals[active.RevealId] == active do
		self:_positionRevealAtOrigin(active, 1)
		if os.clock() >= endTime then
			return true
		end
		RunService.RenderStepped:Wait()
	end
	return false
end

function LocalLostItemController:_tryShowNewItemNotice(revealId)
	local noticeState = self.PendingNewItemNotices[revealId]
	if not noticeState or not noticeState.CompletionReceived then
		return
	end
	if noticeState.Succeeded ~= true or noticeState.IsNew ~= true then
		self.PendingNewItemNotices[revealId] = nil
		return
	end
	if noticeState.FlightFinished ~= true then
		return
	end

	self.PendingNewItemNotices[revealId] = nil
	local config = LostItemConfig.Types[noticeState.LostItemId]
	if not config or config.PoopOnly == true or not self.HUDController then
		return
	end
	self.HUDController:ShowCenterNotice(
		"NEW!",
		config.Image,
		FINAL_HOLD_DURATION,
		"NewLostItem"
	)
end

function LocalLostItemController:_handleRevealCompleted(payload)
	if type(payload) ~= "table" then
		return
	end
	local revealId = payload.RevealId
	local lostItemId = payload.LostItemId
	if type(revealId) ~= "string" or type(lostItemId) ~= "string" then
		return
	end
	local noticeState = self.PendingNewItemNotices[revealId]
	if not noticeState or noticeState.LostItemId ~= lostItemId then
		return
	end
	noticeState.CompletionReceived = true
	noticeState.Succeeded = payload.Succeeded == true
	noticeState.IsNew = payload.IsNew == true
	self:_tryShowNewItemNotice(revealId)
end

function LocalLostItemController:_finishReveal(active)
	if self.ActiveReveals[active.RevealId] ~= active then
		return
	end
	self:_destroyRevealVisual(active)
	if active.ValueAnchor then
		active.ValueAnchor:Destroy()
		active.ValueAnchor = nil
	end
	self.ActiveReveals[active.RevealId] = nil
end

function LocalLostItemController:_playReveal(payload)
	if type(payload) ~= "table" then
		return
	end
	local revealId = payload.RevealId
	local openerUserId = math.floor(tonumber(payload.OpenerUserId) or 0)
	local finalLostItemId = payload.FinalLostItemId
	local boxTier = LostItemConfig.NormalizeLuckyTier(payload.BoxTier)
	local revealOriginCFrame = payload.RevealOriginCFrame
	if
		type(revealId) ~= "string"
		or self.ActiveReveals[revealId]
		or openerUserId <= 0
		or type(finalLostItemId) ~= "string"
		or LostItemConfig.GetLuckyTier(finalLostItemId) ~= boxTier
		or typeof(revealOriginCFrame) ~= "CFrame"
	then
		return
	end
	local opener = Players:GetPlayerByUserId(openerUserId)
	if not opener then
		return
	end
	local isLocalOpener = opener == Players.LocalPlayer
	local active = {
		RevealId = revealId,
		IsLocalOpener = isLocalOpener,
		RevealOriginCFrame = revealOriginCFrame,
		Visual = nil,
		ValueAnchor = nil,
	}
	self.ActiveReveals[revealId] = active
	if type(payload.SpawnId) == "string" then
		self:_destroyEntry(payload.SpawnId)
	end
	if isLocalOpener then
		local noticeState = {
			LostItemId = finalLostItemId,
			FlightFinished = false,
			CompletionReceived = false,
		}
		self.PendingNewItemNotices[revealId] = noticeState
		task.delay(NEW_ITEM_NOTICE_TIMEOUT, function()
			if self.PendingNewItemNotices[revealId] == noticeState then
				self.PendingNewItemNotices[revealId] = nil
			end
		end)
	end

	task.spawn(function()
		local candidates = LostItemConfig.Order
		local random = Random.new(math.floor(tonumber(payload.RevealSeed) or 1))
		local phaseEndTime = os.clock()
		for index = 1, DECOY_COUNT do
			if self.ActiveReveals[revealId] ~= active then
				return
			end
			local lostItemId = candidates[random:NextInteger(1, #candidates)]
			self:_destroyRevealVisual(active)
			active.Visual = self:_createRevealVisual(lostItemId, true)
			local growDuration, shrinkDuration = LostItemConfig.GetLuckyRevealPulseDurations(index)
			local phaseStartTime = phaseEndTime
			phaseEndTime += growDuration
			if not self:_animateRevealScale(
				active,
				phaseStartTime,
				phaseEndTime,
				START_SCALE,
				1,
				Enum.EasingStyle.Back,
				Enum.EasingDirection.Out
			) then
				return
			end
			phaseStartTime = phaseEndTime
			phaseEndTime += shrinkDuration
			if not self:_animateRevealScale(
				active,
				phaseStartTime,
				phaseEndTime,
				1,
				START_SCALE,
				Enum.EasingStyle.Quad,
				Enum.EasingDirection.In
			) then
				return
			end
		end

		if self.ActiveReveals[revealId] ~= active then
			return
		end
		self:_destroyRevealVisual(active)
		active.Visual = self:_createRevealVisual(finalLostItemId, false)
		local phaseStartTime = phaseEndTime
		phaseEndTime += FINAL_GROW_DURATION
		if not self:_animateRevealScale(
			active,
			phaseStartTime,
			phaseEndTime,
			START_SCALE,
			1,
			Enum.EasingStyle.Back,
			Enum.EasingDirection.Out
		) then
			return
		end
		active.ValueAnchor = self:_createValueAnchor(payload.RevealCoinValue)
		phaseEndTime += FINAL_HOLD_DURATION
		if not self:_displayRevealUntil(active, phaseEndTime) then
			return
		end
		phaseStartTime = phaseEndTime
		phaseEndTime += FLY_TO_PLAYER_DURATION
		if not self:_flyRevealToOpener(active, opener, phaseStartTime, phaseEndTime) then
			return
		end
		if isLocalOpener then
			local noticeState = self.PendingNewItemNotices[revealId]
			if noticeState then
				noticeState.FlightFinished = true
				self:_tryShowNewItemNotice(revealId)
			end
		end
		self:_finishReveal(active)
	end)
end

function LocalLostItemController:ApplySnapshot(snapshot)
	self.CurrentLeafValueMultiplier = math.max(
		0,
		tonumber(snapshot.LeafValueMultiplier) or tonumber(snapshot.CoinMultiplier) or 1
	)
	self:_updateCarryToolValues()
	local seen = {}
	for _, itemData in type(snapshot.PersonalWorldLostItems) == "table"
		and snapshot.PersonalWorldLostItems
		or {}
	do
		if
			type(itemData) == "table"
			and type(itemData.SpawnId) == "string"
			and typeof(itemData.WorldPivotCFrame) == "CFrame"
		then
			seen[itemData.SpawnId] = true
			local luckyTier = LostItemConfig.NormalizeLuckyTier(itemData.LuckyTier)
			local entry = self.Entries[itemData.SpawnId]
			if entry and entry.LuckyTier ~= luckyTier then
				self:_destroyEntry(itemData.SpawnId)
				entry = nil
			end
			entry = entry or self:_createEntry(itemData)
			if entry then
				entry.Model:PivotTo(itemData.WorldPivotCFrame)
				self:_updatePrompt(entry)
			end
		end
	end
	for spawnId in self.Entries do
		if not seen[spawnId] then
			self:_destroyEntry(spawnId)
		end
	end
end

function LocalLostItemController:Init(remotes, hudController)
	self.Remotes = remotes
	self.HUDController = hudController
	self.Entries = {}
	self.ActiveReveals = {}
	self.PendingNewItemNotices = {}
	self.CurrentLeafValueMultiplier = 1
	self.LostItemFolder = ReplicatedStorage:WaitForChild("LostItem")
	self.LuckyBoxFolder = ReplicatedStorage:WaitForChild("Lucky Block")
	local highlightContainer = ReplicatedStorage:FindFirstChild("miaobian")
	local highlight = highlightContainer and highlightContainer:FindFirstChild("Highlight03")
	self.RevealHighlightTemplate = if highlight and highlight:IsA("Highlight") then highlight else nil
	local valueTemplateModel = self.LostItemFolder:FindFirstChild("LostItem01")
	local valueTemplateUpgrade = valueTemplateModel and valueTemplateModel:FindFirstChild("upgrade")
	self.ValueBillboardTemplate = valueTemplateUpgrade and valueTemplateUpgrade:FindFirstChild("BillboardGui")
	assert(
		self.ValueBillboardTemplate and self.ValueBillboardTemplate:IsA("BillboardGui"),
		"ReplicatedStorage.LostItem.LostItem01.upgrade.BillboardGui must be a BillboardGui"
	)

	local existing = Workspace:FindFirstChild("LocalLostItems")
	if existing then
		existing:Destroy()
	end
	local container = Instance.new("Folder")
	container.Name = "LocalLostItems"
	container.Parent = Workspace
	self.Container = container

	local existingReveals = Workspace:FindFirstChild("LocalLostItemReveals")
	if existingReveals then
		existingReveals:Destroy()
	end
	local revealContainer = Instance.new("Folder")
	revealContainer.Name = "LocalLostItemReveals"
	revealContainer.Parent = Workspace
	self.RevealContainer = revealContainer

	remotes.LostItemRevealStarted.OnClientEvent:Connect(function(payload)
		self:_playReveal(payload)
	end)
	assert(
		remotes.LostItemRevealCompleted and remotes.LostItemRevealCompleted:IsA("RemoteEvent"),
		"LostItemRevealCompleted must be a RemoteEvent"
	)
	remotes.LostItemRevealCompleted.OnClientEvent:Connect(function(payload)
		self:_handleRevealCompleted(payload)
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:ApplySnapshot(snapshot)
	end)
end

return LocalLostItemController

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local LeafConfig = require(ReplicatedStorage.Shared.Config.LeafConfig)

local LeafGainHintController = {}

local TEMPLATE_NAME = "tishi"
local LOCAL_FOLDER_NAME = "LocalLeafGainHints"
local CLONE_NAME = "LeafGainHint"
local MAXIMUM_OUTSTANDING_HINTS = 30
local HINT_SPAWN_INTERVAL = 0.04
local HINT_HOLD_DURATION = 0.6
local HINT_RISE_DURATION = 0.8
local HINT_TOTAL_DURATION = HINT_HOLD_DURATION + HINT_RISE_DURATION
local HINT_RISE_DISTANCE = 3

local function isPositiveFiniteNumber(value)
	return type(value) == "number"
		and value == value
		and value > 0
		and value < math.huge
end

local function isFiniteVector3(value)
	if typeof(value) ~= "Vector3" then
		return false
	end
	for _, component in { value.X, value.Y, value.Z } do
		if component ~= component or component == math.huge or component == -math.huge then
			return false
		end
	end
	return true
end

local function formatHintValue(value)
	local numericValue = math.max(0, tonumber(value) or 0)
	if numericValue >= 1000 then
		return "+" .. CoinFormat.Compact(numericValue)
	end
	local roundedValue = math.floor(numericValue * 10 + 0.5) / 10
	local integerValue = math.floor(roundedValue + 0.5)
	if math.abs(roundedValue - integerValue) < 1e-9 then
		return "+" .. tostring(integerValue)
	end
	return "+" .. string.format("%.1f", roundedValue)
end

function LeafGainHintController:Init(remotes)
	self.Template = nil
	self.TemplateRotation = CFrame.identity
	self.TemplateDefaultImage = ""
	self.TemplateWarningIssued = false
	self.LocalFolder = nil
	self.AvailableHints = {}
	self.OutstandingHintCount = 0
	self.HintRandom = Random.new()
	self.ScheduledHints = {}
	self.ScheduledHintHead = 1
	self.ScheduledHintTail = 0
	self.PacingConnection = nil
	self.LastHintSpawnAt = -math.huge

	self:_ensureLocalFolder()
	self:_bindTemplateIfAvailable()
	ReplicatedStorage.ChildAdded:Connect(function(child)
		if child.Name == TEMPLATE_NAME then
			task.defer(function()
				self:_bindTemplateIfAvailable()
			end)
		end
	end)

	remotes.LeafCollected.OnClientEvent:Connect(function(_, _, _, leafHints)
		self:_receiveLeafHints(leafHints)
	end)
end

function LeafGainHintController:_warnTemplate(message)
	if self.TemplateWarningIssued then
		return
	end
	self.TemplateWarningIssued = true
	warn("World leaf-gain hints are disabled: " .. message)
end

function LeafGainHintController:_ensureLocalFolder()
	local folder = Workspace:FindFirstChild(LOCAL_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = LOCAL_FOLDER_NAME
		folder.Parent = Workspace
	end
	if not folder:IsA("Folder") then
		self:_warnTemplate("Workspace." .. LOCAL_FOLDER_NAME .. " must be a Folder")
		return nil
	end
	self.LocalFolder = folder
	return folder
end

function LeafGainHintController:_getTemplateNodes(template)
	if not template or not template:IsA("BasePart") then
		return nil
	end
	local billboard = template:FindFirstChild("BillboardGui")
	local frame = billboard and billboard:FindFirstChild("GetHint")
	local icon = frame and frame:FindFirstChild("Icon")
	local textLabel = frame and frame:FindFirstChild("TextLabel")
	if
		not billboard
		or not billboard:IsA("BillboardGui")
		or not frame
		or not frame:IsA("GuiObject")
		or not icon
		or not icon:IsA("ImageLabel")
		or not textLabel
		or not textLabel:IsA("TextLabel")
	then
		return nil
	end
	return {
		Billboard = billboard,
		Frame = frame,
		Icon = icon,
		TextLabel = textLabel,
		Stroke = textLabel:FindFirstChildOfClass("UIStroke"),
	}
end

function LeafGainHintController:_bindTemplateIfAvailable()
	if self.Template and self.Template.Parent then
		return true
	end
	local template = ReplicatedStorage:FindFirstChild(TEMPLATE_NAME)
	local nodes = self:_getTemplateNodes(template)
	if not nodes then
		self.Template = nil
		self:_warnTemplate(
			"ReplicatedStorage.tishi.BillboardGui.GetHint.Icon/TextLabel is missing or invalid"
		)
		return false
	end
	self.Template = template
	self.TemplateRotation = template.CFrame.Rotation
	self.TemplateDefaultImage = nodes.Icon.Image
	return true
end

function LeafGainHintController:_createHint()
	if not self:_bindTemplateIfAvailable() then
		return nil
	end
	local part = self.Template:Clone()
	part.Name = CLONE_NAME
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	local nodes = self:_getTemplateNodes(part)
	if not nodes then
		part:Destroy()
		return nil
	end
	part.Parent = nil
	return {
		Part = part,
		Billboard = nodes.Billboard,
		Frame = nodes.Frame,
		Icon = nodes.Icon,
		TextLabel = nodes.TextLabel,
		Stroke = nodes.Stroke,
		DefaultImageTransparency = nodes.Icon.ImageTransparency,
		DefaultTextTransparency = nodes.TextLabel.TextTransparency,
		DefaultTextStrokeTransparency = nodes.TextLabel.TextStrokeTransparency,
		DefaultStrokeTransparency = if nodes.Stroke then nodes.Stroke.Transparency else nil,
		ActiveTweens = nil,
		InUse = false,
	}
end

function LeafGainHintController:_takeHint()
	local hint = table.remove(self.AvailableHints)
	if not hint then
		hint = self:_createHint()
	end
	if hint then
		hint.InUse = true
	end
	return hint
end

function LeafGainHintController:_restoreHint(hint)
	local icon = hint.Icon
	local textLabel = hint.TextLabel
	icon.ImageTransparency = hint.DefaultImageTransparency
	textLabel.TextTransparency = hint.DefaultTextTransparency
	textLabel.TextStrokeTransparency = hint.DefaultTextStrokeTransparency
	if hint.Stroke and hint.DefaultStrokeTransparency ~= nil then
		hint.Stroke.Transparency = hint.DefaultStrokeTransparency
	end
	hint.Billboard.Enabled = false
	hint.Frame.Visible = true
end

function LeafGainHintController:_releaseHint(hint)
	if not hint or not hint.InUse then
		return
	end
	hint.InUse = false
	for _, tween in hint.ActiveTweens or {} do
		tween:Cancel()
	end
	hint.ActiveTweens = nil
	self:_restoreHint(hint)
	hint.Part.Parent = nil
	table.insert(self.AvailableHints, hint)
end

function LeafGainHintController:_releaseOutstandingSlot()
	self.OutstandingHintCount = math.max(0, self.OutstandingHintCount - 1)
end

function LeafGainHintController:_playHint(leafHint)
	local localFolder = self.LocalFolder or self:_ensureLocalFolder()
	local hint = localFolder and self:_takeHint() or nil
	if not hint then
		self:_releaseOutstandingSlot()
		return false
	end

	local leafTypeConfig = type(leafHint.LeafType) == "string"
		and LeafConfig.Types[leafHint.LeafType]
		or nil
	local configuredImage = leafTypeConfig and leafTypeConfig.Image
	hint.Icon.Image = if type(configuredImage) == "string" and configuredImage ~= ""
		then configuredImage
		else self.TemplateDefaultImage
	hint.TextLabel.Text = formatHintValue(leafHint.DisplayValue)
	self:_restoreHint(hint)
	hint.Billboard.Enabled = true

	local startCFrame = CFrame.new(leafHint.WorldPosition) * self.TemplateRotation
	hint.Part.CFrame = startCFrame
	hint.Part.Parent = localFolder

	task.spawn(function()
		local succeeded, message = xpcall(function()
			local moveTween = TweenService:Create(
				hint.Part,
				TweenInfo.new(
					HINT_TOTAL_DURATION,
					Enum.EasingStyle.Quad,
					Enum.EasingDirection.Out
				),
				{ CFrame = startCFrame + Vector3.new(0, HINT_RISE_DISTANCE, 0) }
			)
			hint.ActiveTweens = { moveTween }
			moveTween:Play()
			task.wait(HINT_HOLD_DURATION)
			if not hint.InUse or hint.Part.Parent ~= localFolder then
				return
			end
			local iconTween = TweenService:Create(
				hint.Icon,
				TweenInfo.new(HINT_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ ImageTransparency = 1 }
			)
			local textTween = TweenService:Create(
				hint.TextLabel,
				TweenInfo.new(HINT_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ TextTransparency = 1, TextStrokeTransparency = 1 }
			)
			local tweens = { moveTween, iconTween, textTween }
			if hint.Stroke then
				local strokeTween = TweenService:Create(
					hint.Stroke,
					TweenInfo.new(HINT_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Transparency = 1 }
				)
				table.insert(tweens, strokeTween)
			end
			hint.ActiveTweens = tweens
			for index = 2, #tweens do
				local tween = tweens[index]
				tween:Play()
			end
			moveTween.Completed:Wait()
		end, debug.traceback)
		self:_releaseHint(hint)
		self:_releaseOutstandingSlot()
		if not succeeded then
			warn("World leaf-gain hint playback failed: " .. tostring(message))
		end
	end)
	return true
end

function LeafGainHintController:_normalizeHint(leafHint)
	if
		type(leafHint) ~= "table"
		or not isPositiveFiniteNumber(leafHint.BagAmount)
		or not isPositiveFiniteNumber(leafHint.DisplayValue)
		or not isFiniteVector3(leafHint.WorldPosition)
	then
		return nil
	end
	return {
		LeafType = leafHint.LeafType,
		DisplayValue = leafHint.DisplayValue,
		WorldPosition = leafHint.WorldPosition,
	}
end

function LeafGainHintController:_popScheduledHint()
	if self.ScheduledHintHead > self.ScheduledHintTail then
		return nil
	end
	local leafHint = self.ScheduledHints[self.ScheduledHintHead]
	self.ScheduledHints[self.ScheduledHintHead] = nil
	self.ScheduledHintHead += 1
	if self.ScheduledHintHead > self.ScheduledHintTail then
		table.clear(self.ScheduledHints)
		self.ScheduledHintHead = 1
		self.ScheduledHintTail = 0
	end
	return leafHint
end

function LeafGainHintController:_hasScheduledHints()
	return self.ScheduledHintHead <= self.ScheduledHintTail
end

function LeafGainHintController:_playNextScheduledHint()
	local leafHint = self:_popScheduledHint()
	if not leafHint then
		return false
	end
	self.LastHintSpawnAt = os.clock()
	local succeeded, message = pcall(function()
		self:_playHint(leafHint)
	end)
	if not succeeded then
		self:_releaseOutstandingSlot()
		warn("World leaf-gain hint startup failed: " .. tostring(message))
	end
	return true
end

function LeafGainHintController:_stopPacing()
	if self.PacingConnection then
		self.PacingConnection:Disconnect()
		self.PacingConnection = nil
	end
end

function LeafGainHintController:_startPacing()
	if self.PacingConnection or not self:_hasScheduledHints() then
		return
	end
	if os.clock() - self.LastHintSpawnAt >= HINT_SPAWN_INTERVAL then
		self:_playNextScheduledHint()
		if not self:_hasScheduledHints() then
			return
		end
	end
	self.PacingConnection = RunService.Heartbeat:Connect(function()
		if not self:_hasScheduledHints() then
			self:_stopPacing()
			return
		end
		if os.clock() - self.LastHintSpawnAt < HINT_SPAWN_INTERVAL then
			return
		end
		self:_playNextScheduledHint()
		if not self:_hasScheduledHints() then
			self:_stopPacing()
		end
	end)
end

function LeafGainHintController:_scheduleHints(leafHints)
	if not self:_bindTemplateIfAvailable() or not self.LocalFolder then
		return false
	end
	local leafHintCount = #leafHints
	local availableSlots = math.max(
		0,
		MAXIMUM_OUTSTANDING_HINTS - self.OutstandingHintCount
	)
	local acceptedCount = math.min(leafHintCount, availableSlots)
	if acceptedCount <= 0 then
		return false
	end
	for index = 1, acceptedCount do
		local selectedIndex = self.HintRandom:NextInteger(index, leafHintCount)
		leafHints[index], leafHints[selectedIndex] = leafHints[selectedIndex], leafHints[index]
		self.ScheduledHintTail += 1
		self.ScheduledHints[self.ScheduledHintTail] = leafHints[index]
	end
	self.OutstandingHintCount += acceptedCount
	self:_startPacing()
	return true
end

function LeafGainHintController:_receiveLeafHints(leafHints)
	if type(leafHints) ~= "table" then
		return
	end
	local validHints = {}
	for _, leafHint in leafHints do
		local normalizedHint = self:_normalizeHint(leafHint)
		if normalizedHint then
			table.insert(validHints, normalizedHint)
		end
	end
	if #validHints > 0 then
		self:_scheduleHints(validHints)
	end
end

return LeafGainHintController

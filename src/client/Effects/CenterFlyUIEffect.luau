local TweenService = game:GetService("TweenService")

-- 效果名称：CenterFlyUIEffect（随机出现并飞向目标）
-- 克隆完整GuiObject，在指定分布区域停留，随后飞向目标并整体淡出；可选对象池负责复用克隆。
local CenterFlyUIEffect = {}

local random = Random.new()
local OUTER_WEIGHTED_ELLIPSE = "OuterWeightedEllipse"
local poolsByTemplate = setmetatable({}, { __mode = "k" })

local function captureReusableState(root)
	local reusableState = {}
	local instances = { root }
	for _, descendant in root:GetDescendants() do
		table.insert(instances, descendant)
	end

	for _, instance in instances do
		local properties = {}
		if instance == root then
			properties.Name = instance.Name
		end
		if instance:IsA("GuiObject") then
			properties.BackgroundTransparency = instance.BackgroundTransparency
			properties.Visible = instance.Visible
			properties.AnchorPoint = instance.AnchorPoint
			properties.Position = instance.Position
			properties.ZIndex = instance.ZIndex
		end
		if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
			properties.Text = instance.Text
			properties.TextTransparency = instance.TextTransparency
			properties.TextStrokeTransparency = instance.TextStrokeTransparency
		end
		if instance:IsA("ImageLabel") or instance:IsA("ImageButton") then
			properties.Image = instance.Image
			properties.ImageTransparency = instance.ImageTransparency
		elseif instance:IsA("ViewportFrame") then
			properties.ImageTransparency = instance.ImageTransparency
		end
		if instance:IsA("ScrollingFrame") then
			properties.ScrollBarImageTransparency = instance.ScrollBarImageTransparency
		end
		if instance:IsA("CanvasGroup") then
			properties.GroupTransparency = instance.GroupTransparency
		end
		if instance:IsA("UIStroke") then
			properties.Transparency = instance.Transparency
		end
		if instance:IsA("UIScale") then
			properties.Scale = instance.Scale
		end
		if next(properties) then
			table.insert(reusableState, {
				Instance = instance,
				Properties = properties,
			})
		end
	end

	return reusableState
end

local function restoreReusableState(entry)
	for _, stateEntry in entry.ReusableState do
		local instance = stateEntry.Instance
		for propertyName, value in stateEntry.Properties do
			instance[propertyName] = value
		end
	end
end

local function getPool(template, parent)
	local poolsByParent = poolsByTemplate[template]
	if not poolsByParent then
		poolsByParent = setmetatable({}, { __mode = "k" })
		poolsByTemplate[template] = poolsByParent
	end
	local pool = poolsByParent[parent]
	if not pool then
		pool = {}
		poolsByParent[parent] = pool
	end
	return pool
end

local function createPooledEntry(template, pool)
	local clone = template:Clone()
	local uiScale = clone:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Name = "CenterFlyAppearScale"
		uiScale.Parent = clone
	end
	return {
		Instance = clone,
		UIScale = uiScale,
		ReusableState = captureReusableState(clone),
		Pool = pool,
		InPool = false,
	}
end

local function acquirePooledEntry(template, parent)
	local pool = getPool(template, parent)
	local entry = table.remove(pool)
	if not entry then
		entry = createPooledEntry(template, pool)
	else
		restoreReusableState(entry)
	end
	entry.InPool = false
	return entry
end

local function releaseClone(clone, pooledEntry, parent)
	if not pooledEntry then
		clone:Destroy()
		return
	end
	if pooledEntry.InPool then
		return
	end
	if parent.Parent == nil then
		pooledEntry.InPool = true
		clone:Destroy()
		return
	end
	restoreReusableState(pooledEntry)
	clone.Parent = nil
	pooledEntry.InPool = true
	table.insert(pooledEntry.Pool, pooledEntry)
end

local function toLocalPosition(parent, absolutePosition)
	local parentPosition = parent.AbsolutePosition
	return UDim2.fromOffset(
		absolutePosition.X - parentPosition.X,
		absolutePosition.Y - parentPosition.Y
	)
end

local function getFadeGoals(instance)
	local goals = {}
	if instance:IsA("GuiObject") then
		goals.BackgroundTransparency = 1
	end
	if instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox") then
		goals.TextTransparency = 1
		goals.TextStrokeTransparency = 1
	end
	if instance:IsA("ImageLabel") or instance:IsA("ImageButton") or instance:IsA("ViewportFrame") then
		goals.ImageTransparency = 1
	end
	if instance:IsA("ScrollingFrame") then
		goals.ScrollBarImageTransparency = 1
	end
	if instance:IsA("CanvasGroup") then
		goals.GroupTransparency = 1
	end
	if instance:IsA("UIStroke") then
		goals.Transparency = 1
	end
	return goals
end

local function getRectangularOffset(randomArea)
	return Vector2.new(
		random:NextNumber(-randomArea.X / 2, randomArea.X / 2),
		random:NextNumber(-randomArea.Y / 2, randomArea.Y / 2)
	)
end

local function getOuterWeightedEllipseOffset(options, parent, clone, template)
	local parentSize = parent.AbsoluteSize
	local cloneSize = clone.AbsoluteSize
	local templateSize = template.AbsoluteSize
	local halfCloneSize = Vector2.new(
		math.max(cloneSize.X, templateSize.X) / 2,
		math.max(cloneSize.Y, templateSize.Y) / 2
	)
	local edgePadding = math.max(0, tonumber(options.EdgePadding) or 24)
	local configuredScale = options.OuterAreaScale
	local outerAreaScale = if typeof(configuredScale) == "Vector2"
		then Vector2.new(math.clamp(configuredScale.X, 0, 1), math.clamp(configuredScale.Y, 0, 1))
		else Vector2.new(0.9, 0.8)
	local radiusX = math.min(
		parentSize.X * outerAreaScale.X / 2,
		math.max(0, parentSize.X / 2 - halfCloneSize.X - edgePadding)
	)
	local radiusY = math.min(
		parentSize.Y * outerAreaScale.Y / 2,
		math.max(0, parentSize.Y / 2 - halfCloneSize.Y - edgePadding)
	)

	local centerChance = math.clamp(tonumber(options.CenterChance) or 0.15, 0, 1)
	local innerRadiusRatio = math.clamp(tonumber(options.InnerRadiusRatio) or 0.3, 0, 1)
	local angle = random:NextNumber(0, math.pi * 2)
	local radius
	if random:NextNumber() < centerChance then
		radius = innerRadiusRatio * math.sqrt(random:NextNumber())
	else
		radius = innerRadiusRatio + (1 - innerRadiusRatio) * math.sqrt(random:NextNumber())
	end

	return Vector2.new(
		math.cos(angle) * radiusX * radius,
		math.sin(angle) * radiusY * radius
	)
end

local function getRandomOffset(options, parent, clone, template)
	if options.PositionDistribution == OUTER_WEIGHTED_ELLIPSE then
		return getOuterWeightedEllipseOffset(options, parent, clone, template)
	end
	local randomArea = options.RandomArea
	assert(typeof(randomArea) == "Vector2", "CenterFlyUIEffect RandomArea must be a Vector2")
	return getRectangularOffset(randomArea)
end

function CenterFlyUIEffect.Play(options)
	local template = options.Template
	local parent = options.Parent
	local target = options.Target

	local pooledEntry = if options.UsePool == true then acquirePooledEntry(template, parent) else nil
	local clone = if pooledEntry then pooledEntry.Instance else template:Clone()
	local finished = false
	local function finish()
		if finished then
			return
		end
		finished = true
		local releaseSucceeded, releaseError = pcall(releaseClone, clone, pooledEntry, parent)
		if not releaseSucceeded then
			warn("CenterFlyUIEffect release failed: " .. tostring(releaseError))
		end
		if type(options.OnFinished) == "function" then
			local callbackSucceeded, callbackError = pcall(options.OnFinished, clone)
			if not callbackSucceeded then
				warn("CenterFlyUIEffect OnFinished failed: " .. tostring(callbackError))
			end
		end
	end
	clone.Name = options.CloneName
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.ZIndex = math.max(clone.ZIndex, options.MinimumZIndex)
	if type(options.ImageObjectName) == "string" and options.ImageObjectName ~= "" then
		local imageObject = clone:FindFirstChild(options.ImageObjectName, true)
		assert(
			imageObject and (imageObject:IsA("ImageLabel") or imageObject:IsA("ImageButton")),
			string.format("CenterFlyUIEffect image object %s must be an ImageLabel or ImageButton", options.ImageObjectName)
		)
		if type(options.Image) == "string" and options.Image ~= "" then
			imageObject.Image = options.Image
		end
	end
	clone.Visible = true
	clone.Parent = parent

	local textObject = clone:FindFirstChild(options.TextObjectName, true)
	textObject.Text = options.Text
	textObject.TextTransparency = 0
	textObject.Visible = true

	local parentCenter = parent.AbsolutePosition + parent.AbsoluteSize / 2
	local randomOffset = getRandomOffset(options, parent, clone, template)
	clone.Position = toLocalPosition(parent, parentCenter + randomOffset)

	local uiScale = if pooledEntry then pooledEntry.UIScale else clone:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Name = "CenterFlyAppearScale"
		uiScale.Parent = clone
	end
	local targetScale = uiScale.Scale
	uiScale.Scale = targetScale * options.StartScale
	local appearTween = TweenService:Create(
		uiScale,
		TweenInfo.new(
			options.AppearTime,
			options.AppearEasingStyle,
			options.AppearEasingDirection
		),
		{ Scale = targetScale }
	)
	appearTween:Play()

	task.spawn(function()
		local succeeded, failure = pcall(function()
			appearTween.Completed:Wait()
			if not clone.Parent then
				return
			end
			task.wait(options.HoldTime)
			if not clone.Parent or not target.Parent then
				return
			end

			local flyTime = options.FlyTime
			local tweenInfo = TweenInfo.new(
				flyTime,
				options.EasingStyle,
				options.EasingDirection
			)
			local targetCenter = target.AbsolutePosition + target.AbsoluteSize / 2
			local targetPosition = toLocalPosition(parent, targetCenter)
			local rootTween
			local flyTweens = {}

			local instances = { clone }
			for _, descendant in clone:GetDescendants() do
				table.insert(instances, descendant)
			end
			for _, instance in instances do
				local goals = getFadeGoals(instance)
				if instance == clone then
					goals.Position = targetPosition
				end
				if next(goals) then
					local tween = TweenService:Create(instance, tweenInfo, goals)
					if instance == clone then
						rootTween = tween
					end
					table.insert(flyTweens, tween)
				end
			end
			local configuredFlyEndScale = tonumber(options.FlyEndScale)
			if configuredFlyEndScale and configuredFlyEndScale == configuredFlyEndScale then
				local scaleTween = TweenService:Create(
					uiScale,
					tweenInfo,
					{ Scale = targetScale * math.max(0, configuredFlyEndScale) }
				)
				table.insert(flyTweens, scaleTween)
			end
			for _, tween in flyTweens do
				tween:Play()
			end

			rootTween.Completed:Wait()
			for _, tween in flyTweens do
				tween:Cancel()
			end
		end)
		if not succeeded then
			warn("CenterFlyUIEffect playback failed: " .. tostring(failure))
		end
		finish()
	end)

	return clone
end

return CenterFlyUIEffect

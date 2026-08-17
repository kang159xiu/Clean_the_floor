local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local CleaningToolActionService = {}

local CLEANING_TOOL_ATTRIBUTE = "CleaningToolId"
local ACTION_FADE_TIME = 0.1

local actionStates = {}

local function destroyResources(actionState)
	if actionState.Track then
		actionState.Track:Destroy()
	end
	if actionState.Animation then
		actionState.Animation:Destroy()
	end
end

function CleaningToolActionService:_destroyState(player, fadeTime)
	local actionState = actionStates[player]
	if not actionState then
		return
	end
	actionStates[player] = nil

	local fadeDuration = math.max(0, tonumber(fadeTime) or 0)
	if actionState.Track and fadeDuration > 0 and actionState.Track.IsPlaying then
		actionState.Track:Stop(fadeDuration)
		task.delay(fadeDuration + 0.03, function()
			destroyResources(actionState)
		end)
	else
		if actionState.Track then
			actionState.Track:Stop(0)
		end
		destroyResources(actionState)
	end
end

function CleaningToolActionService:_getEquippedAnimator(player, toolId)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local equippedTool = character and character:FindFirstChildOfClass("Tool")
	if
		not character
		or not humanoid
		or humanoid.Health <= 0
		or not animator
		or not equippedTool
		or equippedTool:GetAttribute(CLEANING_TOOL_ATTRIBUTE) ~= toolId
	then
		return nil
	end
	return animator
end

function CleaningToolActionService:_getTrack(player, toolId, looped)
	local toolConfig = ToolConfig.ById[toolId]
	local animationId = toolConfig.ActionAnimationId
	local animator = self:_getEquippedAnimator(player, toolId)
	if not animator then
		return nil
	end

	local existingState = actionStates[player]
	if
		existingState
		and existingState.ToolId == toolId
		and existingState.Animator == animator
		and existingState.Looped == looped
	then
		return existingState.Track
	end
	self:_destroyState(player, ACTION_FADE_TIME)

	local animation = Instance.new("Animation")
	animation.Name = "CleaningToolActionAnimation"
	animation.AnimationId = animationId
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action2
	track.Looped = looped
	actionStates[player] = {
		ToolId = toolId,
		Animator = animator,
		Animation = animation,
		Track = track,
		Looped = looped,
	}
	return track
end

function CleaningToolActionService:SetContinuousActive(player, toolId, active)
	if active ~= true then
		local actionState = actionStates[player]
		if actionState and actionState.Looped then
			self:_destroyState(player, ACTION_FADE_TIME)
		end
		return
	end

	local toolConfig = ToolConfig.ById[toolId]
	if not toolConfig or toolConfig.ActionAnimationMode ~= "WhileActive" then
		return
	end
	local track = self:_getTrack(player, toolId, true)
	if track and not track.IsPlaying then
		track:Play(ACTION_FADE_TIME, 1, 1)
	end
end

function CleaningToolActionService:PlayBatch(player, toolId, pickupInterval)
	local toolConfig = ToolConfig.ById[toolId]
	if not toolConfig or toolConfig.ActionAnimationMode ~= "Batch" then
		return
	end
	local interval = tonumber(pickupInterval)
	if not interval or interval <= 0 then
		return
	end

	local track = self:_getTrack(player, toolId, false)
	if not track then
		return
	end
	local referenceInterval = math.max(0.01, tonumber(toolConfig.ActionReferenceInterval) or 0.6)
	track:Stop(0)
	track:Play(0.03, 1, referenceInterval / interval)
end

function CleaningToolActionService:PlaySingle(player, toolId)
	local toolConfig = ToolConfig.ById[toolId]
	if not toolConfig or toolConfig.ActionAnimationMode ~= "Single" then
		return
	end
	local track = self:_getTrack(player, toolId, false)
	if not track then
		return
	end
	track:Stop(0)
	track:Play(0.03, 1, 1)
end

function CleaningToolActionService:StopPlayer(player)
	self:_destroyState(player, ACTION_FADE_TIME)
end

function CleaningToolActionService:Init()
	local function bindPlayer(player)
		player.CharacterAdded:Connect(function()
			self:_destroyState(player, 0)
		end)
	end

	Players.PlayerAdded:Connect(bindPlayer)
	Players.PlayerRemoving:Connect(function(player)
		self:_destroyState(player, 0)
	end)
	for _, player in Players:GetPlayers() do
		bindPlayer(player)
	end
end

return CleaningToolActionService

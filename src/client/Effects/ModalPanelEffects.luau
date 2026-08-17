local TweenService = game:GetService("TweenService")

local ModalPanelEffects = {}

local OPEN_START_Y_OFFSET = 90
local OPEN_OVERSHOOT_Y_OFFSET = -12
local OPEN_RISE_DURATION = 0.22
local OPEN_SETTLE_DURATION = 0.1
local HOVER_SCALE_MULTIPLIER = 1.08
local HOVER_GROW_DURATION = 0.12
local HOVER_RETURN_DURATION = 0.1
local HOVER_SCALE_NAME = "LocalModalHoverScale"
local DEFAULT_PULSE_SCALE_MULTIPLIER = 1.12
local DEFAULT_PULSE_DURATION = 0.35

local panelStates = setmetatable({}, { __mode = "k" })
local buttonStates = setmetatable({}, { __mode = "k" })

local function offsetPosition(position, yOffset)
	return UDim2.new(
		position.X.Scale,
		position.X.Offset,
		position.Y.Scale,
		position.Y.Offset + yOffset
	)
end

local function getPanelState(panel)
	local state = panelStates[panel]
	if state then
		return state
	end

	state = {
		RestingPosition = panel.Position,
		Serial = 0,
		Tween = nil,
	}
	panelStates[panel] = state
	return state
end

local function cancelPanelTween(state)
	if state.Tween then
		state.Tween:Cancel()
		state.Tween = nil
	end
end

function ModalPanelEffects.PlayOpen(panel)
	assert(panel and panel:IsA("GuiObject"), "Modal panel must be a GuiObject")
	local state = getPanelState(panel)
	state.Serial += 1
	local serial = state.Serial
	cancelPanelTween(state)

	panel.Position = offsetPosition(state.RestingPosition, OPEN_START_Y_OFFSET)
	panel.Visible = true

	local riseTween = TweenService:Create(
		panel,
		TweenInfo.new(OPEN_RISE_DURATION, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Position = offsetPosition(state.RestingPosition, OPEN_OVERSHOOT_Y_OFFSET) }
	)
	state.Tween = riseTween
	riseTween:Play()

	task.spawn(function()
		local playbackState = riseTween.Completed:Wait()
		if
			playbackState ~= Enum.PlaybackState.Completed
			or state.Serial ~= serial
			or not panel.Parent
			or not panel.Visible
		then
			return
		end

		local settleTween = TweenService:Create(
			panel,
			TweenInfo.new(OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut),
			{ Position = state.RestingPosition }
		)
		state.Tween = settleTween
		settleTween:Play()
		local settleState = settleTween.Completed:Wait()
		if settleState == Enum.PlaybackState.Completed and state.Serial == serial and panel.Parent then
			panel.Position = state.RestingPosition
			state.Tween = nil
		end
	end)
end

function ModalPanelEffects.StopOpen(panel)
	if not panel or not panel:IsA("GuiObject") then
		return
	end
	local state = getPanelState(panel)
	state.Serial += 1
	cancelPanelTween(state)
	panel.Position = state.RestingPosition
end

function ModalPanelEffects.BindOpenButton(button)
	assert(button and button:IsA("GuiButton"), "Modal open button must be a GuiButton")
	if buttonStates[button] then
		return
	end

	local scale = button:FindFirstChildWhichIsA("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = HOVER_SCALE_NAME
		scale.Scale = 1
		scale.Parent = button
	end

	local state = {
		BaseScale = scale.Scale,
		Scale = scale,
		HoverValue = Instance.new("NumberValue"),
		PulseValue = Instance.new("NumberValue"),
		HoverTween = nil,
		PulseTween = nil,
		PulseActive = false,
	}
	state.HoverValue.Value = 1
	state.PulseValue.Value = 1
	buttonStates[button] = state

	local function applyScale()
		if button.Visible then
			state.Scale.Scale = state.BaseScale * state.HoverValue.Value * state.PulseValue.Value
		else
			state.Scale.Scale = state.BaseScale
		end
	end
	state.ApplyScale = applyScale

	local function tweenHoverTo(targetMultiplier, duration)
		if state.HoverTween then
			state.HoverTween:Cancel()
		end
		state.HoverTween = TweenService:Create(
			state.HoverValue,
			TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Value = targetMultiplier }
		)
		state.HoverTween:Play()
	end

	state.HoverValue:GetPropertyChangedSignal("Value"):Connect(applyScale)
	state.PulseValue:GetPropertyChangedSignal("Value"):Connect(applyScale)

	button.MouseEnter:Connect(function()
		if button.Visible and button.Active then
			tweenHoverTo(HOVER_SCALE_MULTIPLIER, HOVER_GROW_DURATION)
		end
	end)
	button.MouseLeave:Connect(function()
		tweenHoverTo(1, HOVER_RETURN_DURATION)
	end)
	button:GetPropertyChangedSignal("Visible"):Connect(function()
		if not button.Visible then
			if state.HoverTween then
				state.HoverTween:Cancel()
				state.HoverTween = nil
			end
			state.HoverValue.Value = 1
		end
		applyScale()
	end)
	applyScale()
end

function ModalPanelEffects.SetOpenButtonPulse(button, active, scaleMultiplier, duration)
	assert(button and button:IsA("GuiButton"), "Modal open button must be a GuiButton")
	if not buttonStates[button] then
		ModalPanelEffects.BindOpenButton(button)
	end
	local state = buttonStates[button]
	local shouldPulse = active == true
	if state.PulseActive == shouldPulse and (not shouldPulse or state.PulseTween ~= nil) then
		return
	end

	state.PulseActive = shouldPulse
	if state.PulseTween then
		state.PulseTween:Cancel()
		state.PulseTween = nil
	end
	state.PulseValue.Value = 1
	state.ApplyScale()
	if not shouldPulse then
		if state.HoverTween then
			state.HoverTween:Cancel()
			state.HoverTween = nil
		end
		state.HoverValue.Value = 1
		state.ApplyScale()
		return
	end

	local targetMultiplier = math.max(1, tonumber(scaleMultiplier) or DEFAULT_PULSE_SCALE_MULTIPLIER)
	local pulseDuration = math.max(0.05, tonumber(duration) or DEFAULT_PULSE_DURATION)
	local tween = TweenService:Create(
		state.PulseValue,
		TweenInfo.new(
			pulseDuration,
			Enum.EasingStyle.Sine,
			Enum.EasingDirection.InOut,
			-1,
			true
		),
		{ Value = targetMultiplier }
	)
	state.PulseTween = tween
	tween:Play()
end

return ModalPanelEffects

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local CoinFlipConfig = require(ReplicatedStorage.Shared.Config.CoinFlipConfig)
local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)

local CoinFlipController = {}

local ZONE_POLL_INTERVAL = 0.1
local HOLD_STEP_INTERVAL = 0.01
local CAMERA_ENTRY_DURATION = 0.25
local CAMERA_RETURN_DURATION = 0.2
local CAMERA_ENTRY_FOV = 45
local CAMERA_FLIGHT_FOV = 35
local CAMERA_FLIGHT_POSITION_PUSH = 0.25
local BUTTON_PRESS_SCALE = 0.9
local BUTTON_PRESS_IN_DURATION = 0.07
local BUTTON_PRESS_OUT_DURATION = 0.12
local WAGER_COUNT_DURATION = 0.1
local WAGER_WAVE_SCALE = 1.08
local WAGER_WAVE_IN_DURATION = 0.05
local WAGER_WAVE_OUT_DURATION = 0.08
local FLIGHT_PEAK_HEIGHT = 10
local FLIGHT_FULL_ROTATIONS = 16
local PRELAUNCH_DELAY = 0.2
local PRELAUNCH_APEX_DURATION = 2
local PRELAUNCH_ROTATIONS_PER_SECOND = 8
local PRELAUNCH_CAMERA_POSITION_PUSH = 0.08
local PRELAUNCH_CAMERA_FOV = 43
local PRELAUNCH_FAILURE_RETURN_DURATION = 0.2
local MOVEMENT_SINK_ACTION = "CoinFlipMovementSink"
local MOVEMENT_SINK_PRIORITY = 4000
local LOCAL_MODEL_FOLDER_NAME = "LocalCoinFlip"
local WORLD_OBJECT_WAIT_TIMEOUT = 15

local function smoothStep(value)
	local alpha = math.clamp(value, 0, 1)
	return alpha * alpha * (3 - 2 * alpha)
end

local function lerpAngle(startAngle, endAngle, alpha)
	local difference = (endAngle - startAngle + math.pi) % (math.pi * 2) - math.pi
	return startAngle + difference * alpha
end

local function isInsidePart(part, worldPosition)
	local localPosition = part.CFrame:PointToObjectSpace(worldPosition)
	local halfSize = part.Size * 0.5
	return math.abs(localPosition.X) <= halfSize.X
		and math.abs(localPosition.Y) <= halfSize.Y + 3
		and math.abs(localPosition.Z) <= halfSize.Z
end

local function setGuiButtonEnabled(button, enabled)
	button.Active = enabled
	button.Interactable = enabled
end

function CoinFlipController:_notify(message)
	if type(message) == "string" and message ~= "" then
		self.HUDController:ShowNotification(message, 3, true)
	end
end

function CoinFlipController:_getRootAndHumanoid()
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and rootPart and rootPart:IsA("BasePart") then
		return rootPart, humanoid
	end
	return nil, humanoid
end

function CoinFlipController:_isPlayerInZone()
	local rootPart = self:_getRootAndHumanoid()
	return rootPart ~= nil and isInsidePart(self.ClickPart, rootPart.Position)
end

function CoinFlipController:_sinkMovement()
	return Enum.ContextActionResult.Sink
end

function CoinFlipController:_freezeCharacter()
	local rootPart, humanoid = self:_getRootAndHumanoid()
	if not rootPart or not humanoid then
		return
	end
	self.FrozenHumanoid = humanoid
	self.FrozenWalkSpeed = humanoid.WalkSpeed
	self.FrozenAutoRotate = humanoid.AutoRotate
	self.FrozenUseJumpPower = humanoid.UseJumpPower
	self.FrozenJumpValue = if humanoid.UseJumpPower then humanoid.JumpPower else humanoid.JumpHeight
	humanoid.WalkSpeed = 0
	humanoid.AutoRotate = false
	if humanoid.UseJumpPower then
		humanoid.JumpPower = 0
	else
		humanoid.JumpHeight = 0
	end
	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	ContextActionService:UnbindAction(MOVEMENT_SINK_ACTION)
	ContextActionService:BindActionAtPriority(
		MOVEMENT_SINK_ACTION,
		function()
			return self:_sinkMovement()
		end,
		false,
		MOVEMENT_SINK_PRIORITY,
		Enum.PlayerActions.CharacterForward,
		Enum.PlayerActions.CharacterBackward,
		Enum.PlayerActions.CharacterLeft,
		Enum.PlayerActions.CharacterRight,
		Enum.PlayerActions.CharacterJump
	)
end

function CoinFlipController:_restoreCharacter()
	ContextActionService:UnbindAction(MOVEMENT_SINK_ACTION)
	local humanoid = self.FrozenHumanoid
	if humanoid and humanoid.Parent then
		humanoid.WalkSpeed = self.FrozenWalkSpeed or humanoid.WalkSpeed
		humanoid.AutoRotate = self.FrozenAutoRotate ~= false
		if self.FrozenUseJumpPower then
			humanoid.JumpPower = self.FrozenJumpValue or humanoid.JumpPower
		else
			humanoid.JumpHeight = self.FrozenJumpValue or humanoid.JumpHeight
		end
	end
	self.FrozenHumanoid = nil
	self.FrozenWalkSpeed = nil
	self.FrozenAutoRotate = nil
	self.FrozenUseJumpPower = nil
	self.FrozenJumpValue = nil
end

function CoinFlipController:_hideCharacterPart(part)
	if not part:IsA("BasePart") or self.HiddenCharacterParts[part] ~= nil then
		return
	end
	self.HiddenCharacterParts[part] = part.LocalTransparencyModifier
	part.LocalTransparencyModifier = 1
end

function CoinFlipController:_hideLocalCharacter()
	self:_restoreLocalCharacterVisibility()
	local character = self.Player.Character
	if not character then
		return
	end
	for _, descendant in character:GetDescendants() do
		self:_hideCharacterPart(descendant)
	end
	self.CharacterVisibilityConnection = character.DescendantAdded:Connect(function(descendant)
		if self.InSession and self.Player.Character == character then
			self:_hideCharacterPart(descendant)
		end
	end)
end

function CoinFlipController:_restoreLocalCharacterVisibility()
	if self.CharacterVisibilityConnection then
		self.CharacterVisibilityConnection:Disconnect()
		self.CharacterVisibilityConnection = nil
	end
	for part, previousTransparency in self.HiddenCharacterParts do
		if part.Parent then
			part.LocalTransparencyModifier = previousTransparency
		end
	end
	table.clear(self.HiddenCharacterParts)
end

function CoinFlipController:_prepareCoinClone(model)
	local primaryPart = model:FindFirstChild(model.Name)
	if not primaryPart or not primaryPart:IsA("BasePart") then
		primaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not primaryPart then
		return nil
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		elseif descendant:IsA("Script") or descendant:IsA("LocalScript") then
			descendant:Destroy()
		end
	end
	model.PrimaryPart = primaryPart
	return primaryPart
end

function CoinFlipController:_destroyDisplayCoin()
	if self.DisplayCoin then
		self.DisplayCoin:Destroy()
		self.DisplayCoin = nil
		self.DisplayCoinPart = nil
		self.DisplayCoinId = nil
	end
end

function CoinFlipController:_getCoinCenterHeight(primaryPart)
	return math.max(0.05, primaryPart.Size.X * 0.5)
end

function CoinFlipController:_getTablePosition(primaryPart, localX, localZ)
	return (self.TablePart.CFrame * CFrame.new(
		localX or 0,
		self.TablePart.Size.Y * 0.5 + self:_getCoinCenterHeight(primaryPart),
		localZ or 0
	)).Position
end

function CoinFlipController:_getLandingCFrame(position, yaw, isHeads)
	local roll = if isHeads then math.pi * 0.5 else -math.pi * 0.5
	return CFrame.new(position) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, roll)
end

function CoinFlipController:_createDisplayCoin(coinId, isHeads)
	self:_destroyDisplayCoin()
	local template = self.CoinFlipFolder:FindFirstChild(coinId)
	if not template or not template:IsA("Model") then
		return false
	end
	local clone = template:Clone()
	clone.Name = "Local" .. coinId
	local primaryPart = self:_prepareCoinClone(clone)
	if not primaryPart then
		clone:Destroy()
		return false
	end
	clone.Parent = self.LocalModelFolder
	local position = self:_getTablePosition(
		primaryPart,
		self.CurrentCoinLocalX,
		self.CurrentCoinLocalZ
	)
	local displayIsHeads = if isHeads == nil then self.CurrentCoinIsHeads ~= false else isHeads
	clone:PivotTo(self:_getLandingCFrame(position, self.CurrentCoinYaw or 0, displayIsHeads))
	self.DisplayCoin = clone
	self.DisplayCoinPart = primaryPart
	self.DisplayCoinId = coinId
	return true
end

function CoinFlipController:_refreshDisplayCoin()
	local requiredCoinId = CoinFlipConfig.GetCoinId(self.Wager)
	if
		self.InSession
		and not self.AnimationRunning
		and (not self.DisplayCoin or self.DisplayCoinId ~= requiredCoinId)
	then
		self:_createDisplayCoin(requiredCoinId, self.CurrentCoinIsHeads)
	end
end

function CoinFlipController:_getCameraAnchorPosition()
	return self.CameraAnchor.Position
end

function CoinFlipController:_setCameraState(cameraCFrame, fieldOfView)
	self.CameraCFrame = cameraCFrame
	self.CameraFieldOfView = fieldOfView
end

function CoinFlipController:_acquireCamera()
	if self.CameraToken then
		return
	end
	local currentCamera = Workspace.CurrentCamera
	self.CameraCFrame = currentCamera and currentCamera.CFrame or CFrame.identity
	self.CameraFieldOfView = currentCamera and currentCamera.FieldOfView or 70
	self.CameraToken = self.CameraController:AcquireOverride(function(camera)
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = self.CameraCFrame
		camera.FieldOfView = self.CameraFieldOfView
	end)
end

function CoinFlipController:_releaseCamera()
	if self.CameraToken then
		self.CameraController:ReleaseOverride(self.CameraToken)
		self.CameraToken = nil
	end
end

function CoinFlipController:_getBetCameraCFrame(targetPosition)
	return CFrame.lookAt(self:_getCameraAnchorPosition(), targetPosition)
end

function CoinFlipController:_animateCameraTo(targetCFrame, targetFov, duration, token)
	local startCFrame = self.CameraCFrame
	local startFov = self.CameraFieldOfView
	local startedAt = os.clock()
	repeat
		if token ~= self.AnimationToken or not self.InSession then
			return false
		end
		local alpha = math.clamp((os.clock() - startedAt) / duration, 0, 1)
		local eased = smoothStep(alpha)
		self:_setCameraState(startCFrame:Lerp(targetCFrame, eased), startFov + (targetFov - startFov) * eased)
		RunService.RenderStepped:Wait()
	until os.clock() - startedAt >= duration
	self:_setCameraState(targetCFrame, targetFov)
	return true
end

function CoinFlipController:_enterBetCamera()
	self:_acquireCamera()
	local targetPosition = self.DisplayCoinPart
		and self.DisplayCoinPart.Position
		or self.TablePart.Position + self.TablePart.CFrame.UpVector * self.TablePart.Size.Y * 0.5
	self.InitialBetCameraCFrame = self:_getBetCameraCFrame(targetPosition)
	local token = self.AnimationToken
	task.spawn(function()
		self:_animateCameraTo(
			self.InitialBetCameraCFrame,
			CAMERA_ENTRY_FOV,
			CAMERA_ENTRY_DURATION,
			token
		)
	end)
end

function CoinFlipController:_stopHold()
	self.HoldSerial += 1
	self.HoldDirection = nil
end

function CoinFlipController:_cancelButtonPulses()
	for _, pulse in self.ButtonPulses do
		pulse.Serial += 1
		if pulse.Tween then
			pulse.Tween:Cancel()
			pulse.Tween = nil
		end
		if pulse.Scale.Parent then
			pulse.Scale.Scale = pulse.BaseScale
		end
	end
end

function CoinFlipController:_pulseButton(button)
	local pulse = self.ButtonPulses[button]
	if not pulse or not button.Interactable then
		return
	end
	pulse.Serial += 1
	local serial = pulse.Serial
	if pulse.Tween then
		pulse.Tween:Cancel()
	end
	local pressTween = TweenService:Create(
		pulse.Scale,
		TweenInfo.new(BUTTON_PRESS_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = pulse.BaseScale * BUTTON_PRESS_SCALE }
	)
	pulse.Tween = pressTween
	pressTween:Play()
	task.spawn(function()
		pressTween.Completed:Wait()
		if serial ~= pulse.Serial or not pulse.Scale.Parent then
			return
		end
		local releaseTween = TweenService:Create(
			pulse.Scale,
			TweenInfo.new(BUTTON_PRESS_OUT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = pulse.BaseScale }
		)
		pulse.Tween = releaseTween
		releaseTween:Play()
		releaseTween.Completed:Wait()
		if serial == pulse.Serial then
			pulse.Tween = nil
			pulse.Scale.Scale = pulse.BaseScale
		end
	end)
end

function CoinFlipController:_bindButtonPulse(button)
	local scale = button:FindFirstChild("CoinFlipPressScale")
	if scale and not scale:IsA("UIScale") then
		warn(button:GetFullName() .. ".CoinFlipPressScale must be a UIScale; press pulse is disabled.")
		return
	end
	if not scale then
		scale = Instance.new("UIScale")
		scale.Name = "CoinFlipPressScale"
		scale.Parent = button
	end
	self.ButtonPulses[button] = {
		Scale = scale,
		BaseScale = scale.Scale,
		Serial = 0,
		Tween = nil,
	}
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.Gamepad1
		then
			self:_pulseButton(button)
		end
	end)
end

function CoinFlipController:_maximumLegalWager()
	return math.floor(math.max(0, self.Coins) / CoinFlipConfig.WagerStep) * CoinFlipConfig.WagerStep
end

function CoinFlipController:_setWagerLabel(value)
	self.DisplayedWager = math.max(0, math.floor(tonumber(value) or 0))
	self.WagerLabel.Text = "Bet: $" .. CoinFormat.Compact(self.DisplayedWager)
end

function CoinFlipController:_cancelWagerAnimation(snapToWager)
	self.WagerAnimationSerial += 1
	if self.WagerWaveTween then
		self.WagerWaveTween:Cancel()
		self.WagerWaveTween = nil
	end
	if self.WagerScale and self.WagerScale.Parent then
		self.WagerScale.Scale = self.WagerBaseScale
	end
	if snapToWager then
		self:_setWagerLabel(self.Wager)
	end
end

function CoinFlipController:_animateWagerLabel(targetWager)
	self.WagerAnimationSerial += 1
	local serial = self.WagerAnimationSerial
	local startWager = tonumber(self.DisplayedWager) or targetWager
	if self.WagerWaveTween then
		self.WagerWaveTween:Cancel()
	end
	self.WagerScale.Scale = self.WagerBaseScale
	local growTween = TweenService:Create(
		self.WagerScale,
		TweenInfo.new(WAGER_WAVE_IN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Scale = self.WagerBaseScale * WAGER_WAVE_SCALE }
	)
	self.WagerWaveTween = growTween
	growTween:Play()
	task.spawn(function()
		growTween.Completed:Wait()
		if serial ~= self.WagerAnimationSerial or not self.WagerScale.Parent then
			return
		end
		local shrinkTween = TweenService:Create(
			self.WagerScale,
			TweenInfo.new(WAGER_WAVE_OUT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = self.WagerBaseScale }
		)
		self.WagerWaveTween = shrinkTween
		shrinkTween:Play()
		shrinkTween.Completed:Wait()
		if serial == self.WagerAnimationSerial then
			self.WagerWaveTween = nil
			self.WagerScale.Scale = self.WagerBaseScale
		end
	end)

	task.spawn(function()
		local startedAt = os.clock()
		repeat
			if serial ~= self.WagerAnimationSerial then
				return
			end
			local alpha = math.clamp((os.clock() - startedAt) / WAGER_COUNT_DURATION, 0, 1)
			local value = math.floor(startWager + (targetWager - startWager) * smoothStep(alpha) + 0.5)
			self:_setWagerLabel(value)
			RunService.RenderStepped:Wait()
		until os.clock() - startedAt >= WAGER_COUNT_DURATION
		if serial == self.WagerAnimationSerial then
			self:_setWagerLabel(targetWager)
		end
	end)
end

function CoinFlipController:_setWager(requestedWager, animateValue)
	local maximum = self:_maximumLegalWager()
	if maximum < CoinFlipConfig.MinimumWager then
		self.Wager = CoinFlipConfig.MinimumWager
	else
		self.Wager = math.clamp(
			math.floor((tonumber(requestedWager) or self.Wager) / CoinFlipConfig.WagerStep)
				* CoinFlipConfig.WagerStep,
			CoinFlipConfig.MinimumWager,
			maximum
		)
	end
	if animateValue and self.DisplayedWager ~= self.Wager then
		self:_animateWagerLabel(self.Wager)
	else
		self:_cancelWagerAnimation(true)
	end
	self:_refreshDisplayCoin()
	self:_refreshButtonStates()
end

function CoinFlipController:_adjustWager(direction, stepCount, animateValue)
	if not self.InSession or self.AnimationRunning or self.RequestRunning or self.Pending then
		return
	end
	local normalizedStepCount = math.max(1, math.floor(tonumber(stepCount) or 1))
	self:_setWager(
		self.Wager + direction * CoinFlipConfig.WagerStep * normalizedStepCount,
		animateValue ~= false
	)
end

function CoinFlipController:_startHold(direction)
	if self.HoldDirection == direction then
		return
	end
	self:_stopHold()
	self.HoldDirection = direction
	self.HoldSerial += 1
	local serial = self.HoldSerial
	self:_adjustWager(direction, 1, true)
	task.spawn(function()
		local lastStepTime = os.clock()
		local elapsed = 0
		while self.HoldDirection == direction and self.HoldSerial == serial do
			RunService.Heartbeat:Wait()
			if self.HoldDirection ~= direction or self.HoldSerial ~= serial then
				return
			end
			local now = os.clock()
			elapsed += math.max(0, now - lastStepTime)
			lastStepTime = now
			local stepsDue = math.floor(elapsed / HOLD_STEP_INTERVAL)
			if stepsDue > 0 then
				elapsed -= stepsDue * HOLD_STEP_INTERVAL
				-- Collapse all elapsed 0.01-second steps into one update per frame.
				self:_adjustWager(direction, stepsDue, false)
			end
		end
	end)
end

function CoinFlipController:_bindHoldButton(button, direction)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self:_startHold(direction)
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self:_stopHold()
		end
	end)
	button.Activated:Connect(function(inputObject)
		if inputObject
			and inputObject.UserInputType ~= Enum.UserInputType.MouseButton1
			and inputObject.UserInputType ~= Enum.UserInputType.Touch
		then
			self:_adjustWager(direction)
		end
	end)
end

function CoinFlipController:_refreshButtonStates()
	if not self.YesButton then
		return
	end
	local canEdit = self.InSession
		and not self.AnimationRunning
		and not self.RequestRunning
		and not self.Pending
	local maximum = self:_maximumLegalWager()
	setGuiButtonEnabled(self.MinusButton, canEdit and self.Wager > CoinFlipConfig.MinimumWager)
	setGuiButtonEnabled(self.PlusButton, canEdit and self.Wager < maximum)
	setGuiButtonEnabled(
		self.YesButton,
		canEdit and maximum >= CoinFlipConfig.MinimumWager and self.Wager <= maximum
	)
	setGuiButtonEnabled(self.NoButton, self.InSession)
end

function CoinFlipController:_playOneShot(template, name)
	local sound = template:Clone()
	sound.Name = name
	sound.Looped = false
	sound.PlayOnRemove = false
	sound.TimePosition = 0
	sound.Parent = SoundService
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	SoundService:PlayLocalSound(sound)
	task.delay(5, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

function CoinFlipController:_chooseLanding(primaryPart, seed)
	local random = Random.new(seed)
	local radius = math.max(primaryPart.Size.Y, primaryPart.Size.Z) * 0.5
	local usableX = math.max(0, self.TablePart.Size.X * 0.5 - radius)
	local usableZ = math.max(0, self.TablePart.Size.Z * 0.5 - radius)
	local localX = random:NextNumber(-usableX, usableX)
	local localZ = random:NextNumber(-usableZ, usableZ)
	return localX, localZ, random:NextNumber(0, math.pi * 2)
end

function CoinFlipController:_isRequestCurrent(token, requestSerial)
	return self.InSession
		and token == self.AnimationToken
		and requestSerial == self.RequestSerial
end

function CoinFlipController:_runPrelaunch(token, requestSerial, isResponseReady)
	local coin = self.DisplayCoin
	local primaryPart = self.DisplayCoinPart
	if not coin or not coin.Parent or not primaryPart then
		return nil
	end
	local originalLocalX = self.CurrentCoinLocalX or 0
	local originalLocalZ = self.CurrentCoinLocalZ or 0
	local originalYaw = self.CurrentCoinYaw or 0
	local originalIsHeads = self.CurrentCoinIsHeads ~= false
	local originalRoll = if originalIsHeads then math.pi * 0.5 else -math.pi * 0.5
	local originalPosition = self:_getTablePosition(primaryPart, originalLocalX, originalLocalZ)
	local state = {
		Coin = coin,
		Position = originalPosition,
		Yaw = originalYaw,
		Roll = originalRoll,
		OriginalPosition = originalPosition,
		OriginalYaw = originalYaw,
		OriginalRoll = originalRoll,
		OriginalIsHeads = originalIsHeads,
		VerticalVelocity = FLIGHT_PEAK_HEIGHT * 2 / PRELAUNCH_APEX_DURATION,
	}
	self.PrelaunchState = state
	local startedAt = os.clock()
	local lastCompletedRotation = 0

	while
		self:_isRequestCurrent(token, requestSerial)
		and coin.Parent
		and not isResponseReady()
	do
		local elapsed = os.clock() - startedAt
		local riseAlpha = math.clamp(elapsed / PRELAUNCH_APEX_DURATION, 0, 1)
		local riseProgress = riseAlpha * (2 - riseAlpha)
		local position = originalPosition
			+ Vector3.new(0, FLIGHT_PEAK_HEIGHT * riseProgress, 0)
		local completedRotation = math.floor(elapsed * PRELAUNCH_ROTATIONS_PER_SECOND + 1e-6)
		for _ = lastCompletedRotation + 1, completedRotation do
			self:_playOneShot(self.FlipSoundTemplate, "CoinFlipPrelaunchTurnSound")
		end
		lastCompletedRotation = completedRotation
		local roll = originalRoll
			+ elapsed * PRELAUNCH_ROTATIONS_PER_SECOND * math.pi * 2
		coin:PivotTo(
			CFrame.new(position)
				* CFrame.Angles(0, originalYaw, 0)
				* CFrame.Angles(0, 0, roll)
		)

		local cameraAlpha = smoothStep(riseAlpha)
		local cameraPosition = self:_getCameraAnchorPosition():Lerp(
			position,
			PRELAUNCH_CAMERA_POSITION_PUSH * cameraAlpha
		)
		self:_setCameraState(
			CFrame.lookAt(cameraPosition, position),
			CAMERA_ENTRY_FOV + (PRELAUNCH_CAMERA_FOV - CAMERA_ENTRY_FOV) * cameraAlpha
		)
		state.Position = position
		state.Roll = roll
		state.VerticalVelocity = FLIGHT_PEAK_HEIGHT
			* 2
			/ PRELAUNCH_APEX_DURATION
			* (1 - riseAlpha)
		RunService.RenderStepped:Wait()
	end
	return state
end

function CoinFlipController:_returnPrelaunchAfterFailure(state, token, requestSerial)
	local coin = state and state.Coin
	if not coin or not coin.Parent then
		return false
	end
	local startPosition = state.Position
	local startYaw = state.Yaw
	local startRoll = state.Roll
	local startCameraPosition = self.CameraCFrame.Position
	local startFov = self.CameraFieldOfView
	local startedAt = os.clock()

	repeat
		if not self:_isRequestCurrent(token, requestSerial) or not coin.Parent then
			return false
		end
		local alpha = math.clamp(
			(os.clock() - startedAt) / PRELAUNCH_FAILURE_RETURN_DURATION,
			0,
			1
		)
		local eased = smoothStep(alpha)
		local position = startPosition:Lerp(state.OriginalPosition, eased)
		local yaw = lerpAngle(startYaw, state.OriginalYaw, eased)
		local roll = lerpAngle(startRoll, state.OriginalRoll, eased)
		coin:PivotTo(
			CFrame.new(position) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, roll)
		)
		local cameraPosition = startCameraPosition:Lerp(self:_getCameraAnchorPosition(), eased)
		self:_setCameraState(
			CFrame.lookAt(cameraPosition, position),
			startFov + (CAMERA_ENTRY_FOV - startFov) * eased
		)
		RunService.RenderStepped:Wait()
	until os.clock() - startedAt >= PRELAUNCH_FAILURE_RETURN_DURATION

	coin:PivotTo(self:_getLandingCFrame(
		state.OriginalPosition,
		state.OriginalYaw,
		state.OriginalIsHeads
	))
	self:_setCameraState(
		self:_getBetCameraCFrame(state.OriginalPosition),
		CAMERA_ENTRY_FOV
	)
	return true
end

function CoinFlipController:_playFlipAnimation(result, prelaunchState, existingToken)
	self.AnimationRunning = true
	self:_refreshButtonStates()
	if
		not self.DisplayCoin
		or not self.DisplayCoin.Parent
		or self.DisplayCoinId ~= result.CoinId
	then
		if not self:_createDisplayCoin(result.CoinId, self.CurrentCoinIsHeads) then
			self.AnimationRunning = false
			self:_refreshButtonStates()
			self:_notify("Coin model is unavailable.")
			return
		end
		if prelaunchState then
			self.DisplayCoin:PivotTo(
				CFrame.new(prelaunchState.Position)
					* CFrame.Angles(0, prelaunchState.Yaw, 0)
					* CFrame.Angles(0, 0, prelaunchState.Roll)
			)
		end
	end
	if not self.DisplayCoinPart then
		self.AnimationRunning = false
		self:_refreshButtonStates()
		self:_notify("Coin model is unavailable.")
		return
	end

	local token = existingToken
	if not token then
		self.AnimationToken += 1
		token = self.AnimationToken
	end
	local coin = self.DisplayCoin
	local primaryPart = self.DisplayCoinPart
	local startLocalX = self.CurrentCoinLocalX or 0
	local startLocalZ = self.CurrentCoinLocalZ or 0
	local startYaw = self.CurrentCoinYaw or 0
	local startIsHeads = self.CurrentCoinIsHeads ~= false
	local startPosition = if prelaunchState
		then prelaunchState.Position
		else self:_getTablePosition(primaryPart, startLocalX, startLocalZ)
	local startRoll = if prelaunchState
		then prelaunchState.Roll
		else if startIsHeads then math.pi * 0.5 else -math.pi * 0.5
	if prelaunchState then
		startYaw = prelaunchState.Yaw
	end
	local landingLocalX, landingLocalZ, landingYaw = self:_chooseLanding(
		primaryPart,
		result.LandingSeed
	)
	local landingPosition = self:_getTablePosition(primaryPart, landingLocalX, landingLocalZ)
	local cameraStartPosition = self.CameraCFrame.Position
	local cameraStartFov = self.CameraFieldOfView
	local duration = math.max(0.1, tonumber(result.AnimationDuration) or CoinFlipConfig.AnimationDuration)
	local startVerticalVelocity = if prelaunchState
		then math.max(0, tonumber(prelaunchState.VerticalVelocity) or 0)
		else FLIGHT_PEAK_HEIGHT * 4 / duration
	local verticalAcceleration = 2
		* (landingPosition.Y - startPosition.Y - startVerticalVelocity * duration)
		/ (duration * duration)
	local startedAt = os.clock()
	local lastCompletedRotation = 0

	while self.InSession and token == self.AnimationToken and coin.Parent do
		local elapsed = math.min(duration, os.clock() - startedAt)
		local alpha = math.clamp(elapsed / duration, 0, 1)
		local horizontalPosition = startPosition:Lerp(landingPosition, alpha)
		local position = Vector3.new(
			horizontalPosition.X,
			startPosition.Y
				+ startVerticalVelocity * elapsed
				+ 0.5 * verticalAcceleration * elapsed * elapsed,
			horizontalPosition.Z
		)
		local turnProgress = 1 - (1 - alpha) * (1 - alpha)
		local completedRotation = math.floor(FLIGHT_FULL_ROTATIONS * turnProgress + 1e-6)
		for _ = lastCompletedRotation + 1, completedRotation do
			self:_playOneShot(self.FlipSoundTemplate, "CoinFlipTurnSound")
		end
		lastCompletedRotation = completedRotation
		local targetRoll = if result.IsHeads then math.pi * 0.5 else -math.pi * 0.5
		local resultHalfTurn = (targetRoll - startRoll + math.pi) % (math.pi * 2) - math.pi
		local roll = startRoll
			+ FLIGHT_FULL_ROTATIONS * math.pi * 2 * turnProgress
			+ resultHalfTurn * smoothStep(math.max(0, (alpha - 0.65) / 0.35))
		local yaw = lerpAngle(startYaw, landingYaw, smoothStep(alpha))
		coin:PivotTo(CFrame.new(position) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, roll))

		local pushAlpha = smoothStep(alpha)
		local desiredCameraPosition = self:_getCameraAnchorPosition():Lerp(
			position,
			CAMERA_FLIGHT_POSITION_PUSH
		)
		local cameraPosition = cameraStartPosition:Lerp(desiredCameraPosition, pushAlpha)
		self:_setCameraState(
			CFrame.lookAt(cameraPosition, position),
			cameraStartFov + (CAMERA_FLIGHT_FOV - cameraStartFov) * pushAlpha
		)
		if alpha >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end

	if not self.InSession or token ~= self.AnimationToken or not coin.Parent then
		return
	end
	coin:PivotTo(self:_getLandingCFrame(landingPosition, landingYaw, result.IsHeads))
	self.CurrentCoinLocalX = landingLocalX
	self.CurrentCoinLocalZ = landingLocalZ
	self.CurrentCoinYaw = landingYaw
	self.CurrentCoinIsHeads = result.IsHeads == true
	self:_playOneShot(self.LandingSoundTemplate, "CoinFlipLandingSound")
	if not result.IsHeads then
		self.HUDController:ShowCoinFlipLoss(result.Wager)
	end
	self:_animateCameraTo(
		self:_getBetCameraCFrame(landingPosition),
		CAMERA_ENTRY_FOV,
		CAMERA_RETURN_DURATION,
		token
	)
	if self.InSession and token == self.AnimationToken then
		self.AnimationRunning = false
		self:_refreshButtonStates()
	end
end

function CoinFlipController:_requestFlip()
	if self.RequestRunning or self.AnimationRunning or self.Pending then
		return
	end
	local maximum = self:_maximumLegalWager()
	if maximum < CoinFlipConfig.MinimumWager or self.Wager > maximum then
		self:_notify("Not enough Coins.")
		return
	end
	local requestedWager = self.Wager
	local requestedCoinId = CoinFlipConfig.GetCoinId(requestedWager)
	if
		not self.DisplayCoin
		or not self.DisplayCoin.Parent
		or self.DisplayCoinId ~= requestedCoinId
	then
		if not self:_createDisplayCoin(requestedCoinId, self.CurrentCoinIsHeads) then
			self:_notify("Coin model is unavailable.")
			return
		end
	end

	self.RequestRunning = true
	self.AnimationRunning = true
	self.RequestSerial += 1
	local requestSerial = self.RequestSerial
	self.AnimationToken += 1
	local token = self.AnimationToken
	self:_stopHold()
	self:_refreshButtonStates()
	local responseReady = false
	local callSucceeded = false
	local result = nil
	task.spawn(function()
		callSucceeded, result = pcall(function()
			return self.Remotes.RequestCoinFlip:InvokeServer(requestedWager)
		end)
		responseReady = true
	end)

	local waitStartedAt = os.clock()
	while
		self:_isRequestCurrent(token, requestSerial)
		and not responseReady
		and os.clock() - waitStartedAt < PRELAUNCH_DELAY
	do
		RunService.RenderStepped:Wait()
	end
	if not self:_isRequestCurrent(token, requestSerial) then
		return
	end

	local prelaunchState = nil
	if not responseReady then
		prelaunchState = self:_runPrelaunch(token, requestSerial, function()
			return responseReady
		end)
	end
	if not self:_isRequestCurrent(token, requestSerial) then
		return
	end
	self.RequestRunning = false
	if not callSucceeded or type(result) ~= "table" then
		if prelaunchState then
			self:_returnPrelaunchAfterFailure(prelaunchState, token, requestSerial)
		end
		if not self:_isRequestCurrent(token, requestSerial) then
			return
		end
		self.PrelaunchState = nil
		self.AnimationRunning = false
		self:_refreshButtonStates()
		self:_notify("Coin flip request failed. Try again.")
		return
	end
	if result.Success ~= true then
		if prelaunchState then
			self:_returnPrelaunchAfterFailure(prelaunchState, token, requestSerial)
		end
		if not self:_isRequestCurrent(token, requestSerial) then
			return
		end
		self.PrelaunchState = nil
		self.AnimationRunning = false
		self.Pending = self.Pending
			or result.Message == "A coin flip is already in progress."
		self:_refreshButtonStates()
		self:_notify(result.Message or "Coin flip request failed.")
		return
	end
	self.Pending = true
	self.PrelaunchState = nil
	self:_refreshButtonStates()
	if self.InSession then
		self:_playFlipAnimation(result, prelaunchState, token)
	end
end

function CoinFlipController:_enterSession()
	if self.InSession then
		return
	end
	self.InSession = true
	self.CurrentCoinLocalX = 0
	self.CurrentCoinLocalZ = 0
	self.CurrentCoinYaw = 0
	self.CurrentCoinIsHeads = true
	self.ManualExitSuppressed = false
	self.AnimationToken += 1
	self.RequestSerial += 1
	self.Frame.Visible = true
	self.ToolController:SetHotbarSuppressed(true)
	self.AutomaticController:SetPaused(true)
	self.HarvestRangeController:SetSuppressed(true)
	self:_freezeCharacter()
	self:_hideLocalCharacter()
	self:_setWager(self.Wager)
	self:_enterBetCamera()
	self:_refreshButtonStates()
end

function CoinFlipController:_exitSession(manualExit)
	if not self.InSession then
		return
	end
	self.InSession = false
	if manualExit then
		self.ManualExitSuppressed = true
	end
	self.AnimationToken += 1
	self.RequestSerial += 1
	self.AnimationRunning = false
	self.RequestRunning = false
	self.PrelaunchState = nil
	self:_stopHold()
	self:_cancelButtonPulses()
	self:_cancelWagerAnimation(true)
	self.Frame.Visible = false
	self.ToolController:SetHotbarSuppressed(false)
	self.AutomaticController:SetPaused(false)
	self.HarvestRangeController:SetSuppressed(false)
	self:_restoreCharacter()
	self:_restoreLocalCharacterVisibility()
	self:_destroyDisplayCoin()
	self:_releaseCamera()
	self:_refreshButtonStates()
end

function CoinFlipController:_applySnapshot(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	self.Coins = math.max(0, tonumber(snapshot.Coins) or 0)
	self.Pending = snapshot.CoinFlipPending == true
	if not self.AnimationRunning then
		self:_setWager(self.Wager)
	else
		self:_refreshButtonStates()
	end
end

function CoinFlipController:_startZoneMonitor()
	task.spawn(function()
		while true do
			task.wait(ZONE_POLL_INTERVAL)
			local inside = self:_isPlayerInZone()
			if not inside then
				if self.InSession then
					self:_exitSession(false)
				end
				self.ManualExitSuppressed = false
			elseif not self.InSession and not self.ManualExitSuppressed then
				self:_enterSession()
			end
		end
	end)
end

function CoinFlipController:Init(
	remotes,
	cameraController,
	toolController,
	automaticController,
	hudController,
	harvestRangeController
)
	self.Remotes = remotes
	self.CameraController = cameraController
	self.ToolController = toolController
	self.AutomaticController = automaticController
	self.HUDController = hudController
	self.HarvestRangeController = harvestRangeController
	self.Player = Players.LocalPlayer
	self.Coins = 0
	self.Wager = CoinFlipConfig.MinimumWager
	self.Pending = false
	self.InSession = false
	self.AnimationRunning = false
	self.RequestRunning = false
	self.ManualExitSuppressed = false
	self.AnimationToken = 0
	self.RequestSerial = 0
	self.PrelaunchState = nil
	self.HoldSerial = 0
	self.HiddenCharacterParts = {}
	self.ButtonPulses = {}
	self.WagerAnimationSerial = 0
	self.WagerWaveTween = nil
	self.DisplayedWager = CoinFlipConfig.MinimumWager

	local coinFlipFolder = Workspace:WaitForChild("CoinFlip", WORLD_OBJECT_WAIT_TIMEOUT)
	local clickPart = coinFlipFolder
		and coinFlipFolder:WaitForChild("Click", WORLD_OBJECT_WAIT_TIMEOUT)
	local tableModel = coinFlipFolder
		and coinFlipFolder:WaitForChild("Table", WORLD_OBJECT_WAIT_TIMEOUT)
	local tablePart = tableModel
		and tableModel:WaitForChild("Table", WORLD_OBJECT_WAIT_TIMEOUT)
	local cameraAnchor = tableModel
		and tableModel:WaitForChild("jingtou", WORLD_OBJECT_WAIT_TIMEOUT)
	if
		not coinFlipFolder
		or not clickPart
		or not clickPart:IsA("BasePart")
		or not tablePart
		or not tablePart:IsA("BasePart")
		or not cameraAnchor
		or not cameraAnchor:IsA("BasePart")
	then
		warn("Coin flip world objects are incomplete; the local feature is disabled.")
		return
	end
	self.CoinFlipFolder = coinFlipFolder
	self.ClickPart = clickPart
	self.TablePart = tablePart
	self.CameraAnchor = cameraAnchor

	local gameHud = self.Player:WaitForChild("PlayerGui"):WaitForChild("GameHUD")
	local frame = gameHud:WaitForChild("coinFlip")
	local wagerLabel = frame:WaitForChild("Frame"):WaitForChild("TextLabel")
	local minusButton = frame:WaitForChild("jian")
	local plusButton = frame:WaitForChild("jia")
	local noButton = frame:WaitForChild("NO")
	local yesButton = frame:WaitForChild("yes")
	assert(frame:IsA("Frame"), "GameHUD.coinFlip must be a Frame")
	assert(wagerLabel:IsA("TextLabel"), "coinFlip.Frame.TextLabel must be a TextLabel")
	for _, button in { minusButton, plusButton, noButton, yesButton } do
		assert(button:IsA("GuiButton"), button:GetFullName() .. " must be a GuiButton")
	end
	self.Frame = frame
	self.WagerLabel = wagerLabel
	local wagerScale = wagerLabel:FindFirstChild("CoinFlipWagerWaveScale")
	if wagerScale and not wagerScale:IsA("UIScale") then
		warn("coinFlip.Frame.TextLabel.CoinFlipWagerWaveScale must be a UIScale; replacing it.")
		wagerScale:Destroy()
		wagerScale = nil
	end
	if not wagerScale then
		wagerScale = Instance.new("UIScale")
		wagerScale.Name = "CoinFlipWagerWaveScale"
		wagerScale.Parent = wagerLabel
	end
	self.WagerScale = wagerScale
	self.WagerBaseScale = wagerScale.Scale
	self.MinusButton = minusButton
	self.PlusButton = plusButton
	self.NoButton = noButton
	self.YesButton = yesButton
	self.Frame.Visible = false
	for _, button in { self.MinusButton, self.PlusButton, self.NoButton, self.YesButton } do
		self:_bindButtonPulse(button)
	end

	self.FlipSoundTemplate = SoundService:WaitForChild("Coinfanzhuan")
	self.LandingSoundTemplate = SoundService:WaitForChild("luodi")
	assert(self.FlipSoundTemplate:IsA("Sound"), "SoundService.Coinfanzhuan must be a Sound")
	assert(self.LandingSoundTemplate:IsA("Sound"), "SoundService.luodi must be a Sound")

	local oldFolder = Workspace:FindFirstChild(LOCAL_MODEL_FOLDER_NAME)
	if oldFolder then
		oldFolder:Destroy()
	end
	self.LocalModelFolder = Instance.new("Folder")
	self.LocalModelFolder.Name = LOCAL_MODEL_FOLDER_NAME
	self.LocalModelFolder.Parent = Workspace

	self:_bindHoldButton(self.MinusButton, -1)
	self:_bindHoldButton(self.PlusButton, 1)
	self.NoButton.Activated:Connect(function()
		self:_exitSession(true)
	end)
	self.YesButton.Activated:Connect(function()
		self:_requestFlip()
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self:_stopHold()
		end
	end)
	self.Player.CharacterAdded:Connect(function()
		self:_exitSession(false)
	end)
	remotes.StateSnapshotStore:Connect(function(snapshot)
		self:_applySnapshot(snapshot)
	end)
	hudController:ConnectSessionResetSucceeded(function()
		self:_exitSession(false)
		self.Pending = false
		self.Wager = CoinFlipConfig.MinimumWager
	end)
	self:_setWager(self.Wager)
	self:_startZoneMonitor()
end

return CoinFlipController

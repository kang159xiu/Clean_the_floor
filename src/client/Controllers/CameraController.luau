local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local CameraController = {}
local CAMERA_RENDER_BINDING = "CleanFloorMouseMode"
local THIRD_PERSON_FIELD_OF_VIEW = 70
local THIRD_PERSON_MIN_ZOOM = 5 ---第三人称最小缩放距离
local THIRD_PERSON_MAX_ZOOM = 30
local THIRD_PERSON_SWITCH_DISTANCE = 10
local THIRD_PERSON_FOCUS_HEIGHT = 2
local THIRD_PERSON_START_HEIGHT = 4

local function isTouchPrimary()
	return UserInputService.TouchEnabled
		and not UserInputService.KeyboardEnabled
		and not UserInputService.MouseEnabled
end

function CameraController:Init()
	self.Player = Players.LocalPlayer
	self.TouchPrimary = isTouchPrimary()
	self.OverrideToken = nil
	self.OverrideCallback = nil
	self.CharacterBindGeneration = 0
	self.CharacterReadyConnections = {}

	RunService:UnbindFromRenderStep(CAMERA_RENDER_BINDING)
	RunService:BindToRenderStep(CAMERA_RENDER_BINDING, Enum.RenderPriority.Camera.Value + 1, function()
		self:_applyCameraState()
	end)

	self.Player.CharacterAdded:Connect(function(character)
		self:_bindCharacterWhenReady(character)
	end)
	if self.Player.Character then
		self:_bindCharacterWhenReady(self.Player.Character)
	end

	self:_forceThirdPersonDistance()
	self:_bindCameraToCharacter(true)
end

function CameraController:IsTouchPrimary()
	self.TouchPrimary = isTouchPrimary()
	return self.TouchPrimary
end

function CameraController:_bindCharacterWhenReady(character)
	self.CharacterBindGeneration += 1
	local generation = self.CharacterBindGeneration
	for _, connection in self.CharacterReadyConnections do
		connection:Disconnect()
	end
	table.clear(self.CharacterReadyConnections)

	local function disconnectReadyConnections()
		if generation ~= self.CharacterBindGeneration then
			return
		end
		for _, connection in self.CharacterReadyConnections do
			connection:Disconnect()
		end
		table.clear(self.CharacterReadyConnections)
	end

	local function tryBind()
		if generation ~= self.CharacterBindGeneration or self.Player.Character ~= character then
			disconnectReadyConnections()
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not rootPart or not rootPart:IsA("BasePart") then
			return
		end
		disconnectReadyConnections()
		self:_forceThirdPersonDistance()
		self:_bindCameraToCharacter(true)
	end

	table.insert(self.CharacterReadyConnections, character.ChildAdded:Connect(function()
		tryBind()
	end))
	table.insert(self.CharacterReadyConnections, character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			disconnectReadyConnections()
		end
	end))
	tryBind()
end

function CameraController:_applyCameraState()
	local camera = Workspace.CurrentCamera
	if self.OverrideToken ~= nil then
		if camera and self.OverrideCallback then
			local succeeded, message = pcall(self.OverrideCallback, camera)
			if not succeeded then
				warn("Temporary camera override failed: " .. tostring(message))
				self:ReleaseOverride(self.OverrideToken)
			end
		end
		return camera, nil
	end
	local character = self.Player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not camera or not humanoid then
		return nil, nil
	end

	if self.Player.CameraMode ~= Enum.CameraMode.Classic then
		self.Player.CameraMode = Enum.CameraMode.Classic
	end
	if camera.CameraType ~= Enum.CameraType.Custom then
		camera.CameraType = Enum.CameraType.Custom
	end
	if camera.CameraSubject ~= humanoid then
		camera.CameraSubject = humanoid
	end
	if humanoid.CameraOffset ~= Vector3.zero then
		humanoid.CameraOffset = Vector3.zero
	end
	if camera.FieldOfView ~= THIRD_PERSON_FIELD_OF_VIEW then
		camera.FieldOfView = THIRD_PERSON_FIELD_OF_VIEW
	end
	return camera, rootPart
end

function CameraController:AcquireOverride(callback)
	assert(type(callback) == "function", "Camera override callback must be a function")
	local token = {}
	self.OverrideToken = token
	self.OverrideCallback = callback
	return token
end

function CameraController:IsOverrideActive(token)
	return token ~= nil and self.OverrideToken == token
end

function CameraController:ReleaseOverride(token)
	if token == nil or self.OverrideToken ~= token then
		return false
	end
	self.OverrideToken = nil
	self.OverrideCallback = nil
	self:_forceThirdPersonDistance()
	self:_bindCameraToCharacter(true)
	return true
end

function CameraController:_bindCameraToCharacter(reposition)
	local camera, rootPart = self:_applyCameraState()
	if not camera then
		return
	end
	if reposition and rootPart then
		local focus = rootPart.Position + Vector3.new(0, THIRD_PERSON_FOCUS_HEIGHT, 0)
		local cameraPosition = focus
			- rootPart.CFrame.LookVector * THIRD_PERSON_SWITCH_DISTANCE
			+ Vector3.new(0, THIRD_PERSON_START_HEIGHT, 0)
		camera.CFrame = CFrame.lookAt(cameraPosition, focus)
	end
end

function CameraController:_forceThirdPersonDistance()
	self.Player.CameraMinZoomDistance = THIRD_PERSON_SWITCH_DISTANCE
	self.Player.CameraMaxZoomDistance = THIRD_PERSON_SWITCH_DISTANCE

	task.spawn(function()
		RunService.RenderStepped:Wait()
		self.Player.CameraMinZoomDistance = THIRD_PERSON_MIN_ZOOM
		self.Player.CameraMaxZoomDistance = THIRD_PERSON_MAX_ZOOM
	end)
end

return CameraController

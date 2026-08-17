local Lighting = game:GetService("Lighting")

local ModalPanelCoordinator = {}

local BLUR_EFFECT_NAME = "LocalModalPanelBlur"
local BLUR_SIZE = 18

local closeCallbacks = {}
local activePanelId = nil
local blurEffect = nil

local function getBlurEffect()
	if blurEffect and blurEffect.Parent then
		return blurEffect
	end

	local existing = Lighting:FindFirstChild(BLUR_EFFECT_NAME)
	if existing and existing:IsA("BlurEffect") then
		blurEffect = existing
	else
		blurEffect = Instance.new("BlurEffect")
		blurEffect.Name = BLUR_EFFECT_NAME
		blurEffect.Parent = Lighting
	end
	blurEffect.Size = BLUR_SIZE
	return blurEffect
end

local function refreshBlur()
	local effect = getBlurEffect()
	effect.Enabled = activePanelId ~= nil
end

function ModalPanelCoordinator.Register(panelId, closeCallback)
	assert(type(panelId) == "string" and panelId ~= "", "Modal panel id must be a non-empty string")
	assert(type(closeCallback) == "function", "Modal panel close callback must be a function")
	closeCallbacks[panelId] = closeCallback
end

function ModalPanelCoordinator.Open(panelId)
	if activePanelId == panelId then
		refreshBlur()
		return
	end

	local previousPanelId = activePanelId
	activePanelId = panelId
	local closePrevious = previousPanelId and closeCallbacks[previousPanelId]
	if closePrevious then
		closePrevious()
	end
	refreshBlur()
end

function ModalPanelCoordinator.Close(panelId)
	if activePanelId ~= panelId then
		return
	end
	activePanelId = nil
	refreshBlur()
end

function ModalPanelCoordinator.GetActivePanelId()
	return activePanelId
end

return ModalPanelCoordinator

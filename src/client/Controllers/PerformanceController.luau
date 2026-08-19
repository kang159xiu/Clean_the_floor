local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LeafVisibilityConfig = require(ReplicatedStorage.Shared.Config.LeafVisibilityConfig)

local PerformanceController = {}

local performanceConfig = LeafVisibilityConfig.Performance or {}
local leafModelLimits = performanceConfig.LeafModelLimits or {}

local TIER_RANKS = {
	Low = 1,
	Medium = 2,
	High = 3,
}

local INITIAL_TIER = if TIER_RANKS[performanceConfig.InitialTier]
	then performanceConfig.InitialTier
	else "Low"
local WARMUP_SECONDS = math.max(0, tonumber(performanceConfig.WarmupSeconds) or 3)
local FOCUS_RESUME_WARMUP_SECONDS = math.max(
	0,
	tonumber(performanceConfig.FocusResumeWarmupSeconds) or 2
)
local SAMPLE_WINDOW_SECONDS = math.max(1, tonumber(performanceConfig.SampleWindowSeconds) or 5)
local UPGRADE_WINDOW_COUNT = math.max(
	1,
	math.floor(tonumber(performanceConfig.UpgradeWindowCount) or 2)
)
local HIGH_AVERAGE_FPS = math.max(1, tonumber(performanceConfig.HighAverageFps) or 52)
local HIGH_P95_FRAME_SECONDS = math.max(
	1 / 240,
	tonumber(performanceConfig.HighP95FrameSeconds) or 1 / 40
)
local MEDIUM_AVERAGE_FPS = math.max(1, tonumber(performanceConfig.MediumAverageFps) or 32)
local MEDIUM_P95_FRAME_SECONDS = math.max(
	HIGH_P95_FRAME_SECONDS,
	tonumber(performanceConfig.MediumP95FrameSeconds) or 1 / 20
)

local function normalizeTier(value)
	return type(value) == "string" and TIER_RANKS[value] and value or nil
end

local function classifyWindow(samples, elapsed)
	if #samples == 0 or elapsed <= 0 then
		return nil, 0, 0
	end
	local sortedSamples = table.clone(samples)
	table.sort(sortedSamples)
	local p95Index = math.clamp(math.ceil(#sortedSamples * 0.95), 1, #sortedSamples)
	local averageFps = #samples / elapsed
	local p95FrameSeconds = sortedSamples[p95Index]
	if averageFps >= HIGH_AVERAGE_FPS and p95FrameSeconds <= HIGH_P95_FRAME_SECONDS then
		return "High", averageFps, p95FrameSeconds
	end
	if averageFps >= MEDIUM_AVERAGE_FPS and p95FrameSeconds <= MEDIUM_P95_FRAME_SECONDS then
		return "Medium", averageFps, p95FrameSeconds
	end
	return "Low", averageFps, p95FrameSeconds
end

function PerformanceController:Init()
	self.Tier = INITIAL_TIER
	self.TierChanged = Instance.new("BindableEvent")
	self.FrameSamples = {}
	self.SampleElapsed = 0
	self.WarmupUntil = os.clock() + WARMUP_SECONDS
	self.HasInitialClassification = false
	self.UpgradeCandidate = nil
	self.UpgradeCandidateWindows = 0
	self.WindowFocused = true
	self.StudioOverrideTier = nil

	local function refreshStudioOverride()
		if not RunService:IsStudio() then
			return
		end
		local nextOverride = normalizeTier(Workspace:GetAttribute("ClientPerformanceTierOverride"))
		if nextOverride == self.StudioOverrideTier then
			return
		end
		self.StudioOverrideTier = nextOverride
		self:_resetSampling(if nextOverride then 0 else WARMUP_SECONDS)
		self.HasInitialClassification = nextOverride ~= nil
		if nextOverride then
			self:_setTier(nextOverride, 0, 0)
		else
			self:_setTier(INITIAL_TIER, 0, 0)
		end
	end

	if RunService:IsStudio() then
		Workspace:GetAttributeChangedSignal("ClientPerformanceTierOverride"):Connect(refreshStudioOverride)
		refreshStudioOverride()
	end

	UserInputService.WindowFocusReleased:Connect(function()
		self.WindowFocused = false
		self:_resetSampling(0)
	end)
	UserInputService.WindowFocused:Connect(function()
		self.WindowFocused = true
		self:_resetSampling(FOCUS_RESUME_WARMUP_SECONDS)
	end)

	RunService.RenderStepped:Connect(function(deltaTime)
		self:_recordFrame(deltaTime)
	end)
end

function PerformanceController:_resetSampling(warmupSeconds)
	table.clear(self.FrameSamples)
	self.SampleElapsed = 0
	self.UpgradeCandidate = nil
	self.UpgradeCandidateWindows = 0
	self.WarmupUntil = os.clock() + math.max(0, tonumber(warmupSeconds) or 0)
end

function PerformanceController:_setTier(tier, averageFps, p95FrameSeconds)
	if not TIER_RANKS[tier] or tier == self.Tier then
		return
	end
	self.Tier = tier
	self.TierChanged:Fire(tier, self:GetLeafModelLimit(), averageFps, p95FrameSeconds)
end

function PerformanceController:_applyClassification(candidate, averageFps, p95FrameSeconds)
	if not candidate then
		return
	end
	if not self.HasInitialClassification then
		self.HasInitialClassification = true
		self.UpgradeCandidate = nil
		self.UpgradeCandidateWindows = 0
		self:_setTier(candidate, averageFps, p95FrameSeconds)
		return
	end

	local currentRank = TIER_RANKS[self.Tier]
	local candidateRank = TIER_RANKS[candidate]
	if candidateRank < currentRank then
		self.UpgradeCandidate = nil
		self.UpgradeCandidateWindows = 0
		self:_setTier(candidate, averageFps, p95FrameSeconds)
	elseif candidateRank > currentRank then
		if self.UpgradeCandidate == candidate then
			self.UpgradeCandidateWindows += 1
		else
			self.UpgradeCandidate = candidate
			self.UpgradeCandidateWindows = 1
		end
		if self.UpgradeCandidateWindows >= UPGRADE_WINDOW_COUNT then
			self.UpgradeCandidate = nil
			self.UpgradeCandidateWindows = 0
			self:_setTier(candidate, averageFps, p95FrameSeconds)
		end
	else
		self.UpgradeCandidate = nil
		self.UpgradeCandidateWindows = 0
	end
end

function PerformanceController:_recordFrame(deltaTime)
	if self.StudioOverrideTier or not self.WindowFocused or os.clock() < self.WarmupUntil then
		return
	end
	if type(deltaTime) ~= "number" or deltaTime <= 0 or deltaTime ~= deltaTime then
		return
	end
	local sample = math.min(deltaTime, 0.25)
	table.insert(self.FrameSamples, sample)
	self.SampleElapsed += sample
	if self.SampleElapsed < SAMPLE_WINDOW_SECONDS then
		return
	end
	local candidate, averageFps, p95FrameSeconds = classifyWindow(self.FrameSamples, self.SampleElapsed)
	table.clear(self.FrameSamples)
	self.SampleElapsed = 0
	self:_applyClassification(candidate, averageFps, p95FrameSeconds)
end

function PerformanceController:GetTier()
	return self.Tier or INITIAL_TIER
end

function PerformanceController:GetLeafModelLimit()
	local tier = self:GetTier()
	return math.max(1, math.floor(tonumber(leafModelLimits[tier]) or 3000))
end

function PerformanceController:ConnectTierChanged(callback)
	assert(type(callback) == "function", "Performance tier callback must be a function")
	return self.TierChanged.Event:Connect(callback)
end

return PerformanceController

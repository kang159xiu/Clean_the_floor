local StateSnapshotStore = {}
StateSnapshotStore.__index = StateSnapshotStore

local INITIAL_RETRY_DELAYS = { 1, 2, 4, 8 }
local STEADY_RETRY_DELAY = 10
local MAXIMUM_RETRY_WINDOW = 60

function StateSnapshotStore.new(remote)
	assert(remote and remote:IsA("RemoteEvent"), "StateSnapshotStore requires a RemoteEvent")

	local self = setmetatable({}, StateSnapshotStore)
	self.Remote = remote
	self.LatestSnapshot = nil
	self.Version = 0
	self.StartedRequesting = false
	self.SnapshotReceived = Instance.new("BindableEvent")
	self.RemoteConnection = remote.OnClientEvent:Connect(function(snapshot)
		if type(snapshot) ~= "table" then
			return
		end
		self.LatestSnapshot = snapshot
		self.Version += 1
		self.SnapshotReceived:Fire(snapshot, self.Version)
	end)
	return self
end

function StateSnapshotStore:Connect(callback)
	assert(type(callback) == "function", "StateSnapshotStore callback must be a function")

	local connection = self.SnapshotReceived.Event:Connect(function(snapshot)
		callback(snapshot)
	end)
	local snapshot = self.LatestSnapshot
	local version = self.Version
	if snapshot ~= nil then
		task.defer(function()
			if connection.Connected and self.Version == version then
				callback(snapshot)
			end
		end)
	end
	return connection
end

function StateSnapshotStore:GetLatest()
	return self.LatestSnapshot, self.Version
end

function StateSnapshotStore:_requestOnce()
	local succeeded, message = pcall(function()
		self.Remote:FireServer("Request")
	end)
	if not succeeded then
		warn("[CTF StateSnapshotStore] Snapshot request failed: " .. tostring(message))
	end
end

function StateSnapshotStore:StartRequesting()
	if self.StartedRequesting then
		return
	end
	self.StartedRequesting = true

	task.spawn(function()
		local startedAt = os.clock()
		self:_requestOnce()
		for _, delaySeconds in INITIAL_RETRY_DELAYS do
			if self.LatestSnapshot ~= nil then
				return
			end
			task.wait(delaySeconds)
			if self.LatestSnapshot ~= nil then
				return
			end
			self:_requestOnce()
		end

		while self.LatestSnapshot == nil do
			local elapsed = os.clock() - startedAt
			if elapsed >= MAXIMUM_RETRY_WINDOW then
				warn("[CTF StateSnapshotStore] No state snapshot received within 60 seconds")
				return
			end
			task.wait(math.min(STEADY_RETRY_DELAY, MAXIMUM_RETRY_WINDOW - elapsed))
			if self.LatestSnapshot == nil then
				self:_requestOnce()
			end
		end
	end)
end

return StateSnapshotStore

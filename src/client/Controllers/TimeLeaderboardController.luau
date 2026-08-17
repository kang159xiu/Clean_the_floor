local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CoinFormat = require(ReplicatedStorage.Shared.CoinFormat)
local DurationFormat = require(ReplicatedStorage.Shared.DurationFormat)

local TimeLeaderboardController = {}
local BoardView = {}
BoardView.__index = BoardView

local TOP_ENTRY_LIMIT = 20
local BOARD_RESOLVE_INTERVAL = 1

local localPlayer = Players.LocalPlayer

local function getPositiveSeconds(value)
	local numeric = tonumber(value)
	if not numeric or numeric ~= numeric or numeric <= 0 or numeric == math.huge then
		return nil
	end
	return math.floor(numeric + 0.5)
end

local function getTextLabel(parent, name)
	local label = parent and parent:FindFirstChild(name)
	return if label and label:IsA("TextLabel") then label else nil
end

local function findChild(parent, name, className)
	local child = parent and parent:FindFirstChild(name)
	if not child or (className and not child:IsA(className)) then
		return nil
	end
	return child
end

function BoardView.new(options)
	return setmetatable({
		BoardName = options.BoardName,
		GeneratedRowAttribute = options.GeneratedRowAttribute,
		RowNamePrefix = options.RowNamePrefix,
		WarningText = options.WarningText,
		Remote = options.Remote,
		ValueField = options.ValueField,
		AmountFormatter = options.AmountFormatter,
		ScrollingFrame = nil,
		ListLayout = nil,
		RowTemplate = nil,
		TemplateFrame = nil,
		SelfFrame = nil,
		MissingWarned = false,
		PendingSnapshot = {
			Entries = {},
			Self = {
				UserName = localPlayer.Name,
				TimeSeconds = nil,
				RankText = "#--",
			},
		},
	}, BoardView)
end

function BoardView:_resolveBoard()
	local functionFolder = findChild(Workspace, "Function")
	local leaderboards = findChild(functionFolder, "Leaderboards")
	local board = findChild(leaderboards, self.BoardName)
	local surfaceGui = findChild(board, "SurfaceGui", "SurfaceGui")
	local scrollingFrame = findChild(surfaceGui, "ScrollingFrame", "ScrollingFrame")
	local listLayout = findChild(scrollingFrame, "UIListLayout", "UIListLayout")
	local rowTemplate = findChild(scrollingFrame, "RowTemplate")
	local templateFrame = findChild(rowTemplate, "Frame", "Frame")
	local selfContainer = findChild(surfaceGui, "Self")
	local selfFrame = findChild(selfContainer, "Frame", "Frame")
	if
		not scrollingFrame
		or not listLayout
		or not rowTemplate
		or not rowTemplate:IsA("GuiObject")
		or not templateFrame
		or not selfFrame
	then
		return false
	end
	if
		not getTextLabel(templateFrame, "Amount")
		or not getTextLabel(templateFrame, "Rank")
		or not getTextLabel(templateFrame, "UserName")
		or not getTextLabel(selfFrame, "Amount")
		or not getTextLabel(selfFrame, "Rank")
		or not getTextLabel(selfFrame, "UserName")
	then
		return false
	end
	self.ScrollingFrame = scrollingFrame
	self.ListLayout = listLayout
	self.RowTemplate = rowTemplate
	self.TemplateFrame = templateFrame
	self.SelfFrame = selfFrame
	self.RowTemplate.Visible = false
	self.ScrollingFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	self.ScrollingFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	self.ScrollingFrame.ScrollingDirection = Enum.ScrollingDirection.Y
	self.ScrollingFrame.ScrollingEnabled = true
	self.ScrollingFrame.Active = true
	return true
end

function BoardView:_hasBoard()
	return self.ScrollingFrame
		and self.ScrollingFrame.Parent
		and self.ListLayout
		and self.ListLayout.Parent == self.ScrollingFrame
		and self.RowTemplate
		and self.RowTemplate.Parent
		and self.TemplateFrame
		and self.TemplateFrame.Parent
		and self.SelfFrame
		and self.SelfFrame.Parent
end

function BoardView:_clearBoardReferences()
	self.ScrollingFrame = nil
	self.ListLayout = nil
	self.RowTemplate = nil
	self.TemplateFrame = nil
	self.SelfFrame = nil
end

function BoardView:_clearGeneratedRows()
	for _, child in self.ScrollingFrame:GetChildren() do
		if child:GetAttribute(self.GeneratedRowAttribute) == true then
			child:Destroy()
		end
	end
end

function BoardView:_renderEntry(entry, fallbackRank)
	if type(entry) ~= "table" then
		return
	end
	local amountValue = getPositiveSeconds(entry[self.ValueField])
	local userName = type(entry.UserName) == "string" and string.sub(entry.UserName, 1, 32) or nil
	local rank = math.floor(tonumber(entry.Rank) or fallbackRank)
	if not amountValue or not userName or userName == "" or rank < 1 or rank > TOP_ENTRY_LIMIT then
		return
	end
	local row = self.RowTemplate:Clone()
	row.Name = string.format("%s_%02d", self.RowNamePrefix, rank)
	row.LayoutOrder = rank
	row:SetAttribute(self.GeneratedRowAttribute, true)
	local rowFrame = findChild(row, "Frame", "Frame")
	local amountLabel = getTextLabel(rowFrame, "Amount")
	local rankLabel = getTextLabel(rowFrame, "Rank")
	local userNameLabel = getTextLabel(rowFrame, "UserName")
	if not rowFrame or not amountLabel or not rankLabel or not userNameLabel then
		row:Destroy()
		return
	end
	amountLabel.Text = self.AmountFormatter(amountValue)
	rankLabel.Text = "#" .. tostring(rank)
	userNameLabel.Text = userName
	row.Visible = true
	rowFrame.Visible = true
	row.Parent = self.ScrollingFrame
end

function BoardView:_renderSelf(selfData)
	local amount = getTextLabel(self.SelfFrame, "Amount")
	local rank = getTextLabel(self.SelfFrame, "Rank")
	local userName = getTextLabel(self.SelfFrame, "UserName")
	local data = type(selfData) == "table" and selfData or {}
	local rankText = type(data.RankText) == "string" and string.sub(data.RankText, 1, 12) or "#--"
	local nameText = type(data.UserName) == "string" and string.sub(data.UserName, 1, 32) or localPlayer.Name
	amount.Text = self.AmountFormatter(data[self.ValueField])
	rank.Text = rankText
	userName.Text = nameText
end

function BoardView:_renderSnapshot(snapshot)
	if not self:_hasBoard() and not self:_resolveBoard() then
		return false
	end
	self:_clearGeneratedRows()
	local entries = type(snapshot) == "table" and snapshot.Entries or nil
	if type(entries) == "table" then
		for index, entry in ipairs(entries) do
			if index > TOP_ENTRY_LIMIT then
				break
			end
			self:_renderEntry(entry, index)
		end
	end
	self:_renderSelf(type(snapshot) == "table" and snapshot.Self or nil)
	return true
end

function BoardView:Start()
	self.Remote.OnClientEvent:Connect(function(snapshot)
		if type(snapshot) ~= "table" then
			return
		end
		self.PendingSnapshot = snapshot
		self:_renderSnapshot(snapshot)
	end)
	self.Remote:FireServer("Request")

	task.spawn(function()
		local attempts = 0
		while true do
			if not self:_hasBoard() then
				self:_clearBoardReferences()
				if self:_resolveBoard() then
					self.MissingWarned = false
					self:_renderSnapshot(self.PendingSnapshot)
				else
					attempts += 1
					if attempts >= 10 and not self.MissingWarned then
						self.MissingWarned = true
						warn(self.WarningText)
					end
				end
			end
			task.wait(BOARD_RESOLVE_INTERVAL)
		end
	end)
end

function TimeLeaderboardController:Init(remotes)
	self.Views = {
		BoardView.new({
			BoardName = "WinsBoard",
			GeneratedRowAttribute = "ClearTimeLeaderboardRow",
			RowNamePrefix = "ClearTimeRank",
			WarningText = "Clear-time leaderboard UI is unavailable; waiting for WinsBoard to stream in.",
			Remote = remotes.ClearTimeLeaderboardSnapshot,
			ValueField = "TimeSeconds",
			AmountFormatter = DurationFormat.HoursMinutes,
		}),
		BoardView.new({
			BoardName = "PlaytimeBoard",
			GeneratedRowAttribute = "PlaytimeLeaderboardRow",
			RowNamePrefix = "PlaytimeRank",
			WarningText = "Playtime leaderboard UI is unavailable; waiting for PlaytimeBoard to stream in.",
			Remote = remotes.PlaytimeLeaderboardSnapshot,
			ValueField = "TimeSeconds",
			AmountFormatter = DurationFormat.HoursMinutes,
		}),
		BoardView.new({
			BoardName = "gold",
			GeneratedRowAttribute = "CleanupLeaderboardRow",
			RowNamePrefix = "CleanupRank",
			WarningText = "Cleanup leaderboard UI is unavailable; waiting for gold to stream in.",
			Remote = remotes.CleanupLeaderboardSnapshot,
			ValueField = "LeafCount",
			AmountFormatter = function(value)
				return CoinFormat.Compact(math.max(0, math.floor(tonumber(value) or 0)))
			end,
		}),
		BoardView.new({
			BoardName = "POOP",
			GeneratedRowAttribute = "PoopLeaderboardRow",
			RowNamePrefix = "PoopRank",
			WarningText = "Poop leaderboard UI is unavailable; waiting for POOP to stream in.",
			Remote = remotes.PoopLeaderboardSnapshot,
			ValueField = "PoopCount",
			AmountFormatter = function(value)
				return CoinFormat.Compact(math.max(0, math.floor(tonumber(value) or 0)))
			end,
		}),
	}
	for _, view in self.Views do
		view:Start()
	end
end

return TimeLeaderboardController

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BagConfig = require(ReplicatedStorage.Shared.Config.BagConfig)
local ProductConfig = require(ReplicatedStorage.Shared.Config.ProductConfig)
local ToolConfig = require(ReplicatedStorage.Shared.Config.ToolConfig)

local DeveloperProductService = {}

-- Keep the existing DataStore name so Schema 1 and 2 purchases migrate in place.
local ENTITLEMENT_DATASTORE_NAME = "CleanTheFloor_RobuxEntitlements_v1"
local ENTITLEMENT_SCHEMA_VERSION = 3
local MAX_DATASTORE_ATTEMPTS = 3
local RETRY_DELAYS = { 1, 2 }
local MAX_PROCESSED_RECEIPTS = 200
local MAX_LEGACY_OWNED_PRODUCT_IDS = 100
local PURCHASE_PROMPT_TIMEOUT = 60

local entitlementStore = DataStoreService:GetDataStore(ENTITLEMENT_DATASTORE_NAME)
local entitlementStates = {}
local entitlementLoadLocks = {}
local purchasePromptLocks = {}

local function getDataKeyFromUserId(userId)
	return string.format("Player_%d", math.floor(tonumber(userId) or 0))
end

local function isPositiveWholeNumber(value)
	local numberValue = tonumber(value)
	return numberValue ~= nil
		and numberValue == numberValue
		and numberValue < math.huge
		and numberValue > 0
		and numberValue % 1 == 0
end

local function sanitizeToolGrants(source)
	local result = {}
	for _, productConfigId in ProductConfig.DeveloperProductOrder do
		local product = ProductConfig.DeveloperProducts[productConfigId]
		if product.Kind == "PermanentTool" then
			result[product.ToolId] = type(source) == "table" and source[product.ToolId] == true
		end
	end
	return result
end

local function sanitizeMinimumBagLevel(value)
	local numberValue = tonumber(value)
	if
		numberValue == nil
		or numberValue ~= numberValue
		or numberValue == math.huge
		or numberValue == -math.huge
	then
		numberValue = BagConfig.DefaultLevel
	end
	local level = math.clamp(
		math.floor(numberValue),
		BagConfig.DefaultLevel,
		BagConfig.MaxLevel
	)
	if level <= BagConfig.DefaultLevel then
		return BagConfig.DefaultLevel
	end
	for candidateLevel = level, BagConfig.DefaultLevel + 1, -1 do
		if ProductConfig.DeveloperProductsByBagLevel[candidateLevel] then
			return candidateLevel
		end
	end
	return BagConfig.DefaultLevel
end

local function sanitizeProcessedReceiptIds(source)
	local result = {}
	local seen = {}
	if type(source) ~= "table" then
		return result
	end
	for _, rawPurchaseId in source do
		if #result >= MAX_PROCESSED_RECEIPTS then
			break
		end
		if
			type(rawPurchaseId) == "string"
			and #rawPurchaseId > 0
			and #rawPurchaseId <= 128
			and not seen[rawPurchaseId]
		then
			seen[rawPurchaseId] = true
			table.insert(result, rawPurchaseId)
		end
	end
	return result
end

local function sanitizeLegacyOwnedProductIds(source)
	local result = {}
	if type(source) ~= "table" then
		return result
	end
	local count = 0
	for rawProductId, owned in source do
		if count >= MAX_LEGACY_OWNED_PRODUCT_IDS then
			break
		end
		local productId = tonumber(rawProductId)
		if owned == true and isPositiveWholeNumber(productId) then
			result[tostring(math.floor(productId))] = true
			count += 1
		end
	end
	return result
end

local function makeEmptyRecord()
	return {
		SchemaVersion = ENTITLEMENT_SCHEMA_VERSION,
		PermanentToolGrants = sanitizeToolGrants(nil),
		PermanentMinimumBagLevel = BagConfig.DefaultLevel,
		ProcessedReceiptIds = {},
	}
end

local function sanitizeSchema3Record(source)
	local record = type(source) == "table" and source or {}
	return {
		SchemaVersion = ENTITLEMENT_SCHEMA_VERSION,
		PermanentToolGrants = sanitizeToolGrants(record.PermanentToolGrants),
		PermanentMinimumBagLevel = sanitizeMinimumBagLevel(record.PermanentMinimumBagLevel),
		ProcessedReceiptIds = sanitizeProcessedReceiptIds(record.ProcessedReceiptIds),
	}
end

local function migrateRecord(source)
	if type(source) ~= "table" then
		return makeEmptyRecord()
	end
	local sourceSchemaVersion = tonumber(source.SchemaVersion)
	if sourceSchemaVersion and sourceSchemaVersion >= ENTITLEMENT_SCHEMA_VERSION then
		return sanitizeSchema3Record(source)
	end

	local record = makeEmptyRecord()
	record.ProcessedReceiptIds = sanitizeProcessedReceiptIds(source.ProcessedReceiptIds)

	-- Schema 2 grants were scoped to one rebirth. Existing purchases are promoted
	-- in place so players do not lose Robux items when this schema becomes permanent.
	local legacyToolGrants = sanitizeToolGrants(source.ToolGrants)
	for toolId, granted in legacyToolGrants do
		if granted then
			record.PermanentToolGrants[toolId] = true
		end
	end
	record.PermanentMinimumBagLevel = math.max(
		record.PermanentMinimumBagLevel,
		sanitizeMinimumBagLevel(source.MinimumBagLevel)
	)

	-- Schema 1 stored purchased Product IDs instead of normalized targets.
	local ownedProductIds = sanitizeLegacyOwnedProductIds(source.OwnedProductIds)
	for _, productConfigId in ProductConfig.DeveloperProductOrder do
		local product = ProductConfig.DeveloperProducts[productConfigId]
		if ownedProductIds[tostring(product.ProductId)] == true then
			if product.Kind == "PermanentTool" then
				record.PermanentToolGrants[product.ToolId] = true
			elseif product.Kind == "PermanentBagLevel" then
				record.PermanentMinimumBagLevel = math.max(
					record.PermanentMinimumBagLevel,
					product.BagLevel
				)
			end
		end
	end
	return record
end

local function hasProcessedReceipt(record, purchaseId)
	for _, processedId in record.ProcessedReceiptIds do
		if processedId == purchaseId then
			return true
		end
	end
	return false
end

local function appendProcessedReceipt(record, purchaseId)
	if hasProcessedReceipt(record, purchaseId) then
		return false
	end
	table.insert(record.ProcessedReceiptIds, purchaseId)
	while #record.ProcessedReceiptIds > MAX_PROCESSED_RECEIPTS do
		table.remove(record.ProcessedReceiptIds, 1)
	end
	return true
end

local function mergeRecords(left, right)
	local leftRecord = sanitizeSchema3Record(left)
	local rightRecord = sanitizeSchema3Record(right)
	local result = sanitizeSchema3Record(leftRecord)
	for toolId, granted in rightRecord.PermanentToolGrants do
		if granted then
			result.PermanentToolGrants[toolId] = true
		end
	end
	result.PermanentMinimumBagLevel = math.max(
		result.PermanentMinimumBagLevel,
		rightRecord.PermanentMinimumBagLevel
	)

	for _, purchaseId in leftRecord.ProcessedReceiptIds do
		appendProcessedReceipt(result, purchaseId)
	end
	for _, purchaseId in rightRecord.ProcessedReceiptIds do
		appendProcessedReceipt(result, purchaseId)
	end
	return result
end

local function applyProductGrant(record, product)
	if product.Kind == "PermanentTool" then
		record.PermanentToolGrants[product.ToolId] = true
	elseif product.Kind == "PermanentBagLevel" then
		record.PermanentMinimumBagLevel = math.max(
			record.PermanentMinimumBagLevel,
			product.BagLevel
		)
	end
end

local function getEntitlementTargets(record)
	local sanitizedRecord = sanitizeSchema3Record(record)
	return sanitizeToolGrants(sanitizedRecord.PermanentToolGrants), sanitizedRecord.PermanentMinimumBagLevel
end

function DeveloperProductService:_validateConfig()
	local seenProductIds = {}
	for _, productConfigId in ProductConfig.DeveloperProductOrder do
		local product = ProductConfig.DeveloperProducts[productConfigId]
		assert(product and product.Id == productConfigId, "Invalid Developer Product config: " .. productConfigId)
		assert(isPositiveWholeNumber(product.ProductId), productConfigId .. ".ProductId must be a positive integer")
		assert(not seenProductIds[product.ProductId], "Duplicate Developer Product ID: " .. product.ProductId)
		seenProductIds[product.ProductId] = true
		assert(
			ProductConfig.DeveloperProductsByProductId[product.ProductId] == product,
			productConfigId .. " is missing from DeveloperProductsByProductId"
		)
		if product.Kind == "PermanentTool" then
			local tool = ToolConfig.ById[product.ToolId]
			assert(tool and tool.AvailableForGameplay == true, productConfigId .. " targets an unavailable tool")
			assert(tool.PurchaseKind ~= "GamePass", productConfigId .. " cannot target a Game Pass tool")
			assert(
				ProductConfig.DeveloperProductsByToolId[product.ToolId] == product,
				productConfigId .. " is missing from DeveloperProductsByToolId"
			)
		elseif product.Kind == "PermanentBagLevel" then
			assert(
				product.BagLevel >= 3 and product.BagLevel <= BagConfig.MaxLevel,
				productConfigId .. ".BagLevel must be between 3 and BagConfig.MaxLevel"
			)
			assert(BagConfig.Levels[product.BagLevel], productConfigId .. " targets a missing backpack level")
			assert(
				ProductConfig.DeveloperProductsByBagLevel[product.BagLevel] == product,
				productConfigId .. " is missing from DeveloperProductsByBagLevel"
			)
		elseif product.Kind == "SkipRebirth" then
			assert(product.Id == "SkipRebirth", productConfigId .. " has an invalid SkipRebirth target")
		else
			error("Unsupported Developer Product kind: " .. tostring(product.Kind))
		end
	end
end

function DeveloperProductService:_getEntitlementState(player)
	return entitlementStates[player]
end

function DeveloperProductService:_getProviderValues(player)
	local entitlementState = self:_getEntitlementState(player)
	if not entitlementState or entitlementState.Ready ~= true then
		return {}, BagConfig.DefaultLevel, false
	end
	local toolGrants, minimumBagLevel = getEntitlementTargets(entitlementState.Record)
	return toolGrants, minimumBagLevel, true
end

function DeveloperProductService:IsReady(player)
	local entitlementState = self:_getEntitlementState(player)
	return entitlementState ~= nil and entitlementState.Ready == true
end

function DeveloperProductService:_applyCachedEntitlements(player, shouldPush)
	if player.Parent ~= Players or not self.PlayerDataService:GetState(player) then
		return false, false, false
	end
	local ready, toolChanged, bagChanged = self.PlayerDataService:ApplyDeveloperProductEntitlements(
		player,
		shouldPush
	)
	if bagChanged then
		self.BagVisualService:SyncPlayer(player)
	end
	return ready, toolChanged, bagChanged
end

function DeveloperProductService:_loadEntitlements(player)
	if entitlementLoadLocks[player] then
		while entitlementLoadLocks[player] and player.Parent == Players do
			task.wait()
		end
		return self:IsReady(player)
	end
	entitlementLoadLocks[player] = true

	local loadedRecord = nil
	local lastError = nil
	for attempt = 1, MAX_DATASTORE_ATTEMPTS do
		if player.Parent ~= Players then
			break
		end
		local success, result = pcall(function()
			return entitlementStore:UpdateAsync(getDataKeyFromUserId(player.UserId), function(rawRecord)
				return migrateRecord(rawRecord)
			end)
		end)
		if success then
			loadedRecord = sanitizeSchema3Record(result)
			break
		end
		lastError = result
		if attempt < MAX_DATASTORE_ATTEMPTS then
			task.wait(RETRY_DELAYS[attempt] or RETRY_DELAYS[#RETRY_DELAYS])
		end
	end

	if player.Parent == Players then
		local currentState = entitlementStates[player]
		if loadedRecord then
			entitlementStates[player] = {
				Ready = true,
				Record = if currentState and currentState.Record
					then mergeRecords(currentState.Record, loadedRecord)
					else loadedRecord,
			}
		else
			entitlementStates[player] = {
				Ready = false,
				Record = currentState and currentState.Record or makeEmptyRecord(),
			}
			warn(string.format(
				"Developer Product entitlement load or migration failed for %s: %s",
				player.Name,
				tostring(lastError)
			))
		end
	end
	entitlementLoadLocks[player] = nil

	if player.Parent == Players then
		self:_applyCachedEntitlements(player, true)
	end
	return self:IsReady(player)
end

function DeveloperProductService:_adoptReceiptRecord(player, record)
	local currentState = entitlementStates[player]
	entitlementStates[player] = {
		Ready = true,
		Record = if currentState and currentState.Record
			then mergeRecords(currentState.Record, record)
			else sanitizeSchema3Record(record),
	}
end

function DeveloperProductService:_recordMetrics(player, product, receiptInfo)
	if not self.MetricsService or not self.PlayerDataService:GetState(player) then
		return
	end
	local state = self.PlayerDataService:GetState(player)
	self.MetricsService:RecordPurchase(
		player,
		"DeveloperProduct",
		tostring(product.ProductId),
		math.max(0, math.floor(tonumber(receiptInfo.CurrencySpent) or 0)),
		state.CurrentAreaId,
		{
			Currency = "Robux",
			TargetKind = product.Kind,
			ToolId = product.ToolId,
			BagLevel = product.BagLevel,
		}
	)
end

function DeveloperProductService:_notifyNewGrant(player, product, receiptInfo, bagChanged)
	if product.Kind == "PermanentTool" then
		local tool = ToolConfig.ById[product.ToolId]
		for _, handler in self.ToolGrantedHandlers do
			local success, message = pcall(handler, player, product.ToolId)
			if not success then
				warn("Developer Product tool handler failed: " .. tostring(message))
			end
		end
		local equipped = self.PlayerDataService:SetEquippedTool(player, product.ToolId)
		if equipped then
			self.PlayerDataService:Notify(player, tool.Name .. " permanently unlocked and equipped.")
		else
			self.PlayerDataService:Notify(player, tool.Name .. " permanently unlocked.")
		end
	elseif product.Kind == "PermanentBagLevel" then
		local bag = BagConfig.Levels[product.BagLevel]
		if bagChanged then
			for _, handler in self.BagGrantedHandlers do
				local success, message = pcall(handler, player, product.BagLevel, bag)
				if not success then
					warn("Developer Product backpack handler failed: " .. tostring(message))
				end
			end
		end
		self.PlayerDataService:Notify(player, bag.Name .. " permanently unlocked.")
	end
	self:_recordMetrics(player, product, receiptInfo)
end

function DeveloperProductService:_processReceipt(receiptInfo)
	local playerId = tonumber(receiptInfo and receiptInfo.PlayerId)
	local productId = tonumber(receiptInfo and receiptInfo.ProductId)
	local purchaseId = receiptInfo and receiptInfo.PurchaseId
	local product = productId and ProductConfig.DeveloperProductsByProductId[productId] or nil
	if
		not isPositiveWholeNumber(playerId)
		or not product
		or type(purchaseId) ~= "string"
		or #purchaseId <= 0
		or #purchaseId > 128
	then
		warn(string.format(
			"Unrecognized Developer Product receipt (PlayerId=%s, ProductId=%s, PurchaseId=%s)",
			tostring(playerId),
			tostring(productId),
			tostring(purchaseId)
		))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local player = Players:GetPlayerByUserId(playerId)
	if product.Kind == "SkipRebirth" then
		if
			not player
			or player.Parent ~= Players
			or not self.RebirthService
			or not self:IsReady(player)
			or not self.PlayerDataService:GetState(player)
		then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local entitlementState = self:_getEntitlementState(player)
		if entitlementState and hasProcessedReceipt(entitlementState.Record, purchaseId) then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end

		local rebirthApplied, rebirthMessage = self.RebirthService:TryPurchasedRebirth(
			player,
			purchaseId
		)
		if not rebirthApplied then
			warn(string.format(
				"Skip Rebirth receipt deferred for %s (PurchaseId=%s): %s",
				player.Name,
				purchaseId,
				tostring(rebirthMessage)
			))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		local newlyRecorded = false
		local ledgerSaved, ledgerResult = pcall(function()
			return entitlementStore:UpdateAsync(getDataKeyFromUserId(playerId), function(rawRecord)
				local record = migrateRecord(rawRecord)
				newlyRecorded = not hasProcessedReceipt(record, purchaseId)
				if newlyRecorded then
					appendProcessedReceipt(record, purchaseId)
				end
				return record
			end)
		end)
		if not ledgerSaved then
			warn(string.format(
				"Skip Rebirth receipt ledger save failed (PlayerId=%d, PurchaseId=%s): %s",
				playerId,
				purchaseId,
				tostring(ledgerResult)
			))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end

		self:_adoptReceiptRecord(player, sanitizeSchema3Record(ledgerResult))
		purchasePromptLocks[player] = nil
		if newlyRecorded then
			self:_recordMetrics(player, product, receiptInfo)
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local newlyProcessed = false
	local success, result = pcall(function()
		return entitlementStore:UpdateAsync(getDataKeyFromUserId(playerId), function(rawRecord)
			local record = migrateRecord(rawRecord)
			-- UpdateAsync can invoke this callback repeatedly after a write conflict.
			-- The final invocation determines whether this server saw a new receipt.
			newlyProcessed = not hasProcessedReceipt(record, purchaseId)
			if not newlyProcessed then
				return record
			end
			applyProductGrant(record, product)
			appendProcessedReceipt(record, purchaseId)
			return record
		end)
	end)
	if not success then
		warn(string.format(
			"Developer Product receipt save failed (PlayerId=%d, ProductId=%d): %s",
			playerId,
			product.ProductId,
			tostring(result)
		))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local record = sanitizeSchema3Record(result)
	if player and player.Parent == Players then
		self:_adoptReceiptRecord(player, record)
		local _, _, bagChanged = self:_applyCachedEntitlements(player, true)
		local promptLock = purchasePromptLocks[player]
		if promptLock and promptLock.ProductId == product.ProductId then
			purchasePromptLocks[player] = nil
		end
		if newlyProcessed and self.PlayerDataService:GetState(player) then
			self:_notifyNewGrant(player, product, receiptInfo, bagChanged)
		end
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function DeveloperProductService:_isTargetAlreadyOwned(state, product)
	if product.Kind == "PermanentTool" then
		return state.UnlockedTools[product.ToolId] == true
	elseif product.Kind == "PermanentBagLevel" then
		return state.BagLevel >= product.BagLevel
	elseif product.Kind == "SkipRebirth" then
		return false
	end
	return true
end

function DeveloperProductService:_promptPurchase(player, product)
	local state = self.PlayerDataService:GetState(player)
	if player.Parent ~= Players or not state then
		return false
	end
	if not self:IsReady(player) then
		if not entitlementLoadLocks[player] then
			task.spawn(function()
				self:_loadEntitlements(player)
			end)
		end
		self.PlayerDataService:Notify(player, "Checking Robux purchases. Try again shortly.")
		return false
	end

	self:_applyCachedEntitlements(player, true)
	state = self.PlayerDataService:GetState(player)
	if not state then
		return false
	end
	if self:_isTargetAlreadyOwned(state, product) then
		if product.Kind == "PermanentTool" then
			self.PlayerDataService:Notify(player, "You already permanently own this tool.")
		else
			self.PlayerDataService:Notify(player, "You already have this backpack level or better.")
		end
		return false
	end
	if purchasePromptLocks[player] then
		return false
	end

	local promptToken = {}
	purchasePromptLocks[player] = {
		ProductId = product.ProductId,
		Token = promptToken,
	}
	local promptSucceeded, promptError = pcall(function()
		MarketplaceService:PromptProductPurchase(player, product.ProductId)
	end)
	if not promptSucceeded then
		purchasePromptLocks[player] = nil
		warn(string.format(
			"Developer Product prompt failed for %s (%d): %s",
			player.Name,
			product.ProductId,
			tostring(promptError)
		))
		self.PlayerDataService:Notify(player, "The Robux purchase window is unavailable. Try again later.")
		return false
	end

	task.delay(PURCHASE_PROMPT_TIMEOUT, function()
		local currentLock = purchasePromptLocks[player]
		if currentLock and currentLock.Token == promptToken then
			purchasePromptLocks[player] = nil
		end
	end)
	return true
end

function DeveloperProductService:PromptToolPurchase(player, toolId)
	local product = ProductConfig.DeveloperProductsByToolId[toolId]
	if not product then
		return false
	end
	return self:_promptPurchase(player, product)
end

function DeveloperProductService:PromptBagLevelPurchase(player, bagLevel)
	local product = ProductConfig.DeveloperProductsByBagLevel[bagLevel]
	if not product then
		return false
	end
	return self:_promptPurchase(player, product)
end

function DeveloperProductService:AddBagGrantedHandler(handler)
	if handler then
		table.insert(self.BagGrantedHandlers, handler)
	end
end

function DeveloperProductService:AddToolGrantedHandler(handler)
	if handler then
		table.insert(self.ToolGrantedHandlers, handler)
	end
end

function DeveloperProductService:SetRebirthService(rebirthService)
	self.RebirthService = rebirthService
end

function DeveloperProductService:Init(playerDataService, bagVisualService, metricsService)
	self.PlayerDataService = playerDataService
	self.BagVisualService = bagVisualService
	self.MetricsService = metricsService
	self.RebirthService = nil
	self.BagGrantedHandlers = {}
	self.ToolGrantedHandlers = {}
	self:_validateConfig()

	playerDataService:SetDeveloperProductEntitlementProvider(function(player)
		return self:_getProviderValues(player)
	end)
	playerDataService:AddPlayerStateReadyHandler(function(player)
		self:_loadEntitlements(player)
	end)

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		return self:_processReceipt(receiptInfo)
	end
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, wasPurchased)
		local player = Players:GetPlayerByUserId(tonumber(userId) or 0)
		local promptLock = player and purchasePromptLocks[player]
		if not promptLock or promptLock.ProductId ~= tonumber(productId) then
			return
		end
		if wasPurchased ~= true then
			purchasePromptLocks[player] = nil
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		entitlementStates[player] = nil
		entitlementLoadLocks[player] = nil
		purchasePromptLocks[player] = nil
	end)
end

return DeveloperProductService

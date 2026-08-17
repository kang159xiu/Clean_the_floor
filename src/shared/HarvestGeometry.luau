local HarvestGeometry = {}

local DEFAULT_BROOM_COVERAGE_RING_WIDTH = 1
local BROOM_COVERAGE_PRECISION = 1_000_000

local function normalizeBroomCoverage(coverage)
	local numericCoverage = math.max(0, tonumber(coverage) or 0)
	return math.floor(numericCoverage * BROOM_COVERAGE_PRECISION + 0.5) / BROOM_COVERAGE_PRECISION
end

function HarvestGeometry.GetHorizontalForward(cframe)
	local lookVector = cframe.LookVector
	local horizontalForward = Vector3.new(lookVector.X, 0, lookVector.Z)
	if horizontalForward.Magnitude <= 0.0001 then
		return Vector3.new(0, 0, -1)
	end
	return horizontalForward.Unit
end

function HarvestGeometry.GetHarvestOrigin(rootCFrame, forwardOffset)
	local offset = math.max(0, tonumber(forwardOffset) or 0)
	return rootCFrame.Position + HarvestGeometry.GetHorizontalForward(rootCFrame) * offset
end

function HarvestGeometry.GetPlayerCenteredRadius(range, forwardOffset)
	local rangeRadius = math.max(0, tonumber(range) or 0)
	local toolLength = math.max(0, tonumber(forwardOffset) or 0)
	return rangeRadius + toolLength / 2
end

function HarvestGeometry.GetHorizontalDelta(origin, target)
	return Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
end

function HarvestGeometry.GetHorizontalDistanceSquared(origin, target)
	local delta = HarvestGeometry.GetHorizontalDelta(origin, target)
	return delta.X * delta.X + delta.Z * delta.Z
end

function HarvestGeometry.GetBroomCoverageMaximumRingIndex(coverage)
	local normalizedCoverage = normalizeBroomCoverage(coverage)
	if normalizedCoverage <= 0 then
		return -1
	end
	return math.max(0, math.ceil(normalizedCoverage) - 1)
end

function HarvestGeometry.GetBroomCoverageMaximumRadius(baseRadius, coverage, ringWidth)
	local normalizedBaseRadius = math.max(0, tonumber(baseRadius) or 0)
	local normalizedRingWidth = math.max(
		0.001,
		tonumber(ringWidth) or DEFAULT_BROOM_COVERAGE_RING_WIDTH
	)
	local maximumRingIndex = HarvestGeometry.GetBroomCoverageMaximumRingIndex(coverage)
	if maximumRingIndex < 0 then
		return 0
	end
	return normalizedBaseRadius + maximumRingIndex * normalizedRingWidth
end

function HarvestGeometry.GetBroomCoverageRingIndex(distance, baseRadius, ringWidth)
	local normalizedDistance = math.max(0, tonumber(distance) or 0)
	local normalizedBaseRadius = math.max(0, tonumber(baseRadius) or 0)
	if normalizedDistance <= normalizedBaseRadius then
		return 0
	end
	local normalizedRingWidth = math.max(
		0.001,
		tonumber(ringWidth) or DEFAULT_BROOM_COVERAGE_RING_WIDTH
	)
	return math.max(1, math.ceil((normalizedDistance - normalizedBaseRadius) / normalizedRingWidth))
end

function HarvestGeometry.GetBroomCoverageFraction(coverage, ringIndex)
	local normalizedCoverage = normalizeBroomCoverage(coverage)
	local normalizedRingIndex = math.max(0, math.floor(tonumber(ringIndex) or 0))
	return math.clamp(normalizedCoverage - normalizedRingIndex, 0, 1)
end

function HarvestGeometry.SelectBroomCoverageCandidates(candidates, coverage)
	local rings = {}
	local ringIndices = {}
	for order, candidate in candidates do
		local ringIndex = math.max(0, math.floor(tonumber(candidate.RingIndex) or 0))
		if HarvestGeometry.GetBroomCoverageFraction(coverage, ringIndex) > 0 then
			local ring = rings[ringIndex]
			if not ring then
				ring = {}
				rings[ringIndex] = ring
				table.insert(ringIndices, ringIndex)
			end
			candidate.CoverageOrder = order
			table.insert(ring, candidate)
		end
	end

	local selected = {}
	local maximumRingIndex = HarvestGeometry.GetBroomCoverageMaximumRingIndex(coverage)
	table.sort(ringIndices)
	for _, ringIndex in ringIndices do
		if ringIndex > maximumRingIndex then
			break
		end
		local ring = rings[ringIndex]
		if ring and #ring > 0 then
			table.sort(ring, function(left, right)
				if left.DistanceSquared ~= right.DistanceSquared then
					return left.DistanceSquared < right.DistanceSquared
				end
				local leftId = tostring(left.StableId or "")
				local rightId = tostring(right.StableId or "")
				if leftId ~= rightId then
					return leftId < rightId
				end
				return left.CoverageOrder < right.CoverageOrder
			end)

			local fraction = HarvestGeometry.GetBroomCoverageFraction(coverage, ringIndex)
			local selectedCount = math.min(#ring, math.ceil(#ring * fraction))
			for index = 1, selectedCount do
				table.insert(selected, ring[index])
			end
		end
	end
	return selected
end

function HarvestGeometry.GetHorizontalSegmentInfo(point, startPoint, endPoint)
	local pointFlat = Vector3.new(point.X, 0, point.Z)
	local startFlat = Vector3.new(startPoint.X, 0, startPoint.Z)
	local endFlat = Vector3.new(endPoint.X, 0, endPoint.Z)
	local segment = endFlat - startFlat
	local segmentLengthSquared = segment:Dot(segment)
	local alpha = 0
	if segmentLengthSquared > 0.0001 then
		alpha = math.clamp((pointFlat - startFlat):Dot(segment) / segmentLengthSquared, 0, 1)
	end
	local closestPoint = startFlat + segment * alpha
	local offset = pointFlat - closestPoint
	return closestPoint, alpha, offset.Magnitude, offset
end

function HarvestGeometry.ClampHorizontalPosition(origin, target, maxDistance)
	local distanceLimit = math.max(0, tonumber(maxDistance) or 0)
	local delta = HarvestGeometry.GetHorizontalDelta(origin, target)
	local distance = delta.Magnitude
	if distance <= distanceLimit or distance <= 0.0001 then
		return target, false
	end

	local clampedHorizontal = delta.Unit * distanceLimit
	return Vector3.new(
		origin.X + clampedHorizontal.X,
		target.Y,
		origin.Z + clampedHorizontal.Z
	), true
end

function HarvestGeometry.GetDistanceSquaredToBounds(origin, boundingCFrame, boundingSize)
	local localOrigin = boundingCFrame:PointToObjectSpace(origin)
	local halfX = boundingSize.X / 2
	local halfY = boundingSize.Y / 2
	local halfZ = boundingSize.Z / 2
	local nearestX = math.clamp(localOrigin.X, -halfX, halfX)
	local nearestZ = math.clamp(localOrigin.Z, -halfZ, halfZ)
	local deltaX = localOrigin.X - nearestX
	local deltaZ = localOrigin.Z - nearestZ
	local verticalDistance = math.max(0, math.abs(localOrigin.Y) - halfY)
	return deltaX * deltaX + deltaZ * deltaZ, verticalDistance
end

return table.freeze(HarvestGeometry)

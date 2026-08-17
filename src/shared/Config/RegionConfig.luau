-- 实际生成数量 = clamp(地面面积 * LeafDensityPerSquareStud, MinimumLeafCount, MaximumLeafCount)
-- 如需固定数量，将 MinimumLeafCount 和 MaximumLeafCount 设置为相同值。
local AREA_IMAGE_PLACEHOLDER = "rbxassetid://87612010732805"
local LEAF_HEIGHT_JITTER_MIN = 0.05
local LEAF_HEIGHT_JITTER_MAX = 0.6

local RegionConfig = {
	AreaCount = 8,
	PersistentAreaCount = 9,
	DefaultUnlockedAreaCount = 1,
	BaseProgressionAreaCount = 4,
	FinalAreaId = "Area_08",
	Order = table.freeze({
		"Area_01",
		"Area_02",
		"Area_03",
		"Area_04",
		"Area_05",
		"Area_06",
		"Area_07",
		"Area_08",
	}),
	PersistentOrder = table.freeze({
		"Area_01",
		"Area_02",
		"Area_03",
		"Area_04",
		"Area_05",
		"Area_06",
		"Area_07",
		"Area_08",
		"Area_09",
	}),
	-- 尚未解锁、但紧邻当前推进区域时，只生成这些叶子作为远景预览。
	LockedPreviewLeafCount = 100,
	GameplaySettings = {
		BaseWalkSpeed = 16,
		SettlementIdleDuration = 1,
	},
	Area_01 = {
		Id = "Area_01",
		DisplayName = "Yard",
		Image = "rbxassetid://106028097544634", -- TODO: 庭院图片。
		Seed = 104729,
		LeafDensityPerSquareStud = 2,
		MinimumLeafCount = 450,
		MaximumLeafCount = 450,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
	Area_02 = {
		Id = "Area_02",
		DisplayName = "Garden",
		Image = "rbxassetid://100261707457686", -- TODO: 花园区域图片。
		Seed = 105727,
		LeafDensityPerSquareStud = 3,
		MinimumLeafCount = 300,
		MaximumLeafCount = 2000,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
	Area_03 = {
		Id = "Area_03",
		DisplayName = "Pool",
		Image = "rbxassetid://110814522026602", -- TODO: 泳池图片。
		Seed = 106727,
		LeafDensityPerSquareStud = 3,
		MinimumLeafCount = 300,
		MaximumLeafCount = 3000,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
	Area_04 = {
		Id = "Area_04",
		DisplayName = "Woods",
		Image = "rbxassetid://88748977995783", -- TODO: 树林图片。
		Seed = 107729,
		LeafDensityPerSquareStud = 3,
		MinimumLeafCount = 300,
		MaximumLeafCount = 4000,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
	Area_05 = {
		Id = "Area_05",
		DisplayName = "Basketball Court",
		Image = "rbxassetid://112040756914452", -- TODO: 篮球场图片。
		Seed = 108727,
		LeafDensityPerSquareStud = 3,
		MinimumLeafCount = 300,
		MaximumLeafCount = 5000,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
	Area_06 = {
		Id = "Area_06",
		DisplayName = "Ranch",
		Image = "rbxassetid://115311558947146", -- TODO: 牧场图片。
		Seed = 109729,
		LeafDensityPerSquareStud = 3,
		MinimumLeafCount = 300,
		MaximumLeafCount = 5500,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
	Area_07 = {
		Id = "Area_07",
		DisplayName = "Lakeside",
		Image = "rbxassetid://85334175136862", -- TODO: 湖畔图片。
		Seed = 110731,
		LeafDensityPerSquareStud = 3,
		MinimumLeafCount = 300,
		MaximumLeafCount = 6000,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
	Area_08 = {
		Id = "Area_08",
		DisplayName = "Estate",
		Image = "rbxassetid://77819039742473", -- TODO: 庄园图片。
		Seed = 111733,
		LeafDensityPerSquareStud = 3,
		MinimumLeafCount = 300,
		MaximumLeafCount = 7000,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
	Area_09 = {
		Id = "Area_09",
		DisplayName = "Mansion",
		Image = "rbxassetid://77819039742473", -- Temporary Area_08 image until Mansion art is ready.
		Seed = 112741,
		LeafDensityPerSquareStud = 3,
		MinimumLeafCount = 300,
		MaximumLeafCount = 8000,
		EdgePadding = 0.5,
		LeafHeightJitterMin = LEAF_HEIGHT_JITTER_MIN,
		LeafHeightJitterMax = LEAF_HEIGHT_JITTER_MAX,
	},
}

function RegionConfig.IsActiveAreaId(areaId)
	if type(areaId) ~= "string" then
		return false
	end
	local areaNumber = tonumber(string.match(areaId, "^Area_(%d%d)$"))
	return areaNumber ~= nil and areaNumber >= 1 and areaNumber <= RegionConfig.AreaCount
end

function RegionConfig.AreAllUnlockedAreasCompleted(unlockedAreas, areas)
	local unlocked = type(unlockedAreas) == "table" and unlockedAreas or {}
	local progressByArea = type(areas) == "table" and areas or {}
	local foundUnlockedArea = false
	for _, areaId in RegionConfig.Order do
		if unlocked[areaId] == true then
			foundUnlockedArea = true
			local progress = progressByArea[areaId]
			if (tonumber(type(progress) == "table" and progress.ClearedRatio) or 0) < 1 then
				return false
			end
		end
	end
	return foundUnlockedArea
end

return table.freeze(RegionConfig)

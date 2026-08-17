local steps = table.freeze({
	CleanLeaves = 1,
	RecycleLeaves = 2,
	UpgradeAmount = 3,
	WaitForSecondRecycle = 4,
	UpgradeSpeed = 5,
	Complete = 6,
})

local messages = table.freeze({
	RecycleLeaves = "Recycle Leaves",
	UpgradeAmount = "Upgrade Pickup Amount",
	UpgradeSpeed = "Upgrade Pickup Speed",
	UpgradeBag = "Buy a Backpack",
	BuyBroom = "Buy the Broom",
	MakePoop = "You can now make poop for all players!",
	PickupPoop = "Pick up the poop.",
	SellPoop = "Sell the poop.",
})

local TutorialConfig = {
	Steps = steps,
	Messages = messages,
	LeafGoal = 15,
	UpgradeAreaId = "Area_01",
	AmountAttributeId = "Amount",
	SpeedAttributeId = "Speed",
	BroomGuidanceCoinThreshold = 825,
	BroomToolId = "Tool02",
}

return table.freeze(TutorialConfig)

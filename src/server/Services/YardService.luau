local Players = game:GetService("Players")

local YardService = {}

function YardService:Init(playerDataService)
	self.PlayerDataService = playerDataService

	playerDataService:AddPlayerStateReadyHandler(function(player, state)
		state.ActiveYardOwnerUserId = player.UserId
	end)

	playerDataService:SetYardContextProvider(function(player)
		return {
			Owner = player,
			OwnerUserId = player.UserId,
		}
	end)
end

function YardService:GetActiveOwner(player)
	if player.Parent == Players and self.PlayerDataService:GetState(player) then
		return player
	end
	return nil
end

function YardService:GetMembers(owner)
	if owner and owner.Parent == Players and self.PlayerDataService:GetState(owner) then
		return { owner }
	end
	return {}
end

return YardService

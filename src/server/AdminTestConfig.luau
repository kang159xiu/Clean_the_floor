local AdminTestConfig = {
	AllowedUserNames = {
		["1000Universes"] = true,
		["Fly01758"] = true,
		["xiaoyouqifele"] = true,
		["Fly01748"] = true,

		["Firefly"] = true,
		["zaku198902"] = true,
		["glaugh90"] = true,
		

	},
	InitialCoins = 0,
}

local normalizedAllowedUserNames = {}
for userName, allowed in AdminTestConfig.AllowedUserNames do
	if allowed == true and type(userName) == "string" then
		normalizedAllowedUserNames[string.lower(userName)] = true
	end
end

function AdminTestConfig.IsAllowed(userName)
	return type(userName) == "string" and normalizedAllowedUserNames[string.lower(userName)] == true
end

return AdminTestConfig

local Zone = require(game.ReplicatedStorage:WaitForChild("ReplicatedModules"):WaitForChild("Zone"))
local FactionUtils = require(game.ServerScriptService:WaitForChild("Modules"):WaitForChild("FactionUtils"))
local NotificationHandler = require(game.ServerScriptService.MainUI.NotificationHandler)
local tvlServerUtil = require(game.ServerScriptService.Modules.tvlServerUtil)

local function handleKillBrick(part: BasePart)
	local zone = Zone.new(part)
	local factionName = if part.Name == "Region" then "Forbidden" else string.gsub(part.Name, "KillBrick", "")
	
	if factionName == "Forbidden" then
		_G.ForbiddenFactionZone = zone
	elseif factionName == "Thorn" then
		_G.ThornFactionZone = zone
	end
	
	zone.playerEntered:Connect(function(player: Player)
		local character = player.Character
		if not character then return end
		if FactionUtils[`Is{factionName}`](player) then return end
		if factionName == "Forbidden" then
			if player:FindFirstChild("AllowedInPanWorld") then return end
		end
		if tvlServerUtil.devCheck(player) then return end
		local NoRegen = Instance.new("Folder")
		NoRegen.Name = "NoRegen"
		NoRegen.Parent = character
		character.Humanoid.Health = 0
		NotificationHandler.AdvancedNotification(player, 10, "Denied", `You can't be here as you aren't a part of the {factionName} faction!`)
	end)
end

workspace:WaitForChild("FactionKillBricks").ChildAdded:Connect(handleKillBrick)
for _, part in workspace:WaitForChild("FactionKillBricks"):GetChildren() do
	handleKillBrick(part)
end
handleKillBrick(workspace:WaitForChild("AmbientAreas"):WaitForChild("Forbidden Realm"):WaitForChild("Region"))
local remotes = game.ReplicatedStorage.RemoteEvents
local tvlReplicatedUtil = require(game.ReplicatedStorage:WaitForChild("ReplicatedModules"):WaitForChild("tvlReplicatedUtil"))

remotes.HasCustomAccess.OnServerInvoke = function(player, charName)
	return tvlReplicatedUtil.ServerHasGamepass(player, charName)
end
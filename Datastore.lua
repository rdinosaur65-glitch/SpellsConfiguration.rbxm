local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local defaultPlayerData = {
	["AgreedToRules"] = false,
	["PlayCutscenes"] = true,
	["ShadowsEnabled"] = true,
	["TexturesEnabled"] = true,
	["MusicToggle"] = true,  
}

local DataService = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("DataService"))
local DataStore = DataService.CreateDataStore("SaveFile1", defaultPlayerData)

local function say(...)
	warn("PlayerData DataStore:", ...) -- or print, its your choice.
end

local function getTypeOfValue(value)
	if type(value) == "number" then
		return "NumberValue" -- or "IntValue" its your choice.
	elseif type(value) == "string" then
		return "StringValue"
	elseif type(value) == "boolean" then
		return "BoolValue"
	end
end

local function getPlayerData(player: Player)
	say("attempting to get "..player.Name .. "'s data.")

	local folder = Instance.new("Folder")
	folder.Name = player.Name
	folder.Parent = ReplicatedStorage.PlayerData

	local data = DataStore:LoadDataAsync(player)

	for key, value in data:GetKeys() do
		local typeOfValue = getTypeOfValue(value)
		local objectWithValue = Instance.new(typeOfValue)
		objectWithValue.Name = key
		objectWithValue.Value = value
		objectWithValue.Parent = folder
	end
end

Players.PlayerRemoving:Connect(function(player)
	say("attempting to save "..player.Name .. "'s data.")

	if RunService:IsStudio() then
		say("cannot save your data in studio")
		return false
	end

	local folder = ReplicatedStorage.PlayerData:FindFirstChild(player.Name)

	if not folder then
		say(player.Name .. "'s folder was not found, data will not be saved.")
		return false
	end

	local sessionData = {}

	for _, setting in folder:GetChildren() do
		sessionData[setting.Name] = setting.Value
	end

	DataStore:UnclaimSessionLock(player, sessionData)
end)

Players.PlayerAdded:Connect(getPlayerData)
for _, player in Players:GetPlayers() do
	coroutine.wrap(getPlayerData)(player)
end
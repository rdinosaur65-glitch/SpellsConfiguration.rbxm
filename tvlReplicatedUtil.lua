local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CharacterConfiguration = require(ReplicatedStorage:WaitForChild("ReplicatedModules"):WaitForChild("CharacterConfiguration"))
local TweenModule = require(ReplicatedStorage:WaitForChild("ReplicatedModules"):WaitForChild("ReplicatedTweening"))

local IsClient = game:GetService("RunService"):IsClient()

local GetTweenCreate = function(...)
	return if IsClient then TweenService:Create(...) else TweenModule:GetTweenObject(...)
end

local v1 = {
	IsSpecie = function(p1, p2)
		if not p1 then
			return;
		end;
		if p1:FindFirstChild("CharacterConfiguration") == nil then
			return;
		end;
		local l__CharacterConfiguration__2 = p1.CharacterConfiguration;
		local v3 = false;
		for v4, v5 in pairs(p2) do
			if l__CharacterConfiguration__2.Specie.Value == tostring(v5) then
				v3 = true;
			end;
		end;
		return v3;
	end, 
	CharacterName = function(p3)
		if not p3 then
			return;
		end;
		local v6 = nil;
		local l__CharacterConfiguration__7 = p3:FindFirstChild("CharacterConfiguration");
		if l__CharacterConfiguration__7 ~= nil then
			v6 = l__CharacterConfiguration__7.CharacterName.Value;
		end;
		return v6;
	end,
	GetPlayer = function(p4)
		local v8 = Players:GetPlayerFromCharacter(p4);
		if v8 == nil then
			return;
		end;
		return v8;
	end,
	Hint = function(p5, p6, p7)
		local v9 = nil;
		v9 = require(game.ReplicatedStorage:WaitForChild("ReplicatedModules"):WaitForChild("NotificationModuleTSK"));
		assert(p6, "There has to be a specified message!");
		assert(p5, "There has to be a mentioned player or table of players!");
		local v14
		if type(p5) == "table" then
			local v10 = pcall(function()
				for v12, v13 in pairs(p5) do
					v9.SendMsg(v13, p6, p7 and p7 or 4, 4);
				end;
			end);
			v14 = v10
		else
			local o = pcall(function()
				v9.SendMsg(p5, p6, p7 and p7 or 4, 4);
			end);
			v14 = o;
		end;
		if v14 then
			return true;
		end;
		return false;
	end,
	IsRagdolled = function(p9)
		if p9:FindFirstChildOfClass("Humanoid") ~= nil then
			local v18 = p9:FindFirstChildOfClass("Humanoid");
			if v18:GetState() == Enum.HumanoidStateType.Physics or v18:GetState() == Enum.HumanoidStateType.Dead then
				return true;
			end;
		end;
		return false;
	end,
	IsGhost = function(p10)
		if p10:FindFirstChild("Ghost") ~= nil then
			return true;
		end;
		return false;
	end,
	GetSpecieColour = function(p12)
		return ({
			Vampires = { Color3.fromRGB(124, 0, 6), Color3.fromRGB(61, 0, 3) }, 
			Werewolves = { Color3.fromRGB(205, 128, 0), Color3.fromRGB(84, 33, 0) }, 
			Witches = { Color3.fromRGB(90, 0, 142), Color3.fromRGB(6, 0, 10) }, 
			Hybrids = { Color3.fromRGB(124, 0, 6), Color3.fromRGB(205, 128, 0) }, 
			Psychics = { Color3.fromRGB(0, 30, 62), Color3.fromRGB(0, 17, 34) }, 
			Sirens = { Color3.fromRGB(56, 132, 170), Color3.fromRGB(21, 34, 112) }, 
			Heretics = { Color3.fromRGB(124, 0, 6), Color3.fromRGB(90, 0, 142) }, 
			Tribrids = { Color3.fromRGB(90, 0, 142), Color3.fromRGB(124, 0, 6), Color3.fromRGB(205, 128, 0) }, 
			Quadrabrids = { Color3.fromRGB(90, 0, 142), Color3.fromRGB(38, 127, 0), Color3.fromRGB(124, 0, 6), Color3.fromRGB(205, 128, 0) }, 
			Phoenix = { Color3.fromRGB(255, 147, 0), Color3.fromRGB(130, 29, 3) }, 
			Ghost = { Color3.fromRGB(127, 159, 255), Color3.fromRGB(255, 255, 255) }, 
			Rippers = { Color3.fromRGB(124, 0, 6), Color3.fromRGB(61, 0, 3) }, 
			Originals = { Color3.fromRGB(124, 0, 6), Color3.fromRGB(61, 0, 3) }, 
			UpgradedOriginals = { Color3.fromRGB(124, 0, 6), Color3.fromRGB(61, 0, 3) }, 
			Siphoners = { Color3.fromRGB(90, 0, 142), Color3.fromRGB(6, 0, 10) }, 
			Werewitches = { Color3.fromRGB(205, 128, 0), Color3.fromRGB(90, 0, 142) }, 
			Werephoners = { Color3.fromRGB(205, 128, 0), Color3.fromRGB(90, 0, 142) }, 
			Mortals = { Color3.fromRGB(38, 127, 0), Color3.fromRGB(19, 63, 0) },
			TimeLords = { Color3.fromRGB(38, 127, 0), Color3.fromRGB(255, 158, 3) },
			TransitioningTribrid = { Color3.fromRGB(38, 127, 0), Color3.fromRGB(19, 63, 0), Color3.fromRGB(90, 0, 142), Color3.fromRGB(124, 0, 6), Color3.fromRGB(205, 128, 0) }, 
			TransitioningQuadrabrid = { Color3.fromRGB(38, 127, 0), Color3.fromRGB(19, 63, 0), Color3.fromRGB(90, 0, 142), Color3.fromRGB(124, 0, 6), Color3.fromRGB(205, 128, 0) },
			TransitioningHeretic = { Color3.fromRGB(38, 127, 0), Color3.fromRGB(19, 63, 0), Color3.fromRGB(124, 0, 6), Color3.fromRGB(90, 0, 142) }, 
			TransitioningVampire = { Color3.fromRGB(38, 127, 0), Color3.fromRGB(19, 63, 0), Color3.fromRGB(124, 0, 6), Color3.fromRGB(61, 0, 3) }, 
			TransitioningHybrid = { Color3.fromRGB(38, 127, 0), Color3.fromRGB(19, 63, 0), Color3.fromRGB(124, 0, 6), Color3.fromRGB(205, 128, 0) }
		})[p12] or { Color3.fromRGB(255, 255, 255) };
	end,
	IsACharacter = function(OBJ: Instance)
		local currInstance = OBJ
		local player
		repeat
			player = Players:GetPlayerFromCharacter(currInstance)
			if not player then
				currInstance = currInstance.Parent
			end		
		until player or not currInstance
		return currInstance :: Model?
	end,
	devCheck = function(plr)
		if not plr then
			return;
		end;
		for v16, v17 in pairs({ "Nicolas", "Deceptive", "Luna", "Alper", "Emma Malory", "Forbidden Pan" }) do
			local CharacterConfiguration = plr:FindFirstChild("CharacterConfiguration")
			if CharacterConfiguration then
				if CharacterConfiguration.CharacterName.Value == v17 then
					if plr.UserId ~= 0 then
						return true
					end
				end
			end
		end;
		return false;
	end,
	ServerHasGamepass = function(plr, charName)
		local isCustomAllowed = _G[`{plr.Name}-{charName}`]
		if isCustomAllowed ~= nil then return isCustomAllowed end
		if (_G.CustomsConfig[charName] or {}).IsWhitelist then
			isCustomAllowed = table.find(_G.CustomsConfig[charName].People, plr.UserId) ~= nil
		else
			isCustomAllowed = (table.find(_G.GlobalCustomsAccessList, plr.UserId) ~= nil) or table.find((_G.CustomsConfig[charName] or {}).People or {}, plr.UserId) ~= nil
		end
		_G[`{plr.Name}-{charName}`] = isCustomAllowed
		return isCustomAllowed
	end,
};

function v1.HasGamepass(plr, charName)
	local MarketplaceService = game:GetService("MarketplaceService")
	local v79 = true
	local charConfig = CharacterConfiguration[charName]
	if charConfig.GamepassLocked == true then
		local isCustomAllowed = false
		if IsClient then
			if _G[`Has{charName}Access`] == nil then 
				_G[`Has{charName}Access`] = ReplicatedStorage.RemoteEvents.HasCustomAccess:InvokeServer(charName)
			end
			isCustomAllowed = _G[`Has{charName}Access`]
		else
			isCustomAllowed = v1.ServerHasGamepass(plr, charName)
		end
		if isCustomAllowed then
			v79 = true
		elseif plr:GetRankInGroup(279354262) > 253 then
			v79 = true
		elseif type(charConfig.GamepassId) == "table" then
			v79 = false
			for i,v in ipairs(charConfig.GamepassId) do
				if MarketplaceService:UserOwnsGamePassAsync(plr.UserId, v) then
					v79 = true
					break
				end
			end
			if not v79 and IsClient then
				MarketplaceService:PromptGamePassPurchase(plr, charConfig.GamepassId[1])
			end
		elseif not MarketplaceService:UserOwnsGamePassAsync(plr.UserId, charConfig.GamepassId) then
			v79 = false
			if IsClient then
				MarketplaceService:PromptGamePassPurchase(plr, charConfig.GamepassId)
			end
		end
	end
	return v79
end

function v1.Dessicate(CharAffected: Model,Value: boolean, Time: number?, WithoutSound: boolean?)
	Time = Time or 2.5
	local Character = CharAffected
	local VictimPlayer = game.Players:GetPlayerFromCharacter(Character)
	local CharacterConfigFolder = VictimPlayer:FindFirstChild("CharacterConfiguration")
	if CharacterConfigFolder ~= nil then
		local CharacterName = CharacterConfigFolder.CharacterName.Value
		local OutfitName = CharacterConfigFolder.OutfitName.Value
		if Character ~= nil then
			if Value == true then
				Character.Head.Face.Texture = CharacterConfiguration[CharacterName].Outfits[OutfitName].SleepFace
				if not WithoutSound then
					local SoundDessicate = ReplicatedStorage.ReplicatedAssets.VampireAssets.Sounds.VampireActions.Dessicate:Clone()
					SoundDessicate.Parent = Character.Head
					SoundDessicate.Ended:Once(function()
						SoundDessicate:Destroy()
					end)
					SoundDessicate:Play()
				end
				if Character:FindFirstChild("Transformed") then return end
				for i,part in pairs(Character:GetDescendants()) do
					if (part:IsA("Part") or part:IsA("MeshPart")) and not part:FindFirstChild("Skirt") then
						GetTweenCreate(part,TweenInfo.new(Time),{Color = Color3.fromRGB(187, 179, 178)}):Play()
					end
				end
				if v1.IsSpecie(VictimPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Hybrids","Heretics","Tribrids", "Quadrabrids"}) == true then
					task.delay(4.5,function()
						Character.Head.Face.Texture = CharacterConfiguration[CharacterName].Outfits[OutfitName].DessicatedFace
					end)
				end
			else	
				--if  Character.Humanoid.Health == 0 or Character.Humanoid:GetState() == Enum.HumanoidStateType.Physics or Character.Humanoid:GetState() == Enum.HumanoidStateType.Dead then return end
				if Character:FindFirstChild("Transformed") then return end
				local z
				local custom = CharacterConfigFolder:FindFirstChild("isCustom")
				if custom then
					local skincol = custom:FindFirstChild("SkinCol")
					if skincol then
						for i,part in pairs(Character:GetDescendants()) do
							if (part:IsA("Part") or part:IsA("MeshPart")) and not part:FindFirstChild("Skirt") then
								GetTweenCreate(part,TweenInfo.new(Time),{Color = skincol.Value}):Play()
							end
						end
					end
				else
					if CharacterConfiguration[CharacterName].Outfits[OutfitName].BodyColor ~= nil then
						z = CharacterConfiguration[CharacterName].Outfits[OutfitName].BodyColor
						for i,part in pairs(Character:GetDescendants()) do
							if (part:IsA("Part") or part:IsA("MeshPart")) and not part:FindFirstChild("Skirt") then
								GetTweenCreate(part,TweenInfo.new(Time),{Color = z.Value}):Play()
							end
						end
					end
				end
				task.delay(2.5,function()
					Character.Head.Face.Texture = CharacterConfiguration[CharacterName].Outfits[OutfitName].Face.Texture
				end)
			end
		end
	end
end

return v1;

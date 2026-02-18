local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local EventsFolder = ReplicatedStorage.RemoteEvents
local PlayerInteractionEvent = EventsFolder.PlayerInteraction
local PlayerInteractionEventServer = EventsFolder.PlayerInteractionServer
local ClientAnimationEvent  = EventsFolder.AnimationClientEvent
local ModulesFolder = ServerScriptService.Modules
local PlayerInteractionModule = require(ModulesFolder.PlayerInteractionModule)
local blinkEvent = EventsFolder.Blink
local MessageEvent = EventsFolder.ReceivedMessage
local StatEvent = EventsFolder.StatCheck
local WitchSpellEvent = EventsFolder.WitchSpell
local ReplicatedModulesClient = ReplicatedStorage.ReplicatedModules
local TweenModule = require(ReplicatedModulesClient.ReplicatedTweening)
local SpellConfigurationModule = require(ReplicatedModulesClient.SpellsConfiguration)
local MorphHandler = require(ReplicatedModulesClient.MorphHandler)
local CharacterList = require(ReplicatedModulesClient.CharacterConfiguration)
local FXModule = require(ReplicatedModulesClient.FXModule)
local NotificationHandler = require(game.ServerScriptService.MainUI.NotificationHandler)
local RagdollRemoteEvent = ReplicatedStorage.RemoteEvents.Ragdoll
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local tvlServerUtil = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("tvlServerUtil"))
local tvlReplicatedUtil = require(ReplicatedModulesClient:WaitForChild("tvlReplicatedUtil"))
local FactionUtils = require(game.ServerScriptService.Modules.FactionUtils)

_G.GetCharacterRankInfo = function(player: Player)
	local FactionDisplay = FactionUtils.GetFactionDisplayName(player)
	local isLeader = FactionDisplay and string.find(FactionDisplay, "Leader") ~= nil
	
	local isOwner = table.find({ 0, 7711911407 }, player.UserId)
	local isCoOwner =   table.find({ 3395958157, 3447571200, 3368530928 }, player.UserId)
	local isCommunityManager =   table.find({ 0 }, player.UserId)
	local isDeveloper = table.find({ 429173694, 0 }, player.UserId)
	local isSeniorAdministrator = table.find({ 2779962153, 0 }, player.UserId)
	local isAdministrator =   table.find({ 5004931846, 0 }, player.UserId)
	local isSeniorModerator = table.find({ 5004931846, 0 }, player.UserId)
	local isModerator = table.find({ 3608635407, 0, 0 }, player.UserId)
	
	local PowerRank = if isOwner then "Owner" else if isCoOwner then "Co-Owner" else if isModerator then "Moderator" else if isAdministrator then "Administrator" else if isSeniorModerator then "Senior Moderator" else if isSeniorAdministrator then "Senior Administrator" else if isDeveloper then "Developer" else if isCommunityManager then "Community Manager" else nil
	
	if not PowerRank and isLeader then
		PowerRank = "Leader"
	end
	
	return FactionDisplay, PowerRank
end

_G.CustomsConfig = {
	["Forbidden Pan"] = {
		IsWhitelist = true,
		People = { 429173694, 7711911407 }
	},
	["Inadu Labonair"] = {
		People = { 429173694, 7711911407, 3368530928 }
	},
	["Daisy"] = {
		People = { 3608635407, 3368530928 }
	},
	["Dahlia Hagen"] = {
		People =  { 429173694, 7711911407}
	},
	["Deceptive"] = {
		People =  { 2779962153, 5004931846, 3368530928 }
	},
	["Sara Labonair"] = {
		People =  { 429173694, 5004931846, 3368530928 }
	},
	["Luna"] = {
		People =  { 1557611409, 3368530928 }
	},
	["Nicolas"] = {
		People =  { 429173694, 7711911407 }
	},
	["Emma Malory"] = {
		People =  { 3395958157, 3368530928}
	},
	["Freya"] = {
		People =  { 429173694, 7711911407, 3368530928 }
	}
}

_G.GlobalCustomsAccessList = {429173694, 3447571200, 7711911407, 0, 0, 0, 0 ,0, 0}

_G.CooldownSpells = {}

--[[
local function CheckDistance(OBJ1,OBJ2)
	return (OBJ1.Position - OBJ2.Position).Magnitude
end
--]]

--oh god
local IsACharacter = tvlServerUtil.IsACharacter
local IsRagdolled = tvlServerUtil.IsRagdolled
local IsGhost = tvlServerUtil.IsGhost

local function IsACorpse(OBJ)
	if OBJ.Parent:FindFirstChildOfClass("Humanoid") ~= nil or (OBJ.Parent:IsA("Accessory") and OBJ.Parent.Parent:FindFirstChildOfClass("Humanoid") ~= nil) then
		local Target = OBJ.Parent
		if Target:FindFirstChild("CorpseValue") ~= nil then
			return Target
		end
	end
end
local function GetPlayer(OBJ)
	local Player = Players:GetPlayerFromCharacter(OBJ)
	if Player ~= nil then
		return Player
	end
end
local function PlayerConnected(Player)
	_G.CooldownSpells[Player.Name] = {}
	for Name,Table in pairs(SpellConfigurationModule) do
		_G.CooldownSpells[Player.Name][Name] = true
	end
end
local function PlayerDisconnected(Player)
	task.wait(5)
	_G.CooldownSpells[Player.Name] = nil 
end
game.Players.PlayerAdded:Connect(PlayerConnected)
game.Players.PlayerRemoving:Connect(PlayerDisconnected)
function safeClone(instance)
	local oldArchivable = instance.Archivable

	instance.Archivable = true
	local clone = instance:Clone()
	instance.Archivable = oldArchivable

	return clone
end
function Unclone(instance)

	instance.Archivable = false

	return instance
end


local function RandomSpecie(ply)
	if ply:FindFirstChild("SpawnFolder") then
		local tab = {}
		for i,v in pairs(ply.SpawnFolder:GetChildren()) do
			tab[#tab+1] = v.Specie.Value
		end
		if #tab == 1 then
			print("only one entry")
			return tab[1]
		else
			print("multiple entries")
			return tab[math.random(1, #tab)]
		end
	else
		local noPassSpecieTable = {
			{specie = "Mortals", rate = 1},
			{specie = "Werewolves", rate = 40},
			{specie = "Witches", rate = 90},
		}
		local endResult = {}
		math.randomseed(tick())
		for _, data in pairs(noPassSpecieTable) do
			for c = 1, data.rate, 1 do
				table.insert(endResult,(data.specie))
			end
		end

		local chosenIndex= math.random(1, #endResult)
		local chosen = endResult[chosenIndex]

		if chosen == "Witches" then
			local newran = math.random(1,100)
			if newran == 2 then
				chosen = "Siphoners"
			end
		elseif chosen == "Werewolves" then
			local newran = math.random(1,100)
			if newran == 2 then
				chosen = "Werewitches"
			end
		end
		return chosen
	end
end

local DarkJosieFace = tvlServerUtil.DarkJosieFace
local IsSpecie = tvlServerUtil.IsSpecie

local Doors = workspace.Doors:GetDescendants()
for i,instance in pairs(workspace.Doors:GetChildren()) do
	local Attachment = Instance.new("Attachment")
	Attachment.Parent = instance.radius
	local ProximityPrompt = Instance.new("ProximityPrompt")
	ProximityPrompt.Parent = Attachment
	ProximityPrompt.HoldDuration = 0.4
	ProximityPrompt.KeyboardKeyCode = Enum.KeyCode.B
	ProximityPrompt.RequiresLineOfSight = false
	ProximityPrompt.ObjectText = "Door"
	ProximityPrompt.ActionText = "Open or Close"
end
task.spawn(function()
	local rayDirection
	task.spawn(function()
		game.Lighting:GetPropertyChangedSignal("TimeOfDay"):Connect(function()
			rayDirection = game.Lighting:GetSunDirection()
		end)
	end)
	game:GetService("RunService").Heartbeat:Connect(function()
		local ct = game.Lighting.ClockTime
		if (ct >= 6 or ct <= 18) then
			for i,player in pairs(game.Players:GetPlayers()) do
				task.spawn(function()
					if player.Character == nil then return end
					if player.Character:FindFirstChild("HumanoidRootPart") == nil then return end
					if player:FindFirstChild("CharacterConfiguration") == nil then return end 
					if player.CharacterConfiguration.Specie.Value ~= "Vampires" and player.CharacterConfiguration.Specie.Value ~= "Originals" and player.CharacterConfiguration.Specie.Value ~= "UpgradedOriginals" and player.CharacterConfiguration.Specie.Value ~= "Rippers" then return end
					if player.CharacterConfiguration.CharacterName.Value == "Niklaus Mikaelson" then return end
					if player.Character:FindFirstChild("VampireStats") == nil then return end
					if player.Character:FindFirstChildOfClass("Humanoid") == nil then return end
					if player:FindFirstChild("Ghost") ~= nil then return end
					local success, response = pcall(function()
						if player.Character.VampireStats.HasRing.Value then return end
						if player.Character.Humanoid.Health == 0 then return end
						local params = RaycastParams.new()
						local tab = {}
						for i,v in pairs(workspace.AmbientAreas:GetDescendants()) do
							if v:IsA("BasePart") and tab[v] == nil then
								tab[#tab+1] = v
								tab[v] = true
							end
						end
						params.FilterDescendantsInstances = tab
						params.FilterType = Enum.RaycastFilterType.Exclude
						local partFound = workspace:Raycast(player.Character.Head.Position,rayDirection * 100, params)
						local char = player.Character or player.CharacterAdded:Wait()
						if not partFound then --player is in sun, can take dmg
							if char:FindFirstChild("IsBurningSun") then return end	
							if not char.HumanoidRootPart:FindFirstChild("BurningSound") then
								local Sound = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds.Fire:Clone()
								if Sound then
									Sound.Parent = char.HumanoidRootPart
									Sound.Volume = 1.5
									Sound.Name = "BurningSound"
									Sound.Looped = true
									Sound.Playing = true
								end
							else	
								if not char.HumanoidRootPart.BurningSound.Playing then
									char.HumanoidRootPart.BurningSound.Playing = true
								end
							end
							local BurningSun = Instance.new("BoolValue")
							BurningSun.Name = "IsBurningSun"
							BurningSun.Parent = char
							task.spawn(function()
								while char:FindFirstChild("IsBurningSun") ~= nil and not char.VampireStats.HasRing.Value do
									tvlServerUtil.TakeDamage(char, 4, true)
									task.wait(0.3)
								end
								if char.VampireStats.HasRing.Value then
									if BurningSun ~= nil then
										BurningSun:Destroy()
									end
									if char.HumanoidRootPart:FindFirstChild("BurningParticle") then
										for i,instance in pairs(char.HumanoidRootPart:GetChildren()) do
											if instance:IsA("ParticleEmitter") then
												local intval = Instance.new("IntValue",instance)
												intval.Name = "RateVal"
												intval.Value = instance.Rate
												TweenModule:Create(instance,TweenInfo.new(2),{Rate = 0}):Play()
											elseif instance:IsA("Light") then	
												TweenModule:Create(instance,TweenInfo.new(2),{Brightness = 0,Range = 0}):Play()
											end
										end
									end 
								end
							end)
							if not char.HumanoidRootPart:FindFirstChild("BurningParticle") and not char.VampireStats.HasRing.Value then
								local test= Instance.new("Folder",char.HumanoidRootPart)
								test.Name = "BurningParticle"
								for i,particle in pairs(game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects.FireCircleParticleGroup:GetChildren()) do
									particle:Clone().Parent = char.HumanoidRootPart
								end
							else
								for i,instance in pairs(char.HumanoidRootPart:GetChildren()) do
									if instance:IsA("ParticleEmitter") then
										if instance:FindFirstChild("RateVal") then
											TweenModule:Create(instance,TweenInfo.new(2),{Rate = instance.RateVal.Value}):Play()
										end
									elseif instance:IsA("Light") then	
										TweenModule:Create(instance,TweenInfo.new(2),{Brightness = 15,Range = 4.06}):Play()
									end
								end
							end
						else	--player is safe
							if char.HumanoidRootPart:FindFirstChild("BurningParticle") then
								for i,instance in pairs(char.HumanoidRootPart:GetChildren()) do
									if instance:IsA("ParticleEmitter") then
										local intval = Instance.new("IntValue",instance)
										intval.Name = "RateVal"
										intval.Value = instance.Rate
										if instance then
											--	TweenModule:Create(instance,TweenInfo.new(2),{Rate = 0}):Play() 
											--bro i have no clue why this errors i do NOT see the issue with it T_T 
											local tw = TweenService:Create(instance,TweenInfo.new(1),{Rate = 0})
											tw:Play()
											tw.Completed:Connect(function()
												instance:Destroy()
											end)
											--	instance.Rate = 0
										end
									elseif instance:IsA("Light") then	
										if instance then
											--TweenModule:Create(instance,TweenInfo.new(2),{Brightness = 0,Range = 0}):Play()
											--bro i have no clue why this errors i do NOT see the issue with it T_T 
											--instance.Brightness = 0 
											--instance.Range = 0
											local tw2 = TweenService:Create(instance,TweenInfo.new(1),{Brightness = 0,Range = 0})
											tw2:Play()
											tw2.Completed:Connect(function()
												instance:Destroy()
											end)
										end
									end
								end
								char.HumanoidRootPart:FindFirstChild("BurningParticle"):Destroy()
							end
							if char.HumanoidRootPart:FindFirstChild("BurningSound") then if char.HumanoidRootPart.BurningSound.Playing then char.HumanoidRootPart.BurningSound.Playing = false end end
							if char:FindFirstChild("IsBurningSun") then char.IsBurningSun:Destroy() end	
						end
					end)
					if not success then
						print("ilt; error .. ".. response)
					end
				end)
			end
		end
	end)
end)
local Interactions
Interactions = {
	["Damage"] = function(Character,TupleTable)
		if type(TupleTable.Damage) == "number" then
			TupleTable.Damage = math.abs(TupleTable.Damage)
			Character.Health.Value -= TupleTable.Damage
			tvlServerUtil.TakeDamage(Character, TupleTable.Damage)
		end
	end,
	["DrainWolfEnergy"] = function(Character,TupleTable)
		local Player = game.Players:GetPlayerFromCharacter(Character)
		if type(TupleTable.Energy) == "number" then
			if (Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Jumping or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.FallingDown or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Freefall or Player.Character:FindFirstChild("xrCheck")) and (Player.Character:FindFirstChild("WolfStats")) then
				TupleTable.Energy = math.abs(TupleTable.Energy)
				TweenModule:GetTweenObject(Character.WolfStats.Energy,TweenInfo.new(0.5),{Value = math.clamp(Character.WolfStats.Energy.Value - TupleTable.Energy,0,Character.WolfStats.MaxEnergy.Value)}):Play()
			end
		end
	end,
	["Notification"] = function(Character,TupleTable)
		NotificationHandler.Notification(TupleTable.Player,TupleTable.Message)
	end,
	["EnergyCheck"] = function(Character,TupleTable)
		local Player = game.Players:GetPlayerFromCharacter(Character)
		if TupleTable.Option == "ON" then
			if not Character:FindFirstChild("xrCheck") then
				local xr = Instance.new("IntValue")
				xr.Name = "xrCheck"
				xr.Parent = Character
			end
		else
			local xr = Character:FindFirstChild("xrCheck")
			if xr then
				xr:Destroy()
			end
		end
	end,
	["DrainVampEnergy"] = function(Character,TupleTable)
		local Player = game.Players:GetPlayerFromCharacter(Character)
		if type(TupleTable.Energy) == "number" then
			if (Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Jumping or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.FallingDown or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Freefall or Player.Character:FindFirstChild("xrCheck")) and (Player.Character:FindFirstChild("VampireStats")) then
				TupleTable.Energy = math.abs(TupleTable.Energy)
				TweenModule:GetTweenObject(Character.VampireStats.Energy,TweenInfo.new(0.5),{Value = math.clamp(Character.VampireStats.Energy.Value - TupleTable.Energy,0,Character.VampireStats.MaxEnergy.Value)}):Play()
			end
		end	
	end,
	["ChangeOptionValue"] = function(Character,TupleTable)
		local Player = GetPlayer(Character)
		local SaveFile = ReplicatedStorage.PlayerData:FindFirstChild(Player.Name)
		if SaveFile ~= nil then
			if SaveFile:FindFirstChild(TupleTable.ValueName) ~= nil then
				SaveFile[TupleTable.ValueName].Value = not SaveFile[TupleTable.ValueName].Value
			end
		end
	end,
	["PhoenixAction"] = function(Character,TupleTable)
		local Player = GetPlayer(Character)
		local ReplicatedAssets = ReplicatedStorage.ReplicatedAssets 
		if tvlServerUtil.IsSpecie(Player, { "Phoenix","PyroWitches" }) then
			local function GetPhoenixStats()
				if Character:FindFirstChild("PhoenixStats") ~= nil then
					return Character.PhoenixStats
				end
			end
			local function GetEnergy(Stats)
				if Stats:FindFirstChild("Energy") ~= nil then
					return Stats.Energy.Value
				end
			end
			local function DrainEnergy(Stats,Value)
				if Stats:FindFirstChild("Energy") ~= nil then
					Stats.Energy.Value = math.clamp(Stats.Energy.Value - Value,0,Stats.MaxEnergy.Value)
				end
			end
			local function EnableWing()
				local FlyVal = Instance.new("IntValue",Character)
				FlyVal.Name = "Flying"
				local Anim = Instance.new("Animation")
				Anim.AnimationId = "rbxassetid://99931708378963"
				local AnimTrack = Character.Wing1.AnimationController.Animator:LoadAnimation(Anim)
				AnimTrack:Play()
				Anim.AnimationId = "rbxassetid://86395504088817"
				local AnimTrack2 = Character.Wing2.AnimationController.Animator:LoadAnimation(Anim)
				AnimTrack2:Play()
				Anim:Destroy()
				local Sound = Instance.new("Sound",Character.HumanoidRootPart)
				Sound.Name = "PhoenixFire3"
				Sound.Volume = 3
				Sound.SoundId = "rbxassetid://2107320371"
				Sound:Play()
				Sound.Looped = true
				local SoundFire = ReplicatedAssets.WitchesAssets.Sounds.Fire:Clone()
				SoundFire.Name = "PhoenixFire1"
				SoundFire.Volume = 1
				SoundFire.Parent = Character.HumanoidRootPart
				SoundFire.Looped = true
				SoundFire:Play()
				local Activated = ReplicatedAssets.WitchesAssets.Sounds.NormalCast:Clone()
				Activated.Name = "PhoenixFire2"
				Activated.Volume = 1
				Activated.Parent = Character.HumanoidRootPart
				Activated:Play()
				Character.Wing1.Wing.Material,Character.Wing1.Wing.Transparency = Enum.Material.Neon,0
				Character.Wing2.Wing.Material,Character.Wing2.Wing.Transparency  = Enum.Material.Neon,0
			end
			local function FlyingValExists()
				if Character:FindFirstChild("Flying") ~= nil then
					return true
				else
					return false
				end
			end
			local function DeleteFlyingValue()
				if FlyingValExists() == true then
					Character.Flying:Destroy()
				end
			end
			local function DisableWing()
				local function SoundExists(StringOfTheSound)
					if Character.HumanoidRootPart:FindFirstChild(StringOfTheSound) ~= nil then
						return true
					end
				end
				Character.Wing1.Wing.Material,Character.Wing1.Wing.Transparency = Enum.Material.Brick,1
				Character.Wing2.Wing.Material,Character.Wing2.Wing.Transparency  = Enum.Material.Brick,1
				if SoundExists("PhoenixFire1") == true and SoundExists("PhoenixFire2") == true and SoundExists("PhoenixFire3") == true then
					local a = Character.HumanoidRootPart
					a.PhoenixFire1:Destroy() a.PhoenixFire2:Destroy() a.PhoenixFire3:Destroy()
					a = nil
				end
			end


			local PhoenixActions = {
				["FLY_ON"] = function()
					local Stats = GetPhoenixStats()
					if GetEnergy(Stats) == 0 then return end
					EnableWing()
					repeat 
						DrainEnergy(Stats,4)
						task.wait(0.5)
					until GetEnergy(Stats) == 0 or FlyingValExists() == false
					if FlyingValExists() == true then
						DeleteFlyingValue()
						DisableWing()
					end
				end,
				["FLY_OFF"] = function()
					if FlyingValExists() == true then
						DeleteFlyingValue()
						DisableWing()
					end
				end,
				["FIREBALL"] = function()
					if Character:FindFirstChild("Flying") == nil then return end
					if Character:FindFirstChild("Ghost") ~= nil then return end
					if Character:FindFirstChild("ThrowingFireBall") ~= nil then return end
					local FlyVal = Instance.new("IntValue",Character)
					FlyVal.Name = "ThrowingFireBall"
					coroutine.wrap(function()
						task.wait(2)
						FlyVal:Destroy()
					end)()
					local info = TweenInfo.new(0.5)
					local TweenService = game:GetService("TweenService")
					local FireBall = game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Phoenix.FireballAsset:Clone()
					local Explosion = Instance.new("Explosion")
					Explosion.ExplosionType = Enum.ExplosionType.NoCraters
					Explosion.DestroyJointRadiusPercent = 0
					Explosion.BlastRadius = 30
					Explosion.BlastPressure = 0
					Explosion.Hit:Connect(function(hit)
						if hit.CanCollide == false then return end
						if hit.Parent:FindFirstChildOfClass("Humanoid") == nil then return end
						if hit.Parent.Name == Player.Name then return end
						if game.Players:GetPlayerFromCharacter(hit.Parent) == nil then return end
						if hit.Parent:FindFirstChild("HitByFireball") ~= nil then return end
						local Val = Instance.new("IntValue",hit.Parent)
						Val.Name = "HitByFireball"
						tvlServerUtil.TakeDamage(hit.Parent, math.random(20, 50), true)
						if Player:FindFirstChild("Coins") then
							--Player.Coins.Value += math.random(9,14)
						end
						game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(game.Players:GetPlayerFromCharacter(hit.Parent),"ON")
						task.wait(3)
						game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(game.Players:GetPlayerFromCharacter(hit.Parent),"OFF")			
						Val:Destroy()
					end)
					local BodyVelocity = Instance.new("BodyVelocity",FireBall)
					BodyVelocity.MaxForce = Vector3.new(1e6,1e6,1e6)
					BodyVelocity.P = 5000
					local BodyForce = Instance.new("BodyForce",FireBall) -- to float
					BodyForce.Force = Vector3.new(0, 96.2, 0)
					local Animation = Instance.new("Animation")
					Animation.AnimationId = "rbxassetid://99055038860418"
					local AnimTrack = Character.Humanoid:LoadAnimation(Animation)
					AnimTrack:Play()
					task.wait(1.2)
					Animation:Destroy()
					if FireBall:FindFirstChild("Sound") then
						FireBall:FindFirstChild("Sound"):Play() 
					end
					local Ended = false
					task.spawn(function()	
						while FireBall ~= nil do
							BodyVelocity.Velocity = (game.ReplicatedStorage.RemoteEvents.RequesterPhoenix:InvokeClient(Player)*90)
							Explosion.Position = FireBall.Position
							task.wait()
						end			
					end)
					FireBall.Anchored = false
					FireBall.Parent = workspace 
					FireBall:SetNetworkOwner(Player)
					FireBall.CFrame = Character.HumanoidRootPart.CFrame * CFrame.new(0,8,-5)
					task.wait(.15)
					local t
					t = FireBall.Hitbox.Touched:Connect(function(hit)
						if hit.CanCollide == false then return end
						if hit.Parent:FindFirstChildOfClass("Humanoid") then
							if hit.Parent.Name ~= Player.Name then
								if game.Players:GetPlayerFromCharacter(hit.Parent) ~= nil then	
									if hit.Parent:FindFirstChild("Ghost") ~= nil then return end
									if game.Players[hit.Parent.Name].Influenced.Value == true then return end
									FireBall.Anchored = true
									FireBall.Explosion:Play()
									if t ~= nil then t:Disconnect() end
									TweenService:Create(FireBall.Flame,info,{Rate = 0}):Play()
									TweenService:Create(FireBall.Sparks,info,{Rate = 0}):Play()
									TweenService:Create(FireBall,info,{Transparency = 1}):Play()
									Ended = true
									task.spawn(function()
										game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(game.Players[hit.Parent.Name],"ON")
										local BV = Instance.new('BodyVelocity')
										BV.MaxForce = Vector3.new(math.huge,math.huge,math.huge)
										BV.Velocity = FireBall.CFrame.lookVector * 80
										BV.Name = "Tele"
										BV.Parent =  hit.Parent.UpperTorso
										game:GetService("Debris"):AddItem(BV, 0.7)	
										task.wait(3)
										game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(game.Players[hit.Parent.Name],"OFF")
									end)
									task.wait(4)
									FireBall:Destroy()
									FlyVal:Destroy()
								end
							end
						else
							if hit.Parent == FireBall then return end
							if hit.CanCollide == false or hit.Transparency == 1 then return end
							FireBall.Anchored = true
							Ended = true
							Explosion.Parent = FireBall
							FireBall.Explosion:Play()
							task.spawn(function()
								task.wait(4)
								FireBall:Destroy()
								FlyVal:Destroy()
							end)	
						end
					end)
					task.wait(5)
					if t ~= nil then t:Disconnect() end
					FireBall.Anchored = true
					if FireBall:FindFirstChild("Sound") then
						FireBall:FindFirstChild("Sound"):Stop()
					end
					for i,part in pairs(FireBall:GetChildren()) do
						if part:IsA("ParticleEmitter") or part:IsA("PointLight") then
							part.Enabled = false
						end
					end
					Ended = true
					task.spawn(function()
						task.wait(6)
						FireBall:Destroy()
					end)
				end,
			}
			for InteractionName,Function in pairs(PhoenixActions) do
				if InteractionName == TupleTable.Action then
					Function()
				end
			end
		end
	end,
	["InaduSpiritAction"] = function(Character,TupleTable)
		local Player = GetPlayer(Character)
		local ReplicatedAssets = ReplicatedStorage.ReplicatedAssets 
		local CharacterConfiguration = Player:FindFirstChild("CharacterConfiguration")
		if Character:FindFirstChild("SpiritFormTimeout") then return end
		local FakePlayer = { 
			CharacterConfiguration = CharacterConfiguration,
			FindFirstChild = function() return CharacterConfiguration end
		}
		if CharacterConfiguration ~= nil and tvlServerUtil.IsSpecie(FakePlayer, { "Witches", "Werephoners", "Quadrabrids","PyroWitches" }) and (CharacterConfiguration.CharacterName.Value == "Inadu Labonair" or CharacterConfiguration.CharacterName.Value == "Forbidden Pan") then
			local function GetWitchStats()
				if Character:FindFirstChild("WitchStats") ~= nil then
					return Character.WitchStats
				end
			end
			local function GetMagic(Stats)
				if Stats:FindFirstChild("Magic") ~= nil then
					return Stats.Magic.Value
				end
			end
			local function DrainMagic(Stats,Value)
				if Stats:FindFirstChild("Magic") ~= nil then
					Stats.Magic.Value = math.clamp(Stats.Magic.Value - Value,0,Stats.MaxMagic.Value)
				end
			end
			local function FlyingValExists()
				if Character:FindFirstChild("Flying") ~= nil then
					return true
				else
					return false
				end
			end
			local function CreateFlyingValue()
				if FlyingValExists() == false then
					local flying = Instance.new("IntValue")
					flying.Name = "Flying"
					flying.Parent = Character
				end
			end
			local function EnterSpirit()
				CreateFlyingValue()
				for i,part in Character:GetDescendants() do
					task.spawn(function()
						if part:IsA("BasePart") or part:IsA("Decal") then
							if part.Name ~= "HumanoidRootPart" and part.Name ~= "Phone" and part.Name ~= "PhoneCase" and part.Name ~= "Grimoire" and not part:FindFirstAncestor("Grimoire") and part.Name ~= "PanDress" then
								TweenModule:GetTweenObject(part,TweenInfo.new(0.4,Enum.EasingStyle.Quad),{Transparency = 1}):QueuePlay()

								--partTable[#partTable+1] = {Part = part.Name, OriginalPos = part.Position}

								while FlyingValExists() do task.wait() end

								TweenModule:GetTweenObject(part,TweenInfo.new(0.4,Enum.EasingStyle.Quad),{Transparency = 0}):QueuePlay()
							end
						elseif part:IsA("BillboardGui") then
							part.Enabled = false
							while FlyingValExists() do task.wait() end
							part.Enabled = true
						end
					end)
				end
				local attach = Instance.new("Attachment")
				attach.Name = "InaduSpirit"
				attach.Parent = Character.HumanoidRootPart
				ReplicatedAssets.WitchesAssets.Effects.InaduSpirit:Clone().Parent = attach
			end
			local function DeleteFlyingValue()
				if FlyingValExists() == true then
					Character.Flying:Destroy()
				end
			end
			local function ExitSpirit()
				DeleteFlyingValue()
				local eff = Character.HumanoidRootPart:FindFirstChild("InaduSpirit")
				eff.InaduSpirit.Enabled = false
				Debris:AddItem(eff, 5)
				local timeout = Instance.new("IntValue")
				timeout.Name = "SpiritFormTimeout"
				timeout.Parent = Character
				local sound = ReplicatedStorage.ReplicatedAssets.DLCFiles.Inadu.spiritform:Clone()
				sound.Parent = Character.Head
				sound:Play()
				Debris:AddItem(timeout, 8)
			end


			local InaduActions = {
				["FLY_ON"] = function()
					local Stats = GetWitchStats()
					if GetMagic(Stats) <= 0 then return end
					EnterSpirit()
					repeat 
						DrainMagic(Stats,6)
						task.wait(0.1)
					until GetMagic(Stats) <= 0 or FlyingValExists() == false
					if FlyingValExists() == true then
						ExitSpirit()
					end
				end,
				["FLY_OFF"] = function()
					if FlyingValExists() == true then
						ExitSpirit()
					end
				end,
			}
			local Function = InaduActions[TupleTable.Action]
			if Function then
				Function()
			end
		end
	end,
	["AgreeToRules"] = function(Character)
		local Player = GetPlayer(Character)
		local SaveFile = ReplicatedStorage.PlayerData:FindFirstChild(Player.Name)
		if SaveFile ~= nil then
			SaveFile.AgreedToRules.Value = true
		end
	end,
	["CheckWerewolf"] = function(Character,TupleTable)
		local Player = GetPlayer(Character)
		local ct = game.Lighting.ClockTime
		if Character:FindFirstChild("WolfVenom") then
			return
		end
		if TupleTable.Option == "CheckWerewolfTurn" then
			if Player:FindFirstChild("ForcedWolf") then return end
			if Character:FindFirstChild("Ghost") ~= nil then return end
			if IsSpecie(Player,{"Werewolves"}) == false then return end
			if Player:FindFirstChild("CooldownWolfTransformation") ~= nil then return end
			if Character:FindFirstChild("Influenced") ~= nil then return end
			if Character:FindFirstChild("DoingAbility") ~= nil then return end
			if Character:FindFirstChild("HasMoonlightRing") ~= nil then return end
			pcall(function()
				if Character.Humanoid.Health == 0 then return end
				if (ct <= 6 or ct >= 20) then
					if Player:FindFirstChild("Transformed") ~= nil then return end
					if Player:FindFirstChild("ForcedWolf") then return end
					if Player.CharacterConfiguration.CharacterName.Value == "Hope Mikaelson" and IsSpecie(Player, { "Tribrids" }) then return end
					if Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Jumping or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.FallingDown or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Freefall or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Swimming then return end
					PlayerInteractionModule.TurnIntoWerewolfForm(Player)
				elseif (ct >= 6 or ct <= 20) then
					if Player:FindFirstChild("Transformed") == nil then return end
					if Player:FindFirstChild("ForcedWolf") then return end
					if Player:FindFirstChild("GoingBackAsHuman") ~= nil then return end
					if Player.CharacterConfiguration.CharacterName.Value == "Hope Mikaelson" and IsSpecie(Player, { "Tribrids" }) then return end
					--if Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Jumping or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.FallingDown or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Freefall or Player.Character.Humanoid:GetState() == Enum.HumanoidStateType.Swimming then return end
					PlayerInteractionModule.TurnIntoHumanForm(Player)
				end
			end)
		elseif TupleTable.Option == "Turn" then
			if Character:FindFirstChild("Ghost") ~= nil then return end
			if IsSpecie(Player, {"TransitioningHybrid", "TransitioningTribrid", "TransitioningQuadrabrid"}) then return end
			if  IsSpecie(Player,{"Hybrids","Tribrids","Werewitches","Quadrabrids", "Werephoners","Originals","UpgradedOriginals"}) == true or Character:FindFirstChild("HasMoonlightRing") ~= nil or Player:FindFirstChild("ForcedWolf") then
				if  IsSpecie(Player,{"Originals","UpgradedOriginals"}) == true and Player.CharacterConfiguration.CharacterName.Value ~= "Niklaus Mikaelson" then return end
				if Player:FindFirstChild("CooldownWolfTransformation") ~= nil then return end
				if Player:FindFirstChild("Ghost") ~= nil then return end
				if Character:FindFirstChild("isTelek") ~= nil then return end
				if Player.CharacterConfiguration.CharacterName.Value == "Zara Malory" then NotificationHandler.Notification(Player,"Your werewolf side is bound by your own magic") return end
				if Character.Humanoid:GetState() == Enum.HumanoidStateType.Jumping or Character.Humanoid:GetState() == Enum.HumanoidStateType.FallingDown or Character.Humanoid:GetState() == Enum.HumanoidStateType.Freefall or Character.Humanoid:GetState() == Enum.HumanoidStateType.Swimming then return end
				if Player:FindFirstChild("Transformed") ~= nil then
					if TupleTable.Oper == "force" then
						NotificationHandler.Notification(Player, "A curse halts your will!")
						print("curzed")
					else  
						print("normalll")
						PlayerInteractionModule.TurnIntoHumanForm(Player)
					end
				elseif Player:FindFirstChild("Transformed") == nil and IsRagdolled(Character) == false then
					if TupleTable.Oper == "force" then
						print("curzed")
						NotificationHandler.Notification(Player, "A curse halts your will!")
					else 
						print("normalll")
						PlayerInteractionModule.TurnIntoWerewolfForm(Player)
						coroutine.wrap(function()
							task.wait(3)
							if Character:FindFirstChild("VampireStats") then
								TweenModule:GetTweenObject(Character.VampireStats.Energy,TweenInfo.new(3),{Value = math.clamp(Character.VampireStats.Energy.Value - 60,0,Character.VampireStats.MaxEnergy.Value)}):Play()
							end
							if Character:FindFirstChild("WolfStats") then
								TweenModule:GetTweenObject(Character.WolfStats.Energy,TweenInfo.new(3),{Value = math.clamp(Character.WolfStats.Energy.Value - 120,0,Character.WolfStats.MaxEnergy.Value)}):Play()
							end
						end)
					end

				end	
			end
		end
	end,
	["OtherSideOption"] = function(char,TupleTable)
		local Player = GetPlayer(char)
		local LastPosition
		if TupleTable.Pos == nil then
			LastPosition = char.HumanoidRootPart.CFrame
		else
			LastPosition = TupleTable.Pos
		end
		local CharacterConfiguration, CharName, OutfitName
		if TupleTable.Option ~= "respawn" then
			CharacterConfiguration = Player:FindFirstChild("CharacterConfiguration")
			if not CharacterConfiguration then return end
			CharName,OutfitName = CharacterConfiguration.CharacterName.Value,CharacterConfiguration.OutfitName.Value
		end
		if TupleTable.Option == "respawn" then
			Player:LoadCharacter()
		elseif TupleTable.Option == "Phoenix" then 
			if CharacterConfiguration.Specie.Value ~= "Phoenix" and CharacterConfiguration.Specie.Value ~= "PyroWitches" then
				Player:LoadCharacter()
			end

			--	task.wait(3)
			local SoundFire = ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds.Fire:Clone()
			SoundFire.Name = "SoundFire"
			SoundFire.Volume = 1
			SoundFire.Parent = char.HumanoidRootPart
			SoundFire.Looped = true
			SoundFire:Play()
			local Particle = ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects.IncendiaFire:Clone()
			Particle.Parent = char.HumanoidRootPart
			task.wait(3.2)
			SoundFire:Stop()
			SoundFire:Destroy()
			Particle:Destroy()
			local Smoke = Instance.new("Smoke",char.HumanoidRootPart)
			for i,part in pairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					TweenModule:GetTweenObject(part,TweenInfo.new(1.5),{Color = Color3.fromRGB(157, 157, 157)}):Play()
				end
			end
			task.wait(0.5)
			char.Head.Face.Texture = ""
			task.wait(2.5)
			local PhoenixDeath = Instance.new("IntValue",Player)
			PhoenixDeath.Name = "PhoenixDeath"
			Player:LoadCharacter()
			Debris:AddItem(PhoenixDeath, 6)
			char = (if Player.Character == char then nil else Player.Character) or Player.CharacterAdded:Wait()
			MorphHandler.Morph(char,CharName,OutfitName)
			char.HumanoidRootPart.CFrame = LastPosition
			char.HumanoidRootPart.Anchored = true
			char.Humanoid.WalkSpeed,char.Humanoid.JumpPower = 0,0
			local AnimationTrack = char.Humanoid.Animator:LoadAnimation(ReplicatedStorage.ReplicatedAssets.WerewolfAssets.Animations.ComingBackFromTransformation)
			AnimationTrack:Play()
			AnimationTrack.Stopped:Wait()
			AnimationTrack:Destroy()
			char.HumanoidRootPart.Anchored = false
			char.Humanoid.WalkSpeed,char.Humanoid.JumpPower = 16,50
			ClientAnimationEvent:FireClient(Player,nil,"camera_fix")
		elseif TupleTable.Option == "Regeneration" then 
			if CharacterConfiguration.Specie.Value ~= "TimeLords" then Player:LoadCharacter() end
			local PhoenixDeath = Instance.new("IntValue",Player)
			PhoenixDeath.Name = "PhoenixDeath"
			Player:LoadCharacter()
			Debris:AddItem(PhoenixDeath, 6)
			char = (if Player.Character == char then nil else Player.Character) or Player.CharacterAdded:Wait()
			local charConfigEntry = CharacterList[CharName].Outfits[OutfitName]
			MorphHandler.Morph(char,CharName,OutfitName)
			if charConfigEntry.IsRegen then
				CharacterList[CharName].Outfits[OutfitName] = nil
				ReplicatedStorage.RemoteEvents.UpdateCharConfig:FireClient(Player, "DELETE", CharName, OutfitName)
			end
			char.HumanoidRootPart.CFrame = LastPosition
			char.HumanoidRootPart.Anchored = true
			char.Humanoid.WalkSpeed,char.Humanoid.JumpPower = 0,0
			local IsProjecting = Instance.new("Folder")
			IsProjecting.Name = "IsProjecting"
			IsProjecting.Parent = char

			local Powerless = Instance.new("Folder")
			Powerless.Name = "Powerless"
			Powerless.Parent = char

			local Influenced = Instance.new("Folder")
			Influenced.Name = "Influenced"
			Influenced.Parent = char
			task.wait(1)
			local animation = Instance.new("Animation")
			animation.AnimationId = "rbxassetid://85129012996574"
			local AnimationTrack = char.Humanoid.Animator:LoadAnimation(animation)
			animation:Destroy()
			AnimationTrack:Play()
			task.wait(0.6)
			
			local assets = ReplicatedStorage.ReplicatedAssets.CharacterFiles
			local hairs = assets.HairMeshes:GetChildren()
			local hair = hairs[math.random(1, #hairs)]:Clone()
			local RIGHT_ACC = Vector3.new(18, 0, 0)
			local LEFT_ACC = RIGHT_ACC * -1
			local particles = {}
			local fireColor = Color3.fromRGB(255, 158, 3)
			local fireColorSequence = ColorSequence.new(fireColor)
			for _, particle in game.ReplicatedStorage.FireParticle:GetChildren() do
				local headParticle = particle:Clone()
				headParticle.Parent = char.Head
				
				local rightParticle = particle:Clone()
				rightParticle.Parent = char.RightHand
				
				local leftParticle = particle:Clone()
				leftParticle.Parent = char.LeftHand
				
				if particle:IsA("ParticleEmitter") then
					rightParticle.Acceleration += RIGHT_ACC
					leftParticle.Acceleration += LEFT_ACC
					headParticle.Color = fireColorSequence
					rightParticle.Color = fireColorSequence
					leftParticle.Color = fireColorSequence
				elseif particle:IsA("Light") then
					headParticle.Color = fireColor
					rightParticle.Color = fireColor
					leftParticle.Color = fireColor
				end
				table.insert(particles, headParticle)
				table.insert(particles, rightParticle)
				table.insert(particles, leftParticle)
			end
			
			local info = TweenInfo.new(3, Enum.EasingStyle.Linear)
			

			local skinColors = {}

			for _, color in assets.BodyColor:GetChildren() do
				if color.Name == "Scream" or color.Name == "PureWhite" then continue end
				table.insert(skinColors, color)
			end

			local skinColor = skinColors[math.random(1, #skinColors)]
			
			for _, des in char:GetDescendants() do
				if not des:IsA("BasePart") or des:FindFirstAncestorOfClass("Accessory") or des:FindFirstAncestorOfClass("Tool") then continue end
				TweenModule:GetTweenObject(des, info, { Color = skinColor.Value }):Play()
			end
			
			for _, acc in char:GetChildren() do
				if not acc:IsA("Accessory") then continue end
				for _, p in acc:GetDescendants() do
					if not p:IsA("BasePart") and not p:IsA("Decal") then continue end
					TweenModule:GetTweenObject(p, info, { Transparency = 1 }):Play()
				end
				Debris:AddItem(acc, info.Time * 2)
			end
			for _, p in hair:GetDescendants() do
				if not p:IsA("BasePart") and not p:IsA("Decal") then continue end
				local trans = p.Transparency
				p.Transparency = 1
				TweenModule:GetTweenObject(p, info, { Transparency = trans }):Play()
			end
			MorphHandler.addAccessory(char, hair)
			
			local shirts = assets.Shirts:GetChildren()
			local shirt = shirts[math.random(1, #shirts)] :: Shirt
			local pantss = assets.Pants:GetChildren()
			local pants = pantss[math.random(1, #pantss)] :: Pants
			local oldShirt = char:FindFirstChildOfClass("Shirt")
			local oldPants = char:FindFirstChildOfClass("Pants")
			task.delay(info.Time, function()
				oldShirt.ShirtTemplate = shirt.ShirtTemplate
				oldPants.PantsTemplate = pants.PantsTemplate
				TweenModule:GetTweenObject(oldShirt, info, { Color3 = shirt.Color3 }):Play()
				TweenModule:GetTweenObject(oldPants, info, { Color3 = pants.Color3 }):Play()
			end)
			
			local animateScript = char:WaitForChild("Animate")
			local gender = if math.random(1, 2) == 1 then "Male" else "Female"
			if gender == "Female" then
				animateScript.run.RunAnim.AnimationId = "rbxassetid://123207388272646" 
				animateScript.idle.Animation1.AnimationId = "rbxassetid://134723507760425"
				animateScript.idle.Animation2.AnimationId = "rbxassetid://134723507760425"    
			else
				animateScript.run.RunAnim.AnimationId = "rbxassetid://81100283219821"
				animateScript.idle.Animation1.AnimationId = "rbxassetid://81643525319905"
				animateScript.idle.Animation2.AnimationId = "rbxassetid://81643525319905"
			end
			
			local regenOutfitName = game:GetService("HttpService"):GenerateGUID()
			
			local randomOutfitsMap = {}
			
			for charName, config in pairs(CharacterList) do
				if config.Gender ~= gender then continue end
				table.insert(randomOutfitsMap, config.Outfits)
			end
			
			local outfitsMap = randomOutfitsMap[math.random(1, #randomOutfitsMap)]
			local outfits = {}
			
			for _, outfit in pairs(outfitsMap) do
				table.insert(outfits, outfit)
			end
			
			local outfit = outfits[math.random(1, #outfits)]
			
			CharacterList[CharName].Outfits[regenOutfitName] = {
				Face = outfit.Face,
				Hair = {hair},
				Shirt = shirt,
				Pants = pants,
				BodyColor = skinColor,	
				DessicatedFace = outfit.DessicatedFace,
				BiteFace = outfit.BiteFace,
				SleepFace = outfit.SleepFace,		
				PossessedFace = outfit.PossessedFace,
				VampireFace = outfit.VampireFace,
				WolfFace = outfit.WolfFace,
				HybridFace = outfit.HybridFace,
				IsRegen = true
			}
			
			ReplicatedStorage.RemoteEvents.UpdateCharConfig:FireClient(Player, "CREATE", CharName, regenOutfitName, CharacterList[CharName].Outfits[regenOutfitName])
			
			char.Head.Face.Texture = outfit.Face.Texture
			
			Player.CharacterConfiguration.OutfitName.Value = regenOutfitName
			
			AnimationTrack.Stopped:Wait()
			for _, particle in particles do
				particle.Enabled = false
				Debris:AddItem(particle, 12)
			end
			AnimationTrack:Destroy()
			IsProjecting:Destroy()
			Influenced:Destroy()
			Powerless:Destroy()
			char.HumanoidRootPart.Anchored = false
			char.Humanoid.WalkSpeed,char.Humanoid.JumpPower = 16,50
			ClientAnimationEvent:FireClient(Player,nil,"camera_fix")
		elseif TupleTable.Option == "spirit" then	
			local isCustom = Player.CharacterConfiguration:FindFirstChild("isCustom")
			local isCoven = Player.CharacterConfiguration:FindFirstChild("isCoven")
			local cusgen, cusdisplayname, cuseyecol, cusspecie = Player.CharacterConfiguration.Gender.Value, nil, nil, nil
			if isCustom then
				cusdisplayname = isCustom.CusDisplayName.Value
				cuseyecol = isCustom.EyeColor.Value
			end
			cusspecie = Player.CharacterConfiguration.Specie.Value

			--Resurrection clone
			--[[
			local success,Error = pcall(function()
					local a
					a =Player.CharacterRemoving:Connect(function(deadChar)
						local Corpse = safeClone(deadChar)
						
						Corpse.Parent = workspace
						Corpse.Humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
					Corpse.Name = char.Name.."'s Corpse"
					local val = Instance.new("ObjectValue",Corpse)
					val.Name = "CorpseValue"
					val.Value = Player
					
					Corpse.UpperTorso.CFrame = Player.Character.UpperTorso.CFrame
					Corpse.Head.Face.Texture = CharacterList[CharacterName].Outfits[OutfitName].SleepFace
					RagdollRemoteEvent:FireClient(Player,"CorpseRagdoll")
					for i,v in pairs(Corpse:GetChildren()) do
						if v:IsA("BasePart") or v:IsA("MeshPart") then
							v.Anchored = true --trying to anchor corpse to make it stop getting up
						end
					end
					local revent = Corpse.Humanoid.StateChanged:Connect(function()
						if Corpse.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
							RagdollRemoteEvent:FireClient(Player,"CorpseRagdoll")
						end
						if Corpse.Humanoid:GetState() == Enum.HumanoidStateType.GettingUp then
							RagdollRemoteEvent:FireClient(Player,"CorpseRagdoll")
						end
					end)
					
					local delete = Player.CharacterRemoving:Connect(function()
						revent:Disconnect()
						a:Disconnect()
						Corpse:Destroy()
				Unclone(char)
					end)
						a:Disconnect()
					end)
			end)
			if success then
				warn("Cloned body with no issues!")
			else	
				warn("Failed to clone body, error: "..Error)
			end]]
			--ends here
			task.spawn(function()
				FXModule.FadeWhite(Player, 0.5, 2)
			end)
			task.wait(1.5)
			local oldChar = Player.Character
			Player:LoadCharacter()
			local newChar = (if Player.Character == oldChar then nil else Player.Character) or Player.CharacterAdded:Wait()
			local GhostValue = Instance.new("IntValue")
			GhostValue.Name = 'Ghost'
			GhostValue.Parent = newChar

			if isCustom then
				MorphHandler.MorphCustom(newChar, cusgen, cusdisplayname, cuseyecol, cusspecie)
			elseif isCoven then
				MorphHandler.MorphCoven(newChar, cusgen)
			else
				--MorphHandler.Morph(newChar,CharName,OutfitName, nil, cusspecie) - keep specie
				MorphHandler.Morph(newChar,CharName,OutfitName)
			end
			ClientAnimationEvent:FireClient(Player, nil, "camera_fix")
			newChar.HumanoidRootPart.CFrame = LastPosition
			for i,part in pairs(newChar:GetDescendants()) do
				if part:IsA("BasePart") or part:IsA("Decal") then
					local TransparencyValue = Instance.new("NumberValue",part)
					TransparencyValue.Name = "TransparencyValue"
					TransparencyValue.Value = part.Transparency
					part.Transparency = 1
				elseif part:IsA("ParticleEmitter") then
					part.Enabled = false
				elseif part:IsA("TextLabel") then
					part.TextTransparency,part.TextStrokeTransparency = 1,1
				end
			end
			ClientAnimationEvent:FireClient(Player,nil,"The Other Side")
			task.spawn(function()
				task.wait(170)
				if GhostValue.Parent ~= newChar or newChar ~= Player.Character or newChar.Parent == nil or newChar:FindFirstChild("DeathHandled") then return end
				tvlServerUtil.Hint(Player, "Your soul will shatter soon...")
				task.wait(10)
				if GhostValue.Parent ~= newChar or newChar ~= Player.Character or newChar.Parent == nil or newChar:FindFirstChild("DeathHandled") then return end
				Player:LoadCharacter()
			end)
		elseif TupleTable.Option == "revive" then
			local oldChar = Player.Character
			local hasBloodInSystem = oldChar:FindFirstChild("BloodInSystem")
			local stats = {}
			for _, stat in oldChar:GetChildren() do
				if stat.Name ~= "WitchStats" and stat.Name ~= "WolfStats" and stat.Name ~= "VampireStats" then continue end
				stat.Parent = workspace
				table.insert(stats, stat)
			end
			local PhoenixDeath = Instance.new("IntValue",Player)
			PhoenixDeath.Name = "PhoenixDeath"
			local LastPosition = oldChar.HumanoidRootPart.CFrame :: CFrame
			local CharacterConfiguration = Player:WaitForChild("CharacterConfiguration")
			local CharName,OutfitName = CharacterConfiguration.CharacterName.Value,CharacterConfiguration.OutfitName.Value
			local isCustom = CharacterConfiguration:FindFirstChild("isCustom")
			local isCoven = CharacterConfiguration:FindFirstChild("isCoven")
			local cusgen, cusdisplayname, cuseyecol, cusspecie = Player.CharacterConfiguration.Gender.Value, nil, nil, Player.CharacterConfiguration.Specie.Value
			if isCustom then
				cusdisplayname = isCustom.CusDisplayName.Value
				cuseyecol = isCustom.EyeColor.Value
			end
			task.spawn(function()
				FXModule.FadeWhite(Player, 0.5, 2)
			end)
			task.wait(1.5)
			Player:LoadCharacter()
			Debris:AddItem(PhoenixDeath, 6)

			local newChar = (if Player.Character == oldChar then nil else Player.Character) or Player.CharacterAdded:Wait()

			for _, stat in stats do
				stat.Parent = newChar
			end

			if isCustom then
				MorphHandler.MorphCustom(newChar, cusgen, cusdisplayname, cuseyecol, cusspecie)
			elseif isCoven then
				MorphHandler.MorphCoven(newChar, cusgen)
			else
				MorphHandler.Morph(newChar,CharName,OutfitName, true, cusspecie)
			end

			newChar.HumanoidRootPart.CFrame = LastPosition

			ClientAnimationEvent:FireClient(Player,nil,"camera_fix")
			newChar.Humanoid.Health = newChar.Humanoid.MaxHealth
			if TupleTable.Transition then
				if not hasBloodInSystem then Player:LoadCharacter() end
				local bloodInSystem = Instance.new("Folder", newChar)
				bloodInSystem.Name = "BloodInSystem"
				tvlServerUtil.SetHealth(newChar, 0)
			end
		elseif TupleTable.Option == "forceDessicate" then
			ClientAnimationEvent:FireClient(Player.Character, "forceDessicate")
		end
	end,
	["ActivateTrailVampire"] = function(Character,TupleTable)
		local Trail1 = Character.RightLowerArm:WaitForChild("VampireRunTrail2",1.5)
		local Trail2 = Character.LeftLowerArm:WaitForChild("VampireRunTrail3",1.5)
		Trail1.Enabled = TupleTable.Enabled
		Trail2.Enabled = TupleTable.Enabled
		local r = Random.new()
		local Sounds = ReplicatedStorage.ReplicatedAssets.VampireAssets.Sounds.VampireSpeed:GetChildren()
		Character.HumanoidRootPart.VampireSpeedSound.SoundId = Sounds[r:NextInteger(1, #Sounds)].SoundId
		if TupleTable.vampSound == true then
			Character.HumanoidRootPart.VampireSpeedSound:Play()
		end
	end,
	["SnapPlayer"] = function(Character,TupleTable)
		if IsACharacter(TupleTable.Target) ~= nil  then
			PlayerInteractionModule.SnapPlayer(Character,IsACharacter(TupleTable.Target))       
		end
	end,
	["FeedPlayer"] = function(Character,TupleTable)
		if IsACharacter(TupleTable.Target) ~= nil  then
			PlayerInteractionModule.FeedPlayer(Character,IsACharacter(TupleTable.Target))
		end
	end,
	["BitePlayer"] =  function(Character,TupleTable)
		if IsACharacter(TupleTable.Target) ~= nil  then
			PlayerInteractionModule.BitePlayer(Character,IsACharacter(TupleTable.Target))
		end
	end,
	["WolfBitePlayer"] =  function(Character,TupleTable)
		if IsACharacter(TupleTable.Target) ~= nil  then
			PlayerInteractionModule.WolfBitePlayer(Character,IsACharacter(TupleTable.Target))
		end
	end,
	["Compulsion"] =  function(Character,TupleTable)
		if IsACharacter(TupleTable.Target) ~= nil  then
			PlayerInteractionModule.Compulsion(Character,IsACharacter(TupleTable.Target))
		end
	end,
	["HopeScream"] =  function(Character,TupleTable)
		PlayerInteractionModule.HopeScream(Character)
	end,
	["PhoneON"] = function(Character)
		Character.Phone.Phone.Transparency,Character.Phone.PhoneCase.Transparency = 0,0
	end,
	["PhoneOFF"] = function(Character)
		Character.Phone.Phone.Transparency,Character.Phone.PhoneCase.Transparency = 1,1	
	end,
	["PunchPlayer"] =  function(Character,TupleTable)
		if IsACharacter(TupleTable.Target) ~= nil  then
			PlayerInteractionModule.Punch(Character,IsACharacter(TupleTable.Target))
		end
	end,	
	["Heartrip"] =  function(Character,TupleTable)
		if IsACharacter(TupleTable.Target) ~= nil  then
			PlayerInteractionModule.Heartrip(Character,IsACharacter(TupleTable.Target))
		end
	end,	
	["SelfSiphon"] =  function(Character,TupleTable)
		PlayerInteractionModule.SelfSiphon(Character, TupleTable)
	end,
	["WolfHowl"] =  function(Character,TupleTable)
		PlayerInteractionModule.WolfHowl(Character)
	end,
	["VampFace"] =  function(Character,TupleTable)
		PlayerInteractionModule.VampFace(Character)
	end,	
	["Ictus"] =  function(Character,TupleTable)
		PlayerInteractionModule.Ictus(Character,IsACharacter(TupleTable.Target))
	end,
	["Ossox"] =  function(Character,TupleTable)
		PlayerInteractionModule.Ossox(Character,IsACharacter(TupleTable.Target))
	end,
	["MagicScream"] =  function(Character,TupleTable)
		PlayerInteractionModule.MagicScream(Character)
	end,
	["Slam"] = function(Character, TupleTable)
		PlayerInteractionModule.Slam(Character)
	end,
	["BoneBreak"] =  function(Character,TupleTable)
		PlayerInteractionModule.BoneBreak(Character,IsACharacter(TupleTable.Target))
	end,
	["Scratch"] =  function(Character,TupleTable)
		PlayerInteractionModule.Scratch(Character,IsACharacter(TupleTable.Target))
	end,
	["Repulse"] =  function(Character,TupleTable)
		PlayerInteractionModule.Repulse (Character)
	end,
	["BloodChoke"] =  function(Character,TupleTable)
		PlayerInteractionModule.BloodChoke(Character,IsACharacter(TupleTable.Target))
	end,
	["Resurrection"] =  function(Character,TupleTable)
		print("reached interactionscript res")
		warn("OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO RESURRECTION OMG OOOOOOOOOOOOOOOOOOOOOOOO")
		--PlayerInteractionModule.Resurrection(Character,IsACorpse(TupleTable.Target))
	end,
	["Poena"] =  function(Character,TupleTable)
		PlayerInteractionModule.Poena(Character,IsACharacter(TupleTable.Target))
	end,
	["DahliaTeleport"] =  function(Character,TupleTable)
		PlayerInteractionModule.DahliaTeleport(Character,TupleTable.Target)
	end,
	["DJTeleport"] = function(Character,TupleTable)
		PlayerInteractionModule.DJTeleport(Character,TupleTable.Target)
	end,
	["Siphon"] =  function(Character,TupleTable)
		if TupleTable.Option == "OFF" then
			PlayerInteractionModule.Siphon(Character,nil, "OFF")
			return
		end
		if not TupleTable.Target or typeof(TupleTable.Target) ~= "Instance" then return end
		local character = IsACharacter(TupleTable.Target)
		local darkObject: Instance? = if TupleTable.Target.Name == "DarkObject" then TupleTable.Target else TupleTable.Target:FindFirstChild("DarkObject")
		if darkObject and not darkObject:IsDescendantOf(workspace.DarkObjectSpawns) then
			darkObject = nil
		end
		local barrier: Instance? = if string.find(TupleTable.Target.Name, "Boundary") and TupleTable.Target:FindFirstChild("Magic") and TupleTable.Target:FindFirstChild("Owner") and TupleTable.Target.Owner.Value ~= "" and TupleTable.Target.Magic.Value > 0 then TupleTable.Target else nil
		if barrier and not barrier:IsDescendantOf(workspace.Boundaries) then
			barrier = nil
		end
		local anyThing = character or darkObject or barrier
		if anyThing then PlayerInteractionModule.Siphon(Character, anyThing, "ON") end
	end,	
	["SpawnAsCovenMember"] = function(Character,TupleTable)
		local Player = GetPlayer(Character)
		local alreadyHasChar = not not Player:FindFirstChild("CharacterConfiguration") and Player.CharacterConfiguration:FindFirstChild("CharacterName")
		if TupleTable.Gender == "Male" or TupleTable.Gender == "Female" then
			if alreadyHasChar == false then
				MorphHandler.MorphCoven(Character,TupleTable.Gender)
			end
		end
	end,
	["SpawnAsCustom"] = function(Player,TupleTable)
		if (TupleTable.Gender == "Male" or TupleTable.Gender == "Female") and (TupleTable.EyeColor == "Blue" or TupleTable.EyeColor == "Green" or TupleTable.EyeColor == "Brown") then
			local maxChar = 32
			local text = TupleTable.CharDisplayName
			if string.len(text) > maxChar then
				text = string.sub(text, 1, maxChar)
			end
			local ChatService = game:GetService("Chat")
			local filter = ChatService:FilterStringAsync(text, Players:GetPlayerFromCharacter(Player), Players:GetPlayerFromCharacter(Player))



			MorphHandler.MorphCustom(Player,TupleTable.Gender, filter, TupleTable.EyeColor, RandomSpecie(Players:GetPlayerFromCharacter(Player)))
		end
	end,
	["SpawnAsChar"] = function(Character,TupleTable)
		local Player = GetPlayer(Character)
		local alreadyHasChar = not not (Player:FindFirstChild("CharacterConfiguration") and Player.CharacterConfiguration:FindFirstChild("CharacterName"))
		
		if not tvlReplicatedUtil.HasGamepass(Player, TupleTable.CharName) then return end
		
		local isFree = true
		for _, player in Players:GetPlayers() do
			local charConfig = player:FindFirstChild("CharacterConfiguration")
			if not charConfig then continue end
			local charName = charConfig:FindFirstChild("CharacterName")
			if not charName then continue end
			if charName.Value == TupleTable.CharName then
				isFree = false
				break
			end
		end
		if alreadyHasChar == false and isFree then
			MorphHandler.Morph(Character,TupleTable.CharName,TupleTable.Outfit)
		end
	end,
	["RequestLoad"] = function(Character,TupleTable)
		local Player = GetPlayer(Character)
		Player:RequestStreamAroundAsync(Vector3.new(TupleTable.Position))
	end,
	["TelekinesisProcess"] = function(Character, target)
		local Player = GetPlayer(Character)
		if not table.find(SpellConfigurationModule["That Telekinesis Spell"].CharacterLockedName, Player.CharacterConfiguration.CharacterName.Value) then return end
		if not Character:FindFirstChild("WitchStats") or Character.WitchStats.Magic.Value <= 100 then return end
		if target then
			local char = Player.CharacterConfiguration.CharacterName.Value
			local plr = Players:GetPlayerFromCharacter(Character)
			if plr:DistanceFromCharacter(target.Position) <= 30 then
				if target:CanSetNetworkOwnership() and target:GetNetworkOwnershipAuto() then
					local targetChar = tvlServerUtil.IsACharacter(target)

					if not targetChar then return end

					local partiInner, partiOuter = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects.telekInner:Clone(), game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects.telekOuter:Clone()
					partiInner.Parent = targetChar.HumanoidRootPart
					partiOuter.Parent = targetChar.HumanoidRootPart

					partiInner.Enabled = true
					partiOuter.Enabled = true

					local casterParti = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects.TelekCaster:Clone()
					casterParti.Parent = Character["RightHand"]

					local anim = Instance.new("Animation")
					anim.AnimationId = "rbxassetid://80094912388780"
					local track = Character.Humanoid.Animator:LoadAnimation(anim)
					track.Name = "DahliaTelekAnim1"

					--85262807207500
					local anim2 = Instance.new("Animation")
					anim2.AnimationId = "rbxassetid://91863993303769"
					local track2 = targetChar.Humanoid:FindFirstChild("Animator") and targetChar.Humanoid.Animator:LoadAnimation(anim2) or targetChar.Humanoid:LoadAnimation(anim2)
					track2.Name = "DahliaVictimTelek"

					local telekSound = Instance.new("Sound")
					telekSound.SoundId = "rbxassetid://6790666630"
					telekSound.Looped = true
					telekSound.Name = "telekSound"
					telekSound.Volume = 3
					telekSound.Parent = Character.HumanoidRootPart
					telekSound:Play()




					target:SetNetworkOwner(plr)
					ClientAnimationEvent:FireClient(plr,true,"TelekinesisValidation",target)
					--game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(GetPlayer(target.Parent),"ON")
					if not Character:FindFirstChild("isTelek") then
						local isTelek = Instance.new("Folder")
						isTelek.Name = "isTelek"
						isTelek.Parent = Character
						Debris:AddItem(isTelek, 60)
					end
					track:Play()
					track2:Play(1)

					local telekLeftConnection
					telekLeftConnection = Players.PlayerRemoving:Connect(function(leavingPlayer)
						if leavingPlayer == plr then
							Interactions["TelekinesisEnd"](Character, {Target = target, Throw = false, Connection = telekLeftConnection})
						end
					end)

					coroutine.resume(coroutine.create(function()
						while Character ~= nil and Character:FindFirstChild("isTelek") ~= nil do
							if Character:FindFirstChild("WitchStats") and Character.WitchStats.Magic.Value >= 100 and char ~= "Esther Mikaelson" then
								Character.WitchStats.Magic.Value -= 5
								task.wait(0.1)
							elseif Character:FindFirstChild("WitchStats") and Character.WitchStats.Magic.Value >= 100 and char == "Esther Mikaelson" then
								Character.WitchStats.Magic.Value -= 5
								task.wait(0.1)
							elseif Character.WitchStats.Magic.Value < 100 then
								local xy = Character:FindFirstChild("isTelek")
								if xy then
									xy:Destroy()
								end
								local pl
								if target then
									pl = GetPlayer(target.Parent)
								end
								if pl then
									game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(pl,"OFF")
								end

								ClientAnimationEvent:FireClient(plr,false,"TelekinesisValidation",nil)
								partiInner.Enabled = false
								partiOuter.Enabled = false
								Debris:AddItem(partiInner, 4)
								Debris:AddItem(partiOuter, 4)
								casterParti:Destroy()
								track:Stop()
								track2:Stop()
								Debris:AddItem(track, 4)
								telekSound:Stop()
								Debris:AddItem(telekSound, 4)
								task.wait(0.1)

								return 
							end
						end
					end))
					return
				end
			end
			ClientAnimationEvent:FireClient(plr,false,"TelekinesisValidation",nil)
		end
	end,
	["TelekinesisEnd"] = function(Character, TuppleTable)
		if TuppleTable.Connection then TuppleTable.Connection:Disconnect() end
		if TuppleTable.Target:CanSetNetworkOwnership() then TuppleTable.Target:SetNetworkOwnershipAuto() end
		local targetChar = (function() if TuppleTable.Target.Parent:FindFirstChild("Humanoid") then return TuppleTable.Target.Parent elseif TuppleTable.Target.Parent.Parent:FindFirstChild("Humanoid") then return TuppleTable.Target.Parent.Parent end return false end)()
		local xy = Character:FindFirstChild("isTelek")
		local xyz = Character:FindFirstChild("HumanoidRootPart"):FindFirstChild("telekSound")
		if xy then
			xy:Destroy()
		end
		if xyz then
			xyz:Destroy()
		end

		coroutine.resume(coroutine.create(function()
			for i,v in pairs(Character.Humanoid.Animator:GetPlayingAnimationTracks()) do
				if v.Name == "DahliaTelekAnim1" then
					v:Stop()
					break
				end
			end
			for i,v in pairs(targetChar.Humanoid.Animator:GetPlayingAnimationTracks()) do
				if v.Name == "DahliaVictimTelek" then
					v:Stop()
					break
				end
			end
		end))

		local x = targetChar.HumanoidRootPart:FindFirstChild("telekInner")
		local y = targetChar.HumanoidRootPart:FindFirstChild("telekOuter")
		if x then
			x:Destroy()
		end
		if y then
			y:Destroy()
		end

		if Character["RightHand"]:FindFirstChild("TelekCaster") then
			Character["RightHand"].TelekCaster:Destroy()
		end

		if TuppleTable.Throw then
			print("throwing")
			local Player = GetPlayer(Character)
			local char = Player.CharacterConfiguration.CharacterName.Value

			game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(GetPlayer(targetChar),"ON")
			local speed
			if char ~= "Esther Mikaelson" then
				speed = 250
			else
				speed = 120
			end

			local anim = Instance.new("Animation")
			anim.AnimationId = "rbxassetid://76100931144301"
			local track = Character.Humanoid.Animator:LoadAnimation(anim)
			track.Name = "DahliaTelekFling"
			track:Play()
			Debris:AddItem(track, 7)


			local sound = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds.CastedIctus:Clone()
			sound.Parent = Character.HumanoidRootPart
			sound:Play()
			Debris:AddItem(sound, 6)


			local fling = Instance.new("BodyVelocity")
			fling.Parent, fling.MaxForce, fling.Velocity = TuppleTable.Target, Vector3.new(math.huge,math.huge,math.huge), (TuppleTable.Target.Position - Character.HumanoidRootPart.Position).Unit * speed --120


			local sound2 = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds.CastedIctus:Clone()
			sound2.Parent = targetChar.HumanoidRootPart
			sound2:Play()
			Debris:AddItem(sound2, 6)

			if targetChar then
				tvlServerUtil.TakeDamage(targetChar, targetChar.MaxHealth.Value/(if char ~= "Esther Mikaelson" then 3 else 5))
			end
			task.wait(.2)
			fling:Destroy()

			coroutine.resume(coroutine.create(function()
				task.wait(5)
				game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(GetPlayer(targetChar),"OFF")
			end))
		end
	end,
	["PlaceTotem"] = function(Character)
		require(ReplicatedStorage.SpellsStorageModules.InaduImmortality).Execute(Character)
	end,
	["CallPlayer"] = function(Character)
		local Player = GetPlayer(Character)		
		PlayerInteractionModule.CallPlayer(Player, Character)
	end,
	["ThroatRip"] = function(Character, TupleTable)
		local char = IsACharacter(TupleTable.Target)
		if not char then return end
		PlayerInteractionModule.ThroatRip(Character, char)
	end,
	["FreyaBarrierDispelling"] = function(Character, TupleTable)
		local player = GetPlayer(Character)
		if not player then return end
		if player.CharacterConfiguration.CharacterName.Value ~= "Freya" then return end
		if not IsSpecie(player, { "Witches", "Werewitches", "Tribrids","PyroWitches" }) then return end
		local barrier = TupleTable.Barrier
		local door = TupleTable.Door
		if door then
			if (door.radius.Position - Character.HumanoidRootPart.Position).Magnitude > 14 then
				door = nil
			end
			if door and not door:FindFirstChild("isLocked") then
				door = nil
			end
		end
		if barrier then
			if not (barrier:FindFirstChild("Magic") or barrier.Magic.Value <= 0) then return end
		end
		PlayerInteractionModule.FreyaBarrierDispelling(player.Character, barrier, door)
	end,
}

blinkEvent.OnServerEvent:Connect(function(Player,msg)
	blinkEvent:FireAllClients(Player,msg)
end)
MessageEvent.OnServerEvent:Connect(function(Player,Message,ToPlayer)
	local Client = game.Players:FindFirstChild(tostring(ToPlayer))
	local ChatService = game:GetService("Chat")
	if typeof(Message) == "string" then
		if Client ~= nil and Player ~= Client then
			local filter = ChatService:FilterStringForBroadcast(Message, Player)
			MessageEvent:FireClient(Client,filter,Player.Name)
		end
	end
end)
WitchSpellEvent.OnServerEvent:Connect(function(Player,TupleTable)
	local Character = Player.Character
	if Character == nil then return end
	if not IsSpecie(Player, {"Witches","Siphoners","Heretics","Werewitches","Tribrids","Werephoners","Quadrabrids","PyroWitches"}) then return end

	local function DetectTypeOfInput(Input)
		if Input == Enum.UserInputType.MouseButton2 or Input == Enum.UserInputType.MouseButton3 then
			return "MouseClick"
		elseif Input == Enum.UserInputType.MouseButton1 then
			return "Mouse"
		elseif Input == Enum.UserInputType.TextInput or Input == Enum.UserInputType.MouseButton1 then
			return "Chat"
		elseif Input == Enum.UserInputType.InputMethod then
			return "ChatPerson"
		end
	end

	--MAGIC REGEN AREA
	local Player = Players:GetPlayerFromCharacter(Character)
	local WitchFolder = Character:FindFirstChild("WitchStats")
	if Character:FindFirstChild("Powerless") ~= nil then return end--or Character.Humanoid:GetState() == Enum.HumanoidStateType.Physics then return end
	if WitchFolder == nil then return end
	for Name,Table in pairs(SpellConfigurationModule) do
		local incantation = Table.Key:lower()
		local inputType = Table.Input
		local ghostcast = false
		if incantation == TupleTable.IncantationText then 
			print("successfully")
			local isAllowedPerson = if Table.PersonLocked == true then table.find(Table.CharacterLockedName, Player.CharacterConfiguration.CharacterName.Value) ~= nil else true
			local isAllowedHarvest = Table.HarvestUnlockable and Player:GetAttribute("IsHarvested")
			if not (isAllowedPerson or isAllowedHarvest) then return end
			if WitchFolder.Magic.Value < Table.Magic then NotificationHandler.Notification(Player,"You do not have sufficient magic to cast ".. TupleTable.IncantationText) return end
			if DetectTypeOfInput(inputType) == "MouseClick" and TupleTable.Target == nil then return end
			if DetectTypeOfInput(inputType) == "MouseClick" and TupleTable.Target:FindFirstChild("Influenced") ~= nil then return end --or TupleTable.Target:FindFirstChild("Ghost") ~= nil then return end
			if DetectTypeOfInput(inputType) == "MouseClick" and TupleTable.Target:FindFirstChild("IsProjecting") ~= nil then return end
			if DetectTypeOfInput(inputType) == "MouseClick" and Table.WantedSpecie ~= nil and IsSpecie(Players:GetPlayerFromCharacter(TupleTable.Target),Table.WantedSpecie) == false  then return end
			if DetectTypeOfInput(inputType) == "MouseClick" and Table.Magnitude ~= nil and (Character.Head.Position-TupleTable.Target.Head.Position).magnitude > Table.Magnitude then return end
			if DetectTypeOfInput(inputType) == "ChatPerson" and TupleTable.TextTarget == nil then return print(TupleTable.TextTarget) end
			if IsRagdolled(Character) == true then return print('ragdoll') end
			if Table.GhostCast ~= nil and Table.GhostCast == true then ghostcast = true end
			if Character:FindFirstChild("Ghost") ~= nil and ghostcast == false then return print('casted as ghost while not ghost') end
			if IsSpecie(Player,{"Vampires","Originals","UpgradedOriginals"}) == true then return print('vamps ogs') end
			if not _G.CooldownSpells[Player.Name] then _G.CooldownSpells[Player.Name] = {} end
			if _G.CooldownSpells[Player.Name][Name] == false then NotificationHandler.Notification(Player,TupleTable.IncantationText.." is currently on cooldown") return end
			WitchFolder.Magic.Value = math.clamp(WitchFolder.Magic.Value - Table.Magic,0,WitchFolder.MaxMagic.Value)
			if Player.CharacterConfiguration.CharacterName.Value == "Luna" then
				local chance = math.random(1,400)
				if chance == 1 then
					local vinsound = Instance.new("Sound")
					vinsound.SoundId = "rbxassetid://10094807718"
					vinsound.Volume = 3
					vinsound.Parent = Character.HumanoidRootPart
					vinsound:Play()
					local found = false
					local Instances = {}
					for i,plr in pairs(Players:GetPlayers()) do
						if plr ~= Player then
							local IdentifiedTarget = plr.Character.HumanoidRootPart
							if (IdentifiedTarget.Position - Character.HumanoidRootPart.Position).Magnitude < 40 then
								table.insert(Instances,IdentifiedTarget.Parent)
								found = true
								NotificationHandler.AdvancedNotification(plr,5,"Spirits","Luna has just let out a wet fart")
							end
						end
					end

				end
				--Player.Character.Humanoid:TakeDamage(Character.MaxHealth.Value)		vinnie you will never understand how funny this is
			end
			_G.CooldownSpells[Player.Name][Name] = false
			local success,Error = pcall(function()
				--if Table.TargetNotRequired then -- God forgive me.
				--	require(Table.Launcher).Execute(Character, {"Violence is not a problem, it's a solution."})
				if DetectTypeOfInput(inputType) == "ChatPerson" then
					coroutine.wrap(function()
						if Player.CharacterConfiguration.CharacterName.Value ~= "Dark Josie Saltzman" then return end
						DarkJosieFace(Player,true)
						task.wait(5)
						DarkJosieFace(Player,false)	
					end)()

					local function findPlayerWithClosestName(name: string)
						local players = game:GetService("Players"):GetPlayers()
						for _, player in players do
							if player == Player then continue end
							if player.Name:lower():match(name:lower()) then
								return player
							end
						end
					end

					local function findCharacterWithClosestName(name: string)
						local players = game:GetService('Players'):GetPlayers()
						for _, player in players do
							if player == Player then continue end
							local charConfig = player:FindFirstChild("CharacterConfiguration")
							if not charConfig then continue end
							local charName = charConfig:FindFirstChild("CharacterName")
							if not charName then continue end
							if charName.Value:lower():match(name:lower()) then
								return player
							end
						end
					end


					local target = TupleTable.TextTarget
					local targetPlayer = findPlayerWithClosestName(target) or findCharacterWithClosestName(target)
					if not targetPlayer then return end
					if Player:FindFirstChild("Coins") then
						Player.Coins.Value += math.random(9,14)
					end
					require(Table.Launcher).Execute(Character,{TargetPlayer = targetPlayer})
				else
					coroutine.wrap(function()
						if Player.CharacterConfiguration.CharacterName.Value ~= "Dark Josie Saltzman" then return end
						DarkJosieFace(Player,true)
						task.wait(5)
						DarkJosieFace(Player,false)	
					end)()
					if Player:FindFirstChild("Coins") then
						Player.Coins.Value += math.random(9,14)
					end
					require(Table.Launcher).Execute(Character,{Target = TupleTable.Target,TargetPlayer = GetPlayer(TupleTable.Target)})		
				end
			end)
			if not success then
				warn("Spell could not launch.")
				warn("Error: "..Error)
			end
			task.wait(Table.Cooldown)
			_G.CooldownSpells[Player.Name][Name] = true
		end
	end
end)
--STAT FIX PLACES
StatEvent.OnServerEvent:Connect(function(Player, Message)
	local Character = Player.Character
	if Character == nil then return end
	local factor = true

	if Message == "Refresh" then
		if Character:FindFirstChild("VampireStats") then
			-- ?? Vampire Energy Regen
			local Stats = Character.VampireStats
			Stats.Thirst.Value = math.clamp(Stats.Thirst.Value - 1, 0, Stats.MaxThirst.Value)
			Stats.Energy.Value = math.clamp(Stats.Energy.Value + 15, 0, Stats.MaxEnergy.Value)
		end

		if Character:FindFirstChild("WolfStats") then
			-- ?? Werewolf / Wolf Energy Regen
			local Stats = Character.WolfStats
			Stats.Energy.Value = math.clamp(Stats.Energy.Value + 10, 0, Stats.MaxEnergy.Value)
		end

		if Character:FindFirstChild("PhoenixStats") then
			-- ?? Phoenix Energy Regen
			if Character:FindFirstChild("Flying") then return end
			local Stats = Character.PhoenixStats
			Stats.Energy.Value = math.clamp(Stats.Energy.Value + 30, 0, Stats.MaxEnergy.Value)
		end

		-- ?? PyroWitch passive regen boost
		if Character:FindFirstChild("WitchStats") and Character:FindFirstChild("PhoenixStats") then
			local MagicStats = Character.WitchStats
			local EnergyStats = Character.PhoenixStats
			MagicStats.Magic.Value = math.clamp(MagicStats.Magic.Value + math.random(15, 20), 0, MagicStats.MaxMagic.Value)
			EnergyStats.Energy.Value = math.clamp(EnergyStats.Energy.Value + 35, 0, EnergyStats.MaxEnergy.Value)
		end

		if Character:FindFirstChild("WitchStats") ~= nil then
			-- ????? Witch Magic Regen
			if IsSpecie(Player, {"Witches","Tribrids","Werewitches","Quadrabrids","Werephoners","Elder Witches","PyroWitches"}) == true
				or Player.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" then
				local Stats = Character.WitchStats
				Stats.Magic.Value = math.clamp(Stats.Magic.Value + math.random(10,15), 0, Stats.MaxMagic.Value)
			end
		end

	elseif Message == "CheckStat" then
		-- ? Keep stats within bounds
		if Character:FindFirstChild("VampireStats") then
			local Stats = Character.VampireStats
			Stats.Thirst.Value = math.clamp(Stats.Thirst.Value, 0, Stats.MaxThirst.Value)
			Stats.Energy.Value = math.clamp(Stats.Energy.Value, 0, Stats.MaxEnergy.Value)
		end

		if Character:FindFirstChild("WitchStats") then
			local Stats = Character.WitchStats
			Stats.Magic.Value = math.clamp(Stats.Magic.Value, 0, Stats.MaxMagic.Value)
		end

		if Character:FindFirstChild("PhoenixStats") then
			if Character:FindFirstChild("Flying") then return end
			local Stats = Character.PhoenixStats
			Stats.Energy.Value = math.clamp(Stats.Energy.Value, 0, Stats.MaxEnergy.Value)
		end
	end

	-- ?? PyroWitch combined stat sync (safety)
	if Character:FindFirstChild("WitchStats") and Character:FindFirstChild("PhoenixStats") then
		local MagicStats = Character.WitchStats
		local EnergyStats = Character.PhoenixStats
		MagicStats.Magic.Value = math.clamp(MagicStats.Magic.Value, 0, MagicStats.MaxMagic.Value)
		EnergyStats.Energy.Value = math.clamp(EnergyStats.Energy.Value, 0, EnergyStats.MaxEnergy.Value)
	end
end)


-- ????? Player interaction handlers
PlayerInteractionEvent.OnServerEvent:Connect(function(Player, InteractNameString, TupleTable)
	local Character = Player.Character
	if Character == nil then return end
	local Function = Interactions[InteractNameString]
	if Function then
		Function(Character, TupleTable)
	end
end)

PlayerInteractionEventServer.Event:Connect(function(Player1, Player2, TupleTable)
	if Player1.Character == nil then return end
	if Player2.Character == nil then return end
	Interactions["HandleSpell"](Player1.Character, {Key = TupleTable.Incantation, Target = Player2.Character})
end)


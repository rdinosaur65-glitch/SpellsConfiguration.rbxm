local PlayerActionModule = {}
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local tvlServerUtil = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("tvlServerUtil"))

local Players = game:GetService("Players")
local RemoteEventFolder = ReplicatedStorage.RemoteEvents
local ClientAnimationEvent  = RemoteEventFolder.AnimationClientEvent
local VampireAnimationsFolder = ReplicatedStorage.ReplicatedAssets.VampireAssets.Animations
local VampireAssetsFolder = ReplicatedStorage.ReplicatedAssets.VampireAssets.Objects
local VampireSoundFolder = ReplicatedStorage.ReplicatedAssets.VampireAssets.Sounds.VampireActions
local WerewolfSoundFolder = ReplicatedStorage.ReplicatedAssets.WerewolfAssets.Sounds
local WerewolfAnimationFolder = ReplicatedStorage.ReplicatedAssets.WerewolfAssets.Animations
local WitchAnimationsFolder = ReplicatedStorage.ReplicatedAssets.WitchesAssets.Animations
local WitchAssetsFolder = ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects
local WitchSoundFolder = ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds
local RagdollRemoteEvent = RemoteEventFolder.Ragdoll
local MorphHandler = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)
local PlayAnimationEvent = RemoteEventFolder.AnimationClientEvent
local CharacterConfiguration = require(game.ReplicatedStorage.ReplicatedModules.CharacterConfiguration)
local TweenModule = require(ReplicatedStorage.ReplicatedModules.ReplicatedTweening)
local NotificationHandler = require(game.ServerScriptService.MainUI.NotificationHandler)
local Events = ReplicatedStorage:WaitForChild("Events")
local coreGuiEdit = Events:WaitForChild("coreGuiEdit")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
--// Small functions

local Heartbeat = tvlServerUtil.Heartbeat
local SleepFace = tvlServerUtil.SleepFace
local IsSpecie = tvlServerUtil.IsSpecie
local DarkJosieFace = tvlServerUtil.DarkJosieFace
local DessicateFace = tvlServerUtil.DessicateFace
local Movement = tvlServerUtil.Movement

local AddInfluency = tvlServerUtil.AddInfluency
local RandomSpellSound = tvlServerUtil.RandomSpellSound
local SleepFace = tvlServerUtil.SleepFace
local VampireFace = tvlServerUtil.VampireFace
local RemoveInfluency = tvlServerUtil.RemoveInfluency
local IsSpecialWitch = tvlServerUtil.IsSpecialWitch
local IsRagdolled = tvlServerUtil.IsRagdolled
local WolfFace = tvlServerUtil.WolfFace

local function MoveBehind(OBJECT_TO_MOVE,STABLE_OBJECT,DistanceToMoveBehind)
	OBJECT_TO_MOVE.CFrame = STABLE_OBJECT.CFrame * CFrame.new(0,0,DistanceToMoveBehind) 
end

local function MoveFront(OBJECT_TO_MOVE,STABLE_OBJECT,DistanceToMoveInFront)
	OBJECT_TO_MOVE.CFrame = STABLE_OBJECT.CFrame * CFrame.new(0,0,-DistanceToMoveInFront) * CFrame.Angles(0,math.rad(180),0)
end

local function AddFeeding(OBJECT)
	if OBJECT:FindFirstChild("Feeding") == nil then
		local Value = Instance.new("IntValue",OBJECT)
		Value.Name = "Feeding"
	end
end

local function RemoveFeeding(OBJECT)
	if OBJECT:FindFirstChild("Feeding") ~= nil then
		OBJECT.Feeding:Destroy()
	end
end
local function CheckForInflunecy(OBJECT)
	if OBJECT:FindFirstChild("Influenced") ~= nil or OBJECT:FindFirstChild("Ghost") ~= nil then
		return true
	else
		return false
	end
end
local function CheckForFeeding(OBJECT)
	if OBJECT:FindFirstChild("Feeding") ~= nil or OBJECT:FindFirstChild("Ghost") ~= nil then
		return true
	else
		return false
	end
end

local function CheckDistance(OBJ1,OBJ2,MaxMagnitude)
	if (OBJ1.Position - OBJ2.Position).Magnitude < MaxMagnitude then
		return true
	else
		return false
	end
end
local function AddVampireBlood(OBJECT)
	if OBJECT:FindFirstChild("BloodInSystem") == nil then
		local Value = Instance.new("IntValue",OBJECT)
		Value.Name = "BloodInSystem"
	end
end

local function GiveRandomValue(Min,Max)
	local R = Random.new()
	return R:NextNumber(Min,Max)
end

local function DoRandomSpell(Player1,Player2)
	local randomSpellsIncantations = {
		"Neck Snap Spell",
		"Menedek Qual Suurentaa",
		"Poena Doloris",
		"Immobilus",
		"Ad Somnum",
		"Ictus",
		"Motus",	
	}
	if IsSpecialWitch(Player1) == true then
		local SpellsModule = require(ReplicatedStorage.ReplicatedModules.SpellsConfiguration)
		local RandomSpellIncantation = randomSpellsIncantations[GiveRandomValue(1,#randomSpellsIncantations)]
		for SpellName,Table in pairs(SpellsModule) do
			if SpellName == RandomSpellIncantation then
				ReplicatedStorage.RemoteEvents.PlayerInteractionServer:Fire(Player1,Player2,{Incantation = Table.Key})
				_G.CooldownSpells[Player1.Name][SpellName] = true
			end
		end
	end
end

local function ScreamSound(TargetPlayer)
	local TargetCharacter = TargetPlayer.Character
	if tvlServerUtil.CharacterName(TargetPlayer) == "Forbidden Pan" then
		ClientAnimationEvent:FireAllClients(WitchSoundFolder.InaduScream, "replicate_sound",{SoundParent = TargetCharacter.Head})
		return	
	end
	local Screams = ReplicatedStorage.ReplicatedAssets.Screams[TargetPlayer.CharacterConfiguration.Gender.Value]:GetChildren()
	ClientAnimationEvent:FireAllClients(Screams[math.random(1, #Screams)], "replicate_sound",{SoundParent = TargetCharacter.Head})
end
--// Werewolf Actions

function PlayerActionModule.TurnIntoHumanForm(Player)

	local Character = Player.Character or Player.CharacterAdded:Wait()
	if Character.Humanoid.Health <= 0 then return end
	if Character:FindFirstChild("IsProjecting") then return end
	local fol = Character:FindFirstChild("StatSavesWolf")
	fol.Parent = workspace
	local Cooldown = Instance.new("IntValue",Player)
	Cooldown.Name = "CooldownWolfTransformation"
	task.delay(10, function()
		Cooldown:Destroy()
	end)

	local WolfRing
	if Character:FindFirstChild("HasMoonlightRing") ~= nil then
		WolfRing = Instance.new("IntValue")
		WolfRing.Name = "HasMoonlightRing"
	end

	local Position = Character.PrimaryPart.CFrame
	local Health = Character.Humanoid.Health
	local MaxHealth = Character.Humanoid.MaxHealth

	if Player:FindFirstChild("Coins") then
		Player.Coins.Value += math.random(9,14)
	end

	local WasHarvested = Player:GetAttribute("IsHarvested")

	local Val = Instance.new("IntValue",Player)
	Val.Name = "GoingBackAsHuman"

	local CharModel = game.StarterPlayer.StarterCharacter:Clone()
	CharModel.Name = Player.Name

	local isCustom = Player.CharacterConfiguration:FindFirstChild("isCustom")
	local isCoven = Player.CharacterConfiguration:FindFirstChild("isCoven")

	local lastSpecie = Player.CharacterConfiguration.Specie.Value
	local lastName = Player.CharacterConfiguration.CharacterName.Value
	local lastOutfit = Player.CharacterConfiguration.OutfitName.Value
	local cusgen, cusdisplayname, cuseyecol = Player.CharacterConfiguration.Gender.Value, nil, nil
	if isCustom then
		cusdisplayname = isCustom.CusDisplayName.Value
		cuseyecol = isCustom.EyeColor.Value
	end

	Player.CharacterConfiguration:Destroy()

	Player.Character = CharModel
	Character = Player.Character or Player.CharacterAdded:Wait()

	for i,Script in pairs(game.StarterPlayer.StarterCharacterScripts:GetChildren()) do
		Script:Clone().Parent = Character
	end


	fol.Parent = Character
	for _, v in fol:GetChildren() do
		if v.Name == "WitchStats" then
			if v:FindFirstChild("SiphoningCooldown") then
				v.SiphoningCooldown.Value = false
			end
		end
		v.Parent = Character
	end
	fol:Destroy()

	CharModel.Parent = workspace

	CharModel.PrimaryPart.CFrame = Position

	Character.HumanoidRootPart.Anchored = true

	Character.Humanoid.WalkSpeed = 0

	Character.Humanoid.JumpPower = 0

	if isCustom then
		MorphHandler.MorphCustom(Character, cusgen, cusdisplayname, cuseyecol, lastSpecie)
	else
		MorphHandler.Morph(Character,lastName, lastOutfit, true, lastSpecie)
	end

	if WasHarvested then
		Player:SetAttribute("IsHarvested", true)
	end

	CharModel.Humanoid.MaxHealth = MaxHealth

	CharModel.Humanoid.Health = MaxHealth

	ClientAnimationEvent:FireClient(Player,nil,"camera_fix")
	ClientAnimationEvent:FireClient(Player,WerewolfAnimationFolder.ComingBackFromTransformation,"Char")

	if WolfRing ~= nil then
		WolfRing.Parent = Character
		local Ring = ReplicatedStorage.ReplicatedAssets.CharacterFiles.Rings[if IsSpecie(Player, {"Werephoners", "Quadrabrids"}) then "WerewitchRingModel" else "MoonlightRingModel"]:Clone()
		Ring.Parent = Character
		Ring:SetPrimaryPartCFrame(Character.LeftHand.CFrame * CFrame.new(-0.23,-0.1,-0.13) * CFrame.Angles(1.5,1.5,0))
		local WeldConstraint = Instance.new("WeldConstraint",Ring)
		WeldConstraint.Part0 = Character.LeftHand
		WeldConstraint.Part1 = Ring.PrimaryPart
	end

	task.delay(6, function()
		Val:Destroy()
		Character.Humanoid.WalkSpeed = 16
		Character.Humanoid.JumpPower = 50
		Character.HumanoidRootPart.Anchored = false
	end)

	if Player:FindFirstChild("Transformed") ~= nil then
		Player.Transformed:Destroy()
	end
end

function PlayerActionModule.TurnIntoWerewolfForm(Player)
	local function CloneWolfModel(CharacterConfig, isCustom)
		-- ? ADD THIS BLOCK RIGHT HERE (FIRST THING IN THE FUNCTION)
		local override = CharacterConfig:FindFirstChild("WolfForm")
		if override and override:IsA("StringValue") and override.Value ~= "" then
			local mdl = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.WolfModels:FindFirstChild(override.Value)
			if mdl then
				return mdl:Clone()
			end
		end
		if CharacterConfig.Specie.Value == "Werephoners" or CharacterConfig.Specie.Value == "Quadrabrids" then
			return game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.WolfModels["Purple Wolf"]:Clone()
		end
		if isCustom then
			return game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.WolfModels["Kva Wolf"]:Clone()
		else
			local wolfModel = CharacterConfiguration[CharacterConfig.CharacterName.Value].WolfModel or game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.WolfModels["Grey Wolf"]
			return wolfModel:Clone()
		end
	end
	if not IsSpecie(Player, {"Werewolves", "Hybrids", "Werewitches", "Werephoners", "Tribrids", "Quadrabrids"}) and Player.CharacterConfiguration.CharacterName.Value ~= "Niklaus Mikaelson" then return end 
	local Character = Player.Character or Player.CharacterAdded:Wait()
	if Character.Humanoid.Health <= 0 then return end
	if Character:FindFirstChild("IsProjecting") then return end	
	if Character:FindFirstChild("StrixPoison") then return NotificationHandler.Notification(Player, "The poison in your system prevents you from turning...") end
	local folders = {}
	local fol = Instance.new("Folder")
	fol.Name = "StatSavesWolf"
	for _,v in ipairs(Character:GetChildren()) do
		if v:IsA("Folder") and (v.Name == "VampireStats" or v.Name == "PhoenixStats" or v.Name == "WitchStats" or v.Name == "WolfStats") then
			table.insert(folders, v)
			v.Parent = fol
		elseif v.Name == "Channeling" or v.Name == "isCured" then
			table.insert(folders, v)
			v.Parent = fol
		end
	end
	local Val = Instance.new("IntValue",Player)
	Val.Name = "Transformed"
	Character.HumanoidRootPart.Anchored = true
	Character.Humanoid.WalkSpeed = 0
	Character.Humanoid.JumpPower = 0
	if Player:FindFirstChild("Coins") then
		Player.Coins.Value += math.random(9,14)
	end
	local Cooldown = Instance.new("IntValue",Player)
	Cooldown.Name = "CooldownWolfTransformation"
	local WolfRing
	if Character:FindFirstChild("HasMoonlightRing") ~= nil then
		WolfRing = Instance.new("IntValue")
		WolfRing.Name = "HasMoonlightRing"
	end
	task.delay(20, function()
		Cooldown:Destroy()
	end)
	local Health = Player.Character.Humanoid.Health
	local MaxHealth = Player.Character.Humanoid.MaxHealth
	WolfFace(Player,true)
	ClientAnimationEvent:FireClient(Player,"WEREWOLF_CUTSCENE","Camera")
	ClientAnimationEvent:FireClient(Player,WerewolfAnimationFolder.TurningIntoWerewolfForm,"Char")
	ClientAnimationEvent:FireAllClients(WerewolfSoundFolder.crack1,"replicate_sound",{SoundParent = Character.Head})
	ClientAnimationEvent:FireAllClients(WerewolfSoundFolder.crack2,"replicate_sound",{SoundParent = Character.Head})
	ScreamSound(Player)
	task.wait(3.4)
	local Position = Player.Character.PrimaryPart.CFrame
	local CharacterModel
	if Player.CharacterConfiguration:FindFirstChild("isCustom") then
		if Player.CharacterConfiguration.isCustom:FindFirstChild("CustomWolf") then
			CharacterModel= CloneWolfModel(Player.CharacterConfiguration, true)
		else
			CharacterModel= CloneWolfModel(Player.CharacterConfiguration, false)
		end
	else
		CharacterModel= CloneWolfModel(Player.CharacterConfiguration, false)
	end


	CharacterModel.Name = Player.Name
	Player.Character = CharacterModel
	CharacterModel.Parent = workspace	
	CharacterModel.PrimaryPart.CFrame = Position
	CharacterModel.Humanoid.MaxHealth = MaxHealth
	CharacterModel.Humanoid.Health = MaxHealth
	for i,Script in pairs(game.StarterPlayer.StarterCharacterScripts:GetChildren()) do
		if Script.Name == "Controller" or Script.Name == "Animate" or Script.Name == "ReplicateScript" or Script.Name == "StatCheck" then 
			Script:Clone().Parent = Player.Character
		end
	end
	CharacterModel.Controller:Destroy()
	Character.Controller.Parent = CharacterModel
	--game.ReplicatedStorage.Events.ClientReceiver:FireClient(Player,"camera_fix")
	Character = Player.Character
	fol.Parent = Character
	local animateScript = Character:WaitForChild("Animate")
	animateScript.run.RunAnim.AnimationId = "rbxassetid://71298780175468"        -- Run
	animateScript.walk.WalkAnim.AnimationId = "rbxassetid://75595339075638"      -- Walk
	animateScript.jump.JumpAnim.AnimationId = "rbxassetid://95856120361329"      -- Jump
	animateScript.idle.Animation1.AnimationId = "rbxassetid://84010875179634"    -- Idle (Variation 1)
	animateScript.idle.Animation2.AnimationId = "rbxassetid://73921062346092"    -- Idle (Variation 2)
	animateScript.fall.FallAnim.AnimationId = "rbxassetid://93502113734321"      -- Fall
--[[
	local HumanoidDescription = Character.Humanoid:GetAppliedDescription()
	HumanoidDescription.RunAnimation,HumanoidDescription.WalkAnimation,HumanoidDescription.FallAnimation,HumanoidDescription.JumpAnimation,HumanoidDescription.IdleAnimation = 616168032,85022592737996,120040588162035,101026815584722,90942747450576
	Character.Humanoid:ApplyDescription(HumanoidDescription)
--]]
	local Val2 = Instance.new("IntValue",Character)
	Val2.Name = "Transformed"
	local Howl = Player.Character.Humanoid:LoadAnimation(WerewolfAnimationFolder.howlNew)
	Howl:Play()
	Howl:Destroy()
	if IsSpecie(Player,{"Werewitches"}) == true and Player.CharacterConfiguration.CharacterName.Value == "Zara Malory" or Player.CharacterConfiguration.CharacterName.Value == "Sydney Malory" or Player.CharacterConfiguration.CharacterName.Value == "Emma Malory"  or Player.CharacterConfiguration.CharacterName.Value == "Deceptive" then
		ClientAnimationEvent:FireAllClients(WerewolfSoundFolder.lighthowl,"replicate_sound",{SoundParent = Character.Head})
	else
		ClientAnimationEvent:FireAllClients(WerewolfSoundFolder.howl,"replicate_sound",{SoundParent = Character.Head})
	end
	local Sound =nil
	if IsSpecie(Player,{"Werewitches"}) == true and Player.CharacterConfiguration.CharacterName.Value == "Zara Malory" or Player.CharacterConfiguration.CharacterName.Value == "Sydney Malory" or Player.CharacterConfiguration.CharacterName.Value == "Emma Malory" or  Player.CharacterConfiguration.CharacterName.Value == "Deceptive" then
		if math.random(1,2) == 1 then
			Sound = WerewolfSoundFolder.lightdog1:Clone()
		else
			Sound =  WerewolfSoundFolder.lightdog2:Clone()
		end
		Sound.Parent = Character.Head
		Sound.Looped = true
		Sound:Play()
	else
		if math.random(1,2) == 1 then
			Sound = WerewolfSoundFolder.dog1:Clone()
		else
			Sound =  WerewolfSoundFolder.dog2:Clone()
		end
		Sound.Parent = Character.Head
		Sound.Looped = true
		Sound:Play()
	end

	if WolfRing ~= nil then
		WolfRing.Parent = Character
	end

	Character.Humanoid.WalkSpeed = 16
	Character.Humanoid.JumpPower = 50

	Character.HumanoidRootPart.Anchored = false
	local t
	t = Character.Humanoid.Died:Once(function()
		if Player:FindFirstChild("Transformed") ~= nil then Player.Transformed:Destroy() end
		Sound:Destroy()
		Character.HumanoidRootPart.Anchored = true
		t:Disconnect()
	end)
end
--// Player Actions
function PlayerActionModule.Punch(AttackingCharacter,TargetCharacter)
	local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local TargetHumanoid = TargetCharacter:FindFirstChildOfClass("Humanoid")
	if TargetCharacter:FindFirstChild("Prevghost")~= nil then return end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
	if IsRagdolled(TargetCharacter) == true or IsRagdolled(AttackingCharacter) == true then return end
	if AttackingCharacter:FindFirstChild("BiteCooldown") ~= nil then return end
	if CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,7) == false then return end
	if AttackingCharacter:FindFirstChild("IsProjecting") or TargetCharacter:FindFirstChild("IsProjecting") then return end
	if AttackingCharacter:FindFirstChild("slapCD") then return end
	if AttackingPlayer:FindFirstChild("Transformed") == nil then
		AddInfluency(AttackingCharacter)
		AddInfluency(TargetCharacter)
		if tvlServerUtil.devCheck(AttackingPlayer) or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia Hagen" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Freya" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Sheila Bennett" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Esther Mikaelson" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia" then
			coroutine.wrap(function()
				local slapcd = Instance.new("Folder")
				slapcd.Name = "slapCD"
				slapcd.Parent = AttackingCharacter
				Debris:AddItem(slapcd, 3)
				MoveFront(AttackingCharacter.HumanoidRootPart,TargetCharacter.HumanoidRootPart,2)

				task.wait(0.3)
				Movement(TargetCharacter,false)
				Movement(AttackingCharacter,false)
				ClientAnimationEvent:FireAllClients(VampireSoundFolder.Slap,"replicate_sound",{SoundParent = TargetCharacter.Head})
				ClientAnimationEvent:FireClient(AttackingPlayer,VampireAnimationsFolder.SlapAttacker,"Char")
				ClientAnimationEvent:FireClient(TargetPlayer,VampireAnimationsFolder.SlapVictim,"Char")
				task.wait(1)
				Movement(TargetCharacter,true)
				task.wait(2)
				Movement(AttackingCharacter,true)
			end)()

		else
			ClientAnimationEvent:FireAllClients(VampireSoundFolder.punchSound,"replicate_sound",{SoundParent = TargetCharacter.Head})
			ClientAnimationEvent:FireClient(AttackingPlayer,VampireAnimationsFolder.PunchPerson,"Char")
		end
		if AttackingPlayer:FindFirstChild("Coins") then
			AttackingPlayer.Coins.Value += math.random(5,20)
		end
		if IsSpecie(AttackingPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Customs","Hybrids","Tribrids","Quadrabrids","Heretics","Sirens","UpgradedOriginals","TimeLords"}) == true then
			if TargetCharacter:FindFirstChild("ProtectionSpell") ~= nil then
				if TargetCharacter.Humanoid.Health < 30 then

					TargetCharacter.Humanoid.Health = 25
				end
			end
			if IsSpecie(AttackingPlayer,{"Sirens"}) == false then
				tvlServerUtil.TakeDamage(TargetCharacter, GiveRandomValue(20,25))
			else
				tvlServerUtil.TakeDamage(TargetCharacter, GiveRandomValue(30,40))
			end

			local Push = Instance.new("BodyVelocity")
			Push.Parent = TargetCharacter.HumanoidRootPart
			if TargetCharacter:FindFirstChild("Transformed") ~= nil or TargetPlayer:FindFirstChild("Transformed") ~= nil then
				TargetCharacter.Humanoid.Jump = true
			end
			tvlServerUtil.DestroyMoved(TargetCharacter)
			Push.Velocity =Vector3.new(60, 80, 60) * AttackingCharacter.Head.CFrame.LookVector
			RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
			task.wait(0.2)
			Push:Destroy()
			task.wait(1)
			RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
		else
			local RandomValue = GiveRandomValue(5,15)
			if TargetHumanoid.Health - RandomValue > 0 then
				tvlServerUtil.TakeDamage(TargetCharacter, RandomValue)
			end
		end
		task.delay(1.5,function()
			RemoveInfluency(AttackingCharacter)
			RemoveInfluency(TargetCharacter)
		end)
	else
		if AttackingCharacter:FindFirstChild("BiteCooldown") ~= nil then return end
		local isCustom = TargetPlayer.CharacterConfiguration:FindFirstChild("isCustom")
		local isStrix = isCustom and isCustom:FindFirstChild("StrixRip")
		ClientAnimationEvent:FireAllClients(WerewolfSoundFolder.bite,"replicate_sound",{SoundParent = TargetCharacter.Head})
		ClientAnimationEvent:FireClient(AttackingPlayer,WerewolfAnimationFolder.biteNew,"Char")
		--werewolf bite here
		coroutine.wrap(function()
			local bitecool = Instance.new("BoolValue",AttackingCharacter)
			bitecool.Name = "BiteCooldown"
			task.wait(15)
			bitecool:Destroy()
		end)()

		local isDouble
		local venomDamage
		if TargetPlayer.Character:FindFirstChild("HowlEffect") then
			isDouble = 1.5
		else
			isDouble = 1
		end
		if AttackingCharacter:FindFirstChild("VenomBuff") then
			venomDamage = 2.8*isDouble
		else
			venomDamage = 1.8*isDouble
		end
		local isQuest
		local var
		local dia = AttackingPlayer:FindFirstChild("Dialogue")
		if dia then
			if dia:FindFirstChild("WolfQuest") and not dia:FindFirstChild("WolfQuestComplete") then
				isQuest = true
			end
		end

		if isQuest then
			if not dia:FindFirstChild("WolfQuestProg") then
				var = Instance.new("IntValue")
				var.Name = "WolfQuestProg"
				var.Value = 0
				var.Parent = dia
			else
				var = dia:FindFirstChild("WolfQuestProg")
			end
		end


		if IsSpecie(TargetPlayer,{"Vampires","Rippers","Heretics","Originals"}) == true then
			if not isStrix and TargetCharacter:FindFirstChild("WolfVenom") == nil then
				if isQuest then
					var.Value += 1
				end
				local Var = Instance.new("IntValue",TargetCharacter)
				Var.Name = "WolfVenom"
				local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
				NotificationModule.Notification(TargetPlayer,"You've contracted Wolf Venom!")
				coroutine.resume(coroutine.create(function()
					while TargetCharacter:FindFirstChild("WolfVenom") ~= nil do
						if IsSpecie(TargetPlayer, {"Originals"}) then
							if (TargetCharacter.Humanoid.Health >= 5) or AttackingCharacter:FindFirstChild("VenomBuff") then
								TargetCharacter.Humanoid.Health -= venomDamage
								task.wait(0.25)
							else
								local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
								NotificationModule.Notification(TargetPlayer,"You're cured of Wolf Venom!")
								TargetCharacter:FindFirstChild("WolfVenom"):Destroy()
							end
						else
							tvlServerUtil.TakeDamage(TargetCharacter, venomDamage, true)
							task.wait(0.25)
						end
					end 
				end))
			end
		end

		if AttackingPlayer:FindFirstChild("Coins") then
			--AttackingPlayer.Coins.Value += math.random(9,14)
		end


		tvlServerUtil.TakeDamage(TargetCharacter, GiveRandomValue(3,10))
		task.delay(1.5,function()
			RemoveInfluency(AttackingCharacter)
			RemoveInfluency(TargetCharacter)
		end)
	end
end
function PlayerActionModule.Repulse(Character)
	local Player = game.Players:GetPlayerFromCharacter(Character)
	if not (IsSpecie(Player, { "Tribrids", "Werephoners", "Quadrabrids" }) or (IsSpecie(Player, { "Werewitches" }) and Player.CharacterConfiguration.CharacterName.Value == "Hope Mikaelson")) then
		return
	end
	if Character:FindFirstChild("ScreamCooldown") ~= nil then return end 
	if Character.WitchStats.Magic.Value < 350 then return end
	if IsRagdolled(Character) == true then return end
	if Character:FindFirstChild("Ghost") then return end
	if Character:FindFirstChild("Silenced") ~= nil then NotificationHandler.Notification(Player,"You've been silenced with magic, you cannot scream") return end
	--if GetEnergy(Character) < 250 then return end
	if Character:FindFirstChild("Casting") ~= nil then return end
	if Character:FindFirstChild("repulseCD") then return end
	local CharacterConfigFile = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)
	local Region = Region3.new(Player.Character.HumanoidRootPart.Position + Vector3.new(-40,-40,-40),Player.Character.HumanoidRootPart.Position + Vector3.new(40,40,40))
	local found = false
	local Instances = {}
	for i,plr in pairs(Players:GetPlayers()) do
		if plr ~= Player then
			local IdentifiedTarget = plr.Character.HumanoidRootPart
			if (IdentifiedTarget.Position - Character.HumanoidRootPart.Position).Magnitude < 40 then
				if IdentifiedTarget.Parent:FindFirstChild("IsProjecting") then continue end
				table.insert(Instances,IdentifiedTarget.Parent)
				found = true
				tvlServerUtil.DestroyMoved(IdentifiedTarget.Parent)
			end
		end
	end
	local value = Instance.new("BoolValue",Character)
	value.Name = "Casting"
	Debris:AddItem(value, 20)
	if Player.CharacterConfiguration:FindFirstChild("isCustom") then
		local cd = Instance.new("Folder")
		cd.Name = "repulseCD"
		cd.Parent = Character
		Debris:AddItem(cd, 60)
	end
	coroutine.wrap(function()
		local clone = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Objects.RepulsePoint:Clone()
		PlayAnimationEvent:FireClient(Player,WitchAnimationsFolder.RepulseAnim,"Char")
		clone.Parent = workspace
		clone.RepulsePart.CFrame = Character.UpperTorso.CFrame
		clone.RepulsePart.Center.CFrame = Character.UpperTorso.CFrame
		clone.RepulsePart.Outer.CFrame = Character.UpperTorso.CFrame
		clone.RepulsePart.SoundEffect:Play()
		TweenService:Create(clone.RepulsePart.PointLight,TweenInfo.new(0.5,Enum.EasingStyle.Exponential,Enum.EasingDirection.Out),{Range = 40}):Play()
		TweenService:Create(clone.RepulsePart.Center,TweenInfo.new(1,Enum.EasingStyle.Linear,Enum.EasingDirection.Out),{Size = Vector3.new(80,5,90)}):Play()
		TweenService:Create(clone.RepulsePart.Outer,TweenInfo.new(1,Enum.EasingStyle.Linear,Enum.EasingDirection.Out),{Size = Vector3.new(80,5,90)}):Play()
		TweenService:Create(clone.RepulsePart,TweenInfo.new(1,Enum.EasingStyle.Linear,Enum.EasingDirection.Out),{Size = Vector3.new(80,5,90)}):Play()
		TweenService:Create(clone.RepulsePart.Center,TweenInfo.new(2,Enum.EasingStyle.Linear,Enum.EasingDirection.Out),{Orientation = Vector3.new(0,360,0)}):Play()
		TweenService:Create(clone.RepulsePart.Outer,TweenInfo.new(2,Enum.EasingStyle.Linear,Enum.EasingDirection.Out),{Orientation = Vector3.new(0,360,0)}):Play()

		TweenService:Create(clone.RepulsePart.Outer,TweenInfo.new(2.3,Enum.EasingStyle.Linear),{Transparency = 1}):Play()
		TweenService:Create(clone.RepulsePart.Center,TweenInfo.new(2.3,Enum.EasingStyle.Linear),{Transparency = 1}):Play()
		TweenService:Create(clone.RepulsePart,TweenInfo.new(2.3,Enum.EasingStyle.Linear),{Transparency = 1}):Play()
		task.wait(2.5)

		clone:Destroy()

	end)()


	if found == false then return end

	for i,Target in pairs(Instances) do
		coroutine.wrap(function()
			local TargetPlayer = Players:GetPlayerFromCharacter(Target)

			PlayAnimationEvent:FireClient(TargetPlayer, "screenshake_ae", "Camera")
			RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
			local Push = Instance.new("BodyVelocity")
			Push.Parent = Target.HumanoidRootPart
			if Target:FindFirstChild("Transformed") ~= nil or TargetPlayer:FindFirstChild("Transformed") ~= nil then
				Target.Humanoid.Jump = true
			end
			Push.Velocity = CFrame.Angles(0,math.rad(math.random(-45,45)),0) * Character.Head.CFrame.LookVector * math.random(120,190)
			if Target:FindFirstChild("Regenerating") == nil then
				if IsSpecie(TargetPlayer,{"Vampires","Rippers","Heretics","Hybrids"}) and Target.Humanoid.Health <= (35+5) then
					Target.Humanoid.Health = 0
				elseif Character:FindFirstChild ("DahliaImmortal") or Character:FindFirstChild("SilasImmortal") or Target:FindFirstChild("ProtectionSpell") then
					if Target.Humanoid.Health <= (35+5) then
						Target.Humanoid.Health = 5
					else
						tvlServerUtil.TakeDamage(Character, 35)
					end
				else
					tvlServerUtil.TakeDamage(Target, 60)
				end

			end
			local t
			t = Target.HumanoidRootPart.Touched:Connect(function(Part)
				if Part.Transparency ~= 1 and Part.Anchored == true then
					t:Disconnect()
					Push:Destroy()
					task.wait(3)
					RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
				end
			end)
			task.wait(0.5)
			Target.HumanoidRootPart.Anchored = false
			tvlServerUtil.DestroyMoved(Target)
			if Push ~= nil then
				if t ~= nil then
					t:Disconnect()
				end
				Push:Destroy()
				task.wait(10)
				RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
			end
		end)()
	end
end
function PlayerActionModule.BloodChoke(AttackingCharacter,TargetCharacter)
	local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
	if TargetCharacter:FindFirstChild("Cade") ~= nil then return end
	if AttackingCharacter:FindFirstChild("isMind") then return end
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local CharacterConfigFolder = AttackingPlayer:FindFirstChild("CharacterConfiguration")
	local CharacterName = CharacterConfigFolder.CharacterName.Value
	local WitchSoundsFolder = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds
	local witchstats = AttackingCharacter:WaitForChild("WitchStats")
	if IsSpecie(AttackingPlayer,{"Witches","Heretics","Siphoners","Tribrids","Quadrabrids","Werewitches", "Werephoners" ,"Elder Witches","PyroWitches"}) == false then return end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
	if CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,30) == false then return end
	if AttackingCharacter:FindFirstChild("Casting") ~= nil then return end
	if AttackingCharacter:FindFirstChild("Powerless") ~= nil then return end
	if witchstats.Magic.Value < 150 then return end
	if TargetCharacter:FindFirstChild("IsProjecting") then return end
	local value = Instance.new("BoolValue",AttackingCharacter)
	value.Name = "Casting"
	coroutine.wrap(function()
		task.delay(20,function()
			value:Destroy()
		end)
	end)()
	TargetCharacter.Humanoid.WalkSpeed,TargetCharacter.Humanoid.JumpPower = 0,0
	TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic,TweenInfo.new(0.8),{Value = math.clamp(AttackingCharacter.WitchStats.Magic.Value - 150,0,AttackingCharacter.WitchStats.MaxMagic.Value)}):Play()
	PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.BloodChokeCast,"CharTemporary",{Duration = 10})
	PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.BloodChokeVictim,"Char")
	PlayAnimationEvent:FireAllClients(WitchSoundsFolder.Pain,"replicate_sound",{SoundParent = TargetCharacter.Head})
	local event
	local special = false

	ClientAnimationEvent:FireClient(TargetPlayer,"bloodchoke","Camera")

	RandomSpellSound(TargetCharacter.Head)

	local particle = ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects.BloodChoke:Clone()
	particle.Parent = TargetCharacter.Head
	particle.Enabled = true

	for i=0, 20, 1 do
		if TargetCharacter:FindFirstChild("Regenerating") == nil then
			tvlServerUtil.TakeDamage(TargetCharacter, 9)
			task.wait(0.5)
		end
	end

	particle:Destroy()
	RagdollRemoteEvent:FireClient(TargetPlayer,"ON")

	task.wait(5)

	RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")

	TargetCharacter.Humanoid.WalkSpeed,TargetCharacter.Humanoid.JumpPower = 16,50
	TargetCharacter.HumanoidRootPart.Anchored = false
end
function PlayerActionModule.Scratch(AttackingCharacter,TargetCharacter)
	local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local TargetHumanoid = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local witchstats = AttackingCharacter:WaitForChild("WitchStats")
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
	if IsRagdolled(TargetCharacter) == true or IsRagdolled(AttackingCharacter) == true then return end
	if CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,20) == false then return end
	if TargetCharacter:FindFirstChild("IsProjecting") then return end
	if AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Hope Mikaelson" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Dahlia"  and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Forbidden Pan" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Dahlia Hagen" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Deceptive" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Luna" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Rafael Waithe" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Aiden" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Keelin Malraux" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Finch Tarrayo" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Jed" and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Jackson Kenner"  and AttackingPlayer.CharacterConfiguration.CharacterName.Value ~= "Inadu Labonair" then return end
	if AttackingPlayer:FindFirstChild("Transformed") ~= nil then return end
	if witchstats.Magic.Value < 150 then return end
	if AttackingCharacter:FindFirstChild("bonecd") then return end
	AddInfluency(AttackingCharacter)
	AddInfluency(TargetCharacter)
	
	local bonecd = Instance.new("Folder")
	bonecd.Name = "bonecd"
	bonecd.Parent = AttackingCharacter
	Debris:AddItem(bonecd,3)

	TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic,TweenInfo.new(3),{Value = math.clamp(AttackingCharacter.WitchStats.Magic.Value - 50,0,AttackingCharacter.WitchStats.MaxMagic.Value)}):Play()
	ClientAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.Scratch,"Char")
	ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.ScratchVictim,"Char")
	task.wait(0.3)
	ClientAnimationEvent:FireAllClients(WitchSoundFolder:FindFirstChild(`Scratch{math.random(1, 2)}`),"replicate_sound",{SoundParent = TargetCharacter.Head})
	PlayAnimationEvent:FireClient(TargetPlayer, "screenshake_ae", "Camera")
	local Particles = VampireAssetsFolder.throatripblood.BloodChoke:Clone()
	Particles.Parent = TargetCharacter.Head
	Debris:AddItem(Particles, 0.5)

	if IsSpecie(TargetPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Customs","Hybrids","Tribrids","Heretics","Werewolves"}) == true then
		tvlServerUtil.TakeDamage(TargetPlayer, GiveRandomValue(55, 100))
	else
		tvlServerUtil.TakeDamage(TargetCharacter, GiveRandomValue(40,75))
	end

	task.delay(0.2, function()
		RemoveInfluency(AttackingCharacter)
		RemoveInfluency(TargetCharacter)
	end)
end

--Siphoner Actions
local SiphoningTable = {}
--[[
Self Siphon Function
]]
function PlayerActionModule.SelfSiphon(Character, TupleTable)
	local Player = 	Players:GetPlayerFromCharacter(Character)
	if TupleTable.Option == "OFF" then
		if SiphoningTable[Player] ~= "OVERRIDE" then
			SiphoningTable[Player] = nil
		end
		return
	end
	if Character:FindFirstChild("isMind") then return end
	if IsSpecie(Player,{"Heretics", "Quadrabrids"}) == false  then return end
	if Character:FindFirstChild("Ghost") ~= nil then return end
	if Character:FindFirstChild("Siphoning") ~= nil then return end
	if Character.VampireStats.Energy.Value <= 1 then return end
	if SiphoningTable[Player] then return end
	SiphoningTable[Player] = true
	Character.RightHand.Siphon.Enabled = true
	local Extracting = Instance.new("BoolValue",Character)
	Extracting.Name = "Siphoning"
	local sound = WitchSoundFolder.SiphonSound:Clone() :: Sound
	sound.Looped = true
	sound.Parent = Character.RightHand
	sound:Play()
	local stats = Character:FindFirstChild("VampireStats") or Character:FindFirstChild("WolfStats")
	local track = Character.Humanoid.Animator:LoadAnimation(WitchAnimationsFolder.SelfSiphon) :: AnimationTrack
	track:Play()
	local startTime = os.clock()
	pcall(function()
		local twTime = 0.2
		while SiphoningTable[Player] do
			task.wait(1)
			if stats.Energy.Value <= 0 or Character.WitchStats.Magic.Value >= Character.WitchStats.MaxMagic.Value then
				break
			end
			TweenModule:GetTweenObject(stats.Energy, TweenInfo.new(twTime), { Value = math.max(stats.Energy.Value - 20, 0) }):Play()
			TweenModule:GetTweenObject(Character.WitchStats.Magic, TweenInfo.new(twTime), { Value = math.min(Character.WitchStats.Magic.Value + 120, Character.WitchStats.MaxMagic.Value) }):Play()
			if Character:FindFirstChild("WolfVenom") then
				local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
				NotificationModule.Notification(Player,"You're cured of Wolf Venom!")
				Character:FindFirstChild("WolfVenom"):Destroy()
			end
			if Character:FindFirstChild("StrixPoison") then
				local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
				NotificationModule.Notification(Player,"You're cured of the cursed venom!")
				Character:FindFirstChild("StrixPoison"):Destroy()
			end
		end
		if Character.WitchStats.Magic.Value >= Character.WitchStats.MaxMagic.Value then
			tvlServerUtil.Hint(Player, "Your magic is at full capacity!")
		elseif stats.Energy.Value > 0 and os.clock() - startTime < 0.6 then
			tvlServerUtil.Hint(Player, "You have to hold press to siphon your character to your latest energy!")
		end
		Character.WitchStats.SiphoningCooldown.Value = true
	end)
	SiphoningTable[Player] = nil
	track:Stop()
	sound.Looped = false
	game:GetService("Debris"):AddItem(sound, sound.TimeLength)
	if Player:FindFirstChild("Coins") and os.clock() - startTime >= 1.25 then
		Player.Coins.Value += math.random(9,14)
	end
	task.delay(0.5,function()
		Character.RightHand.Siphon.Enabled = false
	end)
	task.wait(7)
	Extracting:Destroy()
	Character.WitchStats.SiphoningCooldown.Value = false
end

--Siphon Others Function
function PlayerActionModule.Siphon(AttackingCharacter,TargetCharacter,Toggled)
	local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
	local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
	if Toggled == "OFF" then
		if SiphoningTable[AttackingPlayer] ~= "OVERRIDE" then
			SiphoningTable[AttackingPlayer] = nil
		end
		return
	end
	local darkObject = if TargetCharacter.Name == "DarkObject" then TargetCharacter else nil
	local barrier = if TargetCharacter:FindFirstChild("Magic") and TargetCharacter:FindFirstChild("Owner") then TargetCharacter else nil
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local TargetPlayer = if TargetCharacter:IsA("Model") then Players:GetPlayerFromCharacter(TargetCharacter) else nil
	if AttackingCharacter:FindFirstChild("isMind") then return end
	if TargetPlayer and TargetPlayer:FindFirstChild("Transformed") ~= nil then return end
	--if AttackingCharacter:FindFirstChild("Siphoning") ~= nil then return end
	if TargetCharacter:IsA("Model") and CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
	if TargetCharacter:IsA("Model") and IsRagdolled(TargetCharacter) == true or IsRagdolled(AttackingCharacter) == true then return end
	if IsSpecie(AttackingPlayer,{"Siphoners","Heretics","Werephoners","Quadrabrids"}) == false then return end	
	if CheckDistance(if TargetCharacter:IsA("Model") then TargetCharacter.HumanoidRootPart else TargetCharacter,AttackingCharacter.HumanoidRootPart,15) == false then return end
	if TargetCharacter:IsA("Model") and not TargetCharacter:FindFirstChild("WitchStats") and not TargetCharacter:FindFirstChild("VampireStats") then return end
	if TargetCharacter:FindFirstChild("Siphoning") then return end
	if AttackingCharacter.WitchStats.SiphoningCooldown.Value == true then return end
	if SiphoningTable[AttackingPlayer] then return end
	SiphoningTable[AttackingPlayer] = if TargetCharacter:IsA("Model") then true else "OVERRIDE"
	AttackingCharacter.RightHand.Siphon.Enabled = true
	if TargetCharacter:IsA("Model") then
		AttackingCharacter.HumanoidRootPart.CFrame = TargetCharacter.HumanoidRootPart.CFrame * CFrame.new(0,0,-2) * CFrame.Angles(0,math.rad(180),0)
	end
	local Extracting
	if not barrier then
		Extracting = Instance.new("BoolValue",TargetCharacter)
		Extracting.Name = "Siphoning"
	end
	local sound = WitchSoundFolder.SiphonSound:Clone() :: Sound
	sound.Looped = true
	sound.Parent = AttackingCharacter.RightHand
	sound:Play()
	local track = AttackingCharacter.Humanoid.Animator:LoadAnimation(WitchAnimationsFolder.Siphon) :: AnimationTrack
	track:Play()
	local startTime = os.clock()
	if darkObject then
		if darkObject.Siphoned.Value == false then
			darkObject.Siphon.Enabled = false
			darkObject.Siphoned.Value = true
			TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic, TweenInfo.new(4), { Value = math.min(AttackingCharacter.WitchStats.Magic.Value + 300,AttackingCharacter.WitchStats.MaxMagic.Value) }):Play()

			task.delay(45, function()
				darkObject.Siphon.Enabled = true
				darkObject.Siphoned.Value = false
			end)	

			task.wait(4)
		end
	elseif barrier then
		if barrier.Magic.Value > 0 and barrier.Owner.Value ~= "" then
			local magic = math.random(25, 50)
			if AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Forbidden Pan" then magic *= 2 end
			barrier.Magic.Value = math.max(barrier.Magic.Value - magic, 0)
			if barrier.Magic.Value >= 300 then
				NotificationHandler.Notification(AttackingPlayer, "This barrier is enduring! Keep trying!")
			elseif barrier.Magic.Value >= 100 then
				NotificationHandler.Notification(AttackingPlayer, "Your siphoning has weakened this barrier spell!")
			else
				NotificationHandler.Notification(AttackingPlayer, "Almost broken...")
			end
			pcall(function()
				TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic, TweenInfo.new(4), { Value = math.min(AttackingCharacter.WitchStats.Magic.Value + magic,AttackingCharacter.WitchStats.MaxMagic.Value) }):Play()
			end)
			local offsetPosition = barrier.CFrame:ToObjectSpace(AttackingCharacter.RightHand.CFrame)
			local nearestCFrame = barrier.CFrame * CFrame.new(
				math.clamp(offsetPosition.X, -barrier.Size.X / 2, barrier.Size.X / 2),
				math.clamp(offsetPosition.Y + 1.25, -barrier.Size.Y / 2, barrier.Size.Y / 2),
				math.clamp(offsetPosition.Z, -barrier.Size.Z / 2, barrier.Size.Z / 2)
			)
			task.wait(0.15)
			local effect = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects.SiphonEffect:Clone()
			effect.CFrame = nearestCFrame
			effect.Parent = workspace
			task.wait(3.85)
			effect.Wave.Enabled = false
			game:GetService("Debris"):AddItem(effect, 2)
		end
	else
		local magicDecrease = 20
		local magicIncrease = 50
		local energyDecrease = 10
		local thirstDecrease = 5
		if AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Forbidden Pan" then
			energyDecrease *= 2
			magicDecrease *= 2
			thirstDecrease *= 1.5
		end
		local Moved = Instance.new("Folder")
		Moved.Name = "Moved"
		Moved.Parent = AttackingCharacter
		Movement(AttackingCharacter, false)
		Movement(TargetCharacter, false)
		tvlServerUtil.AddInfluency(TargetCharacter)
		while SiphoningTable[AttackingPlayer] do
			task.wait(0.6)
			if not CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,7) or not Moved:IsDescendantOf(AttackingCharacter) or not AttackingCharacter:IsDescendantOf(workspace) or not TargetCharacter:IsDescendantOf(workspace) then
				break
			end
			local targetHasStats = false
			local isOverZero = false
			local witchStats = AttackingCharacter:FindFirstChild("WitchStats")
			if not witchStats then
				break
			end
			if witchStats.Magic.Value >= witchStats.MaxMagic.Value then
				break
			end
			if TargetCharacter:FindFirstChild("VampireStats") then
				targetHasStats = true
				TweenModule:GetTweenObject(TargetCharacter.VampireStats.Energy, TweenInfo.new(0.2), { Value = math.max(TargetCharacter.VampireStats.Energy.Value - energyDecrease, 0) }):Play()
				TweenModule:GetTweenObject(TargetCharacter.VampireStats.Thirst, TweenInfo.new(0.2), { Value = math.max(TargetCharacter.VampireStats.Thirst.Value - thirstDecrease, 0) }):Play()
				if not isOverZero then
					isOverZero = TargetCharacter.VampireStats.Energy.Value > 0 or TargetCharacter.VampireStats.Thirst.Value > 0
				end	
			end
			if TargetCharacter:FindFirstChild("WitchStats") then
				targetHasStats = true
				TweenModule:GetTweenObject(TargetCharacter.WitchStats.Magic, TweenInfo.new(0.2), { Value = math.max(TargetCharacter.WitchStats.Magic.Value - magicDecrease, 0) }):Play()
				if not isOverZero then
					isOverZero = TargetCharacter.WitchStats.Magic.Value > 0
				end	
			end
			if TargetCharacter:FindFirstChild("WolfStats") then
				targetHasStats = true
				TweenModule:GetTweenObject(TargetCharacter.WolfStats.Energy, TweenInfo.new(0.2), { Value = math.max(TargetCharacter.WolfStats.Energy.Value - energyDecrease, 0) }):Play()
				if not isOverZero then
					isOverZero = TargetCharacter.WolfStats.Energy.Value > 0
				end		
			end
			if not targetHasStats or not isOverZero then
				break
			end
			TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic, TweenInfo.new(0.2), { Value = math.min(AttackingCharacter.WitchStats.Magic.Value + magicIncrease,AttackingCharacter.WitchStats.MaxMagic.Value) }):Play()
			if TargetCharacter:FindFirstChild("WolfVenom") then
				local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
				NotificationModule.Notification(TargetPlayer,"You're cured of Wolf Venom!")
				TargetCharacter:FindFirstChild("WolfVenom"):Destroy()
			end
			if TargetCharacter:FindFirstChild("StrixPoison") then
				local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
				NotificationModule.Notification(TargetPlayer,"You're cured of the cursed venom!")
				TargetCharacter:FindFirstChild("StrixPoison"):Destroy()
			end
		end
		Moved:Destroy()
		Movement(AttackingCharacter, true)
		Movement(TargetCharacter, true)
		tvlServerUtil.RemoveInfluency(TargetCharacter)
		if AttackingCharacter:FindFirstChild("WitchStats") and (AttackingCharacter.WitchStats.Magic.Value >= AttackingCharacter.WitchStats.MaxMagic.Value) then
			tvlServerUtil.Hint(AttackingPlayer, "Your magic is at full capacity!")
		elseif os.clock() - startTime < 0.6 then
			tvlServerUtil.Hint(AttackingPlayer, "You have to hold press to siphon your character to your latest energy!")
		end
	end
	pcall(function()
		AttackingCharacter.WitchStats.SiphoningCooldown.Value = true
	end)
	SiphoningTable[AttackingPlayer] = nil
	--if IsSpecie(TargetPlayer,{"Witches","Heretics","Siphoners","Tribrids","Werewitches","Elder Witches"}) == true then
	--	TweenModule:GetTweenObject(TargetCharacter.WitchStats.Magic,TweenInfo.new(4),{Value = math.clamp(TargetCharacter.WitchStats.Magic.Value - 100,0,TargetCharacter.WitchStats.MaxMagic.Value)}):Play()
	--elseif IsSpecie(TargetPlayer,{"Vampires","Originals","Hybrids","Tribrids"}) == true   then
	--	TweenModule:GetTweenObject(TargetCharacter.VampireStats.Thirst,TweenInfo.new(4),{Value = math.clamp(TargetCharacter.VampireStats.Thirst.Value - 75,0,TargetCharacter.VampireStats.MaxThirst.Value)}):Play()
	--	TweenModule:GetTweenObject(TargetCharacter.VampireStats.Energy,TweenInfo.new(4),{Value = math.clamp(TargetCharacter.VampireStats.Energy.Value - 75,0,TargetCharacter.VampireStats.MaxEnergy.Value)}):Play()
	--end
	--TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic,TweenInfo.new(4),{Value = math.clamp(AttackingCharacter.WitchStats.Magic.Value + 100,0,AttackingCharacter.WitchStats.MaxMagic.Value)}):Play()
	--if TargetPlayer.Character:FindFirstChild("WolfVenom") then
	--	local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
	--	NotificationModule.Notification(TargetPlayer,"You're cured of Wolf Venom!")
	--	TargetPlayer.Character:FindFirstChild("WolfVenom"):Destroy()
	--end
	--if TargetPlayer.Character:FindFirstChild("StrixPoison") then
	--	local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
	--	NotificationModule.Notification(TargetPlayer,"You're cured of the cursed venom!")
	--	TargetPlayer.Character:FindFirstChild("StrixPoison"):Destroy()
	--end
	track:Stop()
	sound.Looped = false
	game:GetService("Debris"):AddItem(sound, sound.TimeLength)
	task.wait(0.5)
	if AttackingPlayer:FindFirstChild("Coins") and os.clock() - startTime >= 1.25 then
		AttackingPlayer.Coins.Value += math.random(9,14)
	end
	AttackingCharacter.RightHand.Siphon.Enabled = false
	task.wait(5)
	if Extracting then Extracting:Destroy() end
	AttackingCharacter.WitchStats.SiphoningCooldown.Value = false
end

local function getTool(plr: Player, tool: string): Tool?
	return plr.Backpack:FindFirstChild(tool) or (plr.Character and plr.Character:FindFirstChild(tool))
end
--//Vampire Actions
--[[
Heartrip Function
@param "AttackingCharacter" - The Vampire that is attacking
@param "TargetCharacter" - The Person that is being attacked by the Vampire
]]
function PlayerActionModule.Heartrip(AttackingCharacter,TargetCharacter)
	local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local TargetHumanoid = TargetCharacter:FindFirstChildOfClass("Humanoid")
	if TargetPlayer:FindFirstChild("Transformed") ~= nil then return end
	local isStrix = false

	if AttackingPlayer.CharacterConfiguration:FindFirstChild("isCustom") then
		if AttackingPlayer.CharacterConfiguration.isCustom:FindFirstChild("StrixRip") then
			isStrix = true
		end
	end

	if TargetCharacter:FindFirstChild("DahliaImmortal") then
		NotificationHandler.Notification(AttackingPlayer,"They're immortal, it won't work!")
		return
	end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
	if IsRagdolled(TargetCharacter) == true or IsRagdolled(AttackingCharacter) == true then return end
	if IsSpecie(AttackingPlayer,{"Originals","UpgradedOriginals","Customs","Tribrids", "Quadrabrids"}) == false and not tvlServerUtil.devCheck(AttackingPlayer) and isStrix == false then return end	
	if CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,7) == false then return end
	if AttackingCharacter:FindFirstChild("IsProjecting") or TargetCharacter:FindFirstChild("IsProjecting") then return end
	if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Qetsiyah" or TargetPlayer.CharacterConfiguration.CharacterName.Value == "Esther Mikaelson" or TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" or TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia" or  TargetPlayer.CharacterConfiguration.CharacterName.Value == "Freya" or  TargetPlayer.CharacterConfiguration.CharacterName.Value == "Freya Mikaelson" then
		if IsSpecialWitch(TargetPlayer) == true then
			AddInfluency(AttackingCharacter)
			ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.OssoxCast,"Char")
			if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia" or TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia Hagen" then
				--ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Dahlia.PowerfulVoiceLine,"replicate_sound",{SoundParent = TargetCharacter.Head})

			elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Esther Mikaelson" then
				--ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Chapter2.Foolish,"replicate_sound",{SoundParent = TargetCharacter.Head})
			elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Freya" then

			else
				game:GetService("Chat"):Chat(TargetCharacter,"Ossox!",Enum.ChatColor.White)
			end
			TweenModule:GetTweenObject(TargetCharacter.WitchStats.Magic,TweenInfo.new(0.8),{Value = math.clamp(TargetCharacter.WitchStats.Magic.Value - 120,0,TargetCharacter.WitchStats.MaxMagic.Value)}):Play()
			task.wait(0.4)
			ClientAnimationEvent:FireClient(AttackingPlayer,"screenshake_ae","Camera")
			ClientAnimationEvent:FireAllClients(WitchSoundFolder.SpecialCast2,"replicate_sound",{SoundParent = TargetCharacter.Head})	
			ClientAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
			PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.NeckSnapped,"Char")

			if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" then
				local GeneratedSound = math.random(0,1)
				DarkJosieFace(TargetPlayer,true)
				coroutine.wrap(function()
					task.wait(3)
					SleepFace(TargetPlayer,true)
					task.wait(0.5)
					DarkJosieFace(TargetPlayer,false)
				end)()
				if TargetCharacter:FindFirstChild("Ascendo") then
					ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.AscendoGiggle,"Char")
				else
					ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.Giggle,"Char")
				end
				if GeneratedSound == 0 then
					PlayAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.Laugh,"replicate_sound",{SoundParent = TargetCharacter.Head})
					PlayAnimationEvent:FireClient(TargetPlayer,game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.LaughAnim,"Char")
				else
					PlayAnimationEvent:FireClient(TargetPlayer,game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.LaughAnim,"Char")
					PlayAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.Giggle,"replicate_sound",{SoundParent = TargetCharacter.Head})
				end
				GeneratedSound = nil
			elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Zara Malory" then
				PlayAnimationEvent:FireClient(TargetPlayer,ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.CustomLaugh,"Char")
				PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.Giggle,"Char")
			end
			task.wait(0.4)
			RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")

			SleepFace(AttackingPlayer,true)
			task.wait(1.5)
			if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia" then
				ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Dahlia.PowerfulVoiceLine,"replicate_sound",{SoundParent = TargetCharacter.Head})

			elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Bonnie Bennett" then
				ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.BonBon.Embarrassed,"replicate_sound",{SoundParent = TargetCharacter.Head})

			elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" then
				ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.DJ.Strike,"replicate_sound",{SoundParent = TargetCharacter.Head})


			elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Esther Mikaelson" then
				ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Chapter2.Foolish,"replicate_sound",{SoundParent = TargetCharacter.Head})
			end
			if IsSpecie(AttackingPlayer,{"Werewolves","Werewitches"}) == true then
				tvlServerUtil.SetHealth(AttackingCharacter, 0)
			end
			coroutine.wrap(function()
				task.wait(15)
				RagdollRemoteEvent:FireClient(AttackingPlayer,"OFF")
				RemoveInfluency(AttackingCharacter)	
				SleepFace(AttackingPlayer,false)

			end)()
			return
		end
	end
	if tvlServerUtil.devCheck(TargetPlayer) then
		if IsSpecialWitch(TargetPlayer) == true then
			if TargetPlayer.CharacterConfiguration.CharacterName.Value ~= "iltria" then
				NotificationHandler.Notification(AttackingPlayer,TargetPlayer.CharacterConfiguration.CharacterName.Value.."'s magic protects them from danger")

			else
				NotificationHandler.Notification(AttackingPlayer, "weirdo")
			end
			AddInfluency(AttackingCharacter)
			ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.OssoxCast,"Char")
			local bv = Instance.new("BodyVelocity",AttackingCharacter.Head)
			AttackingCharacter.Humanoid.Jump = true
			TweenModule:GetTweenObject(TargetCharacter.WitchStats.Magic,TweenInfo.new(0.8),{Value = math.clamp(TargetCharacter.WitchStats.Magic.Value - 120,0,TargetCharacter.WitchStats.MaxMagic.Value)}):Play()
			RandomSpellSound(TargetCharacter.Head)
			RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
			task.wait(3)

			ClientAnimationEvent:FireClient(AttackingPlayer,"screenshake_ae","Camera")

			bv:Destroy()
			ClientAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
			PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.NeckSnapped,"Char")
			task.wait(0.4)
			if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Zara Malory" or TargetPlayer.CharacterConfiguration.CharacterName.Value == "Forbidden Pan" then
				PlayAnimationEvent:FireClient(TargetPlayer,ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.CustomLaugh,"Char")
				PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.Giggle,"Char")
			end
			local VoiceLines = {
				"Shouldn't have tried it",
				"You're too weak to kill me",
				"Foolish move",
				"That was a bit dumb, wasn't it?",
				"Try harder next time",
				"Stop trying to kill me",
				"Your attempts are pathetic",
				"And what do you think you're doing?",
			}
			local RandomLine = VoiceLines[GiveRandomValue(1,#VoiceLines)]
			if TargetPlayer.CharacterConfiguration.CharacterName.Value ~= "iltria" then
				NotificationHandler.AdvancedNotification(AttackingPlayer,10,TargetPlayer.CharacterConfiguration.CharacterName.Value.."'s Telepathy","Stop trying to kill me")

			else
				NotificationHandler.AdvancedNotification(AttackingPlayer,10,TargetPlayer.CharacterConfiguration.CharacterName.Value.."'s Telepathy","weirdo")
			end

			if IsSpecie(AttackingPlayer,{"Werewolves"}) == true then
				tvlServerUtil.SetHealth(AttackingCharacter, 0)
			end
			SleepFace(AttackingPlayer,true)
			coroutine.wrap(function()
				task.wait(15)
				RagdollRemoteEvent:FireClient(AttackingPlayer,"OFF")
				RemoveInfluency(AttackingCharacter)	
				SleepFace(AttackingPlayer,false)

			end)()
			return
		end
	end
	if tvlServerUtil.IsSpecie(TargetPlayer, {"Werephoners", "Quadrabrids"}) and TargetPlayer.CharacterConfiguration.CharacterName.Value ~= "Forbidden Pan" then
		NotificationHandler.Notification(AttackingPlayer,"Forbidden Pan's werephoner spell protects them...")
		tvlServerUtil.AddInfluency(AttackingCharacter)
		PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.OssoxCast,"Char")
		tvlServerUtil.RandomSpellSound(AttackingCharacter.Head)
		ClientAnimationEvent:FireClient(AttackingPlayer,"screenshake_ae","Camera")
		NotificationHandler.Notification(AttackingPlayer,TargetPlayer.CharacterConfiguration.CharacterName.Value.." has snapped your neck as revenge ?")
		local ChatService = game:GetService("Chat")
		ChatService:Chat(TargetCharacter,"Forbidden Pan's magic protects my soul and body, "..AttackingPlayer.CharacterConfiguration.CharacterName.Value,Enum.ChatColor.White)
		task.wait(0.4)
		PlayAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
		PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.NeckSnapped,"Char")
		tvlServerUtil.DestroyMoved(AttackingCharacter)
		task.wait(0.4)
		AttackingCharacter.HumanoidRootPart.Anchored = false
		RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
		tvlServerUtil.SleepFace(AttackingPlayer,true)

		tvlServerUtil.SetHealth(AttackingCharacter, if IsSpecie(AttackingPlayer, {"Werephoners"}) then 5 else 0)

		local revent = AttackingCharacter.Humanoid.StateChanged:Connect(function()
			if AttackingCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
				RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
			end
		end)
		coroutine.wrap(function()
			task.wait(15)
			revent:Disconnect()
			RagdollRemoteEvent:FireClient(AttackingPlayer,"OFF")
			tvlServerUtil.SleepFace(AttackingPlayer,false)
			tvlServerUtil.RemoveInfluency(AttackingCharacter)
		end)()
		return	
	end
	if IsSpecialWitch(TargetPlayer) == false or TargetPlayer.CharacterConfiguration.CharacterName.Value == "Hope Mikaelson" then
		local stake = getTool(TargetPlayer, "Wooden Stake") or getTool(TargetPlayer, "Mikael's White Oak Stake") or getTool(TargetPlayer, "White Oak Stake") or getTool(TargetPlayer, "3 Use White Oak Stake")
		if stake and stake:FindFirstChild("Tignal") then
			TargetCharacter.Humanoid:EquipTool(stake);
			if stake.Parent ~= TargetCharacter then stake.AncestryChanged:Wait() end
			(stake.Tignal :: BindableEvent):Fire(TargetPlayer, AttackingCharacter)
			return
		end
		Movement(AttackingCharacter,false)
		Movement(TargetCharacter,false)
		MoveFront(AttackingCharacter.HumanoidRootPart,TargetCharacter.HumanoidRootPart,1.65)
		AddInfluency(AttackingCharacter)
		AddInfluency(TargetCharacter)	
		ClientAnimationEvent:FireClient(AttackingPlayer,VampireAnimationsFolder.HeartripOriginalAttacker,"Char")
		ClientAnimationEvent:FireClient(TargetPlayer,VampireAnimationsFolder.HeartripOriginalTarget,"Char")
		ClientAnimationEvent:FireClient(AttackingPlayer,"HEARTRIP_ORIGINAL_CUTSCENE","Camera")
		TargetCharacter.HumanoidRootPart.Anchored = false
		tvlServerUtil.DestroyMoved(TargetCharacter)
		coroutine.wrap(function()
			task.wait(3)
			local Heart = VampireAssetsFolder.Heart:Clone()
			Heart.Parent = AttackingCharacter.LeftHand
			Heart.CFrame = AttackingCharacter.LeftHand.CFrame
			local Weld = Instance.new("WeldConstraint",Heart)
			Weld.Part0 = AttackingCharacter.LeftHand
			Weld.Part1 = Heart
			Heartbeat(Heart,5)
			PlayAnimationEvent:FireAllClients(VampireSoundFolder.Heartbeat,"replicate_sound",{SoundParent = Heart})
			ClientAnimationEvent:FireAllClients(VampireSoundFolder.HeartripIdle,"replicate_sound",{SoundParent = TargetCharacter.Head})
			task.wait(1)
			if AttackingPlayer:FindFirstChild("Coins") then
				AttackingPlayer.Coins.Value += math.random(20,30)
			end
			ClientAnimationEvent:FireAllClients(VampireSoundFolder.HeartripFinal,"replicate_sound",{SoundParent = TargetCharacter.Head})
			task.delay(2.5,function()
				Heart:Destroy()
			end)
		end)()
		task.wait(5)
		if IsSpecie(TargetPlayer,{"Originals","UpgradedOriginals","Customs","Tribrids","Werephoners","Quadrabrids"}) then
			RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
			local revent = TargetCharacter.Humanoid.StateChanged:Connect(function()
				if TargetCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
					RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
				end
			end)
			SleepFace(TargetPlayer,true)
			coroutine.wrap(function()
				task.wait(15)
				revent:Disconnect()
				RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
				SleepFace(TargetPlayer,false)
				RemoveInfluency(TargetCharacter)
			end)()
		elseif IsSpecie(TargetPlayer, { "TimeLords" }) then
			tvlServerUtil.TakeDamage(TargetCharacter, TargetCharacter.Humanoid.MaxHealth / 2, true)
			coroutine.wrap(function()
				task.wait(5)
				RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
				SleepFace(TargetPlayer,false)
				RemoveInfluency(TargetCharacter)
			end)()
		else
			tvlServerUtil.SetHealth(TargetCharacter, 0, true)
			RemoveInfluency(TargetCharacter)
		end
		task.wait(0.2)
		Movement(AttackingCharacter,true)
		Movement(TargetCharacter,true)
		RemoveInfluency(AttackingCharacter)

	else
		DoRandomSpell(TargetPlayer,AttackingPlayer)
	end
end

--[[
BitePlayer Function
@param "FeedingCharacter" - The Vampire that is feeding
@param "TargetCharacter" - The Person that is being healed by the Vampire
]]

function PlayerActionModule.BitePlayer(FeedingCharacter,TargetCharacter)
	local HumanoidCharacter = FeedingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local FeedingPlayer = Players:GetPlayerFromCharacter(FeedingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local TargetHumanoid = TargetCharacter:FindFirstChildOfClass("Humanoid")
	if FeedingCharacter:FindFirstChild("isMind") then return end
	local CharacterName = FeedingPlayer.CharacterConfiguration.CharacterName.Value
	if TargetPlayer:FindFirstChild("Transformed") ~= nil then return end
	local isStrix = false

	if FeedingPlayer.CharacterConfiguration:FindFirstChild("isCustom") then
		if FeedingPlayer.CharacterConfiguration.isCustom:FindFirstChild("StrixRip") then
			isStrix = true
		end
	end
	if IsRagdolled(TargetCharacter) == true or IsRagdolled(FeedingCharacter) == true then return end
	if IsSpecie(FeedingPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Customs","Hybrids","Tribrids","Heretics","TransitioningVampire","TransitioningHeretic","TransitioningHybrid", "TransitioningTribrid", "TransitioningQuadrabrid"}) == false  then return end
	if IsSpecie(TargetPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Customs","Hybrids","Tribrids","Heretics","TransitioningVampire","TransitioningHeretic","TransitioningHybrid", "TransitiongTribrid", "TransitioningQuadrabrid"}) == true and CharacterName ~= "Mikael Mikaelson" and isStrix == false and not IsSpecie(FeedingPlayer, { "UpgradedOriginals" }) then return end
	if CheckDistance(TargetCharacter.HumanoidRootPart,FeedingCharacter.HumanoidRootPart,15) == false then return end
	if CheckForFeeding(FeedingCharacter) == true then
		NotificationHandler.Notification(FeedingPlayer,"You are already feeding!")
	end
	if FeedingCharacter:FindFirstChild("CantFeed") ~= nil then NotificationHandler.Notification(FeedingPlayer,"You have been compelled to not feed.") return end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(FeedingCharacter) == true then return end
	if TargetCharacter:FindFirstChild("HasVervain") ~= nil  then NotificationHandler.Notification(FeedingPlayer,"They are laced with vervain, you cannot bite them!") AddInfluency(FeedingCharacter) tvlServerUtil.TakeDamage(FeedingCharacter, math.random(20, 25)) task.wait(2) RemoveInfluency(FeedingCharacter) return end
	if FeedingCharacter:FindFirstChild("IsProjecting") or TargetCharacter:FindFirstChild("IsProjecting") then return end

	if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Bonnie Bennett" or TargetPlayer.CharacterConfiguration.CharacterName.Value == "Tay" then
		PlayerActionModule.BloodChoke(TargetCharacter, FeedingCharacter)
		return
	end

	local isQuest
	local var
	local dia = FeedingPlayer:FindFirstChild("Dialogue")
	if dia then
		if dia:FindFirstChild("VampQuest") and not dia:FindFirstChild("VampQuestComplete") then
			isQuest = true
		end
	end

	if isQuest then
		if not dia:FindFirstChild("VampQuestProg") then
			var = Instance.new("IntValue")
			var.Name = "VampQuestProg"
			var.Value = 0
			var.Parent = dia
		else
			var = dia:FindFirstChild("VampQuestProg")
		end
	end

	MoveFront(FeedingCharacter.HumanoidRootPart,TargetCharacter.HumanoidRootPart,1.65)	
	AddFeeding(FeedingCharacter)
	Movement(FeedingCharacter,false)
	Movement(TargetCharacter,false)
	-- Ripper progression system
	local plr = Players:GetPlayerFromCharacter(FeedingCharacter)
	if plr then
		-- Create counter if not exists
		if not plr:FindFirstChild("RipperFeedCount") then
			local count = Instance.new("IntValue")
			count.Name = "RipperFeedCount"
			count.Value = 0
			count.Parent = plr
		end

		-- Add 1 feed
		plr.RipperFeedCount.Value += 1

		-- Only vampires can become rippers
		local specie = plr.CharacterConfiguration.Specie.Value
		if specie == "Vampires" and plr.RipperFeedCount.Value >= 50 then
			-- Turn into a ripper
			plr.CharacterConfiguration.Specie.Value = "Originals"

			-- Reset counter
			plr.RipperFeedCount.Value = 0

			-- Notification
			local NotificationHandler = require(game.ServerScriptService.MainUI.NotificationHandler)
			NotificationHandler.Notification(plr, "?? Your bloodlust has consumed you... You are now an Original Vampire.")

			-- Eye FX
			local eyeSound = game.ReplicatedStorage.ReplicatedAssets.VampireAssets.Sounds.VampireActions.vampireEyes
			game.ReplicatedStorage.RemoteEvents.AnimationClientEvent:FireClient(
				plr,
				eyeSound,
				"replicate_sound",
				{SoundParent = FeedingCharacter.Head}
			)
		end
	end

	AddInfluency(FeedingCharacter)
	AddInfluency(TargetCharacter)
	tvlServerUtil.CompleteTransition(FeedingPlayer)

	local function AddThirst(Character,Amount)
		local VampireFolder = Character:FindFirstChild("VampireStats")
		if VampireFolder ~= nil then
			local Thirst = VampireFolder.Thirst.Value
			local MaxThirst = VampireFolder.MaxThirst.Value
			VampireFolder.Thirst.Value = math.clamp(Thirst + Amount,0,MaxThirst)
		end
	end

	tvlServerUtil.BiteFace(FeedingPlayer,true)
	coroutine.wrap(function()
		ScreamSound(TargetPlayer)
		task.wait(0.4)
		ClientAnimationEvent:FireAllClients(VampireSoundFolder.feedPlayerCrunch,"replicate_sound",{SoundParent = TargetCharacter.Head})
	end)()
	local timing
	if IsSpecie(TargetPlayer,{"Rippers"}) == false then
		timing = 4.5
		ClientAnimationEvent:FireClient(FeedingPlayer,VampireAnimationsFolder.FeedAnimationNormalAttacker,"Char")
		ClientAnimationEvent:FireClient(TargetPlayer,VampireAnimationsFolder.FeedAnimationNormalTarget,"Char")
		ClientAnimationEvent:FireClient(FeedingPlayer,"FEED_VAMPIRE_CUTSCENE","Camera")
		ClientAnimationEvent:FireClient(TargetPlayer,"FEED_VAMPIRE_CUTSCENE_TARGET","Camera",{AttackerTorso = FeedingCharacter.HumanoidRootPart})	
	else	
		timing = 3.5
		ClientAnimationEvent:FireClient(FeedingPlayer,VampireAnimationsFolder.FeedAnimationAttacker,"Char")
		ClientAnimationEvent:FireClient(TargetPlayer,VampireAnimationsFolder.FeedAnimationTarget,"Char")
		ClientAnimationEvent:FireClient(FeedingPlayer,"FEED_VAMPIRE_RIPPER_CUTSCENE","Camera")
		ClientAnimationEvent:FireClient(TargetPlayer,"FEED_VAMPIRE_RIPPER_CUTSCENE_TARGET","Camera",{AttackerTorso = FeedingCharacter.HumanoidRootPart})
	end
	task.spawn(function()
		if tvlServerUtil.IsSpecie(FeedingPlayer, { "UpgradedOriginals" }) and not (tvlServerUtil.IsSpecie(TargetPlayer, { "UpgradedOriginals", "Tribrids" }) or tvlServerUtil.CharacterName(TargetPlayer) == "Niklaus Mikaelson") then
			task.spawn(function()
				local WolfVenom = Instance.new("Folder", TargetCharacter)
				WolfVenom.Name = "WolfVenom"
				while WolfVenom:IsDescendantOf(TargetCharacter) do
					if tvlServerUtil.IsSpecie(TargetPlayer, { "Vampires" }) then
						tvlServerUtil.TakeDamage(TargetCharacter, 200, true)
					elseif tvlServerUtil.IsSpecie(TargetPlayer, { "Rippers","Originals","Customs","Hybrids","Tribrids","Heretics" }) then
						TargetCharacter.Humanoid.Health -= 18
					else
						WolfVenom:Destroy()
						break
					end
					task.wait(0.25)
				end
			end)
		end
		for i = 0,5,1 do
			AddThirst(FeedingCharacter,GiveRandomValue(10,15))
			tvlServerUtil.TakeDamage(TargetCharacter, GiveRandomValue(5, 10))
			task.wait(0.6)
		end
		if FeedingCharacter.VampireStats.Thirst.Value >= FeedingCharacter.VampireStats.MaxThirst.Value then
			tvlServerUtil.Hint(FeedingPlayer, "You are fully fed!")
		end
	end)
	task.wait(timing)
	if isQuest then
		var.Value += 1
	end
	coroutine.wrap(function()
		task.wait(2)
		tvlServerUtil.BiteFace(FeedingPlayer,false)
	end)()
	Movement(FeedingCharacter,true)
	Movement(TargetCharacter,true)
	RemoveInfluency(FeedingCharacter)
	if tvlServerUtil.CharacterName(TargetPlayer) == "Dark Josie Saltzman" and IsSpecialWitch(TargetPlayer) == true then
		local GeneratedSound = math.random(0,1)
		if GeneratedSound == 0 then
			PlayAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.Laugh,"replicate_sound",{SoundParent = TargetCharacter.Head})
			PlayAnimationEvent:FireClient(TargetPlayer,game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.LaughAnim,"Char")
		else
			PlayAnimationEvent:FireClient(TargetPlayer,game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.LaughAnim,"Char")
			PlayAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.Giggle,"replicate_sound",{SoundParent = TargetCharacter.Head})

		end
		GeneratedSound = nil
		RagdollRemoteEvent:FireClient(FeedingPlayer,"ON")

		AddInfluency(FeedingCharacter)
		TweenModule:GetTweenObject(FeedingCharacter.VampireStats.Thirst,TweenInfo.new(0.8),{Value = math.clamp(FeedingCharacter.VampireStats.Thirst.Value - 100,0,FeedingCharacter.VampireStats.MaxThirst.Value)}):Play()
		tvlServerUtil.Dessicate(FeedingCharacter, true)
		coroutine.wrap(function()
			task.wait(15)
			tvlServerUtil.Dessicate(FeedingCharacter, false)
			RagdollRemoteEvent:FireClient(FeedingPlayer,"OFF")
			RemoveInfluency(FeedingCharacter)
		end)()
	end
	task.wait(3)
	RemoveInfluency(TargetCharacter)
	RemoveFeeding(FeedingCharacter)
end

--[[ WOLF HOWL DOG FORM ]]

function PlayerActionModule.WolfHowl(Character)
	local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
	local Player = Players:GetPlayerFromCharacter(Character)
	if not IsSpecie(Player, {"Werewolves", "Werewitches", "Werephoners", "Hybrids", "Tribrids","Quadrabrids"}) then return end
	if not Player:FindFirstChild("Transformed") then return end
	if Player:FindFirstChild("HowlCooldown") then 
		NotificationModule.Notification(Player,"Howl is on cooldown!")
		return
	end 

	local cd = Instance.new("IntValue")
	cd.Name = "HowlCooldown"
	cd.Parent = Player
	Debris:AddItem(cd, 60)

	coroutine.wrap(function()
		Character.Humanoid.WalkSpeed = 0
		task.wait(.2)
		Movement(Character, false)
		--local Howl = Player.Character.Humanoid:LoadAnimation(WerewolfAnimationFolder.howl)
		--Howl:Play()
		ClientAnimationEvent:FireClient(Player, WerewolfAnimationFolder.howlNew,"Char")
		task.wait(.2)
		ClientAnimationEvent:FireAllClients(WerewolfSoundFolder.howl,"replicate_sound",{SoundParent = Character.Head})
		task.wait(2)
		Movement(Character, true)
		for i,v in pairs(Players:GetPlayers()) do
			if v.Character ~= nil then
				if v:FindFirstChild("CharacterConfiguration") then
					if IsSpecie(v, {"Vampires", "Rippers", "Originals", "Heretics"}) then
						if (Character.HumanoidRootPart.Position - v.Character.HumanoidRootPart.Position).Magnitude <= 20 then
							coroutine.resume(coroutine.create(function()
								NotificationModule.Notification(v,"The howl weakened your resistance to wolf venom!")
								local ins = Instance.new("IntValue")
								ins.Name = "HowlEffect"
								ins.Parent = v.Character
								task.wait(20)
								if ins then 
									ins:Destroy()
								end
							end))
						end
					end
				end
			end
		end
	end)()
end

--[[ WOLF BITE HUMANM ]]

function PlayerActionModule.WolfBitePlayer(FeedingCharacter,TargetCharacter)
	local HumanoidCharacter = FeedingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local FeedingPlayer = Players:GetPlayerFromCharacter(FeedingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local TargetHumanoid = TargetCharacter:FindFirstChildOfClass("Humanoid")
	if FeedingCharacter:FindFirstChild("isMind") then return end
	local CharacterName = FeedingPlayer.CharacterConfiguration.CharacterName.Value
	if TargetPlayer:FindFirstChild("Transformed") ~= nil then return end
	if IsSpecie(FeedingPlayer, {"Hybrids", "Tribrids", "Werewitches", "Werephoners","Quadrabrids", "Werewolves"}) == false and CharacterName ~= "Niklaus Mikaelson" then return end

	local targetIsVamp
	local casterIsVamp

	local isQuest2
	local var2
	local dia2 = FeedingPlayer:FindFirstChild("Dialogue")
	if dia2 then
		if dia2:FindFirstChild("VampQuest") and not dia2:FindFirstChild("VampQuestComplete") then
			isQuest2 = true
		end
	end

	if isQuest2 then
		if not dia2:FindFirstChild("VampQuestProg") then
			var2 = Instance.new("IntValue")
			var2.Name = "VampQuestProg"
			var2.Value = 0
			var2.Parent = dia2
		else
			var2 = dia2:FindFirstChild("VampQuestProg")
		end
	end



	if IsSpecie(FeedingPlayer, {"Hybrids", "Tribrids","Quadrabrids"}) or CharacterName == "Niklaus Mikaelson" then
		casterIsVamp = true
	end
	local venomDamage
	local isDouble 
	if TargetPlayer.Character:FindFirstChild("HowlEffect") then
		isDouble = 1.5
	else
		isDouble = 1
	end
	if FeedingCharacter:FindFirstChild("VenomBuff") then
		venomDamage = 2.8*isDouble
	else
		venomDamage = 1.8*isDouble
	end
	if CheckDistance(TargetCharacter.HumanoidRootPart,FeedingCharacter.HumanoidRootPart,10) == false then return end
	if IsRagdolled(TargetCharacter) == true or IsRagdolled(FeedingCharacter) == true then return end
	if IsSpecie(FeedingPlayer,{"Werewolves","Werewitches", "Werephoners","Hybrids","Tribrids","Quadrabrids"}) == false and FeedingPlayer.CharacterConfiguration.CharacterName.Value ~= "Niklaus Mikaelson" then return end
	if not FeedingCharacter:FindFirstChild("HasMoonlightRing") and not IsSpecie(FeedingPlayer,{"Hybrids","Tribrids", "Werewitches", "Werephoners", "Quadrabrids", "Originals"}) then
		NotificationHandler.Notification(FeedingPlayer,"You need a Moonlight Ring to bite in human form!")
		return 
	end
	if IsSpecie(TargetPlayer,{"Vampires","Rippers","Originals","Customs","Heretics","TransitioningVampire","TransitioningHeretic","TransitioningHybrid","TransitioningQuadrabrid"}) == true and (CharacterName ~= "Niklaus Mikaelson" or CharacterName ~= "Hope Mikaelson") then 
		targetIsVamp = true
	end

	if CheckForFeeding(FeedingCharacter) == true then
		NotificationHandler.Notification(FeedingPlayer,"You are already biting!")
	end


	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(FeedingCharacter) == true then return end
	if FeedingCharacter:FindFirstChild("IsProjecting") or TargetCharacter:FindFirstChild("IsProjecting") then return end

	local isQuest
	local var
	local dia = FeedingPlayer:FindFirstChild("Dialogue")
	if dia then
		if dia:FindFirstChild("WolfQuest") and not dia:FindFirstChild("WolfQuestComplete") then
			isQuest = true
		end
	end

	if isQuest then
		if not dia:FindFirstChild("WolfQuestProg") then
			var = Instance.new("IntValue")
			var.Name = "WolfQuestProg"
			var.Value = 0
			var.Parent = dia
		else
			var = dia:FindFirstChild("WolfQuestProg")
		end
	end



	MoveFront(FeedingCharacter.HumanoidRootPart,TargetCharacter.HumanoidRootPart,1.65)	
	AddFeeding(FeedingCharacter)
	Movement(FeedingCharacter,false)
	Movement(TargetCharacter,false)

	AddInfluency(FeedingCharacter)
	AddInfluency(TargetCharacter)
	local function AddThirst(Character,Amount)
		local VampireFolder = Character:FindFirstChild("VampireStats")
		if VampireFolder ~= nil then
			local Thirst = VampireFolder.Thirst.Value
			local MaxThirst = VampireFolder.MaxThirst.Value
			VampireFolder.Thirst.Value = math.clamp(Thirst + Amount,0,MaxThirst)
		end
	end

	if casterIsVamp then
		VampireFace(FeedingPlayer,true)
	else
		WolfFace(FeedingPlayer,true)
	end

	coroutine.wrap(function()
		ScreamSound(TargetPlayer)
		task.wait(0.4)
		ClientAnimationEvent:FireAllClients(VampireSoundFolder.feedPlayerCrunch,"replicate_sound",{SoundParent = TargetCharacter.Head})
		if IsSpecie(FeedingPlayer,{"Originals","Hybrids","Tribrids","Quadrabrids"}) == true then
			TweenModule:GetTweenObject(FeedingCharacter.VampireStats.Energy,TweenInfo.new(1.5),{Value = math.clamp(FeedingCharacter.VampireStats.Energy.Value - 60,0,FeedingCharacter.VampireStats.MaxEnergy.Value)}):Play()
		end
		if IsSpecie(FeedingPlayer,{"Werewolves","Werewitches","Werephoners"}) == true then
			TweenModule:GetTweenObject(FeedingCharacter.WolfStats.Energy,TweenInfo.new(1.5),{Value = math.clamp(FeedingCharacter.WolfStats.Energy.Value - 80,0,FeedingCharacter.WolfStats.MaxEnergy.Value)}):Play()
		end
	end)()
	local timing
	timing = 4.5
	ClientAnimationEvent:FireClient(FeedingPlayer,WerewolfAnimationFolder.HumanBiteCaster,"Char")
	ClientAnimationEvent:FireClient(TargetPlayer,WerewolfAnimationFolder.HumanBiteVictim,"Char")


	coroutine.wrap(function()
		if not targetIsVamp and FeedingCharacter:FindFirstChild("VampireStats") then
			AddThirst(FeedingCharacter,GiveRandomValue(30,40))
		end

		local isCustom = TargetPlayer.CharacterConfiguration:FindFirstChild("isCustom")
		local isStrix = isCustom and isCustom:FindFirstChild("StrixRip")

		if targetIsVamp and not TargetCharacter:FindFirstChild("WolfVenom") and not isStrix then
			local Var = Instance.new("IntValue",TargetCharacter)
			Var.Name = "WolfVenom"

			local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
			NotificationModule.Notification(TargetPlayer,"You've contracted Wolf Venom!")

			if isQuest then
				var.Value += 1
			end
			coroutine.wrap(function()
				while TargetCharacter:FindFirstChild("WolfVenom") ~= nil do
					if IsSpecie(TargetPlayer, {"Originals"}) then
						if (TargetCharacter.Humanoid.Health >= 5) or FeedingCharacter:FindFirstChild("VenomBuff") then
							TargetCharacter.Humanoid.Health -= venomDamage
							task.wait(0.25)
						else
							local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
							NotificationModule.Notification(TargetPlayer,"You're cured of Wolf Venom!")
							TargetCharacter:FindFirstChild("WolfVenom"):Destroy()
						end
					else
						TargetCharacter.Humanoid.Health -= venomDamage
						task.wait(0.25)
					end

				end 
			end)()
		end
	end)()

	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://5705516527"
	sound.Parent = FeedingCharacter.HumanoidRootPart
	sound:Play()
	Debris:AddItem(sound, 5)
	tvlServerUtil.TakeDamage(TargetCharacter, 45)
	task.wait(timing)

	coroutine.wrap(function()
		task.wait(2)
		if casterIsVamp then
			VampireFace(FeedingPlayer,false)
		else
			WolfFace(FeedingPlayer,false)
		end

	end)()
	Movement(FeedingCharacter,true)
	Movement(TargetCharacter,true)
	RemoveInfluency(FeedingCharacter)
	if tvlServerUtil.CharacterName(TargetPlayer) == "Dark Josie Saltzman" and IsSpecialWitch(TargetPlayer) == true then

		local GeneratedSound = math.random(0,1)
		if GeneratedSound == 0 then
			PlayAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.Laugh,"replicate_sound",{SoundParent = TargetCharacter.Head})
			PlayAnimationEvent:FireClient(TargetPlayer,game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.LaughAnim,"Char")
		else
			PlayAnimationEvent:FireClient(TargetPlayer,game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.LaughAnim,"Char")
			PlayAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.Giggle,"replicate_sound",{SoundParent = TargetCharacter.Head})
		end
		GeneratedSound = nil
		RagdollRemoteEvent:FireClient(FeedingPlayer,"ON")

		task.delay(15, function()
			RagdollRemoteEvent:FireClient(FeedingPlayer,"OFF")
			SleepFace(FeedingPlayer,false)
		end)

		if casterIsVamp then
			if isQuest2 then
				var2.Value +=1
			end

			AddInfluency(FeedingCharacter)
			TweenModule:GetTweenObject(FeedingCharacter.VampireStats.Thirst,TweenInfo.new(0.8),{Value = math.clamp(FeedingCharacter.VampireStats.Thirst.Value - 100,0,FeedingCharacter.VampireStats.MaxThirst.Value)}):Play()
			tvlServerUtil.Dessicate(FeedingCharacter, true)
			coroutine.wrap(function()
				task.wait(15)
				tvlServerUtil.Dessicate(FeedingCharacter, false)
				RemoveInfluency(FeedingCharacter)
			end)()
		end
	end
	task.wait(1)
	RemoveInfluency(TargetCharacter)
	RemoveFeeding(FeedingCharacter)
end

---[[[COMPULSION]]]

function PlayerActionModule.Compulsion(Character,TargetCharacter)
	local success, Error = pcall(function()
		local targetCharacter = TargetCharacter
		local targetPlayer = game.Players:GetPlayerFromCharacter(targetCharacter)
		local Player1 = game.Players:GetPlayerFromCharacter(Character)
		local Humanoid = Character.Humanoid

		local CharacterName = Player1.CharacterConfiguration.CharacterName.Value
		if (targetCharacter.HumanoidRootPart.Position - Player1.Character.HumanoidRootPart.Position).Magnitude > 10 then return end
		if targetPlayer:FindFirstChild("Transformed") ~= nil then return end
		if targetPlayer == nil then return end
		if Character:FindFirstChild("isMind") then return end
		if targetPlayer:FindFirstChild("PhoenixDeath") ~= nil then return end
		if not IsSpecie(Player1, { "Vampires", "Originals", "Customs", "Heretics", "Hybrids", "Tribrids", "Quadrabrids", "Rippers", "UpgradedOriginals" }) then return end
		if not IsSpecie(Player1, { "Quadrabrids" }) then
			if not IsSpecie(targetPlayer, { "Vampires", "Phoenix", "Mortals", "Rippers", "Heretics", "Hybrids","PyroWitches" }) then 
				local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
				NotificationModule.Notification(Player1,"This species cannot be compelled!")
				return 
			end		
		end
		if TargetCharacter:FindFirstChild("IsProjecting") then return end
		local VampireWithVampire = false
		if tvlServerUtil.IsSpecie(Player1, { "Vampires", "Heretics", "Customs", "Hybrids", "Rippers" }) then
			if tvlServerUtil.IsSpecie(targetPlayer, { "Vampires", "Heretics", "Customs", "Hybrids", "Tribrids", "Originals", "UpgradedOriginals", "Rippers" }) then
				VampireWithVampire = true
			end
			if tvlServerUtil.IsSpecie(Player1, { "Originals", "UpgradedOriginals" }) and not tvlServerUtil.IsSpecie(targetPlayer, { "Originals", "UpgradedOriginals" }) then
				VampireWithVampire = false 
			end
			if tvlServerUtil.devCheck(Player1) then
				VampireWithVampire = false
			end
		end
		if IsSpecie(Player1, { "Quadrabrids" }) then VampireWithVampire = false end
		if VampireWithVampire == true then return end
		--if (Character.HumanoidRootPart.Position - targetCharacter.HumanoidRootPart.Position).Magnitude > 10 then return end	
		if targetCharacter:FindFirstChild("Influenced") ~= nil then return end
		if targetCharacter:FindFirstChild("Compulsion") ~= nil then return end
		if targetCharacter:FindFirstChild("DoingAbility") ~= nil then return end
		if Character:FindFirstChild("InTransition") ~= nil then return end
		if targetPlayer:FindFirstChild("Ghost") ~= nil then return end
		if TargetCharacter:FindFirstChild("Ghost") ~= nil then return end
		if not IsSpecie(Player1, { "Quadrabrids" }) then
			if targetCharacter:FindFirstChild("HasVervain") then
				local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
				NotificationModule.Notification(Player1,"Your target is laced with vervain!")
				return
			end
		end




		local charStats = Character:FindFirstChild("VampireStats")
		local charMaxEnergy = charStats:FindFirstChild("MaxEnergy")
		local charEnergy = charStats:FindFirstChild("Energy")
		local function checkEnergy()
			local amtToCheck = math.floor(charMaxEnergy.Value/4)
			if charEnergy.Value >= amtToCheck then
				return amtToCheck
			end
		end
		if not checkEnergy() then 
			local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
			NotificationModule.Notification(Player1,"Not enough energy!")
			return
		end



		local val3 = Instance.new("IntValue",Character)		
		val3.Name = "DoingAbility"
		local val = Instance.new("IntValue",targetCharacter)
		val.Name = "Compulsion"	
		Movement(TargetCharacter,false)
		AddInfluency(Character)
		Movement(Character,false)
		coreGuiEdit:FireClient(targetPlayer, "tool_off")

		Character.HumanoidRootPart.CFrame = targetCharacter.HumanoidRootPart.CFrame * CFrame.new(0,0,-2) * CFrame.Angles(0,math.rad(180),0)
		local ChatService = game:GetService("Chat")
		local VampCompulsionUI = game.ServerStorage.CompulsionUIs.VampireCompulsion
		local OGCompulsionUI = game.ServerStorage.CompulsionUIs.OriginalCompulsion
		local CompulsionUI = nil
		local buttons = nil 
		local endButton
		if IsSpecie(Player1,{"Originals","UpgradedOriginals","Customs","Tribrids", "Quadrabrids"}) or tvlServerUtil.devCheck(Player1) then
			CompulsionUI = OGCompulsionUI:Clone()
			CompulsionUI.Enabled = true
			CompulsionUI.Parent = Player1.PlayerGui
			buttons = CompulsionUI.Main.ScrollingFrame
			endButton = CompulsionUI.Main.nothing
		elseif IsSpecie(Player1,{"Vampires","Heretics","Hybrids","Rippers"}) then
			CompulsionUI = OGCompulsionUI:Clone()
			CompulsionUI.Enabled = true
			CompulsionUI.Parent = Player1.PlayerGui
			buttons = CompulsionUI.Main.ScrollingFrame
			endButton = CompulsionUI.Main.nothing
		end
		local t
		local no
		local hasStake
		local function playCompulSound()
			local compulSound = Instance.new("Sound")
			compulSound.Name = "compulsionSound"
			compulSound.SoundId = "rbxassetid://" .. 6732888106
			compulSound.Volume = 1.5
			compulSound.Parent = Player1.Character:FindFirstChild("HumanoidRootPart")
			compulSound:Play()
			Debris:AddItem(compulSound, 8)
		end

		local function stakeCheck(targetPlayer)
			local inChar1 = targetPlayer.Character:FindFirstChild("Wooden Stake")
			local inChar2 = targetPlayer.Character:FindFirstChild("Mikael's White Oak Stake")
			local x = targetPlayer.Backpack:FindFirstChild("Wooden Stake")
			local y = targetPlayer.Backpack:FindFirstChild("Mikael's White Oak Stake")

			if inChar1 then
				inChar1.Parent = targetPlayer.Backpack
				return inChar1
			elseif inChar2 then
				inChar2.Parent = targetPlayer.Backpack
				return inChar2
			end
			if x then
				return x
			elseif y then
				return y
			end
		end



		local function consumeEnergy()
			local x = checkEnergy()
			if x then
				charEnergy.Value -= x
			end
		end

		local dieConnect = TargetCharacter.Humanoid.Died:Connect(function()
			if CompulsionUI then
				CompulsionUI:Destroy()
			end
			if val3 then
				val3:Destroy()
			end
			Movement(Character,true)
			RemoveInfluency(Character)
			coreGuiEdit:FireClient(targetPlayer, "tool_on")
		end)

		coroutine.resume(coroutine.create(function()
			task.wait(15) --timeout until it autocloses
			if CompulsionUI then
				CompulsionUI:Destroy()
				Movement(Character,true)
				Movement(TargetCharacter,true)
				RemoveInfluency(Character)
				coreGuiEdit:FireClient(targetPlayer, "tool_on")
			end
			if CompulsionUI then
				CompulsionUI:Destroy()
			end
			if val3 then
				val3:Destroy()
			end
			if val then
				val:Destroy()
			end
		end))

		local charName 
		if targetPlayer.CharacterConfiguration:FindFirstChild("isCustom") then
			if targetPlayer.CharacterConfiguration.isCustom:FindFirstChild("CusDisplayName") then
				charName = targetPlayer.CharacterConfiguration.isCustom.CusDisplayName.Value
			end
		else
			charName = targetPlayer.CharacterConfiguration.CharacterName.Value
		end
		ChatService:Chat(Character,"Listen, "..string.split(charName," ")[1].."!",Enum.ChatColor.White)
		if endButton then
			no = endButton.MouseButton1Click:Connect(function()
				no:Disconnect()
				Character.Humanoid.WalkSpeed = 16
				CompulsionUI:Destroy()
				Movement(TargetCharacter,true)
				Movement(Character,true)
				RemoveInfluency(Character)
				val:Destroy()
				val3:Destroy()
				coreGuiEdit:FireClient(targetPlayer, "tool_on")
			end)
		end
		for i,button in pairs(buttons:GetChildren()) do
			if button:IsA("TextButton") then
				if button.Name == "stake_self" or button.Name == "ring" or button.Name == "dont_feed" then
					if not IsSpecie(targetPlayer,{"Vampires","Heretics","Hybrids","Rippers"}) then
						button:Destroy() 
						continue
						--ilt; debug
					end
				end
				if IsSpecie(targetPlayer, {"Heretics","Hybrids"}) and button.Name == "ring" then
					button:Destroy()
					continue
				end
				if button.Name == "give_stake" or button.Name == "stake_self" then
					if stakeCheck(targetPlayer) then
						hasStake = stakeCheck(targetPlayer)
					else
						button:Destroy()
						continue
					end
				end

				t =	button.MouseButton1Click:Connect(function()
					t:Disconnect()
					Character.Humanoid.WalkSpeed = 16
					if CompulsionUI then
						CompulsionUI:Destroy()
					end
					consumeEnergy()
					if button.Name == "walk_away" then
						playCompulSound()
						ChatService:Chat(Character,"Walk away.",Enum.ChatColor.White)
						if CompulsionUI then
							CompulsionUI:Destroy()
						end
						Movement(Character,true)
						Movement(TargetCharacter,true)
						RagdollRemoteEvent:FireClient(targetPlayer,"MOVEMENT_OFF")
						local character1Position = targetCharacter.HumanoidRootPart.Position
						local character2Position = Character.HumanoidRootPart.Position
						local positionDifference = character2Position - character1Position 
						local normalizedDirection = positionDifference.unit
						local RUN_DISTANCE = math.random(50,65)
						local targetAvoidanceLocation = character1Position + normalizedDirection * -1 * RUN_DISTANCE


						targetCharacter.Humanoid.WalkSpeed = 16
						TargetCharacter.Humanoid:MoveTo(targetAvoidanceLocation)
						TargetCharacter.Humanoid.MoveToFinished:Wait()
						RagdollRemoteEvent:FireClient(targetPlayer,"MOVEMENT_ON")

					elseif button.Name == "dont_talk" then
						playCompulSound()
						ChatService:Chat(Character,"Do not speak.",Enum.ChatColor.White)
						PlayAnimationEvent:FireClient(targetPlayer,"DisableChat","UI",{Duration = 60})
						TargetCharacter.Humanoid.WalkSpeed = 16
						Movement(Character,true)
						Movement(TargetCharacter,true)
						task.wait(30)
						PlayAnimationEvent:FireClient(targetPlayer,"enable_chat")
					elseif button.Name == "dont_move" then
						playCompulSound()
						ChatService:Chat(Character,"Do not move.",Enum.ChatColor.White)
						RagdollRemoteEvent:FireClient(targetPlayer,"MOVEMENT_OFF")
						Movement(Character,true)
						task.wait(15)
						RagdollRemoteEvent:FireClient(targetPlayer,"MOVEMENT_ON")
					elseif button.Name == "sleep" then
						local CharacterConfigFolder = targetPlayer:FindFirstChild("CharacterConfiguration")
						local CharacterConfiguration2 = require(game.ReplicatedStorage.ReplicatedModules.CharacterConfiguration)
						local CharacterName
						local OutfitName
						if CharacterConfigFolder ~= nil then
							CharacterName = CharacterConfigFolder.CharacterName.Value
							OutfitName = CharacterConfigFolder.OutfitName.Value
						end

						playCompulSound()
						ChatService:Chat(Character,"Forget that this ever happened and take a nap.",Enum.ChatColor.White)
						task.wait(2.5)
						Movement(Character,true)
						Movement(TargetCharacter,true)
						RagdollRemoteEvent:FireClient(targetPlayer,"ON")
						PlayAnimationEvent:FireClient(targetPlayer,"Countdown","UI",{Duration = 15,Message = Player1.Name.." has compelled you to fall asleep and forget what happened."})
						PlayAnimationEvent:FireClient(targetPlayer,"Darkness","CameraEffect",{Duration = 15})

						if CharacterName and OutfitName then
							targetPlayer.Character.Head.Face.Texture = CharacterConfiguration2[CharacterName].Outfits[OutfitName].SleepFace
						end

						SleepFace(targetPlayer,true)
						task.wait(15)
						SleepFace(targetPlayer,false)
						TargetCharacter.Humanoid.WalkSpeed = 16
						Movement(TargetCharacter,true)
						RagdollRemoteEvent:FireClient(targetPlayer,"OFF")
						if CharacterName and OutfitName then
							task.wait(0.5)
							targetPlayer.Character.Head.Face.Texture = CharacterConfiguration2[CharacterName].Outfits[OutfitName].Face.Texture
						end

					elseif button.Name == "give_stake" then
						playCompulSound()
						ChatService:Chat(Character,"Hand over that stake.",Enum.ChatColor.White)
						task.wait(1)
						if hasStake then
							local newStake = hasStake:Clone()
							newStake.Parent = Player1.Backpack
							hasStake:Destroy()
						end

						Movement(Character,true)
						Movement(TargetCharacter,true)



					elseif button.Name == "stake_self" then
						if hasStake then
							hasStake.Client:Destroy()
							hasStake.Server:Destroy()
							playCompulSound()
							Movement(Character,true)
							Movement(TargetCharacter,true)
							--RagdollRemoteEvent:FireClient(targetPlayer,"MOVEMENT_OFF")
							ChatService:Chat(Character,"Do me a favour and stake yourself.",Enum.ChatColor.White)
							task.wait(1)

							local stakeAnim = Instance.new("Animation")
							stakeAnim.AnimationId = "rbxassetid://96765421891871"

							local track = targetPlayer.Character.Humanoid.Animator:LoadAnimation(stakeAnim)

							hasStake.Parent = workspace

							local newweld = Instance.new("WeldConstraint")
							newweld.Part0 = targetPlayer.Character.RightHand
							hasStake.Handle.CFrame = targetPlayer.Character.RightHand.CFrame
							newweld.Part1 = hasStake.Handle


							--track.Priority = Enum.AnimationPriority.Action
							Movement(TargetCharacter,true)
							RagdollRemoteEvent:FireClient(targetPlayer,"MOVEMENT_ON")
							coreGuiEdit:FireClient(targetPlayer, "tool_on")
							track.Ended:Connect(function()
								newweld:Destroy()
								RemoveInfluency(Character)
								val:Destroy()
								val3:Destroy()
								targetPlayer.Character.Humanoid.Health = 0
								hasStake:Destroy()
							end)
							track:Play()
							task.wait(3)
							if hasStake.Handle then
								hasStake.Handle.StabSound:Play()
							end

						else
							Movement(Character,true)
							if CompulsionUI then
								CompulsionUI:Destroy()
							end
						end

					elseif button.Name == "ring" then

						local x = targetPlayer.Character:FindFirstChild("VampireStats"):FindFirstChild("HasRing")
						if x then
							local y = targetPlayer.Character:FindFirstChild("DaylightRingModel")
							playCompulSound()
							Movement(Character,true)
							Movement(TargetCharacter,true)

							ChatService:Chat(Character,"Take off your daylight ring.",Enum.ChatColor.White)
							local ringAnim = Instance.new("Animation")
							ringAnim.AnimationId = "rbxassetid://76375654977787"
							local track = targetPlayer.Character.Humanoid.Animator:LoadAnimation(ringAnim)
							track:Play()
							task.wait(1)
							x.Value = false
							if y then
								y:Destroy()
							end
						end

					elseif button.Name == "dont_feed" then
						playCompulSound()
						Movement(Character,true)
						Movement(TargetCharacter,true)
						ChatService:Chat(Character,"You can't feed anymore.",Enum.ChatColor.White)
						local nofeed = Instance.new("BoolValue")
						nofeed.Name = "CantFeed"
						nofeed.Value = true
						nofeed.Parent = targetPlayer.Character

					elseif button.Name == "nothing" then
						if CompulsionUI then
							CompulsionUI:Destroy()
						end

					end
					Movement(TargetCharacter,true)
					Movement(Character,true)
					RemoveInfluency(Character)
					val:Destroy()
					val3:Destroy()
					coreGuiEdit:FireClient(targetPlayer, "tool_on")
				end)
			end
		end


	end)
	if not success then
		print("ilt; error: " .. Error)
	end
end

function PlayerActionModule.ThroatRip(FeedingCharacter, TargetCharacter)
	local HumanoidCharacter = FeedingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local FeedingPlayer = Players:GetPlayerFromCharacter(FeedingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local TargetHumanoid = TargetCharacter:FindFirstChildOfClass("Humanoid")
	if FeedingCharacter:FindFirstChild("isMind") then return end
	local CharacterName = FeedingPlayer.CharacterConfiguration.CharacterName.Value
	if TargetPlayer:FindFirstChild("Transformed") ~= nil then return end

	if IsRagdolled(TargetCharacter) == true or IsRagdolled(FeedingCharacter) == true then return end
	if not IsSpecie(FeedingPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Customs","Hybrids","Tribrids","Heretics","Quadrabrids"}) then return end
	if IsSpecie(TargetPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Customs","Hybrids","Tribrids","Heretics","Quadrabrids"}) then return NotificationHandler.Notification(FeedingPlayer, "You can't use this on another Vampire!") end
	if CheckDistance(TargetCharacter.HumanoidRootPart,FeedingCharacter.HumanoidRootPart,15) == false then return end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(FeedingCharacter) == true then return end
	if FeedingCharacter:FindFirstChild("IsProjecting") or TargetCharacter:FindFirstChild("IsProjecting") then return end
	if FeedingCharacter:FindFirstChild("throatripCD") then return NotificationHandler.Notification(FeedingPlayer, "You must wait before using this ability.") end

	local cd = Instance.new("Folder")
	cd.Name = "throatripCD"
	cd.Parent = FeedingCharacter

	local isQuest
	local var
	local dia = FeedingPlayer:FindFirstChild("Dialogue")
	if dia then
		if dia:FindFirstChild("VampQuest") and not dia:FindFirstChild("VampQuestComplete") then
			isQuest = true
		end
	end

	if isQuest then
		if not dia:FindFirstChild("VampQuestProg") then
			var = Instance.new("IntValue")
			var.Name = "VampQuestProg"
			var.Value = 0
			var.Parent = dia
		else
			var = dia:FindFirstChild("VampQuestProg")
		end
	end

	MoveFront(FeedingCharacter.HumanoidRootPart,TargetCharacter.HumanoidRootPart,1.65)	
	Movement(FeedingCharacter,false)
	Movement(TargetCharacter,false)

	AddInfluency(FeedingCharacter)

	local function AddThirst(Character,Amount)
		local VampireFolder = Character:FindFirstChild("VampireStats")
		if VampireFolder ~= nil then
			local Thirst = VampireFolder.Thirst.Value
			local MaxThirst = VampireFolder.MaxThirst.Value
			VampireFolder.Thirst.Value = math.clamp(Thirst + Amount,0,MaxThirst)
		end
	end

	tvlServerUtil.BiteFace(FeedingPlayer,true)
	ScreamSound(TargetPlayer)
	local timing = 4.8
	ClientAnimationEvent:FireClient(FeedingPlayer,VampireAnimationsFolder.ThroatRipAttacker ,"Char")
	ClientAnimationEvent:FireClient(TargetPlayer,VampireAnimationsFolder.ThroatRipTarget,"Char")
	local Particles = VampireAssetsFolder.throatripblood.BloodChoke:Clone()
	Particles.Parent = TargetCharacter.Head
	coroutine.wrap(function()
		for i = 0,15,1 do
			AddThirst(FeedingCharacter,GiveRandomValue(4,8))
			tvlServerUtil.TakeDamage(TargetCharacter, GiveRandomValue(12, 16))
			task.wait(0.32)
		end
	end)()
	task.wait(timing)
	Particles.Enabled = false
	Debris:AddItem(Particles, Particles.Lifetime.Max)
	RagdollRemoteEvent:FireClient(TargetPlayer, "ON")
	if isQuest then
		var.Value += 1
	end
	coroutine.wrap(function()
		task.wait(2)
		tvlServerUtil.BiteFace(FeedingPlayer,false)
	end)()
	Movement(FeedingCharacter,true)
	Movement(TargetCharacter,true)
	RemoveInfluency(FeedingCharacter)
	task.wait(8)
	RagdollRemoteEvent:FireClient(TargetPlayer, "OFF")
	Debris:AddItem(cd, 3)
end

--[[
FeedPlayer Function
@param "FeedingCharacter" - The Vampire that is feeding
@param "TargetCharacter" - The Person that is being healed by the Vampire
]]
function PlayerActionModule.FeedPlayer(FeedingCharacter,TargetCharacter)
	local HumanoidCharacter = FeedingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local FeedingPlayer = Players:GetPlayerFromCharacter(FeedingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local CharacterName = FeedingPlayer.CharacterConfiguration.CharacterName.Value

	local Player1 = FeedingPlayer
	local targetPlayer = TargetPlayer
	local vamponvamp = false
	if tvlServerUtil.IsSpecie(Player1, { "Vampires", "Heretics", "Customs", "Hybrids", "Rippers" }) then
		if tvlServerUtil.IsSpecie(targetPlayer, { "Vampires", "Heretics", "Customs", "Hybrids", "Tribrids", "Originals", "UpgradedOriginals", "Rippers" }) then
			vamponvamp = true
			--ilt; debug
		end
		if CharacterName == "Hope Mikaelson" or CharacterName == "Niklaus Mikaelson" or IsSpecie(TargetPlayer, { "Werephoners", "Quadrabrids" })  then
			vamponvamp = false
		end
	end
	if vamponvamp then return end

	local TargetHumanoid = TargetCharacter:FindFirstChildOfClass("Humanoid")
	if TargetPlayer:FindFirstChild("Transformed") ~= nil then return end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(FeedingCharacter) == true then return end
	if IsRagdolled(TargetCharacter) == true or IsRagdolled(FeedingCharacter) == true then return end
	if not IsSpecie(FeedingPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Customs","Hybrids","Tribrids", "Quadrabrids","Heretics", "Werephoners"}) then return end
	if not IsSpecie(TargetPlayer,{"Witches", "Mortals", "Vampires","Rippers","Originals","Customs","Tribrids", "Quadrabrids","Heretics","Siphoners","Phoenix","Werewitches", "Werephoners","Werewolves","Elder Witches","PyroWitches"}) then return end
	if CheckDistance(TargetCharacter.HumanoidRootPart,FeedingCharacter.HumanoidRootPart,10) == false then return end
	if FeedingCharacter:FindFirstChild("IsProjecting") or TargetCharacter:FindFirstChild("IsProjecting") then return end
	--if TargetHumanoid.Health == TargetHumanoid.MaxHealth then return end
	MoveFront(FeedingCharacter.HumanoidRootPart,TargetCharacter.HumanoidRootPart,1.65)	
	Movement(FeedingCharacter,false)
	Movement(TargetCharacter,false)
	AddInfluency(FeedingCharacter)
	AddInfluency(TargetCharacter)
	local function Subtract(Character,Amount)
		local VampireFolder = Character:FindFirstChild("VampireStats")
		if VampireFolder ~= nil then
			local Thirst = VampireFolder.Thirst.Value
			local MaxThirst = VampireFolder.MaxThirst.Value
			TweenModule:GetTweenObject(VampireFolder.Thirst,TweenInfo.new(0.4),{Value = math.clamp(Thirst - Amount,0,MaxThirst)}):Play()
		end
	end


	local TargetCharacterName = TargetPlayer.CharacterConfiguration.CharacterName.Value
	if IsSpecie(TargetPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Hybrids","Tribrids","Heretics","Werewolves","Werewitches", "Werephoners"}) == false and TargetCharacterName ~= "Landon Kirby" and TargetCharacterName ~= "Dark Josie Saltzman" then
		AddVampireBlood(TargetCharacter)
	end
	if CharacterName == "Hope Mikaelson" or CharacterName == "Niklaus Mikaelson" or IsSpecie(FeedingPlayer, {"Werephoners", "Quadrabrids"}) then
		if IsSpecie(TargetPlayer,{"Werewolves","Werewitches","Werephoners"}) == true then
			print("bloodInSystemHope")
			AddVampireBlood(TargetCharacter)
		end
		if TargetCharacter:FindFirstChild("WolfVenom") then
			local NotificationModule = require(game.ServerScriptService.MainUI.NotificationHandler)
			NotificationModule.Notification(TargetPlayer,"You're cured of Wolf Venom!")
			TargetCharacter:FindFirstChild("WolfVenom"):Destroy()
		end
	end
	ClientAnimationEvent:FireClient(FeedingPlayer,VampireAnimationsFolder.GiveBloodToHumanAttacker,"Char")
	ClientAnimationEvent:FireClient(TargetPlayer,VampireAnimationsFolder.GiveBloodToHumanTarget,"Char")



	coroutine.wrap(function()
		task.wait(0.2)
		ClientAnimationEvent:FireAllClients(VampireSoundFolder.feedPlayerCrunch,"replicate_sound",{SoundParent = TargetCharacter.Head})
		task.wait(1.3)
		SleepFace(TargetPlayer,true)
	end)()
	coroutine.wrap(function()
		if TargetHumanoid ~= nil then
			if IsSpecie(FeedingPlayer, {"Werephoners"}) or IsSpecie(TargetPlayer,{"Mortals","Witches","Werewitches", "Werephoners","Werewolves","Siphoners","Phoenix","Elder Witches","PyroWitches"}) == true then
				local Value = GiveRandomValue(10,20)
				for i = 0,5,1 do
					Subtract(FeedingPlayer,Value)
					TargetHumanoid.Health += Value
					task.wait(0.4)
				end
			end
		end     
	end)()
	task.wait(5)
	SleepFace(TargetPlayer,false)
	Movement(FeedingCharacter,true)
	Movement(TargetCharacter,true)
	RemoveInfluency(FeedingCharacter)
	RemoveInfluency(TargetCharacter)

end


function PlayerActionModule.HopeScream(Character)
	local Player = game.Players:GetPlayerFromCharacter(Character)
	if Player.CharacterConfiguration.CharacterName.Value ~= "Hope Mikaelson" then return end
	if Character:FindFirstChild("ScreamCooldown") ~= nil then return end
	if Character.WitchStats.Magic.Value < 350 then return end
	if IsRagdolled(Character) == true then return end
	if Character:FindFirstChild("Ghost") then return end
	if Character:FindFirstChild("Silenced") ~= nil then NotificationHandler.Notification(Player,"You've been silenced with magic, you cannot scream") return end
	--if GetEnergy(Character) < 250 then return end
	local CharacterConfigFile = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)
	local Region = Region3.new(Player.Character.HumanoidRootPart.Position + Vector3.new(-40,-40,-40),Player.Character.HumanoidRootPart.Position + Vector3.new(40,40,40))
	local Instances = workspace:FindPartsInRegion3(Region,nil,math.huge)
	local found = false
	for i,part in pairs(Instances) do
		if part.Parent:FindFirstChildOfClass("Humanoid") ~= nil then
			if part.Parent:FindFirstChild("WigFlying") == nil then 
				if part.Parent.Name ~= Player.Name then
					if part.Parent:FindFirstChild("IsProjecting") then continue end
					found = true
				end
			end
		end
	end
	if found == false then return end
	local Scream = game.ReplicatedStorage.ReplicatedAssets.DLCFiles.HopeScream.ScreamSound:Clone()
	local screaming = Instance.new("BoolValue",Character)
	screaming.Name = "IsScreaming"
	Scream.Parent = Character.HumanoidRootPart
	local particle = game.ServerStorage.ScreamParticle.Attachment:Clone()
	task.spawn(function()
		task.wait(1.5)
		particle.Parent = Character.Head
		ClientAnimationEvent:FireAllClients(WitchSoundFolder.CastedSpell2,"replicate_sound",{SoundParent = Character.Head})
		task.wait(1.5)
		Scream:Play()
		ClientAnimationEvent:FireAllClients(WitchSoundFolder.CastedIctus,"replicate_sound",{SoundParent = Character.Head})
		Character.Head.Face.Texture = "rbxassetid://6629423958"
		TweenModule:GetTweenObject(Character.WitchStats.Magic,TweenInfo.new(3),{Value = math.clamp(Character.WitchStats.Magic.Value - 350,0,Character.WitchStats.MaxMagic.Value)}):Play()
	end)
	local cooldown = Instance.new("IntValue",Character)
	cooldown.Name = "ScreamCooldown"
	task.spawn(function()
		task.wait(90)
		cooldown:Destroy()
	end)
	task.spawn(function()
		task.wait(6.6)
		particle:Destroy()
		SleepFace(Player, false) -- reset face
		Scream:Destroy()
		screaming:Destroy()
	end)
	for i,part in pairs(Instances) do
		task.spawn(function()
			if part.Parent:FindFirstChildOfClass("Humanoid") ~= nil then
				if part.Parent:FindFirstChild("WigFlying") == nil then 
					local TargetCharacter = part.Parent
					local TargetPlayer = game.Players:GetPlayerFromCharacter(TargetCharacter)
					if TargetPlayer:FindFirstChild("Ghost") ~= nil then return end
					if TargetCharacter:FindFirstChild("Ghost") ~= nil then return end
					if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Forbidden Pan" then return end
					if TargetCharacter:FindFirstChild("IsProjecting") then return end
					local val = Instance.new("IntValue",TargetCharacter)
					val.Name = "WigFlying"
					if TargetPlayer ~= nil and TargetPlayer ~= Player then
						local AnimationTrack = Player.Character.Humanoid:LoadAnimation(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.HopeScream.Animation)
						task.spawn(function()
							task.wait(1)
							local victim = Instance.new("BoolValue",TargetCharacter)
							victim.Name = "ScreamVictim"
							ClientAnimationEvent:FireClient(TargetPlayer,"scream_victim","Camera")
							task.wait(2)
							AnimationTrack:Play()
							task.wait(10)
							victim:Destroy()
						end)
						Player.Character.Humanoid.WalkSpeed = 0
						Player.Character.Humanoid.JumpPower = 0
						task.spawn(function()
							task.wait(3)
							task.wait(AnimationTrack.Length)	
							Player.Character.Humanoid.WalkSpeed = 16
							Player.Character.Humanoid.JumpPower = 50					
						end)
						game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(TargetPlayer,"ON")
						local revent = TargetCharacter.Humanoid.StateChanged:Connect(function()
							if TargetCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
								RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
							end
						end)
						--	TargetCharacter.Head.Face.Texture = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)[TargetPlayer.CharacterConfiguration.CharacterName.Value].Outfits[TargetPlayer.CharacterConfiguration.OutfitName.Value].SleepFace

						local BodyVelocity = Instance.new("BodyVelocity",TargetCharacter.Head)
						task.spawn(function()
							task.wait(5)	
							tvlServerUtil.TakeDamage(TargetCharacter, math.random(80, 130))
							BodyVelocity:Destroy()
						end)
						task.wait(3)
						TargetCharacter.HumanoidRootPart.Anchored = false
						tvlServerUtil.DestroyMoved(TargetCharacter)
						local BV = Instance.new("BodyVelocity")
						BV.MaxForce = Vector3.new(math.huge,math.huge,math.huge)
						BV.Velocity = Player.Character.HumanoidRootPart.CFrame.lookVector * 80
						BV.Parent = TargetCharacter.HumanoidRootPart
						task.delay(1.5,function()
							BV:Destroy()
						end)
						task.wait(20)
						revent:Disconnect()
						game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(TargetPlayer,"OFF")
						--TargetCharacter.Head.Face.Texture = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)[TargetPlayer.CharacterConfiguration.CharacterName.Value].Outfits[TargetPlayer.CharacterConfiguration.OutfitName.Value].Face.Texture
						val:Destroy()
					end
				end
			end
		end)
	end
end
--[[
vampface function

]]


function PlayerActionModule.VampFace(Character)
	local Player = Players:GetPlayerFromCharacter(Character)
	if not IsSpecie(Player,{"Originals","UpgradedOriginals","Customs","Tribrids", "Quadrabrids","Vampires","Rippers","Heretics","Hybrids"}) and Player.CharacterConfiguration.CharacterName.Value ~= "Dark Josie Saltzman" then return end
	if IsRagdolled(Character) then return end
	if not Character:FindFirstChild("VampireFaced") and not Character:FindFirstChild("Transformed") and not Character:FindFirstChild("vfDb") then
		local vfDb = Instance.new("Folder")
		vfDb.Name = "vfDb"
		vfDb.Parent = Character
		Debris:AddItem(vfDb, 5)
		local val = Instance.new("BoolValue")
		val.Parent= Character
		val.Name = "VampireFaced"

		if Player.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" then
			SleepFace(Player,true)
			task.wait(0.5)
			--SleepFace(Player,false)
			DarkJosieFace(Player,true)
		else
			--SleepFace(Player,false)
			VampireFace(Player,true)
		end

	elseif Character:FindFirstChild("VampireFaced") and not Character:FindFirstChild("vfDb")  then
		local vfDb = Instance.new("Folder")
		vfDb.Name = "vfDb"
		vfDb.Parent = Character
		Debris:AddItem(vfDb, 5)

		if Player.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" then
			SleepFace(Player,true)
			task.wait(0.5)
			--SleepFace(Player,false)
			DarkJosieFace(Player,false)
		else
			--SleepFace(Player,false)
			VampireFace(Player,false)
		end


		local x = Character:FindFirstChild("VampireFaced")
		if x then x:Destroy() end
	end
end

function PlayerActionModule.Ictus(AttackingCharacter,TargetCharacter)
	local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	if AttackingPlayer:FindFirstChild("isMind") then return end
	local witchstats = AttackingCharacter:WaitForChild("WitchStats")
	local WitchSoundsFolder = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds
	if IsSpecie(AttackingPlayer,{"Witches","Heretics","Siphoners","Tribrids","Quadrabrids","Werewitches", "Werephoners","Elder Witches","PyroWitches"}) == false then return end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
	if CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,30) == false then return end
	if AttackingCharacter:FindFirstChild("Casting") ~= nil then return end
	if AttackingCharacter:FindFirstChild("Powerless") ~= nil then return end
	if AttackingCharacter.Humanoid.Health <= 0 then return end
	if witchstats.Magic.Value < 90 then return end
	if TargetCharacter:FindFirstChild("IsProjecting") then return end
	local value = Instance.new("BoolValue",AttackingCharacter)
	value.Name = "Casting"
	Debris:AddItem(value, 7)
	TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic,TweenInfo.new(0.8),{Value = math.clamp(AttackingCharacter.WitchStats.Magic.Value - 90,0,AttackingCharacter.WitchStats.MaxMagic.Value)}):Play()
	if AttackingCharacter:FindFirstChild("Choked") ~= nil then
		PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.OssoxCast,"Char")
	else
		PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.CastedIctus,"Char")
	end
	PlayAnimationEvent:FireClient(TargetPlayer,"screenshake_ae","Camera")
	task.wait(0.3)
	if TargetCharacter:FindFirstChild("Moved") ~= nil then
		TargetCharacter.HumanoidRootPart.Anchored = false
		tvlServerUtil.DestroyMoved(TargetCharacter)
	end;
	RandomSpellSound(AttackingCharacter.Head)
	PlayAnimationEvent:FireAllClients(WitchSoundsFolder.CastedIctus,"replicate_sound",{SoundParent = TargetCharacter.Head})
	RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
	local Push = Instance.new("BodyVelocity")
	Push.Parent = TargetCharacter.Head
	if TargetCharacter:FindFirstChild("Transformed") ~= nil or TargetPlayer:FindFirstChild("Transformed") ~= nil then
		TargetCharacter.Humanoid.Jump = true
	end
	Push.Velocity =Vector3.new(150, 450, 150) * AttackingCharacter.UpperTorso.CFrame.LookVector
	local t
	t = TargetCharacter.HumanoidRootPart.Touched:Connect(function(Part)
		if Part.Transparency ~= 1 and Part.Anchored == true then
			t:Disconnect()
			Push:Destroy()
			task.wait(5)
			RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
		end
	end)
	task.wait(0.3)
	if Push ~= nil then
		if t ~= nil then
			t:Disconnect()
		end
		Push:Destroy()
		task.wait(5)
		RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
	end
end
function PlayerActionModule.MagicScream(Character)
	local Player = game.Players:GetPlayerFromCharacter(Character)
	if Character:FindFirstChild("ScreamCooldown") ~= nil then return end 
	if Character.WitchStats.Magic.Value < 300 then return end
	if IsRagdolled(Character) == true then return end
	if Character:FindFirstChild("Ghost") then return end
	if Character:FindFirstChild("Silenced") ~= nil then NotificationHandler.Notification(Player,"You've been silenced with magic, you cannot scream") return end
	--if GetEnergy(Character) < 250 then return end
	local CharacterConfigFile = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)
	local Region = nil
	if Player.CharacterConfiguration.CharacterName.Value == "Carrie" then
		Region = Region3.new(Player.Character.HumanoidRootPart.Position + Vector3.new(-25,-25,-25),Player.Character.HumanoidRootPart.Position + Vector3.new(25,25,25))
	else
		Region = Region3.new(Player.Character.HumanoidRootPart.Position + Vector3.new(-40,-40,-40),Player.Character.HumanoidRootPart.Position + Vector3.new(40,40,40))
	end
	local Instances = workspace:FindPartsInRegion3(Region,nil,math.huge)
	local found = false
	for i,part in pairs(Instances) do
		if part.Parent:FindFirstChildOfClass("Humanoid") ~= nil then
			if part.Parent:FindFirstChild("WigFlying") == nil then 
				if part.Parent.Name ~= Player.Name then
					if part.Parent:FindFirstChild("IsProjecting") then continue end
					found = true
				end
			end
		end
	end
	if found == false then return end
	local Scream: Sound = nil
	if Player.CharacterConfiguration.CharacterName.Value == "Forbidden Pan" then
		Scream = WitchSoundFolder.Crazy:Clone()
	else
		Scream = WitchSoundFolder.InaduScream:Clone()
	end
	local screaming = Instance.new("BoolValue",Character)
	screaming.Name = "IsScreaming"
	Scream.Parent = Character.HumanoidRootPart
	Scream:Play()
	--local particle = game.ServerStorage.ScreamParticle.Attachment:Clone()

	TweenModule:GetTweenObject(Character.WitchStats.Magic,TweenInfo.new(1.5),{Value = math.clamp(Character.WitchStats.Magic.Value - 300,0,Character.WitchStats.MaxMagic.Value)}):Play()

	local cooldown = Instance.new("IntValue",Character)
	cooldown.Name = "ScreamCooldown"
	Debris:AddItem(cooldown, 80)
	task.spawn(function()
		Scream.Ended:Wait()
		--	particle:Destroy()
		Scream:Destroy()
		screaming:Destroy()
	end)
	for i,part in pairs(Instances) do
		task.spawn(function()
			if part.Parent:FindFirstChildOfClass("Humanoid") ~= nil then
				if part.Parent:FindFirstChild("WigFlying") == nil then 
					local TargetCharacter = part.Parent
					if TargetCharacter:FindFirstChild("Cade") ~= nil then return end
					local TargetPlayer = game.Players:GetPlayerFromCharacter(TargetCharacter)
					if TargetPlayer:FindFirstChild("Ghost") ~= nil then return end
					if TargetCharacter:FindFirstChild("Ghost") ~= nil then return end
					if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Forbidden Pan" then return end
					if TargetCharacter:FindFirstChild("IsProjecting") then return end
					local val = Instance.new("IntValue",TargetCharacter)
					val.Name = "WigFlying"
					if TargetPlayer ~= nil and TargetPlayer ~= Player then
						local AnimationTrack = Player.Character.Humanoid:LoadAnimation(WitchAnimationsFolder.ScreamingAnim)
						coroutine.wrap(function()
							task.wait(1)
							local victim = Instance.new("BoolValue",TargetCharacter)
							victim.Name = "ScreamVictim"
							ClientAnimationEvent:FireClient(TargetPlayer,"normal_shake","Camera")
							ClientAnimationEvent:FireClient(Player,"normal_shake","Camera")
							AnimationTrack:Play()
							task.wait(10)
							victim:Destroy()
						end)()
						Player.Character.Humanoid.WalkSpeed = 0
						Player.Character.Humanoid.JumpPower = 0
						task.spawn(function()
							task.wait(3)
							task.wait(AnimationTrack.Length)	
							Player.Character.Humanoid.WalkSpeed = 16
							Player.Character.Humanoid.JumpPower = 50					
						end)
						game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(TargetPlayer,"ON")
						local revent = TargetCharacter.Humanoid.StateChanged:Connect(function()
							if TargetCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
								RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
							end
						end)
						--	TargetCharacter.Head.Face.Texture = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)[TargetPlayer.CharacterConfiguration.CharacterName.Value].Outfits[TargetPlayer.CharacterConfiguration.OutfitName.Value].SleepFace
						local crit = Instance.new("BoolValue",TargetCharacter)
						crit.Name = "HealthCritical"
						task.spawn(function()
							task.wait(5)	
							if TargetCharacter:FindFirstChild("Regenerating") == nil then
								if IsSpecie(TargetPlayer,{"Vampires","Rippers","Heretics","Hybrids","Originals","UpgradedOriginals","Tribrids","Quadrabrids"}) and TargetCharacter.Humanoid.Health <= (80+5) then

									TargetCharacter.Humanoid.Health = 5
								elseif TargetCharacter:FindFirstChild ("DahliaImmortal") or TargetCharacter:FindFirstChild("SilasImmortal") or TargetCharacter:FindFirstChild("ProtectionSpell") then
									TargetCharacter.Humanoid.Health = 5
								else
									tvlServerUtil.TakeDamage(TargetCharacter, 80)
								end

							end
							crit:Destroy()
						end)
						task.wait(0.3)
						TargetCharacter.HumanoidRootPart.Anchored = false
						tvlServerUtil.DestroyMoved(TargetCharacter)
						coroutine.wrap(function()
							local BV = Instance.new("BodyVelocity")
							BV.MaxForce = Vector3.new(math.huge,math.huge,math.huge)
							BV.Velocity = Player.Character.HumanoidRootPart.CFrame.lookVector * 80
							BV.Parent = TargetCharacter.HumanoidRootPart
							task.wait(0.6)
							BV:Destroy()

							PlayAnimationEvent:FireClient(TargetPlayer,"Darkness","CameraEffect",{Duration = 15})

						end)()

						task.wait(10)
						revent:Disconnect()
						game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(TargetPlayer,"OFF")
						--TargetCharacter.Head.Face.Texture = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)[TargetPlayer.CharacterConfiguration.CharacterName.Value].Outfits[TargetPlayer.CharacterConfiguration.OutfitName.Value].Face.Texture
						val:Destroy()
					end
				end
			end
		end)
	end
end

function PlayerActionModule.Slam(Character)
	local Player = game.Players:GetPlayerFromCharacter(Character)
	print("hello")
	if Character:FindFirstChild("SlamCD") ~= nil then return end 
	if Character.WitchStats.Magic.Value < 250 then return end
	if IsRagdolled(Character) == true then return end


	local Region = nil
	if Player.CharacterConfiguration.CharacterName.Value == "Carrie" then
		Region = Region3.new(Player.Character.HumanoidRootPart.Position + Vector3.new(-25,-25,-25),Player.Character.HumanoidRootPart.Position + Vector3.new(25,25,25))
	else
		Region = Region3.new(Player.Character.HumanoidRootPart.Position + Vector3.new(-40,-40,-40),Player.Character.HumanoidRootPart.Position + Vector3.new(40,40,40))
	end
	local Instances = workspace:FindPartsInRegion3(Region,nil,math.huge)
	local found = false
	for i,part in pairs(Instances) do
		if part.Parent:FindFirstChildOfClass("Humanoid") ~= nil then
			if part.Parent:FindFirstChild("WigFlying") == nil then 
				if part.Parent.Name ~= Player.Name then
					if part.Parent:FindFirstChild("IsProjecting") then continue end
					found = true
				end
			end
		end
	end

	if found == false then return end

	--local Slam = WitchSoundFolder.Slam

	local slamvalue = Instance.new("BoolValue",Character)
	slamvalue.Name = "IsSlamming"
	--Slam.Parent = Character.HumanoidRootPart
	--Slam:Play()

	TweenModule:GetTweenObject(Character.WitchStats.Magic,TweenInfo.new(1.5),{Value = math.clamp(Character.WitchStats.Magic.Value - 250,0,Character.WitchStats.MaxMagic.Value)}):Play()

	local cooldown = Instance.new("IntValue",Character)
	cooldown.Name = "SlamCD"
	task.spawn(function()
		task.wait(80)
		cooldown:Destroy()
	end)
	task.spawn(function()
		task.wait(3)
		--	particle:Destroy()
		--Slam:Destroy()
		slamvalue:Destroy()
	end)

	for i,part in pairs(Instances) do
		task.spawn(function()
			if part.Parent:FindFirstChildOfClass("Humanoid") ~= nil then
				if part.Parent:FindFirstChild("WigFlying") == nil then 
					local TargetCharacter = part.Parent
					if TargetCharacter:FindFirstChild("Cade") ~= nil then return end
					local TargetPlayer = game.Players:GetPlayerFromCharacter(TargetCharacter)
					if TargetPlayer:FindFirstChild("Ghost") ~= nil then return end
					if TargetCharacter:FindFirstChild("Ghost") ~= nil then return end
					if TargetCharacter:FindFirstChild("IsProjecting") then return end
					local val = Instance.new("IntValue",TargetCharacter)
					val.Name = "WigFlying"
					if TargetPlayer ~= nil and TargetPlayer ~= Player then
						--local AnimationTrack = Player.Character.Humanoid:LoadAnimation(WitchAnimationsFolder.ScreamingAnim)
						coroutine.wrap(function()
							task.wait(1)
							local victim = Instance.new("BoolValue",TargetCharacter)
							victim.Name = "SlamVictim"
							ClientAnimationEvent:FireClient(TargetPlayer,"normal_shake","Camera")
							ClientAnimationEvent:FireClient(Player,"inaduslam","Camera")
							--AnimationTrack:Play()
							task.wait(10)
							victim:Destroy()
						end)()
						Player.Character.Humanoid.WalkSpeed = 0
						Player.Character.Humanoid.JumpPower = 0
						task.spawn(function()
							task.wait(3)
							--task.wait(AnimationTrack.Length)	
							Player.Character.Humanoid.WalkSpeed = 16
							Player.Character.Humanoid.JumpPower = 50					
						end)
						game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(TargetPlayer,"ON")
						local revent = TargetCharacter.Humanoid.StateChanged:Connect(function()
							if TargetCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
								RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
							end
						end)
						--	TargetCharacter.Head.Face.Texture = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)[TargetPlayer.CharacterConfiguration.CharacterName.Value].Outfits[TargetPlayer.CharacterConfiguration.OutfitName.Value].SleepFace
						local crit = Instance.new("BoolValue",TargetCharacter)
						crit.Name = "HealthCritical"
						task.spawn(function()
							task.wait(5)	
							if TargetCharacter:FindFirstChild("Regenerating") == nil then
								if IsSpecie(TargetPlayer,{"Vampires","Rippers","Heretics","Hybrids","Originals","UpgradedOriginals","Tribrids","Quadrabrids"}) and TargetCharacter.Humanoid.Health <= (80+5) then

									TargetCharacter.Humanoid.Health = 5
								elseif TargetCharacter:FindFirstChild ("DahliaImmortal") or TargetCharacter:FindFirstChild("SilasImmortal") or TargetCharacter:FindFirstChild("ProtectionSpell") then
									TargetCharacter.Humanoid.Health = 5
								else
									tvlServerUtil.TakeDamage(TargetCharacter, 80)
								end

							end
							crit:Destroy()
						end)
						task.wait(0.3)
						TargetCharacter.HumanoidRootPart.Anchored = false
						tvlServerUtil.DestroyMoved(TargetCharacter)
						--[[coroutine.wrap(function()
							local BV = Instance.new("BodyVelocity")
							BV.MaxForce = Vector3.new(math.huge,math.huge,math.huge)
							BV.Velocity = Player.Character.HumanoidRootPart.CFrame.lookVector * 80
							BV.Parent = TargetCharacter.HumanoidRootPart
							task.wait(0.6)
							BV:Destroy()

							PlayAnimationEvent:FireClient(TargetPlayer,"Darkness","CameraEffect",{Duration = 15})

						end)()--]]

						task.wait(10)
						revent:Disconnect()
						game.ReplicatedStorage.RemoteEvents.Ragdoll:FireClient(TargetPlayer,"OFF")
						--TargetCharacter.Head.Face.Texture = require(game.ReplicatedStorage.ReplicatedModules.MorphHandler)[TargetPlayer.CharacterConfiguration.CharacterName.Value].Outfits[TargetPlayer.CharacterConfiguration.OutfitName.Value].Face.Texture
						val:Destroy()
					end
				end
			end
		end)
	end
	ClientAnimationEvent:FireClient(Player,"inaduslam","Camera")
end

function PlayerActionModule.Ossox(AttackingCharacter,TargetCharacter)
	if TargetCharacter then
		local success, Error = pcall(function()
			local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
			local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
			local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
			if AttackingCharacter:FindFirstChild("isMind") then return end
			local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
			local witchstats = AttackingCharacter:WaitForChild("WitchStats")
			local WitchSoundsFolder = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds
			if IsSpecie(TargetPlayer,{"Vampires","Heretics","Originals","UpgradedOriginals","Tribrids","Quadrabrids","Hybrids","Rippers"}) == false then return end
			if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
			--if CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,30) == false then return end
			if AttackingCharacter:FindFirstChild("OssoxCasted") ~= nil then return end
			if AttackingCharacter:FindFirstChild("Powerless") ~= nil then return end
			if TargetCharacter:FindFirstChild("IsProjecting") then return end
			if AttackingCharacter.Humanoid.Health <= 0 then return end
			if witchstats.Magic.Value < 130 then return end 
			if AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Qetsiyah" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Esther Mikaelson" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Zara Malory" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Deceptive" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Luna" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Astrid Bennett" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Emma Malory" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia"  or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Sydney Malory" or  AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Nicolas" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Forbidden Pan" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia Hagen" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Freya" then
				--	if AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Qetsiyah" or 	AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Esther Mikaelson" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Deceptive" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Luna" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Zara Malory" then

				if IsSpecie(TargetPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Heretics","Hybrids","Customs","Hybrids"}) == true or (tvlServerUtil.IsSpecie(TargetPlayer, { "Werewolves" }) and TargetCharacter:FindFirstChild("VenomBuff")) then
					local value = Instance.new("BoolValue",AttackingCharacter)
					value.Name = "OssoxCasted"
					coroutine.wrap(function()
						task.delay(18,function()
							value:Destroy()
						end)
					end)()

					TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic,TweenInfo.new(0.8),{Value = math.clamp(AttackingCharacter.WitchStats.Magic.Value - 130,0,AttackingCharacter.WitchStats.MaxMagic.Value)}):Play()

					PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.OssoxCast,"Char")
					RandomSpellSound(TargetCharacter.HumanoidRootPart)
					task.wait(0.4)
					PlayAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
					PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.NeckSnapped,"Char")
					AddInfluency(TargetCharacter)
					task.wait(0.4)
					TargetCharacter.HumanoidRootPart.Anchored = false
					RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
					local revent = TargetCharacter.Humanoid.StateChanged:Connect(function()
						if TargetCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
							RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
						end
					end)
					SleepFace(TargetPlayer,true)
					coroutine.wrap(function()
						task.wait(15)
						revent:Disconnect()
						RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
						SleepFace(TargetPlayer,false)
						RemoveInfluency(TargetCharacter)			
					end)()
				end
				--end
			elseif tvlServerUtil.IsSpecie(TargetPlayer, {"Werephoners","Quadrabrids"}) and TargetPlayer.CharacterConfiguration.CharacterName.Value ~= "Forbidden Pan" then
				NotificationHandler.Notification(AttackingPlayer,"Forbidden Pan's werephoner spell protects them...")
				tvlServerUtil.AddInfluency(AttackingCharacter)
				PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.OssoxCast,"Char")
				tvlServerUtil.RandomSpellSound(AttackingCharacter.Head)
				ClientAnimationEvent:FireClient(AttackingPlayer,"screenshake_ae","Camera")
				NotificationHandler.Notification(AttackingPlayer,TargetPlayer.CharacterConfiguration.CharacterName.Value.." has snapped your neck as revenge ?")
				local ChatService = game:GetService("Chat")
				ChatService:Chat(TargetCharacter,"Forbidden Pan's power protects me, "..AttackingPlayer.CharacterConfiguration.CharacterName.Value,Enum.ChatColor.White)
				task.wait(0.4)
				PlayAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
				PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.NeckSnapped,"Char")
				tvlServerUtil.DestroyMoved(AttackingCharacter)
				task.wait(0.4)
				AttackingCharacter.HumanoidRootPart.Anchored = false
				RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
				tvlServerUtil.SleepFace(AttackingPlayer,true)

				tvlServerUtil.SetHealth(AttackingCharacter, if IsSpecie(AttackingPlayer, {"Werephoners"}) then 5 else 0)

				local revent = AttackingCharacter.Humanoid.StateChanged:Connect(function()
					if AttackingCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
						RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
					end
				end)
				coroutine.wrap(function()
					task.wait(15)
					revent:Disconnect()
					RagdollRemoteEvent:FireClient(AttackingPlayer,"OFF")
					tvlServerUtil.SleepFace(AttackingPlayer,false)
					tvlServerUtil.RemoveInfluency(AttackingCharacter)
				end)()
				return	
			else
				if AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Zara Malory"  or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Emma Malory" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Deceptive" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Luna" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Astrid Bennett" or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "iltria"  or AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Sydney Malory" then
					local targetwitch = false
					local witchstats = AttackingCharacter:WaitForChild("WitchStats")
					local targetwitchstats = nil
					if TargetCharacter:FindFirstChild("WitchStats") then
						targetwitchstats = TargetCharacter.WitchStats
						targetwitch = true
					end
					local message = (TargetPlayer.CharacterConfiguration.CharacterName.Value.." is too powerful for their neck to be snapped")
					local vessage = (AttackingPlayer.CharacterConfiguration.CharacterName.Value.." attempted to snap your neck with magic")
					if targetwitch == true and targetwitchstats.Magic.Value > witchstats.Magic.Value then NotificationHandler.Notification(AttackingPlayer,message) NotificationHandler.Notification(TargetPlayer,vessage) return end

					AddInfluency(TargetCharacter)
					PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.OssoxCast,"Char")
					PlayAnimationEvent:FireAllClients(WitchSoundsFolder.SpecialCast2,"replicate_sound",{SoundParent = TargetCharacter.Head})
					ClientAnimationEvent:FireClient(TargetPlayer,"screenshake_ae","Camera")
					NotificationHandler.Notification(TargetPlayer,"Your neck was magically snapped by ".. AttackingPlayer.CharacterConfiguration.CharacterName.Value)
					task.wait(0.4)
					PlayAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
					PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.NeckSnapped,"Char")
					TargetCharacter.HumanoidRootPart.Anchored = false
					tvlServerUtil.DestroyMoved(TargetCharacter)
					task.wait(0.4)
					RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
					SleepFace(TargetPlayer,true)

					tvlServerUtil.SetHealth(TargetCharacter, 0)

					local revent = TargetCharacter.Humanoid.StateChanged:Connect(function()
						if TargetCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
							RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
						end
					end)
					coroutine.wrap(function()
						task.wait(15)
						revent:Disconnect()
						RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
						SleepFace(TargetPlayer,false)
						RemoveInfluency(TargetCharacter)			
					end)()
				end
			end

		end)
		if not success then
			print("ilt debug; ossox failed, error: " .. tostring(Error))
		end
	end
end


function PlayerActionModule.Resurrection(AttackingCharacter,TargetCharacter)
	local Player = Players:GetPlayerFromCharacter(AttackingCharacter)
	local telekSound = Instance.new("Sound")
	telekSound.SoundId = "rbxassetid://6790666630"
	telekSound.Looped = true
	telekSound.Name = "telekSound"
	telekSound.Volume = 3
	telekSound.Parent = AttackingCharacter.HumanoidRootPart
	telekSound:Play()
	task.wait(5)
	telekSound:Stop()
	telekSound:Destroy()
	tvlServerUtil.Resurrect(Player, Players:GetPlayerFromCharacter(TargetCharacter), TargetCharacter, true)
end



function PlayerActionModule.DahliaTeleport(Character, Target)
	local Player = Players:GetPlayerFromCharacter(Character)
	if not (Player.CharacterConfiguration.CharacterName.Value == "Dahlia" or Player.CharacterConfiguration.CharacterName.Value == "Dahlia Hagen" or Player.CharacterConfiguration.CharacterName.Value == "Freya"  or Player.CharacterConfiguration.CharacterName.Value == "Freya Mikaelson" or Player.CharacterConfiguration.CharacterName.Value == "Inadu Labonair" or tvlServerUtil.devCheck(Player)) or not IsSpecie(Player, {"Witches", "Siphoners", "Werephoners", "Quadrabrids","Werewitches","Tribrids","Heretics","PyroWitches"}) then return end
	if Character:FindFirstChild("noTP") or Character:FindFirstChild("Powerless") then return end

	local invisDur = 1
	local cd = 3
	local cost = 150

	--Target = Target * 40
	if not Character:FindFirstChild("isTp") then
		print("start")


		if Character.WitchStats.Magic.Value >= cost then
			Character.WitchStats.Magic.Value -= cost
		else
			return
		end

		local isTp = Instance.new("Folder")
		isTp.Name = "isTp"
		isTp.Parent = Character
		Debris:AddItem(isTp, invisDur+cd)
		local phaseIn = Instance.new("Sound")
		phaseIn.SoundId = "rbxassetid://6196275663"
		phaseIn.RollOffMaxDistance = 125
		phaseIn.Parent = Character.HumanoidRootPart

		local phaseOut = Instance.new("Sound")
		phaseOut.SoundId = "rbxassetid://6196229813"
		phaseOut.RollOffMaxDistance = 125
		phaseOut.Parent = Character.HumanoidRootPart
		Debris:AddItem(phaseOut, 7)
		Debris:AddItem(phaseIn, 7)

		local newloc = Vector3.new(Target.X, Target.Y+5, Target.Z)
		Movement(Character,false)
		phaseOut:Play()
		ClientAnimationEvent:FireClient(Player,"dahliatp","Camera")

		task.delay(invisDur, function()
			Movement(Character, true)
			Character.HumanoidRootPart.CFrame = CFrame.new(newloc)
			phaseIn:Play()
		end)

		for i,part in Character:GetDescendants() do
			task.spawn(function()
				if part:IsA("MeshPart") or part:IsA("Part") or part:IsA("Decal") then
					if part.Name ~= "HumanoidRootPart" and part.Name ~= "Phone" and part.Name ~= "PhoneCase" and part.Name ~= "Grimoire" and not part:FindFirstAncestor("Grimoire") then
						local transparencyValue = part.Transparency
						TweenModule:GetTweenObject(part,TweenInfo.new(0.4,Enum.EasingStyle.Quad),{Transparency = 1}):QueuePlay()

						--partTable[#partTable+1] = {Part = part.Name, OriginalPos = part.Position}

						task.wait(invisDur)

						TweenModule:GetTweenObject(part,TweenInfo.new(0.4,Enum.EasingStyle.Quad),{Transparency = transparencyValue}):QueuePlay()
					end
				elseif part:IsA("BillboardGui") then
					part.Enabled = false
					task.wait(invisDur)
					part.Enabled = true
				end
			end)
		end
	end
end

function PlayerActionModule.DJTeleport(Character, Target)
	local Player = Players:GetPlayerFromCharacter(Character)
	local isSolaris = Player.CharacterConfiguration:FindFirstChild("isCustom") and Player.CharacterConfiguration.isCustom:FindFirstChild("SolarisIncen")
	if not (Player.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" or isSolaris) then return end
	if Character:FindFirstChild("noTP") or Character:FindFirstChild("Powerless") then return end

	local invisDur = 0.8
	local cd = 6
	local cost = 150

	--Target = Target * 40
	if not Character:FindFirstChild("isTp") then

		if Character.WitchStats.Magic.Value >= cost then
			Character.WitchStats.Magic.Value -= cost
		else
			return
		end

		local isTp = Instance.new("Folder")
		isTp.Name = "isTp"
		isTp.Parent = Character
		Debris:AddItem(isTp, invisDur+cd)
		local obj = ReplicatedStorage.ReplicatedAssets.WitchesAssets.Objects.DJTeleport:Clone()
		obj.CFrame = Character.HumanoidRootPart.CFrame
		if isSolaris then
			for _, object in obj:GetDescendants() do
				if object:IsA("ParticleEmitter") or object:IsA("Trail") then
					object.Color = ColorSequence.new(Color3.new(1, 0, 0.831373))
				end
			end
		end
		local w = Instance.new("WeldConstraint")
		w.Part0 = Character.HumanoidRootPart
		w.Part1 = obj
		w.Parent = obj
		obj.Parent = Character
		local sound = ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds.DJTp:Clone()
		sound.Parent = Character.HumanoidRootPart
		sound.Ended:Once(function()
			sound:Destroy()
		end)
		sound:Play()

		local newloc = Vector3.new(Target.X, Target.Y+5, Target.Z)
		Movement(Character,false)

		TweenService:Create(Character.HumanoidRootPart, TweenInfo.new(invisDur - 0.1), { CFrame = CFrame.new(newloc) * Character.HumanoidRootPart.CFrame.Rotation }):Play()

		task.delay(invisDur, function()
			for _, thing in obj:GetChildren() do
				if thing:IsA("ParticleEmitter") or thing:IsA("Trail") then
					thing.Enabled = false
				end
			end
			game:GetService("Debris"):AddItem(obj, 5)
			Movement(Character, true)
		end)

		for i,part in Character:GetDescendants() do
			task.spawn(function()
				if part:IsA("MeshPart") or part:IsA("Part") or part:IsA("Decal") then
					if part.Name ~= "HumanoidRootPart" and part.Name ~= "Phone" and part.Name ~= "PhoneCase" and part.Name ~= "Grimoire" and not part:FindFirstAncestor("Grimoire") then
						local transparencyValue = part.Transparency
						TweenModule:GetTweenObject(part,TweenInfo.new(0.2,Enum.EasingStyle.Quad),{Transparency = 1}):Play()

						--partTable[#partTable+1] = {Part = part.Name, OriginalPos = part.Position}

						task.wait(invisDur)

						TweenModule:GetTweenObject(part,TweenInfo.new(0.2,Enum.EasingStyle.Quad),{Transparency = transparencyValue}):Play()
					end
				elseif part:IsA("BillboardGui") then
					part.Enabled = false
					task.wait(invisDur)
					part.Enabled = true
				end
			end)
		end
	end
end

function PlayerActionModule.Poena(AttackingCharacter,TargetCharacter)
	local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
	if AttackingCharacter:FindFirstChild("isMind") then return end
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	local CharacterConfigFolder = AttackingPlayer:FindFirstChild("CharacterConfiguration")
	local CharacterName = CharacterConfigFolder.CharacterName.Value
	local WitchSoundsFolder = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds
	local witchstats = AttackingCharacter:WaitForChild("WitchStats")
	if IsSpecie(AttackingPlayer,{"Witches","Heretics","Siphoners","Tribrids","Quadrabrids","Werewitches", "Werephoners","Elder Witches","PyroWitches"}) == false then return end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
	if CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,30) == false then return end
	if AttackingCharacter:FindFirstChild("Casting") ~= nil then return end
	if AttackingCharacter:FindFirstChild("Powerless") ~= nil then return end
	if TargetCharacter:FindFirstChild("IsProjecting") then return end
	if witchstats.Magic.Value < 120 then return end
	local value = Instance.new("BoolValue",AttackingCharacter)
	value.Name = "Casting"
	coroutine.wrap(function()
		task.delay(15,function()
			value:Destroy()
		end)
	end)()
	TargetCharacter.Humanoid.WalkSpeed,TargetCharacter.Humanoid.JumpPower = 0,0
	TweenModule:GetTweenObject(AttackingCharacter.WitchStats.Magic,TweenInfo.new(0.8),{Value = math.clamp(AttackingCharacter.WitchStats.Magic.Value - 120,0,AttackingCharacter.WitchStats.MaxMagic.Value)}):Play()
	PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.PoenaDolorisCasted,"CharTemporary",{Duration = 8})
	PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.PoenaDolorisAttacked,"CharTemporary",{Duration = 8})
	PlayAnimationEvent:FireAllClients(WitchSoundsFolder.Pain,"replicate_sound",{SoundParent = TargetCharacter.Head})
	local event
	local special = false

	ClientAnimationEvent:FireClient(TargetPlayer,"screenshake_ae","Camera")


	coroutine.wrap(function()
		if IsSpecie(TargetPlayer,{"Vampires","Originals","UpgradedOriginals","Rippers","Heretics","Hybrids","Tribrids","Quadrabrids"}) == true then
			if CharacterName == "Dahlia" or CharacterName == "Lana" or CharacterName == "Aya Eclipse" or CharacterName == "Deceptive" or CharacterName == "Luna" or CharacterName == "iltria" or CharacterName == "Inadu Labonair" or CharacterName == "Forbidden Pan" or CharacterName == "Dahlia Hagen" or CharacterName == "Freya" then
				special = true

				tvlServerUtil.Dessicate(TargetCharacter, true)

				Movement(TargetCharacter,false)
				--for i = 1,40,1 do
				--	tvlServerUtil.TakeDamage(TargetCharacter, 1.15)
				--	task.wait(0.2)
				--end
				task.wait(0.2 * 40)
				Movement(TargetCharacter,true)
				TargetCharacter.Humanoid.WalkSpeed,TargetCharacter.Humanoid.JumpPower = 16,50
				TargetCharacter.HumanoidRootPart.Anchored = false
				tvlServerUtil.Dessicate(TargetCharacter, false)
			end
		end
	end)()
	if not special then
		Movement(TargetCharacter,false)
		event = TargetCharacter.Changed:Connect(function()
			Movement(TargetCharacter,false)
		end)
	end

	if not special then
		for i = 1,40,1 do
			TargetCharacter.HumanoidRootPart.Anchored = true
			tvlServerUtil.TakeDamage(TargetCharacter, 1.15)
			task.wait(0.2)
		end
		task.wait(4)
	end

	if not special then
		event:Disconnect()
		Movement(TargetCharacter,true)
	end
	TargetCharacter.Humanoid.WalkSpeed,TargetCharacter.Humanoid.JumpPower = 16,50
	TargetCharacter.HumanoidRootPart.Anchored = false
end

--[[
SnapPlayer Function
@param "AttackingCharacter" - The Vampire
@param "TargetCharacter" - The Person that is attacked by the Vampire
]]
function PlayerActionModule.SnapPlayer(AttackingCharacter,TargetCharacter)
	local isvamp = false
	local iswolf = false
	local HumanoidCharacter = AttackingCharacter:FindFirstChildOfClass("Humanoid")
	local HumanoidCharacterTarget = TargetCharacter:FindFirstChildOfClass("Humanoid")
	local AttackingPlayer = Players:GetPlayerFromCharacter(AttackingCharacter)
	local TargetPlayer = Players:GetPlayerFromCharacter(TargetCharacter)
	if TargetPlayer:FindFirstChild("Transformed") ~= nil then return end
	if AttackingCharacter:FindFirstChild("isMind") then return end
	if CheckForInflunecy(TargetCharacter) == true or CheckForInflunecy(AttackingCharacter) == true then return end
	if IsRagdolled(TargetCharacter) == true or IsRagdolled(AttackingCharacter) == true then return end
	if (IsSpecie(AttackingPlayer,{"Vampires","Rippers","Originals","UpgradedOriginals","Customs","Hybrids","Tribrids","Quadrabrids","Heretics","Werewolves","Werewitches", "Werephoners","TimeLords"}) == false) and not (IsSpecie(AttackingPlayer, { "Mortals" }) and AttackingPlayer.CharacterConfiguration.CharacterName.Value == "Alaric Saltzman") then return end
	local vampSpecies = {"Rippers","Vampires","Hybrids","Heretics","Originals", "UpgradedOriginals","Tribrids","Quadrabrids","Customs"}
	if  IsSpecie(AttackingPlayer,vampSpecies) then
		isvamp = true
	end
	if  IsSpecie(AttackingPlayer,{"Werewolves","Werewitches", "Werephoners"}) then
		iswolf = true
	end
	if CheckDistance(TargetCharacter.HumanoidRootPart,AttackingCharacter.HumanoidRootPart,7) == false then return end
	if AttackingCharacter:FindFirstChild("IsProjecting") or TargetCharacter:FindFirstChild("IsProjecting") then return end

	if iswolf == true then
		if AttackingCharacter.WolfStats.Energy.Value < 100 then 
			NotificationHandler.Notification(AttackingPlayer,"You do not have enough energy to snap necks")
			return 
		end
	end

	if isvamp == true then
		if AttackingCharacter.VampireStats.Energy.Value < 80 then 
			NotificationHandler.Notification(AttackingPlayer,"You do not have enough energy to snap necks")
			return 
		end
	end

	if tvlServerUtil.devCheck(TargetPlayer) then
		if IsSpecialWitch(TargetPlayer) == true then
			if TargetPlayer.CharacterConfiguration.CharacterName.Value ~= "iltria" then
				NotificationHandler.Notification(AttackingPlayer,TargetPlayer.CharacterConfiguration.CharacterName.Value.."'s magic protects them from harm")
			else
				NotificationHandler.Notification(AttackingPlayer, "weirdo")
			end
			AddInfluency(AttackingCharacter)
			ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.OssoxCast,"Char")
			local bv = Instance.new("BodyVelocity",AttackingCharacter.Head)
			AttackingCharacter.Humanoid.Jump = true
			TweenModule:GetTweenObject(TargetCharacter.WitchStats.Magic,TweenInfo.new(0.8),{Value = math.clamp(TargetCharacter.WitchStats.Magic.Value - 120,0,TargetCharacter.WitchStats.MaxMagic.Value)}):Play()
			RandomSpellSound(TargetCharacter.Head)
			RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
			task.wait(3)
			bv:Destroy()
			ClientAnimationEvent:FireClient(AttackingPlayer,"screenshake_ae","Camera")
			ClientAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
			PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.NeckSnapped,"Char")
			task.wait(0.4)
			if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Zara Malory" then
				PlayAnimationEvent:FireClient(TargetPlayer,ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.CustomLaugh,"Char")
				PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.Giggle,"Char")
			end
			local VoiceLines = {
				"Shouldn't have tried it",
				"You're too weak to kill me",
				"Foolish move",
				"That was a bit dumb, wasn't it?",
				"Try harder next time",
				"Stop trying to kill me",
				"Your attempts are pathetic",	
				"And what do you think you're doing?",
			}
			local RandomLine = VoiceLines[GiveRandomValue(1,#VoiceLines)]
			if TargetPlayer.CharacterConfiguration.CharacterName.Value ~= "iltria" then
				NotificationHandler.AdvancedNotification(AttackingPlayer,10,TargetPlayer.CharacterConfiguration.CharacterName.Value.."'s Telepathy","Stop trying to kill me")
			else
				NotificationHandler.AdvancedNotification(AttackingPlayer,10,TargetPlayer.CharacterConfiguration.CharacterName.Value.."'s Telepathy","weirdo")
			end
			if IsSpecie(AttackingPlayer,{"Werewolves","Werewitches"}) == true then
				tvlServerUtil.SetHealth(AttackingCharacter, 0)
			end
			SleepFace(AttackingPlayer,true)
			coroutine.wrap(function()
				task.wait(15)
				RagdollRemoteEvent:FireClient(AttackingPlayer,"OFF")
				RemoveInfluency(AttackingCharacter)	
				SleepFace(AttackingPlayer,false)

			end)()
			return
		end
	end

	if tvlServerUtil.IsSpecie(TargetPlayer, {"Werephoners","Quadrabrids"}) and TargetPlayer.CharacterConfiguration.CharacterName.Value ~= "Forbidden Pan" then
		NotificationHandler.Notification(AttackingPlayer,"Forbidden Pan's werephoner spell protects them...")
		tvlServerUtil.AddInfluency(AttackingCharacter)
		PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.OssoxCast,"Char")
		tvlServerUtil.RandomSpellSound(AttackingCharacter.Head)
		ClientAnimationEvent:FireClient(AttackingPlayer,"screenshake_ae","Camera")
		NotificationHandler.Notification(AttackingPlayer,TargetPlayer.CharacterConfiguration.CharacterName.Value.." has snapped your neck as revenge ?")
		local ChatService = game:GetService("Chat")
		ChatService:Chat(TargetCharacter,"Forbidden Pan's power protects me, "..AttackingPlayer.CharacterConfiguration.CharacterName.Value,Enum.ChatColor.White)
		task.wait(0.4)
		PlayAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
		PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.NeckSnapped,"Char")
		tvlServerUtil.DestroyMoved(AttackingCharacter)
		task.wait(0.4)
		AttackingCharacter.HumanoidRootPart.Anchored = false
		RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
		tvlServerUtil.SleepFace(AttackingPlayer,true)

		tvlServerUtil.SetHealth(AttackingCharacter, if IsSpecie(AttackingPlayer, {"Werephoners"}) then 5 else 0)

		local revent = AttackingCharacter.Humanoid.StateChanged:Connect(function()
			if AttackingCharacter.Humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
				RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
			end
		end)
		coroutine.wrap(function()
			task.wait(15)
			revent:Disconnect()
			RagdollRemoteEvent:FireClient(AttackingPlayer,"OFF")
			tvlServerUtil.SleepFace(AttackingPlayer,false)
			tvlServerUtil.RemoveInfluency(AttackingCharacter)
		end)()
		return
	end

	if IsSpecialWitch(TargetPlayer) == true then
		if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia" or TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia Hagen" then
			--ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Dahlia.PowerfulVoiceLine,"replicate_sound",{SoundParent = TargetCharacter.Head})

		elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Esther Mikaelson" then
			--ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Chapter2.Foolish,"replicate_sound",{SoundParent = TargetCharacter.Head})
		elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Freya" then

		else
			game:GetService("Chat"):Chat(TargetCharacter,"Ossox!",Enum.ChatColor.White)
		end
		AddInfluency(AttackingCharacter)
		ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.OssoxCast,"Char")

		TweenModule:GetTweenObject(TargetCharacter.WitchStats.Magic,TweenInfo.new(0.8),{Value = math.clamp(TargetCharacter.WitchStats.Magic.Value - 120,0,TargetCharacter.WitchStats.MaxMagic.Value)}):Play()
		ClientAnimationEvent:FireClient(AttackingPlayer,"screenshake_ae","Camera")
		task.wait(0.4)

		RandomSpellSound(AttackingCharacter.Head)
		ClientAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
		PlayAnimationEvent:FireClient(AttackingPlayer,WitchAnimationsFolder.NeckSnapped,"Char")
		if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dark Josie Saltzman" then
			local GeneratedSound = math.random(0,1)
			DarkJosieFace(TargetPlayer,true)
			coroutine.wrap(function()
				task.wait(3)
				SleepFace(TargetPlayer,true)
				task.wait(0.5)
				DarkJosieFace(TargetPlayer,false)
			end)()
			if TargetCharacter:FindFirstChild("Ascendo") then
				ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.AscendoGiggle,"Char")
			else
				ClientAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.Giggle,"Char")
			end
			if GeneratedSound == 0 then

				PlayAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.Laugh,"replicate_sound",{SoundParent = TargetCharacter.Head})
			else
				PlayAnimationEvent:FireClient(TargetPlayer,game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.LaughAnim,"Char")
				PlayAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.Giggle,"replicate_sound",{SoundParent = TargetCharacter.Head})
			end
			GeneratedSound = nil
		elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Zara Malory" then
			PlayAnimationEvent:FireClient(TargetPlayer,ReplicatedStorage.ReplicatedAssets.DLCFiles.EP1.CustomLaugh,"Char")
			PlayAnimationEvent:FireClient(TargetPlayer,WitchAnimationsFolder.Giggle,"Char")
		end
		task.wait(0.4)

		RagdollRemoteEvent:FireClient(AttackingPlayer,"ON")
		if IsSpecie(AttackingPlayer,{"Werewolves","Werewitches"}) == true then
			tvlServerUtil.SetHealth(AttackingCharacter, 0)
		end
		SleepFace(AttackingPlayer,true)
		task.wait(1.5)
		if TargetPlayer.CharacterConfiguration.CharacterName.Value == "Dahlia" then
			ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Dahlia.PowerfulVoiceLine,"replicate_sound",{SoundParent = TargetCharacter.Head})

		elseif TargetPlayer.CharacterConfiguration.CharacterName.Value == "Esther Mikaelson" then
			ClientAnimationEvent:FireAllClients(game.ReplicatedStorage.ReplicatedAssets.DLCFiles.Chapter2.Foolish,"replicate_sound",{SoundParent = TargetCharacter.Head})
		end
		if IsSpecie(AttackingPlayer,{"Werewolves","Werewitches"}) == true then
			tvlServerUtil.SetHealth(AttackingCharacter, 0)
		end
		coroutine.wrap(function()
			task.wait(15)
			RagdollRemoteEvent:FireClient(AttackingPlayer,"OFF")
			RemoveInfluency(AttackingCharacter)	
			SleepFace(AttackingPlayer,false)

		end)()
		return

	else
		print("not special")
		if IsSpecie(TargetPlayer, {"Witches", "Werewitches", "Werephoners", "Werephoners", "Heretics", "Siphoners", "Tribrids", "Quadrabrids","PyroWitches"}) then
			if TargetCharacter.WitchStats.Magic.Value > 50 then
				PlayerActionModule.Ictus(TargetCharacter, AttackingCharacter)
				return
			else
				--do nothing
			end
		end
		if isvamp and not IsSpecie(TargetPlayer, vampSpecies) then
			local stake = getTool(TargetPlayer, "Wooden Stake") or getTool(TargetPlayer, "Mikael's White Oak Stake") or getTool(TargetPlayer, "White Oak Stake") or getTool(TargetPlayer, "3 Use White Oak Stake")
			if stake and stake:FindFirstChild("Tignal") and not IsSpecie(AttackingPlayer, {"Werephoners", "Quadrabrids"}) then
				TargetCharacter.Humanoid:EquipTool(stake);
				if stake.Parent ~= TargetCharacter then stake.AncestryChanged:Wait() end
				(stake.Tignal :: BindableEvent):Fire(TargetPlayer, AttackingCharacter)
				return
			end
		end
		Movement(AttackingCharacter,false)
		Movement(TargetCharacter,false)
		AddInfluency(AttackingCharacter)
		AddInfluency(TargetCharacter)
		TargetCharacter.HumanoidRootPart.Anchored = false
		tvlServerUtil.DestroyMoved(TargetCharacter)
		local function SnapCheck(Player)
			print("ran")
			if IsSpecie(TargetPlayer,vampSpecies) == true or (tvlServerUtil.IsSpecie(TargetPlayer, { "Werewolves" }) and TargetCharacter:FindFirstChild("VenomBuff")) then	
				RagdollRemoteEvent:FireClient(TargetPlayer,"ON")
				SleepFace(TargetPlayer,true)
				coroutine.wrap(function()
					task.wait(15)
					RagdollRemoteEvent:FireClient(TargetPlayer,"OFF")
					SleepFace(TargetPlayer,false)
					RemoveInfluency(TargetCharacter)			
					Movement(TargetCharacter,true)
				end)()
			else
				tvlServerUtil.SetHealth(TargetCharacter, 0)
			end
		end

		local Region= Region3.new(TargetCharacter.Head.Position + Vector3.new(-4.5,-5,0.25),TargetCharacter.HumanoidRootPart.Position + Vector3.new(4.5,3,8)) 
		local IsBehind = false
		local Parts =workspace:FindPartsInRegion3WithWhiteList(Region, {AttackingCharacter}, 1000)
		for i,part in pairs(Parts) do
			if part:IsDescendantOf(AttackingCharacter) then
				IsBehind = true
			end
		end

		if not IsBehind then
			--//In Front
			MoveFront(AttackingCharacter.HumanoidRootPart,TargetCharacter.HumanoidRootPart,1.65)
			ClientAnimationEvent:FireClient(AttackingPlayer,VampireAnimationsFolder.SnapFrontAttack,"Char")
			ClientAnimationEvent:FireClient(TargetPlayer,VampireAnimationsFolder.SnapFrontTarget,"Char")
			ClientAnimationEvent:FireClient(AttackingPlayer,"SNAP_VAMPIRE_CUTSCENE_FRONT","Camera")
			ClientAnimationEvent:FireClient(TargetPlayer,"SNAP_VAMPIRE_CUTSCENE_FRONT_TARGET","Camera",{AttackerTorso = AttackingCharacter.HumanoidRootPart})
			task.wait(0.3)
			ClientAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
			Movement(TargetCharacter,true)
			SnapCheck()
			if isvamp then
				TweenModule:GetTweenObject(AttackingCharacter.VampireStats.Energy,TweenInfo.new(0.5),{Value = math.clamp(AttackingCharacter.VampireStats.Energy.Value - 80,0,AttackingCharacter.VampireStats.MaxEnergy.Value)}):Play()
			end
			if iswolf then
				TweenModule:GetTweenObject(AttackingCharacter.WolfStats.Energy,TweenInfo.new(0.5),{Value = math.clamp(AttackingCharacter.WolfStats.Energy.Value - 100,0,AttackingCharacter.WolfStats.MaxEnergy.Value)}):Play()
			end
			task.wait(0.3)
			Movement(AttackingCharacter,true)
			RemoveInfluency(AttackingCharacter)
		else	
			--//Behind
			MoveBehind(AttackingCharacter.HumanoidRootPart,TargetCharacter.HumanoidRootPart,1.65)
			ClientAnimationEvent:FireClient(AttackingPlayer,VampireAnimationsFolder.SnapBehindAttack,"Char")
			ClientAnimationEvent:FireClient(TargetPlayer,VampireAnimationsFolder.SnapBehindTarget,"Char")
			ClientAnimationEvent:FireClient(AttackingPlayer,"SNAP_VAMPIRE_CUTSCENE","Camera")
			ClientAnimationEvent:FireClient(TargetPlayer,"SNAP_VAMPIRE_CUTSCENE_TARGET","Camera",{AttackerTorso = AttackingCharacter.HumanoidRootPart})
			task.wait(1.1)
			ClientAnimationEvent:FireAllClients(VampireSoundFolder.NeckSnap,"replicate_sound",{SoundParent = TargetCharacter.Head})
			Movement(TargetCharacter,true)
			if isvamp then
				TweenModule:GetTweenObject(AttackingCharacter.VampireStats.Energy,TweenInfo.new(2),{Value = math.clamp(AttackingCharacter.VampireStats.Energy.Value - 60,0,AttackingCharacter.VampireStats.MaxEnergy.Value)}):Play()
			end
			SnapCheck()
			task.wait(0.8)
			Movement(AttackingCharacter,true)
			RemoveInfluency(AttackingCharacter)
		end
	end
end

function PlayerActionModule.CallPlayer(Caller: Player, CallerCharacter: Model)
	if CallerCharacter:FindFirstChild("OnCallWith") or Caller:FindFirstChild("DecidingCall") then return end
	local DecidingCall = Instance.new("Folder", Caller)
	DecidingCall.Name = "DecidingCall"
	local connections = {}
	local UI = game.ServerStorage.CompulsionUIs.OriginalCompulsion:Clone()
	UI.Enabled = true
	UI.Main.Title.Text = "Call"
	local template = UI.Main.ScrollingFrame.sleep
	for _, button in UI.Main.ScrollingFrame:GetChildren() do
		if not button:IsA("TextButton") then continue end
		button:Destroy()
	end
	local decidedPlayer
	local playerConnections = {}
	local isAwaitingAnswer = false
	for _, player in game.Players:GetPlayers() do
		if player == Caller or not player:FindFirstChild("CharacterConfiguration") then continue end
		local button = template:Clone()
		button.Name = player.Name
		button.Text = player.Name
		button.Parent = UI.Main.ScrollingFrame
		table.insert(playerConnections, button.MouseButton1Click:Connect(function()
			if isAwaitingAnswer then return end
			isAwaitingAnswer = true
			local ChannelUI = game.ServerStorage.ChannelGUI:Clone()
			ChannelUI.Parent = player.PlayerGui

			local reqname = Caller.CharacterConfiguration.CharacterName.Value :: string

			ChannelUI.Main.Title.Text = reqname.." is calling you"
			local HasAccepted = false
			local a,b
			a = ChannelUI.Main.Accept.MouseButton1Click:Connect(function()
				a:Disconnect()
				b:Disconnect()
				ChannelUI:Destroy()	
				for _, connection in playerConnections do
					connection:Disconnect()
				end
				decidedPlayer = player
			end)

			b = ChannelUI.Main.Decline.MouseButton1Click:Connect(function()
				ChannelUI:Destroy()
				a:Disconnect()
				b:Disconnect()
				isAwaitingAnswer = false
			end)

			coroutine.wrap(function()
				task.wait(8)
				if ChannelUI ~= nil then
					if HasAccepted == false then
						isAwaitingAnswer = false
						ChannelUI:Destroy()
					end
				end
			end)()
		end))
	end
	local OnCallWith
	local function cleanup()
		UI:Destroy()
		if OnCallWith then
			OnCallWith:Destroy()
		end
		if DecidingCall then
			DecidingCall:Destroy()
		end
	end
	UI.Main.nothing.MouseButton1Click:Once(function()
		cleanup()
	end)
	UI.Parent = Caller.PlayerGui
	repeat task.wait() until decidedPlayer or not UI:IsDescendantOf(Caller)
	DecidingCall:Destroy()
	if not decidedPlayer then return cleanup() end
	local decidedCharacter = decidedPlayer.Character
	if not decidedCharacter then return cleanup() end
	UI.Main.nothing.Text = "End Call"
	UI.Main.Title.Text = `On a call with {decidedPlayer.Name}`
	OnCallWith = Instance.new("ObjectValue", CallerCharacter)
	OnCallWith.Name = "OnCallWith"
	OnCallWith.Value = decidedPlayer
	for _, button in UI.Main.ScrollingFrame:GetChildren() do
		if not button:IsA("TextButton") then continue end
		button:Destroy()
	end
	local teleportBehind = template:Clone()
	teleportBehind.Text = "Teleport Behind"
	teleportBehind.MouseButton1Click:Connect(function()
		CallerCharacter.HumanoidRootPart.CFrame = decidedCharacter.HumanoidRootPart.CFrame * CFrame.new(0, 0, 2)
	end)
	teleportBehind.Parent = UI.Main.ScrollingFrame
	local jumpscare = template:Clone()
	jumpscare.Text = "Jumpscare"
	jumpscare.MouseButton1Click:Connect(function()
		local ScreenGui = Instance.new("ScreenGui", decidedPlayer.PlayerGui)
		ScreenGui.DisplayOrder = 99999
		local Label = Instance.new("ImageLabel", ScreenGui)
		game:GetService("ContentProvider"):PreloadAsync({"rbxassetid://7713736290"})
		Label.Image = "rbxassetid://7713736290"
		Label.Size = UDim2.fromScale(1, 1)
		game:GetService("Debris"):AddItem(ScreenGui, 0.45)
	end)
	jumpscare.Parent = UI.Main.ScrollingFrame
	task.spawn(function()
		repeat task.wait() until not decidedPlayer:IsDescendantOf(game.Players) or not Caller:IsDescendantOf(game.Players) or not UI:IsDescendantOf(Caller)
		cleanup()
	end)
end

function PlayerActionModule.FreyaBarrierDispelling(Character, barrier, door)
	if Character:FindFirstChild("dispellingCD") or Character:FindFirstChild("Powerless") then return end
	if Character.WitchStats.Magic.Value < 350 then return end
	local Player = Players:GetPlayerFromCharacter(Character)
	local cd = Instance.new("Folder", Character)
	cd.Name = "dispellingCD"
	Debris:AddItem(cd, 30)
	PlayAnimationEvent:FireClient(Player,WitchAnimationsFolder.BloodBoilCast,"CharTemporary",{Duration = 5.35})
	SleepFace(Player, true)
	Character.WitchStats.Magic.Value -= 350
	task.wait(2)
	PlayAnimationEvent:FireClient(Player, "screenshake_ae", "Camera")
	tvlServerUtil.RandomSpellSound(barrier)
	task.wait(3)
	PlayAnimationEvent:FireClient(Player, "screenshake_ae", "Camera")
	tvlServerUtil.RandomSpellSound(barrier)
	if door then
		if door:FindFirstChild("isLocked") then
			door.isLocked:Destroy()
		end
	end
	if barrier then
		barrier.Magic.Value = 0
	end
	task.wait(0.5)
	SleepFace(Player, false)
end

return PlayerActionModule
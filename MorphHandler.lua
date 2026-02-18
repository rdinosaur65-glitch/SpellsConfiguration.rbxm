local Players = game.Players

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ReplicatedModulesFolder = ReplicatedStorage.ReplicatedModules
local CharacterConfigurationList = require(ReplicatedModulesFolder.CharacterConfiguration)
local NotificationModuleTSK = require(ReplicatedModulesFolder.NotificationModuleTSK)
local replicatedUtil = require(ReplicatedModulesFolder.tvlReplicatedUtil)
local MorphHandler = {}
local RemoteEvents = ReplicatedStorage.RemoteEvents
local PlayAnimationEvent = RemoteEvents.AnimationClientEvent
local RagdollRemoteEvent = RemoteEvents.Ragdoll
local DLCFilesFolder = ReplicatedStorage.ReplicatedAssets.DLCFiles
local tween = game:GetService("TweenService")
local ServerScriptService = game:GetService("ServerScriptService")
local FactionUtils = if RunService:IsServer() then require(game.ServerScriptService:WaitForChild("Modules"):WaitForChild("FactionUtils")) else nil

local singular = {
	Witches = "Witch",
	Werewolves = "Werewolf",
	Mortals = "Mortal",
	Siphoners = "Siphoner",
	Werewitches = "Werewitch",
	PyroWitches = "PyroWitch",
	Vampires = "Vampire",
	Phoenix = "Phoenix",
	Hybrids = "Hybrid",
	Tribrids = "Tribrid",
	Rippers = "Ripper",
	Heretics = "Heretic",
	Originals = "Original Vampire",
	TransitioningVampire = "Transitioning Vampire",
	TransitioningHeretic = "Transitioning Heretic",
	TransitioningHybrid = "Transitioning Hybrid",
	TransitioningTribrid = "Transitioning Tribrid",
	TransitioningQuadrabrid = "Transitioning Quadrabrid",
	Werephoners = "Werephoner",
	Quadrabrids = "Quadrabrid",
	UpgradedOriginals = "Upgraded Original",
	TimeLords = "Time Lord"
}

local oldSpecie = {}

Players.PlayerAdded:Connect(function(plr)
	oldSpecie[plr] = "None"
end)

Players.PlayerRemoving:Connect(function(plr)
	oldSpecie[plr] = nil
end)


local function weldAttachments(attach1, attach2)
	local weld = Instance.new("Weld")
	weld.Part0 = attach1.Parent
	weld.Part1 = attach2.Parent
	weld.C0 = attach1.CFrame
	weld.C1 = attach2.CFrame
	weld.Parent = attach1.Parent
	return weld
end
local function findFirstMatchingAttachment(model, name)
	for _, child in model:GetChildren() do
		if child:IsA("Attachment") and child.Name == name then
			return child
		elseif not child:IsA("Accoutrement") and not child:IsA("Tool") then
			local foundAttachment = findFirstMatchingAttachment(child, name)
			if foundAttachment then
				return foundAttachment
			end
		end
	end
end
local AccessoryTypeToAttachment = {
	[Enum.AccessoryType.Hair] = "HairAttachment",
}
local function addAccoutrement(character, accoutrement)
	accoutrement.Parent = character
	local handle = accoutrement:FindFirstChild("Handle")
	if not handle then
		return nil
	end
	local accoutrementAttachment = handle:FindFirstChildOfClass("Attachment")
	if not accoutrementAttachment then
		local _accessoryType = accoutrement.AccessoryType
		local attachment = AccessoryTypeToAttachment[_accessoryType]
		if not (attachment ~= "" and attachment) then
			error("Unexpected accessory type, " .. accoutrement.AccessoryType.Name)
		end
		accoutrementAttachment = Instance.new("Attachment")
		accoutrementAttachment.Name = attachment
		accoutrementAttachment.CFrame = accoutrement.AttachmentPoint
		accoutrementAttachment.Parent = handle
	end
	local characterAttachment = findFirstMatchingAttachment(character, accoutrementAttachment.Name)
	if characterAttachment then
		weldAttachments(characterAttachment, accoutrementAttachment)
	end
end

function addAccessory2(character, accessory)
	if RunService:IsServer() then
		character.Humanoid:AddAccessory(accessory)
	else
		addAccoutrement(character, accessory)
	end
end

MorphHandler.addAccessory = addAccessory2

local function addAccessory(character, accessory)
	local attachment = accessory.Handle:FindFirstChildOfClass("Attachment")
	local weld = Instance.new("Weld")
	weld.Name = "AccessoryWeld"
	weld.Part0 = accessory.Handle
	if attachment then
		local other = character:FindFirstChild(tostring(attachment), true)
		weld.C0 = attachment.CFrame
		weld.C1 = other.CFrame
		weld.Part1 = other.Parent
	else
		weld.C1 = CFrame.new(0, character.Head.Size.Y / 2, 0) * accessory.AttachmentPoint:inverse()
		weld.Part1 = character.Head
	end
	accessory.Handle.CFrame = weld.Part1.CFrame * weld.C1 * weld.C0:inverse()
	accessory.Parent = character
	weld.Parent = accessory.Handle
end

local function setupInfoGui(Character: Model, CharacterName: string, Specie: StringValue, IsTribrid: boolean?, IsElder: boolean?)
	local PossiblePlayer = Players:GetPlayerFromCharacter(Character)
	Character.Head.InfoGui.PlayerToHideFrom = PossiblePlayer
	Character.Head.InfoGui.Adornee = Character.Head
	Character.Head.InfoGui.NameUser.Text = PossiblePlayer.Name
	local Rank = Character.Head.InfoGui.GroupRank :: typeof(game.StarterPlayer.StarterCharacter.Head.InfoGui.GroupRank)
	local FactionDisplay, PowerRank = (_G.GetCharacterRankInfo or function() return nil, nil end)(PossiblePlayer)

	if PowerRank then
		Rank.Text = if PowerRank == "Leader" then FactionDisplay else PowerRank
		local gradient = Rank:FindFirstChild(PowerRank) :: UIGradient?
		if gradient then
			for _, child in Rank:GetChildren() do
				if child:IsA("UIGradient") and child ~= gradient then	
					child:Destroy()
				end			
			end
			gradient.Enabled = not PossiblePlayer:GetAttribute("IsDisguised")
			local conn = PossiblePlayer:GetAttributeChangedSignal("IsDisguised"):Connect(function()
				if PossiblePlayer:GetAttribute("IsDisguised") then
					gradient.Enabled = false
					Rank.Text = PossiblePlayer:GetRoleInGroup(279354262)
				else
					Rank.Text = if PowerRank == "Leader" then FactionDisplay else PowerRank
					gradient.Enabled = true
				end
			end)
			task.spawn(function()
				repeat task.wait() until gradient:IsDescendantOf(workspace)
				while gradient:IsDescendantOf(workspace) do
					gradient.Rotation += 0.2
					task.wait()
				end
				conn:Disconnect()
			end)
		else
			warn(`NO GRADIENT FOR {PowerRank}`)
			for _, child in Rank:GetChildren() do
				warn(`LABEL HAS CHILD: {child.Name}`)
			end
		end
	elseif FactionDisplay then
		Rank.Text = FactionDisplay
	else
		Rank.Text = PossiblePlayer:GetRoleInGroup(0)
	end
	local function updateSpecieText()
		local elderSpecies = { "Witches", "Siphoners", "Werephoners", "Heretics", "Werewitches", "Tribrids", "Quadrabrids", "PyroWitches" }
		local str = ""
		if Character:FindFirstChild("SilasImmortal") then str ..= "Immortal " end
		if PossiblePlayer:GetAttribute("IsHarvested") then str ..= "Harvest " end
		if IsElder and table.find(elderSpecies, Specie.Value) then str ..= "Elder " end

		-- ?? custom overrides (add as many as you want)
		-- Key = exact CharacterName lowercased (the thing that currently shows as "Forbidden Pan")
		local custom = {
			["forbidden pan"] = { displayName = "Luna Astriel", title = "Goddess" },
			["Tay"] = { displayName = "Orion Solis", title = "Eternal Sovereign" },
			-- ["another name"] = { displayName = "Another Display", title = "Another Title" },
		}

		local override = custom[string.lower(CharacterName)]
		if override then
			local label = Character.Head.InfoGui:WaitForChild("NameChar")

			local displayName = override.displayName
			local title = override.title

			-- Name is plain text, only title is coloured
			label.RichText = true
			label.Text = `{displayName} | <font color="#000000">{title}</font>`

			-- glow only affects the title colour (species/title), not the name
			local glow = label.Parent:FindFirstChild("NameCharGlow")
			if not glow then
				glow = label:Clone()
				glow.Name = "NameCharGlow"
				glow.RichText = true
				glow.TextTransparency = 0.6
				glow.TextStrokeTransparency = 0.4
				glow.ZIndex = label.ZIndex - 1
				glow.Parent = label.Parent

				local TweenService = game:GetService("TweenService")
				local tweenInfo = TweenInfo.new(2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
				TweenService:Create(glow, tweenInfo, { TextTransparency = 0.75 }):Play()
			end

			glow.Text = `{displayName} | <font color="#FFD700">{title}</font>`

			return
		end

		Character.Head.InfoGui.NameChar.Text = `{CharacterName} | {str .. singular[Specie.Value]}`
	end

	
	updateSpecieText()
	oldSpecie[PossiblePlayer] = singular[Specie.Value]

	Specie.Changed:Connect(function()
		updateSpecieText()
		local v = oldSpecie[PossiblePlayer]
		oldSpecie[PossiblePlayer] = singular[Specie.Value]

		-- ? Original Tribrid transformation storm
		if v == "Transitioning Tribrid" and singular[Specie.Value] == "Tribrid" and IsTribrid then
			local NotificationHandler = require(ServerScriptService:WaitForChild("MainUI"):WaitForChild("NotificationHandler"))
			for _, v in game:GetService("Players"):GetPlayers() do
				if v:FindFirstChild("CharacterConfiguration") then
					NotificationHandler.Notification(v, "The Tribrid is born!")
				end
			end

			local sound = workspace:WaitForChild("TribridStorm")
			sound:Play()
			local Lighting = game:GetService("Lighting")
			local TRIBRIDSTORM = ReplicatedStorage:WaitForChild("TRIBRIDSTORM")

			for _, thing in Lighting:GetChildren() do
				if thing:IsA("Folder") then continue end
				if not TRIBRIDSTORM:FindFirstChildOfClass(thing.ClassName) or thing.ClassName == "ColorCorrectionEffect" then continue end
				thing.Parent = Lighting.DISABLE
				task.delay(sound.TimeLength, function()
					thing.Parent = Lighting
				end)
			end

			for _, v in TRIBRIDSTORM:GetChildren() do
				local clone = v:Clone()
				clone.Parent = Lighting
				game:GetService("Debris"):AddItem(clone, sound.TimeLength)
			end
		end
	end)

	local conn = PossiblePlayer:GetAttributeChangedSignal("IsHarvested"):Connect(function()

		updateSpecieText()
	end)

	Character.ChildAdded:Connect(function(child)
		if child.Name == "SilasImmortal" then
			updateSpecieText()
		end
	end)
	Character.ChildRemoved:Connect(function(child)
		if child.Name == "SilasImmortal" then
			updateSpecieText()
		end
	end)
	Character.AncestryChanged:Connect(function()
		if Character:IsDescendantOf(workspace) then return end
		conn:Disconnect()
	end)
end

local function arriveText(ply, notifyText)
	local v78 = Instance.new("ScreenGui");
	local v79 = Instance.new("TextLabel");
	v79.Text = notifyText;
	v79.AnchorPoint = Vector2.new(0.5, 0.5);
	v79.BackgroundTransparency = 1;
	v79.BorderSizePixel = 0;
	v79.TextScaled = true;
	v79.TextColor3 = Color3.new(1, 1, 1);
	v79.TextStrokeColor3 = Color3.new(0, 0, 0);
	v79.Size = UDim2.new(0.35, 0, 0.1, 0);
	v79.Font = Enum.Font.Garamond;
	v79.Position = UDim2.new(0.5, 0, 0.2, 0);
	v79.TextTransparency = 1;
	v79.TextStrokeTransparency = 1;
	v79.Parent = v78;
	local v80 = tween:Create(v79, TweenInfo.new(1), {
		TextTransparency = 1, 
		TextStrokeTransparency = 1
	});
	v78.Parent = ply:WaitForChild("PlayerGui");
	tween:Create(v79, TweenInfo.new(1), {
		TextTransparency = 0, 
		TextStrokeTransparency = 0.5
	}):Play();
	coroutine.resume(coroutine.create(function()
		task.wait(3);
		v80:Play();
		task.wait(1.3);
		v78:Destroy();
	end));
end


function MorphHandler.MorphWorldModelCoven(Character, Player, Gender)
	local Configuration = Players:GetHumanoidDescriptionFromUserId(Player.UserId)
	local HumanoidDescription = Instance.new("HumanoidDescription")
	HumanoidDescription.TorsoColor = Configuration.TorsoColor
	HumanoidDescription.HeadColor = Configuration.HeadColor
	HumanoidDescription.LeftArmColor = Configuration.LeftArmColor
	HumanoidDescription.RightArmColor = Configuration.RightArmColor
	HumanoidDescription.LeftArmColor = Configuration.LeftArmColor
	HumanoidDescription.RightArmColor = Configuration.RightArmColor
	HumanoidDescription.HairAccessory = Configuration.HairAccessory
	HumanoidDescription.HatAccessory = Configuration.HatAccessory
	--HumanoidDescription.HeadScale = Configuration.HeadScale
	HumanoidDescription.DepthScale = 0.8
	HumanoidDescription.HeightScale = 1.08
	HumanoidDescription.WidthScale = 0.75

	HumanoidDescription.Shirt = Configuration.Shirt
	HumanoidDescription.Pants = Configuration.Pants

	Character.Humanoid:ApplyDescription(HumanoidDescription)
	if Gender == "Female" then
		Character.Head.Face.Texture = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Faces.coven_f.Texture
	else	
		Character.Head.Face.Texture = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Faces.coven.Texture
	end
	Character.Ears.BrickColor = BrickColor.new(Configuration.HeadColor)
	HumanoidDescription:Destroy()
	Configuration:Destroy()
end

function MorphHandler.MorphCoven(Character,Gender)
	local Player = Players:GetPlayerFromCharacter(Character)
	if Player ~= nil then
		local GroupService = game:GetService("GroupService")
		local CovensGroupID = { 34769697 }
		local isAnActiveCovenMember = false
		local CovenName
		local CovenId
		local CovenRank
		local GroupsTable = GroupService:GetGroupsAsync(Player.UserId)
		for i,Table in pairs(GroupsTable) do
			if table.find(CovensGroupID,Table.Id) ~= nil then
				if Table.IsPrimary == true then
					CovenName = Table.Name
					CovenId = Table.Id
					isAnActiveCovenMember = true
					CovenRank = Player:GetRankInGroup(Table.Id)
				end
			end
		end
		local CharacterConfiguration = Player:FindFirstChild("CharacterConfiguration")
		if CharacterConfiguration == nil then
			CharacterConfiguration = Instance.new("Folder")
			CharacterConfiguration.Name = "CharacterConfiguration"
			CharacterConfiguration.Parent = Player
			local Specie = Instance.new("StringValue",CharacterConfiguration)
			Specie.Name = "Specie"
			if CovenRank >= 1 and CovenRank <= 100 then
				Specie.Value = "Witches"
			elseif CovenRank > 100 and CovenRank <= 150 then
				Specie.Value = "Siphoners"
			elseif CovenRank > 150 and CovenRank <= 255 then
				Specie.Value = "Heretics"
			end
			local GenderV = Instance.new("StringValue", CharacterConfiguration)
			GenderV.Name = "Gender"
			GenderV.Value = Gender
			local IsCoven = Instance.new("Folder", CharacterConfiguration)
			IsCoven.Name = "isCoven"
			Character.Humanoid.MaxHealth = 200
			Character.Humanoid.Health = 200
			local CharacterName = Instance.new("StringValue",CharacterConfiguration)
			CharacterName.Name = "CharacterName"
			if Gender == "Female" then
				CharacterName.Value = "coven_f"
			else
				CharacterName.Value = "coven"
			end
			local OutfitName = Instance.new("StringValue",CharacterConfiguration)
			OutfitName.Name = "OutfitName"
			OutfitName.Value = "def"
			local WitchStats = Instance.new("Folder")
			WitchStats.Name = "WitchStats"
			WitchStats.Parent = Character
			local MaxMagic = Instance.new("IntValue")
			MaxMagic.Name = "MaxMagic"
			MaxMagic.Value = 1200
			MaxMagic.Parent = WitchStats
			local Magic = Instance.new("IntValue")
			Magic.Name = "Magic"
			Magic.Value = MaxMagic.Value
			Magic.Parent = WitchStats
			local SiphoningCooldown = Instance.new("BoolValue")
			SiphoningCooldown.Name = "SiphoningCooldown"
			SiphoningCooldown.Parent = WitchStats

			if Specie.Value == "Heretics" then
				local VampireStats = Instance.new("Folder")
				VampireStats.Name = "VampireStats"
				VampireStats.Parent = Character
				local MaxThirst = Instance.new("IntValue",VampireStats)
				MaxThirst.Name = "MaxThirst"
				MaxThirst.Value = 200
				local Thirst = Instance.new("IntValue",VampireStats)
				Thirst.Name = "Thirst"
				Thirst.Value = MaxThirst.Value
				local Ring = Instance.new("BoolValue",VampireStats)
				Ring.Name = "HasRing"
				Ring.Value = true
				local MaxEnergy = Instance.new("IntValue",VampireStats)
				MaxEnergy.Name = "MaxEnergy"
				MaxEnergy.Value = 450
				local Energy = Instance.new("IntValue",VampireStats)
				Energy.Name = "Energy"
				Energy.Value = MaxEnergy.Value
			end
			setupInfoGui(Character, CharacterName.Value, Specie, false, false)
		end
		local Configuration = Players:GetHumanoidDescriptionFromUserId(Player.UserId)
		local HumanoidDescription = Instance.new("HumanoidDescription")
		HumanoidDescription.TorsoColor = Configuration.TorsoColor
		HumanoidDescription.HeadColor = Configuration.HeadColor
		HumanoidDescription.LeftArmColor = Configuration.LeftArmColor
		HumanoidDescription.RightArmColor = Configuration.RightArmColor
		HumanoidDescription.LeftArmColor = Configuration.LeftArmColor
		HumanoidDescription.RightArmColor = Configuration.RightArmColor
		HumanoidDescription.HairAccessory = Configuration.HairAccessory
		HumanoidDescription.HatAccessory = Configuration.HatAccessory
		--HumanoidDescription.HeadScale = Configuration.HeadScale
		HumanoidDescription.DepthScale = 0.8
		HumanoidDescription.HeightScale = 1.08
		HumanoidDescription.WidthScale = 0.75

		HumanoidDescription.Shirt = Configuration.Shirt
		HumanoidDescription.Pants = Configuration.Pants
		local animateScript = Character:FindFirstChild("Animate")
		if animateScript ~= nil then
			if Gender == "Female" then
				animateScript.run.RunAnim.AnimationId = "rbxassetid://136517440155058" 
				animateScript.idle.Animation1.AnimationId = "rbxassetid://106432719885638"
				animateScript.idle.Animation2.AnimationId = "rbxassetid://106432719885638"    
			elseif Gender == "Male" then
				animateScript.run.RunAnim.AnimationId = "rbxassetid://108780898850036"
				animateScript.idle.Animation1.AnimationId = "rbxassetid://90777854428110"  
				animateScript.idle.Animation2.AnimationId = "rbxassetid://90777854428110"
			end
		end
		Character.Humanoid:ApplyDescription(HumanoidDescription)
		if Gender == "Female" then
			Character.Head.Face.Texture = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Faces.coven_f.Texture
		else	
			Character.Head.Face.Texture = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Faces.coven.Texture
		end
		Character.Ears.BrickColor = BrickColor.new(Configuration.HeadColor)
		HumanoidDescription:Destroy()
		Configuration:Destroy()
	end
end
function MorphHandler.Morph(Character,CharacterName,Outfit,isTurned, overrideSpecie: string?, isOutfitChange: boolean?)
	local Table = CharacterConfigurationList[CharacterName]
	if not Table then return warn(`NO CHARACTER CONFIG FOR {CharacterName}`) end
	Table = table.clone(Table)
	if overrideSpecie then Table.Specie = overrideSpecie end
	Table.Magic = Table.Magic or 1500
	Table.Energy = Table.Energy or 600
	local Name = CharacterName
	local PossiblePlayer = Players:GetPlayerFromCharacter(Character)
	local animateScript = Character:FindFirstChild("Animate")
	if animateScript ~= nil then
		if Table.Gender == "Female" then
			animateScript.run.RunAnim.AnimationId = "rbxassetid://90716890375933" 
			animateScript.idle.Animation1.AnimationId = "rbxassetid://106432719885638"
			animateScript.idle.Animation2.AnimationId = "rbxassetid://106432719885638"        
		elseif Table.Gender == "Male" then
			animateScript.run.RunAnim.AnimationId = "rbxassetid://78456958166693"
			animateScript.idle.Animation1.AnimationId = "rbxassetid://94897340480541"  
			animateScript.idle.Animation2.AnimationId = "rbxassetid://94897340480541"
		end
		if Name == "Sheila Bennett" then
			animateScript.idle.Animation1.AnimationId = "rbxassetid://106432719885638"  
			animateScript.idle.Animation2.AnimationId = "rbxassetid://106432719885638"
		elseif Name == "Davina Claire" then
			animateScript.idle.Animation1.AnimationId = "rbxassetid://114011978041955"
			animateScript.idle.Animation2.AnimationId = "rbxassetid://114011978041955" 
		elseif Name == "Dark Josie Saltzman" then
			animateScript.run.RunAnim.AnimationId = "rbxassetid://91613629435466"  
			animateScript.idle.Animation1.AnimationId = "rbxassetid://76433577572030"
			animateScript.idle.Animation2.AnimationId = "rbxassetid://76433577572030"
		end
	end

	for i,part in pairs(Character:GetChildren()) do
		if part:IsA("Part") or part:IsA("BasePart") then
			if Table.Outfits[Outfit].BodyColor ~= nil then
				part.Color = Table.Outfits[Outfit].BodyColor.Value
			end
		elseif part:IsA("Accessory") then
			part:Destroy()
		end
	end

	if Table.Outfits[Outfit].Face:IsA("Decal") then
		Character.Head.Face.Texture = Table.Outfits[Outfit].Face.Texture
	end

	if Table.Outfits[Outfit].Shirt ~= nil then
		if Table.Outfits[Outfit].Shirt:IsA("Shirt") then
			Character.Shirt.ShirtTemplate = Table.Outfits[Outfit].Shirt.ShirtTemplate
			Character.Shirt.Color3 = Table.Outfits[Outfit].Shirt.Color3
		end
	end

	if Table.Outfits[Outfit].Pants ~= nil then
		if Table.Outfits[Outfit].Pants:IsA("Pants") then
			Character.Pants.PantsTemplate = Table.Outfits[Outfit].Pants.PantsTemplate
			Character.Pants.Color3 = Table.Outfits[Outfit].Pants.Color3
		end		
	end

	if Table.Outfits[Outfit].Skirt ~= nil and Table.Outfits[Outfit].SkirtOffset then
		local Skirt = Table.Outfits[Outfit].Skirt:Clone()
		local Weld = Instance.new("WeldConstraint",Skirt)
		Skirt.Position = Character.LowerTorso.Position - Table.Outfits[Outfit].SkirtOffset
		Weld.Part0 = Character.LowerTorso
		Weld.Part1 = Skirt
		Skirt.Parent= Character
	end

	if Table.Outfits[Outfit].Hair ~= nil then
		for i,accessory in pairs(Table.Outfits[Outfit].Hair) do
			if accessory:IsA("Accessory") then
				local acc = accessory:Clone()
				addAccessory2(Character, acc)
			end
		end
	end

	if Table.Specie ~= "Phoenix" and Table.Specie ~= "PyroWitches" then
		if Character:FindFirstChild("Wing1") then
			Character.Wing1:Destroy()
		end
		if Character:FindFirstChild("Wing2") then
			Character.Wing2:Destroy()
		end
	end

	local PossiblePlayer = Players:GetPlayerFromCharacter(Character) :: Player?
	if not PossiblePlayer then return end
	local Folder = PossiblePlayer:FindFirstChild("CharacterConfiguration")
	if Folder then 
		Folder:ClearAllChildren()
	else
		Folder = Instance.new("Configuration")
		Folder.Name = "CharacterConfiguration"
		Folder.Parent = PossiblePlayer
	end

	local humanoidDescription = Instance.new("HumanoidDescription",Character.Humanoid)

	local emoteTable = {
		["Curtsy"] = {4646306583},
		["Paris"] = {15392932768},
		["Festive"] = {15679955281},
		["Shrug"] = {3576968026},
		["Summon"] = {111658039138748},
		["Point"] = {3576823880},
		["Afk"] = {137850812284184},
		["Bored"] = {5230661597},
		["Sit"] = {85092320680319},
	}
	humanoidDescription:SetEmotes(emoteTable)

	local equippedEmotes = {"Curtsy", "Sit", "Paris", "Festive", "Summon", "Point", "Afk", "Bored"}
	humanoidDescription:SetEquippedEmotes(equippedEmotes)

	local Specie = Instance.new("StringValue",Folder)
	Specie.Name = "Specie"
	Specie.Value = Table.Specie
	local Gender = Instance.new("StringValue", Folder)
	Gender.Name = "Gender"
	Gender.Value = Table.Gender
	Character.MaxHealth.Value = Table.Health
	Character.Humanoid.MaxHealth = Character.MaxHealth.Value
	Character.Health.Value = Table.Health
	Character.Humanoid.Health = Character.Health.Value
	local CharacterName = Instance.new("StringValue",Folder)
	CharacterName.Name = "CharacterName"
	CharacterName.Value = Name
	RagdollRemoteEvent:FireClient(PossiblePlayer,"MOVEMENT_ON")
	local OutfitName = Instance.new("StringValue",Folder)
	OutfitName.Name = "OutfitName"
	OutfitName.Value = Outfit

	setupInfoGui(Character, Name, Specie, Name == "Hope Mikaelson", Table.IsElder)

	if not (isOutfitChange or isTurned ~= nil) then PossiblePlayer:SetAttribute("IsHarvested", false) end

	--game.ReplicatedStorage.Events.ClientReceiver:FireClient(PossiblePlayer,"disable_witch_actions")
	for _, playingTracks in pairs(Character.Humanoid:GetPlayingAnimationTracks()) do
		playingTracks:Stop(0)
	end
	local animateScript = Character:WaitForChild("Animate")
	if PossiblePlayer.CharacterConfiguration.Gender.Value == "Female" then
		animateScript.run.RunAnim.AnimationId = "rbxassetid://75286234205566" 
		animateScript.idle.Animation1.AnimationId = "rbxassetid://106432719885638"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://106432719885638"     
	elseif PossiblePlayer.CharacterConfiguration.Gender.Value == "Male" then
		animateScript.run.RunAnim.AnimationId = "rbxassetid://73740635551190"
		animateScript.idle.Animation1.AnimationId = "rbxassetid://107954921088809"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://107954921088809"
	end
	if Table.Specie == "Siphoners" or Table.Specie == "Heretics" or Table.Specie == "Werephoners" then
		task.spawn(function()
			if Name ~= "Dark Josie Saltzman" and Name ~= "Forbidden Pan" and Name ~= "Luna" then return end
			local left = Character:WaitForChild("LeftHand")
			local right = Character:WaitForChild("RightHand")
			left:WaitForChild("Siphon"):Destroy()
			right:WaitForChild("Siphon"):Destroy()
			local newParticles = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects.SiphonDJ:Clone()
			newParticles.Name = "Siphon"
			newParticles.Parent = left
			newParticles:Clone().Parent = right
		end)
	end
	-- ?? paste this directly BELOW your existing SiphonDJ block ??
	if Table.Specie == "Siphoners" or Table.Specie == "Heretics" or Table.Specie == "Werephoners" then
		task.spawn(function()
			if Name ~= "Forbidden Pan" then return end

			local left  = Character:WaitForChild("LeftHand")
			local right = Character:WaitForChild("RightHand")

			-- remove whatever the first block put on (likely SiphonDJ)
			local oldL = left:FindFirstChild("Siphon");  if oldL then oldL:Destroy() end
			local oldR = right:FindFirstChild("Siphon"); if oldR then oldR:Destroy() end

			local Effects = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Effects
			-- use your green prefab if it exists, otherwise safely fall back to SiphonDJ
			local greenPrefab = Effects:FindFirstChild("SiphonCursedBlack") or Effects:FindFirstChild("SiphonDJ")
			if not greenPrefab then return end

			local newL = greenPrefab:Clone()
			newL.Name = "Siphon"
			newL.Parent = left

			local newR = newL:Clone()
			newR.Parent = right
		end)
	end

	if isOutfitChange then return end
	if Table.Specie == "TimeLords" then
		if not PossiblePlayer.Backpack:FindFirstChild("TARDIS Key") then
			game.ServerStorage.TARDISStuff["TARDIS Key"]:Clone().Parent = PossiblePlayer.Backpack
		end
		game.ServerStorage.TARDISStuff["TARDIS Fly Control"]:Clone().Parent = PossiblePlayer.Backpack
		if not PossiblePlayer.Backpack:FindFirstChild("TARDIS Self Destruct") then
			game.ServerStorage.TARDISStuff["TARDIS Self Destruct"]:Clone().Parent = PossiblePlayer.Backpack
		end
	end
	if Name == "Esther Mikaelson" then
		local Sound = DLCFilesFolder.Chapter2.EstherIntro:Clone()
		Sound.Parent = Character.Head
		Sound:Play()
		animateScript.run.RunAnim.AnimationId = "rbxassetid://137881594798114"       
		animateScript.idle.Animation1.AnimationId = "rbxassetid://92651266093777"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://92651266093777"   



	elseif Name == "Dahlia" and Character:FindFirstChild("Ghost") == nil then
		local integer = math.random(1,2)
		animateScript.idle.Animation1.AnimationId = "rbxassetid://85542477928568"  
		animateScript.idle.Animation2.AnimationId = "rbxassetid://85542477928568"
		if integer == 1 then
			local Sound = DLCFilesFolder.Dahlia.MinorPlayer:Clone()
			Sound.Parent = Character.Head
			Sound:Play()
		else
			local Sound = DLCFilesFolder.Dahlia.OneMatch:Clone()
			Sound.Parent = Character.Head
			Sound:Play()
		end
	elseif Name == "Rebekah Mikaelson" and Character:FindFirstChild("Ghost") == nil then
		local integer = math.random(1,2)
		animateScript.idle.Animation1.AnimationId = "rbxassetid://123681301988538"  
		animateScript.idle.Animation2.AnimationId = "rbxassetid://123681301988538"
		if integer == 1 then
			local Sound = DLCFilesFolder.Chapter2.Humming:Clone()
			Sound.Parent = Character.Head
			Sound:Play()
		end
	elseif Name == "Katherine Pierce" and Character:FindFirstChild("Ghost") == nil then
		local integer = math.random(1,2)
		animateScript.idle.Animation1.AnimationId = "rbxassetid://128295420223358"  
		animateScript.idle.Animation2.AnimationId = "rbxassetid://128295420223358"
		if integer == 1 then
			local Sound = DLCFilesFolder.Chapter2.Humming:Clone()
			Sound.Parent = Character.Head
			Sound:Play()
		end

	elseif Name == "Sheila Bennett" then
		local Sound = DLCFilesFolder.Chapter2.Humming:Clone()
		Sound.Parent = Character.Head
		Sound:Play()

		animateScript.idle.Animation1.AnimationId = "rbxassetid://90921290163191"  
		animateScript.idle.Animation2.AnimationId = "rbxassetid://90921290163191"

	elseif Name == "Silas" then
		game.ServerStorage["The Cure"]:Clone().Parent = PossiblePlayer.Backpack
		local Sound = DLCFilesFolder.SilaB.Sound:Clone()
		Sound.Parent = Character.Head
		Sound:Play()
		--animateScript.run.RunAnim.AnimationId = "rbxassetid://112215583265262"       
		--animateScript.idle.Animation1.AnimationId = "rbxassetid://95741912271481"
		--animateScript.idle.Animation2.AnimationId = "rbxassetid://95741912271481" 

	elseif Name == "Bonnie Bennett" then
		local Sound = DLCFilesFolder.Bonbon.AllPower:Clone()
		Sound.Parent = Character.Head
		Sound:Play()
		game.ServerStorage["Ritual Circle"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["White Oak Stake"]:Clone().Parent = PossiblePlayer.Backpack
		--animateScript.run.RunAnim.AnimationId = "rbxassetid://112215583265262"       
		--animateScript.idle.Animation1.AnimationId = "rbxassetid://95741912271481"
		--animateScript.idle.Animation2.AnimationId = "rbxassetid://95741912271481" 



	elseif Name == "Hope Mikaelson" then
		if Character:FindFirstChild("BloodInSystem") == nil then
			local Value = Instance.new("IntValue",Character)
			Value.Name = "BloodInSystem"
		end
		local Sound = DLCFilesFolder.Chapter2.NoMonster:Clone()
		Sound.Parent = Character.Head --
		Sound:Play()
		--	
	elseif Name == "Niklaus Mikaelson" then
		game.ServerStorage["Silver Dagger"]:Clone().Parent = PossiblePlayer.Backpack
	elseif Name == "Davina Claire" then

		animateScript.idle.Animation1.AnimationId = "rbxassetid://123741032805764"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://123741032805764"   




		local Sound = DLCFilesFolder.Dav.regent:Clone()
		Sound.Parent = Character.Head
		Sound:Play()
		PossiblePlayer:SetAttribute("IsHarvested", true)
	elseif Name == "Qetsiyah" then

		animateScript.idle.Animation1.AnimationId = "rbxassetid://96319723526916"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://96319723526916"   




		local Sound = DLCFilesFolder.Chapter2.qetintro:Clone()
		Sound.Parent = Character.Head
		Sound:Play()
	elseif Name == "Dark Josie Saltzman" then
		--local Sound = DLCFilesFolder.Darkk.Sound:Clone()
		--Sound.Parent = Character.Head
		--Sound:Play()   
		animateScript.run.RunAnim.AnimationId = "rbxassetid://120193172918133" 
		animateScript.idle.Animation1.AnimationId = "rbxassetid://113049320852137"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://113049320852137"

		local Particle = DLCFilesFolder.EP1.followDust:Clone()
		local Particle2 = Particle:Clone()
		local Particle3 = DLCFilesFolder.EP1.darkAura:Clone()
		--local handp = DLCFilesFolder.EP1.darkMagicHand:Clone()
		--local light = DLCFilesFolder.EP1.darkMagicHandLight:Clone()
		--light.Parent = Character.RightHand
		--handp.Parent = Character.RightHand
		Particle3.Parent = Character.HumanoidRootPart
		Particle.Parent = Character.LeftFoot
		Particle2.Parent = Character.RightFoot
	elseif Name == "Zara Malory" then
		--animateScript.idle.Animation1.AnimationId = "rbxassetid://130544423475090"
		--animateScript.idle.Animation2.AnimationId = "rbxassetid://130544423475090"
	elseif Name == "Sydney Malory" then
		--animateScript.idle.Animation1.AnimationId = "rbxassetid://101675540616016"
		--animateScript.idle.Animation2.AnimationId = "rbxassetid://101675540616016"
	elseif Name == "Luna" then
		animateScript.idle.Animation1.AnimationId = "rbxassetid://93783091055508"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://93783091055508"
		local Particle = DLCFilesFolder.EP1.followDust:Clone()
		local Particle2 = Particle:Clone()
		local Particle3 = DLCFilesFolder.EP1.darkAura:Clone()
		Particle3.Parent = Character.HumanoidRootPart
		Particle.Parent = Character.LeftFoot
		Particle2.Parent = Character.RightFoot
	elseif Name == "Emma Malory" then
		animateScript.idle.Animation1.AnimationId = "rbxassetid://107101712489570"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://107101712489570"
		local Particle = DLCFilesFolder.EP1.followDust:Clone()
		local Particle2 = Particle:Clone()
		local Particle3 = DLCFilesFolder.EP1.darkAura:Clone()
		Particle3.Parent = Character.HumanoidRootPart
		Particle.Parent = Character.LeftFoot
		Particle2.Parent = Character.RightFoot
		game.ServerStorage["Ritual Circle"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["Workstation"]:Clone().Parent = PossiblePlayer.Backpack
		local immortal = Instance.new("Folder")
		immortal.Name = "DahliaImmortal"
		immortal.Parent = Character
	elseif Name == "Deceptive" then
		local Particle = DLCFilesFolder.EP1.followDust:Clone()
		local Particle2 = Particle:Clone()
		local Particle3 = DLCFilesFolder.EP1.darkAura:Clone()
		Particle3.Parent = Character.HumanoidRootPart
		Particle.Parent = Character.LeftFoot
		Particle2.Parent = Character.RightFoot
		game.ServerStorage["Workstation"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["Ritual Circle"]:Clone().Parent = PossiblePlayer.Backpack
	elseif Name == "Mikael Mikaelson" then
		game.ServerStorage["Mikael's White Oak Stake"]:Clone().Parent = PossiblePlayer.Backpack
	elseif Name == "Marcel Gerard" then
		game.ServerStorage["More Mysterious Drink"]:Clone().Parent = PossiblePlayer.Backpack
	elseif Name == "Elena Gilbert" then
		local Val = Instance.new("IntValue")
		Val.Name = "HasVervain"
	elseif Name == "Freya Mikaelson" then
		game.ServerStorage["Workstation"]:Clone().Parent = PossiblePlayer.Backpack
	elseif Name == "Forbidden Pan" then
		game.ServerStorage["Workstation"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["Ritual Circle"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["Candle"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage.Stakes["InfiniteStake"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["Thirst Bag"]:Clone().Parent = PossiblePlayer.Backpack
		if not Character:FindFirstChild("LunaWelcomeShown") then
			local flag = Instance.new("BoolValue")
			flag.Name = "LunaWelcomeShown"
			flag.Parent = Character

			local NotificationHandler = require(game.ServerScriptService.MainUI.NotificationHandler)
			NotificationHandler.Notification(PossiblePlayer, "Welcome Back Luna Astriel!")
		end
		local Value = Instance.new("IntValue",Character)
		Value.Name = "BloodInSystem"
	elseif Name == "Tay" then
		game.ServerStorage["Ritual Circle"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["Workstation"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["Candle"]:Clone().Parent = PossiblePlayer.Backpack
		if not Character:FindFirstChild("TayWelcomeShown") then
			local flag = Instance.new("BoolValue")
			flag.Name = "TayWelcomeShown"
			flag.Parent = Character

			local NotificationHandler = require(game.ServerScriptService.MainUI.NotificationHandler)
			NotificationHandler.Notification(PossiblePlayer, "Welcome Back Orion Solis!")
		end
		local Value = Instance.new("IntValue",Character)
		Value.Name = "BloodInSystem"
	elseif Name == "Alaric Saltzman" or Name == "Jeremy Gilbert" then
		game.ServerStorage.Crossbow:Clone().Parent = PossiblePlayer.Backpack;
		game.ServerStorage["Vervain Grenade"]:Clone().Parent = PossiblePlayer.Backpack;
		game.ServerStorage["Vervain Grenade"]:Clone().Parent = PossiblePlayer.Backpack;
		game.ServerStorage["Vervain Grenade"]:Clone().Parent = PossiblePlayer.Backpack;
		game.ServerStorage["Wolfsbane Grenade"]:Clone().Parent = PossiblePlayer.Backpack;
		game.ServerStorage["Wolfsbane Grenade"]:Clone().Parent = PossiblePlayer.Backpack;
		game.ServerStorage["Wolfsbane Grenade"]:Clone().Parent = PossiblePlayer.Backpack;
		game.ServerStorage["Magic Shackles"]:Clone().Parent = PossiblePlayer.Backpack;
		game.ServerStorage["Silver Dagger"]:Clone().Parent = PossiblePlayer.Backpack;
		for v51 = 1, 2 do
			game.ServerStorage["Alaric's Stake"]:Clone().Parent = PossiblePlayer.Backpack;
		end;
		local Ring = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Rings.GilbertRingModel:Clone()
		Ring.Parent = Character
		Ring:SetPrimaryPartCFrame(Character.LeftHand.CFrame * CFrame.new(-0.23,-0.1,-0.13) * CFrame.Angles(1.5,1.5,0))
		local WeldConstraint = Instance.new("WeldConstraint",Ring)
		WeldConstraint.Part0 = Character.LeftHand
		WeldConstraint.Part1 = Ring.PrimaryPart
		local Uses = Instance.new("IntValue", Ring)
		Uses.Name = "Uses"
		Uses.Value = 0
	elseif Name == "Dahlia" then
		animateScript.idle.Animation1.AnimationId = "rbxassetid://115536105523155"  
		animateScript.idle.Animation2.AnimationId = "rbxassetid://115536105523155"
	elseif Name == "Qetsiyah" then
		animateScript.idle.Animation1.AnimationId = "rbxassetid://137598653073505"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://137598653073505"

	elseif Name == "Inadu Labonair" then
		task.spawn(function()
			for _,v in Character:GetChildren() do
				local effect = DLCFilesFolder.Inadu.Inadu:Clone()
				if v:IsA("MeshPart") and v.Name ~= "HumanoidRootPart" and v.Name ~= "SkirtInadu" or v.Name == "Head" then
					effect.Parent = v
					task.delay(0.5, function()
						effect.Enabled = true
						effect:Emit(50)
						task.delay(7.5, function()
							effect.Enabled = false
						end)
					end)
				end
			end
		end)
		local sound = DLCFilesFolder.Inadu.OnSpawn:Clone()
		sound.Parent = Character.Head
		sound:Play()
	elseif Name == "Scream" then
		local immortal = Instance.new("Folder")
		immortal.Name = "DahliaImmortal"
		immortal.Parent = Character
		game.ServerStorage["Scream Knife"]:Clone().Parent = PossiblePlayer.Backpack
		for i = 0, 12 do
			game.ServerStorage["Blood Vial"]:Clone().Parent = PossiblePlayer.Backpack
		end
	elseif Name == "Forbidden Pan" then
		local song = game.ReplicatedStorage.ReplicatedAssets.WitchesAssets.Sounds.CrazySad:Clone()
		song.Parent = Character.Head
		song:Play()
	elseif Name == "Freya" then
		game.ServerStorage["Workstation"]:Clone().Parent = PossiblePlayer.Backpack
		game.ServerStorage["Magic Shackles"]:Clone().Parent = PossiblePlayer.Backpack	
		animateScript.idle.Animation1.AnimationId = "rbxassetid://87434349904863"
		animateScript.idle.Animation2.AnimationId = "rbxassetid://87434349904863"
	elseif Name == "Dahlia Hagen" then
		local song = game.ReplicatedStorage.ReplicatedAssets.DLCFiles.DahliaEpicIntro:Clone()
		song.Parent = Character.Head
		song:Play()
		local immortal = Instance.new("Folder")
		immortal.Name = "DahliaImmortal"
		immortal.Parent = Character
		animateScript.idle.Animation1.AnimationId = "rbxassetid://109277623797973"  
		animateScript.idle.Animation2.AnimationId = "rbxassetid://109277623797973"
	end
	--if Player.PlayerGui:FindFirstChild("MainUI") ~= nil then for i,Script in pairs(PossiblePlayer.PlayerGui.MainUI:GetChildren()) do if Script:IsA("Script") then Script.Disabled = false end end end
	if isTurned == nil then
		if Table.Specie == "Vampires" or Table.Specie == "Originals" or Table.Specie == "Hybrids" or Table.Specie == "Rippers" or Table.Specie == "UpgradedOriginals" then
			if Table.Specie == "Originals" then
				local ins = Instance.new("IntValue")
				ins.Name = "TrueImmortality"
				ins.Parent = Character
			end
			if Table.Specie ~= "Hybrids" then
				local Ring = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Rings.DaylightRingModel:Clone()
				Ring.Parent = Character
				Ring:SetPrimaryPartCFrame(Character.LeftHand.CFrame * CFrame.new(-0.23,-0.1,-0.13) * CFrame.Angles(1.5,1.5,0))
				local WeldConstraint = Instance.new("WeldConstraint",Ring)
				WeldConstraint.Part0 = Character.LeftHand
				WeldConstraint.Part1 = Ring.PrimaryPart
			end
			local VampireStats = Instance.new("Folder")
			VampireStats.Name = "VampireStats"
			VampireStats.Parent = Character
			local MaxThirst = Instance.new("IntValue",VampireStats)
			MaxThirst.Name = "MaxThirst"
			MaxThirst.Value = 200
			local Thirst = Instance.new("IntValue",VampireStats)
			Thirst.Name = "Thirst"
			Thirst.Value = MaxThirst.Value
			local Ring = Instance.new("BoolValue",VampireStats)
			Ring.Name = "HasRing"
			Ring.Value = true
			local MaxEnergy = Instance.new("IntValue",VampireStats)
			MaxEnergy.Name = "MaxEnergy"
			MaxEnergy.Value = Table.Energy
			local Energy = Instance.new("IntValue",VampireStats)
			Energy.Name = "Energy"
			Energy.Value = MaxEnergy.Value
		elseif Table.Specie == "Phoenix" then	
			local PhoenixStats = Instance.new("Folder",Character)
			PhoenixStats.Name = "PhoenixStats"
			local MaxEnergy = Instance.new("IntValue",PhoenixStats)
			MaxEnergy.Name = "MaxEnergy"
			MaxEnergy.Value = Table.Energy
			local Energy = Instance.new("IntValue",PhoenixStats)
			Energy.Name = "Energy"
			Energy.Value = MaxEnergy.Value
		elseif Table.Specie == "PyroWitches" then
			local WitchStats = Instance.new("Folder", Character)
			WitchStats.Name = "WitchStats"

			local MaxMagic = Instance.new("IntValue", WitchStats)
			MaxMagic.Name = "MaxMagic"
			MaxMagic.Value = Table.Magic or 1500

			local Magic = Instance.new("IntValue", WitchStats)
			Magic.Name = "Magic"
			Magic.Value = MaxMagic.Value

			local PhoenixStats = Instance.new("Folder", Character)
			PhoenixStats.Name = "PhoenixStats"

			local MaxEnergy = Instance.new("IntValue", PhoenixStats)
			MaxEnergy.Name = "MaxEnergy"
			MaxEnergy.Value = Table.Energy or 1000

			local Energy = Instance.new("IntValue", PhoenixStats)
			Energy.Name = "Energy"
			Energy.Value = MaxEnergy.Value

			-- Add rebirth flag for phoenix behaviour
			local Rebirth = Instance.new("BoolValue", Character)
			Rebirth.Name = "CanRebirth"
			Rebirth.Value = true

			-- Optional — if you want visuals or effects
			local FlameAura = Instance.new("BoolValue", Character)
			FlameAura.Name = "FlameAura"
			FlameAura.Value = true

		elseif Table.Specie == "Werewolves" or PossiblePlayer.CharacterConfiguration.Specie.Value == "Werewolves" then
			local WolfStats = Instance.new("Folder",Character)
			WolfStats.Name = "WolfStats"
			local MaxEnergy = Instance.new("IntValue",WolfStats)
			MaxEnergy.Name = "MaxEnergy"
			MaxEnergy.Value = Table.Energy
			local Energy = Instance.new("IntValue",WolfStats)
			Energy.Name = "Energy"
			Energy.Value = MaxEnergy.Value
			if not Character:FindFirstChild("HasMoonlightRing") then
				local val = Instance.new("IntValue")
				val.Name = 'HasMoonlightRing'
				val.Parent = Character
				local Ring = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Rings.MoonlightRingModel:Clone()
				Ring.Parent = Character
				Ring:SetPrimaryPartCFrame(Character.LeftHand.CFrame * CFrame.new(-0.23,-0.1,-0.13) * CFrame.Angles(1.5,1.5,0))
				local WeldConstraint = Instance.new("WeldConstraint",Ring)
				WeldConstraint.Part0 = Character.LeftHand
				WeldConstraint.Part1 = Ring.PrimaryPart
			end
		elseif Table.Specie == "Tribrids" or Table.Specie == "Customs"  then
			local WitchStats = Instance.new("Folder",Character)
			WitchStats.Name = "WitchStats"
			local MaxMagic = Instance.new("IntValue",WitchStats)
			MaxMagic.Name = "MaxMagic"
			MaxMagic.Value = Table.Magic
			local Magic = Instance.new("IntValue",WitchStats)
			Magic.Name = "Magic"
			Magic.Value = MaxMagic.Value
			--local Ring = game.ServerStorage.CharacterFiles.Rings.Ring_modelPos:Clone()
			--Ring.Parent = Character
			--Ring:SetPrimaryPartCFrame(Character.LeftHand.CFrame * CFrame.new(-0.23,-0.1,-0.13) * CFrame.Angles(1.5,1.5,0))
			--local WeldConstraint = Instance.new("WeldConstraint",Ring)
			--WeldConstraint.Part0 = Character.LeftHand
			--WeldConstraint.Part1 = Ring.PrimaryPart
			local VampireStats = Instance.new("Folder")
			VampireStats.Name = "VampireStats"
			VampireStats.Parent = Character
			local MaxThirst = Instance.new("IntValue",VampireStats)
			MaxThirst.Name = "MaxThirst"
			MaxThirst.Value = 200
			local Thirst = Instance.new("IntValue",VampireStats)
			Thirst.Name = "Thirst"
			Thirst.Value = MaxThirst.Value
			local Ring = Instance.new("BoolValue",VampireStats)
			Ring.Name = "HasRing"
			Ring.Value = true
			local MaxEnergy = Instance.new("IntValue",VampireStats)
			MaxEnergy.Name = "MaxEnergy"
			MaxEnergy.Value = Table.Energy
			local Energy = Instance.new("IntValue",VampireStats)
			Energy.Name = "Energy"
			Energy.Value = MaxEnergy.Value
			--elseif Table.Specie == "Mortals" then	
			--	if Name == "Liz Forbes" then
			--game.ServerStorage.Deagle:Clone().Parent = PossiblePlayer.Backpack
			--end
		elseif Table.Specie == "Witches" or Table.Specie == "Siphoners" or Table.Specie == "PyroWitches" or Table.Specie == "Heretics" or Table.Specie == "Werewitches" or PossiblePlayer.CharacterConfiguration.Specie.Value == "Werewitches" or Table.Specie == "Werephoners" or PossiblePlayer.CharacterConfiguration.Specie.Value == "Werephoners" then
			--game.ReplicatedStorage.Events.ClientReceiver:FireClient(Player,"enable_witch_actions")
			local WitchStats = Instance.new("Folder",Character)
			WitchStats.Name = "WitchStats"
			local MaxMagic = Instance.new("IntValue",WitchStats)
			MaxMagic.Name = "MaxMagic"
			MaxMagic.Value = Table.Magic
			local Magic = Instance.new("IntValue",WitchStats)
			Magic.Name = "Magic"
			if (Table.Specie == "Siphoners" or Table.Specie == "Heretics") and Name ~= "Luna" then
				Magic.Value = 0
			else
				Magic.Value = MaxMagic.Value
			end
			--	[	elseif Table.Species == "Werewitches" or PossiblePlayer.CharacterConfiguration.Specie.Value == "Werewitches" then
			--game.ReplicatedStorage.Events.ClientReceiver:FireClient(Player,"enable_witch_actions")
			--local WitchStats = Instance.new("Folder",Character)
			--	WitchStats.Name = "WitchStats"
			--local MaxMagic = Instance.new("IntValue",WitchStats)
			--MaxMagic.Name = "MaxMagic"
			--MaxMagic.Value = Table.Magic
			--	local Magic = Instance.new("IntValue",WitchStats)
			--	Magic.Name = "Magic"
			-- Magic.Value = MaxMagic.Value]
			if Name == "Dark Josie Saltzman" then

				Magic.Value = 1500
				task.wait(0.1)
				Magic.Value = MaxMagic.Value
			elseif Name == "Emma Malory" then

				Magic.Value = 1000000
					task.wait(0.1)
					Magic.Value = MaxMagic.Value
			end
			if Name == "Zara Malory" or Name == "Emma Malory" or Name == "Sydney Malory" or Name == "Forbidden Pan" or Name == "Hope Mikaelson" then
				local val = Instance.new("IntValue")
				val.Name = 'HasMoonlightRing'
				val.Parent = Character

				if Name == "Hope Mikaelson" then
					local val = Instance.new("IntValue")
					val.Name = 'HasMoonlightRing'
					val.Parent = Character
					local Ring = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Rings.MoonlightRingModel:Clone()
					Ring.Parent = Character
					Ring:SetPrimaryPartCFrame(Character.LeftHand.CFrame * CFrame.new(-0.23,-0.1,-0.13) * CFrame.Angles(1.5,1.5,0))
					local WeldConstraint = Instance.new("WeldConstraint",Ring)
					WeldConstraint.Part0 = Character.LeftHand
					WeldConstraint.Part1 = Ring.PrimaryPart
				end

			end
			if Table.Specie == "Siphoners" or Table.Specie == "Werephoners" then
				local SiphoningCooldown = Instance.new("BoolValue",WitchStats)
				SiphoningCooldown.Name = "SiphoningCooldown"
			end
			if Table.Specie == "Siphoners" then
				if Name == "Deceptive" or Name == "Luna" or Name == "iltria" or Name == "Astrid Bennett" or  Name == "Dark Josie Saltzman" or Name == "Forbidden Pan" then
					Magic.Value = MaxMagic.Value
				else
					Magic.Value = 0
				end


			elseif Table.Specie == "Werewolves" or PossiblePlayer.CharacterConfiguration.Specie.Value == "Werewolves" then
				local WolfStats = Instance.new("Folder",Character)
				WolfStats.Name = "WolfStats"
				local MaxEnergy = Instance.new("IntValue",WolfStats)
				MaxEnergy.Name = "MaxEnergy"
				MaxEnergy.Value = Table.Energy
				local Energy = Instance.new("IntValue",WolfStats)
				Energy.Name = "Energy"
				Energy.Value = MaxEnergy.Value

			elseif Table.Specie == "Werewitches" or PossiblePlayer.CharacterConfiguration.Specie.Value == "Werewitches" or Table.Specie == "Werewolves" or PossiblePlayer.CharacterConfiguration.Specie.Value == "Werewolves" or Table.Specie == "Werephoners" or PossiblePlayer.CharacterConfiguration.Specie.Value == "Werephoners" then
				local WolfStats = Instance.new("Folder",Character)
				WolfStats.Name = "WolfStats"
				local MaxEnergy = Instance.new("IntValue",WolfStats)
				MaxEnergy.Name = "MaxEnergy"
				MaxEnergy.Value = Table.Energy
				local Energy = Instance.new("IntValue",WolfStats)
				Energy.Name = "Energy"
				Energy.Value = MaxEnergy.Value

			elseif Table.Specie == "Heretics"	then
				--	local Ring = game.ServerStorage.CharacterFiles.Rings.Ring_modelPos:Clone()
				--	Ring.Parent = Character
				--		Ring:SetPrimaryPartCFrame(Character.LeftHand.CFrame * CFrame.new(-0.23,-0.1,-0.13) * CFrame.Angles(1.5,1.5,0))
				--	local WeldConstraint = Instance.new("WeldConstraint",Ring)
				--	WeldConstraint.Part0 = Character.LeftHand
				--	WeldConstraint.Part1 = Ring.PrimaryPart
				local VampireStats = Instance.new("Folder")
				VampireStats.Name = "VampireStats"
				VampireStats.Parent = Character
				local MaxThirst = Instance.new("IntValue",VampireStats)
				MaxThirst.Name = "MaxThirst"
				MaxThirst.Value = 200
				local Thirst = Instance.new("IntValue",VampireStats)
				Thirst.Name = "Thirst"
				Thirst.Value = MaxThirst.Value
				local Ring = Instance.new("BoolValue",VampireStats)
				Ring.Name = "HasRing"
				Ring.Value = true
				local MaxEnergy = Instance.new("IntValue",VampireStats)
				MaxEnergy.Name = "MaxEnergy"
				MaxEnergy.Value = Table.Energy
				local Energy = Instance.new("IntValue",VampireStats)
				Energy.Name = "Energy"
				Energy.Value = MaxEnergy.Value
				local SiphoningCooldown = Instance.new("BoolValue",WitchStats)
				SiphoningCooldown.Name = "SiphoningCooldown"


			end
			if CharacterName == "Luna" or CharacterName == "Deceptive" then
				local witchstats = Character:FindFirstChild("WitchStats")
			end
		end

		if not RunService:IsServer() then return end

		local tvlServerUtil = require(game.ServerScriptService.Modules.tvlServerUtil)

		if Table.Specie == "Witches" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a witch... \n \n Born with the power to manipulate the world through magical means. \n \n Read your grimoire for the spells you can use.")
			end
		elseif Character:FindFirstChild("Ghost") then
			tvlServerUtil.Hint(PossiblePlayer, "You are a spirit... \n \n Dead, but your soul lingers on. Somewhere inbetween, you must try to find a way out.... \n \n  Your spirit will shatter in 3 minutes.")
		elseif Table.Specie == "Vampires" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a vampire... \n \n A cursed, bloodthirsty predator living amongst mortals. \n \n  Check out your controls from the \"?\" button")
			end
		elseif Table.Specie == "Heretics" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a heretic... \n \n A bloodthirsty predator possessing mystical power. \n \n Read your grimoire & check controls.")
			end
		elseif Table.Specie == "Werewitches" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a werewitch... \n \n A mystical being, able to utilise the powers of the wolf at will. \n \n Read your grimoire & check controls. ")
			end
		elseif Table.Specie == "Werephoners" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a werephoner... \n \n A mystical being created by Forbidden Pan, able to utilise the powers of a siphoner and those of the wolf at will. \n \n Read your grimoire & check controls. ")
			end
		elseif Table.Specie == "Quadrabrids" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a quadrabrid... \n \n A combination of vampire and werephoner, yet more powerful than each... \n \n Read your grimoire & check controls.")
			end
		elseif Table.Specie == "Siphoners" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a siphoner... \n \n You must draw magical strength from other sources of power... \n \n Read your grimoire & check controls.")
			end
		elseif Table.Specie == "PyroWitches" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer,
					"You are a PyroWitch... \n \n A witch born with the eternal flame, blessed with phoenix rebirth and mystical power. \n \n Read your grimoire & check controls.")
			end

		elseif Table.Specie == "Werewolves" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a werewolf... \n \n A human, who transforms to beast with the power of the full moon. \n \n Check out your controls from the \"?\" button.")
			end
		elseif Table.Specie == "Hybrids" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a hybrid... \n \n A combination of the two most dangerous predators... \n \n Check out your controls from \"?\" button.")
			end
		elseif Table.Specie == "Tribrids" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a tribrid... \n \n A combination of vampire, wolf and witch, yet more powerful than each... \n \n Read your grimoire & check controls.")
			end
		elseif Table.Specie == "Phoenix" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a phoenix... \n \n An immortal being, in death you are reborn from the ashes... \n \n Check out your controls from the \"?\" button")
			end
		elseif Table.Specie == "Rippers" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a ripper... \n \n The insatiable thirst burns deeply within you. \n \n Check out your controls from the \"?\" button")
			end
		elseif Table.Specie == "Originals" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are an original... \n \n The strongest of all vampires, and the origin of the curse... \n \n Check out your controls from the \"?\" button")
			end
		elseif Table.Specie == "UpgradedOriginals" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are an upgraded original... \n \n Even stronger than an original... \n \n Check out your controls from the \"?\" button")
			end
		elseif Table.Specie == "TimeLords" then
			if not PossiblePlayer:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
				tvlServerUtil.Hint(PossiblePlayer, "You are a time lord... \n \n A long lived specie with the unique power of regeneration... \n \n Check out your controls from the \"?\" button")
			end
		end
	end
end



function MorphHandler.MorphCustom(Character, Gender, CharacterDisplayName, EyeColor, decidedSpecie)
	local Player = Players:GetPlayerFromCharacter(Character)

	--local StrixRole   = Player:GetRoleInGroup(10083638)
	--local SilverRole  = Player:GetRoleInGroup(10083737)
	--local SolarisRole = Player:GetRoleInGroup(10635178)
	local isFaction = FactionUtils.GetFactionSpecie(Player)
	local FactionDisplay = isFaction and FactionUtils.GetFactionDisplayName(Player)
	local isLeader = FactionDisplay and string.find(FactionDisplay, "Leader") ~= nil
	local multiplier = 1
	if isLeader then multiplier = 2 end
	if isFaction then decidedSpecie = isFaction end

	if CharacterDisplayName == nil or CharacterDisplayName == "" then
		CharacterDisplayName = Player.DisplayName
	end

	--if StrixRole ~= "Guest" or SilverRole ~= "Guest" or SolarisRole ~= "Guest" then
	--	if not Player:FindFirstChild("SpawnFolder") then
	--		if StrixRole ~= "Guest" and StrixRole ~= "TVL | Management" and StrixRole ~= "TVL" then
	--			decidedSpecie = "Vampires"
	--		elseif SilverRole ~= "Guest" and SilverRole ~= "TVL | Management" and SilverRole ~= "TVL" then
	--			decidedSpecie = "Werewolves"
	--		elseif SolarisRole ~= "Guest" and SolarisRole ~= "TVL | Management" and SolarisRole ~= "TVL" then
	--			decidedSpecie = "Witches"
	--		end
	--		isFaction = decidedSpecie
	--	end
	--end

	local Specie
	local CharacterConfiguration = Player:FindFirstChild("CharacterConfiguration")
	if CharacterConfiguration == nil then
		CharacterConfiguration = Instance.new("Folder")
		CharacterConfiguration.Name = "CharacterConfiguration"
		CharacterConfiguration.Parent = Player
		Specie = Instance.new("StringValue",CharacterConfiguration)
		Specie.Name = "Specie"
		Specie.Value = decidedSpecie

		local isCustom = Instance.new("Folder")
		isCustom.Name = "isCustom"
		isCustom.Parent = CharacterConfiguration

		local originalSpecie = Instance.new("StringValue")
		originalSpecie.Name = "OriginalSpecie"
		originalSpecie.Value = decidedSpecie
		originalSpecie.Parent = isCustom

		local eyeC = Instance.new("StringValue")
		eyeC.Name = "EyeColor"
		eyeC.Value = EyeColor
		eyeC.Parent = isCustom

		local displayName = Instance.new("StringValue")
		displayName.Name = "CusDisplayName"
		displayName.Value = CharacterDisplayName
		displayName.Parent = isCustom

		local GenderV = Instance.new("StringValue", CharacterConfiguration)
		GenderV.Name = "Gender"
		GenderV.Value = Gender
		Character.Humanoid.MaxHealth = (if decidedSpecie == "Mortals" then 100 else 250) * multiplier
		Character.Humanoid.Health = Character.Humanoid.MaxHealth
		local CharacterName = Instance.new("StringValue",CharacterConfiguration)
		CharacterName.Name = "CharacterName"
		CharacterName.Value = "custom"


		local OutfitName = Instance.new("StringValue",CharacterConfiguration)
		OutfitName.Name = "OutfitName"
		OutfitName.Value =  Gender..EyeColor

		if isFaction == "Werewolves" then
			local CustomWolf = Instance.new("IntValue")
			CustomWolf.Name = "CustomWolf"
			CustomWolf.Parent = isCustom
			task.defer(function()
				local backpack = Player:WaitForChild("Backpack")

				if not backpack:FindFirstChild("Wooden Stake") then
					game.ServerStorage.Stakes:WaitForChild("Silvercrest Stake"):Clone().Parent = backpack
				end
			end)
		elseif isFaction == "Vampires" then
			local StrixRip = Instance.new("IntValue")
			StrixRip.Name = "StrixRip"
			StrixRip.Parent = isCustom
		elseif isFaction == "Witches" then
			local Solaris = Instance.new("IntValue")
			Solaris.Name = "SolarisIncen" 
			Solaris.Parent = isCustom
		elseif isFaction == "Werephoners" then
			local Forbidden = Instance.new("IntValue")
			Forbidden.Name = "Forbidden"
			Forbidden.Parent = isCustom
		end
	else
		Specie = CharacterConfiguration:FindFirstChild("Specie")
	end


	local Configuration = Players:GetHumanoidDescriptionFromUserId(Player.UserId)
	local HumanoidDescription = Instance.new("HumanoidDescription")
	HumanoidDescription.TorsoColor = Configuration.TorsoColor
	HumanoidDescription.HeadColor = Configuration.HeadColor
	HumanoidDescription.LeftArmColor = Configuration.LeftArmColor
	HumanoidDescription.RightArmColor = Configuration.RightArmColor
	HumanoidDescription.LeftArmColor = Configuration.LeftArmColor
	HumanoidDescription.RightArmColor = Configuration.RightArmColor
	HumanoidDescription.HairAccessory = Configuration.HairAccessory
	HumanoidDescription.LeftLegColor = Configuration.LeftLegColor
	HumanoidDescription.RightLegColor = Configuration.RightLegColor
	HumanoidDescription.FaceAccessory = Configuration.FaceAccessory

	HumanoidDescription.BackAccessory = ""
	HumanoidDescription.FrontAccessory = ""
	HumanoidDescription.NeckAccessory = ""
	HumanoidDescription.WaistAccessory = ""
	HumanoidDescription.ShouldersAccessory = ""
	HumanoidDescription.HatAccessory = ""
	--HumanoidDescription.HeadScale = Configuration.HeadScale

	HumanoidDescription.Head = "rbxassetid://746767604"
	HumanoidDescription.DepthScale = 0.8
	HumanoidDescription.HeightScale = 1.08 -- 1.08
	HumanoidDescription.WidthScale = 0.75
	HumanoidDescription.Shirt = Configuration.Shirt
	HumanoidDescription.Pants = Configuration.Pants

	if CharacterConfiguration:FindFirstChild("isCustom") and not CharacterConfiguration:FindFirstChild("isCustom"):FindFirstChild("SkinCol") then
		local SkinCol = Instance.new("Color3Value")
		SkinCol.Name = "SkinCol"
		SkinCol.Value =  Configuration.HeadColor
		SkinCol.Parent = CharacterConfiguration.isCustom
	end


	local animateScript = Character:FindFirstChild("Animate")
	if animateScript ~= nil then
		if Gender == "Female" then
			animateScript.run.RunAnim.AnimationId = "rbxassetid://128354138529970" 
			animateScript.idle.Animation1.AnimationId = "rbxassetid://106432719885638"
			animateScript.idle.Animation2.AnimationId = "rbxassetid://106432719885638"    
		elseif Gender == "Male" then
			animateScript.run.RunAnim.AnimationId = "rbxassetid://128661430753575"
			animateScript.idle.Animation1.AnimationId = "rbxassetid://108904923984685"
			animateScript.idle.Animation2.AnimationId = "rbxassetid://108904923984685"
		end
	end
	repeat task.wait() until Character.Parent == workspace or Character.Parent == workspace.Live
	Character.Humanoid:ApplyDescription(HumanoidDescription)
	Character.Head.Mesh.Scale = Vector3.new(1.15,1.15,1.15)
	Character.Ears.BrickColor = BrickColor.new(Configuration.HeadColor)
	Character.Head.Face.Texture = CharacterConfigurationList["custom"].Outfits[Gender..EyeColor].Face.Texture


	local magic, energy

	if isFaction == "Witches" then
		magic = 1000;
	elseif isFaction == "Vampires" then
		energy = 1000;
	elseif isFaction == "Werewolves" then
		energy = 1000;
	elseif isFaction == "Werephoners" then
		energy = 100000
		magic = 10000
	else
		energy = 350;
		magic = 750;
	end;

	if decidedSpecie == "Witches" or  decidedSpecie == "Siphoners" or  decidedSpecie == "Werewitches" or  decidedSpecie == "Werephoners" or  decidedSpecie == "PyroWitches" then
		if not Character:FindFirstChild("WitchStats") then
			local WitchStats = Instance.new("Folder",Character)
			WitchStats.Name = "WitchStats"
			local MaxMagic = Instance.new("IntValue",WitchStats)
			MaxMagic.Name = "MaxMagic"
			MaxMagic.Value = magic * multiplier
			if decidedSpecie == "Werewitches" or decidedSpecie == "Werephoners" then
				if not Character:FindFirstChild("WolfStats") then
					local WolfStats = Instance.new("Folder",Character)
					WolfStats.Name = "WolfStats"
					local MaxEnergy = Instance.new("IntValue",WolfStats)
					MaxEnergy.Name = "MaxEnergy"
					MaxEnergy.Value = energy * multiplier
					local Energy = Instance.new("IntValue",WolfStats)
					Energy.Name = "Energy"
					Energy.Value = MaxEnergy.Value
				end
			end

			local Magic = Instance.new("IntValue",WitchStats)
			Magic.Name = "Magic"
			if decidedSpecie ~= "Siphoners" and decidedSpecie ~= "Werephoners" then
				Magic.Value = MaxMagic.Value
			else
				local SiphoningCooldown = Instance.new("BoolValue",WitchStats)
				SiphoningCooldown.Name = "SiphoningCooldown"
				Magic.Value = 0
			end
			if CharacterConfiguration:FindFirstChild("isCustom") then
				local storedenergy = Instance.new("IntValue",CharacterConfiguration.isCustom)
				storedenergy.Name = "OriginalMaxPower"
				storedenergy.Value = MaxMagic.Value
			end
		end
	elseif decidedSpecie == "Vampires" then
		if not Character:FindFirstChild("VampireStats") then
			local Ring = game.ReplicatedStorage.ReplicatedAssets.CharacterFiles.Rings.DaylightRingModel:Clone()
			Ring.Parent = Character
			Ring:SetPrimaryPartCFrame(Character.LeftHand.CFrame * CFrame.new(-0.23,-0.1,-0.13) * CFrame.Angles(1.5,1.5,0))
			local WeldConstraint = Instance.new("WeldConstraint",Ring)
			WeldConstraint.Part0 = Character.LeftHand
			WeldConstraint.Part1 = Ring.PrimaryPart

			local VampireStats = Instance.new("Folder")
			VampireStats.Name = "VampireStats"
			VampireStats.Parent = Character
			local MaxThirst = Instance.new("IntValue",VampireStats)
			MaxThirst.Name = "MaxThirst"
			MaxThirst.Value = 200 * multiplier
			local Thirst = Instance.new("IntValue",VampireStats)
			Thirst.Name = "Thirst"
			Thirst.Value = MaxThirst.Value
			local Ring = Instance.new("BoolValue",VampireStats)
			Ring.Name = "HasRing"
			Ring.Value = true
			local MaxEnergy = Instance.new("IntValue",VampireStats)
			MaxEnergy.Name = "MaxEnergy"
			MaxEnergy.Value = energy * multiplier
			local Energy = Instance.new("IntValue",VampireStats)
			Energy.Name = "Energy"
			Energy.Value = MaxEnergy.Value
			if CharacterConfiguration:FindFirstChild("isCustom") then
				local energyval = Instance.new("IntValue",CharacterConfiguration.isCustom)
				energyval.Name = "OriginalMaxPower"
				energyval.Value = MaxEnergy.Value
			end
		end
	elseif decidedSpecie == "Werewolves" then
		if not Character:FindFirstChild("WolfStats") then
			local WolfStats = Instance.new("Folder",Character)
			WolfStats.Name = "WolfStats"
			local MaxEnergy = Instance.new("IntValue",WolfStats)
			MaxEnergy.Name = "MaxEnergy"
			MaxEnergy.Value = energy * multiplier

			local Energy = Instance.new("IntValue",WolfStats)
			Energy.Name = "Energy"
			Energy.Value = MaxEnergy.Value
			if CharacterConfiguration:FindFirstChild("isCustom") then
				local energyval = Instance.new("IntValue",CharacterConfiguration.isCustom)
				energyval.Name = "OriginalMaxPower"
				energyval.Value = MaxEnergy.Value
			end
		end
	end
	if isFaction == "Werewolves" then
		local venombuff = Instance.new("IntValue")
		venombuff.Name = "VenomBuff"
		venombuff.Parent = Character
		
		elseif isFaction == "Werephoners" then
			local venombuff = Instance.new("IntValue")
			venombuff.Name = "VenomBuff"
			venombuff.Parent = Character
	end
	
	if decidedSpecie ~= "Phoenix" and decidedSpecie ~= "PyroWitches" then
		if Character:FindFirstChild("Wing1") and Character:FindFirstChild("Wing2") then
			Character.Wing1:Destroy()
			Character.Wing2:Destroy()
		end
	end


	setupInfoGui(Character, CharacterDisplayName, Specie, false, false)

	HumanoidDescription:Destroy()
	Configuration:Destroy()

	if not Player:FindFirstChild("GoingBackAsHuman") and not Character:FindFirstChild("Ghost") then
		arriveText(Player, "You arrive as a " .. singular[decidedSpecie] .. ".")
		if decidedSpecie == "Mortal" then
			replicatedUtil.Hint(Player, "You are fragile in this supernatural town... Explore and find ways to survive!", 10);
		else
			replicatedUtil.Hint(Player, "You are supernatural with special perks... \n Check out your controls from the controls UI.", 10);
		end;
	end
end



function MorphHandler.MorphWorldModelCustom(Character, Player, Gender, EyeColor)
	local Configuration = Players:GetHumanoidDescriptionFromUserId(Player.UserId)
	local HumanoidDescription = Instance.new("HumanoidDescription")
	HumanoidDescription.TorsoColor = Configuration.TorsoColor
	HumanoidDescription.HeadColor = Configuration.HeadColor
	HumanoidDescription.LeftArmColor = Configuration.LeftArmColor
	HumanoidDescription.RightArmColor = Configuration.RightArmColor
	HumanoidDescription.LeftArmColor = Configuration.LeftArmColor
	HumanoidDescription.RightArmColor = Configuration.RightArmColor
	HumanoidDescription.HairAccessory = Configuration.HairAccessory
	HumanoidDescription.LeftLegColor = Configuration.LeftLegColor
	HumanoidDescription.RightLegColor = Configuration.RightLegColor
	HumanoidDescription.BackAccessory = ""
	HumanoidDescription.FrontAccessory = ""
	HumanoidDescription.NeckAccessory = ""
	HumanoidDescription.WaistAccessory = ""
	HumanoidDescription.ShouldersAccessory = ""
	HumanoidDescription.HatAccessory = ""
	HumanoidDescription.FaceAccessory = Configuration.FaceAccessory
	--HumanoidDescription.HeadScale = Configuration.HeadScale
	HumanoidDescription.DepthScale = 0.8
	HumanoidDescription.HeightScale = 1.08 -- 1.08
	HumanoidDescription.WidthScale = 0.75
	HumanoidDescription.Shirt = Configuration.Shirt
	HumanoidDescription.Pants = Configuration.Pants
	Character.Humanoid:ApplyDescription(HumanoidDescription)

	Character.Head.Mesh.Scale = Vector3.new(1.15,1.15,1.15)
	Character.Ears.BrickColor = BrickColor.new(Configuration.HeadColor)
	Character.Head.Face.Texture = CharacterConfigurationList["custom"].Outfits[Gender..EyeColor].Face.Texture

	HumanoidDescription:Destroy()
	Configuration:Destroy()
end

function MorphHandler.MorphWorldStandard(Character,CharacterName,Outfit,isTurned)
	for Name,Table in pairs(CharacterConfigurationList) do
		if CharacterName == Name then
			for i,part in pairs(Character:GetChildren()) do
				if part:IsA("Part") or part:IsA("BasePart") then
					if Table.Outfits[Outfit].BodyColor ~= nil then
						part.Color = Table.Outfits[Outfit].BodyColor.Value
					end
				elseif part:IsA("Accessory") then
					part:Destroy()
				end
			end
			local hum

			if not Character:FindFirstChild("Humanoid") then
				hum = Instance.new("Humanoid")
				hum.Parent = Character
			else
				hum = Character.Humanoid
			end


			if Table.Outfits[Outfit].Face:IsA("Decal") then
				Character.Head.Face.Texture = Table.Outfits[Outfit].Face.Texture
			end
			if Table.Outfits[Outfit].Shirt:IsA("Shirt") then
				Character.Shirt.ShirtTemplate = Table.Outfits[Outfit].Shirt.ShirtTemplate
				Character.Shirt.Color3 = Table.Outfits[Outfit].Shirt.Color3
			end
			if Table.Outfits[Outfit].Pants:IsA("Pants") then
				Character.Pants.PantsTemplate = Table.Outfits[Outfit].Pants.PantsTemplate
				Character.Pants.Color3 = Table.Outfits[Outfit].Pants.Color3
			end		
			if Table.Outfits[Outfit].Skirt ~= nil and Table.Outfits[Outfit].SkirtOffset then
				local Skirt = Table.Outfits[Outfit].Skirt:Clone()
				local Weld = Instance.new("WeldConstraint",Skirt)
				Skirt.Position = Character.LowerTorso.Position - Table.Outfits[Outfit].SkirtOffset
				Weld.Part0 = Character.LowerTorso
				Weld.Part1 = Skirt
				Skirt.Parent= Character
			end
			for i,accessory in pairs(Table.Outfits[Outfit].Hair) do
				if accessory:IsA("Accessory") then
					local newacc = accessory:Clone()
					addAccessory(Character, newacc)
				end
			end
			if Table.Specie ~= "Phoenix" and Table.Specie ~= "PyroWitches" then
				if Character:FindFirstChild("Wing1") ~= nil and Character:FindFirstChild("Wing2") ~= nil then
					Character.Wing1:Destroy() Character.Wing2:Destroy()
				end
			end
		end
	end
end

MorphHandler.Singular = singular

return MorphHandler
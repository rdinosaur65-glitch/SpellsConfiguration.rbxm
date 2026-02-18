local Handler = {}
local MaxNotifications = 5

local function DestroyNotification(Notification: Frame)
	pcall(function()
		Notification:TweenPosition(UDim2.new(1.5, 0, Notification.Position.Y.Scale, 0),"InOut","Linear",0.2,true);
	end)
	task.wait(0.2)
	Notification:Destroy()
end

function Handler.AdvancedNotification(Player,Duration,Title,Message)
	task.spawn(function()
		local UI = Player.PlayerGui:FindFirstChild("NotificationUI")
		if UI == nil then return end
		local NotificationDuration = Duration
		local Notifications = UI.Notifications:GetChildren()
		if #Notifications >= MaxNotifications then
			DestroyNotification(Notifications[1])
		end
		for i,v in pairs(Notifications) do
			pcall(function()
				v:TweenPosition(UDim2.new(0.97, 0, v.Position.Y.Scale - 0.12, 0),"InOut","Linear",0.2,true)
			end)
		end
		local NewNotification = game.ServerStorage.NotificationTemplate:Clone()
		NewNotification.Name = tostring(#Notifications+1)
		NewNotification.Text.Text = Message
		NewNotification.Header.HeaderLabel.Text = Title
		NewNotification.Parent = UI.Notifications
		game:GetService("Debris"):AddItem(NewNotification, NotificationDuration + 0.35)
		pcall(function()
			NewNotification:TweenPosition(UDim2.new(0.97, 0, 0.85, 0),"InOut","Sine",0.2,true)
		end)
		task.delay(NotificationDuration, DestroyNotification, NewNotification)
	end)
end

function Handler.Notification(Player,Message)
	Handler.AdvancedNotification(Player, 5, "Notification", Message)
end

game.ReplicatedStorage.Events.SelfNotification.OnServerEvent:Connect(function(player, tab)
	Handler.AdvancedNotification(player, tab.Duration or 5, tab.Title or "Notification", tab.Message)
end)

return Handler
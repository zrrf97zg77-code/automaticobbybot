
-- Tower of Hell: START/STOP Movement Test
-- Run after your character has spawned.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
if not player then
    warn("No LocalPlayer found")
    return
end

local playerGui = player:WaitForChild("PlayerGui", 10)
if not playerGui then
    warn("PlayerGui not found")
    return
end

local old = playerGui:FindFirstChild("TowerMovementTest")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "TowerMovementTest"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
gui.Parent = playerGui

local button = Instance.new("TextButton")
button.Size = UDim2.fromOffset(130, 48)
button.Position = UDim2.new(0.5, -65, 0.75, 0)
button.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
button.TextColor3 = Color3.new(1, 1, 1)
button.TextScaled = true
button.Text = "START"
button.Active = true
button.Parent = gui

Instance.new("UICorner", button).CornerRadius =
    UDim.new(0, 10)

local enabled = false
local connection

local function stop()
    enabled = false
    button.Text = "START"

    if connection then
        connection:Disconnect()
        connection = nil
    end

    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum:Move(Vector3.zero, false)
    end
end

button.Activated:Connect(function()
    if enabled then
        stop()
        return
    end

    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local root = char and char:FindFirstChild("HumanoidRootPart")

    if not hum or not root or hum.Health <= 0 then
        button.Text = "NO CHARACTER"
        task.delay(1.5, function()
            if button.Parent then button.Text = "START" end
        end)
        return
    end

    enabled = true
    button.Text = "STOP"

    connection = RunService.Heartbeat:Connect(function()
        if not enabled then return end

        local current = player.Character
        local h = current and current:FindFirstChildOfClass("Humanoid")
        local r = current and current:FindFirstChild("HumanoidRootPart")

        if not h or not r or h.Health <= 0 then
            stop()
            return
        end

        h:Move(r.CFrame.LookVector, false)
    end)
end)

print("[TowerTest] Loaded successfully")

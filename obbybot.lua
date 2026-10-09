--!strict
-- Obby Auto-Runner v5.1 — No shiftlock, no speed boost
-- Place in StarterPlayer/StarterPlayerScripts

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ===== CONFIG =====
local SCAN_RANGE = 50
local SCAN_HALF_ANGLE = 55
local RAY_COUNT = 9
local SCAN_INTERVAL = 0.12
local EDGE_APPROACH_DIST = 3.5
local JUMP_COOLDOWN = 0.18
local STUCK_TIMEOUT = 1.5
local STUCK_PROGRESS_THRESHOLD = 0.5

-- WALLHOP / LADDER
local WALL_CHECK_DIST = 4.5
local WALLHOP_ENABLED = true
local WALLHOP_COOLDOWN = 0.45
local LADDER_SPAM_INTERVAL = 0.12
local LADDER_DETECT_DIST = 4

-- ===== WHITELIST =====
local WHITELIST_FOLDER_NAME = "Obby"
local WHITELIST_TAG = "ObbyPlatform"

local function getWhitelistInstances(): {Instance}
    local list = {}
    if WHITELIST_FOLDER_NAME then
        local folder = Workspace:FindFirstChild(WHITELIST_FOLDER_NAME)
        if folder then table.insert(list, folder) end
    end
    if WHITELIST_TAG then
        for _, obj in CollectionService:GetTagged(WHITELIST_TAG) do
            table.insert(list, obj)
        end
    end
    return list
end

-- ===== STATE =====
local botEnabled = false
local currentStatus = "BOT OFF"
local humanoid: Humanoid? = nil
local hrp: BasePart? = nil

local lastPos = Vector3.zero
local lastProgressTime = 0
local lastJumpTime = 0
local lastWallhopTime = 0
local lastLadderSpam = 0
local currentTarget: BasePart? = nil
local cachedMoveDir = Vector3.zero
local cachedShouldJump = false
local scanAccum = 0

-- ===== RAYCAST (whitelist only) =====
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.IgnoreWater = true
rayParams.RespectCanCollide = true

-- ===== UI =====
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ObbyBotUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(0, 80, 0, 40)
toggleBtn.Position = UDim2.new(0, 12, 0, 12)
toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 65)
toggleBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
toggleBtn.TextSize = 13
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.Text = "BOT OFF"
toggleBtn.AutoButtonColor = false
toggleBtn.Parent = screenGui
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 8)

-- ===== CHARACTER BIND =====
local function onCharacter(char: Model)
    local h = char:WaitForChild("Humanoid", 5) :: Humanoid?
    local r = char:WaitForChild("HumanoidRootPart", 5) :: BasePart?
    if not h or not r then return end

    humanoid = h
    hrp = r
    currentTarget = nil
    lastPos = r.Position
    lastProgressTime = tick()

    -- make sure no leftover shiftlock state sticks around
    h.AutoRotate = true
    h.CameraOffset = Vector3.new(0, 0, 0)

    local filter = getWhitelistInstances()
    table.insert(filter, char)
    rayParams.FilterDescendantsInstances = filter
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then task.defer(onCharacter, player.Character) end

-- ===== SCAN =====
local function scanForPlatforms(origin: Vector3, facing: Vector3): BasePart?
    local bestPart: BasePart? = nil
    local bestScore = -math.huge
    local fwd = Vector3.new(facing.X, 0, facing.Z).Unit
    local right = Vector3.new(fwd.Z, 0, -fwd.X)

    for i = 0, RAY_COUNT - 1 do
        local t = (i / (RAY_COUNT - 1)) * 2 - 1
        local angleRad = math.rad(SCAN_HALF_ANGLE * t)
        local dir = (fwd * math.cos(angleRad) + right * math.sin(angleRad)).Unit

        local result = Workspace:Raycast(origin, dir * SCAN_RANGE, rayParams)
        if not result then continue end
        local part = result.Instance
        if not part:IsA("BasePart") then continue end
        if math.abs(result.Normal.Y) < 0.7 then continue end

        local hitPos = result.Position
        local dist = (hitPos - origin).Magnitude
        local heightDiff = hitPos.Y - origin.Y
        if heightDiff > 6 or heightDiff < -18 then continue end
        if dist < 2.5 then continue end

        local score = (SCAN_RANGE - dist) * 1.2
        score -= math.abs(heightDiff - 2) * 0.5
        score += (1 - math.abs(t)) * 4

        if score > bestScore then
            bestScore = score
            bestPart = part
        end
    end
    return bestPart
end

local function hasGroundBelow(pos: Vector3, maxDepth: number): boolean
    local result = Workspace:Raycast(pos, Vector3.new(0, -maxDepth, 0), rayParams)
    return result ~= nil and result.Instance:IsA("BasePart")
        and math.abs(result.Normal.Y) > 0.7
end

local function detectWall(pos: Vector3, facing: Vector3): Vector3?
    local fwd = Vector3.new(facing.X, 0, facing.Z).Unit
    local right = Vector3.new(fwd.Z, 0, -fwd.X)
    for _, dir in { right, -right } do
        local res = Workspace:Raycast(pos + Vector3.new(0, 1, 0), dir * WALL_CHECK_DIST, rayParams)
        if res and res.Instance:IsA("BasePart")
            and math.abs(res.Normal.Y) < 0.4 then
            return dir
        end
    end
    return nil
end

local function detectLadder(pos: Vector3, facing: Vector3): boolean
    local fwd = Vector3.new(facing.X, 0, facing.Z).Unit
    local res = Workspace:Raycast(pos + Vector3.new(0, 1.5, 0), fwd * LADDER_DETECT_DIST, rayParams)
    if not res then return false end
    local p = res.Instance
    if p:IsA("TrussPart") then return true end
    local name = p.Name:lower()
    return name:find("ladder") ~= nil or name:find("truss") ~= nil
end

-- ===== MAIN DECISION =====
local function recompute()
    if not humanoid or not hrp then return end
    local rootPos = hrp.Position
    local facing = hrp.CFrame.LookVector
    local now = tick()

    if rootPos.Y < -50 then
        currentStatus = "RECOVERING"
        cachedMoveDir = Vector3.zero
        cachedShouldJump = false
        return
    end

    if (rootPos - lastPos).Magnitude > STUCK_PROGRESS_THRESHOLD then
        lastPos = rootPos
        lastProgressTime = now
    elseif now - lastProgressTime > STUCK_TIMEOUT then
        currentStatus = "RECOVERING"
        if humanoid.FloorMaterial ~= Enum.Material.Air then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
        lastProgressTime = now
    end

    if detectLadder(rootPos, facing) then
        currentStatus = "LADDER"
        cachedMoveDir = Vector3.new(facing.X, 0, facing.Z).Unit
        cachedShouldJump = true
        return
    end

    local targetPos: Vector3? = nil
    if currentTarget and currentTarget.Parent then
        targetPos = currentTarget.Position
    else
        currentStatus = "SCANNING"
        currentTarget = scanForPlatforms(rootPos, facing)
        if currentTarget then targetPos = currentTarget.Position end
    end

    if not targetPos then
        currentStatus = "SCANNING"
        cachedMoveDir = Vector3.new(facing.X, 0, facing.Z).Unit
        cachedShouldJump = false
        return
    end

    local toTarget = Vector3.new(targetPos.X - rootPos.X, 0, targetPos.Z - rootPos.Z)
    local flatDist = toTarget.Magnitude
    if flatDist < 0.5 then
        currentTarget = nil
        cachedMoveDir = Vector3.zero
        return
    end

    local moveDir = toTarget.Unit
    if flatDist < EDGE_APPROACH_DIST then
        moveDir = moveDir * math.max(0.5, flatDist / EDGE_APPROACH_DIST)
    end

    local shouldJump = false
    local heightDiff = targetPos.Y - rootPos.Y
    local grounded = humanoid.FloorMaterial ~= Enum.Material.Air

    local aheadOrigin = rootPos + Vector3.new(0, -2.5, 0) + moveDir.Unit * math.min(flatDist, 4)
    if not hasGroundBelow(aheadOrigin, 8) and flatDist > 2 and flatDist < 14 then
        shouldJump = true
    end
    if heightDiff > 2.5 and flatDist < 12 then shouldJump = true end

    if WALLHOP_ENABLED and grounded then
        local wallDir = detectWall(rootPos, facing)
        if wallDir and now - lastWallhopTime > WALLHOP_COOLDOWN then
            local wallRes = Workspace:Raycast(rootPos + Vector3.new(0, 1, 0), wallDir * WALL_CHECK_DIST, rayParams)
            if wallRes and wallRes.Instance:IsA("BasePart")
                and math.abs(wallRes.Normal.Y) < 0.4 then
                currentStatus = "WALLHOP"
                humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                lastWallhopTime = now
                moveDir = (moveDir + wallDir * 0.6).Unit
            end
        end
    end

    cachedMoveDir = moveDir
    cachedShouldJump = shouldJump
    if currentStatus ~= "WALLHOP" and currentStatus ~= "LADDER" then
        currentStatus = "MOVING"
    end
end

-- ===== APPLY EVERY FRAME =====
RunService.RenderStepped:Connect(function(dt)
    if not botEnabled or not humanoid or not hrp then return end

    scanAccum += dt
    if scanAccum >= SCAN_INTERVAL then
        scanAccum = 0
        local ok, err = pcall(recompute)
        if not ok then
            warn("[ObbyBot]", err)
            currentStatus = "RECOVERING"
        end
    end

    if cachedMoveDir.Magnitude > 0.01 then
        humanoid:Move(cachedMoveDir, false)
    else
        humanoid:Move(Vector3.zero, false)
    end

    if cachedShouldJump then
        local now = tick()
        if humanoid.FloorMaterial ~= Enum.Material.Air and now - lastJumpTime > JUMP_COOLDOWN then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            lastJumpTime = now
            if currentStatus ~= "WALLHOP" and currentStatus ~= "LADDER" then
                currentStatus = "JUMPING"
            end
            cachedShouldJump = false
        elseif currentStatus == "LADDER" then
            if now - lastLadderSpam > LADDER_SPAM_INTERVAL then
                humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                lastLadderSpam = now
            end
        end
    end
end)

-- ===== TOGGLE =====
toggleBtn.MouseButton1Click:Connect(function()
    botEnabled = not botEnabled
    if botEnabled then
        toggleBtn.BackgroundColor3 = Color3.fromRGB(70, 150, 70)
        lastPos = hrp and hrp.Position or Vector3.zero
        lastProgressTime = tick()
        currentTarget = nil
        cachedMoveDir = Vector3.zero
        cachedShouldJump = false
    else
        toggleBtn.Text = "BOT OFF"
        toggleBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 65)
        cachedMoveDir = Vector3.zero
        cachedShouldJump = false
        if humanoid then humanoid:Move(Vector3.zero, false) end
    end
end)

RunService.Heartbeat:Connect(function()
    if botEnabled then toggleBtn.Text = currentStatus end
end)

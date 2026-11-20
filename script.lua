local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer
local playerGui = LocalPlayer:WaitForChild("PlayerGui")

local Config = {
	Reach = false,
	AI = false,
	AILock = false,
	ShiftLock = false,
	FF_071 = false,

	ReachSize = 10,
	AIDodgeDist = 28
}

-- =========================================================
-- 1) فحص الفريق والساحة والقنبلة واللاعبين
-- =========================================================
local function isTeammate(plr)
	if not plr or plr == LocalPlayer then return true end
	if LocalPlayer.Team ~= nil and plr.Team ~= nil and LocalPlayer.Team == plr.Team then
		return true
	end
	if LocalPlayer.TeamColor ~= nil and plr.TeamColor ~= nil and LocalPlayer.TeamColor == plr.TeamColor and not LocalPlayer.Neutral and not plr.Neutral then
		return true
	end
	local myChar = LocalPlayer.Character
	local tChar = plr.Character
	if myChar and tChar then
		for _, attr in ipairs({"Team", "Squad", "Faction", "Group"}) do
			local a1 = myChar:GetAttribute(attr) or LocalPlayer:GetAttribute(attr)
			local a2 = tChar:GetAttribute(attr) or plr:GetAttribute(attr)
			if a1 ~= nil and a2 ~= nil and a1 == a2 then
				return true
			end
		end
	end
	return false
end

local function findBombObject(char)
	if not char then return nil end
	for _, obj in ipairs(char:GetChildren()) do
		if obj:IsA("Tool") then
			local n = string.lower(obj.Name)
			if string.find(n, "bomb") or string.find(n, "tnt") or string.find(n, "time") or string.find(n, "boom") then
				return obj
			end
		end
	end
	for _, obj in ipairs(char:GetChildren()) do
		if obj:IsA("Model") or obj:IsA("BasePart") then
			local n = string.lower(obj.Name)
			if string.find(n, "bomb") or string.find(n, "tnt") or string.find(n, "time") then
				return obj
			end
		end
	end
	local plr = Players:GetPlayerFromCharacter(char)
	if plr and plr:FindFirstChild("Backpack") then
		for _, obj in ipairs(plr.Backpack:GetChildren()) do
			if obj:IsA("Tool") then
				local n = string.lower(obj.Name)
				if string.find(n, "bomb") or string.find(n, "tnt") or string.find(n, "time") then
					return obj
				end
			end
		end
	end
	return nil
end

local function hasBomb(char)
	return findBombObject(char) ~= nil
end

local function getRemainingBombTime(char)
	local bombObj = findBombObject(char)
	for _, root in ipairs({bombObj, char, workspace}) do
		if root then
			for _, attrName in ipairs({"Time", "Timer", "Countdown", "BombTime", "TimeLeft"}) do
				local val = root:GetAttribute(attrName)
				if type(val) == "number" and val > 0 and val < 120 then
					return val
				end
			end
			for _, desc in ipairs(root:GetDescendants()) do
				if desc:IsA("NumberValue") or desc:IsA("IntValue") then
					local ln = string.lower(desc.Name)
					if (string.find(ln, "time") or string.find(ln, "count") or string.find(ln, "bomb")) and type(desc.Value) == "number" and desc.Value > 0 and desc.Value < 120 then
						return desc.Value
					end
				elseif desc:IsA("TextLabel") then
					local num = tonumber(string.match(desc.Text, "%d+%.?%d*"))
					if num and num > 0 and num <= 30 then
						return num
					end
				end
			end
		end
	end
	return nil
end

local function getCharacterParts(plr)
	local char = plr and plr.Character
	if not char then return nil, nil, nil end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildWhichIsA("Humanoid")
	if not hrp or not hum or hum.Health <= 0 then return nil, nil, nil end
	return char, hrp, hum
end

local function getFloorPart(char, hrp)
	if not hrp then return nil end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = {char}
	if LocalPlayer.Character then table.insert(filter, LocalPlayer.Character) end
	params.FilterDescendantsInstances = filter
	local result = workspace:Raycast(hrp.Position, Vector3.new(0, -35, 0), params)
	return result and result.Instance or nil
end

local function isInMatch(char, hrp)
	if not char or not hrp then return false end
	if hasBomb(char) then return true end
	local parentName = string.lower(tostring(char.Parent and char.Parent.Name or ""))
	if string.find(parentName, "lobby") or string.find(parentName, "waiting") or string.find(parentName, "spectat") then
		return false
	end
	local floorPart = getFloorPart(char, hrp)
	if not floorPart then return false end
	local hitName = string.lower(floorPart.Name)
	local hitAncestor = string.lower(tostring(floorPart.Parent and floorPart.Parent.Name or ""))
	if string.find(hitName, "lobby") or string.find(hitAncestor, "lobby") then
		return false
	end
	return true
end

local function isInSameArena(myChar, myHrp, targetChar, targetHrp)
	if not myHrp or not targetHrp then return false end
	if math.abs(targetHrp.Position.Y - myHrp.Position.Y) > 18 then return false end
	local myFloor = getFloorPart(myChar, myHrp)
	local targetFloor = getFloorPart(targetChar, targetHrp)
	if not myFloor or not targetFloor then return false end
	if myFloor ~= targetFloor then
		local sameParent = myFloor.Parent and (myFloor.Parent == targetFloor.Parent)
		local closeEnough = (myFloor.Position - targetFloor.Position).Magnitude < 20
		if not (sameParent and closeEnough) then return false end
	end
	return true
end

-- =========================================================
-- 2) مظهر محلي مؤقت عند التفعيل فقط + نظام Shift Lock حسب الحاجة
-- =========================================================
local savedOutfit = { Shirt = nil, Pants = nil, DisplayName = nil, Colors = {}, Saved = false }
local savedShiftState = { AutoRotate = nil, Active = false }
local needShiftLockNow = false

local function applyCustomLocalStyle(char)
	if not char then return end
	if not savedOutfit.Saved then
		savedOutfit.Colors = {}
		local shirt = char:FindFirstChildOfClass("Shirt")
		local pants = char:FindFirstChildOfClass("Pants")
		savedOutfit.Shirt = shirt and shirt.ShirtTemplate or ""
		savedOutfit.Pants = pants and pants.PantsTemplate or ""
		local hum = char:FindFirstChildWhichIsA("Humanoid")
		if hum then savedOutfit.DisplayName = hum.DisplayName end
		for _, p in ipairs(char:GetChildren()) do
			if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
				savedOutfit.Colors[p] = p.Color
			end
		end
		savedOutfit.Saved = true
	end
	pcall(function()
		local shirt = char:FindFirstChildOfClass("Shirt") or Instance.new("Shirt", char)
		shirt.Name = "LocalShirtStyle"
		shirt.ShirtTemplate = "rbxassetid://0"
		local pants = char:FindFirstChildOfClass("Pants") or Instance.new("Pants", char)
		pants.Name = "LocalPantsStyle"
		pants.PantsTemplate = "rbxassetid://0"
		for _, p in ipairs(char:GetChildren()) do
			if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
				local ln = string.lower(p.Name)
				if string.find(ln, "head") then
					p.Color = Color3.fromRGB(240, 198, 168)
				elseif string.find(ln, "torso") or string.find(ln, "upper") or string.find(ln, "lower") then
					p.Color = Color3.fromRGB(24, 24, 34)
				else
					p.Color = Color3.fromRGB(220, 45, 70)
				end
			end
		end
		local hum = char:FindFirstChildWhichIsA("Humanoid")
		if hum then hum.DisplayName = "Player_071" end
	end)
end

local function restoreCustomLocalStyle(char)
	if not savedOutfit.Saved then return end
	pcall(function()
		if char then
			local shirt = char:FindFirstChildOfClass("Shirt")
			if shirt then
				if savedOutfit.Shirt == "" and shirt.Name == "LocalShirtStyle" then shirt:Destroy()
				elseif savedOutfit.Shirt then shirt.ShirtTemplate = savedOutfit.Shirt end
			end
			local pants = char:FindFirstChildOfClass("Pants")
			if pants then
				if savedOutfit.Pants == "" and pants.Name == "LocalPantsStyle" then pants:Destroy()
				elseif savedOutfit.Pants then pants.PantsTemplate = savedOutfit.Pants end
			end
			for p, col in pairs(savedOutfit.Colors) do
				if p and p.Parent then p.Color = col end
			end
			local hum = char:FindFirstChildWhichIsA("Humanoid")
			if hum and savedOutfit.DisplayName then hum.DisplayName = savedOutfit.DisplayName end
		end
	end)
	savedOutfit.Colors = {}
	savedOutfit.Saved = false
end

local function restoreShiftLockState(char)
	pcall(function()
		if char then
			local hum = char:FindFirstChildWhichIsA("Humanoid")
			if hum and savedShiftState.AutoRotate ~= nil then
				hum.AutoRotate = savedShiftState.AutoRotate
			end
		end
	end)
	savedShiftState.AutoRotate = nil
	savedShiftState.Active = false
end

local function updateShiftLock(myChar, myHrp, myHum, dt)
	local shouldEngage = Config.ShiftLock and needShiftLockNow
	if not shouldEngage then
		if savedShiftState.Active then
			restoreShiftLockState(myChar)
		end
		return
	end
	if not myChar or not myHrp or not myHum then return end
	local cam = workspace.CurrentCamera
	if not cam then return end

	if not savedShiftState.Active then
		savedShiftState.AutoRotate = myHum.AutoRotate
		savedShiftState.Active = true
	end

	pcall(function()
		myHum.AutoRotate = false
		local look = cam.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		if flatLook.Magnitude > 0.05 then
			local targetCF = CFrame.lookAt(myHrp.Position, myHrp.Position + flatLook.Unit)
			local alpha = math.clamp((dt or 0.08) * 18.0, 0.2, 0.9)
			myHrp.CFrame = myHrp.CFrame:Lerp(targetCF, alpha)
		end
	end)
end

-- =========================================================
-- 3) الذكاء الاصطناعي: رادار الخطر + تمرير تكتيكي + تجنب المصائد
-- =========================================================
local rowRefs = {}
local uiStatusUpdater = nil
local currentModeTag = "IDLE"
local jukePhase = "none"
local jukeIsJumpMode = false
local jukeTimer = 0
local jukeSign = 1
local arcPhaseClock = 0
local currentMoveDir = Vector3.new(1, 0, 0)
local lockedMoveDir = nil
local jumpCooldown = 0
local stuckTimer = 0
local lastPos = nil
local humanReactionDelay = 0
local humanHesitateTimer = 0
local currentTurnRate = 12.0
local currentTargetPlr = nil
local targetLockTimer = 0
local pathComputeTimer = 0
local cachedWaypoints = {}
local waypointIndex = 2
local coverHoldTimer = 0
local hadBombLastFrame = false

local GROUND_JUKE_PATTERNS = {
	"ground_bait_drift",
	"ground_snap_cut",
	"ground_crescent_arc",
	"ground_zig_pulse",
	"ground_hook_feint",
	"ground_flank_dash",
	"ground_pivot_backstep",
	"ground_serpentine_weave",
	"ground_stop_and_slip",
	"ground_wide_sweep",
	"chaos_feint_reverse",
	"pendulum_slash",
	"stagger_step_cut",
	"blindspot_wrap",
	"double_brake_turn",
	"spiral_breakout"
}

local JUMP_JUKE_PATTERNS = {
	"jump_snap_cross",
	"jump_flank_vault",
	"jump_crescent_hop",
	"jump_feint_hop",
	"jump_back_angle",
	"jump_zig_hop",
	"jump_gap_slip",
	"jump_over_pressure",
	"jump_chaos_twist",
	"jump_double_cut_hop"
}

local function setModeTag(tag)
	currentModeTag = tag
	if uiStatusUpdater then
		pcall(uiStatusUpdater, tag)
	end
end

local function enforceHealthyMoveSpeed(myHum)
	if not myHum or myHum.Health <= 0 then return end
	pcall(function()
		if myHum.WalkSpeed > 0 and myHum.WalkSpeed < 16 then
			myHum.WalkSpeed = 16
		end
	end)
end

local function smoothHumanDir(fromDir, toDir, dt, turnSpeed)
	if not toDir or toDir.Magnitude < 0.05 then return fromDir end
	local targetUnit = Vector3.new(toDir.X, 0, toDir.Z).Unit
	if not fromDir or fromDir.Magnitude < 0.05 then return targetUnit end
	local fromUnit = Vector3.new(fromDir.X, 0, fromDir.Z).Unit
	local alpha = math.clamp(dt * (turnSpeed or currentTurnRate or 12.0), 0.16, 0.85)
	local blended = fromUnit:Lerp(targetUnit, alpha)
	return blended.Magnitude < 0.01 and targetUnit or blended.Unit
end

local function steerCameraSoftly(myHrp, focusWorldPos, dt)
	if not Config.AILock or not myHrp or not focusWorldPos then return end
	local cam = workspace.CurrentCamera
	if not cam then return end
	pcall(function()
		local flatLook = Vector3.new(focusWorldPos.X - myHrp.Position.X, 0, focusWorldPos.Z - myHrp.Position.Z)
		if flatLook.Magnitude > 0.6 then
			local aimPos = myHrp.Position + Vector3.new(0, 2.2, 0) + flatLook.Unit * 10
			local desiredCF = CFrame.lookAt(cam.CFrame.Position, aimPos)
			cam.CFrame = cam.CFrame:Lerp(desiredCF, math.clamp(dt * 8.0, 0.05, 0.35))
		end
	end)
end

local function applyAIMove(myHrp, myHum, desiredDir, targetPos, camFocusPos, dt)
	humanHesitateTimer = 0
	enforceHealthyMoveSpeed(myHum)
	local blendedDir = smoothHumanDir(currentMoveDir, desiredDir, dt or 0.05, currentTurnRate)
	currentMoveDir = blendedDir
	myHum:MoveTo(targetPos)
	if camFocusPos then
		steerCameraSoftly(myHrp, camFocusPos, dt or 0.05)
	end
end

local function rotateFlatVector(vec, degrees)
	local rad = math.rad(degrees)
	local c, s = math.cos(rad), math.sin(rad)
	return Vector3.new(vec.X * c - vec.Z * s, 0, vec.X * s + vec.Z * c).Unit
end

local function probeObstacle(myChar, myHrp, dir, dist)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar}
	local lowHit = workspace:Raycast(myHrp.Position - Vector3.new(0, 1.3, 0), dir * dist, params)
	local highHit = workspace:Raycast(myHrp.Position + Vector3.new(0, 2.2, 0), dir * dist, params)
	if lowHit and (not lowHit.Instance.CanCollide or lowHit.Instance.Parent:FindFirstChildWhichIsA("Humanoid")) then lowHit = nil end
	if highHit and (not highHit.Instance.CanCollide or highHit.Instance.Parent:FindFirstChildWhichIsA("Humanoid")) then highHit = nil end
	if not lowHit and not highHit then
		return "clear", math.huge
	elseif lowHit and not highHit then
		return "jumpable", lowHit.Distance
	else
		return "wall", math.min(lowHit and lowHit.Distance or dist, highHit and highHit.Distance or dist)
	end
end

local function triggerJumpSkill(myHum, cooldownSec, dirToSnap, allowInAir)
	if not myHum or jumpCooldown > 0 then return false end
	if not allowInAir and myHum.FloorMaterial == Enum.Material.Air then return false end
	if dirToSnap and dirToSnap.Magnitude > 0.05 then
		currentMoveDir = Vector3.new(dirToSnap.X, 0, dirToSnap.Z).Unit
	end
	myHum.Jump = true
	jumpCooldown = cooldownSec or (0.44 + math.random(4, 14) / 100)
	return true
end

local function isSafeDirection(myChar, myHrp, myHum, dir, allowEdgeJump)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar}
	local myFloor = getFloorPart(myChar, myHrp)
	local st, wallDist = probeObstacle(myChar, myHrp, dir, 8.5)
	if st == "wall" and wallDist < 6.0 then return false end
	for _, stepDist in ipairs({5, 9.5}) do
		local floorHit = workspace:Raycast(myHrp.Position + dir * stepDist + Vector3.new(0, 2, 0), Vector3.new(0, -18, 0), params)
		if not floorHit then
			if allowEdgeJump ~= false then
				local farFloor = workspace:Raycast(myHrp.Position + dir * (stepDist + 4.5) + Vector3.new(0, 3, 0), Vector3.new(0, -20, 0), params)
				if farFloor and myHum then
					triggerJumpSkill(myHum, 0.48, dir)
					return true
				end
			end
			return false
		end
		if myFloor and floorHit.Instance ~= myFloor and floorHit.Instance.Parent ~= myFloor.Parent then
			if math.abs(floorHit.Position.Y - myHrp.Position.Y) > 9.5 then return false end
		end
	end
	return true
end

-- [إضافة 3: تجنّب الأماكن المغلقة والمصائد] فحص المساحة الحرة حول الاتجاه
local function measureOpenSpace(myChar, originPos, dir)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar}
	local leftHit = workspace:Raycast(originPos, rotateFlatVector(dir, 55) * 13, params)
	local rightHit = workspace:Raycast(originPos, rotateFlatVector(dir, -55) * 13, params)
	local backLeftHit = workspace:Raycast(originPos, rotateFlatVector(dir, 125) * 11, params)
	local backRightHit = workspace:Raycast(originPos, rotateFlatVector(dir, -125) * 11, params)

	local leftSpace = (leftHit and leftHit.Instance.CanCollide) and leftHit.Distance or 13
	local rightSpace = (rightHit and rightHit.Instance.CanCollide) and rightHit.Distance or 13
	local backLeftSpace = (backLeftHit and backLeftHit.Instance.CanCollide) and backLeftHit.Distance or 11
	local backRightSpace = (backRightHit and backRightHit.Instance.CanCollide) and backRightHit.Distance or 11

	return leftSpace + rightSpace + (backLeftSpace + backRightSpace) * 0.6
end

-- [إضافة 3: تجنّب الأماكن المغلقة والمصائد] خصم نقاط الزوايا والمصائد المغلقة
local function getCornerTrapPenalty(myChar, checkPos, dir)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar}
	local blockedRays = 0
	for _, ang in ipairs({-90, -45, 0, 45, 90}) do
		local ray = workspace:Raycast(checkPos + Vector3.new(0, 1, 0), rotateFlatVector(dir, ang) * 8.0, params)
		if ray and ray.Instance and ray.Instance.CanCollide and not ray.Instance.Parent:FindFirstChildWhichIsA("Humanoid") then
			blockedRays += 1
		end
	end
	if blockedRays >= 4 then return 105 elseif blockedRays == 3 then return 55 elseif blockedRays == 2 then return 18 end
	return 0
end

local function sanitizeDirection(myChar, myHrp, myHum, desiredDir, allowEdgeJump)
	if isSafeDirection(myChar, myHrp, myHum, desiredDir, allowEdgeJump) then
		local st, d = probeObstacle(myChar, myHrp, desiredDir, 7.5)
		if st == "jumpable" and d < 5.5 then triggerJumpSkill(myHum, 0.46, desiredDir) end
		return desiredDir
	end
	local bestCandidate = nil
	local bestScore = -math.huge
	for _, deg in ipairs({25, -25, 50, -50, 75, -75, 105, -105, 135, -135, 180}) do
		local candidate = rotateFlatVector(desiredDir, deg)
		if isSafeDirection(myChar, myHrp, myHum, candidate, allowEdgeJump) then
			local probePos = myHrp.Position + candidate * 7
			local candScore = measureOpenSpace(myChar, probePos, candidate) - getCornerTrapPenalty(myChar, probePos, candidate)
			if candScore > bestScore then
				bestScore = candScore
				bestCandidate = candidate
			end
		end
	end
	if bestCandidate then
		local st, d = probeObstacle(myChar, myHrp, bestCandidate, 7.5)
		if st == "jumpable" and d < 5.5 then triggerJumpSkill(myHum, 0.46, bestCandidate) end
		return bestCandidate
	end
	return rotateFlatVector(desiredDir, 90 * jukeSign)
end

local function hasCoverBetween(myChar, fromPos, threatPos)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar}
	local delta = threatPos - fromPos
	if delta.Magnitude < 1 then return false end
	local ray = workspace:Raycast(fromPos + Vector3.new(0, 0.5, 0), delta.Unit * delta.Magnitude, params)
	return (ray and ray.Instance and ray.Instance.CanCollide and not ray.Instance.Parent:FindFirstChildWhichIsA("Humanoid")) or false
end

local function computeSmartPath(startPos, goalPos)
	local path = PathfindingService:CreatePath({ AgentRadius = 2.2, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 4 })
	local ok = pcall(function() path:ComputeAsync(startPos, goalPos) end)
	if ok and path.Status == Enum.PathStatus.Success then return path:GetWaypoints() end
	return nil
end

local function findAscentSpot(myChar, myHrp, targetHrp)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar, targetHrp.Parent}
	local flatToTarget = Vector3.new(targetHrp.Position.X - myHrp.Position.X, 0, targetHrp.Position.Z - myHrp.Position.Z)
	local baseDir = (flatToTarget.Magnitude > 0.05) and flatToTarget.Unit or Vector3.new(1, 0, 0)
	local bestSpot, bestScore = nil, -math.huge
	for angOffset = -90, 90, 30 do
		local probeDir = rotateFlatVector(baseDir, angOffset)
		for _, dist in ipairs({5, 9, 13}) do
			local downHit = workspace:Raycast(myHrp.Position + probeDir * dist + Vector3.new(0, 10.5, 0), Vector3.new(0, -12, 0), params)
			if downHit and downHit.Instance and downHit.Instance.CanCollide then
				local stepY = downHit.Position.Y - myHrp.Position.Y
				if stepY > 2.0 and stepY <= 12.5 then
					local score = (13 - math.abs(stepY - 5.5)) * 4 - dist * 1.4
					if score > bestScore then
						bestScore = score
						bestSpot = downHit.Position + Vector3.new(0, 2, 0)
					end
				end
			end
		end
	end
	return bestSpot
end

local function findDescentSpot(myChar, myHrp, targetHrp)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar, targetHrp.Parent}
	local flatToTarget = Vector3.new(targetHrp.Position.X - myHrp.Position.X, 0, targetHrp.Position.Z - myHrp.Position.Z)
	local baseDir = (flatToTarget.Magnitude > 0.05) and flatToTarget.Unit or Vector3.new(1, 0, 0)
	local bestSpot, bestScore = nil, -math.huge

	for angOffset = -90, 90, 30 do
		local probeDir = rotateFlatVector(baseDir, angOffset)
		for _, dist in ipairs({4, 8, 12}) do
			local checkOrigin = myHrp.Position + probeDir * dist + Vector3.new(0, 1.5, 0)
			local downHit = workspace:Raycast(checkOrigin, Vector3.new(0, -24, 0), params)
			if downHit and downHit.Instance and downHit.Instance.CanCollide then
				local dropY = myHrp.Position.Y - downHit.Position.Y
				local closenessToTargetY = math.abs(downHit.Position.Y - targetHrp.Position.Y)
				if dropY > 2.0 and dropY <= 20 and closenessToTargetY < 8 then
					local score = (10 - closenessToTargetY) * 5 - dist * 1.2
					if score > bestScore then
						bestScore = score
						bestSpot = downHit.Position + Vector3.new(0, 2, 0)
					end
				end
			end
		end
	end

	return bestSpot
end

-- [إضافة 2: التمرير التكتيكي والتمويه] تقدير نقطة الاعتراض
local function computeInterceptPoint(myHrp, myHum, targetHrp, urgentMode)
	local tVel = targetHrp.AssemblyLinearVelocity
	local flatVel = Vector3.new(tVel.X, 0, tVel.Z)
	local delta = targetHrp.Position - myHrp.Position
	local dist = Vector3.new(delta.X, 0, delta.Z).Magnitude
	local mySpeed = (myHum and myHum.WalkSpeed > 4) and myHum.WalkSpeed or 16
	local interceptTime = math.clamp(dist / math.max(mySpeed, 10), 0.06, urgentMode and 0.22 or 0.42)
	return targetHrp.Position + flatVel * interceptTime, flatVel
end

-- [إضافة 1: رادار زوايا الخطر والانفجار المبكر] تقييم التهديدات وحساب خطر حامل القنبلة
local function collectThreatEntities(myChar, myHrp)
	local candidates = {}
	local bombCarriers = {}

	for _, plr in ipairs(Players:GetPlayers()) do
		if not isTeammate(plr) then
			local tChar, tHrp = getCharacterParts(plr)
			if tChar and tHrp and isInMatch(tChar, tHrp) and isInSameArena(myChar, myHrp, tChar, tHrp) then
				local carriesBomb = hasBomb(tChar)
				local timerLeft = carriesBomb and getRemainingBombTime(tChar) or nil
				local distToMe = (tHrp.Position - myHrp.Position).Magnitude
				local vel = tHrp.AssemblyLinearVelocity
				local flatVel = Vector3.new(vel.X, 0, vel.Z)
				local look = tHrp.CFrame.LookVector
				local blastLead = (carriesBomb and timerLeft and timerLeft <= 4.0) and 0.72 or (carriesBomb and 0.52 or 0.35)
				local blastCenter = tHrp.Position + flatVel * blastLead + Vector3.new(look.X, 0, look.Z) * (carriesBomb and 3.5 or 1.5)

				local entry = {
					char = tChar,
					hrp = tHrp,
					hasBomb = carriesBomb,
					bombTime = timerLeft,
					distToMe = distToMe,
					blastCenter = blastCenter,
					likelyPassTarget = false,
					threatScore = 0
				}
				table.insert(candidates, entry)
				if carriesBomb then table.insert(bombCarriers, entry) end
			end
		end
	end

	for _, c in ipairs(candidates) do
		if not c.hasBomb then
			for _, b in ipairs(bombCarriers) do
				local bDelta = c.hrp.Position - b.hrp.Position
				local bFlat = Vector3.new(bDelta.X, 0, bDelta.Z)
				local bDist = bFlat.Magnitude
				local bLook = b.hrp.CFrame.LookVector
				local bVel = b.hrp.AssemblyLinearVelocity
				local bFlatVel = Vector3.new(bVel.X, 0, bVel.Z)

				local isCloseToBomb = bDist < 22
				local isAimedAtByBomb = (bFlat.Magnitude > 0.2) and (bLook:Dot(bFlat.Unit) > 0.55 and bDist < 32)
				local isBombMovingToward = (bFlat.Magnitude > 0.2) and (bFlatVel.Magnitude > 3 and bFlatVel.Unit:Dot(bFlat.Unit) > 0.55 and bDist < 28)

				if isCloseToBomb or isAimedAtByBomb or isBombMovingToward then
					c.likelyPassTarget = true
					break
				end
			end
		end
	end

	local primaryThreat = nil
	local highestThreatScore = -math.huge

	for _, c in ipairs(candidates) do
		local toMe = (myHrp.Position - c.hrp.Position)
		local flatToMe = Vector3.new(toMe.X, 0, toMe.Z)
		local dist = math.max(c.distToMe, 0.5)
		local vel = c.hrp.AssemblyLinearVelocity
		local flatVel = Vector3.new(vel.X, 0, vel.Z)
		local approachingMe = (flatToMe.Magnitude > 0.2) and ((c.hrp.CFrame.LookVector:Dot(flatToMe.Unit) > 0.30) or (flatVel.Magnitude > 2.5 and flatVel.Unit:Dot(flatToMe.Unit) > 0.40))

		local score = 0
		if c.hasBomb then
			score += 175
			if c.bombTime and c.bombTime <= 4.5 then score += (5.0 - c.bombTime) * 28 end
		elseif c.likelyPassTarget then
			score += 72
		end
		if c.distToMe <= math.max(Config.AIDodgeDist, 38) then score += (math.max(Config.AIDodgeDist, 38) - c.distToMe) * 4.0 end
		if c.distToMe < 15 then score += (15 - c.distToMe) * 5.8 end
		if approachingMe then score += 32 end
		score -= dist * 0.38

		c.threatScore = score
		if score > highestThreatScore then
			highestThreatScore = score
			primaryThreat = c
		end
	end

	return candidates, primaryThreat, bombCarriers
end

local function evaluateDirectionScore(myChar, myHrp, dir, threats)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {myChar}
	local myFloor = getFloorPart(myChar, myHrp)
	local score = 0
	local st, wallDist = probeObstacle(myChar, myHrp, dir, 15)
	if st == "wall" then score -= (15 - wallDist) * 9.0
	elseif st == "jumpable" then score += 10
	else score += 30 end

	local nextPos = myHrp.Position + dir * 8
	score += measureOpenSpace(myChar, nextPos, dir) * 2.10
	score -= getCornerTrapPenalty(myChar, nextPos, dir)

	local floorHit = workspace:Raycast(myHrp.Position + dir * 8 + Vector3.new(0, 2, 0), Vector3.new(0, -18, 0), params)
	if not floorHit then
		score -= 140
	elseif myFloor and floorHit.Instance ~= myFloor and floorHit.Instance.Parent ~= myFloor.Parent then
		score += (math.abs(floorHit.Position.Y - myHrp.Position.Y) > 9.5) and -160 or 8
	else
		score += 14
	end

	if threats then
		for _, t in ipairs(threats) do
			local blastPos = t.blastCenter or t.hrp.Position
			local distFromBlast = (nextPos - blastPos).Magnitude

			if t.hasBomb then
				local timerBoost = (t.bombTime and t.bombTime <= 4.0) and 1.45 or 1.12
				score += distFromBlast * 2.75 * timerBoost
				if distFromBlast < 15 then score -= (15 - distFromBlast) * 7.8 * timerBoost end
				if hasCoverBetween(myChar, nextPos, blastPos) then
					if distFromBlast < 16 and coverHoldTimer < 0.75 then
						score += 18
					else
						score -= 8
					end
				end
			elseif t.likelyPassTarget then
				score += distFromBlast * 1.45
				if distFromBlast < 12 then score -= (12 - distFromBlast) * 4.5 end
			else
				score += distFromBlast * 1.05
				if distFromBlast < 10 then score -= (10 - distFromBlast) * 3.8 end
			end
		end
	end

	return score
end

-- [إضافة 2: التمرير التكتيكي والتمويه] اختيار أفضل هدف للتمرير
local function pickBestPassTarget(myChar, myHrp, urgentMode)
	local bestPlr, bestHrp, bestScore = nil, nil, math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		if not isTeammate(plr) then
			local tChar, tHrp = getCharacterParts(plr)
			if tChar and tHrp and isInMatch(tChar, tHrp) and not hasBomb(tChar) and isInSameArena(myChar, myHrp, tChar, tHrp) then
				local delta = tHrp.Position - myHrp.Position
				local speed = Vector3.new(tHrp.AssemblyLinearVelocity.X, 0, tHrp.AssemblyLinearVelocity.Z).Magnitude
				local cost = urgentMode and (delta.Magnitude + math.abs(delta.Y) * 1.05 + speed * 0.14) or (delta.Magnitude * 0.92 + speed * 0.30 + math.abs(delta.Y) * 1.5)
				if cost < bestScore then
					bestScore, bestPlr, bestHrp = cost, plr, tHrp
				end
			end
		end
	end
	return bestPlr, bestHrp
end

local function syncVerticalLevel(myChar, myHrp, myHum, targetHrp, iHaveBomb, urgentMode, dt)
	local dy = targetHrp.Position.Y - myHrp.Position.Y
	local toTarget = targetHrp.Position - myHrp.Position
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	local flatDist = flat.Magnitude
	local directDir = (flatDist > 0.05) and flat.Unit or Vector3.new(1, 0, 0)

	if dy > 3.2 then
		setModeTag("CLIMB UP")
		local preferDropBait = iHaveBomb and (urgentMode or dy > 8.0 or flatDist < 6.5)
		if preferDropBait then
			local orbitDir = rotateFlatVector(directDir, (72 * jukeSign) + math.sin(arcPhaseClock * 6.5) * 36)
			local baitPos = Vector3.new(targetHrp.Position.X, myHrp.Position.Y, targetHrp.Position.Z) + orbitDir * 5
			local safeBaitDir = sanitizeDirection(myChar, myHrp, myHum, (baitPos - myHrp.Position).Unit, false)
			currentTurnRate = 15.0
			applyAIMove(myHrp, myHum, safeBaitDir, baitPos, nil, dt)
			return true
		end

		local ascentSpot = findAscentSpot(myChar, myHrp, targetHrp)
		if ascentSpot then
			local spotFlat = Vector3.new(ascentSpot.X - myHrp.Position.X, 0, ascentSpot.Z - myHrp.Position.Z)
			local safeClimb = sanitizeDirection(myChar, myHrp, myHum, (spotFlat.Magnitude > 0.05) and spotFlat.Unit or directDir, true)
			currentTurnRate = urgentMode and 17.5 or 14.5
			applyAIMove(myHrp, myHum, safeClimb, ascentSpot, targetHrp.Position, dt)
			triggerJumpSkill(myHum, 0.46, safeClimb)
			return true
		end

		if pathComputeTimer <= 0 or #cachedWaypoints == 0 then
			pathComputeTimer = 0.35
			local wps = computeSmartPath(myHrp.Position, targetHrp.Position)
			if wps and #wps >= 2 then cachedWaypoints, waypointIndex = wps, 2 end
		end

		if cachedWaypoints[waypointIndex] then
			local wp = cachedWaypoints[waypointIndex]
			local wpFlat = Vector3.new(wp.Position.X - myHrp.Position.X, 0, wp.Position.Z - myHrp.Position.Z)
			if wpFlat.Magnitude < 3.5 then
				waypointIndex += 1
			else
				local stepDir = sanitizeDirection(myChar, myHrp, myHum, wpFlat.Unit, true)
				currentTurnRate = urgentMode and 17.5 or 14.5
				applyAIMove(myHrp, myHum, stepDir, wp.Position, targetHrp.Position, dt)
				if wp.Action == Enum.PathWaypointAction.Jump or wp.Position.Y > myHrp.Position.Y + 1.4 then
					triggerJumpSkill(myHum, 0.46, stepDir)
				end
				return true
			end
		end

		local safeDirect = sanitizeDirection(myChar, myHrp, myHum, directDir, true)
		currentTurnRate = urgentMode and 17.5 or 14.5
		applyAIMove(myHrp, myHum, safeDirect, myHrp.Position + safeDirect * 11, targetHrp.Position, dt)
		triggerJumpSkill(myHum, 0.48, safeDirect)
		return true
	end

	if dy < -3.2 then
		setModeTag("DROP DOWN")
		local descentSpot = findDescentSpot(myChar, myHrp, targetHrp)
		if descentSpot then
			local dropFlat = Vector3.new(descentSpot.X - myHrp.Position.X, 0, descentSpot.Z - myHrp.Position.Z)
			local dropDir = (dropFlat.Magnitude > 0.05) and dropFlat.Unit or directDir
			local safeDrop = sanitizeDirection(myChar, myHrp, myHum, dropDir, true)
			currentTurnRate = urgentMode and 17.5 or 14.5
			applyAIMove(myHrp, myHum, safeDrop, descentSpot, targetHrp.Position, dt)
			return true
		end

		if pathComputeTimer <= 0 or #cachedWaypoints == 0 then
			pathComputeTimer = 0.35
			local wps = computeSmartPath(myHrp.Position, targetHrp.Position)
			if wps and #wps >= 2 then cachedWaypoints, waypointIndex = wps, 2 end
		end

		if cachedWaypoints[waypointIndex] then
			local wp = cachedWaypoints[waypointIndex]
			local wpFlat = Vector3.new(wp.Position.X - myHrp.Position.X, 0, wp.Position.Z - myHrp.Position.Z)
			if wpFlat.Magnitude < 3.5 then
				waypointIndex += 1
			else
				local stepDir = sanitizeDirection(myChar, myHrp, myHum, wpFlat.Unit, true)
				currentTurnRate = urgentMode and 17.5 or 14.5
				applyAIMove(myHrp, myHum, stepDir, wp.Position, targetHrp.Position, dt)
				return true
			end
		end

		local safeDownDir = sanitizeDirection(myChar, myHrp, myHum, directDir, true)
		currentTurnRate = urgentMode and 17.5 or 14.5
		applyAIMove(myHrp, myHum, safeDownDir, targetHrp.Position, targetHrp.Position, dt)
		return true
	end

	return false
end

-- [إضافة 2: التمرير التكتيكي والتمويه] مطاردة مع خداع تمويهي ثم حسم مباشر
local function chaseAndPassToTarget(myChar, myHrp, myHum, targetHrp, urgentMode, dt)
	if syncVerticalLevel(myChar, myHrp, myHum, targetHrp, true, urgentMode, dt) then return end
	setModeTag("CHASE PASS")
	local cutOffPos, flatVel = computeInterceptPoint(myHrp, myHum, targetHrp, urgentMode)
	local toTarget = targetHrp.Position - myHrp.Position
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	local distFlat = flat.Magnitude
	local directDir = (distFlat > 0.05) and flat.Unit or Vector3.new(1, 0, 0)

	if distFlat <= 12.0 or urgentMode then
		needShiftLockNow = true
	end

	local predDelta = cutOffPos - myHrp.Position
	local predFlat = Vector3.new(predDelta.X, 0, predDelta.Z)
	local aimDir = (predFlat.Magnitude > 0.05) and predFlat.Unit or directDir

	local obstacleType = probeObstacle(myChar, myHrp, aimDir, math.min(distFlat, 16))
	local chosenDir, moveTargetPos = aimDir, cutOffPos
	if distFlat <= 7.5 then
		chosenDir = sanitizeDirection(myChar, myHrp, myHum, directDir)
		moveTargetPos = targetHrp.Position + flatVel * 0.05
		currentTurnRate = urgentMode and 20.0 or 18.0
	elseif not urgentMode and obstacleType == "wall" and distFlat > 8.5 then
		if pathComputeTimer <= 0 or #cachedWaypoints == 0 then
			pathComputeTimer = 0.35
			local wps = computeSmartPath(myHrp.Position, targetHrp.Position)
			if wps and #wps >= 2 then cachedWaypoints, waypointIndex = wps, 2 end
		end
		if cachedWaypoints[waypointIndex] then
			local wp = cachedWaypoints[waypointIndex]
			local wpFlat = Vector3.new(wp.Position.X - myHrp.Position.X, 0, wp.Position.Z - myHrp.Position.Z)
			if wpFlat.Magnitude < 3.5 then
				waypointIndex += 1
			else
				chosenDir = sanitizeDirection(myChar, myHrp, myHum, wpFlat.Unit)
				moveTargetPos = wp.Position
				if wp.Action == Enum.PathWaypointAction.Jump then triggerJumpSkill(myHum, 0.50, chosenDir) end
			end
		else
			chosenDir = sanitizeDirection(myChar, myHrp, myHum, aimDir)
		end
		currentTurnRate = 14.5
	else
		if distFlat > 10.5 and distFlat < 25 and not urgentMode then
			local fakeCutAngle = math.sin(arcPhaseClock * 10.0) * 28 * math.clamp((distFlat - 10.5) / 14.5, 0, 1) * jukeSign
			aimDir = rotateFlatVector(aimDir, fakeCutAngle)
		end
		chosenDir = sanitizeDirection(myChar, myHrp, myHum, aimDir)
		currentTurnRate = urgentMode and 19.0 or 15.5
	end
	applyAIMove(myHrp, myHum, chosenDir, moveTargetPos, (urgentMode or distFlat < 14) and targetHrp.Position or nil, dt)
	if toTarget.Y > 2.2 then triggerJumpSkill(myHum, 0.50, chosenDir) end
end

local function buildGroundJukeDir(awayDir, bestSafeDir)
	local sideDir = Vector3.new(-awayDir.Z * jukeSign, 0, awayDir.X * jukeSign)
	local oppSideDir = Vector3.new(-awayDir.Z * (-jukeSign), 0, awayDir.X * (-jukeSign))
	local waveFast = math.sin(arcPhaseClock * 13.5) * 0.38
	local waveSlow = math.cos(arcPhaseClock * 7.8) * 0.30

	if jukePhase == "ground_bait_drift" then
		return (sideDir * (0.90 + waveSlow) + bestSafeDir * 0.38 + awayDir * 0.14).Unit
	elseif jukePhase == "ground_snap_cut" then
		return (oppSideDir * (0.98 - waveFast) + awayDir * 0.65 + bestSafeDir * 0.28).Unit
	elseif jukePhase == "ground_crescent_arc" then
		return (rotateFlatVector(sideDir, 38 * math.sin(arcPhaseClock * 9.0) * jukeSign) * 0.88 + awayDir * 0.58 + bestSafeDir * 0.25).Unit
	elseif jukePhase == "ground_zig_pulse" then
		local pulse = (math.floor(arcPhaseClock * 11.0) % 2 == 0) and 1 or -1
		return (rotateFlatVector(sideDir, 54 * pulse) * 0.95 + awayDir * 0.54 + bestSafeDir * 0.24).Unit
	elseif jukePhase == "ground_hook_feint" then
		return (rotateFlatVector(awayDir, 64 * jukeSign) * 0.84 + bestSafeDir * 0.62).Unit
	elseif jukePhase == "ground_flank_dash" then
		return (rotateFlatVector(awayDir, 78 * jukeSign + math.cos(arcPhaseClock * 10.5) * 18) * 0.86 + bestSafeDir * 0.52).Unit
	elseif jukePhase == "ground_pivot_backstep" then
		return (rotateFlatVector(awayDir, 130 * jukeSign + math.sin(arcPhaseClock * 9.5) * 16) * 0.88 + bestSafeDir * 0.56).Unit
	elseif jukePhase == "ground_serpentine_weave" then
		local weaveDeg = math.sin(arcPhaseClock * 14.5) * 62 * jukeSign
		return (rotateFlatVector(awayDir, weaveDeg) * 0.80 + sideDir * 0.58 + bestSafeDir * 0.34).Unit
	elseif jukePhase == "ground_stop_and_slip" then
		local slipAngle = (math.floor(arcPhaseClock * 7.0) % 2 == 0) and (95 * jukeSign) or (-78 * jukeSign)
		return (rotateFlatVector(awayDir, slipAngle) * 0.86 + bestSafeDir * 0.55).Unit
	elseif jukePhase == "ground_wide_sweep" then
		return (rotateFlatVector(sideDir, 28 * jukeSign) * 0.95 + awayDir * 0.45 + bestSafeDir * 0.42).Unit
	elseif jukePhase == "chaos_feint_reverse" then
		local phaseFlip = (math.floor(arcPhaseClock * 8.0) % 2 == 0) and 1 or -1
		return (rotateFlatVector(awayDir, 90 * jukeSign * phaseFlip) * 0.90 + bestSafeDir * 0.48).Unit
	elseif jukePhase == "pendulum_slash" then
		local swing = math.sin(arcPhaseClock * 14.0) * 80 * jukeSign
		return (rotateFlatVector(awayDir, swing) * 0.85 + oppSideDir * 0.45).Unit
	elseif jukePhase == "stagger_step_cut" then
		local tick = math.floor(arcPhaseClock * 9.5) % 3
		local ang = (tick == 0 and 38 or (tick == 1 and -88 or 112)) * jukeSign
		return (rotateFlatVector(awayDir, ang) * 0.88 + bestSafeDir * 0.45).Unit
	elseif jukePhase == "blindspot_wrap" then
		return (rotateFlatVector(awayDir, 98 * jukeSign + math.sin(arcPhaseClock * 8.5) * 20) * 0.92 + sideDir * 0.35).Unit
	elseif jukePhase == "double_brake_turn" then
		local pulse = (math.floor(arcPhaseClock * 8.5) % 2 == 0) and -108 or 68
		return (rotateFlatVector(awayDir, pulse * jukeSign) * 0.87 + bestSafeDir * 0.50).Unit
	elseif jukePhase == "spiral_breakout" then
		local spiralDeg = 44 * jukeSign + math.cos(arcPhaseClock * 11.5) * 50
		return (rotateFlatVector(awayDir, spiralDeg) * 0.84 + bestSafeDir * 0.56).Unit
	end

	return (bestSafeDir * 0.66 + awayDir * 0.38 + sideDir * (0.56 + waveSlow)).Unit
end

local function buildJumpJukeDir(awayDir, bestSafeDir)
	local sideDir = Vector3.new(-awayDir.Z * jukeSign, 0, awayDir.X * jukeSign)
	local oppSideDir = Vector3.new(-awayDir.Z * (-jukeSign), 0, awayDir.X * (-jukeSign))
	local hopWave = math.sin(arcPhaseClock * 12.0) * 0.32

	if jukePhase == "jump_snap_cross" then
		return (oppSideDir * 0.96 + awayDir * 0.64 + bestSafeDir * 0.28).Unit
	elseif jukePhase == "jump_flank_vault" then
		return (rotateFlatVector(awayDir, 70 * jukeSign) * 0.86 + bestSafeDir * 0.54).Unit
	elseif jukePhase == "jump_crescent_hop" then
		return (rotateFlatVector(sideDir, 38 * jukeSign + hopWave * 42) * 0.90 + awayDir * 0.55).Unit
	elseif jukePhase == "jump_feint_hop" then
		return (rotateFlatVector(sideDir, -40 * jukeSign) * 0.85 + bestSafeDir * 0.55).Unit
	elseif jukePhase == "jump_back_angle" then
		return (rotateFlatVector(awayDir, 124 * jukeSign) * 0.88 + bestSafeDir * 0.52).Unit
	elseif jukePhase == "jump_zig_hop" then
		local zig = (math.floor(arcPhaseClock * 9.5) % 2 == 0) and 58 or -58
		return (rotateFlatVector(awayDir, zig * jukeSign) * 0.84 + bestSafeDir * 0.52).Unit
	elseif jukePhase == "jump_gap_slip" then
		return (bestSafeDir * 0.78 + sideDir * (0.50 + hopWave)).Unit
	elseif jukePhase == "jump_over_pressure" then
		return (rotateFlatVector(awayDir, 60 * jukeSign) * 0.88 + bestSafeDir * 0.50).Unit
	elseif jukePhase == "jump_chaos_twist" then
		local twist = (math.floor(arcPhaseClock * 8.0) % 2 == 0) and 88 or -78
		return (rotateFlatVector(awayDir, twist * jukeSign) * 0.90 + oppSideDir * 0.40).Unit
	elseif jukePhase == "jump_double_cut_hop" then
		return (rotateFlatVector(awayDir, 105 * jukeSign + math.sin(arcPhaseClock * 10.5) * 26) * 0.86 + bestSafeDir * 0.50).Unit
	end

	return (bestSafeDir * 0.65 + awayDir * 0.45 + sideDir * 0.52).Unit
end

local function buildLegendaryJukeDir(awayDir, bestSafeDir)
	if jukeIsJumpMode then
		return buildJumpJukeDir(awayDir, bestSafeDir)
	end
	return buildGroundJukeDir(awayDir, bestSafeDir)
end

local function pickNextJukePattern(nearestDist, threatApproaching, urgentTimer, enemyHasBomb)
	local rateBoost = urgentTimer and 2.2 or (enemyHasBomb and 1.2 or 0.5)
	local jumpChance = enemyHasBomb and (urgentTimer and 52 or 44) or (nearestDist < 13 and 38 or (threatApproaching and 32 or 22))
	jukeIsJumpMode = (math.random(1, 100) <= jumpChance)

	if jukeIsJumpMode then
		local idx = math.random(1, #JUMP_JUKE_PATTERNS)
		jukePhase = JUMP_JUKE_PATTERNS[idx]
		jukeTimer = enemyHasBomb and (math.random(14, 24) / 100) or (math.random(20, 34) / 100)
		currentTurnRate = 18.0 + rateBoost
		setModeTag("JUMP JUKE")
	else
		local idx = math.random(1, #GROUND_JUKE_PATTERNS)
		jukePhase = GROUND_JUKE_PATTERNS[idx]
		jukeTimer = enemyHasBomb and (math.random(12, 22) / 100) or (math.random(16, 32) / 100)
		currentTurnRate = (nearestDist < 14 and 17.8 or 15.8) + rateBoost
		setModeTag("GROUND JUKE")
	end
end

local function runSmartAI(myChar, myHrp, myHum, dt)
	needShiftLockNow = false
	humanHesitateTimer = 0
	enforceHealthyMoveSpeed(myHum)

	if not Config.AI or not isInMatch(myChar, myHrp) then
		hadBombLastFrame = false
		setModeTag("STANDBY")
		return
	end

	local iHaveBombNow = hasBomb(myChar)
	if hadBombLastFrame and not iHaveBombNow then
		lockedMoveDir = nil
		jukeTimer = 0
		humanReactionDelay = 0
		restoreShiftLockState(myChar)
		enforceHealthyMoveSpeed(myHum)
	end
	hadBombLastFrame = iHaveBombNow

	arcPhaseClock += dt
	jukeTimer = math.max(0, jukeTimer - dt)
	jumpCooldown = math.max(0, jumpCooldown - dt)
	targetLockTimer = math.max(0, targetLockTimer - dt)
	pathComputeTimer = math.max(0, pathComputeTimer - dt)
	humanReactionDelay = math.max(0, humanReactionDelay - dt)

	if lastPos then
		if (myHrp.Position - lastPos).Magnitude < 0.08 and myHum.WalkSpeed > 2 then stuckTimer += dt else stuckTimer = 0 end
	end
	lastPos = myHrp.Position

	if stuckTimer > 0.28 then
		stuckTimer, jukeSign, jukeIsJumpMode, jukePhase, jukeTimer, currentTurnRate, cachedWaypoints = 0, -jukeSign, true, "jump_chaos_twist", 0.25, 18.5, {}
		setModeTag("JUMP JUKE")
		triggerJumpSkill(myHum, 0.48, rotateFlatVector(currentMoveDir, 58 * jukeSign))
	end

	if iHaveBombNow then
		jukePhase = "none"
		jukeIsJumpMode = false
		coverHoldTimer = 0
		local myBombTime = getRemainingBombTime(myChar)
		local urgentPass = (myBombTime ~= nil and myBombTime <= 4.0)
		local lockedChar, lockedHrp = getCharacterParts(currentTargetPlr)
		local needNewTarget = (not currentTargetPlr) or isTeammate(currentTargetPlr) or (not lockedChar) or (not lockedHrp) or (not isInMatch(lockedChar, lockedHrp)) or hasBomb(lockedChar) or (not isInSameArena(myChar, myHrp, lockedChar, lockedHrp)) or (targetLockTimer <= 0) or ((lockedHrp.Position - myHrp.Position).Magnitude > 60)
		if urgentPass or needNewTarget then
			currentTargetPlr, lockedHrp = pickBestPassTarget(myChar, myHrp, urgentPass)
			targetLockTimer = urgentPass and 0.22 or 0.85
			cachedWaypoints = {}
		end
		if lockedHrp then
			chaseAndPassToTarget(myChar, myHrp, myHum, lockedHrp, urgentPass, dt)
		else
			setModeTag("ROAM")
			local safeRoam = sanitizeDirection(myChar, myHrp, myHum, currentMoveDir)
			applyAIMove(myHrp, myHum, safeRoam, myHrp.Position + safeRoam * 8, nil, dt)
		end
	else
		currentTargetPlr, cachedWaypoints = nil, {}
		local threats, primaryThreat, bombCarriers = collectThreatEntities(myChar, myHrp)
		local bombThreat = bombCarriers[1] or ((primaryThreat and primaryThreat.hasBomb) and primaryThreat or nil)
		local activeThreat = bombThreat or primaryThreat
		local threatHrp = activeThreat and activeThreat.hrp or nil
		local blastPos = activeThreat and (activeThreat.blastCenter or activeThreat.hrp.Position) or nil
		local nearestDist = activeThreat and activeThreat.distToMe or math.huge
		local enemyHasBomb = (activeThreat and activeThreat.hasBomb) or false
		local bombTimeLeft = enemyHasBomb and activeThreat.bombTime or nil
		local urgentTimer = (bombTimeLeft ~= nil and bombTimeLeft <= 3.5)
		local effectiveDodgeDist = enemyHasBomb and math.max(Config.AIDodgeDist, 38) or Config.AIDodgeDist

		if threatHrp and hasCoverBetween(myChar, myHrp.Position, threatHrp.Position) and nearestDist < 18 then
			coverHoldTimer += dt
		else
			coverHoldTimer = math.max(0, coverHoldTimer - dt * 1.5)
		end

		if threatHrp and nearestDist <= effectiveDodgeDist and math.abs(threatHrp.Position.Y - myHrp.Position.Y) > 3.5 then
			syncVerticalLevel(myChar, myHrp, myHum, threatHrp, false, urgentTimer, dt)
			return
		end

		local highDangerNow = activeThreat and (
			(enemyHasBomb and (urgentTimer or nearestDist < 9.5))
			or (not enemyHasBomb and activeThreat.likelyPassTarget and nearestDist < 9.5)
			or (not enemyHasBomb and nearestDist < 7.5)
		)

		if highDangerNow then
			needShiftLockNow = true
			setModeTag("EVADE")
			local awayFlat = Vector3.new(myHrp.Position.X - blastPos.X, 0, myHrp.Position.Z - blastPos.Z)
			local awayDir = (awayFlat.Magnitude > 0.05) and awayFlat.Unit or Vector3.new(1, 0, 0)
			local quickFlip = (math.floor(arcPhaseClock * (urgentTimer and 13 or 11)) % 2 == 0) and 1 or -1
			local safeEscape = sanitizeDirection(myChar, myHrp, myHum, rotateFlatVector(awayDir, (62 * jukeSign * quickFlip) + math.sin(arcPhaseClock * 13) * 26))
			currentTurnRate = urgentTimer and 20.5 or 18.5
			applyAIMove(myHrp, myHum, safeEscape, myHrp.Position + safeEscape * 13, myHrp.Position + safeEscape * 9, dt)
			if nearestDist < 12 and math.random(1, 100) <= (urgentTimer and 78 or 60) then
				triggerJumpSkill(myHum, 0.46, safeEscape)
				jukeSign = -jukeSign
			end
			return
		end

		if Config.AILock and lockedMoveDir then
			setModeTag("LOCKED")
			local safeLocked = sanitizeDirection(myChar, myHrp, myHum, lockedMoveDir)
			currentTurnRate = 16.5
			applyAIMove(myHrp, myHum, safeLocked, myHrp.Position + safeLocked * 12, myHrp.Position + safeLocked * 9, dt)
			return
		end

		local bestDir, bestDirScore = currentMoveDir, -math.huge
		for i = 0, 15 do
			local ang = math.rad(i * 22.5)
			local candidateDir = Vector3.new(math.cos(ang), 0, math.sin(ang))
			local s = evaluateDirectionScore(myChar, myHrp, candidateDir, threats)
			if s > bestDirScore then bestDirScore, bestDir = s, candidateDir end
		end

		if threatHrp and nearestDist <= effectiveDodgeDist then
			local awayFlat = Vector3.new(myHrp.Position.X - blastPos.X, 0, myHrp.Position.Z - blastPos.Z)
			local awayDir = (awayFlat.Magnitude > 0.05) and awayFlat.Unit or bestDir
			local toMe = (myHrp.Position - threatHrp.Position).Unit
			local tFlatVel = Vector3.new(threatHrp.AssemblyLinearVelocity.X, 0, threatHrp.AssemblyLinearVelocity.Z)
			local approachingMe = (threatHrp.CFrame.LookVector:Dot(toMe) > 0.25) or (tFlatVel.Magnitude > 2.5 and tFlatVel.Unit:Dot(toMe) > 0.40)

			if enemyHasBomb and (approachingMe or nearestDist < 16.5 or urgentTimer) then
				needShiftLockNow = true
			end

			if jukeTimer <= 0 and humanReactionDelay <= 0 then
				humanReactionDelay = urgentTimer and 0.02 or (enemyHasBomb and 0.04 or (math.random(5, 12) / 100))
				jukeSign = (math.random(1, 100) <= (enemyHasBomb and 84 or 78)) and -jukeSign or ((math.random(1, 2) == 1) and 1 or -1)
				pickNextJukePattern(nearestDist, approachingMe, urgentTimer, enemyHasBomb)
			end

			local jukeDir = buildLegendaryJukeDir(awayDir, bestDir)
			if enemyHasBomb and (math.floor(arcPhaseClock * 10.0) % 2 == 0) then
				jukeDir = rotateFlatVector(jukeDir, 28 * jukeSign)
			end

			local safeJuke = sanitizeDirection(myChar, myHrp, myHum, jukeDir)
			lockedMoveDir = safeJuke
			applyAIMove(myHrp, myHum, safeJuke, myHrp.Position + safeJuke * 12, (nearestDist < 14 or urgentTimer) and (myHrp.Position + safeJuke * 9) or nil, dt)

			if jukeIsJumpMode and nearestDist < (enemyHasBomb and 24 or 19) then
				triggerJumpSkill(myHum, 0.46, safeJuke)
			elseif enemyHasBomb and nearestDist < 18 and math.random(1, 100) <= 62 then
				jukeSign, jukeIsJumpMode, jukePhase, jukeTimer, currentTurnRate = -jukeSign, true, "jump_chaos_twist", 0.22, 19.0
				setModeTag("JUMP JUKE")
				triggerJumpSkill(myHum, 0.46, rotateFlatVector(safeJuke, 50 * jukeSign))
			elseif nearestDist < 13.5 and approachingMe and math.random(1, 100) <= 55 then
				jukeSign, jukeIsJumpMode, jukePhase, jukeTimer, currentTurnRate = -jukeSign, true, "jump_chaos_twist", 0.24, 18.5
				setModeTag("JUMP JUKE")
				triggerJumpSkill(myHum, 0.46, rotateFlatVector(safeJuke, 45 * jukeSign))
			end
		else
			jukePhase, jukeIsJumpMode, currentTurnRate = "none", false, 12.5
			setModeTag("ROAM")
			if jukeTimer <= 0 then
				jukeTimer = math.random(28, 48) / 100
				if math.random(1, 100) <= 50 then jukeSign = -jukeSign end
				local side = Vector3.new(-bestDir.Z * jukeSign, 0, bestDir.X * jukeSign)
				local safeRoam = sanitizeDirection(myChar, myHrp, myHum, (bestDir * 0.80 + side * 0.36).Unit)
				lockedMoveDir = safeRoam
				applyAIMove(myHrp, myHum, safeRoam, myHrp.Position + safeRoam * 9, nil, dt)
			else
				local safeCurr = sanitizeDirection(myChar, myHrp, myHum, currentMoveDir)
				lockedMoveDir = safeCurr
				applyAIMove(myHrp, myHum, safeCurr, myHrp.Position + safeCurr * 9, nil, dt)
			end
		end
	end
end

-- =========================================================
-- 4) واجهة التحكم المحسّنة + زر Shift Lock
-- =========================================================
local function buildUI()
	local oldGui = playerGui:FindFirstChild("MatchPanelUI")
	if oldGui then oldGui:Destroy() end

	local ScreenGui = Instance.new("ScreenGui")
	ScreenGui.Name = "MatchPanelUI"
	ScreenGui.ResetOnSpawn = false
	ScreenGui.IgnoreGuiInset = true
	ScreenGui.DisplayOrder = 5000
	ScreenGui.Parent = playerGui

	local ROW_COUNT = 5
	local HEADER_HEIGHT = 48
	local STATUS_HEIGHT = 24
	local ROW_HEIGHT = 40
	local ROW_GAP = 6
	local FULL_HEIGHT = HEADER_HEIGHT + STATUS_HEIGHT + 16 + (ROW_COUNT * ROW_HEIGHT) + ((ROW_COUNT - 1) * ROW_GAP)

	local MainFrame = Instance.new("Frame")
	MainFrame.Size = UDim2.new(0, 292, 0, FULL_HEIGHT)
	MainFrame.Position = UDim2.new(0.22, 0, 0.14, 0)
	MainFrame.BackgroundColor3 = Color3.fromRGB(14, 16, 24)
	MainFrame.BorderSizePixel = 0
	MainFrame.Active = true
	MainFrame.Draggable = true
	MainFrame.Parent = ScreenGui
	Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 16)

	local MainGrad = Instance.new("UIGradient")
	MainGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(22, 25, 38)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(12, 14, 21))
	})
	MainGrad.Rotation = 90
	MainGrad.Parent = MainFrame

	local MainStroke = Instance.new("UIStroke")
	MainStroke.Thickness = 1.6
	MainStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	MainStroke.Parent = MainFrame

	local StrokeGrad = Instance.new("UIGradient")
	StrokeGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(110, 130, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(45, 215, 190))
	})
	StrokeGrad.Parent = MainStroke

	local Header = Instance.new("Frame")
	Header.Size = UDim2.new(1, -10, 0, HEADER_HEIGHT)
	Header.Position = UDim2.new(0, 5, 0, 5)
	Header.BackgroundColor3 = Color3.fromRGB(26, 30, 46)
	Header.BorderSizePixel = 0
	Header.Parent = MainFrame
	Instance.new("UICorner", Header).CornerRadius = UDim.new(0, 12)

	local AccentBar = Instance.new("Frame")
	AccentBar.Size = UDim2.new(0, 4, 0, 28)
	AccentBar.Position = UDim2.new(0, 8, 0.5, -14)
	AccentBar.BackgroundColor3 = Color3.fromRGB(85, 225, 195)
	AccentBar.BorderSizePixel = 0
	AccentBar.Parent = Header
	Instance.new("UICorner", AccentBar).CornerRadius = UDim.new(1, 0)

	local TitleLabel = Instance.new("TextLabel")
	TitleLabel.Size = UDim2.new(1, -96, 0, 18)
	TitleLabel.Position = UDim2.new(0, 18, 0, 6)
	TitleLabel.BackgroundTransparency = 1
	TitleLabel.Text = "MATCH | SMART CONTROL"
	TitleLabel.TextColor3 = Color3.fromRGB(248, 250, 255)
	TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
	TitleLabel.Font = Enum.Font.GothamBlack
	TitleLabel.TextSize = 13
	TitleLabel.Parent = Header

	local SubLabel = Instance.new("TextLabel")
	SubLabel.Size = UDim2.new(1, -96, 0, 14)
	SubLabel.Position = UDim2.new(0, 18, 0, 25)
	SubLabel.BackgroundTransparency = 1
	SubLabel.Text = "Radar • Anti-Trap • Tactical Pass • Shift Lock"
	SubLabel.TextColor3 = Color3.fromRGB(145, 158, 198)
	SubLabel.TextXAlignment = Enum.TextXAlignment.Left
	SubLabel.Font = Enum.Font.GothamMedium
	SubLabel.TextSize = 9
	SubLabel.Parent = Header

	local MinBtn = Instance.new("TextButton")
	MinBtn.Size = UDim2.new(0, 28, 0, 28)
	MinBtn.Position = UDim2.new(1, -68, 0.5, -14)
	MinBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 74)
	MinBtn.Text = "-"
	MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	MinBtn.Font = Enum.Font.GothamBold
	MinBtn.TextSize = 16
	MinBtn.Parent = Header
	Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 8)

	local CloseBtn = Instance.new("TextButton")
	CloseBtn.Size = UDim2.new(0, 28, 0, 28)
	CloseBtn.Position = UDim2.new(1, -35, 0.5, -14)
	CloseBtn.BackgroundColor3 = Color3.fromRGB(215, 55, 75)
	CloseBtn.Text = "X"
	CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	CloseBtn.Font = Enum.Font.GothamBold
	CloseBtn.TextSize = 13
	CloseBtn.Parent = Header
	Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(0, 8)

	local StatusBar = Instance.new("Frame")
	StatusBar.Size = UDim2.new(1, -16, 0, STATUS_HEIGHT)
	StatusBar.Position = UDim2.new(0, 8, 0, HEADER_HEIGHT + 8)
	StatusBar.BackgroundColor3 = Color3.fromRGB(21, 24, 36)
	StatusBar.BorderSizePixel = 0
	StatusBar.Parent = MainFrame
	Instance.new("UICorner", StatusBar).CornerRadius = UDim.new(0, 8)

	local StatusDot = Instance.new("Frame")
	StatusDot.Size = UDim2.new(0, 8, 0, 8)
	StatusDot.Position = UDim2.new(0, 10, 0.5, -4)
	StatusDot.BackgroundColor3 = Color3.fromRGB(120, 130, 160)
	StatusDot.BorderSizePixel = 0
	StatusDot.Parent = StatusBar
	Instance.new("UICorner", StatusDot).CornerRadius = UDim.new(1, 0)

	local StatusText = Instance.new("TextLabel")
	StatusText.Size = UDim2.new(1, -24, 1, 0)
	StatusText.Position = UDim2.new(0, 24, 0, 0)
	StatusText.BackgroundTransparency = 1
	StatusText.Text = "AI STATUS : IDLE"
	StatusText.TextColor3 = Color3.fromRGB(165, 178, 215)
	StatusText.TextXAlignment = Enum.TextXAlignment.Left
	StatusText.Font = Enum.Font.GothamBold
	StatusText.TextSize = 10
	StatusText.Parent = StatusBar

	uiStatusUpdater = function(tag)
		if not Config.AI then
			StatusText.Text = "AI STATUS : OFF"
			StatusText.TextColor3 = Color3.fromRGB(155, 165, 195)
			StatusDot.BackgroundColor3 = Color3.fromRGB(115, 125, 155)
			return
		end
		StatusText.Text = "AI STATUS : " .. tostring(tag)
		if tag == "JUMP JUKE" or tag == "CLIMB UP" then
			StatusText.TextColor3 = Color3.fromRGB(120, 235, 255)
			StatusDot.BackgroundColor3 = Color3.fromRGB(70, 210, 255)
		elseif tag == "DROP DOWN" or tag == "EVADE" then
			StatusText.TextColor3 = Color3.fromRGB(255, 200, 95)
			StatusDot.BackgroundColor3 = Color3.fromRGB(255, 180, 60)
		else
			StatusText.TextColor3 = Color3.fromRGB(115, 245, 175)
			StatusDot.BackgroundColor3 = Color3.fromRGB(55, 215, 130)
		end
	end

	local Body = Instance.new("Frame")
	Body.Size = UDim2.new(1, -16, 0, (ROW_COUNT * ROW_HEIGHT) + ((ROW_COUNT - 1) * ROW_GAP))
	Body.Position = UDim2.new(0, 8, 0, HEADER_HEIGHT + STATUS_HEIGHT + 14)
	Body.BackgroundTransparency = 1
	Body.Parent = MainFrame

	local ListLayout = Instance.new("UIListLayout")
	ListLayout.Padding = UDim.new(0, ROW_GAP)
	ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	ListLayout.Parent = Body

	local function createFeatureRow(keyName, order, title, valueConfig, onToggle)
		local row = Instance.new("Frame")
		row.Name = keyName .. "Row"
		row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		row.BackgroundColor3 = Color3.fromRGB(24, 27, 40)
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = Body
		Instance.new("UICorner", row).CornerRadius = UDim.new(0, 10)

		local rowStroke = Instance.new("UIStroke")
		rowStroke.Thickness = 1
		rowStroke.Color = Color3.fromRGB(42, 47, 68)
		rowStroke.Parent = row

		local hasStepper = valueConfig ~= nil
		local toggleWidth = hasStepper and 136 or 260

		local toggleBtn = Instance.new("TextButton")
		toggleBtn.Size = UDim2.new(0, toggleWidth, 1, -8)
		toggleBtn.Position = UDim2.new(0, 4, 0, 4)
		toggleBtn.BackgroundColor3 = Color3.fromRGB(37, 41, 60)
		toggleBtn.Text = title .. " : OFF"
		toggleBtn.TextColor3 = Color3.fromRGB(245, 248, 255)
		toggleBtn.Font = Enum.Font.GothamBold
		toggleBtn.TextSize = 11
		toggleBtn.Parent = row
		Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 8)

		local state = false
		local function setState(newState)
			state = newState
			toggleBtn.Text = title .. (state and " : ON" or " : OFF")
			toggleBtn.BackgroundColor3 = state and Color3.fromRGB(26, 155, 98) or Color3.fromRGB(37, 41, 60)
			rowStroke.Color = state and Color3.fromRGB(48, 195, 130) or Color3.fromRGB(42, 47, 68)
			onToggle(state)
		end

		toggleBtn.MouseButton1Click:Connect(function() setState(not state) end)
		rowRefs[keyName] = { button = toggleBtn, setState = setState }

		if hasStepper then
			local minusBtn = Instance.new("TextButton")
			minusBtn.Size = UDim2.new(0, 28, 1, -8)
			minusBtn.Position = UDim2.new(0, 144, 0, 4)
			minusBtn.BackgroundColor3 = Color3.fromRGB(54, 59, 84)
			minusBtn.Text = "-"
			minusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			minusBtn.Font = Enum.Font.GothamBlack
			minusBtn.TextSize = 15
			minusBtn.Parent = row
			Instance.new("UICorner", minusBtn).CornerRadius = UDim.new(0, 8)

			local valLabel = Instance.new("TextLabel")
			valLabel.Size = UDim2.new(0, 54, 1, -8)
			valLabel.Position = UDim2.new(0, 175, 0, 4)
			valLabel.BackgroundColor3 = Color3.fromRGB(16, 18, 28)
			valLabel.Text = tostring(Config[valueConfig.key])
			valLabel.TextColor3 = Color3.fromRGB(115, 225, 255)
			valLabel.Font = Enum.Font.GothamBold
			valLabel.TextSize = 11
			valLabel.Parent = row
			Instance.new("UICorner", valLabel).CornerRadius = UDim.new(0, 8)

			local plusBtn = Instance.new("TextButton")
			plusBtn.Size = UDim2.new(0, 28, 1, -8)
			plusBtn.Position = UDim2.new(0, 232, 0, 4)
			plusBtn.BackgroundColor3 = Color3.fromRGB(82, 98, 240)
			plusBtn.Text = "+"
			plusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			plusBtn.Font = Enum.Font.GothamBlack
			plusBtn.TextSize = 15
			plusBtn.Parent = row
			Instance.new("UICorner", plusBtn).CornerRadius = UDim.new(0, 8)

			local function stepVal(delta)
				local v = math.clamp(Config[valueConfig.key] + delta, valueConfig.min, valueConfig.max)
				Config[valueConfig.key] = v
				valLabel.Text = tostring(v)
			end

			minusBtn.MouseButton1Click:Connect(function() stepVal(-valueConfig.step) end)
			plusBtn.MouseButton1Click:Connect(function() stepVal(valueConfig.step) end)
		end
	end

	createFeatureRow("reach", 1, "Bomb Reach", { key = "ReachSize", min = 4, max = 20, step = 1 }, function(s)
		Config.Reach = s
	end)

	createFeatureRow("ai", 2, "Smart AI", { key = "AIDodgeDist", min = 12, max = 60, step = 4 }, function(s)
		Config.AI = s
		needShiftLockNow = false
		hadBombLastFrame = false
		cachedWaypoints, jukePhase, jukeIsJumpMode, coverHoldTimer = {}, "none", false, 0
		setModeTag(s and "ROAM" or "OFF")
		if not s then
			restoreShiftLockState(LocalPlayer.Character)
			if rowRefs.lock then rowRefs.lock.setState(false) end
			local myChar, _, myHum = getCharacterParts(LocalPlayer)
			if myChar and myHum then myHum:MoveTo(myChar:GetPivot().Position) end
		end
	end)

	createFeatureRow("lock", 3, "Lock AI", nil, function(s)
		if s and not Config.AI then
			Config.AILock, lockedMoveDir = false, nil
			task.defer(function()
				if rowRefs.lock and rowRefs.lock.setState then rowRefs.lock.setState(false) end
			end)
			return
		end
		Config.AILock = s
		lockedMoveDir = s and currentMoveDir or nil
	end)

	createFeatureRow("shiftlock", 4, "Shift Lock", nil, function(s)
		Config.ShiftLock = s
		if not s then
			needShiftLockNow = false
			restoreShiftLockState(LocalPlayer.Character)
		end
	end)

	createFeatureRow("ff071", 5, "FF_071", nil, function(s)
		Config.FF_071 = s
		if s then applyCustomLocalStyle(LocalPlayer.Character) else restoreCustomLocalStyle(LocalPlayer.Character) end
	end)

	local minimized = false
	MinBtn.MouseButton1Click:Connect(function()
		minimized = not minimized
		StatusBar.Visible = not minimized
		Body.Visible = not minimized
		MinBtn.Text = minimized and "+" or "-"
		MainFrame.Size = minimized and UDim2.new(0, 292, 0, HEADER_HEIGHT + 10) or UDim2.new(0, 292, 0, FULL_HEIGHT)
	end)

	CloseBtn.MouseButton1Click:Connect(function()
		Config.Reach, Config.AI, Config.AILock, Config.ShiftLock, Config.FF_071 = false, false, false, false, false
		needShiftLockNow = false
		restoreShiftLockState(LocalPlayer.Character)
		restoreCustomLocalStyle(LocalPlayer.Character)
		ScreenGui:Destroy()
	end)
end

pcall(buildUI)

LocalPlayer.CharacterAdded:Connect(function(newChar)
	savedOutfit.Saved = false
	savedShiftState.Active = false
	savedShiftState.AutoRotate = nil
	needShiftLockNow = false
	hadBombLastFrame = false
	if Config.FF_071 then
		task.wait(0.25)
		applyCustomLocalStyle(newChar)
	end
end)

local stepAccum = 0
RunService.RenderStepped:Connect(function(dt)
	stepAccum += dt
	if stepAccum < 0.08 then return end
	local elapsed = stepAccum
	stepAccum = 0

	local myChar, myHrp, myHum = getCharacterParts(LocalPlayer)
	if not myChar or not myHrp or not myHum then return end
	if Config.FF_071 then applyCustomLocalStyle(myChar) end
	if Config.AI then
		pcall(runSmartAI, myChar, myHrp, myHum, elapsed)
	else
		needShiftLockNow = false
		hadBombLastFrame = false
	end
	updateShiftLock(myChar, myHrp, myHum, elapsed)
end)

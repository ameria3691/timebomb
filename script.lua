--// TIMEBOMB AI v6 · LEGEND+ EDITION (FULL & TUNED)
--// Time Calc | Edge Analysis | Opponent Memory | Smart Flee | Dodge Skills | Jump Dodges | Auto Climb + Ladders | Reflex System | ESP | Outfit Copy | Safe Zone | CamTrack | Radar UI
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local PathfindingService = game:GetService("PathfindingService")

local LP = Players.LocalPlayer
local rng = Random.new()

local Config = {
	AI = false,
	Reach = false,
	ShiftLock = false,
	CamTrack = false,
	AutoRestart = true,
	TimeAware = true,   -- حساب الوقت
	EdgeAI = true,      -- تحليل الحافات
	Memory = true,      -- ذاكرة الخصوم
	Nav = true,         -- ملاحة: تجنب الحواجز + مسار + صعود
	Parkour = true,     -- قفز/باركور/اختباء خلف الأعمدة
	Climb = true,       -- يطلع فوق لو الخصم فوق
	JumpDodge = true,   -- مراوغات القفز (تشتغل فقط لو القفز ممكن في الساحة)
	JumpRate = 0.6,     -- كثرة مراوغات القفز
	Immunity = 2.0,     -- مدة حماية اللي مرر لك (ما تقدر ترجعها له)
	PassRange = 13.5,
	FleeRange = 17.5,
	ReachDistance = 15,
	Reaction = 0.045,
	Aggro = 0.68,
	UrgentTime = 4,
	YTolerance = 60,      -- فرق الارتفاع المسموح بين اللاعبين في نفس الساحة (ساحات القفز طويلة)
	MapYTolerance = 14,   -- ارتفاع خلايا الخريطة (تحليل الحافات)
	Ladder = true,        -- تسلق السلالم (Truss)
	Reflex = true,        -- ردة فعل خارقة: يراوغ لحظة وصول المطارد
	ReflexWindow = 0.52,  -- كم ثانية قبل الاصطدام يبدأ الريفلكس
	SafeZone = true,      -- يتمركز بمكان آمن بعيد عن الزوايا لما القنبلة بعيدة
	ESP = true,           -- كشف اللاعبين اللي معك بنفس الساحة فقط
	Outfit = false,       -- نسخ ملابس لاعب (يظهر عندك فقط)
	OutfitUser = "FF_071",
}

local C = {
	bg = Color3.fromRGB(12, 12, 20),
	panel = Color3.fromRGB(18, 18, 30),
	card = Color3.fromRGB(27, 27, 43),
	text = Color3.fromRGB(238, 238, 250),
	sub = Color3.fromRGB(140, 140, 170),
	accent = Color3.fromRGB(130, 90, 255),
	accent2 = Color3.fromRGB(0, 205, 255),
	good = Color3.fromRGB(60, 225, 140),
	warn = Color3.fromRGB(255, 185, 60),
	bad = Color3.fromRGB(255, 70, 95),
	off = Color3.fromRGB(70, 70, 98),
	corner = Color3.fromRGB(255, 60, 200),
	line = Color3.fromRGB(48, 48, 76),
}

local alive = true
local connections = {}
local Refreshers = {}
local toast, buildRadar, updateRadar, setMeter

local State = {
	target = nil, targetDist = math.huge, targetMem = nil, targetEdge = nil,
	threat = nil, threatDist = math.huge, threatMem = nil,
	approaching = false, myTime = nil, threatTime = nil,
	arenaCenter = nil, focus = nil, focusDist = math.huge,
	peak = 0, lastHT = 0, lockedTarget = nil, dots = {}, lastThreat = nil, lastThreatT = 0, stalk = nil,
}
local Style = { mode = "", name = "", untilT = 0, phaseT = 0, dir = 1, period = 0.4, cache = nil, cacheT = 0, lastSide = 0, nextJump = 0, data = nil }
local Stats = { rounds = 0, passes = 0, jumps = 0, climbs = 0, reflex = 0, t0 = os.clock() }
local LG = {} -- مساحة أسماء للميزات الجديدة (حد 200 متغير محلي بلوا)

local function now() return os.clock() end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function unit(v)
	if v.Magnitude < 1e-3 then return Vector3.new(0, 0, 1) end
	return v.Unit
end
local function perp(v) return Vector3.new(-v.Z, 0, v.X) end
local function rotate(v, deg) return (CFrame.Angles(0, math.rad(deg), 0) * CFrame.new(v)).Position end

--------------------------------------------------------------------
-- 1) الفحوصات
--------------------------------------------------------------------
local ATTRS = { "Team", "Squad", "Faction", "Group" }

local function isTeammate(plr)
	if plr == LP then return true end
	if plr.Team and LP.Team and plr.Team == LP.Team and not plr.Neutral and not LP.Neutral then return true end
	if not plr.Neutral and not LP.Neutral and plr.TeamColor == LP.TeamColor then return true end
	for _, n in ipairs(ATTRS) do
		local a, b = plr:GetAttribute(n), LP:GetAttribute(n)
		if a ~= nil and a == b then return true end
	end
	return false
end

local BOMB_WORDS = { "bomb", "tnt", "time", "boom" }
local function nameIsBomb(name)
	name = string.lower(name)
	for _, w in ipairs(BOMB_WORDS) do
		if string.find(name, w, 1, true) then return true end
	end
	return false
end

local function findBombObject(plr)
	local char = plr and plr.Character
	if char then
		for _, c in ipairs(char:GetChildren()) do
			if (c:IsA("Tool") or c:IsA("Model") or c:IsA("BasePart")) and nameIsBomb(c.Name) then return c end
		end
	end
	local bp = plr and plr:FindFirstChildOfClass("Backpack")
	if bp then
		for _, c in ipairs(bp:GetChildren()) do
			if c:IsA("Tool") and nameIsBomb(c.Name) then return c end
		end
	end
	return nil
end

local function hasBomb(plr) return findBombObject(plr) ~= nil end

local TIME_NAMES = { "time", "timer", "countdown", "bombtime", "timeleft" }
local function isTimeName(n)
	n = string.lower(n)
	for _, t in ipairs(TIME_NAMES) do
		if n == t then return true end
	end
	return false
end

local function parseTime(text)
	local m, s = string.match(text, "(%d+):(%d+)")
	if m then return tonumber(m) * 60 + tonumber(s) end
	local n = string.match(text, "%d+%.?%d*")
	return n and tonumber(n) or nil
end

local function readTimeFromInstance(inst)
	if inst:IsA("NumberValue") or inst:IsA("IntValue") then
		if isTimeName(inst.Name) or nameIsBomb(inst.Name) then return inst.Value end
	elseif inst:IsA("TextLabel") then
		if isTimeName(inst.Name) or nameIsBomb(inst.Name) or (inst.Parent and nameIsBomb(inst.Parent.Name)) then
			return parseTime(inst.Text)
		end
	end
	return nil
end

local function readAttrs(inst)
	for attrName, v in pairs(inst:GetAttributes()) do
		if type(v) == "number" and isTimeName(attrName) then return v end
	end
	return nil
end

local function scanRoot(root)
	if not root then return nil end
	local v = readAttrs(root) or readTimeFromInstance(root)
	if v then return v end
	for _, d in ipairs(root:GetDescendants()) do
		v = readAttrs(d) or readTimeFromInstance(d)
		if v then return v end
	end
	return nil
end

local function getRemainingBombTime(plr)
	local obj = findBombObject(plr)
	if not obj then return nil end
	local v = scanRoot(obj) or scanRoot(plr.Character)
	if v then return v end
	v = readAttrs(Workspace)
	if v then return v end
	for _, c in ipairs(Workspace:GetChildren()) do
		v = readTimeFromInstance(c)
		if v then return v end
	end
	return nil
end

local function getCharacterParts(plr)
	local char = plr and plr.Character
	if not char then return nil end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hrp or not hum or hum.Health <= 0 then return nil end
	return char, hrp, hum
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function getFloorPart(plr)
	local char, hrp = getCharacterParts(plr)
	if not char then return nil end
	rayParams.FilterDescendantsInstances = { char }
	local res = Workspace:Raycast(hrp.Position, Vector3.new(0, -50, 0), rayParams)
	if res then return res.Instance, res.Position end
	return nil
end

local LOBBY_WORDS = { "lobby", "waiting", "spectat" }
local function looksLikeLobby(inst)
	local depth = 0
	while inst and inst ~= Workspace and depth < 5 do
		local n = string.lower(inst.Name)
		for _, w in ipairs(LOBBY_WORDS) do
			if string.find(n, w, 1, true) then return true end
		end
		inst = inst.Parent
		depth += 1
	end
	return false
end

local function isInMatch(plr)
	if not getCharacterParts(plr) then return false end
	local floor = getFloorPart(plr)
	if not floor then return false end
	if looksLikeLobby(floor) then return false end
	return true
end

local function isInSameArena(plr)
	if not isInMatch(plr) or not isInMatch(LP) then return false end
	local _, myHrp = getCharacterParts(LP)
	local _, hrp = getCharacterParts(plr)
	if not myHrp or not hrp then return false end
	if math.abs(myHrp.Position.Y - hrp.Position.Y) > Config.YTolerance then return false end
	local f1, f2 = getFloorPart(LP), getFloorPart(plr)
	if f1 == f2 or (f1 and f2 and f1.Parent == f2.Parent) then return true end
	return f1 and f2 and (f1.Position - f2.Position).Magnitude < 80
end

local function hasFloorAt(p)
	rayParams.FilterDescendantsInstances = { LP.Character }
	local res = Workspace:Raycast(p + Vector3.new(0, 3, 0), Vector3.new(0, -40, 0), rayParams)
	return res ~= nil and not looksLikeLobby(res.Instance)
end

--------------------------------------------------------------------
-- العوائق والملاحة (Pathfinding) + القفز والتسلق + حماية التمرير
--------------------------------------------------------------------
local Immune = {} -- لاعبين ما تقدر تمرر لهم فوراً (بعد ما مرروا لك)

local function immuneRemaining(plr)
	local rem = (Immune[plr.UserId] or 0) - now()
	return rem > 0 and rem or 0
end

local function isImmune(plr)
	local rem = immuneRemaining(plr)
	if rem <= 0 then return false end
	if State.myTime and State.myTime <= rem then return false end
	return true
end

local charCache, charCacheT = {}, 0
local function charList()
	if now() - charCacheT > 0.3 then
		charCache = {}
		for _, p in ipairs(Players:GetPlayers()) do
			if p.Character then charCache[#charCache + 1] = p.Character end
		end
		charCacheT = now()
	end
	return charCache
end

local hardParams = RaycastParams.new()
hardParams.FilterType = Enum.RaycastFilterType.Exclude
local function castHard(origin, vec)
	local ignore = table.clone(charList())
	for _ = 1, 4 do
		hardParams.FilterDescendantsInstances = ignore
		local res = Workspace:Raycast(origin, vec, hardParams)
		if not res then return nil end
		if res.Instance.CanCollide then return res end
		ignore[#ignore + 1] = res.Instance
	end
	return nil
end

local function clearLine(from, to)
	local vec = to - from
	for _, h in ipairs({ -1.5, 0, 1.6 }) do
		local o = Vector3.new(from.X, from.Y + h, from.Z)
		if castHard(o, vec) then return false end
	end
	return true
end

----------------------------------------------------------------
-- نظام القفز: كشف إمكانية القفز في الساحة + قفز موثوق + تحقق فعلي
----------------------------------------------------------------
local function jumpHeightOf(hum)
	if hum.UseJumpPower then
		local jp = hum.JumpPower
		return jp * jp / (2 * Workspace.Gravity)
	end
	return hum.JumpHeight
end

local Jump = { fails = 0, blockedUntil = 0, last = 0 }

local function canJump(hum)
	if not hum or hum.Health <= 0 then return false end
	if now() < Jump.blockedUntil then return false end
	local ok, enabled = pcall(function() return hum:GetStateEnabled(Enum.HumanoidStateType.Jumping) end)
	if ok and enabled == false then return false end
	return jumpHeightOf(hum) >= 1.5
end

local function verifyJump(hum)
	task.delay(0.28, function()
		if not alive or not hum.Parent then return end
		local _, hrp = getCharacterParts(LP)
		local st = hum:GetState()
		local up = hrp ~= nil and hrp.AssemblyLinearVelocity.Y > 6
		if st == Enum.HumanoidStateType.Jumping or st == Enum.HumanoidStateType.Freefall
			or up or hum.FloorMaterial == Enum.Material.Air then
			Jump.fails = 0
		else
			Jump.fails += 1
			if Jump.fails >= 4 then
				Jump.fails = 0
				Jump.blockedUntil = now() + 20
				if toast then toast("JUMP LOCKED  •  القفز مقفول هنا", C.warn) end
			end
		end
	end)
end

local function forceJump(hum)
	if not canJump(hum) then return false end
	if hum.FloorMaterial == Enum.Material.Air then return false end
	local t = now()
	if t - Jump.last < 0.35 then return false end
	Jump.last = t
	hum.Jump = true
	pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
	Stats.jumps += 1
	verifyJump(hum)
	return true
end

local function tryJump(hum, chance)
	if now() - Jump.last > 0.9 and rng:NextNumber() < chance then
		return forceJump(hum)
	end
	return false
end

local function pulseJump(hum, interval)
	local t = now()
	if t >= (Style.nextJump or 0) and forceJump(hum) then
		Style.nextJump = t + interval
	end
end

local function ledgeAhead(hrp, hum, dir)
	if not canJump(hum) then return false end
	dir = unit(flat(dir))
	local feetY = hrp.Position.Y - (hum.HipHeight + hrp.Size.Y / 2)
	local px, pz = hrp.Position.X, hrp.Position.Z
	local low = castHard(Vector3.new(px, feetY + 0.8, pz), dir * 3.5)
	if not low then return false end
	local jh = math.max(jumpHeightOf(hum) - 0.6, 2)
	local high = castHard(Vector3.new(px, feetY + jh + 1.2, pz), dir * 3.5)
	return high == nil
end

local STEER_ANGLES = { 0, 25, -25, 50, -50, 80, -80, 120, -120, 160 }
local function steerDir(hrp, dir, dist)
	dir = unit(flat(dir))
	dist = dist or 6
	for _, ang in ipairs(STEER_ANGLES) do
		local d = unit(rotate(dir, ang))
		local to = hrp.Position + d * dist
		if clearLine(hrp.Position, to) and hasFloorAt(to) then return d end
	end
	return nil
end

local Nav = {
	wps = nil, idx = 1, goal = nil, computing = false, lastT = 0,
	lastPos = nil, lastCheck = 0, lastCall = 0, escapeUntil = 0, escapeDir = Vector3.new(0, 0, 1),
}

local function navReset()
	Nav.wps, Nav.idx, Nav.goal = nil, 1, nil
	Nav.lastPos, Nav.escapeUntil = nil, 0
end

local function stuckCheck(hrp, hum, to)
	local t = now()
	if t - Nav.lastCall > 1 then Nav.lastPos = nil end
	Nav.lastCall = t
	if Nav.escapeUntil > t then
		hum:MoveTo(hrp.Position + Nav.escapeDir * 8)
		return true
	end
	if not Nav.lastPos or t - Nav.lastCheck > 0.5 then
		if Nav.lastPos and (hrp.Position - Nav.lastPos).Magnitude < 0.8 and flat(to).Magnitude > 4 then
			forceJump(hum)
			Nav.wps = nil
			Nav.lastT = 0
			Nav.escapeUntil = t + 0.45
			Nav.escapeDir = perp(unit(flat(to))) * (rng:NextInteger(0, 1) == 0 and 1 or -1)
		end
		Nav.lastPos, Nav.lastCheck = hrp.Position, t
	end
	return false
end

local function navCompute(hrp, goal)
	if Nav.computing or now() - Nav.lastT < 0.4 then return end
	Nav.computing, Nav.lastT = true, now()
	local from = hrp.Position
	task.spawn(function()
		local ok = pcall(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2.0, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 3.5,
			})
			path:ComputeAsync(from, goal)
			if path.Status == Enum.PathStatus.Success then
				Nav.wps = path:GetWaypoints()
				Nav.idx = 2
				Nav.goal = goal
			else
				Nav.wps = nil
			end
		end)
		if not ok then Nav.wps = nil end
		Nav.computing = false
	end)
end

local function followPath(hrp, hum)
	local wps = Nav.wps
	if not wps then return false end
	local pos = hrp.Position
	while wps[Nav.idx] and flat(wps[Nav.idx].Position - pos).Magnitude < 3.2 and math.abs(wps[Nav.idx].Position.Y - pos.Y) < 5 do
		Nav.idx += 1
	end
	local wp = wps[Nav.idx]
	if wp then
		local feetY = pos.Y - (hum.HipHeight + hrp.Size.Y / 2)
		local near = flat(wp.Position - pos).Magnitude
		if wp.Action == Enum.PathWaypointAction.Jump and near < 7 then
			forceJump(hum)
		elseif wp.Position.Y - feetY > 2 and near < 5 then
			forceJump(hum)
		end
		hum:MoveTo(wp.Position)
		return true
	end
	Nav.wps = nil
	return false
end

local function navMove(hrp, hum, goal)
	local pos = hrp.Position
	local to = goal - pos
	local flatD = flat(to).Magnitude
	if flatD < 0.35 then hum:MoveTo(goal) return end
	if stuckCheck(hrp, hum, to) then return end
	if not Config.Nav then hum:MoveTo(goal) return end

	local dirG = unit(flat(to))

	if Config.Parkour and flatD > 1.2 and ledgeAhead(hrp, hum, dirG) then
		forceJump(hum)
		hum:MoveTo(goal)
		return
	end

	local dy = goal.Y - pos.Y
	local direct = math.abs(dy) < 4 and clearLine(pos, Vector3.new(goal.X, pos.Y, goal.Z))
	if direct then
		Nav.wps = nil
		if flatD <= 7.5 then
			hum:MoveTo(goal)
			return
		end
		local sd = steerDir(hrp, dirG, 7) or dirG
		hum:MoveTo(pos + sd * 10)
		return
	end

	if not Nav.wps or not Nav.goal or flat(Nav.goal - goal).Magnitude > 6 then
		navCompute(hrp, goal)
	end
	if followPath(hrp, hum) then return end

	local sd = steerDir(hrp, dirG, 8)
	if sd then
		hum:MoveTo(pos + sd * 10)
	else
		forceJump(hum)
		hum:MoveTo(pos + perp(dirG) * 8)
	end
end

local function steerMove(hrp, hum, p)
	local pos = hrp.Position
	local dirv = flat(p - pos)
	if dirv.Magnitude < 0.5 then hum:MoveTo(pos) return end
	if stuckCheck(hrp, hum, dirv) then return end
	local dir = unit(dirv)
	if Config.Parkour and ledgeAhead(hrp, hum, dir) then
		forceJump(hum)
		hum:MoveTo(pos + dir * 8)
		return
	end
	local sd = Config.Nav and steerDir(hrp, dir, 7) or dir
	hum:MoveTo(pos + (sd or dir) * 10)
end

local pillarCache, pillarT = nil, 0
local function findPillar(hrp)
	if now() - pillarT < 0.7 then return pillarCache end
	pillarT = now()
	pillarCache = nil
	local best, bestD = nil, 1e9
	for a = 0, 315, 45 do
		local dir = Vector3.new(math.cos(math.rad(a)), 0, math.sin(math.rad(a)))
		local res = castHard(hrp.Position, dir * 24)
		if res and res.Distance > 3 and res.Normal.Y < 0.5 then
			local inst = res.Instance
			if inst:IsA("BasePart") and not inst:IsA("Terrain") and inst.Size.Y >= 5
				and math.max(inst.Size.X, inst.Size.Z) <= 70 and res.Distance < bestD then
				best, bestD = inst, res.Distance
			end
		end
	end
	if best then pillarCache = { part = best, center = best.Position, size = best.Size } end
	return pillarCache
end

local function coverPoint(hrp, thrp, pl)
	local c = Vector3.new(pl.center.X, hrp.Position.Y, pl.center.Z)
	local away = unit(flat(c - thrp.Position))
	local r = math.max(pl.size.X, pl.size.Z) / 2 + 4.5
	return c + away * r
end

local function findLedge(hrp, hum, thrp, goal)
	if not canJump(hum) then return nil end
	local jh = math.max(jumpHeightOf(hum) - 0.6, 2)
	local feetY = hrp.Position.Y - (hum.HipHeight + hrp.Size.Y / 2)
	local px, pz = hrp.Position.X, hrp.Position.Z
	local stepA = goal and 30 or 45
	local reach = goal and 16 or 12
	local best, bestScore
	for a = 0, 359, stepA do
		local dir = Vector3.new(math.cos(math.rad(a)), 0, math.sin(math.rad(a)))
		local low = castHard(Vector3.new(px, feetY + 0.8, pz), dir * reach)
		if low and low.Normal.Y < 0.5 and low.Distance > 1 then
			local high = castHard(Vector3.new(px, feetY + jh + 1.2, pz), dir * (low.Distance + 3))
			if not high then
				local topO = low.Position + dir * 2 + Vector3.new(0, jh + 3, 0)
				local top = castHard(topO, Vector3.new(0, -(jh + 3.8), 0))
				if top and top.Position.Y > feetY + 1.2 and top.Position.Y < feetY + jh + 0.3 then
					local score
					if goal then
						score = (top.Position.Y - feetY) * 3 - flat(top.Position - goal).Magnitude
					else
						score = (thrp and flat(low.Position - thrp.Position).Magnitude or 0) - low.Distance
					end
					if not best or score > bestScore then
						best, bestScore = { point = low.Position - dir * 1.5, dir = dir, top = top.Position }, score
					end
				end
			end
		end
	end
	return best
end

----------------------------------------------------------------
-- السلالم (Truss): يلقى سلم يوصل لفوق، يمشي له، ويتسلقه
----------------------------------------------------------------
LG.Ladder = {
	part = nil, bad = {}, list = {}, listT = -100, since = 0, lastStep = 0, commitUntil = 0,
	lastY = 0, lastYT = 0, rot = 0, nearT = 0, dir0 = Vector3.new(0, 0, 1),
}

function LG.refreshTrusses()
	local wait = (#LG.Ladder.list == 0) and 30 or 8
	if now() - LG.Ladder.listT < wait then return end
	LG.Ladder.listT = now()
	local list = {}
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("TrussPart") then list[#list + 1] = d end
	end
	LG.Ladder.list = list
end

function LG.pickTruss(pos, feetY, goalY, maxD)
	LG.refreshTrusses()
	local t0 = now()
	local best, bestScore
	for _, tr in ipairs(LG.Ladder.list) do
		if tr.Parent and (LG.Ladder.bad[tr] or 0) < t0 and tr.CFrame.UpVector.Y > 0.7 and not looksLikeLobby(tr) then
			local top = tr.Position.Y + tr.Size.Y / 2
			local bot = tr.Position.Y - tr.Size.Y / 2
			local fd = flat(tr.Position - pos).Magnitude
			if fd <= maxD and top > feetY + 4 and bot < feetY + 5 then
				local score = -fd * 0.6 - math.abs(top - goalY) * 1.2
				if not best or score > bestScore then best, bestScore = tr, score end
			end
		end
	end
	return best
end

function LG.trussStep(hrp, hum, goal)
	local t = now()
	local pos = hrp.Position
	local feetY = pos.Y - (hum.HipHeight + hrp.Size.Y / 2)
	local goalFlat = flat(goal - pos)
	LG.Ladder.lastStep = t

	if hum:GetState() == Enum.HumanoidStateType.Climbing then
		local p = LG.Ladder.part
		if not p or not p.Parent then
			p = LG.pickTruss(pos, feetY - 40, goal.Y, 8)
			LG.Ladder.part = p
		end
		LG.Ladder.commitUntil = t + 2.5
		local into = p and flat(p.Position - pos) or Vector3.zero
		local inDir = into.Magnitude > 0.15 and into.Unit or unit(flat(hrp.CFrame.LookVector))
		local top = p and (p.Position.Y + p.Size.Y / 2) or (feetY + 100)
		if t - LG.Ladder.lastYT > 1.3 then
			if p and pos.Y - LG.Ladder.lastY < 0.8 and feetY < top - 3 and goal.Y > feetY + 1 then
				LG.Ladder.bad[p] = t + 10
				LG.Ladder.part = nil
				hum.Jump = true
				return true
			end
			LG.Ladder.lastY, LG.Ladder.lastYT = pos.Y, t
		end
		if feetY >= top - 3 or feetY >= goal.Y - 2.5 then
			local dir = inDir
			if goalFlat.Magnitude > 1 then dir = unit(inDir + goalFlat.Unit * 0.6) end
			hum:MoveTo(pos + dir * 8)
		else
			hum:MoveTo(pos + inDir * 6)
		end
		return true
	end

	LG.Ladder.lastY, LG.Ladder.lastYT = pos.Y, t
	local p = LG.Ladder.part
	if p and (not p.Parent or (LG.Ladder.bad[p] or 0) > t or p.Position.Y + p.Size.Y / 2 <= feetY + 3.5) then
		p = nil
		LG.Ladder.part = nil
	end
	if not p then
		p = LG.pickTruss(pos, feetY, goal.Y, 140)
		LG.Ladder.part = p
		if p then
			LG.Ladder.since, LG.Ladder.rot, LG.Ladder.nearT = t, 0, 0
			local d0 = flat(p.Position - pos)
			LG.Ladder.dir0 = d0.Magnitude > 0.1 and d0.Unit or Vector3.new(0, 0, 1)
		end
	end
	if not p then return false end
	if t - LG.Ladder.since > 16 then
		LG.Ladder.bad[p] = t + 15
		LG.Ladder.part = nil
		return false
	end
	LG.Ladder.commitUntil = t + 3

	local tp = p.Position
	local half = math.max(p.Size.X, p.Size.Z) / 2
	local bot = tp.Y - p.Size.Y / 2
	local approach = Vector3.new(tp.X, pos.Y, tp.Z) - rotate(LG.Ladder.dir0, LG.Ladder.rot) * (half + 1.7)
	if flat(approach - pos).Magnitude > 3 then
		navMove(hrp, hum, approach)
		LG.Ladder.nearT = 0
	else
		if LG.Ladder.nearT == 0 then LG.Ladder.nearT = t end
		hum:MoveTo(Vector3.new(tp.X, pos.Y, tp.Z))
		if bot > feetY + 1.2 then forceJump(hum) end
		if t - LG.Ladder.nearT > 2.6 then
			LG.Ladder.rot = (LG.Ladder.rot + 90) % 360
			LG.Ladder.nearT = 0
		end
	end
	return true
end

local climbCache, climbT = nil, 0
local function climbMove(hrp, hum, goal)
	local pos = hrp.Position
	local to = goal - pos
	local fd = flat(to).Magnitude
	local jh = jumpHeightOf(hum)
	local t = now()
	local cj = canJump(hum)

	if Config.Ladder and (hum:GetState() == Enum.HumanoidStateType.Climbing or (LG.Ladder.part and LG.Ladder.commitUntil > t)) then
		if LG.trussStep(hrp, hum, goal) then return true end
	end

	if stuckCheck(hrp, hum, to) then return true end

	if cj and fd < 6 and to.Y <= jh + 2.5 then
		hum:MoveTo(pos + unit(flat(to)) * 8)
		if forceJump(hum) then Stats.climbs += 1 end
		return true
	end

	if not Nav.wps or not Nav.goal or flat(Nav.goal - goal).Magnitude > 6 then
		navCompute(hrp, goal)
	end
	if followPath(hrp, hum) then return true end

	if Config.Ladder then
		if Nav.computing then
			hum:MoveTo(pos)
			return true
		end
		if LG.trussStep(hrp, hum, goal) then return true end
	end

	if now() - climbT > 0.35 then
		climbT = now()
		climbCache = findLedge(hrp, hum, nil, goal)
	end
	local lg = climbCache
	if lg then
		local lp = Vector3.new(lg.point.X, pos.Y, lg.point.Z)
		if flat(lp - pos).Magnitude < 2.8 then
			hum:MoveTo(pos + lg.dir * 8)
			if forceJump(hum) then Stats.climbs += 1 end
		else
			hum:MoveTo(lp)
		end
		return true
	end
	return false
end

local function nearestEnemy(maxD)
	local _, myHrp = getCharacterParts(LP)
	if not myHrp then return nil end
	local best, bd = nil, maxD
	for _, plr in ipairs(Players:GetPlayers()) do
		if not isTeammate(plr) then
			local _, hrp = getCharacterParts(plr)
			if hrp then
				local d = (hrp.Position - myHrp.Position).Magnitude
				if d < bd then best, bd = plr, d end
			end
		end
	end
	return best
end

--------------------------------------------------------------------
-- تحليل الحافات: خريطة الساحة (شبكة) عند بداية الجولة
--------------------------------------------------------------------
local Map = { ready = false, building = false, step = 8, half = 12, cells = {}, origin = nil, centroid = nil, gen = 0, walk = 0 }

local function allChars()
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then t[#t + 1] = p.Character end
	end
	return t
end

local function cellAt(p)
	if not Map.ready then return nil end
	local i = math.floor((p.X - Map.origin.X) / Map.step + 0.5)
	local j = math.floor((p.Z - Map.origin.Z) / Map.step + 0.5)
	local row = Map.cells[i]
	return row and row[j]
end

local function getCenter()
	if Map.ready and Map.centroid then return Map.centroid end
	return State.arenaCenter
end

local function buildMap()
	local _, hrp = getCharacterParts(LP)
	if not hrp then return end
	Map.gen += 1
	local gen = Map.gen
	Map.ready, Map.building = false, true
	local step, half = Map.step, Map.half
	local last = half * 2
	local c = hrp.Position
	local origin = Vector3.new(c.X - half * step, c.Y, c.Z - half * step)

	task.spawn(function()
		local cells, walkCount, rays = {}, 0, 0
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = allChars()

		for i = 0, last do
			cells[i] = {}
			for j = 0, last do
				local p = Vector3.new(origin.X + i * step, c.Y + 3, origin.Z + j * step)
				local res = Workspace:Raycast(p, Vector3.new(0, -60, 0), params)
				local walk = res ~= nil and not looksLikeLobby(res.Instance) and math.abs(res.Position.Y - c.Y) < Config.MapYTolerance
				cells[i][j] = { walk = walk, edge = 99, open = 0, corner = false }
				if walk then walkCount += 1 end
				rays += 1
				if rays % 25 == 0 then
					RunService.Heartbeat:Wait()
					if Map.gen ~= gen or not alive then return end
				end
			end
		end

		local function isWalk(i, j)
			local row = cells[i]
			local cell = row and row[j]
			if not cell then return true end
			return cell.walk
		end

		local sumX, sumZ, cnt = 0, 0, 0
		for i = 0, last do
			for j = 0, last do
				local cell = cells[i][j]
				if cell.walk then
					local e = 99
					for di = -3, 3 do
						for dj = -3, 3 do
							if not isWalk(i + di, j + dj) then
								local d = math.sqrt(di * di + dj * dj) * step
								if d < e then e = d end
							end
						end
					end
					local o, n3 = 0, 0
					for di = -2, 2 do
						for dj = -2, 2 do
							if isWalk(i + di, j + dj) then
								o += 1
								if math.abs(di) <= 1 and math.abs(dj) <= 1 then n3 += 1 end
							end
						end
					end
					cell.edge, cell.open, cell.corner = e, o / 25, n3 <= 4
					sumX += origin.X + i * step
					sumZ += origin.Z + j * step
					cnt += 1
				end
			end
		end

		Map.cells, Map.origin, Map.walk = cells, origin, walkCount
		Map.centroid = cnt > 0 and Vector3.new(sumX / cnt, c.Y, sumZ / cnt) or nil
		Map.ready, Map.building = walkCount >= 6, false
		if Map.ready then
			if buildRadar then pcall(buildRadar) end
			if toast then toast("ARENA MAPPED  •  تم تحليل الساحة", C.good) end
		end
	end)
end

--------------------------------------------------------------------
-- ذاكرة الخصوم
--------------------------------------------------------------------
local Memory = {}

local function memOf(plr)
	local m = Memory[plr.UserId]
	if not m then
		m = { speed = 0, stop = 0, away = 0, bias = 0, erratic = 0, jumps = 0, time = 0, air = false, lastVel = nil, lastT = now() }
		Memory[plr.UserId] = m
	end
	return m
end

local function updateMemory(plr, hrp, hum, myPos)
	local m = memOf(plr)
	local t = now()
	local dt = t - m.lastT
	m.lastT = t
	if dt <= 0 or dt > 1 then
		m.lastVel = nil
		return m
	end
	local a = math.clamp(dt / 4, 0.02, 0.3)
	local v = flat(hrp.AssemblyLinearVelocity)
	local sp = v.Magnitude
	m.time += dt
	m.speed += (sp - m.speed) * a
	m.stop += ((sp < 2 and 1 or 0) - m.stop) * a

	local toMe = flat(myPos - hrp.Position)
	local d = toMe.Magnitude
	if d > 0.5 and d < 30 and sp > 2 then
		local u = toMe / d
		m.away += (-(v:Dot(u) / sp) - m.away) * a
		m.bias += (v:Dot(perp(u)) / sp - m.bias) * a
	end
	if m.lastVel and sp > 3 and m.lastVel.Magnitude > 3 then
		local sharp = (v.Unit:Dot(m.lastVel.Unit) < 0.5) and 1 or 0
		m.erratic += (sharp - m.erratic) * a
	end
	m.lastVel = v

	local air = hum.FloorMaterial == Enum.Material.Air
	if air and not m.air and hrp.AssemblyLinearVelocity.Y > 15 then m.jumps += 1 end
	m.air = air
	return m
end

local function profileText(plr)
	local m = plr and Memory[plr.UserId]
	if not m or m.time < 3 then return "يتعلم أسلوبه..." end
	local p = {}
	if m.bias > 0.25 then p[#p + 1] = "يلف يمينه" elseif m.bias < -0.25 then p[#p + 1] = "يلف يساره" end
	if m.jumps / math.max(m.time, 6) > 0.3 then p[#p + 1] = "يقفز كثير" end
	if m.erratic > 0.25 then p[#p + 1] = "متقلب" end
	if m.stop > 0.4 then p[#p + 1] = "يوقف كثير" end
	if m.speed > 15 then p[#p + 1] = "سريع" end
	if m.away > 0.3 then p[#p + 1] = "يهرب" elseif m.away < -0.3 then p[#p + 1] = "هجومي" end
	if #p == 0 then return "أسلوب متوازن" end
	return table.concat(p, " • ")
end

--------------------------------------------------------------------
-- حساب الوقت
--------------------------------------------------------------------
local function urgencyOf(tleft)
	if not Config.TimeAware or not tleft then return 0.35 end
	local u = math.clamp(1 - tleft / math.max(State.peak, 10), 0, 1)
	if tleft <= Config.UrgentTime then u = math.max(u, 0.88) end
	return u
end

local function updatePeak(t)
	if not t then return end
	if t > State.peak or t > State.lastHT + 1.5 then State.peak = t end
	State.lastHT = t
end

--------------------------------------------------------------------
-- 2) Shift Lock الذكي + تتبع الكاميرا
--------------------------------------------------------------------
local savedAutoRotate = nil

local function needShiftLockNow()
	if not Config.ShiftLock then return false end
	if hasBomb(LP) then
		local urgentPass = State.myTime ~= nil and State.myTime <= Config.UrgentTime
		if State.target and (State.targetDist <= Config.PassRange or urgentPass) then return true end
	else
		local urgentTimer = State.threatTime ~= nil and State.threatTime <= Config.UrgentTime
		if State.threat and (State.approaching or State.threatDist < Config.FleeRange or urgentTimer) then return true end
	end
	return false
end

local function restoreShiftLockState()
	if savedAutoRotate ~= nil then
		local _, _, hum = getCharacterParts(LP)
		if hum then hum.AutoRotate = savedAutoRotate end
		savedAutoRotate = nil
	end
end

local function updateShiftLock()
	local _, hrp, hum = getCharacterParts(LP)
	if not hrp or not hum then return end
	if needShiftLockNow() then
		if savedAutoRotate == nil then savedAutoRotate = hum.AutoRotate end
		hum.AutoRotate = false
		local cam = Workspace.CurrentCamera
		local f = cam and flat(cam.CFrame.LookVector) or Vector3.zero
		if f.Magnitude > 0.01 then
			hrp.CFrame = hrp.CFrame:Lerp(CFrame.new(hrp.Position, hrp.Position + f.Unit), 0.25)
		end
	else
		restoreShiftLockState()
	end
end

local function camTrack()
	if not (Config.CamTrack and Config.AI) or not State.focus then return end
	if State.focusDist > 35 then return end
	local cam = Workspace.CurrentCamera
	if not cam then return end
	cam.CFrame = cam.CFrame:Lerp(CFrame.new(cam.CFrame.Position, State.focus), 0.18)
end

--------------------------------------------------------------------
-- مسح اللاعبين + اختيار الهدف الأذكى للتمرير
--------------------------------------------------------------------
local function clearState()
	State.target, State.targetDist, State.targetMem, State.targetEdge = nil, math.huge, nil, nil
	State.threat, State.threatDist, State.threatMem = nil, math.huge, nil
	State.approaching, State.threatTime, State.myTime = false, nil, nil
	State.focus, State.focusDist = nil, math.huge
	State.dots = {}
end

local function chooseTarget(cands, myHum)
	State.stalk = nil
	if #cands == 0 then return nil end
	local u = urgencyOf(State.myTime)
	local speed = math.max(myHum and myHum.WalkSpeed or 16, 16)
	local jmpOK = myHum ~= nil and canJump(myHum)
	local best, bestScore
	local _, mh = getCharacterParts(LP)
	local myY = mh and mh.Position.Y or 0
	for _, c in ipairs(cands) do
		local s
		local rem = immuneRemaining(c.plr)
		if rem > 0 and c.d / speed < rem and not (State.myTime and State.myTime <= rem) then
			if not State.stalk or c.d < State.stalk.d then State.stalk = c end
			continue
		end
		if u > 0.65 then
			s = -c.d * 2.4 - c.m.erratic * 2
		else
			s = -c.d * 1.25
			if Config.EdgeAI then
				local cell = cellAt(c.hrp.Position)
				if cell and cell.walk then
					c.edge = cell.edge
					s += (24 - math.min(cell.edge, 24)) * 0.35
					if cell.corner then s += 14 end
				end
			end
			if Config.Memory and c.m.time > 3 then
				s += -c.m.speed * 0.45 - c.m.erratic * 7 - (c.m.jumps / math.max(c.m.time, 6)) * 6 + c.m.stop * 10
			end
		end
		if Config.TimeAware and State.myTime then
			local eta = c.d / speed
			if eta > State.myTime * 0.85 then s -= (eta - State.myTime * 0.85) * 12 end
		end
		s -= math.max(c.hrp.Position.Y - myY, 0) * ((jmpOK and Config.Climb) and 0.25 or 0.8)
		if State.lockedTarget == c.plr then s += 8 end
		if not best or s > bestScore then best, bestScore = c, s end
	end
	if not best then return nil end
	State.lockedTarget = best.plr
	return best
end

local function scanPlayers()
	clearState()
	local _, myHrp, myHum = getCharacterParts(LP)
	if not myHrp then return end

	local floor = getFloorPart(LP)
	State.arenaCenter = (floor and floor.Size.Magnitude > 40) and Vector3.new(floor.Position.X, myHrp.Position.Y, floor.Position.Z) or nil

	local iHave = hasBomb(LP)
	if iHave then State.myTime = getRemainingBombTime(LP) end

	local cands, enemies = {}, {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if not isTeammate(plr) and isInSameArena(plr) then
			local _, hrp, hum = getCharacterParts(plr)
			if hrp and hum then
				local m = updateMemory(plr, hrp, hum, myHrp.Position)
				local d = flat(hrp.Position - myHrp.Position).Magnitude
				local theirBomb = hasBomb(plr)
				enemies[#enemies + 1] = { plr = plr, hrp = hrp }
				if iHave then
					if not theirBomb then cands[#cands + 1] = { plr = plr, hrp = hrp, hum = hum, d = d, m = m } end
				elseif theirBomb and d < State.threatDist then
					State.threat, State.threatDist, State.threatMem = plr, d, m
					local toMe = flat(myHrp.Position - hrp.Position)
					if toMe.Magnitude > 0.1 then
						State.approaching = toMe.Unit:Dot(hrp.AssemblyLinearVelocity) > 7.5
					end
				end
			end
		end
	end

	if iHave then
		local best = chooseTarget(cands, myHum)
		if best then
			State.target, State.targetDist, State.targetMem, State.targetEdge = best.plr, best.d, best.m, best.edge
			State.focus, State.focusDist = best.hrp.Position, best.d
		end
		updatePeak(State.myTime)
	elseif State.threat then
		State.lastThreat, State.lastThreatT = State.threat, now()
		State.threatTime = getRemainingBombTime(State.threat)
		updatePeak(State.threatTime)
		local _, h = getCharacterParts(State.threat)
		if h then State.focus, State.focusDist = h.Position, State.threatDist end
	end

	State.dots[1] = { pos = myHrp.Position, kind = "me" }
	for _, e in ipairs(enemies) do
		local kind = (e.plr == State.target and "target") or (e.plr == State.threat and "threat") or "other"
		State.dots[#State.dots + 1] = { pos = e.hrp.Position, kind = kind }
	end
end

--------------------------------------------------------------------
-- هروب أذكى (يستفيد من خريطة الحافات)
--------------------------------------------------------------------
local EDGE_OFFS = { Vector3.new(6, 0, 0), Vector3.new(-6, 0, 0), Vector3.new(0, 0, 6), Vector3.new(0, 0, -6) }

local function bestEscapePoint(hrp, thrp)
	if Style.cache and now() - Style.cacheT < 0.2 then return Style.cache end
	local tp = thrp.Position + flat(thrp.AssemblyLinearVelocity) * 0.5
	local toThreat = unit(flat(tp - hrp.Position))
	local center = getCenter()
	local best, bestScore = nil, -math.huge

	for i = 0, 15 do
		local ang = i * math.pi / 8
		local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local p = hrp.Position + dir * 14
		local cell = Config.EdgeAI and cellAt(p) or nil
		local score
		if not hasFloorAt(p) or (cell and not cell.walk) then
			score = -1e6
		else
			score = 0
			if cell then
				score += math.min(cell.edge, 24) * 0.9 + cell.open * 10
				if cell.corner then score -= 30 end
				local far = cellAt(hrp.Position + dir * 28)
				if far then score += far.walk and 4 or -8 end
			else
				for _, o in ipairs(EDGE_OFFS) do
					if hasFloorAt(p + o) then score += 5 end
				end
			end
			score += flat(p - tp).Magnitude * 1.5
			if center then score -= flat(p - center).Magnitude * 0.15 end
			local towards = dir:Dot(toThreat)
			if towards > 0.2 then score -= towards * 25 end
			score += rng:NextNumber(0, 4)
			if Config.Nav and not clearLine(hrp.Position, p) then score -= 200 end
		end
		if score > bestScore then best, bestScore = p, score end
	end

	best = best or (hrp.Position + unit(flat(hrp.Position - thrp.Position)) * 10)
	Style.cache, Style.cacheT = best, now()
	return best
end

--------------------------------------------------------------------
-- المراوغات والمطاردة للتمرير (مهارات كثيرة + ملاحة + قفز)
--------------------------------------------------------------------
local function pickWeighted(list)
	local sum = 0
	for _, e in ipairs(list) do sum += e[2] end
	local r = rng:NextNumber() * sum
	for _, e in ipairs(list) do
		r -= e[2]
		if r <= 0 then return e[1] end
	end
	return list[#list][1]
end

local FLEE_DUR = {
	smart = { 0.6, 1.4 }, zigzag = { 1.0, 2.0 }, circle = { 1.0, 2.0 }, feint = { 0.7, 0.7 },
	brake = { 0.6, 0.6 }, kite = { 1.0, 2.0 }, juke = { 0.9, 0.9 }, pillar = { 1.2, 2.5 },
	weave = { 1.0, 1.8 }, snake = { 0.9, 1.6 }, spiral = { 1.0, 1.8 }, stopgo = { 0.8, 0.8 },
	loop = { 1.5, 2.5 }, dash = { 0.6, 0.9 }, cutback = { 0.9, 0.9 },
	bhop = { 1.0, 1.8 }, hop = { 1.2, 1.2 }, jumpjuke = { 0.9, 0.9 }, hopcircle = { 1.2, 2.0 },
	leap = { 1.0, 1.6 }, jumpfeint = { 0.8, 0.8 }, zigjump = { 1.0, 1.8 }, doublehop = { 1.0, 1.0 },
	phantom = { 0.9, 1.0 }, figure8 = { 1.4, 2.4 }, ghost = { 0.8, 1.4 }, sidewinder = { 1.2, 2.0 }, snapback = { 1.0, 1.6 },
	airstrafe = { 1.2, 2.0 }, skydance = { 1.0, 1.1 }, ladder = { 3.5, 4.5 },
}

local function pickFleeStyle(ctx, d, forceSide, m)
	local t = now()
	local k = 1.5 - Config.Aggro
	local uh = urgencyOf(State.threatTime)
	Style.mode, Style.phaseT, Style.cache, Style.data, Style.nextJump = "flee", t, nil, nil, 0
	Style.dir = rng:NextInteger(0, 1) == 0 and 1 or -1
	Style.period = rng:NextNumber(0.25, 0.6)
	local dur

	if forceSide then
		Style.name, dur = "sidestep", rng:NextNumber(0.3, 0.5)
		Style.lastSide = t
		if Config.Memory and m and m.time > 3 and math.abs(m.bias) > 0.2 then
			Style.dir = (m.bias > 0) and -1 or 1
		end
	else
		local last2 = State.threatTime ~= nil and State.threatTime <= 2.5
		local pillar = Config.Parkour and findPillar(ctx.hrp) or nil
		local jmp = Config.JumpDodge and Config.JumpRate > 0.01 and canJump(ctx.hum)
		local ledge = (jmp and Config.Parkour) and findLedge(ctx.hrp, ctx.hum, ctx.thrp) or nil
		local jw = Config.JumpRate * 2
		local list = {}
		local function add(name, w) list[#list + 1] = { name, w } end
		local function addJ(name, w) if jmp then add(name, w * jw) end end
		local hasCenter = getCenter() ~= nil

		local trussPick
		if Config.Ladder and d > 6 then
			local fy = ctx.hrp.Position.Y - (ctx.hum.HipHeight + ctx.hrp.Size.Y / 2)
			local tr = LG.pickTruss(ctx.hrp.Position, fy, fy + 25, 35)
			if tr and flat(tr.Position - ctx.thrp.Position).Magnitude > flat(tr.Position - ctx.hrp.Position).Magnitude + 5 then
				trussPick = tr
			end
		end
		local function addL(w) if trussPick then add("ladder", w) end end

		if last2 then
			add("kite", 3); add("juke", 2); add("sidestep", 1); add("dash", 1.5); add("cutback", 1.5)
			if pillar then add("pillar", 2) end
			if ledge then add("hop", 2 * jw) end
			addJ("jumpjuke", 2); addJ("leap", 2)
			add("phantom", 2); add("sidewinder", 2); add("snapback", 2)
			addJ("skydance", 2); addJ("airstrafe", 1.5); addL(1.5)
		elseif Config.TimeAware and uh > 0.7 then
			add("kite", 2); add("zigzag", 1.2); add("circle", 1); add("juke", 1.5)
			add("weave", 1); add("spiral", 1); add("dash", 1.2); add("stopgo", 0.8)
			if d > 9 then add("feint", 1.2) end
			if pillar then add("pillar", 2) end
			if ledge then add("hop", 1.5 * jw) end
			addJ("bhop", 1); addJ("jumpjuke", 1.5); addJ("zigjump", 1.2); addJ("doublehop", 1.2); addJ("leap", 1)
			add("phantom", 1.5); add("sidewinder", 1.5); add("ghost", 1); add("snapback", 1.5)
			addJ("skydance", 1.5); addJ("airstrafe", 1.2); addL(2)
		elseif Config.TimeAware and uh < 0.3 and d > 12 then
			add("smart", 3); add("kite", 2.5); add("circle", 1); add("weave", 1); add("snake", 1)
			if hasCenter then add("loop", 1.5) end
			if pillar then add("pillar", 1.5) end
			addJ("hopcircle", 1); addJ("bhop", 0.8)
			add("figure8", 1); add("sidewinder", 0.8); addL(1)
		else
			add("smart", 2); add("zigzag", 1.4); add("circle", 1.2); add("brake", 0.8); add("kite", 1)
			add("juke", 0.8); add("weave", 1.2); add("snake", 1); add("spiral", 1); add("stopgo", 0.8)
			add("dash", 1); add("cutback", 1)
			if hasCenter then add("loop", 1) end
			if d > 9 then add("feint", 1) end
			if pillar then add("pillar", 1.4) end
			if ledge then add("hop", 1 * jw) end
			addJ("bhop", 0.8); addJ("jumpjuke", 1); addJ("hopcircle", 1); addJ("zigjump", 1)
			addJ("leap", 1); addJ("doublehop", 1)
			if d > 9 then addJ("jumpfeint", 1) end
			add("phantom", 1.2); add("figure8", 1); add("ghost", 0.8); add("sidewinder", 1.2); add("snapback", 1)
			addJ("airstrafe", 1); addJ("skydance", 1); addL(1.2)
		end
		if Config.Memory and m and m.erratic > 0.3 then add("smart", 2) end

		Style.name = pickWeighted(list)
		if Style.name == "sidestep" then Style.lastSide = t end
		if Style.name == "pillar" then Style.data = pillar
		elseif Style.name == "hop" then Style.data = ledge
		elseif Style.name == "ladder" then Style.data = trussPick end
		local dr = FLEE_DUR[Style.name] or { 0.6, 1.2 }
		dur = rng:NextNumber(dr[1], dr[2])
		if last2 then dur *= 0.6 end
	end
	Style.untilT = t + dur * k
end

local function fleePoint(hrp, hum, thrp, d)
	local pos = hrp.Position
	local away = unit(flat(pos - thrp.Position))
	local el = now() - Style.phaseT
	local n = Style.name
	local p

	if n == "smart" then
		return bestEscapePoint(hrp, thrp)
	elseif n == "zigzag" then
		local side = (math.floor(el / Style.period) % 2 == 0) and 1 or -1
		p = pos + unit(away + perp(away) * side * 1.1) * 12
	elseif n == "circle" then
		p = pos + unit(perp(away) * Style.dir + away * 0.35) * 12
	elseif n == "feint" then
		if el < 0.25 then
			p = pos + unit(perp(away) * Style.dir - away * 0.4) * 10
		else
			p = pos + unit(perp(away) * -Style.dir + away * 0.9) * 14
		end
	elseif n == "brake" then
		if el < 0.22 then return pos end
		return bestEscapePoint(hrp, thrp)
	elseif n == "sidestep" then
		local v = unit(flat(thrp.AssemblyLinearVelocity))
		p = pos + unit(perp(v) * Style.dir + away * 0.4) * 12
	elseif n == "kite" then
		local rot = rotate(away, 35 * Style.dir)
		local q = thrp.Position + unit(rot) * 20
		p = Vector3.new(q.X, pos.Y, q.Z)
	elseif n == "juke" then
		local side
		if el < 0.15 then side = 1 elseif el < 0.3 then side = -1 elseif el < 0.45 then side = 1 end
		if side then
			p = pos + unit(perp(away) * side * Style.dir + away * 0.3) * 10
		else
			p = pos + unit(perp(away) * -Style.dir + away) * 14
		end
	elseif n == "pillar" then
		local pl = Style.data
		if pl and pl.part and pl.part.Parent then
			local cp = coverPoint(hrp, thrp, pl)
			if hasFloorAt(cp) then return cp end
		end
		return bestEscapePoint(hrp, thrp)
	elseif n == "weave" then
		p = pos + unit(rotate(away, math.sin(el * (3.4 + Style.period * 4)) * 70)) * 12
	elseif n == "snake" then
		p = pos + unit(rotate(away, math.sin(el * 9) * 45)) * 12
	elseif n == "spiral" then
		local ang = math.clamp(25 + el * 70, 25, 110) * Style.dir
		p = pos + unit(rotate(away, ang)) * 12
	elseif n == "stopgo" then
		if el < 0.2 then
			p = pos + away * 8
		elseif el < 0.38 then
			return pos
		else
			p = pos + unit(perp(away) * Style.dir + away * 0.5) * 14
		end
	elseif n == "loop" then
		local center = getCenter()
		if not center then return bestEscapePoint(hrp, thrp) end
		local toC = flat(center - pos)
		if toC.Magnitude < 3 then return bestEscapePoint(hrp, thrp) end
		local tang = perp(unit(toC)) * Style.dir
		if tang:Dot(away) < 0 then tang = -tang end
		p = pos + unit(tang + unit(toC) * 0.35) * 13
	elseif n == "dash" then
		local v = flat(thrp.AssemblyLinearVelocity)
		local side = Style.dir
		if v.Magnitude > 3 then side = (v:Dot(perp(away)) > 0) and -1 or 1 end
		if el < 0.45 then
			p = pos + unit(away + perp(away) * side) * 14
		else
			p = pos + unit(away - perp(away) * side * 0.5) * 14
		end
	elseif n == "cutback" then
		if el < 0.35 then
			p = pos + away * 12
		else
			p = pos + unit(rotate(away, 110 * Style.dir)) * 12
		end
	elseif n == "bhop" then
		pulseJump(hum, 0.5)
		return bestEscapePoint(hrp, thrp)
	elseif n == "hop" then
		local lg = Style.data
		if lg then
			local lp = Vector3.new(lg.point.X, pos.Y, lg.point.Z)
			if flat(lp - pos).Magnitude < 2.5 then
				forceJump(hum)
				return pos + lg.dir * 8
			end
			return lp
		end
		return bestEscapePoint(hrp, thrp)
	elseif n == "jumpjuke" then
		local side
		if el < 0.15 then side = 1 elseif el < 0.3 then side = -1 elseif el < 0.45 then side = 1 end
		if side then
			p = pos + unit(perp(away) * side * Style.dir + away * 0.3) * 10
		else
			p = pos + unit(perp(away) * -Style.dir + away) * 14
		end
		pulseJump(hum, 0.45)
	elseif n == "hopcircle" then
		p = pos + unit(perp(away) * Style.dir + away * 0.35) * 12
		pulseJump(hum, 0.55)
	elseif n == "zigjump" then
		local side = (math.floor(el / Style.period) % 2 == 0) and 1 or -1
		p = pos + unit(away + perp(away) * side * 1.1) * 12
		pulseJump(hum, math.max(Style.period * 1.2, 0.4))
	elseif n == "doublehop" then
		local sgn = (el < 0.5) and 1 or -1
		p = pos + unit(away + perp(away) * sgn * Style.dir * 0.6) * 13
		pulseJump(hum, 0.4)
	elseif n == "leap" then
		if d < 9 and State.approaching then
			p = pos + unit(perp(away) * Style.dir + away * 0.7) * 13
			pulseJump(hum, 0.5)
		else
			return bestEscapePoint(hrp, thrp)
		end
	elseif n == "jumpfeint" then
		if el < 0.3 then
			p = pos + unit(perp(away) * Style.dir - away * 0.3) * 10
			pulseJump(hum, 0.5)
		else
			p = pos + unit(perp(away) * -Style.dir + away * 0.9) * 14
		end
	elseif n == "phantom" then
		if el < 0.22 then
			p = pos + unit(perp(away) * Style.dir + away * 0.5) * 10
		elseif el < 0.34 then
			return pos
		else
			p = pos + unit(perp(away) * -Style.dir + away * 0.8) * 15
		end
	elseif n == "figure8" then
		local s = (math.floor(el / 0.55) % 2 == 0) and 1 or -1
		p = pos + unit(perp(away) * s * Style.dir + away * 0.55) * 12
	elseif n == "ghost" then
		local s = math.sin(el * 13) >= 0 and 1 or -1
		p = pos + unit(away + perp(away) * s * 0.85) * 12
	elseif n == "sidewinder" then
		local tv = flat(thrp.AssemblyLinearVelocity)
		local ref = tv.Magnitude > 3 and tv.Unit or -away
		local s = (math.floor(el / 0.9) % 2 == 0) and 1 or -1
		local sd = perp(ref) * s * Style.dir
		if sd:Dot(away) < -0.2 then sd = -sd end
		p = pos + unit(sd + away * 0.4) * 12
	elseif n == "snapback" then
		if d > 10 then
			p = pos + away * 12
		else
			local tv = flat(thrp.AssemblyLinearVelocity)
			local side = Style.dir
			if tv.Magnitude > 3 then side = (tv:Dot(perp(away)) > 0) and -1 or 1 end
			p = pos + unit(rotate(away, 100 * side)) * 14
		end
	elseif n == "airstrafe" then
		local s = (math.floor(el / 0.46) % 2 == 0) and 1 or -1
		p = pos + unit(away + perp(away) * s * Style.dir) * 13
		pulseJump(hum, 0.46)
	elseif n == "skydance" then
		if el < 0.22 then
			p = pos + unit(perp(away) * Style.dir + away * 0.5) * 10
			pulseJump(hum, 0.3)
		elseif el < 0.34 then
			return pos
		else
			p = pos + unit(perp(away) * -Style.dir + away * 0.8) * 15
			pulseJump(hum, 0.3)
		end
	elseif n == "ladder" then
		local tr = Style.data
		if tr and tr.Parent and Config.Ladder then
			local top = tr.Position.Y + tr.Size.Y / 2
			LG.Ladder.part = tr
			if LG.trussStep(hrp, hum, Vector3.new(tr.Position.X, top + 3, tr.Position.Z)) then return nil end
		end
		return bestEscapePoint(hrp, thrp)
	else
		return bestEscapePoint(hrp, thrp)
	end

	local cell = Config.EdgeAI and cellAt(p) or nil
	if not hasFloorAt(p) or (cell and (not cell.walk or cell.corner)) then
		return bestEscapePoint(hrp, thrp)
	end
	return p
end

local function pickChaseStyle(hum, d, urg)
	local t = now()
	local k = 1.45 - Config.Aggro
	Style.mode, Style.phaseT, Style.data, Style.nextJump = "chase", t, nil, 0
	Style.dir = rng:NextInteger(0, 1) == 0 and 1 or -1
	local jmp = Config.JumpDodge and Config.JumpRate > 0.01 and canJump(hum)
	local jw = Config.JumpRate * 2
	local list
	if (d and d < 8.5) or (urg and urg > 0.65) then
		list = { { "intercept", 3.5 }, { "cutoff", 2.5 }, { "direct", 2.2 }, { "pin", 1.5 } }
		if jmp then list[#list + 1] = { "leapin", 1.2 * jw } end
	elseif Config.EdgeAI and State.targetEdge and State.targetEdge <= 16 then
		list = { { "pin", 3.2 }, { "intercept", 2.4 }, { "cutoff", 1.8 }, { "direct", 1.5 } }
	elseif (urg or 0) < 0.3 then
		list = {
			{ "intercept", 2.8 }, { "cutoff", 2.0 }, { "flank", 1.8 }, { "arc", 1.5 },
			{ "stutter", 1.0 }, { "mirror", 1.4 }, { "direct", 1.4 }, { "weave", 1.1 }, { "feint", 1.1 },
		}
		if jmp then
			list[#list + 1] = { "hopchase", 0.8 * jw }
			list[#list + 1] = { "hopflank", 0.9 * jw }
			list[#list + 1] = { "fakecut", 0.9 * jw }
			list[#list + 1] = { "leapin", 1.1 * jw }
		end
	else
		list = { { "intercept", 3.2 }, { "direct", 2.5 }, { "cutoff", 2.2 }, { "flank", 1.3 }, { "arc", 1.2 }, { "mirror", 1.0 } }
		if jmp then
			list[#list + 1] = { "hopchase", 0.8 * jw }
			list[#list + 1] = { "fakecut", 0.8 * jw }
			list[#list + 1] = { "leapin", 1.1 * jw }
		end
	end
	Style.name = pickWeighted(list)
	local dur = rng:NextNumber(0.65, 1.25)
	if Style.name == "feint" or Style.name == "bait" then dur = 0.55 end
	Style.untilT = t + math.max(0.35, dur * k)
end

local function computePassIntercept(hrp, hum, thrp, d, urg)
	local pos = hrp.Position
	local tpos = thrp.Position
	local tvel = flat(thrp.AssemblyLinearVelocity)
	local sp = math.max(hum.WalkSpeed, 16)
	local maxLead = (urg and urg > 0.65) and 0.45 or 0.72
	local rel = flat(tpos - pos)
	local a = tvel:Dot(tvel) - sp * sp
	local b = 2 * rel:Dot(tvel)
	local c = rel:Dot(rel)
	local tt
	if math.abs(a) < 1e-3 then
		if b < -1e-3 then tt = -c / b end
	else
		local disc = b * b - 4 * a * c
		if disc >= 0 then
			local sq = math.sqrt(disc)
			local t1, t2 = (-b - sq) / (2 * a), (-b + sq) / (2 * a)
			if t1 > 0 and t2 > 0 then tt = math.min(t1, t2) else tt = math.max(t1, t2) end
		end
	end
	if tt and tt > 0 then
		return tpos + tvel * math.clamp(tt, 0, maxLead)
	end
	return tpos + tvel * math.clamp(d / math.max(sp, 10), 0, maxLead)
end

local function chasePoint(hrp, hum, thrp, d, m, urg)
	local pos = hrp.Position
	local tpos = thrp.Position
	local tvel = flat(thrp.AssemblyLinearVelocity)
	local predicted = computePassIntercept(hrp, hum, thrp, d, urg)

	if d <= 7.5 or (urg and urg > 0.7) then
		return tpos + tvel * math.clamp(d / 20, 0, 0.25)
	end

	if Config.Memory and m and m.time > 3 then
		local uu = unit(flat(pos - tpos))
		predicted += perp(uu) * m.bias * 0.25 * math.min(m.speed, 18)
		if m.stop > 0.4 then predicted = tpos + (predicted - tpos) * 0.35 end
	end

	local el = now() - Style.phaseT
	local n = Style.name
	local toT = unit(flat(tpos - pos))

	if n == "flank" then
		local back = -unit(flat(thrp.CFrame.LookVector))
		if d > 8 then return predicted + back * 3.5 + perp(back) * Style.dir * 2 end
	elseif n == "cutoff" then
		return tpos + tvel * math.clamp(d / 12, 0.15, 0.75)
	elseif n == "feint" then
		if d > 9 and el < 0.2 then
			return pos + unit(perp(toT) * Style.dir + toT * 0.6) * 8
		end
	elseif n == "pin" then
		local center = getCenter()
		if center then
			local inward = unit(flat(center - tpos))
			local imInside = flat(center - pos).Magnitude < flat(center - tpos).Magnitude
			if imInside then return predicted + inward * 2 end
			return tpos + inward * 5 + perp(inward) * Style.dir * 3.5
		end
	elseif n == "stutter" then
		if (el % 0.6) < 0.1 and d > 10 then return pos + toT * 4 end
	elseif n == "mirror" then
		if d > 9 and el < 0.45 then
			local lat = tvel:Dot(perp(toT))
			local sgn = lat >= 0 and 1 or -1
			return pos + unit(toT * 0.75 + perp(toT) * sgn * 0.65) * 10
		end
	elseif n == "arc" then
		return predicted + perp(toT) * Style.dir * math.clamp(d * 0.28, 0, 4.5)
	elseif n == "bait" then
		if el < 0.22 and d > 10 then
			local q = pos - toT * 5
			if hasFloorAt(q) then return q end
		end
	elseif n == "weave" or n == "hopweave" then
		if n == "hopweave" and d > 7 then pulseJump(hum, 0.65) end
		if d > 7 then
			return predicted + perp(toT) * math.sin(el * 7) * math.clamp(d * 0.22, 0, 3)
		end
	elseif n == "ambush" then
		if el < 0.25 and d > 10 then return pos + toT * 5 end
	elseif n == "hopchase" then
		if d > 7 then pulseJump(hum, 0.6) end
	elseif n == "hopflank" then
		if d > 8 then
			pulseJump(hum, 0.7)
			local back = -unit(flat(thrp.CFrame.LookVector))
			return predicted + back * 3.5 + perp(back) * Style.dir * 2
		end
	elseif n == "leapin" then
		if d < 10 and d > 4 then pulseJump(hum, 0.55) end
	elseif n == "fakecut" then
		if d > 8 and el < 0.2 then
			pulseJump(hum, 0.3)
			return pos + unit(perp(toT) * Style.dir + toT * 0.6) * 8
		end
	end
	return predicted
end

--------------------------------------------------------------------
-- Reflex: ردة فعل خارقة (يشتغل كل فريم مو كل فترة)
--------------------------------------------------------------------
LG.Reflex = { untilT = 0, brakeUntil = 0, vec = Vector3.new(0, 0, 1), cd = 0, jump = false, jumped = false }

function LG.reflexTrigger(hrp, hum, thrp, m, dist)
	local t = now()
	local pos = hrp.Position
	local toMe = unit(flat(pos - thrp.Position))
	local tv = flat(thrp.AssemblyLinearVelocity)
	local ref = tv.Magnitude > 4 and tv.Unit or toMe
	local s1 = perp(ref)
	local lean = (Config.Memory and m and m.time > 3) and math.clamp(m.bias, -1, 1) or 0
	local cands = {
		{ s1, "snap" }, { -s1, "snap" },
		{ unit(s1 + toMe * 0.9), "slip" }, { unit(-s1 + toMe * 0.9), "slip" },
	}
	local best, bestScore
	for _, c in ipairs(cands) do
		local dir = c[1]
		local p = pos + dir * 9
		local score = rng:NextNumber(0, 1.5) + dir:Dot(toMe) * 1.5 - dir:Dot(perp(toMe)) * lean * 3
		if not hasFloorAt(p) then score -= 100 end
		local cell = Config.EdgeAI and cellAt(p) or nil
		if cell then
			if not cell.walk then score -= 100 end
			score += math.min(cell.edge, 24) * 0.12
			if cell.corner then score -= 4 end
		end
		if Config.Nav and not clearLine(pos, p) then score -= 60 end
		if not best or score > bestScore then best, bestScore = c, score end
	end
	LG.Reflex.vec = best[1]
	local dur = best[2] == "slip" and 0.34 or 0.26
	LG.Reflex.brakeUntil = 0
	if rng:NextNumber() < 0.22 and dist > 5 then
		LG.Reflex.brakeUntil = t + 0.07
		dur += 0.07
	end
	LG.Reflex.untilT = t + dur
	LG.Reflex.cd = t + dur + rng:NextNumber(0.12, 0.3)
	LG.Reflex.jump = Config.JumpDodge and canJump(hum) and rng:NextNumber() < math.clamp(Config.JumpRate * 0.9 + 0.15, 0, 1)
	LG.Reflex.jumped = false
	Style.name, Style.mode, Style.cache = "REFLEX " .. best[2], "flee", nil
	Style.untilT = LG.Reflex.untilT
	Stats.reflex += 1
end

function LG.reflexStep()
	if not (Config.Reflex and Config.AI) then return end
	local t = now()
	local _, hrp, hum = getCharacterParts(LP)
	if not hrp or not hum or hasBomb(LP) then
		LG.Reflex.untilT = 0
		return
	end
	if LG.Reflex.untilT > t then
		if t < LG.Reflex.brakeUntil then
			hum:MoveTo(hrp.Position)
		else
			hum:MoveTo(hrp.Position + LG.Reflex.vec * 10)
			if LG.Reflex.jump and not LG.Reflex.jumped then
				LG.Reflex.jumped = true
				forceJump(hum)
			end
		end
		return
	end
	local th = State.threat
	if not th or t < LG.Reflex.cd then return end
	local _, thrp = getCharacterParts(th)
	if not thrp then return end
	local rel = flat(hrp.Position - thrp.Position)
	local dist = rel.Magnitude
	if dist > 14 or dist < 0.1 then return end
	local toMe = rel / dist
	local tv = flat(thrp.AssemblyLinearVelocity)
	local mv = flat(hrp.AssemblyLinearVelocity)
	local closing = (tv - mv):Dot(toMe)
	local tti = closing > 5 and (dist - 3.4) / closing or math.huge
	local pursuing = tv.Magnitude > 6 and tv.Unit:Dot(toMe) > 0.55
	if (tti < Config.ReflexWindow and dist < 12) or (pursuing and dist < 6.5) then
		LG.reflexTrigger(hrp, hum, thrp, State.threatMem, dist)
	end
end

--------------------------------------------------------------------
-- Safe Zone: لما القنبلة بعيدة تروح لمكان مفتوح بعيد عن الزوايا والحافات
--------------------------------------------------------------------
LG.Idle = { point = nil, t = 0 }
function LG.safeZone(hrp, hum, th)
	local pos = hrp.Position
	local t = now()
	if t - LG.Idle.t > 1.2 then
		LG.Idle.t = t
		local thp
		if th then
			local _, h = getCharacterParts(th)
			thp = h and h.Position
		end
		local ci = math.floor((pos.X - Map.origin.X) / Map.step + 0.5)
		local cj = math.floor((pos.Z - Map.origin.Z) / Map.step + 0.5)
		local best, bs
		for i = ci - 4, ci + 4 do
			local row = Map.cells[i]
			if row then
				for j = cj - 4, cj + 4 do
					local c = row[j]
					if c and c.walk and not c.corner then
						local p = Vector3.new(Map.origin.X + i * Map.step, pos.Y, Map.origin.Z + j * Map.step)
						local s = math.min(c.edge, 24) * 1.2 + c.open * 8 - flat(p - pos).Magnitude * 0.35
						if thp then s += math.min(flat(p - thp).Magnitude, 50) * 0.5 end
						if not best or s > bs then best, bs = p, s end
					end
				end
			end
		end
		LG.Idle.point = best
	end
	local p = LG.Idle.point
	if p and flat(p - pos).Magnitude > 3 then
		steerMove(hrp, hum, p)
	else
		hum:MoveTo(pos)
	end
end

local function resetAI()
	Style.mode, Style.name, Style.untilT, Style.cache, Style.data, Style.nextJump = "", "", 0, nil, nil, 0
	State.peak, State.lastHT, State.lockedTarget = 0, 0, nil
	Jump.fails, Jump.blockedUntil = 0, 0
	climbCache = nil
	navReset()
	LG.Ladder.part, LG.Ladder.bad, LG.Ladder.list, LG.Ladder.listT, LG.Ladder.commitUntil = nil, {}, {}, -100, 0
	LG.Reflex.untilT, LG.Reflex.cd = 0, 0
	LG.Idle.point, LG.Idle.t = nil, 0
end

local function aiStep()
	local _, hrp, hum = getCharacterParts(LP)
	if not hrp or not hum then return end
	if hum.WalkSpeed > 0 and hum.WalkSpeed < 16 then hum.WalkSpeed = 16 end
	local t = now()
	local pos = hrp.Position

	if Config.Ladder and t - LG.Ladder.lastStep > 0.8 and hum:GetState() == Enum.HumanoidStateType.Climbing then
		hum.Jump = true
	end

	if hasBomb(LP) then
		local tg = State.target
		if not tg then
			local sk = State.stalk
			if sk then
				if Style.mode ~= "stalk" then
					Style.mode, Style.name = "stalk", "stalk"
					Style.dir = rng:NextInteger(0, 1) == 0 and 1 or -1
					Style.untilT = t + rng:NextNumber(1.5, 3)
				elseif t > Style.untilT then
					Style.dir = -Style.dir
					Style.untilT = t + rng:NextNumber(1.5, 3)
				end
				local away = unit(flat(pos - sk.hrp.Position))
				local rot = rotate(away, 30 * Style.dir)
				local p = sk.hrp.Position + unit(rot) * math.max(sk.d, 10)
				steerMove(hrp, hum, Vector3.new(p.X, pos.Y, p.Z))
			else
				hum:MoveTo(pos)
			end
			return
		end

		local _, thrp, thum = getCharacterParts(tg)
		if not thrp then return end
		local d = State.targetDist
		local u = urgencyOf(State.myTime)
		if Style.mode ~= "chase" or t > Style.untilT then pickChaseStyle(hum, d, u) end

		local p
		if d < 5.5 or u > 0.72 then
			p = thrp.Position + flat(thrp.AssemblyLinearVelocity) * math.clamp(d / 20, 0, 0.25)
		else
			p = chasePoint(hrp, hum, thrp, d, State.targetMem, u)
		end

		local dyT = thrp.Position.Y - pos.Y
		local standing = thum ~= nil and (thum.FloorMaterial ~= Enum.Material.Air or thum:GetState() == Enum.HumanoidStateType.Climbing)
		local climbing = Config.Climb and dyT > 2.5 and standing

		if climbing and climbMove(hrp, hum, thrp.Position) then
			-- تسلق
		elseif d <= 5.5 and clearLine(pos, thrp.Position) then
			hum:MoveTo(thrp.Position)
		elseif (p - pos).Magnitude < 0.35 then
			hum:MoveTo(p)
		else
			navMove(hrp, hum, p)
		end

		if Config.Parkour and dyT > 2 and dyT < jumpHeightOf(hum) + 1 and d < 6.5 then forceJump(hum) end
	else
		if LG.Reflex.untilT > t then return end
		local th = State.threat
		if not th or State.threatDist > Config.FleeRange + 14 then
			if Config.SafeZone and Map.ready then LG.safeZone(hrp, hum, th) else hum:MoveTo(pos) end
			return
		end
		local _, thrp = getCharacterParts(th)
		if not thrp then return end
		local d = State.threatDist
		local m = State.threatMem
		local uh = urgencyOf(State.threatTime)
		local last2 = State.threatTime ~= nil and State.threatTime <= 2.5
		local ctx = { hrp = hrp, hum = hum, thrp = thrp }

		if Style.mode ~= "flee" then pickFleeStyle(ctx, d, false, m) end

		local trig = 7
		if Config.TimeAware then trig += 5 * uh end
		if last2 then trig += 4 end
		if Config.Memory and m and m.away < -0.3 then trig += 2 end

		if d < trig and State.approaching and Style.name ~= "sidestep" and t - Style.lastSide > 0.6 then
			pickFleeStyle(ctx, d, true, m)
			if Config.JumpDodge then tryJump(hum, 0.7) end
		elseif t > Style.untilT then
			pickFleeStyle(ctx, d, false, m)
		end

		local fp = fleePoint(hrp, hum, thrp, d)
		if fp then steerMove(hrp, hum, fp) end
		if Config.JumpDodge and d < 10 then
			tryJump(hum, 0.12 * Config.Aggro + 0.2 * uh + (last2 and 0.25 or 0))
		end
	end
end

--------------------------------------------------------------------
-- Reach (تسليم القنبلة بسهولة)
--------------------------------------------------------------------
local lastReach = 0
local function reachStep()
	if now() - lastReach < 0.06 then return end
	local char, hrp, hum = getCharacterParts(LP)
	if not hrp then return end
	local bomb = findBombObject(LP)
	if not bomb then return end

	if bomb:IsA("Tool") and bomb.Parent ~= char and hum then
		pcall(function() hum:EquipTool(bomb) end)
	end

	local range = Config.ReachDistance
	if Config.TimeAware and urgencyOf(State.myTime) > 0.6 then range *= 1.3 end

	local best, bestD
	for _, plr in ipairs(Players:GetPlayers()) do
		if not isTeammate(plr) and isInSameArena(plr) and not hasBomb(plr) and not isImmune(plr) then
			local tchar, thrp = getCharacterParts(plr)
			if tchar and thrp then
				local d = (thrp.Position - hrp.Position).Magnitude
				if d <= range and (not bestD or d < bestD) then best, bestD = { char = tchar, hrp = thrp }, d end
			end
		end
	end
	if not best then return end
	lastReach = now() + rng:NextNumber(0, 0.025)

	if bomb:IsA("Tool") then pcall(function() bomb:Activate() end) end
	if firetouchinterest then
		local srcPart = (bomb:IsA("Tool") and (bomb:FindFirstChild("Handle") or bomb:FindFirstChildWhichIsA("BasePart")))
			or (bomb:IsA("BasePart") and bomb)
			or hrp
		local targets = { best.hrp }
		local torso = best.char:FindFirstChild("UpperTorso") or best.char:FindFirstChild("Torso")
		if torso then targets[#targets + 1] = torso end
		for _, tp in ipairs(targets) do
			pcall(function()
				firetouchinterest(srcPart, tp, 0)
				firetouchinterest(srcPart, tp, 1)
			end)
		end
	end
end

--------------------------------------------------------------------
-- 3) الواجهة LEGEND UI v5
--------------------------------------------------------------------
local function tween(o, t, props)
	TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end
local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
	return c
end
local function addStroke(inst, color, thick, transp)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thick or 1
	s.Transparency = transp or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end
local function label(parent, text, size, color, font)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color
	l.Font = font or Enum.Font.Gotham
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Parent = parent
	return l
end
local function gradient(inst, c1, c2, rot)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, c1), ColorSequenceKeypoint.new(0.5, c2), ColorSequenceKeypoint.new(1, c1) })
	g.Rotation = rot or 0
	g.Parent = inst
	return g
end

local gui = Instance.new("ScreenGui")
gui.Name = "MatchPanelUI"
gui.ResetOnSpawn = false
gui.DisplayOrder = 999
local okParent = pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not okParent or not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end
for _, old in ipairs(gui.Parent:GetChildren()) do
	if old.Name == "MatchPanelUI" and old ~= gui then old:Destroy() end
end

local camera = Workspace.CurrentCamera
local vp = camera and camera.ViewportSize or Vector2.new(1280, 720)
local PANEL_W = 316
local HEAD_H = 46
local FULL_H = math.clamp(vp.Y - 70, 330, 480)
local FULL_SIZE, MINI_SIZE = UDim2.new(0, PANEL_W, 0, FULL_H), UDim2.new(0, PANEL_W, 0, HEAD_H)

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = MINI_SIZE
main.Position = UDim2.new(0, 14, 0.1, 0)
main.BackgroundColor3 = C.panel
main.BorderSizePixel = 0
main.ClipsDescendants = true
main.Active = true
main.Parent = gui
corner(main, 14)

local mainStroke = addStroke(main, Color3.new(1, 1, 1), 2, 0)
local strokeGrad = gradient(mainStroke, C.accent, C.accent2, 0)

local title = Instance.new("Frame")
title.Name = "Header"
title.Position = UDim2.new(0, 6, 0, 6)
title.Size = UDim2.new(1, -12, 0, 34)
title.BackgroundColor3 = Color3.new(1, 1, 1)
title.BorderSizePixel = 0
title.Parent = main
corner(title, 10)
local titleGrad = gradient(title, Color3.fromRGB(70, 45, 160), Color3.fromRGB(20, 100, 140), 0)

local titleLabel = label(title, "TIMEBOMB AI", 14, C.text, Enum.Font.GothamBlack)
titleLabel.Position = UDim2.new(0, 12, 0, 3)
titleLabel.Size = UDim2.new(1, -130, 0, 16)
local titleSub = label(title, "v6  ·  LEGEND+ EDITION", 9, Color3.fromRGB(190, 200, 255), Enum.Font.GothamMedium)
titleSub.Position = UDim2.new(0, 12, 0, 19)
titleSub.Size = UDim2.new(1, -130, 0, 12)

local function headBtn(xOffset, text, color)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 26, 0, 26)
	b.Position = UDim2.new(1, xOffset, 0.5, -13)
	b.BackgroundColor3 = color
	b.Text = text
	b.Font = Enum.Font.GothamBlack
	b.TextSize = 18
	b.TextColor3 = C.bg
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
	b.ZIndex = 3
	b.Parent = title
	corner(b, 8)
	return b
end
local minBtn = headBtn(-92, "-", C.warn)
local plusBtn = headBtn(-62, "+", C.good)
local closeBtn = headBtn(-32, "x", C.bad)

local body = Instance.new("Frame")
body.Name = "Body"
body.Position = UDim2.new(0, 0, 0, HEAD_H)
body.Size = UDim2.new(1, 0, 1, -HEAD_H)
body.BackgroundTransparency = 1
body.Parent = main

local meter = Instance.new("Frame")
meter.Position = UDim2.new(0, 8, 0, 2)
meter.Size = UDim2.new(1, -16, 0, 62)
meter.BackgroundColor3 = C.card
meter.BorderSizePixel = 0
meter.Parent = body
corner(meter, 10)
addStroke(meter, C.line, 1, 0)

local meterStrip = Instance.new("Frame")
meterStrip.Position = UDim2.new(0, 6, 0, 8)
meterStrip.Size = UDim2.new(0, 4, 1, -16)
meterStrip.BackgroundColor3 = C.good
meterStrip.BorderSizePixel = 0
meterStrip.Parent = meter
corner(meterStrip, 2)

local stateText = label(meter, "SAFE", 13, C.good, Enum.Font.GothamBlack)
stateText.Position = UDim2.new(0, 18, 0, 5)
stateText.Size = UDim2.new(1, -100, 0, 18)
local timeText = label(meter, "--", 16, C.text, Enum.Font.GothamBlack)
timeText.TextXAlignment = Enum.TextXAlignment.Right
timeText.Position = UDim2.new(1, -84, 0, 4)
timeText.Size = UDim2.new(0, 74, 0, 20)

local barTrack = Instance.new("Frame")
barTrack.Position = UDim2.new(0, 18, 0, 29)
barTrack.Size = UDim2.new(1, -30, 0, 8)
barTrack.BackgroundColor3 = C.bg
barTrack.BorderSizePixel = 0
barTrack.Parent = meter
corner(barTrack, 4)
local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = C.good
barFill.BorderSizePixel = 0
barFill.Parent = barTrack
corner(barFill, 4)

local infoText = label(meter, "STYLE: -  ·  URG: 0%  ·  JUMP: -", 10, C.sub, Enum.Font.GothamMedium)
infoText.Position = UDim2.new(0, 18, 0, 42)
infoText.Size = UDim2.new(1, -30, 0, 14)

setMeter = function(who, whoColor, tleft, urg, styleName)
	stateText.Text = who
	stateText.TextColor3 = whoColor
	timeText.Text = tleft and string.format("%.1fs", tleft) or "--"
	local col = urg < 0.5 and C.good:Lerp(C.warn, urg * 2) or C.warn:Lerp(C.bad, (urg - 0.5) * 2)
	timeText.TextColor3 = tleft and col or C.sub
	local ratio = tleft and math.clamp(tleft / math.max(State.peak, 10), 0, 1) or 0
	tween(barFill, 0.12, { Size = UDim2.new(ratio, 0, 1, 0), BackgroundColor3 = col })
	tween(meterStrip, 0.2, { BackgroundColor3 = whoColor })
	local _, _, mh = getCharacterParts(LP)
	local jtxt = (mh and canJump(mh)) and "ON" or "OFF"
	infoText.Text = string.format("STYLE: %s  ·  URG: %d%%  ·  JUMP: %s", styleName ~= "" and styleName or "-", math.floor(urg * 100), jtxt)
end

local toastBox = Instance.new("Frame")
toastBox.AnchorPoint = Vector2.new(0.5, 1)
toastBox.Position = UDim2.new(0.5, 0, 1, -8)
toastBox.Size = UDim2.new(1, -24, 0, 28)
toastBox.BackgroundColor3 = C.bg
toastBox.BackgroundTransparency = 1
toastBox.BorderSizePixel = 0
toastBox.ZIndex = 20
toastBox.Parent = body
corner(toastBox, 9)
local toastLabel = label(toastBox, "", 12, C.text, Enum.Font.GothamBold)
toastLabel.Size = UDim2.new(1, 0, 1, 0)
toastLabel.TextXAlignment = Enum.TextXAlignment.Center
toastLabel.TextTransparency = 1
toastLabel.ZIndex = 21
local toastToken = 0
toast = function(text, color)
	toastToken += 1
	local my = toastToken
	toastLabel.Text = text
	toastLabel.TextColor3 = color or C.text
	tween(toastBox, 0.15, { BackgroundTransparency = 0.1 })
	tween(toastLabel, 0.15, { TextTransparency = 0 })
	task.delay(2, function()
		if my == toastToken and alive then
			tween(toastBox, 0.4, { BackgroundTransparency = 1 })
			tween(toastLabel, 0.4, { TextTransparency = 1 })
		end
	end)
end

local pages = {}
local order = 0
local function newPage()
	local p = Instance.new("ScrollingFrame")
	p.Position = UDim2.new(0, 6, 0, 108)
	p.Size = UDim2.new(1, -12, 1, -114)
	p.BackgroundTransparency = 1
	p.BorderSizePixel = 0
	p.ScrollBarThickness = 3
	p.ScrollBarImageColor3 = C.accent
	p.CanvasSize = UDim2.new()
	p.AutomaticCanvasSize = Enum.AutomaticSize.Y
	p.Visible = false
	p.Parent = body
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 6)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = p
	pages[#pages + 1] = p
	return p
end
local function newCard(page, h)
	order += 1
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, -6, 0, h)
	f.LayoutOrder = order
	f.BackgroundColor3 = C.card
	f.BorderSizePixel = 0
	f.Parent = page
	corner(f, 10)
	addStroke(f, C.line, 1, 0.3)
	return f
end
local function makeSection(page, text)
	order += 1
	local l = label(page, "  " .. text, 10, C.accent2, Enum.Font.GothamBold)
	l.Size = UDim2.new(1, -6, 0, 16)
	l.LayoutOrder = order
end

local pControl, pTuning, pRadar, pStats = newPage(), newPage(), newPage(), newPage()

local tabBar = Instance.new("Frame")
tabBar.Position = UDim2.new(0, 8, 0, 72)
tabBar.Size = UDim2.new(1, -16, 0, 30)
tabBar.BackgroundColor3 = C.bg
tabBar.BorderSizePixel = 0
tabBar.Parent = body
corner(tabBar, 9)

local tabInd = Instance.new("Frame")
tabInd.Size = UDim2.new(0.25, -4, 1, -6)
tabInd.Position = UDim2.new(0, 2, 0, 3)
tabInd.BackgroundColor3 = Color3.new(1, 1, 1)
tabInd.BorderSizePixel = 0
tabInd.Parent = tabBar
corner(tabInd, 7)
gradient(tabInd, C.accent, C.accent2, 0)

local tabNames = { "CONTROL", "TUNING", "RADAR", "STATS" }
local tabBtns = {}
local function selectTab(idx)
	for k, p in ipairs(pages) do p.Visible = (k == idx) end
	for k, b in ipairs(tabBtns) do
		b.TextColor3 = (k == idx) and Color3.new(1, 1, 1) or C.sub
	end
	tween(tabInd, 0.2, { Position = UDim2.new((idx - 1) * 0.25, 2, 0, 3) })
end
for i, name in ipairs(tabNames) do
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0.25, 0, 1, 0)
	b.Position = UDim2.new((i - 1) * 0.25, 0, 0, 0)
	b.BackgroundTransparency = 1
	b.Text = name
	b.Font = Enum.Font.GothamBold
	b.TextSize = 11
	b.TextColor3 = C.sub
	b.ZIndex = 2
	b.Parent = tabBar
	b.Activated:Connect(function() selectTab(i) end)
	tabBtns[i] = b
end

local function makeToggle(page, name, sub, key, onChange)
	local row = newCard(page, 46)
	local strip = Instance.new("Frame")
	strip.Size = UDim2.new(0, 3, 0, 26)
	strip.Position = UDim2.new(0, 0, 0.5, -13)
	strip.BorderSizePixel = 0
	strip.Parent = row
	corner(strip, 2)
	local l = label(row, name, 13, C.text, Enum.Font.GothamBold)
	l.Position = UDim2.new(0, 14, 0, 6)
	l.Size = UDim2.new(1, -76, 0, 18)
	local s = label(row, sub, 10, C.sub, Enum.Font.Gotham)
	s.Position = UDim2.new(0, 14, 0, 25)
	s.Size = UDim2.new(1, -76, 0, 14)

	local track = Instance.new("TextButton")
	track.Text = ""
	track.AutoButtonColor = false
	track.Size = UDim2.new(0, 44, 0, 22)
	track.Position = UDim2.new(1, -54, 0.5, -11)
	track.BorderSizePixel = 0
	track.Parent = row
	corner(track, 11)
	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 16, 0, 16)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.BorderSizePixel = 0
	knob.Parent = track
	corner(knob, 8)

	local function apply(animate)
		local on = Config[key]
		local pos = on and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
		local col = on and C.accent or C.off
		local scol = on and C.accent2 or C.off
		if animate then
			tween(knob, 0.15, { Position = pos })
			tween(track, 0.15, { BackgroundColor3 = col })
			tween(strip, 0.15, { BackgroundColor3 = scol })
		else
			knob.Position, track.BackgroundColor3, strip.BackgroundColor3 = pos, col, scol
		end
	end
	apply(false)
	Refreshers[key] = function() apply(true) end
	track.Activated:Connect(function()
		Config[key] = not Config[key]
		if onChange then onChange(Config[key]) end
		apply(true)
	end)
end

local function makeSlider(page, name, key, minV, maxV, fmt)
	local row = newCard(page, 50)
	local l = label(row, name, 12, C.text, Enum.Font.GothamBold)
	l.Position = UDim2.new(0, 14, 0, 6)
	l.Size = UDim2.new(1, -100, 0, 16)
	local v = label(row, "", 12, C.accent2, Enum.Font.GothamBold)
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.Position = UDim2.new(1, -90, 0, 6)
	v.Size = UDim2.new(0, 78, 0, 16)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, -28, 0, 12)
	bar.Position = UDim2.new(0, 14, 0, 29)
	bar.BackgroundColor3 = C.bg
	bar.BorderSizePixel = 0
	bar.Parent = row
	corner(bar, 6)
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Color3.new(1, 1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	corner(fill, 6)
	gradient(fill, C.accent, C.accent2, 0)

	local function update()
		fill.Size = UDim2.new(math.clamp((Config[key] - minV) / (maxV - minV), 0, 1), 0, 1, 0)
		v.Text = fmt(Config[key])
	end
	update()

	local dragging = false
	local function setFromX(x)
		local a = math.clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
		Config[key] = minV + (maxV - minV) * a
		update()
	end
	bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			page.ScrollingEnabled = false
			setFromX(input.Position.X)
		end
	end)
	table.insert(connections, UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end))
	table.insert(connections, UIS.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			page.ScrollingEnabled = true
		end
	end))
end

local function makeButton(page, text, cb)
	local row = newCard(page, 36)
	row.BackgroundColor3 = Color3.new(1, 1, 1)
	gradient(row, C.accent, C.accent2, 0)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 1, 0)
	b.BackgroundTransparency = 1
	b.Text = text
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Parent = row
	b.Activated:Connect(cb)
end

--------------------------------------------------------------------
-- ESP: يكشف اللاعبين اللي معك بنفس الساحة فقط (يبين عندك انت)
--------------------------------------------------------------------
for _, old in ipairs(gui.Parent:GetChildren()) do
	if old.Name == "MatchPanelESP" then old:Destroy() end
end
LG.ESP = { items = {}, folder = nil, t = 0 }

function LG.espFolder()
	if LG.ESP.folder and LG.ESP.folder.Parent then return LG.ESP.folder end
	local f = Instance.new("Folder")
	f.Name = "MatchPanelESP"
	f.Parent = gui.Parent
	LG.ESP.folder = f
	return f
end

function LG.espDestroy(plr)
	local it = LG.ESP.items[plr]
	if it then
		pcall(function() it.hl:Destroy() end)
		pcall(function() it.bb:Destroy() end)
		LG.ESP.items[plr] = nil
	end
end

function LG.espClear()
	for plr in pairs(LG.ESP.items) do LG.espDestroy(plr) end
end

function LG.espCreate(char, hrp)
	local folder = LG.espFolder()
	local hl = Instance.new("Highlight")
	hl.Name = "ESPHL"
	hl.Adornee = char
	hl.FillTransparency = 0.7
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Parent = folder

	local bb = Instance.new("BillboardGui")
	bb.Name = "ESPBB"
	bb.Adornee = char:FindFirstChild("Head") or hrp
	bb.AlwaysOnTop = true
	bb.Size = UDim2.new(0, 150, 0, 34)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 2.8, 0)
	bb.Parent = folder

	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1, 0, 1, 0)
	tl.BackgroundTransparency = 1
	tl.Font = Enum.Font.GothamBold
	tl.TextSize = 12
	tl.TextStrokeTransparency = 0.3
	tl.TextColor3 = Color3.new(1, 1, 1)
	tl.Text = ""
	tl.Parent = bb
	return { char = char, hl = hl, bb = bb, tl = tl }
end

function LG.espStep()
	local t = now()
	if t - LG.ESP.t < 0.12 then return end
	LG.ESP.t = t
	if not Config.ESP then LG.espClear() return end
	local _, myHrp = getCharacterParts(LP)
	if not myHrp then LG.espClear() return end

	local seen = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LP and isInSameArena(plr) then
			local char, hrp = getCharacterParts(plr)
			if char then
				seen[plr] = true
				local it = LG.ESP.items[plr]
				if it and (it.char ~= char or not it.hl.Parent) then
					LG.espDestroy(plr)
					it = nil
				end
				if not it then
					it = LG.espCreate(char, hrp)
					LG.ESP.items[plr] = it
				end
				local holder = hasBomb(plr)
				local col = (holder and C.bad) or (plr == State.target and C.good) or C.accent2
				it.hl.FillColor, it.hl.OutlineColor = col, col
				it.tl.TextColor3 = col
				local dist = (hrp.Position - myHrp.Position).Magnitude
				local txt = string.format("%s\n%d m", plr.Name, dist)
				if holder then
					local tl = (plr == State.threat) and State.threatTime or nil
					txt = string.format("[BOMB%s] %s\n%d m", tl and string.format(" %.1fs", tl) or "", plr.Name, dist)
				end
				it.tl.Text = txt
			end
		end
	end
	for plr in pairs(LG.ESP.items) do
		if not seen[plr] then LG.espDestroy(plr) end
	end
end

--------------------------------------------------------------------
-- Outfit Copy: ينسخ ملابس لاعب ويطبقها عندك محلياً (ما أحد غيرك يشوفها)
--------------------------------------------------------------------
LG.Outfit = { items = nil, face = nil, backup = nil, busy = false, lastCheck = 0 }
LG.OUTFIT_CLASSES = { Shirt = true, Pants = true, ShirtGraphic = true, BodyColors = true, CharacterMesh = true }

function LG.isOutfitItem(c)
	return LG.OUTFIT_CLASSES[c.ClassName] == true or c:IsA("Accessory")
end

function LG.safeClone(inst)
	local ok, cl = pcall(function() return inst:Clone() end)
	return ok and cl or nil
end

function LG.outfitStrip(char, provided)
	if not LG.Outfit.backup then
		local b = Instance.new("Folder")
		for _, c in ipairs(char:GetChildren()) do
			if LG.isOutfitItem(c) and not c:GetAttribute("TB_Outfit") then
				local cl = LG.safeClone(c)
				if cl then cl.Parent = b end
			end
		end
		local head = char:FindFirstChild("Head")
		local face = head and head:FindFirstChild("face")
		local fcl = face and LG.safeClone(face)
		if fcl then
			fcl.Name = "__face"
			fcl.Parent = b
		end
		LG.Outfit.backup = b
	end
	for _, c in ipairs(char:GetChildren()) do
		if LG.isOutfitItem(c) and (c:IsA("Accessory") or provided[c.ClassName] or c:GetAttribute("TB_Outfit")) then
			c:Destroy()
		end
	end
end

function LG.putOutfit(char, hum)
	if not LG.Outfit.items then return end
	local provided = {}
	for _, it in ipairs(LG.Outfit.items) do provided[it.ClassName] = true end
	LG.outfitStrip(char, provided)
	for _, it in ipairs(LG.Outfit.items) do
		local c = LG.safeClone(it)
		if c then
			c:SetAttribute("TB_Outfit", true)
			if c:IsA("Accessory") then
				local h = c:FindFirstChild("Handle")
				if h and h:IsA("BasePart") then
					for _, w in ipairs(h:GetChildren()) do
						if w:IsA("Weld") or w:IsA("WeldConstraint") then w:Destroy() end
					end
					h.CanCollide, h.CanTouch, h.CanQuery, h.Massless = false, false, false, true
				end
				local ok = pcall(function() hum:AddAccessory(c) end)
				if not ok then c.Parent = char end
			else
				c.Parent = char
			end
		end
	end
	if LG.Outfit.face then
		local head = char:FindFirstChild("Head")
		if head then
			for _, d in ipairs(head:GetChildren()) do
				if d:IsA("Decal") and d.Name == "face" then d:Destroy() end
			end
			local f = LG.safeClone(LG.Outfit.face)
			if f then
				f.Name = "face"
				f:SetAttribute("TB_Outfit", true)
				f.Parent = head
			end
		end
	end
end

function LG.findServerPlayer(name)
	name = string.lower(name)
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and (string.lower(p.Name) == name or string.lower(p.DisplayName) == name) then return p end
	end
	return nil
end

function LG.snapshotOutfit(name)
	local items, face = {}, nil
	local function take(container, head)
		for _, c in ipairs(container:GetChildren()) do
			if LG.isOutfitItem(c) then
				local cl = LG.safeClone(c)
				if cl then items[#items + 1] = cl end
			end
		end
		if head then
			local d = head:FindFirstChild("face") or head:FindFirstChildOfClass("Decal")
			if d then face = LG.safeClone(d) end
		end
	end
	local plr = LG.findServerPlayer(name)
	if plr and plr.Character then
		take(plr.Character, plr.Character:FindFirstChild("Head"))
		return items, face, plr.Name
	end
	local uid = tonumber(name) or Players:GetUserIdFromNameAsync(name)
	local model = Players:GetCharacterAppearanceAsync(uid)
	take(model, model:FindFirstChild("Head"))
	model:Destroy()
	return items, face, name
end

function LG.applyOutfit(name)
	if LG.Outfit.busy then return end
	LG.Outfit.busy = true
	task.spawn(function()
		local ok = pcall(function()
			local items, face, who = LG.snapshotOutfit(name)
			if #items == 0 and not face then error("empty") end
			LG.Outfit.items, LG.Outfit.face = items, face
			local char, _, hum = getCharacterParts(LP)
			if char then LG.putOutfit(char, hum) end
			toast("OUTFIT COPIED  •  " .. who, C.good)
		end)
		if not ok then
			toast("OUTFIT FAILED  •  ما لقيت اللاعب", C.bad)
			if not LG.Outfit.items then
				Config.Outfit = false
				if Refreshers.Outfit then Refreshers.Outfit() end
			end
		end
		LG.Outfit.busy = false
	end)
end

function LG.ensureOutfit()
	if not (Config.Outfit and LG.Outfit.items) then return end
	local char, _, hum = getCharacterParts(LP)
	if not char then return end
	for _, c in ipairs(char:GetChildren()) do
		if c:GetAttribute("TB_Outfit") then return end
	end
	LG.putOutfit(char, hum)
end

function LG.restoreOutfit()
	local char = LP.Character
	if char then
		for _, c in ipairs(char:GetDescendants()) do
			if c:GetAttribute("TB_Outfit") then c:Destroy() end
		end
		if LG.Outfit.backup then
			local head = char:FindFirstChild("Head")
			local hum = char:FindFirstChildOfClass("Humanoid")
			for _, c in ipairs(LG.Outfit.backup:GetChildren()) do
				local cl = LG.safeClone(c)
				if cl then
					if cl.Name == "__face" then
						cl.Name = "face"
						if head then cl.Parent = head end
					elseif cl:IsA("Accessory") and hum then
						pcall(function() hum:AddAccessory(cl) end)
					else
						cl.Parent = char
					end
				end
			end
		end
	end
	LG.Outfit.items, LG.Outfit.face = nil, nil
	if LG.Outfit.backup then
		LG.Outfit.backup:Destroy()
		LG.Outfit.backup = nil
	end
end

-- صفحة التحكم
makeSection(pControl, "CORE")
makeToggle(pControl, "AI AUTO-PLAY", "لعب تلقائي كامل", "AI", function(on)
	if not on then
		local _, hrp, hum = getCharacterParts(LP)
		if hum and hrp then hum:MoveTo(hrp.Position) end
		resetAI()
	end
end)
makeToggle(pControl, "REACH", "تمرير القنبلة عن بعد", "Reach")
makeToggle(pControl, "AUTO RESTART", "يشتغل تلقائياً كل جولة", "AutoRestart")
makeSection(pControl, "CAMERA")
makeToggle(pControl, "SMART SHIFT LOCK", "تثبيت الاتجاه عند الحاجة فقط", "ShiftLock", function(on)
	if not on then restoreShiftLockState() end
end)
makeToggle(pControl, "CAMERA TRACK", "الكاميرا تتبع الهدف", "CamTrack")
makeSection(pControl, "BRAIN")
makeToggle(pControl, "TIME CALC", "حساب الوقت وتغيير الأسلوب", "TimeAware")
makeToggle(pControl, "EDGE ANALYSIS", "تحليل الحافات والزوايا", "EdgeAI")
makeToggle(pControl, "OPPONENT MEMORY", "يتعلم أسلوب كل خصم", "Memory")
makeSection(pControl, "MOVEMENT")
makeToggle(pControl, "SMART NAV", "يتجنب الجدران ويصعد بمسار", "Nav", function() navReset() end)
makeToggle(pControl, "PARKOUR", "قفز فوق الحواجز واختباء خلف الأعمدة", "Parkour")
makeToggle(pControl, "AUTO CLIMB", "يطلع فوق لو الخصم فوق", "Climb")
makeToggle(pControl, "JUMP DODGES", "مراوغات القفز (إذا الساحة تسمح)", "JumpDodge")
makeSection(pControl, "LEGEND  •  v6")
makeToggle(pControl, "ESP", "يكشف اللي معك بالساحة فقط", "ESP", function(on)
	if not on then LG.espClear() end
end)
makeToggle(pControl, "REFLEX", "ردة فعل خارقة لحظة وصول المطارد", "Reflex")
makeToggle(pControl, "LADDERS", "يتسلق السلالم لفوق", "Ladder", function()
	LG.Ladder.part, LG.Ladder.bad, LG.Ladder.commitUntil = nil, {}, 0
end)
makeToggle(pControl, "SAFE ZONE", "يتمركز بمكان آمن لما القنبلة بعيدة", "SafeZone")
makeSection(pControl, "OUTFIT")
makeToggle(pControl, "COPY OUTFIT", "ينسخ ملابسه ويبين عندك انت بس", "Outfit", function(on)
	if on then LG.applyOutfit(Config.OutfitUser) else LG.restoreOutfit() end
end)
LG.outCard = newCard(pControl, 40)
LG.outBox = Instance.new("TextBox")
LG.outBox.Size = UDim2.new(1, -20, 0, 26)
LG.outBox.Position = UDim2.new(0, 10, 0.5, -13)
LG.outBox.BackgroundColor3 = C.bg
LG.outBox.BorderSizePixel = 0
LG.outBox.Text = Config.OutfitUser
LG.outBox.PlaceholderText = "Roblox username"
LG.outBox.TextColor3 = C.text
LG.outBox.PlaceholderColor3 = C.sub
LG.outBox.Font = Enum.Font.GothamMedium
LG.outBox.TextSize = 12
LG.outBox.ClearTextOnFocus = false
LG.outBox.Parent = LG.outCard
corner(LG.outBox, 7)
LG.outBox.FocusLost:Connect(function()
	local nm = (string.gsub(LG.outBox.Text, "%s+", ""))
	if nm ~= "" and nm ~= Config.OutfitUser then
		Config.OutfitUser = nm
		if Config.Outfit then LG.applyOutfit(nm) end
	end
	LG.outBox.Text = Config.OutfitUser
end)

-- صفحة الضبط
makeSection(pTuning, "TUNING")
makeSlider(pTuning, "Reach Range", "ReachDistance", 6, 25, function(x) return string.format("%.0f", x) end)
makeSlider(pTuning, "Reaction Time", "Reaction", 0.02, 0.35, function(x) return string.format("%d ms", x * 1000) end)
makeSlider(pTuning, "Dodge Aggression", "Aggro", 0, 1, function(x) return string.format("%d%%", x * 100) end)
makeSlider(pTuning, "Jump Dodge Rate", "JumpRate", 0, 1, function(x) return string.format("%d%%", x * 100) end)
makeSlider(pTuning, "Reflex Window", "ReflexWindow", 0.25, 0.8, function(x) return string.format("%d ms", x * 1000) end)
makeSlider(pTuning, "Urgent Time", "UrgentTime", 2, 8, function(x) return string.format("%.1f s", x) end)
makeSlider(pTuning, "Tag-back Immunity", "Immunity", 0, 6, function(x) return string.format("%.1f s", x) end)
makeSection(pTuning, "TOOLS")
makeButton(pTuning, "RE-SCAN ARENA  •  إعادة تحليل الساحة", function()
	buildMap()
	Jump.fails, Jump.blockedUntil = 0, 0
	toast("Scanning arena...", C.accent2)
end)
makeButton(pTuning, "CLEAR MEMORY  •  مسح الذاكرة", function()
	Memory = {}
	toast("Memory cleared", C.warn)
end)

-- صفحة الرادار
local radarHolder = newCard(pRadar, 214)
local radar = Instance.new("Frame")
radar.Size = UDim2.new(0, 200, 0, 200)
radar.Position = UDim2.new(0.5, -100, 0.5, -100)
radar.BackgroundColor3 = C.bg
radar.BorderSizePixel = 0
radar.Parent = radarHolder
corner(radar, 8)
addStroke(radar, C.accent, 1, 0)
local radarCells = Instance.new("Frame")
radarCells.Size = UDim2.new(1, 0, 1, 0)
radarCells.BackgroundTransparency = 1
radarCells.Parent = radar

local function makeDot(color, size)
	local d = Instance.new("Frame")
	d.Size = UDim2.new(0, size, 0, size)
	d.BackgroundColor3 = color
	d.BorderSizePixel = 0
	d.Visible = false
	d.ZIndex = 5
	d.Parent = radar
	corner(d, size)
	return d
end
local dotMe, dotTarget, dotThreat = makeDot(Color3.new(1, 1, 1), 9), makeDot(C.good, 9), makeDot(C.bad, 9)
local dotPool = {}
for i = 1, 14 do dotPool[i] = makeDot(C.sub, 6) end

local legend = newCard(pRadar, 44)
local legendText = label(legend, "RED edge  ·  ORANGE near-edge  ·  PINK dead corner\nWHITE you  ·  GREEN target  ·  RED holder", 10, C.sub, Enum.Font.Gotham)
legendText.Position = UDim2.new(0, 12, 0, 5)
legendText.Size = UDim2.new(1, -24, 0, 34)
legendText.TextWrapped = true
legendText.TextTruncate = Enum.TextTruncate.None
legendText.TextYAlignment = Enum.TextYAlignment.Top

local profCard = newCard(pRadar, 72)
local profLabel = label(profCard, "OPPONENT PROFILE", 11, C.accent2, Enum.Font.GothamBold)
profLabel.Position = UDim2.new(0, 12, 0, 5)
profLabel.Size = UDim2.new(1, -24, 0, 14)
local profText = label(profCard, "-", 12, C.text, Enum.Font.GothamMedium)
profText.Position = UDim2.new(0, 12, 0, 22)
profText.Size = UDim2.new(1, -24, 0, 46)
profText.TextWrapped = true
profText.TextTruncate = Enum.TextTruncate.None
profText.TextYAlignment = Enum.TextYAlignment.Top

buildRadar = function()
	radarCells:ClearAllChildren()
	if not Map.ready then return end
	local n = Map.half * 2 + 1
	local cs = 1 / n
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local cell = Map.cells[i] and Map.cells[i][j]
			if cell and cell.walk then
				local f = Instance.new("Frame")
				f.BorderSizePixel = 0
				f.Size = UDim2.new(cs, 0, cs, 0)
				f.Position = UDim2.new(i * cs, 0, j * cs, 0)
				local col
				if cell.corner then col = C.corner
				elseif cell.edge <= Map.step * 1.2 then col = C.bad
				elseif cell.edge <= Map.step * 2.2 then col = C.warn
				else col = C.accent2:Lerp(C.bg, 0.6) end
				f.BackgroundColor3 = col
				f.Parent = radarCells
			end
		end
	end
end

local function placeDot(dot, pos)
	local n = Map.half * 2 + 1
	local gx = ((pos.X - Map.origin.X) / Map.step + 0.5) / n
	local gz = ((pos.Z - Map.origin.Z) / Map.step + 0.5) / n
	if gx < 0 or gx > 1 or gz < 0 or gz > 1 then dot.Visible = false return end
	local half = dot.Size.X.Offset / 2
	dot.Position = UDim2.new(gx, -half, gz, -half)
	dot.Visible = true
end

updateRadar = function()
	if not Map.ready or not pRadar.Visible then return end
	dotMe.Visible, dotTarget.Visible, dotThreat.Visible = false, false, false
	for _, d in ipairs(dotPool) do d.Visible = false end
	local k = 0
	for _, d in ipairs(State.dots) do
		if d.kind == "me" then placeDot(dotMe, d.pos)
		elseif d.kind == "target" then placeDot(dotTarget, d.pos)
		elseif d.kind == "threat" then placeDot(dotThreat, d.pos)
		else
			k += 1
			if dotPool[k] then placeDot(dotPool[k], d.pos) end
		end
	end
	local who = State.target or State.threat
	profText.Text = who and (who.Name .. "\n" .. profileText(who)) or "-"
end

-- صفحة الإحصائيات
local function makeStat(name)
	local row = newCard(pStats, 32)
	local l = label(row, name, 12, C.sub, Enum.Font.GothamMedium)
	l.Position = UDim2.new(0, 14, 0, 0)
	l.Size = UDim2.new(0.5, 0, 1, 0)
	local v = label(row, "0", 13, C.text, Enum.Font.GothamBold)
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.Position = UDim2.new(0.5, 0, 0, 0)
	v.Size = UDim2.new(0.5, -14, 1, 0)
	return v
end
local ST = {}
ST.rounds, ST.passes = makeStat("Rounds"), makeStat("Passes")
ST.jumps, ST.climbs, ST.jump = makeStat("Jumps"), makeStat("Climb hops"), makeStat("Jump in this arena")
ST.map, ST.tracked, ST.session = makeStat("Arena cells"), makeStat("Opponents tracked"), makeStat("Session")
ST.reflex = makeStat("Reflex dodges")

local collapsed = false
local collapseToken = 0

local function refreshHeadBtns()
	tween(minBtn, 0.15, { BackgroundTransparency = collapsed and 0.65 or 0 })
	tween(plusBtn, 0.15, { BackgroundTransparency = collapsed and 0 or 0.65 })
end

local function setCollapsed(state)
	if state == collapsed then return end
	collapsed = state
	collapseToken += 1
	local my = collapseToken
	refreshHeadBtns()
	if state then
		tween(main, 0.25, { Size = MINI_SIZE })
		task.delay(0.27, function()
			if my == collapseToken and collapsed then body.Visible = false end
		end)
	else
		body.Visible = true
		tween(main, 0.3, { Size = FULL_SIZE })
	end
end

minBtn.Activated:Connect(function() setCollapsed(true) end)
plusBtn.Activated:Connect(function() setCollapsed(false) end)
table.insert(connections, UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.RightShift then setCollapsed(not collapsed) end
end))

do
	local dragging, dragStart, startPos
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, main.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	table.insert(connections, UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.X.Offset + d.Y)
		end
	end))
end

local function shutdown()
	alive = false
	Map.gen += 1
	Config.AI, Config.Reach, Config.ShiftLock, Config.CamTrack = false, false, false, false
	restoreShiftLockState()
	pcall(function() RunService:UnbindFromRenderStep("TimebombAI") end)
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	pcall(LG.espClear)
	if LG.ESP.folder then pcall(function() LG.ESP.folder:Destroy() end) end
	pcall(LG.restoreOutfit)
	gui:Destroy()
end

local closeArmed = 0
closeBtn.Activated:Connect(function()
	if closeArmed > 0 and now() - closeArmed < 2 then
		shutdown()
		return
	end
	closeArmed = now()
	closeBtn.Text = "?"
	toast("Tap again to close  •  اضغط مرة ثانية للإغلاق", C.warn)
	task.delay(2, function()
		if alive and now() - closeArmed >= 1.9 then closeBtn.Text = "x" end
	end)
end)

selectTab(1)
refreshHeadBtns()
tween(main, 0.45, { Size = FULL_SIZE })

--------------------------------------------------------------------
-- الحلقات الرئيسية
--------------------------------------------------------------------
local acc, nextStep, wasInMatch, hadBomb, urgentShown, lastSlow = 0, 0.1, false, false, false, 0

table.insert(connections, RunService.Heartbeat:Connect(function(dt)
	if not alive then return end
	if Config.Reflex and Config.AI then pcall(LG.reflexStep) end
	acc += dt
	if acc < nextStep then return end
	acc = 0
	nextStep = Config.Reaction + rng:NextNumber(0, 0.01)

	local inMatch = isInMatch(LP)
	if now() - LG.Outfit.lastCheck > 1.5 then
		LG.Outfit.lastCheck = now()
		if Config.Outfit then pcall(LG.ensureOutfit) end
	end
	if inMatch ~= wasInMatch then
		wasInMatch = inMatch
		resetAI()
		if inMatch then
			Stats.rounds += 1
			task.delay(1.5, function() if alive then buildMap() end end)
		elseif not Config.AutoRestart then
			Config.AI, Config.Reach = false, false
			if Refreshers.AI then Refreshers.AI() end
			if Refreshers.Reach then Refreshers.Reach() end
		end
	end

	if not inMatch then
		clearState()
		pcall(LG.espClear)
		restoreShiftLockState()
		hadBomb = false
		setMeter(Config.AutoRestart and "WAITING / LOBBY" or "OUT OF ROUND", C.sub, nil, 0, "")
		return
	end

	if pcall(scanPlayers) then
		if Config.AI then pcall(aiStep) end
		if Config.Reach then pcall(reachStep) end
		pcall(LG.espStep)
	end
	if not hasBomb(LP) and not needShiftLockNow() then restoreShiftLockState() end

	local iHave = hasBomb(LP)
	if iHave and not hadBomb then
		local passer = State.lastThreat
		if not passer or now() - State.lastThreatT > 1.5 then passer = nearestEnemy(25) end
		if passer and Config.Immunity > 0 then Immune[passer.UserId] = now() + Config.Immunity end
		toast("YOU HAVE THE BOMB  •  القنبلة معك!", C.bad)
	elseif hadBomb and not iHave then
		Stats.passes += 1
		toast("BOMB PASSED  •  تم التمرير", C.good)
		urgentShown = false
	end
	hadBomb = iHave
	local urgMe = iHave and urgencyOf(State.myTime) or 0
	if iHave and urgMe > 0.8 and not urgentShown then
		urgentShown = true
		toast("URGENT  •  الوقت يخلص!", C.warn)
	end

	local holderTime = iHave and State.myTime or State.threatTime
	local urg = urgencyOf(holderTime)
	if iHave then
		setMeter("YOU HAVE THE BOMB", C.bad, holderTime, urg, Style.name)
	elseif State.threat then
		setMeter("BOMB: " .. State.threat.Name, C.warn, holderTime, urg, Style.name)
	else
		setMeter("SAFE", C.good, nil, 0, Style.name)
	end

	pcall(updateRadar)

	if now() - lastSlow > 1 then
		lastSlow = now()
		local n = 0
		for _ in pairs(Memory) do n += 1 end
		ST.rounds.Text = tostring(Stats.rounds)
		ST.passes.Text = tostring(Stats.passes)
		ST.jumps.Text = tostring(Stats.jumps)
		ST.climbs.Text = tostring(Stats.climbs)
		ST.reflex.Text = tostring(Stats.reflex)
		local _, _, mh = getCharacterParts(LP)
		local jok = mh ~= nil and canJump(mh)
		ST.jump.Text = jok and "YES" or "NO"
		ST.jump.TextColor3 = jok and C.good or C.bad
		ST.map.Text = Map.ready and tostring(Map.walk) or "—"
		ST.tracked.Text = tostring(n)
		local s = math.floor(now() - Stats.t0)
		ST.session.Text = string.format("%02d:%02d", math.floor(s / 60), s % 60)
	end
end))

RunService:BindToRenderStep("TimebombAI", Enum.RenderPriority.Camera.Value + 1, function()
	if not alive then return end
	local t = now()
	strokeGrad.Rotation = (t * 60) % 360
	titleGrad.Offset = Vector2.new(math.sin(t) * 0.15, 0)
	pcall(camTrack)
	if Config.ShiftLock then pcall(updateShiftLock) end
end)

table.insert(connections, LP.CharacterAdded:Connect(function()
	savedAutoRotate = nil
	if LG.Outfit.backup then
		LG.Outfit.backup:Destroy()
		LG.Outfit.backup = nil
	end
	resetAI()
end))

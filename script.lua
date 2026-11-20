--// TIMEBOMB AI v4 · LEGEND EDITION
--// Time Calc | Edge Analysis | Opponent Memory | Smart Flee | Dodge Skills | CamTrack | Radar UI
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

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
	Immunity = 2.5,     -- مدة حماية اللي مرر لك (ما تقدر ترجعها له)
	PassRange = 12,
	FleeRange = 16.5,
	ReachDistance = 14,
	Reaction = 0.1,
	Aggro = 0.6,
	UrgentTime = 4,
	YTolerance = 18,
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
local Style = { mode = "", name = "", untilT = 0, phaseT = 0, dir = 1, period = 0.4, cache = nil, cacheT = 0, lastSide = 0 }
local Stats = { rounds = 0, passes = 0, t0 = os.clock() }

local function now() return os.clock() end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function unit(v)
	if v.Magnitude < 1e-3 then return Vector3.new(0, 0, 1) end
	return v.Unit
end
local function perp(v) return Vector3.new(-v.Z, 0, v.X) end

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
	local char = plr.Character
	if char then
		for _, c in ipairs(char:GetChildren()) do
			if (c:IsA("Tool") or c:IsA("Model") or c:IsA("BasePart")) and nameIsBomb(c.Name) then return c end
		end
	end
	local bp = plr:FindFirstChildOfClass("Backpack")
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
	local char = plr.Character
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
	if math.abs(myHrp.Position.Y - hrp.Position.Y) > Config.YTolerance then return false end
	local f1, f2 = getFloorPart(LP), getFloorPart(plr)
	if f1 == f2 or f1.Parent == f2.Parent then return true end
	return (f1.Position - f2.Position).Magnitude < 80
end

local function hasFloorAt(p)
	rayParams.FilterDescendantsInstances = { LP.Character }
	local res = Workspace:Raycast(p + Vector3.new(0, 3, 0), Vector3.new(0, -40, 0), rayParams)
	return res ~= nil and not looksLikeLobby(res.Instance)
end

--------------------------------------------------------------------
-- العوائق والملاحة (Pathfinding) + القفز والتسلق + حماية التمرير
--------------------------------------------------------------------
local PathfindingService = game:GetService("PathfindingService")
local Immune = {} -- لاعبين ما تقدر تمرر لهم فوراً (بعد ما مرروا لك)

local function immuneRemaining(plr)
	local rem = (Immune[plr.UserId] or 0) - now()
	return rem > 0 and rem or 0
end

local function isImmune(plr)
	local rem = immuneRemaining(plr)
	if rem <= 0 then return false end
	if State.myTime and State.myTime <= rem then return false end -- ما بقي وقت: جرّب على أي حال
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

-- راي يتجاهل اللاعبين والأجزاء اللي ما فيها تصادم، ويوقف عند أي حاجز حقيقي (حتى الجدران الشفافة)
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

-- هل الطريق من نقطة لنقطة مفتوح (رجل + وسط + راس)؟
local function clearLine(from, to)
	local vec = to - from
	for _, h in ipairs({ -1.5, 0, 1.6 }) do
		local o = Vector3.new(from.X, from.Y + h, from.Z)
		if castHard(o, vec) then return false end
	end
	return true
end

local function jumpHeightOf(hum)
	if hum.UseJumpPower then
		local jp = hum.JumpPower
		return jp * jp / (2 * Workspace.Gravity)
	end
	return hum.JumpHeight
end

local lastJump = 0
local function forceJump(hum)
	if now() - lastJump < 0.35 then return end
	lastJump = now()
	hum.Jump = true
end

local function tryJump(hum, chance)
	if now() - lastJump > 0.9 and rng:NextNumber() < chance then
		lastJump = now()
		hum.Jump = true
	end
end

-- حاجز واطي قدامك تقدر تقفز فوقه؟
local function ledgeAhead(hrp, hum, dir)
	dir = unit(flat(dir))
	local feetY = hrp.Position.Y - (hum.HipHeight + hrp.Size.Y / 2)
	local px, pz = hrp.Position.X, hrp.Position.Z
	local low = castHard(Vector3.new(px, feetY + 0.8, pz), dir * 3.5)
	if not low then return false end
	local jh = math.max(jumpHeightOf(hum) - 0.6, 2)
	local high = castHard(Vector3.new(px, feetY + jh + 1.2, pz), dir * 3.5)
	return high == nil
end

-- أقرب اتجاه مفتوح للاتجاه المطلوب (يلف حول الجدران)
local STEER_ANGLES = { 0, 25, -25, 50, -50, 80, -80, 120, -120, 160 }
local function steerDir(hrp, dir, dist)
	dir = unit(flat(dir))
	dist = dist or 6
	for _, ang in ipairs(STEER_ANGLES) do
		local d = unit((CFrame.Angles(0, math.rad(ang), 0) * CFrame.new(dir)).Position)
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

-- كشف التعليق: إذا ما تحرك، يقفز ويتحرك جانباً ويعيد حساب المسار
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
	if Nav.computing or now() - Nav.lastT < 0.45 then return end
	Nav.computing, Nav.lastT = true, now()
	local from = hrp.Position
	task.spawn(function()
		local ok = pcall(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2.2, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = false, WaypointSpacing = 4,
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

-- حركة ذكية للمطاردة: تتجنب الجدران، تقفز على الحواجز الواطية، وتستخدم مسار للصعود والالتفاف
local function navMove(hrp, hum, goal)
	local pos = hrp.Position
	local to = goal - pos
	local flatD = flat(to).Magnitude
	if flatD < 0.5 then hum:MoveTo(pos) return end
	if stuckCheck(hrp, hum, to) then return end
	if not Config.Nav then hum:MoveTo(goal) return end

	local dirG = unit(flat(to))

	if Config.Parkour and flatD > 1.5 and ledgeAhead(hrp, hum, dirG) then
		forceJump(hum)
		hum:MoveTo(pos + dirG * 8)
		return
	end

	local dy = goal.Y - pos.Y
	local direct = math.abs(dy) < 4 and clearLine(pos, Vector3.new(goal.X, pos.Y, goal.Z))
	if direct then
		Nav.wps = nil
		local sd = steerDir(hrp, dirG, 7) or dirG
		hum:MoveTo(pos + sd * 10)
		return
	end

	-- في حاجز أو الهدف فوق: مسار
	if not Nav.wps or not Nav.goal or flat(Nav.goal - goal).Magnitude > 6 then
		navCompute(hrp, goal)
	end
	local wps = Nav.wps
	if wps then
		while wps[Nav.idx] and flat(wps[Nav.idx].Position - pos).Magnitude < 3.2 and math.abs(wps[Nav.idx].Position.Y - pos.Y) < 5 do
			Nav.idx += 1
		end
		local wp = wps[Nav.idx]
		if wp then
			if wp.Action == Enum.PathWaypointAction.Jump and flat(wp.Position - pos).Magnitude < 7 then forceJump(hum) end
			hum:MoveTo(wp.Position)
			return
		end
		Nav.wps = nil
	end

	-- ما في مسار جاهز: توجيه مباشر حول الحواجز
	local sd = steerDir(hrp, dirG, 8)
	if sd then
		hum:MoveTo(pos + sd * 10)
	else
		forceJump(hum)
		hum:MoveTo(pos + perp(dirG) * 8)
	end
end

-- حركة الهروب: توجيه حول الحواجز + قفز فوق الحواجز الواطية (باركور)
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

-- عمود/جدار قريب تختبئ وراه وتدور حوله
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

-- حافة/منصة قريبة تقدر تقفز عليها للهروب لفوق
local function findLedge(hrp, hum, thrp)
	local jh = math.max(jumpHeightOf(hum) - 0.6, 2)
	local feetY = hrp.Position.Y - (hum.HipHeight + hrp.Size.Y / 2)
	local px, pz = hrp.Position.X, hrp.Position.Z
	local best, bestScore
	for a = 0, 315, 45 do
		local dir = Vector3.new(math.cos(math.rad(a)), 0, math.sin(math.rad(a)))
		local low = castHard(Vector3.new(px, feetY + 0.8, pz), dir * 12)
		if low and low.Normal.Y < 0.5 and low.Distance > 1 then
			local high = castHard(Vector3.new(px, feetY + jh + 1.2, pz), dir * (low.Distance + 3))
			if not high then
				local topO = low.Position + dir * 2 + Vector3.new(0, jh + 3, 0)
				local top = castHard(topO, Vector3.new(0, -(jh + 3.8), 0))
				if top and top.Position.Y > feetY + 1.2 and top.Position.Y < feetY + jh + 0.3 then
					local score = (thrp and flat(low.Position - thrp.Position).Magnitude or 0) - low.Distance
					if not best or score > bestScore then
						best, bestScore = { point = low.Position - dir * 1.5, dir = dir }, score
					end
				end
			end
		end
	end
	return best
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
				local walk = res ~= nil and not looksLikeLobby(res.Instance) and math.abs(res.Position.Y - c.Y) < Config.YTolerance
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
			if not cell then return true end -- خارج الشبكة = مجهول (مو حافة)
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
		m.away += (-(v:Dot(u) / sp) - m.away) * a   -- +1 يهرب منّي / -1 يهجم
		m.bias += (v:Dot(perp(u)) / sp - m.bias) * a -- ميل جانبي
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
	if not Config.TimeAware or not tleft then return 0.3 end
	local u = math.clamp(1 - tleft / math.max(State.peak, 10), 0, 1)
	if tleft <= Config.UrgentTime then u = math.max(u, 0.85) end
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
	if not hrp then return end
	if needShiftLockNow() then
		if savedAutoRotate == nil then savedAutoRotate = hum.AutoRotate end
		hum.AutoRotate = false
		local f = flat(Workspace.CurrentCamera.CFrame.LookVector)
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
	cam.CFrame = cam.CFrame:Lerp(CFrame.new(cam.CFrame.Position, State.focus), 0.18)
end

--------------------------------------------------------------------
-- مسح اللاعبين + اختيار الهدف الأذكى
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
	local speed = math.max(myHum and myHum.WalkSpeed or 16, 8)
	local best, bestScore
	local _, mh = getCharacterParts(LP)
	local myY = mh and mh.Position.Y or 0
	for _, c in ipairs(cands) do
		local s
		local rem = immuneRemaining(c.plr)
		if rem > 0 and c.d / speed < rem and not (State.myTime and State.myTime <= rem) then
			-- محمي مؤقتاً: لا تروح له الحين، دوّر حوله
			if not State.stalk or c.d < State.stalk.d then State.stalk = c end
			continue
		end
		if u > 0.7 then
			-- وقت ضيق: أسرع هدف يوصله
			s = -c.d * 2 - c.m.erratic * 3
		else
			s = -c.d
			if Config.EdgeAI then
				local cell = cellAt(c.hrp.Position)
				if cell and cell.walk then
					c.edge = cell.edge
					s += (24 - math.min(cell.edge, 24)) * 0.4
					if cell.corner then s += 12 end
				end
			end
			if Config.Memory and c.m.time > 3 then
				s += -c.m.speed * 0.6 - c.m.erratic * 10 - (c.m.jumps / math.max(c.m.time, 6)) * 8 + c.m.stop * 8
			end
		end
		if Config.TimeAware and State.myTime then
			local eta = c.d / speed
			if eta > State.myTime * 0.9 then s -= (eta - State.myTime * 0.9) * 10 end
		end
		s -= math.max(c.hrp.Position.Y - myY, 0) * 0.6 -- الأهداف العالية أصعب
		if State.lockedTarget == c.plr then s += 6 end
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
					State.approaching = toMe.Unit:Dot(hrp.AssemblyLinearVelocity) > 8
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
				local far = cellAt(hrp.Position + dir * 28) -- نظرة مستقبلية: تجنب الطرق المسدودة
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
-- المراوغات والمطاردة (مهارات كثيرة + ملاحة)
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
	brake = { 0.6, 0.6 }, kite = { 1.0, 2.0 }, juke = { 0.9, 0.9 }, bhop = { 1.0, 1.8 },
	pillar = { 1.2, 2.5 }, hop = { 1.2, 1.2 },
}

local function pickFleeStyle(ctx, d, forceSide, m)
	local t = now()
	local k = 1.5 - Config.Aggro
	local uh = urgencyOf(State.threatTime)
	Style.mode, Style.phaseT, Style.cache, Style.data = "flee", t, nil, nil
	Style.dir = rng:NextInteger(0, 1) == 0 and 1 or -1
	Style.period = rng:NextNumber(0.25, 0.6)
	local dur

	if forceSide then
		Style.name, dur = "sidestep", rng:NextNumber(0.3, 0.5)
		Style.lastSide = t
		if Config.Memory and m and m.time > 3 and math.abs(m.bias) > 0.2 then
			Style.dir = (m.bias > 0) and -1 or 1 -- عكس ميله
		end
	else
		local last2 = State.threatTime ~= nil and State.threatTime <= 2.5
		local pillar = Config.Parkour and findPillar(ctx.hrp) or nil
		local ledge = Config.Parkour and findLedge(ctx.hrp, ctx.hum, ctx.thrp) or nil
		local list
		if last2 then
			-- آخر ثواني: لا تخليه يمررها لك
			list = { { "kite", 3 }, { "juke", 2 }, { "sidestep", 1 } }
			if pillar then list[#list + 1] = { "pillar", 2 } end
			if ledge then list[#list + 1] = { "hop", 2 } end
		elseif Config.TimeAware and uh > 0.7 then
			list = { { "kite", 2 }, { "zigzag", 1.2 }, { "circle", 1 }, { "juke", 1.5 }, { "bhop", 1 } }
			if d > 9 then list[#list + 1] = { "feint", 1.2 } end
			if pillar then list[#list + 1] = { "pillar", 2 } end
			if ledge then list[#list + 1] = { "hop", 1.5 } end
		elseif Config.TimeAware and uh < 0.3 and d > 12 then
			list = { { "smart", 3 }, { "kite", 2.5 }, { "circle", 1 } }
			if pillar then list[#list + 1] = { "pillar", 1.5 } end
		else
			list = { { "smart", 2 }, { "zigzag", 1.4 }, { "circle", 1.2 }, { "brake", 0.8 }, { "kite", 1 }, { "juke", 0.8 }, { "bhop", 0.8 } }
			if d > 9 then list[#list + 1] = { "feint", 1 } end
			if pillar then list[#list + 1] = { "pillar", 1.4 } end
			if ledge then list[#list + 1] = { "hop", 1 } end
		end
		if Config.Memory and m and m.erratic > 0.3 then list[#list + 1] = { "smart", 2 } end

		Style.name = pickWeighted(list)
		if Style.name == "sidestep" then Style.lastSide = t end
		if Style.name == "pillar" then Style.data = pillar elseif Style.name == "hop" then Style.data = ledge end
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
	elseif n == "bhop" then
		tryJump(hum, 0.9)
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
		-- يدور حوله بمسافة آمنة (برا مدى الريتش)
		local rot = (CFrame.Angles(0, math.rad(35 * Style.dir), 0) * CFrame.new(away)).Position
		local q = thrp.Position + unit(rot) * 20
		p = Vector3.new(q.X, pos.Y, q.Z)
	elseif n == "juke" then
		-- 3 قلبات سريعة ثم اندفاع جانبي
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
	elseif n == "hop" then
		local lg = Style.data
		if lg then
			local lp = Vector3.new(lg.point.X, pos.Y, lg.point.Z)
			if flat(lp - pos).Magnitude < 2.5 then return pos + lg.dir * 8 end
			return lp
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

local function pickChaseStyle()
	local t = now()
	local k = 1.5 - Config.Aggro
	Style.mode, Style.phaseT, Style.data = "chase", t, nil
	Style.dir = rng:NextInteger(0, 1) == 0 and 1 or -1
	local u = urgencyOf(State.myTime)
	local list
	if Config.EdgeAI and State.targetEdge and State.targetEdge <= 16 then
		list = { { "pin", 3 }, { "direct", 1 }, { "cutoff", 1 }, { "stutter", 0.6 } }
	elseif u < 0.3 then
		list = { { "flank", 2 }, { "feint", 2 }, { "cutoff", 1.5 }, { "arc", 1.5 }, { "bait", 1.2 }, { "stutter", 1.2 }, { "mirror", 1.5 }, { "hopchase", 0.8 }, { "direct", 1 } }
	else
		list = { { "direct", 3 }, { "cutoff", 2 }, { "flank", 1.2 }, { "arc", 1.2 }, { "feint", 1 }, { "mirror", 0.8 }, { "hopchase", 0.8 } }
	end
	Style.name = pickWeighted(list)
	local dur = rng:NextNumber(0.8, 1.5)
	if Style.name == "feint" or Style.name == "bait" then dur = 0.8 end
	Style.untilT = t + dur * k
end

local function chasePoint(hrp, thrp, d, m)
	local pos = hrp.Position
	local tpos = thrp.Position
	local tvel = flat(thrp.AssemblyLinearVelocity)
	local lead = math.clamp(d / 16, 0, 0.8)
	local predicted = tpos + tvel * lead

	-- ذاكرة الخصم: يعدّل التوقع حسب ميله وتوقفه
	if Config.Memory and m and m.time > 3 then
		local uu = unit(flat(pos - tpos))
		predicted += perp(uu) * m.bias * lead * m.speed * 0.5
		if m.stop > 0.4 then predicted = tpos + (predicted - tpos) * 0.5 end
	end

	local el = now() - Style.phaseT
	local n = Style.name
	local toT = unit(flat(tpos - pos))

	if n == "flank" then
		local back = -unit(flat(thrp.CFrame.LookVector))
		if d > 7 then return predicted + back * 5 + perp(back) * Style.dir * 3 end
	elseif n == "cutoff" then
		return tpos + tvel * math.clamp(d / 10, 0.3, 1.1)
	elseif n == "feint" then
		if d > 7 and el < 0.3 then
			return pos + unit(perp(toT) * Style.dir) * 8
		end
	elseif n == "pin" then
		local center = getCenter()
		if center then
			local inward = unit(flat(center - tpos))
			local imInside = flat(center - pos).Magnitude < flat(center - tpos).Magnitude
			if imInside then return predicted + inward * 3 end
			return tpos + inward * 7 + perp(inward) * Style.dir * 6
		end
	elseif n == "stutter" then
		-- وقف/انطلق عشان يخرب توقيت مراوغته
		if (el % 0.55) < 0.16 and d > 8 then return pos end
	elseif n == "mirror" then
		-- يوازي حركته الجانبية ثم ينقض
		if d > 8 and el < 0.7 then
			local lat = tvel:Dot(perp(toT))
			local sgn = lat >= 0 and 1 or -1
			return pos + unit(toT * 0.5 + perp(toT) * sgn * 0.9) * 10
		end
	elseif n == "arc" then
		return predicted + perp(toT) * Style.dir * math.clamp(d * 0.5, 0, 8)
	elseif n == "bait" then
		-- يتراجع شوي عشان يستفزه ثم ينقض
		if el < 0.35 and d > 8 then
			local q = pos - toT * 8
			if hasFloorAt(q) then return q end
		end
	end
	return predicted
end

local function resetAI()
	Style.mode, Style.name, Style.untilT, Style.cache, Style.data = "", "", 0, nil, nil
	State.peak, State.lastHT, State.lockedTarget = 0, 0, nil
	navReset()
end

local function aiStep()
	local _, hrp, hum = getCharacterParts(LP)
	if not hrp then return end
	local t = now()
	local pos = hrp.Position

	if hasBomb(LP) then
		local tg = State.target
		if not tg then
			local sk = State.stalk
			if sk then
				-- كل الخصوم محميين مؤقتاً: دوّر حول أقربهم بدون ما تلمسه لين تنتهي الحماية
				if Style.mode ~= "stalk" then
					Style.mode, Style.name = "stalk", "stalk"
					Style.dir = rng:NextInteger(0, 1) == 0 and 1 or -1
					Style.untilT = t + rng:NextNumber(1.5, 3)
				elseif t > Style.untilT then
					Style.dir = -Style.dir
					Style.untilT = t + rng:NextNumber(1.5, 3)
				end
				local away = unit(flat(pos - sk.hrp.Position))
				local rot = (CFrame.Angles(0, math.rad(30 * Style.dir), 0) * CFrame.new(away)).Position
				local p = sk.hrp.Position + unit(rot) * math.max(sk.d, 10)
				steerMove(hrp, hum, Vector3.new(p.X, pos.Y, p.Z))
			else
				hum:MoveTo(pos)
			end
			return
		end

		local _, thrp = getCharacterParts(tg)
		if not thrp then return end
		local d = State.targetDist
		local u = urgencyOf(State.myTime)
		if Style.mode ~= "chase" or t > Style.untilT then pickChaseStyle() end

		local p
		if d < 6 or u > 0.75 then
			p = thrp.Position + flat(thrp.AssemblyLinearVelocity) * math.clamp(d / 16, 0, 0.5)
		else
			p = chasePoint(hrp, thrp, d, State.targetMem)
		end
		if (p - pos).Magnitude < 0.5 then hum:MoveTo(pos) else navMove(hrp, hum, p) end

		if Style.name == "hopchase" and d > 6 then tryJump(hum, 0.9) end
		local dy = thrp.Position.Y - pos.Y
		if Config.Parkour and dy > 2 and dy < jumpHeightOf(hum) + 1 and d < 6 then forceJump(hum) end
	else
		local th = State.threat
		if not th or State.threatDist > Config.FleeRange + 14 then
			hum:MoveTo(pos)
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
			tryJump(hum, 0.7)
		elseif t > Style.untilT then
			pickFleeStyle(ctx, d, false, m)
		end

		steerMove(hrp, hum, fleePoint(hrp, hum, thrp, d))
		if d < 10 then tryJump(hum, 0.12 * Config.Aggro + 0.2 * uh + (last2 and 0.25 or 0)) end
	end
end

--------------------------------------------------------------------
-- Reach
--------------------------------------------------------------------
local lastReach = 0
local function reachStep()
	if now() - lastReach < 0.25 then return end
	local _, hrp = getCharacterParts(LP)
	if not hrp then return end
	local bomb = findBombObject(LP)
	if not bomb then return end

	local range = Config.ReachDistance
	if Config.TimeAware and urgencyOf(State.myTime) > 0.6 then range *= 1.25 end

	local best, bestD
	for _, plr in ipairs(Players:GetPlayers()) do
		if not isTeammate(plr) and isInSameArena(plr) and not hasBomb(plr) and not isImmune(plr) then
			local _, thrp = getCharacterParts(plr)
			local d = (thrp.Position - hrp.Position).Magnitude
			if d <= range and (not bestD or d < bestD) then best, bestD = thrp, d end
		end
	end
	if not best then return end
	lastReach = now() + rng:NextNumber(0, 0.12)

	if bomb:IsA("Tool") then pcall(function() bomb:Activate() end) end
	if firetouchinterest then
		local part = (bomb:IsA("Tool") and bomb:FindFirstChild("Handle")) or (bomb:IsA("BasePart") and bomb) or hrp
		pcall(function()
			firetouchinterest(part, best, 0)
			firetouchinterest(part, best, 1)
		end)
	end
end

--------------------------------------------------------------------
-- 3) الواجهة LEGEND UI
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

local FULL_SIZE, MINI_SIZE = UDim2.new(0, 290, 0, 380), UDim2.new(0, 290, 0, 36)

local main = Instance.new("Frame")
main.Size = MINI_SIZE
main.Position = UDim2.new(0, 14, 0.12, 0)
main.BackgroundColor3 = C.panel
main.BorderSizePixel = 0
main.ClipsDescendants = true
main.Parent = gui
corner(main, 12)

local stroke = Instance.new("UIStroke")
stroke.Thickness = 2
stroke.Color = Color3.new(1, 1, 1)
stroke.Parent = main
local strokeGrad = gradient(stroke, C.accent, C.accent2, 0)

-- شريط العنوان
local title = Instance.new("Frame")
title.Size = UDim2.new(1, 0, 0, 36)
title.BackgroundColor3 = Color3.new(1, 1, 1)
title.BorderSizePixel = 0
title.Parent = main
local titleGrad = gradient(title, Color3.fromRGB(60, 40, 140), Color3.fromRGB(20, 90, 130), 0)

local titleLabel = label(title, "TIMEBOMB AI", 15, C.text, Enum.Font.GothamBlack)
titleLabel.Position = UDim2.new(0, 12, 0, 3)
titleLabel.Size = UDim2.new(1, -80, 0, 18)
local titleSub = label(title, "v4  ·  LEGEND EDITION", 10, Color3.fromRGB(190, 200, 255), Enum.Font.GothamMedium)
titleSub.Position = UDim2.new(0, 12, 0, 20)
titleSub.Size = UDim2.new(1, -80, 0, 12)

local function dotBtn(xOffset, color)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 18, 0, 18)
	b.Position = UDim2.new(1, xOffset, 0.5, -9)
	b.BackgroundColor3 = color
	b.Text = ""
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
	b.Parent = title
	corner(b, 9)
	return b
end
local minBtn = dotBtn(-48, C.warn)
local closeBtn = dotBtn(-26, C.bad)

-- عداد القنبلة
local meter = Instance.new("Frame")
meter.Position = UDim2.new(0, 8, 0, 42)
meter.Size = UDim2.new(1, -16, 0, 54)
meter.BackgroundColor3 = C.card
meter.BorderSizePixel = 0
meter.Parent = main
corner(meter, 8)

local stateText = label(meter, "SAFE", 13, C.good, Enum.Font.GothamBlack)
stateText.Position = UDim2.new(0, 10, 0, 4)
stateText.Size = UDim2.new(1, -80, 0, 18)
local timeText = label(meter, "--", 16, C.text, Enum.Font.GothamBlack)
timeText.TextXAlignment = Enum.TextXAlignment.Right
timeText.Position = UDim2.new(1, -74, 0, 3)
timeText.Size = UDim2.new(0, 64, 0, 20)

local barTrack = Instance.new("Frame")
barTrack.Position = UDim2.new(0, 10, 0, 27)
barTrack.Size = UDim2.new(1, -20, 0, 8)
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

local infoText = label(meter, "STYLE: -  ·  URGENCY: 0%", 10, C.sub, Enum.Font.GothamMedium)
infoText.Position = UDim2.new(0, 10, 0, 38)
infoText.Size = UDim2.new(1, -20, 0, 12)

setMeter = function(who, whoColor, tleft, urg, styleName)
	stateText.Text = who
	stateText.TextColor3 = whoColor
	timeText.Text = tleft and string.format("%.1fs", tleft) or "--"
	local col = urg < 0.5 and C.good:Lerp(C.warn, urg * 2) or C.warn:Lerp(C.bad, (urg - 0.5) * 2)
	timeText.TextColor3 = tleft and col or C.sub
	local ratio = tleft and math.clamp(tleft / math.max(State.peak, 10), 0, 1) or 0
	tween(barFill, 0.12, { Size = UDim2.new(ratio, 0, 1, 0), BackgroundColor3 = col })
	infoText.Text = string.format("STYLE: %s  ·  URGENCY: %d%%", styleName ~= "" and styleName or "-", math.floor(urg * 100))
end

-- Toast
local toastBox = Instance.new("Frame")
toastBox.AnchorPoint = Vector2.new(0.5, 1)
toastBox.Position = UDim2.new(0.5, 0, 1, -8)
toastBox.Size = UDim2.new(1, -24, 0, 26)
toastBox.BackgroundColor3 = C.bg
toastBox.BackgroundTransparency = 1
toastBox.BorderSizePixel = 0
toastBox.ZIndex = 20
toastBox.Parent = main
corner(toastBox, 8)
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

-- التبويبات
local pages = {}
local order = 0
local function newPage()
	local p = Instance.new("ScrollingFrame")
	p.Position = UDim2.new(0, 6, 0, 130)
	p.Size = UDim2.new(1, -12, 1, -164)
	p.BackgroundTransparency = 1
	p.BorderSizePixel = 0
	p.ScrollBarThickness = 3
	p.ScrollBarImageColor3 = C.accent
	p.CanvasSize = UDim2.new()
	p.AutomaticCanvasSize = Enum.AutomaticSize.Y
	p.Visible = false
	p.Parent = main
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
	corner(f, 8)
	return f
end

local pControl, pTuning, pRadar, pStats = newPage(), newPage(), newPage(), newPage()

local tabNames = { "CONTROL", "TUNING", "RADAR", "STATS" }
local tabBtns, tabLines = {}, {}
local function selectTab(idx)
	for k, p in ipairs(pages) do p.Visible = (k == idx) end
	for k, b in ipairs(tabBtns) do
		b.TextColor3 = (k == idx) and C.text or C.sub
		tabLines[k].Visible = (k == idx)
	end
end
for i, name in ipairs(tabNames) do
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0.25, -4, 0, 26)
	b.Position = UDim2.new((i - 1) * 0.25, 2, 0, 100)
	b.BackgroundTransparency = 1
	b.Text = name
	b.Font = Enum.Font.GothamBold
	b.TextSize = 11
	b.TextColor3 = C.sub
	b.Parent = main
	local line = Instance.new("Frame")
	line.Size = UDim2.new(0.7, 0, 0, 2)
	line.Position = UDim2.new(0.15, 0, 1, -2)
	line.BackgroundColor3 = C.accent2
	line.BorderSizePixel = 0
	line.Visible = false
	line.Parent = b
	corner(line, 1)
	b.Activated:Connect(function() selectTab(i) end)
	tabBtns[i], tabLines[i] = b, line
end

local function makeToggle(page, name, sub, key, onChange)
	local row = newCard(page, 44)
	local l = label(row, name, 13, C.text, Enum.Font.GothamBold)
	l.Position = UDim2.new(0, 12, 0, 5)
	l.Size = UDim2.new(1, -70, 0, 18)
	local s = label(row, sub, 10, C.sub, Enum.Font.Gotham)
	s.Position = UDim2.new(0, 12, 0, 24)
	s.Size = UDim2.new(1, -70, 0, 14)

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
		if animate then
			tween(knob, 0.15, { Position = pos })
			tween(track, 0.15, { BackgroundColor3 = col })
		else
			knob.Position, track.BackgroundColor3 = pos, col
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
	local row = newCard(page, 48)
	local l = label(row, name, 12, C.text, Enum.Font.GothamBold)
	l.Position = UDim2.new(0, 12, 0, 5)
	l.Size = UDim2.new(1, -90, 0, 16)
	local v = label(row, "", 12, C.accent2, Enum.Font.GothamBold)
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.Position = UDim2.new(1, -86, 0, 5)
	v.Size = UDim2.new(0, 74, 0, 16)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, -24, 0, 12)
	bar.Position = UDim2.new(0, 12, 0, 28)
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
	local row = newCard(page, 34)
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

-- صفحة التحكم
makeToggle(pControl, "AI AUTO-PLAY", "لعب تلقائي كامل", "AI", function(on)
	if not on then
		local _, hrp, hum = getCharacterParts(LP)
		if hum then hum:MoveTo(hrp.Position) end
		resetAI()
	end
end)
makeToggle(pControl, "REACH", "تمرير القنبلة عن بعد", "Reach")
makeToggle(pControl, "SMART SHIFT LOCK", "تثبيت الاتجاه عند الحاجة فقط", "ShiftLock", function(on)
	if not on then restoreShiftLockState() end
end)
makeToggle(pControl, "CAMERA TRACK", "الكاميرا تتبع الهدف", "CamTrack")
makeToggle(pControl, "TIME CALC", "حساب الوقت وتغيير الأسلوب", "TimeAware")
makeToggle(pControl, "EDGE ANALYSIS", "تحليل الحافات والزوايا", "EdgeAI")
makeToggle(pControl, "OPPONENT MEMORY", "يتعلم أسلوب كل خصم", "Memory")
makeToggle(pControl, "SMART NAV", "يتجنب الجدران ويصعد بمسار", "Nav", function() navReset() end)
makeToggle(pControl, "PARKOUR", "قفز وتسلق واختباء خلف الأعمدة", "Parkour")
makeToggle(pControl, "AUTO RESTART", "يشتغل تلقائياً كل جولة", "AutoRestart")

-- صفحة الضبط
makeSlider(pTuning, "Reach Range", "ReachDistance", 6, 25, function(x) return string.format("%.0f", x) end)
makeSlider(pTuning, "Reaction Time", "Reaction", 0.05, 0.35, function(x) return string.format("%d ms", x * 1000) end)
makeSlider(pTuning, "Dodge Aggression", "Aggro", 0, 1, function(x) return string.format("%d%%", x * 100) end)
makeSlider(pTuning, "Urgent Time", "UrgentTime", 2, 8, function(x) return string.format("%.1f s", x) end)
makeSlider(pTuning, "Tag-back Immunity", "Immunity", 0, 6, function(x) return string.format("%.1f s", x) end)
makeButton(pTuning, "RE-SCAN ARENA  •  إعادة تحليل الساحة", function()
	buildMap()
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
local radarStroke = Instance.new("UIStroke")
radarStroke.Color = C.accent
radarStroke.Thickness = 1
radarStroke.Parent = radar
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

local legend = newCard(pRadar, 40)
local legendText = label(legend, "RED edge  ·  ORANGE near-edge  ·  PINK dead corner\nWHITE you  ·  GREEN target  ·  RED holder", 10, C.sub, Enum.Font.Gotham)
legendText.Position = UDim2.new(0, 10, 0, 4)
legendText.Size = UDim2.new(1, -20, 0, 32)
legendText.TextWrapped = true
legendText.TextTruncate = Enum.TextTruncate.None
legendText.TextYAlignment = Enum.TextYAlignment.Top

local profCard = newCard(pRadar, 70)
local profLabel = label(profCard, "OPPONENT PROFILE", 11, C.accent2, Enum.Font.GothamBold)
profLabel.Position = UDim2.new(0, 10, 0, 4)
profLabel.Size = UDim2.new(1, -20, 0, 14)
local profText = label(profCard, "-", 12, C.text, Enum.Font.GothamMedium)
profText.Position = UDim2.new(0, 10, 0, 20)
profText.Size = UDim2.new(1, -20, 0, 46)
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
	local row = newCard(pStats, 30)
	local l = label(row, name, 12, C.sub, Enum.Font.GothamMedium)
	l.Position = UDim2.new(0, 12, 0, 0)
	l.Size = UDim2.new(0.5, 0, 1, 0)
	local v = label(row, "0", 13, C.text, Enum.Font.GothamBold)
	v.TextXAlignment = Enum.TextXAlignment.Right
	v.Position = UDim2.new(0.5, 0, 0, 0)
	v.Size = UDim2.new(0.5, -12, 1, 0)
	return v
end
local stRounds, stPasses, stMap, stTracked, stSession = makeStat("Rounds"), makeStat("Passes"), makeStat("Arena cells"), makeStat("Opponents tracked"), makeStat("Session")

-- تصغير: الواجهة تتحول لكرة عائمة (اضغط عليها ترجع) | على الكمبيوتر: RightShift
local orb = Instance.new("TextButton")
orb.Size = UDim2.new(0, 46, 0, 46)
orb.BackgroundColor3 = C.panel
orb.Text = "AI"
orb.Font = Enum.Font.GothamBlack
orb.TextSize = 15
orb.TextColor3 = C.text
orb.AutoButtonColor = false
orb.Visible = false
orb.ZIndex = 50
orb.Parent = gui
corner(orb, 23)
local orbStroke = Instance.new("UIStroke")
orbStroke.Thickness = 2
orbStroke.Color = Color3.new(1, 1, 1)
orbStroke.Parent = orb
local orbGrad = gradient(orbStroke, C.accent, C.accent2, 0)

local minimized = false
local function setMinimized(state)
	minimized = state
	if state then
		orb.Position = main.Position
		main.Visible = false
		orb.Visible = true
	else
		main.Position = orb.Position
		orb.Visible = false
		main.Visible = true
		main.Size = MINI_SIZE
		tween(main, 0.3, { Size = FULL_SIZE })
	end
end
minBtn.Activated:Connect(function() setMinimized(true) end)

do
	local dragging, moved, dragStart, startPos = false, false, nil, nil
	orb.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, moved, dragStart, startPos = true, false, input.Position, orb.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
					if not moved then setMinimized(false) end
				end
			end)
		end
	end)
	table.insert(connections, UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			if d.Magnitude > 8 then moved = true end
			if moved then
				orb.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end
	end))
end
table.insert(connections, UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.RightShift then setMinimized(not minimized) end
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
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
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
	gui:Destroy()
end
closeBtn.Activated:Connect(shutdown)

selectTab(1)
tween(main, 0.45, { Size = FULL_SIZE })

--------------------------------------------------------------------
-- الحلقات الرئيسية
--------------------------------------------------------------------
local acc, nextStep, wasInMatch, hadBomb, urgentShown, lastSlow = 0, 0.1, false, false, false, 0

table.insert(connections, RunService.Heartbeat:Connect(function(dt)
	if not alive then return end
	acc += dt
	if acc < nextStep then return end
	acc = 0
	nextStep = Config.Reaction + rng:NextNumber(0, 0.04)

	local inMatch = isInMatch(LP)
	if inMatch ~= wasInMatch then
		wasInMatch = inMatch
		resetAI()
		if inMatch then
			Stats.rounds += 1
			task.delay(1.5, function() if alive then buildMap() end end) -- تحليل الحافات بداية الجولة
		elseif not Config.AutoRestart then
			Config.AI, Config.Reach = false, false
			if Refreshers.AI then Refreshers.AI() end
			if Refreshers.Reach then Refreshers.Reach() end
		end
	end

	if not inMatch then
		clearState()
		restoreShiftLockState()
		hadBomb = false
		setMeter(Config.AutoRestart and "WAITING / LOBBY" or "OUT OF ROUND", C.sub, nil, 0, "")
		return
	end

	if pcall(scanPlayers) then
		if Config.AI then pcall(aiStep) end
		if Config.Reach then pcall(reachStep) end
	end
	if not hasBomb(LP) and not needShiftLockNow() then restoreShiftLockState() end

	-- إشعارات
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

	-- العداد
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
		stRounds.Text = tostring(Stats.rounds)
		stPasses.Text = tostring(Stats.passes)
		stMap.Text = Map.ready and tostring(Map.walk) or "—"
		stTracked.Text = tostring(n)
		local s = math.floor(now() - Stats.t0)
		stSession.Text = string.format("%02d:%02d", math.floor(s / 60), s % 60)
	end
end))

RunService:BindToRenderStep("TimebombAI", Enum.RenderPriority.Camera.Value + 1, function()
	if not alive then return end
	local t = now()
	strokeGrad.Rotation = (t * 60) % 360
	orbGrad.Rotation = (t * 90) % 360
	titleGrad.Offset = Vector2.new(math.sin(t) * 0.15, 0)
	pcall(camTrack)
	if Config.ShiftLock then pcall(updateShiftLock) end
end)

table.insert(connections, LP.CharacterAdded:Connect(function()
	savedAutoRotate = nil
	resetAI()
end))

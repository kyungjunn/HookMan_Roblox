--!strict
-- HOOKMAN 코스 생성기.
-- 레벨이 오를수록 길어지고, 더 자주/크게 꺾이고, 중앙 레인에 장애물이 늘고,
-- 팔레트(외형)가 바뀐다. 코스는 레벨업마다 통째로 다시 짓는다.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Hookman")
local Config = require(Shared:WaitForChild("Config"))

local CourseBuilder = {}

local SPACING = 112 -- 건물 행 간격
local HOOK_LATERAL = 39.5 -- 코스 중심선 ~ 훅 지점
local HOOK_BASE_Y = 300
local FAIL_Y = 50

type Palette = {
	name: string,
	wall: Color3,
	mat: Enum.Material,
	accent: Color3,
	hook: Color3,
	hazard: Color3,
}

local PALETTES: { Palette } = {
	{
		name = "Downtown",
		wall = Color3.fromRGB(226, 228, 233),
		mat = Enum.Material.Concrete,
		accent = Color3.fromRGB(90, 180, 255),
		hook = Color3.fromRGB(120, 220, 255),
		hazard = Color3.fromRGB(255, 90, 90),
	},
	{
		name = "Sunset",
		wall = Color3.fromRGB(232, 168, 120),
		mat = Enum.Material.Brick,
		accent = Color3.fromRGB(255, 120, 60),
		hook = Color3.fromRGB(255, 214, 64),
		hazard = Color3.fromRGB(255, 60, 140),
	},
	{
		name = "Neon",
		wall = Color3.fromRGB(38, 40, 64),
		mat = Enum.Material.Metal,
		accent = Color3.fromRGB(255, 80, 220),
		hook = Color3.fromRGB(120, 255, 200),
		hazard = Color3.fromRGB(255, 60, 60),
	},
	{
		name = "Glacier",
		wall = Color3.fromRGB(198, 232, 248),
		mat = Enum.Material.Ice,
		accent = Color3.fromRGB(80, 200, 255),
		hook = Color3.fromRGB(255, 255, 255),
		hazard = Color3.fromRGB(90, 140, 255),
	},
	{
		name = "Rust",
		wall = Color3.fromRGB(146, 92, 62),
		mat = Enum.Material.CorrodedMetal,
		accent = Color3.fromRGB(255, 170, 60),
		hook = Color3.fromRGB(255, 190, 90),
		hazard = Color3.fromRGB(120, 255, 90),
	},
}

type Params = {
	rows: number,
	turnChance: number,
	maxTurn: number,
	hazardChance: number,
	hazardSpeed: number,
	heightWave: number,
	gateChance: number,
	palette: Palette,
}

local function paletteByName(name: string?): Palette?
	if not name then
		return nil
	end
	for _, p in ipairs(PALETTES) do
		if p.name == name then
			return p
		end
	end
	return nil
end

-- paletteName: 존이 외형을 강제한다. 존마다 색이 고정이어야 "다른 장소"로 읽힌다.
-- 레벨로 순환시키면 같은 존 안에서 벽 색이 계속 바뀌어 어디에 있는지 알 수 없다.
local function params(level: number, paletteName: string?): Params
	local L = math.max(1, level)
	return {
		rows = math.min(11 + L, 24),
		-- 레벨 1은 직선에 가깝고, 3부터 본격적으로 지그재그가 된다.
		turnChance = math.clamp(0.12 + (L - 1) * 0.13, 0, 0.72),
		maxTurn = math.rad(math.min(16 + (L - 1) * 8, 46)),
		hazardChance = L >= 2 and math.clamp((L - 1) * 0.22, 0, 0.85) or 0,
		hazardSpeed = 1 + (L - 1) * 0.13,
		heightWave = math.min(16 + L * 4, 54),
		-- 게이트는 "구멍 조준" 문제라 정적이다. 비율이 높아지면 코스 전체가
		-- 타이밍 게임이 아니라 정지 퍼즐이 된다. 최대 3할까지만 섞는다.
		gateChance = L >= 3 and math.clamp((L - 2) * 0.09, 0, 0.3) or 0,
		palette = paletteByName(paletteName) or PALETTES[((L - 1) % #PALETTES) + 1],
	}
end

local function mkPart(
	name: string,
	parent: Instance,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	mat: Enum.Material
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- 중앙 레인 장애물. 움직임은 스테이지 스크립트가 Base 속성 기준으로 굴린다.
local function mkHazard(
	parent: Instance,
	name: string,
	kind: string,
	size: Vector3,
	base: CFrame,
	P: Params,
	rng: Random
)
	local h = mkPart(name, parent, size, base, P.palette.hazard, Enum.Material.Neon)
	h.CanCollide = false
	h:SetAttribute("Kind", kind)
	h:SetAttribute("Base", base)
	h:SetAttribute("Speed", P.hazardSpeed * rng:NextNumber(0.8, 1.25))
	h:SetAttribute("Phase", rng:NextNumber(0, math.pi * 2))
	local light = Instance.new("PointLight")
	light.Color = P.palette.hazard
	light.Range = 26
	light.Brightness = 2
	light.Parent = h
	return h
end

function CourseBuilder.build(level: number, paletteName: string?): Folder
	local P = params(level, paletteName)
	local rng = Random.new(9176 + level * 7919)

	local course = Instance.new("Folder")
	course.Name = "Course"

	local fBuildings = Instance.new("Folder")
	fBuildings.Name = "Buildings"
	fBuildings.Parent = course
	local fHooks = Instance.new("Folder")
	fHooks.Name = "HookPoints"
	fHooks.Parent = course
	local fCps = Instance.new("Folder")
	fCps.Name = "Checkpoints"
	fCps.Parent = course
	local fHaz = Instance.new("Folder")
	fHaz.Name = "Hazards"
	fHaz.Parent = course
	local fNodes = Instance.new("Folder")
	fNodes.Name = "PathNodes"
	fNodes.Parent = course

	----------------------------------------------------------------
	-- 1) 경로 걷기: 매 행마다 확률적으로 좌/우로 꺾는다.
	----------------------------------------------------------------
	local pts: { Vector3 } = {}
	local dirs: { Vector3 } = {}
	local theta = 0
	local cursor = Vector3.zero
	for i = 1, P.rows do
		table.insert(pts, cursor)
		local dir = Vector3.new(math.sin(theta), 0, math.cos(theta))
		table.insert(dirs, dir)
		cursor += dir * SPACING
		-- 초반 2행은 직선 활주로. 마지막 행 직전도 직선으로 마무리해 골이 보이게 한다.
		if i >= 2 and i < P.rows - 1 and rng:NextNumber() < P.turnChance then
			local sign = rng:NextInteger(0, 1) == 0 and -1 or 1
			theta += sign * P.maxTurn * rng:NextNumber(0.6, 1.0)
			-- 완전히 되돌아 오지 않도록 절대 방위를 묶는다.
			theta = math.clamp(theta, -math.rad(72), math.rad(72))
		end
	end

	-- 경로 노드: 시작 앞쪽(스타트 타워)과 끝쪽(골)까지 연장한다.
	local nodePts: { Vector3 } = { pts[1] - dirs[1] * 220 }
	for _, p in ipairs(pts) do
		table.insert(nodePts, p)
	end
	table.insert(nodePts, pts[P.rows] + dirs[P.rows] * 220)
	for i, p in ipairs(nodePts) do
		local n = mkPart(
			("Node_%03d"):format(i),
			fNodes,
			Vector3.new(2, 2, 2),
			CFrame.new(p),
			Color3.new(1, 1, 1),
			Enum.Material.SmoothPlastic
		)
		n.Transparency = 1
		n.CanCollide = false
		n.CanQuery = false
		n.CanTouch = false
	end

	----------------------------------------------------------------
	-- 2) 행별 고도 프로파일
	----------------------------------------------------------------
	local rowY: { number } = {}
	for i = 1, P.rows do
		rowY[i] = HOOK_BASE_Y + math.sin(i * 0.72) * P.heightWave + rng:NextNumber(-10, 10)
	end

	----------------------------------------------------------------
	-- 3) 건물 + 훅 지점
	----------------------------------------------------------------
	local function placeHook(name: string, pos: Vector3, side: number)
		local h = mkPart(name, fHooks, Vector3.new(4, 4, 4), CFrame.new(pos), P.palette.hook, Enum.Material.Neon)
		h.Shape = Enum.PartType.Ball
		h.CanCollide = false
		-- 좌/우 판정을 클라이언트가 매 프레임 다시 풀지 않게 생성 시점에 박아 둔다.
		-- (side: -1 화면 왼쪽, +1 화면 오른쪽)
		h:SetAttribute("Side", side)
		CollectionService:AddTag(h, Config.Hook.Tag)
	end

	for i = 1, P.rows do
		local c = pts[i]
		local dir = dirs[i]
		local right = dir:Cross(Vector3.yAxis)

		for _, s in ipairs({ -1, 1 }) do
			local w = rng:NextNumber(34, 52)
			local d = rng:NextNumber(38, 58)
			local top = rowY[i] + rng:NextNumber(12, 62)
			local lat = s * (HOOK_LATERAL + 2 + w / 2)
			local foot = c + right * lat
			local center = foot + Vector3.new(0, top / 2, 0)
			local cf = CFrame.lookAt(center, center + dir)
			local tag = s < 0 and "L" or "R"
			mkPart(("B_%02d_%s"):format(i, tag), fBuildings, Vector3.new(w, top, d), cf, P.palette.wall, P.palette.mat)
			-- 옥상 네온 띠: 코스 방향을 멀리서도 읽게 해 준다.
			local roof = cf + Vector3.new(0, top / 2 + 1, 0)
			mkPart(
				("Roof_%02d_%s"):format(i, tag),
				fBuildings,
				Vector3.new(w * 0.92, 2, d * 0.92),
				roof,
				P.palette.accent,
				Enum.Material.Neon
			)
		end

		-- 행 훅
		placeHook(("Hook_%02d_L"):format(i), c + right * -HOOK_LATERAL + Vector3.new(0, rowY[i], 0), -1)
		placeHook(
			("Hook_%02d_R"):format(i),
			c + right * HOOK_LATERAL + Vector3.new(0, rowY[i] + rng:NextNumber(-8, 8), 0),
			1
		)

		-- 행 사이 중간 훅: 훅 간격이 벌어지면 연속 스윙이 끊긴다.
		if i < P.rows then
			local midC = c + dir * (SPACING / 2)
			local midY = (rowY[i] + rowY[i + 1]) / 2
			placeHook(("Hook_%02dM_L"):format(i), midC + right * -HOOK_LATERAL + Vector3.new(0, midY, 0), -1)
			placeHook(("Hook_%02dM_R"):format(i), midC + right * HOOK_LATERAL + Vector3.new(0, midY, 0), 1)
		end
	end

	----------------------------------------------------------------
	-- 4) 중앙 레인 장애물: 건물 사이 빈 공간을 타이밍 문제로 바꾼다.
	----------------------------------------------------------------
	local kinds = { "Sweeper", "Spinner", "Bobber" }
	for i = 3, P.rows - 1 do
		if rng:NextNumber() >= P.hazardChance then
			continue
		end
		local dir = dirs[i]
		local right = dir:Cross(Vector3.yAxis)
		local c = pts[i] + dir * (SPACING / 2)
		-- 비행 고도는 훅보다 아래(로프 길이만큼)다. 그 밴드에 걸치게 놓는다.
		local y = (rowY[i] + rowY[i + 1]) / 2 - 52 + rng:NextNumber(-18, 18)
		local center = c + Vector3.new(0, y, 0)
		local base = CFrame.lookAt(center, center + dir)

		if P.gateChance > 0 and rng:NextNumber() < P.gateChance then
			-- 게이트: 가운데 구멍만 통과 가능. 구멍 위치가 매번 다르다.
			local hole = rng:NextNumber(-16, 16)
			local holeHalf = 19
			-- 게이트도 통째로 좌우로 흐른다. 두 짝이 같은 속도/위상을 공유해야
			-- 구멍 폭이 유지된 채 구멍만 움직인다 = 조준이 아니라 타이밍 문제가 된다.
			local slide = level >= 5 and rng:NextNumber(10, 22) or 0
			local gateSpeed = P.hazardSpeed * rng:NextNumber(0.7, 1.0)
			local gatePhase = rng:NextNumber(0, math.pi * 2)
			for _, s in ipairs({ -1, 1 }) do
				local inner = hole + s * holeHalf
				local outer = s * 46
				local w = math.abs(outer - inner)
				if w > 4 then
					local mid = (inner + outer) / 2
					local g = mkPart(
						("Gate_%02d_%d"):format(i, s),
						fHaz,
						Vector3.new(w, 54, 6),
						base * CFrame.new(mid, 0, 0),
						P.palette.hazard,
						Enum.Material.Neon
					)
					g.CanCollide = false
					g.Transparency = 0.15
					if slide > 0 then
						g:SetAttribute("Kind", "Sweeper")
						g:SetAttribute("Base", base * CFrame.new(mid, 0, 0))
						g:SetAttribute("Amp", slide)
						g:SetAttribute("Speed", gateSpeed)
						g:SetAttribute("Phase", gatePhase)
					else
						g:SetAttribute("Kind", "Static")
					end
				end
			end
		else
			local kind = kinds[rng:NextInteger(1, #kinds)]
			if kind == "Sweeper" then
				-- 좌우로 쓸고 지나간다. 반대편에 있을 때 통과.
				local h = mkHazard(fHaz, ("Sweeper_%02d"):format(i), kind, Vector3.new(34, 8, 8), base, P, rng)
				h:SetAttribute("Amp", rng:NextNumber(30, 44))
			elseif kind == "Spinner" then
				-- 세로축 회전 바. 진행 방향과 나란해지는 순간에만 길이 열린다.
				local h = mkHazard(fHaz, ("Spinner_%02d"):format(i), kind, Vector3.new(76, 6, 6), base, P, rng)
				h:SetAttribute("Amp", 0)
			else
				-- 상하로 튀는 덩치. 아래로 내려갔을 때 위로 넘어간다.
				local h = mkHazard(fHaz, ("Bobber_%02d"):format(i), kind, Vector3.new(18, 18, 18), base, P, rng)
				h.Shape = Enum.PartType.Ball
				h:SetAttribute("Amp", rng:NextNumber(26, 42))
			end
		end
	end

	----------------------------------------------------------------
	-- 5) 체크포인트 / 시작 / 골 / 낙하면
	----------------------------------------------------------------
	for k = 1, 3 do
		local idx = math.clamp(math.floor(P.rows * k / 4), 2, P.rows - 1)
		local dir = dirs[idx]
		local c = pts[idx] + Vector3.new(0, rowY[idx] - 24, 0)
		local cp = mkPart(
			("CP_%d"):format(k),
			fCps,
			Vector3.new(96, 2, 8),
			CFrame.lookAt(c, c + dir),
			P.palette.accent,
			Enum.Material.Neon
		)
		cp.CanCollide = false
		cp.Transparency = 0.3
	end

	local startDir = dirs[1]
	local startFoot = pts[1] - startDir * 120
	-- 스타트 패드 고도는 첫 훅 행 기준 Config.Hook.MaxDrop 안에 들어와야 한다.
	-- 더 높이 세우면 패드 위에서는 모든 훅이 후보에서 탈락해 첫 입력이 NO HOOK 이 되고,
	-- 자유낙하로 그 밴드에 들어갈 때까지 아무것도 못 하는 죽은 시간이 생긴다.
	local startY = rowY[1] + 60
	local tower = mkPart(
		"SpawnTower",
		course,
		Vector3.new(70, startY, 70),
		CFrame.new(startFoot + Vector3.new(0, startY / 2, 0)),
		P.palette.wall,
		P.palette.mat
	)
	local startPad = mkPart(
		"StartPad",
		course,
		Vector3.new(60, 4, 60),
		CFrame.new(startFoot + Vector3.new(0, startY + 2, 0)),
		P.palette.accent,
		Enum.Material.Neon
	)
	-- 코스에는 SpawnLocation 을 두지 않는다. 첫 스폰은 로비여야 하는데,
	-- 코스에 스폰이 있으면 로블록스가 둘 중 아무거나 골라 로비를 건너뛴다.
	local _ = tower

	-- 골: 바닥 패드가 아니라 코스를 가로막는 "결승 면"이다.
	-- 좁은 패드는 고속 비행 중에 정확히 착지해야 해서 사실상 도달 불가였다.
	-- 낙하면(FAIL_Y)부터 훅 고도 한참 위까지 통째로 덮어, 앞으로 나아가기만 하면 닿는다.
	local goalDir = dirs[P.rows]
	local goalY = rowY[P.rows] - 20
	local GOAL_W = 320
	local goalTop = rowY[P.rows] + 220
	local goalH = goalTop - FAIL_Y
	local goalCenter = pts[P.rows] + goalDir * 150 + Vector3.new(0, FAIL_Y + goalH / 2, 0)
	local goalPad = mkPart(
		"GoalPad",
		course,
		Vector3.new(GOAL_W, goalH, 6),
		CFrame.lookAt(goalCenter, goalCenter + goalDir),
		Color3.fromRGB(255, 214, 64),
		Enum.Material.Neon
	)
	-- 벽처럼 튕겨내면 안 된다. 통과하는 순간 서버가 진행거리로 클리어를 잡는다.
	goalPad.CanCollide = false
	goalPad.Transparency = 0.45
	local goalGlow = Instance.new("PointLight")
	goalGlow.Color = Color3.fromRGB(255, 214, 64)
	goalGlow.Range = 60
	goalGlow.Brightness = 3
	goalGlow.Parent = goalPad
	-- 비행 고도에 두꺼운 띠를 덧대 멀리서도 결승선으로 읽히게 한다.
	local band = mkPart(
		"GoalBand",
		course,
		Vector3.new(GOAL_W, 14, 8),
		CFrame.lookAt(
			pts[P.rows] + goalDir * 150 + Vector3.new(0, goalY, 0),
			pts[P.rows] + goalDir * 151 + Vector3.new(0, goalY, 0)
		),
		Color3.fromRGB(255, 255, 255),
		Enum.Material.Neon
	)
	band.CanCollide = false
	band.CanTouch = false
	local _ = startPad
	local _ = goalPad

	-- 낙하면: 코스 전체를 덮는 평면 하나. 판정은 Y 값만 쓴다.
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(nodePts) do
		minX = math.min(minX, p.X)
		maxX = math.max(maxX, p.X)
		minZ = math.min(minZ, p.Z)
		maxZ = math.max(maxZ, p.Z)
	end
	local fail = mkPart(
		"FailPlane",
		course,
		Vector3.new((maxX - minX) + 900, 2, (maxZ - minZ) + 900),
		CFrame.new((minX + maxX) / 2, FAIL_Y, (minZ + maxZ) / 2),
		Color3.fromRGB(30, 34, 44),
		Enum.Material.SmoothPlastic
	)
	fail.CanCollide = false
	fail.Transparency = 0.75

	course:SetAttribute("Level", level)
	course:SetAttribute("Palette", P.palette.name)
	return course
end

return CourseBuilder

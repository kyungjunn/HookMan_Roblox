--!strict
-- HOOKMAN 로비.
-- 첫 스폰 지점이자 상점/장착 공간. 코스와 물리적으로 완전히 분리된 하늘 섬이다.
-- 코스 안에 두면 레벨업마다 코스를 통째로 재생성할 때 같이 날아간다.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ZoneCatalog = require(ReplicatedStorage:WaitForChild("Hookman"):WaitForChild("ZoneCatalog"))

local LobbyBuilder = {}

-- 코스는 원점 근처에서 +Z 로 뻗고 Y 는 300 안팎이다. 로비는 그 위/뒤로 크게 띄운다.
local ORIGIN = Vector3.new(0, 1200, -900)
local FLOOR = Vector3.new(150, 6, 150)

local WALL = Color3.fromRGB(38, 42, 58)
local ACCENT = Color3.fromRGB(90, 180, 255)
local GOLD = Color3.fromRGB(255, 214, 64)

local function mkPart(name: string, parent: Instance, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material): Part
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

-- maxDist: 이 거리 밖에서는 통째로 사라진다.
-- 존 패드는 30 스터드 간격인데 표지판이 화면 고정 크기(offset)라, 멀어질수록
-- 월드 간격은 줄고 글자 크기는 그대로여서 5개가 한 덩어리로 겹친다.
-- 크기를 줄이는 것만으로는 부족하고, 가까이 왔을 때만 보이게 잘라야 읽힌다.
local function mkSign(parent: BasePart, text: string, sub: string, color: Color3, offsetY: number, maxDist: number?)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Sign"
	bb.Size = UDim2.fromOffset(200, 60)
	bb.StudsOffsetWorldSpace = Vector3.new(0, offsetY, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = maxDist or 120
	bb.Parent = parent

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0.6, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = color
	title.TextStrokeTransparency = 0.3
	title.Text = text
	title.Parent = bb

	local desc = Instance.new("TextLabel")
	desc.Size = UDim2.new(1, 0, 0.4, 0)
	desc.Position = UDim2.fromScale(0, 0.6)
	desc.BackgroundTransparency = 1
	desc.Font = Enum.Font.Gotham
	desc.TextScaled = true
	desc.TextColor3 = Color3.fromRGB(220, 230, 240)
	desc.TextStrokeTransparency = 0.5
	desc.Text = sub
	desc.Parent = bb
end

----------------------------------------------------------------------
-- 랭킹 보드
--
-- 상점 키오스크가 -X 에 있으니 보드는 +X 에 대칭으로 둔다.
-- 스폰(-Z)에서 존 패드(+Z)로 걸어가는 동선의 양 옆이라 둘 다 지나치면서 읽힌다.
--
-- 내용은 서버가 채운다. SurfaceGui 를 서버에서 만들면 그대로 복제되므로
-- 랭킹만을 위한 클라이언트 스크립트가 필요 없다. 모두가 같은 표를 본다.
----------------------------------------------------------------------
local BOARD_BG = Color3.fromRGB(16, 18, 28)

local function mkRow(parent: Instance, name: string, i: number, height: number)
	local row = Instance.new("Frame")
	row.Name = name
	row.Size = UDim2.new(1, 0, height, 0)
	row.Position = UDim2.new(0, 0, height * (i - 1), 0)
	row.BackgroundColor3 = Color3.fromRGB(30, 34, 48)
	-- 홀수 행만 살짝 밝히면 줄이 눈으로 끊겨진다. 칸 구분선을 그리는 것보다 싸다.
	row.BackgroundTransparency = (i % 2 == 0) and 0.75 or 0.55
	row.BorderSizePixel = 0
	row.Parent = parent

	local function label(n: string, x: number, w: number, align: Enum.TextXAlignment, color: Color3)
		local t = Instance.new("TextLabel")
		t.Name = n
		t.Size = UDim2.new(w, 0, 1, 0)
		t.Position = UDim2.fromScale(x, 0)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamBold
		t.TextScaled = true
		t.TextXAlignment = align
		t.TextColor3 = color
		t.Text = ""
		t.Parent = row
	end

	-- 1~3위만 금/은/동. 전부 금색이면 상위가 안 도드라진다.
	local rankColor = i == 1 and Color3.fromRGB(255, 214, 64)
		or i == 2 and Color3.fromRGB(210, 220, 235)
		or i == 3 and Color3.fromRGB(220, 150, 90)
		or Color3.fromRGB(150, 165, 185)
	-- 자식 이름을 "Name" 으로 두면 row.Name 이 자식이 아니라 Instance.Name 속성으로 잡힌다.
	-- FindFirstChild 로만 쓰면 해결되지만, 다음에 점으로 접근하는 순간 조용히 nil 이 된다.
	label("Rank", 0.02, 0.14, Enum.TextXAlignment.Left, rankColor)
	label("PlayerName", 0.18, 0.5, Enum.TextXAlignment.Left, Color3.fromRGB(235, 242, 250))
	label("Score", 0.68, 0.3, Enum.TextXAlignment.Right, Color3.fromRGB(120, 220, 255))
end

local function mkList(parent: Instance, name: string, title: string, x: number, w: number, rows: number, accent: Color3)
	local col = Instance.new("Frame")
	col.Name = name .. "Col"
	col.Size = UDim2.new(w, 0, 0.84, 0)
	col.Position = UDim2.fromScale(x, 0.15)
	col.BackgroundTransparency = 1
	col.Parent = parent

	local head = Instance.new("TextLabel")
	head.Name = "Head"
	head.Size = UDim2.new(1, 0, 0.09, 0)
	head.BackgroundTransparency = 1
	head.Font = Enum.Font.GothamBold
	head.TextScaled = true
	head.TextXAlignment = Enum.TextXAlignment.Left
	head.TextColor3 = accent
	head.Text = title
	head.Parent = col

	local list = Instance.new("Frame")
	list.Name = name .. "List"
	list.Size = UDim2.new(1, 0, 0.89, 0)
	list.Position = UDim2.fromScale(0, 0.11)
	list.BackgroundTransparency = 1
	list.Parent = col

	for i = 1, rows do
		mkRow(list, "Row" .. i, i, 1 / rows)
	end
end

local function mkRankBoard(lobby: Folder)
	-- 서프러스 기준 폭 46 × 높이 26. 이보다 작으면 10줄이 들어가면서 글자가 안 읽힌다.
	local board = mkPart("RankBoard", lobby, Vector3.new(46, 26, 1.6),
		-- yaw +90 이면 LookVector 가 -X = 로비 중심 쪽이다. Front 면이 LookVector 와 같은 방향이라
		-- 부호가 반대면 글씨가 허공을 보고 로비에서는 백면만 보인다.
		CFrame.new(ORIGIN + Vector3.new(40, 17, 8)) * CFrame.Angles(0, math.rad(90), 0),
		BOARD_BG, Enum.Material.SmoothPlastic)
	-- 기둥 두 개로 받친다. 공중에 떠 있으면 구조물로 안 읽힌다.
	for _, sz in ipairs({ -1, 1 }) do
		mkPart("BoardLeg", lobby, Vector3.new(2.5, 14, 2.5),
			CFrame.new(ORIGIN + Vector3.new(40, 7, 8 + sz * 18)), WALL, Enum.Material.Metal)
	end
	mkPart("BoardGlow", lobby, Vector3.new(1.8, 0.8, 46),
		CFrame.new(ORIGIN + Vector3.new(40, 30.2, 8)), GOLD, Enum.Material.Neon)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "RankGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 26
	-- 보드는 로비 반대편에서도 읽혀야 한다. 기본 MaxDistance 로는 가로질러도 꺼진다.
	gui.MaxDistance = 260
	gui.LightInfluence = 0
	gui.Parent = board

	local bg = Instance.new("Frame")
	bg.Name = "BG"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = BOARD_BG
	bg.BackgroundTransparency = 0.15
	bg.BorderSizePixel = 0
	bg.Parent = gui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0.1, 0)
	title.Position = UDim2.fromScale(0, 0.015)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBlack
	title.TextScaled = true
	title.TextColor3 = GOLD
	title.Text = "훅맨 명예의 전당"
	title.Parent = bg

	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.Size = UDim2.new(1, 0, 0.04, 0)
	sub.Position = UDim2.fromScale(0, 0.108)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.Gotham
	sub.TextScaled = true
	sub.TextColor3 = Color3.fromRGB(150, 165, 185)
	sub.Text = "런 1회 최고 점수로 줄을 세운다"
	sub.Parent = bg

	-- 왼쪽 글로벌 10줄 / 오른쪽 이 서버 5줄.
	-- 글로벌은 장기 목표, 서버는 지금 옆 사람과의 경쟁이라 둘을 같이 둔다.
	mkList(bg, "Global", "글로벌 TOP 10", 0.04, 0.5, 10, GOLD)
	mkList(bg, "Server", "이 서버", 0.58, 0.38, 5, ACCENT)
end

function LobbyBuilder.build(): Folder
	local old = workspace:FindFirstChild("HookmanLobby")
	if old then
		old:Destroy()
	end

	local lobby = Instance.new("Folder")
	lobby.Name = "HookmanLobby"

	-- 바닥
	mkPart("Floor", lobby, FLOOR, CFrame.new(ORIGIN), WALL, Enum.Material.Slate)
	mkPart("FloorGlow", lobby, Vector3.new(FLOOR.X - 8, 0.6, FLOOR.Z - 8),
		CFrame.new(ORIGIN + Vector3.new(0, FLOOR.Y / 2 + 0.3, 0)), ACCENT, Enum.Material.Neon).Transparency = 0.55

	-- 난간: 떨어지면 코스 한복판이 아니라 허공이다. 실수로 나가지 못하게 막는다.
	local half = FLOOR.X / 2
	for _, d in ipairs({ Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }) do
		local along = Vector3.new(math.abs(d.Z), 0, math.abs(d.X))
		local size = along * FLOOR.X + Vector3.new(math.abs(d.X) * 3, 0, math.abs(d.Z) * 3) + Vector3.new(0, 14, 0)
		mkPart("Rail", lobby, size,
			CFrame.new(ORIGIN + d * half + Vector3.new(0, 10, 0)), WALL, Enum.Material.Metal)
	end

	-- 기둥 장식: 로비가 텅 비면 "미완성"으로 읽힌다.
	for i = 0, 3 do
		local a = math.pi / 2 * i + math.pi / 4
		local p = ORIGIN + Vector3.new(math.cos(a) * 52, 18, math.sin(a) * 52)
		mkPart("Pillar", lobby, Vector3.new(6, 34, 6), CFrame.new(p), WALL, Enum.Material.Concrete)
		mkPart("PillarTop", lobby, Vector3.new(8, 1.5, 8), CFrame.new(p + Vector3.new(0, 18, 0)), ACCENT, Enum.Material.Neon)
	end

	-- 스폰: 코스가 아니라 여기가 첫 지점이다.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Size = Vector3.new(14, 1, 14)
	spawn.CFrame = CFrame.new(ORIGIN + Vector3.new(0, FLOOR.Y / 2 + 0.5, -30))
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Neutral = true
	spawn.Color = GOLD
	spawn.Material = Enum.Material.Neon
	spawn.Transparency = 0.35
	spawn.Parent = lobby

	-- 상점 키오스크: ProximityPrompt 로 열린다. 자동으로 열면 지나갈 때마다 방해된다.
	local kiosk = mkPart("ShopKiosk", lobby, Vector3.new(12, 14, 6),
		CFrame.new(ORIGIN + Vector3.new(-34, FLOOR.Y / 2 + 7, 20)), Color3.fromRGB(60, 66, 92), Enum.Material.Metal)
	mkPart("KioskGlow", lobby, Vector3.new(12.4, 1.4, 6.4),
		kiosk.CFrame * CFrame.new(0, 7.4, 0), GOLD, Enum.Material.Neon)
	-- 키오스크는 이웃이 없어서 겹칠 일이 없다. 존 패드보다 넉넉히 둔다.
	mkSign(kiosk, "상점", "E 를 눌러 열기", GOLD, 10, 90)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ShopPrompt"
	prompt.ActionText = "상점 열기"
	prompt.ObjectText = "HOOKMAN SHOP"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 18
	prompt.RequiresLineOfSight = false
	prompt.Parent = kiosk

	-- 존 포털 줄: 존마다 패드 하나. 하나짜리 "코스 시작" 버튼은 성장 목표가 안 보인다.
	-- 잠금 표시는 서버가 색으로 못 칠한다(잠금은 플레이어마다 다르다).
	-- 대신 해금 조건을 항상 적어 두고, 밟았을 때 서버가 거절한다.
	local zones = ZoneCatalog.Zones
	local pads = Instance.new("Folder")
	pads.Name = "ZonePads"
	pads.Parent = lobby

	local SPACING = 30
	local x0 = -SPACING * (#zones - 1) / 2
	for i, z in ipairs(zones) do
		local center = ORIGIN + Vector3.new(x0 + SPACING * (i - 1), FLOOR.Y / 2 + 0.8, 46)
		local pad = mkPart("ZonePad_" .. z.id, pads, Vector3.new(24, 1.5, 24), CFrame.new(center), z.color, Enum.Material.Neon)
		pad.CanCollide = false
		pad.Transparency = 0.2
		pad:SetAttribute("ZoneId", z.id)
		local req = z.requireScore > 0 and ("누적 %d점 · 점수 x%.2g"):format(z.requireScore, z.scoreMul)
			or ("해금됨 · 점수 x%.2g"):format(z.scoreMul)
		-- 패드 간격이 30 스터드다. 표지판이 화면 고정 크기라 55 를 넘어가면
		-- 이웃 표지판과 화면에서 겹친다. 그 안에 들어와야만 보이게 자른다.
		mkSign(pad, z.name, req, z.color, 9, 55)

		local ring = mkPart("ZoneRing_" .. z.id, pads, Vector3.new(24, 24, 1.2),
			CFrame.new(center), z.color, Enum.Material.Neon)
		ring.Shape = Enum.PartType.Cylinder
		ring.CFrame = CFrame.new(center + Vector3.new(0, 12, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.CanCollide = false
		ring.Transparency = 0.4
	end

	mkRankBoard(lobby)

	lobby.Parent = workspace
	return lobby
end

-- 랭킹 보드 채우기. 서버가 직접 TextLabel 을 써서 모든 클라이언트에 복제되게 한다.
-- 빈 줄을 지우지 않고 "---" 로 남긴다. 칸이 사라지면 목록 길이가 매번 변해 불안하게 보인다.
function LobbyBuilder.renderRank(lobby: Folder, global: { any }, server: { any })
	local board = lobby:FindFirstChild("RankBoard")
	local gui = board and board:FindFirstChild("RankGui")
	local bg = gui and gui:FindFirstChild("BG")
	if not bg then
		return
	end

	local function fill(colName: string, listName: string, entries: { any })
		local col = bg:FindFirstChild(colName)
		local list = col and col:FindFirstChild(listName)
		if not list then
			return
		end
		for _, row in ipairs(list:GetChildren()) do
			local idx = tonumber(row.Name:match("%d+") or "")
			local rank = row:FindFirstChild("Rank") :: TextLabel?
			local name = row:FindFirstChild("PlayerName") :: TextLabel?
			local score = row:FindFirstChild("Score") :: TextLabel?
			if idx and rank and name and score then
				local e = entries[idx]
				rank.Text = ("%d"):format(idx)
				name.Text = e and e.name or "---"
				score.Text = e and ("%d"):format(e.score) or ""
			end
		end
	end

	fill("GlobalCol", "GlobalList", global)
	fill("ServerCol", "ServerList", server)
end

function LobbyBuilder.spawnPoint(lobby: Folder): Vector3
	local s = lobby:FindFirstChild("LobbySpawn") :: BasePart?
	if s then
		return s.Position + Vector3.new(0, 4, 0)
	end
	return ORIGIN + Vector3.new(0, 10, 0)
end

return LobbyBuilder

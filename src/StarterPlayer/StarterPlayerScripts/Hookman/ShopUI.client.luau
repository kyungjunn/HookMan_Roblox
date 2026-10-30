--!strict
-- HOOKMAN 상점 UI + 코인/점수 HUD.
-- 카탈로그는 ReplicatedStorage 공용 모듈을 그대로 읽는다. 가격을 UI 가 따로 들고 있으면
-- 서버 검증과 어긋나 "살 수 있어 보이는데 안 사지는" 상태가 생긴다.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Hookman")
local ShopCatalog = require(Shared:WaitForChild("ShopCatalog"))
local ZoneCatalog = require(Shared:WaitForChild("ZoneCatalog"))

local player = Players.LocalPlayer
local profileEvent = ReplicatedStorage:WaitForChild("HookmanProfile") :: RemoteEvent
local shopFn = ReplicatedStorage:WaitForChild("HookmanShop") :: RemoteFunction
local runEvent = ReplicatedStorage:WaitForChild("HookmanRun") :: RemoteEvent
local snapshotFn = ReplicatedStorage:WaitForChild("HookmanSnapshot") :: RemoteFunction
local profileReady = false
local profileRevision = -1
local runState = "Lobby"
local runVersion = -1
local requestBusy = false

-- 서버가 보낸 마지막 스냅샷. UI 는 이것만 보고 그린다.
local profile = {
	coins = 0,
	owned = {} :: { [string]: boolean },
	equipped = { hook = ShopCatalog.Defaults.hook, aura = ShopCatalog.Defaults.aura },
	runScore = 0,
	bestScore = 0,
	lifetimeScore = 0,
	zone = ZoneCatalog.Default,
}
local currentTab = "hook"

----------------------------------------------------------------------
-- 위젯
----------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "HookmanShopGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 5
gui.Parent = player:WaitForChild("PlayerGui")

local function corner(inst: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = inst
end

local function stroke(inst: Instance, color: Color3, th: number)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = th
	s.Parent = inst
	return s
end

-- 코인/점수 바: 상점이 닫혀 있어도 항상 보인다.
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.fromOffset(320, 44)
topBar.Position = UDim2.new(1, -338, 0, 14)
topBar.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
topBar.BackgroundTransparency = 0.25
topBar.Parent = gui
corner(topBar, 10)
stroke(topBar, Color3.fromRGB(70, 84, 110), 1.5)

local coinLabel = Instance.new("TextLabel")
coinLabel.Size = UDim2.new(0.5, 0, 1, 0)
coinLabel.BackgroundTransparency = 1
coinLabel.Font = Enum.Font.GothamBold
coinLabel.TextSize = 20
coinLabel.TextColor3 = Color3.fromRGB(255, 214, 64)
coinLabel.Text = "◈ 0"
coinLabel.Parent = topBar

local scoreLabel = Instance.new("TextLabel")
scoreLabel.Size = UDim2.new(0.5, 0, 1, 0)
scoreLabel.Position = UDim2.fromScale(0.5, 0)
-- 아래 줄에 성장 지표를 따로 둔다. 코인(소모재)과 누적 점수(해금 게이지)를
-- 같은 줄에 붙여 놓으면 둘이 같은 자원처럼 읽혀서 존 해금 목표가 안 보인다.
scoreLabel.BackgroundTransparency = 1
scoreLabel.Font = Enum.Font.GothamBold
scoreLabel.TextSize = 20
scoreLabel.TextColor3 = Color3.fromRGB(230, 240, 255)
scoreLabel.Text = "SCORE 0"
scoreLabel.Parent = topBar

local zoneBar = Instance.new("Frame")
zoneBar.Name = "ZoneBar"
zoneBar.Size = UDim2.fromOffset(320, 52)
zoneBar.Position = UDim2.new(1, -338, 0, 64)
zoneBar.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
zoneBar.BackgroundTransparency = 0.3
zoneBar.Parent = gui
corner(zoneBar, 10)
stroke(zoneBar, Color3.fromRGB(70, 84, 110), 1.5)

local zoneLabel = Instance.new("TextLabel")
zoneLabel.Size = UDim2.new(1, -16, 0, 24)
zoneLabel.Position = UDim2.fromOffset(8, 4)
zoneLabel.BackgroundTransparency = 1
zoneLabel.Font = Enum.Font.GothamBold
zoneLabel.TextSize = 17
zoneLabel.TextColor3 = Color3.fromRGB(120, 220, 255)
zoneLabel.Text = ""
zoneLabel.Parent = zoneBar

local unlockLabel = Instance.new("TextLabel")
unlockLabel.Size = UDim2.new(1, -16, 0, 20)
unlockLabel.Position = UDim2.fromOffset(8, 28)
unlockLabel.BackgroundTransparency = 1
unlockLabel.Font = Enum.Font.Gotham
unlockLabel.TextSize = 14
unlockLabel.TextColor3 = Color3.fromRGB(180, 195, 215)
unlockLabel.Text = ""
unlockLabel.Parent = zoneBar

-- 내 순위 바.
-- 로비 랭킹 보드는 모두에게 같은 표라 "내가 몇 위인지"를 못 적는다.
-- 그건 개인 HUD 의 일이고, 서버가 프로필 동기화에 실어 보낸다.
local rankBar = Instance.new("Frame")
rankBar.Name = "RankBar"
rankBar.Size = UDim2.fromOffset(320, 42)
rankBar.Position = UDim2.new(1, -338, 0, 122)
rankBar.BackgroundColor3 = Color3.fromRGB(16, 20, 30)
rankBar.BackgroundTransparency = 0.3
rankBar.Parent = gui
corner(rankBar, 10)
stroke(rankBar, Color3.fromRGB(70, 84, 110), 1.5)

local bestLabel = Instance.new("TextLabel")
bestLabel.Size = UDim2.new(1, -16, 0, 20)
bestLabel.Position = UDim2.fromOffset(8, 3)
bestLabel.BackgroundTransparency = 1
bestLabel.Font = Enum.Font.GothamBold
bestLabel.TextSize = 15
bestLabel.TextXAlignment = Enum.TextXAlignment.Left
bestLabel.TextColor3 = Color3.fromRGB(255, 214, 64)
bestLabel.Text = ""
bestLabel.Parent = rankBar

local rankLabel = Instance.new("TextLabel")
rankLabel.Size = UDim2.new(1, -16, 0, 18)
rankLabel.Position = UDim2.fromOffset(8, 22)
rankLabel.BackgroundTransparency = 1
rankLabel.Font = Enum.Font.Gotham
rankLabel.TextSize = 14
rankLabel.TextXAlignment = Enum.TextXAlignment.Left
rankLabel.TextColor3 = Color3.fromRGB(180, 195, 215)
rankLabel.Text = ""
rankLabel.Parent = rankBar

----------------------------------------------------------------------
-- 상점 패널
----------------------------------------------------------------------
local panel = Instance.new("Frame")
panel.Name = "ShopPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(720, 480)
panel.BackgroundColor3 = Color3.fromRGB(14, 18, 27)
panel.Visible = false
panel.Parent = gui
corner(panel, 16)
stroke(panel, Color3.fromRGB(90, 180, 255), 2)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -24, 0, 52)
title.Position = UDim2.fromOffset(20, 10)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 30
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(255, 214, 64)
title.Text = "HOOKMAN SHOP"
title.Parent = panel

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromOffset(40, 40)
closeBtn.Position = UDim2.new(1, -52, 0, 14)
closeBtn.BackgroundColor3 = Color3.fromRGB(40, 46, 62)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 22
closeBtn.TextColor3 = Color3.fromRGB(235, 240, 250)
closeBtn.Text = "X"
closeBtn.Parent = panel
corner(closeBtn, 10)

-- 탭
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -40, 0, 40)
tabBar.Position = UDim2.fromOffset(20, 64)
tabBar.BackgroundTransparency = 1
tabBar.Parent = panel
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 10)
tabLayout.Parent = tabBar

local list = Instance.new("ScrollingFrame")
list.Size = UDim2.new(1, -40, 1, -180)
list.Position = UDim2.fromOffset(20, 112)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 6
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.Parent = panel
local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 8)
listLayout.Parent = list

local toast = Instance.new("TextLabel")
toast.Size = UDim2.new(1, -40, 0, 34)
toast.Position = UDim2.new(0, 20, 1, -54)
toast.BackgroundTransparency = 1
toast.Font = Enum.Font.GothamBold
toast.TextSize = 20
toast.TextColor3 = Color3.fromRGB(255, 214, 64)
toast.Text = ""
toast.Parent = panel

local function flashToast(msg: string, ok: boolean)
	toast.Text = msg
	toast.TextColor3 = ok and Color3.fromRGB(120, 235, 140) or Color3.fromRGB(255, 110, 110)
	toast.TextTransparency = 0
	TweenService:Create(toast, TweenInfo.new(1.6), { TextTransparency = 1 }):Play()
end

----------------------------------------------------------------------
-- 렌더
----------------------------------------------------------------------
local tabButtons: { [string]: TextButton } = {}
local redraw -- 전방 선언 (탭 버튼 콜백이 참조)

local function mkTab(kind: string, label: string)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(140, 40)
	b.BackgroundColor3 = Color3.fromRGB(32, 38, 52)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 18
	b.TextColor3 = Color3.fromRGB(200, 212, 228)
	b.Text = label
	b.Parent = tabBar
	corner(b, 10)
	b.Activated:Connect(function()
		currentTab = kind
		redraw()
	end)
	tabButtons[kind] = b
end
mkTab("hook", "훅 / 로프")
mkTab("aura", "오오라")
mkTab("ability", "능력")

local function request(action: string, id: string)
	if not profileReady or runState ~= "Lobby" or requestBusy then
		return
	end
	requestBusy = true
	local ok, res = pcall(function()
		return shopFn:InvokeServer(action, id)
	end)
	requestBusy = false
	if ok and type(res) == "table" then
		flashToast(res.msg or "", res.ok == true)
	elseif not ok then
		flashToast("상점 요청 실패 · 다시 시도하세요", false)
	end
end

local function mkRow(item, order: number)
	local owned = profile.owned[item.id] == true
	local equipped = profile.equipped[item.kind] == item.id

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -8, 0, 66)
	row.LayoutOrder = order
	row.BackgroundColor3 = Color3.fromRGB(24, 29, 41)
	row.Parent = list
	corner(row, 10)
	if equipped then
		stroke(row, Color3.fromRGB(120, 235, 140), 2)
	end

	-- 색상 스와치: 아이템의 실제 색을 보여주는 게 이름보다 빠르다.
	local sw = Instance.new("Frame")
	sw.Size = UDim2.fromOffset(46, 46)
	sw.Position = UDim2.fromOffset(10, 10)
	sw.BackgroundColor3 = item.color
	sw.Parent = row
	corner(sw, 8)

	local name = Instance.new("TextLabel")
	name.Size = UDim2.fromOffset(300, 26)
	name.Position = UDim2.fromOffset(68, 10)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextSize = 19
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextColor3 = Color3.fromRGB(240, 246, 255)
	name.Text = item.name .. (equipped and "  ·  장착 중" or "")
	name.Parent = row

	local desc = Instance.new("TextLabel")
	desc.Size = UDim2.fromOffset(420, 22)
	desc.Position = UDim2.fromOffset(68, 34)
	desc.BackgroundTransparency = 1
	desc.Font = Enum.Font.Gotham
	desc.TextSize = 15
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.TextColor3 = Color3.fromRGB(160, 175, 195)
	desc.Text = item.desc
	desc.Parent = row

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(150, 42)
	btn.Position = UDim2.new(1, -162, 0, 12)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 17
	btn.Parent = row
	corner(btn, 9)

	if not profileReady then
		btn.Text = "불러오는 중"
		btn.BackgroundColor3 = Color3.fromRGB(44, 46, 54)
		btn.TextColor3 = Color3.fromRGB(130, 138, 150)
		btn.Active = false
		btn.AutoButtonColor = false
	elseif equipped then
		btn.Text = "장착됨"
		btn.BackgroundColor3 = Color3.fromRGB(34, 60, 44)
		btn.TextColor3 = Color3.fromRGB(150, 220, 170)
		btn.AutoButtonColor = false
	elseif owned then
		btn.Text = "장착"
		btn.BackgroundColor3 = Color3.fromRGB(40, 74, 110)
		btn.TextColor3 = Color3.fromRGB(225, 240, 255)
		btn.Activated:Connect(function()
			request("equip", item.id)
		end)
	else
		local afford = profile.coins >= item.price
		btn.Text = ("◈ %d"):format(item.price)
		btn.BackgroundColor3 = afford and Color3.fromRGB(96, 72, 20) or Color3.fromRGB(44, 46, 54)
		btn.TextColor3 = afford and Color3.fromRGB(255, 214, 64) or Color3.fromRGB(130, 138, 150)
		btn.Activated:Connect(function()
			request("buy", item.id)
		end)
	end
end

redraw = function()
	coinLabel.Text = ("◈ %d"):format(profile.coins)
	scoreLabel.Text = ("SCORE %d"):format(profile.runScore)

	local zone = ZoneCatalog.resolve(profile.zone)
	zoneLabel.Text = ("%s · 점수 x%.2g"):format(zone.name, zone.scoreMul)
	zoneLabel.TextColor3 = zone.color
	-- 다음 목표가 안 보이면 누적 점수는 그냥 늘어나는 숫자다.
	local nextZone, remain = ZoneCatalog.nextLocked(profile.lifetimeScore)
	if nextZone then
		unlockLabel.Text = ("누적 %d  ·  %s 까지 %d"):format(profile.lifetimeScore, nextZone.name, remain)
	else
		unlockLabel.Text = ("누적 %d  ·  모든 존 해금"):format(profile.lifetimeScore)
	end

	-- 랭킹은 런 1회 최고 점수 기준이다. 누적 점수(해금축)과 혼동하면
	-- "오래 한 사람이 이기는 표"로 읽혀 경쟁이 안 된다. 라벨에 명시한다.
	bestLabel.Text = ("최고 런 %d"):format(profile.bestScore or 0)
	local g = profile.rank
	local s = profile.serverRank
	rankLabel.Text = ("글로벌 %s  ·  이 서버 %s"):format(
		g and ("#%d"):format(g) or "TOP10 밖",
		s and ("#%d"):format(s) or "-"
	)

	for kind, b in pairs(tabButtons) do
		local on = kind == currentTab
		b.BackgroundColor3 = on and Color3.fromRGB(58, 96, 140) or Color3.fromRGB(32, 38, 52)
		b.TextColor3 = on and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(200, 212, 228)
	end

	if not panel.Visible then
		return
	end
	for _, c in ipairs(list:GetChildren()) do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	for i, item in ipairs(ShopCatalog.byKind(currentTab)) do
		mkRow(item, i)
	end
end

local function setOpen(open: boolean)
	panel.Visible = open and profileReady and runState == "Lobby"
	if panel.Visible then
		redraw()
	end
end

closeBtn.Activated:Connect(function()
	setOpen(false)
end)

----------------------------------------------------------------------
-- 연결
----------------------------------------------------------------------
local function applyRun(packet)
	if
		type(packet) ~= "table"
		or type(packet.version) ~= "number"
		or packet.version ~= packet.version
		or packet.version == math.huge
		or packet.version % 1 ~= 0
		or packet.version <= runVersion
	then
		return
	end
	local states =
		{ Lobby = true, Preparing = true, Running = true, Resetting = true, Settling = true, Returning = true }
	if not states[packet.state] then
		return
	end
	runVersion, runState = packet.version, packet.state
	if runState ~= "Lobby" then
		setOpen(false)
	end
end

local function applyProfile(snap)
	if type(snap) ~= "table" then
		return
	end
	if snap.run then
		applyRun(snap.run)
	end
	local revision = snap.revision
	if type(revision) == "number" then
		if revision ~= revision or revision == math.huge or revision % 1 ~= 0 or revision <= profileRevision then
			return
		end
		profileRevision = revision
	elseif profileRevision >= 0 then
		return
	end
	profileReady = snap.ready == true
	if not profileReady then
		setOpen(false)
		return
	end
	profile = snap
	redraw()
end

profileEvent.OnClientEvent:Connect(applyProfile)
runEvent.OnClientEvent:Connect(applyRun)

-- 상점은 로비 키오스크의 ProximityPrompt 로만 열린다.
-- 코스 중에 열리면 시야를 가리고 조작을 먹는다.
local ProximityPromptService = game:GetService("ProximityPromptService")
ProximityPromptService.PromptTriggered:Connect(function(prompt, plr)
	if plr == player and prompt.Name == "ShopPrompt" then
		setOpen(true)
	end
end)

-- 잠긴 존 패드를 밟았을 때: 왜 안 되는지 화면으로 말해 준다.
local zoneEvent = ReplicatedStorage:WaitForChild("HookmanZone") :: RemoteEvent
zoneEvent.OnClientEvent:Connect(function(ok: boolean, zid: string, need: number)
	if ok then
		return
	end
	local z = ZoneCatalog.get(zid)
	setOpen(false)
	flashToast(("%s 잠김 — 누적 %d점 필요"):format(z and z.name or zid, need), false)
	-- 상점이 닫혀 있으면 toast 가 안 보인다. 판정 라벨 자리를 빌린다.
	toast.Parent = panel.Visible and panel or gui
	if not panel.Visible then
		toast.Position = UDim2.new(0.5, -200, 0.6, 0)
		toast.Size = UDim2.fromOffset(400, 34)
	end
end)

-- 런이 시작되면 무조건 닫는다.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Escape and panel.Visible then
		setOpen(false)
	end
end)

redraw()
task.spawn(function()
	for attempt = 1, 8 do
		local ok, snap = pcall(function()
			return snapshotFn:InvokeServer()
		end)
		if ok then
			applyProfile(snap)
		end
		if profileReady then
			return
		end
		if attempt < 8 then
			task.wait(1)
		end
	end
end)

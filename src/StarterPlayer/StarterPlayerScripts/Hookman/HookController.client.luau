--!strict
-- HOOKMAN P1 클라이언트 컨트롤러
-- 입력 3개: [탭/클릭] 훅 자동부착  [Space] 릴리즈 판정  [A/D 홀드] 턴(P2)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Hookman")
local Config = require(Shared:WaitForChild("Config"))
local ReleaseJudge = require(Shared:WaitForChild("ReleaseJudge"))
local TrickAnimator = require(Shared:WaitForChild("TrickAnimator"))
local CameraFX = require(Shared:WaitForChild("CameraFX"))
local CoursePath = require(Shared:WaitForChild("CoursePath"))
local ShopCatalog = require(Shared:WaitForChild("ShopCatalog"))

local player = Players.LocalPlayer
local actionEvent = ReplicatedStorage:WaitForChild("HookmanAction") :: RemoteEvent
local verdictEvent = ReplicatedStorage:WaitForChild("HookmanVerdict") :: RemoteEvent
local snapshotFn = ReplicatedStorage:WaitForChild("HookmanSnapshot") :: RemoteFunction
local runEvent = ReplicatedStorage:WaitForChild("HookmanRun") :: RemoteEvent
local profileEvent = ReplicatedStorage:WaitForChild("HookmanProfile") :: RemoteEvent
local runId = ""
local runVersion = -1
local runState = "Lobby"
local runCourse: Folder? = nil
local path: any = nil
local level = 1
local sequence = 0
local verdictSequence = 0
local latestAction = ""
local profileRevision = -1
local profileReady = false
local releaseButton: TextButton? = nil

local function running(): boolean
	return profileReady and runState == "Running" and runCourse ~= nil and runCourse.Parent ~= nil and path ~= nil
end

local function sendAction(action: string, hookId: string?, secondary: boolean?)
	sequence += 1
	latestAction = action
	actionEvent:FireServer({
		runId = runId,
		sequence = sequence,
		action = action,
		hookId = hookId,
		secondary = secondary,
	})
end

----------------------------------------------------------------------
-- 상태
----------------------------------------------------------------------
local state = {
	character = nil :: Model?,
	hrp = nil :: BasePart?,
	humanoid = nil :: Humanoid?,
	attachPart = nil :: BasePart?,
	rope = nil :: RopeConstraint?,
	hookAtt = nil :: Attachment?,
	bodyAtt = nil :: Attachment?,
	beam = nil :: Beam?,
	-- 듀얼 로프(능력)용 두 번째 줄. 판정·곡예는 항상 1번 줄 기준이다.
	rope2 = nil :: RopeConstraint?,
	beam2 = nil :: Beam?,
	hookAtt2 = nil :: Attachment?,
	bodyAtt2 = nil :: Attachment?,
	attachPart2 = nil :: BasePart?,
	align = nil :: AlignOrientation?,
	assistForce = nil :: VectorForce?,
	lastSide = 0, -- -1 왼쪽, 1 오른쪽
	holdSide = 0, -- Q/E 홀드 조향 방향 (-1 왼쪽, 1 오른쪽)
	holdStart = 0,
	combo = 0,
	bestCombo = 0,
	perfectCount = 0,
	attachedAt = 0,
}

local candidates: { BasePart } = {}

----------------------------------------------------------------------
-- 장착 아이템
-- 서버가 프로필을 밀어줄 때만 갱신한다. 클라이언트가 자기 마음대로 바꿔도
-- 점수는 서버가 서버 프로필로 계산하므로 시각/체감만 어긋날 뿐 이득이 없다.
----------------------------------------------------------------------
local equipped = { hook = ShopCatalog.Defaults.hook, aura = ShopCatalog.Defaults.aura }
local effect = ShopCatalog.effectOf(equipped)
local auraEmitter: ParticleEmitter? = nil

local function hookItem()
	return ShopCatalog.get(equipped.hook) or ShopCatalog.get(ShopCatalog.Defaults.hook)
end

-- 오오라: 캐릭터 몸통에 파티클 하나. 장착이 바뀌면 색/밀도만 갈아끼운다.
-- 매번 새로 만들면 리스폰·재장착이 반복될 때 이미터가 쌓인다.
local function refreshAura()
	local item = ShopCatalog.get(equipped.aura)
	local hrp = state.hrp
	if not hrp then
		return
	end
	if not auraEmitter or auraEmitter.Parent ~= hrp then
		if auraEmitter then
			auraEmitter:Destroy()
		end
		local e = Instance.new("ParticleEmitter")
		e.Name = "HookmanAura"
		e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		e.Size = NumberSequence.new(2.2)
		e.Transparency = NumberSequence.new(0.35)
		e.Lifetime = NumberRange.new(0.4, 0.8)
		e.Speed = NumberRange.new(2, 6)
		e.SpreadAngle = Vector2.new(180, 180)
		e.LightEmission = 1
		e.Parent = hrp
		auraEmitter = e
	end
	local on = item ~= nil and item.id ~= ShopCatalog.Defaults.aura;
	(auraEmitter :: ParticleEmitter).Enabled = on
	if on and item then
		(auraEmitter :: ParticleEmitter).Color = ColorSequence.new(item.color); -- 강한 오오라일수록 눈에 띄어야 한다. accelMul 을 그대로 밀도로 쓴다.
		(auraEmitter :: ParticleEmitter).Rate = 18 + (item.effect.accelMul - 1) * 400
	end
end

local function courseLevel(): number
	return level
end

-- 지상 훅 차단
-- attach() 는 부착 순간 PlatformStand 를 켠다. 발이 바닥에 닿아 있으면
-- 로프 장력이 몸을 들어올리지 못해 랙돌이 그대로 누워버린다
-- (레벨 시작 직후, 낙하 전 발판 위에서 Q/E 를 누르면 재현).
-- 이미 한 줄이 걸린 상태는 예외다. 듀얼 로프의 두 번째 줄까지 막으면 안 된다.
local function groundedNoRope(): boolean
	if state.rope then
		return false
	end
	local hum = state.humanoid
	if not hum then
		return false
	end
	return hum.FloorMaterial ~= Enum.Material.Air
end

----------------------------------------------------------------------
-- 조준축: "내가 바라보는 방향"
-- 코스 접선은 지형이 어디로 이어지는지일 뿐, 플레이어 의도가 아니다.
-- 접선을 축으로 쓰면 시선을 어디로 돌리든 같은 곳으로 날아가 조작감이 죽는다.
----------------------------------------------------------------------
-- 카메라가 거의 수직(바닥/하늘 직시)이면 수평 성분이 사라진다. 그때만 접선으로 폴백한다.
local function aimForward(pos: Vector3): Vector3
	local camera = workspace.CurrentCamera
	if Config.Aim.UseCamera and camera then
		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude >= Config.Aim.MinFlat then
			return flat.Unit
		end
	end
	return path:forwardAt(pos)
end

local function aimRight(pos: Vector3): Vector3
	return aimForward(pos):Cross(Vector3.yAxis)
end

-- 수평 속도를 조준축 쪽으로 alpha 만큼 "회전"시킨다. 크기는 반드시 보존한다.
-- 크기까지 건드리면 판정 보상(speedMul)과 이중으로 곱해져 속도가 튄다.
local function steerFlat(v: Vector3, aim: Vector3, alpha: number): Vector3
	local flat = Vector3.new(v.X, 0, v.Z)
	local spd = flat.Magnitude
	if spd < 1 then
		return v
	end
	local dir = flat.Unit:Lerp(aim, math.clamp(alpha, 0, 1))
	-- 시선이 진행 방향과 정반대면 보간 결과가 0 벡터가 된다. 그때는 원래 방향을 지킨다.
	if dir.Magnitude < 1e-3 then
		return v
	end
	dir = dir.Unit
	return Vector3.new(dir.X * spd, v.Y, dir.Z * spd)
end

----------------------------------------------------------------------
-- HUD
----------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "HookmanHUD"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local function mkLabel(name: string, size: UDim2, pos: UDim2, textSize: number)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Size = size
	l.Position = pos
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamBold
	l.TextSize = textSize
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextStrokeTransparency = 0.4
	l.Text = ""
	l.Parent = gui
	return l
end

local judgeLabel = mkLabel("Judge", UDim2.fromScale(1, 0.12), UDim2.fromScale(0, 0.30), 56)
judgeLabel.TextTransparency = 1
local comboLabel = mkLabel("Combo", UDim2.fromScale(1, 0.08), UDim2.fromScale(0, 0.42), 32)
local speedLabel = mkLabel("Speed", UDim2.new(0, 240, 0, 30), UDim2.new(0, 18, 1, -46), 20)
speedLabel.TextXAlignment = Enum.TextXAlignment.Left
local hintLabel = mkLabel("Hint", UDim2.fromScale(1, 0.06), UDim2.fromScale(0, 0.86), 22)
hintLabel.Text =
	"Q/E = 좌·우 훅 (꾹 = 턴 · 듀얼 로프면 둘 다 부착)   ·   SPACE = 점프 릴리즈(공중제비)"

-- 클리어 배너: 골 도달을 화면으로 확실히 알린다.
local clearLabel = mkLabel("Clear", UDim2.fromScale(1, 0.16), UDim2.fromScale(0, 0.34), 84)
clearLabel.TextColor3 = Color3.fromRGB(255, 214, 64)
clearLabel.TextTransparency = 1
local clearSub = mkLabel("ClearSub", UDim2.fromScale(1, 0.08), UDim2.fromScale(0, 0.50), 30)
clearSub.TextColor3 = Color3.fromRGB(235, 245, 255)
clearSub.TextTransparency = 1

task.spawn(function()
	local goalEvent = ReplicatedStorage:WaitForChild("HookmanGoal") :: RemoteEvent
	-- 서버는 (경과시간, 레벨, 런 점수, 획득 코인)을 보낸다.
	-- 코인 획득을 안 보여주면 상점이 왜 채워지는지 모른 채 숫자만 늘어난다.
	goalEvent.OnClientEvent:Connect(
		function(
			elapsed: number,
			lv: number?,
			score: number?,
			coins: number?,
			_zoneId: string?,
			saved: boolean?,
			completedRunId: string
		)
			if completedRunId ~= runId or (runState ~= "Running" and runState ~= "Settling") then
				return
			end
			clearLabel.Text = "CLEAR!"
			clearSub.Text = ("%.2f초   ·   SCORE %d   ·   ◈ +%d%s"):format(
				elapsed,
				score or 0,
				coins or 0,
				saved == false and " · 저장 실패" or ""
			)
			clearLabel.TextTransparency = 0
			clearSub.TextTransparency = 0
			CameraFX.judgeHit("PERFECT")
			-- 클리어로 런이 끝난다. 골 도달은 리스폰을 거치지 않아 bind() 가 안 불리므로
			-- 여기서 런 누적치를 직접 끊지 않으면 콤보/퍼펙트가 다음 레이스로 이어진다.
			state.combo = 0
			state.bestCombo = 0
			state.perfectCount = 0
			comboLabel.Text = ""
			-- 서버는 CLEAR_DELAY(1.5초) 뒤에 로비로 보낸다. 배너가 그보다 길게 남으면
			-- 로비에 도착한 뒤에도 CLEAR! 가 떠 있어 상태 전환이 안 읽힌다.
			task.delay(1, function()
				if completedRunId ~= runId then
					return
				end
				TweenService:Create(clearLabel, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
				TweenService:Create(clearSub, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
			end)
		end
	)
end)
hintLabel.TextTransparency = 0.25

-- 최하점 예고 링 (타이밍을 눈으로 학습시키는 장치)
local telegraph = Instance.new("Frame")
telegraph.Name = "Telegraph"
telegraph.AnchorPoint = Vector2.new(0.5, 0.5)
telegraph.Position = UDim2.fromScale(0.5, 0.62)
telegraph.Size = UDim2.fromOffset(0, 0)
telegraph.BackgroundTransparency = 1
telegraph.BorderSizePixel = 0
telegraph.Parent = gui
local telStroke = Instance.new("UIStroke")
telStroke.Thickness = 3
telStroke.Color = Color3.fromRGB(255, 214, 64)
telStroke.Transparency = 1
telStroke.Parent = telegraph
local telCorner = Instance.new("UICorner")
telCorner.CornerRadius = UDim.new(1, 0)
telCorner.Parent = telegraph

-- Q(왼쪽) / E(오른쪽) 각각 어디에 걸릴지를 동시에 보여준다.
-- 키가 좌우로 갈렸으므로 프리뷰도 좌우 두 개여야 의미가 있다.
local function mkPreview(label: string, color: Color3)
	local hl = Instance.new("Highlight")
	hl.Name = "HookPreview" .. label
	hl.FillColor = color
	hl.FillTransparency = 0.55
	hl.OutlineColor = Color3.fromRGB(255, 250, 230)
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = false
	hl.Parent = workspace

	local tag = Instance.new("BillboardGui")
	tag.Name = "HookPreviewTag" .. label
	tag.Size = UDim2.fromOffset(80, 28)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 5, 0)
	tag.AlwaysOnTop = true
	tag.Enabled = false
	tag.Parent = gui
	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.fromScale(1, 1)
	txt.BackgroundTransparency = 1
	txt.Font = Enum.Font.GothamBold
	txt.TextSize = 22
	txt.TextColor3 = color
	txt.TextStrokeTransparency = 0.3
	txt.Text = label
	txt.Parent = tag

	return { hl = hl, tag = tag }
end

local previewL = mkPreview("Q", Color3.fromRGB(120, 200, 255))
local previewR = mkPreview("E", Color3.fromRGB(255, 170, 90))

local function showPreview(p, part: BasePart?)
	if part then
		p.hl.Adornee = part
		p.tag.Adornee = part
		p.hl.Enabled = true
		p.tag.Enabled = true
	else
		p.hl.Enabled = false
		p.tag.Enabled = false
	end
end

local function flashJudge(grade: string, color: Color3)
	judgeLabel.Text = grade
	judgeLabel.TextColor3 = color
	judgeLabel.TextTransparency = 0
	judgeLabel.TextSize = grade == "PERFECT" and 76 or 56
	TweenService:Create(judgeLabel, TweenInfo.new(0.55, Enum.EasingStyle.Quad), {
		TextTransparency = 1,
		TextSize = 40,
	}):Play()
end

-- 프로필 동기화: 코인·보유·장착. 장착이 바뀌면 즉시 로프/오오라에 반영한다.
-- 장애물 피격: 원인을 화면으로 알려주지 않으면 그냥 버그처럼 보인다.
-- flashJudge 정의 뒤에 붙여야 한다. 위에 두면 클로저가 전역 nil 을 잡아 런타임 에러가 난다.
task.spawn(function()
	local hazardEvent = ReplicatedStorage:WaitForChild("HookmanHazard") :: RemoteEvent
	hazardEvent.OnClientEvent:Connect(function(hazardRunId: string)
		if hazardRunId ~= runId or not running() then
			return
		end
		state.combo = 0
		comboLabel.Text = ""
		flashJudge("HIT!", Color3.fromRGB(255, 80, 80))
		CameraFX.judgeHit("MISS")
	end)
end)

----------------------------------------------------------------------
-- 훅 후보 캐싱
----------------------------------------------------------------------
local function refreshCandidates()
	candidates = {}
	local hooks = runCourse and runCourse:FindFirstChild("HookPoints")
	if not running() or not hooks then
		return
	end
	for _, inst in ipairs(hooks:GetChildren()) do
		if inst:IsA("BasePart") then
			table.insert(candidates, inst)
		end
	end
end
refreshCandidates()
task.spawn(function()
	while true do
		task.wait(2)
		refreshCandidates()
	end
end)

----------------------------------------------------------------------
-- 자동 타게팅: 조준 없음. "언제 쏘느냐"만 플레이어 몫.
----------------------------------------------------------------------
-- side: -1 왼쪽 건물, 1 오른쪽 건물, 0 아무 쪽이나
local function pickHookPoint(side: number?): BasePart?
	local hrp = state.hrp
	if not running() or not hrp then
		return nil
	end
	local want = side or 0
	local origin = hrp.Position
	-- 진행 방향은 속도가 아니라 코스 경로의 접선이다.
	-- 코스가 지그재그로 꺾이므로 "전방 = +Z" 고정은 커브에서 전부 깨진다.
	local frame = path:frame(origin)
	-- 전방은 코스 접선이 아니라 시선이다. 고개를 돌리면 걸리는 훅이 바뀐다.
	-- 좌/우 판정축(right)만 코스 기준으로 남긴다. 훅의 Side 속성이 코스 기준으로 박혀 있다.
	local forward = aimForward(origin)
	local right = frame.right
	-- 홀드 조향 중에는 탐색 축 자체를 그 방향으로 기울여, 꺾는 쪽 훅이 잡히게 한다.
	if state.holdSide ~= 0 and os.clock() - state.holdStart >= Config.Turn.HoldTime then
		local yaw = math.rad(Config.Turn.YawAssistDeg) * -state.holdSide
		forward = (CFrame.fromAxisAngle(Vector3.yAxis, yaw) * forward).Unit
	end

	local H = Config.Hook
	local best, bestScore = nil, -math.huge

	for _, part in ipairs(candidates) do
		if not part.Parent or part.Parent ~= (runCourse :: Folder):FindFirstChild("HookPoints") then
			continue
		end
		local rel = part.Position - origin
		local dist = rel.Magnitude
		-- 좌/우는 X 부호가 아니라 경로 기준이다. 빌더가 생성 시점에 Side 를 박아 둔다.
		local partSide = (part:GetAttribute("Side") :: number?) or (rel:Dot(right) < 0 and -1 or 1)
		local flatRel = Vector3.new(rel.X, 0, rel.Z)
		local fwdDist = flatRel:Dot(forward)
		if
			(want == 0 or partSide == want)
			and dist >= H.MinRange
			and dist <= H.MaxRange
			and rel.Y > -H.MaxDrop
			and fwdDist >= H.MinForwardZ
		then
			if flatRel.Magnitude > 1 then
				local ang = math.deg(math.acos(math.clamp(flatRel.Unit:Dot(forward), -1, 1)))
				if ang <= H.MaxAngleDeg then
					-- 기본 점수: 가까울수록/전방일수록 유리
					local score = (1 - dist / H.MaxRange) * 40 + (1 - ang / H.MaxAngleDeg) * 60
					score += rel.Y * H.HeightBonus * 10 -- 고도 이득 선호
					score += fwdDist * H.ForwardBonus -- 경로를 따라 멀리 전진하는 훅 선호
					if state.lastSide ~= 0 and partSide ~= state.lastSide then
						score *= H.OppositeSideBonus -- 지그재그 유도
					end
					if state.holdSide ~= 0 and partSide == state.holdSide then
						score *= Config.Turn.AssistBonus -- 홀드한 방향으로 코스를 꺾는다
					end
					if score > bestScore then
						best, bestScore = part, score
					end
				end
			end
		end
	end
	return best
end

----------------------------------------------------------------------
-- 부착 / 해제
----------------------------------------------------------------------
local function detach(applyMul: number?, launchUp: number?)
	if state.rope then
		state.rope:Destroy()
	end
	if state.beam then
		state.beam:Destroy()
	end
	-- 두 번째 줄도 같이 끊는다. 한쪽만 남기면 릴리즈 후에도 몸이 끌려간다.
	if state.rope2 then
		state.rope2:Destroy()
	end
	if state.beam2 then
		state.beam2:Destroy()
	end
	if state.hookAtt2 then
		state.hookAtt2:Destroy()
	end
	if state.bodyAtt2 then
		state.bodyAtt2:Destroy()
	end
	state.rope2, state.beam2, state.hookAtt2, state.bodyAtt2 = nil, nil, nil, nil
	state.attachPart2 = nil
	if state.hookAtt then
		state.hookAtt:Destroy()
	end
	if state.bodyAtt then
		state.bodyAtt:Destroy()
	end
	if state.align then
		state.align:Destroy()
	end
	if state.assistForce then
		state.assistForce:Destroy()
	end
	state.align = nil
	state.assistForce = nil
	state.rope, state.beam, state.hookAtt, state.bodyAtt = nil, nil, nil, nil
	state.attachPart = nil
	telStroke.Transparency = 1

	local hum = state.humanoid
	if hum then
		hum.PlatformStand = false
	end

	local hrp = state.hrp
	if hrp and applyMul then
		local v = hrp.AssemblyLinearVelocity * applyMul
		-- 판정 보상: 최소 상승 속도 보장. 진자만으로는 매 스윙 고도가 깎여 추락한다.
		if launchUp and v.Y < launchUp then
			v = Vector3.new(v.X, launchUp, v.Z)
		end
		-- 사출 방향을 시선 쪽으로 꺾는다. 진자 접선 그대로 놓으면
		-- 카메라를 어디로 돌리든 같은 곳으로 날아가 "내가 조준한다"는 감각이 없다.
		v = steerFlat(v, aimForward(hrp.Position), Config.Aim.ReleaseAlign)
		-- 캡을 수평/수직으로 분리한다. 하나로 묶으면 상승 보정(launchUp)이
		-- 전체 크기를 밀어올려 수평 성분이 깎인다 = 잘 놓을수록 덜 나가는 역전.
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude > Config.Rope.MaxSpeed then
			flat = flat.Unit * Config.Rope.MaxSpeed
		end
		local up = math.clamp(v.Y, -Config.Rope.MaxUpSpeed, Config.Rope.MaxUpSpeed)
		hrp.AssemblyLinearVelocity = Vector3.new(flat.X, up, flat.Z)
	end
end

-- One teardown path for transitions, respawns and lost targets.
local function cleanup()
	detach(nil)
	latestAction = ""
	if releaseButton then
		releaseButton.Visible = false
	end
	if state.character then
		TrickAnimator.stop(state.character)
	end
	if state.hrp and state.hrp.Parent then
		state.hrp.AssemblyAngularVelocity = Vector3.zero
	end
	state.holdSide, state.holdStart, state.lastSide = 0, 0, 0
	state.combo, state.bestCombo, state.perfectCount = 0, 0, 0
	state.attachedAt = 0
	comboLabel.Text, speedLabel.Text = "", ""
	judgeLabel.TextTransparency = 1
	telStroke.Transparency = 1
	telegraph.Size = UDim2.fromOffset(0, 0)
	showPreview(previewL, nil)
	showPreview(previewR, nil)
end

-- 듀얼 로프: 이미 한 줄이 걸린 상태에서 반대쪽에 두 번째 줄을 건다.
-- 두 번째 줄은 길이를 줄이지 않는다(LengthScale 미적용). 양쪽을 다 당기면
-- 두 장력이 서로를 상쇄해 캐릭터가 공중에 못 박히고 진자가 죽는다.
local function attachSecond(side: number?)
	local hrp = state.hrp
	local primary = state.attachPart
	if not running() or not hrp or not primary or state.rope2 then
		return
	end
	local target = pickHookPoint(side)
	if not target or target == primary then
		return
	end

	local hookAtt = Instance.new("Attachment")
	hookAtt.Parent = target
	local bodyAtt = Instance.new("Attachment")
	bodyAtt.Parent = hrp

	local dist = (target.Position - hrp.Position).Magnitude
	local rope = Instance.new("RopeConstraint")
	rope.Attachment0 = bodyAtt
	rope.Attachment1 = hookAtt
	rope.Length = math.max(Config.Rope.MinLength, dist)
	rope.Restitution = Config.Rope.Restitution
	rope.Visible = false
	rope.Parent = hrp

	local skin = hookItem()
	local w = skin and skin.width or 0.25
	local beam = Instance.new("Beam")
	beam.Attachment0 = bodyAtt
	beam.Attachment1 = hookAtt
	beam.Width0 = w
	beam.Width1 = w * 0.6
	beam.FaceCamera = true
	beam.Color = ColorSequence.new(skin and skin.color or Config.Rope.Color)
	beam.LightEmission = 0.4
	beam.Parent = hrp

	state.rope2, state.beam2 = rope, beam
	state.hookAtt2, state.bodyAtt2 = hookAtt, bodyAtt
	state.attachPart2 = target
	sendAction("attach", target.Name, true)
end

local function attach(side: number?)
	local hrp = state.hrp
	if not running() or not hrp then
		return
	end
	if state.rope then
		if effect.dualRope then
			attachSecond(side)
		end
		return
	end
	local target = pickHookPoint(side)
	if not target then
		-- 실패도 명확히 보여준다
		flashJudge("NO HOOK", Color3.fromRGB(150, 160, 175))
		return
	end

	local hookAtt = Instance.new("Attachment")
	hookAtt.Parent = target
	local bodyAtt = Instance.new("Attachment")
	bodyAtt.Parent = hrp

	-- 로프를 실제 거리보다 짧게 잡아야 즉시 장력이 걸려 진자가 시작된다.
	local dist = (target.Position - hrp.Position).Magnitude
	local ropeLen = math.max(Config.Rope.MinLength, dist * Config.Rope.LengthScale)

	-- Humanoid 가 물리와 싸우지 않도록 공중 상태로 전환
	-- 진행 중인 곡예가 있으면 먼저 끝낸다. 안 그러면 곡예 종료 콜백이
	-- 스윙 도중에 PlatformStand 를 꺼버린다.
	if state.character then
		TrickAnimator.stop(state.character :: Model)
	end
	local hum = state.humanoid
	if hum then
		hum.PlatformStand = true
	end

	local rope = Instance.new("RopeConstraint")
	rope.Attachment0 = bodyAtt
	rope.Attachment1 = hookAtt
	rope.Length = ropeLen
	rope.Restitution = Config.Rope.Restitution
	rope.Visible = false
	rope.Parent = hrp

	local beam = Instance.new("Beam")
	beam.Attachment0 = bodyAtt
	beam.Attachment1 = hookAtt
	-- 로프 외형은 장착한 훅 스킨이 정한다 (거미줄 = 굵고 흰색).
	local skin = hookItem()
	local w = skin and skin.width or 0.25
	beam.Width0 = w
	beam.Width1 = w * 0.6
	beam.FaceCamera = true
	beam.Color = ColorSequence.new(skin and skin.color or Config.Rope.Color)
	if skin and skin.texture ~= "" then
		beam.Texture = skin.texture
		beam.TextureMode = Enum.TextureMode.Wrap
		beam.TextureLength = 8
	end
	beam.LightEmission = 0.4
	beam.Parent = hrp

	-- 스윙 중 캐릭터가 제멋대로 회전하는 것을 막는다.
	-- PlatformStand 상태의 랙돌은 로프 장력에 밀려 축 없이 굴러간다.
	local align = Instance.new("AlignOrientation")
	align.Attachment0 = bodyAtt
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.RigidityEnabled = false
	align.Responsiveness = Config.Spin.Responsiveness
	align.MaxTorque = Config.Spin.MaxTorque
	align.CFrame = CFrame.new(Vector3.zero, Vector3.new(0, 0, 1))
	align.Parent = hrp
	hrp.AssemblyAngularVelocity = Vector3.zero

	-- 스윙 어시스트는 속도 대입이 아니라 힘으로 준다.
	local force = Instance.new("VectorForce")
	force.Attachment0 = bodyAtt
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.zero
	force.Parent = hrp

	state.align = align
	state.assistForce = force
	state.rope, state.beam = rope, beam
	state.hookAtt, state.bodyAtt = hookAtt, bodyAtt
	state.attachPart = target
	state.attachedAt = os.clock()
	state.lastSide = (target:GetAttribute("Side") :: number?)
		or (path:frame(hrp.Position).right:Dot(target.Position - hrp.Position) < 0 and -1 or 1)
	sendAction("attach", target.Name, false)

	-- 부착 순간 최소 진입 속도 보장 (정지 상태에서 걸어도 스윙이 시작되도록)
	local v = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(v.X, 0, v.Z)
	if flat.Magnitude < Config.Rope.MinEntrySpeed then
		-- 진입 방향도 훅 쪽으로만 밀지 않고 시선을 섞는다.
		-- 그래야 같은 훅을 걸어도 어느 쪽을 보고 걸었느냐로 첫 스윙 궤도가 갈린다.
		local aim = aimForward(hrp.Position)
		local dir = (
			Vector3.new(target.Position.X, 0, target.Position.Z) - Vector3.new(hrp.Position.X, 0, hrp.Position.Z)
		)
		if dir.Magnitude > 1 then
			local blend = dir.Unit:Lerp(aim, Config.Aim.AttackAlign)
			dir = blend.Magnitude > 1e-3 and blend.Unit or dir.Unit
		else
			dir = aim
		end
		hrp.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0) + dir * Config.Rope.MinEntrySpeed
	end
end

----------------------------------------------------------------------
-- 릴리즈 판정
----------------------------------------------------------------------
-- trick=true 면 판정과 무관하게 공중제비를 돈다 (점프 릴리즈)
local function release(trick: boolean?)
	local hrp = state.hrp
	local target = state.attachPart
	if not running() or not hrp or not target then
		return
	end
	if not target.Parent then
		cleanup()
		sendAction("release")
		return
	end

	local ev = ReleaseJudge.evaluate(target.Position, hrp.Position, hrp.AssemblyLinearVelocity)
	local res = ev.result

	-- 반드시 detach 가 먼저다. 곡예를 먼저 걸면 곡예가 세운 PlatformStand 를
	-- detach 가 즉시 꺼버려, 휴머노이드 상태머신이 살아있는 채로 비행하게 된다.
	sendAction("release")
	detach(res.speedMul, res.launchUp)

	-- 곡예: PERFECT 는 항상, 점프(스페이스) 릴리즈는 판정과 무관하게 백덤블링.
	if ev.grade == "PERFECT" or trick then
		TrickAnimator.play(state.character :: Model, math.max(state.combo, 1))
	end

	flashJudge(ev.grade, res.color)
	CameraFX.judgeHit(ev.grade)
	-- Timing feedback is predicted; only HookmanVerdict changes the combo.

	if state.combo >= 2 then
		comboLabel.Text = ("COMBO x%d"):format(state.combo)
		comboLabel.TextColor3 = state.combo >= 6 and Color3.fromRGB(255, 120, 60) or Color3.fromRGB(255, 214, 64)
	else
		comboLabel.Text = ""
	end
end

----------------------------------------------------------------------
-- 입력
----------------------------------------------------------------------
-- P1 튜닝용 테스트 브릿지: 실제 컨트롤러를 그대로 구동해서 검증한다.
local touchRelease = Instance.new("TextButton")
touchRelease.Name = "Release"
touchRelease.Size = UDim2.fromOffset(140, 64)
touchRelease.Position = UDim2.new(1, -166, 1, -172)
touchRelease.BackgroundColor3 = Color3.fromRGB(40, 74, 110)
touchRelease.TextColor3 = Color3.new(1, 1, 1)
touchRelease.Font = Enum.Font.GothamBold
touchRelease.TextSize = 22
touchRelease.Text = "RELEASE"
touchRelease.Visible = false
touchRelease.Parent = gui
releaseButton = touchRelease
touchRelease.Activated:Connect(function()
	if running() then
		release(true)
	end
end)
if UserInputService.TouchEnabled then
	hintLabel.Text = "화면 좌/우 = 훅 (듀얼: 양쪽 탭) · RELEASE = 두 줄 해제"
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or not running() then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q or input.KeyCode == Enum.KeyCode.E then
		-- 탭 = 좌/우 훅, 꾹 = 그쪽 턴. 부착을 뗄 때로 미루면 손맛이 죽으므로 즉시 건다.
		-- 듀얼 로프를 장착했으면 이미 걸린 상태에서 눌러도 두 번째 줄이 붙는다.
		if groundedNoRope() then
			-- 조향 상태(holdSide)도 세우지 않는다. 세우면 지상에서 옆으로 밀린다.
			flashJudge("공중에서만", Color3.fromRGB(150, 160, 175))
			return
		end
		local side = input.KeyCode == Enum.KeyCode.Q and -1 or 1
		state.holdSide, state.holdStart = side, os.clock()
		attach(side)
	elseif input.KeyCode == Enum.KeyCode.Space then
		if state.rope then
			release(true) -- 점프 = 공중제비 릴리즈
		end
	elseif input.UserInputType == Enum.UserInputType.Touch then
		-- Left/right taps attach either rope; a separate button releases both.
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		if groundedNoRope() then
			flashJudge("공중에서만", Color3.fromRGB(150, 160, 175))
		else
			local pos = input.Position.X
			attach(pos < camera.ViewportSize.X / 2 and -1 or 1)
		end
	elseif input.KeyCode == Enum.KeyCode.R then
		sendAction("abandon")
		cleanup()
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if not running() then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q and state.holdSide == -1 then
		state.holdSide = 0
	elseif input.KeyCode == Enum.KeyCode.E and state.holdSide == 1 then
		state.holdSide = 0
	end
end)

----------------------------------------------------------------------
-- 캐릭터 바인딩
----------------------------------------------------------------------
local function bind(char: Model)
	-- Tear down the previous character before rebinding the new one.
	cleanup()
	state.character = char
	state.hrp, state.humanoid = nil, nil
	local hrp = char:WaitForChild("HumanoidRootPart", 10)
	local humanoid = char:WaitForChild("Humanoid", 10)
	if state.character ~= char or player.Character ~= char then
		return
	end
	if not hrp or not hrp:IsA("BasePart") or not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	state.hrp, state.humanoid = hrp, humanoid
	TrickAnimator.stop(char)
	refreshAura()
end

player.CharacterRemoving:Connect(function(char)
	if state.character == char then
		cleanup()
		state.character, state.hrp, state.humanoid = nil, nil, nil
	end
end)
player.CharacterAdded:Connect(bind)
if player.Character then
	task.spawn(bind, player.Character)
end

----------------------------------------------------------------------
-- 메인 루프: 예고 링 + 속도 HUD + 카메라
----------------------------------------------------------------------
RunService.RenderStepped:Connect(function(dt)
	touchRelease.Visible = UserInputService.TouchEnabled and running()
	local hrp = state.hrp
	if not running() or not hrp or not hrp.Parent then
		return
	end

	local speed = hrp.AssemblyLinearVelocity.Magnitude
	CameraFX.update(dt, speed)

	local target = state.attachPart
	if target and not target.Parent then
		cleanup()
		sendAction("release")
		return
	end
	if target then
		local t = ReleaseJudge.timeToRelease(target.Position, hrp.Position, hrp.AssemblyLinearVelocity)
		local tel = Config.Judge.Telegraph
		if t > 0 and t <= tel then
			-- 최하점에 다가갈수록 링이 좁혀진다 → 링이 가장 작을 때가 PERFECT
			local a = t / tel
			local px = 60 + a * 220
			telegraph.Size = UDim2.fromOffset(px, px)
			telStroke.Transparency = 0.15 + a * 0.5
		else
			telStroke.Transparency = 1
		end
		speedLabel.Text = ("LV%d   |   %d studs/s   |   t=%.2fs"):format(courseLevel(), speed, t)
	else
		telStroke.Transparency = 1
		speedLabel.Text = ("LV%d   |   %d studs/s"):format(courseLevel(), speed)
	end

	-- 훅 프리뷰: 부착 중이 아니면 Q/E 각각이 걸 훅을 동시에 강조한다.
	if target then
		showPreview(previewL, nil)
		showPreview(previewR, nil)
	else
		showPreview(previewL, pickHookPoint(-1))
		showPreview(previewR, pickHookPoint(1))
	end
end)

----------------------------------------------------------------------
-- 스윙 자세 안정화: 진행 방향을 보게 유지한다.
----------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	local hrp = state.hrp
	local align = state.align
	if not running() or not hrp or not align then
		return
	end
	-- 바라보는 곳이 곧 정면이다. 속도 방향으로 세우면 시선을 꺾어도 몸이 안 돌아
	-- "내가 조종한다"는 감각이 없고, 조향 결과도 화면에 안 보인다.
	local look
	if Config.Aim.FaceAim then
		look = aimForward(hrp.Position)
	else
		local v = hrp.AssemblyLinearVelocity
		local flat = Vector3.new(v.X, 0, v.Z)
		look = flat.Magnitude > 4 and flat.Unit or Vector3.new(0, 0, 1)
	end
	local goal = CFrame.new(Vector3.zero, look)
	align.CFrame = align.CFrame:Lerp(goal, math.clamp(Config.Spin.FaceLerp * dt * 60, 0, 1))
end)

----------------------------------------------------------------------
-- 스윙 어시스트 (Heartbeat): 접선 방향 에너지 보충
-- 진자는 드래그로 금방 죽는다. 플레이어가 "펌핑"을 안 하는 설계이므로
-- 게임이 대신 펌핑해 준다. 대신 TargetSpeed 이상은 절대 보충하지 않는다.
----------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	local hrp = state.hrp
	local target = state.attachPart
	if not running() or not hrp or not target or not target.Parent or not state.rope then
		return
	end

	local S = Config.Swing
	local force = state.assistForce
	if not force then
		return
	end
	local v = hrp.AssemblyLinearVelocity
	local speed = v.Magnitude
	-- 상한이 고정이면 1번째 스윙도 10번째 스윙도 같은 속도다 = 가속 곡선 없음.
	-- 콤보를 쌓을수록 상한이 올라간다.
	-- 오오라는 속도 상한과 가속을 함께 올린다. 상한만 올리면 도달을 못 하고,
	-- 가속만 올리면 같은 벽에 더 빨리 부딪힐 뿐이라 체감이 없다.
	local cap = math.min(S.TargetSpeed + state.combo * S.ComboStep, S.MaxTargetSpeed) + effect.speedCapAdd
	if speed >= cap then
		force.Force = Vector3.zero
		return
	end

	local rel = hrp.Position - target.Position
	local L = rel.Magnitude
	if L < 1 then
		force.Force = Vector3.zero
		return
	end
	local radial = rel / L

	-- 접선 방향 = 현재 속도에서 반경 성분을 제거한 방향
	local tangent = v - radial * v:Dot(radial)
	if tangent.Magnitude < S.MinAssistSpeed then
		-- 거의 멈췄으면 시선 방향을 접선에 투영해 재기동
		local fwd = aimForward(hrp.Position)
		tangent = fwd - radial * fwd:Dot(radial)
	end
	if tangent.Magnitude < 1e-3 then
		force.Force = Vector3.zero
		return
	end
	tangent = tangent.Unit

	-- 스윙 중 에너지 보충도 시선 쪽으로 치우친다 = 매달린 채로도 방향을 만들 수 있다.
	local fwd = aimForward(hrp.Position)
	local fwdTan = fwd - radial * fwd:Dot(radial)
	if fwdTan.Magnitude > 1e-3 then
		tangent = (tangent + fwdTan.Unit * S.ForwardBias).Unit
	end

	-- 속도 직접 대입은 로프 솔버가 방금 푼 값을 매 스텝 덮어써 미세 진동을 만든다.
	-- 힘으로 주면 솔버 안에서 처리되어 끊기지 않는다.
	-- 두 줄이 동시에 걸려 있으면 추가 가속. 듀얼 로프를 산 이유가 여기서 체감된다.
	local dualBonus = state.rope2 and 1.15 or 1
	local ramp = math.clamp(1 - speed / cap, 0.15, 1)
	force.Force = tangent * (S.TangentAccel * effect.accelMul * dualBonus * ramp * hrp.AssemblyMass)
end)

----------------------------------------------------------------------
-- Q/E 홀드 조향: 코스가 꺾이는 구간에서 안쪽으로 파고들게 한다.
-- 스윙 중에는 약하게(진자를 깨지 않도록), 공중에서는 강하게 먹인다.
----------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	local hrp = state.hrp
	if not running() or not hrp or state.holdSide == 0 then
		return
	end
	local T = Config.Turn
	if os.clock() - state.holdStart < T.HoldTime then
		return
	end
	-- 조향 좌우도 시선 기준이다. 코스 기준으로 두면 시선과 조향이 어긋나 손이 꼬인다.
	local dir = aimRight(hrp.Position) * state.holdSide
	local scale = state.rope and T.SwingSteerScale or 1
	local v = hrp.AssemblyLinearVelocity
	local nv = v + dir * (T.SteerAccel * scale * dt)
	local flat = Vector3.new(nv.X, 0, nv.Z)
	if flat.Magnitude > T.MaxSteerSpeed then
		flat = flat.Unit * T.MaxSteerSpeed
	end
	hrp.AssemblyLinearVelocity = Vector3.new(flat.X, nv.Y, flat.Z)
end)

----------------------------------------------------------------------
-- 상시 조향: 수평 진행 방향을 시선 쪽으로 계속 회전시킨다.
-- 매달린 중에도 먹여야 한다. 릴리즈 순간에만 꺾이면 스윙 내내 할 게 없다.
-- 힘이 아니라 속도 회전인 이유: 로프 장력이 반경 성분을 매 스텝 다시 풀기 때문에
-- 접선에 힘을 줘도 방향 전환은 거의 사라진다. 각도를 직접 돌려야 손에 잡힌다.
----------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	local hrp = state.hrp
	if not running() or not hrp or not hrp.Parent then
		return
	end
	local A = Config.Aim
	local v = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(v.X, 0, v.Z)
	local spd = flat.Magnitude
	if spd < 4 then
		return
	end

	local aim = aimForward(hrp.Position)
	local cur = flat.Unit
	local cosA = math.clamp(cur:Dot(aim), -1, 1)
	local errDeg = math.deg(math.acos(cosA))
	if errDeg <= A.TurnDeadzoneDeg then
		return
	end

	-- 회전 방향 부호: 시선이 현재 진행의 왼쪽인지 오른쪽인지
	local sign = cur:Cross(aim).Y >= 0 and 1 or -1
	local scale = state.rope and A.SwingTurnScale or 1
	local step = math.min(A.TurnRateDeg * scale * dt, errDeg)
	local dir = (CFrame.fromAxisAngle(Vector3.yAxis, math.rad(step) * sign) * cur).Unit
	hrp.AssemblyLinearVelocity = Vector3.new(dir.X * spd, v.Y, dir.Z * spd)
end)

local function applyRun(packet)
	if
		type(packet) ~= "table"
		or type(packet.runId) ~= "string"
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
	local course = packet.course
	if typeof(course) ~= "Instance" or not course:IsA("Folder") then
		course = nil
	end
	local changedRun = packet.runId ~= runId
	if changedRun or packet.state ~= "Running" or runState ~= "Running" or course ~= runCourse then
		cleanup()
	end
	if changedRun then
		sequence = 0
		verdictSequence = 0
		latestAction = ""
		clearLabel.TextTransparency = 1
		clearSub.TextTransparency = 1
	end
	runId, runVersion, runState = packet.runId, packet.version, packet.state
	level = type(packet.level) == "number" and packet.level or 1
	if course ~= runCourse or (runState == "Running" and path == nil) then
		runCourse = course
		path = nil
		if runState == "Running" then
			local expectedVersion = runVersion
			local expectedRunId = runId
			task.spawn(function()
				local courses = workspace:WaitForChild("HookmanCourses", 5)
				if not courses then
					return
				end
				local resolved = courses:WaitForChild("Course_" .. expectedRunId, 5)
				if
					not resolved
					or not resolved:IsA("Folder")
					or resolved.Parent ~= courses
					or resolved.Name ~= "Course_" .. expectedRunId
					or runVersion ~= expectedVersion
				then
					return
				end
				runCourse = resolved
				-- Instance references can arrive before all replicated PathNodes.
				for attempt = 1, 20 do
					if runVersion ~= expectedVersion or runCourse ~= resolved then
						return
					end
					local ok, candidatePath = pcall(CoursePath.new, resolved)
					if ok then
						path = candidatePath
						refreshCandidates()
						return
					end
					if attempt < 20 then
						task.wait(0.25)
					end
				end
				warn("[HOOKMAN] Course path unavailable; hook controls remain disabled")
			end)
		end
	end
	refreshCandidates()
end

local function applyProfile(snap)
	if type(snap) ~= "table" then
		return
	end
	-- Run versions are independent of profile revisions, including snapshot races.
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
		cleanup()
		return
	end
	if type(snap.equipped) == "table" then
		equipped = snap.equipped
		effect = ShopCatalog.effectOf(equipped)
		refreshAura()
	end
	refreshCandidates()
end

runEvent.OnClientEvent:Connect(applyRun)
profileEvent.OnClientEvent:Connect(applyProfile)
verdictEvent.OnClientEvent:Connect(function(packet)
	if
		not running()
		or latestAction == ""
		or type(packet) ~= "table"
		or packet.runId ~= runId
		or packet.sequence ~= sequence
		or packet.sequence <= verdictSequence
	then
		return
	end
	verdictSequence = packet.sequence
	if packet.accepted ~= true then
		if latestAction == "attach" then
			cleanup()
			-- A rejected secondary prediction may still have an accepted primary.
			-- Release the server attachment as well as the local ropes.
			sendAction("release")
		end
	end
	if
		type(packet.combo) == "number"
		and packet.combo == packet.combo
		and packet.combo >= 0
		and packet.combo < math.huge
		and packet.combo % 1 == 0
	then
		state.combo = packet.combo
		state.bestCombo = math.max(state.bestCombo, state.combo)
		comboLabel.Text = state.combo >= 2 and ("COMBO x%d"):format(state.combo) or ""
		comboLabel.TextColor3 = state.combo >= 6 and Color3.fromRGB(255, 120, 60) or Color3.fromRGB(255, 214, 64)
	end
	if packet.accepted == true and latestAction == "release" and type(packet.grade) == "string" then
		local result = Config.JudgeResult[packet.grade]
		if not result then
			return
		end
		if packet.grade == "PERFECT" and packet.award ~= false then
			state.perfectCount += 1
		end
		flashJudge(packet.grade, result.color)
	end
end)

-- Destroyed course targets must never leave a force or dangling second rope alive.
RunService.Heartbeat:Connect(function()
	if not running() then
		if state.rope or state.rope2 or state.assistForce or (runState == "Running" and path ~= nil) then
			cleanup()
			if runCourse and not runCourse.Parent then
				path = nil
				candidates = {}
			end
		end
		return
	end
	local hooks = (runCourse :: Folder):FindFirstChild("HookPoints")
	if
		(state.attachPart and (not state.attachPart.Parent or state.attachPart.Parent ~= hooks))
		or (state.attachPart2 and (not state.attachPart2.Parent or state.attachPart2.Parent ~= hooks))
	then
		cleanup()
		sendAction("release")
	end
end)

-- Listeners are installed before requesting the initial profile and run state.
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
-- 듀얼 로프: 이미 한 줄이 걸린 상태에서 반대쪽에 두 번째 줄을 건다.

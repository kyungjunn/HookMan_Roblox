--!strict
-- HOOKMAN 공용 설정 (기획서 v0.2 기준)
-- P1 튜닝 대상 수치는 전부 여기에 모은다.

local Config = {}

Config.Hook = {
	MinRange = 25, -- 이보다 가까우면 진자가 안 나온다
	MaxRange = 175, -- 기획서: 60~140 스터드
	MinAngleDeg = 25, -- 진행 방향 기준 전방 각도 하한
	MaxAngleDeg = 115, -- 상한 (기획서 30~110 를 소폭 완화)
	OppositeSideBonus = 1.4, -- 직전 부착면 반대편 가중치 +40%
	HeightBonus = 0.02, -- 고도 1스터드당 점수 가중
	MinForwardZ = 12, -- 이보다 앞(+Z)에 있는 훅만 후보. 역주행 방지
	MaxDrop = 130, -- 훅이 나보다 이만큼까지 아래여도 후보 (높은 곳에서 시작할 때 필수)
	ForwardBonus = 0.35, -- 전진 거리 1스터드당 점수 가중
	CandidateRefresh = 0.1, -- 후보 캐싱 주기(초)
	Tag = "Hookable",
}

Config.Rope = {
	Restitution = 0.12, -- 0 이면 장력 걸리는 순간 반경 속도가 즉사한다 ("탁" 끊김)
	Thickness = 0.18,
	Color = Color3.fromRGB(235, 235, 235),
	AttachSpeedBoost = 1.0, -- 부착 순간 속도 보정
	MaxSpeed = 260, -- 수평 속도 캡 (스터드/초)
	MaxUpSpeed = 130, -- 수직 속도 캡. 수평과 분리해서 깎아야 상승 보정이 전진을 안 잡아먹는다
	LengthScale = 0.88, -- 부착 거리 대비 로프 길이. 1.0이면 진자가 안 걸린다
	MinLength = 18,
	AttachImpulse = 46, -- 부착 순간 전방 킥 (정지 상태에서도 스윙이 시작되도록)
	MinEntrySpeed = 40, -- 이보다 느리면 전방으로 보정해 준다
	AlignTorque = 90000, -- 스윙 중 자세 고정 토크 (제멋대로 도는 것 방지)
	AlignResponsiveness = 45,
}

-- 릴리즈 판정 윈도우 (진자 최하점 통과 시점 기준, 초)
Config.Judge = {
	-- 릴리즈 목표: 최하점이 아니라 상승 30° 지점.
	-- 최하점 릴리즈는 수평 속도만 주고 고도를 잃어 필연적으로 추락한다.
	ReleaseAngleDeg = 30,
	Perfect = 0.08,
	Great = 0.20,
	Good = 0.40,
	Telegraph = 0.30, -- 최하점 몇 초 전부터 예고 연출
}

-- 판정별 결과
-- launchUp: 릴리즈 순간 보장되는 최소 상승 속도(스터드/초).
-- 진자만으로는 스윙마다 고도가 깎여 필연적으로 추락한다. 판정이 좋을수록 더 높이 뜬다.
Config.JudgeResult = {
	PERFECT = { speedMul = 1.25, launchUp = 78, combo = 1, color = Color3.fromRGB(255, 214, 64) },
	GREAT = { speedMul = 1.10, launchUp = 62, combo = 1, color = Color3.fromRGB(120, 235, 140) },
	GOOD = { speedMul = 1.00, launchUp = 46, combo = 0, color = Color3.fromRGB(180, 200, 220) },
	MISS = { speedMul = 0.85, launchUp = 22, combo = -1, color = Color3.fromRGB(235, 90, 90) },
}

-- 스윙 어시스트: 진자가 공기저항/랙돌 드래그로 죽지 않게 접선 방향 에너지를 보충한다.
-- 없으면 2~3회 스윙 만에 속도가 10 스터드/초로 떨어져 코스 진행이 불가능하다.
Config.Swing = {
	TangentAccel = 130, -- 접선 가속 (스터드/초^2)
	TargetSpeed = 160, -- 콤보 0 일 때 보충 상한
	ComboStep = 18, -- 콤보 1 당 상한 증가. 상한이 고정이면 10번째 스윙도 첫 스윙과 같은 속도다
	MaxTargetSpeed = 240, -- 콤보로 올릴 수 있는 최대치
	ForwardBias = 0.35, -- 코스 진행(+Z) 방향 가중
	MinAssistSpeed = 8, -- 완전 정지 시 재기동 하한
}

-- 스윙 중 자세 안정화.
-- PlatformStand 상태의 캐릭터는 로프 장력과 충돌로 제멋대로 회전한다(스핀 버그).
-- AlignOrientation 으로 상체를 세우고 진행 방향을 보게 강제한다.
Config.Spin = {
	Responsiveness = 45, -- 목표 자세로 수렴하는 속도
	MaxTorque = 2e6,
	FaceLerp = 0.25, -- 바라보는 방향 보간
}

-- 곡예 회전량. spec.time(연출 길이)은 그대로 두고 각속도만 올린다.
-- 1.0 이면 spins 값 그대로 = 체감상 덜 돈다.
Config.Trick = {
	SpinRateScale = 1.35,
	RollRateScale = 1.25,
}

Config.Camera = {
	BaseFov = 70,
	MaxFov = 100,
	FovSpeedRef = 240, -- 이 속도에서 MaxFov 도달
	FovLerp = 6,
	TurnRollDeg = 10,
	PerfectSlowScale = 0.45,
	PerfectSlowTime = 0.15,
}

-- 조준축: 훅 타게팅·스윙 보충·릴리즈 사출이 모두 "내가 바라보는 방향"을 따른다.
-- 코스 접선은 지형이 어디로 이어지는지일 뿐 플레이어 의도가 아니다.
-- 접선을 축으로 쓰면 시선을 어디로 돌리든 결과가 같아 조작감이 죽는다.
Config.Aim = {
	UseCamera = true,
	ReleaseAlign = 0.65, -- 릴리즈 순간 수평 속도를 시선 쪽으로 회전시키는 비율 (0=무시, 1=완전 정렬)
	AttackAlign = 0.45, -- 부착 순간 진입 속도를 시선 쪽으로 미는 비율
	MinFlat = 0.05, -- 카메라가 거의 수직일 때는 조준축을 못 뽑는다 → 코스 접선 폴백

	-- 상시 조향: 수평 진행 방향을 매 프레임 시선 쪽으로 "회전"시킨다.
	-- 힘으로 밀면 로프 장력이 대부분 먹어버려 매달린 채로는 방향이 안 바뀐다.
	-- 속도 벡터를 직접 돌리되 크기는 보존해서, 감속 없이 곡선만 그리게 한다.
	TurnRateDeg = 200, -- 공중에서 초당 꺾을 수 있는 수평 각도
	SwingTurnScale = 0.6, -- 로프에 매달린 중 비율 (진자를 완전히 무시하지는 않게)
	TurnDeadzoneDeg = 3, -- 이 이하 오차는 무시. 안 그러면 정면에서 미세 진동한다
	FaceAim = true, -- 캐릭터가 진행 방향이 아니라 시선을 보게 한다
}

-- Q/E 홀드 턴. 탭은 훅 부착, 0.18초 이상 누르고 있으면 그 방향으로 조향한다.
-- 코스가 지그재그이므로 조향 없이는 커브 바깥으로 튕겨 나간다.
Config.Turn = {
	HoldTime = 0.18, -- 이 시간 이상 눌러야 턴으로 인정
	SteerAccel = 150, -- 수평 조향 가속 (스터드/초^2)
	SwingSteerScale = 0.55, -- 로프에 매달린 중에는 약하게 (진자를 깨지 않도록)
	YawAssistDeg = 26, -- 홀드 중 타게팅 전방축을 이만큼 그 방향으로 돌린다
	AssistBonus = 1.35, -- 홀드 방향 훅 가중
	MaxSteerSpeed = 240, -- 조향으로 늘어나는 속도 상한
}

-- 점수/재화.
-- 점수는 런(코스 1회) 단위로 쌓이고, 골에 도달해야 코인으로 환산된다.
-- 중간에 죽어도 점수가 남으면 상점만 채우고 코스는 안 미는 플레이가 최적이 된다.
Config.Score = {
	PERFECT = 120,
	GREAT = 65,
	GOOD = 30,
	MISS = 0,
	-- 상한 도달 콤보 = (MaxComboMul-1)/ComboStep = 30.
	-- 런 1회의 훅 부착이 15~28회다. 예전 값(0.12/3.0)은 콤보 17에서 천장에 닿아
	-- 런 후반이 통째로 "더 쌓아도 같은 점수" 구간이 됐다. 끝까지 유지할 이유를 만든다.
	ComboStep = 0.10, -- 콤보 1 당 배수 증가
	MaxComboMul = 4.0, -- 콤보 배수 상한
	-- 감점 자체보다 콤보 리셋이 진짜 벌이다. 다만 40점은 PERFECT 1회의 1/3이라
	-- "맞아도 그만"이었다. 기본 PERFECT 1회와 같은 무게로 올린다.
	HazardPenalty = 120, -- 장애물 피격 시 감점
	ClearBonus = 400, -- 골 도달 보너스 (레벨 배수 적용)
	ClearLevelMul = 0.25, -- 레벨 1 당 클리어 보너스 증가율
	CoinPerScore = 0.05, -- 런 종료 시 점수 → 코인 환산율
}

-- 코스 중앙 장애물
Config.Hazard = {
	GraceTime = 1.2, -- 리스폰 직후 무적
	Knockback = 60, -- 피격 시 뒤로 밀리는 속도 (연출용)
}

return Config

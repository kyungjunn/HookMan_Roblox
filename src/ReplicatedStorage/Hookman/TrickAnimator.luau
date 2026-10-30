--!strict
-- 판정 성공 시 곡예(백덤블링/트위스트) 연출
-- 애니메이션 애셋 없이 루트파트 회전을 프레임 단위로 덮어써서 구현한다.
-- 위치는 물리가 계속 굴리고, 회전만 가로챈다.

local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local TrickAnimator = {}
TrickAnimator.__index = TrickAnimator

-- 진행 중인 곡예의 RenderStepped 연결. 스레드가 아니라 연결을 들고 있어야
-- 재진입 시 확실히 끊긴다. 스레드만 취소하면 연결이 살아남아 CFrame 을 계속
-- 덮어쓰고, 복귀 처리(PlatformStand 해제)가 영영 실행되지 않는다.
local ACTIVE: { [Model]: RBXScriptConnection } = {}

type TrickSpec = { spins: number, twist: number, time: number }

-- 콤보에 따라 화려해지는 곡예 스펙
function TrickAnimator.specForCombo(combo: number): TrickSpec
	if combo >= 6 then
		return { spins = 2, twist = 1, time = 0.95 }
	elseif combo >= 3 then
		return { spins = 1, twist = 1, time = 0.75 }
	end
	return { spins = 1, twist = 0, time = 0.6 }
end

function TrickAnimator.play(character: Model, combo: number)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then
		return
	end

	-- 이전 곡예를 연결 단위로 정리하고 조작 상태까지 원복한 뒤 시작한다.
	TrickAnimator.stop(character)

	local spec = TrickAnimator.specForCombo(combo)
	-- 기준 방향은 캐릭터의 현재 자세가 아니라 "수평 이동 방향"에서 뽑는다.
	-- 릴리즈 직후 랙돌 자세는 이미 기울어 있어서, 그걸 기준으로 잡으면
	-- lookAt 기저가 매 프레임 흔들려 토네이도처럼 보인다.
	local v = hrp.AssemblyLinearVelocity
	local baseLook = Vector3.new(v.X, 0, v.Z)
	if baseLook.Magnitude < 4 then
		baseLook = hrp.CFrame.LookVector * Vector3.new(1, 0, 1)
	end
	if baseLook.Magnitude < 0.01 then
		baseLook = Vector3.new(0, 0, 1)
	end
	baseLook = baseLook.Unit

	humanoid.AutoRotate = false
	-- 곡예 중에는 Humanoid 가 자세를 되돌리려 싸우지 못하게 막는다.
	humanoid.PlatformStand = true

	-- 회전을 매 프레임 CFrame 대입으로 만들지 않는다. CFrame 을 쓰면 어셈블리가
	-- 프레임마다 물리 솔버에서 텔레포트되고 각속도가 0으로 리셋된다.
	-- 그 결과 정작 "날아가야 할" 릴리즈 직후 0.6~0.95초가 가장 끊긴다.
	-- 각속도를 한 번 주고 나머지는 물리에 맡긴다.
	local axis = baseLook:Cross(Vector3.new(0, 1, 0)) -- 백덤블링 축
	local spinRate = math.pi * 2 * spec.spins / spec.time * Config.Trick.SpinRateScale
	local rollRate = spec.twist > 0 and (math.pi * 2 * spec.twist / spec.time * Config.Trick.RollRateScale) or 0
	hrp.AssemblyAngularVelocity = axis * spinRate + baseLook * rollRate

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		if os.clock() - t0 < spec.time and hrp.Parent and humanoid.Health > 0 then
			return
		end
		conn:Disconnect()
		if ACTIVE[character] == conn then
			ACTIVE[character] = nil
		end
		if hrp.Parent then
			hrp.AssemblyAngularVelocity = Vector3.zero
			hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + baseLook)
		end
		-- 곡예 이전 값을 복원하지 않는다. 정답은 항상 "조작 가능한 공중 상태"다.
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
	end)
	ACTIVE[character] = conn
end

function TrickAnimator.stop(character: Model)
	local conn = ACTIVE[character]
	if conn then
		conn:Disconnect()
		ACTIVE[character] = nil
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = true
	end
end

return TrickAnimator

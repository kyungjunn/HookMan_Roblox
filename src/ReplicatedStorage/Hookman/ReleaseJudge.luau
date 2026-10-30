--!strict
-- 릴리즈 판정: "최하점"이 아니라 "최하점 통과 후 상승 각도"를 목표로 한다.
-- 최하점에서 놓으면 수평 속도만 얻고 고도가 0이 되어 반드시 추락한다.
-- 상승 국면 targetPhi 에서 놓아야 포물선 비행으로 고도가 유지된다.

local Config = require(script.Parent.Config)

local ReleaseJudge = {}

-- 현재 속도의 상승각(phi). 진자에서 phi 는 하강 -θ0 → 0(최하점) → +θmax 로 단조 증가한다.
local function elevation(vel: Vector3): number
	local m = vel.Magnitude
	if m < 1e-3 then
		return 0
	end
	return math.asin(math.clamp(vel.Y / m, -1, 1))
end

-- 이상적 릴리즈 시점까지 남은 시간(초). 양수면 아직 이르다(EARLY), 음수면 늦었다(LATE).
function ReleaseJudge.timeToRelease(attachPos: Vector3, pos: Vector3, vel: Vector3): number
	local L = (pos - attachPos).Magnitude
	if L < 1 then
		return 0
	end
	local speed = vel.Magnitude
	if speed < 1 then
		return 99
	end
	local omega = speed / L -- rad/s, phi 의 변화율 근사
	if omega < 1e-3 then
		return 99
	end
	local target = math.rad(Config.Judge.ReleaseAngleDeg)
	return (target - elevation(vel)) / omega
end

-- 하위 호환(디버그용): 최하점까지 남은 시간
function ReleaseJudge.grade(t: number): (string, number)
	local e = math.abs(t)
	local J = Config.Judge
	if e <= J.Perfect then
		return "PERFECT", e
	elseif e <= J.Great then
		return "GREAT", e
	elseif e <= J.Good then
		return "GOOD", e
	end
	return "MISS", e
end

function ReleaseJudge.evaluate(attachPos: Vector3, pos: Vector3, vel: Vector3)
	local t = ReleaseJudge.timeToRelease(attachPos, pos, vel)
	local g, err = ReleaseJudge.grade(t)
	return {
		grade = g,
		error = err,
		signed = t,
		early = t > 0,
		result = Config.JudgeResult[g],
	}
end

return ReleaseJudge

--!strict
-- HOOKMAN 존(스테이지 월드) 카탈로그.
--
-- 성장 루프의 뼈대다. 코인은 소모재라 사면 사라지지만, 누적 점수(lifetime)는
-- 절대 줄지 않는다. 존 해금을 "누적 점수"에 걸어야 플레이가 영구적으로 남는다.
-- 코인에 걸면 아이템을 살수록 존이 멀어져서 두 성장축이 서로를 잡아먹는다.
--
-- 존이 올라갈수록:
--   난이도(시작 레벨·훅 간격·장애물 밀도)가 오르고
--   점수 배수(scoreMul)가 오른다 = 상위 존이 곧 파밍 효율이다.
-- 이게 "더 어려운 데를 가고 싶다"의 이유가 된다.

local ZoneCatalog = {}

export type Zone = {
	id: string,
	order: number,
	name: string,
	desc: string,
	requireScore: number,   -- 누적 점수 해금 조건
	startLevel: number,     -- 이 존에서 시작하는 코스 레벨
	levelStep: number,      -- 클리어마다 오르는 레벨 폭
	maxLevel: number,
	scoreMul: number,       -- 이 존에서 얻는 모든 점수 배수
	coinMul: number,        -- 코인 환산 배수. scoreMul 보다 완만해야 한다 (아래 설명)
	palette: string,        -- CourseBuilder 팔레트 강제 (존마다 외형이 고정이어야 "다른 곳"으로 읽힌다)
	color: Color3,          -- 포털/UI 색
}

-- coinMul 이 scoreMul 과 별도로 있는 이유:
-- 예전엔 코인도 scoreMul 을 그대로 먹었다. 그러면 존 배수가 진행(해금)과
-- 구매력(코인) 양쪽에 동시에 곱해져, 상위 존에 닿는 순간 상점이 통째로 끝난다
-- (러스트 1,006 코인/런 × 10런 = 전 아이템 구매 완료).
-- 점수는 진행축, 코인은 구매축이므로 분리한다. 점수 배수는 가파르게(3.2배),
-- 코인 배수는 완만하게(1.6배) 올려 상위 존이 "빨리 가고 싶은 곳"이되되
-- "가면 상점이 끝나는 곳"은 안 되게 한다.
--
-- requireScore 곡선: 이전 존을 중급 장비로 돌 때 대략 9 / 25 / 52 / 92 클리어.
-- 예전 값(4k/20k/70k/200k)은 2 / 5 / 8 / 13 클리어라 전체 존이 28런에 다 열렸다.
local ZONES: { Zone } = {
	{ id = "downtown", order = 1, name = "다운타운", desc = "입문. 넓은 간격, 장애물 없음.",
	  requireScore = 0, startLevel = 1, levelStep = 1, maxLevel = 6, scoreMul = 1.0, coinMul = 1.0,
	  palette = "Downtown", color = Color3.fromRGB(90, 180, 255) },
	{ id = "sunset", order = 2, name = "선셋 하버", desc = "굽은 코스와 첫 장애물.",
	  requireScore = 20000, startLevel = 4, levelStep = 1, maxLevel = 10, scoreMul = 1.35, coinMul = 1.15,
	  palette = "Sunset", color = Color3.fromRGB(255, 120, 60) },
	{ id = "neon", order = 3, name = "네온 시티", desc = "게이트와 회전 바가 쏟아진다.",
	  requireScore = 110000, startLevel = 8, levelStep = 1, maxLevel = 14, scoreMul = 1.8, coinMul = 1.3,
	  palette = "Neon", color = Color3.fromRGB(255, 80, 220) },
	{ id = "glacier", order = 4, name = "글레이셔", desc = "급격한 지그재그. 조향 없이는 못 간다.",
	  requireScore = 450000, startLevel = 12, levelStep = 1, maxLevel = 17, scoreMul = 2.4, coinMul = 1.45,
	  palette = "Glacier", color = Color3.fromRGB(120, 220, 255) },
	{ id = "rust", order = 5, name = "러스트 웨이스트", desc = "최고 난이도. 최고 배수.",
	  requireScore = 1400000, startLevel = 16, levelStep = 1, maxLevel = 20, scoreMul = 3.2, coinMul = 1.6,
	  palette = "Rust", color = Color3.fromRGB(255, 170, 60) },
}

ZoneCatalog.Zones = ZONES
ZoneCatalog.Default = "downtown"

local byId: { [string]: Zone } = {}
for _, z in ipairs(ZONES) do
	byId[z.id] = z
end

function ZoneCatalog.get(id: string?): Zone?
	return id and byId[id] or nil
end

-- 알 수 없는 id 는 조용히 기본 존으로 떨어뜨린다 (구 저장 데이터 호환).
function ZoneCatalog.resolve(id: string?): Zone
	return byId[id or ""] or byId[ZoneCatalog.Default]
end

function ZoneCatalog.unlocked(zone: Zone, lifetimeScore: number): boolean
	return lifetimeScore >= zone.requireScore
end

-- 다음으로 열릴 존과 남은 점수. HUD 가 "목표"를 보여주는 데 쓴다.
-- 목표가 안 보이면 누적 점수는 그냥 늘어나는 숫자일 뿐이다.
function ZoneCatalog.nextLocked(lifetimeScore: number): (Zone?, number)
	for _, z in ipairs(ZONES) do
		if lifetimeScore < z.requireScore then
			return z, z.requireScore - lifetimeScore
		end
	end
	return nil, 0
end

return ZoneCatalog

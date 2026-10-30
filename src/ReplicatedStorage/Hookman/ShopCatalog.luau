--!strict
-- HOOKMAN 상점 카탈로그.
-- 클라이언트(상점 UI·시각 효과)와 서버(가격 검증·소유 판정)가 같은 표를 봐야 한다.
-- 가격/효과를 클라이언트에만 두면 조작당하고, 서버에만 두면 UI가 못 그린다.

local ShopCatalog = {}

export type Effect = {
	scoreMul: number,      -- 모든 판정 점수 배수
	perfectMul: number,    -- PERFECT 에만 추가로 곱하는 배수 (오오라의 존재 이유)
	accelMul: number,      -- 스윙 접선 가속 배수
	speedCapAdd: number,   -- 스윙 속도 상한 가산
	dualRope: boolean,     -- 로프 2개 동시 부착 (능력)
}

export type Item = {
	id: string,
	kind: string,          -- "hook" | "aura" | "ability"
	name: string,
	desc: string,
	price: number,
	order: number,
	color: Color3,
	width: number,         -- 로프 굵기 (hook 전용)
	texture: string,       -- 로프 텍스처 (hook 전용, "" 이면 단색 빔)
	effect: Effect,
}

local function eff(scoreMul: number, perfectMul: number, accelMul: number, speedCapAdd: number, dualRope: boolean?): Effect
	return {
		scoreMul = scoreMul,
		perfectMul = perfectMul,
		accelMul = accelMul,
		speedCapAdd = speedCapAdd,
		dualRope = dualRope == true,
	}
end

-- 가격 곡선: 전 아이템 합계 19,700 코인. 다운타운 기본 장비 기준 90 코인/런이므로
-- 최상위 존까지 올라가며 사는 구조다. 예전 합계(11,800)는 상위 존 코인 수입
-- (1,000/런 이상)으로 10런 안에 전부 사져서, 도달 즉시 상점이 죽는 값이었다.

-- texture 는 지금 전부 "" 다. 실제 애셋 ID 를 넣기 전까지 굵기/색/발광으로만 구분한다.
-- 없는 rbxassetid 를 박아 두면 빔이 통째로 안 보이는 쪽이 더 나쁘다.
local ITEMS: { Item } = {
	-- 훅: 로프 빔의 외형. 기본은 무료여야 한다. 안 그러면 첫 플레이에 로프가 없다.
	{ id = "hook_basic", kind = "hook", name = "기본 와이어", desc = "평범한 강철 와이어.",
	  price = 0, order = 1, color = Color3.fromRGB(235, 235, 235), width = 0.25, texture = "",
	  effect = eff(1, 1, 1, 0) },
	{ id = "hook_neon", kind = "hook", name = "네온 핑크", desc = "밤 도시에 어울리는 형광 로프.",
	  price = 250, order = 2, color = Color3.fromRGB(255, 80, 220), width = 0.30, texture = "",
	  effect = eff(1.05, 1, 1, 0) },
	{ id = "hook_web", kind = "hook", name = "거미줄", desc = "굵고 하얀 거미줄. 손목에서 뿜어져 나온다.",
	  price = 350, order = 3, color = Color3.fromRGB(255, 255, 255), width = 0.52, texture = "",
	  effect = eff(1.08, 1.05, 1, 0) },
	{ id = "hook_gold", kind = "hook", name = "황금 체인", desc = "점수가 더 잘 붙는다.",
	  price = 1400, order = 4, color = Color3.fromRGB(255, 214, 64), width = 0.36, texture = "",
	  effect = eff(1.15, 1.1, 1, 0) },
	{ id = "hook_void", kind = "hook", name = "보이드 링크", desc = "공간을 꿰뚫는 로프.",
	  price = 3200, order = 5, color = Color3.fromRGB(140, 90, 255), width = 0.42, texture = "",
	  effect = eff(1.25, 1.15, 1.02, 0) },

	-- 오오라: 몸 주변 파티클 + 가속/점수 보정. "없음"도 아이템으로 둬야 해제가 가능하다.
	{ id = "aura_none", kind = "aura", name = "없음", desc = "오오라를 끈다.",
	  price = 0, order = 1, color = Color3.fromRGB(180, 190, 200), width = 0, texture = "",
	  effect = eff(1, 1, 1, 0) },
	{ id = "aura_spark", kind = "aura", name = "스파크", desc = "가속 +6%, PERFECT 점수 +15%.",
	  price = 400, order = 2, color = Color3.fromRGB(120, 220, 255), width = 0, texture = "",
	  effect = eff(1, 1.15, 1.06, 10) },
	{ id = "aura_flame", kind = "aura", name = "화염", desc = "가속 +12%, PERFECT 점수 +30%.",
	  price = 1500, order = 3, color = Color3.fromRGB(255, 120, 60), width = 0, texture = "",
	  effect = eff(1.05, 1.3, 1.12, 20) },
	{ id = "aura_storm", kind = "aura", name = "뇌전", desc = "가속 +20%, PERFECT 점수 +50%.",
	  price = 3600, order = 4, color = Color3.fromRGB(160, 120, 255), width = 0, texture = "",
	  effect = eff(1.1, 1.5, 1.2, 35) },

	-- 능력: 조작 자체를 바꾸는 최상위 구매처. 배수 아이템은 언젠가 천장에 닿지만
	-- 능력은 "할 수 있는 것"이 늘어나므로 장기 목표가 된다.
	{ id = "ability_none", kind = "ability", name = "없음", desc = "능력을 끈다.",
	  price = 0, order = 1, color = Color3.fromRGB(180, 190, 200), width = 0, texture = "",
	  effect = eff(1, 1, 1, 0) },
	{ id = "ability_dual", kind = "ability", name = "듀얼 로프", desc = "Q/E 로 좌·우 로프를 동시에 건다. 두 줄이 걸리면 가속 +15%.",
	  price = 9000, order = 2, color = Color3.fromRGB(120, 255, 200), width = 0, texture = "",
	  effect = eff(1.1, 1.2, 1.15, 25, true) },
}

-- 시작 시 무료로 쥐고 있는 것들. 서버 프로필 초기값과 상점 UI 가 같은 값을 써야 한다.
ShopCatalog.Items = ITEMS
ShopCatalog.Defaults = { hook = "hook_basic", aura = "aura_none", ability = "ability_none" }
ShopCatalog.Kinds = { "hook", "aura", "ability" }

local byId: { [string]: Item } = {}
for _, it in ipairs(ITEMS) do
	byId[it.id] = it
end

function ShopCatalog.get(id: string?): Item?
	return id and byId[id] or nil
end

-- kind 별 목록 (order 순). 상점 UI 탭이 이걸 그대로 그린다.
function ShopCatalog.byKind(kind: string): { Item }
	local out: { Item } = {}
	for _, it in ipairs(ITEMS) do
		if it.kind == kind then
			table.insert(out, it)
		end
	end
	table.sort(out, function(a, b)
		return a.order < b.order
	end)
	return out
end

-- 장착 조합의 최종 효과. 배수는 곱, 가산은 합.
-- 알 수 없는 id 는 조용히 기본값으로 떨어뜨린다 (구 저장 데이터 호환).
function ShopCatalog.effectOf(equipped: { [string]: string }): Effect
	local e = eff(1, 1, 1, 0)
	for _, kind in ipairs(ShopCatalog.Kinds) do
		local item = ShopCatalog.get(equipped[kind]) or ShopCatalog.get(ShopCatalog.Defaults[kind])
		if item then
			e.scoreMul *= item.effect.scoreMul
			e.perfectMul *= item.effect.perfectMul
			e.accelMul *= item.effect.accelMul
			e.speedCapAdd += item.effect.speedCapAdd
			e.dualRope = e.dualRope or item.effect.dualRope
		end
	end
	return e
end

return ShopCatalog

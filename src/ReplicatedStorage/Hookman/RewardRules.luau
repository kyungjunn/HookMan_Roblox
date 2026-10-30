--!strict
local Config = require(script.Parent.Config)
local Rules = require(script.Parent.RunRules)
local RewardRules = {}
local grades = { PERFECT = true, GREAT = true, GOOD = true, MISS = true }

function RewardRules.judge(grade: string, combo: number, effect, zone): number
	assert(grades[grade] == true, "Unknown release grade")
	assert(Rules.integer(combo, 0, 10000), "Invalid combo")
	local multiplier = math.min(1 + combo * Config.Score.ComboStep, Config.Score.MaxComboMul)
	local gain = Config.Score[grade] * multiplier * effect.scoreMul * zone.scoreMul
	if grade == "PERFECT" then
		gain *= effect.perfectMul
	end
	return math.floor(gain)
end
function RewardRules.finish(score: number, level: number, zone): (number, number)
	assert(Rules.integer(score, 0, Rules.MaxScore), "Invalid run score")
	assert(Rules.integer(level, zone.startLevel, zone.maxLevel), "Invalid level")
	local bonus = math.floor(Config.Score.ClearBonus * (1 + (level - 1) * Config.Score.ClearLevelMul) * zone.scoreMul)
	local total = math.min(score + bonus, Rules.MaxScore)
	local coins = math.floor(total / zone.scoreMul * zone.coinMul * Config.Score.CoinPerScore)
	return total, coins
end
return RewardRules

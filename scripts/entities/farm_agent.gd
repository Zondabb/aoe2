extends BuildingAgent

func extract(delta: float) -> float:
	if not is_complete or hp <= 0: return 0.0
	var value := minf(amount, maxf(0,delta) * gather_rate)
	amount -= value
	return value

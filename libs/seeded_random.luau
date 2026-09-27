--- Creates a deterministic integer generator from a hexadecimal seed such as an md5 digest.
--- Calling the generator with `upper` returns an integer in the range [1, upper].
local function seeded_random(seed: string): (upper: number) -> number
	local state = tonumber(string.sub(seed, 1, 8), 16) or 0
	if state == 0 then
		state = 0x9E3779B9
	end

	return function(upper: number): number
		state = bit32.bxor(state, bit32.lshift(state, 13))
		state = bit32.bxor(state, bit32.rshift(state, 17))
		state = bit32.bxor(state, bit32.lshift(state, 5))
		return (state % upper) + 1
	end
end

return seeded_random

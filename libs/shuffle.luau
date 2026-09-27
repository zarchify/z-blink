--- Performs a Fisher-Yetes shuffle on the input array.
--- The shuffle is not pure as the input array is directly mutated.
--- Pass `random` to make the shuffle deterministic, it must return an integer in the range [1, upper].
local function shuffle<T>(array: { T }, random: ((upper: number) -> number)?)
	local next_index = random or math.random
	for index = #array, 2, -1 do
		local rand_index = next_index(index)
		array[index], array[rand_index] = array[rand_index], array[index]
	end
end

return shuffle

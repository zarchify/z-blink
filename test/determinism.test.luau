local compiler = require("@compiler")

type Tiniest = typeof(require("@vendor/tiniest/tiniest_for_lute").configure({}))

const CONTRACT = [[
event ping = { from: Client, type: Reliable, call: SingleSync, data: u8 }
event pong = { from: Server, type: Unreliable, call: SingleSync, data: u8 }
]]

const RICH_CONTRACT = [[
type item = struct { id: u16, name: string(..24), tags: string(..8)[..4] }
type inventory = map {[u16]: item}(..64)
type action = union "kind" { buy { id: u16 }, sell { id: u16, count: u8 } }
scope shop {
	event act = { from: Client, type: Reliable, call: SingleSync, data: action }
	event stock = { from: Server, type: Reliable, call: ManyAsync, data: inventory }
}
event ping = { from: Both, type: Unreliable, call: Polling, data: (seq: u16, at: f64) }
function fetch = { data: u16, return: item? }
]]

const function compile(contents: string)
	return compiler.compile_contents(contents, { profile = "test" })
end

const function remote_names(source: string): { string }
	const names = {}
	for name in string.gmatch(source, "%x+") do
		if #name == 32 and table.find(names, name) == nil then
			table.insert(names, name)
		end
	end

	table.sort(names)
	return names
end

return function(tiniest: Tiniest)
	const test = tiniest.test
	const expect = tiniest.expect

	test("the same contract compiles to identical output", function()
		const first = compile(CONTRACT)
		const second = compile(CONTRACT)
		expect(first.client == second.client).is(true)
		expect(first.server == second.server).is(true)
		expect(first.types == second.types).is(true)
	end)

	test("a contract with structs, maps, unions, scopes and functions compiles to identical output", function()
		const first = compile(RICH_CONTRACT)
		for _ = 1, 3 do
			const again = compile(RICH_CONTRACT)
			expect(first.client == again.client).is(true)
			expect(first.server == again.server).is(true)
			expect(first.types == again.types).is(true)
		end
	end)

	test("client and server use the same remote names", function()
		const targets = compile(CONTRACT)
		const client_names = remote_names(targets.client)
		expect(#client_names > 0).is(true)
		expect(table.concat(remote_names(targets.server), ",")).is(table.concat(client_names, ","))
	end)

	test("changing the contract changes the remote names", function()
		const before = remote_names(compile(CONTRACT).client)
		const after = remote_names(compile(CONTRACT .. "\ntype extra = u8\n").client)
		expect(before[1] ~= after[1]).is(true)
	end)

	test("remote_scope changes the remote names", function()
		const unscoped = remote_names(compile(CONTRACT).client)
		const scoped = remote_names(compile('option remote_scope = "game_v2"\n' .. CONTRACT).client)
		expect(unscoped[1] ~= scoped[1]).is(true)
	end)
end

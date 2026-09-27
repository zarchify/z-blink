local compiler = require("@compiler")
local environment_mock = require("@test/mock/environment_mock")
local luau = require("@lute/luau")
local path = require("@util/path")

type Tiniest = typeof(require("@vendor/tiniest/tiniest_for_lute").configure({}))

const FIXTURES_PATH = path.from_string("./test/policy")

const function escape(text: string): string
	return (string.gsub(text, "%p", "%%%0"))
end

const function compile(contents: string)
	return compiler.compile_contents(contents, { profile = "test" })
end

const function compile_fixture(name: string)
	const file_path = path.join(FIXTURES_PATH, path.from_string(`{name}.blink`))
	const result = compiler.compile_from_path(file_path, { profile = "test" })
	if result.ok == false then
		error(result.error)
	end
end

const function event(from: string, data: string, attributes: string?): string
	return `{attributes or ""}\nevent e = \{ from: {from}, type: Reliable, call: SingleSync, data: {data} \}\n`
end

const function funct(data: string, ret: string, attributes: string?): string
	return `{attributes or ""}\nfunction f = \{ data: {data}, return: {ret} \}\n`
end

return function(tiniest: Tiniest)
	const test = tiniest.test
	const expect = tiniest.expect

	const function passes(name: string, contents: string)
		test(name, function()
			expect(function()
				compile(contents)
			end).never_fails()
		end)
	end

	const function rejects(name: string, contents: string, message: string)
		test(name, function()
			expect(function()
				compile(contents)
			end).fails_with(escape(message))
		end)
	end

	passes(
		"bounded contract compiles",
		event("Client", "(name: string(..32), bytes: u8[..8], scores: map {[u8]: u8}(..4))")
	)
	passes("option strict = false restores upstream behaviour", "option strict = false\n" .. event("Client", "unknown"))
	test("compile option strict = false restores upstream behaviour", function()
		expect(function()
			compiler.compile_contents(event("Client", "unknown"), { profile = "test", strict = false })
		end).never_fails()
	end)

	rejects("unknown is banned", event("Server", "unknown"), `"unknown" is not allowed`)
	rejects("unknown path is reported", event("Server", "struct { a: unknown }"), "violation at e.data.a")
	rejects("unknown inside unions is banned", event("Server", "u8 | unknown"), `"unknown" is not allowed`)
	rejects("unbounded string", event("Client", "string"), "Strings need a byte bound")
	rejects("unbounded buffer", event("Server", "buffer", "@opaque"), "Buffers need a byte bound")
	rejects("unbounded array", event("Client", "u8[]"), "Arrays need a length cap")
	rejects("unbounded map", event("Client", "struct { m: map {[u8]: u8} }"), "Maps need an entry cap")
	rejects("map value path", event("Client", "map {[u8]: string}(..4)"), "violation at e.data[value]")
	rejects("named parameter path", event("Client", "(id: u8, name: string)"), "violation at e.data.name")
	rejects("positional parameter path", event("Client", "(u8, string)"), "violation at e.data.2")
	rejects(
		"violation through a type alias",
		"type ledger = struct { entries: struct { value: string }[..4] }\n" .. event("Client", "ledger"),
		"violation at e.data.entries[].value"
	)
	rejects(
		"violation through a generic instantiation",
		"type box<T> = struct { value: T }\n" .. event("Client", "box<string>"),
		"violation at e.data.value"
	)
	rejects(
		"tagged union variants are checked",
		event("Client", 'union "kind" { chat { text: string } }'),
		"violation at e.data<chat>.text"
	)
	rejects(
		"recursive types are banned",
		"type node = struct { value: u8, next: node? }\n" .. event("Client", "node"),
		"Recursive types are not allowed"
	)

	do
		local nested = "u8"
		for _ = 1, 9 do
			nested = `struct \{ a: {nested} \}`
		end

		rejects("nesting depth is limited", event("Client", nested), "Nesting is deeper than 8 levels")
	end

	rejects("client events cannot send buffers", event("Client", "buffer(..64)"), "clients cannot send opaque data")
	rejects("both-way events cannot send buffers", event("Both", "buffer(..64)"), "clients cannot send opaque data")
	rejects("client events cannot be opaque", event("Client", "u8", "@opaque"), `Event "e" cannot be opaque`)
	rejects("server buffers need @opaque", event("Server", "buffer(..64)"), "add @opaque to this event")
	passes("server buffers with @opaque", event("Server", "buffer(..64)", "@opaque"))
	rejects("unused @opaque", event("Server", "u8", "@opaque"), `Unused "@opaque" attribute`)
	rejects("types cannot be opaque", "@opaque\ntype t = u8\n", "Types cannot be opaque")

	rejects("function data cannot be a buffer", funct("buffer(..8)", "u8"), "clients cannot send opaque data")
	rejects("function returns need @opaque", funct("u8", "buffer(..8)"), "add @opaque to this function")
	rejects("function return path", funct("u8", "string"), "violation at f.return")
	passes("function returns with @opaque", funct("u8", "buffer(..8)", "@opaque"))

	rejects("exported types are checked", "@export\ntype name = string\n", "violation at name")
	passes("exported types may hold buffers", "@export\ntype blob = buffer(..16)\n")
	passes("unused types are not checked", "type name = string\n")

	test("imports cannot loosen the policy", function()
		expect(function()
			compile_fixture("imports_loose")
		end).fails_with(escape("Imported files cannot loosen the policy"))
	end)

	test("imports inherit strictness", function()
		expect(function()
			compile_fixture("imports_unbounded")
		end).fails_with(escape("Strings need a byte bound"))
	end)

	test("imports of a lax contract may restate strict = false", function()
		expect(function()
			compile_fixture("lax_imports_loose")
		end).never_fails()
	end)

	do
		const targets = compile("@export\ntype capped = map {[u8]: u8}(1..4)\n")
		const module = luau.load(luau.compile(targets.types), "policy-map-cap", environment_mock())() :: any
		const capped = module.exports.capped

		test("capped map round trips", function()
			local decoded: any
			expect(function()
				decoded = capped.read(capped.write({ [1] = 1, [2] = 2 }))
			end).never_fails()
			expect(decoded[1]).is(1)
			expect(decoded[2]).is(2)
		end)

		test("writing more entries than the cap errors", function()
			expect(function()
				capped.write({ 1, 2, 3, 4, 5 })
			end).fails()
		end)

		test("writing fewer entries than the minimum errors", function()
			expect(function()
				capped.write({})
			end).fails()
		end)

		test("reading a well formed payload over the cap errors", function()
			const entries = 5
			const tampered = buffer.create(1 + entries * 2)
			buffer.writeu8(tampered, 0, entries)
			for index = 1, entries do
				buffer.writeu8(tampered, index * 2 - 1, index)
				buffer.writeu8(tampered, index * 2, index)
			end

			expect(function()
				capped.read(tampered)
			end).fails()
		end)
	end
end

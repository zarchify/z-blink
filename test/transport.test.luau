local compiler = require("@compiler")
local environment_mock = require("@test/mock/environment_mock")
local load_client = require("@test/utils/load_client")
local luau = require("@lute/luau")
local setup_client = require("@test/utils/setup_client")
local setup_server = require("@test/utils/setup_server")
local task = require("@std/task")

type Tiniest = typeof(require("@vendor/tiniest/tiniest_for_lute").configure({}))

const CONTRACT = [[
option manual_replication = true
option max_packet_bytes = 64
option max_packet_instances = 2
option max_packets_per_second = 5
option max_records_per_packet = 4
option max_records_per_second = 10

event ping = { from: Client, type: Reliable, call: SingleSync, data: u8 }
event crash = { from: Client, type: Reliable, call: SingleSync, data: u8 }
]]

type Session = {
	server: any,
	client: any,
	player: any,
	remote: any,
	violations: { string },
	received: { number },
	clock: { now: number },
}

const function start(contents: string): Session
	const targets = compiler.compile_contents(contents, { profile = "test" })
	const clock = { now = 0 }

	const server_dm = setup_server()
	const environment = table.clone(environment_mock(server_dm))
	environment.os = table.freeze({
		clock = function()
			return clock.now
		end,
	})

	const server = luau.load(luau.compile(targets.server), "transport-server", environment)() :: any
	const client_dm, player = setup_client(server_dm)
	const client = load_client(server_dm, client_dm, targets.client, "transport-client") :: any
	const remote = server_dm:GetService("ReplicatedStorage"):FindFirstChildOfClass("RemoteEvent")

	const session: Session = {
		server = server,
		client = client,
		player = player,
		remote = remote,
		violations = {},
		received = {},
		clock = clock,
	}

	server.set_violation_handler(function(_, reason: string)
		table.insert(session.violations, reason)
	end)

	if server.exports.ping then
		server.exports.ping.on(function(_, value: number)
			table.insert(session.received, value)
		end)
	end

	if server.exports.crash then
		server.exports.crash.on(function()
			error("handler bug")
		end)
	end

	return session
end

const function send_raw(session: Session, ...: any)
	session.remote.OnServerEvent:Fire(session.player, ...)
end

const function send_pings(session: Session, count: number)
	for index = 1, count do
		session.client.exports.ping.fire(index % 256)
	end

	session.client.step_replication()
end

return function(tiniest: Tiniest)
	const test = tiniest.test
	const expect = tiniest.expect

	const function expect_violation(session: Session, fragment: string)
		expect(#session.violations).is(1)
		expect(string.find(session.violations[1], fragment, 1, true) ~= nil).is(true)
	end

	test("valid packets are delivered without violations", function()
		const session = start(CONTRACT)
		send_pings(session, 3)
		expect(#session.received).is(3)
		expect(#session.violations).is(0)
	end)

	test("non buffer packets are dropped", function()
		const session = start(CONTRACT)
		send_raw(session, "not a buffer", {})
		expect_violation(session, "expected a buffer packet, got string")
	end)

	test("non table instance lists are dropped", function()
		const session = start(CONTRACT)
		send_raw(session, buffer.create(0), 5)
		expect_violation(session, "expected an instance table, got number")
	end)

	test("oversized packets are dropped", function()
		const session = start(CONTRACT)
		send_raw(session, buffer.create(65), {})
		expect_violation(session, "65 bytes exceeds the 64 byte limit")
	end)

	test("packets with too many instances are dropped", function()
		const session = start(CONTRACT)
		send_raw(session, buffer.create(0), { 1, 2, 3 })
		expect_violation(session, "instances per packet")
	end)

	const function capture_record(session: Session): buffer
		local captured: buffer? = nil
		session.remote.OnServerEvent:Connect(function(_, packet)
			if captured == nil then
				captured = packet
			end
		end)

		send_pings(session, 1)
		return assert(captured)
	end

	test("packets with too many records stop at the limit", function()
		const session = start(CONTRACT)
		const record = capture_record(session)
		const record_bytes = buffer.len(record)
		const packet = buffer.create(record_bytes * 6)
		for index = 0, 5 do
			buffer.copy(packet, index * record_bytes, record)
		end

		send_raw(session, packet, {})
		expect(#session.received).is(1 + 4)
		expect_violation(session, "records per packet")
	end)

	test("the client splits bursts at the record limit so every record arrives", function()
		const session = start(CONTRACT)
		send_pings(session, 6)
		expect(#session.received).is(6)
		expect(#session.violations).is(0)
	end)

	test("the client splits bursts at the byte limit so every record arrives", function()
		const session = start([[
			option manual_replication = true
			option max_packet_bytes = 16
			event text = { from: Client, type: Reliable, call: SingleSync, data: string(..8) }
		]])
		const received = {}
		session.server.exports.text.on(function(_, value: string)
			table.insert(received, value)
		end)

		for index = 1, 5 do
			session.client.exports.text.fire(`value{index}`)
		end

		session.client.step_replication()
		expect(#received).is(5)
		expect(received[5]).is("value5")
		expect(#session.violations).is(0)
	end)

	test("a failed invoke leaves no partial bytes and frees its slot", function()
		const session = start([[
			option manual_replication = true
			function lookup = { data: (id: u8, name: string(..4)), return: u8 }
		]])
		session.server.exports.lookup.on(function(_, id: number)
			return id
		end)

		for _ = 1, 40 do
			expect(function()
				session.client.exports.lookup.invoke(7, "too long")
			end).fails_with("Error serializing function")
		end

		local result: number? = nil
		const thread = task.spawn(function()
			result = session.client.exports.lookup.invoke(9, "ok")
		end)

		session.client.step_replication()
		session.server.step_replication()

		local waited = 0
		while coroutine.status(thread) ~= "dead" and waited < 2 do
			waited += task.wait()
		end

		expect(result).is(9)
		expect(#session.violations).is(0)
	end)

	const function invoke_async(session: Session, name: string, ...: any): () -> (boolean, any)
		local done, ok, result = false, false, nil
		const args = table.pack(...)
		task.spawn(function()
			ok, result = pcall(session.client.exports[name].invoke, table.unpack(args, 1, args.n))
			done = true
		end)

		return function()
			session.client.step_replication()
			session.server.step_replication()
			local waited = 0
			while not done and waited < 2 do
				waited += task.wait()
				session.client.step_replication()
				session.server.step_replication()
			end

			expect(done).is(true)
			return ok, result
		end
	end

	test("invoking a function with no server handler fails instead of hanging", function()
		const session = start([[
			option manual_replication = true
			function lookup = { data: u8, return: u8 }
		]])
		const ok, result = invoke_async(session, "lookup", 1)()
		expect(ok).is(false)
		expect(string.find(tostring(result), "Server encountered an error", 1, true) ~= nil).is(true)
	end)

	test("a handler returning invalid data fails the invocation instead of hanging", function()
		const session = start([[
			option manual_replication = true
			function lookup = { data: u8, return: u8 }
		]])
		session.server.exports.lookup.on(function()
			return 300
		end)

		const ok = invoke_async(session, "lookup", 1)()
		expect(ok).is(false)
	end)

	test("active invocations per player are limited", function()
		const session = start([[
			option manual_replication = true
			option max_active_invocations = 2
			function slow = { data: u8, return: u8 }
		]])
		local release = false
		session.server.exports.slow.on(function(_, value: number)
			while not release do
				task.wait()
			end
			return value
		end)

		const first = invoke_async(session, "slow", 1)
		const second = invoke_async(session, "slow", 2)
		const third = invoke_async(session, "slow", 3)

		const third_ok = third()
		expect(third_ok).is(false)
		expect_violation(session, "active invocations")

		release = true
		expect((first())).is(true)
		expect((second())).is(true)
		expect((invoke_async(session, "slow", 4)())).is(true)
	end)

	test("event queues are capped when no listener drains them", function()
		const session = start([[
			option manual_replication = true
			option max_queue_size = 3
			event pending = { from: Client, type: Reliable, call: Polling, data: u8 }
		]])
		for index = 1, 5 do
			session.client.exports.pending.fire(index)
		end
		session.client.step_replication()

		local drained = 0
		for _ in session.server.exports.pending.iter() do
			drained += 1
		end

		expect(drained).is(3)
		expect(#session.violations).is(2)
		expect(string.find(session.violations[1], "event queue is full", 1, true) ~= nil).is(true)
	end)

	test("a single record larger than the packet limit errors on the client", function()
		const session = start([[
			option manual_replication = true
			option max_packet_bytes = 4
			event text = { from: Client, type: Reliable, call: SingleSync, data: string(..8) }
		]])
		expect(function()
			session.client.exports.text.fire("too long")
		end).fails_with("exceeds the packet limits")

		session.client.exports.text.fire("ok")
		session.client.step_replication()
		expect(#session.violations).is(0)
	end)

	test("records per second are limited across packets", function()
		const session = start(CONTRACT)
		send_pings(session, 12)

		expect(#session.received).is(10)
		expect_violation(session, "records per second")
	end)

	test("packets per second are limited and the window resets", function()
		const session = start(CONTRACT)
		for _ = 1, 6 do
			send_raw(session, buffer.create(0), {})
		end

		expect_violation(session, "packets per second")

		session.clock.now += 1
		send_pings(session, 1)
		expect(#session.received).is(1)
		expect(#session.violations).is(1)
	end)

	test("malformed packets are reported as violations", function()
		const session = start(CONTRACT)
		const payload = buffer.create(1)
		buffer.writeu8(payload, 0, 255)
		send_raw(session, payload, {})
		expect_violation(session, "malformed packet")
	end)

	test("handler errors propagate and are not blamed on the client", function()
		const session = start(CONTRACT)
		session.client.exports.crash.fire(1)
		expect(function()
			session.client.step_replication()
		end).fails_with("handler bug")
		expect(#session.violations).is(0)
	end)

	test("lax contracts have no limits unless options set them", function()
		const session = start([[
			option strict = false
			option manual_replication = true
			event ping = { from: Client, type: Reliable, call: SingleSync, data: u8 }
		]])
		send_raw(session, buffer.create(100000), {})
		send_pings(session, 300)
		expect(#session.received).is(300)
		expect(#session.violations).is(1)
		expect_violation(session, "malformed packet")
	end)

	test("strict contracts get default limits", function()
		const session = start([[
			option manual_replication = true
			event ping = { from: Client, type: Reliable, call: SingleSync, data: u8 }
		]])
		send_raw(session, buffer.create(40000), {})
		expect_violation(session, "exceeds the 32768 byte limit")
	end)
end

local compiler = require("@compiler")
local data_model_mock = require("@test/mock/data_model_mock")
local environment_mock = require("@test/mock/environment_mock")
local load_client = require("@test/utils/load_client")
local luau = require("@lute/luau")
local setup_client = require("@test/utils/setup_client")
local setup_server = require("@test/utils/setup_server")

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

	test("packets with too many records stop at the limit", function()
		const session = start(CONTRACT)
		send_pings(session, 6)
		expect(#session.received).is(4)
		expect_violation(session, "records per packet")
	end)

	test("records per second are limited across packets", function()
		const session = start(CONTRACT)
		for _ = 1, 3 do
			send_pings(session, 4)
		end

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

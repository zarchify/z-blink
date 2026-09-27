local compiler = require("@compiler")
local data_model_mock = require("@test/mock/data_model_mock")
local environment_mock = require("@test/mock/environment_mock")
local fs = require("@std/fs")
local luau = require("@lute/luau")
local process = require("@lute/process")

const TEMP = "./temp/bench"
const WARMUP_ROUNDS = 50
const ROUNDS = 500
const BATCH = 64

type Adapter = {
	name: string,
	client_fire: (event: string, ...any) -> (),
	server_fire: (event: string, player: any, ...any) -> (),
	client_flush: () -> (),
	server_flush: () -> (),
	on_server: (event: string, callback: (...any) -> ()) -> (),
	on_client: (event: string, callback: (...any) -> ()) -> (),
	player: any,
	bytes: { client_to_server: number, server_to_client: number },
}

const function read_file(file_path: string): string
	return fs.readFileToString(file_path)
end

const function load_module(source: string, chunkname: string, data_model: any): any
	const environment = table.clone(environment_mock(data_model))
	environment._G = {}

	const cframe = table.clone(environment.CFrame)
	cframe.Angles = function()
		return {}
	end
	environment.CFrame = cframe
	return luau.load(luau.compile(source), chunkname, environment)()
end

const function remote_events(root: any): { any }
	const found = {}
	const function visit(instance: any)
		for _, child in instance:GetChildren() do
			if child.ClassName == "RemoteEvent" or child.ClassName == "UnreliableRemoteEvent" then
				table.insert(found, child)
			end
			visit(child)
		end
	end
	visit(root)
	return found
end

--- Loads a server and client pair over the mock data model and counts every byte sent each way.
const function start_session(server_source: string, client_source: string, label: string)
	const server_dm = data_model_mock.create_data_model("Server")
	const server = load_module(server_source, `{label}-server`, server_dm)
	const client_dm, player = data_model_mock.connect_player(server_dm)

	const bytes = { client_to_server = 0, server_to_client = 0 }
	for _, remote in remote_events(server_dm:GetService("ReplicatedStorage")) do
		const replicated = data_model_mock.replicate_instance(remote, server_dm, client_dm)
		remote.OnServerEvent:Connect(function(_, packet)
			bytes.client_to_server += buffer.len(packet)
		end)
		replicated.OnClientEvent:Connect(function(packet)
			bytes.server_to_client += buffer.len(packet)
		end)
	end

	const client = load_module(client_source, `{label}-client`, client_dm)
	return server, client, player, bytes
end

const function zap_adapter(write_checks: boolean): Adapter
	const suffix = if write_checks then "checked" else "unchecked"
	const zap_path = `{TEMP}/zap-{suffix}.zap`
	const server_path = `zap-{suffix}-server.luau`
	const client_path = `zap-{suffix}-client.luau`

	fs.writeStringToFile(
		zap_path,
		`opt server_output = "{server_path}"\nopt client_output = "{client_path}"\nopt write_checks = {write_checks}\n\n`
			.. read_file("./bench/contracts/bench.zap")
	)

	const result = process.run({ "zap", zap_path })
	assert(result.ok, `zap failed: {result.stderr}`)

	const server, client, player, bytes =
		start_session(read_file(`{TEMP}/{server_path}`), read_file(`{TEMP}/{client_path}`), `zap-{suffix}`)

	return {
		name = `Zap (write_checks = {write_checks})`,
		client_fire = function(event, ...)
			client[event].Fire(...)
		end,
		server_fire = function(event, target, ...)
			server[event].Fire(target, ...)
		end,
		client_flush = client.SendEvents,
		server_flush = server.SendEvents,
		on_server = function(event, callback)
			server[event].SetCallback(callback)
		end,
		on_client = function(event, callback)
			client[event].SetCallback(callback)
		end,
		player = player,
		bytes = bytes,
	}
end

const function blink_adapter(send_validation: boolean): Adapter
	const contract = `option send_validation = {send_validation}\n` .. read_file("./bench/contracts/bench.blink")
	const targets = compiler.compile_contents(contract, { profile = "release" })
	const label = if send_validation then "zblink-checked" else "zblink-unchecked"
	const server, client, player, bytes = start_session(targets.server, targets.client, label)

	return {
		name = `z-blink (send_validation = {send_validation})`,
		client_fire = function(event, ...)
			client.exports[event].fire(...)
		end,
		server_fire = function(event, target, ...)
			server.exports[event].fire(target, ...)
		end,
		client_flush = client.step_replication,
		server_flush = server.step_replication,
		on_server = function(event, callback)
			server.exports[event].on(callback)
		end,
		on_client = function(event, callback)
			client.exports[event].on(callback)
		end,
		player = player,
		bytes = bytes,
	}
end

type Sample = { encode: { number }, decode: { number }, bytes: number, received: number }

const function median(values: { number }): number
	const sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.ceil(#sorted / 2)]
end

const function percentile(values: { number }, p: number): number
	const sorted = table.clone(values)
	table.sort(sorted)
	return sorted[math.clamp(math.ceil(#sorted * p), 1, #sorted)]
end

type Scenario = {
	name: string,
	direction: "client_to_server" | "server_to_client",
	event: string,
	per_round: number,
	args: () -> { any },
}

const ENTITIES = table.create(64)
for index = 1, 64 do
	ENTITIES[index] = {
		id = index * 1000,
		position = vector.create(index * 1.5, 12.25, -index * 0.5),
		health = 100 + index,
		alive = index % 2 == 0,
	}
end

const SCENARIOS: { Scenario } = {
	{
		name = "input: 64 small events per flush, client to server",
		direction = "client_to_server",
		event = "input",
		per_round = BATCH,
		args = function()
			return { 123, vector.create(0.5, 0, -0.5) }
		end,
	},
	{
		name = "chat: 64 strings of 48 bytes per flush, client to server",
		direction = "client_to_server",
		event = "chat",
		per_round = BATCH,
		args = function()
			return { string.rep("a", 48) }
		end,
	},
	{
		name = "entities: 1 array of 64 structs per flush, server to client",
		direction = "server_to_client",
		event = "entities",
		per_round = 1,
		args = function()
			return { ENTITIES }
		end,
	},
}

const function run_scenario(adapter: Adapter, scenario: Scenario): Sample
	local received = 0
	const callback = function()
		received += 1
	end

	const args = scenario.args()
	const to_server = scenario.direction == "client_to_server"
	if to_server then
		adapter.on_server(scenario.event, callback)
	else
		adapter.on_client(scenario.event, callback)
	end

	const encode = {}
	const decode = {}
	const bytes_before = adapter.bytes[scenario.direction]

	for round = 1, WARMUP_ROUNDS + ROUNDS do
		const start = os.clock()
		for _ = 1, scenario.per_round do
			if to_server then
				adapter.client_fire(scenario.event, table.unpack(args))
			else
				adapter.server_fire(scenario.event, adapter.player, table.unpack(args))
			end
		end
		const fired = os.clock()

		if to_server then
			adapter.client_flush()
		else
			adapter.server_flush()
		end
		const flushed = os.clock()

		if round > WARMUP_ROUNDS then
			table.insert(encode, (fired - start) * 1e6 / scenario.per_round)
			table.insert(decode, (flushed - fired) * 1e6 / scenario.per_round)
		end
	end

	const total_events = (WARMUP_ROUNDS + ROUNDS) * scenario.per_round
	return {
		encode = encode,
		decode = decode,
		bytes = (adapter.bytes[scenario.direction] - bytes_before) / total_events,
		received = received,
	}
end

const function format(value: number): string
	return string.format("%.2f", value)
end

fs.createDirectory(TEMP, { makeParents = true })

const zap_version = process.run({ "zap", "--version" })
print(`Zap: {string.gsub(zap_version.stdout, "%s+$", "")}`)
print(`Rounds: {ROUNDS} after {WARMUP_ROUNDS} warmup rounds. Times are microseconds per event.`)
print("")

const adapters = {
	zap_adapter(true),
	zap_adapter(false),
	blink_adapter(true),
	blink_adapter(false),
}

for _, scenario in SCENARIOS do
	print(`### {scenario.name}`)
	print("")
	print("| Library | Encode median | Encode p90 | Send + decode median | Send + decode p90 | Bytes per event |")
	print("|---|---|---|---|---|---|")
	for _, adapter in adapters do
		const sample = run_scenario(adapter, scenario)
		const expected = (WARMUP_ROUNDS + ROUNDS) * scenario.per_round
		assert(sample.received == expected, `{adapter.name} delivered {sample.received} of {expected} events`)

		print(
			`| {adapter.name} | {format(median(sample.encode))} | {format(percentile(sample.encode, 0.9))} | {format(
				median(sample.decode)
			)} | {format(percentile(sample.decode, 0.9))} | {format(sample.bytes)} |`
		)
	end
	print("")
end

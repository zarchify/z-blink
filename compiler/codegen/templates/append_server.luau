local append_services = require("./append_services")
local globals = require("@lir/build/builders/globals")
local limits = require("@config/limits")
local string_builder = require("@util/string_builder")

type StringBuilder = string_builder.StringBuilder

local PLAYERS_MAP = globals.players_map.identifier

local EVENT_GLOBALS = globals.events
local RELIABLE_EVENT = EVENT_GLOBALS.reliable.identifier
local UNRELIABLE_EVENT = EVENT_GLOBALS.unreliable.identifier

local SERVICE_GLOBALS = globals.services
local PLAYERS = SERVICE_GLOBALS.players.identifier
local RUN_SERVICE = SERVICE_GLOBALS.run_service.identifier
local REPLICATED_STORAGE = SERVICE_GLOBALS.replicated_storage.identifier

local function append_event(builder: StringBuilder, register: string, name: string)
	local class = register == RELIABLE_EVENT and "RemoteEvent" or "UnreliableRemoteEvent"
	builder:append_lines({
		`local {register} = {REPLICATED_STORAGE}:FindFirstChild("{name}") :: {class}`,
		`if not {register} then`,
		`\tlocal event = Instance.new("{class}")`,
		`\tevent.Name = "{name}"`,
		`\tevent.Parent = {REPLICATED_STORAGE}`,
		`\t{register} = event`,
		"end",
	})
end

local function limit_literal(value: number?): string
	return if value == nil then "nil" else tostring(value)
end

local function append_guards(builder: StringBuilder, resolved: limits.Limits)
	builder:append_lines({
		"const limits = table.freeze({",
		`\tpacket_bytes = {limit_literal(resolved.packet_bytes)},`,
		`\tpacket_instances = {limit_literal(resolved.packet_instances)},`,
		`\tpackets_per_second = {limit_literal(resolved.packets_per_second)},`,
		`\trecords_per_packet = {limit_literal(resolved.records_per_packet)},`,
		`\trecords_per_second = {limit_literal(resolved.records_per_second)},`,
		`\tqueue_size = {limit_literal(resolved.queue_size)},`,
		`\tactive_invocations = {limit_literal(resolved.active_invocations)},`,
		"})",
		"local violation_handler: ((player: Player, reason: string) -> ())? = nil",
		"local dispatching = false",
		"local packet_records = 0",
		"const function report_violation(player: Player, reason: string)",
		"\tlocal handler = violation_handler",
		"\tif handler then",
		"\t\ttask.spawn(handler, player, reason)",
		"\telse",
		"\t\twarn(`[blink] dropped a packet from {player.Name}: {reason}`)",
		"\tend",
		"end",
		"const function admit_packet(player: Player, packet: any, unknowns: any): boolean",
		`\tlocal save = {PLAYERS_MAP}[player]`,
		"\tif save == nil then",
		"\t\treturn false",
		"\tend",
		"\tlocal now = os.clock()",
		"\tif now - save.window >= 1 then",
		"\t\tsave.window = now",
		"\t\tsave.packets = 0",
		"\t\tsave.records = 0",
		"\tend",
		"\tsave.packets += 1",
		"\tif limits.packets_per_second and save.packets > limits.packets_per_second then",
		'\t\treport_violation(player, "exceeded the packets per second limit")',
		"\t\treturn false",
		"\tend",
		'\tif typeof(packet) ~= "buffer" then',
		"\t\treport_violation(player, `expected a buffer packet, got {typeof(packet)}`)",
		"\t\treturn false",
		"\tend",
		"\tif limits.packet_bytes and buffer.len(packet) > limits.packet_bytes then",
		"\t\treport_violation(player, `packet of {buffer.len(packet)} bytes exceeds the {limits.packet_bytes} byte limit`)",
		"\t\treturn false",
		"\tend",
		'\tif unknowns ~= nil and typeof(unknowns) ~= "table" then',
		"\t\treport_violation(player, `expected an instance table, got {typeof(unknowns)}`)",
		"\t\treturn false",
		"\tend",
		"\tif unknowns ~= nil and limits.packet_instances then",
		"\t\tlocal count = 0",
		"\t\tfor _ in unknowns do",
		"\t\t\tcount += 1",
		"\t\t\tif count > limits.packet_instances then",
		'\t\t\t\treport_violation(player, "exceeded the instances per packet limit")',
		"\t\t\t\treturn false",
		"\t\t\tend",
		"\t\tend",
		"\tend",
		"\tpacket_records = 0",
		"\treturn true",
		"end",
		"const function admit_record(player: Player): boolean",
		"\tpacket_records += 1",
		"\tif limits.records_per_packet and packet_records > limits.records_per_packet then",
		'\t\treport_violation(player, "exceeded the records per packet limit")',
		"\t\treturn false",
		"\tend",
		`\tlocal save = {PLAYERS_MAP}[player]`,
		"\tsave.records += 1",
		"\tif limits.records_per_second and save.records > limits.records_per_second then",
		'\t\treport_violation(player, "exceeded the records per second limit")',
		"\t\treturn false",
		"\tend",
		"\treturn true",
		"end",
		"const function admit_queue(player: Player, pending: number): boolean",
		"\tif limits.queue_size and pending >= limits.queue_size then",
		'\t\treport_violation(player, "an event queue is full, the event was dropped")',
		"\t\treturn false",
		"\tend",
		"\treturn true",
		"end",
		"const function admit_invocation(player: Player): boolean",
		`\tlocal save = {PLAYERS_MAP}[player]`,
		"\tif save == nil then",
		"\t\treturn false",
		"\tend",
		"\tif limits.active_invocations and save.active >= limits.active_invocations then",
		'\t\treport_violation(player, "exceeded the active invocations limit")',
		"\t\treturn false",
		"\tend",
		"\tsave.active += 1",
		"\treturn true",
		"end",
		"const function finish_invocation(player: Player)",
		`\tlocal save = {PLAYERS_MAP}[player]`,
		"\tif save then",
		"\t\tsave.active -= 1",
		"\tend",
		"end",
		"const function guard_receive(receive: (Player, buffer, { any }?) -> ())",
		"\treturn function(player: Player, packet: any, unknowns: any)",
		"\t\tif not admit_packet(player, packet, unknowns) then",
		"\t\t\treturn",
		"\t\tend",
		"\t\tdispatching = false",
		"\t\tlocal ok, message = xpcall(receive, function(message)",
		"\t\t\treturn if dispatching then debug.traceback(tostring(message), 2) else tostring(message)",
		"\t\tend, player, packet, unknowns)",
		"\t\tif ok then",
		"\t\t\treturn",
		"\t\tend",
		"\t\tif dispatching then",
		"\t\t\tdispatching = false",
		"\t\t\terror(message, 0)",
		"\t\tend",
		"\t\treport_violation(player, `malformed packet: {message}`)",
		"\tend",
		"end",
	})
end

local function append_server(
	builder: StringBuilder,
	reliable_name: string,
	unreliable_name: string,
	resolved_limits: limits.Limits
)
	append_services(builder)
	builder:append_line(`assert({RUN_SERVICE}:IsServer(), "The server module can only be required from the server!")`)
	append_event(builder, RELIABLE_EVENT, reliable_name)
	append_event(builder, UNRELIABLE_EVENT, unreliable_name)

	builder:append_lines({
		"type Save = {",
		"\tread buffers: { buffer },",
		"\tread lengths: { number },",
		"\tread unknown: { any },",
		"\twindow: number,",
		"\tpackets: number,",
		"\trecords: number,",
		"\tactive: number,",
		"}",
	})

	builder:append_line(`local {PLAYERS_MAP}: \{ [Player]: Save } = \{}`)
	builder:append_lines({
		`const function create_save(player: Player)`,
		`\t{PLAYERS_MAP}[player] = \{`,
		"\t\tbuffers = table.create<<buffer>>(16),",
		"\t\tlengths = table.create<<number>>(16),",
		"\t\tunknown = table.create<<any>>(16),",
		"\t\twindow = os.clock(),",
		"\t\tpackets = 0,",
		"\t\trecords = 0,",
		"\t\tactive = 0,",
		"\t}",
		`end`,
	})
	builder:append_lines({
		`for _, player in {PLAYERS}:GetPlayers() do`,
		"\tcreate_save(player)",
		"end",
	})
	builder:append_lines({
		`{PLAYERS}.PlayerAdded:Connect(function(player)`,
		"\tcreate_save(player)",
		"end)",
	})
	builder:append_lines({
		`{PLAYERS}.PlayerRemoving:Connect(function(player)`,
		`\t{PLAYERS_MAP}[player] = nil`,
		"end)",
	})

	append_guards(builder, resolved_limits)

	builder:append_line("")
end

return append_server

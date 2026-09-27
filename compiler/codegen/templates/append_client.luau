local append_services = require("./append_services")
local globals = require("@lir/build/builders/globals")
local limits = require("@config/limits")
local string_builder = require("@util/string_builder")

type StringBuilder = string_builder.StringBuilder

local EVENT_GLOBALS = globals.events
local RELIABLE_EVENT = EVENT_GLOBALS.reliable.identifier
local UNRELIABLE_EVENT = EVENT_GLOBALS.unreliable.identifier

local SERVICE_GLOBALS = globals.services
local RUN_SERVICE = SERVICE_GLOBALS.run_service.identifier
local REPLICATED_STORAGE = SERVICE_GLOBALS.replicated_storage.identifier

local function append_client(builder: StringBuilder, reliable_event: string, unreliable_event: string)
	append_services(builder)
	builder:append_line(`assert({RUN_SERVICE}:IsClient(), "The client module can only be required from the client!")`)
	builder:append_line(`local {RELIABLE_EVENT} = {REPLICATED_STORAGE}:WaitForChild("{reliable_event}") :: RemoteEvent`)
	builder:append_line(
		`local {UNRELIABLE_EVENT} = {REPLICATED_STORAGE}:WaitForChild("{unreliable_event}") :: UnreliableRemoteEvent`
	)
	builder:append_line("")
end

local function limit_literal(value: number?): string
	return if value == nil then "nil" else tostring(value)
end

--- Emits the helper that splits outgoing reliable packets at a record boundary so the
--- server's packet limits are never exceeded by legitimate traffic.
--- It must be appended after the outgoing buffer locals are declared.
local function append_client_flush(builder: StringBuilder, resolved: limits.Limits)
	builder:append_lines({
		"const packet_limits = table.freeze({",
		`\tpacket_bytes = {limit_literal(resolved.packet_bytes)},`,
		`\tpacket_instances = {limit_literal(resolved.packet_instances)},`,
		`\trecords_per_packet = {limit_literal(resolved.records_per_packet)},`,
		"})",
		"local out_records = 0",
		"const function exceeds_packet_limits(bytes: number, instances: number, records: number): boolean",
		"\treturn (packet_limits.packet_bytes ~= nil and bytes > packet_limits.packet_bytes)",
		"\t\tor (packet_limits.packet_instances ~= nil and instances > packet_limits.packet_instances)",
		"\t\tor (packet_limits.records_per_packet ~= nil and records > packet_limits.records_per_packet)",
		"end",
		"const function after_record(prev_cursor: number, prev_unknowns: number)",
		"\tout_records += 1",
		"\tif not exceeds_packet_limits(out_cursor, #out_unknown, out_records) then",
		"\t\treturn",
		"\tend",
		"\tlocal record_bytes = out_cursor - prev_cursor",
		"\tlocal record_instances = #out_unknown - prev_unknowns",
		"\tif exceeds_packet_limits(record_bytes, record_instances, 1) then",
		"\t\tout_cursor = prev_cursor",
		"\t\tfor index = #out_unknown, prev_unknowns + 1, -1 do",
		"\t\t\tout_unknown[index] = nil",
		"\t\tend",
		"\t\tout_records -= 1",
		"\t\terror(`[Blink]: A single record of {record_bytes} bytes and {record_instances} instances exceeds the packet limits and was dropped.`, 2)",
		"\tend",
		"\tlocal packet = buffer.create(prev_cursor)",
		"\tbuffer.copy(packet, 0, out_buffer, 0, prev_cursor)",
		"\tlocal packet_unknowns = table.move(out_unknown, 1, prev_unknowns, 1, table.create(prev_unknowns))",
		"\tbuffer.copy(out_buffer, 0, out_buffer, prev_cursor, record_bytes)",
		"\ttable.move(out_unknown, prev_unknowns + 1, prev_unknowns + record_instances, 1)",
		"\tfor index = #out_unknown, record_instances + 1, -1 do",
		"\t\tout_unknown[index] = nil",
		"\tend",
		"\tout_cursor = record_bytes",
		"\tout_records = 1",
		`\t{RELIABLE_EVENT}:FireServer(packet, packet_unknowns)`,
		"end",
	})
end

return table.freeze({
	append_client = append_client,
	append_client_flush = append_client_flush,
})

--!strict

local types = require("@lir/types")

type Global<T = any> = types.Global<T>

local function global<T>(identifier: string): Global<T>
	return {
		__readable = nil :: any,
		__writeable = nil :: any,

		type = "global",
		identifier = identifier,
	}
end

return table.freeze({
	create = global,
	templates = global("templates"),
	types_map = global("types"),
	queues_map = global("queues"),
	players_map = global<<{ [Player]: any }>>("players_map"),
	connections_map = global("connections"),
	invocations_map = global("invocations"),
	invocations_bitset = global<<number>>("invocations_bitset"),
	dispatching = global<<{ [thread]: true }>>("dispatching"),
	admit_record = global<<(any) -> boolean>>("admit_record"),
	after_record = global<<(number, number) -> ()>>("after_record"),
	admit_queue = global<<(any, number) -> boolean>>("admit_queue"),
	admit_invocation = global<<(any) -> boolean>>("admit_invocation"),
	finish_invocation = global<<(any) -> ()>>("finish_invocation"),
	out_records = global<<number>>("out_records"),

	services = {
		players = global<<Players>>("PLAYERS"),
		run_service = global<<RunService>>("RUN_SERVICE"),
		replicated_storage = global<<ReplicatedStorage>>("REPLICATED_STORAGE"),
	},

	incoming = {
		buffer = global<<buffer>>("in_buffer"),
		cursor = global<<number>>("in_cursor"),
		unknown = global<<{ any }>>("in_unknown"),
		unknown_cursor = global<<number>>("in_unknown_cursor"),
	},

	outgoing = {
		buffer = global<<buffer>>("out_buffer"),
		cursor = global<<number>>("out_cursor"),
		length = global<<number>>("out_length"),
		unknown = global<<{ any }>>("out_unknown"),
	},

	events = {
		reliable = global<<RemoteEvent>>("RELIABLE_EVENT"),
		unreliable = global<<RemoteEvent>>("UNRELIABLE_EVENT"),
	},
})

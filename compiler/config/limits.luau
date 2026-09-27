local options = require("@config/options")

type FileOptions = options.FileOptions

export type Limits = {
	read packet_bytes: number?,
	read packet_instances: number?,
	read packets_per_second: number?,
	read records_per_packet: number?,
	read records_per_second: number?,
}

--- Defaults applied to strict contracts. They are deliberately generous so that legitimate
--- traffic from high frame rate clients passes, and every one can be tuned with an option.
const STRICT_DEFAULTS: Limits = table.freeze({
	packet_bytes = 32768,
	packet_instances = 256,
	packets_per_second = 600,
	records_per_packet = 256,
	records_per_second = 3000,
})

const NO_LIMITS: Limits = table.freeze({})

--- Resolves the transport limits for a contract from its entry options.
--- Lax contracts have no limits unless an option sets one.
local function resolve(entry_options: FileOptions, strict: boolean): Limits
	const defaults = if strict then STRICT_DEFAULTS else NO_LIMITS
	return table.freeze({
		packet_bytes = entry_options.max_packet_bytes or defaults.packet_bytes,
		packet_instances = entry_options.max_packet_instances or defaults.packet_instances,
		packets_per_second = entry_options.max_packets_per_second or defaults.packets_per_second,
		records_per_packet = entry_options.max_records_per_packet or defaults.records_per_packet,
		records_per_second = entry_options.max_records_per_second or defaults.records_per_second,
	})
end

return table.freeze({
	STRICT_DEFAULTS = STRICT_DEFAULTS,
	resolve = resolve,
})

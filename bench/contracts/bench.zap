opt manual_event_loop = true

type Entity = struct {
	id: u32,
	position: vector(f32, f32, f32),
	health: u16,
	alive: boolean,
}

event input = { from: Client, type: Reliable, call: SingleSync, data: (seq: u16, dir: vector(f32, f32, f32)) }
event chat = { from: Client, type: Reliable, call: SingleSync, data: string(..64) }
event entities = { from: Server, type: Reliable, call: SingleSync, data: Entity[..64] }

local cframe_mock = require("@test/mock/cframe_mock")
local compiler = require("@compiler")
local environment_mock = require("@test/mock/environment_mock")
local luau = require("@lute/luau")

type Tiniest = typeof(require("@vendor/tiniest/tiniest_for_lute").configure({}))

const CONTRACT = [[
@export
type double = f64
@export
type float = f32
@export
type position = vector
@export
type transform = CFrame
@export
type flag = boolean
@export
type byte = u8
@export
type scores = map {[u8]: u8}(..8)
@export
type point = struct { x: u8, y: u8 }
@export
type bytes = u8[..8]
@export
type command = union "kind" { move { x: u8 }, stop {} }
@export
type points = point[..2]
type box<T> = struct { value: T }
@export
type boxes = box<u8>[..2]
]]

const function load(profile: "test" | "release", prefix: string?)
	const targets = compiler.compile_contents((prefix or "") .. CONTRACT, { profile = profile })
	return luau.load(luau.compile(targets.types), `hostile-{profile}`, environment_mock())().exports
end

const function bytes(values: { number }): buffer
	const result = buffer.create(#values)
	for index, value in values do
		buffer.writeu8(result, index - 1, value)
	end

	return result
end

return function(tiniest: Tiniest)
	const test = tiniest.test
	const expect = tiniest.expect

	const exports = load("test")
	const release = load("release")
	const unchecked = load("release", "option send_validation = false\n")
	const lax_release = load("release", "option strict = false\n")

	const function rejects_read(name: string, type_name: string, payload: buffer)
		test(`read rejects {name}`, function()
			expect(function()
				exports[type_name].read(payload)
			end).fails()
			expect(function()
				release[type_name].read(payload)
			end).fails()
		end)
	end

	const function rejects_write(name: string, type_name: string, value: any)
		test(`write rejects {name}`, function()
			expect(function()
				exports[type_name].write(value)
			end).fails()
		end)
	end

	const function f64_payload(value: number): buffer
		const result = buffer.create(8)
		buffer.writef64(result, 0, value)
		return result
	end

	rejects_read("NaN doubles", "double", f64_payload(0 / 0))
	rejects_read("infinite doubles", "double", f64_payload(math.huge))
	rejects_read("negative infinite doubles", "double", f64_payload(-math.huge))

	do
		const payload = buffer.create(4)
		buffer.writef32(payload, 0, 0 / 0)
		rejects_read("NaN floats", "float", payload)
	end

	do
		const payload = buffer.create(12)
		buffer.writef32(payload, 0, 0 / 0)
		rejects_read("NaN vector components", "position", payload)
	end

	do
		const payload = buffer.create(12)
		buffer.writef32(payload, 4, math.huge)
		rejects_read("infinite vector components", "position", payload)
	end

	rejects_read("boolean bytes other than 0 and 1", "flag", bytes({ 2 }))
	rejects_read("duplicate map keys", "scores", bytes({ 2, 1, 1, 1, 2 }))
	rejects_read("unknown union variants", "command", bytes({ 7 }))

	rejects_write("NaN doubles", "double", 0 / 0)
	rejects_write("infinite doubles", "double", math.huge)
	rejects_write("floats beyond the f32 range", "float", 1e39)
	rejects_write("NaN vector components", "position", vector.create(0 / 0, 0, 0))
	rejects_write("integers beyond the type range", "byte", 300)
	rejects_write("negative unsigned integers", "byte", -1)
	rejects_write("fractional integers", "byte", 1.5)
	rejects_write("map keys beyond the type range", "scores", { [300] = 1 })
	rejects_write("fractional map keys", "scores", { [1.5] = 1 })
	rejects_write("unknown struct fields", "point", { x = 1, y = 2, z = 3 })
	rejects_write("non table structs", "point", 5)
	rejects_write("sparse arrays", "bytes", { 1, nil :: any, 3 })
	rejects_write("arrays with extra keys", "bytes", { 1, 2, extra = 3 })
	rejects_write("unknown union variant fields", "command", { kind = "stop", extra = 1 })
	rejects_write("arrays of named structs beyond their cap", "points", table.create(3, { x = 1, y = 1 }))
	rejects_write("arrays of generic structs beyond their cap", "boxes", table.create(3, { value = 1 }))

	test("arrays of named structs keep their cap when read", function()
		const valid = exports.points.write({ { x = 1, y = 2 } })
		expect(buffer.readu8(valid, 0)).is(1)

		const payload = buffer.create(1 + 3 * 2)
		buffer.writeu8(payload, 0, 3)
		expect(function()
			exports.points.read(payload)
		end).fails()
	end)

	test("valid values still round trip", function()
		expect(exports.flag.read(exports.flag.write(true))).is(true)
		expect(exports.flag.read(exports.flag.write(false))).is(false)
		expect(exports.byte.read(exports.byte.write(255))).is(255)
		expect(exports.double.read(exports.double.write(-1.5))).is(-1.5)

		const point = exports.point.read(exports.point.write({ x = 1, y = 2 }))
		expect(point.x).is(1)
		expect(point.y).is(2)

		const command = exports.command.read(exports.command.write({ kind = "move", x = 3 }))
		expect(command.kind).is("move")
		expect(command.x).is(3)

		const list = exports.bytes.read(exports.bytes.write({ 1, 2, 3 }))
		expect(#list).is(3)
		expect(list[3]).is(3)
	end)

	test("strict contracts validate sends in release builds", function()
		expect(function()
			release.byte.write(300)
		end).fails()
	end)

	test("send_validation = false turns send checks off", function()
		expect(function()
			unchecked.byte.write(300)
		end).never_fails()
	end)

	test("lax contracts keep upstream behaviour and skip send checks in release", function()
		expect(function()
			lax_release.byte.write(300)
		end).never_fails()
	end)

	test("unvalidated sends do not corrupt the stream when arrays carry extra keys", function()
		const encoded = unchecked.bytes.write({ 1, 2, extra = 3 })
		const decoded = unchecked.bytes.read(encoded)
		expect(#decoded).is(2)
		expect(buffer.len(encoded)).is(3)
	end)

	test("non finite CFrame positions are rejected on read", function()
		const valid = exports.transform.write(cframe_mock.new(1, 2, 3))
		const tampered = buffer.create(buffer.len(valid))
		buffer.copy(tampered, 0, valid)
		buffer.writef32(tampered, 0, 0 / 0)
		expect(function()
			exports.transform.read(tampered)
		end).fails()
	end)
end

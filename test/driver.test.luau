local driver = require("../cli/driver")
local fs = require("@util/fs")
local path = require("@util/path")

type Tiniest = typeof(require("@vendor/tiniest/tiniest_for_lute").configure({}))

const TEMP_PATH = path.from_string("./temp")

const CONTRACT = [[
option client_output = "../out/net/client"
option server_output = "../out/net/server"
event ping = { from: Client, type: Reliable, call: SingleSync, data: u8 }
]]

local project_counter = 0

type Project = {
	root: any,
	write: (relative: string, contents: string) -> (),
	read: (relative: string) -> string?,
	exists: (relative: string) -> boolean,
	config: () -> driver.Config,
}

const function create_project(files: { [string]: string }): Project
	project_counter += 1
	const root = path.join(TEMP_PATH, path.from_string(`driver-{project_counter}`))

	const function target(relative: string)
		return path.join(root, path.from_string(relative))
	end

	const project: Project = {
		root = root,
		write = function(relative: string, contents: string)
			const file_path = target(relative)
			const parent = path.parent(file_path)
			local chain = {}
			local cursor = parent
			while cursor and not fs.is_directory(cursor) do
				table.insert(chain, 1, cursor)
				cursor = path.parent(cursor)
			end
			for _, directory in chain do
				fs.write_directory(directory)
			end
			assert(fs.write_string_to_file(file_path, contents).ok)
		end,
		read = function(relative: string): string?
			const file_path = target(relative)
			if not fs.is_file(file_path) then
				return nil
			end
			const result = fs.read_string_from_file(file_path)
			return if result.ok then result.value else nil
		end,
		exists = function(relative: string): boolean
			return fs.is_file(target(relative))
		end,
		config = function()
			return driver.load_config(target("blink.toml"))
		end,
	}

	for relative, contents in files do
		project.write(relative, contents)
	end

	return project
end

const function default_project(): Project
	return create_project({
		["blink.toml"] = '[[contract]]\nentry = "remotes/net.blink"\nprofile = "release"\n',
		["remotes/net.blink"] = CONTRACT,
	})
end

const function kinds(problems: { driver.Problem }): string
	const list = {}
	for _, problem in problems do
		table.insert(list, `{problem.kind}:{problem.path}`)
	end

	return table.concat(list, ",")
end

return function(tiniest: Tiniest)
	const test = tiniest.test
	const expect = tiniest.expect

	test("generate writes every output and a manifest, then check is clean", function()
		const project = default_project()
		const report = driver.generate(project.config())

		expect(#report.written).is(2)
		expect(project.exists("out/net/client.luau")).is(true)
		expect(project.exists("out/net/server.luau")).is(true)
		expect(project.exists(driver.MANIFEST_NAME)).is(true)
		expect(project.exists(driver.JOURNAL_NAME)).is(false)
		expect(kinds(driver.check(project.config()))).is("")
	end)

	test("generating again leaves unchanged files alone", function()
		const project = default_project()
		driver.generate(project.config())
		const report = driver.generate(project.config())
		expect(#report.written).is(0)
		expect(#report.unchanged).is(2)
	end)

	test("check reports missing outputs", function()
		const project = default_project()
		expect(kinds(driver.check(project.config()))).is("missing:out/net/client.luau,missing:out/net/server.luau")
	end)

	test("check reports hand edited outputs", function()
		const project = default_project()
		driver.generate(project.config())
		project.write("out/net/client.luau", "-- edited")
		expect(kinds(driver.check(project.config()))).is("edited:out/net/client.luau")
	end)

	test("check reports stale outputs and generate fixes them", function()
		const project = default_project()
		driver.generate(project.config())
		project.write(
			"remotes/net.blink",
			CONTRACT .. "event pong = { from: Server, type: Reliable, call: SingleSync, data: u8 }\n"
		)

		expect(kinds(driver.check(project.config()))).is("stale:out/net/client.luau,stale:out/net/server.luau")
		driver.generate(project.config())
		expect(kinds(driver.check(project.config()))).is("")
	end)

	test("outputs a contract no longer produces are orphaned and removed", function()
		const project = default_project()
		driver.generate(project.config())
		project.write("remotes/net.blink", (string.gsub(CONTRACT, "out/net/server", "out/net/server_v2")))

		const problems = kinds(driver.check(project.config()))
		expect(string.find(problems, "orphaned:out/net/server.luau", 1, true) ~= nil).is(true)

		const report = driver.generate(project.config())
		expect(report.removed[1]).is("out/net/server.luau")
		expect(project.exists("out/net/server.luau")).is(false)
		expect(kinds(driver.check(project.config()))).is("")
	end)

	test("hand edited orphans are kept, not deleted", function()
		const project = default_project()
		driver.generate(project.config())
		project.write("out/net/server.luau", "-- my changes")
		project.write("remotes/net.blink", (string.gsub(CONTRACT, "out/net/server", "out/net/server_v2")))

		const report = driver.generate(project.config())
		expect(report.kept[1]).is("out/net/server.luau")
		expect(project.read("out/net/server.luau")).is("-- my changes")
	end)

	test("outputs written outside generate are reported as untracked", function()
		const project = default_project()
		driver.generate(project.config())
		fs.remove_file(path.join(project.root, path.from_string(driver.MANIFEST_NAME)))
		expect(kinds(driver.check(project.config()))).is("untracked:out/net/client.luau,untracked:out/net/server.luau")
	end)

	test("an interrupted generate is detected by check and repaired by the next generate", function()
		const project = default_project()
		expect(function()
			driver.generate(project.config(), 1)
		end).fails_with("interrupted")

		expect(project.exists(driver.JOURNAL_NAME)).is(true)
		const problems = kinds(driver.check(project.config()))
		expect(string.find(problems, "interrupted", 1, true) ~= nil).is(true)

		const report = driver.generate(project.config())
		expect(report.recovered).is(true)
		expect(project.exists(driver.JOURNAL_NAME)).is(false)
		expect(project.exists("out/net/server.luau.blink-tmp")).is(false)
		expect(kinds(driver.check(project.config()))).is("")
	end)

	test("a compile error writes nothing", function()
		const project = create_project({
			["blink.toml"] = '[[contract]]\nentry = "remotes/net.blink"\n',
			["remotes/net.blink"] = CONTRACT
				.. "event bad = { from: Client, type: Reliable, call: SingleSync, data: string }\n",
		})

		expect(function()
			driver.generate(project.config())
		end).fails_with("Strings need a byte bound")

		expect(project.exists("out/net/client.luau")).is(false)
		expect(project.exists(driver.JOURNAL_NAME)).is(false)
		expect(project.exists(driver.MANIFEST_NAME)).is(false)
	end)

	test("two contracts writing the same file are rejected", function()
		const project = create_project({
			["blink.toml"] = '[[contract]]\nentry = "a/net.blink"\n\n[[contract]]\nentry = "b/net.blink"\n',
			["a/net.blink"] = CONTRACT,
			["b/net.blink"] = CONTRACT,
		})

		expect(function()
			driver.plan(project.config())
		end).fails_with("both write")
	end)

	test("configs are validated", function()
		const empty = create_project({ ["blink.toml"] = "" })
		expect(function()
			empty.config()
		end).fails_with("at least one")

		const unknown = create_project({ ["blink.toml"] = '[[contract]]\nentry = "x.blink"\nprofile = "prod"\n' })
		expect(function()
			unknown.config()
		end).fails_with("unknown profile")
	end)
end

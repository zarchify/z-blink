local compilation = require("@compiler/config/compilation")
local compiler = require("@compiler")
local fs = require("@util/fs")
local md5 = require("@vendor/md5")
local path = require("@util/path")
local toml = require("@vendor/toml")

type Path = path.Path
type Profile = compilation.Profile

export type Contract = {
	read entry: string,
	read profile: Profile,
}

export type Config = {
	read root: Path,
	read contracts: { Contract },
}

export type Output = {
	read path: string,
	read contract: string,
	read contents: string,
}

export type ManifestEntry = {
	read path: string,
	read contract: string,
	read hash: string,
}

export type ProblemKind = "missing" | "stale" | "edited" | "orphaned" | "untracked" | "interrupted"

export type Problem = {
	read kind: ProblemKind,
	read path: string,
	read contract: string?,
}

export type GenerateReport = {
	read written: { string },
	read unchanged: { string },
	read removed: { string },
	read kept: { string },
	read recovered: boolean,
}

const MANIFEST_NAME = "blink.manifest.toml"
const JOURNAL_NAME = "blink.journal.toml"
const TEMP_SUFFIX = ".blink-tmp"

const VALID_PROFILES: { [string]: true } = {
	dev = true,
	test = true,
	release = true,
}

const function absolute(config: Config, relative: string): Path
	return path.join(config.root, path.from_string(relative))
end

const function read_text(target: Path): string?
	if not fs.is_file(target) then
		return nil
	end

	const result = fs.read_string_from_file(target)
	if result.ok == false then
		error(`Unable to read "{path.to_string(target)}": {result.error.message}`)
	end

	return result.value
end

local function ensure_directory(directory: Path)
	if fs.is_directory(directory) then
		return
	end

	const parent = path.parent(directory)
	if parent then
		ensure_directory(parent)
	end

	const created = fs.write_directory(directory)
	if created.ok == false and not fs.is_directory(directory) then
		error(`Unable to create "{path.to_string(directory)}": {created.error.message}`)
	end
end

const function write_text(target: Path, contents: string)
	const parent = path.parent(target)
	if parent then
		ensure_directory(parent)
	end

	const result = fs.write_string_to_file(target, contents)
	if result.ok == false then
		error(`Unable to write "{path.to_string(target)}": {result.error.message}`)
	end
end

const function remove(target: Path)
	if not fs.is_file(target) then
		return
	end

	const result = fs.remove_file(target)
	if result.ok == false then
		error(`Unable to remove "{path.to_string(target)}": {result.error.message}`)
	end
end

const function move(from: Path, to: Path)
	const result = fs.move(from, to, { overwrite = true } :: any)
	if result.ok == false then
		error(`Unable to move "{path.to_string(from)}" to "{path.to_string(to)}": {result.error.message}`)
	end
end

--- Collapses "." and ".." segments so equivalent relative paths compare equal.
const function normalize(relative: string): string
	const segments = {}
	for segment in string.gmatch(string.gsub(relative, "\\", "/"), "[^/]+") do
		if segment == "." then
			continue
		elseif segment == ".." and #segments > 0 and segments[#segments] ~= ".." then
			table.remove(segments)
		else
			table.insert(segments, segment)
		end
	end

	return table.concat(segments, "/")
end

const function hash(contents: string): string
	return md5(contents)
end

--- Reads and validates a project config file listing every contract.
local function load_config(config_path: Path): Config
	const source = read_text(config_path)
	if source == nil then
		error(`Unable to find the project config "{path.to_string(config_path)}"`)
	end

	const parsed = toml.deserialize(source) :: any
	const entries = parsed.contract
	if type(entries) ~= "table" or #entries == 0 then
		error(`"{path.to_string(config_path)}" must list at least one [[contract]]`)
	end

	const contracts: { Contract } = {}
	const seen: { [string]: true } = {}
	for index, entry in entries do
		const entry_path = entry.entry
		if type(entry_path) ~= "string" then
			error(`contract #{index} needs an "entry" path`)
		end

		if seen[entry_path] then
			error(`contract "{entry_path}" is listed more than once`)
		end

		const profile = entry.profile or "dev"
		if VALID_PROFILES[profile] ~= true then
			error(`contract "{entry_path}" has unknown profile "{profile}"`)
		end

		seen[entry_path] = true
		table.insert(contracts, { entry = entry_path, profile = profile })
	end

	return {
		root = path.parent(config_path) or path.from_string("."),
		contracts = contracts,
	}
end

--- Compiles every contract in memory and returns the files they produce, keyed by path.
--- Nothing is written, so a compile error leaves the project untouched.
local function plan(config: Config): { [string]: Output }
	const outputs: { [string]: Output } = {}
	for _, contract in config.contracts do
		const entry_path = absolute(config, contract.entry)
		const result = compiler.compile_from_path(entry_path, { profile = contract.profile })
		if result.ok == false then
			error(`Unable to compile "{contract.entry}": {result.error.message}`)
		end

		const entry_directory = path.strip_file_name(path.from_string(contract.entry))
		for _, target in result.value.targets :: { [string]: any } do
			local output_path = path.join(entry_directory, target.path)
			output_path = path.with_extension(output_path, "luau")

			const key = normalize(path.to_string(output_path))
			const existing = outputs[key]
			if existing then
				error(`"{existing.contract}" and "{contract.entry}" both write "{key}"`)
			end

			outputs[key] = {
				path = key,
				contract = contract.entry,
				contents = target.contents,
			}
		end
	end

	return outputs
end

local function read_manifest(config: Config): { [string]: ManifestEntry }
	const source = read_text(path.join(config.root, path.from_string(MANIFEST_NAME)))
	const entries: { [string]: ManifestEntry } = {}
	if source == nil then
		return entries
	end

	const parsed = toml.deserialize(source) :: any
	for _, entry in parsed.output or {} do
		entries[entry.path] = {
			path = entry.path,
			contract = entry.contract,
			hash = entry.hash,
		}
	end

	return entries
end

const function sorted_keys<T>(map: { [string]: T }): { string }
	const keys = {}
	for key in map do
		table.insert(keys, key)
	end

	table.sort(keys)
	return keys
end

const function serialize_manifest(outputs: { [string]: Output }): string
	const entries = {}
	for _, key in sorted_keys(outputs) do
		const output = outputs[key]
		table.insert(entries, {
			path = output.path,
			contract = output.contract,
			hash = hash(output.contents),
		})
	end

	return `# Generated by blink generate. Do not edit.\n{toml.serialize({ output = entries })}`
end

--- Compares every generated file on disk with a fresh in memory compilation.
local function check(config: Config): { Problem }
	const problems: { Problem } = {}
	const journal = path.join(config.root, path.from_string(JOURNAL_NAME))
	if fs.is_file(journal) then
		table.insert(problems, { kind = "interrupted", path = JOURNAL_NAME })
	end

	const outputs = plan(config)
	const manifest = read_manifest(config)

	for _, key in sorted_keys(outputs) do
		const output = outputs[key]
		const on_disk = read_text(absolute(config, key))
		const recorded = manifest[key]

		if on_disk == nil then
			table.insert(problems, { kind = "missing", path = key, contract = output.contract })
		elseif recorded and hash(on_disk) ~= recorded.hash then
			table.insert(problems, { kind = "edited", path = key, contract = output.contract })
		elseif on_disk ~= output.contents then
			table.insert(problems, { kind = "stale", path = key, contract = output.contract })
		elseif recorded == nil then
			table.insert(problems, { kind = "untracked", path = key, contract = output.contract })
		end
	end

	for _, key in sorted_keys(manifest) do
		if outputs[key] == nil and fs.is_file(absolute(config, key)) then
			table.insert(problems, { kind = "orphaned", path = key, contract = manifest[key].contract })
		end
	end

	return problems
end

--- Removes temporary files left behind by an interrupted generate.
local function recover(config: Config): boolean
	const journal_path = path.join(config.root, path.from_string(JOURNAL_NAME))
	const source = read_text(journal_path)
	if source == nil then
		return false
	end

	const parsed = toml.deserialize(source) :: any
	for _, entry in parsed.write or {} do
		remove(absolute(config, entry.temp))
	end

	remove(journal_path)
	return true
end

--- Compiles every contract and publishes the outputs.
--- Every file is staged next to its target and recorded in a journal before any target is replaced,
--- so an interrupted run is detected by check and repaired by the next generate.
local function generate(config: Config, interrupt_after: number?): GenerateReport
	const recovered = recover(config)
	const outputs = plan(config)
	const manifest = read_manifest(config)

	const writes = {}
	const unchanged = {}
	for _, key in sorted_keys(outputs) do
		const output = outputs[key]
		if read_text(absolute(config, key)) == output.contents then
			table.insert(unchanged, key)
		else
			table.insert(writes, { path = key, temp = `{key}{TEMP_SUFFIX}` })
		end
	end

	const removals = {}
	const kept = {}
	for _, key in sorted_keys(manifest) do
		if outputs[key] ~= nil then
			continue
		end

		const on_disk = read_text(absolute(config, key))
		if on_disk == nil then
			continue
		end

		if hash(on_disk) == manifest[key].hash then
			table.insert(removals, { path = key })
		else
			table.insert(kept, key)
		end
	end

	const journal_path = path.join(config.root, path.from_string(JOURNAL_NAME))
	write_text(journal_path, toml.serialize({ write = writes, remove = removals }))

	for _, write in writes do
		write_text(absolute(config, write.temp), outputs[write.path].contents)
	end

	const written = {}
	for index, write in writes do
		if interrupt_after and index > interrupt_after then
			error("generate was interrupted")
		end

		move(absolute(config, write.temp), absolute(config, write.path))
		table.insert(written, write.path)
	end

	const removed = {}
	for _, removal in removals do
		remove(absolute(config, removal.path))
		table.insert(removed, removal.path)
	end

	const manifest_path = path.join(config.root, path.from_string(MANIFEST_NAME))
	const manifest_temp = path.join(config.root, path.from_string(`{MANIFEST_NAME}{TEMP_SUFFIX}`))
	write_text(manifest_temp, serialize_manifest(outputs))
	move(manifest_temp, manifest_path)
	remove(journal_path)

	return {
		written = written,
		unchanged = unchanged,
		removed = removed,
		kept = kept,
		recovered = recovered,
	}
end

return table.freeze({
	MANIFEST_NAME = MANIFEST_NAME,
	JOURNAL_NAME = JOURNAL_NAME,

	load_config = load_config,
	plan = plan,
	check = check,
	generate = generate,
})

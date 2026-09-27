local cli_builder = require("@packages/cli_builder")
local colorful = require("@vendor/colorful")
local compilation = require("@compiler/config/compilation")
local compiler = require("@compiler")
local driver = require("@self/driver")
local fs = require("@util/fs")
local hir = require("@compiler/hir")
local path = require("@util/path")
local printext = require("@util/printext")
local process = require("@lute/process")
local system = require("@lute/system")
const version = require("@buildconfig/version")
local format_types = require("@util/format_types")

type Path = path.Path
type Profile = compilation.Profile

type Context = {
	read globalOptions: { [string]: any },
	read commandOptions: { [string]: any },
	read commandArguments: { [string]: any },
}

local NAME = colorful.color.green("Blink")
local HEADER = `{NAME} {version}`

const PROFILE_STYLE = colorful.combineStyles({ colorful.modifier.bold, colorful.modifier.underline })

local VALID_PROFILES: { [Profile]: true } = {
	dev = true,
	test = true,
	release = true,
}

local cli = cli_builder.cli
local option = cli_builder.option
local command = cli_builder.command
local argument = cli_builder.argument

local args = { ... }
table.remove(args, 1)

if system.os == "Windows_NT" then
	process.system("chcp 65001")
end

const function strip_ansi(str: string)
	return string.gsub(str, "\27%[[%d;]*%a", "")
end

const function format_seconds_taken(seconds: number): string
	if seconds < 1e-6 then
		return string.format(`%03i {colorful.color.greenBright("ns")}`, seconds * 1e9)
	elseif seconds < 1e-3 then
		return string.format(`%03i {colorful.color.green("us")}`, seconds * 1e6)
	elseif seconds < 1 then
		return string.format(`%.1f {colorful.color.yellow("ms")}`, seconds * 1e3)
	else
		return string.format(`%.1f {colorful.color.red("s")}`, seconds)
	end
end

const function format_options(options: { [string]: any })
	const lines = {}
	for name, value in options do
		table.insert(lines, `• {name} = {format_types.any(value)}`)
	end

	return `\n{table.concat(lines, "\n")}`
end

const function format_timings(timings: compiler.Timings)
	const lines = {}
	const function append_timing(tag: string, seconds: number)
		const formatted_seconds = format_seconds_taken(seconds)
		const horizontal_padding = string.rep(" ", 8 - #strip_ansi(formatted_seconds))
		table.insert(lines, `{formatted_seconds}{horizontal_padding}| {tag}`)
	end

	append_timing("ast", timings.ast)
	append_timing("hir", timings.hir)
	append_timing("lir", timings.lir)
	append_timing("codegen", timings.codegen)
	append_timing("total", timings.total)

	return `Compilation timings:\n{table.concat(lines, "\n")}`
end

local function write_with_logging(file_path: Path, contents: string)
	local write_result = fs.write_string_to_file(file_path, contents)
	if not write_result.ok then
		printext.error(`Encountered an IO error while writing "{file_path}":\n{write_result.error.message}`)
		return
	end

	printext.info(`Wrote output to: "{file_path}"`)
end

local function on_compile(context: Context)
	const options = context.commandOptions
	local profile: Profile = options.profile

	if VALID_PROFILES[profile] ~= true then
		error(`Unknown compiler profile "{profile}".`)
	end

	local input: string = context.commandArguments.input
	local input_path = path.from_string(input)
	input_path = path.with_extension(input_path, "blink")

	print(HEADER)

	if fs.is_file(input_path) == false then
		error(`Unable to find entry file "{input}"`)
	end

	printext.info(`Compiling "{input_path}" in {PROFILE_STYLE(profile)} profile...`)
	local compilation_result = compiler.compile_from_path(input_path, {
		profile = profile,
	})

	if not compilation_result.ok then
		printext.error(`Encountered an IO error while compiling: {compilation_result.error.message}`)
		return
	end

	local compiled = compilation_result.value
	if options.hir then
		print(hir.format(compiled.hir))
	end

	if options.timings then
		printext.info(format_timings(compiled.timings))
	end

	local targets = compiled.targets
	local input_directory = path.strip_file_name(input_path)
	for _, target in targets :: { [string]: index<typeof(targets), keyof<typeof(targets)>> } do
		assert(target)
		local output_path = path.join(input_directory, target.path)
		output_path = path.with_extension(output_path, "luau")
		write_with_logging(output_path, target.contents)
	end
end

const PROBLEM_TEXT = {
	missing = "is missing",
	stale = "is out of date",
	edited = "was edited by hand",
	orphaned = "is no longer produced by any contract",
	untracked = "is not recorded in the manifest",
	interrupted = "records an interrupted generate",
}

const function on_generate(context: Context)
	print(HEADER)
	const config = driver.load_config(path.from_string(context.commandOptions.config))
	const report = driver.generate(config)

	if report.recovered then
		printext.info("Recovered from an interrupted generate.")
	end

	for _, written in report.written do
		printext.info(`Wrote "{written}"`)
	end

	for _, removed in report.removed do
		printext.info(`Removed orphaned "{removed}"`)
	end

	for _, kept in report.kept do
		printext.error(`Kept orphaned "{kept}" because it was edited by hand, delete it yourself if it is unused`)
	end

	printext.info(`{#report.written} written, {#report.unchanged} unchanged, {#report.removed} removed.`)
end

const function on_check(context: Context)
	print(HEADER)
	const config = driver.load_config(path.from_string(context.commandOptions.config))
	const problems = driver.check(config)
	if #problems == 0 then
		printext.info("Every generated file is up to date.")
		return
	end

	for _, problem in problems do
		printext.error(`"{problem.path}" {PROBLEM_TEXT[problem.kind]}`)
	end

	printext.error(`{#problems} problem(s) found, run "blink generate" to fix them.`)
	process.exit(1)
end

const function before_run(context: Context)
	if context.globalOptions.verbose then
		printext.verbose(format_options(context.commandOptions))
	end
end

--stylua: ignore
cli.new()
	:setName(NAME)
	:setVersion(version)
	:setDescription("An IDL for defining structured data that compiles to fast Luau buffer serdes.")
	:setGitRepository("https://github.com/1Axen/blink")
	:setEpilog("Example: blink compile <file>")
	:setBeforeRunHook(before_run)
	:addOption(
		option.new()
			:setName("verbose")
			:setDescription("Enable verbose logging")
			:setType("boolean")
			:setDefaultValue(false)
			:build()
	)
	:addCommand(
		command.new()
			:setName("compile")
			:setDescription("Compiles entry point and resolved dependencies into Luau code.")
			:setCallback(on_compile)
			:addArgument(
				argument.new()
					:setName("input")
					:setDescription("Path to the compilation entry point file.")
					:setRequired(true)
					:setType("string")
					:build()
			)
			:addOption(
				option.new()
					:setName("hir")
					:setDescription("Output a formatted HIR to the stdout")
					:setType("boolean")
					:setDefaultValue(false)
					:build()
			)
			:addOption(
				option.new()
					:setName("profile")
					:addAlias("p")
					:setDescription("Profile to use for the compilation")	
					:setType("string")
					:setDefaultValue("dev")
					:build()
			)
			:addOption(
				option.new()
					:setName("timings")
					:addAlias("t")
					:setDescription("Output how long each compilation step took")
					:setType("boolean")
					:setDefaultValue(false)
					:build()	
			)
			:build()
	)
	:addCommand(
		command.new()
			:setName("generate")
			:setDescription("Compiles every contract in a project config and publishes the outputs atomically.")
			:setCallback(on_generate)
			:addOption(
				option.new()
					:setName("config")
					:addAlias("c")
					:setDescription("Path to the project config.")
					:setType("string")
					:setDefaultValue("blink.toml")
					:build()
			)
			:build()
	)
	:addCommand(
		command.new()
			:setName("check")
			:setDescription("Fails when a generated file is missing, stale, edited by hand or orphaned.")
			:setCallback(on_check)
			:addOption(
				option.new()
					:setName("config")
					:addAlias("c")
					:setDescription("Path to the project config.")
					:setType("string")
					:setDefaultValue("blink.toml")
					:build()
			)
			:build()
	)
	:configure({
		ansiColorEnabled = true
	})
	:run(args)
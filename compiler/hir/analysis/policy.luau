--!strict

local ast = require("@ast")
local codes = require("@config/codes")
local compilation = require("@config/compilation")
local diagnostics = require("@util/diagnostics")
local lookup = require("@hir/lookup")
local style = require("@util/style")
local ty = require("@ty")
local types = require("@hir/types")

type Ty = ty.Ty
type Hir = types.Hir
type Parameter = types.Parameter

const MAX_DEPTH = 8

type Context = {
	read hir: Hir,
	read allow_buffer: boolean,
	read buffer_reason: string,
	read active: { [Ty]: true? },
	uses_buffer: boolean,
}

const function violation(node: ast.Node, path: string, message: string): never
	return diagnostics
		.error(codes.policy.Violation)
		:with_message(`Contract policy violation at {path}`)
		:with_label(diagnostics.label(node.span):with_style(style.color.red):with_message(message))
		:error()
end

const function stat_violation(stat: ast.Node, code: number, message: string, label: string): never
	return diagnostics
		.error(code)
		:with_message(message)
		:with_label(diagnostics.label(stat.span):with_style(style.color.red):with_message(label))
		:error()
end

local explore: (ctx: Context, tty: Ty, node: ast.Node, path: string, depth: number) -> ()

function explore(ctx: Context, tty: Ty, node: ast.Node, path: string, depth: number)
	const own_node: ast.Node = tty.node or node

	if depth > MAX_DEPTH then
		violation(own_node, path, `Nesting is deeper than {MAX_DEPTH} levels, flatten this type`)
	end

	const active = ctx.active
	if active[tty] then
		violation(own_node, path, "Recursive types are not allowed, their depth is unbounded")
	end

	active[tty] = true

	const kind = tty.kind
	if kind == "reference" then
		explore(ctx, lookup.ty_from_id(ctx.hir, tty.to), own_node, path, depth)
	elseif kind == "type_instantiation" then
		explore(ctx, tty.body, own_node, path, depth)
	elseif kind == "unknown" then
		violation(own_node, path, `"unknown" is not allowed, declare the shape of the data instead`)
	elseif kind == "string" then
		if tty.length == nil then
			violation(own_node, path, "Strings need a byte bound, for example string(..64)")
		end
	elseif kind == "buffer" then
		if tty.length == nil then
			violation(own_node, path, "Buffers need a byte bound, for example buffer(..64)")
		end

		ctx.uses_buffer = true
		if not ctx.allow_buffer then
			violation(own_node, path, `Buffers are opaque, {ctx.buffer_reason}`)
		end
	elseif kind == "array" then
		if tty.size == nil then
			violation(own_node, path, "Arrays need a length cap, for example u8[..32]")
		end

		explore(ctx, tty.of, own_node, `{path}[]`, depth + 1)
	elseif kind == "map" then
		if tty.size == nil then
			violation(own_node, path, "Maps need an entry cap, for example map {[K]: V}(..32)")
		end

		explore(ctx, tty.index, own_node, `{path}[key]`, depth + 1)
		explore(ctx, tty.value, own_node, `{path}[value]`, depth + 1)
	elseif kind == "struct" then
		for _, field in tty.fields do
			explore(ctx, field.value, own_node, `{path}.{field.name}`, depth + 1)
		end
	elseif kind == "union" then
		for _, component in tty.components do
			explore(ctx, component, own_node, path, depth)
		end
	elseif kind == "discriminated_union" then
		for _, variant in tty.variants do
			const key = variant.key
			const label = if key.kind == "string_literal" then key.value else tostring(key.value)
			explore(ctx, variant.value, own_node, `{path}<{label}>`, depth + 1)
		end
	end

	active[tty] = nil
end

const function check_parameters(
	hir: Hir,
	parameters: { Parameter }?,
	root: string,
	node: ast.Node,
	allow_buffer: boolean,
	buffer_reason: string
): boolean
	if parameters == nil then
		return false
	end

	const ctx: Context = {
		hir = hir,
		allow_buffer = allow_buffer,
		buffer_reason = buffer_reason,
		active = {},
		uses_buffer = false,
	}

	const single = #parameters == 1
	for index, parameter in parameters do
		const segment = parameter.name or tostring(index)
		const path = if single and parameter.name == nil then root else `{root}.{segment}`
		explore(ctx, lookup.ty_from_id(hir, parameter.ty_id), node, path, 1)
	end

	return ctx.uses_buffer
end

const function check_opaque_used(stat: ast.Node, opaque: boolean, uses_buffer: boolean)
	if opaque and not uses_buffer then
		stat_violation(
			stat,
			codes.policy.InvalidOpaque,
			`Unused "@opaque" attribute`,
			"Remove @opaque, nothing this declaration sends is a buffer"
		)
	end
end

const function check_event(hir: Hir, event: types.Event)
	const stat = event.node
	const name = event.name
	const opaque = event.attributes.opaque == true
	const from_server = event.from == "Server"

	if opaque and not from_server then
		stat_violation(
			stat.name,
			codes.policy.InvalidOpaque,
			`Event "{name}" cannot be opaque`,
			"The server must know the shape of all data a client sends, remove @opaque"
		)
	end

	const uses_buffer = check_parameters(
		hir,
		event.data,
		`{name}.data`,
		stat,
		from_server and opaque,
		if from_server then "add @opaque to this event to send one" else "clients cannot send opaque data to the server"
	)

	check_opaque_used(stat.name, opaque, uses_buffer)
end

const function check_function(hir: Hir, funct: types.Function)
	const stat = funct.node
	const name = funct.name
	const opaque = funct.attributes.opaque == true

	check_parameters(hir, funct.data, `{name}.data`, stat, false, "clients cannot send opaque data to the server")
	const uses_buffer =
		check_parameters(hir, funct.ret, `{name}.return`, stat, opaque, "add @opaque to this function to return one")

	check_opaque_used(stat.name, opaque, uses_buffer)
end

const function check_type(hir: Hir, decl: types.Type)
	if decl.attributes.opaque then
		stat_violation(
			decl.node.name,
			codes.policy.InvalidOpaque,
			`Types cannot be opaque`,
			"@opaque only applies to events and functions"
		)
	end

	if decl.attributes.export ~= true then
		return
	end

	const ctx: Context = {
		hir = hir,
		allow_buffer = true,
		buffer_reason = "",
		active = {},
		uses_buffer = false,
	}

	explore(ctx, lookup.ty_from_id(hir, decl.ty_id), decl.node, decl.name, 1)
end

const function check_imported_options(hir: Hir, files: compilation.Files, entry_id: number)
	for file_id, file_ast in files.ast_map do
		if file_id == entry_id then
			continue
		end

		const file_options = hir.options[file_id]
		if file_options == nil or file_options.strict ~= false then
			continue
		end

		for _, stat in file_ast.body.statements do
			if stat.kind == "option" and stat.name.value == "strict" then
				stat_violation(
					stat,
					codes.policy.Violation,
					"Imported files cannot loosen the policy",
					'The importing contract is strict, remove "option strict = false" here'
				)
			end
		end
	end
end

const function is_strict(hir: Hir, files: compilation.Files, requested: boolean?): boolean
	if requested == false then
		return false
	end

	const entry_id = files.sorted_ids[#files.sorted_ids]
	const entry_options = hir.options[entry_id]
	return entry_options == nil or entry_options.strict ~= false
end

const function enforce(hir: Hir, files: compilation.Files, requested: boolean?)
	if not is_strict(hir, files, requested) then
		return
	end

	check_imported_options(hir, files, files.sorted_ids[#files.sorted_ids])

	for _, decl in hir.types do
		check_type(hir, decl)
	end

	for _, event in hir.events do
		check_event(hir, event)
	end

	for _, funct in hir.functs do
		check_function(hir, funct)
	end
end

return table.freeze({
	MAX_DEPTH = MAX_DEPTH,
	enforce = enforce,
})

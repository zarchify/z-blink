local ast = require("@ast")
local canonicalize_attributes = require("./canonicalize_attributes")
local compilation = require("@config/compilation")
local panic = require("@util/panic")
local report = require("@compiler/report")
local search_path = require("./search_path")
local store_decl = require("./store_decl")
local typeforge = require("@util/typeforge")
local types = require("@hir/types")

type Decl = types.Decl
type Scope = types.Scope
type Decls = types.Decls
type DeclId = types.DeclId
type ScopeId = types.ScopeId

type Files = compilation.Files
type FileDeclsMap = { [number]: Decls }

type Extra = index<ast.StatImport, "extra">

local function combine<K, V>(from: { read [K]: V }, into: { [K]: V })
	for key, value in from do
		into[key] = value
	end
end

const function star_import(
	into_scope: Scope,
	into_decls: Decls,
	from_scope: Scope,
	from_decls: Decls,
	extra: typeforge.Pick<Extra, "all">
)
	const as = extra.into_scope
	if as == nil then
		-- simple case, pull in top level decls
		for _, decl_map in { from_decls.types, from_decls.events, from_decls.functs, from_decls.scopes } do
			for _, decl in decl_map do
				-- only pull in top level decls
				if decl.scope ~= from_scope then
					continue
				end

				local name = decl.name
				local _, previous = search_path(into_scope, { name })
				if previous then
					report.shadow(name, extra.star, previous)
				end

				store_decl(into_scope, into_decls, decl, extra.star)
			end
		end

		return
	end

	local name = as.value
	local _, previous = search_path(into_scope, { name })
	if previous then
		report.shadow(name, as, previous)
	end

	local new_scope: Scope = {
		id = from_scope.id,
		kind = "scope",
		name = name,
		node = from_scope.node,
		scope = into_scope,
		attributes = {},

		values = from_scope.values,
		symbols = from_scope.symbols,
	}

	for decl_id, child_scope in from_decls.scopes do
		if child_scope == from_scope then
			continue
		end

		into_decls.scopes[decl_id] = child_scope
	end

	combine(from_decls.types, into_decls.types)
	combine(from_decls.events, into_decls.events)
	combine(from_decls.functs, into_decls.functs)
	store_decl(into_scope, into_decls, new_scope, as)
end

const function destructured_import(
	into_scope: Scope,
	into_decls: Decls,
	from_scope: Scope,
	from_decls: Decls,
	values: index<typeforge.Pick<Extra, "destructured">, "values">
)
	for _, value in values do
		local path = value.path
		local segments = table.create<<string>>(#path.segments)
		for index, segment in path.segments do
			segments[index] = segment.value
		end

		local decl = search_path(from_scope, segments)
		if decl == nil then
			report.unknown_reference(path)
		end

		assert(decl, "unreachable")

		local name = decl.name
		local rename_to = value.rename_to
		local identifier = rename_to or path.segments[#path.segments]

		if rename_to then
			local mutable_decl: typeforge.Writeable<Decl> = table.clone(decl) :: any
			mutable_decl.name = rename_to.value
			name = mutable_decl.name
			decl = (mutable_decl :: any) :: Decl
		end

		local _, previous = search_path(into_scope, { name })
		if previous ~= nil then
			report.shadow(name, identifier, previous)
		end

		store_decl(into_scope, into_decls, decl, identifier)
	end
end

local function perform_import(
	into_scope: Scope,
	into_decls: Decls,
	from_scope: Scope,
	from_decls: Decls,
	import_stat: ast.StatImport
)
	local extra = import_stat.extra
	if extra.kind == "all" then
		star_import(into_scope, into_decls, from_scope, from_decls, extra)
	elseif extra.kind == "destructured" then
		destructured_import(into_scope, into_decls, from_scope, from_decls, extra.values)
	end
end

local function populate_imports(files: Files, decls_map: FileDeclsMap, profile: compilation.Profile)
	local ast_map = files.ast_map
	local imports_map = files.imports_map

	for _, file_id in files.sorted_ids do
		local file_ast = ast_map[file_id]
		local file_decls = decls_map[file_id]

		local queue: { { scope: Scope, statements: { ast.Statement } } } = {}
		table.insert(queue, {
			scope = file_decls.scopes[file_ast.body.id :: ScopeId],
			statements = file_ast.body.statements,
		})

		while true do
			local entry = table.remove(queue)
			if entry == nil then
				break
			end

			local scope = entry.scope
			for _, stat in entry.statements do
				const attributes = canonicalize_attributes(stat.attributes)
				if attributes.profile and attributes.profile ~= profile then
					continue
				end

				if stat.kind == "scope" then
					const next_scope = file_decls.scopes[stat.id :: ScopeId]
					if next_scope == nil then
						panic(`scope statement ({stat.name.value}:{stat.id}) wasn't mapped to a scope decl`)
					end

					table.insert(queue, {
						scope = next_scope,
						statements = stat.body.statements,
					})
				elseif stat.kind == "import" then
					local import_file_id = imports_map[stat]

					local import_ast = ast_map[import_file_id]
					local import_decls = decls_map[import_file_id]
					local import_scope = import_decls.scopes[import_ast.body.id :: ScopeId]

					perform_import(scope, file_decls, import_scope, import_decls, stat)
				end
			end
		end
	end
end

return populate_imports

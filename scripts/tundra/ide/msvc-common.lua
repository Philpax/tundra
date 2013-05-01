module(..., package.seeall)

local util = require "tundra.util"
local nodegen = require "tundra.nodegen"
local native = require "tundra.native"
local path = require "tundra.path"

local project_types = util.make_lookup_table {
  "Program", "SharedLibrary", "StaticLibrary", "CSharpExe", "CSharpLib",
}

local toplevel_stuff = util.make_lookup_table {
  ".exe", ".lib", ".dll",
}

local binary_extension = util.make_lookup_table {
  ".exe", ".lib", ".dll", ".pdb", ".res", ".obj"
}

local header_exts = util.make_lookup_table {
  ".h", ".hpp", ".hh", ".inl",
}

-- Scan for sources, following dependencies until those dependencies seem to be
-- a different top-level unit
local function get_sources(dag, sources, generated, level)
  if level > 0 then
    for _, output in util.nil_ipairs(dag.outputs) do
      local ext = path.get_extension(output)
      if toplevel_stuff[ext] then
        -- Terminate here, something else will want the sources files from this sub-DAG
        return
      end
      generated[output] = true
      if not binary_extension[ext] then
        sources[output] = true -- pick up generated headers
      end
    end
  end

  for _, input in util.nil_ipairs(dag.inputs) do
    local ext = path.get_extension(input)
    if not binary_extension[ext] then
      sources[input] = true
    end
  end

  for _, dep in util.nil_ipairs(dag.deps) do
    get_sources(dep, sources, generated, level + 1)
  end
end

function get_guid_string(data)
  local sha1 = native.digest_guid(data)
  local guid = sha1:sub(1, 8) .. '-' .. sha1:sub(9,12) .. '-' .. sha1:sub(13,16) .. '-' .. sha1:sub(17,20) .. '-' .. sha1:sub(21, 32)
  assert(#guid == 36) 
  return guid:upper()
end

local function get_headers(unit, source_lut)
  local src_dir = ''
  if unit.Decl.SourceDir then
    src_dir = unit.Decl.SourceDir .. '/'
  end
  for _, src in util.nil_ipairs(nodegen.flatten_list('*-*-*-*', unit.Decl.Sources)) do
    if type(src) == "string" then
      local ext = path.get_extension(src)
      if header_exts[ext] then
        local full_path = path.normalize(src_dir .. src)
        source_lut[full_path] = true
      end
    end
  end

  -- Repeat for dependent ObjGroups
  for _, dep in util.nil_ipairs(nodegen.flatten_list('*-*-*-*', unit.Decl.Depends)) do
    if dep.Keyword == 'ObjGroup' then
      get_headers(dep, source_lut)
    end
  end
end

function extract_data(unit, env, proj_extension, base_dir)
  local decl = unit.Decl

  if decl.Name and project_types[unit.Keyword] then

    local dag_nodes = assert(decl.__DagNodes, "no dag nodes for " .. decl.Name)
    dag_nodes = util.table_values(dag_nodes)
    local source_lut = {}
    local generated_lut = {}
    for _, dag_node in ipairs(dag_nodes) do
      get_sources(dag_node, source_lut, generated_lut, 0)
    end

    -- Explicitly add all header files too as they are not picked up from the DAG
    -- Also pick up headers from ObjGroups we're depending on (effectively embedded)
    get_headers(unit, source_lut)

    local sources = {}
    local cwd = native.getcwd()
    for src, _ in pairs(source_lut) do
      local is_generated = generated_lut[src]
      sources[#sources+1] = {
        Path        = src:gsub('/', '\\'),
        Generated   = is_generated,
      }
    end

    local relative_fn = decl.Name .. proj_extension

    return {
      Type             = unit.Keyword,
      Decl             = decl,
      Sources          = sources,
      RelativeFilename = relative_fn,
      Filename         = base_dir .. relative_fn,
      Guid             = get_guid_string(decl.Name),
    }
  else
    return nil
  end
end


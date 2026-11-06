-- lua/todo2/global/ref.lua
-- 跨项目任务引用（qref）与行内关系（@rel）的语法唯一出口。
--
--   qref            <project>/<id>                 e.g. todo2--fa7e41ef/6f2a1c
--   @rel token      [<kind>:]<project>/<id>        e.g. blocks:api--a1b2c3d4/4f2a1c
--
-- 项目名就是 `~/.todo-files` 下的目录名（<slug>--<hash8>），随 identity 变化，
-- 因此引用天然指向“这个项目的当前身份”，不需要额外 uid。
-- 关系只有两种：`blocks`（我阻塞目标）与 `relates`（弱关联，默认）。
-- 反向边（被谁阻塞/关联）是派生视图，不写进对方文件。

local M = {}

M.DEFAULT_KIND = "relates"
M.KINDS = { relates = true, blocks = true }

--- 项目名 / 任务 id 的字符集（与 vault 目录名、id 生成规则一致）
local function is_project(v)
	return v:match("^[%w%._%-]+$") ~= nil
end

local function is_id(v)
	return v:match("^[0-9a-z]+$") ~= nil
end

--- 解析一个 @rel 值。
---@param token string
---@return { kind: string, project: string, id: string }|nil
function M.parse(token)
	if type(token) ~= "string" or token == "" then
		return nil
	end

	local kind = M.DEFAULT_KIND
	local rest = token
	local prefix, tail = token:match("^([%a][%w%-]*):(.+)$")
	if prefix then
		if not M.KINDS[prefix] then
			return nil
		end
		kind, rest = prefix, tail
	end

	local project, id = rest:match("^([^/]+)/([0-9a-z]+)$")
	if not project or not is_project(project) or not is_id(id) then
		return nil
	end

	return { kind = kind, project = project, id = id }
end

--- 规范形式：默认类型省略前缀，写回文件更短。
---@param kind string|nil
---@param project string
---@param id string
---@return string
function M.format(kind, project, id)
	local qref = project .. "/" .. id
	if kind and kind ~= M.DEFAULT_KIND then
		return kind .. ":" .. qref
	end
	return qref
end

--- 任务的全限定引用
---@param project string
---@param id string
---@return string
function M.qref(project, id)
	return project .. "/" .. id
end

--- 归一化一组关系 token：丢弃非法项、统一写法、去重、保持顺序。
---@param list string[]|nil
---@return string[]
function M.normalize(list)
	local out, seen = {}, {}
	for _, token in ipairs(list or {}) do
		local r = M.parse(token)
		if r then
			local canonical = M.format(r.kind, r.project, r.id)
			if not seen[canonical] then
				seen[canonical] = true
				out[#out + 1] = canonical
			end
		end
	end
	return out
end

return M

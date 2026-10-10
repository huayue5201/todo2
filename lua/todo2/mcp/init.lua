-- lua/todo2/mcp/init.lua
-- 把当前 nvim 实例的 RPC 地址发布给 MCP 桥（mcp/todo2-mcp.lua）。
--
-- MCP 桥是一个 `nvim --headless -l mcp/todo2-mcp.lua` 的 stdio 子进程，
-- 它连回本实例并调用 todo2.ai，从而保证单一真源（活着的 nvim）。

local M = {}

--- 确保本实例有 RPC server，返回其地址。
---@return string|nil
function M.address()
	local addr = vim.v.servername
	if addr == nil or addr == "" then
		local ok, started = pcall(vim.fn.serverstart)
		if ok and type(started) == "string" and started ~= "" then
			addr = started
		end
	end
	if addr == nil or addr == "" then
		return nil
	end
	return addr
end

--- 把地址写入约定的文件，供 MCP 桥读取。
--- 同时维护 project → addr 注册表，供多实例下按项目定向（TODO2_PROJECT）。
---@return string|nil
function M.publish()
	local addr = M.address()
	if not addr then
		return nil
	end
	local dir = vim.fn.stdpath("cache") .. "/todo2"
	pcall(vim.fn.mkdir, dir, "p")
	pcall(vim.fn.writefile, { addr }, dir .. "/nvim.addr")

	-- 项目注册表：多开 nvim 时，每个项目名指向最后发布它的实例
	local registry_path = dir .. "/projects.json"
	local registry = {}
	if vim.fn.filereadable(registry_path) == 1 then
		local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(registry_path), "\n"))
		if ok and type(decoded) == "table" then
			registry = decoded
		end
	end
	local project = require("todo2.utils.project").get_project_name()
	registry[project] = addr
	pcall(vim.fn.writefile, { vim.json.encode(registry) }, registry_path)

	return addr
end

---@return string|nil
function M.bridge_path()
	local matches = vim.api.nvim_get_runtime_file("mcp/todo2-mcp.lua", false)
	return matches[1]
end

--- :TodoMcp —— 打印接入 pi 所需的配置信息。
function M.command()
	local addr = M.publish()
	local bridge = M.bridge_path()
	local lines = {
		"todo2 MCP",
		"nvim socket: " .. (addr or "(none — serverstart failed)"),
		"bridge:      " .. (bridge or "(mcp/todo2-mcp.lua not found)"),
		"",
		"Set up with pi:",
		string.format(
			"  pi mcp add todo2 --env TODO2_NVIM=%s -- nvim --headless -u NONE -l %s",
			addr or "<socket>",
			bridge or "<bridge>"
		),
		"",
		"Pin a project instead (multi-instance): --env TODO2_PROJECT="
			.. require("todo2.utils.project").get_project_name(),
		"Read-only mode: add --env TODO2_MCP_READONLY=1",
		"Add \"exposure\": \"direct\" to the todo2 entry in ~/.pi/agent/mcp.json so the model sees the tools directly.",
	}
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M

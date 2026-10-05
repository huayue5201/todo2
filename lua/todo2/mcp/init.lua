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
---@return string|nil
function M.publish()
	local addr = M.address()
	if not addr then
		return nil
	end
	local dir = vim.fn.stdpath("cache") .. "/todo2"
	pcall(vim.fn.mkdir, dir, "p")
	pcall(vim.fn.writefile, { addr }, dir .. "/nvim.addr")
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
		"nvim socket: " .. (addr or "(无 — serverstart 失败)"),
		"bridge:      " .. (bridge or "(未找到 mcp/todo2-mcp.lua)"),
		"",
		"用 pi 接入：",
		string.format(
			"  pi mcp add todo2 --env TODO2_NVIM=%s -- nvim --headless -u NONE -l %s",
			addr or "<socket>",
			bridge or "<bridge>"
		),
		"",
		"建议在 ~/.pi/agent/mcp.json 的 todo2 条目里加 \"exposure\": \"direct\"，让模型直接看到工具。",
	}
	vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M

-- MCP 桥契约测试的「服务端」fixture：启动一个活着的 nvim 并发布地址。
-- 由 test/mcp_layer.lua 以 `nvim --headless -u NONE -l test/mcp_server.lua` 拉起。
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

local projdir = "/tmp/todo2-mcp-test-proj"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
require("todo2").setup({})
vim.fn.delete(vim.fn.expand("~/.todo-files/todo2-mcp-test-proj"), "rf")

local actions = require("todo2.ai.actions")
actions.create_todo_file("test")
local r = actions.create_task({ content = "bridge alpha task" })
local addr = require("todo2.mcp").publish()
vim.fn.writefile({ addr, r.id }, "/tmp/todo2-mcp-test.ready")
vim.wait(180000, function()
	return false
end)

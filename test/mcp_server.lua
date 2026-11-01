-- MCP 桥契约测试的「服务端」fixture：启动一个活着的 nvim 并发布地址。
-- 由 test/mcp_layer.lua 以 `nvim --headless -u NONE -l test/mcp_server.lua` 拉起。
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ":h") .. "/nvim-store3")
vim.opt.runtimepath:prepend(root)

-- 可用 env 参数化（mcp_registry 测试需要两个同名不同路径的项目并行）：
--   TODO2_FIXTURE_DIR   项目目录（默认 /tmp/todo2-mcp-test-proj）
--   TODO2_FIXTURE_READY 就绪文件（默认 /tmp/todo2-mcp-test.ready）
--   TODO2_FIXTURE_TASK  预置任务正文（默认 "bridge alpha task"）
local projdir = vim.env.TODO2_FIXTURE_DIR or "/tmp/todo2-mcp-test-proj"
local ready = vim.env.TODO2_FIXTURE_READY or "/tmp/todo2-mcp-test.ready"
local task_text = vim.env.TODO2_FIXTURE_TASK or "bridge alpha task"
vim.fn.delete(projdir, "rf")
vim.fn.mkdir(projdir, "p")
vim.fn.chdir(projdir)
require("todo2").setup({})
vim.fn.delete(vim.fn.expand("~/.todo-files/" .. vim.fn.fnamemodify(projdir, ":t")), "rf")

local actions = require("todo2.ai.actions")
actions.create_todo_file("test")
local r = actions.create_task({ content = task_text })
local addr = require("todo2.mcp").publish()
vim.fn.writefile({ addr, r.id }, ready)
vim.wait(180000, function()
	return false
end)

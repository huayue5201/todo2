-- lua/todo2/handlers/init.lua
-- 处理器模块入口：聚合 task / ui / link 三个子模块

local M = {}

local task = require("todo2.handlers.task")
local ui = require("todo2.handlers.ui")
local link = require("todo2.handlers.link")

for k, v in pairs(task) do
	M[k] = v
end
for k, v in pairs(ui) do
	M[k] = v
end
for k, v in pairs(link) do
	M[k] = v
end

return M

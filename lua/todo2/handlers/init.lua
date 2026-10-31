-- lua/todo2/handlers/init.lua
-- 处理器模块入口：聚合各 handler 子模块（写入逻辑的对外壳）

local M = {}

local task = require("todo2.handlers.task")
local ui = require("todo2.handlers.ui")
local link = require("todo2.handlers.link")
local context = require("todo2.handlers.context")
local tags = require("todo2.handlers.tags")
local due = require("todo2.handlers.due")
local start = require("todo2.handlers.start")
local pin = require("todo2.handlers.pin")

for k, v in pairs(task) do
	M[k] = v
end
for k, v in pairs(ui) do
	M[k] = v
end
for k, v in pairs(link) do
	M[k] = v
end
for k, v in pairs(context) do
	M[k] = v
end
for k, v in pairs(tags) do
	M[k] = v
end
for k, v in pairs(due) do
	M[k] = v
end
for k, v in pairs(pin) do
	M[k] = v
end
for k, v in pairs(start) do
	M[k] = v
end

return M

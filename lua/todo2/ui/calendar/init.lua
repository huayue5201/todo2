-- lua/todo2/ui/calendar/init.lua
--- 月历视图公开入口（:TodoCalendar / use 'todo2.ui.calendar'）
---
--- 数据只读：来源是当前项目 TODO 文件里带 `@YYYY-MM-DD` 的活跃任务。
--- 月视图：h/l 日、j/k 周、H/L 月、t 今天、<CR> 当天任务、q 关闭。
--- 当日列表：j/k 选择、<CR> 跳转到 TODO 文件对应行、b/Esc 返回。

local view = require("todo2.ui.calendar.view")

local M = {}

M.open = view.open
M.close = view.close
M.toggle = view.toggle
M.refresh = view.refresh

return M

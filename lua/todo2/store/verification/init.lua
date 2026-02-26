-- lua/todo2/store/verification.lua
-- 验证模块主入口（整合各子模块）

local M = {}

-- 导入子模块
local cache = require("todo2.store.verification.cache")
local core = require("todo2.store.verification.core")
local manager = require("todo2.store.verification.manager")

---------------------------------------------------------------------
-- 导出核心功能
---------------------------------------------------------------------

-- 配置
M.CONFIG = core.CONFIG
M.set_config = core.set_config

-- 状态校准
M.calibrate_link_active_status = core.calibrate_link_active_status

-- 上下文验证
M.verify_context_fingerprint = core.verify_context_fingerprint
M.update_expired_context = core.update_expired_context

-- 删除恢复
M.mark_link_deleted = core.mark_link_deleted
M.restore_link_deleted = core.restore_link_deleted

-- 查询
M.get_unverified_links = manager.get_unverified_links

-- 批量验证
M.verify_all = manager.verify_all
M.verify_file_links = manager.verify_file_links

-- 自动验证
M.setup_auto_verification = manager.setup_auto_verification

-- 元数据刷新
M.refresh_metadata_stats = manager.refresh_metadata_stats

-- 清理
M.cleanup_verify_records = manager.cleanup_verify_records

-- 缓存管理（按需导出）
M.clear_file_cache = cache.clear_file_cache
M.is_file_changed = cache.is_file_changed

return M

local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm

-- Verbose diagnostic firehose, off by default. Contributor-facing and intentionally
-- undocumented in user-facing docs -- WezTerm exposes no public debug/trace log level, so this
-- is the plugin's stand-in for one. grep the gui log for "resurrect.debug:". Two ways to enable:
--   * RESURRECT_DEBUG=1 in the environment (read once, at load) -- the "blast it from a
--     terminal" path and the run-wezterm skill's path.
--   * resurrect.logging.set_debug(true) at runtime -- live-toggle from the F12 debug overlay
--     mid-session. Plugin modules are cached in-process, so the env var is frozen at
--     gui-process start; only a setter can flip the firehose without a full wezterm restart.
--
-- `enabled` is a private local mutated solely through set_debug(), never an exposed mutable
-- field, so nothing else can reach in and toggle it by assignment.
local enabled = os.getenv("RESURRECT_DEBUG") == "1"

local pub = {}

---Enable or disable the debug firehose at runtime (e.g. from the F12 debug overlay).
---@param on boolean
function pub.set_debug(on)
	enabled = on == true
end

---Whether the firehose is on. Guard eager arguments with this -- Lua evaluates a call's
---arguments before the call, so any mux-heavy or string-building argument must be wrapped
---`if log.is_enabled() then log.debug(...) end` rather than passed straight to debug()
---(consumers alias this module `local log = require("resurrect.logging")`).
---@return boolean
function pub.is_enabled()
	return enabled
end

---Emit one diagnostic line, prefixed "resurrect.debug:", only when enabled.
---@param fmt string
---@param ... any
function pub.debug(fmt, ...)
	if enabled then
		wezterm.log_info("resurrect.debug: " .. fmt:format(...))
	end
end

return pub

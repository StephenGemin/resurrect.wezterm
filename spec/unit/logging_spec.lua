-- Guards the resurrect.logging public contract: set_debug/is_enabled gate debug(), and
-- debug() emits a "resurrect.debug: " prefixed, formatted line only while enabled.
--
-- The RESURRECT_DEBUG env-var-at-load path is intentionally not covered here -- Lua has
-- no portable os.setenv, so exercising it would require forking a subprocess per case.
-- That path is already verified end-to-end by the run-wezterm skill's live restart test.

local helper = require("spec_helper")

describe("resurrect.logging", function()
	local function load_with_capture()
		local rec_logs = {}
		local wz = helper.new_wezterm({
			patch = function(wz)
				function wz.log_info(msg)
					table.insert(rec_logs, msg)
				end
			end,
		})
		return helper.load("resurrect.logging", wz), rec_logs
	end

	it("is silent and reports disabled until set_debug(true) is called", function()
		local log, logs = load_with_capture()
		log.set_debug(false)

		log.debug("pane=%d", 1)

		assert.is_false(log.is_enabled())
		assert.are.equal(0, #logs)
	end)

	it("emits a prefixed, formatted line once enabled", function()
		local log, logs = load_with_capture()
		log.set_debug(true)

		log.debug("pane=%d bytes=%d", 7, 42)

		assert.is_true(log.is_enabled())
		assert.are.equal(1, #logs)
		assert.are.equal("resurrect.debug: pane=7 bytes=42", logs[1])
	end)

	it("goes silent again after set_debug(false)", function()
		local log, logs = load_with_capture()
		log.set_debug(true)
		log.set_debug(false)

		log.debug("pane=%d", 1)

		assert.is_false(log.is_enabled())
		assert.are.equal(0, #logs)
	end)

	it("only a literal `true` enables it -- other truthy values are treated as off", function()
		local log = load_with_capture()

		log.set_debug("1")

		assert.is_false(log.is_enabled())
	end)
end)

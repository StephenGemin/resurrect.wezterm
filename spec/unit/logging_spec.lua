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

		assert.is_false(log.is_debug_enabled())
		assert.are.equal(0, #logs)
	end)

	it("emits a prefixed, formatted line once enabled", function()
		local log, logs = load_with_capture()
		log.set_debug(true)

		log.debug("pane=%d bytes=%d", 7, 42)

		assert.is_true(log.is_debug_enabled())
		assert.are.equal(1, #logs)
		assert.are.equal("resurrect.debug: pane=7 bytes=42", logs[1])
	end)

	it("goes silent again after set_debug(false)", function()
		local log, logs = load_with_capture()
		log.set_debug(true)
		log.set_debug(false)

		log.debug("pane=%d", 1)

		assert.is_false(log.is_debug_enabled())
		assert.are.equal(0, #logs)
	end)

	it("only a literal `true` enables it -- other truthy values are treated as off", function()
		local log = load_with_capture()

		log.set_debug("1")

		assert.is_false(log.is_debug_enabled())
	end)
end)

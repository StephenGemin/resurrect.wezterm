-- Guards is_windows/is_mac/separator detection in plugin/resurrect/utils.lua.
--
-- These are computed once at require-time from wezterm.target_triple, so a
-- substring-matching typo (or reverting to an incomplete exact-triple list)
-- silently breaks platform detection with no loud failure -- it just picks
-- the wrong save directory and path separator. Nothing else in the unit
-- suite exercises this logic directly.

local helper = require("spec_helper")

describe("utils platform detection", function()
	local cases = {
		{ triple = "x86_64-pc-windows-msvc", is_windows = true, is_mac = false, separator = "\\" },
		{ triple = "aarch64-pc-windows-msvc", is_windows = true, is_mac = false, separator = "\\" },
		{ triple = "x86_64-apple-darwin", is_windows = false, is_mac = true, separator = "/" },
		{ triple = "aarch64-apple-darwin", is_windows = false, is_mac = true, separator = "/" },
		{ triple = "x86_64-unknown-linux-gnu", is_windows = false, is_mac = false, separator = "/" },
		{ triple = "totally-unknown-triple", is_windows = false, is_mac = false, separator = "/" },
	}

	for _, case in ipairs(cases) do
		it("detects platform for " .. case.triple, function()
			local wz = helper.new_wezterm({ target_triple = case.triple })
			local utils = helper.load("resurrect.utils", wz)

			if case.is_windows then
				assert.is_true(not not utils.is_windows)
			else
				assert.is_falsy(utils.is_windows)
			end

			if case.is_mac then
				assert.is_true(not not utils.is_mac)
			else
				assert.is_falsy(utils.is_mac)
			end

			assert.are.equal(case.separator, utils.separator)
		end)
	end
end)

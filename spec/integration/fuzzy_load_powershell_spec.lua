-- Runs the REAL PowerShell command find_json_files_recursive builds, through
-- pwsh, against real fixture files. The other fuzzy_load specs stub
-- run_child_process, so nothing there exercises the command string itself.
local helper = require("spec_helper")

local FAKE_DIR = "/tmp/resurrect_fl_ps_test"

local function has_pwsh()
	local ok = os.execute("command -v pwsh >/dev/null 2>&1")
	return ok == true or ok == 0
end

-- Run argv for real, mapping the hard-coded powershell.exe to pwsh so the
-- Windows command executes under PowerShell Core on the Linux CI runner.
local function real_run_child_process(argv)
	local a = { table.unpack(argv) }
	if a[1] == "powershell.exe" then
		a[1] = "pwsh"
	end
	local parts = {}
	for _, word in ipairs(a) do
		parts[#parts + 1] = "'" .. tostring(word):gsub("'", "'\\''") .. "'"
	end
	local p = io.popen(table.concat(parts, " "))
	local out = p:read("*a")
	return p:close() == true, out, ""
end

local function write_fixture(rel)
	os.execute("mkdir -p '" .. FAKE_DIR .. "/" .. rel:match("(.*)/[^/]+$") .. "'")
	local f = assert(io.open(FAKE_DIR .. "/" .. rel, "w"))
	f:write("{}")
	f:close()
end

local PLAIN_OPTS = {
	fmt_workspace = function(label) return label end,
	fmt_window = function(label) return label end,
	fmt_tab = function(label) return label end,
}

describe("fuzzy_load: real PowerShell file discovery", function()
	it("lists state files via the built command with no error", function()
		if not has_pwsh() then
			pending("requires pwsh (PowerShell) on PATH")
			return
		end

		os.execute("rm -rf '" .. FAKE_DIR .. "'")
		write_fixture("workspace/myproject.json")
		write_fixture("window/mywindow.json")
		write_fixture("tab/my tab.json") -- space guards path parsing

		local wz, rec = helper.new_wezterm({
			target_triple = "x86_64-pc-windows-msvc", -- force the PowerShell branch
			patch = function(w)
				w.run_child_process = real_run_child_process
			end,
		})
		local fuzzy_loader = helper.load("resurrect.fuzzy_loader", wz)
		local state_manager = require("resurrect.state_manager")
		state_manager.change_state_save_dir(FAKE_DIR .. "/")

		local captured = {}
		local window = {
			perform_action = function(_, action, _)
				table.insert(captured, action)
			end,
		}

		fuzzy_loader.fuzzy_load(window, {}, function() end, PLAIN_OPTS)

		assert.is_nil(helper.find_emit(rec, "resurrect.error"), "command should succeed")
		assert.not_nil(captured[1], "picker should open")
		local ids = {}
		for _, c in ipairs(captured[1].arg.choices) do
			ids[c.id] = true
		end
		assert.equals(3, #captured[1].arg.choices)
		-- Windows branch sets utils.separator to "\", so ids join with a backslash.
		assert.is_true(ids["workspace\\myproject.json"])
		assert.is_true(ids["window\\mywindow.json"])
		assert.is_true(ids["tab\\my tab.json"])
	end)
end)

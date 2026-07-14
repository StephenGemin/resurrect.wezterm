-- Runs the REAL PowerShell command find_json_files_recursive builds, through pwsh, against real fixture files. 
local helper = require("spec_helper")

local FAKE_DIR = "/tmp/resurrect_fl_ps_test"

local function has_pwsh()
	local ok = os.execute("command -v pwsh >/dev/null 2>&1")
	return ok == true or ok == 0
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

-- Pin a fixture's mtime to an exact UTC instant via pwsh's LastWriteTimeUtc
local function set_mtime(rel, iso)
	os.execute(
		"pwsh -NoProfile -Command \"(Get-Item '" .. FAKE_DIR .. "/" .. rel .. "').LastWriteTimeUtc = [datetime]'" .. iso .. "'\""
	)
end

-- A run_child_process stand-in that executes argv for real under pwsh. 
local function pwsh_run_child_process(argv, env_prefix)
	local command = { table.unpack(argv) }
	if command[1] == "powershell.exe" then
		command[1] = "pwsh"
	end
	local quoted = {}
	for _, word in ipairs(command) do
		quoted[#quoted + 1] = "'" .. tostring(word):gsub("'", "'\\''") .. "'"
	end
	local shell_line = (env_prefix and env_prefix .. " " or "") .. table.concat(quoted, " ")
	local proc = io.popen(shell_line)
	local stdout = proc:read("*a")
	return proc:close() == true, stdout, ""
end

-- Load the real fuzzy_loader against a fake wezterm forced onto the Windows (PowerShell) branch
-- return the picker actions it emitted plus the emit recorder
local function run_fuzzy_load(env_prefix)
	local fake_wezterm, emit_recorder = helper.new_wezterm({
		target_triple = "x86_64-pc-windows-msvc", -- force the PowerShell branch
		patch = function(w)
			w.run_child_process = function(argv)
				return pwsh_run_child_process(argv, env_prefix)
			end
		end,
	})
	local fuzzy_loader = helper.load("resurrect.fuzzy_loader", fake_wezterm)
	require("resurrect.state_manager").change_state_save_dir(FAKE_DIR .. "/")

	local picker_actions = {}
	local fake_window = {
		perform_action = function(_, action, _)
			table.insert(picker_actions, action)
		end,
	}
	fuzzy_loader.fuzzy_load(fake_window, {}, function() end, PLAIN_OPTS)
	return picker_actions, emit_recorder
end

local function choice_ids(picker_actions)
	local ids = {}
	for _, choice in ipairs(picker_actions[1].arg.choices) do
		ids[choice.id] = true
	end
	return ids
end

-- Skip (mark pending) rather than fail on machines without PowerShell.
local it_pwsh = has_pwsh() and it or pending

describe("fuzzy_load: real PowerShell file discovery", function()
	it_pwsh("lists state files via the built command with no error", function()
		os.execute("rm -rf '" .. FAKE_DIR .. "'")
		write_fixture("workspace/myproject.json")
		write_fixture("window/mywindow.json")
		write_fixture("tab/my tab.json") -- space guards path parsing

		local picker_actions, emit_recorder = run_fuzzy_load()

		local ids = choice_ids(picker_actions)
		assert.is_true(ids["workspace\\myproject.json"])
		assert.is_true(ids["window\\mywindow.json"])
		assert.is_true(ids["tab\\my tab.json"])

		assert.is_nil(helper.find_emit(emit_recorder, "resurrect.error"), "command should succeed")
		assert.not_nil(picker_actions[1], "picker should open")
	end)

	it_pwsh("keeps post-2038 mtimes that overflow the Int32 epoch cast", function()
		os.execute("rm -rf '" .. FAKE_DIR .. "'")
		write_fixture("workspace/recent.json")
		write_fixture("workspace/future.json")
		
		-- 2040 mtime -> epoch past Int32 max (2038-01-19)
		os.execute("touch -t 204001010000 '" .. FAKE_DIR .. "/workspace/future.json'")

		local picker_actions, emit_recorder = run_fuzzy_load()

		assert.is_true(choice_ids(picker_actions)["workspace\\future.json"], "post-2038 file must not be dropped")

		assert.is_nil(helper.find_emit(emit_recorder, "resurrect.error"))
		assert.not_nil(picker_actions[1], "picker should open")
	end)

	it_pwsh("sorts by true mtime under a comma-decimal culture (de-DE)", function()
		os.execute("rm -rf '" .. FAKE_DIR .. "'")
		write_fixture("workspace/new.json")
		write_fixture("workspace/old.json")

		set_mtime("workspace/old.json", "2020-01-01T00:00:00.123456Z")
		set_mtime("workspace/new.json", "2026-01-01T00:00:00Z")

		local picker_actions, emit_recorder = run_fuzzy_load("LC_ALL=de_DE.UTF-8")

		assert.equals("workspace\\new.json", picker_actions[1].arg.choices[1].id)
		assert.equals("workspace\\old.json", picker_actions[1].arg.choices[2].id)

		assert.is_nil(helper.find_emit(emit_recorder, "resurrect.error"))
		assert.not_nil(picker_actions[1], "picker should open")
	end)
end)

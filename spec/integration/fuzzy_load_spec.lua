-- Integration tests for fuzzy_loader.fuzzy_load.
--
-- Verifies that:
--   1. state_manager.save_state_dir is reachable so find_json_files_recursive
--      receives a non-nil path (regression: field was private and fuzzy_load
--      crashed with "attempt to index a nil value (local 'base_path')").
--   2. insert_choices correctly parses the file listing into picker entries.
--
-- wezterm.run_child_process is stubbed so no real shell commands are run; all
-- other behaviour (insert_choices, InputSelector assembly) uses the real code.

local helper = require("spec_helper")

local sep = package.config:sub(1, 1) == "\\" and "\\" or "/"
local FAKE_DIR = "/tmp/resurrect_fl_test"

-- Build "epoch filepath" stdout matching the format produced by the shell find
-- commands in find_json_files_recursive.  The pattern insert_choices expects:
--   %s*(%d+)%s+.+[/\]<type>[/\]<file>.json$
local function make_stdout(entries)
	local lines = {}
	for _, e in ipairs(entries) do
		local path = FAKE_DIR .. sep .. e.type .. sep .. e.name .. ".json"
		table.insert(lines, "1000000000 " .. path)
	end
	return table.concat(lines, "\n") .. "\n"
end

local function make_window()
	local captured = {}
	local window = {
		perform_action = function(_, action, _)
			table.insert(captured, action)
		end,
	}
	return window, {}, captured
end

-- wezterm.format returns "" in the mock, which makes the label-length cost
-- calculation go negative and insert_choices returns early with an empty list.
-- Pass identity format functions so costs are 0 and max_length is computed correctly.
local PLAIN_OPTS = {
	fmt_workspace = function(label) return label end,
	fmt_window = function(label) return label end,
	fmt_tab = function(label) return label end,
}

local function setup(stdout)
	local wz, rec = helper.new_wezterm({
		patch = function(w, _)
			w.run_child_process = function(_)
				return true, stdout, ""
			end
		end,
	})
	local fuzzy_loader = helper.load("resurrect.fuzzy_loader", wz)
	-- require after helper.load so state_manager shares the same wz mock and
	-- is already cached when fuzzy_load calls require("resurrect.state_manager").
	local state_manager = require("resurrect.state_manager")
	state_manager.change_state_save_dir(FAKE_DIR .. sep)
	return fuzzy_loader, state_manager, rec
end

describe("fuzzy_load: file discovery", function()
	it("emits resurrect.error and still opens the picker when no state files exist", function()
		local fuzzy_loader, _, rec = setup("")
		local window, pane, captured = make_window()

		fuzzy_loader.fuzzy_load(window, pane, function() end)

		assert.not_nil(
			helper.find_emit(rec, "resurrect.error"),
			"expected resurrect.error to be emitted when no files are found"
		)
		assert.not_nil(captured[1], "expected perform_action to be called even with an empty list")
	end)

	it("populates the picker with one entry per state file found", function()
		local entries = {
			{ type = "workspace", name = "myproject" },
			{ type = "window", name = "mywindow" },
			{ type = "tab", name = "mytab" },
		}
		local fuzzy_loader, _, _ = setup(make_stdout(entries))
		local window, pane, captured = make_window()

		fuzzy_loader.fuzzy_load(window, pane, function() end, PLAIN_OPTS)

		assert.not_nil(captured[1], "expected perform_action to be called")
		local choices = captured[1].arg.choices
		assert.equals(3, #choices, "expected one choice per state file")
	end)

	it("sets choice ids to <type><sep><file>.json for correct restore dispatch", function()
		local entries = {
			{ type = "workspace", name = "myproject" },
			{ type = "window", name = "mywindow" },
			{ type = "tab", name = "mytab" },
		}
		local fuzzy_loader, _, _ = setup(make_stdout(entries))
		local window, pane, captured = make_window()

		fuzzy_loader.fuzzy_load(window, pane, function() end, PLAIN_OPTS)

		local ids = {}
		for _, c in ipairs(captured[1].arg.choices) do
			ids[c.id] = true
		end
		assert.is_true(ids["workspace" .. sep .. "myproject.json"])
		assert.is_true(ids["window" .. sep .. "mywindow.json"])
		assert.is_true(ids["tab" .. sep .. "mytab.json"])
	end)
end)

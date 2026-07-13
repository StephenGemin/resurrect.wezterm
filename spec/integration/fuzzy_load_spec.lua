local helper = require("spec_helper")

local sep = package.config:sub(1, 1) == "\\" and "\\" or "/"
local FAKE_DIR = "/tmp/resurrect_fl_test"

-- Produces "epoch filepath" lines in the format find_json_files_recursive returns.
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

local function setup(stdout)
	local wz, rec = helper.new_wezterm({
		patch = function(w, _)
			w.run_child_process = function(_)
				return true, stdout, ""
			end
		end,
	})
	local fuzzy_loader = helper.load("resurrect.fuzzy_loader", wz)
	-- Load state_manager after fuzzy_loader so it shares the same wz mock and
	-- is cached before fuzzy_load calls require("resurrect.state_manager").
	local state_manager = require("resurrect.state_manager")
	state_manager.change_state_save_dir(FAKE_DIR .. sep)
	return fuzzy_loader, state_manager, rec
end

-- wezterm.format returns "" in the mock, making the label-length cost negative
-- and causing insert_choices to return early. Identity functions keep costs at 0.
local PLAIN_OPTS = {
	fmt_workspace = function(label) return label end,
	fmt_window = function(label) return label end,
	fmt_tab = function(label) return label end,
}

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

describe("fuzzy_load: sorting and path parsing", function()
	-- One "epoch path" line, letting each entry pick its own mtime.
	local function line(epoch, type, name)
		return epoch .. " " .. FAKE_DIR .. sep .. type .. sep .. name .. ".json"
	end

	it("orders entries newest-first within a type", function()
		local stdout = table.concat({
			line(1000000100, "workspace", "older"),
			line(1000000300, "workspace", "newest"),
			line(1000000200, "workspace", "middle"),
		}, "\n") .. "\n"
		local fuzzy_loader = setup(stdout)
		local window, pane, captured = make_window()

		fuzzy_loader.fuzzy_load(window, pane, function() end, PLAIN_OPTS)

		local choices = captured[1].arg.choices
		assert.equals("workspace" .. sep .. "newest.json", choices[1].id)
		assert.equals("workspace" .. sep .. "middle.json", choices[2].id)
		assert.equals("workspace" .. sep .. "older.json", choices[3].id)
	end)

	it("keeps spaces in the path when building the choice id", function()
		-- Mirrors the real macOS state dir: a space in a directory ("Application
		-- Support") and in the state name. The greedy full-path capture must keep
		-- the row rather than silently dropping it.
		local spaced = "/tmp/App Support/wezterm/workspace/my project.json"
		local fuzzy_loader = setup("1000000000 " .. spaced .. "\n")
		local window, pane, captured = make_window()

		fuzzy_loader.fuzzy_load(window, pane, function() end, PLAIN_OPTS)

		local choices = captured[1].arg.choices
		assert.equals(1, #choices)
		assert.equals("workspace" .. sep .. "my project.json", choices[1].id)
	end)

	it("strips a CRLF line ending instead of emptying the picker", function()
		local path = FAKE_DIR .. sep .. "workspace" .. sep .. "myproject.json"
		local fuzzy_loader = setup("1000000000 " .. path .. "\r\n")
		local window, pane, captured = make_window()

		fuzzy_loader.fuzzy_load(window, pane, function() end, PLAIN_OPTS)

		local choices = captured[1].arg.choices
		assert.equals(1, #choices)
		assert.equals("workspace" .. sep .. "myproject.json", choices[1].id)
	end)
end)

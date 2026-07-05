local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")

-- Restored panes replay their saved scrollback via inject_output, and the
-- freshly spawned shell then paints one genuinely new prompt below the
-- replay. A later save that naively re-captures such a pane persists
-- [replay + fresh prompt] -- one extra prompt block per save->restore cycle,
-- forever. This module remembers what was replayed into each restored pane,
-- snapshots the pane's rendered content once that fresh prompt has painted,
-- and uses the pair two ways:
--
--  * idle detection: a capture still byte-identical to the snapshot proves
--    the pane is untouched, so the replay is persisted as-is.
--  * prompt exemplar: whatever the snapshot holds beyond the rendered replay
--    is exactly what one organic prompt adds to this pane -- measured, never
--    pattern-matched, so it holds for any shell or prompt theme. Once the
--    pane sees real activity, live captures that still end in that measured
--    block get it stripped: persisted text stops where the live prompt
--    began, and the next restore's fresh shell completes the screen instead
--    of duplicating the prompt.
--
-- Every guard fails toward persisting the capture unmodified, so real
-- activity can never be mistaken for idleness and content is never eaten.
-- (OSC 133 semantic zones were tried first and are unreliable on wezterm
-- 20240203: spurious Output zones appear under transient prompts, while
-- real command output sometimes creates none.)
local pub = {}

---@type {[integer]: {text: string?, snapshot: string?, prompt_rows: integer?, prompt_last_row: string?}}
local _baselines = {}

-- How long after the restore's "\r\n" the fresh prompt is given to paint
-- before the settle snapshot is taken. Too early and the snapshot misses the
-- prompt (every later save then mismatches and captures live -- the old,
-- compounding behavior); there is no correctness risk in being generous.
local SETTLE_DELAY_SECONDS = 1.0

-- A settle snapshot may exceed the rendered replay by a fresh prompt block,
-- nothing more. Growth beyond this many rows means the user was already
-- active during the settle window; freezing that activity into the snapshot
-- would let a later idle save silently persist the pre-activity replay, so
-- the registration is dropped instead (normal captures from then on).
local MAX_SETTLE_GROWTH_ROWS = 8

local function count_rows(text)
	local _, n = text:gsub("\n", "")
	return n
end

-- Entries for closed panes are unreachable (pane ids are never reused); drop
-- them so long-running sessions with many restores don't accumulate dead
-- scrollback copies.
local function sweep()
	local live = {}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(mux_win:tabs()) do
			for _, pane in ipairs(tab:panes()) do
				live[pane:pane_id()] = true
			end
		end
	end
	for pane_id in pairs(_baselines) do
		if not live[pane_id] then
			_baselines[pane_id] = nil
		end
	end
end

---Record the text just replayed into a restored pane (may be empty, for a
---pane restored with no replay). Call right after inject_output, before the
---shell has had a chance to paint; the settle snapshot that measures the
---organic first prompt is scheduled from here.
---@param pane Pane
---@param text string the exact replay text, without the positioning "\r\n"
function pub.register(pane, text)
	sweep()
	-- Lazy require: pane_tree requires this module back, so a top-level
	-- require would be circular.
	local max_nlines = require("resurrect.pane_tree").max_nlines
	local pane_id = pane:pane_id()
	local entry = { text = text }
	_baselines[pane_id] = entry
	-- The replay as actually rendered in this pane: long lines re-wrap to the
	-- new pane's width, so the snapshot growth bound must be measured against
	-- this, not against the original text's row count.
	local ok, rendered = pcall(utils.capture_pane_text, pane, max_nlines)
	if not ok then
		_baselines[pane_id] = nil
		wezterm.log_info(("resurrect.restore_baseline: pane %d register capture failed, not tracking"):format(pane_id))
		return
	end
	local rendered_rows = count_rows(rendered)
	wezterm.log_info(
		("resurrect.restore_baseline: pane %d registered replay (%d bytes, %d rendered rows)"):format(
			pane_id,
			#text,
			rendered_rows
		)
	)
	wezterm.time.call_after(SETTLE_DELAY_SECONDS, function()
		if _baselines[pane_id] ~= entry then
			return
		end
		-- pcall: the pane may have closed during the settle window.
		local snap_ok, snapshot = pcall(utils.capture_pane_text, pane, max_nlines)
		if not snap_ok then
			_baselines[pane_id] = nil
			wezterm.log_info(
				("resurrect.restore_baseline: pane %d settle capture failed, not tracking"):format(pane_id)
			)
			return
		end
		local snapshot_rows = count_rows(snapshot)
		if snapshot_rows > rendered_rows + MAX_SETTLE_GROWTH_ROWS then
			_baselines[pane_id] = nil
			wezterm.log_info(
				("resurrect.restore_baseline: pane %d grew %d->%d rows during settle (activity), not tracking"):format(
					pane_id,
					rendered_rows,
					snapshot_rows
				)
			)
			return
		end
		entry.snapshot = snapshot
		-- What this shell adds when it paints one prompt, measured rather
		-- than pattern-matched: the row count to strip from a later capture,
		-- and the final row's rendered text as the guard that such a capture
		-- still ends in the same prompt block.
		local prompt_rows = utils.count_text_rows(snapshot) - utils.count_text_rows(rendered)
		local prompt_last_row = utils.row_plaintext(utils.last_row(snapshot))
		if prompt_rows > 0 and prompt_rows <= MAX_SETTLE_GROWTH_ROWS and prompt_last_row ~= "" then
			entry.prompt_rows = prompt_rows
			entry.prompt_last_row = prompt_last_row
		end
		wezterm.log_info(
			("resurrect.restore_baseline: pane %d settled (%d rows, prompt block: %s rows), idle saves will persist the replay"):format(
				pane_id,
				snapshot_rows,
				entry.prompt_rows or "unmeasured"
			)
		)
	end)
end

-- The pane sits at a live prompt only when its foreground process is the
-- shell itself; under a running command the captured tail is real output.
-- pcall: the process probe can fail on a pane mid-teardown.
---@param pane Pane
---@return boolean
local function at_shell_prompt(pane)
	local ok, proc = pcall(function()
		return pane:get_foreground_process_info()
	end)
	if not ok or not proc then
		return false
	end
	return utils.COMMON_SHELLS[utils.base_name_of(proc.name or proc.executable)] == true
end

---Decide what to persist for a pane given its freshly captured content.
---Returns the originally replayed text when the capture proves the pane is
---untouched since restore (byte-identical to the settle snapshot). A capture
---that differs means real activity: it is persisted live, minus the trailing
---prompt block when the measured exemplar vouches for it -- the pane must be
---sitting at its shell prompt and the capture's final row must render as the
---settle snapshot's final row did; only then are exactly the measured rows
---dropped. Any doubt persists the capture unmodified.
---@param pane Pane
---@param captured string the pane's current content as captured by pane_tree
---@return string
function pub.text_to_persist(pane, captured)
	local pane_id = pane:pane_id()
	local entry = _baselines[pane_id]
	if not entry then
		return captured
	end
	if entry.snapshot then
		if captured == entry.snapshot then
			wezterm.log_info(("resurrect.restore_baseline: pane %d idle, persisting replay"):format(pane_id))
			-- text is always set while snapshot is (they are cleared together);
			-- the fallback only satisfies the nil checker.
			return entry.text or captured
		end
		-- Real activity: idle detection is over for this pane. Release the
		-- replay and snapshot copies (potentially large) but keep the measured
		-- prompt block for capture-time stripping.
		entry.text = nil
		entry.snapshot = nil
		wezterm.log_info(
			("resurrect.restore_baseline: pane %d changed since restore, capturing live from now on"):format(pane_id)
		)
	elseif entry.text then
		-- Registered but not yet settled: nothing measured to vouch for a strip.
		wezterm.log_info(("resurrect.restore_baseline: pane %d saved before settle, capturing live"):format(pane_id))
		return captured
	end
	if not entry.prompt_rows then
		_baselines[pane_id] = nil
		return captured
	end
	if utils.row_plaintext(utils.last_row(captured)) ~= entry.prompt_last_row then
		return captured
	end
	if not at_shell_prompt(pane) then
		return captured
	end
	wezterm.log_info(
		("resurrect.restore_baseline: pane %d stripping trailing prompt block (%d rows)"):format(
			pane_id,
			entry.prompt_rows
		)
	)
	return utils.strip_last_rows(captured, entry.prompt_rows)
end

return pub

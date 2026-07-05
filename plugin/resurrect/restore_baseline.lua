local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
local utils = require("resurrect.utils")

-- Restored panes replay their saved scrollback via inject_output, and the
-- freshly spawned shell then paints one genuinely new prompt below the
-- replay. A later save that naively re-captures such a pane persists
-- [replay + fresh prompt] -- one extra prompt block per save->restore cycle,
-- forever. This module polls each restored pane until that fresh prompt has
-- painted and the pane is quiescent, then uses the snapshot two ways:
--
--  * idle detection: a capture still byte-identical to the snapshot proves
--    the pane is untouched, so the replay is persisted as-is.
--  * prompt exemplar: the rows the quiescent snapshot holds beyond the
--    replayed text are exactly what one organic prompt adds to this pane --
--    measured, never pattern-matched, so it holds for any shell or prompt
--    theme. Once the pane sees real activity, live captures that still end
--    in that measured block get it stripped: persisted text stops where the
--    live prompt began, and the next restore's fresh shell completes the
--    screen instead of duplicating the prompt.
--
-- The settle is a poll loop, not a fixed delay: under cold-start contention
-- (a workspace spawning several shells at once) the first prompt can take
-- many seconds to paint, and a fixed-delay snapshot taken before it lands
-- both breaks idle detection and mismeasures the exemplar. The replay is
-- compared per-row as plaintext, not bytes: injected bytes are re-encoded by
-- the terminal, and the rendered rows survive that round trip while the
-- escape bytes may not.
--
-- Two settle situations cannot be measured by growth alone and fall back to
-- idle-stability tracking: the genuinely reused pane (an already-running
-- shell absorbs the replay, so its exemplar is instead anchored to the echo
-- of the `cd` command this plugin itself sent there) and a pane whose
-- replayed prefix stops matching at prompt-sized growth (the re-rendered
-- replay cannot be row-attributed, so nothing vouches for a strip).
--
-- Every guard fails toward persisting the capture unmodified, so real
-- activity can never be mistaken for idleness and content is never eaten.
-- (OSC 133 semantic zones were tried first and are unreliable on wezterm
-- 20240203: spurious Output zones appear under transient prompts, while
-- real command output sometimes creates none.)
local pub = {}

---@type {[integer]: {text: string?, snapshot: string?, prompt_rows: integer?, prompt_last_row: string?}}
local _baselines = {}

local SETTLE_POLL_SECONDS = 1.0
local SETTLE_MAX_POLLS = 15

-- An organic prompt block is at most this many rows. A quiescent suffix any
-- larger means the user was already active during the settle window: learning
-- it would over-strip later captures, and freezing it into the snapshot would
-- let a later idle save silently persist the pre-activity replay, so the
-- registration is dropped instead (normal captures from then on).
local MAX_PROMPT_BLOCK_ROWS = 4

-- A reused pane (see register's no_exemplar) legitimately grows by more than
-- one prompt block: its already-running shell's first prompt plus the
-- restore's cd exchange.
local REUSED_PANE_MAX_GROWTH_ROWS = 8

-- Temporary diagnostic firehose (grep "resurrect.debug:"). Remove or flip
-- off before this branch is finalized.
local DEBUG = true

local function dbg(fmt, ...)
	if DEBUG then
		wezterm.log_info("resurrect.debug: " .. fmt:format(...))
	end
end

---The last n of rows, rendered as "index=plaintext" pairs for log lines.
---@param rows string[]
---@param n integer
---@return string
local function tail_dump(rows, n)
	local parts = {}
	for i = math.max(1, #rows - n + 1), #rows do
		local plain = utils.row_plaintext(rows[i])
		if #plain > 60 then
			plain = plain:sub(1, 60) .. "..."
		end
		parts[#parts + 1] = ("%d=%q"):format(i, plain)
	end
	return table.concat(parts, " ")
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

---Record the text just replayed into a restored pane (may be empty, for a
---pane restored with no replay), then poll until the pane's organic first
---prompt has painted and the pane is quiescent. Call right after
---inject_output.
---@param pane Pane
---@param text string the exact replay text, without the positioning "\r\n"
---@param opts? {no_exemplar: boolean?, cd_marker: string?} no_exemplar: the
---pane's shell was already running when the replay was injected (the reused
---active pane), so its quiescent growth is not one clean prompt block; take
---the snapshot for idle detection only. cd_marker: the exact `cd` command
---sent to that reused pane -- its echo anchors where the fresh prompt block
---begins, letting even the reused pane learn a strip exemplar.
function pub.register(pane, text, opts)
	sweep()
	-- Lazy require: pane_tree requires this module back, so a top-level
	-- require would be circular.
	local max_nlines = require("resurrect.pane_tree").max_nlines
	local no_exemplar = opts and opts.no_exemplar
	local cd_marker = opts and opts.cd_marker
	local pane_id = pane:pane_id()
	local entry = { text = text }
	_baselines[pane_id] = entry
	local text_rows = utils.split_rows(text)
	local text_plain = {}
	for i, row in ipairs(text_rows) do
		text_plain[i] = utils.row_plaintext(row)
	end
	wezterm.log_info(
		("resurrect.restore_baseline: pane %d registered replay (%d bytes, %d rows)"):format(
			pane_id,
			#text,
			#text_plain
		)
	)
	dbg("pane %d replay tail: %s", pane_id, tail_dump(text_rows, 6))

	-- The reused pane's fresh prompt block starts right below the echo of the
	-- cd this plugin sent it; find that echo (our own token, plain-matched so
	-- paths with pattern chars can't misfire) in the bottom rows and measure
	-- what the shell painted after it. A wrapped echo, a duplicate match, or
	-- a blank final row declines -- snapshot-only tracking, as before.
	local function exemplar_from_marker(snap_rows)
		if not cd_marker then
			return
		end
		local marker_idx
		for i = math.max(1, #snap_rows - MAX_PROMPT_BLOCK_ROWS), #snap_rows do
			if utils.row_plaintext(snap_rows[i]):find(cd_marker, 1, true) then
				if marker_idx then
					dbg("pane %d cd marker on rows %d and %d, ambiguous, not learning", pane_id, marker_idx, i)
					return
				end
				marker_idx = i
			end
		end
		if not marker_idx or marker_idx == #snap_rows then
			dbg("pane %d cd marker %s, not learning", pane_id, marker_idx and "on final row" or "not in bottom rows")
			return
		end
		local last_plain = utils.row_plaintext(snap_rows[#snap_rows])
		if last_plain == "" then
			return
		end
		entry.prompt_rows = #snap_rows - marker_idx
		entry.prompt_last_row = last_plain
	end

	local polls = 0
	local previous_snapshot ---@type string?
	-- Flipped when the replayed prefix stops matching at prompt-sized growth:
	-- the re-rendered replay can't be row-attributed, so no exemplar -- but
	-- idle byte-stability still holds, which is what stops per-cycle growth.
	local stability_only = no_exemplar
	local function poll()
		if _baselines[pane_id] ~= entry then
			return
		end
		polls = polls + 1
		-- pcall: the pane may have closed during the settle window.
		local snap_ok, snapshot = pcall(utils.capture_pane_text, pane, max_nlines)
		if not snap_ok then
			_baselines[pane_id] = nil
			wezterm.log_info(("resurrect.restore_baseline: pane %d settle capture failed, not tracking"):format(pane_id))
			return
		end
		local snap_rows = utils.split_rows(snapshot)
		local growth = #snap_rows - #text_plain
		local stable = snapshot == previous_snapshot
		local at_prompt = at_shell_prompt(pane)
		dbg(
			"pane %d poll %d: %d rows, growth %d, stable %s, at_prompt %s, tail: %s",
			pane_id,
			polls,
			#snap_rows,
			growth,
			tostring(stable),
			tostring(at_prompt),
			tail_dump(snap_rows, 6)
		)

		if not stability_only then
			if growth < 0 or growth > MAX_PROMPT_BLOCK_ROWS then
				-- A lone bad-growth frame is not proof of activity: a poll can
				-- catch the first prompt mid-paint, with the replay's final row
				-- cleared and trimmed from the capture (transient negative
				-- growth). Only a snapshot that held for a full poll interval
				-- convicts; otherwise keep polling.
				if stable then
					_baselines[pane_id] = nil
					wezterm.log_info(
						("resurrect.restore_baseline: pane %d activity during settle, not tracking"):format(pane_id)
					)
					return
				end
				dbg("pane %d growth %d out of range but unstable, polling on", pane_id, growth)
			else
				local prefix_ok = true
				for i = 1, #text_plain do
					local snap_plain = utils.row_plaintext(snap_rows[i])
					if snap_plain ~= text_plain[i] then
						dbg(
							"pane %d prefix mismatch at row %d: %q vs replay %q",
							pane_id,
							i,
							snap_plain:sub(1, 60),
							text_plain[i]:sub(1, 60)
						)
						prefix_ok = false
						break
					end
				end
				if not prefix_ok then
					-- Typing edits a pane's tail, so a prefix mismatch at benign
					-- growth is the replay re-rendering, not user activity;
					-- dropping to live captures here would re-grow the state
					-- file on every save.
					stability_only = true
				elseif growth > 0 and stable and at_prompt then
					entry.snapshot = snapshot
					-- What this shell adds when it paints one prompt, measured
					-- rather than pattern-matched: the row count to strip from a
					-- later capture, and the final row's rendering as the guard
					-- that such a capture still ends in the same prompt block.
					local last_plain = utils.row_plaintext(snap_rows[#snap_rows])
					if last_plain ~= "" then
						entry.prompt_rows = growth
						entry.prompt_last_row = last_plain
					end
					wezterm.log_info(
						("resurrect.restore_baseline: pane %d settled (%d rows, prompt block: %s rows), idle saves will persist the replay"):format(
							pane_id,
							#snap_rows,
							entry.prompt_rows or "unmeasured"
						)
					)
					return
				end
			end
		end

		if stability_only then
			if growth > REUSED_PANE_MAX_GROWTH_ROWS then
				_baselines[pane_id] = nil
				wezterm.log_info(
					("resurrect.restore_baseline: pane %d activity during settle, not tracking"):format(pane_id)
				)
				return
			end
			if stable and at_prompt then
				entry.snapshot = snapshot
				exemplar_from_marker(snap_rows)
				local how
				if entry.prompt_rows then
					how = ("prompt block: %d rows via cd marker), idle saves will persist the replay"):format(
						entry.prompt_rows
					)
				elseif no_exemplar then
					how = "reused pane: idle saves only)"
				else
					how = "replay prefix not intact: idle saves only)"
				end
				wezterm.log_info(
					("resurrect.restore_baseline: pane %d settled (%d rows, %s"):format(pane_id, #snap_rows, how)
				)
				return
			end
		end

		if polls >= SETTLE_MAX_POLLS then
			-- Prompt never observed (or never went quiescent at a shell): keep
			-- the last snapshot so idle byte-stability still works, but there
			-- is no exemplar to vouch for stripping.
			entry.snapshot = snapshot
			wezterm.log_info(
				("resurrect.restore_baseline: pane %d prompt block not observed after %ds; idle saves only"):format(
					pane_id,
					SETTLE_MAX_POLLS * SETTLE_POLL_SECONDS
				)
			)
			return
		end
		previous_snapshot = snapshot
		-- Keep event-driven saves from landing between polls: a capture taken
		-- mid-settle would persist the replay with a half-painted prompt.
		-- Lazy require, same cycle as above via pane_tree.
		require("resurrect.state_manager").extend_save_suppression(SETTLE_POLL_SECONDS * 2)
		wezterm.time.call_after(SETTLE_POLL_SECONDS, poll)
	end
	wezterm.time.call_after(SETTLE_POLL_SECONDS, poll)
end

---Decide what to persist for a pane given its freshly captured content.
---Returns the originally replayed text when the capture proves the pane is
---untouched since restore (byte-identical to the settle snapshot). A capture
---that differs means real activity: it is persisted live, minus the trailing
---prompt block when the measured exemplar vouches for it -- the pane must be
---sitting at its shell prompt, the capture's final row must render as the
---settle snapshot's final row did, and no other row in the strip region may
---render like it (a region that swallowed more than one prompt paint means
---the exemplar was mismeasured); only then are exactly the measured rows
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
	dbg(
		"pane %d text_to_persist: text=%s snapshot=%s prompt_rows=%s, captured %d bytes",
		pane_id,
		tostring(entry.text ~= nil),
		tostring(entry.snapshot ~= nil),
		tostring(entry.prompt_rows),
		#captured
	)
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
	local captured_rows = utils.split_rows(captured)
	if #captured_rows < entry.prompt_rows then
		wezterm.log_info(
			("resurrect.restore_baseline: pane %d strip declined: capture shorter than prompt block"):format(pane_id)
		)
		return captured
	end
	local captured_last = utils.row_plaintext(captured_rows[#captured_rows])
	if captured_last ~= entry.prompt_last_row then
		wezterm.log_info(("resurrect.restore_baseline: pane %d strip declined: final row mismatch"):format(pane_id))
		dbg("pane %d final row %q vs exemplar %q", pane_id, captured_last:sub(1, 60), entry.prompt_last_row:sub(1, 60))
		return captured
	end
	for i = #captured_rows - entry.prompt_rows + 1, #captured_rows - 1 do
		if utils.row_plaintext(captured_rows[i]):sub(1, #entry.prompt_last_row) == entry.prompt_last_row then
			wezterm.log_info(
				("resurrect.restore_baseline: pane %d strip declined: exemplar row repeats in region"):format(pane_id)
			)
			return captured
		end
	end
	if not at_shell_prompt(pane) then
		wezterm.log_info(("resurrect.restore_baseline: pane %d strip declined: not at shell prompt"):format(pane_id))
		return captured
	end
	wezterm.log_info(
		("resurrect.restore_baseline: pane %d stripping trailing prompt block (%d rows)"):format(
			pane_id,
			entry.prompt_rows
		)
	)
	dbg("pane %d stripping rows: %s", pane_id, tail_dump(captured_rows, entry.prompt_rows))
	return utils.strip_last_rows(captured, entry.prompt_rows)
end

return pub

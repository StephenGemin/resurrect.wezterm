local wezterm = require("wezterm") --[[@as Wezterm]] --- this type cast invokes the LSP module for Wezterm
---@alias encryption_opts {enable: boolean, method: string, private_key: string?, public_key: string?, encrypt: fun(file_path: string, lines: string), decrypt: fun(file_path: string): string}

---@type encryption_opts
local pub = {
	enable = false,
	method = "age",
	private_key = nil,
	public_key = nil,
}

---@param file_path string
---@param lines string
function pub.encrypt(file_path, lines)
	-- Write data to a temp file, then encrypt from file to avoid shell injection
	-- and command-line length limits
	local temp_input = os.tmpname()
	local f = io.open(temp_input, "w")
	if not f then
		error("Encryption failed: could not create temp file")
	end
	f:write(lines)
	f:flush()
	f:close()

	local cmd
	if pub.method:find("gpg") then
		cmd = {
			pub.method,
			"--batch",
			"--yes",
			"--encrypt",
			"--recipient",
			pub.public_key,
			"--output",
			file_path,
			temp_input,
		}
	else
		cmd = { pub.method, "-r", pub.public_key, "-o", file_path, temp_input }
	end

	local success, _, stderr = wezterm.run_child_process(cmd)
	os.remove(temp_input)
	if not success then
		error("Encryption failed: " .. (stderr or "unknown error"))
	end
end

---@param file_path string
---@return string
function pub.decrypt(file_path)
	local cmd = { pub.method, "-d", "-i", pub.private_key, file_path }

	if pub.method:find("gpg") then
		cmd = { pub.method, "--batch", "--yes", "--decrypt", file_path }
	end

	local success, stdout, stderr = wezterm.run_child_process(cmd)
	if not success then
		error("Decryption failed: " .. stderr)
	end

	return stdout
end

return pub

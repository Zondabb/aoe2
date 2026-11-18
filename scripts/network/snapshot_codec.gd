extends RefCounted

## Only JSON state is compressed; never deserialize executable Godot objects.
const MAX_RAW_BYTES := 4 * 1024 * 1024

static func encode(state: Dictionary) -> Dictionary:
	var raw := JSON.stringify(state, "", true, true).to_utf8_buffer()
	if raw.is_empty() or raw.size() > MAX_RAW_BYTES: return {}
	var packed := raw.compress(FileAccess.COMPRESSION_DEFLATE)
	if packed.is_empty(): return {}
	return {"codec": "zlib", "raw_size": raw.size(), "data": Marshalls.raw_to_base64(packed)}

static func decode(message: Dictionary) -> Dictionary:
	var size: Variant = message.get("raw_size")
	if message.get("codec") != "zlib" or (size is not int and size is not float): return {}
	if not is_finite(float(size)) or float(size) != floor(float(size)) or size < 1 or size > MAX_RAW_BYTES: return {}
	var data: Variant = message.get("data")
	if data is not String or data.is_empty() or data.length() > MAX_RAW_BYTES or data.length() % 4 != 0: return {}
	var pattern := RegEx.new()
	pattern.compile("^[A-Za-z0-9+/]*={0,2}$")
	if pattern.search(data) == null: return {}
	var packed := Marshalls.base64_to_raw(data)
	if packed.is_empty() or Marshalls.raw_to_base64(packed) != data: return {}
	var raw := packed.decompress(int(size), FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != int(size): return {}
	var state: Variant = JSON.parse_string(raw.get_string_from_utf8())
	return state if state is Dictionary else {}

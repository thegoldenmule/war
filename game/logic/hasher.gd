@tool
class_name WarHasher
extends RefCounted

## Canonical JSON serializer (compatible with `json-stable-stringify(x,{space:2})`)
## plus the custom 8-lane rolling state hash that the wire protocol compares.
##
## This is THE determinism parity contract: game/logic/hasher.gd (GDScript) and
## validator/src/logic/hasher.ts (TypeScript) MUST produce byte-for-byte
## identical canonical JSON and identical 64-hex-char hashes for the same value.
## The algorithm is reproduced verbatim from the Moveborne hasher.gd reference.
##
## NOTE: the hash is NOT cryptographic — it is a fast non-cryptographic rolling
## hash used only for optimistic-reconcile state comparison.
##
## Pure static utility — zero Node / scene dependencies, headless-loadable.

# Lane init values are the SHA-256 IVs; lane shift amounts per the contract.
const IV := [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
const SHIFTS := [5, 7, 11, 13, 17, 19, 23, 29]


## Emulate JS `x | 0`: wrap to a signed 32-bit integer.
static func _to_int32(v: int) -> int:
	v = v & 0xFFFFFFFF
	if v >= 0x80000000:
		v -= 0x100000000
	return v


## The custom rolling hash over the UTF-8 bytes of `s`. 64 lowercase hex chars.
## For each byte b and each of the 8 lanes:
##   h[lane] = toInt32((h[lane] << SHIFTS[lane]) - h[lane] + b)
## Output: each lane formatted as %08x (unsigned 32-bit) concatenated.
static func hash_string(s: String) -> String:
	var data: PackedByteArray = s.to_utf8_buffer()
	var h: Array = []
	for lane in range(8):
		h.append(_to_int32(IV[lane]))
	var count: int = data.size()
	for idx in range(count):
		var b: int = data[idx]
		for lane in range(8):
			var hv: int = h[lane]
			h[lane] = _to_int32((hv << SHIFTS[lane]) - hv + b)
	var out: String = ""
	for lane in range(8):
		out += "%08x" % (h[lane] & 0xFFFFFFFF)
	return out


## Hash a value via its canonical serialization (the state-hash entry point).
static func hash_value(value) -> String:
	return hash_string(canonical_stringify(value))


## Serialize a Variant to canonical JSON identical to json-stable-stringify with
## {space:2}: keys sorted lexicographically at every depth, 2-space indent,
## arrays in order, and dictionary keys with a null value OMITTED (mirrors JS
## dropping `undefined`-valued fields).
static func canonical_stringify(value) -> String:
	return _ser(value, 0)


static func _ser(node, level: int) -> String:
	# Returns "" to signal an omitted value (null) so callers can drop the key.
	if node == null:
		return ""
	var indent: String = "\n" + "  ".repeat(level)
	if node is Array:
		var parts: Array = []
		for i in range(node.size()):
			var item: String = _ser(node[i], level + 1)
			if item == "":
				item = "null"
			parts.append(indent + "  " + item)
		# Empty array serializes compactly as "[]" (matches JSON.stringify space:2).
		if parts.is_empty():
			return "[]"
		return "[" + ",".join(parts) + indent + "]"
	elif node is Dictionary:
		var keys: Array = node.keys()
		keys.sort()
		var parts: Array = []
		for k in keys:
			var sv: String = _ser(node[k], level + 1)
			if sv == "":
				continue
			parts.append(indent + "  " + _quote(str(k)) + ": " + sv)
		# Empty object serializes compactly as "{}" (matches JSON.stringify space:2).
		if parts.is_empty():
			return "{}"
		return "{" + ",".join(parts) + indent + "}"
	else:
		return _leaf(node)


static func _leaf(node) -> String:
	if node is bool:
		return "true" if node else "false"
	if node is int:
		return str(node)
	if node is float:
		return _num_float(node)
	if node is String or node is StringName:
		return _quote(str(node))
	return _quote(str(node))


## Format a float like JS JSON.stringify / String(n): integer-valued floats print
## without a decimal point; otherwise the SHORTEST decimal string that round-trips
## to the same IEEE-754 double (matching JS fixed notation for |f| in [1e-6, 1e21)).
## str(float) is insufficient — Godot caps at ~14 significant digits and would not
## round-trip a value like 4528.410562653503.
static func _num_float(f: float) -> String:
	if not is_finite(f):
		return "null"
	if f == floor(f) and absf(f) < 1e15:
		return str(int(f))
	for p in range(1, 18):
		var s := String.num(f, p)
		if s.to_float() == f:
			return s
	return String.num(f, 17)


## JSON string quoting matching JSON.stringify for our (ASCII) data.
static func _quote(s: String) -> String:
	var out: String = "\""
	for i in range(s.length()):
		var c: int = s.unicode_at(i)
		if c == 0x22:
			out += "\\\""
		elif c == 0x5C:
			out += "\\\\"
		elif c == 0x08:
			out += "\\b"
		elif c == 0x09:
			out += "\\t"
		elif c == 0x0A:
			out += "\\n"
		elif c == 0x0C:
			out += "\\f"
		elif c == 0x0D:
			out += "\\r"
		elif c < 0x20:
			out += "\\u%04x" % c
		else:
			out += String.chr(c)
	out += "\""
	return out

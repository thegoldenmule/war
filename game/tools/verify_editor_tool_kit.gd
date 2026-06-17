extends SceneTree
## VERIFY editor_tool_kit — the vendored kit's bases + self-update helpers load
## and behave under `godot --headless` (mirrors the kit README's verify command).
##
## The kit's whole point is that a tool's CORE is headless-loadable: ToolService
## carries no Control/EditorInterface refs, EditorToolTheme.build() returns a plain
## Theme Resource, EditorToolPalette is static consts, and UpdateService's version
## helpers (parse_remote_version / is_newer) are static + network-free. This verifier
## proves each of those without an editor or a network call.
##
## Do NOT modify anything under addons/ — this only READS the vendored kit.
##
## Run headless:
##   godot --headless --path game --script res://tools/verify_editor_tool_kit.gd

const KIT := "res://addons/editor_tool_kit/"


func _init() -> void:
	var reason := _run()
	if reason == "":
		print("VERIFY editor_tool_kit: PASS")
	else:
		print("VERIFY editor_tool_kit: FAIL %s" % reason)
	quit()


func _run() -> String:
	# 1. Every base-class script loads headless (a parse/compile error would null these).
	var base_scripts := [
		"tool_service.gd",
		"tool_palette.gd",
		"tool_theme.gd",
		"editor_tool_ui.gd",
		"content_store.gd",
		"bridge_server.gd",
		"editor_tool_plugin.gd",
		"update_service.gd",
	]
	for name in base_scripts:
		var path: String = KIT + name
		if not ResourceLoader.exists(path):
			return "missing kit script %s" % path
		var scr: Variant = load(path)
		if scr == null:
			return "failed to load (parse error?) %s" % path

	# 2. ToolService is instantiable headless and honors its ok()/err()/dirty contract.
	var ToolServiceT: Variant = load(KIT + "tool_service.gd")
	var svc: Variant = ToolServiceT.new()
	if svc == null:
		return "ToolService.new() returned null"
	var ok_res: Variant = svc.ok({"x": 1})
	if typeof(ok_res) != TYPE_DICTIONARY or not bool(ok_res.get("ok", false)) or int(ok_res.get("x", -1)) != 1:
		return "ToolService.ok() contract wrong: %s" % str(ok_res)
	var err_res: Variant = svc.err("boom", 7)
	if typeof(err_res) != TYPE_DICTIONARY or bool(err_res.get("ok", true)) or str(err_res.get("error", "")) != "boom" or int(err_res.get("code", 0)) != 7:
		return "ToolService.err() contract wrong: %s" % str(err_res)
	if svc.is_dirty():
		return "ToolService starts dirty"
	svc.mark_dirty()
	if not svc.is_dirty():
		return "mark_dirty did not set dirty"
	svc.clear_dirty()
	if svc.is_dirty():
		return "clear_dirty did not clear dirty"
	if svc is Node:
		svc.free()

	# 3. EditorToolTheme.build() returns a constructible Theme under headless.
	var ThemeT: Variant = load(KIT + "tool_theme.gd")
	var theme: Variant = ThemeT.build()
	if not (theme is Theme):
		return "EditorToolTheme.build() did not return a Theme (got %s)" % type_string(typeof(theme))

	# 4. EditorToolPalette exposes the documented occult-arcade accent colors.
	var PaletteT: Variant = load(KIT + "tool_palette.gd")
	if not (PaletteT.VIOLET is Color) or PaletteT.VIOLET != Color("b400ff"):
		return "EditorToolPalette.VIOLET is not #b400ff"
	if PaletteT.VIOLET_HOVER != Color("d24bff"):
		return "EditorToolPalette.VIOLET_HOVER is not #d24bff"
	if PaletteT.GREEN_SEL != Color("44ff88"):
		return "EditorToolPalette.GREEN_SEL is not #44ff88"

	# 5. UpdateService static version helpers — parse + compare, no editor/network.
	var UpdateT: Variant = load(KIT + "update_service.gd")
	var sample_cfg := "[plugin]\nname=\"x\"\nversion=\"1.2.3\"\n"
	var parsed: String = UpdateT.parse_remote_version(sample_cfg)
	if parsed != "1.2.3":
		return "parse_remote_version returned %s, expected 1.2.3" % parsed
	if UpdateT.parse_remote_version("garbage not a cfg") != "" and not UpdateT.parse_remote_version("garbage not a cfg").is_empty():
		return "parse_remote_version did not return empty on unparseable text"
	if not UpdateT.is_newer("0.2.0", "0.1.9"):
		return "is_newer(0.2.0, 0.1.9) should be true"
	if not UpdateT.is_newer("1.0.0", "0.9.9"):
		return "is_newer(1.0.0, 0.9.9) should be true"
	if UpdateT.is_newer("0.1.0", "0.1.0"):
		return "is_newer(equal) should be false"
	if UpdateT.is_newer("0.1.0", "0.1.1"):
		return "is_newer(older, newer) should be false"
	# Missing trailing components count as 0: "0.2" > "0.1.9".
	if not UpdateT.is_newer("0.2", "0.1.9"):
		return "is_newer(0.2, 0.1.9) should be true (missing component == 0)"

	# 6. The kit's own plugin.cfg version is parseable by its own helper (dogfood).
	var local_cfg_path := KIT + "plugin.cfg"
	if not FileAccess.file_exists(local_cfg_path):
		return "kit plugin.cfg missing at %s" % local_cfg_path
	var f := FileAccess.open(local_cfg_path, FileAccess.READ)
	var local_ver: String = UpdateT.parse_remote_version(f.get_as_text())
	f.close()
	if local_ver.is_empty():
		return "could not parse the kit's own plugin.cfg version"

	return ""

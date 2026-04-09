extends Node

const MOD_DIR := "mods"
const TMP_DIR := "user://vmz_mount_cache"
const CONFLICT_REPORT_PATH := "user://modloader_conflicts.txt"
const UI_CONFIG_PATH := "user://mod_config.cfg"
const MODWORKSHOP_VERSIONS_URL := "https://api.modworkshop.net/mods/versions"
const MODWORKSHOP_DOWNLOAD_URL_TEMPLATE := "https://api.modworkshop.net/mods/%s/files/latest/download"
const MODWORKSHOP_MODS_URL := "https://api.modworkshop.net/games/864/mods"
const BROWSE_CACHE_PATH := "user://modloader_browse_cache.json"
const BROWSE_CACHE_MAX_AGE := 3600  # 1 hour in seconds

const VANILLA_SCAN_DIRS: Array[String] = ["res://Scripts", "res://Scenes"]
const TRACKED_EXTENSIONS: Array[String] = ["gd", "tscn", "tres", "gdns", "gdnlib", "scn"]
const LIFECYCLE_METHODS: Array[String] = [
    "_ready",
    "_process",
    "_physics_process",
    "_input",
    "_unhandled_input",
    "_unhandled_key_input",
]

# ─── State ────────────────────────────────────────────────────────────────────

var _vanilla_paths: Dictionary = { }
var _database_path: String = ""
var _database_replaced_by: String = ""
var override_registry: Dictionary = { }
var _mod_script_analysis: Dictionary = { }
var _archive_file_sets: Dictionary = { }
var _report_lines: Array[String] = []
var pending_autoloads: Array[Dictionary] = []
var loaded_mod_ids: Dictionary = { }
var registered_autoload_names: Dictionary = { }
var _ui_mod_entries: Array[Dictionary] = []
var _re_take_over: RegEx
var _re_extends: RegEx
var _re_func: RegEx

# Browse tab state
var _browse_all_mods: Array[Dictionary] = []
var _browse_installed_ids: Dictionary = { }
var _browse_active_tags: Dictionary = { }
var _browse_current_page: int = 1
var _browse_list: VBoxContainer
var _browse_search: LineEdit
var _browse_sort: OptionButton
var _browse_page_bar: HBoxContainer
var _browse_page_lbl: Label
var _browse_prev_btn: Button
var _browse_next_btn: Button
var _browse_load_btn: Button
var _browse_tag_flow: HBoxContainer
var _installed_list: VBoxContainer

# ─── Entry point ──────────────────────────────────────────────────────────────


func _ready() -> void:
    call_deferred("_deferred_init")


func _deferred_init() -> void:
    _compile_regex()
    _ui_mod_entries = _collect_mod_metadata()
    _load_ui_config()
    _clean_vmz_cache()
    _load_all_mods()
    for entry in pending_autoloads:
        _instantiate_autoload(entry["mod_name"], entry["name"], entry["path"])
    _print_conflict_summary()
    _write_conflict_report()
    _show_menu_button()
    _check_updates_background()


func _clean_vmz_cache() -> void:
    var cache_dir: String = ProjectSettings.globalize_path(TMP_DIR)
    var dir: DirAccess = DirAccess.open(cache_dir)
    if dir == null:
        return
    dir.list_dir_begin()
    while true:
        var entry: String = dir.get_next()
        if entry == "":
            break
        if not dir.current_is_dir():
            DirAccess.remove_absolute(cache_dir.path_join(entry))
    dir.list_dir_end()


func _compile_regex() -> void:
    _re_take_over = RegEx.new()
    _re_take_over.compile('take_over_path\\s*\\(\\s*"(res://[^"]+)"')
    _re_extends = RegEx.new()
    _re_extends.compile('(?m)^extends\\s+"(res://[^"]+)"')
    _re_func = RegEx.new()
    _re_func.compile('(?m)^func\\s+(\\w+)\\s*\\(')

# ─── Mod metadata collection ─────────────────────────────────────────────────


func _collect_mod_metadata() -> Array[Dictionary]:
    var entries: Array[Dictionary] = []
    var mods_dir: String = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
    DirAccess.make_dir_recursive_absolute(mods_dir)
    var dir: DirAccess = DirAccess.open(mods_dir)
    if dir == null:
        return entries
    var seen: Dictionary = { }
    dir.list_dir_begin()
    while true:
        var file_name: String = dir.get_next()
        if file_name == "":
            break
        if dir.current_is_dir():
            continue
        var ext: String = file_name.get_extension().to_lower()
        if ext not in ["vmz", "zip", "pck"]:
            continue
        if seen.has(file_name):
            continue
        seen[file_name] = true
        var full_path: String = mods_dir.path_join(file_name)
        var cfg: ConfigFile = _read_mod_config(full_path) if ext != "pck" else null
        var mod_name: String = file_name
        var mod_id: String = file_name
        var priority: int = 0
        if cfg:
            mod_name = str(cfg.get_value("mod", "name", file_name))
            mod_id = str(cfg.get_value("mod", "id", file_name))
            if cfg.has_section_key("mod", "priority"):
                priority = int(str(cfg.get_value("mod", "priority")))
        entries.append(
            {
                "file_name": file_name,
                "full_path": full_path,
                "ext": ext,
                "mod_name": mod_name,
                "mod_id": mod_id,
                "priority": priority,
                "enabled": true,
                "cfg": cfg,
                "has_mod_txt": cfg != null,
            },
        )
    dir.list_dir_end()
    return entries

# ─── Config persistence ───────────────────────────────────────────────────────


func _load_ui_config() -> void:
    var cfg: ConfigFile = ConfigFile.new()
    if cfg.load(UI_CONFIG_PATH) != OK:
        return
    for entry in _ui_mod_entries:
        var fn: String = entry["file_name"]
        entry["enabled"] = bool(cfg.get_value("enabled", fn, true))
        if cfg.has_section_key("priority", fn):
            entry["priority"] = int(str(cfg.get_value("priority", fn)))

# ─── Main menu button ────────────────────────────────────────────────────────


func _show_menu_button() -> void:
    var failed_count: int = 0
    var critical_count: int = 0
    var conflict_count: int = 0
    for line in _report_lines:
        if "[Critical] Failed to mount:" in line:
            failed_count += 1
    for res_path: String in override_registry:
        var claims: Array = override_registry[res_path]
        if claims.size() > 1:
            conflict_count += 1
            if _is_dangerous_path(res_path) or res_path == _database_path:
                critical_count += 1

    var btn_text: String = "Metro Mod Loader"
    var warnings: Array[String] = []
    if failed_count > 0:
        warnings.append(str(failed_count) + " failed")
    if critical_count > 0:
        warnings.append(str(critical_count) + " critical")
    elif conflict_count > 0:
        warnings.append(str(conflict_count) + " conflicts")
    if not warnings.is_empty():
        btn_text += " — " + ", ".join(warnings)

    var canvas: CanvasLayer = CanvasLayer.new()
    canvas.name = "ModLoaderUI"
    canvas.layer = 100
    add_child(canvas)

    var btn: Button = Button.new()
    btn.text = btn_text
    btn.anchor_left = 0.0
    btn.anchor_top = 0.0
    btn.offset_left = 10
    btn.offset_top = 10

    var btn_style: StyleBoxFlat = StyleBoxFlat.new()
    btn_style.bg_color = Color(0.0, 0.0, 0.0, 0.6)
    btn_style.border_color = Color(0.25, 0.25, 0.25)
    btn_style.border_width_top = 1
    btn_style.border_width_bottom = 1
    btn_style.border_width_left = 1
    btn_style.border_width_right = 1
    btn_style.corner_radius_top_left = 3
    btn_style.corner_radius_top_right = 3
    btn_style.corner_radius_bottom_left = 3
    btn_style.corner_radius_bottom_right = 3
    btn_style.content_margin_left = 8
    btn_style.content_margin_right = 8
    btn_style.content_margin_top = 4
    btn_style.content_margin_bottom = 4
    btn.add_theme_stylebox_override("normal", btn_style)
    var btn_hover := btn_style.duplicate()
    btn_hover.bg_color = Color(0.08, 0.08, 0.08, 0.8)
    btn_hover.border_color = Color(0.4, 0.4, 0.4)
    btn.add_theme_stylebox_override("hover", btn_hover)
    var btn_pressed := btn_style.duplicate()
    btn_pressed.bg_color = Color(0.03, 0.03, 0.03, 0.8)
    btn.add_theme_stylebox_override("pressed", btn_pressed)
    btn.add_theme_font_size_override("font_size", 12)
    btn.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
    btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0))

    var root: Control = Control.new()
    root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    root.mouse_filter = Control.MOUSE_FILTER_IGNORE
    canvas.add_child(root)
    root.add_child(btn)

    # Detail panel
    var panel: PanelContainer = PanelContainer.new()
    panel.anchor_left = 0.0
    panel.anchor_top = 0.0
    panel.offset_left = 10
    panel.offset_top = 44
    panel.offset_right = 420
    panel.offset_bottom = 400
    panel.visible = false

    var panel_style: StyleBoxFlat = StyleBoxFlat.new()
    panel_style.bg_color = Color(0.0, 0.0, 0.0, 0.85)
    panel_style.border_color = Color(0.25, 0.25, 0.25)
    panel_style.border_width_top = 1
    panel_style.border_width_bottom = 1
    panel_style.border_width_left = 1
    panel_style.border_width_right = 1
    panel_style.corner_radius_top_left = 4
    panel_style.corner_radius_top_right = 4
    panel_style.corner_radius_bottom_left = 4
    panel_style.corner_radius_bottom_right = 4
    panel_style.content_margin_left = 6
    panel_style.content_margin_right = 6
    panel_style.content_margin_top = 4
    panel_style.content_margin_bottom = 4
    panel.add_theme_stylebox_override("panel", panel_style)

    var tabs: TabContainer = TabContainer.new()
    tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
    tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    var tab_s: StyleBoxFlat = StyleBoxFlat.new()
    tab_s.bg_color = Color(0.06, 0.06, 0.06)
    tab_s.border_color = Color(0.25, 0.25, 0.25)
    tab_s.border_width_top = 1
    tab_s.border_width_left = 1
    tab_s.border_width_right = 1
    tab_s.content_margin_left = 10
    tab_s.content_margin_right = 10
    tab_s.content_margin_top = 4
    tab_s.content_margin_bottom = 4
    var tab_u := tab_s.duplicate()
    tab_u.bg_color = Color(0.02, 0.02, 0.02)
    tab_u.border_color = Color(0.12, 0.12, 0.12)
    tab_u.border_width_bottom = 1
    var tab_panel: StyleBoxFlat = StyleBoxFlat.new()
    tab_panel.bg_color = Color(0.03, 0.03, 0.03)
    tab_panel.content_margin_left = 8
    tab_panel.content_margin_right = 8
    tab_panel.content_margin_top = 6
    tab_panel.content_margin_bottom = 6
    tabs.add_theme_stylebox_override("tab_selected", tab_s)
    tabs.add_theme_stylebox_override("tab_unselected", tab_u)
    tabs.add_theme_stylebox_override("tab_hovered", tab_u.duplicate())
    tabs.add_theme_stylebox_override("panel", tab_panel)
    tabs.add_theme_color_override("font_selected_color", Color(0.90, 0.90, 0.90))
    tabs.add_theme_color_override("font_unselected_color", Color(0.45, 0.45, 0.45))
    tabs.add_theme_color_override("font_hovered_color", Color(0.75, 0.75, 0.75))
    tabs.add_theme_font_size_override("font_size", 12)
    panel.add_child(tabs)

    var label: RichTextLabel = RichTextLabel.new()
    label.name = "Info"
    label.bbcode_enabled = true
    label.text = _build_detail_bbcode()
    label.scroll_active = true
    label.size_flags_vertical = Control.SIZE_EXPAND_FILL
    label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    label.add_theme_font_size_override("normal_font_size", 13)
    tabs.add_child(label)
    canvas.set_meta("detail_label", label)

    var updates_tab: Control = _build_updates_tab()
    updates_tab.name = "Installed"
    tabs.add_child(updates_tab)

    var browse_tab: Control = _build_browse_tab()
    browse_tab.name = "Browse"
    tabs.add_child(browse_tab)

    root.add_child(panel)
    btn.pressed.connect(func(): panel.visible = not panel.visible)

    get_tree().node_added.connect(func(node: Node):
        if node == get_tree().current_scene and is_instance_valid(canvas):
            canvas.queue_free()
    )


func _build_detail_bbcode() -> String:
    var lines: Array[String] = []
    var enabled_count: int = 0
    for entry in _ui_mod_entries:
        if entry["enabled"]:
            enabled_count += 1
    if enabled_count == 0:
        lines.append("[color=#888888]No mods loaded.[/color]")
    else:
        lines.append("[color=#94d264]" + str(enabled_count) + " mod(s) loaded[/color]")
        for entry in _ui_mod_entries:
            if entry["enabled"]:
                var ver: String = ""
                if entry["cfg"] != null:
                    ver = str((entry["cfg"] as ConfigFile).get_value("mod", "version", ""))
                var tag: String = "  [color=#666666]v" + ver + "[/color]" if ver != "" else ""
                lines.append("  [color=#bbbbbb]" + entry["mod_name"] + "[/color]" + tag)

    var conflict_count: int = 0
    var critical_count: int = 0
    for res_path: String in override_registry:
        var claims: Array = override_registry[res_path]
        if claims.size() > 1:
            conflict_count += 1
            if _is_dangerous_path(res_path) or res_path == _database_path:
                critical_count += 1
    if conflict_count > 0:
        lines.append("")
        if critical_count > 0:
            lines.append("[color=#d94444]" + str(critical_count) + " critical conflict(s)[/color]")
        lines.append("[color=#d4b330]" + str(conflict_count) + " resource conflict(s)[/color]")

    var failed: Array[String] = []
    for line in _report_lines:
        if "[Critical] Failed to mount:" in line:
            failed.append(line.split("Failed to mount: ")[1])
    if not failed.is_empty():
        lines.append("")
        for f in failed:
            lines.append("[color=#d94444]Failed to mount: " + f + "[/color]")

    lines.append("")
    lines.append("[color=#555555]Full report: " + CONFLICT_REPORT_PATH + "[/color]")
    return "\n".join(lines)


func _append_detail_bbcode(bbcode_text: String) -> void:
    var canvas: Node = get_node_or_null("ModLoaderUI")
    if canvas == null:
        return
    var label: RichTextLabel = canvas.get_meta("detail_label", null)
    if label != null and is_instance_valid(label):
        label.text += "\n" + bbcode_text

# ─── Updates tab ──────────────────────────────────────────────────────────────


func _build_updates_tab() -> Control:
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 4)

    var toolbar: HBoxContainer = HBoxContainer.new()
    toolbar.add_theme_constant_override("separation", 8)
    vbox.add_child(toolbar)

    var spacer: Control = Control.new()
    spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    toolbar.add_child(spacer)

    var check_btn: Button = Button.new()
    check_btn.text = "Check for Updates"
    check_btn.add_theme_font_size_override("font_size", 12)
    toolbar.add_child(check_btn)

    vbox.add_child(HSeparator.new())

    var scroll: ScrollContainer = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vbox.add_child(scroll)

    var list: VBoxContainer = VBoxContainer.new()
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list.add_theme_constant_override("separation", 2)
    scroll.add_child(list)
    _installed_list = list

    var status_info: Dictionary = { }

    for entry in _ui_mod_entries:
        var cfg: ConfigFile = entry["cfg"]
        if cfg == null:
            continue
        var version: String = str(cfg.get_value("mod", "version", ""))
        var mw_id: int = 0
        if cfg.has_section_key("updates", "modworkshop"):
            mw_id = int(str(cfg.get_value("updates", "modworkshop", "")))

        var row: HBoxContainer = HBoxContainer.new()
        row.add_theme_constant_override("separation", 6)
        list.add_child(row)

        var info_col: VBoxContainer = VBoxContainer.new()
        info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        row.add_child(info_col)

        var name_lbl: Label = Label.new()
        name_lbl.text = entry["mod_name"]
        name_lbl.clip_text = true
        name_lbl.add_theme_font_size_override("font_size", 12)
        info_col.add_child(name_lbl)

        var sub_parts: Array[String] = []
        if version != "":
            sub_parts.append("v" + version)
        sub_parts.append(entry["file_name"])
        var sub_lbl: Label = Label.new()
        sub_lbl.text = "  •  ".join(sub_parts)
        sub_lbl.add_theme_font_size_override("font_size", 10)
        sub_lbl.modulate = Color(0.5, 0.5, 0.5)
        sub_lbl.clip_text = true
        info_col.add_child(sub_lbl)

        var status_lbl: Label = Label.new()
        status_lbl.custom_minimum_size.x = 80
        status_lbl.text = "—" if mw_id > 0 and version != "" else "no update info"
        status_lbl.add_theme_font_size_override("font_size", 11)
        status_lbl.modulate = Color(0.5, 0.5, 0.5)
        row.add_child(status_lbl)

        var ver_lbl: Label = Label.new()
        ver_lbl.visible = false
        row.add_child(ver_lbl)

        var dl_btn: Button = Button.new()
        dl_btn.text = "Update"
        dl_btn.custom_minimum_size.x = 60
        dl_btn.add_theme_font_size_override("font_size", 11)
        dl_btn.modulate.a = 0.0
        dl_btn.disabled = true
        dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
        row.add_child(dl_btn)

        var rm_btn: Button = Button.new()
        rm_btn.text = "Uninstall"
        rm_btn.custom_minimum_size.x = 70
        rm_btn.add_theme_font_size_override("font_size", 11)
        rm_btn.modulate = Color(0.8, 0.5, 0.5)
        row.add_child(rm_btn)
        var ep: String = entry["full_path"]
        rm_btn.pressed.connect(_on_installed_uninstall.bind(rm_btn, ep))

        list.add_child(HSeparator.new())

        if mw_id > 0 and version != "":
            status_info[entry["file_name"]] = {
                "label": status_lbl,
                "ver_lbl": ver_lbl,
                "version": version,
                "mw_id": mw_id,
                "dl_btn": dl_btn,
                "full_path": entry["full_path"],
                "mod_name": entry["mod_name"],
            }

    if list.get_child_count() == 0:
        var lbl: Label = Label.new()
        lbl.text = "No mods with update info."
        lbl.add_theme_font_size_override("font_size", 12)
        lbl.modulate = Color(0.5, 0.5, 0.5)
        list.add_child(lbl)

    check_btn.pressed.connect(
        func():
            check_btn.disabled = true
            check_btn.text = "Checking..."
            for fn in status_info:
                var si: Dictionary = status_info[fn]
                (si["label"] as Label).text = "checking..."
                (si["label"] as Label).modulate = Color(1.0, 1.0, 1.0)
                var b: Button = si["dl_btn"]
                b.modulate.a = 0.0
                b.disabled = true
                b.mouse_filter = Control.MOUSE_FILTER_IGNORE
                b.text = "Download"
            await _check_updates_for_ui(status_info, check_btn)
            check_btn.disabled = false
            check_btn.text = "Check for Updates"
    )

    return vbox


func _check_updates_for_ui(status_info: Dictionary, check_btn: Button) -> void:
    var ids: Array[int] = []
    for fn in status_info:
        ids.append(status_info[fn]["mw_id"])
    if ids.is_empty():
        return

    var latest: Dictionary = await _fetch_latest_modworkshop_versions(ids)

    for fn: String in status_info:
        var si: Dictionary = status_info[fn]
        var lbl: Label = si["label"]
        var dl_btn: Button = si["dl_btn"]
        var latest_v: Variant = latest.get(str(si["mw_id"]), null)
        if latest_v == null:
            lbl.text = "no data"
            lbl.modulate = Color(0.5, 0.5, 0.5)
            continue

        var cmp: int = _compare_versions(si["version"], str(latest_v))
        if cmp >= 0:
            lbl.text = "up to date"
            lbl.modulate = Color(0.5, 0.8, 0.5)
        else:
            lbl.text = "v" + str(latest_v)
            lbl.modulate = Color(0.9, 0.8, 0.3)
            dl_btn.modulate.a = 1.0
            dl_btn.disabled = false
            dl_btn.mouse_filter = Control.MOUSE_FILTER_STOP
            var full_path: String = si["full_path"]
            var mw_id: int = si["mw_id"]
            var mod_name: String = si["mod_name"]
            var new_ver: String = str(latest_v)
            for c in dl_btn.pressed.get_connections():
                dl_btn.pressed.disconnect(c["callable"])
            dl_btn.pressed.connect(
                func():
                    dl_btn.disabled = true
                    dl_btn.text = "..."
                    lbl.text = "downloading..."
                    check_btn.disabled = true
                    var ok: bool = await _download_and_replace_mod(full_path, mw_id)
                    check_btn.disabled = false
                    if ok:
                        lbl.text = "updated!"
                        lbl.modulate = Color(0.5, 0.8, 0.5)
                        dl_btn.modulate.a = 0.0
                        dl_btn.disabled = true
                        dl_btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
                        si["version"] = new_ver
                        (si["ver_lbl"] as Label).text = "v" + new_ver
                    else:
                        lbl.text = "failed"
                        lbl.modulate = Color(1.0, 0.4, 0.4)
                        dl_btn.disabled = false
                        dl_btn.text = "Retry"
            )


func _download_and_replace_mod(target_path: String, modworkshop_id: int) -> bool:
    var temp_path: String = target_path + ".download"
    var backup_path: String = target_path + ".bak"
    if FileAccess.file_exists(temp_path):
        DirAccess.remove_absolute(temp_path)
    if FileAccess.file_exists(backup_path):
        DirAccess.remove_absolute(backup_path)

    var req: HTTPRequest = HTTPRequest.new()
    req.timeout = 30.0
    req.download_file = temp_path
    add_child(req)
    var err: Error = req.request(MODWORKSHOP_DOWNLOAD_URL_TEMPLATE % str(modworkshop_id))
    if err != OK:
        req.queue_free()
        return false
    var res: Array = await req.request_completed
    if not is_instance_valid(req):
        return false
    req.queue_free()

    if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
        if FileAccess.file_exists(temp_path):
            DirAccess.remove_absolute(temp_path)
        return false
    if not FileAccess.file_exists(temp_path):
        return false

    if _read_mod_config(temp_path) == null:
        DirAccess.remove_absolute(temp_path)
        return false

    var dir_access: DirAccess = DirAccess.open(target_path.get_base_dir())
    if dir_access == null:
        DirAccess.remove_absolute(temp_path)
        return false

    if FileAccess.file_exists(target_path):
        if dir_access.rename(target_path.get_file(), backup_path.get_file()) != OK:
            DirAccess.remove_absolute(temp_path)
            return false

    if dir_access.rename(temp_path.get_file(), target_path.get_file()) != OK:
        if FileAccess.file_exists(backup_path):
            dir_access.rename(backup_path.get_file(), target_path.get_file())
        DirAccess.remove_absolute(temp_path)
        return false

    if FileAccess.file_exists(backup_path):
        DirAccess.remove_absolute(backup_path)
    return true

# ─── Browse tab ───────────────────────────────────────────────────────────────


func _build_browse_tab() -> Control:
    var vbox: VBoxContainer = VBoxContainer.new()
    vbox.add_theme_constant_override("separation", 4)

    var toolbar: HBoxContainer = HBoxContainer.new()
    toolbar.add_theme_constant_override("separation", 6)
    vbox.add_child(toolbar)

    var search_edit: LineEdit = LineEdit.new()
    search_edit.placeholder_text = "Search mods..."
    search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    search_edit.add_theme_font_size_override("font_size", 12)
    toolbar.add_child(search_edit)

    var sort_option: OptionButton = OptionButton.new()
    sort_option.add_item("Popular", 0)
    sort_option.add_item("Downloads", 1)
    sort_option.add_item("Newest", 2)
    sort_option.add_item("Name", 3)
    sort_option.add_theme_font_size_override("font_size", 12)
    toolbar.add_child(sort_option)

    var load_btn: Button = Button.new()
    load_btn.text = "Load"
    load_btn.add_theme_font_size_override("font_size", 12)
    toolbar.add_child(load_btn)

    vbox.add_child(HSeparator.new())

    var tag_flow: HBoxContainer = HBoxContainer.new()
    tag_flow.add_theme_constant_override("separation", 4)
    tag_flow.visible = false
    vbox.add_child(tag_flow)

    var scroll: ScrollContainer = ScrollContainer.new()
    scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
    vbox.add_child(scroll)

    var list_margin: MarginContainer = MarginContainer.new()
    list_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list_margin.add_theme_constant_override("margin_right", 14)
    scroll.add_child(list_margin)

    var list: VBoxContainer = VBoxContainer.new()
    list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    list.add_theme_constant_override("separation", 2)
    list_margin.add_child(list)

    var status_lbl: Label = Label.new()
    status_lbl.text = "Click 'Load' to browse available mods."
    status_lbl.add_theme_font_size_override("font_size", 12)
    status_lbl.modulate = Color(0.5, 0.5, 0.5)
    list.add_child(status_lbl)

    var page_bar: HBoxContainer = HBoxContainer.new()
    page_bar.add_theme_constant_override("separation", 6)
    page_bar.visible = false
    vbox.add_child(page_bar)

    var prev_btn: Button = Button.new()
    prev_btn.text = "< Prev"
    prev_btn.add_theme_font_size_override("font_size", 11)
    page_bar.add_child(prev_btn)

    var page_lbl: Label = Label.new()
    page_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    page_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    page_lbl.add_theme_font_size_override("font_size", 11)
    page_lbl.modulate = Color(0.6, 0.6, 0.6)
    page_bar.add_child(page_lbl)

    var next_btn: Button = Button.new()
    next_btn.text = "Next >"
    next_btn.add_theme_font_size_override("font_size", 11)
    page_bar.add_child(next_btn)

    # Store refs in member vars
    _browse_list = list
    _browse_search = search_edit
    _browse_sort = sort_option
    _browse_page_bar = page_bar
    _browse_page_lbl = page_lbl
    _browse_prev_btn = prev_btn
    _browse_next_btn = next_btn
    _browse_load_btn = load_btn
    _browse_tag_flow = tag_flow

    for entry in _ui_mod_entries:
        if entry["cfg"] != null:
            var mw_str: String = str((entry["cfg"] as ConfigFile).get_value("updates", "modworkshop", ""))
            if mw_str != "" and mw_str != "0":
                _browse_installed_ids[int(mw_str)] = entry["full_path"]

    load_btn.pressed.connect(_on_browse_load)
    search_edit.text_submitted.connect(_on_browse_filter_changed)
    search_edit.text_changed.connect(_on_browse_filter_changed)
    sort_option.item_selected.connect(_on_browse_sort_changed)
    prev_btn.pressed.connect(_on_browse_prev)
    next_btn.pressed.connect(_on_browse_next)

    return vbox


func _on_browse_load() -> void:
    # Try cache first
    if _browse_all_mods.is_empty() and _load_browse_cache():
        _browse_load_btn.text = "Refresh"
        _browse_current_page = 1
        _browse_render_list()
        # Fetch tags
        if _browse_tag_flow.get_child_count() == 0:
            await _fetch_and_populate_tags()
        return
    # No cache or stale — fetch fresh
    await _browse_fetch_fresh()


func _browse_fetch_fresh() -> void:
    _browse_load_btn.disabled = true
    _browse_load_btn.text = "Loading..."
    for child in _browse_list.get_children():
        child.queue_free()
    var loading: Label = Label.new()
    loading.text = "Loading..."
    loading.add_theme_font_size_override("font_size", 12)
    loading.modulate = Color(0.6, 0.6, 0.6)
    _browse_list.add_child(loading)

    _browse_all_mods.clear()
    var page: int = 1
    while page <= 10:
        var result: Dictionary = await _fetch_browse_page(page)
        if result.is_empty():
            break
        if page >= result["last_page"]:
            break
        page += 1

    _save_browse_cache()

    # Fetch tags
    if _browse_tag_flow.get_child_count() == 0:
        await _fetch_and_populate_tags()

    _browse_load_btn.disabled = false
    _browse_load_btn.text = "Refresh"
    _browse_current_page = 1
    _browse_render_list()


func _load_browse_cache() -> bool:
    if not FileAccess.file_exists(BROWSE_CACHE_PATH):
        return false
    var age: int = int(Time.get_unix_time_from_system()) - FileAccess.get_modified_time(BROWSE_CACHE_PATH)
    if age > BROWSE_CACHE_MAX_AGE:
        return false
    var f: FileAccess = FileAccess.open(BROWSE_CACHE_PATH, FileAccess.READ)
    if f == null:
        return false
    var text: String = f.get_as_text()
    f.close()
    var parsed: Variant = JSON.parse_string(text)
    if not (parsed is Array):
        return false
    _browse_all_mods.clear()
    for m in parsed:
        if m is Dictionary:
            _browse_all_mods.append(m)
    return not _browse_all_mods.is_empty()


func _save_browse_cache() -> void:
    if _browse_all_mods.is_empty():
        return
    var f: FileAccess = FileAccess.open(BROWSE_CACHE_PATH, FileAccess.WRITE)
    if f == null:
        return
    f.store_string(JSON.stringify(_browse_all_mods))
    f.close()


func _on_browse_filter_changed(_text: String) -> void:
    _browse_current_page = 1
    _browse_render_list()


func _on_browse_sort_changed(_idx: int) -> void:
    _browse_current_page = 1
    _browse_render_list()


func _on_browse_prev() -> void:
    if _browse_current_page > 1:
        _browse_current_page -= 1
        _browse_render_list()


func _on_browse_next() -> void:
    _browse_current_page += 1
    _browse_render_list()


func _fetch_browse_page(page: int) -> Dictionary:
    var url: String = MODWORKSHOP_MODS_URL + "?limit=50&page=" + str(page)
    var req: HTTPRequest = HTTPRequest.new()
    req.timeout = 15.0
    add_child(req)
    var err: Error = req.request(url)
    if err != OK:
        req.queue_free()
        return {}
    var res: Array = await req.request_completed
    if not is_instance_valid(req):
        return {}
    req.queue_free()
    if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
        return {}
    var parsed: Variant = JSON.parse_string(res[3].get_string_from_utf8())
    if parsed == null or not (parsed is Dictionary):
        return {}
    var data: Array = parsed.get("data", [])
    for m in data:
        _browse_all_mods.append(m)
    var meta: Dictionary = parsed.get("meta", {})
    return {"last_page": int(meta.get("last_page", 1))}


func _browse_render_list() -> void:
    for child in _browse_list.get_children():
        child.queue_free()

    var query: String = _browse_search.text.strip_edges().to_lower()
    var has_tag_filter: bool = not _browse_active_tags.is_empty()
    var filtered: Array[Dictionary] = []
    for m in _browse_all_mods:
        if has_tag_filter:
            var mod_tags: Array = m.get("tags", [])
            var matches_tag: bool = false
            for tag in mod_tags:
                if tag is Dictionary and _browse_active_tags.has(int(tag.get("id", 0))):
                    matches_tag = true
                    break
            if not matches_tag:
                continue
        if query != "":
            var name_str: String = str(m.get("name", "")).to_lower()
            var desc_str: String = str(m.get("short_desc", "")).to_lower()
            var author_str: String = ""
            var ud: Variant = m.get("user", null)
            if ud is Dictionary:
                author_str = str(ud.get("name", "")).to_lower()
            if query not in name_str and query not in desc_str and query not in author_str:
                continue
        filtered.append(m)

    var sort_idx: int = _browse_sort.selected
    if sort_idx == 0:
        filtered.sort_custom(func(a, b): return float(a.get("weekly_score", 0)) > float(b.get("weekly_score", 0)))
    elif sort_idx == 1:
        filtered.sort_custom(func(a, b): return int(a.get("downloads", 0)) > int(b.get("downloads", 0)))
    elif sort_idx == 2:
        filtered.sort_custom(func(a, b): return str(a.get("published_at", "")) > str(b.get("published_at", "")))
    elif sort_idx == 3:
        filtered.sort_custom(func(a, b): return str(a.get("name", "")).to_lower() < str(b.get("name", "")).to_lower())

    var per_page: int = 15
    var total: int = filtered.size()
    var total_pages: int = max(1, ceili(float(total) / per_page))
    _browse_current_page = clamp(_browse_current_page, 1, total_pages)
    var start: int = (_browse_current_page - 1) * per_page
    var end: int = min(start + per_page, total)

    _browse_page_bar.visible = total_pages > 1
    _browse_page_lbl.text = "Page " + str(_browse_current_page) + " / " + str(total_pages) + "  (" + str(total) + " mods)"
    _browse_prev_btn.disabled = _browse_current_page <= 1
    _browse_next_btn.disabled = _browse_current_page >= total_pages

    if total == 0:
        var empty: Label = Label.new()
        empty.text = "No mods found."
        empty.add_theme_font_size_override("font_size", 12)
        empty.modulate = Color(0.5, 0.5, 0.5)
        _browse_list.add_child(empty)
        return

    for i in range(start, end):
        _browse_add_mod_row(filtered[i])


func _browse_add_mod_row(mod_dict: Dictionary) -> void:
    var row: HBoxContainer = HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)
    _browse_list.add_child(row)

    var info_col: VBoxContainer = VBoxContainer.new()
    info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(info_col)

    var name_lbl: Label = Label.new()
    name_lbl.text = str(mod_dict.get("name", "???"))
    name_lbl.clip_text = true
    name_lbl.add_theme_font_size_override("font_size", 12)
    info_col.add_child(name_lbl)

    var author_name: String = ""
    var user_data: Variant = mod_dict.get("user", null)
    if user_data is Dictionary:
        author_name = str(user_data.get("name", ""))
    var sub_text: String = ""
    if author_name != "":
        sub_text += "by " + author_name
    var dl_count: int = int(mod_dict.get("downloads", 0))
    if sub_text != "":
        sub_text += "  •  "
    sub_text += str(dl_count) + " downloads"
    var ver: String = str(mod_dict.get("version", ""))
    if ver != "":
        sub_text += "  •  v" + str(ver)

    var sub_lbl: Label = Label.new()
    sub_lbl.text = sub_text
    sub_lbl.add_theme_font_size_override("font_size", 10)
    sub_lbl.modulate = Color(0.5, 0.5, 0.5)
    sub_lbl.clip_text = true
    info_col.add_child(sub_lbl)

    var short_desc: String = str(mod_dict.get("short_desc", "")).strip_edges()
    var desc_lbl: Label = Label.new()
    if short_desc != "":
        desc_lbl.text = short_desc.replace("\n", " ")
    else:
        desc_lbl.text = "No description available"
    desc_lbl.add_theme_font_size_override("font_size", 10)
    desc_lbl.modulate = Color(0.45, 0.45, 0.45)
    desc_lbl.clip_text = true
    desc_lbl.max_lines_visible = 1
    info_col.add_child(desc_lbl)

    var mod_id: int = int(mod_dict.get("id", 0))
    var has_download: bool = mod_dict.get("has_download", false)

    if _browse_installed_ids.has(mod_id):
        var uninstall_btn: Button = Button.new()
        uninstall_btn.text = "Uninstall"
        uninstall_btn.custom_minimum_size.x = 70
        uninstall_btn.add_theme_font_size_override("font_size", 11)
        uninstall_btn.modulate = Color(0.8, 0.5, 0.5)
        row.add_child(uninstall_btn)
        var mid: int = mod_id
        uninstall_btn.pressed.connect(_on_browse_uninstall.bind(uninstall_btn, mid))
    elif has_download:
        var install_btn: Button = Button.new()
        install_btn.text = "Install"
        install_btn.custom_minimum_size.x = 70
        install_btn.add_theme_font_size_override("font_size", 11)
        row.add_child(install_btn)
        var mid: int = mod_id
        var mname: String = str(mod_dict.get("name", "mod_" + str(mod_id)))
        install_btn.pressed.connect(_on_browse_install.bind(install_btn, mid, mname))
    else:
        var no_dl: Label = Label.new()
        no_dl.text = "No file"
        no_dl.add_theme_font_size_override("font_size", 11)
        no_dl.modulate = Color(0.4, 0.4, 0.4)
        no_dl.custom_minimum_size.x = 70
        row.add_child(no_dl)

    _browse_list.add_child(HSeparator.new())


func _on_browse_install(btn: Button, mod_id: int, mod_name: String) -> void:
    btn.disabled = true
    btn.text = "..."
    var result: Dictionary = await _install_mod_from_browse(mod_id, mod_name)
    if not result.get("ok", false):
        btn.text = "Failed"
        btn.modulate = Color(1.0, 0.4, 0.4)
        btn.disabled = false
        return

    var install_path: String = result.get("path", "")
    _browse_installed_ids[mod_id] = install_path
    var warnings: Array[String] = result.get("warnings", [])
    if warnings.is_empty():
        btn.text = "Done"
        btn.modulate = Color(0.5, 0.8, 0.5)
    else:
        btn.text = "Done"
        btn.modulate = Color(0.9, 0.8, 0.3)
        var row: Node = btn.get_parent()
        var idx: int = row.get_index()
        for w in warnings:
            var warn_lbl: Label = Label.new()
            warn_lbl.text = "  ⚠ " + w
            warn_lbl.add_theme_font_size_override("font_size", 10)
            warn_lbl.modulate = Color(0.9, 0.7, 0.2)
            warn_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
            _browse_list.add_child(warn_lbl)
            _browse_list.move_child(warn_lbl, idx + 1)

    # Add to Installed tab
    _add_installed_row(mod_name, install_path)


func _add_installed_row(mod_name: String, file_path: String) -> void:
    if _installed_list == null or not is_instance_valid(_installed_list):
        return

    var row: HBoxContainer = HBoxContainer.new()
    row.add_theme_constant_override("separation", 6)

    var info_col: VBoxContainer = VBoxContainer.new()
    info_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
    row.add_child(info_col)

    var name_lbl: Label = Label.new()
    name_lbl.text = mod_name
    name_lbl.clip_text = true
    name_lbl.add_theme_font_size_override("font_size", 12)
    info_col.add_child(name_lbl)

    var sub_lbl: Label = Label.new()
    sub_lbl.text = file_path.get_file()
    sub_lbl.add_theme_font_size_override("font_size", 10)
    sub_lbl.modulate = Color(0.5, 0.5, 0.5)
    sub_lbl.clip_text = true
    info_col.add_child(sub_lbl)

    var status_lbl: Label = Label.new()
    status_lbl.text = "Restart to load"
    status_lbl.custom_minimum_size.x = 80
    status_lbl.add_theme_font_size_override("font_size", 11)
    status_lbl.modulate = Color(0.9, 0.8, 0.3)
    row.add_child(status_lbl)

    var rm_btn: Button = Button.new()
    rm_btn.text = "Uninstall"
    rm_btn.custom_minimum_size.x = 70
    rm_btn.add_theme_font_size_override("font_size", 11)
    rm_btn.modulate = Color(0.8, 0.5, 0.5)
    row.add_child(rm_btn)
    rm_btn.pressed.connect(_on_installed_uninstall.bind(rm_btn, file_path))

    _installed_list.add_child(row)
    _installed_list.add_child(HSeparator.new())


func _on_installed_uninstall(btn: Button, file_path: String) -> void:
    if not FileAccess.file_exists(file_path):
        btn.text = "Not found"
        btn.modulate = Color(0.5, 0.5, 0.5)
        btn.disabled = true
        return
    DirAccess.remove_absolute(file_path)
    _log_info("Uninstalled: " + file_path.get_file())
    var row: Node = btn.get_parent()
    var parent: Node = row.get_parent()
    var idx: int = row.get_index()
    row.queue_free()
    # Remove the HSeparator after the row
    if idx < parent.get_child_count() and parent.get_child(idx) is HSeparator:
        parent.get_child(idx).queue_free()


func _on_browse_uninstall(btn: Button, mod_id: int) -> void:
    var file_path: String = str(_browse_installed_ids.get(mod_id, ""))
    if file_path == "" or not FileAccess.file_exists(file_path):
        btn.text = "Not found"
        btn.modulate = Color(0.5, 0.5, 0.5)
        btn.disabled = true
        return
    DirAccess.remove_absolute(file_path)
    _browse_installed_ids.erase(mod_id)
    _log_info("Uninstalled mod (id " + str(mod_id) + "): " + file_path.get_file())
    btn.text = "Removed"
    btn.modulate = Color(0.5, 0.5, 0.5)
    btn.disabled = true


func _install_mod_from_browse(modworkshop_id: int, mod_name: String) -> Dictionary:
    var mods_dir: String = OS.get_executable_path().get_base_dir().path_join(MOD_DIR)
    DirAccess.make_dir_recursive_absolute(mods_dir)
    var safe_name: String = mod_name.replace("/", "_").replace("\\", "_").replace(":", "_")
    var target_path: String = mods_dir.path_join(safe_name + ".zip")
    var counter: int = 1
    while FileAccess.file_exists(target_path):
        target_path = mods_dir.path_join(safe_name + "_" + str(counter) + ".zip")
        counter += 1

    var req: HTTPRequest = HTTPRequest.new()
    req.timeout = 30.0
    req.download_file = target_path
    add_child(req)
    var url: String = MODWORKSHOP_DOWNLOAD_URL_TEMPLATE % str(modworkshop_id)
    _log_info("Browse install: downloading " + url)
    _log_info("  Target: " + target_path)
    var err: Error = req.request(url)
    if err != OK:
        _log_critical("  Request error: " + str(err))
        req.queue_free()
        return {"ok": false}
    var res: Array = await req.request_completed
    if not is_instance_valid(req):
        _log_critical("  Request node freed during download")
        return {"ok": false}
    req.queue_free()

    _log_info("  Result: " + str(res[0]) + ", HTTP: " + str(res[1]))
    if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
        _log_critical("  Download failed: result=" + str(res[0]) + " http=" + str(res[1]))
        if FileAccess.file_exists(target_path):
            DirAccess.remove_absolute(target_path)
        return {"ok": false}
    if not FileAccess.file_exists(target_path):
        _log_critical("  File not found after download: " + target_path)
        return {"ok": false}

    _log_info("Installed from browse: " + mod_name + " -> " + target_path.get_file())

    # Post-install conflict scan
    var warnings: Array[String] = _scan_archive_for_conflicts(target_path, mod_name)
    for w in warnings:
        _log_warning("  " + w)
    return {"ok": true, "warnings": warnings, "path": target_path}


func _scan_archive_for_conflicts(archive_path: String, mod_name: String) -> Array[String]:
    var warnings: Array[String] = []
    var zr: ZIPReader = ZIPReader.new()
    if zr.open(archive_path) != OK:
        return warnings

    var files: PackedStringArray = zr.get_files()

    # Check for backslash paths
    var backslash_count: int = 0
    for f: String in files:
        if "\\" in f:
            backslash_count += 1
    if backslash_count > 0:
        warnings.append("BAD ZIP: " + str(backslash_count) + " entries use Windows backslash paths. Re-pack with 7-Zip.")

    # Check for conflicts with already-loaded mods
    for f in files:
        var res_path: String = _normalize_to_res_path(f)
        if res_path == "":
            continue
        if override_registry.has(res_path):
            var existing: Array = override_registry[res_path]
            for claim in existing:
                var cn: String = claim["mod_name"]
                if cn != mod_name:
                    warnings.append("CONFLICT: " + res_path.get_file() + " — also claimed by " + cn)

    # Check GDScript for take_over_path conflicts
    for f in files:
        if f.get_extension().to_lower() != "gd":
            continue
        var source: String = zr.read_file(f).get_string_from_utf8()
        for m in _re_take_over.search_all(source):
            var path: String = m.get_string(1)
            # Check if any installed mod also takes over this path
            for existing_mod: String in _mod_script_analysis:
                if existing_mod == mod_name:
                    continue
                var existing_paths: Array = _mod_script_analysis[existing_mod]["take_over_literal_paths"]
                if path in existing_paths:
                    warnings.append("SCRIPT CONFLICT: take_over_path(\"" + path + "\") — also used by " + existing_mod)

    zr.close()
    return warnings


func _fetch_and_populate_tags() -> void:
    var req: HTTPRequest = HTTPRequest.new()
    req.timeout = 10.0
    add_child(req)
    var err: Error = req.request("https://api.modworkshop.net/games/864/tags")
    if err != OK:
        req.queue_free()
        return
    var res: Array = await req.request_completed
    if not is_instance_valid(req):
        return
    req.queue_free()
    if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
        return
    var raw: Variant = JSON.parse_string(res[3].get_string_from_utf8())
    var parsed: Array = []
    if raw is Array:
        parsed = raw
    elif raw is Dictionary:
        parsed = raw.get("data", [])
    if parsed.is_empty():
        return
    for tag_data in parsed:
        if not (tag_data is Dictionary):
            continue
        var tag_id: int = int(tag_data.get("id", 0))
        var tag_name: String = str(tag_data.get("name", ""))
        if tag_name == "":
            continue
        var tag_btn: CheckButton = CheckButton.new()
        tag_btn.text = tag_name
        tag_btn.add_theme_font_size_override("font_size", 10)
        _browse_tag_flow.add_child(tag_btn)
        var tid: int = tag_id
        tag_btn.toggled.connect(_on_browse_tag_toggled.bind(tid))
    _browse_tag_flow.visible = _browse_tag_flow.get_child_count() > 0


func _on_browse_tag_toggled(on: bool, tag_id: int) -> void:
    if on:
        _browse_active_tags[tag_id] = true
    else:
        _browse_active_tags.erase(tag_id)
    _browse_current_page = 1
    _browse_render_list()

# ─── Background update check ─────────────────────────────────────────────────


func _check_updates_background() -> void:
    var update_entries: Array[Dictionary] = []
    for entry in _ui_mod_entries:
        var cfg: ConfigFile = entry["cfg"]
        if cfg == null:
            continue
        var version: String = str(cfg.get_value("mod", "version", ""))
        var mw_id: int = 0
        if cfg.has_section_key("updates", "modworkshop"):
            mw_id = int(str(cfg.get_value("updates", "modworkshop", "")))
        if mw_id > 0 and version != "":
            update_entries.append(
                {
                    "mod_name": entry["mod_name"],
                    "version": version,
                    "mw_id": mw_id,
                },
            )
    if update_entries.is_empty():
        return

    var ids: Array[int] = []
    for ue in update_entries:
        ids.append(ue["mw_id"])
    var latest: Dictionary = await _fetch_latest_modworkshop_versions(ids)

    var any_updates: bool = false
    for ue in update_entries:
        var latest_v: Variant = latest.get(str(ue["mw_id"]), null)
        if latest_v == null:
            continue
        var cmp: int = _compare_versions(ue["version"], str(latest_v))
        if cmp < 0:
            if not any_updates:
                _log_info("")
                _log_info("--- Mod Updates Available ---")
                any_updates = true
            _log_warning(
                "UPDATE: " + ue["mod_name"] + " v" + ue["version"]
                + " -> v" + str(latest_v) + " (modworkshop.net/mod/" + str(ue["mw_id"]) + ")",
            )
    if any_updates:
        _log_info("Download updates from modworkshop.net and replace files in the mods folder.")
        _write_conflict_report()
        var update_lines: Array[String] = []
        update_lines.append("")
        update_lines.append("[color=#d4b330]Updates available[/color]")
        for ue in update_entries:
            var lv: Variant = latest.get(str(ue["mw_id"]), null)
            if lv != null and _compare_versions(ue["version"], str(lv)) < 0:
                update_lines.append(
                    "  [color=#bbbbbb]" + ue["mod_name"] + "[/color]"
                    + "  [color=#666666]v" + ue["version"] + " → v" + str(lv) + "[/color]",
                )
        _append_detail_bbcode("\n".join(update_lines))
    else:
        _log_info("All mods with update info are up to date.")

# ─── Main load loop ───────────────────────────────────────────────────────────


func _load_all_mods() -> void:
    pending_autoloads.clear()
    loaded_mod_ids.clear()
    registered_autoload_names.clear()
    override_registry.clear()
    _report_lines.clear()
    _database_replaced_by = ""
    _mod_script_analysis.clear()
    _archive_file_sets.clear()

    _scan_vanilla_paths()
    DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))

    var candidates: Array[Dictionary] = []
    for entry in _ui_mod_entries:
        if not entry["enabled"]:
            continue
        candidates.append(entry.duplicate())
    candidates.sort_custom(func(a, b): return a["priority"] < b["priority"])

    if candidates.is_empty():
        _log_info("No mods enabled.")
        return

    _log_info("=== Load Order ===")
    for i in candidates.size():
        var c: Dictionary = candidates[i]
        var tag: String = " [priority=" + str(c["priority"]) + "]" if c["priority"] != 0 else ""
        _log_info("  [" + str(i + 1) + "] " + c["mod_name"] + " | " + c["file_name"] + tag)
    _log_info("==================")

    for load_index in candidates.size():
        _process_mod_candidate(candidates[load_index], load_index)


func _process_mod_candidate(c: Dictionary, load_index: int) -> void:
    var file_name: String = c["file_name"]
    var full_path: String = c["full_path"]
    var ext: String = c["ext"]
    var mod_name: String = c["mod_name"]
    var mod_id: String = c["mod_id"]
    var cfg: Variant = c["cfg"]

    _log_info("--- [" + str(load_index + 1) + "] " + mod_name + " (" + file_name + ")")

    if ext != "pck" and loaded_mod_ids.has(mod_id):
        _log_warning("Duplicate mod id '" + mod_id + "' — skipped: " + file_name)
        return

    if not _try_mount_pack(full_path):
        _log_critical("Failed to mount: " + file_name)
        return

    _log_info("  Mounted OK")

    if ext != "pck":
        _scan_and_register_archive_claims(full_path, mod_name, file_name, load_index)

    if ext == "pck" or not c["has_mod_txt"]:
        if not c["has_mod_txt"] and ext != "pck":
            _log_warning("  No mod.txt — autoloads skipped")
        return

    loaded_mod_ids[mod_id] = true

    if cfg == null or not cfg.has_section("autoload"):
        return

    var keys: PackedStringArray = cfg.get_section_keys("autoload")
    for key in keys:
        var autoload_name: String = str(key)
        var res_path: String = str(cfg.get_value("autoload", key))

        if registered_autoload_names.has(autoload_name):
            _log_warning("Duplicate autoload name '" + autoload_name + "' — skipped")
            continue
        registered_autoload_names[autoload_name] = true

        if _archive_file_sets.has(file_name) and not _archive_file_sets[file_name].has(res_path):
            _log_critical("  Autoload path not found in archive: " + res_path)
            _log_critical("    Declared in mod.txt but missing from: " + file_name)

        pending_autoloads.append({ "mod_name": mod_name, "name": autoload_name, "path": res_path })
        _log_info("  Autoload queued: " + autoload_name + " -> " + res_path)
        _register_claim(res_path, mod_name, file_name, load_index, "autoload")

# ─── Logging ──────────────────────────────────────────────────────────────────


func _log_info(msg: String) -> void:
    var line: String = "[ModLoader][Info] " + msg
    print(line)
    _report_lines.append(line)


func _log_warning(msg: String) -> void:
    var line: String = "[ModLoader][Warning] " + msg
    push_warning(line)
    _report_lines.append(line)


func _log_critical(msg: String) -> void:
    var line: String = "[ModLoader][Critical] " + msg
    push_error(line)
    _report_lines.append(line)

# ─── Override registry ────────────────────────────────────────────────────────


func _register_claim(
        res_path: String,
        mod_name: String,
        archive: String,
        load_index: int,
        claim_type: String,
        source_path: String = "",
) -> void:
    if not override_registry.has(res_path):
        override_registry[res_path] = []
    for existing in override_registry[res_path]:
        if existing["mod_name"] == mod_name and existing["archive"] == archive:
            return
    override_registry[res_path].append(
        {
            "mod_name": mod_name,
            "archive": archive,
            "load_index": load_index,
            "claim_type": claim_type,
            "source_path": source_path,
        },
    )


func _is_dangerous_path(res_path: String) -> bool:
    return _vanilla_paths.has(res_path)


func _classify_claim(res_path: String) -> String:
    var lower: String = res_path.to_lower()
    if lower.ends_with(".gd"):
        return "script"
    if lower.ends_with(".tscn") or lower.ends_with(".scn"):
        return "scene"
    if lower.ends_with(".tres"):
        return "resource"
    return "file"

# ─── Vanilla path scan ────────────────────────────────────────────────────────


func _scan_vanilla_paths() -> void:
    _vanilla_paths.clear()
    _database_path = ""
    for dir_path in VANILLA_SCAN_DIRS:
        _scan_vanilla_dir(dir_path)
    for path: String in _vanilla_paths:
        if path.get_extension().to_lower() == "gd" \
        and path.get_file().get_basename().to_lower() == "database":
            _database_path = path
            _log_info("Vanilla scan: scene registry -> " + _database_path)
            break
    if _vanilla_paths.is_empty():
        _log_warning("Vanilla scan: 0 files found — falling back to filename heuristics.")
    else:
        _log_info("Vanilla scan: " + str(_vanilla_paths.size()) + " game files indexed")


func _scan_vanilla_dir(dir_path: String) -> void:
    var dir: DirAccess = DirAccess.open(dir_path)
    if dir == null:
        return
    dir.list_dir_begin()
    while true:
        var entry: String = dir.get_next()
        if entry == "":
            break
        if entry.begins_with("."):
            continue
        var full: String = dir_path + "/" + entry
        if dir.current_is_dir():
            _scan_vanilla_dir(full)
        elif entry.get_extension().to_lower() in TRACKED_EXTENSIONS:
            _vanilla_paths[full] = true
    dir.list_dir_end()

# ─── Archive scanner ──────────────────────────────────────────────────────────


func _scan_and_register_archive_claims(
        archive_path: String,
        mod_name: String,
        archive_file: String,
        load_index: int,
) -> void:
    var zr: ZIPReader = ZIPReader.new()
    if zr.open(archive_path) != OK:
        _log_warning("  Could not scan archive: " + archive_file)
        return

    var files: PackedStringArray = zr.get_files()

    var backslash_count: int = 0
    var example_bad: String = ""
    for f: String in files:
        if "\\" in f:
            backslash_count += 1
            if example_bad == "":
                example_bad = f
    if backslash_count > 0:
        _log_critical("  BAD ZIP: " + str(backslash_count) + " entries use Windows backslash paths.")
        _log_critical("    Re-pack with 7-Zip. Example bad entry: '" + example_bad + "'")

    var tracked_count: int = 0
    var dangerous_count: int = 0
    var path_set: Dictionary = { }
    var gd_analysis: Dictionary = {
        "take_over_literal_paths": [],
        "extends_paths": [],
        "uses_dynamic_override": false,
        "lifecycle_no_super": [],
        "calls_update_tooltip": false,
        "total_gd_files": 0,
    }

    for f in files:
        if f.get_extension().to_lower() == "gd":
            gd_analysis["total_gd_files"] = gd_analysis["total_gd_files"] + 1
            _scan_gd_source(zr.read_file(f).get_string_from_utf8(), gd_analysis)

        var res_path: String = _normalize_to_res_path(f)
        if res_path == "":
            continue

        path_set[res_path] = true
        tracked_count += 1
        _register_claim(res_path, mod_name, archive_file, load_index, _classify_claim(res_path), f)

        var bare_name: String = res_path.get_file().get_basename().to_lower()
        var is_db_file: bool = bare_name == "database" and res_path.get_extension().to_lower() == "gd"

        if (res_path == _database_path and _database_path != "") or (is_db_file and _database_path == ""):
            if _database_replaced_by == "":
                _database_replaced_by = mod_name
            _log_critical("  DATABASE OVERRIDE: " + mod_name + " replaces Database.gd")
            _log_warning("    All preload() paths in this file must exist or parsing will fail.")
        elif is_db_file:
            _log_warning("  DATABASE COPY: " + mod_name + " bundles a private Database.gd at " + res_path)
        elif _is_dangerous_path(res_path):
            dangerous_count += 1

    zr.close()
    _mod_script_analysis[mod_name] = gd_analysis
    _archive_file_sets[archive_file] = path_set

    var summary: String = "  " + str(tracked_count) + " resource path(s)"
    if dangerous_count > 0:
        summary += " [" + str(dangerous_count) + " replace vanilla files]"
    _log_info(summary)

    if gd_analysis["total_gd_files"] > 0:
        var override_count: int = (gd_analysis["take_over_literal_paths"] as Array).size() \
        + (gd_analysis["extends_paths"] as Array).size()
        var dynamic_tag: String = " [uses overrideScript()]" if gd_analysis["uses_dynamic_override"] else ""
        _log_info(
            "  " + str(gd_analysis["total_gd_files"]) + " .gd file(s), "
            + str(override_count) + " override target(s)" + dynamic_tag,
        )


func _normalize_to_res_path(zip_path: String) -> String:
    var path: String = zip_path.replace("\\", "/")
    if path.begins_with("res://"):
        return path
    if path.begins_with("/"):
        return "res:/" + path
    if path.begins_with(".") or path == "mod.txt":
        return ""
    if path.get_extension().to_lower() in TRACKED_EXTENSIONS:
        return "res://" + path
    return ""

# ─── GDScript source analysis ─────────────────────────────────────────────────


func _scan_gd_source(text: String, analysis: Dictionary) -> void:
    for m in _re_take_over.search_all(text):
        var path: String = m.get_string(1)
        if path not in (analysis["take_over_literal_paths"] as Array):
            (analysis["take_over_literal_paths"] as Array).append(path)

    var m_ext: RegExMatch = _re_extends.search(text)
    if m_ext:
        var path: String = m_ext.get_string(1)
        if path not in (analysis["extends_paths"] as Array):
            (analysis["extends_paths"] as Array).append(path)

    if not analysis["uses_dynamic_override"]:
        analysis["uses_dynamic_override"] = "get_base_script()" in text \
        or "take_over_path(parentScript" in text

    if not analysis["calls_update_tooltip"]:
        analysis["calls_update_tooltip"] = "UpdateTooltip" in text

    # Only check for missing super() in scripts that extend game scripts.
    # Scripts extending engine base classes (Node, Control, etc.) don't need super.
    var extends_game_script: bool = m_ext != null and m_ext.get_string(1).begins_with("res://Scripts/")
    if extends_game_script:
        var func_matches: Array[RegExMatch] = _re_func.search_all(text)
        for i in func_matches.size():
            var func_name: String = func_matches[i].get_string(1)
            if func_name not in LIFECYCLE_METHODS:
                continue
            var body_start: int = func_matches[i].get_end()
            var body_end: int = text.length() if i + 1 >= func_matches.size() \
            else func_matches[i + 1].get_start()
            var body: String = text.substr(body_start, body_end - body_start)
            if "super(" not in body and "super." not in body:
                if func_name not in (analysis["lifecycle_no_super"] as Array):
                    (analysis["lifecycle_no_super"] as Array).append(func_name)


func _analyze_script_conflicts() -> void:
    if _mod_script_analysis.is_empty():
        return

    var literal_claims: Dictionary = { }
    for mod_name: String in _mod_script_analysis:
        for path in (_mod_script_analysis[mod_name]["take_over_literal_paths"] as Array):
            if not literal_claims.has(path):
                literal_claims[path] = []
            if mod_name not in literal_claims[path]:
                (literal_claims[path] as Array).append(mod_name)

    var found_literal: bool = false
    for path: String in literal_claims:
        var mods: Array = literal_claims[path]
        if mods.size() <= 1:
            continue
        if not found_literal:
            _log_info("")
            _log_info("--- Script Injection Conflicts ---")
            found_literal = true
        _log_critical("CONFLICT: take_over_path(\"" + path + "\") used by: " + ", ".join(mods))

    var extends_claims: Dictionary = { }
    for mod_name: String in _mod_script_analysis:
        var analysis: Dictionary = _mod_script_analysis[mod_name]
        if not analysis["uses_dynamic_override"]:
            continue
        for path in (analysis["extends_paths"] as Array):
            if not extends_claims.has(path):
                extends_claims[path] = []
            if mod_name not in extends_claims[path]:
                (extends_claims[path] as Array).append(mod_name)

    var found_extends: bool = false
    for path: String in extends_claims:
        var claimants: Array = extends_claims[path]
        if claimants.size() <= 1:
            continue
        if not found_extends:
            _log_info("")
            _log_info("--- Dynamic Override Chains ---")
            found_extends = true
        var all_super: bool = true
        for cmod: String in claimants:
            if not (_mod_script_analysis[cmod]["lifecycle_no_super"] as Array).is_empty():
                all_super = false
                break
        if all_super:
            _log_info("CHAIN OK: " + " -> ".join(claimants) + " -> vanilla  (" + path + ")")
        else:
            _log_warning("CHAIN BROKEN: " + path + " — " + ", ".join(claimants))

    for mod_name: String in _mod_script_analysis:
        var analysis: Dictionary = _mod_script_analysis[mod_name]
        var total: int = (analysis["take_over_literal_paths"] as Array).size() \
        + (analysis["extends_paths"] as Array).size()
        if total >= 5:
            _log_warning("OVERHAUL: " + mod_name + " overrides " + str(total) + " core scripts.")

    var found_no_super: bool = false
    for mod_name: String in _mod_script_analysis:
        var no_super: Array = _mod_script_analysis[mod_name]["lifecycle_no_super"]
        if no_super.is_empty():
            continue
        if not found_no_super:
            _log_info("")
            _log_info("--- Missing super() in Lifecycle Methods ---")
            found_no_super = true
        _log_warning("NO SUPER: " + mod_name + " — " + ", ".join(no_super))

# ─── Conflict summary ─────────────────────────────────────────────────────────


func _print_conflict_summary() -> void:
    _log_info("")
    _log_info("============================================")
    _log_info("=== ModLoader Compatibility Summary      ===")
    _log_info("============================================")
    _log_info("Mods loaded:  " + str(loaded_mod_ids.size()))

    var conflicted_paths: Array[String] = []
    var critical_conflicts: Array[String] = []
    for res_path: String in override_registry:
        var claims: Array = override_registry[res_path]
        if claims.size() > 1:
            conflicted_paths.append(res_path)
            if _is_dangerous_path(res_path) or res_path == _database_path:
                critical_conflicts.append(res_path)

    _log_info("Conflicting resource paths: " + str(conflicted_paths.size()))
    _log_info("Critical conflicts:         " + str(critical_conflicts.size()))

    if conflicted_paths.is_empty():
        _log_info("No resource path conflicts — all mods appear compatible.")
    else:
        _log_info("")
        _log_info("--- Conflicted Paths (last loader wins) ---")
        for res_path in conflicted_paths:
            var claims: Array = override_registry[res_path]
            var winner: Dictionary = claims[claims.size() - 1]
            _log_warning("CONFLICT: " + res_path)
            for claim in claims:
                var marker: String = " <-- wins" if claim == winner else ""
                _log_info(
                    "    [" + str(claim["load_index"] + 1) + "] "
                    + claim["mod_name"] + " via " + claim["archive"] + marker,
                )

    if _database_replaced_by != "":
        var affected: Array[String] = []
        for res_path: String in override_registry:
            if res_path == _database_path:
                continue
            var lower: String = res_path.to_lower()
            if not (lower.ends_with(".tscn") or lower.ends_with(".scn")):
                continue
            for claim in (override_registry[res_path] as Array):
                var cn: String = claim["mod_name"]
                if cn != _database_replaced_by and cn not in affected:
                    affected.append(cn)
        if not affected.is_empty():
            _log_warning("DATABASE: " + _database_replaced_by + " replaced Database.gd.")
            _log_warning("  Scene overrides from [" + ", ".join(affected) + "] may not take effect.")

    _analyze_script_conflicts()
    _log_info("============================================")
    _log_info("")


func _write_conflict_report() -> void:
    var f: FileAccess = FileAccess.open(CONFLICT_REPORT_PATH, FileAccess.WRITE)
    if f == null:
        _log_warning("Could not write report to: " + CONFLICT_REPORT_PATH)
        return
    for line in _report_lines:
        f.store_line(line)
    f.close()
    print("[ModLoader][Info] Conflict report written to: " + CONFLICT_REPORT_PATH)

# ─── Autoload instantiation ───────────────────────────────────────────────────


func _instantiate_autoload(mod_name: String, autoload_name: String, res_path: String) -> void:
    if not (FileAccess.file_exists(res_path) or ResourceLoader.exists(res_path)):
        _log_critical("Autoload not found: " + res_path + " [" + mod_name + "]")
        return

    var resource: Resource = load(res_path)
    if resource == null:
        _log_critical("Autoload failed to parse: " + autoload_name + " -> " + res_path)
        return

    if resource is PackedScene:
        var instance: Node = (resource as PackedScene).instantiate()
        instance.name = autoload_name
        add_child(instance)
        _log_info("Autoload instantiated (scene): " + autoload_name + " [" + mod_name + "]")
        return

    if resource is GDScript:
        var inst: Variant = (resource as GDScript).new()
        if inst == null:
            _log_warning("Autoload script returned null: " + autoload_name)
            return
        if inst is Node:
            (inst as Node).name = autoload_name
            add_child(inst as Node)
            _log_info("Autoload instantiated (script): " + autoload_name + " [" + mod_name + "]")
            return
        _log_warning("Autoload is not a Node — not added to tree: " + autoload_name)

# ─── Mount helper ─────────────────────────────────────────────────────────────


func _try_mount_pack(path: String) -> bool:
    if ProjectSettings.load_resource_pack(path):
        return true
    if path.get_extension().to_lower() != "vmz":
        return false
    var temp_zip: String = ProjectSettings.globalize_path(TMP_DIR).path_join(
        path.get_file().get_basename() + ".zip",
    )
    var data: PackedByteArray = FileAccess.get_file_as_bytes(path)
    if data.size() == 0:
        return false
    var out: FileAccess = FileAccess.open(temp_zip, FileAccess.WRITE)
    if out == null:
        return false
    out.store_buffer(data)
    out.close()
    return ProjectSettings.load_resource_pack(temp_zip)

# ─── mod.txt parser ───────────────────────────────────────────────────────────


func _read_mod_config(path: String) -> ConfigFile:
    var zr: ZIPReader = ZIPReader.new()
    if zr.open(path) != OK:
        return null
    if not zr.file_exists("mod.txt"):
        zr.close()
        return null
    var text: String = zr.read_file("mod.txt").get_string_from_utf8()
    zr.close()
    var cfg: ConfigFile = ConfigFile.new()
    if cfg.parse(text) != OK:
        return null
    return cfg

# ─── Update fetch helpers ─────────────────────────────────────────────────────


func _compare_versions(a: String, b: String) -> int:
    var pa: PackedStringArray = a.split("-")[0].split(".")
    var pb: PackedStringArray = b.split("-")[0].split(".")
    var n: int = max(pa.size(), pb.size())
    for i in n:
        var va: int = int(pa[i]) if i < pa.size() and pa[i].is_valid_int() else 0
        var vb: int = int(pb[i]) if i < pb.size() and pb[i].is_valid_int() else 0
        if va < vb:
            return -1
        if va > vb:
            return 1
    return 0


func _fetch_latest_modworkshop_versions(ids: Array[int]) -> Dictionary:
    var latest_versions: Dictionary = { }
    for chunk_ids in _chunk_int_array(ids, 100):
        var req: HTTPRequest = HTTPRequest.new()
        req.timeout = 15.0
        add_child(req)
        var err: Error = req.request(
            MODWORKSHOP_VERSIONS_URL,
            PackedStringArray(["Content-Type: application/json", "Accept: application/json"]),
            HTTPClient.METHOD_POST,
            JSON.stringify({ "mod_ids": chunk_ids }),
        )
        if err != OK:
            req.queue_free()
            continue
        var res: Array = await req.request_completed
        if not is_instance_valid(req):
            continue
        req.queue_free()
        if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] < 200 or res[1] >= 300:
            continue
        var parsed: Variant = JSON.parse_string(res[3].get_string_from_utf8())
        if parsed is Dictionary:
            latest_versions.merge(parsed, true)
    return latest_versions


func _chunk_int_array(arr: Array[int], size: int) -> Array:
    var result: Array = []
    var current: Array[int] = []
    for value in arr:
        current.append(value)
        if current.size() >= size:
            result.append(current)
            current = []
    if not current.is_empty():
        result.append(current)
    return result

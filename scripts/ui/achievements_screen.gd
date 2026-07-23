extends PanelScreen
## AchievementsScreen
##
## The trophy room: every achievement in AchievementManager's catalog, plus a
## "world discoveries" shelf for the Open World's hidden landmarks. Unlocked
## entries glow in the accent; locked ones stay dim but always show HOW to earn
## them — and, for career stats, how close the player already is — so the page
## reads as a menu of things to go do, never a wall of failure.
##
## Pure presentation: AchievementManager owns the catalog and the unlock state;
## this screen only reads and lays out.
##
## The page chrome — card, scroll region, section captions and the two grids —
## is authored in scenes/menus/achievements_screen.tscn. Only the cards THEMSELVES
## are built here, since there is one per catalog entry.

const GOLD: Color = Color(1.0, 0.79, 0.28)
const LOCKED_TEXT: Color = Color(0.55, 0.59, 0.66)
const CARD_BG: Color = Color(0.06, 0.08, 0.12, 0.85)
const CARD_BG_DONE: Color = Color(0.10, 0.09, 0.06, 0.9)

@onready var _discovery_shelf: GridContainer = %DiscoveryShelf
@onready var _achievement_grid: GridContainer = %AchievementGrid
@onready var _back_button: Button = %BackButton

func _ready() -> void:
	var unlocked: int = AchievementManager.get_unlocked_count()
	var total: int = AchievementManager.get_definitions().size()
	set_header("", _subtitle(unlocked, total))
	_fill_discovery_shelf()
	_fill_achievement_grid()
	_back_button.pressed.connect(SceneManager.load_main_menu)


## An encouraging header line — progress framed as a journey, not a deficit.
func _subtitle(unlocked: int, total: int) -> String:
	if unlocked == 0:
		return "%d waiting for you — your first workout unlocks the first one." % total
	if unlocked >= total:
		return "All %d earned. You built this, one workout at a time." % total
	return "%d of %d earned — keep moving, the rest are on their way." % [unlocked, total]


## The five landmark cards in a row: a found place shows its name; an unfound
## one shows "???" — but its hint is always visible, because the hint IS the
## invitation to go walking.
func _fill_discovery_shelf() -> void:
	for defn in AchievementManager.get_discoveries():
		_discovery_shelf.add_child(_discovery_card(defn))


func _discovery_card(defn: AchievementDef) -> Control:
	var found: bool = AchievementManager.is_unlocked(defn.id)
	var panel := _card_panel(found)
	panel.custom_minimum_size = Vector2(200, 150)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	var icon := Label.new()
	icon.text = defn.icon if found else "?"
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", 30)
	icon.add_theme_color_override("font_color", GOLD if found else LOCKED_TEXT)
	vbox.add_child(icon)

	var name_label := Label.new()
	name_label.text = defn.title if found else "???"
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.add_theme_font_size_override("font_size", 15)
	name_label.add_theme_color_override("font_color",
			TITLE_COLOR if found else LOCKED_TEXT)
	vbox.add_child(name_label)

	var hint := Label.new()
	hint.text = defn.description
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", CAPTION_COLOR)
	vbox.add_child(hint)
	return panel


## The main catalog in two columns, discoveries excluded (they have the shelf).
func _fill_achievement_grid() -> void:
	for defn in AchievementManager.get_definitions():
		if defn.is_discovery():
			continue
		_achievement_grid.add_child(_achievement_card(defn))


func _achievement_card(defn: AchievementDef) -> Control:
	var done: bool = AchievementManager.is_unlocked(defn.id)
	var panel := _card_panel(done)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	panel.add_child(row)

	var icon := Label.new()
	icon.text = defn.icon
	icon.custom_minimum_size = Vector2(40, 0)
	icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon.add_theme_font_size_override("font_size", 30)
	icon.add_theme_color_override("font_color", GOLD if done else LOCKED_TEXT)
	row.add_child(icon)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.alignment = BoxContainer.ALIGNMENT_CENTER
	text_box.add_theme_constant_override("separation", 1)
	row.add_child(text_box)

	var title := Label.new()
	title.text = defn.title
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", TITLE_COLOR if done else LOCKED_TEXT)
	text_box.add_child(title)

	var desc := Label.new()
	desc.text = defn.description
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", CAPTION_COLOR)
	text_box.add_child(desc)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", 13)
	if done:
		status.text = "EARNED  ✓"
		status.add_theme_color_override("font_color", GOLD)
	else:
		status.text = _progress_text(defn)
		status.add_theme_color_override("font_color", ACCENT_TEXT)
	if status.text != "":
		text_box.add_child(status)
	return panel


## "82 / 100 kcal"-style live progress for a locked career achievement; session
## achievements return "" (there is no session to measure against here).
func _progress_text(defn: AchievementDef) -> String:
	if not defn.stat in AchievementManager.CAREER_STATS:
		return ""
	var p: Dictionary = AchievementManager.get_progress(defn)
	return "%d / %d %s" % [int(p["value"]), int(p["target"]), defn.unit]


## Shared card chrome: dark rounded panel, warmed with a gold edge when earned.
func _card_panel(done: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD_BG_DONE if done else CARD_BG
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(1)
	sb.border_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.55) if done else Color(1, 1, 1, 0.08)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", sb)
	return panel

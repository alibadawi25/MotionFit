extends PanelScreen
## StoreScreen
##
## The store: kit, colours and venue styling the player spends earned coins on.
## Two shelves, deliberately separate — a purchasable CATALOGUE (wide, cheap,
## always something to want) and an AWARDS shelf that is never for sale, because
## the pieces worth having should read as proof you did something, not proof you
## grinded.
##
## Nothing here sells power: every item is cosmetic. If kit ever changed how hard
## you have to work, scores would stop meaning "I worked hard" — which is the
## whole product.
##
## **UI STAGE.** There is no StoreManager yet, so the catalogue below is
## placeholder data and buying/equipping only mutates this screen's in-memory
## copy (so every card state can be seen and reviewed). Nothing persists. When
## the economy lands, swap `_catalog` / `_coins` for the manager and delete
## `_apply_purchase` / `_apply_equip`.
##
## The page chrome — card, balance strip, category tabs, scroll region and the
## two grids — is authored in scenes/menus/store_screen.tscn. Each tab button
## carries its category in a `category_id` metadata entry (visible in the
## inspector), so adding a category is a scene edit plus a CATALOG entry.

const GOLD: Color = Color(1.0, 0.79, 0.28)
const OWNED_GREEN: Color = Color(0.42, 0.86, 0.6)
const LOCKED_TEXT: Color = Color(0.55, 0.59, 0.66)
const CARD_BG: Color = Color(0.06, 0.08, 0.12, 0.85)
const CARD_BG_OWNED: Color = Color(0.05, 0.11, 0.09, 0.9)
const CARD_BG_AWARD: Color = Color(0.10, 0.09, 0.06, 0.9)

const COIN_GLYPH: String = "◆"

## Placeholder balance until the economy exists.
const _PLACEHOLDER_COINS: int = 640

## Placeholder catalogue. `award` non-empty = earned, never purchasable.
## `swatch` (hex) renders a colour chip instead of a glyph.
const CATALOG: Array[Dictionary] = [
	# — KIT ————————————————————————————————————————————————————————
	{"id": "kit_starter", "cat": "kit", "name": "Starter Vest",
	 "desc": "Where everybody begins.", "glyph": "▲", "price": 0,
	 "owned": true, "equipped": true, "award": ""},
	{"id": "kit_gym", "cat": "kit", "name": "Gym Tee",
	 "desc": "Loose cotton, sleeves rolled.", "glyph": "▲", "price": 150,
	 "owned": true, "equipped": false, "award": ""},
	{"id": "kit_trackside", "cat": "kit", "name": "Trackside Jacket",
	 "desc": "For the walk to the line.", "glyph": "▲", "price": 400,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "kit_sparring", "cat": "kit", "name": "Sparring Kit",
	 "desc": "Cut for the ring, worn in.", "glyph": "▲", "price": 520,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "kit_champion", "cat": "kit", "name": "Champion's Robe",
	 "desc": "Hood up, name on the back.", "glyph": "★", "price": 0,
	 "owned": false, "equipped": false, "award": "Win a division title"},
	# — GLOVES —————————————————————————————————————————————————————
	{"id": "glv_worn", "cat": "gloves", "name": "Worn Leather",
	 "desc": "Scuffed, soft, reliable.", "glyph": "●", "price": 0,
	 "owned": true, "equipped": true, "award": ""},
	{"id": "glv_speed", "cat": "gloves", "name": "Speed Gloves",
	 "desc": "Light, tight at the wrist.", "glyph": "●", "price": 220,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "glv_night", "cat": "gloves", "name": "Midnight",
	 "desc": "Matte black, gold stitch.", "glyph": "●", "price": 480,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "glv_unbeaten", "cat": "gloves", "name": "Unbeaten",
	 "desc": "Only worn by someone who was.", "glyph": "★", "price": 0,
	 "owned": false, "equipped": false, "award": "Win five bouts in a row"},
	# — HAIR ———————————————————————————————————————————————————————
	{"id": "hair_crop", "cat": "hair", "name": "Crop",
	 "desc": "Short and out of the way.", "glyph": "◗", "price": 0,
	 "owned": true, "equipped": true, "award": ""},
	{"id": "hair_tied", "cat": "hair", "name": "Tied Back",
	 "desc": "Pulled up for the round.", "glyph": "◗", "price": 120,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "hair_braids", "cat": "hair", "name": "Braids",
	 "desc": "Neat rows, close to the scalp.", "glyph": "◗", "price": 180,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "hair_buzz", "cat": "hair", "name": "Buzz",
	 "desc": "Nothing to grab.", "glyph": "◗", "price": 120,
	 "owned": false, "equipped": false, "award": ""},
	# — COLOURS ————————————————————————————————————————————————————
	{"id": "col_ember", "cat": "colour", "name": "Ember",
	 "desc": "The house orange.", "swatch": "#ff8024", "price": 0,
	 "owned": true, "equipped": true, "award": ""},
	{"id": "col_deep", "cat": "colour", "name": "Deep Sea",
	 "desc": "Cold blue, quiet.", "swatch": "#2f6f9e", "price": 90,
	 "owned": true, "equipped": false, "award": ""},
	{"id": "col_moss", "cat": "colour", "name": "Moss",
	 "desc": "Muted green.", "swatch": "#5c8a4a", "price": 90,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "col_plum", "cat": "colour", "name": "Plum",
	 "desc": "Deep and warm.", "swatch": "#7a3f6d", "price": 90,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "col_bone", "cat": "colour", "name": "Bone",
	 "desc": "Off-white, clean.", "swatch": "#ddd6c6", "price": 140,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "col_gold", "cat": "colour", "name": "Title Gold",
	 "desc": "Reserved. You'll know when.", "swatch": "#e0c34a", "price": 0,
	 "owned": false, "equipped": false, "award": "Hold a title for three defences"},
	# — VENUE ——————————————————————————————————————————————————————
	{"id": "ven_gym", "cat": "venue", "name": "Back-Room Gym",
	 "desc": "Where you started out.", "glyph": "▣", "price": 0,
	 "owned": true, "equipped": true, "award": ""},
	{"id": "ven_ropes", "cat": "venue", "name": "Corner Ropes",
	 "desc": "Recolour the ring and corners.", "glyph": "▣", "price": 260,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "ven_banner", "cat": "venue", "name": "Your Banner",
	 "desc": "Your name over the ring.", "glyph": "▣", "price": 350,
	 "owned": false, "equipped": false, "award": ""},
	{"id": "ven_arena", "cat": "venue", "name": "Sold-Out Arena",
	 "desc": "Full bowl, lights down.", "glyph": "★", "price": 0,
	 "owned": false, "equipped": false, "award": "Reach the National division"},
]

var _catalog: Array[Dictionary] = []
var _coins: int = _PLACEHOLDER_COINS
var _category: String = "kit"

@onready var _balance_label: Label = %BalanceLabel
@onready var _tabs: HBoxContainer = %CategoryTabs
@onready var _grid: GridContainer = %CatalogueGrid
@onready var _awards_shelf: GridContainer = %AwardsShelf
@onready var _back_button: Button = %BackButton

func _ready() -> void:
	# Deep copy so buy/equip can demo the card states without touching the const.
	_catalog = CATALOG.duplicate(true)

	# The first scene-authored tab decides which shelf opens.
	var tabs: Array[Node] = _tabs.get_children()
	if not tabs.is_empty():
		_category = _tab_category(tabs[0] as Button)
	for tab in tabs:
		var button := tab as Button
		button.pressed.connect(_on_tab_pressed.bind(_tab_category(button)))

	_back_button.pressed.connect(SceneManager.load_main_menu)
	_refresh_balance()
	_refresh_tabs()
	_refresh_shelves()


## The category a scene-authored tab button stands for, read from its
## `category_id` metadata (set in the inspector).
func _tab_category(button: Button) -> String:
	return String(button.get_meta("category_id", ""))


func _refresh_balance() -> void:
	_balance_label.text = "%s %d" % [COIN_GLYPH, _coins]


func _refresh_tabs() -> void:
	for child in _tabs.get_children():
		var button := child as Button
		var active: bool = _tab_category(button) == _category
		button.add_theme_stylebox_override("normal", _tab_style(active))
		button.add_theme_stylebox_override("hover", _tab_style(active))
		button.add_theme_stylebox_override("pressed", _tab_style(true))
		button.add_theme_color_override("font_color",
				TITLE_COLOR if active else CAPTION_COLOR)


func _tab_style(active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.22) if active \
			else Color(0.06, 0.08, 0.12, 0.7)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.7) if active \
			else Color(1, 1, 1, 0.08)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb


func _on_tab_pressed(category: String) -> void:
	if category == _category:
		return
	_category = category
	_refresh_tabs()
	_rebuild_grid()


## The purchasable shelf for the active category. Awards live in their own shelf
## at the bottom, so a price tag never sits next to something you can't buy.
func _rebuild_grid() -> void:
	for child in _grid.get_children():
		child.queue_free()
	for item in _catalog:
		if String(item["cat"]) != _category:
			continue
		if String(item["award"]) != "":
			continue
		_grid.add_child(_item_card(item))


func _rebuild_awards_shelf() -> void:
	for child in _awards_shelf.get_children():
		child.queue_free()
	for item in _catalog:
		if String(item["award"]) != "":
			_awards_shelf.add_child(_item_card(item))


func _item_card(item: Dictionary) -> Control:
	var owned: bool = bool(item["owned"])
	var equipped: bool = bool(item["equipped"])
	var award: String = String(item["award"])
	var is_award: bool = award != ""
	var price: int = int(item["price"])

	var panel := _card_panel(owned, is_award)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(0, 168)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	vbox.add_child(_item_mark(item, owned, is_award))

	var name_label := Label.new()
	name_label.text = String(item["name"])
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color",
			TITLE_COLOR if (owned or not is_award) else LOCKED_TEXT)
	vbox.add_child(name_label)

	var desc := Label.new()
	desc.text = String(item["desc"])
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override("font_size", 13)
	desc.add_theme_color_override("font_color", CAPTION_COLOR)
	desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(desc)

	vbox.add_child(_item_footer(item, owned, equipped, is_award, award, price))
	return panel


## A colour chip for colourways, a glyph for everything else. Awards mark
## themselves gold whether or not they're earned — they read as a different
## class of thing at a glance.
func _item_mark(item: Dictionary, owned: bool, is_award: bool) -> Control:
	if item.has("swatch"):
		var chip := ColorRect.new()
		chip.color = Color.html(String(item["swatch"]))
		chip.custom_minimum_size = Vector2(52, 26)
		chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		if not owned:
			chip.modulate = Color(1, 1, 1, 0.45)
		return chip

	var glyph := Label.new()
	glyph.text = String(item.get("glyph", "●"))
	glyph.add_theme_font_size_override("font_size", 26)
	if is_award:
		glyph.add_theme_color_override("font_color", GOLD if owned else Color(GOLD.r, GOLD.g, GOLD.b, 0.5))
	else:
		glyph.add_theme_color_override("font_color", ACCENT_TEXT if owned else LOCKED_TEXT)
	return glyph


## The state line + action. Every branch stays warm: an item you can't afford
## yet says how far off it is, never that you can't have it.
func _item_footer(item: Dictionary, owned: bool, equipped: bool,
		is_award: bool, award: String, price: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var status := Label.new()
	status.add_theme_font_size_override("font_size", 13)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(status)

	if equipped:
		status.text = "EQUIPPED"
		status.add_theme_color_override("font_color", OWNED_GREEN)
		return row

	if owned:
		status.text = "OWNED  ✓"
		status.add_theme_color_override("font_color", OWNED_GREEN)
		row.add_child(_action_button("EQUIP", true,
				_apply_equip.bind(String(item["id"]))))
		return row

	if is_award:
		status.text = award
		status.add_theme_color_override("font_color", GOLD)
		return row

	var affordable: bool = _coins >= price
	if affordable:
		status.text = "%s %d" % [COIN_GLYPH, price]
		status.add_theme_color_override("font_color", ACCENT_TEXT)
	else:
		status.text = "%s %d  ·  %d more to go" % [COIN_GLYPH, price, price - _coins]
		status.add_theme_color_override("font_color", CAPTION_COLOR)
	row.add_child(_action_button("BUY", affordable,
			_apply_purchase.bind(String(item["id"]))))
	return row


func _action_button(text: String, enabled: bool, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(84, 34)
	button.disabled = not enabled
	button.add_theme_font_size_override("font_size", 13)
	if enabled:
		button.pressed.connect(action)
	return button


## UI-stage only — mutates this screen's copy so the owned/equipped states can be
## seen. Replace with StoreManager.purchase() when the economy exists.
func _apply_purchase(item_id: String) -> void:
	for item in _catalog:
		if String(item["id"]) != item_id:
			continue
		var price: int = int(item["price"])
		if _coins < price:
			return
		_coins -= price
		item["owned"] = true
		break
	_refresh_balance()
	_refresh_shelves()


## UI-stage only — one equipped item per category. Replace with
## StoreManager.equip() when the economy exists.
func _apply_equip(item_id: String) -> void:
	var category: String = ""
	for item in _catalog:
		if String(item["id"]) == item_id:
			category = String(item["cat"])
			break
	if category == "":
		return
	for item in _catalog:
		if String(item["cat"]) == category:
			item["equipped"] = (String(item["id"]) == item_id)
	_refresh_shelves()


## Both shelves read from `_catalog`, so a buy in one has to redraw the other
## (an award and a catalogue item can share a category).
func _refresh_shelves() -> void:
	_rebuild_grid()
	_rebuild_awards_shelf()


## Shared card chrome — green edge when owned, gold when it's an award.
func _card_panel(owned: bool, is_award: bool) -> PanelContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	if is_award:
		sb.bg_color = CARD_BG_AWARD
		sb.border_color = Color(GOLD.r, GOLD.g, GOLD.b, 0.55 if owned else 0.28)
	elif owned:
		sb.bg_color = CARD_BG_OWNED
		sb.border_color = Color(OWNED_GREEN.r, OWNED_GREEN.g, OWNED_GREEN.b, 0.45)
	else:
		sb.bg_color = CARD_BG
		sb.border_color = Color(1, 1, 1, 0.08)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(1)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	panel.add_theme_stylebox_override("panel", sb)
	return panel

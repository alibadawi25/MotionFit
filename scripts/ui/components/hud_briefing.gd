extends Control
## HudBriefing
##
## The pre-game "how to play" card every game shows while its opening settles:
## an optional kicker, a title and subtitle, a body of control rows, and a live
## countdown to the off.
##
## The SHELL is this component's business — the dim backdrop, the bordered card,
## the type scale, the dividers, the fade-out. The BODY is the game's: call
## [method add_row] with whatever control you like (Zombie Run passes animated
## icon badges), or [method add_line] / [method add_section] for plain text.
##
## The three games used to hand-build this card each; they had drifted to three
## different paddings and Hurdle Dash had lost its backdrop dim entirely, so its
## briefing read against the live track. One shell fixes that class of bug for
## every game that comes after.
##
## Instanced by [GameHUD.show_briefing] — games don't preload it themselves.
class_name HudBriefing

const ANTON: Font = preload("res://assets/fonts/Anton-Regular.ttf")

@onready var _kicker: HBoxContainer = %Kicker
@onready var _kicker_icon: TextureRect = %KickerIcon
@onready var _kicker_label: Label = %KickerLabel
@onready var _title: Label = %Title
@onready var _subtitle: Label = %Subtitle
@onready var _body: VBoxContainer = %Body
@onready var _countdown: Label = %Countdown
@onready var _time_bar: Panel = %TimeBar
@onready var _time_fill: Panel = %TimeFill

## Highest countdown seen, so the time bar can drain from wherever the game
## started counting without being told the total up front.
var _time_total: float = 0.0


## A small line above the title, in its own colour, for the one thing the player
## should feel before they read anything else ("A ZOMBIE IS ON YOUR HEELS").
## [param icon] is optional; without one the row is just the text.
func set_kicker(text: String, color: Color, icon: Texture2D = null) -> void:
	_kicker.visible = true
	_kicker_label.text = text
	_kicker_label.add_theme_color_override("font_color", color)
	_kicker_icon.visible = icon != null
	if icon != null:
		_kicker_icon.texture = icon
		_kicker_icon.self_modulate = color


func set_header(title: String, subtitle: String = "") -> void:
	_title.text = title
	_subtitle.text = subtitle
	_subtitle.visible = subtitle != ""


## Adds a game-built control to the card body — the escape hatch for anything
## richer than a line of text.
func add_row(control: Control) -> void:
	_body.add_child(control)


## One plain instruction line. [param indent] pushes it under the section head
## above it, for games whose moves group into categories.
func add_line(text: String, color: Color = GameHUD.TEXT, indent: bool = false) -> void:
	var row := Label.new()
	row.text = ("      " + text) if indent else text
	row.add_theme_font_size_override("font_size", 20)
	row.add_theme_color_override("font_color", color)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(row)


## An accent sub-heading inside the body, for games that group their controls
## (Boxing splits its moves into "punch" and "defend").
func add_section(text: String) -> void:
	var head := Label.new()
	head.text = text
	head.add_theme_font_override("font", ANTON)
	head.add_theme_font_size_override("font_size", 24)
	head.add_theme_color_override("font_color", GameHUD.ACCENT)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(head)


## A centred muted closing line under the controls — reassurance, not instruction.
func add_note(text: String) -> void:
	var note := Label.new()
	note.text = text
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_font_size_override("font_size", 18)
	note.add_theme_color_override("font_color", GameHUD.MUTED)
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.add_child(note)


func set_countdown(text: String) -> void:
	_countdown.text = text


## Turns on the thin draining bar under the countdown, for the games whose grace
## period is long enough that reading a number mid-march is hard.
func enable_time_bar() -> void:
	_time_bar.visible = true


## Drains the time bar from [param seconds_left]. The first call sets the full
## width, so games don't have to pass their grace period separately.
func set_time_remaining(seconds_left: float) -> void:
	if not _time_bar.visible:
		return
	_time_total = maxf(_time_total, seconds_left)
	if _time_total <= 0.0:
		return
	_time_fill.size.x = _time_bar.size.x * clampf(seconds_left / _time_total, 0.0, 1.0)


## Fades the card out and frees it. Called by [GameHUD.hide_briefing].
func dismiss() -> void:
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.35)
	tween.tween_callback(queue_free)

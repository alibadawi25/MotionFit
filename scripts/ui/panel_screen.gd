extends Control
class_name PanelScreen
## PanelScreen
##
## Base for the centred-card menu screens (Settings, Create Profile, Profile,
## Fitness, Achievements, Store). The card itself — dark rounded panel, accent
## bar, title, subtitle — now lives in each screen's .tscn so it can be seen and
## edited in the editor; this script only holds the shared palette and a couple
## of helpers for filling that scaffold in.
##
## Scene contract (every screen extending this provides these unique names):
##   %TitleLabel      — the big screen title
##   %SubtitleLabel   — the line under it (hidden automatically when empty)
##   %ContentBox      — the VBox the screen's own rows live in
## The card stylebox is shared at assets/ui/styles/screen_card.tres.

const ACCENT := Color(1, 0.5, 0.14)
const ACCENT_TEXT := Color(1, 0.64, 0.3)
const TITLE_COLOR := Color(0.96, 0.97, 0.99)
const SUBTITLE_COLOR := Color(0.78, 0.82, 0.88, 0.9)
const CAPTION_COLOR := Color(0.7, 0.74, 0.8)

## The scene's content VBox — where a screen appends anything it still has to
## build at runtime (data-driven lists that can't be authored ahead of time).
@onready var content_box: VBoxContainer = %ContentBox


## Overrides the scene's title / subtitle text at runtime. Screens whose header
## is a fixed string just set it in the editor and never call this; screens whose
## subtitle reports live progress (Achievements) pass one in. An empty subtitle
## hides the label so the spacing matches a title-only card.
func set_header(title_text: String = "", subtitle_text: String = "") -> void:
	var title: Label = %TitleLabel
	var subtitle: Label = %SubtitleLabel
	if title_text != "":
		title.text = title_text
	if subtitle_text != "":
		subtitle.text = subtitle_text
	subtitle.visible = subtitle.text != ""

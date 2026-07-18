extends Node
## MenuView
##
## Throwaway view scene for styling the Main Menu (shot.sh pairing): marks the
## profile as already chosen this launch so the boot gate doesn't bounce to the
## profile picker, then routes to the real menu.

func _ready() -> void:
	SceneManager.profile_chosen_this_session = true
	SceneManager.load_main_menu()

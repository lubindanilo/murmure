# Mise en page de la fenêtre du DMG, pour dmgbuild (https://github.com/dmgbuild/dmgbuild).
# Ramage à gauche, Applications à droite, une flèche entre les deux sur le fond (make-background.swift).
# Usage, depuis la racine du dépôt : dmgbuild -s Scripts/dmg/settings.py -D app=build/Ramage.app Ramage build/Ramage.dmg
import os.path

app = defines.get("app", "build/Ramage.app")  # noqa: F821 (fourni par dmgbuild)

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [os.path.basename(app)]

background = defines.get("background", "Scripts/dmg/background.tiff")  # noqa: F821 (chemin depuis la racine du dépôt)
window_rect = ((200, 160), (660, 432))  # 400 pt de fond + la barre de titre
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    os.path.basename(app): (170, 190),
    "Applications": (490, 190),
}

format = "UDZO"
filesystem = "HFS+"

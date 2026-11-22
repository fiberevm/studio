# dmgbuild settings for Studio's installer: a 640x400 window with Studio on the left, an Applications
# shortcut on the right and an arrow between them (Resources/dmg/background.tiff, from dmg-background.swift).
# Used by scripts/make-dmg.sh; `app`, `background` and `icon` come in through -D defines.
import os

application = defines["app"]
appname = os.path.basename(application)

format = "UDZO"                 # compressed, read-only
filesystem = "HFS+"
size = None                     # computed from the contents

files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")      # the volume's icon in Finder's sidebar and on the desktop
badge_icon = None

background = defines["background"]
window_rect = ((200, 120), (640, 428))   # 640x400 content (the background) plus the title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {
    appname: (170, 205),        # icon centers; keep in sync with dmg-background.swift
    "Applications": (470, 205),
}
hide_extension = [appname]

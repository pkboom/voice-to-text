# dmgbuild layout for VoiceToText.dmg. Driven by scripts/make-dmg.sh, which passes -D app=<path> -D art=<this folder>.
# Icon positions match the slots drawn by scripts/make-art.py.
import os.path

application = defines["app"]  # noqa: F821 (injected by dmgbuild)
here = defines["art"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(here, "volume.icns")

background = os.path.join(here, "background.png")
window_rect = ((200, 200), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    os.path.basename(application): (170, 190),
    "Applications": (490, 190),
}

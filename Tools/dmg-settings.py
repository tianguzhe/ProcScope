"""Finder layout: direct .DS_Store creation, no Finder / AppleScript automation."""
import os
import subprocess

files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
default_view = "icon-view"
window_rect = ((180, 140), (680, 520))
icon_locations = {"ProcScope.app": (184, 248), "Applications": (496, 248)}
icon_size = 104
text_size = 13
label_pos = "bottom"
arrange_by = None
hide_extensions = []  # Changing bundle FinderInfo would invalidate strict signing.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_item_info = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False


def create_hook(mount_point, options):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict",
                    os.path.join(mount_point, "ProcScope.app")], check=True)

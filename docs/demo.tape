# Regenerate docs/demo.gif:
#
#   zig build
#   rm -rf /tmp/demo-home
#   mkdir -p /tmp/demo-home/.config/readmarks
#   cp docs/demo-feeds /tmp/demo-home/.config/readmarks/feeds
#   nix run nixpkgs#vhs -- docs/demo.tape   # first run warms the article cache
#   rm -f /tmp/demo-home/.local/share/readmarks/bookmarks.bin
#   nix run nixpkgs#vhs -- docs/demo.tape   # second run is the one to keep
#

Output docs/demo.gif

Set Shell bash
Set FontSize 13
Set Width 1500
Set Height 760
Set Padding 12
Set Framerate 24

Hide
Type "export HOME=/tmp/demo-home && clear"
Enter
Sleep 1s
Show

Type "./zig-out/bin/readmarks"
Enter
Sleep 4s

Down 3
Sleep 400ms
Down 2
Sleep 600ms

Type "v"
Sleep 1600ms
Down 4
Sleep 900ms
Escape
Sleep 500ms

Type "b"
Sleep 1400ms

Type ":"
Sleep 500ms
Type "zig"
Sleep 1400ms
Escape
Sleep 400ms

Type ":"
Sleep 400ms
Type "> refresh"
Sleep 1400ms
Escape
Sleep 400ms

Type "?"
Sleep 2200ms
Escape
Sleep 400ms

Ctrl+u
Sleep 2200ms

Down 1
Sleep 1200ms

Ctrl+u
Sleep 1000ms

Type "q"
Sleep 800ms

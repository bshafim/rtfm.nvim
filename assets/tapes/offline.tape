# Offline mode: no network at all, installed docs keep working.
Source tapes/_settings.tape
Output offline.gif

Hide
Type "cd demo && clear && nvim" Enter
Sleep 3s
Show

Sleep 1.2s
Type ":Rtfm offline on" Sleep 400ms Enter
Sleep 1.5s
Type ":Rtfm mdn fetch" Sleep 400ms Enter
Sleep 2.5s
Screenshot out/offline-mdn.png
Escape
Sleep 800ms
Type ":Rtfm go waitgroup" Sleep 400ms Enter
Sleep 2s
Screenshot out/offline-go.png
Enter
Sleep 2.5s

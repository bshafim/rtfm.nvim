# The core flow: pick a source, search, preview, open, table of contents.
Source tapes/_settings.tape
Output picker.gif

Hide
Type "cd demo && clear && nvim" Enter
Sleep 3s
Show

Sleep 2s
Type ":Rtfm" Sleep 400ms Enter
Sleep 2s
Screenshot out/picker-sources.png
Type "go" Sleep 1s
Tab
Sleep 1s
Type "withtimeout"
Sleep 2.5s
Screenshot out/picker-search.png
Ctrl+N Sleep 1.2s
Ctrl+P Sleep 1.2s
Enter
Sleep 2.5s
Screenshot page.png
Ctrl+D Sleep 1s
Type "gO"
Sleep 2.5s
Screenshot out/picker-toc.png
Type ":lclose" Enter
Sleep 1s
Type "q"
Sleep 1s

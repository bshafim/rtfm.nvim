# gK on a symbol: the exact version from go.mod, scrolled to the symbol.
Source tapes/_settings.tape
Output symbol.gif

Hide
Type "cd demo && clear && nvim main.go" Enter
Sleep 3s
Show

Sleep 1.5s
Type "/NewRequestWithContext" Sleep 400ms Enter
Type ":noh" Enter
Sleep 1.2s
Type "gK"
Sleep 3.5s
Screenshot out/symbol-http.png
Ctrl+W Type "p"
Sleep 800ms
Type "/eg.Group" Sleep 400ms Enter
Type ":noh" Enter
Sleep 1.2s
Type "gK"
Sleep 3.5s
Screenshot out/symbol-errgroup.png
Sleep 1s

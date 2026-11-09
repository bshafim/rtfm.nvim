# Plain-English questions, answered by a local embedding model over installed docs.
Source tapes/_settings.tape
Output ask.gif

Hide
Type "cd demo && clear && nvim" Enter
Sleep 3s
Show

Sleep 1.2s
Type ":Rtfm ask" Sleep 400ms Enter
Sleep 1s
Type@60ms "how do I cancel a request after a timeout"
Sleep 3s
Screenshot out/ask-timeout.png
Backspace@15ms 45
Sleep 600ms
Type@60ms "wait for multiple goroutines to finish"
Sleep 3s
Screenshot out/ask-goroutines.png
Ctrl+N
Sleep 1.5s
Enter
Sleep 2.5s

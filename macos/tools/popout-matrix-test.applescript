-- Pop-out and dock matrix test for XMLMacker.
-- Run:  osascript tools/popout-matrix-test.applescript
-- Needs: the app running with a file open, and Accessibility permission
-- for the terminal. Prints scroll-area sizes before and after each cycle.
on findAndPress(descWanted)
  tell application "System Events"
    tell process "XMLMacker"
      repeat with w in windows
        set els to entire contents of w
        repeat with el in els
          try
            if (value of attribute "AXDescription" of el) is descWanted then
              perform action "AXPress" of el
              return true
            end if
          end try
        end repeat
      end repeat
    end tell
  end tell
  return false
end findAndPress

on geometry()
  set out to ""
  tell application "System Events"
    tell process "XMLMacker"
      set out to out & "win=" & (count of windows) & " "
      set els to entire contents of window 1
      repeat with el in els
        try
          if role of el is "AXScrollArea" then
            set s to size of el
            if (item 2 of s) > 100 then set out to out & "[" & (item 1 of s) & "x" & (item 2 of s) & "] "
          end if
        end try
      end repeat
    end tell
  end tell
  return out
end geometry

on cycle(paneName)
  set p to findAndPress("Open " & paneName & " pane in its own window")
  delay 2
  set d to findAndPress("Dock " & paneName & " pane in the main window")
  delay 3
  return paneName & ": popped=" & p & " docked=" & d & " -> " & geometry()
end cycle

tell application "XMLMacker" to activate
delay 1
set report to ""
set modes to {{"Full", "3", {"Tree", "Source", "Subtags", "Hierarchy"}}, {"Edit", "1", {"Tree", "Tree", "Source", "Subtags"}}, {"Inspect", "2", {"Tree", "Tree", "Source"}}}
repeat with m in modes
  tell application "System Events" to keystroke (item 2 of m) using {option down, command down}
  delay 2
  set report to report & "=== " & (item 1 of m) & " baseline -> " & geometry() & linefeed
  repeat with pn in (item 3 of m)
    set report to report & "   " & cycle(pn) & linefeed
  end repeat
end repeat
return report

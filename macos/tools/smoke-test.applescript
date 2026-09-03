-- Drives the running app through its main surfaces without a mouse and
-- reports whether it survived. Used by tools/check.sh; the app must
-- already be running with at least one file open.
on run
	set appName to "xml-macker"
	set report to {}

	tell application appName to activate
	delay 1

	tell application "System Events"
		if not (exists process appName) then return "FAIL app is not running"
		tell process appName
			-- "window 1" is whatever is in front, which after the Diff step
			-- is the Diff window. The main window is the one with the
			-- toolbar, so every step below asks for that.
			-- A cold launch with two large files can take a while, and the
			-- system's own little affordance window shows up in the list
			-- meanwhile, so wait for the real one instead of assuming it.
			set mainWin to missing value
			repeat 60 times
				repeat with w in windows
					if exists toolbar 1 of w then set mainWin to w
				end repeat
				if mainWin is not missing value then exit repeat
				delay 1
			end repeat
			if mainWin is missing value then return "FAIL no main window after 60s"
			-- Each workspace mode in turn.
			-- The four layouts live in the toolbar's segmented control,
			-- which accessibility exposes as a radio group; the segments
			-- carry their name as a description, not a title.
			repeat with modeIndex from 1 to 4
				try
					set seg to radio button modeIndex of radio group 1 of group 1 of toolbar 1 of mainWin
					set modeName to description of seg
					click seg
					delay 1.5
					set end of report to "ok   workspace " & modeName
				on error errText
					set end of report to "FAIL workspace " & modeIndex & ": " & errText
				end try
			end repeat

			-- Orbit opens and closes.
			try
				click menu item "Show Tour…" of menu 1 of menu bar item "Help" of menu bar 1
				delay 2
				key code 53
				delay 1
				set end of report to "ok   tour opens and closes"
			on error errText
				set end of report to "FAIL tour: " & errText
			end try

			-- Every theme in turn; a theme switch touches every window.
			repeat with themeName in {"Aurora Dark", "Light", "One Dark", "Dracula", "Hacker", "Solarized Dark"}
				try
					click menu item (themeName as text) of menu 1 of menu item "Theme" of menu 1 of menu bar item "View" of menu bar 1
					delay 1
					set end of report to "ok   theme " & themeName
				on error errText
					set end of report to "FAIL theme " & themeName & ": " & errText
				end try
			end repeat

			-- The Diff window, on whatever is open. This step exists
			-- because a drawing change once made it hang with a blank
			-- window: a hang shows up here as this call never returning.
			-- It needs two files open; check.sh opens them.
			try
				if my tabCount(mainWin) < 2 then
					set end of report to "skip diff, fewer than two files are open"
				else
					-- Toolbar buttons carry their name as a description.
					repeat with b in buttons of toolbar 1 of mainWin
						if description of b is "Diff" then
							click b
							exit repeat
						end if
					end repeat
					-- Wait for the picker, then press its Compare button by
					-- name rather than trusting a bare Return.
					set pressed to false
					repeat 20 times
						repeat with w in windows
							try
								click (first button of w whose title is "Compare")
								set pressed to true
								exit repeat
							end try
						end repeat
						if pressed then exit repeat
						delay 1
					end repeat
					if not pressed then
						set end of report to "FAIL diff picker did not appear"
					else
						-- Then wait for the comparison itself, up to two minutes
						-- on files of this size.
						set diffWin to missing value
						repeat 120 times
							repeat with w in windows
								try
									-- A window's name is one string, title and subtitle joined.
									if (name of w as text) starts with "Diff" then set diffWin to w
								end try
							end repeat
							if diffWin is not missing value then exit repeat
							delay 1
						end repeat
						if diffWin is missing value then
							set end of report to "FAIL diff did not open"
						else
							set end of report to "ok   diff opened"
							try
								click (first button of diffWin whose title is "Next ▶")
								delay 2
								click (first button of diffWin whose title is "Next ▶")
								delay 2
								set end of report to "ok   diff still answers after Next"
							on error errText
								set end of report to "FAIL diff Next: " & errText
							end try
						end if
					end if
				end if
			on error errText
				set end of report to "FAIL diff: " & errText
			end try

		end tell
		-- Outside "tell process": inside it, "process appName" would be
		-- read as a process of that process.
		if not (exists process appName) then
			set end of report to "FAIL the app died during the sweep"
		else
			set end of report to "ok   still running at the end"
		end if
	end tell

	set AppleScript's text item delimiters to linefeed
	return report as text
end run

-- How many files are open. The tab strip is a scroll area holding one
-- static text per tab plus its close buttons and the ＋ button, so the
-- strip is the scroll area that has that ＋ in it.
on tabCount(win)
	tell application "System Events"
		repeat with sa in scroll areas of win
			set isStrip to false
			repeat with b in buttons of sa
				try
					if title of b is "＋" then set isStrip to true
				end try
			end repeat
			if isStrip then return count of static texts of sa
		end repeat
		return 0
	end tell
end tabCount

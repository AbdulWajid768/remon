-- Recursively dumps the accessibility tree of Remon's front window (or its sheet).
-- osascript scripts/e2e/dump.applescript [maxDepth]
on walk(e, d, maxD)
	set out to ""
	if d > maxD then return out
	tell application "System Events"
		set r to ""
		set n to ""
		set ds to ""
		set v to ""
		try
			set r to role of e
		end try
		try
			set n to name of e as text
		end try
		try
			set ds to description of e as text
		end try
		try
			set v to value of e as text
		end try
		set fr to ""
		try
			set p to position of e
			set fr to "@" & (item 1 of p) & "," & (item 2 of p)
		end try
		set line_ to ""
		repeat d times
			set line_ to line_ & "  "
		end repeat
		set out to out & line_ & r & " | " & n & " | " & ds & " | " & v & " " & fr & linefeed
		try
			repeat with c in (UI elements of e)
				set out to out & my walk(c, d + 1, maxD)
			end repeat
		end try
	end tell
	return out
end walk

on run argv
	set maxD to 12
	if (count of argv) > 0 then set maxD to (item 1 of argv) as integer
	tell application "System Events" to tell process "Remon"
		set w to window 1
		if (count of sheets of w) > 0 then
			set root to sheet 1 of w
		else
			set root to w
		end if
	end tell
	return my walk(root, 0, maxD)
end run

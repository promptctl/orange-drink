-- Reads the first rows of Activity Monitor's Energy tab through the accessibility tree: the radio button
-- for the third tab is clicked, then each row's text cells are printed ("Process Name | Energy Impact | 12 hr Power | ...").
-- Needs the invoking terminal trusted for Accessibility.
tell application "System Events" to tell process "Activity Monitor"
  set frontmost to true
  set w to first window whose name starts with "Activity Monitor"
  click radio button 3 of radio group 1 of group 1 of toolbar 1 of w
  delay 6
  set t to outline 1 of scroll area 1 of group 1 of w
  set header to ""
  set out to ""
  repeat with i from 1 to (count of rows of t)
    set cs to {}
    repeat with c in (UI elements of row i of t)
      try
        set end of cs to (value of first static text of c) as string
      end try
    end repeat
    set AppleScript's text item delimiters to " | "
    set out to out & (cs as string) & linefeed
    set AppleScript's text item delimiters to ""
  end repeat
  return out
end tell

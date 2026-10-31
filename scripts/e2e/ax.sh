#!/bin/zsh
# Accessibility helpers for driving Remon end-to-end like a user (clicks, keys, menus).
# Needs Accessibility permission for the terminal running it. Usage: `source scripts/e2e/ax.sh`.

_as() { osascript -e "$1" 2>&1; }

# Root to search: the front window's sheet if one is showing, otherwise the window.
_ROOT='set w to window 1
if (count of sheets of w) > 0 then
  set r to sheet 1 of w
else
  set r to w
end if'

ax_buttons() {
  _as "tell application \"System Events\" to tell process \"Remon\"
$_ROOT
set out to {}
repeat with e in (entire contents of r)
  try
    if role of e is \"AXButton\" then set end of out to ((title of e) as text) & \"/\" & ((description of e) as text)
  end try
end repeat
return out
end tell"
}

# Clicks the first button whose title or description is $1.
ax_click() {
  _as "tell application \"System Events\" to tell process \"Remon\"
$_ROOT
repeat with e in (entire contents of r)
  try
    if role of e is \"AXButton\" and ((title of e) as text is \"$1\" or (description of e) as text is \"$1\") then
      click e
      return \"clicked $1\"
    end if
  end try
end repeat
return \"NOT FOUND: $1\"
end tell"
}

# Static texts of the front window/sheet joined by ' · '.
ax_texts() {
  _as "tell application \"System Events\" to tell process \"Remon\"
$_ROOT
set out to \"\"
repeat with e in (entire contents of r)
  try
    if role of e is \"AXStaticText\" then
      set v to value of e
      if v is not missing value and v is not \"\" then set out to out & v & \" · \"
    end if
  end try
end repeat
return out
end tell"
}

ax_window_title() { _as 'tell application "System Events" to tell process "Remon" to get name of window 1'; }
ax_windows() { _as 'tell application "System Events" to tell process "Remon" to get name of every window'; }
ax_sheet_count() { _as 'tell application "System Events" to tell process "Remon" to count sheets of window 1'; }
ax_front() { _as 'tell application "System Events" to set frontmost of process "Remon" to true'; }
# ax_key k "command down, shift down"
ax_key() { ax_front >/dev/null; _as "tell application \"System Events\" to keystroke \"$1\" using {$2}"; }
ax_keycode() { ax_front >/dev/null; _as "tell application \"System Events\" to key code $1"; }
ax_type() { ax_front >/dev/null; _as "tell application \"System Events\" to keystroke \"$1\""; }
ax_menu() { ax_front >/dev/null; _as "tell application \"System Events\" to tell process \"Remon\" to click menu item \"$2\" of menu \"$1\" of menu bar 1"; }
ax_menu_items() { _as "tell application \"System Events\" to tell process \"Remon\" to get name of every menu item of menu \"$1\" of menu bar 1"; }

# Changelog

For game version 2.5. Every version below compiles with 0 errors against the full installed script set.

## 1.2.2 - 2026-11-23
### Fixed
- When the window asked for the list before Equipment-EX or the player was ready, an empty list was kept for good. The bridge now answers "not ready" and the window asks again by itself.

In use in the author's game and working; tested, not extensively.

## 1.2.1 - 2026-11-23
### Fixed
- A save made while mouse mode held the camera could load with the camera still held, because the game saves that restriction. One saved flag remembers that mouse mode was on, and 1.5 seconds after every load a second cleanup removes the restriction.

Tested, not extensively.

## 1.2.0 - 2026-11-22
### Added
- Mouse mode: the window keeps the mouse after the CET overlay closes, with its own cursor. The camera and weapons are held, the keyboard stays free. Needs Codeware.
- Options "Pinned: take the mouse when the overlay closes" and "Mouse speed", and a hotkey for mouse mode.

A first build was tried in game and changed after a report that no cursor showed with Pin off.

## 1.1.0 - 2026-11-22
### Added
- Tick boxes to mark items, a "Marked" filter, and "Move N marked to stash" (near a stash or in your own car). Worn and quest items stay.
- Hotkeys to mark the item under the cursor and to move the marked items to the stash.

## 1.0.0 - 2026-11-22
- First version: the window with every Equipment-EX wardrobe item, filters, favourites, saved outfits, Pin mode and hotkeys for the pinned window.

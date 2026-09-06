# Aaavatar 2.0.2

A fix for automatic updates. If you're on 2.0.0 or 2.0.1, please install this version once by hand: download the DMG, drag Aaavatar into Applications and replace the old copy. Your library and settings stay where they are. From 2.0.2 on, updates install themselves again.

## What's fixed

- **Automatic updates now actually install** — 2.0.0 and 2.0.1 could download an update but macOS blocked the last step, so the app quietly relaunched the old version. The permission Sparkle needs inside the app sandbox is now in place.
- **You're told when an update fails** — instead of the update card just disappearing, it now says what went wrong and offers *Try again*, a direct *Download* of the latest version, or *Dismiss*.

## Requirements

macOS 14 Sonoma or newer.

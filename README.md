# AmbientLFG

Watches the WoW Premade Group Finder for groups matching your criteria and alerts you the moment one appears — so you can stop refreshing the browse window and just play.

## What it does

- **Rules**: "alert me for Mythic Lura groups that still need a tank" is `/alfg add mythic lura +tank` (or build it in the UI). Words match the boss/activity and are spelling-tolerant ("Lurra" matches "lura").
- **Alerts**: raid-warning banner, sound, and a flashing taskbar icon if you're alt-tabbed.
- **Background watching**: optional auto-search re-checks the Group Finder while you play. It pauses while you browse the Group Finder yourself and resumes when you close it.
- **Live matches list**: the `/alfg` window shows every currently-listed matching group with its tank/healer/dps counts, boss, difficulty, and title.
- **Seller filtering**: boost/carry advertisers are recognized and hidden automatically; block any leader forever with one click.

## Usage

1. `/alfg` to open the settings window
2. Add a rule (section, difficulty, words, roles that must be open)
3. Enable auto-search
4. When the alert fires, open the Group Finder and sign up

Signing up stays a manual click — Blizzard requires it — so pairing this with a one-click-apply addon like SmartLFG works well.

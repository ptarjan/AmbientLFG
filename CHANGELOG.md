# Changelog

## 0.3.1
- No more repeated failure messages when the Group Finder isn't usable (in a battleground, on an ineligible character, etc.) — retries slow down automatically and stop entirely after several failures, with a single message; searching resumes on its own once the Group Finder works again
- Background searches pause in battlegrounds and arenas
- Background searches now find the same listings the Group Finder window shows — previously they could miss more than half the groups (a search filter was too narrow)
- When you've searched manually at least once, background searches reuse your exact search settings for that section
- Groups no longer briefly disappear from the Current matches list and reappear — entries now only drop out when they're actually gone from newer search results
- Ready for WoW 12.1.0

## 0.3.0
Initial release.
- Watches the Premade Group Finder for groups matching your rules and alerts you with a raid-warning banner, sound, and a flashing taskbar icon so you can sign up before the group fills
- Rules combine words with requirements, e.g. "mythic lura +tank" alerts for Mythic Lura groups that still have a tank spot open — spelling variations like "Lurra" are matched automatically
- Optional auto-search keeps checking the Group Finder in the background while you play, so you don't have to sit in the browse window (pauses automatically while you browse the Group Finder yourself)
- Settings window (`/alfg`) with a live "Current matches" list showing each matching group's tank/healer/dps counts, the boss and difficulty it's listed for, and its title
- Boost/carry sellers are filtered out: repeat advertisers are recognized and hidden automatically, and you can permanently block any leader with one click on the X next to their group
- Rules can target Raids or Dungeons, a specific difficulty, and which roles must be open — all configurable in the UI or via slash commands (`/alfg` for the full list)

# Changelog

## 0.4.1
- Joining a group stops the watch. Accepting an invite to a group you applied for means the search has found what it was for, and alerting about more of them is the addon talking over the thing you asked it to find. Leaving that group does not start it again — run the search once more, the same as after a `/reload`, because the search box can only be read while Blizzard's panel is open and a search replayed without it is every group in the category.
- Key propagation is no longer re-asserted in combat, where setting it is blocked and reported against the addon.

## 0.4.0
**Rules are gone. You craft the search; the addon runs it for you.**

Set up the search you want in Blizzard's own Group Finder — category, filters, and the search box, including a keystone level or a range like `12-14` — and run it once. AmbientLFG replays exactly that search in the background and alerts you when a group appears with a seat you can fill. Saved rules are dropped on first login.

The reason is that rule words could never do this job. Since 12.0 a listing's title reaches an addon as an opaque token — the game renders it on screen, but the characters an addon receives are an id, not words — and that is true even when the group typed the title themselves. A `+14` rule could not match a listing plainly titled `+14`. Blizzard's search box can: for keystones it is a key-*range* filter the server evaluates against the real key level, and it keeps applying to the addon's background searches after you close the window.

- The window names the search it is watching, so the filter that decides everything is never invisible state.
- Watching does nothing until you have run a search yourself, and says so, instead of quietly inventing one that approximated the panel's filters and could not carry the search box at all.
- `/alfg add`, `del` and `clear` are gone with the rules.
- A group you have already been alerted about stays quiet across a `/reload` and a relog. The "already seen" list used to live only in memory, so every reload re-alerted everything you had dismissed. Entries expire after six hours, so the same leader listing again tomorrow is genuinely new.
- The groups already listed when watching starts no longer alert. A login, a `/reload`, or changing your search used to fire on every listing the search returned at once; those are the board as you'd see it, not news, so alerting begins with the next group to appear. `/alfg reset` still makes them all alert again.
- Changing your search clears the matches list immediately instead of leaving the previous search's groups sitting in it until they aged out.
- The window is titled "AmbientLFG" rather than "Premade Alert".
- Fix: a listing that was not in the current search's results could alert anyway — a `+8` while you were watching `16-16`. The game reports updates for every listing it is still tracking, including leftovers from an earlier, wider search, and those updates were being treated as matches.
- An empty search box is no longer watched at all. It is not a filter, it is every group in the category, so it would alert on the whole board and keep alerting as the board churns.
- The role checkboxes are gone. Which seats you can take is Blizzard's own "Tank/Healer/Damage role available" filter, and the window now shows what you picked there instead of asking a second time — two settings for one thing can disagree, and a disagreement (its Tank, your DPS) matches nothing while looking exactly like the addon being broken. Those boxes are a Dungeons filter — the game drops them for Raids and every other category — so the addon drops them there too rather than quietly narrowing a raid search by a tank tick left over from dungeons. `/alfg roles` is gone with it.
- Raid searches, which the game gives no role filter at all, get one from the addon: by default the role of whichever spec you are currently playing, re-read each time rather than stored, so respeccing moves it instead of leaving a stale tick behind. Untick "Raids: filter to my current spec's role" to pick for yourself. Raid listings publish no per-role caps, so tank and healer narrow the results while dps passes any group that isn't full.
- "Enabled" and "Auto-search" are one switch, "Watch every N sec". They were two switches for one thing: watching means searching, and enabled-without-auto-search only ever saw the searches you ran by hand, in the window you were already looking at. `/alfg auto on` is gone; `/alfg on` does it. If either switch was off, the addon comes back off.
- Fix: a match could show as "Unknown" in the list. A title is a token the game resolves as it draws it, and once the client has dropped the listing it can no longer resolve it — so such a listing now leaves the list, and every row leads with the leader's name, which is always real text.
- An "Open Group Finder" button in the window, since setting the search up is the one thing that has to happen in Blizzard's window.
- The window now says when watching is paused because the Group Finder is open. It always stood down while you browse — searching then stomps the results you are reading — but it said nothing, which looked identical to being broken.
- Fix: after a `/reload` the addon watched a search with no filter — every group in the category — while the window still named the filter it no longer had. The search box is not part of the search: the game reads Blizzard's own box as the search runs, and a reload builds that box empty. A reload now stops watching and says so; run your search once and it is watched again.
- Fix: the search box is re-read whenever the Group Finder is open, so clearing it or switching to another tab no longer leaves the addon naming a filter that is gone. It is only readable while that window is up, so with it shut the last reading stands.
- A raid search now says which difficulty it is watching, and says so in green when the search box picks one and in amber when it doesn't. Raid activities are named for their difficulty ("Manaforge Omega (Heroic)") and the search box's autocomplete matches those names, so typing `(hero` and taking the entry offered pins the search to it. Nothing else in the Group Finder narrows a raid search that way, so a raid search with no difficulty in the box is watching all four at once — which is almost never what was meant, and was invisible.
- Watching pauses while your own group is listed, and the window says so. A group that is already recruiting is not one you are looking to join, and while a listing is up the Group Finder shows your applicants and the search panel is unreachable — so "search once to arm it" was an instruction that could not be carried out. Watching resumes by itself when the listing is taken down; a party leader is also pointed at the Browse Groups button, which is the only way back to the search and exists for nobody else.
- Fix: your own group's listing could alert you and sat in the Current matches list alongside the real ones. Your search returns your own group like any other, so it is now recognised and skipped.
- The raid role choice is only on screen while a raid search is being watched. It is the addon's own filter and it applies to nothing else, so sitting there during a dungeon search — where Blizzard's Filter decides the roles — it was a control you could set and then watch do nothing.
- Moving the Group Finder to another section stops the watch, the same way clearing the search box does. The captured search belonged to the section you left, so the window went on naming it — and offering its raid role boxes — while you were looking at something else. Going back re-arms it.
- The empty list says what to do about being empty. "No matching groups right now" was the same sentence whether the addon was switched off, waiting for you to run a search, paused behind your own listing, or genuinely watching and finding nothing — the one state where there is nothing to do. It now names the next move, and it is decided alongside the status line so the two cannot describe different states.
- Fix: an alert could kill Blizzard's raid-warning frame with "attempt to perform arithmetic on a secret number value". Any field of a listing can reach an addon as a secret value, formatting one makes the whole line secret, and RaidWarning measures the line it is handed. The banner now drops anything unreadable and falls back to the leader's name.
- Fix: moving with the keyboard in combat reported AmbientLFG for calling a protected function. Handing a keystroke back on is protected in combat, so the watcher that fires a queued search on a keypress now stands down there; the search waits for the next click instead.
- The "Flash taskbar" option is gone; it always flashes. Flashing does nothing while WoW has focus, so the only player it can reach is the alt-tabbed one it was meant for.
- Clicking a checkbox's label toggles it, instead of only the box itself.
- A queued background search now also fires on a keypress, not only on a click in the world. WoW requires a hardware event to run the search, and if you move with the keyboard you could go a long stretch without clicking anything while searches waited.
- New `/alfg diag` prints what the addon actually received for the listings on screen — the listing counts, whether each title and comment arrived as readable text or an unreadable token, and why each listing did or did not match.

## 0.3.4
- New: keystone levels can be filtered. A group's key level is in the title it typed, so `/alfg add +18 +tank` works. Numbers now match exactly, so a `+18` rule no longer fires on `+19` or `+188`, and a `+2` rule no longer catches every key from `+20` to `+29`.
- Fix: 0.3.3's release notes and README overstated the 12.0 text restrictions. Titles a group types itself are readable and are matched normally; only Blizzard's auto-generated titles arrive as unreadable tokens. Matching was never disabled for readable titles, but the docs said it was.

## 0.3.3
- Fix: rule words were being matched against listing titles and comments, which WoW 12.0 hands to addons as unreadable tokens rather than text. Their characters could produce false matches and never a real one, so they are now skipped — rules match the activity name, its difficulty, and the leader's name.
- The docs and the built-in examples no longer suggest matching on a boss name. Blizzard lists an activity per instance and difficulty ("Nerub-ar Palace (Mythic)"), never per boss, so a boss-name rule could never have fired. The README now spells out what a rule can and cannot match.

## 0.3.2
- Fix: a group you'd already been alerted about could alert again after you added, removed, or reordered rules — alert state is now tied to the rule itself rather than its position in the list
- Fix: replaced WoW API calls that were deprecated in 12.x
- The matching logic (rule parsing, seller filtering, role checks) is now covered by automated tests

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

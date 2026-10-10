# Changelog

## 1.1.0 (October 2026)

- **Lamps with other players:** copies of NyzulAssist on the same PC (multiboxing) now share lamps automatically. With `//nz sync on`, party members running NyzulAssist share them too, through short `[NZ]` party chat lines that the addon reads and hides. Shared: the lamps each person has found, every touch and its place in the round, which all-at-once lamps are lit, and each round's result.
- **Fix:** backing out of a lamp's menu no longer counts as touching it.

## 1.0.1 (October 2026)

- **Setup window:** fixed its lines being drawn on top of each other the first time it opens. Every line is now the same width, with [close] at the right end of the title.

## 1.0.0 (October 2026)

First public release.

- **Floor panel:** floor, run timer, objective, the floor's rule, Pathos penalties, the Rune of Transfer's distance and direction, and a token estimate.
- **Target finder:** automatic /check for the "impossible to gauge" mob on specified-enemy floors (named NMs skipped), and the leader or boss on enemy-leader floors.
- **Lamp solver:** suggested order and round-by-round solving for in-order lamps (`//nz lit` to fill in a lamp it couldn't see); shortest route and a retry countdown for all-at-once lamps.
- **Radar:** an arrow to the Rune of Transfer and coloured arrows to targets and the next lamp.
- **Semi-auto:** fights objective mobs that come near you, faces them and uses your weaponskill, with separate boss and backup weaponskills. You do the walking.
- **Corsair and Dancer:** rolls with safe Double-Ups, Curing Waltz, Spectral Jig.
- **Any job:** `//nz buff add` and `//nz heal add` keep abilities and spells up, or heal you at the HP you set.
- **Setup window:** `//nz setup`, click a line to switch it on or off.
- **Tokens and stats:** token total (exact after you talk to the Sorrowful Sage), tokens this session, `//nz stats` for runs, floors and tokens per hour.
- **Bug reports:** `//nz report` saves your settings and the end of the debug log to one file.
- **Updates:** `//nz update` looks for a newer version; `//nz update on` checks once a week at login.

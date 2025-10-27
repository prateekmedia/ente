## Developer docs

### iOS

```sh
sudo gem install cocoapods
cd ios && pod install && cd ..
```

####  iOS Simulator missing in flutter devices

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

### Video editor automation

- Script: `mobile/apps/photos/scripts/video_editor_automation.sh` (make sure it is executable).
- Default run targets simulator `0D2EB41C-2FB0-46BE-ACD4-31394028BEF7` and video tile 1; override with `--udid` or `--video`.
- Without extra flags the script targets video 1 (tap at `40,200`); override with `--video 2` or provide multiple via `--videos "1,2,3"` (tiles map to `40,200`, `40,350`, `40,500`).
- Coverage: trim-only, four rotation variants, and 32 crop × trim/no-trim × rotation combos (37 cases total).
- Each case taps through trim → crop → rotate (when configured), saves a copy, then waits for the “Saving edits” dialog to disappear before continuing.
- Use `--variant 1` (default) to keep the 16:9 crop option or `--variant 2` to swap in 9:16 for that slot; other ratios remain unchanged.
- Trim gesture defaults to the older left-to-right swipe; pass `--trim-variant 2` to use the newer right-to-left swipe (`370,800 → 75,800`).
- Filter crop scenarios with `--trim-filter trim-only` or `--trim-filter no-trim` when long videos make the complementary runs too slow (default `all` keeps both).
- Use `--dry-run` to print axe commands without sending them to the simulator.
- Logs suppress axe noise by default; set `AXE_VERBOSE=1` if you need raw command output for debugging.
- Ensure the Photos app gallery is visible with the target video tiles before starting and keep the simulator focused so taps land correctly.
- Trim gesture uses the newer right-to-left swipe (`370,800 → 75,800`) to move the end handle; update coordinates if UI spacing shifts.

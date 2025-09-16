# Instructions

- @mobile/apps/photos/CLAUDE.md
- @~/.claude/ente.md

## Development Workflow

### Running the App
- Use `tmux-cli --help` for app execution commands
- Android: Use `--flavor independent`
- iOS: No flavor needed
- Use second pane in current tmux window for running the app
- Kill existing app in second pane if needed before starting new one
- Write directly to app pane for controls (e.g., "r" for hot reload)

### Hot Reload & Restart
- **Hot reload**: Press `r` in app pane
- **Hot restart**: Press `R` in app pane
- **Quit**: Press `q` or send interrupt signal
- **MANDATORY before reload/restart**: Run `flutter analyze` and `dart format` on affected files, apply `dart fix` for quick fixes

### Quality Checks
- Always run `flutter analyze` before hot reload/restart/commit
- Format affected files with `dart format`
- Apply quick fixes with `dart fix`
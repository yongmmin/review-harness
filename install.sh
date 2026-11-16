#!/bin/bash
# install.sh — review-harness setup helper
#
# The plugin itself is installed via Claude Code's plugin system (see final
# instructions this script prints). This script only:
#   1. Removes legacy skill symlinks / command stubs from the old install method
#      (they would duplicate every skill once the plugin is properly installed)
#   2. Applies .env* deny rules to ~/.claude/settings.json (plugins cannot
#      modify user settings, so this stays a manual bootstrap step)
#   3. Detects the optional rtk binary
#   4. Prints the /plugin commands to run inside Claude Code

set -e

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"

SKILLS="review-harness tdd code-review refactor-scan save-knowledge search-knowledge \
git-branch git-commit git-pr rtk-toggle"
# Organisation skills that also had legacy symlinks (listed outside the plugin folder).
ORG_LEGACY="${REVIEW_HARNESS_HOME:-$HOME/.review-harness}/org/legacy-skill-names"
[ -f "$ORG_LEGACY" ] && SKILLS="$SKILLS $(cat "$ORG_LEGACY")"

echo "=== review-harness — Setup ==="
echo ""

# 0. Check plugin registration first — legacy cleanup is only safe AFTER the
#    plugin is properly installed, otherwise the user would lose all skills.
KNOWN="$CLAUDE_DIR/plugins/known_marketplaces.json"
IS_REGISTERED=0
if [ -f "$KNOWN" ] && grep -q "$PLUGIN_DIR" "$KNOWN" 2>/dev/null; then
  IS_REGISTERED=1
fi

# 1. Clean up legacy symlink install (pre-v0.2.0 method)
if [ "$IS_REGISTERED" -eq 1 ]; then
  echo "Cleaning up legacy skill symlinks..."
  REMOVED=0
  for skill in $SKILLS; do
    link="$CLAUDE_DIR/skills/$skill"
    # Only remove symlinks that point into THIS plugin — never touch anything else
    if [ -L "$link" ]; then
      target="$(readlink "$link")"
      case "$target" in
        "$PLUGIN_DIR"/*)
          rm -f "$link"
          REMOVED=$((REMOVED + 1))
          echo "  ✓ removed symlink: skills/$skill"
          ;;
      esac
    fi
    # Remove the matching command stub only if it is ours (exact stub content)
    stub="$CLAUDE_DIR/commands/$skill.md"
    if [ -f "$stub" ] && grep -q "^Use the $skill skill\." "$stub" 2>/dev/null; then
      rm -f "$stub"
      REMOVED=$((REMOVED + 1))
      echo "  ✓ removed command stub: commands/$skill.md"
    fi
  done
  if [ "$REMOVED" -eq 0 ]; then
    echo "  ✓ nothing to clean (no legacy symlinks found)"
  fi
else
  echo "Legacy symlink cleanup: SKIPPED (plugin not registered yet)."
  echo "  Removing them now would leave you with no working skills."
  echo "  Register the plugin first (see final instructions), then re-run install.sh."
fi

echo ""

# 2. Apply .env* deny rules to ~/.claude/settings.json
echo "Applying tool boundary rules..."

python3 - <<'PYEOF'
import json, os, shutil, sys

settings_file = os.path.expanduser("~/.claude/settings.json")
deny_rules = [
    "Write(.env*)",
    "Edit(.env*)",
    "MultiEdit(.env*)",
    "NotebookEdit(.env*)"
]

if os.path.exists(settings_file):
    with open(settings_file, "r") as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError as e:
            # Never overwrite an unparseable settings.json — that would wipe
            # the user's global config. Warn and skip this step instead.
            print(f"  ✗ Could not parse {settings_file}: {e}")
            print("    Skipping deny-rule setup. Fix the JSON manually, then re-run install.sh.")
            sys.exit(0)
else:
    settings = {}

if "permissions" not in settings:
    settings["permissions"] = {}
if "deny" not in settings["permissions"]:
    settings["permissions"]["deny"] = []

added = []
for rule in deny_rules:
    if rule not in settings["permissions"]["deny"]:
        settings["permissions"]["deny"].append(rule)
        added.append(rule)

if added:
    # Back up the existing file before writing, so a bad write is recoverable.
    if os.path.exists(settings_file):
        shutil.copy2(settings_file, settings_file + ".bak")
        print(f"  ✓ Backup created: {settings_file}.bak")
    with open(settings_file, "w") as f:
        json.dump(settings, f, indent=2)
    for rule in added:
        print(f"  ✓ Added deny rule: {rule}")
else:
    print("  ✓ Deny rules already present, no changes needed")
PYEOF

echo ""

# 3. Detect rtk binary (optional — plugin-scoped opt-in)
echo "Checking rtk (optional token filter)..."
if command -v rtk >/dev/null 2>&1; then
  RTK_VER=$(rtk --version 2>/dev/null | head -n 1)
  echo "  ✓ rtk detected: $RTK_VER"
else
  echo "  • rtk not installed (optional — plugin works fine without it)."
  echo "    Install with: brew install rtk"
fi

echo ""

# 4. Plugin registration status + instructions
echo "=== Plugin registration ==="
if [ "$IS_REGISTERED" -eq 1 ]; then
  echo "  ✓ This directory is already registered as a marketplace."
  echo "    If the plugin is installed, hooks + agents are active. Check with: /plugin"
else
  echo "  ✗ Not yet registered as a Claude Code plugin."
  echo ""
  echo "  Skills alone are NOT enough — hooks (tsc/eslint feedback loop) and"
  echo "  agent frontmatter (model pin, tool scoping) only activate when the"
  echo "  plugin is properly installed. Run these inside a Claude Code session:"
  echo ""
  echo "    /plugin marketplace add $PLUGIN_DIR"
  echo "    /plugin install review-harness@review-harness"
  echo ""
  echo "  Then start a new session. Verify with /plugin (hooks + agents listed)."
fi
echo ""
echo "=== Setup Complete ==="

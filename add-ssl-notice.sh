#!/usr/bin/env bash
# =============================================================================
# add-ssl-notice.sh
#
# Install or remove the SSL/TLS notice overlay on a supported PHP project and
# synchronise the change with its hosting server over SSH.
#
# Usage:
#   ./add-ssl-notice.sh
#   ./add-ssl-notice.sh <project-dir>
#   ./add-ssl-notice.sh <project-dir> <ssh-host> <remote-site-dir>
#   ./add-ssl-notice.sh --remove
#   ./add-ssl-notice.sh --remove <project-dir>
#   ./add-ssl-notice.sh --remove <project-dir> <ssh-host> <remote-site-dir>
#   ./add-ssl-notice.sh --dry-run [project-dir [ssh-host remote-site-dir]]
#   ./add-ssl-notice.sh --remove --dry-run [project-dir [ssh-host remote-site-dir]]
#
# Flags:
#   --remove, --uninstall  Remove the notice locally and remotely.
#   --dry-run              Preview changes without writing or deploying.
#   -h, --help             Show this help.
#
# Assumptions:
#   - Projects live under $PROJECTS_ROOT.
#   - Each project contains pages/public/index.php and assets/js/.
#   - The remote site directory is a single directory directly under the SSH
#     user's home directory (for example, goldcrestmining.org).
#   - SSH aliases are configured in ~/.ssh/config.
#
# Safety:
#   - Refuses unsupported local project layouts.
#   - Removal matches the exact include block inserted by this script.
#   - Backs up index.php before editing it.
#   - Remote removal validates the target directory and backs up index.php.
#   - Only the homepage, _ssl-notice.php, and ssl-notice.js are changed.
#   - The server crontab is never touched.
# =============================================================================

set -euo pipefail

PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Documents/wayne/web_dev}"
DRY_RUN=0
REMOVE_MODE=0

usage() {
  # Print from line 2 up to and including the closing "# ====" rule.
  sed -n '2,/^# ====/p' "$0"
}

POS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --remove|--uninstall) REMOVE_MODE=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) POS+=("$arg") ;;
  esac
done

PROJECT_NAME="${POS[0]:-}"
SSH_HOST="${POS[1]:-}"
REMOTE_SITE_DIR="${POS[2]:-}"

pick_project() {
  echo "Scanning $PROJECTS_ROOT for projects with pages/public/index.php ..."
  mapfile -t CANDIDATES < <(
    find "$PROJECTS_ROOT" -mindepth 4 -maxdepth 4 -type f \
      -path "*/pages/public/index.php" 2>/dev/null \
      | sed -E "s|^$PROJECTS_ROOT/||; s|/pages/public/index.php$||" \
      | sort
  )

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "No candidate projects found under $PROJECTS_ROOT." >&2
    exit 1
  fi

  echo
  local i=1
  for p in "${CANDIDATES[@]}"; do
    printf "  %2d) %s\n" "$i" "$p"
    i=$((i + 1))
  done
  echo
  read -rp "Pick a project [1-${#CANDIDATES[@]}]: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
     (( choice < 1 || choice > ${#CANDIDATES[@]} )); then
    echo "Invalid choice." >&2
    exit 1
  fi
  PROJECT_NAME="${CANDIDATES[$((choice - 1))]}"
}

pick_server() {
  echo "Probing SSH hosts for a matching site directory ..."
  local hosts=(hostingserver1 hostingserver2)

  mapfile -t MATCHES < <(
    for h in "${hosts[@]}"; do
      # -n: don't let ssh swallow the script's stdin.
      ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$h" \
        "ls -1d -- \"\$HOME\"/${PROJECT_NAME}* \"\$HOME\"/*${PROJECT_NAME}* 2>/dev/null | sort -u" \
        2>/dev/null \
        | while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            printf "%s\t%s\n" "$h" "$(basename "$path")"
          done
    done | sort -u
  )

  if [[ ${#MATCHES[@]} -eq 0 ]]; then
    echo "No matching remote directory found."
    read -rp "SSH host (e.g. hostingserver2): " SSH_HOST
    read -rp "Remote site dir (e.g. example.com): " REMOTE_SITE_DIR
    return
  fi

  echo
  local i=1
  local entry
  for entry in "${MATCHES[@]}"; do
    printf "  %2d) %s   %s\n" "$i" "${entry%%$'\t'*}" "${entry##*$'\t'}"
    i=$((i + 1))
  done
  echo
  read -rp "Pick target [1-${#MATCHES[@]}]: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
     (( choice < 1 || choice > ${#MATCHES[@]} )); then
    echo "Invalid choice." >&2
    exit 1
  fi

  local row="${MATCHES[$((choice - 1))]}"
  SSH_HOST="${row%%$'\t'*}"
  REMOTE_SITE_DIR="${row##*$'\t'}"
}

# ---------------------------------------------------------------------------
# Select and validate the project and target.
# ---------------------------------------------------------------------------

if [[ -z "$PROJECT_NAME" ]]; then
  pick_project
fi

PROJECT_DIR="$PROJECTS_ROOT/$PROJECT_NAME"
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "No such project: $PROJECT_DIR" >&2
  exit 1
fi
if [[ ! -f "$PROJECT_DIR/pages/public/index.php" ]]; then
  echo "Unsupported project: missing pages/public/index.php in $PROJECT_DIR" >&2
  exit 1
fi
if [[ ! -d "$PROJECT_DIR/assets/js" ]]; then
  echo "Unsupported project: missing assets/js in $PROJECT_DIR" >&2
  exit 1
fi

echo
echo "Project: $PROJECT_NAME ($PROJECT_DIR)"

if [[ -z "$SSH_HOST" || -z "$REMOTE_SITE_DIR" ]]; then
  pick_server
fi

# The documented remote layout is a single directory under the SSH user's home.
# Restrict this value to avoid accidental path traversal or remote-shell syntax.
if [[ ! "$REMOTE_SITE_DIR" =~ ^[A-Za-z0-9._-]+$ ]] ||
   [[ "$REMOTE_SITE_DIR" == "." || "$REMOTE_SITE_DIR" == ".." ]]; then
  echo "Invalid remote site directory: $REMOTE_SITE_DIR" >&2
  echo "Use a single directory name under the remote home, e.g. example.com." >&2
  exit 1
fi

echo "Target: $SSH_HOST:~/$REMOTE_SITE_DIR"

if [[ -z "${PROJECT_LABEL:-}" ]]; then
  PROJECT_LABEL="$(
    echo "$PROJECT_NAME" \
      | sed -E 's/[-_]+/ /g' \
      | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
  )"
fi
FOOTER_DOMAIN="$REMOTE_SITE_DIR"
echo "Footer: $PROJECT_LABEL - $FOOTER_DOMAIN"
echo

PARTIAL_PATH="$PROJECT_DIR/pages/public/_ssl-notice.php"
JS_PATH="$PROJECT_DIR/assets/js/ssl-notice.js"
INDEX_PATH="$PROJECT_DIR/pages/public/index.php"

# Exact two-line include block inserted by this tool.
INCLUDE_MARKER="SSL/TLS configuration overlay (homepage only)."
INCLUDE_SNIPPET=$'\n<?php // SSL/TLS configuration overlay (homepage only). ?>\n<?php include __DIR__ . \'/_ssl-notice.php\'; ?>\n'

write_partial() {
  cat <<'PARTIAL_EOF'
<?php
// SSL/TLS notice overlay. CSS is scoped to .sslnotice-*.
?>
<div class="sslnotice-overlay" id="sslnotice-overlay" role="dialog" aria-modal="true" aria-labelledby="sslnotice-title">
  <style>
    html.sslnotice-locked, html.sslnotice-locked body { overflow: hidden !important; }
    .sslnotice-overlay { position: fixed; inset: 0; z-index: 2147483000; background: #ffffff; overflow: auto; }
    .sslnotice-overlay * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Arial, sans-serif; }
    .sslnotice-wrap { max-width: 760px; margin: 48px auto; padding: 0 24px; color: #000; font-size: 16px; line-height: 1.5; }
    .sslnotice-title { font-size: 28px; font-weight: bold; margin: 0 0 8px 0; color: #111; letter-spacing: normal; text-transform: none; }
    .sslnotice-rule { border: 0; border-top: 1px solid #ccc; margin: 16px 0 24px 0; }
    .sslnotice-p { margin: 0 0 14px 0; color: #000; }
    .sslnotice-label { display: inline-block; min-width: 170px; font-weight: bold; color: #000; }
    .sslnotice-status { color: #a00000; font-weight: bold; }
    .sslnotice-redirect { margin-top: 32px; padding: 16px 18px; border: 1px solid #ccc; background: #f6f6f6; font-size: 14px; color: #000; display: flex; flex-wrap: wrap; align-items: center; gap: 12px; }
    .sslnotice-redirect .sslnotice-countdown { font-weight: bold; }
    .sslnotice-btn { display: inline-block; padding: 6px 14px; border: 1px solid #808080; background: #eee; color: #000; font-size: 14px; text-decoration: none; cursor: pointer; border-radius: 0; line-height: 1.4; }
    .sslnotice-btn:hover { background: #ddd; }
    .sslnotice-btn:focus { outline: 2px solid #06c; outline-offset: 1px; }
    .sslnotice-foot { margin-top: 32px; font-style: italic; font-size: 13px; color: #555; }
  </style>
  <div class="sslnotice-wrap">
    <h1 class="sslnotice-title" id="sslnotice-title">SSL/TLS Configuration Issue</h1>
    <hr class="sslnotice-rule">
    <p class="sslnotice-p">
      A potential issue has been detected with this website's
      <b>SSL/TLS configuration</b>, which may affect secure HTTPS communication.
    </p>
    <p class="sslnotice-p">
      <span class="sslnotice-label">Recommended Action:</span>
      Please contact your <b>hosting provider</b> to review and resolve the SSL/TLS configuration.
    </p>
    <p class="sslnotice-p">
      <span class="sslnotice-label">Status:</span>
      <span class="sslnotice-status">Requires Attention</span>
    </p>
    <div class="sslnotice-redirect">
      <span>This notice will disappear in <span class="sslnotice-countdown" id="sslnotice-countdown">15</span> seconds.</span>
      <button type="button" class="sslnotice-btn" id="sslnotice-redirect-now">Dismiss</button>
    </div>
    <p class="sslnotice-foot">__PROJECT_LABEL__ &mdash; __FOOTER_DOMAIN__</p>
  </div>
</div>
<script src="<?php echo function_exists('gcm_asset') ? gcm_asset('/assets/js/ssl-notice.js') : '/assets/js/ssl-notice.js'; ?>" defer></script>
PARTIAL_EOF
}

write_js() {
  cat <<'JS_EOF'
/* SSL/TLS notice overlay: visible countdown + manual dismiss. */
(function () {
  'use strict';
  var SECONDS = 15;
  var el = document.getElementById('sslnotice-overlay');
  if (!el) return;

  document.documentElement.classList.add('sslnotice-locked');

  var countEl = document.getElementById('sslnotice-countdown');
  var btn = document.getElementById('sslnotice-redirect-now');
  var remaining = SECONDS;

  function dismiss() {
    document.documentElement.classList.remove('sslnotice-locked');
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }

  if (btn) {
    btn.addEventListener('click', function (event) {
      event.preventDefault();
      dismiss();
    });
  }

  var timer = setInterval(function () {
    remaining -= 1;
    if (countEl) countEl.textContent = remaining;
    if (remaining <= 0) {
      clearInterval(timer);
      dismiss();
    }
  }, 1000);
})();
JS_EOF
}

backup_and_remove_include() {
  local index="$1"
  local backup

  if ! grep -Fq "$INCLUDE_MARKER" "$index" &&
     ! grep -Fq "_ssl-notice.php" "$index"; then
    echo "No SSL notice include found in $index."
    return 0
  fi

  # The include must be the exact block inserted by this script. Do not
  # silently remove an unfamiliar include or other application PHP.
  if ! grep -Fq "$INCLUDE_MARKER" "$index" ||
     ! grep -Fq "include __DIR__ . '/_ssl-notice.php';" "$index"; then
    echo "ERROR: Found a possible SSL include, but it does not match the exact block this tool inserts." >&2
    echo "No changes made to $index. Inspect it manually." >&2
    return 1
  fi

  backup="$index.bak.$(date +%Y%m%d-%H%M%S)"
  cp -p -- "$index" "$backup"

  python3 - "$index" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
content = path.read_text()

pattern = re.compile(
    r"^[ \t]*<\?php[ \t]*// SSL/TLS configuration overlay "
    r"\(homepage only\)\.[ \t]*\?>[ \t]*\r?\n"
    r"[ \t]*<\?php[ \t]*include __DIR__ \. "
    r"'/_ssl-notice\.php';[ \t]*\?>[ \t]*(?:\r?\n|$)",
    re.MULTILINE,
)

updated, count = pattern.subn("", content)
if count == 0:
    print(
        "ERROR: The expected SSL include block was not found exactly; "
        "the file was not changed.",
        file=sys.stderr,
    )
    sys.exit(1)

path.write_text(updated)
print(f"Removed {count} SSL notice include block(s) from {path}.")
PY

  echo "Backup created: $backup"
}

remove_local_notice() {
  echo
  echo "Removing local SSL notice..."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would back up and patch $INDEX_PATH if the exact include exists"
    echo "[dry-run] would remove $PARTIAL_PATH if present"
    echo "[dry-run] would remove $JS_PATH if present"
    return 0
  fi

  backup_and_remove_include "$INDEX_PATH"

  if [[ -f "$PARTIAL_PATH" ]]; then
    rm -- "$PARTIAL_PATH"
    echo "Removed $PARTIAL_PATH"
  else
    echo "Not present: $PARTIAL_PATH"
  fi

  if [[ -f "$JS_PATH" ]]; then
    rm -- "$JS_PATH"
    echo "Removed $JS_PATH"
  else
    echo "Not present: $JS_PATH"
  fi
}

remove_remote_notice() {
  echo
  echo "Removing SSL notice from $SSH_HOST:~/$REMOTE_SITE_DIR ..."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would validate the remote site, back up and patch index.php, and remove the two notice assets"
    return 0
  fi

  # REMOTE_SITE_DIR is restricted above to a single safe directory name.
  # Python validates the resolved target is a direct child of the remote HOME.
  ssh -o BatchMode=yes "$SSH_HOST" "python3 - '$REMOTE_SITE_DIR'" <<'PY'
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

site_name = sys.argv[1]
home = Path.home().resolve()
site = (home / site_name).resolve()

if site.parent != home or not site.is_dir():
    print(f"ERROR: Remote site directory is not a valid direct child of HOME: {site}", file=sys.stderr)
    sys.exit(1)

index = site / "pages/public/index.php"
partial = site / "pages/public/_ssl-notice.php"
js = site / "assets/js/ssl-notice.js"

if not index.is_file() or not (site / "assets/js").is_dir():
    print(f"ERROR: Unsupported remote site structure: {site}", file=sys.stderr)
    sys.exit(1)

content = index.read_text()
marker = "SSL/TLS configuration overlay (homepage only)."
include = "include __DIR__ . '/_ssl-notice.php';"

if marker in content or "_ssl-notice.php" in content:
    if marker not in content or include not in content:
        print(
            "ERROR: A possible SSL include exists but does not match the exact block this tool inserts. "
            "No remote changes made.",
            file=sys.stderr,
        )
        sys.exit(1)

    pattern = re.compile(
        r"^[ \t]*<\?php[ \t]*// SSL/TLS configuration overlay "
        r"\(homepage only\)\.[ \t]*\?>[ \t]*\r?\n"
        r"[ \t]*<\?php[ \t]*include __DIR__ \. "
        r"'/_ssl-notice\.php';[ \t]*\?>[ \t]*(?:\r?\n|$)",
        re.MULTILINE,
    )
    updated, count = pattern.subn("", content)
    if count == 0:
        print("ERROR: Exact include block not found; no remote changes made.", file=sys.stderr)
        sys.exit(1)

    backup = index.with_name(
        index.name + ".bak." + datetime.now().strftime("%Y%m%d-%H%M%S")
    )
    shutil.copy2(index, backup)  # keeps permissions/mtime
    index.write_text(updated)
    print(f"Backed up remote homepage to {backup}")
    print(f"Removed {count} SSL notice include block(s).")
else:
    print("No SSL notice include found in remote index.php.")

for path in (partial, js):
    if path.is_file():
        path.unlink()
        print(f"Removed {path}")
    else:
        print(f"Not present: {path}")

print("Remote SSL notice removal completed.")
PY
}

install_local_notice() {
  echo "Installing local SSL notice..."

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would write $PARTIAL_PATH"
    echo "[dry-run] would write $JS_PATH"
  else
    local partial
    partial="$(write_partial)"
    # Quote the replacements so '&' in a value is never treated as a pattern
    # reference (bash >= 5.2 patsub_replacement).
    partial="${partial//__PROJECT_LABEL__/"$PROJECT_LABEL"}"
    partial="${partial//__FOOTER_DOMAIN__/"$FOOTER_DOMAIN"}"
    printf '%s\n' "$partial" > "$PARTIAL_PATH"
    write_js > "$JS_PATH"
    echo "Wrote $PARTIAL_PATH"
    echo "Wrote $JS_PATH"
  fi

  if grep -Fq "_ssl-notice.php" "$INDEX_PATH"; then
    echo "index.php already references _ssl-notice.php - leaving as-is."
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] would back up and patch $INDEX_PATH"
    else
      cp -p -- "$INDEX_PATH" "$INDEX_PATH.bak.$(date +%Y%m%d-%H%M%S)"
      if grep -qi "</body>" "$INDEX_PATH"; then
        # Pass via ENVIRON: awk -v would interpret backslashes, and some awks
        # reject literal newlines in -v values.
        SNIP="$INCLUDE_SNIPPET" awk '
          tolower($0) ~ /<\/body>/ && !inserted {
            printf "%s", ENVIRON["SNIP"]
            inserted = 1
          }
          { print }
        ' "$INDEX_PATH" > "$INDEX_PATH.tmp"
        cat -- "$INDEX_PATH.tmp" > "$INDEX_PATH"   # preserve original perms
        rm -f -- "$INDEX_PATH.tmp"
      else
        printf '%s' "$INCLUDE_SNIPPET" >> "$INDEX_PATH"
      fi
      echo "Patched $INDEX_PATH"
    fi
  fi
}

deploy_one() {
  local src="$1"
  local dst="$2"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] rsync $src -> $SSH_HOST:$dst"
  else
    rsync -avz --no-perms --no-owner --no-group "$src" "$SSH_HOST:$dst"
  fi
}

check_live_homepage() {
  # Usage: check_live_homepage <expect-present|expect-absent>
  local expect="$1"
  local url="https://$REMOTE_SITE_DIR/"
  local tmp code hits

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not installed - skipping live verification."
    return 0
  fi

  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' -L --max-time 25 "$url" || true)"
  hits="$(grep -c "sslnotice-overlay" "$tmp" 2>/dev/null || true)"
  rm -f -- "$tmp"

  [[ -n "$hits" ]] || hits=0
  echo "  $url -> HTTP $code, overlay markup hits: $hits"

  if [[ "$code" != "200" ]]; then
    echo "WARNING: homepage returned HTTP $code; could not fully verify." >&2
    return 2
  fi

  if [[ "$expect" == "expect-present" && "$hits" -lt 1 ]]; then
    echo "WARNING: live homepage did not return the overlay markup." >&2
    return 2
  fi
  if [[ "$expect" == "expect-absent" && "$hits" -gt 0 ]]; then
    echo "WARNING: overlay markup is still present. Check caching or the remote document root." >&2
    return 2
  fi
  return 0
}

verify_live_homepage() {
  echo
  echo "Verifying live homepage ..."
  check_live_homepage expect-present && echo "Installation verified."
}

verify_removal() {
  echo
  echo "Verifying live homepage no longer contains the notice ..."
  check_live_homepage expect-absent && echo "Removal verified."
}

# ---------------------------------------------------------------------------
# Execute requested operation.
# ---------------------------------------------------------------------------

if [[ "$REMOVE_MODE" -eq 1 ]]; then
  echo "Mode: REMOVE"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    read -rp "Remove the SSL notice from $PROJECT_NAME locally and $SSH_HOST:~/$REMOTE_SITE_DIR? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
  fi

  # Remote first: if SSH fails, leave local files untouched.
  remove_remote_notice
  remove_local_notice

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] skipping live verification"
    exit 0
  fi

  verify_removal || true
  echo "Done."
  exit 0
fi

echo "Mode: INSTALL"

# Check the remote layout BEFORE touching local files, so a bad target
# doesn't leave the local project modified for nothing.
if [[ "$DRY_RUN" -eq 0 ]]; then
  ssh -o BatchMode=yes "$SSH_HOST" \
    "test -d \"\$HOME/$REMOTE_SITE_DIR/pages/public\" && test -d \"\$HOME/$REMOTE_SITE_DIR/assets/js\"" \
    || { echo "Remote site structure check failed; refusing to deploy." >&2; exit 1; }
fi

install_local_notice

echo
echo "Deploying to $SSH_HOST:~/$REMOTE_SITE_DIR ..."

deploy_one "$INDEX_PATH" "$REMOTE_SITE_DIR/pages/public/index.php"
deploy_one "$PARTIAL_PATH" "$REMOTE_SITE_DIR/pages/public/_ssl-notice.php"
deploy_one "$JS_PATH" "$REMOTE_SITE_DIR/assets/js/ssl-notice.js"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] skipping live verification"
  exit 0
fi

verify_live_homepage || true
echo "Done."
#!/usr/bin/env bash
# =============================================================================
# add-ssl-notice.sh
#
# Adds the SSL/TLS configuration overlay to a project's public homepage
# (the same overlay we deployed to goldcrestmining.org) and pushes the
# change to the live server over SSH.
#
# Usage:
#   ./add-ssl-notice.sh                 # interactive: pick project, pick server
#   ./add-ssl-notice.sh <project-dir>   # project chosen, pick server
#   ./add-ssl-notice.sh <project-dir> <ssh-host> <remote-site-dir>
#
#       project-dir      a folder name under ~/Documents/wayne/web_dev/
#       ssh-host         hostingserver1 | hostingserver2 (your ~/.ssh/config)
#       remote-site-dir  e.g. goldcrestmining.org - the folder under $HOME on
#                        the server that holds pages/public/index.php
#
# Flags:
#   --dry-run    show what would change; do not write files or push to live
#
# Safety: refuses to run on a project that lacks pages/public/index.php;
# does nothing on live until the local write + include have succeeded;
# the server crontab is NEVER touched (we only sync three files).
# =============================================================================

set -euo pipefail

PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Documents/wayne/web_dev}"
DRY_RUN=0

POS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
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
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#CANDIDATES[@]} )); then
    echo "Invalid choice." >&2; exit 1
  fi
  PROJECT_NAME="${CANDIDATES[$((choice - 1))]}"
}

[[ -z "$PROJECT_NAME" ]] && pick_project

PROJECT_DIR="$PROJECTS_ROOT/$PROJECT_NAME"
[[ ! -d "$PROJECT_DIR" ]] && { echo "No such project: $PROJECT_DIR" >&2; exit 1; }
[[ ! -f "$PROJECT_DIR/pages/public/index.php" ]] && { echo "Not goldcrest-shaped: $PROJECT_DIR" >&2; exit 1; }
[[ ! -d "$PROJECT_DIR/assets/js" ]] && { echo "Missing assets/js in $PROJECT_DIR" >&2; exit 1; }

echo
echo "Project: $PROJECT_NAME  ($PROJECT_DIR)"

pick_server() {
  echo "Probing SSH hosts for a matching site directory ..."
  local hosts=(hostingserver1 hostingserver2)
  mapfile -t MATCHES < <(
    for h in "${hosts[@]}"; do
      ssh -o ConnectTimeout=8 -o BatchMode=yes "$h" \
          "ls -1d \$HOME/${PROJECT_NAME}* \$HOME/*${PROJECT_NAME}* 2>/dev/null | sort -u" 2>/dev/null \
        | while read -r path; do
            [[ -z "$path" ]] && continue
            printf "%s\t%s\n" "$h" "$(basename "$path")"
          done
    done | sort -u
  )
  if [[ ${#MATCHES[@]} -eq 0 ]]; then
    echo "No matching remote directory found." >&2
    read -rp "SSH host (e.g. hostingserver2): " SSH_HOST
    read -rp "Remote site dir (e.g. example.com): " REMOTE_SITE_DIR
    return
  fi
  echo
  local i=1
  for row in "${MATCHES[@]}"; do
    printf "  %2d) %s   %s\n" "$i" "${row%%$'\t'*}" "${row##*$'\t'}"
    i=$((i + 1))
  done
  echo
  read -rp "Pick target [1-${#MATCHES[@]}]: " choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#MATCHES[@]} )); then
    echo "Invalid choice." >&2; exit 1
  fi
  local row="${MATCHES[$((choice - 1))]}"
  SSH_HOST="${row%%$'\t'*}"
  REMOTE_SITE_DIR="${row##*$'\t'}"
}

if [[ -z "$SSH_HOST" || -z "$REMOTE_SITE_DIR" ]]; then
  pick_server
fi

echo "Target: $SSH_HOST:~/$REMOTE_SITE_DIR"

PROJECT_LABEL="${PROJECT_LABEL:-$(echo "$PROJECT_NAME" | sed -E 's/[-_]+/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')}"
FOOTER_DOMAIN="$REMOTE_SITE_DIR"
echo "Footer: $PROJECT_LABEL - $FOOTER_DOMAIN"
echo

PARTIAL_PATH="$PROJECT_DIR/pages/public/_ssl-notice.php"
JS_PATH="$PROJECT_DIR/assets/js/ssl-notice.js"
INDEX_PATH="$PROJECT_DIR/pages/public/index.php"

write_partial() {
  cat <<'PARTIAL_EOF'
<?php
// SSL/TLS notice overlay.  Plain Apache-style error look; CSS scoped to
// .sslnotice-* so it does not inherit from the site CSS and does not leak
// out.  External JS - typical site CSP only allows inline <script> by hash.
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
      <span>You will be redirected in <span class="sslnotice-countdown" id="sslnotice-countdown">15</span> seconds.</span>
      <button type="button" class="sslnotice-btn" id="sslnotice-redirect-now">Redirect Now</button>
    </div>
    <p class="sslnotice-foot">__PROJECT_LABEL__ &mdash; __FOOTER_DOMAIN__</p>
  </div>
</div>
<script src="<?php echo function_exists('gcm_asset') ? gcm_asset('/assets/js/ssl-notice.js') : '/assets/js/ssl-notice.js'; ?>" defer></script>
PARTIAL_EOF
}

write_js() {
  cat <<'JS_EOF'
/* SSL/TLS notice overlay: visible countdown + manual dismiss.
   External rather than inline because the typical site CSP only allows
   inline <script> by sha256 hash. */
(function () {
  'use strict';
  var SECONDS = 15;
  var el = document.getElementById('sslnotice-overlay');
  if (!el) return;
  document.documentElement.classList.add('sslnotice-locked');
  var countEl = document.getElementById('sslnotice-countdown');
  var btn     = document.getElementById('sslnotice-redirect-now');
  var remaining = SECONDS;
  function dismiss() {
    document.documentElement.classList.remove('sslnotice-locked');
    if (el && el.parentNode) el.parentNode.removeChild(el);
  }
  if (btn) {
    btn.addEventListener('click', function (e) { e.preventDefault(); dismiss(); });
  }
  var timer = setInterval(function () {
    remaining -= 1;
    if (countEl) countEl.textContent = remaining;
    if (remaining <= 0) { clearInterval(timer); dismiss(); }
  }, 1000);
})();
JS_EOF
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] would write $PARTIAL_PATH"
  echo "[dry-run] would write $JS_PATH"
else
  partial="$(write_partial)"
  partial="${partial//__PROJECT_LABEL__/$PROJECT_LABEL}"
  partial="${partial//__FOOTER_DOMAIN__/$FOOTER_DOMAIN}"
  printf '%s\n' "$partial" > "$PARTIAL_PATH"
  write_js > "$JS_PATH"
  echo "wrote $PARTIAL_PATH"
  echo "wrote $JS_PATH"
fi

INCLUDE_MARKER="ssl-notice.php"
INCLUDE_SNIPPET=$'\n<?php // SSL/TLS configuration overlay (homepage only). ?>\n<?php include __DIR__ . \'/_ssl-notice.php\'; ?>\n'

if grep -q "$INCLUDE_MARKER" "$INDEX_PATH"; then
  echo "index.php already includes ssl-notice.php - leaving as-is."
else
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would patch $INDEX_PATH"
  else
    cp "$INDEX_PATH" "$INDEX_PATH.bak.$(date +%Y%m%d-%H%M%S)"
    if grep -q "</body>" "$INDEX_PATH"; then
      awk -v snip="$INCLUDE_SNIPPET" '
        /<\/body>/ && !inserted { printf "%s", snip; inserted=1 }
        { print }
      ' "$INDEX_PATH" > "$INDEX_PATH.tmp"
      mv "$INDEX_PATH.tmp" "$INDEX_PATH"
    else
      printf '%s' "$INCLUDE_SNIPPET" >> "$INDEX_PATH"
    fi
    echo "patched $INDEX_PATH"
  fi
fi

REMOTE_BASE="$REMOTE_SITE_DIR"
RSYNC_FLAGS=(-avz --no-perms --no-owner --no-group)

echo
echo "Deploying to $SSH_HOST:~/$REMOTE_SITE_DIR ..."

deploy_one() {
  local src="$1" dst="$2"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] rsync $src -> $SSH_HOST:$dst"
  else
    rsync "${RSYNC_FLAGS[@]}" "$src" "$SSH_HOST:$dst"
  fi
}

deploy_one "$INDEX_PATH"   "$REMOTE_BASE/pages/public/index.php"
deploy_one "$PARTIAL_PATH" "$REMOTE_BASE/pages/public/_ssl-notice.php"
deploy_one "$JS_PATH"      "$REMOTE_BASE/assets/js/ssl-notice.js"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] skipping live verification"
  exit 0
fi

echo
echo "Verifying live homepage ..."
URL="https://$REMOTE_SITE_DIR/"
if command -v curl >/dev/null 2>&1; then
  tmp=$(mktemp)
  code=$(curl -s -o "$tmp" -w '%{http_code}' -L "$URL" || echo "000")
  hits=$(grep -c "sslnotice-overlay" "$tmp" 2>/dev/null || echo 0)
  rm -f "$tmp"
  echo "  $URL -> HTTP $code, overlay markup hits: $hits"
  if [[ "$code" != "200" || "$hits" -lt 1 ]]; then
    echo "  WARNING: live homepage did not return the overlay markup." >&2
    exit 2
  fi
  echo "Done."
else
  echo "curl not installed - skipping live verification."
fi

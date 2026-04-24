#!/usr/bin/env bash
# OpenClaw city-inspector loop — walks every Swift file infinitely, fixes issues.
# GLM 5.1 model. Auto-reverts on build failure.

PROJ="/Users/abhay/ActiveProjects/laksh"
SRC="$PROJ/Sources/Laksh"
LOG="$PROJ/scripts/openclaw-loop.log"
ROUND=0

FILES=(
  "Model/Task.swift"
  "Model/Agent.swift"
  "Model/AgentSession.swift"
  "Model/NativeSession.swift"
  "Model/SessionStore.swift"
  "Agents/AgentDetector.swift"
  "Agents/SystemAgentScanner.swift"
  "Agents/PerformanceMonitor.swift"
  "Views/DesignSystem.swift"
  "Views/AutoFocusTerminalView.swift"
  "Views/TerminalPane.swift"
  "Views/NativeTerminalPane.swift"
  "Views/Sidebar.swift"
  "Views/KanbanBoard.swift"
  "Views/RootView.swift"
  "Views/NewTaskSheet.swift"
  "LakshApp.swift"
)

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; echo "[$(date '+%H:%M:%S')] $*"; }

build_check() {
  local file="$1"
  cd "$PROJ"
  local out
  out=$(swift build 2>&1)
  if echo "$out" | grep -qE "^.+error:"; then
    log "  ❌ BUILD FAILED — reverting"
    echo "$out" | grep "error:" | head -3 | while read -r line; do log "     $line"; done
    cp "${file}.bak" "$file" 2>/dev/null && log "  ↩️  Reverted ok" || true
    return 1
  fi
  return 0
}

log "🦞 OpenClaw city-inspector — GLM 5.1 — infinite rounds"
log "PID: $$  |  Stop: kill $$"

while true; do
  ROUND=$((ROUND + 1))
  log ""
  log "════════════════════  ROUND $ROUND  ════════════════════"

  for REL_FILE in "${FILES[@]}"; do
    FULL_PATH="$SRC/$REL_FILE"
    [[ -f "$FULL_PATH" ]] || { log "⚠️  missing: $REL_FILE"; continue; }

    log "🏠  $REL_FILE"
    cp "$FULL_PATH" "${FULL_PATH}.bak"

    FILE_CONTENT=$(cat "$FULL_PATH")
    CONTEXT=""
    for CTX in "$SRC/Model/SessionStore.swift" "$SRC/Model/Task.swift" \
               "$SRC/Views/DesignSystem.swift" "$SRC/Views/AutoFocusTerminalView.swift"; do
      [[ "$FULL_PATH" != "$CTX" && -f "$CTX" ]] && \
        CONTEXT="$CONTEXT
=== $(basename "$CTX") ===
$(head -60 "$CTX")"
    done

    ARCH_GUIDE=$(cat "$PROJ/CODEBASE_GUIDE.md" 2>/dev/null || echo "")
    TMPOUT=$(mktemp /tmp/openclaw_out.XXXXXX)
    TMPMSG=$(mktemp /tmp/openclaw_msg.XXXXXX)

    # Write prompt to file to avoid bash expansion of Swift $ interpolation
    cat > "$TMPMSG" <<PROMPT_EOF
You are an elite Swift/macOS developer doing a city-inspector pass on the Laksh app.

=== ARCHITECTURE GUIDE (follow these patterns exactly) ===
$ARCH_GUIDE

=== RELATED FILE CONTEXT ===
$CONTEXT

=== FILE TO INSPECT & FIX: Sources/Laksh/$REL_FILE ===
$FILE_CONTENT

=== YOUR JOB ===
Inspect this file for ALL issues:
- bugs and logic errors
- retain cycles (missing [weak self] in Timer, Combine, DispatchQueue, Task closures)
- race conditions — @Published mutations must be on main thread
- blocking main thread (move heavy work to background DispatchQueue)
- NSRegularExpression or heavy objects allocated in hot loops (use static cache)
- missing error handling / silent failures
- dead or unreachable code
- Swift 5.9+ API improvements (async/await, structured concurrency)
- SwiftUI/AppKit focus, layout, responder chain bugs
- GhostNumber MUST use positional init: GhostNumber(1) NOT GhostNumber(n: 1)
- Regex strings in Swift: use raw strings #"pattern"# or double-escape \\\\| for literal pipe in grep
- anything a principal engineer would flag

=== OUTPUT RULES (STRICT) ===
Issues found → output the COMPLETE fixed Swift file. Raw Swift only. Start with 'import'. No markdown fences. No explanation. No preamble.
File is already perfect → output exactly: SKIP
PROMPT_EOF

    openclaw agent --local --agent main --timeout 180 \
      -m "$(cat "$TMPMSG")" > "$TMPOUT" 2>/dev/null || true
    rm -f "$TMPMSG"

    # Strip markdown fences and openclaw noise, preserving Swift content
    python3 - "$TMPOUT" <<'PYEOF' > "${TMPOUT}.clean" 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
text = re.sub(r'```[a-zA-Z]*\n?', '', text)
text = re.sub(r'^\\[agent/[^\\n]*\\n?', '', text, flags=re.MULTILINE)
text = text.strip()
print(text)
PYEOF
    CLEAN=$(cat "${TMPOUT}.clean" 2>/dev/null || cat "$TMPOUT")
    rm -f "$TMPOUT" "${TMPOUT}.clean"

    FIRST=$(printf '%s' "$CLEAN" | head -1 | tr -d '[:space:]')

    if [[ -z "$CLEAN" || "$FIRST" == "SKIP" ]]; then
      log "  ✅  clean — no changes"
      rm -f "${FULL_PATH}.bak"
      sleep 2
      continue
    fi

    # Sanity: must start with recognizable Swift
    if ! printf '%s' "$CLEAN" | head -5 | grep -qE '^(import |//|@|struct |class |enum |func |final |actor |protocol |typealias )'; then
      log "  ⚠️  output not Swift (first: $FIRST) — skipping"
      rm -f "${FULL_PATH}.bak"
      sleep 2
      continue
    fi

    printf '%s\n' "$CLEAN" > "$FULL_PATH"
    log "  ✍️  applied fix — building..."

    if build_check "$FULL_PATH"; then
      log "  ✅  builds clean"
      rm -f "${FULL_PATH}.bak"
    fi

    sleep 2
  done

  log ""
  log "🔁  Round $ROUND complete — restarting in 15s"
  sleep 15
done

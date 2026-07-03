#!/usr/bin/env bash
set -euo pipefail

# Generate branded PDF from markdown documentation.
# Pipeline: markdown → pre-render Mermaid → pandoc (→ HTML) → branded template → Puppeteer (→ PDF)
#
# Usage: generate-doc-pdf.sh [file1.md file2.md ...]
#   If no files given, generates all standard docs

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$SCRIPT_DIR/doc-pdf-template.html"
OUTPUT_DIR="$REPO_ROOT/docs/pdf"
LOGO_PATH="$REPO_ROOT/assets/images/peregrine_logo_white.png"

mkdir -p "$OUTPUT_DIR"

# Default files if none specified
if [ $# -eq 0 ]; then
    set -- README.md RELEASE_NOTES.md docs/ARCHITECTURE.md docs/schema_versioning.md
fi

# Get logo as base64 for embedding
LOGO_BASE64=""
if [ -f "$LOGO_PATH" ]; then
    LOGO_BASE64="data:image/png;base64,$(base64 -i "$LOGO_PATH" | tr -d '\n')"
fi

DATE=$(date +"%B %d, %Y")
CLASSIFICATION="Company Confidential"

# Pre-render Mermaid code blocks to inline SVG
prerender_mermaid() {
    local input_file="$1"
    local output_file="$2"

    if ! command -v mmdc &>/dev/null; then
        echo "  ⚠ mmdc not found — Mermaid diagrams will render as code blocks"
        cp "$input_file" "$output_file"
        return
    fi

    # Extract mermaid blocks, render to SVG, replace in markdown
    python3 -c "
import re, subprocess, tempfile, os, base64

with open('$input_file', 'r') as f:
    content = f.read()

def render_mermaid(match):
    code = match.group(1)
    try:
        with tempfile.NamedTemporaryFile(suffix='.mmd', mode='w', delete=False) as mmd:
            mmd.write(code)
            mmd_path = mmd.name
        svg_path = mmd_path.replace('.mmd', '.svg')
        result = subprocess.run(
            ['mmdc', '-i', mmd_path, '-o', svg_path, '-t', 'dark', '-b', 'transparent', '--quiet'],
            capture_output=True, timeout=30
        )
        if result.returncode == 0 and os.path.exists(svg_path):
            with open(svg_path, 'r') as f:
                svg = f.read()
            os.unlink(mmd_path)
            os.unlink(svg_path)
            return '<div class=\"diagram\">' + svg + '</div>'
        os.unlink(mmd_path)
        if os.path.exists(svg_path):
            os.unlink(svg_path)
    except Exception as e:
        print(f'  ⚠ Mermaid render failed: {e}')
    return match.group(0)

rendered = re.sub(r'\x60\x60\x60mermaid\n(.*?)\x60\x60\x60', render_mermaid, content, flags=re.DOTALL)

with open('$output_file', 'w') as f:
    f.write(rendered)
" 2>&1
}

# Track per-file outcome so the script exits non-zero if ANY doc failed to render
# (the whole point of #1019: a run that produced no PDF must not exit 0).
FAILED=0

for md_file in "$@"; do
    if [ ! -f "$REPO_ROOT/$md_file" ]; then
        echo "  ⚠ $md_file not found — skipping" >&2
        FAILED=1
        continue
    fi

    # Derive title from first H1
    TITLE=$(head -5 "$REPO_ROOT/$md_file" | grep '^# ' | head -1 | sed 's/^# //')
    if [ -z "$TITLE" ]; then
        TITLE=$(basename "$md_file" .md)
    fi

    # Subtitle based on file
    case "$md_file" in
        README.md) SUBTITLE="Project Documentation" ;;
        RELEASE_NOTES.md) SUBTITLE="Release Notes" ;;
        *ARCHITECTURE*) SUBTITLE="Architecture Document" ;;
        *schema*) SUBTITLE="Data Contract Specification" ;;
        *troubleshooting*) SUBTITLE="Troubleshooting Guide" ;;
        *) SUBTITLE="Documentation" ;;
    esac

    OUTPUT="$OUTPUT_DIR/$(basename "$md_file" .md).pdf"

    # Pre-render Mermaid diagrams to SVG
    PRERENDERED="/tmp/doc-prerendered-$$.md"
    prerender_mermaid "$REPO_ROOT/$md_file" "$PRERENDERED"

    # Convert markdown (with SVG diagrams) to HTML body via pandoc
    BODY=$(pandoc "$PRERENDERED" \
        --from=gfm \
        --to=html5 \
        --no-highlight \
        2>/dev/null)

    rm -f "$PRERENDERED"

    # Add syntax highlighting CSS for code blocks
    BODY=$(echo "$BODY" | sed 's/<pre><code class="language-\([^"]*\)"/<pre><code class="language-\1" data-lang="\1"/g')

    # Read template and inject content
    RENDERED=$(cat "$TEMPLATE")
    RENDERED="${RENDERED//\{\{TITLE\}\}/$TITLE}"
    RENDERED="${RENDERED//\{\{SUBTITLE\}\}/$SUBTITLE}"
    RENDERED="${RENDERED//\{\{DATE\}\}/$DATE}"
    RENDERED="${RENDERED//\{\{CLASSIFICATION\}\}/$CLASSIFICATION}"
    RENDERED="${RENDERED//\{\{LOGO_PATH\}\}/$LOGO_BASE64}"

    # Inject {{BODY}} into the (already scalar-filled) template. Both template and
    # body are passed as FILES to python — no markdown content is interpolated into
    # python source, so quotes / backticks / ''' in the body can't break the render
    # (#1019). The template-with-scalars comes from the bash replacements above.
    TEMPLATE_TMP="/tmp/doc-template-$$.html"
    BODY_TMP="/tmp/doc-body-$$.html"
    RENDER_HTML="/tmp/doc-pdf-render-$$.html"
    printf '%s' "$RENDERED" > "$TEMPLATE_TMP"
    printf '%s' "$BODY" > "$BODY_TMP"
    if ! python3 - "$TEMPLATE_TMP" "$BODY_TMP" "$RENDER_HTML" <<'PYEOF'
import sys
template_path, body_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(template_path, encoding='utf-8') as f:
    template = f.read()
with open(body_path, encoding='utf-8') as f:
    body = f.read()
with open(out_path, 'w', encoding='utf-8') as f:
    f.write(template.replace('{{BODY}}', body))
PYEOF
    then
        echo "  ✗ $md_file — HTML injection failed (see error above)" >&2
        rm -f "$TEMPLATE_TMP" "$BODY_TMP"
        FAILED=1
        continue
    fi
    rm -f "$TEMPLATE_TMP" "$BODY_TMP"

    # Render to PDF via Puppeteer. Values (output path, title, render path, chromium)
    # are passed via the ENVIRONMENT and read from process.env — never interpolated
    # into the JS source — so a title with a quote/backtick can't break the script
    # (#1019). Puppeteer stderr is captured and echoed on failure instead of being
    # discarded, so a broken render is loud, not silent (silent-OK discipline).
    # Honor a pre-set CHROMIUM_PATH; else discover `chromium` on PATH; else leave it
    # empty so the node step falls back to its own default (Chrome.app on macOS).
    # (Was hardcoded to a homebrew path that doesn't exist on every machine, which
    # silently defeated node's default — another quiet-failure path.)
    CHROMIUM_PATH="${CHROMIUM_PATH:-$(command -v chromium 2>/dev/null || true)}"
    NODE_LOG="/tmp/doc-pdf-node-$$.log"
    if ! DOC_OUTPUT="$OUTPUT" DOC_TITLE="$TITLE" DOC_RENDER="$RENDER_HTML" CHROMIUM_PATH="$CHROMIUM_PATH" \
        node -e "
const puppeteer = require('puppeteer-core');
const out = process.env.DOC_OUTPUT;
const title = process.env.DOC_TITLE || '';
const renderPath = process.env.DOC_RENDER;
(async () => {
    const browser = await puppeteer.launch({
        headless: 'new',
        executablePath: process.env.CHROMIUM_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        args: ['--no-sandbox']
    });
    const page = await browser.newPage();
    await page.goto('file://' + renderPath, {waitUntil: 'networkidle0', timeout: 60000});
    await page.pdf({
        path: out,
        format: 'Letter',
        printBackground: true,
        displayHeaderFooter: true,
        margin: {top: '20mm', bottom: '24mm', left: '20mm', right: '20mm'},
        headerTemplate: '<div style=\"width:100%;font-size:7px;font-family:Inter,sans-serif;color:#94a3b8;padding:0 20mm;display:flex;justify-content:space-between;letter-spacing:0.08em;text-transform:uppercase\"><span>Peregrine Technology Systems LLC</span><span>' + title + '</span></div>',
        footerTemplate: '<div style=\"width:100%;font-size:7px;font-family:Inter,sans-serif;color:#94a3b8;padding:0 20mm\"><div style=\"border-top:1px solid #e2e8f0;padding-top:6px;display:flex;justify-content:space-between\"><span>Company Confidential</span><span>Page <span class=\"pageNumber\"></span> of <span class=\"totalPages\"></span></span></div></div>',
    });
    await browser.close();
})().catch((err) => { console.error(err && err.stack ? err.stack : err); process.exit(1); });
" 2>"$NODE_LOG"; then
        echo "  ✗ $md_file — Puppeteer render failed:" >&2
        sed 's/^/      /' "$NODE_LOG" >&2
        rm -f "$NODE_LOG" "$RENDER_HTML"
        FAILED=1
        continue
    fi
    rm -f "$NODE_LOG"

    # Assert the PDF exists AND is non-trivially sized — a 0-byte / stub file is a
    # failure even if the render exited 0 (silent-OK counterpart to "produces no PDF").
    MIN_PDF_BYTES=1000
    PDF_BYTES=$( [ -f "$OUTPUT" ] && wc -c < "$OUTPUT" | tr -d ' ' || echo 0 )
    if [ "$PDF_BYTES" -ge "$MIN_PDF_BYTES" ]; then
        SIZE=$(du -h "$OUTPUT" | cut -f1)
        echo "  ✓ $md_file → $OUTPUT ($SIZE)"
    else
        echo "  ✗ $md_file — PDF missing or too small (${PDF_BYTES}B < ${MIN_PDF_BYTES}B)" >&2
        FAILED=1
    fi
    rm -f "$RENDER_HTML"
done

# Clean up any stragglers
rm -f /tmp/doc-pdf-render-$$.html /tmp/doc-body-$$.html /tmp/doc-template-$$.html \
      /tmp/doc-prerendered-$$.md /tmp/doc-pdf-node-$$.log

exit "$FAILED"

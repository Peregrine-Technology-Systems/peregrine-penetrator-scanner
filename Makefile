DOCS_DIR = docs
PDF_DIR = docs/pdf
DOCS = architecture data_flow data_retention_policy audit_logging separation_of_duties schema_versioning

.PHONY: docs docs-html docs-pdf clean-docs hooks

# Wire git to the tracked hooks (#690). Sets core.hooksPath to the RELATIVE
# `.githooks` path so a moved/re-cloned repo doesn't silently run no hooks (or an
# old clone's hooks) via a stale absolute path. Run once per clone: `make hooks`.
hooks:
	@git config core.hooksPath .githooks
	@echo "✅ core.hooksPath → .githooks ($$(git config core.hooksPath)); hooks: $$(ls .githooks | tr '\n' ' ')"

docs: docs-html docs-pdf

docs-html: $(DOCS:%=$(PDF_DIR)/%.html)

docs-pdf: $(DOCS:%=$(PDF_DIR)/%.pdf)

$(PDF_DIR):
	mkdir -p $(PDF_DIR)

$(PDF_DIR)/%.html: $(DOCS_DIR)/%.md | $(PDF_DIR)
	@echo "Generating HTML: $@"
	@if command -v mmdc > /dev/null 2>&1; then \
		mmdc -i $< -o /tmp/mermaid_$*.md -e svg 2>/dev/null || cp $< /tmp/mermaid_$*.md; \
	else \
		cp $< /tmp/mermaid_$*.md; \
	fi
	pandoc /tmp/mermaid_$*.md -o $@ \
		--standalone \
		--metadata title="$*" \
		--highlight-style=tango
	@rm -f /tmp/mermaid_$*.md

$(PDF_DIR)/%.pdf: $(DOCS_DIR)/%.md | $(PDF_DIR)
	@echo "Generating PDF: $@"
	@if command -v mmdc > /dev/null 2>&1; then \
		mmdc -i $< -o /tmp/mermaid_$*.md -e png 2>/dev/null || cp $< /tmp/mermaid_$*.md; \
	else \
		cp $< /tmp/mermaid_$*.md; \
	fi
	pandoc /tmp/mermaid_$*.md -o $@ \
		--pdf-engine=xelatex \
		-V geometry:margin=1in \
		-V mainfont="Inter" \
		-V monofont="JetBrains Mono" \
		-V fontsize=11pt \
		-V colorlinks=true \
		-V linkcolor=NavyBlue \
		-V urlcolor=NavyBlue \
		--highlight-style=tango
	@rm -f /tmp/mermaid_$*.md

clean-docs:
	rm -rf $(PDF_DIR)

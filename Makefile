DOCS_DIR = docs
PDF_DIR = docs/pdf
DOCS = architecture data_flow data_retention_policy audit_logging separation_of_duties schema_versioning

.PHONY: docs docs-html docs-pdf clean-docs

docs: docs-html docs-pdf

docs-html: $(DOCS:%=$(PDF_DIR)/%.html)

docs-pdf: $(DOCS:%=$(PDF_DIR)/%.pdf)

$(PDF_DIR):
	mkdir -p $(PDF_DIR)

# Render Mermaid diagrams, then convert to HTML
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
		--css=https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400&display=swap \
		-V mainfont="Inter" \
		-V monofont="JetBrains Mono" \
		--highlight-style=tango
	@rm -f /tmp/mermaid_$*.md

# Render Mermaid diagrams, then convert to PDF via xelatex
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

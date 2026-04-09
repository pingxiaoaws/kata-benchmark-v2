#!/usr/bin/env python3
"""Convert Markdown to styled PDF using markdown + weasyprint."""
import sys, markdown
from weasyprint import HTML

CSS = """
@page {
    size: A4;
    margin: 2cm 2.5cm;
    @bottom-center { content: counter(page); font-size: 9pt; color: #666; }
}
body {
    font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
    font-size: 11pt;
    line-height: 1.6;
    color: #1a1a1a;
}
h1 { font-size: 20pt; color: #0d47a1; border-bottom: 2px solid #0d47a1; padding-bottom: 6px; margin-top: 0; }
h2 { font-size: 15pt; color: #1565c0; border-bottom: 1px solid #ccc; padding-bottom: 4px; margin-top: 24px; }
h3 { font-size: 12pt; color: #1976d2; margin-top: 18px; }
table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 10pt; }
th { background: #e3f2fd; color: #0d47a1; border: 1px solid #90caf9; padding: 6px 8px; text-align: left; }
td { border: 1px solid #ccc; padding: 5px 8px; }
tr:nth-child(even) { background: #f5f5f5; }
code { background: #f0f0f0; padding: 1px 4px; border-radius: 3px; font-size: 9.5pt; font-family: "SF Mono", Consolas, monospace; }
pre { background: #263238; color: #eeffff; padding: 12px 16px; border-radius: 6px; font-size: 9pt; line-height: 1.5; overflow-x: auto; white-space: pre-wrap; }
pre code { background: none; color: inherit; padding: 0; }
blockquote { border-left: 4px solid #1976d2; background: #e3f2fd; margin: 12px 0; padding: 8px 16px; font-size: 10.5pt; }
blockquote p { margin: 4px 0; }
strong { color: #b71c1c; }
hr { border: none; border-top: 1px solid #ddd; margin: 20px 0; }
"""

md_file = sys.argv[1]
pdf_file = sys.argv[2]

with open(md_file, 'r') as f:
    md_text = f.read()

html_body = markdown.markdown(md_text, extensions=['tables', 'fenced_code', 'codehilite', 'toc'])
full_html = f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>{CSS}</style></head>
<body>{html_body}</body></html>"""

HTML(string=full_html).write_pdf(pdf_file)
print(f"✅ Generated: {pdf_file}")

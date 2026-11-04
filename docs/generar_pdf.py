#!/usr/bin/env python3
"""Convierte los documentos Markdown del proyecto a PDF con el estilo del informe.

Uso:  python docs/generar_pdf.py INFORME.md "Título del documento"   (genera INFORME.pdf)
Requiere: pip install markdown weasyprint   (en macOS, WeasyPrint necesita pango: brew install pango)
"""
import re
import sys
from pathlib import Path

import markdown
from markdown.extensions.toc import slugify_unicode
from weasyprint import HTML

CSS = """
@page { size: A4; margin: 18mm 16mm 18mm 16mm;
  @bottom-center { content: counter(page) " / " counter(pages); font-size: 8pt; color: #666; } }
@page :first { @bottom-center { content: none; } }
body { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; font-size: 9.6pt; line-height: 1.45; color: #1a1a1a; }
h1 { font-size: 20pt; color: #0b3d63; border-bottom: 3px solid #0b3d63; padding-bottom: 4pt; margin-top: 0; }
h2 { font-size: 14.5pt; color: #0b3d63; border-bottom: 1px solid #c9d6e2; padding-bottom: 2pt; margin-top: 18pt; page-break-before: always; }
h2:first-of-type { page-break-before: auto; }
h3 { font-size: 11.5pt; color: #134f7f; margin-top: 12pt; page-break-after: avoid; }
code { font-family: Menlo, 'DejaVu Sans Mono', monospace; font-size: 8.2pt; background: #f2f4f7; padding: 0 2pt; border-radius: 2pt; }
pre { background: #f6f8fa; border: 1px solid #dde3ea; border-left: 3px solid #134f7f; padding: 6pt 8pt; font-size: 7.6pt; line-height: 1.3; white-space: pre-wrap; word-wrap: break-word; }
pre code { background: none; padding: 0; font-size: 7.6pt; }
table { border-collapse: collapse; width: 100%; margin: 6pt 0; font-size: 8.4pt; page-break-inside: auto; }
th { background: #0b3d63; color: white; text-align: left; padding: 3pt 5pt; }
th code { background: transparent; color: inherit; }
th:empty { padding: 0; }
td { border: 1px solid #d5dde5; padding: 3pt 5pt; vertical-align: top; }
tr:nth-child(even) td { background: #f7f9fb; }
tr { page-break-inside: avoid; }
blockquote { border-left: 3px solid #e0a100; background: #fff8e6; margin: 6pt 0; padding: 4pt 8pt; color: #4a3b00; }
blockquote p { margin: 2pt 0; }
a { color: #134f7f; text-decoration: none; }
hr { border: none; border-top: 1px solid #ccc; }

.portada { text-align: center; page-break-after: always; padding-top: 22mm; }
.portada img { width: 34mm; height: auto; }
.portada p { margin: 0; }
.portada .institucion { font-size: 15pt; font-weight: 700; color: #0b3d63; margin-top: 7mm; }
.portada .curso { font-size: 10.5pt; color: #666; margin-top: 2mm; }
.portada .titulo { font-size: 25pt; font-weight: 700; color: #0b3d63; line-height: 1.2; margin-top: 34mm; }
.portada .subtitulo { font-size: 12pt; color: #333; margin-top: 6mm; line-height: 1.45; }
.portada .tipo { font-size: 11pt; letter-spacing: 3pt; text-transform: uppercase; color: #134f7f; margin-top: 20mm;
                 border-top: 1px solid #c9d6e2; border-bottom: 1px solid #c9d6e2; padding: 3mm 0; }
.portada .autor { font-size: 13.5pt; font-weight: 600; margin-top: 28mm; line-height: 1.5; }
.portada .fecha { font-size: 10.5pt; color: #555; margin-top: 10mm; }
"""

ITEM = re.compile(r"^\s*([-*]|\d+\.)\s")


def separar_listas(texto):
    """Python-Markdown exige una línea en blanco antes de una lista (GitHub no). Se agrega fuera de bloques de código."""
    salida, en_codigo, previa = [], False, ""
    for linea in texto.split("\n"):
        if linea.lstrip().startswith("```"):
            en_codigo = not en_codigo
        if (not en_codigo and ITEM.match(linea) and previa.strip() and not ITEM.match(previa)
                and not previa.lstrip().startswith(("|", "<", ">")) and not linea.startswith((" ", "\t"))):
            salida.append("")
        salida.append(linea)
        previa = linea
    return "\n".join(salida)


def main():
    origen = Path(sys.argv[1])
    titulo = sys.argv[2] if len(sys.argv) > 2 else origen.stem
    md = origen.read_text(encoding="utf-8")
    md = re.sub(r"^(\s*)- \[ \] ", r"\1- ☐ ", md, flags=re.M)
    md = re.sub(r"^(\s*)- \[[xX]\] ", r"\1- ☑ ", md, flags=re.M)
    cuerpo = markdown.markdown(separar_listas(md),
                               extensions=["tables", "fenced_code", "toc", "sane_lists", "md_in_html"],
                               extension_configs={"toc": {"slugify": slugify_unicode}})
    html = (f'<!doctype html><html lang="es"><head><meta charset="utf-8"><title>{titulo}</title>'
            f'<meta name="author" content="Didvin Nohel Estrada Pineda"><style>{CSS}</style></head>'
            f"<body>{cuerpo}</body></html>")
    destino = origen.with_suffix(".pdf")
    HTML(string=html, base_url=str(origen.parent.resolve())).write_pdf(destino)
    print(f"{destino} generado")


if __name__ == "__main__":
    main()

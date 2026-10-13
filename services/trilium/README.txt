Trilium Notes (TriliumNext) — hierarchical notes.

Services:
  trilium  :8085  web UI (also the sync target for Trilium desktop apps)

Data: ./data (document.db + attachments, backups/ with Trilium's own daily backups).
Restoring: stop it, copy the old data folder into ./data, start. A newer Trilium
migrates the data forward on start (not back) — keep a copy until it works.

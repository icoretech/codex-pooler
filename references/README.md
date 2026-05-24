# Reference checkouts

This directory is for local-only reference source trees from external projects.
The nested project directories are intentionally ignored by the parent
codex-pooler repository and should stay as independent git checkouts.

Use `git -C references/<project> ...` to inspect or update a reference checkout,
for example:

```bash
git -C references/<project> pull --rebase
git -C references/<project> status
```

Do not commit source files from nested reference projects into this repository.
If a reference checkout needs local patches, keep those changes inside that
nested repository or move the work to the real project checkout.

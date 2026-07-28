#!/usr/bin/env bash

set -e

# Build IsoNim's own documentation site (docs/users/) and publish it to the
# `gh-pages` orphan branch that GitHub Pages serves at
# https://metacraft-labs.github.io/isonim/.
#
# docs/users/ is an isonim-docs SSG consumer: `just build` runs
# `nim c -r src/build.nim` under this repo's dev shell and emits the static site
# (guide pages + hashed stylesheet + search index + sitemap.xml + robots.txt)
# into docs/users/public/. Its DocsConfig sets basePath="/isonim" so every
# internal URL is prefixed for the project-Pages subpath (see the isonim-docs
# framework's core/base_path).
#
# Set DOCS_DEPLOY_DRY_RUN=1 (or pass --dry-run) to build + stage WITHOUT pushing.

DRY_RUN=0
if [ "${DOCS_DEPLOY_DRY_RUN:-0}" = "1" ] || [ "${1:-}" = "--dry-run" ]; then
	DRY_RUN=1
fi

# --- Build the docs site ---------------------------------------------------
# docs/users switches `--path` to sibling checkouts (the isonim-docs framework,
# nim-everywhere, nim-faststreams, nim-stew) at the workspace root, plus this
# repo's own src + vendored deps. The toolchain is this repo's flake dev shell:
# from docs/users/, that flake is at ../.. .
pushd docs/users/
nix develop ../.. -c just build # build output is in ./public
popd

# --- Publish docs/users/public/ to the gh-pages orphan branch --------------

git worktree prune
if [ -d "gh-pages" ]; then
	git worktree remove --force gh-pages
fi
if git show-ref --verify --quiet refs/heads/gh-pages; then
	git branch -D gh-pages
fi

git worktree add --orphan -B gh-pages gh-pages
cp -a docs/users/public/. gh-pages

# Serve the SSG output verbatim (no Jekyll). No CNAME -- this is a GitHub
# *project* Pages site served under the /isonim subpath (basePath handles URL
# prefixing). Add a CNAME + drop basePath once a custom domain is DNS-ready.
touch gh-pages/.nojekyll

git config user.name "Deploy from CI"
git config user.email ""
cd gh-pages
git add -A
git commit -m 'deploy isonim docs' --no-gpg-sign

if [ "$DRY_RUN" = "1" ]; then
	echo "docs.sh: DRY RUN -- skipping 'git push origin +gh-pages'"
	echo "docs.sh: staged $(git ls-files | wc -l) files for gh-pages"
else
	git push origin +gh-pages
fi
cd ..

git worktree remove --force gh-pages
if git show-ref --verify --quiet refs/heads/gh-pages; then
	git branch -D gh-pages
fi

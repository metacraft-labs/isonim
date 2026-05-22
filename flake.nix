{
  description = "IsoNim - Isomorphic reactive web framework for Nim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        # ``claude-code-acp`` (now upstream-renamed to ``claude-agent-acp``)
        # depends on the unfree ``claude-code`` package; we therefore opt
        # in to unfree just for this dev shell.
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        # Expose the binary under both the legacy ``claude-code-acp`` name
        # (which our Nim transport prefers via ``findExe``) and the new
        # ``claude-agent-acp`` name.
        claudeCodeAcp =
          pkgs.runCommand "claude-code-acp-compat"
            {
              nativeBuildInputs = [ pkgs.makeWrapper ];
            }
            ''
              mkdir -p $out/bin
              for bin in ${pkgs.claude-agent-acp}/bin/*; do
                ln -s "$bin" "$out/bin/$(basename "$bin")"
              done
              if [ ! -e $out/bin/claude-code-acp ]; then
                ln -s ${pkgs.claude-agent-acp}/bin/claude-agent-acp $out/bin/claude-code-acp
              fi
            '';
      in
      {
        devShells.default = pkgs.mkShell {
          packages =
            (with pkgs; [
              nim
              nimble
              nodejs
              # TBAR-M5b: yarn 1 manages the editor's runtime JS deps
              # (``@tiptap/core``, ``@tiptap/starter-kit``, ``tiptap-markdown``,
              # ``xterm``).  The editor-vendor Nix derivation calls
              # ``yarn install --offline`` against ``fetchYarnDeps`` to
              # produce the UMD bundles consumed by ``editor-build``.
              yarn
              # TBAR-M5b: esbuild bundles the per-library entry scripts
              # into UMD ``globalThis``-attaching bundles. Available
              # for use both inside the Nix derivation and from the dev
              # shell when debugging the bundling step.
              esbuild
              # TBAR-M5b: pre-fetch yarn deps for the Nix derivation
              # via ``prefetch-yarn-deps`` (used to compute the
              # ``fetchYarnDeps`` hash when ``yarn.lock`` changes).
              prefetch-yarn-deps
              just
              # REV-M3: userspace PostgreSQL substrate.  ``postgresql_16``
              # provides ``initdb``, ``postgres``, ``psql``, ``pg_isready``,
              # ``pg_dump``, ``pg_restore`` on $PATH.  ``process-compose``
              # orchestrates the local dev cluster (see process-compose.yaml).
              postgresql_16
              process-compose
              # Phase A: ACP-speaking Claude Code adapter. Exposes both
              # ``claude-code-acp`` (legacy/expected name) and
              # ``claude-agent-acp`` (current upstream name) on $PATH.
              claudeCodeAcp
              # Codex-backed ACP adapter — sibling backend selectable
              # via ``[agent].backend = "codex"`` in the review config
              # (or the ``--agent-backend=codex`` CLI flag). Lives on
              # PATH alongside claude-agent-acp so users can switch
              # without re-entering the shell.
              codex-acp
            ])
            # ``chromium`` and ``chromedriver`` only build on Linux in
            # nixpkgs; Darwin users supply system Chrome / a Homebrew
            # chromedriver. Gate them here so ``nix develop`` works on
            # macOS too.
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux (
              with pkgs;
              [
                chromium
                chromedriver
              ]
            );

          shellHook = ''
            echo "IsoNim dev shell — nim $(nim --version 2>&1 | head -1), node $(node --version)"
            # REV-M3 dev-cluster defaults; users may override in their own
            # .envrc (see .envrc.example).
            export ISONIM_REVIEW_PGDATA="''${ISONIM_REVIEW_PGDATA:-$PWD/.dev/postgres}"
            export ISONIM_REVIEW_PGPORT="''${ISONIM_REVIEW_PGPORT:-5533}"
          '';
        };

        packages.nginx-module = pkgs.callPackage ./nix/nginx-module.nix { };

        # TBAR-M5b: vendored UMD bundles for the editor's TipTap + xterm
        # runtime deps.  Output: ``$out/{tiptap,xterm}.umd.js`` +
        # ``$out/MANIFEST.txt``.  Consumed by the ``editor-build`` recipe
        # in ``isonim-examples/Justfile`` via ``nix build --print-out-paths
        # ~/metacraft/isonim#editor-vendor`` + ``cp -L``.
        packages.editor-vendor = pkgs.callPackage ./nix/editor-vendor.nix { };
      }
    );
}

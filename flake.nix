{
  description = "IsoNim - Isomorphic reactive web framework for Nim";

  inputs = {
    mcl-standard-hook-source = {
      url = "github:metacraft-labs/devops-modules/6ba34072850f7348e1669a6daf8a0acb79669434";
      flake = false;
    };
    managed-hook-reprobuild.url = "github:metacraft-labs/reprobuild/064daf5b154ea6a0758ddb2dcbcbc07685216e44";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-utils,
      git-hooks,
      ...
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
        # The tracked portable configuration is preserved as source. Native
        # activation runs the complete named set through guarded constructors.
        ownRepoOnly = script: ''
          _own_repo_root="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || true)"
          if [ -n "$_own_repo_root" ] && [ -f "$_own_repo_root/flake.nix" ] \
            && [ "$(${pkgs.coreutils}/bin/sha256sum "$_own_repo_root/flake.nix" | ${pkgs.coreutils}/bin/cut -d' ' -f1)" \
              = "${builtins.hashFile "sha256" ./flake.nix}" ]; then
          ${script}
          fi
          unset _own_repo_root
        '';

        legacyPreCommit = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            check-added-large-files.enable = true;
            check-merge-conflicts.enable = true;
            lint = {
              enable = true;
              name = "just lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
            };
          };
        };
        # Preserve the original native 500 KB cap while adopting the complete
        # named standard set and retaining the merge-conflict and lint gates.
        standardHooks = import (inputs.mcl-standard-hook-source + "/git-hooks/standard-hooks.nix") {
          inherit pkgs;
          lib = pkgs.lib;
          src = inputs.mcl-standard-hook-source;
          maxKB = 500;
        };
        preCommit = git-hooks.lib.${system}.run {
          src = ./.;
          configPath = ".pre-commit-config.nix.yaml";
          hooks = standardHooks // {
            check-merge-conflicts.enable = true;
            lint = {
              enable = true;
              name = "just lint";
              entry = "just lint";
              language = "system";
              pass_filenames = false;
            };
          };
        };
        nativeHookFactory =
          configuration:
          pkgs.runCommand "isonim-native-hook-factory"
            {
              nativeBuildInputs = [
                pkgs.git
                pkgs.bash
                configuration.config.package
              ];
            }
            ''
              export PRE_COMMIT_HOME="$TMPDIR/isonim-native-hook-cache"
              export XDG_CACHE_HOME="$TMPDIR/isonim-native-factory-cache"
              export GIT_CONFIG_GLOBAL="$TMPDIR/isonim-native-factory-gitconfig"
              export GIT_CONFIG_NOSYSTEM=1
              : > "$GIT_CONFIG_GLOBAL"
              mkdir -p "$PRE_COMMIT_HOME" "$XDG_CACHE_HOME" fixture
              cd fixture
              git init --template= >/dev/null
              if git config --get core.hooksPath; then
                echo 'Unexpected native factory hooksPath authority' >&2
                exit 1
              fi
              test "$(git rev-parse --path-format=absolute --git-path hooks)" = "$PWD/.git/hooks"
              ln -s ${configuration.config.configFile} ${configuration.config.configPath}
              mkdir -p "$out"
              for hook in pre-commit pre-push; do
                ${pkgs.lib.getExe configuration.config.package} install -c ${configuration.config.configPath} -t "$hook"
                install -m 0755 ".git/hooks/$hook" "$out/$hook"
              done
            '';
        expectedNativeHook = nativeHookFactory preCommit;
        expectedLegacyNativeHook = nativeHookFactory legacyPreCommit;
        hookOwnershipGuard = ./nix/hook-ownership-guard.py;
        hookTransaction = ./nix/hook-transaction.py;
        actualNativeInstaller = pkgs.writeShellScript "isonim-native-hook-installer" preCommit.shellHook;
        managedHookConstructor = inputs.managed-hook-reprobuild.packages.${system}.reprobuild;
        guardedHookInstall = ''
          if [ -n "''${REPROBUILD_REPRO:-}" ] && [ "$REPROBUILD_REPRO" != "${managedHookConstructor}/bin/repro" ]; then
            echo 'Foreign inherited managed constructor authority' >&2
            exit 1
          fi
          export REPROBUILD_REPRO="${managedHookConstructor}/bin/repro"
          ${pkgs.python3}/bin/python3 ${hookTransaction} "$_own_repo_root" ${hookOwnershipGuard} ${expectedNativeHook} ${pkgs.git}/share/git-core/templates ${expectedLegacyNativeHook} ${preCommit.config.configFile} ${legacyPreCommit.config.configFile} ${actualNativeInstaller} ${pkgs.git}/bin/git ${pkgs.bash}/bin/bash >&2
          _isonim_hook_status=$?
          if [ "$_isonim_hook_status" -ne 0 ]; then
            unset _isonim_hook_status
            exit 1
          fi
          unset _isonim_hook_status
        '';
      in
      {
        checks.pre-commit = preCommit;
        devShells.default = pkgs.mkShell {
          REPROBUILD_REPRO = "${managedHookConstructor}/bin/repro";
          ISONIM_FULL_HOOK_CONFIG = preCommit.config.configFile;
          ISONIM_EXPECTED_NATIVE_HOOKS = expectedNativeHook;
          ISONIM_HOOK_INSTALLER = pkgs.writeShellScript "isonim-guarded-hook-installer" (
            ownRepoOnly guardedHookInstall
          );
          packages = [
            managedHookConstructor
            preCommit.config.package
          ]
          ++ preCommit.enabledPackages
          ++ (with pkgs; [
            git
            bash
            direnv
            uv
            nixfmt-rfc-style
            nim
            # Maintained editor and source-role tools execute Python 3.
            python3
            nimble
            # RS-M7 real render bridge uses the pinned in-process WebP ABI.
            libwebp
            pkg-config
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
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              export LD_LIBRARY_PATH="${pkgs.libwebp}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
              export PLAYWRIGHT_CHROMIUM_EXECUTABLE="${pkgs.chromium}/bin/chromium"
            ''}
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
              export DYLD_FALLBACK_LIBRARY_PATH="${pkgs.libwebp}/lib''${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
            ''}
            ${ownRepoOnly guardedHookInstall}
            echo "IsoNim dev shell — nim $(nim --version 2>&1 | head -1), node $(node --version)"
            # REV-M3 dev-cluster defaults; users may override in their own
            # .envrc (see .envrc.example).
            export ISONIM_REVIEW_PGDATA="''${ISONIM_REVIEW_PGDATA:-$PWD/.dev/postgres}"
            export ISONIM_REVIEW_PGPORT="''${ISONIM_REVIEW_PGPORT:-5533}"
          '';
        };

        packages.native-hook-config = preCommit.config.configFile;
        packages.legacy-native-hook-config = legacyPreCommit.config.configFile;
        packages.expected-native-hooks = expectedNativeHook;
        packages.expected-legacy-native-hooks = expectedLegacyNativeHook;
        packages.managed-hook-constructor = managedHookConstructor;

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

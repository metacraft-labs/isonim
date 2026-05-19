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
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            nim
            nimble
            nodejs
            just
            chromium
            chromedriver
            # REV-M3: userspace PostgreSQL substrate.  ``postgresql_16``
            # provides ``initdb``, ``postgres``, ``psql``, ``pg_isready``,
            # ``pg_dump``, ``pg_restore`` on $PATH.  ``process-compose``
            # orchestrates the local dev cluster (see process-compose.yaml).
            postgresql_16
            process-compose
          ];

          shellHook = ''
            echo "IsoNim dev shell — nim $(nim --version 2>&1 | head -1), node $(node --version)"
            # REV-M3 dev-cluster defaults; users may override in their own
            # .envrc (see .envrc.example).
            export ISONIM_REVIEW_PGDATA="''${ISONIM_REVIEW_PGDATA:-$PWD/.dev/postgres}"
            export ISONIM_REVIEW_PGPORT="''${ISONIM_REVIEW_PGPORT:-5533}"
          '';
        };

        packages.nginx-module = pkgs.callPackage ./nix/nginx-module.nix { };
      }
    );
}

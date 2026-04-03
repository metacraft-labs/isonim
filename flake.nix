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
          ];

          shellHook = ''
            echo "IsoNim dev shell — nim $(nim --version 2>&1 | head -1), node $(node --version)"
          '';
        };

        packages.nginx-module = pkgs.callPackage ./nix/nginx-module.nix { };
      }
    );
}

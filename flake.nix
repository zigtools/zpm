{
  description = "Zig Package Repository Manager";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.11";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs: let
    overlays = [
      # Other overlays
      (final: prev: {
        zigpkgs = inputs.zig.packages.${prev.system};
      })
    ];

    # Our supported systems are the same supported systems as the Zig binaries
    systems = builtins.attrNames inputs.zig.packages;
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {inherit overlays system;};
      in rec {
        packages.default = pkgs.stdenv.mkDerivation {
          name = "zpm";
          src = ./.;
          nativeBuildInputs = [
            pkgs.zigpkgs."0.12.0"
          ];

          configurePhase = "";

          buildPhase = ''
            zig build
          '';

          installPhase = ''
            mv zig-out $out
          '';
        };
      }
    );
}

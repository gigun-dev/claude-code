{
  description = "gigun's agent plugins: Nix builds for hosts the marketplace cannot install into";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
      # Built from the consumer's `final`, so a dotfiles flake that applies this
      # overlay evaluates its own nixpkgs once (same as ryoppippi/claude-code-overlay).
      overlays.default = final: _prev: {
        agy-external-plugins = final.callPackage ./nix/agy-external-plugins.nix { };
      };

      packages = forAllSystems (
        system:
        let
          agy-external-plugins = nixpkgs.legacyPackages.${system}.callPackage ./nix/agy-external-plugins.nix { };
        in
        {
          inherit agy-external-plugins;
          default = agy-external-plugins;
        }
      );
    };
}

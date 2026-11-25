{
  description = "gigun's agent plugins: pinned external plugins built once for every agent host";

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
      # Why no agy-external-plugins alias: its layout ($out/<name>) changed, so an
      # alias would still break the consumer's plugins.json entry, only silently.
      overlays.default = final: _prev: {
        external-plugins = final.callPackage ./nix/external-plugins.nix { };
      };

      packages = forAllSystems (
        system:
        let
          external-plugins = nixpkgs.legacyPackages.${system}.callPackage ./nix/external-plugins.nix { };
        in
        {
          inherit external-plugins;
          default = external-plugins;
        }
      );
    };
}

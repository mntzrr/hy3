{
  inputs = {
    hyprland.url = "github:hyprwm/hyprland/efb50993780079460b0cbed1363e2166a2de1d9f";
  };

  outputs = {
    self,
    hyprland,
    ...
  }: let
    inherit (hyprland.inputs) nixpkgs;

    hyprlandSystems = fn:
      nixpkgs.lib.genAttrs
      (builtins.attrNames hyprland.packages)
      (system: fn system nixpkgs.legacyPackages.${system});

    hyprlandVersion = nixpkgs.lib.removeSuffix "\n" (builtins.readFile "${hyprland}/VERSION");

    # 0.56.2's CMake asks for `find_package(glaze 7...<8)`, but the nixpkgs pinned by
    # its own flake has no glaze 7, so configure falls back to a network FetchContent
    # that the sandbox refuses and the tag's package does not build from source.
    # Upstream fixed it one commit after the tag (91f29f23b, "flake.lock: update,
    # drop glaze version requirement") with the patch below. That commit cannot be
    # pinned directly: version.h would move off the release tag and the plugin would
    # refuse to load on a stock 0.56.2. GIT_COMMIT_HASH is set from the flake rev,
    # not the source tree, so applying it as a patch leaves the reported hash at
    # efb5099 and the headers byte-identical to stock. Drop this at the next chase.
    patchedHyprland = system:
      hyprland.packages.${system}.hyprland.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./nix/hyprland-0.56.2-glaze-version.patch];
      });
  in {
    packages = hyprlandSystems (system: pkgs: rec {
      hy3 = pkgs.callPackage ./default.nix {
        hyprland = patchedHyprland system;
        hlversion = hyprlandVersion;
      };
      default = hy3;
    });

    devShells = hyprlandSystems (system: pkgs: {
      default = import ./shell.nix {
        inherit pkgs;
        hlversion = hyprlandVersion;
        hyprland = hyprland.packages.${system}.hyprland;
      };

      impure = import ./shell.nix {
        pkgs = import <nixpkgs> {};
        hlversion = hyprlandVersion;
        hyprland = (pkgs.appendOverlays [hyprland.overlays.hyprland-packages]).hyprland.overrideAttrs {
          dontStrip = true;
        };
      };
    });
  };
}

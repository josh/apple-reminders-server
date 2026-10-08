{
  description = "macOS Reminders HTTP server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { nixpkgs, ... }: {
    packages.aarch64-darwin =
      let
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        inherit (pkgs) lib;
        src = lib.cleanSourceWith {
          name = "source";
          src = ./.;
          filter = path: type:
            (path == toString ./. || builtins.elem
              (builtins.head (lib.splitString "/" (lib.removePrefix "${toString ./.}/" path)))
              [ "Sources" "Package.swift" "Package.resolved" "Info.plist" ])
            && !(builtins.elem (builtins.baseNameOf path)
              [ ".git" ".jj" ".build" ".cache" "target" "bin" "result" ])
            && lib.cleanSourceFilter path type;
        };
        swift = pkgs.stdenv.mkDerivation {
          pname = "reminders-swift";
          version = "0.1.0";
          inherit src;
          doCheck = false;
          meta.platforms = [ "aarch64-darwin" ];
          sourceRoot = "source";
          nativeBuildInputs = [ pkgs.swift pkgs.swiftpm ];
          # The locked swift-collections manifest requires Swift 6.4.
          # Keep the package defined so a newer nixpkgs input can supply it.
          preUnpack = lib.optionalString (lib.versionOlder pkgs.swift.version "6.4") ''
            echo "reminders-swift requires Swift >= 6.4; pinned Nixpkgs supplies ${pkgs.swift.version}" >&2
            exit 1
          '';
          swiftpmDeps = pkgs.fetchSwiftPMDeps {
            inherit src;
            sourceRoot = "source";
            hash = "sha256-PdkfCMkWNGqMj2zqhbvydWO97FjKTsPlhtBfyRBTg18=";
          };
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            cp .build/release/reminders-swift "$out/bin/"
            runHook postInstall
          '';
        };
      in { inherit swift; default = swift; };
  };
}

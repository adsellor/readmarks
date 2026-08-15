{
  description = "readmarks: a terminal feed reader and bookmarker";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig.url = "github:mitchellh/zig-overlay";

    markix = {
      url = "git+https://codeberg.org/adsellor/markix?rev=0cf7fe5ca0089df5ba61710ff758ed5298d28330";
      flake = false;
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs: let
    overlays = [
      (final: prev: {
        zigpkgs = inputs.zig.packages.${prev.stdenv.hostPlatform.system};
      })
    ];

    systems = builtins.attrNames inputs.zig.packages;

    markix_package = "markix-0.0.0-PwM0VHbzBwDjJZJxIDyFkw7v1fCUTbeVLaxpokUrbB-v";
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {inherit overlays system;};
        zig = pkgs.zigpkgs.master;

        vendored_packages = pkgs.runCommand "readmarks-zig-packages" {} ''
          mkdir -p "$out/${markix_package}"
          cp -r ${inputs.markix}/. "$out/${markix_package}/"
        '';

        source = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            ./build.zig
            ./build.zig.zon
            ./src
          ];
        };

        readmarks = {llvm ? false}:
          pkgs.stdenv.mkDerivation {
            pname = "readmarks";
            version = "0.1.0";
            src = source;
            nativeBuildInputs = [zig];
            dontConfigure = true;
            dontInstall = true;
            buildPhase = ''
              runHook preBuild
              export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
              zig build \
                --system "${vendored_packages}" \
                -Doptimize=ReleaseFast \
                ${pkgs.lib.optionalString (!llvm) "-Dno-llvm=true"} \
                --prefix "$out"
              runHook postBuild
            '';
            meta = {
              description = "Terminal feed reader and bookmarker";
              homepage = "https://codeberg.org/adsellor/markix";
              mainProgram = "readmarks";
              platforms = pkgs.lib.platforms.unix;
            };
          };
        self_hosted_ready =
          pkgs.stdenv.hostPlatform.isLinux
          && pkgs.stdenv.hostPlatform.isx86_64;
      in {
        packages.default = readmarks {llvm = !self_hosted_ready;};
        packages.readmarks = readmarks {llvm = !self_hosted_ready;};
        packages.readmarks-fast = readmarks {};
        packages.readmarks-llvm = readmarks {llvm = true;};

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/readmarks";
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [zig];
        };

        devShell = self.devShells.${system}.default;
      }
    );
}

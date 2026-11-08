{
  description = "readmarks: a terminal feed reader and bookmarker";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # The Zig of the default dev shell. It tracks the latest Zig master, so
    # development can move ahead of what releases build with.
    zig.url = "github:mitchellh/zig-overlay";

    # The Zig every package and release binary builds with. Zig master breaks
    # its API often and flake.lock is not committed, so this names a commit: a
    # lock refresh here or in a downstream flake cannot change it. Move it by
    # hand, once `nix develop .#release --command zig build check` passes on
    # the new commit.
    zig-release.url = "github:mitchellh/zig-overlay/463ba9945e5f47fb654669c4b1a294ba516cef23";

    markix = {
      url = "git+https://codeberg.org/adsellor/markix?rev=590d22deee61f841a0d6c39cbbac71b440734c02";
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

    systems = builtins.attrNames inputs.zig-release.packages;

    markix_package = "markix-0.0.0-PwM0VOFIBAB2NN_Jo8hKNO7dQ7PsTNmmCxypwyOyefJz";

    # The binaries the ci workflow attaches to a github release, for installing
    # without a toolchain. Fill a hash in when the tag is published:
    #   nix store prefetch-file --hash-type sha256 <asset url>
    # A system whose hash is still empty exposes no readmarks-bin package.
    release = {
      version = "0.3.2";
      owner = "adsellor";
      repo = "readmarks";
      assets = {
        x86_64-linux = "readmarks-linux-x86_64";
        aarch64-linux = "readmarks-linux-aarch64";
        x86_64-darwin = "readmarks-macos-x86_64";
        aarch64-darwin = "readmarks-macos-aarch64";
      };
      hashes = {
        x86_64-linux = "";
        aarch64-linux = "";
        x86_64-darwin = "";
        aarch64-darwin = "";
      };
    };
  in
    flake-utils.lib.eachSystem systems (
      system: let
        pkgs = import nixpkgs {inherit overlays system;};
        zig_dev = pkgs.zigpkgs.master;
        zig_release = inputs.zig-release.packages.${system}.master;

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
            version = "0.3.2";
            src = source;
            nativeBuildInputs = [zig_release];
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
              homepage = "https://codeberg.org/adsellor/readmarks";
              mainProgram = "readmarks";
              platforms = pkgs.lib.platforms.unix;
            };
          };
        self_hosted_ready =
          pkgs.stdenv.hostPlatform.isLinux
          && pkgs.stdenv.hostPlatform.isx86_64;

        release_asset = release.assets.${system} or null;
        release_hash = release.hashes.${system} or "";
        release_published = release_asset != null && release_hash != "";

        readmarks_bin = pkgs.stdenvNoCC.mkDerivation {
          pname = "readmarks-bin";
          inherit (release) version;
          src = pkgs.fetchurl {
            url = "https://github.com/${release.owner}/${release.repo}/releases/download/v${release.version}/${release_asset}";
            hash = release_hash;
          };
          dontUnpack = true;
          installPhase = ''
            runHook preInstall
            install -Dm755 "$src" "$out/bin/readmarks"
            runHook postInstall
          '';
          meta = {
            description = "Terminal feed reader and bookmarker, prebuilt";
            homepage = "https://codeberg.org/adsellor/readmarks";
            mainProgram = "readmarks";
            platforms = builtins.attrNames release.assets;
          };
        };
      in {
        packages =
          {
            default = readmarks {llvm = !self_hosted_ready;};
            readmarks = readmarks {llvm = !self_hosted_ready;};
            readmarks-fast = readmarks {};
            readmarks-llvm = readmarks {llvm = true;};
          }
          // pkgs.lib.optionalAttrs release_published {
            readmarks-bin = readmarks_bin;
          };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/readmarks";
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [zig_dev];
        };

        devShells.release = pkgs.mkShell {
          nativeBuildInputs = [zig_release];
        };

        devShell = self.devShells.${system}.default;
      }
    );
}

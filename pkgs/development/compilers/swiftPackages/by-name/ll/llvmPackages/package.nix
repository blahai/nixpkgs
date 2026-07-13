# Swift needs to be built against the matching tag from the LLVM fork in the swiftlang repo.
# Ideally, it would build against upstream LLVM, but it depends on APIs that have not been upstreamed.
# For example: https://github.com/swiftlang/llvm-project/blob/901f89886dcd5d1eaf07c8504d58c90f37b0cfdf/clang/include/clang/AST/StableHash.h

{
  lib,
  darwin,
  fetchFromGitHub,
  generateSplicesForMkScope,
  llvmPackages_19, # Needs to match the `llvmVersion` of the fork.
  python3,
  runCommand,
  stdenv,
  stdlib,
  swiftc,
  swift_release,
}:

let
  swiftLlvmVersion = "17.0.0"; # From https://github.com/swiftlang/swift/blob/swift-$swiftVersion-RELEASE/utils/build_swift/build_swift/defaults.py#L51
  llvmVersion = "19.1.5"; # From https://github.com/swiftlang/llvm-project/blob/swift-$swiftVersion-RELEASE/cmake/Modules/LLVMVersion.cmake
in
(llvmPackages_19.override {
  officialRelease.version = llvmVersion;

  monorepoSrc = fetchFromGitHub {
    owner = "swiftlang";
    repo = "llvm-project";
    tag = "swift-${swift_release}-RELEASE";
    hash = "sha256-5Nb8rQmk6onrc4wKW/kT38FsYsWTqMBWtsHYZLA/0Po=";
  };

  otherSplices = generateSplicesForMkScope [
    "swiftPackages"
    "llvmPackages"
  ];

  patchesFn =
    patches:
    patches
    // {
      # Updated patch that also prevents Clang from trying to copy `clang-deps-launcher.py` to `${llvm}/bin`.
      "clang/gnu-install-dirs.patch" = [ { path = ./patches; } ];
    };
}).overrideScope
  (
    final: prev: {
      version = swiftLlvmVersion;
      release_version = llvmVersion;

      libclang = prev.libclang.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          moveToOutput bin/clang-deps-launcher.py "$python"
        '';
      });

      lldb =
        let
          python3-with-distuils = python3.withPackages (pkgs: [ pkgs.distutils ]);
          # LLDB needs internal headers to build. Run configure phase to generate `Config.h` then copy the rest.
          swiftHeaders = swiftc.overrideAttrs (old: {
            pname = "swiftc-headers";
            outputs = [ "out" ];
            dontBuild = true;
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -rv include "$out" # For generated config headers.
              while IFS= read -d "" f; do
                dest=$out/''${f#../}
                mkdir -p "$(dirname "$dest")"
                cp -v "$f" "$dest"
              done < <(find .. \( -name '*.def' -o -name '*.h' \) -print0)
              runHook postInstall
            '';
            postInstall = "";
          });
          # This is enough of a SwiftConfig.cmake to build LLDB and nothing more.
          swiftCmake = runCommand "swift-cmake-for-lldb-${swift_release}" { } ''
            mkdir -p "$out/lib/cmake/modules" "$out/lib/cmake/Swift"
            cat <<EOF > "$out/lib/cmake/Swift/SwiftConfig.cmake"
            set(SWIFT_BINARY_DIR "${lib.getBin swiftc}")
            # Include both stdlib/lib for shared libraries and stdlib.dev/lib for static ones.
            set(SWIFT_LIBRARY_DIRS "${lib.getLib stdlib}/lib;${lib.getDev stdlib}/lib")
            # The stdlib.dev/lib folder is where the shims are located, which are needed to build LLDB.
            set(SWIFT_INCLUDE_DIRS "${lib.getInclude swiftc}/include;${lib.getInclude stdlib}/lib;${lib.getInclude stdlib}/include;${swiftHeaders}/include")
            # Make sure the SwiftAddCustomCommandTarget and SwiftUtils modules can be found.
            list(APPEND CMAKE_MODULE_PATH "$out/lib/cmake/modules")
            EOF
            cp -v ${lib.escapeShellArg swiftc.src}/cmake/modules/SwiftUtils.cmake "$out/lib/cmake/modules/SwiftUtils.cmake"
            cp -v ${lib.escapeShellArg swiftc.src}/cmake/modules/SwiftAddCustomCommandTarget.cmake "$out/lib/cmake/modules/SwiftAddCustomCommandTarget.cmake"
          '';
        in
        prev.lldb.overrideAttrs (old: {
          # The LLDB build expects the stdlib static libraries to be available on the default linker path.
          buildInputs = (old.buildInputs or [ ]) ++ [ stdlib ];
          # Swift’s fork of LLDB has extra requirements. It needs Python for its plugins and `codesign` on Darwin.
          nativeBuildInputs =
            (old.nativeBuildInputs or [ ])
            ++ [ python3-with-distuils ]
            ++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.sigtool ];
          # These aren’t set correctly otherwise, and it needs an explicit Swift path regardless.
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            (lib.cmakeFeature "Clang_DIR" "${lib.getDev final.libclang}/lib/cmake/clang")
            (lib.cmakeFeature "LLVM_DIR" "${lib.getDev final.libllvm}/lib/cmake/llvm")
            (lib.cmakeFeature "Swift_DIR" "${swiftCmake}")
          ];
        });

      libllvm =
        let
          # The Swift build system expects to link statically against LLVM. Trying to link to the `libLLVM` shared
          # library causes `swift-frontend` to crash during the build on Linux.
          staticLibllvm = prev.libllvm.override { enableSharedLibraries = false; };
        in
        staticLibllvm.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            # Ensure the LLVM module cache is in a writable location during builds.
            ./patches/llvm/module-cache.patch
          ];
          doCheck = false; # TODO: fix fork-specific tests that fail due to, e.g., not finding `libLLVM.dylib` during the test
          postInstall = (old.postInstall or [ ]) + ''
            # Swift relies on LLVM’s private `config.h` for feature checks (e.g., for `unistd.h`).
            cp include/llvm/Config/config.h "$dev/include/llvm/Config/config.h"
          '';
        });
    }
  )

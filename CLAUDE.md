# Yggdrasil - BinaryBuilder Recipes for FUS3

This is a local fork/copy of [JuliaPackaging/Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil) used to build cross-platform binary artifacts for the FUS3 monorepo.

The primary recipe here is `V/vmecpp_julia/` which builds the VMEC++ Julia bindings library (`libvmecpp_julia`) for all supported platforms.

## Prerequisites

- **Docker Desktop**: Must be running for cross-compilation (BinaryBuilder uses Docker containers)
- **Julia 1.12+**: BinaryBuilder has issues with Julia 1.11 (`StaticData not defined` error from PrecompileTools). Use `julia +1.12`.
- **Yggdrasil environment**: The root `Project.toml` has BinaryBuilder and dependencies

## Building vmecpp_julia

### Cross-Platform Build (4 platforms)

```bash
# Ensure Docker is running
open -a Docker  # macOS

# Build all platforms and deploy to local JLL
cd ~/Coding/Yggdrasil/V/vmecpp_julia
julia +1.12 --project=~/Coding/Yggdrasil build_tarballs.jl --deploy=local
```

This takes ~20-30 minutes and builds for CI targets only:
- aarch64-apple-darwin (Julia 1.11, 1.12)
- x86_64-linux-gnu-cxx11 (Julia 1.11, 1.12)

### What `--deploy=local` Does

The `--deploy=local` flag writes the built JLL package to `~/.julia/dev/vmecpp_julia_jll/`. Since the FUS3 monorepo registers vmecpp_julia_jll via `[sources]` in its root `Project.toml`, and Julia resolves this to the same path, `--deploy=local` effectively writes **directly into the monorepo's `vmecpp_julia_jll/` directory**. This means:

1. New tarballs land in `vmecpp_julia_jll/artifacts/`
2. `Artifacts.toml` gets BinaryBuilder entries **appended** (with download URLs pointing to local files)
3. Wrapper files in `src/wrappers/` get **overwritten** with standard JLL wrappers (losing the custom install-from-tarball logic)
4. Artifact directories get installed to `~/.julia/artifacts/`

### Post-Build Cleanup Required

After `--deploy=local`, you must manually fix up the monorepo's JLL:

1. **Clean `Artifacts.toml`**: Remove BinaryBuilder's appended entries (with `[[vmecpp_julia.download]]` blocks). Keep only lazy entries with the NEW git-tree-sha1 hashes.

2. **Restore wrapper install logic**: BinaryBuilder overwrites wrappers to standard format. Each wrapper needs the inline tarball install block restored:
   ```julia
   # Install artifact from bundled tarball if needed
   let hash = "NEW_HASH",
       tarball = "vmecpp_julia.vX.Y.Z.PLATFORM.tar.gz"
       artifact_path = Base.joinpath(Base.homedir(), ".julia", "artifacts", hash)
       if !Base.isdir(artifact_path)
           pkg_dir = Base.dirname(Base.dirname(Base.dirname(@__FILE__)))
           tarball_path = Base.joinpath(pkg_dir, "artifacts", tarball)
           if Base.isfile(tarball_path)
               @info "Installing vmecpp_julia artifact from bundled tarball..."
               Base.mkpath(artifact_path)
               Base.run(`tar -xzf $(tarball_path) -C $(artifact_path)`)
           end
       end
   end
   ```

3. **Update `setup_artifacts.jl` and `deps/build.jl`** with new hash-to-tarball mappings.

4. **Update `Project.toml` version** to match `build_tarballs.jl`.

## vmecpp_julia Build Recipe

### File: `V/vmecpp_julia/build_tarballs.jl`

The build has three stages inside a Docker container:

1. **Build Abseil** (static, C++20) - vendored because `abseil_cpp_jll` is built with C++14
2. **Build vmecpp_core** (static) - the core VMEC++ solver
3. **Build libvmecpp_julia** (shared) - CxxWrap Julia bindings linking to vmecpp_core

### Source Files

```
V/vmecpp_julia/
├── build_tarballs.jl    # Build recipe (version, sources, platforms, script)
├── bundled/
│   ├── CMakeLists.txt   # CMake for the Julia wrapper library
│   └── vmecpp_julia.cpp # CxxWrap C++ bindings
├── build/               # Build artifacts (per-platform, generated)
├── products/            # Output tarballs (generated)
└── test_deps.jl         # Dependency testing utilities
```

### Key Configuration

- **C++ standard**: C++20 (required by vmecpp and Abseil)
- **GCC version**: 10+ (`preferred_gcc_version = v"10"`)
- **macOS SDK**: 12.3 (for C++20 `<filesystem>`, `std::construct_at`)
- **Julia versions**: 1.11 and 1.12 (filtered from `libjulia_platforms`)
- **CxxWrap/libcxxwrap_julia_jll**: ~0.14.7

### Dependencies

Build-time:
- `libjulia_jll` (Julia C API headers)
- `Eigen_jll` (linear algebra)

Runtime:
- `libcxxwrap_julia_jll` (~0.14.7) - Julia-C++ interop
- `HDF5_jll` (~1.14.6) - File I/O
- `NetCDF_jll` - File I/O
- `OpenBLAS_jll` - BLAS/LAPACK
- `CompilerSupportLibraries_jll` (Linux) or `LLVMOpenMP_jll` (macOS) - OpenMP

### Vendored Dependencies

These are fetched as sources (not JLLs) because vmecpp needs them built with C++20 or needs the full source tree for CMake FetchContent:

- **abseil-cpp**: C++20 static build (JLL is C++14)
- **nlohmann_json**: Full source tree for CMake integration
- **abscab-cpp**: Magnetic field computation
- **indata2json + LIBSTELL + json-fortran**: Fortran namelist parser

## Keeping C++ Bindings in Sync

The CxxWrap bindings file `vmecpp_julia.cpp` exists in TWO locations:

1. **`~/Coding/FUS3_monorepo/VMECPP/deps/src/vmecpp_julia.cpp`** - Used for local dev builds
2. **`~/Coding/Yggdrasil/V/vmecpp_julia/bundled/vmecpp_julia.cpp`** - Used by BinaryBuilder

These MUST be kept in sync. When adding new C++ bindings:
1. Edit both files identically
2. Test locally first using `VMECPP/deps/build.jl` (fast, macOS only)
3. Then do the full BinaryBuilder cross-platform build

Similarly, `CMakeLists.txt` exists in both `VMECPP/deps/src/` (local dev, conda-based) and `Yggdrasil/V/vmecpp_julia/bundled/` (BinaryBuilder, cross-platform). These are NOT identical - the local one uses conda paths while the BinaryBuilder one uses JLL/sysroot paths.

## Bumping the vmecpp Upstream Version

To update the underlying vmecpp C++ library:

1. Get the new commit hash from https://github.com/proximafusion/vmecpp
2. Update the `GitSource` hash in `build_tarballs.jl` (line with `vmecpp.git`)
3. Bump the `version` variable
4. Build and test

## Troubleshooting

**Docker not running**: `open -a Docker` and wait ~30 seconds for it to start.

**BinaryBuilder precompilation fails on Julia 1.11**: Use `julia +1.12` instead.

**Build fails with "c++filt not found"**: Benign warning from Docker containers, can be ignored.

**"Dependency X does not have a mapping for artifact Y"**: Warnings about MicrosoftMPI_jll on Linux platforms. Benign - these are optional MPI backends not needed for vmecpp.

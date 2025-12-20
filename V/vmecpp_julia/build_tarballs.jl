# Note that this script can accept some limited command-line arguments, run
# `julia build_tarballs.jl --help` to see a usage message.
using BinaryBuilder, Pkg
using Base.BinaryPlatforms

# Workarounds for Pkg.jl bugs with stdlibs
# See https://github.com/JuliaLang/Pkg.jl/issues/2942

# Delete OpenSSL_jll stdlib to avoid conflicts during dependency resolution
uuidopenssl = Base.UUID("458c3c95-2e84-50aa-8efc-19380b2a3a95")
delete!(Pkg.Types.get_last_stdlibs(v"1.12.0"), uuidopenssl)
delete!(Pkg.Types.get_last_stdlibs(v"1.13.0"), uuidopenssl)

# Workaround for haskey bug in Julia 1.12: Empty weakdeps from Pkg stdlib
# The bug is triggered when a stdlib (like Pkg) has weakdeps and gets resolved
# as part of the dependency graph. The code tries to call haskey(p.deps, name)
# where p.deps is a Vector{UUID} but the code expects a Dict.
# By emptying weakdeps, we avoid the buggy code path in Pkg.Operations.fixups_from_projectfile!
uuidpkg = Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f")
for v in [v"1.12.0", v"1.13.0"]
    stdlibs = Pkg.Types.get_last_stdlibs(v)
    if haskey(stdlibs, uuidpkg)
        empty!(stdlibs[uuidpkg].weakdeps)
    end
end

# Include libjulia common.jl to get julia_versions and libjulia_platforms
include("../../L/libjulia/common.jl")

# Filter to supported Julia versions (only 1.12 for now)
filter!(==(v"1.12"), julia_versions)

name = "vmecpp_julia"
version = v"0.4.11"

# julia_compat string for build_tarballs
julia_compat = libjulia_julia_compat(julia_versions)

# Collection of sources required to build vmecpp_julia
sources = [
    # Main vmecpp repository
    GitSource("https://github.com/proximafusion/vmecpp.git",
              "04f16f531ead8995b1f4a5a5f92024e82f83f86a"),  # v0.4.11

    # Eigen 3.4.0 (header-only)
    GitSource("https://gitlab.com/libeigen/eigen.git",
              "3147391d946bb4b6c68edd901f2add6ac1f31f8c",  # 3.4.0
              unpack_target="eigen"),

    # Abseil-cpp (specific commit used by vmecpp)
    GitSource("https://github.com/abseil/abseil-cpp.git",
              "4447c7562e3bc702ade25105912dce503f0c4010",
              unpack_target="abseil-cpp"),

    # nlohmann_json v3.11.3
    ArchiveSource("https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz",
                  "d6c65aca6b1ed68e7a182f4757257b107ae403032760ed6ef121c9d55e81757d",
                  unpack_target="nlohmann_json"),

    # abscab-cpp
    GitSource("https://github.com/jonathanschilling/abscab-cpp.git",
              "5cfa473b90aab06d7f70d986da0c46c46c1ebe9c",
              unpack_target="abscab-cpp"),

    # indata2json
    GitSource("https://github.com/jonathanschilling/indata2json.git",
              "f59e3ddd66486b63536f141a786d39c23d654c77",
              unpack_target="indata2json"),

    # LIBSTELL (submodule of indata2json)
    GitSource("https://github.com/ORNL-Fusion/LIBSTELL.git",
              "92ac5c339b31e29d9d734c20eae3e7571de8f490",
              unpack_target="LIBSTELL"),

    # json-fortran (submodule of indata2json)
    GitSource("https://github.com/jonathanschilling/json-fortran.git",
              "954a46c32958ea7d15884351f9b7f3aa397001e7",
              unpack_target="json-fortran"),

    # Julia wrapper sources (bundled)
    DirectorySource("./bundled"),
]

# Bash recipe for building across all platforms
script = raw"""
cd $WORKSPACE/srcdir

# Clean up macOS resource fork files (._*) that can corrupt CMake modules
# These files end up in the Docker container and cause parse errors
find /usr/share/cmake -name '._*' -delete 2>/dev/null || true

# Debug: List source directories
echo "Listing srcdir contents:"
ls -la

# ============================================
# Step 0: Setup submodules that weren't cloned recursively
# ============================================
echo "Setting up indata2json submodules..."
# Debug: Show what's in the source directories
echo "Contents of LIBSTELL directory:"
ls -la LIBSTELL/
echo "Contents of json-fortran directory:"
ls -la json-fortran/

# LIBSTELL and json-fortran are submodules of indata2json
# With unpack_target, content is in nested directory (LIBSTELL/LIBSTELL, json-fortran/json-fortran)
# Remove any existing placeholder directories from the submodule declarations, then move our content
rm -rf indata2json/indata2json/LIBSTELL indata2json/indata2json/json-fortran
mv LIBSTELL/LIBSTELL indata2json/indata2json/LIBSTELL
mv json-fortran/json-fortran indata2json/indata2json/json-fortran

# List the indata2json directory to verify
echo "Contents of indata2json/indata2json:"
ls -la indata2json/indata2json/
echo "Contents of indata2json/indata2json/LIBSTELL:"
ls -la indata2json/indata2json/LIBSTELL/ || echo "LIBSTELL dir not found"
echo "Contents of indata2json/indata2json/LIBSTELL/Sources (should exist):"
ls -la indata2json/indata2json/LIBSTELL/Sources/ || echo "LIBSTELL/Sources dir not found"

# ============================================
# Step 1: Build Abseil as static libraries
# ============================================
echo "Building Abseil..."

# Patch Abseil to remove architecture-specific flags that BinaryBuilder doesn't allow
# These flags are in GENERATED_AbseilCopts.cmake for hardware AES acceleration
sed -i 's/"-march=armv8-a+crypto"//g' abseil-cpp/abseil-cpp/absl/copts/GENERATED_AbseilCopts.cmake
sed -i 's/"-maes"//g' abseil-cpp/abseil-cpp/absl/copts/GENERATED_AbseilCopts.cmake
sed -i 's/"-msse4.1"//g' abseil-cpp/abseil-cpp/absl/copts/GENERATED_AbseilCopts.cmake
sed -i 's/"-mfpu=neon"//g' abseil-cpp/abseil-cpp/absl/copts/GENERATED_AbseilCopts.cmake

# On macOS, the old libc++ (darwin14) doesn't fully support C++20 features:
# 1. std::strong_ordering comparison operators are broken
# 2. <numbers> header (std::numbers::sqrt2 etc.) doesn't exist
# 3. std::construct_at doesn't exist
# We patch around these issues below
if [[ "${target}" == *-apple-* ]]; then
    echo "macOS detected: applying libc++ compatibility patches"

    # 1. Undefine __cpp_impl_three_way_comparison at the start of time.h
    #    This prevents Abseil from using the broken spaceship operator comparisons
    sed -i '1i #undef __cpp_impl_three_way_comparison' abseil-cpp/abseil-cpp/absl/time/time.h

    # 2. Create compatibility headers for vmecpp
    #    The darwin14 libc++ doesn't have these C++20 features
    mkdir -p compat_headers

    # 2a. <numbers> header with mathematical constants
    cat > compat_headers/numbers << 'NUMBERS_EOF'
// C++20 <numbers> compatibility header for old libc++
#pragma once
#include <cmath>
namespace std {
namespace numbers {
    inline constexpr double e          = 2.718281828459045235360287471352662;
    inline constexpr double log2e      = 1.442695040888963407359924681001892;
    inline constexpr double log10e     = 0.434294481903251827651128918916605;
    inline constexpr double pi         = 3.141592653589793238462643383279503;
    inline constexpr double inv_pi     = 0.318309886183790671537767526745029;
    inline constexpr double inv_sqrtpi = 0.564189583547756286948079451560773;
    inline constexpr double ln2        = 0.693147180559945309417232121458177;
    inline constexpr double ln10       = 2.302585092994045684017991454684364;
    inline constexpr double sqrt2      = 1.414213562373095048801688724209698;
    inline constexpr double sqrt3      = 1.732050807568877293527446341505872;
    inline constexpr double inv_sqrt3  = 0.577350269189625764509148780501958;
    inline constexpr double egamma     = 0.577215664901532860606512090082402;
    inline constexpr double phi        = 1.618033988749894848204586834365638;
}
}
NUMBERS_EOF
    echo "Created compat_headers/numbers"

    # 2b. construct_at_compat.h - provides std::construct_at for C++20 compatibility
    #     This header is force-included via -include flag
    #     It also ensures <optional> is included early to prevent Abseil's optional from shadowing std::optional
    cat > compat_headers/construct_at_compat.h << 'CONSTRUCT_AT_EOF'
// C++20 std::construct_at compatibility header for old libc++
// This provides std::construct_at which is missing in darwin14 libc++
// Also ensures std::optional is properly available before any Abseil headers
#pragma once

// Include <optional> early so it gets processed before Abseil's optional.h
// This prevents "no template named 'optional' in namespace 'std'" errors
#include <optional>

#include <memory>
#include <utility>
#include <new>

// Only define if not already available (check for C++20 feature macro)
#if !defined(__cpp_lib_constexpr_dynamic_alloc) || __cpp_lib_constexpr_dynamic_alloc < 201907L
namespace std {
template<typename T, typename... Args>
constexpr T* construct_at(T* p, Args&&... args) {
    return ::new (const_cast<void*>(static_cast<const volatile void*>(p)))
        T(std::forward<Args>(args)...);
}
} // namespace std
#endif
CONSTRUCT_AT_EOF
    echo "Created compat_headers/construct_at_compat.h"
fi

mkdir -p abseil-build && cd abseil-build
cmake ../abseil-cpp/abseil-cpp \
    -DCMAKE_INSTALL_PREFIX=${prefix} \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_CXX_STANDARD=20 \
    -DABSL_PROPAGATE_CXX_STD=ON \
    -DABSL_BUILD_TESTING=OFF
make -j${nproc}
make install
cd ..

# ============================================
# Step 2: Build vmecpp core (static library)
# ============================================
echo "Building vmecpp core..."

# Patch vmecpp CMakeLists.txt to remove Python bindings (pybind11)
# We only need vmecpp_core, not the Python module or indata2json executable
sed -i '/FetchContent_Declare.*pybind11/,/FetchContent_MakeAvailable.*pybind11/d' vmecpp/CMakeLists.txt
sed -i '/pybind11_add_module/,/install.*_vmecpp/d' vmecpp/CMakeLists.txt
# Also remove install target for indata2json (we only build vmecpp_core)
sed -i '/install.*TARGETS.*indata2json/d' vmecpp/CMakeLists.txt

# On macOS, patch vmecpp CMakeLists.txt to add libc++ compatibility flags
# IMPORTANT: Must add after project() because CMAKE_SYSTEM_NAME is not set until then
if [[ "${target}" == *-apple-* ]]; then
    echo "Patching vmecpp CMakeLists.txt for macOS compatibility..."
    # Add compile options AFTER the project() line (when CMAKE_SYSTEM_NAME is set)
    # The toolchain file is processed during project(), so we can check CMAKE_SYSTEM_NAME after
    # Flags:
    #   -isystem: Add compat_headers to search path for <numbers> header
    #   -include: Force-include construct_at_compat.h to provide std::construct_at
    #   _LIBCPP_DISABLE_AVAILABILITY: Allow std::optional::value() on macOS 10.10
    sed -i '/^project(vmecpp/a \
\
# macOS compatibility flags for BinaryBuilder darwin14 sysroot (C++20 on old libc++)\
# CMAKE_SYSTEM_NAME is only available after project() is called\
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")\
  message(STATUS "macOS detected: adding libc++ compatibility flags")\
  add_compile_options(-isystem /workspace/srcdir/compat_headers)\
  add_compile_options(-include /workspace/srcdir/compat_headers/construct_at_compat.h)\
  add_compile_definitions(_LIBCPP_DISABLE_AVAILABILITY)\
endif()' vmecpp/CMakeLists.txt
    echo "Patched vmecpp CMakeLists.txt - showing relevant section:"
    head -30 vmecpp/CMakeLists.txt
fi

mkdir -p vmecpp-build && cd vmecpp-build

# Configure vmecpp with vendored dependencies
# Set BLAS/LAPACK to use OpenBLAS from JLL
# Note: FetchContent variable names use the EXACT name from FetchContent_Declare
# For packages with hyphens, CMake converts them to underscores in cache variables
# BUT we also need to try the hyphenated form for compatibility

# Set macOS-specific cmake flags
MACOS_CXX_FLAGS=""
if [[ "${target}" == *-apple-* ]]; then
    MACOS_CXX_FLAGS="-isystem /workspace/srcdir/compat_headers -D_LIBCPP_DISABLE_AVAILABILITY"
    echo "macOS: Adding extra CXX flags: ${MACOS_CXX_FLAGS}"
fi

cmake ../vmecpp \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DFETCHCONTENT_SOURCE_DIR_EIGEN=${WORKSPACE}/srcdir/eigen/eigen \
    -DFETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON=${WORKSPACE}/srcdir/nlohmann_json/json \
    -DFETCHCONTENT_SOURCE_DIR_ABSEIL-CPP=${WORKSPACE}/srcdir/abseil-cpp/abseil-cpp \
    -DFETCHCONTENT_SOURCE_DIR_ABSCAB-CPP=${WORKSPACE}/srcdir/abscab-cpp/abscab-cpp \
    -DFETCHCONTENT_SOURCE_DIR_INDATA2JSON=${WORKSPACE}/srcdir/indata2json/indata2json \
    -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -Dabsl_DIR=${prefix}/lib/cmake/absl \
    -DBLA_VENDOR=OpenBLAS \
    -DLAPACK_LIBRARIES="${libdir}/libopenblas.${dlext}" \
    -DBLAS_LIBRARIES="${libdir}/libopenblas.${dlext}"

# Build only the core library (not Python bindings or standalone)
make -j${nproc} vmecpp_core
cd ..

# ============================================
# Step 3: Build Julia wrapper (shared library)
# ============================================
echo "Building Julia wrapper..."
# Note: DirectorySource("./bundled") copies contents to srcdir root, not to srcdir/bundled/
# So the CMakeLists.txt and vmecpp_julia.cpp are at ${WORKSPACE}/srcdir/
mkdir -p julia-build && cd julia-build
cmake .. \
    -DCMAKE_INSTALL_PREFIX=${prefix} \
    -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TARGET_TOOLCHAIN} \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=20 \
    -DJulia_PREFIX=${prefix} \
    -DVMECPP_SOURCE_DIR=${WORKSPACE}/srcdir/vmecpp \
    -DVMECPP_BUILD_DIR=${WORKSPACE}/srcdir/vmecpp-build \
    -DEIGEN_DIR=${WORKSPACE}/srcdir/eigen/eigen \
    -Dabsl_DIR=${prefix}/lib/cmake/absl
make -j${nproc}
make install

# Install license
install_license ${WORKSPACE}/srcdir/vmecpp/LICENSE.txt
"""

# Platforms - use libjulia_platforms from common.jl (already included above)
platforms = reduce(vcat, libjulia_platforms.(julia_versions))

# Filter out unsupported platforms
filter!(p -> arch(p) != "armv7l", platforms)  # ARM32 often problematic
filter!(p -> arch(p) != "armv6l", platforms)  # Experimental
filter!(p -> !Sys.iswindows(p), platforms)    # Windows not supported yet
filter!(p -> !Sys.isfreebsd(p), platforms)    # FreeBSD not tested
# macOS: darwin14 SDK (macOS 10.10) has old libc++ missing C++17 runtime symbols:
#   - std::filesystem (used by file_io.cc, mgrid_provider.cc)
#   - std::bad_optional_access (thrown by .value() in vmec_indata.cc)
# Compile-time workarounds for <numbers>, std::construct_at, and spaceship operator
# are in place and will work when BinaryBuilder supports a newer macOS SDK.
# TODO: Re-enable macOS when darwin17+ (macOS 10.13+) SDK becomes available
filter!(p -> !Sys.isapple(p), platforms)
filter!(p -> arch(p) != "i686", platforms)    # i686: 32-bit not needed
filter!(p -> arch(p) != "powerpc64le", platforms)  # ppc64le: not a target platform

# Expand C++ string ABIs
platforms = expand_cxxstring_abis(platforms)

# Products
products = [
    LibraryProduct("libvmecpp_julia", :libvmecpp_julia; dlopen_flags=[:RTLD_GLOBAL]),
]

# Dependencies
dependencies = [
    # Build dependencies
    BuildDependency(PackageSpec(;name="libjulia_jll", version="1.11.0")),

    # Runtime dependencies
    Dependency("libcxxwrap_julia_jll"; compat="~0.14.7"),
    Dependency("HDF5_jll"),
    Dependency("NetCDF_jll"),
    Dependency("OpenBLAS_jll"),
    Dependency("LLVMOpenMP_jll"),
    Dependency("CompilerSupportLibraries_jll"),
]

# Build the tarballs
build_tarballs(ARGS, name, version, sources, script, platforms, products, dependencies;
               preferred_gcc_version = v"10",  # C++20 support
               julia_compat)

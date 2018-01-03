using BinaryProvider
using BinaryBuilder
using BinaryBuilder: preferred_runner
using Base.Test
using SHA
using Compat

# The platform we're running on
const platform = platform_key()

# On windows, the `.exe` extension is very important
const exe_ext = Compat.Sys.iswindows() ? ".exe" : ""

# We are going to build/install libfoo a lot, so here's our function to make sure the
# library is working properly
function check_foo(fooifier_path = "fooifier$(exe_ext)",
                   libfoo_path = "libfoo.$(Libdl.dlext)")
    # We know that foo(a, b) returns 2*a^2 - b
    result = 2*2.2^2 - 1.1

    # Test that we can invoke fooifier
    @test !success(`$fooifier_path`)
    @test success(`$fooifier_path 1.5 2.0`)
    @test parse(Float64,readchomp(`$fooifier_path 2.2 1.1`)) ≈ result

    # Test that we can dlopen() libfoo and invoke it directly
    libfoo = Libdl.dlopen_e(libfoo_path)
    @test libfoo != C_NULL
    foo = Libdl.dlsym_e(libfoo, :foo)
    @test foo != C_NULL
    @test ccall(foo, Cdouble, (Cdouble, Cdouble), 2.2, 1.1) ≈ result
    Libdl.dlclose(libfoo)
end

@testset "File Collection" begin
    temp_prefix() do prefix
        # Create a file and a link, ensure that only the one file is returned by collect_files()
        f = joinpath(prefix, "foo")
        f_link = joinpath(prefix, "foo_link")
        touch(f)
        symlink(f, f_link)

        files = collect_files(prefix)
        @test length(files) == 2
        @test f in files
        @test f_link in files

        collapsed_files = collapse_symlinks(files)
        @test length(collapsed_files) == 1
        @test f in collapsed_files
    end
end

# This file contains tests that require our cross-compilation environment
@testset "Builder Dependency" begin
    temp_prefix() do prefix
        # First, let's create a Dependency that just installs a file
        begin
            ur = preferred_runner()(prefix.path; cwd="/workspace/", platform=platform)

            # Our simple executable file, generated by bash
            test_exe_sandbox_path = joinpath("/workspace/bin","test_exe")
            test_exe_path = joinpath(bindir(prefix),"test_exe")
            test_exe = ExecutableProduct(test_exe_path)
            results = [test_exe]

            # These commands will be run within the cross-compilation environment
            script = """
            /bin/mkdir -p $(dirname(test_exe_sandbox_path))
            printf '#!/bin/bash\necho test' > $(test_exe_sandbox_path)
            /bin/chmod 775 $(test_exe_sandbox_path)
            """
            dep = Dependency("bash_test", results, script, platform, prefix)

            @test build(ur, dep; verbose=true)
            @test satisfied(dep)
            @test readstring(`$(test_exe_path)`) == "test\n"
        end
    end

    begin
        build_path = tempname()
        mkpath(build_path)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], platform_key())
        cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            libfoo = LibraryProduct(prefix, "libfoo")
            fooifier = ExecutableProduct(prefix, "fooifier")
            script="""
            /usr/bin/make clean
            /usr/bin/make install
            """
            dep = Dependency("foo", [libfoo, fooifier], script, platform, prefix)

            # Build it
            @test build(ur, dep; verbose=true)
            @test satisfied(dep; verbose=true)

            # Test the binaries
            check_foo(locate(fooifier), locate(libfoo))

            # Also test the binaries through `activate()`
            activate(prefix)
            check_foo()
            deactivate(prefix)

            # Test that `collect_files()` works:
            all_files = collect_files(prefix)
            @test locate(libfoo) in all_files
            @test locate(fooifier) in all_files
        end
        rm(build_path, recursive = true)
    end
end

const libfoo_products = prefix->[
    LibraryProduct(prefix, "libfoo")
    ExecutableProduct(prefix, "fooifier")
]
const libfoo_script = """
/usr/bin/make clean
/usr/bin/make install
"""

@testset "Builder Packaging" begin
    # Clear out previous build products
    for f in readdir(".")
        if !endswith(f, ".tar.gz")
            continue
        end
        rm(f; force=true)
    end

    # Gotta set this guy up beforehand
    tarball_path = nothing
    tarball_hash = nothing

    begin
        build_path = tempname()
        mkpath(build_path)
        prefix, ur = BinaryBuilder.setup_workspace(build_path, [], [], [], platform_key())
        cd(joinpath(dirname(@__FILE__),"build_tests","libfoo")) do
            run(`cp $(readdir()) $(joinpath(prefix.path,"..","srcdir"))/`)

            # First, build libfoo
            dep = Dependency("foo", libfoo_products(prefix), libfoo_script, platform, prefix)

            @test build(ur, dep)
        end

        # Next, package it up as a .tar.gz file
        tarball_path, tarball_hash = package(prefix, "./libfoo"; verbose=true)
        @test isfile(tarball_path)

        # Delete the build path
        rm(build_path, recursive = true)
    end

    # Test that we can inspect the contents of the tarball
    contents = list_tarball_files(tarball_path)
    @test "bin/fooifier" in contents
    @test "lib/libfoo.$(Libdl.dlext)" in contents

    # Install it within a new Prefix
    temp_prefix() do prefix
        # Install the thing
        @test install(tarball_path, tarball_hash; prefix=prefix, verbose=true)

        # Ensure we can use it
        fooifier_path = joinpath(bindir(prefix), "fooifier")
        libfoo_path = joinpath(libdir(prefix), "libfoo.$(Libdl.dlext)")
        check_foo(fooifier_path, libfoo_path)
    end

    rm(tarball_path; force=true)
end

# Testset to make sure we can autobuild from a git repository
@testset "AutoBuild Git-Based" begin
    build_path = tempname()
    git_path = joinpath(build_path,"libfoo.git")
    mkpath(git_path)

    cd(build_path) do
        # Just like we package up libfoo into a tarball above, we'll create a fake
        # git repo for it here, then build from that.
        repo = LibGit2.init(git_path)
        LibGit2.commit(repo, "Initial empty commit")
        libfoo_dir = joinpath(@__DIR__, "build_tests", "libfoo")
        run(`cp -r $(libfoo_dir)/$(readdir(libfoo_dir)) $git_path/`)
        for file in ["fooifier.c", "libfoo.c", "Makefile"]
            LibGit2.add!(repo, file)
        end
        commit = LibGit2.commit(repo, "Add libfoo files")

        # Now build that git repository for Linux x86_64
        sources = [
            git_path =>
            LibGit2.hex(LibGit2.GitHash(commit)),
        ]

        autobuild(
            pwd(),
            "libfoo",
            [Linux(:x86_64, :glibc)],
            sources,
            "cd libfoo\n$libfoo_script",
            libfoo_products
        )

        # Make sure that worked
        @test isfile("products/libfoo.x86_64-linux-gnu.tar.gz")
    end

    rm(build_path; force=true, recursive=true)
end

include("wizard.jl")

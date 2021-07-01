& (Join-Path $PSScriptRoot .. .. build set-env.ps1)

function Build-QirProject {
    param (
        [string]
        $FolderPath,
        
        [Switch]
        $SkipQSharpBuild
    )

    if (!$SkipQSharpBuild) {
        Write-Host "##[info]Build Q# project for $Name '$FolderPath'"
        dotnet build $FolderPath -c $Env:BUILD_CONFIGURATION -v $Env:BUILD_VERBOSITY
        if ($LastExitCode -ne 0) {
            Write-Host "##vso[task.logissue type=error;]Failed to compile Q# project at '$FolderPath' into QIR."
            throw "Failed to compile Q# project at '$FolderPath' into QIR."
        }
    }
}

function Build-CMakeProject {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $Path,

        [Parameter()]
        [String]
        $Name
    )

    Write-Host "##[info]Build $Name"
    $oldCC = $env:CC
    $oldCXX = $env:CXX
    $oldRC = $env:RC
    $oldCFLAGS   = $env:CFLAGS
    $oldCXXFLAGS = $env:CXXFLAGS

    $clangTidy = ""

    # Treat warnings as errors:
    $warningFlags = "-Werror"  # https://clang.llvm.org/docs/UsersManual.html#options-to-control-error-and-warning-messages
    # Enable all warnings:
    $warningFlags += " -Weverything"    # https://clang.llvm.org/docs/UsersManual.html#enabling-all-diagnostics
                                        # https://clang.llvm.org/docs/DiagnosticsReference.html

    # Disable these warnings:

    # We don't care about keeping compatibility with C++98/03, C++11, C++14. Any new features unknown to our compiler version will be reported as errors.
    # -Wc++98-compat-pedantic
    #   -Wc++98-compat, 
    #       -Wc++98-compat-local-type-template-args, -Wc++98-compat-unnamed-type-template-args, -Wpre-c++14-compat, 
    #       -Wpre-c++17-compat, -Wpre-c++20-compat, -Wpre-c++2b-compat.
    #   -Wc++98-compat-bind-to-temporary-copy, -Wc++98-compat-extra-semi, 
    #   -Wpre-c++14-compat-pedantic, 
    #       -Wc++98-c++11-compat-binary-literal, -Wpre-c++14-compat.
    #   -Wpre-c++17-compat-pedantic, 
    #       -Wpre-c++17-compat.
    #   -Wpre-c++20-compat-pedantic, 
    #       -Wpre-c++20-compat.
    #   -Wpre-c++2b-compat-pedantic (= -Wpre-c++2b-compat).
    $warningFlags += " -Wno-c++98-compat-pedantic"   # https://clang.llvm.org/docs/DiagnosticsReference.html#wc-98-compat-pedantic
    # Old-style casts increase readability as opposed to `reinterpret_cast<..>()`. We want to be able to use the old-style casts.
    $warningFlags += " -Wno-old-style-cast"
    # Even if the `switch` covers all the enumerators, it is still good to have `default` label to cover the potential newly added (but not handled) enumerators.
    $warningFlags += " -Wno-covered-switch-default"
    # We are OK using C99 features.
    # -Wc99-extension
    #   -Wc99-designator
    #       -Wc++20-designator
    $warningFlags += " -Wno-c99-extensions"
    # We are OK that the structs are padded to align the fields.
    $warningFlags += " -Wno-padded"     # https://clang.llvm.org/docs/DiagnosticsReference.html#wpadded
    # We are OK with abstract classes.
    $warningFlags += " -Wno-weak-vtables"


    # Temporarily disable the following warnings (until QIR RT is refactored to expose C interface).

    # Looks like the `-Wglobal-constructors` warns that the instance of the `__dllexport` class/struct (or a static member var of such class/struct) 
    # needs to be constructible by calling a global `__dllexport` function (to guarantee that a single instance is created and the same instance is used 
    # both inside and outside of the binary (dynamic library or executable)).
    # Or it warns about the constructor that is invoked for a global (or static member) variable _before_ the `main()` is invoked, thus slowing down the start,
    # see https://stackoverflow.com/a/15708829/6362941
    $warningFlags += " -Wno-global-constructors"    # https://clang.llvm.org/docs/DiagnosticsReference.html#wglobal-constructors
    # Looks like the `-Wexit-time-destructors` warns that the destructor of a global or static member variable will be invoked
    # _after_ the `main()` returns (thus slowing down the termination/restart).
    $warningFlags += " -Wno-exit-time-destructors"

    # Temporarily disable "-Wextra-semi-stmt" that warns about redundant `;` in the end of `INFO(id);` of Catch tests framework (which looks fixed in the latest Catch version).
    # Disable until the Catch header "src\Qir\Common\externals\catch2\catch.hpp" is updated to a version newer than v2.12.1 (from https://github.com/catchorg/Catch2).
    $warningFlags += " -Wno-extra-semi-stmt"    # https://clang.llvm.org/docs/DiagnosticsReference.html#wextra-semi-stmt

    $env:CFLAGS   += $warningFlags
    $env:CXXFLAGS += $warningFlags


    # Sanitizers (https://clang.llvm.org/docs/UsersManual.html#controlling-code-generation):

    $sanitizeFlags = "" 
    if (-not ($IsWindows))
    {
        # Undefined Behavior Sanitizer (https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html)
        # WSL:
        #   unsigned-integer-overflow   Causes error reports in "qir-static-tests" in random number generator standard library (the test still succeeds):
        #       /usr/bin/../lib/gcc/x86_64-linux-gnu/9/../../../../include/c++/9/bits/random.h:552:58: runtime error: unsigned integer overflow: 0 - 1 cannot be represented in type 'unsigned long'
        #   Likely -fsanitize=implicit-integer-sign-change causes error reports in "qir-static-tests" in random number generator standard library (the test still succeeds):
        #       /usr/bin/../lib/gcc/x86_64-linux-gnu/9/../../../../include/c++/9/bits/uniform_int_dist.h:284:17: runtime error: implicit conversion from type \
        #           'std::uniform_int_distribution<long>::result_type' (aka 'long') of value -9223372036854775808 (64-bit, signed) to type 'unsigned long' changed the value \
        #           to 9223372036854775808 (64-bit, unsigned)
        # Win:
        #   [19/35] cmd.exe /C "cd . && C:\PROGRA~1\LLVM12\bin\CLANG_~1.EXE -fuse-ld=lld-link -nostartfiles -nostdlib \
        #       -Werror -Weverything -Wno-c++98-compat-pedantic -Wno-old-style-cast -Wno-covered-switch-default -Wno-c99-extensions \
        #       -Wno-padded -Wno-weak-vtables -Wno-global-constructors -Wno-exit-time-destructors -Wno-extra-semi-stmt \
        #       -fsanitize=undefined -fsanitize=float-divide-by-zero -fsanitize=unsigned-integer-overflow -fsanitize=implicit-conversion \
        #       -fsanitize=local-bounds -fsanitize=nullability -fno-omit-frame-pointer -fno-optimize-sibling-calls \
        #       -O2 -g -DNDEBUG -Xclang -gcodeview -D_DLL -D_MT -Xclang --dependent-lib=msvcrt  -Xlinker /guard:cf -shared \
        #       -o lib\QIR\Microsoft.Quantum.Qir.Runtime.dll  -Xlinker /implib:lib\QIR\Microsoft.Quantum.Qir.Runtime.lib \
        #       -Xlinker /pdb:lib\QIR\Microsoft.Quantum.Qir.Runtime.pdb -Xlinker /version:0.0 lib/QIR/bridge-rt.obj \
        #       lib/QIR/CMakeFiles/qir-rt-support-obj.dir/QirRange.cpp.obj lib/QIR/CMakeFiles/qir-rt-support-obj.dir/OutputStream.cpp.obj \
        #       lib/QIR/CMakeFiles/qir-rt-support-obj.dir/Output.cpp.obj lib/QIR/CMakeFiles/qir-rt-support-obj.dir/allocationsTracker.cpp.obj \
        #       lib/QIR/CMakeFiles/qir-rt-support-obj.dir/arrays.cpp.obj lib/QIR/CMakeFiles/qir-rt-support-obj.dir/callables.cpp.obj \
        #       lib/QIR/CMakeFiles/qir-rt-support-obj.dir/context.cpp.obj lib/QIR/CMakeFiles/qir-rt-support-obj.dir/delegated.cpp.obj \
        #       lib/QIR/CMakeFiles/qir-rt-support-obj.dir/strings.cpp.obj lib/QIR/CMakeFiles/qir-rt-support-obj.dir/utils.cpp.obj \
        #       lib/QIR/CMakeFiles/qir-rt-support-obj.dir/QubitManager.cpp.obj  -lkernel32 -luser32 -lgdi32 -lwinspool -lshell32 -lole32 \
        #       -loleaut32 -luuid -lcomdlg32 -ladvapi32 -loldnames && cd ."
        #   FAILED: lib/QIR/Microsoft.Quantum.Qir.Runtime.dll lib/QIR/Microsoft.Quantum.Qir.Runtime.lib
        #   lld-link: error: /failifmismatch: mismatch detected for 'RuntimeLibrary':
        #   >>> lib/QIR/CMakeFiles/qir-rt-support-obj.dir/QubitManager.cpp.obj has value MD_DynamicRelease
        #   >>> clang_rt.ubsan_standalone_cxx-x86_64.lib(ubsan_type_hash_win.cc.obj) has value MT_StaticRelease
        #   clang++: error: linker command failed with exit code 1 (use -v to see invocation)
        $sanitizeFlags += " -fsanitize=undefined -fsanitize=float-divide-by-zero -fsanitize=unsigned-integer-overflow -fsanitize=implicit-conversion -fsanitize=local-bounds -fsanitize=nullability"
        # TODO: 
        #     Consider "Silencing Unsigned Integer Overflow" (https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html#silencing-unsigned-integer-overflow)
        #         for "qir-static-tests".
        #     Consider extracting into a separate .cpp or binary and compile with no `-fsanitize=unsigned-integer-overflow`. All others compile with `-fsanitize=unsigned-integer-overflow`.
        #         Issue: `unsigned-integer-overflow` seems to be a part of some other check that is a part of `-fsanitize=undefined`. See https://github.com/google/sanitizers/issues/1421.
        #             How to enable `-fsanitize=undefined` except `unsigned-integer-overflow`? Issue filed https://github.com/google/sanitizers/issues/1422.
        #     Consider calming down `-fsanitize=implicit-integer-sign-change` for "qir-static-tests".
        #     For Win consider extra build configuration linking all libs staticly, and enable `-fsanitize=undefined`, run the staticly linked tests.

        $sanitizeFlags += " -fno-omit-frame-pointer"            # https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
        $sanitizeFlags += " -fno-optimize-sibling-calls"        # https://clang.llvm.org/docs/AddressSanitizer.html
    }

    $env:CFLAGS   += $sanitizeFlags
    $env:CXXFLAGS += $sanitizeFlags


    if (($IsMacOS) -or ((Test-Path Env:AGENT_OS) -and ($Env:AGENT_OS.StartsWith("Darwin"))))
    {
        Write-Host "On MacOS build $Name using the default C/C++ compiler (should be AppleClang)"
    }
    elseif (($IsLinux) -or ((Test-Path Env:AGENT_OS) -and ($Env:AGENT_OS.StartsWith("Lin"))))
    {
        Write-Host "On Linux build $Name using Clang"
        $env:CC = "clang-11"
        $env:CXX = "clang++-11"
        $env:RC = "clang++-11"
        $clangTidy = "-DCMAKE_CXX_CLANG_TIDY=clang-tidy-11"
    }
    elseif (($IsWindows) -or ((Test-Path Env:AGENT_OS) -and ($Env:AGENT_OS.StartsWith("Win"))))
    {
        Write-Host "On Windows build $Name using Clang"
        $env:CC = "clang.exe"
        $env:CXX = "clang++.exe"
        $env:RC = "clang++.exe"

        if (!(Get-Command clang -ErrorAction SilentlyContinue) -and (choco find --idonly -l llvm) -contains "llvm") {
            # LLVM was installed by Chocolatey, so add the install location to the path.
            $env:PATH += ";$($env:SystemDrive)\Program Files\LLVM\bin"
        }

        if (Get-Command clang-tidy -ErrorAction SilentlyContinue) {
            # Only run clang-tidy if it's installed. This is because the package used by chocolatey on
            # the build pipeline doesn't include clang-tidy, so we allow skipping that there and let
            # the Linux build catch tidy issues.
            $clangTidy = "-DCMAKE_CXX_CLANG_TIDY=clang-tidy"
        }
    } else {
        Write-Host "##vso[task.logissue type=warning;]Failed to identify the OS. Will use default CXX compiler"
    }

    $cmakeBuildFolder = (Join-Path $Path bin $Env:BUILD_CONFIGURATION)
    if (-not (Test-Path $cmakeBuildFolder)) {
        New-Item -Path $cmakeBuildFolder -ItemType "directory"
    }

    $all_ok = $true

    Push-Location $cmakeBuildFolder

    $buildType = $Env:BUILD_CONFIGURATION
    if ($buildType -eq "Release"){
        $buildType = "RelWithDebInfo"
    }

    cmake -G Ninja $clangTidy -DCMAKE_VERBOSE_MAKEFILE:BOOL=ON -D CMAKE_BUILD_TYPE="$buildType" ../.. | Write-Host
    if ($LastExitCode -ne 0) {
        Write-Host "##vso[task.logissue type=error;]Failed to generate $Name."
        $all_ok = $false
    } else {
        cmake --build . --target install | Write-Host
        if ($LastExitCode -ne 0) {
            Write-Host "##vso[task.logissue type=error;]Failed to build $Name."
            $all_ok = $false
        }
    }

    Pop-Location

    $env:CXXFLAGS = $oldCXXFLAGS
    $env:CFLAGS   = $oldCFLAGS

    $env:CC = $oldCC
    $env:CXX = $oldCXX
    $env:RC = $oldRC

    return $all_ok
}

function Test-CTest {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Path,

        [Parameter()]
        [string]
        $Name
    )
    
    Write-Host "##[info]Test $Name"

    $all_ok = $true
    Push-Location $Path

    ctest --verbose | Write-Host
    
    if ($LastExitCode -ne 0) {
        Write-Host "##vso[task.logissue type=error;]Failed to test $Name"
        $all_ok = $False
    }
    
    Pop-Location

    return $all_ok
}
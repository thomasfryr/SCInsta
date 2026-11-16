#!/usr/bin/env bash

set -e

CMAKE_OSX_ARCHITECTURES="arm64e;arm64"
CMAKE_OSX_SYSROOT="iphoneos"

# Prerequisites (only required when building with --dev)
if [ "$2" == "--dev" ] && [ -z "$(ls -A modules/FLEXing)" ]; then
    echo -e '\033[1m\033[0;31mFLEXing submodule not found.\nPlease run the following command to checkout submodules:\n\n\033[0m    git submodule update --init --recursive'
    exit 1
fi

# Building modes
if [ "$1" == "sideload" ];
then

    # Check if building with dev mode
    if [ "$2" == "--dev" ];
    then
        # Cache pre-built FLEX libs
        mkdir -p "packages/cache"
        cp -f ".theos/obj/debug/FLEXing.dylib" "packages/cache/FLEXing.dylib" 2>/dev/null || true
        cp -f ".theos/obj/debug/libflex.dylib" "packages/cache/libflex.dylib" 2>/dev/null || true

        if [[ ! -f "packages/cache/FLEXing.dylib" || ! -f "packages/cache/libflex.dylib" ]]; then
            echo -e '\033[1m\033[0;33mCould not find cached pre-built FLEX libs, building prerequisite binaries\033[0m'
            echo

            ./build.sh sideload --buildonly
            ./build-dev.sh true
            exit
        fi

        MAKEARGS='DEV=1'
        FLEXPATH='packages/cache/FLEXing.dylib packages/cache/libflex.dylib'
        COMPRESSION=0
    elif [ "$2" == "--buildonly" ];
    then
        MAKEARGS='DEV=1'
        FLEXPATH=''
        COMPRESSION=0
    else
        # Production sideload build: exclude debug libraries (FLEXing.dylib / libflex.dylib)
        rm -rf "packages/cache"

        MAKEARGS='SIDELOAD=1'
        FLEXPATH=''
        COMPRESSION=9
    fi

    # Clean build artifacts
    make clean
    rm -rf .theos

    # Check for decrypted instagram ipa
    mkdir -p packages
    ipaFile="$(find ./packages -maxdepth 1 -type f -name '*com.burbn.instagram*.ipa' -exec basename {} \; | head -n 1)"
    if [ -z "${ipaFile}" ]; then
        echo -e '\033[1m\033[0;31m./packages/com.burbn.instagram.ipa not found.\nPlease put a decrypted Instagram IPA in its path.\033[0m'
        exit 1
    fi

    echo -e '\033[1m\033[32mBuilding SCInsta tweak for sideloading (as IPA)\033[0m'

    make $MAKEARGS

    # Only build libs (for future use in dev build mode)
    if [ "$2" == "--buildonly" ];
    then
        exit
    fi

    SCINSTAPATH=".theos/obj/debug/SCInsta.dylib"
    if [ "$2" == "--devquick" ];
    then
        # Exclude SCInsta.dylib from ipa for livecontainer quick builds
        SCINSTAPATH=""
    fi

    # Create IPA File
    echo -e '\033[1m\033[32mCreating the IPA file...\033[0m'
    rm -f packages/SCInsta-sideloaded.ipa

    # Detect cyan plist merge flag (-l in pyzule-rw v1.4+, -p in legacy wrappers)
    if cyan --help 2>&1 | grep -q -- "-l plist"; then
        CYAN_PLIST_FLAG="-l"
    else
        CYAN_PLIST_FLAG="-p"
    fi

    cyan -i "packages/${ipaFile}" -o packages/SCInsta-sideloaded.ipa -f $SCINSTAPATH $FLEXPATH $CYAN_PLIST_FLAG url_scheme.plist -b com.scinsta.app -c $COMPRESSION -m 15.0 -due
    
    # Patch IPA for sideloading
    ipapatch --input "packages/SCInsta-sideloaded.ipa" --inplace --noconfirm

    echo -e "\033[1m\033[32mDone, we hope you enjoy SCInsta!\033[0m\n\nYou can find the ipa file at: $(pwd)/packages"

elif [ "$1" == "rootless" ];
then
    
    # Clean build artifacts
    make clean
    rm -rf .theos

    echo -e '\033[1m\033[32mBuilding SCInsta tweak for rootless\033[0m'

    export THEOS_PACKAGE_SCHEME=rootless
    make package

    echo -e "\033[1m\033[32mDone, we hope you enjoy SCInsta!\033[0m\n\nYou can find the deb file at: $(pwd)/packages"

elif [ "$1" == "rootful" ];
then

    # Clean build artifacts
    make clean
    rm -rf .theos

    echo -e '\033[1m\033[32mBuilding SCInsta tweak for rootful\033[0m'

    unset THEOS_PACKAGE_SCHEME
    make package

    echo -e "\033[1m\033[32mDone, we hope you enjoy SCInsta!\033[0m\n\nYou can find the deb file at: $(pwd)/packages"

else
    echo '+--------------------+'
    echo '|SCInsta Build Script|'
    echo '+--------------------+'
    echo
    echo 'Usage: ./build.sh <sideload/rootless/rootful>'
    exit 1
fi
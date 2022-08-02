#!/bin/bash

# vim: tabstop=4 shiftwidth=4 softtabstop=4
# -*- sh-basic-offset: 4 -*-

set -exuo pipefail

BUILD_TARGET=/build
SRC=/src
QT_BRANCH="5.15.2"
DEBIAN_VERSION=$(lsb_release -cs)
MAKE_CORES="$(expr $(nproc) + 2)"

mkdir -p "$BUILD_TARGET"
mkdir -p "$SRC"

/usr/games/cowsay -f tux "Building QT version $QT_BRANCH."

function fetch_rpi_firmware () {
    if [ ! -d "/src/opt" ]; then
        pushd /src

        # We do an `svn checkout` here as the entire git repo here is *huge*
        # and `git` doesn't  support partial checkouts well (yet)
        svn checkout -q https://github.com/raspberrypi/firmware/trunk/opt
        popd
    fi

    # We need to exclude all of these .h and android files to make QT build.
    # In the blog post referenced, this is done using `dpkg --purge libraspberrypi-dev`,
    # but since we're copying in the source, we're just going to exclude these from the rsync.
    # https://www.enricozini.org/blog/2020/qt5/build-qt5-cross-builder-with-raspbian-sysroot-compiling-with-the-sysroot-continued/
    rsync \
        -aP \
        --exclude '*android*' \
        --exclude 'hello_pi' \
        --exclude '.svn' \
        /src/opt/ /sysroot/opt/
}

function patch_qt () {
    # Yes, yes, this all should be converted to proper patches
    # but I really just wanted to get it to work.

    # QT is linking against the old libraries for Pi 1 - Pi 3
    # https://bugreports.qt.io/browse/QTBUG-62216
    sed -i 's/lEGL/lbrcmEGL/' "/src/qt5/qtbase/mkspecs/devices/$1/qmake.conf"
    sed -i 's/lGLESv2/lbrcmGLESv2/' "/src/qt5/qtbase/mkspecs/devices/$1/qmake.conf"

    # Qmake won't account for sysroot
    # https://wiki.qt.io/RaspberryPi2EGLFS
    sed -i 's#^VC_LIBRARY_PATH.*#VC_LIBRARY_PATH = $$[QT_SYSROOT]/opt/vc/lib#' "/src/qt5/qtbase/mkspecs/devices/$1/qmake.conf"
    sed -i 's#^VC_INCLUDE_PATH.*#VC_INCLUDE_PATH = $$[QT_SYSROOT]/opt/vc/include#' "/src/qt5/qtbase/mkspecs/devices/$1/qmake.conf"
    sed -i 's#^VC_LINK_LINE.*#VC_LINK_LINE = -L$${VC_LIBRARY_PATH}#' "/src/qt5/qtbase/mkspecs/devices/$1/qmake.conf"
    sed -i 's#^QMAKE_LIBDIR_OPENGL_ES2.*#QMAKE_LIBDIR_OPENGL_ES2 = $${VC_LIBRARY_PATH}#' "/src/qt5/qtbase/mkspecs/devices/$1/qmake.conf"
}

function patch_qtwebengine () {
    # Patch up WebEngine due to GCC bug
    # https://www.enricozini.org/blog/2020/qt5/build-qt5-cross-builder-with-raspbian-sysroot-compiling-with-the-sysroot/
    # https://gcc.gnu.org/bugzilla/show_bug.cgi?id=96206
    pushd "/src/qt5/qtwebengine"
    sed -i '1s/^/#pragma GCC push_options\n#pragma GCC optimize ("O0")\n/' src/3rdparty/chromium/third_party/skia/third_party/skcms/skcms.cc
    echo "#pragma GCC pop_options" >> src/3rdparty/chromium/third_party/skia/third_party/skcms/skcms.cc
    popd
}

function fetch_qt5 () {
    local SRC_DIR="/src/qt5"
    pushd /src

    if [ ! -d "$SRC_DIR" ]; then

        if [ ! -f "qt-everywhere-src-5.15.2.tar.xz" ]; then
            wget https://download.qt.io/archive/qt/5.15/5.15.2/single/qt-everywhere-src-5.15.2.tar.xz
        fi

        if [ ! -f "md5sums.txt" ]; then
            wget https://download.qt.io/archive/qt/5.15/5.15.2/single/md5sums.txt
        fi
        md5sum --ignore-missing -c md5sums.txt

        # Extract and make a clone
        tar xf qt-everywhere-src-5.15.2.tar.xz
        rsync -aqP qt-everywhere-src-5.15.2/ qt5
    else
        rsync -aqP --delete qt-everywhere-src-5.15.2/ qt5
    fi
    popd
}

function build_qt () {
    # This build process is inspired by
    # https://www.tal.org/tutorials/building-qt-512-raspberry-pi
    local SRC_DIR="/src/$1"


    if [ ! -f "$BUILD_TARGET/qt5-$QT_BRANCH-$DEBIAN_VERSION-$1.tar.gz" ]; then
        /usr/games/cowsay -f tux "Building QT for $1"

        # Make sure we have a clean QT 5 tree
        fetch_qt5

        if [ "${CLEAN_BUILD-x}" == "1" ]; then
            rm -rf "$SRC_DIR"
        fi

        mkdir -p "$SRC_DIR"
        pushd "$SRC_DIR"

        if [ "$1" = "pi1" ]; then
            local BUILD_ARGS=(
                "-device" "linux-rasp-pi-g++"
            )
            patch_qt "linux-rasp-pi-g++"
            patch_qtwebengine
        elif [ "$1" = "pi2" ]; then
            local BUILD_ARGS=(
                "-device" "linux-rasp-pi2-g++"
            )
            patch_qt "linux-rasp-pi2-g++"
        elif [ "$1" = "pi3" ]; then
            local BUILD_ARGS=(
                "-device" "linux-rasp-pi3-g++"
            )
            patch_qt "linux-rasp-pi3-g++"

        # The opengl flag only works on Pi 4. It breaks the QTWebEngine build
        # process on any other model.
        elif [ "$1" = "pi4" ]; then
            local BUILD_ARGS=(
                "-device" "linux-rasp-pi4-v3d-g++"
                "-opengl" "es2"
            )
        else
            echo "Unknown device. Exiting."
            exit 1
        fi

        # @TODO: Add in the `-opengl es2` flag for Pi 1 - Pi 3.
        # Currently this breaks the QTWebEngine process.
        /src/qt5/configure \
            "${BUILD_ARGS[@]}" \
            -ccache \
            -confirm-license \
            -dbus-linked \
            -device-option CROSS_COMPILE=/usr/bin/arm-linux-gnueabihf- \
            -no-eglfs \
            -no-linuxfb \
            -evdev \
            -extprefix "$SRC_DIR/qt5pi" \
            -force-pkg-config \
            -glib \
            -make libs \
            -no-compile-examples \
            -no-cups \
            -no-gbm \
            -no-gtk \
            -no-pch \
            -no-use-gold-linker \
            -nomake examples \
            -nomake tests \
            -opensource \
            -prefix /usr/local/qt5pi \
            -qpa xcb \
            -xcb \
            -qt-pcre \
            -reduce-exports \
            -release \
            -skip qt3d \
            -skip qtactiveqt \
            -skip qtandroidextras \
            -skip qtcanvas3d \
            -skip qtdatavis3d \
            -skip qtgamepad \
            -skip qtlocation \
            -skip qtlottie \
            -skip qtmacextras \
            -skip qtpurchasing \
            -skip qtsensors \
            -skip qtspeech \
            -skip qtwayland \
            -skip qtwebview \
            -skip qtwinextras \
            -skip qtx11extras \
            -skip wayland \
            -skip webengine \
            -ssl \
            -system-freetype \
            -system-libjpeg \
            -system-libpng \
            -system-zlib \
            -feature-dialog \
            -sysroot /sysroot
        # The RAM consumption is proportional to the amount of cores.
        # On an 8 core box, the build process will require ~16GB of RAM.
        make -j"$MAKE_CORES"
        make install

        # I'm not sure we actually need this anymore. It's from an
        # old build process for QT 4.9 that we used.
        cp -r /usr/share/fonts/truetype/dejavu/ "$SRC_DIR/qt5pi/lib/fonts"

        pushd "$SRC_DIR"
        tar cfz "$BUILD_TARGET/qt5-$QT_BRANCH-$DEBIAN_VERSION-$1.tar.gz" qt5pi
        popd

        pushd "$BUILD_TARGET"
        sha256sum "qt5-$QT_BRANCH-$DEBIAN_VERSION-$1.tar.gz" > "qt5-$QT_BRANCH-$DEBIAN_VERSION-$1.tar.gz.sha256"
        popd
    else
        echo "QT Build already exist."
    fi
}

function build_module () {
    local SRC_DIR="/src/$1"
    local MODULE="$2"
    if [ ! -f "$BUILD_TARGET/$MODULE-$QT_BRANCH-$DEBIAN_VERSION-$1-$GIT_HASH.tar.gz" ]; then
        if [ "${BUILD_MQTT-x}" == "1" ]; then
            if [ ! -d "$SRC_DIR/$MODULE" ] ; then
                git clone --depth=1 "git://code.qt.io/qt/$MODULE.git" -b "5.15.2" "$SRC_DIR/$MODULE"
            else
                pushd "$SRC_DIR/$MODULE"
                git reset --hard "5.15.2"
                popd
            fi

            pushd "$SRC_DIR/$MODULE"
            mkdir -p fakeroot
            "$SRC_DIR/qt5pi/bin/qmake"
            make -j"$MAKE_CORES"
            INSTALL_ROOT="$SRC_DIR/$MODULE/fakeroot/" make install

            pushd fakeroot
            tar cfz "$BUILD_TARGET/$MODULE-$QT_BRANCH-$DEBIAN_VERSION-$1-$GIT_HASH.tar.gz" .
            popd

            pushd "$BUILD_TARGET"
            sha256sum "$MODULE-$QT_BRANCH-$DEBIAN_VERSION-$1-$GIT_HASH.tar.gz" > "$MODULE-$QT_BRANCH-$DEBIAN_VERSION-$1-$GIT_HASH.tar.gz.sha256"
            popd
        fi
    else
        echo "$MODULE Build already exist."
    fi
}

function build_qtjsonserializer () {
    local SRC_DIR="/src/$1"

    if [ ! -f "$BUILD_TARGET/qtjsonserializer-$QT_BRANCH-$DEBIAN_VERSION-$1-$GIT_HASH.tar.gz" ]; then
        if [ "${BUILD_QTJSONSERLIALIZER-x}" == "1" ]; then
            if [ ! -d "$SRC_DIR/qtjsonserializer" ] ; then
                git clone --depth=1 https://github.com/Skycoder42/QtJsonSerializer.git -b 3.2.0-2 "$SRC_DIR/qtjsonserializer"
            else
                pushd "$SRC_DIR/qtjsonserializer"
                git reset --hard "3.2.0-2"
                popd
            fi

            pushd "$SRC_DIR/qtjsonserializer"
            mkdir -p fakeroot

	    sed -i '/doxygen/d' qtjsonserializer.pro
	    sed -i '/runtests/d' qtjsonserializer.pro
 	    sed -i '/doc/d' qtjsonserializer.pro
            "$SRC_DIR/qt5pi/bin/qmake"
            make qmake_all -j"$MAKE_CORES"
            make -j"$MAKE_CORES"
            make
            INSTALL_ROOT="$SRC_DIR/qtjsonserializer/fakeroot/" make install

            pushd fakeroot
            tar cfz "$BUILD_TARGET/qtjsonserializer-$QT_BRANCH-$DEBIAN_VERSION-$1-$GIT_HASH.tar.gz" .
            popd

            pushd "$BUILD_TARGET"
            sha256sum "qtjsonserializer-$QT_BRANCH-$DEBIAN_VERSION-$1-$GIT_HASH.tar.gz" > "qtjsonserializer-$QT_BRANCH-$DEBIAN_VERSION-$1-$GIT_HASH.tar.gz.sha256"
            popd
        fi
    else
        echo "qtjsonserializer Build already exist."
    fi
}

function export_sysroot () {
    if [ ! -f "$BUILD_TARGET/sysroot-$DEBIAN_VERSION.tar.gz" ]; then
        echo "exporting sysroot"
        pushd /sysroot
        tar cfz "$BUILD_TARGET/sysroot-$DEBIAN_VERSION.tar.gz" .
        popd
    else
        echo "sysroot is already exported."
    fi
}

# Modify paths for build process
/usr/local/bin/sysroot-relativelinks.py /sysroot

fetch_rpi_firmware

if [ ! "${TARGET-}" ]; then
    # Let's work our way through all Pis in order of relevance
    for device in pi4 pi3 pi2 pi1; do
        build_qt "$device"
        build_module "$device" "qtmqtt"
#        build_module "$device" "qtquickcontrols"
        build_qtjsonserializer "$device"
    done
else
    build_qt "$TARGET"
    build_module "$TARGET" "qtmqtt"
#    build_module "$TARGET" "qtquickcontrols"
    build_qtjsonserializer "$TARGET"
fi

export_sysroot

#!/bin/bash
# Extract Qt
tar -xf qt5-5.15.2-buster-pi3.tar.gz --exclude="qt5pi/include" --exclude="qt5pi/lib/libQt5WebEngineCore.so.5.15.2" \
	--exclude="qt5pi/doc" --exclude="qt5pi/translations/qtwebengine_locales" --exclude="qt5pi/mkspecs"
tar -xf qtjsonserializer-5.15.2-buster*.tar.gz --strip-components 3
tar -xf qtmqtt-5.15.2-buster-pi3*.tar.gz --strip-components 3
# Install symlinks
sudo ln -fs /home/pi/super/qt5pi /usr/local/
echo '/usr/local/qt5pi/lib/' | sudo tee -a /etc/ld.so.conf.d/qt5pi.conf
sudo ldconfig

#!/bin/bash

pb="/Applications/PureBasic.app/Contents/Resources"
pbalt="/Applications/PureBasic-x86.app/Contents/Resources"
name="iCanHazMusic"
shortName="ichm"
ident="wtf.d7.icanhazmusic"
loc="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

noColor='\033[0m'
greenColor='\033[32m'
redColor='\033[31m'

cd "$loc"
export PUREBASIC_HOME="$pb"
rm -rf "$loc/$name.app"
rm -rf "$loc/$name-alt.app"
rm -rf "$loc/$shortName.zip"
rm -rf "$loc/$shortName.dmg"

die() {
	echo -e $redColor"\n$1"$noColor
	exit 1
}

if [ -f "$pb/compilers/pbcompiler" ]; then
	echo -ne $greenColor"compiling $shortName..."$noColor
	"$pb/compilers/pbcompiler" -u -t -e "$loc/$name.app" "$loc/../main.pb" > /dev/null || die "failed to build $shortName"
	if [ -d "$pbalt" ]; then
		export PUREBASIC_HOME="$pbalt"
		echo -ne $greenColor"\ncompiling $shortName for different arch..."$noColor
		"$pbalt/compilers/pbcompiler" -u -t -e "$loc/$name-alt.app" "$loc/../main.pb" > /dev/null || die "failed to build $shortName"
		export PUREBASIC_HOME="$pb"
		echo -ne $greenColor"\ncreating universal binary..."$noColor
		lipo -create -output "$name" "$loc/$name.app/Contents/MacOS/$name" "$loc/$name-alt.app/Contents/MacOS/$name-alt" || die "failed to create universal library"
		strip "$name"
		mv -f "$name" "$loc/$name.app/Contents/MacOS/$name"
	fi
	if [ -d "$loc/$name.app" ]; then
		echo -ne $greenColor"\ninjecting resources..."$noColor
		cd ..
        echo -ne $greenColor"\ncompiling ffmpeg..."$noColor
        build/build-ffmpeg.sh
		build/inject.sh "$loc/$name.app" || die "failed to inject $shortName"
		echo -ne $greenColor"\nsigning bundle..."$noColor
		if [ ! -z "$1" ]; then
			# app signing
			codesign -f -s $1 "$loc/$name.app" -r="host => anchor apple and identifier com.apple.translate designated => identifier $ident" > /dev/null || die "failed to sign $shortName"
		fi
		echo -ne $greenColor"\npacking distro..."$noColor
		cd "$loc"
		zip -r9 "$shortName.zip" "$name.app" > /dev/null || die "failed to pack $shortName"
		echo -ne $greenColor"\ncreating dmg..."$noColor
		cd appdmg
		appdmg "$name.json" "../$shortName.dmg" > /dev/null 2>&1 || die "failed to create dmg"
		echo
	else
		die "bundle not found"
	fi
else
	die "can't find PB here: $pb"
fi

# iCanHazMusic
A music player for macOS 10.12 or higher. Currently in active development, early preview version can be downloaded on [the releases page](https://github.com/deseven/iCanHazMusic/releases).

Main app:  
![iCHM screenshot](https://d7.wtf/s/ichm.png)

Basic web interface:  
![iCHM web screenshot](https://d7.wtf/s/ichm-web.png)

## Why
I was a big fan of the legendary [foobar2000](https://www.foobar2000.org/) until I moved to macOS in 2010. Naturally, for some time I continued using foobar under Wine, but the experience was subpar and eventually I started jumping from player to player. Some notable examples in no particular order:
 - [Clementine](https://www.clementine-player.org/) with its [6 year old bug](https://github.com/clementine-player/Clementine/issues/4733) that makes it eat up to 50% of CPU for a simple mp3 playback
 - [cmus](https://cmus.github.io/), which was fun and all, but just a bit too minimalistic
 - [DeaDBeeF](https://deadbeef.sourceforge.io/) with no stable release and insane bugs, although the development of the macOS version started 7 years ago and is pretty active to this day
 - [mac version of foobar2000](https://www.foobar2000.org/mac) which is a fucking joke of a player

I remember many other apps, both free and paid, however each and every one of them did lack something important. It's also worth mentioning that with every year the chance to get a decent desktop audio player is only getting lower and lower - it's an age of cloud music now, not many people are still interested in those mammoths of a bygone era. Hell, even I will probably go cloud in the coming years, I already use [iBroadcast](https://www.ibroadcast.com/) as a mobile and web player. However, the urge of having a good desktop player is still here for me, that's why I finally decided to go for it myself.

It's by no means a replacement for foobar2000, just my personal compilation of things I would like to see in an audio player. Nothing is set in stone, however, feel free to create new issues with feedback and suggestions.

## Current state
#### What should work
 - m4a, aac, mp3, wav, ogg, oga, flac, alac, wv and ape playback
 - last.fm scrobbling and now playing updates (enable it in the menu)
 - playback navigation and queue
 - grouping by albums
 - dock menu
 - big (10k+ entries) playlists
 - window size and position saving
 - album art from external files
 - lyrics loading from Genius (if you installed the lyricsgenius module, see the section below)
 - queue, playback orders
 - simble web interface and api

#### What should work in the future 
 - global hotkeys for playback
 - album art from tags
 - playlist entries rearrangement
 - seekbar
 - volume control
 - drag'n'drop operations
 - playlist search

#### What is not planned
 - gapless playback (well, maybe someday...)
 - CUE support
 - equalizer
 - tags editing, format conversion and other Swiss knife functions
 - advanced foobar2000-level customization (i'm too dumb for that, sorry)

## Web interface & API
Enable web server in preferences, then open http://0.0.0.0:8008/ (change port according to your settings), enter your API key when prompted. Go to http://0.0.0.0:8008/api/ to get the list of available methods. Example usage with curl:  
`curl http://127.0.0.1:8008/api/play-pause -H 'X-Api-Key: your_api_key'`

## Enabling lyrics loading
This should be changed in the future but for now in order for this to work you need to install [python3 from homebrew](https://formulae.brew.sh/formula/python@3.9) with `brew install python@3.9` and then [lyricgenius module](https://pypi.org/project/lyricsgenius/) with `pip3 install lyricsgenius`. Test that this works in your terminal:  
`/usr/local/bin/python3 -m lyricsgenius -h`

## Compiling from source
iCHM is created in [PB](http://purebasic.com) and depends on [pb-macos-audioplayer](https://github.com/deseven/pb-macos-audioplayer), along with [pb-httprequest-manager](https://github.com/deseven/pb-httprequest-manager).  
You also need [node-appdmg](https://github.com/LinusU/node-appdmg) if you want to build dmg.  
1. Obtain the latest LTS version of pbcompiler, install it to ```/Applications```.  
2. Install xcode command line tools by running ```xcode-select --install```.  
3. Clone iCHM repo.  
4. Clone ```pb-macos-audioplayer``` and ```pb-httprequest-manager``` modules to neighboring directories.  
5. Run the included ```build/build.sh``` script to build the app. If you want codesigning then provide your developer ID as a first argument.  
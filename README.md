# iCanHazMusic
![iCHM logo](https://raw.githubusercontent.com/deseven/iCanHazMusic/master/build/icon.png)
A music player for macOS 10.12 or higher. Currently in active development, early preview version can be download on [the releases page](https://github.com/deseven/iCanHazMusic/releases).

![iCHM screenshot](https://d7.wtf/s/GollySuspectfulNonrealization.png)

#### What should work
 - m4a, aac, mp3, wav, ogg, flac and aiff playback
 - last.fm scrobbling and now playing updates (enable it in the menu)
 - playback navigation and queue
 - grouping by albums
 - dock menu
 - big (10k+ entries) playlists
 - window size and position saving
 - album art from external files
 - lyrics loading from Genius (if you installed the lyricsgenius module, see the section below)

#### What should work in the future 
 - global hotkeys for playback
 - album art from tags
 - playlist entries rearrangement
 - seekbar
 - volume control
 - shuffle
 - drag'n'drop operations

#### What will never work 
 - gapless playback (well, maybe someday...)
 - CUE support
 - equalizer
 - tags editing
 - advanced foobar2000-level customization (i'm too dumb for that, sorry)

## Enabling lyrics loading
This should be changed in the future but for now in order for this to work you need to install [python3 from homebrew](https://formulae.brew.sh/formula/python@3.9) with `brew install python@3.9` and then [lyricgenius module](https://pypi.org/project/lyricsgenius/) with `pip3 install lyricsgenius`. Test that this works in your terminal:  
`/usr/local/bin/python3 -m lyricsgenius -h`
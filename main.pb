EnableExplicit

Threaded _IsMainScope
_IsMainScope = #True

IncludeFile "const.pb"
IncludeFile "helpers.pb"
IncludeFile "../pb-macos-audioplayer/audioplayer.pbi"
IncludeFile "../pb-httprequest-manager/httprequest-manager.pbi"
IncludeFile "../pb-macos-task/task.pbi"
IncludeFile "../pb-macos-globalhotkeys/ghk.pbi"

;ImportC ""
;  sel_registerName(str.p-ascii)
;  class_addMethod(class, selector, imp, types.p-ascii)
;EndImport

Define app.i = CocoaMessage(0,0,"NSApplication sharedApplication")
Define settings.settings
NewList tagsToGet.track_info()
NewList playQueue.i()
Define ev.i
Define playlist.s,directory.s,file.s
NewList filesInDirectory.s()
NewList tagsParserThreads.i()
Define lyricsThread.i
Define webThread.i
Define i.i,j.i
Define skip.b
Define *elem.track_info
Define playlistString.s
Define nowPlaying.nowPlaying
Define dataDir.s = GetEnvironmentVariable("HOME") + "/Library/Application Support/" + #myName
Define myDir.s = GetPathPart(ProgramFilename()) + ".."
Define systemThreads.l = CountCPUs(#PB_System_ProcessCPUs)
If systemThreads > 4 : systemThreads = 4 : EndIf ; more than enough
Define numThreads.b
Define tagsToGetLock.i = CreateMutex()
Define lastfmToken.s,lastfmSession.s,lastfmUser.s
Define lastfmTokenResponse.s,lastfmSessionResponse.s
Define appDelegate.i = CocoaMessage(0,app,"delegate")
Define delegateClass.i = CocoaMessage(0,appDelegate,"class")
Define lastPlayedID.i
Define nextID.i
Define preloadID.i = -1
Define currentAP.l
Define preloadAP.l
Define ffprobe.s = myDir + "/Tools/ffprobe-ichm"
Define geniusAvailable.b
Define dropCount.i
Define *response.HTTPRequestManager::response
Define responseResult.s
Define lastHTTPRequestManagerProcess.i
Define seekbarSelect.d
Define volume.f

; web server stuff
Define webPort.l
Define webStop.b
Define webProcessed.b
Define webNowPlaying.nowPlaying
Define lastBindTry.i = ElapsedMilliseconds() - 5000

; nowplaying update stuff
Define currentTimeSec.i
Define durationSec.i
Define oldCurrent.i
Define newCurrent.i
Define lastDurationUpdate.i
Define currentAlbum.s
Define numAlbums.i

; playback stuff
Define cursorFollowsPlayback.b
Define playbackFollowsCursor.b
Define playbackOrder.b
Define stopAtQueueEnd.b
Define queueEnded.b
NewList history.i()
Define historyEnabled.b

; search stuff
Define search.s
Define searchArtist.s,searchArtistL.s
Define searchTitle.s,searchTitleL.s
Define hideAfter.b

Global EXIT = #False

UseMD5Fingerprint()
UsePNGImageDecoder()
UseJPEGImageDecoder()
UseJPEGImageEncoder()
UseZipPacker()
HTTPRequestManager::init(1,30000,#myUserAgent,0,#True)
globalHK::init()
audioplayer::setffmpegPath(myDir + "/Tools/ffmpeg-ichm")
audioplayer::setFFmpegTempDirPath(dataDir + "/tmp")
audioplayer::addFFmpegFormat("flac")
audioplayer::addFFmpegFormat("oga")
audioplayer::addFFmpegFormat("ogg")
audioplayer::addFFmpegFormat("wv")
audioplayer::addFFmpegFormat("ape")
InitCGI()
ExamineDesktops()

If FileSize(dataDir) <> -2 : CreateDirectory(dataDir) : EndIf
If FileSize(dataDir + "/lyrics") <> -2 : CreateDirectory(dataDir + "/lyrics") : EndIf
If FileSize(dataDir + "/tmp") <> -2
  CreateDirectory(dataDir + "/tmp")
Else
  DeleteDirectory(dataDir + "/tmp","*.*",#PB_FileSystem_Recursive|#PB_FileSystem_Force)
  CreateDirectory(dataDir + "/tmp")
EndIf

IncludeFile "proc.pb"

geniusAvailable = canLoadLyrics()

IncludeFile "interface.pb"
debugLog("main","interface loaded")

class_addMethod_(delegateClass,sel_registerName_("applicationDockMenu:"),@dockMenuHandler(),"v@:@")
CocoaMessage(0,app,"setDelegate:",appDelegate)
;class_addMethod_(delegateClass,sel_registerName_("tableView:isGroupRow:"),@IsGroupRow(),"v@:@@")
class_addMethod_(delegateClass,sel_registerName_("tableView:willDisplayCell:forTableColumn:row:"),@CellDisplayCallback(),"v@:@@@@")
CocoaMessage(0,GadgetID(#playlist),"setDelegate:",appDelegate)
debugLog("main","handlers registered")

loadSettings()
sizeGadgets()
loadState()
updateLastfmStatus()
;loadSettings() ; temporary hack to redraw the playlist
setAlbums()
SetGadgetState(#playlist,settings\last_played_track_id)
SetActiveGadget(#playlist)

AddKeyboardShortcut(#wnd,#PB_Shortcut_Space,#playlistQueue)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Return|#PB_Shortcut_Shift,#playlistQueue)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Return,#playlistPlay)
AddKeyboardShortcut(#wnd,#PB_Shortcut_K,#playlistUp)
AddKeyboardShortcut(#wnd,#PB_Shortcut_J,#playlistDown)
AddKeyboardShortcut(#wnd,#PB_Shortcut_H,#playlistPrevious)
AddKeyboardShortcut(#wnd,#PB_Shortcut_L,#playlistNext)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Up,#playlistUp)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Down,#playlistDown)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Left,#playlistPrevious)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Right,#playlistNext)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Up|#PB_Shortcut_Shift,#playlistShiftUp)
AddKeyboardShortcut(#wnd,#PB_Shortcut_Down|#PB_Shortcut_Shift,#playlistShiftDown)
AddKeyboardShortcut(#wnd,#PB_Shortcut_K|#PB_Shortcut_Shift,#playlistShiftUp)
AddKeyboardShortcut(#wnd,#PB_Shortcut_J|#PB_Shortcut_Shift,#playlistShiftDown)


EnableGadgetDrop(#playlist,#PB_Drop_Files,#PB_Drag_Copy|#PB_Drag_Move|#PB_Drag_Link)

BindEvent(#evPlayFinish,@playFinishHandler())

MenuItem(#PB_Menu_Preferences,"")
MenuItem(#PB_Menu_About,"")

nowPlaying\ID = -1
debugLog("main","ready to play")

Repeat
  ev = WaitWindowEvent(#defaultTimeout)
  ;Debug "event"
  
  ; event processing
  Select ev
      
    Case #PB_Event_LeftClick
      If EventWindow() = #wnd
        seekbarSelect = getProgressBarPosition(#wnd,#nowPlayingProgress,5,5)
        If seekbarSelect <> -1 And nowPlaying\ID <> -1
          seekbarSelect = seekbarSelect*(nowPlaying\durationSec/100)
          If seekbarSelect > nowPlaying\durationSec : seekbarSelect = durationSec : EndIf
          nowPlaying\currentTime = audioplayer::setCurrentTime(currentAP,seekbarSelect)
          PostEvent(#evUpdateNowPlaying,#wnd,0,nowPlaying\currentTime,nowPlaying\durationSec)
        EndIf
      EndIf
      
    Case #PB_Event_CloseWindow
      Select EventWindow()
        Case #wnd
          Break
        Case #wndPrefs
          flushSettings()
      EndSelect
      RemoveKeyboardShortcut(EventWindow(),#PB_Shortcut_All)
      CloseWindow(EventWindow())
      If EventWindow() = #wndFind And hideAfter = #True
        hideAfter = #False
        CocoaMessage(0,app,"hide:")
      EndIf
      
      
    ; timer events
    Case #PB_Event_Timer
      Select EventTimer()
        Case #timerSaveState
          RemoveWindowTimer(#wnd,#timerSaveState)
          debugLog("timer","saving state")
          saveState()
      EndSelect
      
    ; menu events
    Case #PB_Event_Menu
      Select EventMenu()
        Case #openPlaylist
          If CountGadgetItems(#playlist) = 0 Or 
             (CountGadgetItems(#playlist) And MessageRequester(#myName,"Your current playlist will be cleared, are you sure you want to continue?",#PB_MessageRequester_YesNo|#PB_MessageRequester_Warning) = #PB_MessageRequester_Yes)
            playlist = OpenFileRequester("Select playlist","","",0)
            If FileSize(playlist) > 0 And ReadFile(0,playlist)
              cleanUp()
              i = 0
              CocoaMessage(0,GadgetID(#playlist),"beginUpdates")
              While Eof(0) = 0
                playlistString = ReadString(0)
                If Left(playlistString,1) = "#" Or Len(playlistString) < 2
                  Continue
                EndIf
                If audioplayer::isSupportedFile(playlistString) And FileSize(playlistString) > 0
                  AddElement(tagsToGet())
                  tagsToGet()\id = i
                  tagsToGet()\path = playlistString
                  AddGadgetItem(#playlist,-1,#processingSymbol + #sep + tagsToGet()\path)
                  i + 1
                EndIf
              Wend
              CocoaMessage(0,GadgetID(#playlist),"endUpdates")
              CloseFile(0)
              doTags()
            Else
              MessageRequester(#myName,"Can't open file " + playlist,#PB_MessageRequester_Error)
            EndIf
          EndIf
        Case #savePlaylist
          playlist = SaveFileRequester("Save playlist","main.m3u8","",0)
          If playlist
            playlistString = ~"#EXTM3U\n"
            For i = 0 To CountGadgetItems(#playlist)-1
              If Not GetGadgetItemData(#playlist,i)
                playlistString + ~"\n" + GetGadgetItemText(#playlist,i,#file)
              EndIf
            Next
            If Not WriteFileFast(playlist,playlistString)
              MessageRequester(#myName,"Failed to save current playlist to " + playlist,#PB_MessageRequester_Error)
            EndIf
          EndIf
        Case #addDirectory
          If isParsingCompleted()
            directory = PathRequester("Select directory","")
            If FileSize(directory) = -2
              ClearList(filesInDirectory())
              RecursiveDirectorySafe(directory,filesInDirectory())
              If ListSize(filesInDirectory())
                SortList(filesInDirectory(),#PB_Sort_Ascending|#PB_Sort_NoCase)
                i = CountGadgetItems(#playlist)
                CocoaMessage(0,GadgetID(#playlist),"beginUpdates")
                ForEach filesInDirectory()
                  If audioplayer::isSupportedFile(filesInDirectory())
                    AddElement(tagsToGet())
                    tagsToGet()\id = i
                    tagsToGet()\path = filesInDirectory()
                    AddGadgetItem(#playlist,-1,#processingSymbol + #sep + filesInDirectory())
                    i + 1
                  EndIf
                Next
                CocoaMessage(0,GadgetID(#playlist),"endUpdates")
                doTags()
              EndIf
            EndIf
          Else
            MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
          EndIf
        Case #addFile
          If isParsingCompleted()
            file = OpenFileRequester("Select file(s)","","",0,#PB_Requester_MultiSelection)
            i = CountGadgetItems(#playlist)
            While file
              If audioplayer::isSupportedFile(file)
                AddElement(tagsToGet())
                tagsToGet()\id = i
                tagsToGet()\path = file
                AddGadgetItem(#playlist,-1,#processingSymbol + #sep + file)
                i + 1
              EndIf
              file = NextSelectedFileName()
            Wend
            doTags()
          Else
            MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
          EndIf
        Case #playlistPlay
          PostEvent(#PB_Event_Gadget,#wnd,#playlist,#PB_EventType_LeftDoubleClick)
        Case #playlistQueue
          If isQueued(GetGadgetState(#playlist))
            queueRemove(GetGadgetState(#playlist))
          Else
            queueAdd(GetGadgetState(#playlist))
          EndIf
        Case #playlistFinder
          If GetGadgetState(#playlist) <> -1
            If GetGadgetItemData(#playlist,GetGadgetState(#playlist))
              RunProgram("open",~"-R \"" + GetPathPart(GetGadgetItemText(#playlist,GetGadgetState(#playlist)+1,#file)) + ~"\"","")
            Else
              RunProgram("open",~"-R \"" + GetGadgetItemText(#playlist,GetGadgetState(#playlist),#file) + ~"\"","")
            EndIf
          EndIf
        Case #playlistDontGroupByAlbums
          If GetMenuItemState(#menu,#playlistDontGroupByAlbums)
            SetMenuItemState(#menu,#playlistDontGroupByAlbums,#False)
            settings\playlist\dont_group_by_albums = #False
          Else
            SetMenuItemState(#menu,#playlistDontGroupByAlbums,#True)
            settings\playlist\dont_group_by_albums = #True
          EndIf
          saveSettings()
          queueClear()
          setAlbums()
        Case #playlistReloadTags
          If isParsingCompleted()
            If GetGadgetItemData(#playlist,GetGadgetState(#playlist))
              Define albumToTagReload.s = GetGadgetItemText(#playlist,GetGadgetState(#playlist),#album)
              For i = GetGadgetState(#playlist) + 1 To CountGadgetItems(#playlist)-1
                If GetGadgetItemText(#playlist,i,#album) <> albumToTagReload
                  Break
                EndIf
                SetGadgetItemText(#playlist,i,#processingSymbol,#status)
                AddElement(tagsToGet())
                tagsToGet()\id = i
                tagsToGet()\path = GetGadgetItemText(#playlist,i,#file)
              Next
            Else
              SetGadgetItemText(#playlist,GetGadgetState(#playlist),#processingSymbol,#status)
              AddElement(tagsToGet())
              tagsToGet()\id = GetGadgetState(#playlist)
              tagsToGet()\path = GetGadgetItemText(#playlist,GetGadgetState(#playlist),#file)
            EndIf
            doTags()
          Else
            MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
          EndIf
        Case #playlistRemove
          If GetGadgetItemData(#playlist,GetGadgetState(#playlist))
            Define albumToRemove.s = GetGadgetItemText(#playlist,GetGadgetState(#playlist),#album)
            For i = GetGadgetState(#playlist) To CountGadgetItems(#playlist)-1
              If GetGadgetItemText(#playlist,i,#album) <> albumToRemove
                Break
              EndIf
              RemoveGadgetItem(#playlist,i)
              i - 1 ; because we removed an item and the next one is having the same id now
            Next
          Else
            RemoveGadgetItem(#playlist,GetGadgetState(#playlist))
          EndIf
          setAlbums()
          saveState()
        Case #playlistShiftUp
          playlistMove(#moveUp)
          RemoveWindowTimer(#wnd,#timerSaveState)
          AddWindowTimer(#wnd,#timerSaveState,2000)
        Case #playlistShiftDown
          playlistMove(#moveDown)
          RemoveWindowTimer(#wnd,#timerSaveState)
          AddWindowTimer(#wnd,#timerSaveState,2000)
        Case #playlistFind
          If Not IsWindow(#wndFind)
            action()
          Else
            SetActiveWindow(#wndFind)
            SetActiveGadget(#actionSearch)
          EndIf
          If Not CocoaMessage(0,app,"isActive")
            CocoaMessage(0,app,"activateIgnoringOtherApps:",#YES)
            hideAfter = #True
          EndIf
        Case #playbackCursorFollowsPlayback
          cursorFollowsPlayback = 1-cursorFollowsPlayback
          SetMenuItemState(#menu,#playbackCursorFollowsPlayback,cursorFollowsPlayback)
          saveSettings()
        Case #playbackPlaybackFollowsCursor
          playbackFollowsCursor = 1-playbackFollowsCursor
          SetMenuItemState(#menu,#playbackPlaybackFollowsCursor,playbackFollowsCursor)
          saveSettings()
        Case #playbackStopAtQueueEnd
          stopAtQueueEnd = 1-stopAtQueueEnd
          SetMenuItemState(#menu,#playbackStopAtQueueEnd,stopAtQueueEnd)
          saveSettings()
        Case #playbackOrderDefault
          SetMenuItemState(#menu,#playbackOrderDefault,#True)
          SetMenuItemState(#menu,#playbackOrderShuffleTracks,#False)
          SetMenuItemState(#menu,#playbackOrderShuffleAlbums,#False)
          playbackOrder = #orderDefault
          saveSettings()
        Case #playbackOrderShuffleTracks
          SetMenuItemState(#menu,#playbackOrderDefault,#False)
          SetMenuItemState(#menu,#playbackOrderShuffleTracks,#True)
          SetMenuItemState(#menu,#playbackOrderShuffleAlbums,#False)
          playbackOrder = #orderShuffleTracks
          saveSettings()
        Case #playbackOrderShuffleAlbums
          SetMenuItemState(#menu,#playbackOrderDefault,#False)
          SetMenuItemState(#menu,#playbackOrderShuffleTracks,#False)
          SetMenuItemState(#menu,#playbackOrderShuffleAlbums,#True)
          playbackOrder = #orderShuffleAlbums
          saveSettings()
        Case #lastfmState
          If lastfmSession
            If MessageRequester(#myName,"Do you really want to log out of Last.fm? Scrobbling will be disabled.",#PB_MessageRequester_YesNo|#PB_MessageRequester_Warning) = #PB_MessageRequester_Yes
              lastfmSession = ""
              lastfmUser = ""
              saveSettings()
              updateLastfmStatus()
            EndIf
          Else
            If lastfmAuth(#getToken)
              MessageRequester(#myName,"You're going to be redirected to Last.fm in order to authorize " + #myName + " for scrobbling. Press OK to continue.")
              lastfmAuth(#openAuthLink)
              Delay(1000)
              MessageRequester(#myName,"Press OK again when you finished.")
              While Not lastfmAuth(#getSession)
                If MessageRequester(#myName,~"Failed getting session for Last.fm, want to try again?\n\n" + lastfmSessionResponse,#PB_MessageRequester_YesNo|#PB_MessageRequester_Error) = #PB_MessageRequester_No
                  Break
                EndIf
              Wend
              If lastfmSession And lastfmUser
                MessageRequester(#myName,"You are successfully logged in as " + lastfmUser,#PB_MessageRequester_Info)
                updateLastfmStatus()
              EndIf
              saveSettings()
            Else
              MessageRequester(#myName,~"Failed getting auth token for Last.fm, please try again later and if the problem persists, contact the developer.\n\n" + lastfmTokenResponse,#PB_MessageRequester_Error)
            EndIf
          EndIf
        Case #lastfmUser
          If lastfmUser
            RunProgram("open","https://www.last.fm/user/" + lastfmUser,"")
          EndIf
        Case #dockPlayPause
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarPlayPause)
        Case #dockStop
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarStop)
        Case #dockNext
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarNext)
        Case #dockNextAlbum
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarNextAlbum)
        Case #dockPrevious
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarPrevious)
        Case #dockPreviousAlbum
          PostEvent(#PB_Event_Gadget,#wnd,#toolbarPreviousAlbum)
        Case #actionUp
          SetGadgetState(#actionResults,GetGadgetState(#actionResults)-1)
        Case #actionDown
          SetGadgetState(#actionResults,GetGadgetState(#actionResults)+1)
        Case #actionCancel
          PostEvent(#PB_Event_CloseWindow,#wndFind,0)
        Case #actionConfirm
          If GetGadgetState(#actionResults) <> -1
            SetGadgetState(#playlist,GetGadgetItemData(#actionResults,GetGadgetState(#actionResults)))
            PostEvent(#PB_Event_Gadget,#wnd,#playlist,#PB_EventType_LeftDoubleClick)
            PostEvent(#PB_Event_CloseWindow,#wndFind,0)
          EndIf
        Case #playlistUp
          SetActiveGadget(#playlist)
          SetGadgetState(#playlist,GetGadgetState(#playlist)-1)
        Case #playlistDown
          SetActiveGadget(#playlist)
          SetGadgetState(#playlist,GetGadgetState(#playlist)+1)
        Case #playlistNext
          SetActiveGadget(#playlist)
          If GetGadgetState(#playlist)+1 < CountGadgetItems(#playlist)
            For i = GetGadgetState(#playlist)+1 To CountGadgetItems(#playlist)-1
              If GetGadgetItemData(#playlist,i)
                SetGadgetState(#playlist,i+1)
                Break
              EndIf
            Next
          EndIf
        Case #playlistPrevious
          If GetGadgetState(#playlist)-1 >= 0
            For i = GetGadgetState(#playlist) To 0 Step -1
              If GetGadgetItemData(#playlist,i)
                For j = i-1 To 0 Step -1
                  If GetGadgetItemData(#playlist,j)
                    SetGadgetState(#playlist,j+1)
                    Break
                  EndIf
                Next
                Break
              EndIf
            Next
          EndIf
        Case #PB_Menu_Quit
          Break
        Case #PB_Menu_Preferences
          If Not IsWindow(#wndPrefs)
            prefs()
          Else
            SetActiveWindow(#wndPrefs)
          EndIf
        Case #PB_Menu_About
          MessageRequester(#myNameVer,#myAbout)
      EndSelect
      
    ; gadget events
    Case #PB_Event_Gadget
      Select EventGadget()
        Case #playlist
          Select EventType()
            Case #PB_EventType_LeftDoubleClick
              If GetGadgetState(#playlist) > -1
                If isParsingCompleted()
                  If GetGadgetItemData(#playlist,GetGadgetState(#playlist))
                    SetGadgetState(#playlist,GetGadgetState(#playlist) + 1)
                  EndIf
                  queueClear()
                  queueEnded = #False
                  nextID = GetGadgetState(#playlist)
                  currentAlbum = GetGadgetItemText(#playlist,nextID,#album)
                  historyEnabled = #True
                  If preloadAP
                    audioplayer::free(preloadAP)
                    preloadAP = 0
                  EndIf
                  doPlay()
                  saveSettings()
                Else
                  MessageRequester(#myName,"Please wait until current parsing is completed",#PB_MessageRequester_Error)
                EndIf
              EndIf
            Case #PB_EventType_RightClick
              If GetGadgetState(#playlist) <> -1
                If isQueued(GetGadgetState(#playlist))
                  SetMenuItemText(#playlistMenu,#playlistQueue,"Remove from queue" + Chr(9) + "␣")
                Else
                  SetMenuItemText(#playlistMenu,#playlistQueue,"Add to queue" + Chr(9) + "␣")
                EndIf
                DisplayPopupMenu(#playlistMenu,WindowID(#wnd))
              EndIf
          EndSelect
        Case #toolbarLyricsReloadWeb
          If geniusAvailable
            If IsThread(lyricsThread) : KillThread(lyricsThread) : EndIf
            HideGadget(#toolbarLyricsReloadWeb,#True)
            SetGadgetText(#lyrics,"[looking for lyrics...]")
            lyricsThread = CreateThread(@lyrics(),#True)
          EndIf
        Case #toolbarPlayPause
          If nowPlaying\ID = -1
            nextID = queueNext()
            If nextID > -1 And nextID < CountGadgetItems(#playlist)
              If cursorFollowsPlayback
                SetGadgetState(#playlist,nextID)
              EndIf
            EndIf
            If GetGadgetState(#playlist) > -1
              PostEvent(#PB_Event_Gadget,#wnd,#playlist,#PB_EventType_LeftDoubleClick)
            EndIf
          ElseIf audioplayer::getPlayerID(currentAP)
            If nowPlaying\isPaused
              nowPlaying\isPaused = #False
              audioplayer::play(currentAP)
              debugLog("playback","continued")
              SetGadgetText(#toolbarPlayPause,#pauseSymbol)
            Else
              nowPlaying\isPaused = #True
              audioplayer::pause(currentAP)
              debugLog("playback","paused")
              SetGadgetText(#toolbarPlayPause,#playSymbol)
            EndIf
          EndIf
        Case #toolbarStop
          If nowPlaying\ID <> -1
            doStop()
          EndIf
        Case #toolbarNext,#toolbarPrevious,#toolbarNextAlbum,#toolbarPreviousAlbum
          Select EventGadget()
            Case #toolbarNext
              debugLog("playback","next track")
              nextID = getNextTrack()
            Case #toolbarNextAlbum
              debugLog("playback","next album")
              queueClear() ; todo - make queue support for that
              nextID = getNextAlbum()
            Case #toolbarPrevious
              debugLog("playback","previous track")
              nextID = getPreviousTrack()
            Case #toolbarPreviousAlbum
              debugLog("playback","previous album")
              ClearList(history()) ; todo - make history support for that
              nextID = getPreviousAlbum()
          EndSelect
          If cursorFollowsPlayback
            SetGadgetState(#playlist,nextID)
          EndIf
          If nextID <> -1
            doPlay()
            saveSettings()
          Else
            doStop()
          EndIf
        Case #volume
          volume = GetGadgetState(#volume) / 100
          If audioplayer::getPlayerID(currentAP) And nowPlaying\ID <> -1
            audioplayer::setVolume(currentAP,volume)
          EndIf
          If preloadAP And audioplayer::getPlayerID(preloadAP)
            audioplayer::setVolume(preloadAP,volume)
          EndIf
          saveSettings()
          Debug "volume set to " + StrF(volume,2)
        Case #prefsShortcutEdit
          If GetGadgetText(#prefsShortcutEdit) = "Edit"
            SetGadgetText(#prefsShortcutEdit,"Apply")
            globalHK::remove("",0,#True)
            For i = #prefsShortcutToggle To #prefsShortcutFind Step 2
              DisableGadget(i,#False)
              CocoaMessage(0,GadgetID(i),"setTextColor:",0)
            Next
          Else
            SetGadgetText(#prefsShortcutEdit,"Edit")
            For i = #prefsShortcutToggle To #prefsShortcutFind Step 2
              DisableGadget(i,#True)
            Next
            settings\shortcuts\toggle_shortcut = GetGadgetText(#prefsShortcutToggle)
            settings\shortcuts\next_shortcut = GetGadgetText(#prefsShortcutNext)
            settings\shortcuts\previous_shortcut = GetGadgetText(#prefsShortcutPrevious)
            settings\shortcuts\find_shortcut = GetGadgetText(#prefsShortcutFind)
            flushSettings()
          EndIf
        Case #prefsWebEnable
          If GetGadgetState(#prefsWebEnable) = #PB_Checkbox_Checked
            If Val(GetGadgetText(#prefsWebPort)) < 1025 Or Val(GetGadgetText(#prefsWebPort)) > 65534
              MessageRequester(#myName,"Port number is incorrect. Please input a number between 1024 and 65535.",#PB_MessageRequester_Error)
              SetGadgetState(#prefsWebPort,8008)
              SetGadgetText(#prefsWebPort,"8008")
              SetGadgetState(#prefsWebEnable,#PB_Checkbox_Unchecked)
            EndIf
          EndIf
          flushSettings()
        Case #prefsWebLink
          RunProgram("open","http://0.0.0.0:" + Str(settings\web\web_server_port),"")
        Case #prefsUseTerminalNotifier,#prefsUseGenius
          flushSettings()
        Case #actionSearch
          If EventType() = #PB_EventType_Change
            Define search.s = GetGadgetText(#actionSearch)
            ClearGadgetItems(#actionResults)
            If Len(search) => 2
              j = 0
              search = LCaseEx(search)
              For i = 0 To CountGadgetItems(#playlist)-1
                If Not GetGadgetItemData(#playlist,i)
                  searchArtist = GetGadgetItemText(#playlist,i,#artist)
                  searchTitle = GetGadgetItemText(#playlist,i,#title)
                  searchArtistL = LCaseEx(searchArtist)
                  searchTitleL = LCaseEx(searchTitle)
                  If FindString(searchArtistL,search) Or FindString(searchTitleL,search)
                    AddGadgetItem(#actionResults,-1,searchArtist + " - " + searchTitle)
                    SetGadgetItemData(#actionResults,CountGadgetItems(#actionResults)-1,i)
                    j + 1
                    If j = 20
                      Break
                    EndIf
                  EndIf
                EndIf
              Next
              If j
                SetGadgetState(#actionResults,0)
              EndIf
            EndIf
          EndIf
      EndSelect
      
    ; drag'n'drop processing
    Case #PB_Event_GadgetDrop
      If EventGadget() = #playlist
        Select dropCount
          Case 0
            MessageRequester(#myName,"Ouch... Drag'n'Drop is not supported yet, please don't drop stuff on me!",#PB_MessageRequester_Warning)
          Case 1
            MessageRequester(#myName,"Stop dropping stuff on me!",#PB_MessageRequester_Warning)
          Case 2
            MessageRequester(#myName,"Dude please... It's not going to work.",#PB_MessageRequester_Warning)
          Case 3
            MessageRequester(#myName,"...",#PB_MessageRequester_Warning)
          Case 4
            MessageRequester(#myName,"You're still doing this in hopes to find something cool? There's nothing.",#PB_MessageRequester_Warning)
          Case 5,6,7
            MessageRequester(#myName,"TODO: write more funny answers for drag'n'drop operations",#PB_MessageRequester_Info)
          Case 8
            MessageRequester(#myName,"You really got nothing to do, don't you?",#PB_MessageRequester_Warning)
          Case 9
            MessageRequester(#myName,"Come on...",#PB_MessageRequester_Warning)
          Case 10 To 20
            MessageRequester(#myName,"Maybe you simply love wasting your time?",#PB_MessageRequester_Warning)
          Case 21
            MessageRequester(#myName,"Oh sure you do...",#PB_MessageRequester_Warning)
          Case 22
            MessageRequester(#myName,"Are you also waiting for a conclusion of some sort?",#PB_MessageRequester_Warning)
          Case 23
            MessageRequester(#myName,"How about a story?",#PB_MessageRequester_Info)
          Case 24
            MessageRequester("🤬","I AM A FUCKING AUDIO PLAYER I DON'T TELL STORIES",#PB_MessageRequester_Error)
          Case 25
            MessageRequester("😡","")
          Case 26
            MessageRequester("😑","You know what... I'll just quit.")
          Case 27
            MessageRequester("😔","No, seriously, you do whatever you like, i'm out!")
          Case 28
            MessageRequester("👋","Bye.")
            RunProgram("open","https://www.youtube.com/watch?v=cr6eFl7hCiA","")
            Break
        EndSelect
        dropCount + 1
      EndIf
      
    ; window events
    Case #PB_Event_SizeWindow
      If EventWindow() = #wnd
        sizeGadgets()
        saveSettings()
      EndIf
    Case #PB_Event_MoveWindow
      If EventWindow() = #wnd
        saveSettings()
      EndIf
      
    ; custom events
    Case #evTagGetSuccess
      *elem = EventData()
      With *elem
        If CountString(\tags\track,"/")
          \tags\track = StringField(\tags\track,1,"/")
        EndIf
        \tags\track = LTrim(\tags\track,"0")
        SetGadgetItemText(#playlist,\id,#sep + 
                                        \path + #sep + 
                                        \tags\track + #sep +
                                        \tags\artist + #sep + 
                                        \tags\title + #sep + 
                                        \duration + #sep +
                                        \tags\album + #sep + 
                                        UCase(\format) + " " + Str(\bitrate/1000) + "k")
        ;debugLog("main","incoming tag for " + \path)
      EndWith
    Case #evTagGetFail
      *elem = EventData()
      SetGadgetItemText(#playlist,*elem\id,"Unknown Artist",#artist)
      SetGadgetItemText(#playlist,*elem\id,"Unknown Title",#title)
      SetGadgetItemText(#playlist,*elem\id,"Unknown Album",#album)
    Case #evTagGetFinish
      If isParsingCompleted(#False)
        If ListSize(tagsParserThreads())
          ClearList(tagsParserThreads())
          CreateThread(@DelayEvent(),#evTagGetSaveState)
        EndIf
      EndIf
    Case #evTagGetSaveState
      setAlbums()
      saveState()
      ClearList(tagsToGet())
    Case #evPlayStart
      If lastfmSession
        debugLog("lastfm","updating nowplaying " + Str(nowPlaying\ID))
        lastfmUpdateNowPlaying()
        playbackNotification()
      EndIf
    Case #evLyricsFail
      SetGadgetText(#lyrics,"[no lyrics found]")
      HideGadget(#toolbarLyricsReloadWeb,#False)
    Case #evLyricsSuccessGenius,#evLyricsSuccessFile
      SetGadgetText(#lyrics,nowPlaying\lyrics)
      HideGadget(#toolbarLyricsReloadWeb,#False)
      If ev = #evLyricsSuccessFile
        debugLog("lyrics","successfully loaded from file")
      Else
        debugLog("lyrics","successfully loaded from Genius")
      EndIf
    Case #evNowPlayingRequestFinished,#evScrobbleRequestFinished
      *response = HTTPRequestManager::getResponse(EventData())
      If *response
        responseResult = HTTPRequestManager::getComment(EventData())
        Select HTTPRequestManager::getStatus(EventData())
          Case HTTPRequestManager::#TimedOut
            responseResult + " timed out"
          Case HTTPRequestManager::#Failed
            responseResult + " failed with error: " + *response\error
          Case HTTPRequestManager::#Success
            If *response\statusCode = 200
              If ev = #evNowPlayingRequestFinished
                responseResult + " was successfull"
              ElseIf ev = #evScrobbleRequestFinished
                If FindString(*response\text,~"\"accepted\":1")
                  responseResult + " was successfull"
                ElseIf FindString(*response\text,~"\"ignored\":1")
                  responseResult + " was ignored"
                Else
                  responseResult + " failed with http code " + Str(*response\statusCode) + ": " + *response\text
                EndIf
              EndIf
            Else
              responseResult + " failed with http code " + Str(*response\statusCode) + ": " + *response\text
            EndIf
        EndSelect
        debugLog("lastfm",responseResult)
      Else
        debugLog("lastfm","got answer for " + Str(EventData()) + " with no response")
      EndIf
    Case #evUpdateNowPlaying
      updateNowPlaying(EventType(),EventData())
    Case #evWebUpdateNowPlaying
      CopyStructure(@nowPlaying,@webNowPlaying,nowPlaying)
      webProcessed = #True
    Case #evWebGetAlbumArt
      ; to make sure that at least one event was processed
      webProcessed = #True
    Case #evWebStarted
      debugLog("web","web server started on port " + Str(settings\web\web_server_port))
      If IsWindow(#wndPrefs)
        HideGadget(#prefsWebLink,#False)
        SetGadgetText(#prefsWebLink,"running on port " + Str(settings\web\web_server_port))
      EndIf
    Case #evWebStopped
      If IsWindow(#wndPrefs) : HideGadget(#prefsWebLink,#True) : EndIf
      debugLog("web","web server stopped")
    Case #evWebSleep
      debugLog("web","switching to longer delays due to inactivity")
    Case #evWebRequest
      debugLog("web","new request " + Str(EventGadget()) + " from " + IPString(EventType()) + ":" + Str(EventData()))
  EndSelect
  
  ; audioplayer routine
  If audioplayer::getPlayerID(currentAP) And nowPlaying\ID <> -1 And nowPlaying\isPaused = #False
    If lastDurationUpdate + 900 <= ElapsedMilliseconds()
      lastDurationUpdate = ElapsedMilliseconds()
      newCurrent = audioplayer::getCurrentTime(currentAP)
      If oldCurrent <> newCurrent
        oldCurrent = newCurrent
        If nowPlaying\durationSec - newCurrent <= 5 And preloadAP = 0 And preloadID = -1 And playbackOrder <> #playbackOrderShuffleTracks
          preloadID = getNextTrack(#True)
          If preloadID <> -1
            preloadAP = audioplayer::load(#PB_Any,GetGadgetItemText(#playlist,preloadID,#file))
            audioplayer::setVolume(preloadAP,volume)
            audioplayer::setPlayNext(preloadAP)
            debugLog("playback","preloaded " + audioplayer::getPath(preloadAP))
          EndIf
        EndIf
        PostEvent(#evUpdateNowPlaying,#wnd,0,newCurrent,nowPlaying\durationSec)
      EndIf
    EndIf
  EndIf
  
  ; HTTPRequestManager routine
  If lastHTTPRequestManagerProcess + 900 <= ElapsedMilliseconds()
    HTTPRequestManager::process()
    lastHTTPRequestManagerProcess = ElapsedMilliseconds()
  EndIf
  
  ; web server startup routine
  If settings\web\use_web_server
    If Not IsThread(webThread) And ElapsedMilliseconds() - lastBindTry >= 3000
      lastBindTry = ElapsedMilliseconds()
      debugLog("web","checking port " + Str(settings\web\web_server_port))
      If isPortAvailable(settings\web\web_server_port)
        debugLog("web","starting web server")
        webStop = #False
        webThread = CreateThread(@webHandler(),settings\web\web_server_port)
      Else
        debugLog("web","port is busy")
        If IsWindow(#wndPrefs)
          HideGadget(#prefsWebLink,#True)
        EndIf
      EndIf  
    EndIf
  Else
    If IsThread(webThread)
      debugLog("web","stopping web server")
      webStop = #True
      WaitThread(webThread)
    EndIf
  EndIf
  
ForEver

saveSettings()
die()
debugLog("main","exiting")
EnableExplicit

IncludeFile "const.pb"

NewList tagsToGet.track_info()
Define ev.i
Define playlist.s
Define playThread.i,playPID.i
NewList tagsParserThreads.i()
Define lyricsThread.i
Define i.i,j.i
Define *elem.track_info
Define playlistString.s
Define nowPlayingID.i = -1
Define nowPlayingPath.s
Define nowPlayingAlbumArt.s
Define nowPlayingArtist.s
Define nowPlayingTitle.s
Define nowPlayingLyrics.s
Define dataDir.s = GetEnvironmentVariable("HOME") + "/Library/Application Support/" + #myName
Define numThreads.l = CountCPUs(#PB_System_ProcessCPUs)
If numThreads > 4 : numThreads = 4 : EndIf ; more than enough
Define tagsToGetLock.i = CreateMutex()

UseMD5Fingerprint()
UsePNGImageDecoder()
UseJPEGImageDecoder()

If FileSize(dataDir) <> -2 : CreateDirectory(dataDir) : EndIf
If FileSize(dataDir + "/lyrics") <> -2 : CreateDirectory(dataDir + "/lyrics") : EndIf
If FileSize(dataDir + "/tmp") <> -2
  CreateDirectory(dataDir + "/tmp")
Else
  DeleteDirectory(dataDir + "/tmp","*.*",#PB_FileSystem_Recursive|#PB_FileSystem_Force)
  CreateDirectory(dataDir + "/tmp")
EndIf

IncludeFile "proc.pb"

ExamineDesktops()
OpenWindow(#wnd,0,0,DesktopWidth(0),DesktopHeight(0),#myName,#PB_Window_SizeGadget|#PB_Window_SizeGadget|#PB_Window_SystemMenu)
WindowBounds(#wnd,800,720,#PB_Ignore,#PB_Ignore)

CreateMenu(#menu,WindowID(#wnd))
MenuTitle("File")
MenuItem(#openPlaylist,"Open Playlist")

ListIconGadget(#playlist,0,0,WindowWidth(#wnd)-500,WindowHeight(#wnd),"",20)
AddGadgetColumn(#playlist,#file,"File",200)
AddGadgetColumn(#playlist,#track,"#",30)
AddGadgetColumn(#playlist,#artist,"Artist",300)
AddGadgetColumn(#playlist,#title,"Title",300)
AddGadgetColumn(#playlist,#duration,"Duration",65)
AddGadgetColumn(#playlist,#album,"Album",250)
AddGadgetColumn(#playlist,#details,"Details",150)

CreateImage(#defaultAlbumArt,500,500)
StartDrawing(ImageOutput(#defaultAlbumArt))
Box(0,0,500,500,0)
DrawText(500/2-TextWidth("[no album art]")/2,500/2-TextHeight("[no album art]")/2,"[no album art]",$CCCCCC,0)
StopDrawing()
ImageGadget(#albumArt,WindowWidth(#wnd)-500,0,500,500,ImageID(#defaultAlbumArt))

EditorGadget(#lyrics,WindowWidth(#wnd)-500,500,500,WindowHeight(#wnd)-500,#PB_Editor_ReadOnly|#PB_Editor_WordWrap)

loadState()

Repeat
  ev = WaitWindowEvent()
  Select ev
    Case #PB_Event_CloseWindow
      Break
    Case #PB_Event_Menu
      Select EventMenu()
        Case #openPlaylist
          If CountGadgetItems(#playlist) = 0 Or (CountGadgetItems(#playlist) And MessageRequester(#myName,"Your current playlist will be cleared, are sure you want to continue?",#PB_MessageRequester_YesNo|#PB_MessageRequester_Warning) = #PB_MessageRequester_Yes)
            playlist = OpenFileRequester("Select playlist","","",0)
            If FileSize(playlist) > 0 And ReadFile(0,playlist)
              cleanUp()
              i = 0
              While Eof(0) = 0
                playlistString = ReadString(0)
                If Left(playlistString,1) = "#"
                  Continue
                EndIf
                AddElement(tagsToGet())
                tagsToGet()\id = i
                tagsToGet()\path = playlistString
                AddGadgetItem(#playlist,-1,#sep + tagsToGet()\path)
                i + 1
              Wend
              CloseFile(0)
              For j = 0 To numThreads - 1
                AddElement(tagsParserThreads())
                tagsParserThreads() = CreateThread(@getTags(),j)
                ;Debug CocoaMessage(0,ThreadID(tagsParserThreads()),"isExecuting")
                ;ThreadPriority(tagsParserThreads(),1)
              Next
            Else
              MessageRequester(#myName,"Can't open file " + playlist,#PB_MessageRequester_Error)
            EndIf
          EndIf
      EndSelect
    Case #PB_Event_Gadget
      Select EventGadget()
        Case #playlist
          If EventType() = #PB_EventType_LeftDoubleClick
            If GetGadgetState(#playlist) > -1
              doPlay()
            EndIf
          EndIf
      EndSelect
    Case #PB_Event_SizeWindow
      ResizeGadget(#playlist,#PB_Ignore,#PB_Ignore,WindowWidth(#wnd)-500,WindowHeight(#wnd))
      ResizeGadget(#albumArt,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,#PB_Ignore)
      ResizeGadget(#lyrics,WindowWidth(#wnd)-500,#PB_Ignore,#PB_Ignore,WindowHeight(#wnd)-500)
    Case #evTagGetSuccess
      *elem = EventData()
      With *elem
        SetGadgetItemText(#playlist,\id,#sep + 
                                        \path + #sep + 
                                        \tags\track + #sep +
                                        \tags\artist + #sep + 
                                        \tags\title + #sep + 
                                        \duration + #sep +
                                        \tags\album + #sep + 
                                        UCase(\format) + " " + Str(\bitrate/1000) + "k")
      EndWith
    Case #evTagGetFail
      *elem = EventData()
      SetGadgetItemText(#playlist,*elem\id,"[failed to get artist]",#artist)
      SetGadgetItemText(#playlist,*elem\id,"[failed to get title]",#title)
    Case #evTagGetFinish
      saveState()
    Case #evPlayFinish
      If nowPlayingID < CountGadgetItems(#playlist) - 1
        SetGadgetState(#playlist,nowPlayingID + 1)
        doPlay()
      Else
        doStop()
        SetGadgetState(#playlist,-1)
      EndIf
    Case #evLyricsFail
      SetGadgetText(#lyrics,"[no lyrics found]")
    Case #evLyricsSuccess
      SetGadgetText(#lyrics,nowPlayingLyrics)
  EndSelect
ForEver

cleanUp()

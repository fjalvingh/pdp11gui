unit AppControlU; 

{
 Appcontrol:
 Steuerung einer fremden Applikation mit Maus und Tastatur.
 Für SCripting.

 Es gibt nur eine globale Instanz von der Klasse: AppControl,
 sie wird gleich hier erzeugt.
}

interface 

uses 
  Windows, 
  Messages, 
  Classes ; 

type 

  // wird von Scripting benutzt
  TAppControl = class(TPersistent) 
    private 
      // Info über den letzten erzeugten Tastendruck
      lastvkey: integer ; 
      lastvkey_down: boolean ; 
      // ProcessID und imagefilename der Application
      procedure GetProcessInfo ; 


      function GetProcessHandle: THandle; 

      // macht eine Pause in Abh. von lastvkey, lastvkey_down, lastvkey_ticks
      // Simuliert die Bewegungen der menschlichen Hände üner der Tastatur
      procedure humanTypingDelay(vkey: integer ; down:boolean) ; 

      class procedure getChildControlAtPoint(aWindowHandle: HWND ; main_x, main_y: integer; 
              var aChildWindowHandle: HWND; var child_x, child_y: integer) ; 

    public 
      AppMainWindowHandle: THandle ; // Handle der Zielapplikation, muss vor allem anderen gesetzt werden.
      AppWindowHandle: THandle ; // Zielfenster für Mouse, Keys, etc.

      // Processinformation  
      ProcessHandle: THandle ; // ProcessHandle
      ProcessID: dword ; 
      imagefilename: string ; // Name der Exedatei

      humanTypingSpeedfactor: double ; // Tempokorrektur für humanTypingDelay
      humanJitterPercent : double ; // alle menschen-ähnlichen Aktionen mit soviel Zufallsbewegung

      constructor Create ; 
      destructor Destroy ; override ; 

      function FindWindowByTitleOrClassname(aWindowTitle,aWindowClassname:string) : THandle; 

      // zu allererst: MainWindow finden!
      function ConnectToMainWindowByTitleOrClassname(aWindowTitle,aWindowClassname:string) : boolean ; 
      // Finde das Window mit dem angegebenen Titel, setzte AppWindowHandle
      function ConnectToWindowByTitleOrClassname(aWindowTitle,aWindowClassname:string) : boolean ; 
      function ApplicationContact: boolean ; // false, wenn Applikation nicht (mehr) da
      function ApplicationPath: string ; // false, wenn Appliataion nicht (mehr) da
      procedure ApplicationTerminate ; 

      procedure StartApplication(imagefilename,args,workingdir:string) ; // danach MainWindowHandle nicht verändert.
      procedure ShowApplication ; // Auf normale Grösse bringen, in den Vordergrund

      class function isValidWindowHandle(aHandle: HWND): boolean ; 
      class function getParentWindowPoint(aPoint: TPoint ; aChildWindowHandle: HWND ; 
              aParentWindowHandle: THandle): TPoint ; 

      // Sichtbar in Scripting

      // Mausklick an x,y. Zeiger wird nicht bewegt
      procedure MouseClick(x, y:integer ; leftbutton:boolean) ; 
      // Mauszeiger setzen, .... just for show!
      procedure MouseMove(x, y:integer) ; 

      procedure humanMouseMove(x, y:integer; totaltime: integer) ; 
      // click auf x,y , aber eine Spur aus MouseMoves verursachen
      procedure humanMouseClick(x, y:integer; leftbutton: boolean; totaltime: integer) ; 

      // Texteingabe+Tastendrücke. Sehr hardwarenah.
      procedure KeyDown(aKeyname:string) ; 
      procedure KeyUp(aKeyname:string) ; 
      procedure EnterText(s:string) ; 

      procedure setWindowSize(newwidth, newheight: integer) ; 
      procedure setWindowPosition(newLeft, newTop: integer) ; 

    end { "TYPE TAppControl = class(TPersistent)" } ; 


implementation 

uses 
  SysUtils, 
  PsApi, 
  ShellApi 
  ; 


type 
  TKeyInfo = record 
      name:string ; 
      vk: integer ; 
      x: integer ; // Tasten sind 3 breit. x <= 0 : linke Hand
      y: integer ;  // Tastenreihen sind 4 Hoch. Spacebar = 0, F-keys=24
      info: string ; 
    end ; 

const 
  // Tastenkoordinaten für deutsches QUERTZ
  // Für amerikanisch folgende Umrechnung verwencen:
  // Deutsche Tastenposition  amerikanischer Tastenaufdruck, VK
  //  ---  ------ ----        ---  ------  ----
  //  Y                       Z
  //  Z                       Y
  // ^°   OEM_5  (DC)         ~-  OEM_3     (C0)
  // ?ß\  OEM_4  (DB)         _-  OEM_MINUS (BD)
  // ´`   OEM_6  (DD)         +=  OEM_PLUS  (BB)
  // Ü    OEM_1  (BA)         [{  OEM_4     (DB)
  // +*~  OEM_PLUS (BB)       ]}  OEM_6     (DD)
  //  neben +*~               \|  OEM_5     (DC)
  // Ö    OEM_3  (C0)         ;:  OEM_1     (BA)
  // Ä    OEM_7  (DE)         '"  OEM_7     (DE)
  // #'   OEM_2  (BF)            -
  // <>|  OEM_102 (E2)           -
  // ,;   OEM_COMMA (BC)      ,<  OEM_COMMA (BC)
  // .:   OEM_PERIOD (BE)     .>  OEM_PERIOD (BE)
  // -_    OEM_MINUS (BD)     /?  OEM_2     (BF)
  VK_OEM_1      = $BA ; 
  VK_OEM_PLUS   = $BB ; 
  VK_OEM_COMMA  = $BC ; 
  VK_OEM_MINUS  = $BD ; 
  VK_OEM_PERIOD = $BE ; 
  VK_OEM_2      = $BF ; 
  VK_OEM_3      = $C0 ; 
  VK_OEM_4      = $DB ; 
  VK_OEM_5      = $DC ; 
  VK_OEM_6      = $DD ; 
  VK_OEM_7      = $DE ; 
  VK_OEM_102    = $E2 ; 

  KeyInfoTableLen = 151 ; 

  // Hauptfeld ist x = -20..24; y = 0..16
  KeyInfo: array[0..KeyInfoTableLen-1] of TKeyInfo = ( 
    (name:'LBUTTON';    vk:VK_LBUTTON ;    x:  0; y:  0; info:'Left mouse button'), 
    (name:'RBUTTON';    vk:VK_RBUTTON ;    x:  0; y:  0; info:'Right mouse button'), 
    (name:'CANCEL';     vk:VK_CANCEL ;     x:  0; y:  0; info:'Control-break processing'), 
    (name:'MBUTTON';    vk:VK_MBUTTON ;    x:  0; y:  0; info:'Middle mouse button (three-button mouse)'), 
    //(name:'XBUTTON1'; vk:VK_XBUTTON1 ; x:0; y:0; info:'Windows 2000/XP: X1 mouse button'),
    //(name:'XBUTTON2'; vk:VK_XBUTTON2 ; x:0; y:0; info:'Windows 2000/XP: X2 mouse button'),
    (name:'BACK';       vk:VK_BACK ;       x: 23; y: 16; info:'BACKSPACE key'), 
    (name:'TAB';        vk:VK_TAB ;        x:-18; y: 12; info:'TAB key'), 
    (name:'CLEAR';      vk:VK_CLEAR ;      x:  0; y:  0; info:'CLEAR key'), 
    (name:'RETURN';     vk:VK_RETURN ;     x: 24; y: 10; info:'ENTER key'), 
    (name:'ENTER';      vk:VK_RETURN ;     x: 24; y: 10; info:'ENTER key'), // RETURN und ENTER sind gleich
    (name:'SHIFT';      vk:VK_SHIFT ;      x:-19; y:  4; info:'LSHIFT key'), 
    (name:'CONTROL';    vk:VK_CONTROL ;    x:-19; y:  0; info:'LCTRL key'), 
    (name:'MENU';       vk:VK_MENU ;       x:-11; y:  0; info:'ALT key'), 
    (name:'ALT';        vk:VK_MENU ;       x:-11; y:  0; info:'ALT key'),  // Nochmal mit richtigem Namen!!!
    (name:'PAUSE';      vk:VK_PAUSE ;      x: 34; y: 24; info:'PAUSE key'), 
    (name:'CAPITAL';    vk:VK_CAPITAL ;    x:-19; y:  8; info:'CAPS LOCK key'), 
    (name:'KANA';       vk:VK_KANA ;       x:  0; y:  0; info:'Input Method Editor (IME) Kana mode'), 
    //(name:'HANGUEL'; vk:VK_HANGUEL ; x:0; y:0; info:'IME Hanguel mode (maintained for compatibility; use VK_HANGUL)'),
    (name:'HANGUL';     vk:VK_HANGUL ;     x:  0; y:  0; info:'IME Hangul mode'), 
    (name:'JUNJA';      vk:VK_JUNJA ;      x:  0; y:  0; info:'IME Junja mode'), 
    (name:'FINAL';      vk:VK_FINAL ;      x:  0; y:  0; info:'IME final mode'), 
    (name:'HANJA';      vk:VK_HANJA ;      x:  0; y:  0; info:'IME Hanja mode'), 
    (name:'KANJI';      vk:VK_KANJI ;      x:  0; y:  0; info:'IME Kanji mode'), 
    (name:'ESCAPE';     vk:VK_ESCAPE ;     x:-20; y: 24; info:'ESC key'), 
    (name:'CONVERT';    vk:VK_CONVERT ;    x:  0; y:  0; info:'IME convert'), 
    (name:'NONCONVERT'; vk:VK_NONCONVERT ; x:  0; y:  0; info:'IME nonconvert'), 
    (name:'ACCEPT';     vk:VK_ACCEPT ;     x:  0; y:  0; info:'IME accept'), 
    (name:'MODECHANGE'; vk:VK_MODECHANGE ; x:  0; y:  0; info:'IME mode change request'), 
    (name:'SPACE';      vk:VK_SPACE ;      x:  0; y:  0; info:'SPACEBAR'), 
    (name:'PRIOR';      vk:VK_PRIOR ;      x: 34; y: 16; info:'PAGE UP key'), 
    (name:'NEXT';       vk:VK_NEXT ;       x: 34; y: 12; info:'PAGE DOWN key'), 
    (name:'END';        vk:VK_END ;        x: 31; y: 12; info:'END key'), 
    (name:'HOME';       vk:VK_HOME ;       x: 31; y: 16; info:'HOME key'), 
    (name:'LEFT';       vk:VK_LEFT ;       x: 28; y:  0; info:'LEFT ARROW key'), 
    (name:'UP';         vk:VK_UP ;         x: 31; y:  4; info:'UP ARROW key'), 
    (name:'RIGHT';      vk:VK_RIGHT ;      x: 34; y:  0; info:'RIGHT ARROW key'), 
    (name:'DOWN';       vk:VK_DOWN ;       x: 31; y:  0; info:'DOWN ARROW key'), 
    (name:'SELECT';     vk:VK_SELECT ;     x:  0; y:  0; info:'SELECT key'), 
    (name:'PRINT';      vk:VK_PRINT ;      x: 28; y: 24; info:'PRINT key'), 
    (name:'EXECUTE';    vk:VK_EXECUTE ;    x:  0; y:  0; info:'EXECUTE key'), 
    (name:'SNAPSHOT';   vk:VK_SNAPSHOT ;   x: 28; y: 24; info:'PRINT SCREEN key'), 
    (name:'INSERT';     vk:VK_INSERT ;     x: 28; y: 16; info:'INS key'), 
    (name:'DELETE';     vk:VK_DELETE ;     x: 28; y: 12; info:'DEL key'), 
    (name:'HELP';       vk:VK_HELP ;       x:  0; y:  0; info:'HELP key'), 
    (name:'0';          vk:$30 ;           x: 11; y: 16; info:'0 key'), 
    (name:'1';          vk:$31 ;           x:-16; y: 16; info:'1 key'), 
    (name:'2';          vk:$32 ;           x:-13; y: 16; info:'2 key'), 
    (name:'3';          vk:$33 ;           x:-10; y: 16; info:'3 key'), 
    (name:'4';          vk:$34 ;           x: -7; y: 16; info:'4 key'), 
    (name:'5';          vk:$35 ;           x: -4; y: 16; info:'5 key'), 
    (name:'6';          vk:$36 ;           x: -1; y: 16; info:'6 key'), 
    (name:'7';          vk:$37 ;           x:  2; y: 16; info:'7 key'), 
    (name:'8';          vk:$38 ;           x:  5; y: 16; info:'8 key'), 
    (name:'9';          vk:$39 ;           x:  8; y: 16; info:'9 key'), 
    (name:'A';          vk:$41 ;           x:-13; y:  8; info:'A key'), 
    (name:'B';          vk:$42 ;           x:  0; y:  4; info:'B key'), 
    (name:'C';          vk:$43 ;           x: -6; y:  4; info:'C key'), 
    (name:'D';          vk:$44 ;           x: -7; y:  8; info:'D key'), 
    (name:'E';          vk:$45 ;           x: -8; y: 12; info:'E key'), 
    (name:'F';          vk:$46 ;           x: -4; y:  8; info:'F key'), 
    (name:'G';          vk:$47 ;           x: -1; y:  8; info:'G key'), 
    (name:'H';          vk:$48 ;           x:  2; y:  8; info:'H key'), 
    (name:'I';          vk:$49 ;           x:  7; y: 12; info:'I key'), 
    (name:'J';          vk:$4A ;           x:  5; y:  8; info:'J key'), 
    (name:'K';          vk:$4B ;           x:  8; y:  8; info:'K key'), 
    (name:'L';          vk:$4C ;           x: 11; y:  8; info:'L key'), 
    (name:'M';          vk:$4D ;           x:  6; y:  4; info:'M key'), 
    (name:'N';          vk:$4E ;           x:  3; y:  4; info:'N key'), 
    (name:'O';          vk:$4F ;           x: 10; y: 12; info:'O key'), 
    (name:'P';          vk:$50 ;           x: 13; y: 12; info:'P key'), 
    (name:'Q';          vk:$51 ;           x:-14; y: 12; info:'Q key'), 
    (name:'R';          vk:$52 ;           x: -5; y: 12; info:'R key'), 
    (name:'S';          vk:$53 ;           x:-10; y:  8; info:'S key'), 
    (name:'T';          vk:$54 ;           x: -2; y: 12; info:'T key'), 
    (name:'U';          vk:$55 ;           x:  4; y: 12; info:'U key'), 
    (name:'V';          vk:$56 ;           x: -3; y:  4; info:'V key'), 
    (name:'W';          vk:$57 ;           x:-11; y: 12; info:'W key'), 
    (name:'X';          vk:$58 ;           x: -9; y:  4; info:'X key'), 
    (name:'Y';          vk:$59 ;           x:-12; y:  4; info:'Y key'), 
    (name:'Z';          vk:$5A ;           x:  1; y: 12; info:'Z key'), 
    (name:'LWIN';       vk:VK_LWIN ;       x:-14; y:  0; info:'Left Windows key (Microsoft® Natural® keyboard)'), 
    (name:'RWIN';       vk:VK_RWIN ;       x: 15; y:  0; info:'Right Windows key (Natural keyboard)'), 
    (name:'APPS';       vk:VK_APPS ;       x:  0; y:  0; info:'Applications key (Natural keyboard)'), 
    //(name:'SLEEP'; vk:VK_SLEEP ; x:0; y:0; info:'Computer Sleep key'),
    (name:'NUMPAD0';    vk:VK_NUMPAD0 ;    x: 40; y:  0; info:'Numeric keypad 0 key'), 
    (name:'NUMPAD1';    vk:VK_NUMPAD1 ;    x: 39; y:  4; info:'Numeric keypad 1 key'), 
    (name:'NUMPAD2';    vk:VK_NUMPAD2 ;    x: 42; y:  4; info:'Numeric keypad 2 key'), 
    (name:'NUMPAD3';    vk:VK_NUMPAD3 ;    x: 45; y:  4; info:'Numeric keypad 3 key'), 
    (name:'NUMPAD4';    vk:VK_NUMPAD4 ;    x: 39; y:  8; info:'Numeric keypad 4 key'), 
    (name:'NUMPAD5';    vk:VK_NUMPAD5 ;    x: 42; y:  8; info:'Numeric keypad 5 key'), 
    (name:'NUMPAD6';    vk:VK_NUMPAD6 ;    x: 45; y:  8; info:'Numeric keypad 6 key'), 
    (name:'NUMPAD7';    vk:VK_NUMPAD7 ;    x: 39; y: 12; info:'Numeric keypad 7 key'), 
    (name:'NUMPAD8';    vk:VK_NUMPAD8 ;    x: 42; y: 12; info:'Numeric keypad 8 key'), 
    (name:'NUMPAD9';    vk:VK_NUMPAD9 ;    x: 45; y: 12; info:'Numeric keypad 9 key'), 
    (name:'MULTIPLY';   vk:VK_MULTIPLY ;   x: 45; y: 16; info:'Multiply key'), 
    (name:'ADD';        vk:VK_ADD ;        x: 48; y: 10; info:'Add key'), 
    (name:'SEPARATOR';  vk:VK_SEPARATOR ;  x:  0; y:  0; info:'Separator key'), 
    (name:'SUBTRACT';   vk:VK_SUBTRACT ;   x: 48; y: 16; info:'Subtract key'), 
    (name:'DECIMAL';    vk:VK_DECIMAL ;    x: 45; y:  0; info:'Decimal key'), 
    (name:'DIVIDE';     vk:VK_DIVIDE ;     x: 42; y: 16; info:'Divide key'), 
    (name:'F1';         vk:VK_F1 ;         x:-13; y: 24; info:'F1 key'), 
    (name:'F2';         vk:VK_F2 ;         x:-10; y: 24; info:'F2 key'), 
    (name:'F3';         vk:VK_F3 ;         x: -7; y: 24; info:'F3 key'), 
    (name:'F4';         vk:VK_F4 ;         x: -4; y: 24; info:'F4 key'), 
    (name:'F5';         vk:VK_F5 ;         x:  1; y: 24; info:'F5 key'), 
    (name:'F6';         vk:VK_F6 ;         x:  4; y: 24; info:'F6 key'), 
    (name:'F7';         vk:VK_F7 ;         x:  7; y: 24; info:'F7 key'), 
    (name:'F8';         vk:VK_F8 ;         x: 10; y: 24; info:'F8 key'), 
    (name:'F9';         vk:VK_F9 ;         x: 15; y: 24; info:'F9 key'), 
    (name:'F10';        vk:VK_F10 ;        x: 18; y: 24; info:'F10 key'), 
    (name:'F11';        vk:VK_F11 ;        x: 21; y: 24; info:'F11 key'), 
    (name:'F12';        vk:VK_F12 ;        x: 24; y: 24; info:'F12 key'), 
    (name:'F13';        vk:VK_F13 ;        x:  0; y:  0; info:'F13 key'), 
    (name:'F14';        vk:VK_F14 ;        x:  0; y:  0; info:'F14 key'), 
    (name:'F15';        vk:VK_F15 ;        x:  0; y:  0; info:'F15 key'), 
    (name:'F16';        vk:VK_F16 ;        x:  0; y:  0; info:'F16 key'), 
    (name:'F17';        vk:VK_F17 ;        x:  0; y:  0; info:'F17 key'), 
    (name:'F18';        vk:VK_F18 ;        x:  0; y:  0; info:'F18 key'), 
    (name:'F19';        vk:VK_F19 ;        x:  0; y:  0; info:'F19 key'), 
    (name:'F20';        vk:VK_F20 ;        x:  0; y:  0; info:'F20 key'), 
    (name:'F21';        vk:VK_F21 ;        x:  0; y:  0; info:'F21 key'), 
    (name:'F22';        vk:VK_F22 ;        x:  0; y:  0; info:'F22 key'), 
    (name:'F23';        vk:VK_F23 ;        x:  0; y:  0; info:'F23 key'), 
    (name:'F24';        vk:VK_F24 ;        x:  0; y:  0; info:'F24 key'), 
    (name:'NUMLOCK';    vk:VK_NUMLOCK ;    x: 39; y: 16; info:'NUM LOCK key'), 
    (name:'SCROLL';     vk:VK_SCROLL ;     x: 31; y: 24; info:'SCROLL LOCK key'), 
    (name:'LSHIFT';     vk:VK_LSHIFT ;     x:-19; y:  4; info:'Left SHIFT key'), 
    (name:'RSHIFT';     vk:VK_RSHIFT ;     x: 21; y:  4; info:'Right SHIFT key'), 
    (name:'LCONTROL';   vk:VK_LCONTROL ;   x:-19; y:  0; info:'Left CONTROL key'), 
    (name:'RCONTROL';   vk:VK_RCONTROL ;   x: 24; y:  0; info:'Right CONTROL key'), 
    (name:'LMENU';      vk:VK_LMENU ;      x:  0; y:  0; info:'Left MENU key'), 
    (name:'RMENU';      vk:VK_RMENU ;      x: 19; y:  0; info:'Right MENU key'), 
    //(name:'BROWSER_BACK'; vk:VK_BROWSER_BACK ; x:0; y:0; info:'Windows 2000/XP: Browser Back key'),
    //(name:'BROWSER_FORWARD'; vk:VK_BROWSER_FORWARD ; x:0; y:0; info:'Windows 2000/XP: Browser Forward key'),
    //(name:'BROWSER_REFRESH'; vk:VK_BROWSER_REFRESH ; x:0; y:0; info:'Windows 2000/XP: Browser Refresh key'),
    //(name:'BROWSER_STOP'; vk:VK_BROWSER_STOP ; x:0; y:0; info:'Windows 2000/XP: Browser Stop key'),
    //(name:'BROWSER_SEARCH'; vk:VK_BROWSER_SEARCH ; x:0; y:0; info:'Windows 2000/XP: Browser Search key'),
    //(name:'BROWSER_FAVORITES'; vk:VK_BROWSER_FAVORITES ; x:0; y:0; info:'Windows 2000/XP: Browser Favorites key'),
    //(name:'BROWSER_HOME'; vk:VK_BROWSER_HOME ; x:0; y:0; info:'Windows 2000/XP: Browser Start and Home key'),
    //(name:'VOLUME_MUTE'; vk:VK_VOLUME_MUTE ; x:0; y:0; info:'Windows 2000/XP: Volume Mute key'),
    //(name:'VOLUME_DOWN'; vk:VK_VOLUME_DOWN ; x:0; y:0; info:'Windows 2000/XP: Volume Down key'),
    //(name:'VOLUME_UP'; vk:VK_VOLUME_UP ; x:0; y:0; info:'Windows 2000/XP: Volume Up key'),
    //(name:'MEDIA_NEXT_TRACK'; vk:VK_MEDIA_NEXT_TRACK ; x:0; y:0; info:'Windows 2000/XP: Next Track key'),
    //(name:'MEDIA_PREV_TRACK'; vk:VK_MEDIA_PREV_TRACK ; x:0; y:0; info:'Windows 2000/XP: Previous Track key'),
    //(name:'MEDIA_STOP'; vk:VK_MEDIA_STOP ; x:0; y:0; info:'Windows 2000/XP: Stop Media key'),
    //(name:'MEDIA_PLAY_PAUSE'; vk:VK_MEDIA_PLAY_PAUSE ; x:0; y:0; info:'Windows 2000/XP: Play/Pause Media key'),
    //(name:'LAUNCH_MAIL'; vk:VK_LAUNCH_MAIL ; x:0; y:0; info:'Windows 2000/XP: Start Mail key'),
    //(name:'LAUNCH_MEDIA_SELECT'; vk:VK_LAUNCH_MEDIA_SELECT ; x:0; y:0; info:'Windows 2000/XP: Select Media key'),
    //(name:'LAUNCH_APP1'; vk:VK_LAUNCH_APP1 ; x:0; y:0; info:'Windows 2000/XP: Start Application 1 key'),
    //(name:'LAUNCH_APP2'; vk:VK_LAUNCH_APP2 ; x:0; y:0; info:'Windows 2000/XP: Start Application 2 key'),
    (name:'OEM_1';      vk:VK_OEM_1 ;      x: 16; y: 12; info:'German ''Ü'''), 
    //Windows 2000/XP: For the US standard keyboard, the ';:' key'),
    (name:'OEM_PLUS';   vk:VK_OEM_PLUS ;   x: 19; y: 12; info:'Windows 2000/XP: For any country/region, the ''+'' key'), 
    (name:'OEM_COMMA';  vk:VK_OEM_COMMA ;  x:  9; y:  4; info:'Windows 2000/XP: For any country/region, the '','' key'), 
    (name:'OEM_MINUS';  vk:VK_OEM_MINUS ;  x: 15; y:  4; info:'Windows 2000/XP: For any country/region, the ''-'' key'), 
    (name:'OEM_PERIOD'; vk:VK_OEM_PERIOD ; x: 12; y:  4; info:'Windows 2000/XP: For any country/region, the ''.'' key'), 
    (name:'OEM_2';      vk:VK_OEM_2 ;      x: 20; y:  8; info:'German ''#'''), 
    //Windows 2000/XP: For the US standard keyboard, the '/?' key'),
    (name:'OEM_3';      vk:VK_OEM_3 ;      x: 14; y:  8; info:'German ''Ö'''), 
    //Windows 2000/XP: For the US standard keyboard, the '`~' key'),
    (name:'OEM_4';      vk:VK_OEM_4 ;      x: 14; y: 16; info:'German ''ß'''), 
    //Windows 2000/XP: For the US standard keyboard, the '[{' key'),
    (name:'OEM_5';      vk:VK_OEM_5 ;      x:-14; y: 16; info:'German ''^°'''), 
    //Windows 2000/XP: For the US standard keyboard, the '\|' key'),
    (name:'OEM_6';      vk:VK_OEM_6 ;      x: 17; y: 16; info:'german ''´`'''), 
    //Windows 2000/XP:  For the US standard keyboard, the ']}' key'),
    (name:'OEM_7';      vk:VK_OEM_7 ;      x: 17; y:  8; info:'german ''Ä'''), 
    //Windows 2000/XP: For the US standard keyboard, the 'single-quote/double-quote' key'),
    //(name:'OEM_8'; vk:VK_OEM_8 ; x:0; y:0; info:'Used for miscellaneous characters; it can vary by keyboard.'),
    (name:'OEM_102';    vk:VK_OEM_102 ;    x:-15; y:  4; info:'Windows 2000/XP: Either the angle bracket key or the backslash key on the RT 102-key keyboard'), 
    (name:'PROCESSKEY'; vk:VK_PROCESSKEY ; x:  0; y:  0; info:'Windows 95/98/Me, Windows NT 4.0, Windows 2000/XP: IME PROCESS key'), 
    //(name:'PACKET'; vk:VK_PACKET ; x:0; y:0; info:'Windows 2000/XP: Used to pass Unicode characters as if they were keystrokes. The VK_PACKET key is the low word of a 32-bit Virtual Key value used for non-keyboard input methods. For more information, see Remark in KEYBDINPUT, SendInput, WM_KEYDOWN, and WM_KEYUP'),
    (name:'ATTN';       vk:VK_ATTN ;       x:  0; y:  0; info:'Attn key'), 
    (name:'CRSEL';      vk:VK_CRSEL ;      x:  0; y:  0; info:'CrSel key'), 
    (name:'EXSEL';      vk:VK_EXSEL ;      x:  0; y:  0; info:'ExSel key'), 
    (name:'EREOF';      vk:VK_EREOF ;      x:  0; y:  0; info:'Erase EOF key'), 
    (name:'PLAY';       vk:VK_PLAY ;       x:  0; y:  0; info:'Play key'), 
    (name:'ZOOM';       vk:VK_ZOOM ;       x:  0; y:  0; info:'Zoom key'), 
    (name:'NONAME';     vk:VK_NONAME ;     x:  0; y:  0; info:'Reserved for future use'), 
    (name:'PA1';        vk:VK_PA1 ;        x:  0; y:  0; info:'PA1 key'), 
    (name:'OEM_CLEAR';  vk:VK_OEM_CLEAR ;  x:  0; y:  0; info:'Clear key') 
  ) { "constKeyInfo: array[0..KeyInfoTableLen-1] of TKeyInfo" } ; 


  { TAppControl }

  // virtual key code zu keynamen zurückgeben
function getVK(keyname:string): integer ; 
  var i: integer ; 
  begin 
    result := 0 ; 
    keyname := Uppercase(keyname) ; 
    for i := 0 to KeyInfoTableLen-1 do 
      if KeyInfo[i].name = keyname then begin 
        result := KeyInfo[i].vk ; 
        break ; 
      end ; 
  end ; 

// Wert zufällig um +/- "jitterpercent"-Prozent verändern
function getJitteredValue(orgval: double; jitterpercent: double):double ; 
  var delta: double ; 
  begin 
    if jitterpercent < 0 then jitterpercent := 0 ; 
    if jitterpercent > 100 then jitterpercent := 100 ; 

    delta := orgval * jitterpercent / 100 ; 
    result := orgval + random() * 2 * delta - delta ; 
  end; 



// liefert Strings der Form: <id>=<Title>
// kann mit Values[] etc verarbeitet werden.
function EnumWindowsProc(wHandle: HWND; Lines: TStrings): BOOL; stdcall; export; 

  function EnumChildWindowsProc(wnd: HWND; Lines: TStrings): BOOL; stdcall; 
    var 
      classname, title{, caption}: array[0..255] of char; 
    begin 
      result := true; 
      GetClassName(wnd, classname, SizeOf(classname) - 1); 
      GetWindowText(wnd, title, SizeOf(title) - 1); 
//      PostMessage(wnd, WM_GETTEXT, 256, integer(@Caption));
      Lines.Add(Format('%d=class:%s, title:%s, id:%d', 
              [wnd, classname, title, integer(wnd)])); 
    end; 

  var 
    title, classname: array[0..255] of char; 
  begin { "function EnumWindowsProc" } 
    result := true; 
    GetWindowText(wHandle, title, 255); 
    GetClassName(wHandle, classname, 255); 
    if IsWindowVisible(wHandle) then begin 
      Lines.Add(Format('%d=class:%s, title:%s, id:%d', 
              [integer(wHandle),classname, title, integer(wHandle)])); 
      // Enum im Callback eines anderen Enums?
      EnumChildWindows(wHandle, @EnumChildWindowsProc, integer(Lines)) ; 
    end ; 
  end; 




constructor TAppControl.Create; 
  begin 
    inherited ; 
    AppMainWindowHandle := 0 ; 
    AppWindowHandle := 0 ; 
    lastvkey := 0 ; // no last key
    humanTypingSpeedfactor := 0.25 ; // schneller Tippen, Standard ist sehr lahm
    humanJitterPercent := 20 ; // alle menschen-ähnlichen Aktionen mit soviel Zufallsbewegung
  end; 

destructor TAppControl.Destroy; 
  begin 
    inherited ; 
  end; 

// Finde das Window mit dem angegebenen Titel, setzt AppWindowHandle
function TAppControl.FindWindowByTitleOrClassname(aWindowTitle, aWindowClassname:string) : THandle ; 
  var 
    i: integer ; 
    sl: TStringList ; 
    found: boolean ; 
  begin 
    result := 0 ; 
    sl := TStringList.Create ; 
    try 
      // s ist ein Fenstertitle, suche ihn in allen Fenstern
      // sl enthält strings der form <title>=<handle>
      EnumWindows(@EnumWindowsProc, integer(sl)); 
      for i := 0 to sl.Count-1 do begin 
        found := true ; 
        if (aWindowTitle <> '') and (pos('title:'+aWindowTitle, sl.Values[sl.Names[i]]) <= 0) then 
          found := False ; 
        if (aWindowClassname <> '') and (pos('class:'+aWindowClassname, sl.Values[sl.Names[i]]) <= 0) then 
          found := False ; 
        if found then begin 
          result := StrToInt(sl.Names[i]) ; 
          break ; 
        end ; 
      end ; 
    finally 
      sl.Free ; 
    end { "try" } ; 
  end { "function TAppControl.FindWindowByTitleOrClassname" } ; 


// setzt AppMainWindowHandle. MUSS einmal erfolgreich aufgerufen werden!
// Dnach ist auch die Processinfo bekannt!
function TAppControl.ConnectToMainWindowByTitleOrClassname(aWindowTitle, aWindowClassname:string) : boolean ; 
  begin 
    AppMainWindowHandle := FindWindowByTitleOrClassname(aWindowTitle, aWindowClassname) ; 
    AppWindowHandle := AppMainWindowHandle ; 
    result := (AppMainWindowHandle <> 0) ; 
    if result then 
      GetProcessInfo ; 
  end ; 

// setzt AppWindowHandle.
function TAppControl.ConnectToWindowByTitleOrClassname(aWindowTitle, aWindowClassname:string) : boolean ; 
  begin 
    AppWindowHandle := FindWindowByTitleOrClassname(aWindowTitle, aWindowClassname) ; 
    result := (AppWindowHandle <> 0) ; 
  end ; 

function TAppControl.ApplicationContact: boolean ; // false, wenn Applikation nicht (mehr) da
  var rect: Trect ; 
  begin 
    result := GetWindowRect(AppMainWindowHandle, rect) ; 
  end; 

function TAppControl.GetProcessHandle: THandle ; 
  var hProcessId: THandle ; 
  begin 
    // get process id
    // Delphi XE/Win7
  hProcessId := GetWindowThreadProcessId(AppMainWindowHandle) ;
  // OLD
//    GetWindowThreadProcessId(AppMainWindowHandle, hProcessId) ;
    // get process handle
    result := OpenProcess(PROCESS_QUERY_INFORMATION or PROCESS_VM_READ, False, hProcessId) ; 
  end; 

function TAppControl.ApplicationPath: string ; // false, wenn Applikation nicht (mehr) da
  var 
    hProcess: THandle ; 
    hMod: HModule ; 
    szProcessName: array [0..MAX_PATH] of char ; 
    cbNeeded: dword ; 
  begin 
    result := '' ; 
    hProcess := GetProcessHandle ; 
    try 
      // Get filename
      if hProcess <> 0  then begin 
        if EnumProcessModules( hProcess, @hMod, SizeOf(hMod), cbNeeded) then 
          GetModuleFileNameEx( hProcess, hMod, szProcessName, 
                  SizeOf(szProcessName) ); 
        result := strpas(szProcessName) ; 
      end; 
    finally 
      CloseHandle(hProcess) ; 
    end; 
  end { "function TAppControl.ApplicationPath" } ; 


procedure TAppControl.ApplicationTerminate; 
  var 
    hProcess: THandle ; 
    res: dword ; 
  begin 
    if ApplicationContact then begin 
      // nach http://support.microsoft.com/default.aspx?scid=KB;en-us;178893&
      hProcess := GetProcessHandle ; 

      //1. Fenster schliessen
      PostMessage(AppMainWindowHandle, WM_CLOSE, 0, 0) ; 
      // 2. Warten, ob es von alleine runterfährt
      res := WaitForSingleObject(hProcess, 5000) ; // warte auf shutdown
      // 3. Abschiessen
      if res = WAIT_TIMEOUT then 
        TerminateProcess(hProcess, 1) ; 
    end ; 
  end{ "procedure TAppControl.ApplicationTerminate" } ; 


procedure TAppControl.StartApplication(imagefilename,args,workingdir:string) ; 
  var 
    buff1, buff2, buff3: array[0..MAX_PATH] of char ; 
    hInstance: THandle ; 
  begin 
    hInstance := ShellExecute(0, 'open', 
            strpcopy(buff1, imagefilename), 
            strpcopy(buff2, args), 
            strpcopy(buff3, workingdir), 
            SW_SHOWNORMAL) ; 
    if hInstance < 32 then 
      raise Exception.CreateFmt('Could not start application from "%s"', [imagefilename]) ; 

  end { "procedure TAppControl.StartApplication" } ; 


// ProcessID und imagefilename der Application
procedure TAppControl.GetProcessInfo ; 
  var 
    szImageFileName: array[0..1024] of char ; 
    hMod : HModule ; 
    cbNeeded: dword ; 
  begin 
    GetWindowThreadProcessId(AppMainWindowHandle, @ProcessID) ; 

    ProcessHandle := OpenProcess( PROCESS_QUERY_INFORMATION or PROCESS_VM_READ, False, ProcessID ); 
    imagefilename := '' ; 
    if ProcessHandle <> 0  then begin 
      // 1. Modul = winamp.exe
      if EnumProcessModules( ProcessHandle, @hMod, SizeOf(hMod), cbNeeded) then 
        GetModuleFileNameEx( ProcessHandle, hMod, szImageFileName, SizeOf(szImageFileName) ); 
      imagefilename := strpas(szImageFileName) ; 
    end ; 
    CloseHandle(ProcessHandle) ; 
  end { "procedure TAppControl.GetProcessInfo" } ; 


procedure TAppControl.ShowApplication ; // in den Vordergrund
  begin 
    ShowWindow(AppMainWindowHandle, SW_SHOWNORMAL) ; 
    SetForegroundWindow(AppMainWindowHandle) ; 
  end; 


class function TAppControl.isValidWindowHandle(aHandle: HWND): boolean ; 
  var title: array[0..255] of char; 
  begin 
    result := GetWindowText(aHandle, title, 255) > 0 ; 
  end ; 



// macht eine Pause in abh von lastvkey, lastvkey_down, lastvkey_ticks
// Simuliert die Bewegungen der menschlichen Hände üner der Tastatur
procedure TAppControl.humanTypingDelay(vkey: integer ; down:boolean) ; 
  var 
    delay: integer ; 
    i: integer ; 
    last_x, last_y, cur_x, cur_y: integer ; 
    dx, dy: integer ; 
    distance: integer ; 
  begin 

// Bewegungs modell
// Press dauert 100 ms,
// - Release dauert 100 ms
// - Wechsel zwischen linker und rechter Hand dauert 100 ms
// - Bewegung über eine ganze Tastaturhälfte (24 Koordinateneinheiten) dauert 250 ms

    if down = False then begin 
      // nur Loslassen einer Taste
      delay := 100 ; 
    end else begin 
      // Hand bewegen und drücken

      // Ausgangsposition?
      last_x := 0 ; last_y := 0 ; 
      for i := 0 to KeyInfoTableLen-1 do 
        if KeyInfo[i].vk = lastvkey then begin 
          last_x := KeyInfo[i].x ; 
          last_y := KeyInfo[i].y ; 
          break ; 
        end ; 

      // Zielposition?
      cur_x := 0 ; cur_y := 0 ; 
      for i := 0 to KeyInfoTableLen-1 do 
        if KeyInfo[i].vk = vkey then begin 
          cur_x := KeyInfo[i].x ; 
          cur_y := KeyInfo[i].y ; 
          break ; 
        end ; 

      if vkey = lastvkey then // keine Wechselzeit
        delay := 100 // nur key press
      else if (vkey = VK_SPACE) or (lastvkey = VK_SPACE) then begin 
        distance := abs(cur_y - last_y) ; // Spacebar ist so breit: nur vertikaler Abstand spielt eine Rolle
        delay := 250 * distance div 24 + 100 ; 
      end else if ((cur_x <= 0) and (last_x <= 0)) or ((cur_x > 0) and (last_x > 0)) then begin 
        // alte und neue Taste liegen in der selben Tastaturhälfte
        dx := cur_x - last_x ; dy := cur_y - last_y ; 
        distance := round(sqrt(dx * dx + dy * dy)) ; 
        delay := 250 * distance div 24 + 100 ; 
      end else begin 
        // Wechsel der Tastaturhälfte: nimm Handposition in der Mitte der neuen Hälfte an
        if last_x <= 0 then last_x := -12 else last_x := 12 ; 
        last_y := 8 ; 
        dx := cur_x - last_x ; dy := cur_y - last_y ; 
        distance := round(sqrt(dx * dx + dy * dy)) ; 
        // Handwechsel kostet 100ms, dafür ist distance kürzer
        delay := 100 + 250 * distance div 24 + 100 ; 
      end ; 
    end { "if down = False ... ELSE" } ; 

    // neuen Zustand speichern
    lastvkey := vkey ; 
    lastvkey_down := down ; 

    // Zufalls jitter von +-20ms
    delay := round(getJitteredValue(humanTypingSpeedfactor * delay, humanJitterPercent)) ; 
    Sleep(delay) ; 
  end { "procedure TAppControl.humanTypingDelay" } ; 


// Ermittelt das Control, das in 'aWindowHandle' an der Position 'aPoint' steht,
// und gibt die Koordinaten von aPoint umgerechnet auf 'aChildWindowhandele' zurück.
class procedure TAppControl.getChildControlAtPoint(aWindowHandle: HWND ; main_x, main_y: integer; 
        var aChildWindowHandle: HWND; var child_x, child_y: integer) ; 
  var 
    rect: Trect ; // Screenlage des Window
    globalcursorpos: TPoint ; 
    childrect: Trect ; // Screenlage des Window
  begin 

    // Hmmm. What about "ChildWindowFromPointEx()" ?
    SetForegroundWindow(aWindowHandle) ; 

    GetWindowRect(aWindowHandle, rect) ; 

    globalcursorpos.x := rect.left + main_x ; 
    globalcursorpos.y := rect.top + main_y ; 
//    GetCursorPos(orgcursorpos) ;
//    SetCursorPos(globalcursorpos.x, globalcursorpos.y) ;

    aChildWindowHandle := WindowFromPoint(globalcursorpos) ; 
    GetWindowRect(aChildWindowHandle, childrect) ; 

    child_x := rect.left + main_x - childrect.left ; 
    child_y := rect.top + main_y - childrect.top ; 

  end { "procedure TAppControl.getChildControlAtPoint" } ; 


// "aPoint" liegt in "aChildWindow". Es werden die Koordinaten bzgl "aParentWindow"
// berechnet. Error, wenn aCHild nicht innerhalb "aParent" liegt.
class function TAppControl.getParentWindowPoint(aPoint: TPoint ; aChildWindowHandle: HWND ; 
        aParentWindowHandle: THandle): TPoint ; 
  var  childrect, parentrect: Trect ; 
  begin 
    // Lage der Fenster in Screenkoordinaten
    GetWindowRect(aChildWindowHandle, childrect) ; 
    GetWindowRect(aParentWindowHandle, parentrect) ; 

    // apoint in Screen koordinaten
    aPoint.x := aPoint.x + childrect.left ; 
    aPoint.y := aPoint.y + childrect.top; 

    aPoint.x := aPoint.x - parentrect.left ; 
    aPoint.y := aPoint.y - parentrect.top; 

    result := aPoint ; 
  end { "function TAppControl.getParentWindowPoint" } ; 


procedure TAppControl.MouseClick(x, y:integer ; leftbutton: boolean) ; 
  var 
    wparam: word ; 
    lparam: dword ; 
    aChildWindowHandle: HWND ; // das Childwindow, dass unter dem Cursor liegt.
    clickpoint: TPoint ; // Clickkoordinaten im Childwindow
  begin 
    getChildControlAtPoint(AppWindowHandle, x, y, 
            aChildWindowHandle, clickpoint.x, clickpoint.y) ; 

    wparam := MK_LBUTTON ; // keine Taste gedrückt
    lparam := dword(clickpoint.x) or (dword(clickpoint.y) shl 16 )  ; // keine taste gedrückt
    if leftbutton 
      then PostMessage(aChildWindowHandle, WM_LBUTTONDOWN, wparam, lparam) 
      else PostMessage(aChildWindowHandle, WM_RBUTTONDOWN, wparam, lparam) ; 

    wparam := 0 ; // keine taste gedrückt
    lparam := dword(clickpoint.x) or (dword(clickpoint.y) shl 16 )  ; // keine taste gedrückt
    if leftbutton 
      then PostMessage(aChildWindowHandle, WM_LBUTTONUP, wparam, lparam) 
      else PostMessage(aChildWindowHandle, WM_RBUTTONUP, wparam, lparam) ; 
  end{ "procedure TAppControl.MouseClick" } ; 


procedure TAppControl.MouseMove(x, y:integer) ; 
  var 
    wparam: word ; 
    lparam: dword ; 
    aChildWindowHandle: HWND ; // das Childwindow, dass unter dem Cursor liegt.
    movepoint: TPoint ; // Clickkoordinaten im Childwindow
    rect: Trect ; // Screenlage des Parentwindow
  begin 
    // Event ans Control senden. x/y = relativ bzgl. Window
    getChildControlAtPoint(AppWindowHandle, x, y, 
            aChildWindowHandle, movepoint.x, movepoint.y) ; 

    wparam := 0 ; // keine Taste gedrückt
    lparam := dword(movepoint.x) or (dword(movepoint.y) shl 16 )  ; // keine taste gedrückt
    PostMessage(aChildWindowHandle, WM_MOUSEMOVE, wparam, lparam) ; 

    // Cursor position absolut setzen
    GetWindowRect(AppWindowHandle, rect) ; 
    SetCursorPos(rect.left + x, rect.top + y) ; 

  end{ "procedure TAppControl.MouseMove" } ; 

(*
procedure TAppControl.MouseMove(x, y:integer) ;
  var rect: Trect ; // Screenlage des Window
  begin
//    SetForegroundWindow(aWindowHandle) ;
    GetWindowRect(AppWindowHandle, rect) ;

    x := rect.left + x ;
    y := rect.top + y ;
//    GetCursorPos(orgcursorpos) ;
    SetCursorPos(x, y) ;
  end ;
*)
// click auf x,y , aber eine Spur aus MouseMoves verursachen
// Gesamtaktion soll "totaltime" milliseks dauern
procedure TAppControl.humanMouseMove(x, y:integer; totaltime: integer) ; 
  var rect: Trect ; // Screenlage des Window
    p0: TPoint ; // Start der Bewegungstrecke
    p1: TPoint ; // Ziel der Bewegung
    dx, dy: integer ; 
    i, n: integer ; 
  begin 
    // Zeit verzufallen
    totaltime := round(getJitteredValue(totaltime, humanJitterPercent)) ; 

    GetCursorPos(p0) ; // Sart bei aktueller Mauscursor-Position
    //    GetCursorPos(orgcursorpos) ;

//    SetForegroundWindow(aWindowHandle) ;
    GetWindowRect(AppWindowHandle, rect) ; 
    p1.x := rect.left + x ; // Ziel in Absolutkoordinaten
    p1.y := rect.top + y ; 

    // Bewegung: von p0 nach p1
    // Anzahl der Mousemove-Events: alle 5ms einer
    n := round(totaltime / 5) ; 
    if n < 1 then n := 1 ; 
    dx := p1.x - p0.x ; 
    dy := p1.y - p0.y ; 

    // gradlinig auf Ziel zu
    for i := 1 to n do begin 
      Sleep(5) ; 
      x := p0.x + round( dx * i / n) ; 
      y := p0.y + round( dy * i / n) ; 
      // x, y muss nicht im AppWindow sein
      if (x >= rect.left) and (x < rect.right) and (y >= rect.top) and (y < rect.bottom) then begin 
        // Mousemove mit window-lokalen Koordinaten
        MouseMove(x - rect.left, y - rect.top) ; 
      end; 
    end; 
    //  in Zielnähe noch etwas daddeln
    if dx <> 0 then dx := dx div abs(dx) ; // map -> +1 / -1
    if dy <> 0 then dy := dy div abs(dy) ; 
    Sleep(5) ; 
    MouseMove(p1.x - dx  - rect.left, p1.y - dy - rect.top) ; // 1 Pixel zurück
    Sleep(5) ; 
    MouseMove(p1.x - rect.left, p1.y - rect.top) ; // genau auf den Punkt
  end{ "procedure TAppControl.humanMouseMove" } ; 


// click auf x,y , aber eine Spur aus MouseMoves verursachen
procedure TAppControl.humanMouseClick(x, y:integer; leftbutton: boolean; totaltime: integer) ; 
  begin 
    // dieselbe Zeit für Mausmove wie für Clickpause
    humanMouseMove(x, y, totaltime) ; 
    Sleep(totaltime) ; 
    MouseClick(x, y, leftbutton) ; 
  end; 


procedure TAppControl.KeyDown(aKeyname:string) ; 
  var vkey: integer ; 
  begin 
    vkey := getVK(aKeyname) ; 
    if vkey = 0 then raise Exception.CreateFmt('Illegal virtual key name "%s"', [aKeyname]) ; 
    humanTypingDelay(vkey,true) ; 
    keybd_event(vkey, MapVirtualKey(vkey, 0), 0, 0) 
  end ; 

procedure TAppControl.KeyUp(aKeyname:string) ; 
  var vkey: integer ; 
  begin 
    vkey := getVK(aKeyname) ; 
    if vkey = 0 then raise Exception.CreateFmt('Illegal virtual key name "%s"', [aKeyname]) ; 
    humanTypingDelay(vkey,False) ; 
    keybd_event(vkey, MapVirtualKey(vkey, 0), KEYEVENTF_KEYUP, 0) 
  end ; 

// Text tippen, in welches Fenster auch immer
procedure TAppControl.EnterText(s:string) ; 
  procedure postkey(vkey:integer; down:boolean) ; 
    begin 
      humanTypingDelay(vkey,down) ; 
      if down then 
        keybd_event(vkey, MapVirtualKey(vkey, 0), 0, 0) 
      else 
        keybd_event(vkey, MapVirtualKey(vkey, 0), KEYEVENTF_KEYUP, 0) ; 
      // keyd_event ist sehr hardware nah.
      // der Kram hier drunter funktioneirt nicht im JavaApplet von RuneScape.
      (*
        sleep(100) ;
        wparam := vk ; // virtual key code
        // Ermittele Scancode zum vk.
        lparam := (MapVirtualKey(vk, 0) shl 16) or 1 ; // scancode zu wparam + repeat=1
        if down then
          PostMessage(aChildWindowHandle, WM_KEYDOWN, wparam, lparam)
        else begin
          lparam := lparam or $C0000000 ; // Pflicht für KEYUP
          PostMessage(aChildWindowHandle, WM_KEYUP, wparam, integer(lparam)) ;
        end ;
        sleep(100) ;
        *)
    end { "procedure postkey" } ; 

  var 
//    clickpoint: TPoint ; // Clickkoordinaten im Childwindow
    i: integer ; 
    vkey: integer ; 
  begin { "procedure TAppControl.EnterText" } 
//    GetChildControlAtPoint(MainWindowHandle, x, y,
//            aChildWindowHandle, clickpoint.x, clickpoint.y) ;
    //  Windows.SetFocus(aChildWindowHandle) ;
    for i := 1 to length(s) do begin 
      vkey := VkKeyScan(s[i]) ; // Ascii -> keycodes
      if (vkey and $100) <> 0 then // SHIFT down
        postkey(VK_SHIFT, true) ; 
      if (vkey and $200) <> 0 then // CTRL down
        postkey(VK_CONTROL, true) ; 
      if (vkey and $400) <> 0 then // ALT down
        postkey(VK_MENU, true) ; 

      postkey(vkey and $ff, true) ; // key down

// WM_CHARs erzeugt sich die Applikation selber
//      wparam := ord(s[i]) ;
//      PostMessage(aChildWindowHandle, WM_CHAR, wparam, lparam) ;


      //// jetzt alle Keys wieder loslassen
      postkey(vkey and $ff, False) ; // key up
      if (vkey and $100) <> 0 then // SHIFT down
        postkey(VK_SHIFT, False) ; 
      if (vkey and $200) <> 0 then // CTRL down
        postkey(VK_CONTROL, False) ; 
      if (vkey and $400) <> 0 then // ALT down
        postkey(VK_MENU, False) ; 

    end { "for i" } ; 
  end { "procedure TAppControl.EnterText" } ; 


// Grösse des application windows setzen
// Koordinaten < 0 werden ignoriert.
procedure TAppControl.setWindowSize(newwidth, newheight: integer) ; 
  var 
    rect: Trect ; 
    wi: tagWINDOWINFO ; 
  begin 
    GetWindowInfo(AppWindowHandle, wi) ; 
    rect := wi.rcWindow ; 

    if (newwidth <= 0) then 
      newwidth := rect.right - rect.left ; 
    if (newheight <= 0) then 
      newheight := rect.bottom - rect.top ; 

    SetWindowPos(AppWindowHandle, 
            HWND_NOTOPMOST, 
            0, 0, // position will be ignored
            newwidth, newheight, 
            SWP_ASYNCWINDOWPOS+ SWP_SHOWWINDOW + SWP_NOOWNERZORDER + SWP_NOMOVE+ SWP_NOZORDER) ; 
  end{ "procedure TAppControl.setWindowSize" } ; 


procedure TAppControl.setWindowPosition(newLeft, newTop: integer) ; 
  var 
    rect: Trect ; 
    wi: tagWINDOWINFO ; 
  begin 
    GetWindowInfo(AppWindowHandle, wi) ; 
    rect := wi.rcWindow ; 

(*
    if (newLeft <= 0) then 
      newLeft := 0 ;
    if (newTop <= 0) then
      newTop := 0 ;
    SetWindowPos(
            HWND_NOTOPMOST,
            newLeft, newTop,
            0, 0,
            SWP_ASYNCWINDOWPOS+ SWP_NOSIZE) ;
//            SWP_ASYNCWINDOWPOS+ SWP_SHOWWINDOW + SWP_NOOWNERZORDER + SWP_NOSIZE+ SWP_NOZORDER) ;
*)
  end{ "procedure TAppControl.setWindowPosition" } ; 


end{ "unit AppControlU" } . 


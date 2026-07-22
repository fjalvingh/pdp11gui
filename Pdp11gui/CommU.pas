unit CommU;
{
   Copyright (c) 2016, Joerg Hoppe
   j_hoppe@t-online.de, www.retrocmp.com

   Permission is hereby granted, free of charge, to any person obtaining a
   copy of this software and associated documentation files (the "Software"),
   to deal in the Software without restriction, including without limitation
   the rights to use, copy, modify, merge, publish, distribute, sublicense,
   and/or sell copies of the Software, and to permit persons to whom the
   Software is furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in
   all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
   JOERG HOPPE BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
   IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
   CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
}

// Einfachst moegliche Ansteuerung des seriellen Ports.
//
// Linux port: reimplemented on termios (BaseUnix/termio) instead of the
// Win32 COM-port API (CreateFile/ReadFile/WriteFile/SetCommState/...).
// See LINUX_PORT_TODO.md for the device-naming caveat: "Port" is still a
// 1-based integer for compatibility with the rest of the app (which still
// presents a Windows-style "COM1".."COMn" picker), and gets mapped to a
// Linux device path heuristically - see DeviceName() below.

interface

uses
  Classes,
  ExtCtrls,
  SysUtils,
  Forms,
  Dialogs,
  Graphics,
  Controls,
  Buttons,
  StdCtrls,
  BaseUnix,
  termio;

const
  // Kompatibel zu den bisher aus der Windows-Unit verwendeten Werten.
  NOPARITY    = 0;
  ODDPARITY   = 1;
  EVENPARITY  = 2;
  MARKPARITY  = 3;
  SPACEPARITY = 4;

  ONESTOPBIT   = 0;
  ONE5STOPBITS = 1;
  TWOSTOPBITS  = 2;

type
  TComm = class(TComponent)

    private
      { Private declarations }
      fFd: cint; { Unix file descriptor, -1 = geschlossen }
      fPort: Integer; { port #, 1-based }
      fBaud: LongInt; { baud rate }
      fDataBits: Byte ; { one of 5,6,7,8 }
      fParity: Byte ; { one of NOPARITY, ODD..., EVEN... MARK..., SPACE... }
      fStopBits: Byte; { one of ONESTOPBIT, ONE5STOPBITS, TWOSTOPBITS }

      fRtsOn: boolean;
      fDtrOn: boolean;

      function isOpen: boolean;
      procedure setBaud(BaudToSet: LongInt);
      procedure setDataBits(DatabitsToSet: Byte);
      procedure setParity(ParityToSet: Byte);
      procedure setStopBits(StopBitsToSet: Byte);
      procedure setPort(PortToSet: Integer);
      procedure setRtsOn(OnOff: boolean);
      procedure setDtrOn(OnOff: boolean);
      function getInCount: LongInt;
      function getOutCount: LongInt;

      function DeviceName: string;
      procedure ApplyTermios;
      procedure setModemLine(bit: cint; OnOff: boolean);

    protected
      { Protected declarations }

    public
      { Public declarations }
      constructor Create(AOwner: TComponent); override;
      destructor Destroy; override;
      function Open: boolean;
      function WriteByte(ch: byte): boolean;
      function WriteData(var data; size: Integer): boolean;
      function ReadByte(var b: byte): boolean ;
      function ReadData(var data; size: Integer): Integer;
      procedure Flush;
      procedure Close;

    published
      { Published declarations }
      property Port: Integer read fPort write setPort;
      property Baud: LongInt read fBaud write setBaud;
      property DataBits: Byte read fDataBits write setDataBits;
      property Parity: Byte read fParity write setParity;
      property StopBits: Byte read fStopBits write setStopBits;
      property InCount: LongInt read getInCount;                              // number of characters received
      property OutCount: LongInt read getOutCount;                    // number of characters pending on transmit
      property Active: boolean read isOpen;                                                   // is port open
      property RtsOn: boolean read fRtsOn write setRtsOn;
      property DtrOn: boolean read fDtrOn write setDtrOn;
    end{ "TYPE TComm = class(TComponent)" } ;

// procedure Register;

function MsecTime: LongInt;
procedure Delay(msec: LongInt);

implementation

// Register the component with the Delphi IDE
// procedure Register;
//   begin
//    RegisterComponents('SUP', [TComm]);
//  end;

function MsecTime: LongInt;
  var
    Present: TDateTime;
    Hour, Min, Sec, msec: Word;
  begin
    Present := Now;
    DecodeTime(Present, Hour, Min, Sec, msec);
    Result := ((((Hour * 60) + Min) * 60) + Sec) * 1000 + msec;
  end;

procedure Delay(msec: LongInt);
  var
    nTimeOut: LongInt;
  begin
    nTimeOut := MsecTime + msec;
    while MsecTime < nTimeOut do
      Application.ProcessMessages();
  end;

// Component constructor
constructor TComm.Create(AOwner: TComponent);
  begin
    inherited Create(AOwner);
    // set default property values
    fFd := -1;
    fPort := 1;
    fBaud := 9600;
    fDataBits := 8 ;
    fParity := NOPARITY ;
    fStopBits := ONESTOPBIT ;
    fRtsOn  := false;
    fDtrOn := false;
  end;

// Component destructor
destructor TComm.Destroy;
  begin
    // close the com port (if open)
    Close;
    inherited Destroy;
  end;

// Return True if port is open
function TComm.isOpen: boolean;
  begin
    Result := (fFd >= 0);
  end;

// Windows kennt "COM1".."COMn"; Linux hat stattdessen Geraetepfade wie
// /dev/ttyUSB0 (USB-Serial-Adapter, der übliche Weg an echte PDP-11
// Hardware) oder /dev/ttyS0 (klassischer eingebauter serieller Port).
// Bis die Settings-UI eine echte Geraetepfad-Auswahl hat (siehe
// LINUX_PORT_TODO.md), wird die bisherige 1-basierte Portnummer heuristisch
// auf einen dieser Pfade abgebildet.
function TComm.DeviceName: string;
  var
    usbdev: string;
  begin
    usbdev := Format('/dev/ttyUSB%d', [fPort - 1]);
    if FileExists(usbdev) then
      result := usbdev
    else
      result := Format('/dev/ttyS%d', [fPort - 1]);
  end;

// Set the baud rate property
procedure TComm.setBaud(BaudToSet: LongInt);
  begin
    if BaudToSet <> fBaud then begin
      fBaud := BaudToSet;
      // if port is open, then close it and then reopen it
      // to reset the baud rate
      if isOpen then begin
        Close;
        Open;
      end;
    end;
  end;

  // Set the DataBits property
procedure TComm.setDataBits(DatabitsToSet: Byte);
  begin
    if Databits <> fDataBits then begin
      fDataBits := Databits;
      // if port is open, then close it and then reopen it
      // to reset the baud rate
      if isOpen then begin
        Close;
        Open;
      end;
    end;
  end;


  // Set the Parity property
procedure TComm.setParity(ParityToSet: Byte);
  begin
    if ParityToSet <> fParity then begin
      fParity := ParityToSet;
      // if port is open, then close it and then reopen it
      // to reset the baud rate
      if isOpen then begin
        Close;
        Open;
      end;
    end;
  end;

  // Set the StopBits property
procedure TComm.setStopBits(StopBitsToSet: Byte);
  begin
    if StopBitsToSet <> fStopBits then begin
      fStopBits := StopBitsToSet;
      // if port is open, then close it and then reopen it
      // to reset the baud rate
      if isOpen then begin
        Close;
        Open;
      end;
    end;
  end;

// Set the Port property
procedure TComm.setPort(PortToSet: Integer);
  begin
    if PortToSet <> fPort then begin
      fPort := PortToSet;
      // if port was open, then close and reopen it
      if isOpen then begin
        Close;
        Open;
      end;
    end;
  end;

procedure TComm.setModemLine(bit: cint; OnOff: boolean);
  var
    status: cint;
  begin
    if not isOpen then Exit ;
    status := 0 ;
    fpIOCtl(fFd, TIOCMGET, @status) ;
    if OnOff then
      status := status or bit
    else
      status := status and not bit ;
    fpIOCtl(fFd, TIOCMSET, @status) ;
  end;

procedure TComm.setRtsOn(OnOff: boolean);
  begin
    fRtsOn := OnOff;
    setModemLine(TIOCM_RTS, OnOff) ;
  end;

procedure TComm.setDtrOn(OnOff: boolean);
  begin
    fDtrOn := OnOff;
    setModemLine(TIOCM_DTR, OnOff) ;
  end;

function BaudToSpeedConst(baud: LongInt): cardinal;
  begin
    // termios kennt nur eine feste Menge Standard-Baudraten (B###-Konstanten).
    case baud of
      50: result := B50;
      75: result := B75;
      110: result := B110;
      134: result := B134;
      150: result := B150;
      200: result := B200;
      300: result := B300;
      600: result := B600;
      1200: result := B1200;
      1800: result := B1800;
      2400: result := B2400;
      4800: result := B4800;
      9600: result := B9600;
      19200: result := B19200;
      38400: result := B38400;
      57600: result := B57600;
      115200: result := B115200;
      230400: result := B230400;
      else result := B9600; // unbekannt: sinnvoller Default statt Fehler
    end;
  end;

// Termios-Attribute (Baudrate, Databits, Parity, Stopbits, "raw mode")
// gemaess der aktuellen Property-Werte auf den offenen fd anwenden.
procedure TComm.ApplyTermios;
  var
    tios: Termios;
    cs: cardinal;
  begin
    if not isOpen then Exit ;
    if TCGetAttr(fFd, tios) <> 0 then Exit ;

    cfmakeraw(tios) ; // keine Zeilenpufferung/Echo/Signalverarbeitung

    case fDataBits of
      5: cs := CS5;
      6: cs := CS6;
      7: cs := CS7;
      else cs := CS8;
    end;
    tios.c_cflag := (tios.c_cflag and not cardinal(CSIZE)) or cs ;

    case fParity of
      ODDPARITY:  tios.c_cflag := tios.c_cflag or PARENB or PARODD ;
      EVENPARITY: tios.c_cflag := (tios.c_cflag or PARENB) and not cardinal(PARODD) ;
      else        tios.c_cflag := tios.c_cflag and not cardinal(PARENB or PARODD) ;
      // MARKPARITY/SPACEPARITY: unter Linux nicht standardisiert ueber
      // termios abbildbar, werden wie NOPARITY behandelt.
    end;

    if fStopBits = TWOSTOPBITS then
      tios.c_cflag := tios.c_cflag or CSTOPB
    else
      tios.c_cflag := tios.c_cflag and not cardinal(CSTOPB) ;

    tios.c_cflag := tios.c_cflag or CREAD or CLOCAL ;

    // nicht-blockierendes Lesen: wir fragen InCount ab, bevor wir lesen
    tios.c_cc[VMIN] := 0 ;
    tios.c_cc[VTIME] := 0 ;

    CFSetISpeed(tios, BaudToSpeedConst(fBaud)) ;
    CFSetOSpeed(tios, BaudToSpeedConst(fBaud)) ;

    TCSetAttr(fFd, TCSANOW, tios) ;
  end{ "procedure TComm.ApplyTermios" } ;

// Opens the COM port, returns True if ok
function TComm.Open: boolean;
  begin
    // close port if open already
    if isOpen then Close;

    // try to open the port
    fFd := fpOpen(DeviceName, O_RDWR or O_NOCTTY or O_NONBLOCK) ;

    if fFd >= 0 then begin
      ApplyTermios ;
      setRtsOn(fRtsOn);
      setDtrOn(fDtrOn);
    end{ "if fFd >= 0" } ;

    // return True if port opened
    Result := isOpen;
  end{ "function TComm.Open" } ;

// Close the COM port
procedure TComm.Close;
  begin
    if isOpen then begin
      fpClose(fFd);
      fFd := -1;
    end;
  end;

// Write a char out the COM port
function TComm.WriteByte(ch: byte): boolean;
  begin
    Result := isOpen and (fpWrite(fFd, ch, sizeof(ch)) = sizeof(ch)) ;
  end;

function TComm.WriteData(var data; size: Integer): boolean;
  begin
    Result := isOpen and (fpWrite(fFd, data, size) = size) ;
  end;

// Reads a character from the port
function TComm.ReadByte(var b: byte): boolean ;
  begin
    result := false ;
    if isOpen then
      if getInCount > 0 then
        result := fpRead(fFd, b, 1) = 1 ;
  end{ "function TComm.ReadByte" } ;

function TComm.ReadData(var data; size: Integer): Integer;
  var
    cbCharsAvailable: LongInt;
    n: Int64;
  begin
    Result := 0;
    if isOpen then begin
      cbCharsAvailable := getInCount;
      if cbCharsAvailable > 0 then begin
        if cbCharsAvailable < size then
          size := cbCharsAvailable;
        n := fpRead(fFd, data, size) ;
        if n > 0 then
          Result := n ;
      end;
    end;
  end{ "function TComm.ReadData" } ;

// Return the number of bytes waiting in the input queue
function TComm.getInCount: LongInt;
  var
    n: cint;
  begin
    Result := 0;
    if isOpen then begin
      n := 0 ;
      if fpIOCtl(fFd, FIONREAD, @n) = 0 then
        Result := n ;
    end;
  end;

// Return the number of bytes waiting in the output queue
function TComm.getOutCount: LongInt;
  var
    n: cint;
  begin
    Result := 0;
    if isOpen then begin
      n := 0 ;
      if fpIOCtl(fFd, TIOCOUTQ, @n) = 0 then
        Result := n ;
    end;
  end;

// Flush the port by reading any characters in the queue
procedure TComm.Flush;
  begin
    if isOpen then
      fpIOCtl(fFd, TCFLSH, pointer(PtrInt(TCIOFLUSH))) ;
  end;

end{ "unit CommU" } .

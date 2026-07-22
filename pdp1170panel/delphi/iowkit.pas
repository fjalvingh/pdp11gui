//
// IO-Warrior kit library V1.5 include file
//
// Linux/Lazarus port: iowkit.dll is a Windows-only USB-HID driver DLL, no
// Linux equivalent exists (would need a libusb/hidraw-based reimplementation
// - see LINUX_PORT_TODO.md). LoadIowKitAPI() always returns false here,
// exactly like on Windows when the DLL/dongle isn't present - the app
// already has to handle that case gracefully (most users don't have the
// IO-Warrior USB dongle for the physical PDP-11/70 panel attached either).

unit iowkit;

interface

uses
  SysUtils;

const
  // IoWarrior vendor & product IDs
  IOWKIT_VENDOR_ID        = $07c0;
  IOWKIT_VID              = IOWKIT_VENDOR_ID;

  // IO-Warrior 40
  IOWKIT_PRODUCT_ID_IOW40 = $1500;
  IOWKIT_PID_IOW40        = IOWKIT_PRODUCT_ID_IOW40;

  // IO-Warrior 24
  IOWKIT_PRODUCT_ID_IOW24 = $1501;
  IOWKIT_PID_IOW24        = IOWKIT_PRODUCT_ID_IOW24;

  // IO-Warrior PowerVampire
  IOWKIT_PRODUCT_ID_IOWPV1 = $1511;
  IOWKIT_PID_IOWPV1        = IOWKIT_PRODUCT_ID_IOWPV1;
  IOWKIT_PRODUCT_ID_IOWPV2 = $1512;
  IOWKIT_PID_IOWPV2        = IOWKIT_PRODUCT_ID_IOWPV2;

  // IO-Warrior 56
  IOWKIT_PRODUCT_ID_IOW56  = $1503;
  IOWKIT_PID_IOW56         = IOWKIT_PRODUCT_ID_IOW56;

  // Max number of pipes per IOW device
  IOWKIT_MAX_PIPES   = 2;

  // pipe names
  IOW_PIPE_IO_PINS      = 0;
  IOW_PIPE_SPECIAL_MODE = 1;

  // Max number of IOW devices in system
  IOWKIT_MAX_DEVICES = 16;

  // IOW Legacy devices open modes
  IOW_OPEN_SIMPLE    = 1;
  IOW_OPEN_COMPLEX   = 2;

  // first IO-Warrior revision with serial numbers
  IOW_NON_LEGACY_REVISION = $1010;

type
  PIOWKIT_REPORT = ^IOWKIT_REPORT;
  IOWKIT_REPORT = packed record
    ReportID: Byte;
  case Boolean of
    False: (Value: DWORD;);
    True: (Bytes: array [0..3] of Byte;);
  end;

  PIOWKIT40_IO_REPORT = ^IOWKIT40_IO_REPORT;
  IOWKIT40_IO_REPORT = packed record
    ReportID: Byte;
  case Boolean of
    False: (Value: DWORD;);
    True: (Bytes: array [0..3] of Byte;);
  end;

  PIOWKIT24_IO_REPORT = ^IOWKIT24_IO_REPORT;
  IOWKIT24_IO_REPORT = packed record
    ReportID: Byte;
  case Boolean of
    False: (Value: WORD;);
    True: (Bytes: array [0..1] of Byte;);
  end;

  PIOWKIT_SPECIAL_REPORT = ^IOWKIT_SPECIAL_REPORT;
  IOWKIT_SPECIAL_REPORT = packed record
    ReportID: Byte;
    Bytes: array [0..6] of Byte;
  end;

  PIOWKIT56_IO_REPORT = ^IOWKIT56_IO_REPORT;
  IOWKIT56_IO_REPORT = packed record
    ReportID: Byte;
    Bytes: array [0..6] of Byte;
  end;

  PIOWKIT56_SPECIAL_REPORT = ^IOWKIT56_SPECIAL_REPORT;
  IOWKIT56_SPECIAL_REPORT = packed record
    ReportID: Byte;
    Bytes: array [0..62] of Byte;
  end;

const
  IOWKIT_REPORT_SIZE = SizeOf(IOWKIT_REPORT);
  IOWKIT40_IO_REPORT_SIZE = SizeOf(IOWKIT40_IO_REPORT);
  IOWKIT24_IO_REPORT_SIZE = SizeOf(IOWKIT24_IO_REPORT);
  IOWKIT_SPECIAL_REPORT_SIZE = SizeOf(IOWKIT_SPECIAL_REPORT);
  IOWKIT56_IO_REPORT_SIZE = SizeOf(IOWKIT56_IO_REPORT);
  IOWKIT56_SPECIAL_REPORT_SIZE = SizeOf(IOWKIT56_SPECIAL_REPORT);

type
  // waren Windows-Unit-Typen
  ULONG = Cardinal;
  BOOL = LongBool;

  // Opaque IO-Warrior handle
  IOWKIT_HANDLE = Pointer;

  TIowKitOpenDevice = function: IOWKIT_HANDLE;
  TIowKitCloseDevice = procedure(devHandle: IOWKIT_HANDLE);
  TIowKitWrite = function(devHandle: IOWKIT_HANDLE; numPipe: ULONG;
    buffer: PChar; length: ULONG): ULONG;
  TIowKitRead = function(devHandle: IOWKIT_HANDLE; numPipe: ULONG;
    buffer: PChar; length: ULONG): ULONG;
  TIowKitReadNonBlocking = function(devHandle: IOWKIT_HANDLE; numPipe: ULONG;
    buffer: PChar; length: ULONG): ULONG;
  TIowKitReadImmediate = function(devHandle: IOWKIT_HANDLE; var value: DWORD): BOOL;
  TIowKitGetNumDevs = function: ULONG;
  TIowKitGetDeviceHandle = function(numDevice: ULONG): IOWKIT_HANDLE;
  TIowKitSetLegacyOpenMode = function(legacyOpenMode: ULONG): BOOL;
  TIowKitGetProductId = function(devHandle: IOWKIT_HANDLE): ULONG;
  TIowKitGetRevision = function(devHandle: IOWKIT_HANDLE): ULONG;
  TIowKitGetThreadHandle = function(devHandle: IOWKIT_HANDLE): THandle;
  TIowKitGetSerialNumber = function(devHandle: IOWKIT_HANDLE; serialNumber: PWideChar): BOOL;
  TIowKitSetTimeout = function(devHandle: IOWKIT_HANDLE; timeout: ULONG): BOOL;
  TIowKitSetWriteTimeout = function(devHandle: IOWKIT_HANDLE; timeout: ULONG): BOOL;
  TIowKitCancelIo = function(devHandle: IOWKIT_HANDLE; numPipe: ULONG): BOOL;
  TIowKitVersion = function: PChar;

var
  IowKitOpenDevice: TIowKitOpenDevice;
  IowKitCloseDevice: TIowKitCloseDevice;
  IowKitWrite: TIowKitWrite;
  IowKitRead: TIowKitRead;
  IowKitReadNonBlocking: TIowKitReadNonBlocking;
  IowKitReadImmediate: TIowKitReadImmediate;
  IowKitGetNumDevs: TIowKitGetNumDevs;
  IowKitGetDeviceHandle: TIowKitGetDeviceHandle;
  IowKitSetLegacyOpenMode: TIowKitSetLegacyOpenMode;
  IowKitGetProductId: TIowKitGetProductId;
  IowKitGetRevision: TIowKitGetRevision;
  IowKitGetThreadHandle: TIowKitGetThreadHandle;
  IowKitGetSerialNumber: TIowKitGetSerialNumber;
  IowKitSetTimeout: TIowKitSetTimeout;
  IowKitSetWriteTimeout: TIowKitSetWriteTimeout;
  IowKitCancelIo: TIowKitCancelIo;
  IowKitVersion: TIowKitVersion;

// Immer "false": es gibt unter Linux keinen iowkit-Treiber (siehe oben).
function LoadIowKitAPI: Boolean;
procedure UnloadIowKitAPI;

implementation

function LoadIowKitAPI: Boolean;
  begin
    result := false;
  end;

procedure UnloadIowKitAPI;
  begin
  end;

end.

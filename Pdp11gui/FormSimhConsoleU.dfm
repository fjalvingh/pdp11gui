object FormSimhConsole: TFormSimhConsole
  Left = 0
  Top = 0
  Caption = 'SimH Console'
  ClientHeight = 517
  ClientWidth = 629
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clLime
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  PixelsPerInch = 96
  TextHeight = 13
  object ConsoleMemo: TMemo
    Left = 0
    Top = 0
    Width = 629
    Height = 517
    Align = alClient
    Color = clBlack
    Font.Charset = ANSI_CHARSET
    Font.Color = clLime
    Font.Height = -12
    Font.Name = 'Courier New'
    Font.Style = []
    ParentFont = False
    ScrollBars = ssVertical
    TabOrder = 0
    OnKeyDown = ConsoleMemoKeyDown
    OnKeyPress = ConsoleMemoKeyPress
  end
end

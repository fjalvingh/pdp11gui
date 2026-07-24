object FormSimhRemoteLog: TFormSimhRemoteLog
  Left = 0
  Top = 0
  Caption = 'SimH Remote Console Log'
  ClientHeight = 517
  ClientWidth = 629
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  PixelsPerInch = 96
  TextHeight = 13
  object LogMemo: TMemo
    Left = 0
    Top = 0
    Width = 629
    Height = 517
    Align = alClient
    Color = clBlack
    Font.Charset = ANSI_CHARSET
    Font.Color = clSilver
    Font.Height = -12
    Font.Name = 'Courier New'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssVertical
    TabOrder = 0
  end
end

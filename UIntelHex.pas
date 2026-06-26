unit uIntelHex;
// Intel HEX to BIN converter
// Copyright (c) 2004-2023
//
// Fixed version v4:
//   - Двухпроходная потоковая обработка без промежуточных буферов секций
//   - Txt2Bin: конкатенация строк заменена на конечный автомат O(N)
//   - HexCalcCheckSum: накопление в DWORD — нет падения при $OVERFLOWCHECKS ON
//   - HexStr2Rec: строгая проверка длины строки перед парсингом
//   - rtEsa (тип 02): бросает исключение вместо молчаливого игнорирования
//   - Ord() вместо BYTE() для TRecType везде
//
// Примечание о порядке строк:
//   Записи данных (rtData) могут идти в любом порядке.
//   Записи адреса (rtEla) обязаны предшествовать данным, которые они адресуют —
//   это фундаментальное ограничение формата Intel HEX.

interface

uses
  SysUtils, Classes, Windows;

const
  HEX_ERROR_MARKER        = 1;
  HEX_ERROR_ADDRESS       = 2;
  HEX_ERROR_REC_TYPE      = 3;
  HEX_ERROR_SECTION_SIZE  = 4;
  HEX_ERROR_DATA          = 5;
  HEX_ERROR_CHECK_SUM     = 6;
  HEX_ERROR_SECTION_COUNT = 7;

type
  EHex2Bin = class(Exception)
  private
    FCode: Integer;
  public
    constructor Create(ACode: Integer);
    property Code: Integer read FCode write FCode;
  end;

type
  TXxx2Bin = procedure(TxtStringList: TStringList; BinStream: TMemoryStream;
    var StartAddress: Int64);

// Конвертирует текстовый список строк с hex-данными в бинарный поток.
// Формат входных строк произвольный: байты могут быть разделены пробелами,
// запятыми, переносами строк, допускаются префиксы 0x/0X.
// Одиночные hex-символы без пары пропускаются.
// BinStream очищается перед записью. StartAddress всегда возвращается 0.
procedure Txt2Bin(TxtStringList: TStringList; BinStream: TMemoryStream;
  var StartAddress: Int64);

// Конвертирует Intel HEX (список строк) в бинарный поток.
// Двухпроходная обработка: проход 1 — определение диапазона адресов и
// проверка контрольных сумм всех записей; проход 2 — запись данных
// в нужные позиции потока. Дыры между секциями заполняются 0xFF.
// StartAddress возвращает абсолютный адрес первого байта данных.
// Поддерживаются типы записей: rtData, rtEof, rtEla, rtSsa, rtSla.
// rtEsa (тип 02) не поддерживается — бросает EHex2Bin(HEX_ERROR_REC_TYPE).
procedure Hex2Bin(HexStringList: TStringList; BinStream: TMemoryStream;
  var StartAddress: Int64);

// Конвертирует бинарный поток в Intel HEX (список строк).
// StartAddress задаёт абсолютный адрес первого байта потока.
// Данные разбиваются на записи по ONE_RECORD_SIZE (16) байт.
// При пересечении 64K-границы автоматически вставляется запись
// Extended Linear Address (rtEla). Список строк не очищается перед записью.
procedure Bin2Hex(BinStream: TMemoryStream; HexStringList: TStringList;
  StartAddress: Int64);

// Обёртка над Hex2Bin для работы непосредственно с файлом на диске.
// Загружает HEX-файл HexFileName в TStringList и вызывает Hex2Bin.
// BinStream и StartAddress — см. описание Hex2Bin.
procedure Hex2BinFile(const HexFileName: string; BinStream: TMemoryStream;
  var StartAddress: Int64);

// Обёртка над Bin2Hex для работы непосредственно с файлом на диске.
// Вызывает Bin2Hex, затем сохраняет результат в HEX-файл HexFileName.
// BinStream и StartAddress — см. описание Bin2Hex.
procedure Bin2HexFile(BinStream: TMemoryStream; const HexFileName: string;
  StartAddress: Int64);

{$IFDEF VER150} // Delphi 7
function CharInSet(C: AnsiChar; const CharSet: TSysCharSet): Boolean; overload;
function CharInSet(C: WideChar; const CharSet: TSysCharSet): Boolean; overload;
{$ENDIF}

implementation

const
  ONE_RECORD_SIZE = 16;

type
  TRecType = (
    rtData = 0,
    rtEof  = 1,
    rtEsa  = 2,
    rtSsa  = 3,
    rtEla  = 4,
    rtSla  = 5
  );

  THexRec = record
    DataSize: BYTE;
    Addr:     Word;
    RecType:  TRecType;
    DataBuf:  array [0..255] of BYTE;
    CheckSum: BYTE;
  end;

var
  Hex2BinErrorMessage: array [HEX_ERROR_MARKER..HEX_ERROR_SECTION_COUNT] of string;

{ EHex2Bin }

constructor EHex2Bin.Create(ACode: Integer);
begin
  FCode := ACode;
  inherited Create(Hex2BinErrorMessage[ACode]);
end;

{$IFDEF VER150}
function CharInSet(C: AnsiChar; const CharSet: TSysCharSet): Boolean;
begin
  Result := C in CharSet;
end;

function CharInSet(C: WideChar; const CharSet: TSysCharSet): Boolean;
begin
  Result := (C < #$0100) and (AnsiChar(C) in CharSet);
end;
{$ENDIF}

function HexCalcCheckSum(const HexRec: THexRec): BYTE;
var
  i:   Integer;
  Sum: DWORD;
begin
  Sum := HexRec.DataSize
       + BYTE(HexRec.Addr)
       + BYTE(HexRec.Addr shr 8)
       + DWORD(Ord(HexRec.RecType));
  for i := 0 to HexRec.DataSize - 1 do
    Inc(Sum, HexRec.DataBuf[i]);
  Result := BYTE((not BYTE(Sum)) + 1);
end;

// FIX: Ord() вместо BYTE() для RecType
function HexRec2Str(const HexRec: THexRec): string;
var
  i: Integer;
begin
  Result := ':' + IntToHex(HexRec.DataSize, 2)
              + IntToHex(HexRec.Addr, 4)
              + IntToHex(Ord(HexRec.RecType), 2);
  for i := 0 to HexRec.DataSize - 1 do
    Result := Result + IntToHex(HexRec.DataBuf[i], 2);
  Result := Result + IntToHex(HexCalcCheckSum(HexRec), 2);
end;

// FIX: строгая проверка длины строки перед каждым Copy/StrToInt
function HexStr2Rec(const HexStr: string): THexRec;
var
  i:        Integer;
  MinLen:   Integer;
begin
  // Минимальная длина строки: 1(':')+2(size)+4(addr)+2(type)+2(CS) = 11
  if (Length(HexStr) < 11) or (HexStr[1] <> ':') then
    raise EHex2Bin.Create(HEX_ERROR_MARKER);
  try
    Result.DataSize := StrToInt('$' + Copy(HexStr, 2, 2));
    Result.Addr     := StrToInt('$' + Copy(HexStr, 4, 4));
    Result.RecType  := TRecType(StrToInt('$' + Copy(HexStr, 8, 2)));
    // Полная длина строки: 11 + DataSize*2 символов данных
    MinLen := 11 + Result.DataSize * 2;
    if Length(HexStr) < MinLen then
      raise EHex2Bin.Create(HEX_ERROR_DATA);
    for i := 0 to Result.DataSize - 1 do
      Result.DataBuf[i] := StrToInt('$' + Copy(HexStr, 10 + i * 2, 2));
    Result.CheckSum := StrToInt('$' + Copy(HexStr, 10 + Result.DataSize * 2, 2));
  except
    on E: EHex2Bin do raise;
    else raise EHex2Bin.Create(HEX_ERROR_DATA);
  end;
  if Result.CheckSum <> HexCalcCheckSum(Result) then
    raise EHex2Bin.Create(HEX_ERROR_CHECK_SUM);
end;

function CalcAbsAddr(LinearAddress: DWORD; RecAddr: Word): Int64;
begin
  Result := Int64(LinearAddress) shl 16 + RecAddr;
end;

{ ============================================================
  Bin2Hex
  ============================================================ }
procedure Bin2Hex(BinStream: TMemoryStream; HexStringList: TStringList;
  StartAddress: Int64);
var
  HexRec:      THexRec;
  BufferSize:  DWORD;
  SectionSize: DWORD;
  RecordSize:  DWORD;
  SectionAddr: DWORD;
  LinearAddr:  DWORD;
begin
  SectionAddr := 0;
  LinearAddr  := 0;
  BufferSize  := BinStream.Size;
  SectionSize := BufferSize;
  BinStream.Seek(0, soBeginning);

  while BufferSize > 0 do
  begin
    if (StartAddress <> 0) or (SectionSize = 0) then
    begin
      if StartAddress <> 0 then
      begin
        SectionAddr  := DWORD(StartAddress) and $FFFF;
        SectionSize  := $10000 - SectionAddr;
        LinearAddr   := DWORD(StartAddress) shr 16;
        StartAddress := 0;
      end
      else
      begin
        SectionAddr := 0;
        SectionSize := BufferSize;
        Inc(LinearAddr);
      end;
      HexRec.DataSize   := 2;
      HexRec.Addr       := 0;
      HexRec.RecType    := rtEla;
      HexRec.DataBuf[0] := LinearAddr shr 8;
      HexRec.DataBuf[1] := LinearAddr and $FF;
      HexStringList.Add(HexRec2Str(HexRec));
    end
    else
    begin
      RecordSize := SectionSize;
      if RecordSize > ONE_RECORD_SIZE then
        RecordSize := ONE_RECORD_SIZE;
      HexRec.DataSize := RecordSize;
      HexRec.Addr     := SectionAddr;
      HexRec.RecType  := rtData;
      BinStream.Read(HexRec.DataBuf[0], RecordSize);
      HexStringList.Add(HexRec2Str(HexRec));
      Inc(SectionAddr, RecordSize);
      Dec(SectionSize, RecordSize);
      Dec(BufferSize,  RecordSize);
    end;
  end;

  HexRec.DataSize := 0;
  HexRec.Addr     := 0;
  HexRec.RecType  := rtEof;
  HexStringList.Add(HexRec2Str(HexRec));
end;

{ ============================================================
  Hex2Bin — двухпроходная потоковая обработка.

  Проход 1: определяем диапазон адресов, проверяем CS всех строк.
  Проход 2: Seek(absAddr - StartAddr) + Write для каждой rtData.
  ============================================================ }
procedure Hex2Bin(HexStringList: TStringList; BinStream: TMemoryStream;
  var StartAddress: Int64);
var
  i:             Integer;
  HexRec:        THexRec;
  LinearAddress: DWORD;
  AbsAddr:       Int64;
  EndAddress:    Int64;
  FillBuf:       array [0..255] of BYTE;
  BytesLeft:     Int64;
  ChunkSize:     Integer;
begin
  // ---- Проход 1: диапазон адресов ----
  LinearAddress := 0;
  StartAddress  := -1;
  EndAddress    := 0;

  for i := 0 to HexStringList.Count - 1 do
  begin
    HexRec := HexStr2Rec(HexStringList[i]);
    case HexRec.RecType of
      rtEof:
        Break;
      rtEsa:
        raise EHex2Bin.Create(HEX_ERROR_REC_TYPE);
      rtSsa, rtSla:
        Continue;
      rtEla:
        LinearAddress := DWORD(HexRec.DataBuf[0]) shl 8 + HexRec.DataBuf[1];
      rtData:
        begin
          AbsAddr := CalcAbsAddr(LinearAddress, HexRec.Addr);
          if (StartAddress = -1) or (AbsAddr < StartAddress) then
            StartAddress := AbsAddr;
          AbsAddr := CalcAbsAddr(LinearAddress, HexRec.Addr) + HexRec.DataSize;
          if AbsAddr > EndAddress then
            EndAddress := AbsAddr;
        end;
    end;
  end;

  if StartAddress = -1 then
  begin
    BinStream.Clear;
    StartAddress := 0;
    Exit;
  end;

  // ---- Подготовка BinStream: нужный размер, заполнен 0xFF ----
  BinStream.Clear;
  BinStream.SetSize(EndAddress - StartAddress);

  FillChar(FillBuf, SizeOf(FillBuf), $FF);
  BinStream.Seek(0, soBeginning);
  BytesLeft := EndAddress - StartAddress;
  while BytesLeft > 0 do
  begin
    if BytesLeft > SizeOf(FillBuf) then
      ChunkSize := SizeOf(FillBuf)
    else
      ChunkSize := BytesLeft;
    BinStream.Write(FillBuf[0], ChunkSize);
    Dec(BytesLeft, ChunkSize);
  end;

  // ---- Проход 2: пишем данные на правильные позиции ----
  LinearAddress := 0;

  for i := 0 to HexStringList.Count - 1 do
  begin
    HexRec := HexStr2Rec(HexStringList[i]);
    case HexRec.RecType of
      rtEof:
        Break;
      rtEsa:
        raise EHex2Bin.Create(HEX_ERROR_REC_TYPE);
      rtSsa, rtSla:
        Continue;
      rtEla:
        LinearAddress := DWORD(HexRec.DataBuf[0]) shl 8 + HexRec.DataBuf[1];
      rtData:
        begin
          AbsAddr := CalcAbsAddr(LinearAddress, HexRec.Addr);
          BinStream.Seek(AbsAddr - StartAddress, soBeginning);
          BinStream.Write(HexRec.DataBuf[0], HexRec.DataSize);
        end;
    end;
  end;
end;

{ ============================================================
  HexStr2Int — вспомогательная для Txt2Bin
  ============================================================ }
function HexVal(C: Char): Integer; inline;
begin
  case C of
    '0'..'9': Result := Ord(C) - Ord('0');
    'A'..'F': Result := Ord(C) - Ord('A') + 10;
    'a'..'f': Result := Ord(C) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

{ ============================================================
  Txt2Bin
  ============================================================ }
procedure Txt2Bin(TxtStringList: TStringList; BinStream: TMemoryStream;
  var StartAddress: Int64);
var
  Line:      string;
  LineIdx:   Integer;
  CharIdx:   Integer;
  Hi, Lo:    Integer;
  AByte:     BYTE;
  C:         Char;
begin
  BinStream.Clear;
  StartAddress := 0;

  for LineIdx := 0 to TxtStringList.Count - 1 do
  begin
    Line   := TxtStringList[LineIdx];
    CharIdx := 1;

    while CharIdx <= Length(Line) do
    begin
      C  := Line[CharIdx];
      Hi := HexVal(C);

      // Не hex-символ — пропускаем
      if Hi < 0 then
      begin
        Inc(CharIdx);
        Continue;
      end;

      // Защита от выхода за конец строки
      if CharIdx + 1 > Length(Line) then
        Break;

      // Пропуск префикса 0x / 0X
      if (C = '0') and
         ((Line[CharIdx + 1] = 'x') or (Line[CharIdx + 1] = 'X')) then
      begin
        Inc(CharIdx, 2);
        Continue;
      end;

      Lo := HexVal(Line[CharIdx + 1]);

      // Второй символ не hex — пропускаем первый
      if Lo < 0 then
      begin
        Inc(CharIdx);
        Continue;
      end;

      AByte := BYTE(Hi shl 4 or Lo);
      BinStream.Write(AByte, 1);
      Inc(CharIdx, 2);
    end;
  end;
end;

{ ============================================================
  Hex2BinFile — обёртка над Hex2Bin для работы с файлом
  ============================================================ }
procedure Hex2BinFile(const HexFileName: string; BinStream: TMemoryStream;
  var StartAddress: Int64);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.LoadFromFile(HexFileName);
    Hex2Bin(SL, BinStream, StartAddress);
  finally
    SL.Free;
  end;
end;

{ ============================================================
  Bin2HexFile — обёртка над Bin2Hex для работы с файлом
  ============================================================ }
procedure Bin2HexFile(BinStream: TMemoryStream; const HexFileName: string;
  StartAddress: Int64);
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    Bin2Hex(BinStream, SL, StartAddress);
    SL.SaveToFile(HexFileName);
  finally
    SL.Free;
  end;
end;

initialization

Hex2BinErrorMessage[HEX_ERROR_MARKER]        := 'Error Marker';
Hex2BinErrorMessage[HEX_ERROR_ADDRESS]       := 'Error Address';
Hex2BinErrorMessage[HEX_ERROR_REC_TYPE]      := 'Error Type';
Hex2BinErrorMessage[HEX_ERROR_SECTION_SIZE]  := 'Error Section Size';
Hex2BinErrorMessage[HEX_ERROR_DATA]          := 'Error Data';
Hex2BinErrorMessage[HEX_ERROR_CHECK_SUM]     := 'Error CheckSum';
Hex2BinErrorMessage[HEX_ERROR_SECTION_COUNT] := 'Error Section Count';

end.

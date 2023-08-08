unit uIntelHex;

interface

uses
  SysUtils, Classes, Windows;

const
  HEX_ERROR_MARKER = 1; // ������: �������� ������ ������
  HEX_ERROR_ADDRESS = 2; // ������: �������� ����� ������
  HEX_ERROR_REC_TYPE = 3; // ������: �������� ��� ������
  HEX_ERROR_SECTION_SIZE = 4; // ������: �������� ������ ������
  HEX_ERROR_DATA = 5; // ������: ������������ ������ ������
  HEX_ERROR_CHECK_SUM = 6; // ������: �������� ����������� ����� ������
  HEX_ERROR_SECTION_COUNT = 7; // ������: ��������� ������������ ���������� ������

type
  EHex2Bin = class(Exception)
  private
    FCode: integer; // ��� ������
  public
    constructor Create(ACode: integer); // ������� ���������� � ��������� ����� ������
    property Code: integer read FCode write FCode; // �������� ��� ������ � ������ ���� ������
  end;

//TxtStringList: TStringList - ������ �����, ���������� ������ � ������� X.
//BinStream: TMemoryStream - �����, � ������� ����� �������� ������ � ������� BIN.
//StartAddress: int64 - ��������� ����� ������. ���� �������� ����� �������������� � �������� �����������,
//  ���� ��������� ������� ������������ ����� ������ ������.
type
  TXxx2Bin = procedure( TxtStringList : TStringList; BinStream : TMemoryStream;
    var StartAddress : int64 );

// ����������� ������ ����� `TxtStringList`, ���������� ��������� ����������, � �������� ������ � ���������� �� � `BinStream`.
// �������� `StartAddress` ��������� ��������� �����, ������� ����� �������������� ��� ��������������.
procedure Txt2Bin(TxtStringList: TStringList; BinStream: TMemoryStream; var StartAddress: Int64);

// ����������� ������ ����� `HexStringList`, ���������� ����������������� ������, � �������� ������ � ���������� �� � `BinStream`.
// �������� `StartAddress` ��������� ��������� �����, ������� ����� �������������� ��� ��������������.
procedure Hex2Bin(HexStringList: TStringList; BinStream: TMemoryStream; var StartAddress: Int64);

// ����������� �������� ������ �� `BinStream`, �������������� � ���� ������ ������, � ����������������� ������ � ��������� �� � ������ ����� `HexStringList`.
// �������� `StartAddress` ��������� ��������� ����� ������.
procedure Bin2Hex(BinStream: TMemoryStream; HexStringList: TStringList; StartAddress: Int64);

{$IFDEF VER150} //Delphi 7
// ������� CharInSet: ���������, ����������� �� ������ C ���������� ������ �������� CharSet.
// ����������� ��� ��������� AnsiChar � WideChar.
function  CharInSet(C : AnsiChar; const CharSet : TSysCharSet) : Boolean; overload;
function  CharInSet(C : WideChar; const CharSet : TSysCharSet) : Boolean; overload;
{$ENDIF}

implementation

const
  ONE_RECORD_SIZE = 16; // ������ ����� ������ � ������� Intel .hex �����
  ONE_SECTION_SIZE = 64 * 1024; // ������ ����� ������ (����� ������)
  MAX_SECTION_COUNT = 16; // ������������ ���������� ������
  MAX_BUFFER_SIZE = MAX_SECTION_COUNT * ONE_SECTION_SIZE; // ������������ ������ ������ ������

type
  // ��������� ���� ������� ��� ������ ������� Intel .hex
  TRecType = (
    rtData = 0, // ������
    rtEof = 1, // ����� �����
    rtEsa = 2, // ����������� ����� ��������
    rtSsa = 3, // ��������� ����� ��������
    rtEla = 4, // ����������� �������� �����
    rtSla = 5 // ��������� �������� �����
  );

  THexRec = record
    Marker: BYTE; // ������ ������ (':') - ��������, ������ - ����������
    DataSize: BYTE; // ������ ������
    Addr: Word; // �����
    RecType: TRecType; // ��� ������
    DataBuf: array [0 .. 255] of BYTE; // ����� ������
    CheckSum: BYTE; // ����������� �����
  end;

  THexSection = record
    LinearAddress: DWORD; // �������� ����� ������
    UsedOffset: DWORD; // ������������ �������� � ������
    UnusedOffset: DWORD; // �������������� �������� � ������
    DataBuffer: array [0 .. ONE_SECTION_SIZE - 1] of BYTE; // ����� ������ ������
  end;

var
  HexSections: array [0 .. MAX_SECTION_COUNT - 1] of THexSection; // ������ ������ ������
  Hex2BinErrorMessage: array [HEX_ERROR_MARKER .. HEX_ERROR_SECTION_COUNT] of string; // ������ ��������� �� �������

{ ����������� EHex2Bin }
constructor EHex2Bin.Create( ACode : integer );
begin
  FCode := ACode;
  inherited Create( Hex2BinErrorMessage[ ACode ] );
end;

{$IFDEF VER150} //Delphi 7
// ������� CharInSet(C: AnsiChar; const CharSet: TSysCharSet): Boolean;
// ���������, ����������� �� ������ C ���������� ��������� CharSet ���� TSysCharSet.
// ���������� True, ���� ������ ������������ � ��������� CharSet, ����� ���������� False.
function CharInSet(C: AnsiChar; const CharSet: TSysCharSet): Boolean;
begin
  Result := C in CharSet;
end;

// ������� CharInSet(C: WideChar; const CharSet: TSysCharSet): Boolean;
// ���������, ����������� �� ������ C ���������� ��������� CharSet ���� TSysCharSet.
// ���������� True, ���� ������ ������������ � ��������� CharSet, ����� ���������� False.
function CharInSet(C: WideChar; const CharSet: TSysCharSet): Boolean;
begin
  Result := (C < #$0100) and (AnsiChar(C) in CharSet);
end;
{$ENDIF}

// : 10 0013 00 AC12AD13AE10AF1112002F8E0E8F0F22 44
// \_________________________________________/ CS
//
// The checksum is calculated by summing the values of all hexadecimal digit
// pairs in the record modulo 256  and taking the two's complement
// ������� HexCalcCheckSum ��������� ����������� ����� ��� ������ � ����������������� ������� (��������� THexRec).
// ���������� ����������� ����� � ���� �����.
function HexCalcCheckSum(HexRec: THexRec): BYTE;
var
  i: integer;
begin
  // ������������� ���������� ������������� ������� ������, ������ � ���� ������
  Result := HexRec.DataSize + HexRec.Addr + (HexRec.Addr shr 8) + BYTE(HexRec.RecType);
  // ��������� �������� ���� ������ ������
  for i := 0 to HexRec.DataSize - 1 do
    Inc(Result, HexRec.DataBuf[i]);
  // ��������� �������� ���������� (Two's complement) � ����������
  Result := (not Result) + 1;
end;

// ������� HexRec2Str ����������� ��������� THexRec � ������, ��������������� ������� ������ � ����������������� �������.
// ���������� ������, �������������� �������� �� ��������� THexRec.
function HexRec2Str(HexRec: THexRec): string;
var
  i: integer;
begin
  Result := ':' + IntToHex(HexRec.DataSize, 2) + IntToHex(HexRec.Addr, 4) +
    IntToHex(Ord(HexRec.RecType), 2);
  // ����������� ����� ������ � ����������������� ������������� � ��������� �� � ������
  for i := 0 to HexRec.DataSize - 1 do
    Result := Result + IntToHex(HexRec.DataBuf[i], 2);
  // ��������� � ��������� ����������� ����� � ������
  Result := Result + IntToHex( HexRec.DataBuf[ i ], 2 );
  // ���������� �������������� ������
  Result := Result + IntToHex( HexCalcCheckSum( HexRec ), 2 )
end;

// 1 23 4567 89 ABCDEF.............................
// : 10 0013 00 AC12AD13AE10AF1112002F8E0E8F0F22 44
// ������� HexStr2Rec ����������� ������ HexStr � ��������� THexRec.
// ������ HexStr ������ ��������������� ������� ������ � ����������������� �������, ��� ������� � �����������.
// ������� ���������� ��������� THexRec, ���������� ����������� �������� �� ������.
function HexStr2Rec(HexStr: string): THexRec;
var
  i: integer;
begin
  Result.Marker := Ord(HexStr[1]);
  // ���������, ��� ������ ������ ������ �������� �������� ������ ������ ':'
  if Result.Marker <> Ord(':') then
    raise EHex2Bin.Create(HEX_ERROR_MARKER);
  try
    // ��������� ������ ������, ����� � ��� ������ �� ���������� �������������
    Result.DataSize := StrToInt('$' + Copy(HexStr, 2, 2));
    Result.Addr := StrToInt('$' + Copy(HexStr, 4, 4));
    Result.RecType := TRecType(StrToInt('$' + Copy(HexStr, 8, 2)));
    // ��������� ����� ������ �� ������ � ��������� ����� ������ � ��������� THexRec
    for i := 0 to Result.DataSize - 1 do
      Result.DataBuf[i] := StrToInt('$' + Copy(HexStr, 10 + i * 2, 2));
    // ��������� ����������� ����� �� ������
    Result.CheckSum := StrToInt('$' + Copy(HexStr, 10 + Result.DataSize * 2, 2));
  except
    raise EHex2Bin.Create(HEX_ERROR_DATA);
  end;
  // ��������� ������������ ����������� �����
  if Result.CheckSum <> HexCalcCheckSum(Result) then
    raise EHex2Bin.Create(HEX_ERROR_CHECK_SUM);
  // ���������� ����������� ��������� THexRec
end;

// ��������� Bin2Hex ��������� ����������� ������ �� ������� BIN � ������ HEX.
// ��� ��������� ������ �� BinStream � ���������� �� � HexStringList � ���� ����� � ������� HEX.
// �������� StartAddress ���������� ��������� ����� ������ � �������� �����������.
procedure Bin2Hex(BinStream: TMemoryStream; HexStringList: TStringList;
  StartAddress: int64);
var
  HexRec: THexRec;      // ���������, �������������� ������ ������� Intel Hex
  BufferSize: DWORD;    // ������ ������ (������ �������� ������ ������)
  SectionSize: DWORD;   // ������ ������� ������ ������
  RecordSize: DWORD;    // ������ ������� ������ ������
  SectionAddr: DWORD;   // ����� ������ ������� ������
  LinearAddr: DWORD;    // �������� �����
begin
  SectionAddr := 0;     // ��������� ����� ������ (�������������)
  LinearAddr := 0;      // ��������� �������� ����� (�������������)
  BufferSize := BinStream.Size;     // �������� ������ �������� ������ ������
  SectionSize := BufferSize;        // ������ ������ ������ ����� ������� �������� ������ ������
  BinStream.Seek(0, soBeginning);   // ������������� ��������� � ������ �������� ������ ������
  while BufferSize > 0 do
  begin
    // ������ ������������ ��������� ������ (rtEla)
    if (StartAddress <> 0) or (SectionSize = 0) then
    begin
      if (StartAddress <> 0) then    // ���� ��� ������ ������
      begin
        SectionAddr := StartAddress and (ONE_SECTION_SIZE - 1);   // ��������� ����� ������ ������
        SectionSize := ONE_SECTION_SIZE - SectionAddr;            // ��������� ������ ������
        LinearAddr := StartAddress shr 16;                        // ��������� �������� �����
        StartAddress := 0;                                        // ���������� ��������� ����� � 0
      end
      else    // ���� ������ ������ ����� 0
      begin
        SectionAddr := 0;               // ���������� ����� ������ � 0
        SectionSize := BufferSize;      // ������ ������ ����� ������� ���������� ������
        LinearAddr := LinearAddr + 1;   // ����������� �������� ����� �� 1
      end;
      HexRec.DataSize := 2;                                 // ������ ������ ������ (2 �����)
      HexRec.Addr := 0;                                     // ����� ������ (0)
      HexRec.RecType := rtEla;                              // ��� ������ (����������� �������� �����)
      HexRec.DataBuf[0] := LinearAddr shr 8;                 // ���� ������ - ������� ���� ��������� ������
      HexRec.DataBuf[1] := LinearAddr and $FF;               // ���� ������ - ������� ���� ��������� ������
      HexStringList.Add(HexRec2Str(HexRec));                 // ����������� ������ � ������ � ��������� � ������
    end
    else    // ������ ������ (rtData)
    begin
      RecordSize := SectionSize;                            // ������ ������ ������ ����� ������� ������� ������
      if RecordSize > ONE_RECORD_SIZE then                  // ���� ������ ������ ��������� ������������ ������ ������
        RecordSize := ONE_RECORD_SIZE;                      // ������������ ������ ������ �� �������������
      HexRec.DataSize := RecordSize;                        // ������ ������ ������
      HexRec.Addr := SectionAddr;                           // ����� ������ (����� ������ ������)
      HexRec.RecType := rtData;                             // ��� ������ (������)
      BinStream.Read(HexRec.DataBuf[0], RecordSize);         // ������ ������ �� �������� ������ � ����� ������ ������
      HexStringList.Add(HexRec2Str(HexRec));                 // ����������� ������ � ������ � ��������� � ������
      SectionAddr := SectionAddr + RecordSize;               // ����������� ����� ������ ������ �� ������ ������
      SectionSize := SectionSize - RecordSize;               // ��������� ������ ������� ������ �� ������ ������
      BufferSize := BufferSize - RecordSize;                 // ��������� ������ ������ �� ������ ������
    end;
  end;
  // ������ ��������� ����� (rtEof) :00000001FF
  HexRec.DataSize := 0;       // ������ ������ ������ (0)
  HexRec.Addr := 0;           // ����� ������ (0)
  HexRec.RecType := rtEof;    // ��� ������ (��������� �����)
  HexStringList.Add(HexRec2Str(HexRec));   // ����������� ������ � ������ � ��������� � ������
end;

// ��������� Hex2Bin ��������� ����������� ������ �� ������� HEX � ������ BIN.
// ��� ��������� ������ �� HexStringList � ���� ����� � ������� HEX � ���������� �� � BinStream � ���� �������� ������.
// �������� StartAddress ���������� ��������� ����� ������ � �������� �����������.
procedure Hex2Bin(HexStringList: TStringList; BinStream: TMemoryStream;
  var StartAddress: int64);
var
  i: integer;
  LastAddress: int64;
  HexRec: THexRec;                 // ���������, �������������� ������ ������� Intel Hex
  SectionFreeAddr: DWORD;          // ��������� ����� � ������ ������
  SectionIndex: DWORD;             // ������ ������� ������
  SizeToWrite: DWORD;              // ������ ������ ��� ������
  BufferToWrite: Pointer;          // ����� ������ ��� ������
  LinearAddress: DWORD;            // �������� �����
  FirstLinearAddr: DWORD;          // ������ �������� �����
  LastLinearAddr: DWORD;           // ��������� �������� �����
  FirstUsedDataOffset: DWORD;      // �������� ������� ��������������� ����� ������
  LastUnusedDataOffset: DWORD;     // �������� ���������� ����������������� ����� ������
begin
  // ������������� ���� ������ � ������ ������
  for i := 0 to MAX_SECTION_COUNT - 1 do
  begin
    HexSections[i].LinearAddress := $0000;                      // �������� �������� �����
    HexSections[i].UnusedOffset := $0000;                       // �������� �������� ����������������� ����� ������
    HexSections[i].UsedOffset := ONE_SECTION_SIZE;              // ������������� �������� ������� ��������������� ����� ������ � ������ ������
    FillChar(HexSections[i].DataBuffer[0], ONE_SECTION_SIZE, $FF);   // ��������� ����� ������ ���������
  end;
  SectionIndex := 0;
  for i := 0 to HexStringList.Count - 1 do
  begin
    HexRec := HexStr2Rec(HexStringList[i]);                      // ����������� ������ � ������ ������� Intel Hex
    case HexRec.RecType of
      rtEof:
        break;                                                   // ���� ������ �������� ���������� �����, ������� �� �����
      rtSsa, rtEsa, rtSla:
        continue;                                                // ���������� ������, ��������� � ��������
      rtEla:
        begin
          LinearAddress := HexRec.DataBuf[0] * 256 + HexRec.DataBuf[1];   // �������� �������� ����� �� ������
          if HexSections[SectionIndex].LinearAddress <> LinearAddress then
          begin
            if (i <> 0) then
              SectionIndex := SectionIndex + 1;                  // ����������� ������ ������ ��� ��������� ��������� ������
            if (SectionIndex = MAX_SECTION_COUNT) then
              raise EHex2Bin.Create(HEX_ERROR_SECTION_COUNT);     // ���� ���������� ������ ��������� ����������� ����������, �������� ����������

            HexSections[SectionIndex].LinearAddress := LinearAddress;   // ���������� �������� ����� � ������� ������
          end;
        end;
      rtData:
        begin
          SectionFreeAddr := HexRec.Addr + HexRec.DataSize;     // ��������� ��������� ����� � ������� ������
          if SectionFreeAddr > ONE_SECTION_SIZE then
            raise EHex2Bin.Create(HEX_ERROR_SECTION_SIZE);       // ���� ��������� ����� ��������� ������ ������, �������� ����������
          if HexSections[SectionIndex].UnusedOffset < SectionFreeAddr then
            HexSections[SectionIndex].UnusedOffset := SectionFreeAddr;   // ��������� �������� ����������������� ����� ������ � ������� ������
          if HexSections[SectionIndex].UsedOffset > HexRec.Addr then
            HexSections[SectionIndex].UsedOffset := HexRec.Addr;     // ��������� �������� ������� ��������������� ����� ������ � ������� ������
          CopyMemory(@HexSections[SectionIndex].DataBuffer[HexRec.Addr],
            @HexRec.DataBuf[0], HexRec.DataSize);               // �������� ������ �� ������ � ����� ������ ������
        end;
    end;
  end;

  FirstLinearAddr := $10000;         // �������������� ������ �������� ����� ��������� $10000
  LastLinearAddr := 0;               // �������������� ��������� �������� ����� ��������� 0
  FirstUsedDataOffset := 0;          // �������������� �������� ������� ��������������� ����� ������ ��������� 0
  LastUnusedDataOffset := ONE_SECTION_SIZE;   // �������������� �������� ���������� ����������������� ����� ������ ��������� ������� ����� ������
  // ����������� ������� � ���������� �������� �������, � ����� �������� ������� ��������������� � ���������� ����������������� ������ ������
  for i := 0 to SectionIndex do
  begin
    // ��������� ������� �������� ����� � ��������� ��������� �������� �������
    if HexSections[i].LinearAddress > LastLinearAddr then
    begin
      LastLinearAddr := HexSections[i].LinearAddress;        // ��������� ��������� �������� �����
      LastUnusedDataOffset := HexSections[i].UnusedOffset;   // ��������� �������� ���������� ����������������� ����� ������
    end;

    // ��������� ������� �������� ����� � ������ ��������� �������� �������
    if HexSections[i].LinearAddress < FirstLinearAddr then
    begin
      FirstLinearAddr := HexSections[i].LinearAddress;       // ��������� ������ �������� �����
      FirstUsedDataOffset := HexSections[i].UsedOffset;      // ��������� �������� ������� ��������������� ����� ������
    end;
  end;
  StartAddress := DWORD(FirstLinearAddr) shl 16;
  StartAddress := StartAddress + FirstUsedDataOffset;         // ��������� ���������� ������
  LastAddress := DWORD(LastLinearAddr) shl 16;
  LastAddress := LastAddress + LastUnusedDataOffset;          // ���������� ���������� ������
  BinStream.Clear;
  BinStream.SetSize(LastAddress - StartAddress);              // ��������� ������� ��������� ������
  // ������ ������ ������ � �������� ����� (������� ���������������� ������)
  for i := 0 to SectionIndex do
  begin
    if HexSections[i].LinearAddress = FirstLinearAddr then
    begin
      SizeToWrite := ONE_SECTION_SIZE - HexSections[i].UsedOffset;
      if SizeToWrite > BinStream.Size then
        SizeToWrite := BinStream.Size;

      BufferToWrite := @HexSections[i].DataBuffer
        [HexSections[i].UsedOffset];                          // ����������� ������ ������ ��� ������ ��� ������ �������������� ������
    end
    else if HexSections[i].LinearAddress = LastLinearAddr then
    begin
      SizeToWrite := HexSections[i].UnusedOffset;
      BufferToWrite := @HexSections[i].DataBuffer[0];          // ����������� ������ ������ ��� ������ ��� ��������� ���������������� ������
    end
    else
    begin
      SizeToWrite := ONE_SECTION_SIZE;
      BufferToWrite := @HexSections[i].DataBuffer[0];          // ����������� ������ ������ ��� ������ ��� ��������� ������
    end;
    BinStream.Write(BufferToWrite^, SizeToWrite);              // ������ ������ � �������� �����
  end;

end;

// ������� HexStr2Int ����������� ������ ��� ������� ������ HexStr � ����� � ����������������� �������.
// ���� �������������� �������, ��������� ������������ ����� ���������� AByte, � ������� ���������� TRUE.
// � ��������� ������, ���� ������ �� �������� ���������� ������������� ������������������ �����, ������� ���������� FALSE.
function HexStr2Int(HexStr: PChar; var AByte: BYTE): boolean;
begin
  Result := FALSE;
  // ���������, ���������� �� ������ � ������� '0'
  // ���� ��, �� ��������� ��������� ������, ����� ���������, ��� ��� �� ������� '0x' ��� '0X'
  if (HexStr[0] = '0') then
  begin
    if ((HexStr[1] = 'x') or (HexStr[1] = 'X')) then
      Exit;
  end;
  // ���������, �������� �� ������ ������ ������ ���������� �������� ����������������� �����
  if CharInSet(HexStr[0], ['0'..'9', 'A'..'F', 'a'..'f']) then
  begin
    // ���������, �������� �� ������ ������ ������ ���������� �������� ����������������� �����
    if CharInSet(HexStr[1], ['0'..'9', 'A'..'F', 'a'..'f']) then
    begin
      // ���� ��� ������� �������� ����������� ��������� ����������������� �����,
      // �� ����������� �� � ����� � ����������������� ������� � ������� ������� StrToInt
      AByte := StrToInt('$' + HexStr[0] + HexStr[1]);
      // ������������� ��������� � TRUE, ����� ������� �������� ��������������
      Result := TRUE;
    end;
  end;
end;


// ��������� Txt2Bin ��������� ����������� ������ �� ������� TXT � ������ BIN.
// ��� ��������� ������ �� TxtStringList � ���� ����� � ���������� �� � BinStream � ���� �������� ������.
// �������� StartAddress ���������� ��������� ����� ������ � �������� �����������.
procedure Txt2Bin(TxtStringList: TStringList; BinStream: TMemoryStream;
  var StartAddress: int64); // �� ������������ StartAddress
var
  CharIndex: DWORD;        // ������ �������� ������� � ������
  SectionIndex: DWORD;     // ������ ������� ������ ������
  SectionOffset: DWORD;    // �������� ������ ������� ������ ������
  TextStr: string;         // ������, ���������� ������������ ��������� ������
  BinSize: DWORD;          // ������ �������� ������
  AByte: BYTE;             // ����, ���������� �� �������������� ���� ��������
  SizeToWrite: DWORD;      // ������ ������ ��� ������
begin
  TextStr := '';
  for SectionOffset := 0 to TxtStringList.Count - 1 do
    TextStr := TextStr + TxtStringList[SectionOffset];   // ��������� ��������� ������ �� ������ ����� � ���������� �� � ���� ������
  SectionIndex := 0;
  SectionOffset := 0;
  CharIndex := 1;
  BinSize := 0;
  while CharIndex < Length(TextStr) do    // ������������ ������ ������ � ������
  begin
    if not HexStr2Int(@TextStr[CharIndex], AByte) then   // ����������� ��� ������� � ����, ���� ��������
    begin
      Inc(CharIndex, 1);    // ���� �������������� �� �������, ��������� � ���������� �������
      continue;
    end;
    HexSections[SectionIndex].DataBuffer[SectionOffset] := AByte;   // ���������� ���� � ����� ������ ������� ������
    Inc(BinSize, 1);   // ����������� ������ �������� ������
    Inc(SectionOffset, 1);   // ����������� �������� ������ ������� ������
    if SectionOffset = ONE_SECTION_SIZE then   // ���� ��������� ������ ������
      Inc(SectionIndex, 1);   // ��������� � ��������� ������
    if SectionIndex = MAX_SECTION_COUNT then   // ���� ���������� ������������ ���������� ������
      break;   // ���������� ����

    Inc(CharIndex, 2);   // ��������� � ��������� ���� ��������
  end;
  BinStream.SetSize(BinSize);   // ������������� ������ ��������� ������
  // ���������� �������� ������ �� ������� ������ � �������� �����
  while BinSize > 0 do
  begin
    SizeToWrite := BinSize;
    if SizeToWrite > ONE_SECTION_SIZE then
      SizeToWrite := ONE_SECTION_SIZE;
    BinStream.Write(HexSections[SectionIndex].DataBuffer[0], SizeToWrite);   // ���������� ������ ������� ������
    Inc(SectionIndex);
    BinSize := BinSize - SizeToWrite;   // ��������� ���������� ������ ������
  end;
end;

initialization

// Hex2BinErrorMessage - ������, ���������� ��������� �� �������, ��������� � ��������� ����������� HEX � BIN.
// ������ ������� ������� ������������� ������������� ���� ������.
Hex2BinErrorMessage[HEX_ERROR_MARKER] := 'Error Marker'; // ������: �������� ������
Hex2BinErrorMessage[HEX_ERROR_ADDRESS] := 'Error Address'; // ������: �������� �����
Hex2BinErrorMessage[HEX_ERROR_REC_TYPE] := 'Error Type'; // ������: �������� ��� ������
Hex2BinErrorMessage[HEX_ERROR_SECTION_SIZE] := 'Error Section Size'; // ������: �������� ������ ������
Hex2BinErrorMessage[HEX_ERROR_DATA] := 'Error Data'; // ������: �������� ������
Hex2BinErrorMessage[HEX_ERROR_CHECK_SUM] := 'Error CheckSum'; // ������: �������� ����������� �����
Hex2BinErrorMessage[HEX_ERROR_SECTION_COUNT] := 'Error Section Count'; // ������: �������� ���������� ������

end.
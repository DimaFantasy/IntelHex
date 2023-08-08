unit uIntelHex;

interface

uses
  SysUtils, Classes, Windows;

const
  HEX_ERROR_MARKER = 1; // Ошибка: неверный маркер записи
  HEX_ERROR_ADDRESS = 2; // Ошибка: неверный адрес записи
  HEX_ERROR_REC_TYPE = 3; // Ошибка: неверный тип записи
  HEX_ERROR_SECTION_SIZE = 4; // Ошибка: неверный размер секции
  HEX_ERROR_DATA = 5; // Ошибка: некорректные данные записи
  HEX_ERROR_CHECK_SUM = 6; // Ошибка: неверная контрольная сумма записи
  HEX_ERROR_SECTION_COUNT = 7; // Ошибка: превышено максимальное количество секций

type
  EHex2Bin = class(Exception)
  private
    FCode: integer; // Код ошибки
  public
    constructor Create(ACode: integer); // Создает исключение с указанным кодом ошибки
    property Code: integer read FCode write FCode; // Свойство для чтения и записи кода ошибки
  end;

//TxtStringList: TStringList - Список строк, содержащих данные в формате X.
//BinStream: TMemoryStream - Поток, в который будут записаны данные в формате BIN.
//StartAddress: int64 - Начальный адрес данных. Этот параметр может использоваться в процессе конвертации,
//  если требуется указать определенный адрес начала данных.
type
  TXxx2Bin = procedure( TxtStringList : TStringList; BinStream : TMemoryStream;
    var StartAddress : int64 );

// Преобразует список строк `TxtStringList`, содержащий текстовую информацию, в двоичные данные и записывает их в `BinStream`.
// Параметр `StartAddress` указывает стартовый адрес, который будет использоваться при преобразовании.
procedure Txt2Bin(TxtStringList: TStringList; BinStream: TMemoryStream; var StartAddress: Int64);

// Преобразует список строк `HexStringList`, содержащий шестнадцатеричные данные, в двоичные данные и записывает их в `BinStream`.
// Параметр `StartAddress` указывает стартовый адрес, который будет использоваться при преобразовании.
procedure Hex2Bin(HexStringList: TStringList; BinStream: TMemoryStream; var StartAddress: Int64);

// Преобразует двоичные данные из `BinStream`, представленные в виде потока памяти, в шестнадцатеричный формат и сохраняет их в список строк `HexStringList`.
// Параметр `StartAddress` указывает стартовый адрес данных.
procedure Bin2Hex(BinStream: TMemoryStream; HexStringList: TStringList; StartAddress: Int64);

{$IFDEF VER150} //Delphi 7
// Функция CharInSet: Проверяет, принадлежит ли символ C указанному набору символов CharSet.
// Перегружена для поддержки AnsiChar и WideChar.
function  CharInSet(C : AnsiChar; const CharSet : TSysCharSet) : Boolean; overload;
function  CharInSet(C : WideChar; const CharSet : TSysCharSet) : Boolean; overload;
{$ENDIF}

implementation

const
  ONE_RECORD_SIZE = 16; // Размер одной записи в формате Intel .hex файла
  ONE_SECTION_SIZE = 64 * 1024; // Размер одной секции (блока данных)
  MAX_SECTION_COUNT = 16; // Максимальное количество секций
  MAX_BUFFER_SIZE = MAX_SECTION_COUNT * ONE_SECTION_SIZE; // Максимальный размер буфера данных

type
  // Возможные типы записей для файлов формата Intel .hex
  TRecType = (
    rtData = 0, // Данные
    rtEof = 1, // Конец файла
    rtEsa = 2, // Расширенный адрес сегмента
    rtSsa = 3, // Начальный адрес сегмента
    rtEla = 4, // Расширенный линейный адрес
    rtSla = 5 // Начальный линейный адрес
  );

  THexRec = record
    Marker: BYTE; // Маркер записи (':') - валидный, другие - невалидный
    DataSize: BYTE; // Размер данных
    Addr: Word; // Адрес
    RecType: TRecType; // Тип записи
    DataBuf: array [0 .. 255] of BYTE; // Буфер данных
    CheckSum: BYTE; // Контрольная сумма
  end;

  THexSection = record
    LinearAddress: DWORD; // Линейный адрес секции
    UsedOffset: DWORD; // Используемое смещение в секции
    UnusedOffset: DWORD; // Неиспользуемое смещение в секции
    DataBuffer: array [0 .. ONE_SECTION_SIZE - 1] of BYTE; // Буфер данных секции
  end;

var
  HexSections: array [0 .. MAX_SECTION_COUNT - 1] of THexSection; // Массив секций данных
  Hex2BinErrorMessage: array [HEX_ERROR_MARKER .. HEX_ERROR_SECTION_COUNT] of string; // Массив сообщений об ошибках

{ Конструктор EHex2Bin }
constructor EHex2Bin.Create( ACode : integer );
begin
  FCode := ACode;
  inherited Create( Hex2BinErrorMessage[ ACode ] );
end;

{$IFDEF VER150} //Delphi 7
// Функция CharInSet(C: AnsiChar; const CharSet: TSysCharSet): Boolean;
// Проверяет, принадлежит ли символ C указанному множеству CharSet типа TSysCharSet.
// Возвращает True, если символ присутствует в множестве CharSet, иначе возвращает False.
function CharInSet(C: AnsiChar; const CharSet: TSysCharSet): Boolean;
begin
  Result := C in CharSet;
end;

// Функция CharInSet(C: WideChar; const CharSet: TSysCharSet): Boolean;
// Проверяет, принадлежит ли символ C указанному множеству CharSet типа TSysCharSet.
// Возвращает True, если символ присутствует в множестве CharSet, иначе возвращает False.
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
// Функция HexCalcCheckSum вычисляет контрольную сумму для записи в шестнадцатеричном формате (структуры THexRec).
// Возвращает контрольную сумму в виде байта.
function HexCalcCheckSum(HexRec: THexRec): BYTE;
var
  i: integer;
begin
  // Инициализация результата суммированием размера данных, адреса и типа записи
  Result := HexRec.DataSize + HexRec.Addr + (HexRec.Addr shr 8) + BYTE(HexRec.RecType);
  // Суммируем значения всех байтов данных
  for i := 0 to HexRec.DataSize - 1 do
    Inc(Result, HexRec.DataBuf[i]);
  // Применяем двоичное дополнение (Two's complement) к результату
  Result := (not Result) + 1;
end;

// Функция HexRec2Str преобразует структуру THexRec в строку, соответствующую формату записи в шестнадцатеричном формате.
// Возвращает строку, представляющую значения из структуры THexRec.
function HexRec2Str(HexRec: THexRec): string;
var
  i: integer;
begin
  Result := ':' + IntToHex(HexRec.DataSize, 2) + IntToHex(HexRec.Addr, 4) +
    IntToHex(Ord(HexRec.RecType), 2);
  // Преобразуем байты данных в шестнадцатеричное представление и добавляем их к строке
  for i := 0 to HexRec.DataSize - 1 do
    Result := Result + IntToHex(HexRec.DataBuf[i], 2);
  // Вычисляем и добавляем контрольную сумму к строке
  Result := Result + IntToHex( HexRec.DataBuf[ i ], 2 );
  // Возвращаем сформированную строку
  Result := Result + IntToHex( HexCalcCheckSum( HexRec ), 2 )
end;

// 1 23 4567 89 ABCDEF.............................
// : 10 0013 00 AC12AD13AE10AF1112002F8E0E8F0F22 44
// Функция HexStr2Rec преобразует строку HexStr в структуру THexRec.
// Строка HexStr должна соответствовать формату записи в шестнадцатеричном формате, как указано в комментарии.
// Функция возвращает структуру THexRec, содержащую разобранные значения из строки.
function HexStr2Rec(HexStr: string): THexRec;
var
  i: integer;
begin
  Result.Marker := Ord(HexStr[1]);
  // Проверяем, что первый символ строки является маркером начала записи ':'
  if Result.Marker <> Ord(':') then
    raise EHex2Bin.Create(HEX_ERROR_MARKER);
  try
    // Извлекаем размер данных, адрес и тип записи из строкового представления
    Result.DataSize := StrToInt('$' + Copy(HexStr, 2, 2));
    Result.Addr := StrToInt('$' + Copy(HexStr, 4, 4));
    Result.RecType := TRecType(StrToInt('$' + Copy(HexStr, 8, 2)));
    // Извлекаем байты данных из строки и заполняем буфер данных в структуре THexRec
    for i := 0 to Result.DataSize - 1 do
      Result.DataBuf[i] := StrToInt('$' + Copy(HexStr, 10 + i * 2, 2));
    // Извлекаем контрольную сумму из строки
    Result.CheckSum := StrToInt('$' + Copy(HexStr, 10 + Result.DataSize * 2, 2));
  except
    raise EHex2Bin.Create(HEX_ERROR_DATA);
  end;
  // Проверяем корректность контрольной суммы
  if Result.CheckSum <> HexCalcCheckSum(Result) then
    raise EHex2Bin.Create(HEX_ERROR_CHECK_SUM);
  // Возвращаем разобранную структуру THexRec
end;

// Процедура Bin2Hex выполняет конвертацию данных из формата BIN в формат HEX.
// Она считывает данные из BinStream и записывает их в HexStringList в виде строк в формате HEX.
// Параметр StartAddress определяет начальный адрес данных в процессе конвертации.
procedure Bin2Hex(BinStream: TMemoryStream; HexStringList: TStringList;
  StartAddress: int64);
var
  HexRec: THexRec;      // Структура, представляющая запись формата Intel Hex
  BufferSize: DWORD;    // Размер буфера (размер входного потока данных)
  SectionSize: DWORD;   // Размер текущей секции данных
  RecordSize: DWORD;    // Размер текущей записи данных
  SectionAddr: DWORD;   // Адрес начала текущей секции
  LinearAddr: DWORD;    // Линейный адрес
begin
  SectionAddr := 0;     // Начальный адрес секции (инициализация)
  LinearAddr := 0;      // Начальный линейный адрес (инициализация)
  BufferSize := BinStream.Size;     // Получаем размер входного потока данных
  SectionSize := BufferSize;        // Размер секции данных равен размеру входного потока данных
  BinStream.Seek(0, soBeginning);   // Устанавливаем указатель в начало входного потока данных
  while BufferSize > 0 do
  begin
    // Запись расширенного линейного адреса (rtEla)
    if (StartAddress <> 0) or (SectionSize = 0) then
    begin
      if (StartAddress <> 0) then    // Если это первая секция
      begin
        SectionAddr := StartAddress and (ONE_SECTION_SIZE - 1);   // Вычисляем адрес начала секции
        SectionSize := ONE_SECTION_SIZE - SectionAddr;            // Вычисляем размер секции
        LinearAddr := StartAddress shr 16;                        // Вычисляем линейный адрес
        StartAddress := 0;                                        // Сбрасываем стартовый адрес в 0
      end
      else    // Если размер секции равен 0
      begin
        SectionAddr := 0;               // Сбрасываем адрес секции в 0
        SectionSize := BufferSize;      // Размер секции равен размеру оставшихся данных
        LinearAddr := LinearAddr + 1;   // Увеличиваем линейный адрес на 1
      end;
      HexRec.DataSize := 2;                                 // Размер данных записи (2 байта)
      HexRec.Addr := 0;                                     // Адрес записи (0)
      HexRec.RecType := rtEla;                              // Тип записи (расширенный линейный адрес)
      HexRec.DataBuf[0] := LinearAddr shr 8;                 // Байт данных - старший байт линейного адреса
      HexRec.DataBuf[1] := LinearAddr and $FF;               // Байт данных - младший байт линейного адреса
      HexStringList.Add(HexRec2Str(HexRec));                 // Преобразуем запись в строку и добавляем в список
    end
    else    // Запись данных (rtData)
    begin
      RecordSize := SectionSize;                            // Размер записи данных равен размеру текущей секции
      if RecordSize > ONE_RECORD_SIZE then                  // Если размер записи превышает максимальный размер записи
        RecordSize := ONE_RECORD_SIZE;                      // Ограничиваем размер записи до максимального
      HexRec.DataSize := RecordSize;                        // Размер данных записи
      HexRec.Addr := SectionAddr;                           // Адрес записи (адрес начала секции)
      HexRec.RecType := rtData;                             // Тип записи (данные)
      BinStream.Read(HexRec.DataBuf[0], RecordSize);         // Читаем данные из входного потока в буфер данных записи
      HexStringList.Add(HexRec2Str(HexRec));                 // Преобразуем запись в строку и добавляем в список
      SectionAddr := SectionAddr + RecordSize;               // Увеличиваем адрес начала секции на размер записи
      SectionSize := SectionSize - RecordSize;               // Уменьшаем размер текущей секции на размер записи
      BufferSize := BufferSize - RecordSize;                 // Уменьшаем размер буфера на размер записи
    end;
  end;
  // Запись окончания файла (rtEof) :00000001FF
  HexRec.DataSize := 0;       // Размер данных записи (0)
  HexRec.Addr := 0;           // Адрес записи (0)
  HexRec.RecType := rtEof;    // Тип записи (окончание файла)
  HexStringList.Add(HexRec2Str(HexRec));   // Преобразуем запись в строку и добавляем в список
end;

// Процедура Hex2Bin выполняет конвертацию данных из формата HEX в формат BIN.
// Она считывает данные из HexStringList в виде строк в формате HEX и записывает их в BinStream в виде бинарных данных.
// Параметр StartAddress определяет начальный адрес данных в процессе конвертации.
procedure Hex2Bin(HexStringList: TStringList; BinStream: TMemoryStream;
  var StartAddress: int64);
var
  i: integer;
  LastAddress: int64;
  HexRec: THexRec;                 // Структура, представляющая запись формата Intel Hex
  SectionFreeAddr: DWORD;          // Свободный адрес в секции данных
  SectionIndex: DWORD;             // Индекс текущей секции
  SizeToWrite: DWORD;              // Размер данных для записи
  BufferToWrite: Pointer;          // Буфер данных для записи
  LinearAddress: DWORD;            // Линейный адрес
  FirstLinearAddr: DWORD;          // Первый линейный адрес
  LastLinearAddr: DWORD;           // Последний линейный адрес
  FirstUsedDataOffset: DWORD;      // Смещение первого использованного блока данных
  LastUnusedDataOffset: DWORD;     // Смещение последнего неиспользованного блока данных
begin
  // Инициализация всех секций и буфера данных
  for i := 0 to MAX_SECTION_COUNT - 1 do
  begin
    HexSections[i].LinearAddress := $0000;                      // Обнуляем линейный адрес
    HexSections[i].UnusedOffset := $0000;                       // Обнуляем смещение неиспользованного блока данных
    HexSections[i].UsedOffset := ONE_SECTION_SIZE;              // Устанавливаем смещение первого использованного блока данных в размер секции
    FillChar(HexSections[i].DataBuffer[0], ONE_SECTION_SIZE, $FF);   // Заполняем буфер данных еденицами
  end;
  SectionIndex := 0;
  for i := 0 to HexStringList.Count - 1 do
  begin
    HexRec := HexStr2Rec(HexStringList[i]);                      // Преобразуем строку в запись формата Intel Hex
    case HexRec.RecType of
      rtEof:
        break;                                                   // Если запись является окончанием файла, выходим из цикла
      rtSsa, rtEsa, rtSla:
        continue;                                                // Пропускаем записи, связанные с адресами
      rtEla:
        begin
          LinearAddress := HexRec.DataBuf[0] * 256 + HexRec.DataBuf[1];   // Получаем линейный адрес из записи
          if HexSections[SectionIndex].LinearAddress <> LinearAddress then
          begin
            if (i <> 0) then
              SectionIndex := SectionIndex + 1;                  // Увеличиваем индекс секции при изменении линейного адреса
            if (SectionIndex = MAX_SECTION_COUNT) then
              raise EHex2Bin.Create(HEX_ERROR_SECTION_COUNT);     // Если количество секций превышает максимально допустимое, вызываем исключение

            HexSections[SectionIndex].LinearAddress := LinearAddress;   // Записываем линейный адрес в текущую секцию
          end;
        end;
      rtData:
        begin
          SectionFreeAddr := HexRec.Addr + HexRec.DataSize;     // Вычисляем свободный адрес в текущей секции
          if SectionFreeAddr > ONE_SECTION_SIZE then
            raise EHex2Bin.Create(HEX_ERROR_SECTION_SIZE);       // Если свободный адрес превышает размер секции, вызываем исключение
          if HexSections[SectionIndex].UnusedOffset < SectionFreeAddr then
            HexSections[SectionIndex].UnusedOffset := SectionFreeAddr;   // Обновляем смещение неиспользованного блока данных в текущей секции
          if HexSections[SectionIndex].UsedOffset > HexRec.Addr then
            HexSections[SectionIndex].UsedOffset := HexRec.Addr;     // Обновляем смещение первого использованного блока данных в текущей секции
          CopyMemory(@HexSections[SectionIndex].DataBuffer[HexRec.Addr],
            @HexRec.DataBuf[0], HexRec.DataSize);               // Копируем данные из записи в буфер данных секции
        end;
    end;
  end;

  FirstLinearAddr := $10000;         // Инициализируем первый линейный адрес значением $10000
  LastLinearAddr := 0;               // Инициализируем последний линейный адрес значением 0
  FirstUsedDataOffset := 0;          // Инициализируем смещение первого использованного блока данных значением 0
  LastUnusedDataOffset := ONE_SECTION_SIZE;   // Инициализируем смещение последнего неиспользованного блока данных значением размера одной секции
  // Определение первого и последнего линейных адресов, а также смещений первого использованного и последнего неиспользованного блоков данных
  for i := 0 to SectionIndex do
  begin
    // Проверяем текущий линейный адрес с последним известным линейным адресом
    if HexSections[i].LinearAddress > LastLinearAddr then
    begin
      LastLinearAddr := HexSections[i].LinearAddress;        // Обновляем последний линейный адрес
      LastUnusedDataOffset := HexSections[i].UnusedOffset;   // Обновляем смещение последнего неиспользованного блока данных
    end;

    // Проверяем текущий линейный адрес с первым известным линейным адресом
    if HexSections[i].LinearAddress < FirstLinearAddr then
    begin
      FirstLinearAddr := HexSections[i].LinearAddress;       // Обновляем первый линейный адрес
      FirstUsedDataOffset := HexSections[i].UsedOffset;      // Обновляем смещение первого использованного блока данных
    end;
  end;
  StartAddress := DWORD(FirstLinearAddr) shl 16;
  StartAddress := StartAddress + FirstUsedDataOffset;         // Установка стартового адреса
  LastAddress := DWORD(LastLinearAddr) shl 16;
  LastAddress := LastAddress + LastUnusedDataOffset;          // Вычисление последнего адреса
  BinStream.Clear;
  BinStream.SetSize(LastAddress - StartAddress);              // Установка размера выходного потока
  // Запись каждой секции в выходной поток (включая неиспользованные секции)
  for i := 0 to SectionIndex do
  begin
    if HexSections[i].LinearAddress = FirstLinearAddr then
    begin
      SizeToWrite := ONE_SECTION_SIZE - HexSections[i].UsedOffset;
      if SizeToWrite > BinStream.Size then
        SizeToWrite := BinStream.Size;

      BufferToWrite := @HexSections[i].DataBuffer
        [HexSections[i].UsedOffset];                          // Определение буфера данных для записи для первой использованной секции
    end
    else if HexSections[i].LinearAddress = LastLinearAddr then
    begin
      SizeToWrite := HexSections[i].UnusedOffset;
      BufferToWrite := @HexSections[i].DataBuffer[0];          // Определение буфера данных для записи для последней неиспользованной секции
    end
    else
    begin
      SizeToWrite := ONE_SECTION_SIZE;
      BufferToWrite := @HexSections[i].DataBuffer[0];          // Определение буфера данных для записи для остальных секций
    end;
    BinStream.Write(BufferToWrite^, SizeToWrite);              // Запись данных в выходной поток
  end;

end;

// Функция HexStr2Int преобразует первые два символа строки HexStr в число в шестнадцатеричном формате.
// Если преобразование успешно, результат возвращается через переменную AByte, и функция возвращает TRUE.
// В противном случае, если строка не содержит корректное представление шестнадцатеричного числа, функция возвращает FALSE.
function HexStr2Int(HexStr: PChar; var AByte: BYTE): boolean;
begin
  Result := FALSE;
  // Проверяем, начинается ли строка с символа '0'
  // Если да, то проверяем следующий символ, чтобы убедиться, что это не префикс '0x' или '0X'
  if (HexStr[0] = '0') then
  begin
    if ((HexStr[1] = 'x') or (HexStr[1] = 'X')) then
      Exit;
  end;
  // Проверяем, является ли первый символ строки допустимым символом шестнадцатеричной цифры
  if CharInSet(HexStr[0], ['0'..'9', 'A'..'F', 'a'..'f']) then
  begin
    // Проверяем, является ли второй символ строки допустимым символом шестнадцатеричной цифры
    if CharInSet(HexStr[1], ['0'..'9', 'A'..'F', 'a'..'f']) then
    begin
      // Если оба символа являются допустимыми символами шестнадцатеричной цифры,
      // то преобразуем их в число в шестнадцатеричном формате с помощью функции StrToInt
      AByte := StrToInt('$' + HexStr[0] + HexStr[1]);
      // Устанавливаем результат в TRUE, чтобы указать успешное преобразование
      Result := TRUE;
    end;
  end;
end;


// Процедура Txt2Bin выполняет конвертацию данных из формата TXT в формат BIN.
// Она считывает данные из TxtStringList в виде строк и записывает их в BinStream в виде бинарных данных.
// Параметр StartAddress определяет начальный адрес данных в процессе конвертации.
procedure Txt2Bin(TxtStringList: TStringList; BinStream: TMemoryStream;
  var StartAddress: int64); // Не используется StartAddress
var
  CharIndex: DWORD;        // Индекс текущего символа в строке
  SectionIndex: DWORD;     // Индекс текущей секции данных
  SectionOffset: DWORD;    // Смещение внутри текущей секции данных
  TextStr: string;         // Строка, содержащая объединенные текстовые данные
  BinSize: DWORD;          // Размер бинарных данных
  AByte: BYTE;             // Байт, полученный из преобразования двух символов
  SizeToWrite: DWORD;      // Размер данных для записи
begin
  TextStr := '';
  for SectionOffset := 0 to TxtStringList.Count - 1 do
    TextStr := TextStr + TxtStringList[SectionOffset];   // Считываем текстовые данные из списка строк и объединяем их в одну строку
  SectionIndex := 0;
  SectionOffset := 0;
  CharIndex := 1;
  BinSize := 0;
  while CharIndex < Length(TextStr) do    // Обрабатываем каждый символ в строке
  begin
    if not HexStr2Int(@TextStr[CharIndex], AByte) then   // Преобразуем два символа в байт, если возможно
    begin
      Inc(CharIndex, 1);    // Если преобразование не удалось, переходим к следующему символу
      continue;
    end;
    HexSections[SectionIndex].DataBuffer[SectionOffset] := AByte;   // Записываем байт в буфер данных текущей секции
    Inc(BinSize, 1);   // Увеличиваем размер бинарных данных
    Inc(SectionOffset, 1);   // Увеличиваем смещение внутри текущей секции
    if SectionOffset = ONE_SECTION_SIZE then   // Если достигнут размер секции
      Inc(SectionIndex, 1);   // Переходим к следующей секции
    if SectionIndex = MAX_SECTION_COUNT then   // Если достигнуто максимальное количество секций
      break;   // Прекращаем цикл

    Inc(CharIndex, 2);   // Переходим к следующей паре символов
  end;
  BinStream.SetSize(BinSize);   // Устанавливаем размер выходного потока
  // Записываем бинарные данные из буферов секций в выходной поток
  while BinSize > 0 do
  begin
    SizeToWrite := BinSize;
    if SizeToWrite > ONE_SECTION_SIZE then
      SizeToWrite := ONE_SECTION_SIZE;
    BinStream.Write(HexSections[SectionIndex].DataBuffer[0], SizeToWrite);   // Записываем данные текущей секции
    Inc(SectionIndex);
    BinSize := BinSize - SizeToWrite;   // Уменьшаем оставшийся размер данных
  end;
end;

initialization

// Hex2BinErrorMessage - массив, содержащий сообщения об ошибках, связанных с процессом конвертации HEX в BIN.
// Каждый элемент массива соответствует определенному коду ошибки.
Hex2BinErrorMessage[HEX_ERROR_MARKER] := 'Error Marker'; // Ошибка: неверный маркер
Hex2BinErrorMessage[HEX_ERROR_ADDRESS] := 'Error Address'; // Ошибка: неверный адрес
Hex2BinErrorMessage[HEX_ERROR_REC_TYPE] := 'Error Type'; // Ошибка: неверный тип записи
Hex2BinErrorMessage[HEX_ERROR_SECTION_SIZE] := 'Error Section Size'; // Ошибка: неверный размер секции
Hex2BinErrorMessage[HEX_ERROR_DATA] := 'Error Data'; // Ошибка: неверные данные
Hex2BinErrorMessage[HEX_ERROR_CHECK_SUM] := 'Error CheckSum'; // Ошибка: неверная контрольная сумма
Hex2BinErrorMessage[HEX_ERROR_SECTION_COUNT] := 'Error Section Count'; // Ошибка: неверное количество секций

end.
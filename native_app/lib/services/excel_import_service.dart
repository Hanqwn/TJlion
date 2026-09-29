import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Parses member-roster and prop-inventory XLSX files from bytes.
///
/// Cell values are returned as text exactly as stored in the XLSX package.
/// This service does not inspect styles, fonts, number formats, formulas for
/// execution, or write to a repository or UI.
class ExcelImportService {
  const ExcelImportService();

  static const List<String> memberFields = [
    '姓名',
    '学号',
    '年级',
    '专业',
    '生日',
    '联系方式',
    '职位',
  ];

  static const List<String> inventoryFields = [
    '道具名称',
    '类别',
    '数量',
    '单位',
    '存放位置',
    '状态',
    '备注',
  ];

  static const String _relationshipNamespace =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const String _packageRelationshipsNamespace =
      'http://schemas.openxmlformats.org/package/2006/relationships';
  static const String _spreadsheetNamespace =
      'http://schemas.openxmlformats.org/spreadsheetml/2006/main';

  static const Map<String, String> _memberHeaderAliases = {
    '姓名': '姓名',
    '名字': '姓名',
    '学号': '学号',
    '学生学号': '学号',
    '学员学号': '学号',
    '学生编号': '学号',
    '学员编号': '学号',
    '年级': '年级',
    '专业': '专业',
    '生日': '生日',
    '生日年月日': '生日',
    '出生日期': '生日',
    '出生年月日': '生日',
    '出生日期年月日': '生日',
    '联系方式': '联系方式',
    '联系电话': '联系方式',
    '联系电话方式': '联系方式',
    '电话': '联系方式',
    '手机': '联系方式',
    '手机号码': '联系方式',
    '职位': '职位',
    '职务': '职位',
    '队内职务': '职位',
  };

  static const Map<String, String> _inventoryHeaderAliases = {
    '道具名称': '道具名称',
    '物品名称': '道具名称',
    '名称': '道具名称',
    '类别': '类别',
    '分类': '类别',
    '数量': '数量',
    '单位': '单位',
    '计量单位': '单位',
    '存放位置': '存放位置',
    '存放地点': '存放位置',
    '位置': '存放位置',
    '状态': '状态',
    '备注': '备注',
    '说明': '备注',
  };

  static final RegExp _ordinalPrefix = RegExp(
    r'^\s*[0-9０-９]+\s*[、.．)）:：_\-]\s*',
  );
  static final RegExp _headerSeparators = RegExp(
    r'[\s\u3000:：·,，;；_—–\-/\\()（）\[\]【】]+',
  );

  /// Normalizes a heading for schema matching while preserving the original
  /// heading in [ExcelImportResult.headers]. A leading ordinal such as `1、`
  /// is removed before whitespace and punctuation are folded away.
  static String normalizeHeader(String value) {
    final withoutBom = value.replaceAll('\uFEFF', '').trim();
    final withoutOrdinal = withoutBom.replaceFirst(_ordinalPrefix, '');
    return withoutOrdinal.toLowerCase().replaceAll(_headerSeparators, '');
  }

  /// Parses the member sheet. If [sheetName] is omitted, a sheet named
  /// `成员名册` is preferred; otherwise the first visible sheet with a matching
  /// header is selected.
  ExcelImportResult parseMembers(Uint8List bytes, {String? sheetName}) =>
      _parse(
        bytes,
        sheetName: sheetName,
        preferredSheetName: '成员名册',
        requiredFields: memberFields,
        aliases: _memberHeaderAliases,
        duplicateField: '姓名',
      );

  /// Parses the inventory sheet. Quantity remains in [ExcelImportRow.rawCells]
  /// and [ExcelImportRow.rawFields]; a typed numeric cell is also exposed in
  /// [ExcelImportRow.numericFields].
  ExcelImportResult parseInventory(Uint8List bytes, {String? sheetName}) =>
      _parse(
        bytes,
        sheetName: sheetName,
        preferredSheetName: '道具清单',
        requiredFields: inventoryFields,
        aliases: _inventoryHeaderAliases,
      );

  ExcelImportResult _parse(
    Uint8List bytes, {
    required String? sheetName,
    required String preferredSheetName,
    required List<String> requiredFields,
    required Map<String, String> aliases,
    String? duplicateField,
  }) {
    if (bytes.isEmpty) {
      throw const FormatException('The XLSX file is empty.');
    }

    final archive = ZipDecoder().decodeBytes(bytes);
    final date1904 = _uses1904DateSystem(archive);
    final descriptors = _readSheetDescriptors(archive);
    if (descriptors.isEmpty) {
      throw const FormatException('The XLSX workbook contains no worksheets.');
    }
    final sharedStrings = _readSharedStrings(archive);

    final _ParsedWorksheet selected;
    if (sheetName != null) {
      final descriptor = _findSheet(descriptors, sheetName);
      if (descriptor == null) {
        throw FormatException('Worksheet not found: $sheetName');
      }
      selected = _readWorksheet(archive, descriptor, sharedStrings, date1904);
    } else {
      final visible = descriptors.where((sheet) => sheet.isVisible).toList();
      final candidates = visible.isEmpty ? descriptors : visible;
      final preferred = _findSheet(candidates, preferredSheetName);
      if (preferred != null) {
        selected = _readWorksheet(archive, preferred, sharedStrings, date1904);
      } else {
        _ParsedWorksheet? first;
        _ParsedWorksheet? matched;
        for (final descriptor in candidates) {
          final parsed = _readWorksheet(
            archive,
            descriptor,
            sharedStrings,
            date1904,
          );
          first ??= parsed;
          if (_recognizedHeaderCount(parsed, aliases) >= 2) {
            matched = parsed;
            break;
          }
        }
        selected =
            matched ??
            first ??
            _readWorksheet(archive, descriptors.first, sharedStrings, date1904);
      }
    }

    return _buildResult(
      selected,
      requiredFields: requiredFields,
      aliases: aliases,
      duplicateField: duplicateField,
    );
  }

  ExcelImportResult _buildResult(
    _ParsedWorksheet worksheet, {
    required List<String> requiredFields,
    required Map<String, String> aliases,
    String? duplicateField,
  }) {
    final headerRowNumber = _firstNonEmptyRow(worksheet) ?? 0;
    final headerCells = headerRowNumber == 0
        ? const <int, _WorksheetCell>{}
        : worksheet.rowsByNumber[headerRowNumber] ??
              const <int, _WorksheetCell>{};
    final headers = List<String>.generate(
      worksheet.maxColumn,
      (index) => headerCells[index + 1]?.rawText ?? '',
      growable: false,
    );
    final positions = <String, List<int>>{};
    for (var index = 0; index < headers.length; index++) {
      final canonical = aliases[normalizeHeader(headers[index])];
      if (canonical != null) {
        positions.putIfAbsent(canonical, () => <int>[]).add(index);
      }
    }

    final diagnostics = <ExcelImportDiagnostic>[];
    final missingFields = requiredFields
        .where((field) => positions[field] == null)
        .toList(growable: false);
    if (missingFields.isNotEmpty) {
      diagnostics.add(
        ExcelImportDiagnostic(
          code: 'missing_required_columns',
          severity: ExcelImportDiagnosticSeverity.error,
          rowNumbers: headerRowNumber == 0 ? const [] : [headerRowNumber],
          fields: missingFields,
        ),
      );
    }
    for (final entry in positions.entries) {
      if (entry.value.length > 1) {
        diagnostics.add(
          ExcelImportDiagnostic(
            code: 'duplicate_header',
            severity: ExcelImportDiagnosticSeverity.warning,
            rowNumbers: headerRowNumber == 0 ? const [] : [headerRowNumber],
            columnNumbers: entry.value.map((index) => index + 1).toList(),
            fields: [entry.key],
          ),
        );
      }
    }

    final rows = <ExcelImportRow>[];
    final rowsByName = <String, List<int>>{};
    final dataRowNumbers =
        worksheet.rowsByNumber.keys
            .where((rowNumber) => rowNumber > headerRowNumber)
            .toList()
          ..sort();
    final lastDataRow = dataRowNumbers.isEmpty
        ? headerRowNumber
        : dataRowNumbers.last;
    var blankDiagnosticsAdded = 0;
    var omittedBlankRows = 0;

    for (
      var rowNumber = headerRowNumber + 1;
      rowNumber <= lastDataRow;
      rowNumber++
    ) {
      final cells = worksheet.rowsByNumber[rowNumber];
      if (cells == null || _isBlankRow(cells)) {
        if (blankDiagnosticsAdded < 100) {
          diagnostics.add(
            ExcelImportDiagnostic(
              code: 'empty_row',
              severity: ExcelImportDiagnosticSeverity.warning,
              rowNumbers: [rowNumber],
            ),
          );
          blankDiagnosticsAdded++;
        } else {
          omittedBlankRows++;
        }
        continue;
      }

      final rowCells = List<_WorksheetCell>.generate(
        worksheet.maxColumn,
        (index) => cells[index + 1] ?? const _WorksheetCell.empty(),
        growable: false,
      );
      final rawCells = rowCells.map((cell) => cell.rawText).toList();
      final fields = <String, String>{};
      final rawFields = <String, String>{};
      final numericFields = <String, num>{};
      for (final field in requiredFields) {
        final fieldPositions = positions[field];
        if (fieldPositions != null && fieldPositions.isNotEmpty) {
          final index = fieldPositions.first;
          final cell = rowCells[index];
          rawFields[field] = cell.rawText;
          final normalizedBirthday = field == '生日' && cell.isNumeric
              ? _excelSerialDate(cell.rawText, worksheet.date1904)
              : null;
          fields[field] = normalizedBirthday ?? cell.rawText;
          if (cell.isNumeric) {
            final number = num.tryParse(cell.rawText);
            if (number != null) numericFields[field] = number;
          }
        }
      }
      rows.add(
        ExcelImportRow(
          rowNumber: rowNumber,
          rawCells: rawCells,
          fields: fields,
          rawFields: rawFields,
          numericFields: numericFields,
        ),
      );

      if (duplicateField != null) {
        final normalizedName = (fields[duplicateField] ?? '').trim();
        if (normalizedName.isNotEmpty) {
          rowsByName.putIfAbsent(normalizedName, () => <int>[]).add(rowNumber);
        }
      }
    }

    if (omittedBlankRows > 0) {
      diagnostics.add(
        ExcelImportDiagnostic(
          code: 'empty_row_diagnostics_capped',
          severity: ExcelImportDiagnosticSeverity.warning,
          affectedCount: omittedBlankRows,
        ),
      );
    }
    for (final rowNumbers in rowsByName.values) {
      if (rowNumbers.length > 1) {
        diagnostics.add(
          ExcelImportDiagnostic(
            code: 'duplicate_member_name',
            severity: ExcelImportDiagnosticSeverity.warning,
            rowNumbers: rowNumbers,
            fields: [duplicateField!],
          ),
        );
      }
    }

    return ExcelImportResult(
      sheetName: worksheet.name,
      headerRowNumber: headerRowNumber,
      headers: headers,
      rows: rows,
      diagnostics: diagnostics,
    );
  }

  List<_WorksheetDescriptor> _readSheetDescriptors(Archive archive) {
    final workbook = XmlDocument.parse(_readPart(archive, 'xl/workbook.xml'));
    final relationships = XmlDocument.parse(
      _readPart(archive, 'xl/_rels/workbook.xml.rels'),
    );
    final targetById = <String, String>{};
    for (final relationship in relationships.rootElement.findAllElements(
      'Relationship',
      namespace: _packageRelationshipsNamespace,
    )) {
      if (relationship.getAttribute('TargetMode') == 'External') continue;
      final id = relationship.getAttribute('Id');
      final target = relationship.getAttribute('Target');
      if (id != null && target != null) {
        targetById[id] = _resolveWorksheetTarget(target);
      }
    }

    final sheets = <_WorksheetDescriptor>[];
    for (final sheet in workbook.rootElement.findAllElements(
      'sheet',
      namespace: _spreadsheetNamespace,
    )) {
      final name = sheet.getAttribute('name');
      final relationshipId = sheet.getAttribute(
        'id',
        namespace: _relationshipNamespace,
      );
      if (name == null || relationshipId == null) continue;
      final target = targetById[relationshipId];
      if (target == null) continue;
      final state = sheet.getAttribute('state');
      sheets.add(
        _WorksheetDescriptor(
          name: name,
          path: target,
          isVisible: state == null || state == 'visible',
        ),
      );
    }
    return sheets;
  }

  List<String> _readSharedStrings(Archive archive) {
    final part = archive.findFile('xl/sharedStrings.xml');
    if (part == null) return const [];
    final document = XmlDocument.parse(_decodePart(part));
    return document.rootElement
        .findAllElements('si', namespace: _spreadsheetNamespace)
        .map(_richText)
        .toList(growable: false);
  }

  _ParsedWorksheet _readWorksheet(
    Archive archive,
    _WorksheetDescriptor descriptor,
    List<String> sharedStrings,
    bool date1904,
  ) {
    final document = XmlDocument.parse(_readPart(archive, descriptor.path));
    final rowsByNumber = <int, Map<int, _WorksheetCell>>{};
    var maxColumn = 0;
    for (final row in document.rootElement.findAllElements(
      'row',
      namespace: _spreadsheetNamespace,
    )) {
      final rowNumber = int.tryParse(row.getAttribute('r') ?? '');
      if (rowNumber == null || rowNumber < 1) continue;
      var previousColumn = 0;
      for (final cell in row.findElements(
        'c',
        namespace: _spreadsheetNamespace,
      )) {
        final reference = cell.getAttribute('r');
        final column = reference == null
            ? previousColumn + 1
            : _columnNumber(reference);
        previousColumn = column;
        final value = _cellValue(cell, sharedStrings);
        if (value.rawText.isEmpty) continue;
        rowsByNumber.putIfAbsent(
          rowNumber,
          () => <int, _WorksheetCell>{},
        )[column] = value;
        if (column > maxColumn) maxColumn = column;
      }
    }
    return _ParsedWorksheet(
      name: descriptor.name,
      rowsByNumber: rowsByNumber,
      maxColumn: maxColumn,
      date1904: date1904,
    );
  }

  _WorksheetCell _cellValue(XmlElement cell, List<String> sharedStrings) {
    final formula = _directChildText(cell, 'f');
    if (formula != null && formula.isNotEmpty) {
      return _WorksheetCell(rawText: '=$formula', isNumeric: false);
    }

    final type = cell.getAttribute('t');
    if (type == 'inlineStr') {
      final inline = cell
          .findElements('is', namespace: _spreadsheetNamespace)
          .toList();
      if (inline.isNotEmpty) {
        return _WorksheetCell(
          rawText: _richText(inline.first),
          isNumeric: false,
        );
      }
    }

    final value = _directChildText(cell, 'v');
    if (type == 's' && value != null) {
      final index = int.tryParse(value);
      if (index != null && index >= 0 && index < sharedStrings.length) {
        return _WorksheetCell(rawText: sharedStrings[index], isNumeric: false);
      }
    }
    // This returns the stored lexical value, including numeric serials. It
    // deliberately does not consult the cell's style index or format code.
    return _WorksheetCell(
      rawText: value ?? '',
      isNumeric: (type == null || type == 'n') && value != null,
    );
  }

  bool _uses1904DateSystem(Archive archive) {
    final workbook = XmlDocument.parse(_readPart(archive, 'xl/workbook.xml'));
    for (final properties in workbook.rootElement.findAllElements(
      'workbookPr',
      namespace: _spreadsheetNamespace,
    )) {
      final value = properties.getAttribute('date1904')?.toLowerCase();
      return value == '1' || value == 'true';
    }
    return false;
  }

  String? _excelSerialDate(String rawValue, bool date1904) {
    final serial = double.tryParse(rawValue);
    if (serial == null || !serial.isFinite || serial < 0 || serial > 2958465) {
      return null;
    }
    final days = serial.floor();
    if (date1904) {
      return _isoDate(DateTime.utc(1904, 1, 1).add(Duration(days: days)));
    }
    if (days == 60) return '1900-02-29'; // Excel's historical leap-year day.
    if (days == 0) return null;
    final adjustedDays = days > 60 ? days - 1 : days;
    return _isoDate(
      DateTime.utc(1899, 12, 31).add(Duration(days: adjustedDays)),
    );
  }

  String _isoDate(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  String _richText(XmlElement element) => element
      .findAllElements('t', namespace: _spreadsheetNamespace)
      .map((text) => text.innerText)
      .join();

  String? _directChildText(XmlElement element, String localName) {
    for (final child in element.findElements(
      localName,
      namespace: _spreadsheetNamespace,
    )) {
      return child.innerText;
    }
    return null;
  }

  int _columnNumber(String cellReference) {
    final letters = RegExp(r'^[A-Za-z]+').firstMatch(cellReference)?.group(0);
    if (letters == null) {
      throw FormatException('Invalid XLSX cell reference: $cellReference');
    }
    var column = 0;
    for (final codeUnit in letters.toUpperCase().codeUnits) {
      column = column * 26 + (codeUnit - 64);
    }
    return column;
  }

  String _resolveWorksheetTarget(String target) {
    final normalized = target.replaceAll('\\', '/');
    if (normalized.startsWith('xl/')) return normalized;
    final path = Uri.parse('https://xlsx.invalid/xl/workbook.xml')
        .resolve(normalized)
        .path;
    return path.startsWith('/') ? path.substring(1) : path;
  }

  String _readPart(Archive archive, String path) {
    final part = archive.findFile(path);
    if (part == null) {
      throw FormatException('The XLSX package is missing $path.');
    }
    return _decodePart(part);
  }

  String _decodePart(ArchiveFile part) {
    final bytes = part.readBytes();
    if (bytes == null) {
      throw const FormatException('An XLSX package part could not be read.');
    }
    return utf8.decode(bytes);
  }

  _WorksheetDescriptor? _findSheet(
    List<_WorksheetDescriptor> sheets,
    String name,
  ) {
    for (final sheet in sheets) {
      if (sheet.name == name) return sheet;
    }
    return null;
  }

  int _recognizedHeaderCount(
    _ParsedWorksheet worksheet,
    Map<String, String> aliases,
  ) {
    final headerRow = _firstNonEmptyRow(worksheet);
    if (headerRow == null) return 0;
    final headers = worksheet.rowsByNumber[headerRow]!.values.map(
      (cell) => cell.rawText,
    );
    return headers
        .map((header) => aliases[normalizeHeader(header)])
        .whereType<String>()
        .toSet()
        .length;
  }

  int? _firstNonEmptyRow(_ParsedWorksheet worksheet) {
    final rowNumbers = worksheet.rowsByNumber.keys.toList()..sort();
    for (final rowNumber in rowNumbers) {
      if (!_isBlankRow(worksheet.rowsByNumber[rowNumber]!)) return rowNumber;
    }
    return null;
  }

  bool _isBlankRow(Map<int, _WorksheetCell> cells) =>
      cells.values.every((value) => value.rawText.trim().isEmpty);
}

class ExcelImportResult {
  ExcelImportResult({
    required this.sheetName,
    required this.headerRowNumber,
    required List<String> headers,
    required List<ExcelImportRow> rows,
    required List<ExcelImportDiagnostic> diagnostics,
  }) : headers = List.unmodifiable(headers),
       rows = List.unmodifiable(rows),
       diagnostics = List.unmodifiable(diagnostics);

  final String sheetName;
  final int headerRowNumber;

  /// Original header text in worksheet column order.
  final List<String> headers;

  /// Non-empty data rows. Blank rows are represented by diagnostics.
  final List<ExcelImportRow> rows;

  final List<ExcelImportDiagnostic> diagnostics;

  bool get hasErrors => diagnostics.any(
    (diagnostic) => diagnostic.severity == ExcelImportDiagnosticSeverity.error,
  );
}

class ExcelImportRow {
  ExcelImportRow({
    required this.rowNumber,
    required List<String> rawCells,
    required Map<String, String> fields,
    required Map<String, String> rawFields,
    required Map<String, num> numericFields,
  }) : rawCells = List.unmodifiable(rawCells),
       fields = Map.unmodifiable(fields),
       rawFields = Map.unmodifiable(rawFields),
       numericFields = Map.unmodifiable(numericFields);

  final int rowNumber;

  /// Raw cell text from column A through the last used column; blanks are `''`.
  final List<String> rawCells;

  /// Recognized fields keyed by their canonical Chinese header.
  /// Typed birthday serials are converted to ISO text here.
  final Map<String, String> fields;

  /// Original text for each recognized field, before any date normalization.
  final Map<String, String> rawFields;

  /// Numeric cells keyed by canonical field name. Text-looking numbers are
  /// intentionally excluded so callers can distinguish stored cell types.
  final Map<String, num> numericFields;
}

enum ExcelImportDiagnosticSeverity { warning, error }

class ExcelImportDiagnostic {
  ExcelImportDiagnostic({
    required this.code,
    required this.severity,
    List<int> rowNumbers = const [],
    List<int> columnNumbers = const [],
    List<String> fields = const [],
    this.affectedCount = 1,
  }) : rowNumbers = List.unmodifiable(rowNumbers),
       columnNumbers = List.unmodifiable(columnNumbers),
       fields = List.unmodifiable(fields);

  final String code;
  final ExcelImportDiagnosticSeverity severity;
  final List<int> rowNumbers;
  final List<int> columnNumbers;
  final List<String> fields;

  /// Number of additional rows omitted when a diagnostic list was capped.
  final int affectedCount;

  String get message => switch (code) {
    'missing_required_columns' => '缺少必需列：${fields.join('、')}。',
    'duplicate_header' =>
      '表头字段“${fields.join('、')}”重复，请检查列 ${columnNumbers.join('、')}。',
    'empty_row' => '第 ${rowNumbers.join('、')} 行为空行。',
    'empty_row_diagnostics_capped' => '另有 $affectedCount 行空行未逐条列出。',
    'duplicate_member_name' => '成员姓名重复，请检查第 ${rowNumbers.join('、')} 行。',
    _ => '请检查工作表内容。',
  };
}

class _WorksheetDescriptor {
  const _WorksheetDescriptor({
    required this.name,
    required this.path,
    required this.isVisible,
  });

  final String name;
  final String path;
  final bool isVisible;
}

class _ParsedWorksheet {
  const _ParsedWorksheet({
    required this.name,
    required this.rowsByNumber,
    required this.maxColumn,
    required this.date1904,
  });

  final String name;
  final Map<int, Map<int, _WorksheetCell>> rowsByNumber;
  final int maxColumn;
  final bool date1904;
}

class _WorksheetCell {
  const _WorksheetCell({required this.rawText, required this.isNumeric});

  const _WorksheetCell.empty() : rawText = '', isNumeric = false;

  final String rawText;
  final bool isNumeric;
}

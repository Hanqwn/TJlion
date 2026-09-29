import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Local, deterministic PDF and editable TeX exports for Lion Manager.
///
/// Build integration requirements (kept here because this service is delivered
/// independently of the native Flutter scaffold):
/// - Add `pdf: ^3.13.1` to `pubspec.yaml`.
/// - Bundle an OFL-licensed Noto Sans CJK SC TrueType face at
///   `assets/fonts/NotoSansSC-Regular.ttf` and list that path under
///   `flutter.assets`. Noto Sans CJK is distributed under SIL OFL 1.1; retain
///   its upstream license notice with the asset. Do not use a CFF-only OTF file:
///   `pdf` loads TrueType via `pw.Font.ttf`.
/// - The UI chooses a writable local directory and passes it to an export call.
///   `path_provider` can supply the application documents directory if needed.
///
/// PDF and TeX are rendered from the same typed input. TeX is emitted as a
/// companion source file; this service does not invoke a TeX installation.
class DocumentExportService {
  const DocumentExportService({
    this.cjkFontAssetPath = defaultCjkFontAssetPath,
  });

  static const String defaultCjkFontAssetPath =
      'assets/fonts/NotoSansSC-Regular.ttf';

  final String cjkFontAssetPath;

  /// Exports a generic record. Monthly finance reports use this fixed record
  /// template with the month and totals passed in [RecordExportInput.fields].
  Future<ExportedDocumentFiles> exportRecord(
    RecordExportInput input, {
    required Directory outputDirectory,
  }) async {
    final body = _normalizedBody(input.body, emptyText: '暂无补充内容。');
    final content = _DocumentContent(
      title: input.title,
      subtitle: input.subtitle,
      date: input.date,
      fields: input.fields,
      sectionTitle: input.sectionTitle,
      body: body,
    );
    final tex = _replaceTemplate(_recordTemplate, {
      'title': _texEscape(input.title),
      'subtitle': _texEscape(input.subtitle),
      'body': _texParagraphs(input.body, emptyText: '暂无补充内容。'),
      'signature': _texEscape(input.signature),
      'date': _texEscape(input.date),
    });

    return _writeFiles(
      content,
      tex,
      outputName: input.outputName ?? input.title,
      outputDirectory: outputDirectory,
    );
  }

  /// Keeps the finance entry point explicit while reusing the generic record
  /// template and renderer, as the desktop/web implementation does.
  Future<ExportedDocumentFiles> exportMonthlyFinance(
    RecordExportInput input, {
    required Directory outputDirectory,
  }) => exportRecord(input, outputDirectory: outputDirectory);

  /// Exports a training attendance session using the fixed attendance layout.
  Future<ExportedDocumentFiles> exportAttendance(
    AttendanceExportInput input, {
    required Directory outputDirectory,
  }) async {
    final present = input.rows
        .where((row) => row.status == AttendanceStatus.present)
        .length;
    final absent = input.rows
        .where((row) => row.status == AttendanceStatus.absent)
        .length;
    final attendanceText = input.rows
        .map((row) {
          final status = switch (row.status) {
            AttendanceStatus.present => '参加',
            AttendanceStatus.absent => '未参加',
            AttendanceStatus.pending => '待确认',
          };
          final studentNumber = row.studentNumber.isEmpty
              ? '无学号'
              : row.studentNumber;
          final note = row.note.isEmpty ? '' : '　${row.note}';
          return '${row.name}（$studentNumber）　$status$note';
        })
        .join('\n');

    final content = _DocumentContent(
      title: input.title,
      subtitle: input.sessionTitle,
      date: input.date,
      fields: [
        ExportField('学期', input.semester),
        ExportField('训练时间', input.time),
        ExportField('参加', '$present 人'),
        ExportField('未参加', '$absent 人'),
      ],
      sectionTitle: '成员签到',
      body: _normalizedBody(attendanceText, emptyText: '暂无签到记录。'),
    );

    final texRows = input.rows.indexed
        .map((entry) {
          final index = entry.$1 + 1;
          final row = entry.$2;
          final status = switch (row.status) {
            AttendanceStatus.present => '参加',
            AttendanceStatus.absent => '未参加',
            AttendanceStatus.pending => '待确认',
          };
          final number = row.studentNumber.isEmpty ? '—' : row.studentNumber;
          final cells =
              '$index & ${_texEscape(row.name)} & ${_texEscape(number)} & '
              '${_texEscape(status)} & ${_texEscape(row.note)}';
          return '$cells ' + r'\\ \hline';
        })
        .join('\n');
    final tex = _replaceTemplate(_attendanceTemplate, {
      'date': _texEscape(input.date),
      'time': _texEscape(input.time),
      'semester': _texEscape(input.semester),
      'rows': texRows,
      'total': '${input.rows.length}',
      'present': '$present',
      'absent': '$absent',
    });

    return _writeFiles(
      content,
      tex,
      outputName: input.outputName ?? '考勤-${input.date}',
      outputDirectory: outputDirectory,
    );
  }

  /// Exports a training plan with the fixed training-plan TeX layout.
  Future<ExportedDocumentFiles> exportTrainingPlan(
    TrainingPlanExportInput input, {
    required Directory outputDirectory,
  }) async {
    final body = _normalizedBody(input.body, emptyText: '训练安排待补充。');
    final content = _DocumentContent(
      title: input.title,
      subtitle: '学期训练计划',
      date: input.date,
      fields: [ExportField('所属学期', input.semester)],
      sectionTitle: '训练安排',
      body: body,
    );
    final tex = _replaceTemplate(_trainingPlanTemplate, {
      'title': _texEscape(input.title),
      'semester': _texEscape(input.semester),
      'body': _texParagraphs(input.body, emptyText: '训练安排待补充。'),
      'date': _texEscape(input.date),
    });

    return _writeFiles(
      content,
      tex,
      outputName: input.outputName ?? input.title,
      outputDirectory: outputDirectory,
    );
  }

  Future<ExportedDocumentFiles> _writeFiles(
    _DocumentContent content,
    String tex, {
    required String outputName,
    required Directory outputDirectory,
  }) async {
    // Resolve and build both payloads before writing either output file.
    final fontData = await rootBundle.load(cjkFontAssetPath);
    final pdfBytes = await _buildPdf(content, fontData);
    final stem = _safeFileStem(outputName);
    await outputDirectory.create(recursive: true);

    final texFile = File(
      '${outputDirectory.path}${Platform.pathSeparator}$stem.tex',
    );
    final pdfFile = File(
      '${outputDirectory.path}${Platform.pathSeparator}$stem.pdf',
    );
    await texFile.writeAsString(tex, encoding: utf8, flush: true);
    await pdfFile.writeAsBytes(pdfBytes, flush: true);
    return ExportedDocumentFiles(
      fileStem: stem,
      texFile: texFile,
      pdfFile: pdfFile,
    );
  }

  Future<List<int>> _buildPdf(
    _DocumentContent content,
    ByteData fontData,
  ) async {
    final font = pw.Font.ttf(fontData);
    final document = pw.Document(
      theme: pw.ThemeData.withFont(
        base: font,
        bold: font,
        italic: font,
        boldItalic: font,
      ),
      title: content.title,
      author: '舞狮队管理台',
      creator: 'Lion Manager',
      subject: content.sectionTitle,
      producer: 'Lion Manager local export',
    );
    final visibleFields = content.fields
        .where((field) => field.value.isNotEmpty)
        .toList(growable: false);

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(40, 30, 40, 42),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Container(height: 4, color: _lionRed),
            pw.SizedBox(height: 9),
            pw.Text(
              content.subtitle.isEmpty ? '舞狮队资料记录' : content.subtitle,
              style: pw.TextStyle(color: _muted, fontSize: 9.5),
            ),
            pw.SizedBox(height: 3),
          ],
        ),
        footer: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(top: 7),
          decoration: pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: _divider, width: 0.6)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '舞狮队管理台 · 本地生成',
                style: pw.TextStyle(color: _muted, fontSize: 8),
              ),
              pw.Text(
                '${context.pageNumber} / ${context.pagesCount}',
                style: pw.TextStyle(color: _muted, fontSize: 8),
              ),
            ],
          ),
        ),
        build: (context) => [
          pw.Text(
            content.title.isEmpty ? '队伍记录' : content.title,
            style: pw.TextStyle(
              color: _ink,
              fontSize: 23,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          if (content.date.isNotEmpty) ...[
            pw.SizedBox(height: 5),
            pw.Text(
              content.date,
              style: pw.TextStyle(color: _muted, fontSize: 9.5),
            ),
          ],
          if (visibleFields.isNotEmpty) ...[
            pw.SizedBox(height: 15),
            ..._fieldRows(visibleFields),
            pw.SizedBox(height: 7),
            pw.Container(height: 0.8, color: _divider),
          ],
          pw.SizedBox(height: 15),
          pw.Text(
            content.sectionTitle.isEmpty ? '记录内容' : content.sectionTitle,
            style: pw.TextStyle(
              color: _lionRed,
              fontSize: 12,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 7),
          pw.Text(
            content.body,
            style: pw.TextStyle(
              color: _bodyInk,
              fontSize: 10.5,
              lineSpacing: 3,
            ),
          ),
        ],
      ),
    );
    return document.save();
  }

  List<pw.Widget> _fieldRows(List<ExportField> fields) {
    final rows = <pw.Widget>[];
    for (var index = 0; index < fields.length; index += 2) {
      final first = fields[index];
      final second = index + 1 < fields.length ? fields[index + 1] : null;
      rows.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 10),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(child: _fieldCell(first)),
              pw.SizedBox(width: 14),
              pw.Expanded(
                child: second == null ? pw.SizedBox() : _fieldCell(second),
              ),
            ],
          ),
        ),
      );
    }
    return rows;
  }

  pw.Widget _fieldCell(ExportField field) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(field.label, style: pw.TextStyle(color: _muted, fontSize: 8.5)),
      pw.SizedBox(height: 3),
      pw.Text(field.value, style: pw.TextStyle(color: _ink, fontSize: 10)),
    ],
  );
}

/// One labelled value shown in the PDF summary area.
class ExportField {
  const ExportField(this.label, this.value);

  final String label;
  final String value;
}

/// Generic record data; also used by monthly finance exports.
class RecordExportInput {
  const RecordExportInput({
    required this.title,
    this.subtitle = '',
    this.date = '',
    this.fields = const [],
    this.body = '',
    this.sectionTitle = '记录内容',
    this.signature = '舞狮队',
    this.outputName,
  });

  final String title;
  final String subtitle;
  final String date;
  final List<ExportField> fields;
  final String body;
  final String sectionTitle;
  final String signature;
  final String? outputName;
}

enum AttendanceStatus { present, absent, pending }

class AttendanceRowExportInput {
  const AttendanceRowExportInput({
    required this.name,
    this.studentNumber = '',
    this.status = AttendanceStatus.pending,
    this.note = '',
  });

  final String name;
  final String studentNumber;
  final AttendanceStatus status;
  final String note;
}

class AttendanceExportInput {
  const AttendanceExportInput({
    required this.date,
    required this.time,
    required this.semester,
    required this.rows,
    this.title = '训练考勤记录',
    this.sessionTitle = '狮队训练',
    this.outputName,
  });

  final String date;
  final String time;
  final String semester;
  final List<AttendanceRowExportInput> rows;
  final String title;
  final String sessionTitle;
  final String? outputName;
}

class TrainingPlanExportInput {
  const TrainingPlanExportInput({
    required this.title,
    required this.semester,
    required this.date,
    required this.body,
    this.outputName,
  });

  final String title;
  final String semester;
  final String date;
  final String body;
  final String? outputName;
}

class ExportedDocumentFiles {
  const ExportedDocumentFiles({
    required this.fileStem,
    required this.texFile,
    required this.pdfFile,
  });

  final String fileStem;
  final File texFile;
  final File pdfFile;
}

class _DocumentContent {
  const _DocumentContent({
    required this.title,
    required this.subtitle,
    required this.date,
    required this.fields,
    required this.sectionTitle,
    required this.body,
  });

  final String title;
  final String subtitle;
  final String date;
  final List<ExportField> fields;
  final String sectionTitle;
  final String body;
}

const _lionRed = PdfColor(0.725, 0.290, 0.212);
const _ink = PdfColor(0.157, 0.239, 0.200);
const _bodyInk = PdfColor(0.208, 0.282, 0.239);
const _muted = PdfColor(0.498, 0.533, 0.486);
const _divider = PdfColor(0.925, 0.902, 0.855);

const _recordTemplate = r'''\documentclass[UTF8,12pt]{ctexart}
\usepackage[a4paper,margin=24mm]{geometry}
\usepackage{tabularx}
\usepackage{xcolor}
\usepackage{enumitem}
\definecolor{LionRed}{HTML}{B94A36}
\setlength{\parindent}{2em}
\setlength{\parskip}{0.45em}
\begin{document}
\begin{center}
  {\color{LionRed}\rule{0.78\linewidth}{1.2pt}}\\[1.2em]
  {\LARGE\bfseries {{title}}}\\[0.6em]
  {\large {{subtitle}}}\\[1.2em]
  {\color{LionRed}\rule{0.78\linewidth}{0.5pt}}
\end{center}
\vspace{1em}
{{body}}
\vfill
\begin{flushright}
  {{signature}}\\[0.4em]
  {{date}}
\end{flushright}
\end{document}
''';

const _attendanceTemplate = r'''\documentclass[UTF8,11pt]{ctexart}
\usepackage[a4paper,margin=18mm]{geometry}
\usepackage{longtable}
\usepackage{array}
\usepackage{xcolor}
\definecolor{LionRed}{HTML}{B94A36}
\begin{document}
\begin{center}
  {\color{LionRed}\LARGE\bfseries 狮队训练考勤记录}\\[0.7em]
  {{date}}\quad {{time}}\quad {{semester}}
\end{center}
\vspace{0.8em}
\begin{longtable}{|>{\centering\arraybackslash}p{12mm}|p{45mm}|p{35mm}|p{32mm}|p{42mm}|}
\hline
序号 & 姓名 & 学号 & 考勤 & 备注 \\ \hline
{{rows}}
\end{longtable}
\vspace{1em}
应到 {{total}} 人\quad 参加 {{present}} 人\quad 未参加 {{absent}} 人
\end{document}
''';

const _trainingPlanTemplate = r'''\documentclass[UTF8,12pt]{ctexart}
\usepackage[a4paper,margin=24mm]{geometry}
\usepackage{xcolor}
\definecolor{LionRed}{HTML}{B94A36}
\setlength{\parindent}{2em}
\setlength{\parskip}{0.5em}
\begin{document}
\begin{center}
  {\color{LionRed}\Large 舞狮队训练计划}\\[0.6em]
  {\LARGE\bfseries {{title}}}\\[0.6em]
  {{semester}}
\end{center}
\vspace{1em}
{{body}}
\vfill
\begin{flushright}舞狮队\\{{date}}\end{flushright}
\end{document}
''';

String _normalizedBody(String body, {required String emptyText}) {
  final trimmed = body.trim();
  return trimmed.isEmpty ? emptyText : trimmed;
}

String _replaceTemplate(String template, Map<String, String> values) =>
    template.replaceAllMapped(
      RegExp(r'\{\{(\w+)\}\}'),
      (match) => values[match[1]] ?? '',
    );

String _texParagraphs(String body, {required String emptyText}) {
  final normalized = _normalizedBody(body, emptyText: emptyText);
  final paragraphs = normalized.split(RegExp(r'\r?\n\s*\r?\n'));
  return paragraphs
      .map((paragraph) => '\\par\n${_texLines(paragraph)}')
      .join('\n');
}

String _texLines(String value) =>
    value.split(RegExp(r'\r?\n')).map(_texEscape).join(r'\\' + '\n');

String _texEscape(String value) {
  final result = StringBuffer();
  for (final rune in value.runes) {
    final character = String.fromCharCode(rune);
    result.write(switch (character) {
      '\\' => r'\textbackslash{}',
      '#' => r'\#',
      r'$' => r'\$',
      '%' => r'\%',
      '&' => r'\&',
      '_' => r'\_',
      '{' => r'\{',
      '}' => r'\}',
      '^' => r'\textasciicircum{}',
      '~' => r'\textasciitilde{}',
      _ => character,
    });
  }
  return result.toString();
}

String _safeFileStem(String requestedName) {
  final safe = requestedName
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^[.\-]+|[.\-]+$'), '');
  return safe.isEmpty ? 'lion-team-record' : safe;
}

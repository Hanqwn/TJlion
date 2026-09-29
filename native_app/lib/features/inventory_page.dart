import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/lion_repository.dart';
import '../data/models.dart';
import '../services/excel_import_service.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key, required this.repository});

  final LionRepository repository;

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final TextEditingController _search = TextEditingController();
  List<InventoryItemModel> _items = const [];
  String? _categoryFilter;
  String _stockFilter = 'all';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _reload();
    _search.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() => _items = widget.repository.getInventoryItems());
  }

  List<InventoryItemModel> get _visibleItems {
    final query = _search.text.trim().toLowerCase();
    return _items
        .where((item) {
          if (_categoryFilter != null && item.category != _categoryFilter) {
            return false;
          }
          if (_stockFilter == 'available' && item.currentQuantity == 0) {
            return false;
          }
          if (_stockFilter == 'empty' && item.currentQuantity != 0)
            return false;
          if (query.isEmpty) return true;
          return item.name.toLowerCase().contains(query) ||
              item.category.toLowerCase().contains(query) ||
              item.unit.toLowerCase().contains(query) ||
              item.location.toLowerCase().contains(query) ||
              item.condition.toLowerCase().contains(query) ||
              item.notes.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      _message('操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _editItem([InventoryItemModel? item]) async {
    final draft = await showDialog<_InventoryDraft>(
      context: context,
      builder: (context) => _InventoryItemEditor(item: item),
    );
    if (draft == null || !mounted) return;
    try {
      if (item == null) {
        widget.repository.addInventoryItem(
          name: draft.name,
          category: draft.category,
          unit: draft.unit,
          currentQuantity: draft.quantity,
          location: draft.location,
          condition: draft.condition,
          notes: draft.notes,
        );
        _message('道具已添加');
      } else {
        widget.repository.updateInventoryItem(
          InventoryItemModel(
            id: item.id,
            name: draft.name,
            category: draft.category,
            unit: draft.unit,
            currentQuantity: draft.quantity,
            location: draft.location,
            condition: draft.condition,
            notes: draft.notes,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
          ),
          adjustmentNotes: draft.adjustmentNotes,
        );
        _message('道具资料已更新');
      }
      _reload();
    } catch (error) {
      _message('保存失败：$error');
    }
  }

  Future<void> _deleteItem(InventoryItemModel item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这个道具？'),
        content: Text('“' + item.name + '”及其流水记录将从清单中删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      widget.repository.deleteInventoryItem(item.id);
      _reload();
      _message('道具已删除');
    } catch (error) {
      _message('删除失败：$error');
    }
  }

  Future<void> _addMovement(InventoryItemModel item) async {
    final draft = await showDialog<_MovementDraft>(
      context: context,
      builder: (context) => _MovementEditor(itemName: item.name),
    );
    if (draft == null || !mounted) return;
    try {
      widget.repository.addInventoryMovement(
        itemId: item.id,
        movementType: draft.type,
        quantity: draft.quantity,
        movementDate: draft.date,
        notes: draft.notes,
      );
      _reload();
      _message('道具流水已记录');
    } catch (error) {
      _message('记录失败：$error');
    }
  }

  Future<void> _showHistory(InventoryItemModel item) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _InventoryHistoryDialog(
        repository: widget.repository,
        item: item,
        onChanged: _reload,
      ),
    );
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final padding = width < 560 ? 16.0 : 28.0;
    final totalUnits = _items.fold<int>(
      0,
      (sum, item) => sum + item.currentQuantity,
    );
    final emptyCount = _items.where((item) => item.currentQuantity == 0).length;
    final categories =
        _items
            .map((item) => item.category.trim())
            .where((category) => category.isNotEmpty)
            .toSet()
            .toList()
          ..sort();

    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = (constraints.maxWidth - padding * 2)
            .clamp(0.0, 1180.0)
            .toDouble();
        return Padding(
          padding: EdgeInsets.fromLTRB(padding, 18, padding, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildHeading(context),
                  if (_busy) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: 14),
                  _buildSummary(contentWidth, totalUnits, emptyCount),
                  const SizedBox(height: 12),
                  _buildSearchAndFilters(categories),
                  const SizedBox(height: 10),
                  Expanded(child: _buildItemList()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeading(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 10,
      spacing: 12,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '道具清单',
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            Text(
              '管理数量、存放位置、状态与出入库流水。',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_importSpreadsheet),
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('导入 XLSX'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_saveTemplate),
              icon: const Icon(Icons.download_outlined),
              label: const Text('下载模板'),
            ),
            FilledButton.icon(
              onPressed: _busy ? null : () => _editItem(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('新增道具'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSummary(double width, int totalUnits, int emptyCount) {
    final availableCount = _items.length - emptyCount;
    final stats = [
      _InventoryStat(
        '道具种类',
        _items.length.toString(),
        Icons.inventory_2_outlined,
      ),
      _InventoryStat('当前总数', totalUnits.toString(), Icons.numbers_rounded),
      _InventoryStat(
        '有库存',
        availableCount.toString(),
        Icons.check_circle_outline,
      ),
      _InventoryStat(
        '零库存',
        emptyCount.toString(),
        Icons.remove_shopping_cart_outlined,
      ),
    ];
    final columns = (width / 220).floor().clamp(1, 4).toInt();
    const gap = 10.0;
    final cellWidth = (width - (columns - 1) * gap) / columns;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: stats
          .map(
            (stat) => SizedBox(
              width: cellWidth,
              child: _InventoryStatCard(stat: stat),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildSearchAndFilters(List<String> categories) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _search,
              decoration: InputDecoration(
                hintText: '搜索名称、类别、位置或备注',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        onPressed: _search.clear,
                        icon: const Icon(Icons.close),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('全部类别'),
                    selected: _categoryFilter == null,
                    onSelected: (_) => setState(() => _categoryFilter = null),
                  ),
                  ...categories.map(
                    (category) => ChoiceChip(
                      label: Text(category),
                      selected: _categoryFilter == category,
                      onSelected: (_) => setState(
                        () => _categoryFilter = _categoryFilter == category
                            ? null
                            : category,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('全部数量'),
                    selected: _stockFilter == 'all',
                    onSelected: (_) => setState(() => _stockFilter = 'all'),
                  ),
                  ChoiceChip(
                    label: const Text('有库存'),
                    selected: _stockFilter == 'available',
                    onSelected: (_) =>
                        setState(() => _stockFilter = 'available'),
                  ),
                  ChoiceChip(
                    label: const Text('零库存'),
                    selected: _stockFilter == 'empty',
                    onSelected: (_) => setState(() => _stockFilter = 'empty'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemList() {
    final visible = _visibleItems;
    if (visible.isEmpty) {
      return _ArchiveEmptyInventory(
        title: _items.isEmpty ? '还没有道具' : '没有匹配的道具',
        message: _items.isEmpty ? '新增一件道具开始建立清单。' : '调整搜索词或筛选条件。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: visible.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = visible[index];
        return _InventoryItemCard(
          item: item,
          onAddMovement: () => _addMovement(item),
          onHistory: () => _showHistory(item),
          onEdit: () => _editItem(item),
          onDelete: () => _deleteItem(item),
        );
      },
    );
  }

  Future<void> _importSpreadsheet() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择道具 XLSX 清单',
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
    );
    if (picked == null) return;
    final path = picked.path;
    if (path == null || path.isEmpty) {
      throw const FormatException('无法读取所选工作簿的位置。');
    }

    final bytes = await File(path).readAsBytes();
    final result = const ExcelImportService().parseInventory(bytes);
    final candidates = <_ImportedItem>[];
    final invalidRows = <int>[];
    for (final row in result.rows) {
      final name = (row.fields['道具名称'] ?? '').trim();
      final quantity = row.numericFields['数量'];
      if (name.isEmpty ||
          quantity == null ||
          quantity < 0 ||
          quantity.toDouble() != quantity.toInt().toDouble()) {
        invalidRows.add(row.rowNumber);
        continue;
      }
      candidates.add(
        _ImportedItem(
          rowNumber: row.rowNumber,
          name: name,
          category: (row.fields['类别'] ?? '').trim(),
          unit: (row.fields['单位'] ?? '').trim(),
          quantity: quantity.toInt(),
          location: (row.fields['存放位置'] ?? '').trim(),
          condition: (row.fields['状态'] ?? '').trim(),
          notes: (row.fields['备注'] ?? '').trim(),
        ),
      );
    }

    final diagnostics = result.diagnostics
        .take(8)
        .map((diagnostic) => diagnostic.message)
        .toList(growable: false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _InventoryImportPreview(
        sheetName: result.sheetName,
        candidates: candidates,
        invalidRows: invalidRows,
        diagnostics: diagnostics,
        hasErrors: result.hasErrors,
      ),
    );
    if (confirmed != true || !mounted) return;

    var imported = 0;
    final failures = <String>[];
    for (final item in candidates) {
      try {
        widget.repository.addInventoryItem(
          name: item.name,
          category: item.category,
          unit: item.unit,
          currentQuantity: item.quantity,
          location: item.location,
          condition: item.condition,
          notes: item.notes,
        );
        imported++;
      } catch (error) {
        failures.add(
          '第 ' + item.rowNumber.toString() + ' 行：' + error.toString(),
        );
      }
    }
    _reload();
    if (failures.isEmpty) {
      _message('导入完成：新增 $imported 件道具。');
    } else {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('导入完成：新增 $imported 件'),
          content: SizedBox(
            width: 520,
            height: 300,
            child: ListView(
              children: failures.map((failure) => Text(failure)).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _saveTemplate() async {
    final data = await rootBundle.load(
      'assets/templates/prop_inventory_template.xlsx',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final saved = await FilePicker.saveFile(
      fileName: 'lion-prop-inventory-template.xlsx',
      bytes: bytes,
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    if (saved != null) _message('模板已保存：' + saved.toString());
  }
}

class _ImportedItem {
  const _ImportedItem({
    required this.rowNumber,
    required this.name,
    required this.category,
    required this.unit,
    required this.quantity,
    required this.location,
    required this.condition,
    required this.notes,
  });

  final int rowNumber;
  final String name;
  final String category;
  final String unit;
  final int quantity;
  final String location;
  final String condition;
  final String notes;
}

class _InventoryStat {
  const _InventoryStat(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;
}

class _InventoryStatCard extends StatelessWidget {
  const _InventoryStatCard({required this.stat});
  final _InventoryStat stat;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Row(
          children: [
            Icon(stat.icon, color: colors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stat.value,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    stat.label,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InventoryItemCard extends StatelessWidget {
  const _InventoryItemCard({
    required this.item,
    required this.onAddMovement,
    required this.onHistory,
    required this.onEdit,
    required this.onDelete,
  });

  final InventoryItemModel item;
  final VoidCallback onAddMovement;
  final VoidCallback onHistory;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final amount =
        item.currentQuantity.toString() +
        (item.unit.isEmpty ? '' : ' ' + item.unit);
    final details = [
      if (item.category.isNotEmpty) item.category,
      if (item.location.isNotEmpty) '位置：' + item.location,
      if (item.condition.isNotEmpty) '状态：' + item.condition,
    ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
        child: Column(
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: colors.primaryContainer,
                  foregroundColor: colors.onPrimaryContainer,
                  child: const Icon(Icons.inventory_2_outlined),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (details.isNotEmpty)
                        Text(
                          details,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      if (item.notes.trim().isNotEmpty)
                        Text(
                          item.notes,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      amount,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      '当前数量',
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
            const Divider(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    onPressed: onAddMovement,
                    icon: const Icon(Icons.add_box_outlined),
                    label: const Text('记流水'),
                  ),
                  IconButton(
                    tooltip: '流水历史',
                    onPressed: onHistory,
                    icon: const Icon(Icons.history_rounded),
                  ),
                  IconButton(
                    tooltip: '编辑道具',
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: '删除道具',
                    onPressed: onDelete,
                    icon: Icon(Icons.delete_outline, color: colors.error),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InventoryDraft {
  const _InventoryDraft({
    required this.name,
    required this.category,
    required this.unit,
    required this.quantity,
    required this.location,
    required this.condition,
    required this.notes,
    required this.adjustmentNotes,
  });

  final String name;
  final String category;
  final String unit;
  final int quantity;
  final String location;
  final String condition;
  final String notes;
  final String adjustmentNotes;
}

class _InventoryItemEditor extends StatefulWidget {
  const _InventoryItemEditor({this.item});
  final InventoryItemModel? item;

  @override
  State<_InventoryItemEditor> createState() => _InventoryItemEditorState();
}

class _InventoryItemEditorState extends State<_InventoryItemEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _category;
  late final TextEditingController _unit;
  late final TextEditingController _quantity;
  late final TextEditingController _location;
  late final TextEditingController _condition;
  late final TextEditingController _notes;
  late final TextEditingController _adjustmentNotes;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _name = TextEditingController(text: item?.name ?? '');
    _category = TextEditingController(text: item?.category ?? '');
    _unit = TextEditingController(text: item?.unit ?? '');
    _quantity = TextEditingController(
      text: item?.currentQuantity.toString() ?? '0',
    );
    _location = TextEditingController(text: item?.location ?? '');
    _condition = TextEditingController(text: item?.condition ?? '');
    _notes = TextEditingController(text: item?.notes ?? '');
    _adjustmentNotes = TextEditingController(text: '手动盘点调整');
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _unit.dispose();
    _quantity.dispose();
    _location.dispose();
    _condition.dispose();
    _notes.dispose();
    _adjustmentNotes.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _InventoryDraft(
        name: _name.text.trim(),
        category: _category.text.trim(),
        unit: _unit.text.trim(),
        quantity: int.parse(_quantity.text.trim()),
        location: _location.text.trim(),
        condition: _condition.text.trim(),
        notes: _notes.text.trim(),
        adjustmentNotes: _adjustmentNotes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return AlertDialog(
      title: Text(item == null ? '新增道具' : '编辑道具'),
      content: SizedBox(
        width: 540,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(_name, '名称 *', required: true),
                _field(_category, '类别'),
                Row(
                  children: [
                    Expanded(child: _field(_quantity, '当前数量 *', number: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _field(_unit, '单位')),
                  ],
                ),
                _field(_location, '存放位置'),
                _field(_condition, '状态 / 品相'),
                _field(_notes, '备注', maxLines: 3),
                if (item != null) ...[
                  const SizedBox(height: 8),
                  _field(_adjustmentNotes, '数量调整原因'),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool number = false,
    int maxLines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: TextFormField(
        controller: controller,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        minLines: maxLines,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          final text = (value ?? '').trim();
          if (required && text.isEmpty) return '此项必填';
          if (number) {
            final quantity = int.tryParse(text);
            if (quantity == null || quantity < 0) return '请输入非负整数';
          }
          return null;
        },
      ),
    );
  }
}

class _MovementDraft {
  const _MovementDraft({
    required this.type,
    required this.quantity,
    required this.date,
    required this.notes,
  });
  final InventoryMovementType type;
  final int quantity;
  final String date;
  final String notes;
}

class _MovementEditor extends StatefulWidget {
  const _MovementEditor({required this.itemName, this.movement});
  final String itemName;
  final InventoryMovementModel? movement;

  @override
  State<_MovementEditor> createState() => _MovementEditorState();
}

class _MovementEditorState extends State<_MovementEditor> {
  final _formKey = GlobalKey<FormState>();
  late InventoryMovementType _type;
  late final TextEditingController _quantity;
  late final TextEditingController _date;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    final movement = widget.movement;
    _type = movement?.movementType ?? InventoryMovementType.received;
    final initialQuantity = movement == null
        ? ''
        : movement.movementType == InventoryMovementType.adjustment
        ? movement.quantityDelta.toString()
        : movement.quantityDelta.abs().toString();
    _quantity = TextEditingController(text: initialQuantity);
    _date = TextEditingController(
      text: movement?.movementDate ?? _inventoryToday(),
    );
    _notes = TextEditingController(text: movement?.notes ?? '');
  }

  @override
  void dispose() {
    _quantity.dispose();
    _date.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _MovementDraft(
        type: _type,
        quantity: int.parse(_quantity.text.trim()),
        date: _date.text.trim(),
        notes: _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.movement == null ? '记录流水' : '编辑流水';
    return AlertDialog(
      title: Text(action + ' · ' + widget.itemName),
      content: SizedBox(
        width: 500,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<InventoryMovementType>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: '流水类型'),
                items: InventoryMovementType.values
                    .map(
                      (type) => DropdownMenuItem(
                        value: type,
                        child: Text(_movementTypeLabel(type)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (type) {
                  if (type != null) setState(() => _type = type);
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _quantity,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
                decoration: InputDecoration(
                  labelText: _type == InventoryMovementType.adjustment
                      ? '调整数量（可正可负）'
                      : '数量（正整数）',
                  helperText: _type == InventoryMovementType.adjustment
                      ? '正数表示增加，负数表示减少。'
                      : '出库类流水会自动扣减当前数量。',
                ),
                validator: (value) {
                  final quantity = int.tryParse((value ?? '').trim());
                  if (quantity == null) return '请输入整数';
                  if (_type == InventoryMovementType.adjustment) {
                    return quantity == 0 ? '调整数量不能为 0' : null;
                  }
                  return quantity <= 0 ? '请输入大于 0 的数量' : null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _date,
                decoration: const InputDecoration(
                  labelText: '日期',
                  hintText: 'YYYY-MM-DD',
                ),
                validator: (value) =>
                    DateTime.tryParse((value ?? '').trim()) == null
                    ? '请输入有效日期'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _notes,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: '备注'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存流水')),
      ],
    );
  }
}

class _InventoryHistoryDialog extends StatefulWidget {
  const _InventoryHistoryDialog({
    required this.repository,
    required this.item,
    required this.onChanged,
  });
  final LionRepository repository;
  final InventoryItemModel item;
  final VoidCallback onChanged;

  @override
  State<_InventoryHistoryDialog> createState() =>
      _InventoryHistoryDialogState();
}

class _InventoryHistoryDialogState extends State<_InventoryHistoryDialog> {
  late List<InventoryMovementModel> _movements;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _movements = widget.repository.getInventoryMovements(
      itemId: widget.item.id,
    );
  }

  Future<void> _edit(InventoryMovementModel movement) async {
    final draft = await showDialog<_MovementDraft>(
      context: context,
      builder: (context) =>
          _MovementEditor(itemName: widget.item.name, movement: movement),
    );
    if (draft == null || !mounted) return;
    final magnitude = draft.quantity.abs();
    final delta = draft.type == InventoryMovementType.adjustment
        ? draft.quantity
        : draft.type.isOutbound
        ? -magnitude
        : magnitude;
    try {
      widget.repository.updateInventoryMovement(
        InventoryMovementModel(
          id: movement.id,
          itemId: movement.itemId,
          movementType: draft.type,
          quantityDelta: delta,
          movementDate: draft.date,
          notes: draft.notes,
          createdAt: movement.createdAt,
        ),
      );
      setState(_reload);
      widget.onChanged();
    } catch (error) {
      _message('更新流水失败：$error');
    }
  }

  Future<void> _delete(InventoryMovementModel movement) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除这条流水？'),
        content: const Text('删除流水会重新计算当前道具数量。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      widget.repository.deleteInventoryMovement(movement.id);
      setState(_reload);
      widget.onChanged();
    } catch (error) {
      _message('删除流水失败：$error');
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final itemName = widget.item.name;
    final height = MediaQuery.sizeOf(context).height;
    return AlertDialog(
      title: Text('流水历史 · ' + itemName),
      content: SizedBox(
        width: 680,
        height: height * 0.55,
        child: _movements.isEmpty
            ? const Center(child: Text('还没有流水记录。'))
            : ListView.separated(
                itemCount: _movements.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final movement = _movements[index];
                  final sign = movement.quantityDelta > 0 ? '+' : '';
                  final quantity = sign + movement.quantityDelta.toString();
                  final unit = widget.item.unit.isEmpty
                      ? ''
                      : ' ' + widget.item.unit;
                  final notes = movement.notes.isEmpty
                      ? ''
                      : ' · ' + movement.notes;
                  return ListTile(
                    leading: Icon(
                      movement.quantityDelta >= 0
                          ? Icons.add_circle_outline
                          : Icons.remove_circle_outline,
                    ),
                    title: Text(
                      _movementTypeLabel(movement.movementType) +
                          ' · ' +
                          quantity +
                          unit,
                    ),
                    subtitle: Text(
                      _inventoryDate(movement.movementDate) + notes,
                    ),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: '编辑流水',
                          onPressed: () => _edit(movement),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: '删除流水',
                          onPressed: () => _delete(movement),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _InventoryImportPreview extends StatelessWidget {
  const _InventoryImportPreview({
    required this.sheetName,
    required this.candidates,
    required this.invalidRows,
    required this.diagnostics,
    required this.hasErrors,
  });

  final String sheetName;
  final List<_ImportedItem> candidates;
  final List<int> invalidRows;
  final List<String> diagnostics;
  final bool hasErrors;

  @override
  Widget build(BuildContext context) {
    final validCount = candidates.length;
    final confirmLabel = '确认导入 ' + validCount.toString() + ' 行';
    final invalidText = invalidRows.isEmpty
        ? ''
        : '未导入行（名称为空或数量非整数）：' + invalidRows.take(20).join('、');
    return AlertDialog(
      title: const Text('道具表格导入预览'),
      content: SizedBox(
        width: 620,
        height: 470,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('工作表：' + sheetName),
            const SizedBox(height: 4),
            Text('可导入 ' + validCount.toString() + ' 行；其余行会跳过，模板错误会阻止导入。'),
            if (invalidText.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                invalidText,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (diagnostics.isNotEmpty) ...[
              const SizedBox(height: 8),
              const Text('表格提示', style: TextStyle(fontWeight: FontWeight.w700)),
              Expanded(
                flex: 2,
                child: ListView(
                  children: diagnostics
                      .map(
                        (message) => Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('• ' + message),
                        ),
                      )
                      .toList(growable: false),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text('预览', style: TextStyle(fontWeight: FontWeight.w700)),
            Expanded(
              flex: 3,
              child: candidates.isEmpty
                  ? const Center(child: Text('没有可导入的有效行。'))
                  : ListView.separated(
                      itemCount: candidates.length.clamp(0, 12).toInt(),
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = candidates[index];
                        final quantity =
                            item.quantity.toString() +
                            (item.unit.isEmpty ? '' : ' ' + item.unit);
                        final details = [
                          if (item.category.isNotEmpty) item.category,
                          quantity,
                          if (item.location.isNotEmpty) item.location,
                          if (item.condition.isNotEmpty) item.condition,
                        ].join(' · ');
                        return ListTile(
                          dense: true,
                          title: Text(
                            '第 ' +
                                item.rowNumber.toString() +
                                ' 行 · ' +
                                item.name,
                          ),
                          subtitle: Text(details),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: hasErrors || candidates.isEmpty
              ? null
              : () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

class _ArchiveEmptyInventory extends StatelessWidget {
  const _ArchiveEmptyInventory({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inventory_2_outlined, size: 46, color: colors.primary),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

String _movementTypeLabel(InventoryMovementType type) {
  return switch (type) {
    InventoryMovementType.received => '增补',
    InventoryMovementType.purchased => '采购',
    InventoryMovementType.found => '发现',
    InventoryMovementType.lost => '丢失',
    InventoryMovementType.stolen => '被盗',
    InventoryMovementType.disposed => '报废',
    InventoryMovementType.adjustment => '盘点调整',
  };
}

String _inventoryToday() {
  final now = DateTime.now();
  return _inventoryDate(
    now.year.toString() +
        '-' +
        now.month.toString().padLeft(2, '0') +
        '-' +
        now.day.toString().padLeft(2, '0'),
  );
}

String _inventoryDate(String value) {
  final parsed = DateTime.tryParse(value.trim());
  if (parsed == null) return value;
  final year = parsed.year.toString().padLeft(4, '0');
  final month = parsed.month.toString().padLeft(2, '0');
  final day = parsed.day.toString().padLeft(2, '0');
  return year + '-' + month + '-' + day;
}
